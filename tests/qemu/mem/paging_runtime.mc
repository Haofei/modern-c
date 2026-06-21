// Bare-metal riscv64 M-mode Sv39 paging runtime — in PURE MC (no C). The M-mode boot
// seam (`-bios none` jumps to 0x80000000 in M-mode) builds the Sv39 table with the SAME
// existing MC `paging_activate` (kernel/arch/riscv64/paging via the demo), delegates
// traps + opens PMP for S-mode, then `mret`s into S-mode. There S-mode turns paging on
// (satp + sfence.vma) and reads the translation-only test VA (3 GiB) — a correct read
// proves real virtual->physical translation is live.
//
// Replaces paging_runtime.c: boot seam, bare-UART console, and the M->S privilege drop
// are all pure MC now; the real work is the unchanged MC paging module.

import "tests/qemu/mem/paging_activate_demo.mc"; // export fn paging_activate -> satp; TEST_VA/TEST_VALUE
import "tests/qemu/mem/mmode_sdrop.mc";          // M->S privilege drop + satp activation
import "kernel/core/mmio_console.mc";            // put_str over the bare 16550 UART
import "kernel/core/console.mc";

const RT_FINISHER: usize = 0x0010_0000;
const RT_FINISHER_HALT: u32 = 0x5555;

// 256 KiB page-pool the MC paging code carves frames from (heap_alloc page-aligns each).
global g_heap_region: [262144]u8;
global g_satp: u64;

// S-mode entry (reached via `mret`): turn paging on, then read the translation-only VA.
export fn s_main() -> void {
    activate_satp(g_satp);
    var v: u32 = 0;
    unsafe { v = raw.load<u32>(phys(TEST_VA)); } // 3 GiB -> test frame, via translation
    put_str("PAGING read ");
    put_hex(v as u64);
    console_putc(10);
    if v == TEST_VALUE {
        put_str("PAGING-OK\n");
    } else {
        put_str("PAGING-BAD\n");
    }
    unsafe { raw.store<u32>(phys(RT_FINISHER), RT_FINISHER_HALT); }
    while true {}
}

// M-mode boot: build the table (MC), then drop to S-mode with paging on.
export fn m_main() -> void {
    put_str("paging booting (M-mode)\n");
    g_satp = paging_activate((&g_heap_region) as usize, 262144);
    put_str("paging: table built, dropping to S-mode\n");
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
