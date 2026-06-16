// satp activation runtime. M-mode builds the Sv39 table (MC paging_activate),
// delegates traps + opens PMP for S-mode, then mrets into S-mode. There it loads
// satp + sfence.vma to turn on paging, and reads the test virtual address (3 GiB),
// which is reachable only through translation — proving virtual memory is live.
#include <stdint.h>
#include <stddef.h>

#define UART ((volatile uint8_t *)0x10000000UL)
#define FINISHER ((volatile uint32_t *)0x00100000UL)
static void putc_(char c) { *UART = (uint8_t)c; }
static void puts_(const char *s) { for (; *s; ++s) putc_(*s); }
static void puthex(uint32_t v) {
    putc_('0'); putc_('x');
    for (int i = 28; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 0xf]);
}

uint64_t paging_activate(uintptr_t region, uintptr_t len); // MC: build table -> satp

__attribute__((aligned(4096))) static uint8_t heap_region[256 * 1024];
static uint64_t g_satp;

#define TEST_VA 0xC0000000UL
#define TEST_VALUE 0xCAFEBABEu

// S-mode: turn on paging, then read the translation-only test address.
__attribute__((used)) void s_main(void) {
    __asm__ volatile("csrw satp, %0\n sfence.vma\n" ::"r"(g_satp) : "memory");
    uint32_t v = *(volatile uint32_t *)TEST_VA; // 3 GiB -> test frame, via translation
    puts_("PAGING read "); puthex(v); putc_('\n');
    if (v == TEST_VALUE) puts_("PAGING-OK\n");
    else puts_("PAGING-BAD\n");
    *FINISHER = 0x5555; // VA 0x00100000 -> PA (identity gigapage)
    for (;;) {}
}

__attribute__((used)) void m_main(void) {
    puts_("paging booting (M-mode)\n");
    g_satp = paging_activate((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region));
    puts_("paging: table built, dropping to S-mode\n");
    // Delegate traps to S-mode, open PMP so S/U may access all physical memory, set
    // mstatus.MPP = S, and mret to s_main.
    __asm__ volatile(
        "li   t0, 0xffff\n"
        "csrw medeleg, t0\n"
        "csrw mideleg, t0\n"
        "li   t0, -1\n"
        "csrw pmpaddr0, t0\n"
        "li   t0, 0x1f\n"        // NAPOT, R|W|X over all memory
        "csrw pmpcfg0, t0\n"
        "li   t0, 0x1800\n"      // mstatus.MPP mask (bits 12:11)
        "csrc mstatus, t0\n"
        "li   t0, 0x800\n"       // MPP = 01 (S-mode)
        "csrs mstatus, t0\n"
        "csrw mepc, %0\n"
        "mret\n"
        ::"r"(&s_main) : "t0", "memory");
    for (;;) {} // unreachable
}

__attribute__((naked, section(".text.start"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call m_main\n"
        "1: j 1b\n");
}
