// COW runtime: M-mode builds two address spaces sharing a read-only frame (MC cow_setup),
// drops to S-mode with a page-fault vector. A store in the parent space faults (the page
// is RO+shared); the handler copies the frame and remaps it writable for the parent, then
// the store retries. The child space, read afterward, still sees the original — copy-on-
// write divergence.
#include <stdint.h>
#include <stddef.h>
#define UART ((volatile uint8_t *)0x10000000UL)
#define FINISHER ((volatile uint32_t *)0x00100000UL)
static void putc_(char c) { *UART=(uint8_t)c; }
static void puts_(const char *s) { for (; *s; ++s) putc_(*s); }
static void puthex(uint32_t v) { putc_('0'); putc_('x'); for (int i=28;i>=0;i-=4) putc_("0123456789abcdef"[(v>>i)&0xf]); }

void cow_setup(uintptr_t region, uintptr_t len);
uint64_t cow_satp_parent(void);
uint64_t cow_satp_child(void);
void cow_handle_fault(uintptr_t fault_va);

__attribute__((aligned(4096))) static uint8_t heap_region[256 * 1024];
static uint64_t g_parent_satp, g_child_satp;
#define COW_VA 0xE0000000UL

__attribute__((used)) void s_trap_handler(uint64_t scause, uint64_t stval) {
    if (scause == 12 || scause == 13 || scause == 15) {
        cow_handle_fault((uintptr_t)stval);
        __asm__ volatile("sfence.vma" ::: "memory");
    } else {
        puts_("UNEXPECTED-TRAP\n"); *FINISHER = 0x5555; for (;;) {}
    }
}

__attribute__((naked, aligned(4))) void s_trap(void) {
    __asm__ volatile(
        "addi sp, sp, -128\n"
        "sd ra,0(sp)\n sd t0,8(sp)\n sd t1,16(sp)\n sd t2,24(sp)\n sd t3,32(sp)\n sd t4,40(sp)\n sd t5,48(sp)\n sd t6,56(sp)\n"
        "sd a0,64(sp)\n sd a1,72(sp)\n sd a2,80(sp)\n sd a3,88(sp)\n sd a4,96(sp)\n sd a5,104(sp)\n sd a6,112(sp)\n sd a7,120(sp)\n"
        "csrr a0, scause\n csrr a1, stval\n"
        "call s_trap_handler\n"
        "ld ra,0(sp)\n ld t0,8(sp)\n ld t1,16(sp)\n ld t2,24(sp)\n ld t3,32(sp)\n ld t4,40(sp)\n ld t5,48(sp)\n ld t6,56(sp)\n"
        "ld a0,64(sp)\n ld a1,72(sp)\n ld a2,80(sp)\n ld a3,88(sp)\n ld a4,96(sp)\n ld a5,104(sp)\n ld a6,112(sp)\n ld a7,120(sp)\n"
        "addi sp, sp, 128\n sret\n");
}

__attribute__((used)) void s_main(void) {
    __asm__ volatile("csrw stvec, %0\n" ::"r"(&s_trap) : "memory");
    volatile uint32_t *p = (volatile uint32_t *)COW_VA;
    // parent space: the write faults (RO+shared) -> COW -> private writable copy
    __asm__ volatile("csrw satp, %0\n sfence.vma\n" ::"r"(g_parent_satp) : "memory");
    *p = 0x22222222u;
    uint32_t pv = *p;
    // child space: must still observe the original shared value
    __asm__ volatile("csrw satp, %0\n sfence.vma\n" ::"r"(g_child_satp) : "memory");
    uint32_t cv = *p;
    puts_("COW parent="); puthex(pv); puts_(" child="); puthex(cv); putc_('\n');
    if (pv == 0x22222222u && cv == 0x11111111u) puts_("COW-OK\n");
    else puts_("COW-BAD\n");
    *FINISHER = 0x5555;
    for (;;) {}
}

__attribute__((used)) void m_main(void) {
    puts_("cow booting (M-mode)\n");
    cow_setup((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region));
    g_parent_satp = cow_satp_parent();
    g_child_satp = cow_satp_child();
    puts_("cow: two spaces sharing a RO frame, dropping to S-mode\n");
    __asm__ volatile(
        "li t0, 0xffff\n csrw medeleg, t0\n csrw mideleg, t0\n"
        "li t0, -1\n csrw pmpaddr0, t0\n li t0, 0x1f\n csrw pmpcfg0, t0\n"
        "li t0, 0x1800\n csrc mstatus, t0\n li t0, 0x800\n csrs mstatus, t0\n"
        "csrw mepc, %0\n mret\n" ::"r"(&s_main) : "t0", "memory");
    for (;;) {}
}

__attribute__((naked, section(".text.start"))) void _start(void) {
    __asm__ volatile("la sp, _stack_top\n call m_main\n 1: j 1b\n");
}
