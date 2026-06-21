// Bare-metal riscv64 M-mode address-space-switch runtime — in PURE MC (no C). The
// M-mode boot seam (`-bios none`) builds two Sv39 tables with the SAME existing MC
// `build_spaces` (kernel/arch/riscv64/paging via the demo), delegates traps + opens
// PMP, drops to S-mode; there it activates the first satp and reads the shared test VA,
// then switches satp to the second and reads it again. The same virtual address yields
// different values — proving each address space is independent (the basis of per-process
// memory).
//
// Replaces paging_switch_runtime.c: boot seam, bare-UART console, and the M->S privilege
// drop are all pure MC now; the real work is the unchanged MC paging module.

import "tests/qemu/mem/paging_switch_demo.mc"; // build_spaces / satp1 / satp2; TEST_VA
import "tests/qemu/mem/mmode_sdrop.mc";        // M->S privilege drop + satp activation
import "kernel/core/mmio_console.mc";          // put_str over the bare 16550 UART
import "kernel/core/console.mc";

const RT_FINISHER: usize = 0x0010_0000;
const RT_FINISHER_HALT: u32 = 0x5555;

global g_heap_region: [262144]u8;
global g_s1: u64;
global g_s2: u64;

// S-mode entry (reached via `mret`): read the shared VA under each address space.
export fn s_main() -> void {
    activate_satp(g_s1);
    var v1: u32 = 0;
    unsafe { v1 = raw.load<u32>(phys(TEST_VA)); } // address space 1
    activate_satp(g_s2);
    var v2: u32 = 0;
    unsafe { v2 = raw.load<u32>(phys(TEST_VA)); } // address space 2 — same VA, different frame
    put_str("VMSWITCH ");
    put_hex(v1 as u64);
    console_putc(32); // ' '
    put_hex(v2 as u64);
    console_putc(10);
    if v1 == 0x1111_1111 && v2 == 0x2222_2222 && v1 != v2 {
        put_str("VMSWITCH-OK\n");
    } else {
        put_str("VMSWITCH-BAD\n");
    }
    unsafe { raw.store<u32>(phys(RT_FINISHER), RT_FINISHER_HALT); }
    while true {}
}

// M-mode boot: build two address spaces (MC), then drop to S-mode with paging on.
export fn m_main() -> void {
    put_str("vm-switch booting (M-mode)\n");
    build_spaces((&g_heap_region) as usize, 262144);
    g_s1 = satp1();
    g_s2 = satp2();
    put_str("two address spaces built, dropping to S-mode\n");
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
