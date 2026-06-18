// Integrated agent-OS governance boot: one image that brings up the heap and the
// console driver, then runs the agent-OS safety keystone INLINE in the boot thread.
// The governance / OOM-kill path is pure bookkeeping (no real context switches needed):
//   * proc_table_init; spawn three LIVE agents A, B, C (none ever exits);
//   * charge memory — A and B modestly, C far more (C is the runaway);
//   * an over-quota charge against C fails closed (err(.OverQuota)), reserving nothing;
//   * proc_oom_victim selects C (highest-usage live, non-bootstrap offender);
//   * proc_oom_reclaim OOM-kills C: it becomes a non-live Zombie with its memory account
//     reset to zero and its fds released, while A and B stay LIVE with accounts intact;
//   * C, now a zombie, reaps cleanly like any normal death.
// Returns a bitmask of the stages that succeeded (0x7 = heap+console up and the keystone
// fully passed). The boot runtime prints AGENTOS-OK when the mask is complete.

import "kernel/core/heap.mc";
import "kernel/core/device.mc";
import "kernel/core/process.mc";
import "kernel/lib/resacct.mc";
import "kernel/lib/fdspace.mc";
import "std/addr.mc";

const UART_BASE: usize = 0x1000_0000;

struct Uart { base: usize }

global g_chardevs: CharRegistry;
global g_uart: Uart;
global g_uart_id: usize;
global g_procs: ProcTable;

impl CharDevice for Uart {
    fn putc(self: *Uart, b: u8) -> void {
        unsafe {
            raw.store<u8>(phys(self.base), b);
        }
    }
}

// Print one byte through the registered console driver (the driver framework in use).
fn say(c: u8) -> void {
    chardev_putc(&g_chardevs, g_uart_id, c);
}

// A LIVE child never exits.
fn worker() -> void {}

// The agent-OS safety keystone, driven inline (mirrors tests/qemu/proc/oom_demo.mc).
fn run_keystone() -> bool {
    var pass: bool = true;
    proc_table_init(&g_procs);

    // Spawn three agents from the bootstrap (pid 0). All stay LIVE — none ever exits.
    let a: u32 = proc_spawn(&g_procs, 0x1000, worker);
    let b: u32 = proc_spawn(&g_procs, 0x2000, worker);
    let c: u32 = proc_spawn(&g_procs, 0x3000, worker);
    let sa: usize = a as usize;
    let sb: usize = b as usize;
    let sc: usize = c as usize;

    // Charge memory: A and B modestly, C WAY more — C is the runaway / worst offender.
    switch proc_charge_mem(&g_procs, sa, 1000) {
        ok(used) => { if used != 1000 { pass = false; } }
        err(e) => { pass = false; }
    }
    switch proc_charge_mem(&g_procs, sb, 2000) {
        ok(used) => { if used != 2000 { pass = false; } }
        err(e) => { pass = false; }
    }
    let c_big: usize = 0x100000 - 16; // 16 units shy of C's default ceiling
    switch proc_charge_mem(&g_procs, sc, c_big) {
        ok(used) => { if used != c_big { pass = false; } }
        err(e) => { pass = false; }
    }
    if pass { say(0x41); } // 'A' — agents spawned and charged

    // Give C an open fd, to prove the kill releases its fd-space.
    switch fd_alloc(proc_fds(&g_procs, sc), 1, 7) {
        ok(fd) => {}
        err(e) => { pass = false; }
    }
    if fd_count(proc_fds(&g_procs, sc)) == 0 { pass = false; } // C holds an fd before the kill

    // --- over-quota: charging C past its limit fails closed, nothing reserved ---
    switch proc_charge_mem(&g_procs, sc, 32) { // only 16 left -> over quota
        ok(used) => { pass = false; }
        err(e) => { if e != .OverQuota { pass = false; } }
    }
    if resacct_used(proc_macct(&g_procs, sc)) != c_big { pass = false; } // failed charge is a no-op
    if pass { say(0x42); } // 'B' — over-quota fail-closed verified

    // --- victim selection: C is the highest-usage live, non-bootstrap process ---
    switch proc_oom_victim(&g_procs) {
        ok(v) => { if v != sc { pass = false; } }
        err(e) => { pass = false; }
    }

    // --- LIVE reclaim: kill the runaway, reclaim its resources ---
    switch proc_oom_reclaim(&g_procs) {
        ok(slot) => { if slot != sc { pass = false; } }
        err(e) => { pass = false; }
    }

    // C is now a non-live Zombie with its memory + fds reclaimed.
    if proc_is_live(&g_procs, sc) { pass = false; }                  // C is no longer live
    if proc_state_code(&g_procs, sc) != 4 { pass = false; }          // 4 == Zombie
    if resacct_used(proc_macct(&g_procs, sc)) != 0 { pass = false; } // memory account reclaimed
    if fd_count(proc_fds(&g_procs, sc)) != 0 { pass = false; }       // fd-space released

    // The OTHER agents survive: A and B are STILL LIVE with their accounts intact.
    if !proc_is_live(&g_procs, sa) { pass = false; }
    if !proc_is_live(&g_procs, sb) { pass = false; }
    if resacct_used(proc_macct(&g_procs, sa)) != 1000 { pass = false; }
    if resacct_used(proc_macct(&g_procs, sb)) != 2000 { pass = false; }
    if pass { say(0x43); } // 'C' — runaway killed + reclaimed, others survive

    // --- C, a zombie, reaps like any normal death (the parent is the bootstrap, pid 0) ---
    switch proc_reap(&g_procs, 0) {
        ok(info) => { if info.pid != c { pass = false; } }
        err(e) => { pass = false; }
    }

    return pass;
}

export fn agentos_main(region_base: usize, region_len: usize) -> u32 {
    var stages: u32 = 0;

    // 1) Heap allocator.
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
    let probe: PAddr = heap_alloc(&heap, 64, 16);
    if pa_value(probe) != 0 {
        stages = stages | 0x1;
    }

    // 2) Driver framework: register the UART as the console device.
    char_registry_init(&g_chardevs);
    g_uart.base = UART_BASE;
    g_uart_id = register_chardev(&g_chardevs, &g_uart);
    stages = stages | 0x2;
    say(0x31); // '1' — heap + console are up

    // 3) The agent-OS governance keystone, inline on the boot thread.
    if run_keystone() {
        stages = stages | 0x4;
        say(0x32); // '2' — keystone passed
    }

    return stages;
}
