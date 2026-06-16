// F1 fault-isolation boot: one image that brings up the heap + console, installs a REAL
// M-mode trap vector, spawns three sandboxed agents (A, B, C), then has agent C trigger a
// GENUINE synchronous trap (an illegal instruction). The trap handler CONTAINS it: it
// recognizes the fault occurred in agent C's fault domain, kills+reclaims C through the SAME
// death path the OOM keystone uses (fds + memory account + IPC + waiters released), advances
// past the faulting instruction, and resumes the KERNEL — so A and B keep running and the
// machine does NOT halt. Returns a stage bitmask (0x7 = heap+console up and containment fully
// proven); the runtime prints FAULT-ISOLATION-OK when complete.
//
// Contrast with the keystone: the OOM path kills a NON-current runaway (pure bookkeeping, no
// trap). Here the victim is the agent that owned the CPU when a real trap fired, so the kill
// must terminate the running domain and the handler must resume elsewhere — the trap-and-contain
// path proper. Without the classification + recover-PC logic the same trap would fall through to
// panic_trap and HALT the kernel (the fail-closed default of the timer handler).

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

// Bookkeeping the handler/post-fault checks consult.
global g_fault_seen: bool = false;   // the trap handler ran and classified an agent fault
global g_killed_slot: usize = 0;     // the slot the handler reclaimed
global g_victim_slot: usize = 0;     // the slot we EXPECT the fault to be attributed to (agent C)

fn uart_putc(u: *Uart, b: u8) -> void {
    unsafe {
        raw.store<u8>(phys(u.base), b);
    }
}

fn say(c: u8) -> void {
    chardev_putc(&g_chardevs, g_uart_id, c);
}

// A LIVE agent never exits.
fn worker() -> void {}

// Platform primitives (in fault_isolation_runtime.c): install the M-mode trap vector, and
// execute a real illegal instruction (the agent's fault). mc_agent_fault returns only because
// the handler CONTAINED the trap and resumed past it; if the fault halted the kernel it would
// never return.
extern fn mc_install_trap_vector() -> void;
extern fn mc_agent_fault() -> void;

// The trap-handler callback. The asm trap stub calls this with the trap cause/PC/value. It
// classifies the trap and, if it is attributable to a live agent (a fault domain is marked),
// CONTAINS it: kill+reclaim the faulting agent through the process death path. Returns the PC to
// RESUME at: faulting PC + 4 (skip the offending 4-byte instruction) so `mret` lands back in the
// kernel, NOT in the dead agent. A fault with no marked domain is the kernel's own and stays
// fatal: we return 0 to tell the stub to panic+halt (fail closed, exactly as the timer handler
// does for an unexpected trap).
export fn handle_agent_fault(mcause: u64, mepc: u64, mtval: u64) -> u64 {
    // Interrupt bit set (MSB) => asynchronous (e.g. timer); not a fault domain question. We only
    // contain SYNCHRONOUS exceptions here. (No timer is armed in this demo, so this is defensive.)
    let is_interrupt: bool = (mcause & 0x8000_0000_0000_0000) != 0;
    if is_interrupt {
        return mepc; // resume where we were; nothing to contain
    }
    switch proc_fault_contain(&g_procs) {
        ok(slot) => {
            g_fault_seen = true;
            g_killed_slot = slot;
            return mepc + 4; // contained: skip the faulting instruction, resume the kernel
        }
        err(e) => {
            return 0; // not attributable to any agent — fatal kernel fault: panic+halt
        }
    }
}

