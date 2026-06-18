// An integrated kernel boot: one image that brings up several subsystems and
// exercises them together (not as separate test binaries). In order: the heap, the
// char-device driver framework (the console), the leveled logger, the VFS over
// ramfs (a file round-trip), and the process scheduler (two processes that run and
// exit). All console output goes through the registered driver. Returns a bitmask
// of the stages that succeeded (0x1F = all five).

import "kernel/core/heap.mc";
import "kernel/core/device.mc";
import "kernel/core/log.mc";
import "kernel/fs/vfs.mc";
import "kernel/core/process.mc";
import "kernel/arch/riscv64/idle.mc";
import "std/arena.mc";
import "std/pool.mc";
import "std/addr.mc";

const UART_BASE: usize = 0x1000_0000;
const STACK_SIZE: usize = 8192;

struct Uart { base: usize }

global g_chardevs: CharRegistry;
global g_uart: Uart;
global g_uart_id: usize;
global g_log: Logger;
global g_vfs: Vfs;
global g_procs: ProcTable;

// A connection/session, tracked in a generational pool (the workload below).
struct Session {
    id: u32,
    total: u32,
    active: bool,
}
global g_sessions: Pool<Session, 16>;

const N_REQUESTS: usize = 6;

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

fn alloc_stack(h: *mut Heap) -> usize {
    let base: PAddr = heap_alloc(h, STACK_SIZE, 16);
    return pa_value(base) + STACK_SIZE;
}

// VFS file round-trip: open "boot", write "OK", read it back, confirm the bytes.
fn vfs_roundtrip() -> bool {
    var name: [5]u8 = .{ 0x62, 0x6F, 0x6F, 0x74, 0 }; // "boot"
    let name_addr: usize = (&name[0]) as usize;
    var fd: usize = 0;
    switch vfs_open(&g_vfs, name_addr, 4) {
        ok(f) => {
            fd = f;
        }
        err(e) => {
            return false;
        }
    }
    var data: [2]u8 = .{ 0x4F, 0x4B }; // "OK"
    switch vfs_write(&g_vfs, fd, (&data[0]) as usize, 2) {
        ok(n) => {}
        err(e) => {
            return false;
        }
    }
    // Re-open for a fresh read position.
    var rfd: usize = 0;
    switch vfs_open(&g_vfs, name_addr, 4) {
        ok(f) => {
            rfd = f;
        }
        err(e) => {
            return false;
        }
    }
    var buf: [4]u8 = .{ 0, 0, 0, 0 };
    switch vfs_read(&g_vfs, rfd, (&buf[0]) as usize, 4) {
        ok(n) => {
            if n != 2 {
                return false;
            }
        }
        err(e) => {
            return false;
        }
    }
    return buf[0] == 0x4F && buf[1] == 0x4B; // "OK"
}

fn worker_a() -> void {
    say(0x41); // 'A'
    proc_exit(&g_procs, 0);
}
fn worker_b() -> void {
    say(0x42); // 'B'
    proc_exit(&g_procs, 0);
}

// Process one request on per-request arena scratch: write 16 bytes derived from
// `seed`, then checksum them. The scratch is a generational handle; the arena is
// reset by the caller after each request (so the handle would go stale).
fn process_request(a: *mut Arena, seed: u32) -> u32 {
    let h: GenRef<u8> = arena_alloc_gen(u8, a, 64, 8);
    var sum: u32 = 0;
    switch arena_resolve(u8, a, h) {
        ok(addr) => {
            var i: usize = 0;
            while i < 16 {
                let b: u8 = ((seed + (i as u32)) & 0xFF) as u8;
                unsafe {
                    raw.store<u8>(pa_offset(addr, i), b);
                }
                i = i + 1;
            }
            var j: usize = 0;
            while j < 16 {
                unsafe {
                    let v: u8 = raw.load<u8>(pa_offset(addr, j));
                    sum = sum + (v as u32);
                }
                j = j + 1;
            }
        }
        err(e) => {}
    }
    return sum;
}

