// Bare-metal riscv64 M-mode anonymous-mmap runtime — in PURE MC (no C). The M-mode
// boot seam (`-bios none` jumps to 0x80000000 in M-mode) builds the Sv39 table with
// the SAME existing MC `mmap_demo` (kernel/core/mmap via tests/qemu/mem/mmap_demo.mc),
// delegates traps + opens PMP for S-mode, then `mret`s into S-mode. There S-mode
// loads satp + sfence.vma to turn paging on and writes+reads both anonymous pages,
// proving they are independent demand-allocated RAM (distinct values round-trip).
//
// This replaces the old C runtime (mmap_runtime.c): the C boot seam, the bare-UART
// console, and the M-mode privilege-drop asm are all pure MC now; the real work is
// the unchanged MC mmap module.

import "tests/qemu/mem/mmap_demo.mc";   // export fn mmap_demo(region, len) -> satp
import "tests/qemu/mem/mmode_sdrop.mc"; // M->S privilege drop + satp activation
import "kernel/core/mmio_console.mc";   // put_str over the bare 16550 UART
import "kernel/core/console.mc";

const RT_FINISHER: usize = 0x0010_0000;
const RT_FINISHER_HALT: u32 = 0x5555;
const RT_VA1: usize = 0xC000_0000; // first anonymous page (3 GiB)
const RT_VA2: usize = 0xC000_1000; // second anonymous page

// 256 KiB page-pool the MC paging code carves frames from. The MC heap allocator
// page-aligns every frame it hands out (heap_alloc(..., PAGE, PAGE)), so the pool
// itself needs no special alignment — the Sv39 root + every frame land on 4 KiB.
global g_heap_region: [262144]u8;
global g_satp: u64;

// S-mode entry: turn paging on (satp + sfence.vma), then exercise the two mmap'd
// anonymous pages. Reached via `mret` from m_main — runs in S-mode.
export fn s_main() -> void {
    activate_satp(g_satp);
    var p1: u32 = 0;
    var p2: u32 = 0;
    unsafe {
        raw.store<u32>(phys(RT_VA1), 0xAAAA_1111);
        raw.store<u32>(phys(RT_VA2), 0xBBBB_2222);
        p1 = raw.load<u32>(phys(RT_VA1));
        p2 = raw.load<u32>(phys(RT_VA2));
    }
    put_str("MMAP p1=");
    put_hex(p1 as u64);
    put_str(" p2=");
    put_hex(p2 as u64);
    console_putc(10);
    if p1 == 0xAAAA_1111 && p2 == 0xBBBB_2222 {
        put_str("MMAP-OK\n");
    } else {
        put_str("MMAP-BAD\n");
    }
    unsafe { raw.store<u32>(phys(RT_FINISHER), RT_FINISHER_HALT); }
    while true {}
}

// M-mode boot: build the table (MC), then drop to S-mode with paging on. The privilege
// drop delegates all traps to S-mode (medeleg/mideleg), opens a full-memory PMP window
// so S/U may touch physical RAM, sets mstatus.MPP=S, points mepc at s_main, and `mret`s.
export fn m_main() -> void {
    put_str("mmap booting (M-mode)\n");
    g_satp = mmap_demo((&g_heap_region) as usize, 262144);
    put_str("mmap: table built, dropping to S-mode\n");
    drop_to_smode((&s_main) as usize);
}

// QEMU `-bios none` jumps to 0x80000000 in M-mode; `.text.start` pins `_start` there.
#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call m_main\n 1: j 1b"
    }
}
