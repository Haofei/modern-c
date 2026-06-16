// Demand-paging runtime. M-mode builds the address space (MC dp_setup) leaving a region
// unmapped, drops to S-mode with a page-fault trap vector, activates satp, and touches
// the unmapped region. The store faults; the S-mode handler calls dp_handle_fault to map
// a page; sret retries the faulting instruction transparently — demand paging is live.
#include <stdint.h>
#include <stddef.h>
#define UART ((volatile uint8_t *)0x10000000UL)
#define FINISHER ((volatile uint32_t *)0x00100000UL)
static void putc_(char c) { *UART = (uint8_t)c; }
static void puts_(const char *s) { for (; *s; ++s) putc_(*s); }
static void puthex(uint32_t v) { putc_('0'); putc_('x'); for (int i=28;i>=0;i-=4) putc_("0123456789abcdef"[(v>>i)&0xf]); }

uint64_t dp_setup(uintptr_t region, uintptr_t len);   // MC: build AS -> satp
void dp_handle_fault(uintptr_t fault_va);             // MC: map a page at the fault

__attribute__((aligned(4096))) static uint8_t heap_region[256 * 1024];
static uint64_t g_satp;
static volatile uint32_t g_faults = 0;

#define DEMAND_VA 0xD0000000UL

// C dispatch: on a page fault, map the page; otherwise halt.
__attribute__((used)) void s_trap_handler(uint64_t scause, uint64_t stval) {
    if (scause == 12 || scause == 13 || scause == 15) { // instr/load/store page fault
        g_faults++;
        dp_handle_fault((uintptr_t)stval);
        __asm__ volatile("sfence.vma" ::: "memory");
    } else {
        puts_("UNEXPECTED-TRAP\n");
        *FINISHER = 0x5555;
        for (;;) {}
    }
}

// S-mode trap entry: save caller-saved regs, dispatch, restore, sret (retry).
__attribute__((naked, aligned(4))) void s_trap(void) {
    __asm__ volatile(
        "addi sp, sp, -128\n"
        "sd ra,0(sp)\n sd t0,8(sp)\n sd t1,16(sp)\n sd t2,24(sp)\n sd t3,32(sp)\n sd t4,40(sp)\n sd t5,48(sp)\n sd t6,56(sp)\n"
        "sd a0,64(sp)\n sd a1,72(sp)\n sd a2,80(sp)\n sd a3,88(sp)\n sd a4,96(sp)\n sd a5,104(sp)\n sd a6,112(sp)\n sd a7,120(sp)\n"
        "csrr a0, scause\n csrr a1, stval\n"
        "call s_trap_handler\n"
        "ld ra,0(sp)\n ld t0,8(sp)\n ld t1,16(sp)\n ld t2,24(sp)\n ld t3,32(sp)\n ld t4,40(sp)\n ld t5,48(sp)\n ld t6,56(sp)\n"
        "ld a0,64(sp)\n ld a1,72(sp)\n ld a2,80(sp)\n ld a3,88(sp)\n ld a4,96(sp)\n ld a5,104(sp)\n ld a6,112(sp)\n ld a7,120(sp)\n"
        "addi sp, sp, 128\n"
        "sret\n");
}

__attribute__((used)) void s_main(void) {
    __asm__ volatile("csrw stvec, %0\n" ::"r"(&s_trap) : "memory");
    __asm__ volatile("csrw satp, %0\n sfence.vma\n" ::"r"(g_satp) : "memory");
    volatile uint32_t *p = (volatile uint32_t *)DEMAND_VA;
    *p = 0xD00D1234u;        // unmapped -> page fault -> handler maps -> retry -> stores
    uint32_t v = *p;          // now mapped
    puts_("DEMAND faults="); puthex(g_faults); puts_(" val="); puthex(v); putc_('\n');
    if (g_faults >= 1 && v == 0xD00D1234u) puts_("DEMAND-OK\n");
    else puts_("DEMAND-BAD\n");
    *FINISHER = 0x5555;
    for (;;) {}
}

__attribute__((used)) void m_main(void) {
    puts_("demand booting (M-mode)\n");
    g_satp = dp_setup((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region));
    puts_("demand: AS built, dropping to S-mode\n");
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
