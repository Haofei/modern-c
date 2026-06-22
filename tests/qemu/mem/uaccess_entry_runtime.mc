// Bare-metal riscv64 M-mode runtime for the uaccess demos (page-table, snapshot,
// taint, elf-loader) — in PURE MC (no C). The all-MC replacement for
// kernel/arch/riscv64/uaccess_entry_runtime.c.
//
// All these demos exercise kernel/core/uaccess.mc, which imports the riscv paging
// module (paging.mc) — whose sfence_vma_page emits the `sfence.vma` instruction. That
// instruction is not assemblable for the host target, so these fixtures cannot run on
// the host driver suite; they boot under QEMU on the real riscv target. Each demo is
// an entry-mode fixture: a `u32 <entry>(void)` returning 1 iff every case passed.
//
// The C runtime selected the fixture entry at compile time via -DMC_ENTRY=<fn>; MC has
// no compile-time defines, so instead a tiny generated shim unit (built per gate in
// the harness) DEFINES `rt_uaccess_entry` as a call to that fixture's entry, and this
// runtime calls the fixed-name `rt_uaccess_entry`. We run it in M-mode and report the
// boolean verdict over UART: UACCESS-OK (1) / UACCESS-BAD (0) / UACCESS-TRAP (fault).
//
// The fixtures define console_putc (via their imports), so this runtime writes the
// bare 16550 UART directly for its markers.

import "tests/qemu/lib/test_report.mc";
const RT_FINISHER: usize = 0x0010_0000; // SiFive test finisher
const RT_FINISHER_HALT: u32 = 0x5555;

fn halt() -> void {
    unsafe { raw.store<u32>(phys(RT_FINISHER), RT_FINISHER_HALT); }
    while true {}
}

// The selected fixture entry, DEFINED by the generated per-gate shim unit (which
// declares the concrete `<entry>` as `extern fn` and forwards to it). Runs every
// case, returns 1 iff all pass.
extern fn rt_uaccess_entry() -> u32;

// Any trap arriving here is an MC safety check lowering to __builtin_trap() (an
// illegal instruction) — i.e. the demo hit an unexpected fault. Report it as failure.
export fn on_trap() -> void {
    uputs("UACCESS-TRAP\n");
    halt();
}

// Naked M-mode trap vector. Pinned to .text.mtrap so virt.ld aligns it to a 4-byte
// boundary (mtvec Direct mode needs base[1:0]=0).
#[naked]
#[section(".text.mtrap")]
export fn trap_vector() -> void {
    asm opaque volatile {
        "call on_trap"
    }
}

export fn m_main() -> void {
    unsafe {
        asm opaque volatile {
            "la t0, trap_vector\n csrw mtvec, t0"
            clobber("t0"), clobber("memory")
        }
    }
    uputs("uaccess demo booting (M-mode)\n");
    let r: u32 = rt_uaccess_entry();
    if r == 1 {
        uputs("UACCESS-OK\n");
    } else {
        uputs("UACCESS-BAD\n");
    }
    halt();
}

// QEMU `-bios none` jumps to 0x80000000 in M-mode.
#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call m_main\n 1: j 1b"
    }
}
