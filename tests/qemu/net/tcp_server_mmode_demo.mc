// Bare-metal riscv64 M-mode (`-bios none`) IPC-completeness demo entry — in PURE MC.
// The all-MC replacement for kernel/arch/riscv64/tcp_server_runtime.c. Drives the
// EXISTING MC path tcp_server_run (tests/qemu/net/tcp_server_demo.mc — multi-slot IPC +
// source filter + notify over green threads). The green-thread context switch itself
// still lives in the shared context_runtime.c (C), linked alongside; this is only the
// boot seam (console + a page-aligned heap region + entry).
//
// Console/halt use local names (uputc/uputs/halt) so they do NOT collide with the
// putc_/puts_/mc_halt that context_runtime.c still exports for its own use. The heap is
// over-allocated and the base rounded up to a page (MC has no compile-time global-align
// attribute; same idiom as agent_confined_runtime.mc).

import "tests/qemu/net/tcp_server_demo.mc"; // tcp_server_run

const UART_THR: usize = 0x1000_0000;
const FINISHER: usize = 0x0010_0000;
const FINISHER_HALT: u32 = 0x5555;
const RT_PAGE: usize = 4096;
const HEAP_LEN: usize = 256 * 1024;

// Over-allocate by a page so the usable base can be rounded up to a 4 KiB boundary.
global g_heap: [262144 + 4096]u8;

fn uputc(c: u8) -> void {
    unsafe { raw.store<u8>(phys(UART_THR), c); }
}
fn uputs(s: *const u8) -> void {
    let base: usize = s as usize;
    var i: usize = 0;
    while true {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(base + i)); }
        if b == 0 { break; }
        uputc(b);
        i = i + 1;
    }
}
fn halt() -> void {
    unsafe { raw.store<u32>(phys(FINISHER), FINISHER_HALT); }
    while true {}
}
fn page_align(base: usize) -> usize {
    return (base + (RT_PAGE - 1)) & ~(RT_PAGE - 1);
}

export fn test_main() -> void {
    uputs("tcp-server booting\n");
    let region: usize = page_align((&g_heap[0]) as usize);
    let rc: u32 = tcp_server_run(region, HEAP_LEN);
    if rc == 1 { uputs("TCPSRV-OK\n"); } else { uputs("TCPSRV-FAIL\n"); }
    halt();
}

// NB: no `_start` here — context_runtime.c (linked alongside) provides the naked
// `.text.start` entry that sets the stack and `call`s this test_main.