// Read-modify-write a session's running total through the pool (gen-checked).
fn accumulate(r: PoolRef<Session>, amount: u32) -> bool {
    switch pool_load(Session, 16, &g_sessions, r) {
        ok(s) => {
            var ns: Session = s;
            ns.total = ns.total + amount;
            switch pool_set(Session, 16, &g_sessions, r, ns) {
                ok(b) => {
                    return true;
                }
                err(e) => {
                    return false;
                }
            }
        }
        err(e) => {
            return false;
        }
    }
}

// A realistic workload tying the new framework together: a session is opened in a
// generational pool; N requests are each processed on per-request arena scratch (reset
// between requests) and accumulated into the session; the total is verified exact;
// then the session is closed and its now-stale handle is confirmed rejected.
fn run_workload(heap: *mut Heap) -> bool {
    let region: PAddr = heap_alloc(heap, 1024, 16);
    var arena: Arena = arena_init(phys_range(region, 1024));
    pool_init(Session, 16, &g_sessions);
    var pass: bool = true;

    var s0: PoolRef<Session> = uninit;
    switch pool_alloc(Session, 16, &g_sessions) {
        ok(r) => {
            s0 = r;
        }
        err(e) => {
            pass = false;
        }
    }
    let init0: Session = .{ .id = 100, .total = 0, .active = true };
    switch pool_set(Session, 16, &g_sessions, s0, init0) {
        ok(b) => {}
        err(e) => {
            pass = false;
        }
    }

    var expected: u32 = 0;
    var i: usize = 0;
    while i < N_REQUESTS {
        let sum: u32 = process_request(&arena, (i as u32) * 7 + 1);
        expected = expected + sum;
        log_event(&g_log, .Info, 2, sum as u64);
        if !accumulate(s0, sum) {
            pass = false;
        }
        arena_reset(&arena); // per-request scratch reclaimed
        i = i + 1;
    }

    // the pooled session must hold exactly what we fed it across the loop
    switch pool_load(Session, 16, &g_sessions, s0) {
        ok(s) => {
            if s.total != expected {
                pass = false;
            }
        }
        err(e) => {
            pass = false;
        }
    }

    // close the session; the handle must now be rejected (use-after-free, fail closed)
    switch pool_free(Session, 16, &g_sessions, s0) {
        ok(b) => {}
        err(e) => {
            pass = false;
        }
    }
    switch pool_load(Session, 16, &g_sessions, s0) {
        ok(s) => {
            pass = false; // BUG if reached: stale handle resolved
        }
        err(e) => {}
    }

    arena_destroy(arena); // consume the linear arena
    return pass;
}

export fn kmain(region_base: usize, region_len: usize) -> u32 {
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

    // 3) Leveled logger.
    log_init(&g_log, .Info);
    log_event(&g_log, .Info, 1, region_len as u64);
    if log_count(&g_log) == 1 {
        stages = stages | 0x4;
        say(0x32); // '2'
    }

    // 4) VFS over ramfs.
    vfs_init(&g_vfs);
    if vfs_roundtrip() {
        stages = stages | 0x8;
        say(0x33); // '3'
    }

    // 5) Process scheduler: spawn two processes that print + exit.
    proc_table_init(&g_procs);
    install_idle(&g_procs); // wfi when nothing runnable
    proc_spawn(&g_procs, alloc_stack(&heap), worker_a);
    proc_spawn(&g_procs, alloc_stack(&heap), worker_b);
    proc_yield(&g_procs); // run them (they print A, B) and return here when both exit
    stages = stages | 0x10;
    say(0x34); // '4'

    // 6) Integrated workload: a session server over the generational pool with
    // per-request arena scratch (the new allocator framework, end to end).
    if run_workload(&heap) {
        stages = stages | 0x20;
        say(0x35); // '5'
    }

    return stages;
}
