// Per-process address-space runtime. M-mode builds three process page tables (MC
// vmspace_setup), delegates + opens PMP, drops to S-mode; there it "context-switches"
// between the three processes by loading each one's satp (proc_satp) and reads the
// shared test VA — each process sees its own value, proving each Process has an
// independent address space switched on the (would-be) context switch.
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

void     vmspace_setup(uintptr_t region, uintptr_t len);
uint64_t vmspace_satp(uintptr_t idx);

// Referenced by proc_spawn/yield/exit in the linked process.mc object but unused in
// this demo (which only uses proc_table_init/proc_set_satp/proc_satp). Stubbed so the
// object links; per-process context switching is covered by the process test.
void mc_thread_init(void *ctx, uintptr_t sp, void (*entry)(void)) { (void)ctx; (void)sp; (void)entry; }
void mc_switch_context(void *old, void *next) { (void)old; (void)next; }
void mc_switch_context_vm(void *old, void *next, uint64_t satp) { (void)old; (void)next; (void)satp; }

__attribute__((aligned(4096))) static uint8_t heap_region[256 * 1024];
#define TEST_VA 0xC0000000UL

__attribute__((used)) void s_main(void) {
    volatile uint32_t *test_va = (volatile uint32_t *)TEST_VA;
    uint32_t expect[3] = { 0xAAAA0000u, 0xBBBB0001u, 0xCCCC0002u };
    int ok = 1;
    for (int i = 0; i < 3; i++) {
        uint64_t satp = vmspace_satp((uintptr_t)i); // load process i's address space
        __asm__ volatile("csrw satp, %0\n sfence.vma\n" ::"r"(satp) : "memory");
        uint32_t v = *test_va; // same VA, per-process frame
        puts_("proc "); putc_((char)('0' + i)); puts_(" VA="); puthex(v); putc_('\n');
        if (v != expect[i]) ok = 0;
    }
    if (ok) puts_("VMSPACE-OK\n"); else puts_("VMSPACE-BAD\n");
    *FINISHER = 0x5555;
    for (;;) {}
}

__attribute__((used)) void m_main(void) {
    puts_("vmspace booting (M-mode)\n");
    vmspace_setup((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region));
    puts_("per-process page tables built, dropping to S-mode\n");
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
