// Bare-metal M-mode runtime for the uaccess demos (page-table, snapshot, taint).
//
// All three demos exercise kernel/core/uaccess.mc, which imports the riscv paging
// module (paging.mc) — whose sfence_vma_page emits the `sfence.vma` instruction. That
// instruction is not assemblable for the host target, so these fixtures cannot run on
// the host driver suite; they must boot under QEMU on the real riscv target. Each demo
// is an entry-mode fixture: a `u32 <entry>(void)` returning 1 iff every case passed.
//
// The entry symbol is injected at compile time via -DMC_ENTRY=<fn>, so one runtime
// serves every uaccess demo. We call it in M-mode and report the boolean verdict over
// UART: UACCESS-OK (1) / UACCESS-BAD (0) / UACCESS-TRAP (an unexpected fault).
#include <stdint.h>

#ifndef MC_ENTRY
#error "define MC_ENTRY to the MC entry symbol (e.g. -DMC_ENTRY=uaccess_pt_run)"
#endif

#define UART ((volatile uint8_t *)0x10000000UL)
#define FINISHER ((volatile uint32_t *)0x00100000UL)
static void putc_(char c) { *UART = (uint8_t)c; }
static void puts_(const char *s) { for (; *s; ++s) putc_(*s); }
static void halt(void) { *FINISHER = 0x5555; for (;;) {} }

// MC entry point: runs every case, returns 1 iff all pass.
uint32_t MC_ENTRY(void);

// Any trap here is an MC safety check lowering to __builtin_trap() (an illegal
// instruction) — i.e. the demo hit an unexpected fault. Report it as a failure.
__attribute__((used)) void on_trap(void) { puts_("UACCESS-TRAP\n"); halt(); }

__attribute__((naked, aligned(4))) void trap_vector(void) {
    __asm__ volatile("call on_trap\n");
}

__attribute__((used)) void m_main(void) {
    __asm__ volatile("csrw mtvec, %0\n" ::"r"((uintptr_t)&trap_vector) : "memory");
    puts_("uaccess demo booting (M-mode)\n");
    uint32_t ok = MC_ENTRY();
    puts_(ok == 1u ? "UACCESS-OK\n" : "UACCESS-BAD\n");
    halt();
}

__attribute__((naked, section(".text.start"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call m_main\n"
        "1: j 1b\n");
}