// Drive the containment keystone inline on the boot thread.
fn run_keystone() -> bool {
    var pass: bool = true;
    proc_table_init(&g_procs);

    // Spawn three agents from the bootstrap (pid 0). All stay LIVE — none exits cleanly.
    let a: u32 = proc_spawn(&g_procs, 0x1000, worker);
    let b: u32 = proc_spawn(&g_procs, 0x2000, worker);
    let c: u32 = proc_spawn(&g_procs, 0x3000, worker);
    let sa: usize = a as usize;
    let sb: usize = b as usize;
    let sc: usize = c as usize;
    g_victim_slot = sc;

    // Charge memory + give C an open fd, so we can prove the kill reclaims them.
    switch proc_charge_mem(&g_procs, sa, 1000) {
        ok(used) => { if used != 1000 { pass = false; } }
        err(e) => { pass = false; }
    }
    switch proc_charge_mem(&g_procs, sb, 2000) {
        ok(used) => { if used != 2000 { pass = false; } }
        err(e) => { pass = false; }
    }
    switch proc_charge_mem(&g_procs, sc, 4000) {
        ok(used) => { if used != 4000 { pass = false; } }
        err(e) => { pass = false; }
    }
    switch fd_alloc(proc_fds(&g_procs, sc), 1, 7) {
        ok(fd) => {}
        err(e) => { pass = false; }
    }
    if fd_count(proc_fds(&g_procs, sc)) == 0 { pass = false; } // C holds an fd before the kill
    if pass { say(0x41); } // 'A' — agents spawned, charged, C holds resources

    // Install the real trap vector, then ENTER agent C's fault domain: from here a trap is
    // attributable to C. (In a full kernel this is the context switch into C; here the fault is
    // executed inline but tagged with C's domain, which is the authority the handler consults.)
    mc_install_trap_vector();
    proc_enter_agent(&g_procs, sc);

    // C FAULTS: a genuine illegal instruction. Control re-enters the trap vector, which calls
    // handle_agent_fault -> contains the fault (kills+reclaims C) and resumes here past the trap.
    mc_agent_fault();

    // --- We are back: the kernel SURVIVED a real trap. Verify containment. ---
    if !g_fault_seen { pass = false; }                 // the handler actually ran + classified
    if g_killed_slot != sc { pass = false; }           // it reclaimed exactly agent C
    if proc_is_live(&g_procs, sc) { pass = false; }    // C is no longer live
    if proc_state_code(&g_procs, sc) != 4 { pass = false; }          // 4 == Zombie
    if resacct_used(proc_macct(&g_procs, sc)) != 0 { pass = false; } // memory account reclaimed
    if fd_count(proc_fds(&g_procs, sc)) != 0 { pass = false; }       // fd-space released
    if pass { say(0x42); } // 'B' — real trap contained, faulting agent killed + reclaimed

    // The OTHER agents survive: A and B are STILL LIVE with their accounts intact.
    if !proc_is_live(&g_procs, sa) { pass = false; }
    if !proc_is_live(&g_procs, sb) { pass = false; }
    if resacct_used(proc_macct(&g_procs, sa)) != 1000 { pass = false; }
    if resacct_used(proc_macct(&g_procs, sb)) != 2000 { pass = false; }
    // The fault domain is cleared — the kernel runs outside any agent now.
    switch proc_fault_domain(&g_procs) {
        ok(s) => { pass = false; } // a domain still marked would be wrong
        err(e) => {}               // expected: no domain (kernel context)
    }
    if pass { say(0x43); } // 'C' — others survive, kernel runs on

    // C, a zombie, reaps like any normal death (parent is the bootstrap, pid 0), exit code marks
    // the contained fault.
    switch proc_reap(&g_procs, 0) {
        ok(info) => {
            if info.pid != c { pass = false; }
            if info.code != 0xDEAD_00F1 { pass = false; } // FAULT_KILLED_CODE sentinel
        }
        err(e) => { pass = false; }
    }
    if pass { say(0x44); } // 'D' — faulting agent reaped with the fault sentinel

    return pass;
}

export fn fault_isolation_main(region_base: usize, region_len: usize) -> u32 {
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
    g_uart_id = register_chardev(&g_chardevs, bind(&g_uart, uart_putc));
    stages = stages | 0x2;
    say(0x31); // '1' — heap + console are up

    // 3) The fault-isolation containment keystone, inline on the boot thread.
    if run_keystone() {
        stages = stages | 0x4;
        say(0x32); // '2' — containment proven
    }

    return stages;
}
