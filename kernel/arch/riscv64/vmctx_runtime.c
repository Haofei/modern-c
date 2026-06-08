// Context switch that swaps the address space. mc_switch_context_vm saves the old
// thread's callee-saved registers, loads the new thread's satp (+ sfence.vma), then
// loads its registers — so changing threads changes the active page table. Two
// S-mode threads each read the same VA and see their own frame, proving satp is part
// of the switched context (what a real scheduler does with proc_satp).
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

void     vmctx_setup(uintptr_t region, uintptr_t len);
uint64_t vmctx_satp_a(void);
uint64_t vmctx_satp_b(void);
uint64_t vmctx_satp_kernel(void);

typedef struct {
    uint64_t ra, sp, s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11;
} Context;

// Save *old (a0), switch satp to a2 (+ sfence.vma), load *new (a1), ret into new's ra.
__attribute__((naked)) static void mc_switch_context_vm(Context *old, Context *next, uint64_t new_satp) {
    __asm__ volatile(
        "sd ra,  0(a0)\n" "sd sp,  8(a0)\n"
        "sd s0, 16(a0)\n" "sd s1, 24(a0)\n" "sd s2, 32(a0)\n" "sd s3, 40(a0)\n"
        "sd s4, 48(a0)\n" "sd s5, 56(a0)\n" "sd s6, 64(a0)\n" "sd s7, 72(a0)\n"
        "sd s8, 80(a0)\n" "sd s9, 88(a0)\n" "sd s10,96(a0)\n" "sd s11,104(a0)\n"
        "csrw satp, a2\n" "sfence.vma\n" // switch address space to the new thread's
        "ld ra,  0(a1)\n" "ld sp,  8(a1)\n"
        "ld s0, 16(a1)\n" "ld s1, 24(a1)\n" "ld s2, 32(a1)\n" "ld s3, 40(a1)\n"
        "ld s4, 48(a1)\n" "ld s5, 56(a1)\n" "ld s6, 64(a1)\n" "ld s7, 72(a1)\n"
        "ld s8, 80(a1)\n" "ld s9, 88(a1)\n" "ld s10,96(a1)\n" "ld s11,104(a1)\n"
        "ret\n");
}
__attribute__((naked)) static void trampoline(void) {
    __asm__ volatile("jr s0\n");
}
static void ctx_init(Context *ctx, uintptr_t stack_top, void (*entry)(void)) {
    uint64_t *s = (uint64_t *)ctx;
    for (int i = 0; i < 14; i++) s[i] = 0;
    ctx->ra = (uint64_t)(uintptr_t)&trampoline;
    ctx->s0 = (uint64_t)(uintptr_t)entry;
    ctx->sp = (uint64_t)stack_top;
}

#define TEST_VA 0xC0000000UL
static Context boot_ctx, a_ctx, b_ctx;
static uint64_t satp_a, satp_b, satp_kernel;
__attribute__((aligned(16))) static uint8_t stack_a[8192];
__attribute__((aligned(16))) static uint8_t stack_b[8192];

__attribute__((used)) static void thread_a(void) {
    uint32_t v = *(volatile uint32_t *)TEST_VA; // resolves in A's address space
    puts_("A sees "); puthex(v); putc_('\n');
    mc_switch_context_vm(&a_ctx, &b_ctx, satp_b); // hand off to B (its address space)
}
__attribute__((used)) static void thread_b(void) {
    uint32_t v = *(volatile uint32_t *)TEST_VA; // resolves in B's address space
    puts_("B sees "); puthex(v); putc_('\n');
    mc_switch_context_vm(&b_ctx, &boot_ctx, satp_kernel); // back to the bootstrap
}

__attribute__((used)) void s_main(void) {
    satp_kernel = vmctx_satp_kernel();
    satp_a = vmctx_satp_a();
    satp_b = vmctx_satp_b();
    __asm__ volatile("csrw satp, %0\n sfence.vma\n" ::"r"(satp_kernel) : "memory");

    ctx_init(&a_ctx, (uintptr_t)(stack_a + sizeof(stack_a)), thread_a);
    ctx_init(&b_ctx, (uintptr_t)(stack_b + sizeof(stack_b)), thread_b);

    puts_("bootstrap -> A\n");
    mc_switch_context_vm(&boot_ctx, &a_ctx, satp_a); // A runs, hands to B, B returns here
    puts_("VMCTX-OK\n");
    *FINISHER = 0x5555;
    for (;;) {}
}

__attribute__((aligned(4096))) static uint8_t heap_region[256 * 1024];

__attribute__((used)) void m_main(void) {
    puts_("vmctx booting (M-mode)\n");
    vmctx_setup((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region));
    puts_("thread address spaces built, dropping to S-mode\n");
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
