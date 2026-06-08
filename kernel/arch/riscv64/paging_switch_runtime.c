// Per-process address-space switch runtime. M-mode builds two Sv39 tables (MC
// build_spaces), delegates + opens PMP, drops to S-mode; there it activates the
// first satp and reads the shared test VA, then switches satp to the second and
// reads it again. The same virtual address yields different values — proving each
// address space is independent (the basis of per-process memory).
#include <stdint.h>
#include <stddef.h>

void *memset(void *d, int c, size_t n) {
    uint8_t *p = (uint8_t *)d;
    for (size_t i = 0; i < n; ++i) p[i] = (uint8_t)c;
    return d;
}
void *memcpy(void *d, const void *s, size_t n) {
    uint8_t *dp = (uint8_t *)d; const uint8_t *sp = (const uint8_t *)s;
    for (size_t i = 0; i < n; ++i) dp[i] = sp[i];
    return d;
}

#define UART ((volatile uint8_t *)0x10000000UL)
#define FINISHER ((volatile uint32_t *)0x00100000UL)
static void putc_(char c) { *UART = (uint8_t)c; }
static void puts_(const char *s) { for (; *s; ++s) putc_(*s); }
static void puthex(uint32_t v) {
    putc_('0'); putc_('x');
    for (int i = 28; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 0xf]);
}

void     build_spaces(uintptr_t region, uintptr_t len);
uint64_t satp1(void);
uint64_t satp2(void);

__attribute__((aligned(4096))) static uint8_t heap_region[256 * 1024];
static uint64_t g_s1, g_s2;

#define TEST_VA 0xC0000000UL

__attribute__((used)) void s_main(void) {
    volatile uint32_t *test_va = (volatile uint32_t *)TEST_VA;
    __asm__ volatile("csrw satp, %0\n sfence.vma\n" ::"r"(g_s1) : "memory");
    uint32_t v1 = *test_va; // address space 1
    __asm__ volatile("csrw satp, %0\n sfence.vma\n" ::"r"(g_s2) : "memory");
    uint32_t v2 = *test_va; // address space 2 — same VA, different frame
    puts_("VMSWITCH "); puthex(v1); putc_(' '); puthex(v2); putc_('\n');
    if (v1 == 0x11111111u && v2 == 0x22222222u && v1 != v2) puts_("VMSWITCH-OK\n");
    else puts_("VMSWITCH-BAD\n");
    *FINISHER = 0x5555;
    for (;;) {}
}

__attribute__((used)) void m_main(void) {
    puts_("vm-switch booting (M-mode)\n");
    build_spaces((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region));
    g_s1 = satp1();
    g_s2 = satp2();
    puts_("two address spaces built, dropping to S-mode\n");
    __asm__ volatile(
        "li   t0, 0xffff\n"
        "csrw medeleg, t0\n"
        "csrw mideleg, t0\n"
        "li   t0, -1\n"
        "csrw pmpaddr0, t0\n"
        "li   t0, 0x1f\n"
        "csrw pmpcfg0, t0\n"
        "li   t0, 0x1800\n"
        "csrc mstatus, t0\n"
        "li   t0, 0x800\n"
        "csrs mstatus, t0\n"
        "csrw mepc, %0\n"
        "mret\n"
        ::"r"(&s_main) : "t0", "memory");
    for (;;) {}
}

__attribute__((naked, section(".text.start"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call m_main\n"
        "1: j 1b\n");
}
