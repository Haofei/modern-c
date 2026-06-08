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
import "std/addr.mc";

const UART_BASE: u64 = 0x1000_0000;
const STACK_SIZE: usize = 8192;

global g_chardevs: CharRegistry;
global g_uart_id: usize;
global g_log: Logger;
global g_vfs: Vfs;
global g_procs: ProcTable;

fn uart_putc(ctx: u64, b: u8) -> void {
    unsafe {
        raw.store<u8>(phys(ctx as usize), b);
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
    g_uart_id = register_chardev(&g_chardevs, uart_putc, UART_BASE);
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
    proc_spawn(&g_procs, alloc_stack(&heap), worker_a);
    proc_spawn(&g_procs, alloc_stack(&heap), worker_b);
    proc_yield(&g_procs); // run them (they print A, B) and return here when both exit
    stages = stages | 0x10;
    say(0x34); // '4'

    return stages;
}
