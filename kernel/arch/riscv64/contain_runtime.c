// MMU crash containment: a buggy "server" dereferences an unmapped address. Instead of
// mapping it (demand paging) or panicking, the S-mode fault handler CONTAINS the fault —
// it redirects past the offending task to a recovery path (the equivalent of killing the
// faulting server), and the system keeps running. Reuses demand.mc's address space.
#include <stdint.h>
#include <stddef.h>
#define UART ((volatile uint8_t *)0x10000000UL)
#define FINISHER ((volatile uint32_t *)0x00100000UL)
static void putc_(char c){ *UART=(uint8_t)c; }
static void puts_(const char *s){ for(;*s;++s) putc_(*s); }

uint64_t dp_setup(uintptr_t region, uintptr_t len); // build AS (kernel mapped; region unmapped)
void dp_handle_fault(uintptr_t fault_va);            // unused here (we contain, not map)

__attribute__((aligned(4096))) static uint8_t heap_region[256 * 1024];
static uint64_t g_satp;
static volatile uint32_t g_contained = 0;
#define BAD_VA 0xD0000000UL

void recovery(void);

__attribute__((used)) void s_trap_handler(uint64_t scause, uint64_t stval) {
    if (scause == 12 || scause == 13 || scause == 15) {
        g_contained = 1;
        (void)stval;
        // contain: redirect past the faulting instruction to recovery (kill the server)
        __asm__ volatile("csrw sepc, %0" ::"r"(&recovery) : "memory");
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

// The recovery path the handler redirects to: the faulting server is gone; carry on.
__attribute__((used)) void recovery(void) {
    if (g_contained == 1) puts_("CONTAINED-OK\n");
    else puts_("CONTAIN-BAD\n");
    *FINISHER = 0x5555;
    for (;;) {}
}

__attribute__((used)) void buggy_server(void) {
    volatile uint32_t *p = (volatile uint32_t *)BAD_VA;
    *p = 0xDEAD; // unmapped -> fault -> contained
    puts_("CONTAIN-BAD\n"); // must not reach here
    *FINISHER = 0x5555; for (;;) {}
}

__attribute__((used)) void s_main(void) {
    __asm__ volatile("csrw stvec, %0\n" ::"r"(&s_trap) : "memory");
    __asm__ volatile("csrw satp, %0\n sfence.vma\n" ::"r"(g_satp) : "memory");
    buggy_server();
    for (;;) {}
}

__attribute__((used)) void m_main(void) {
    puts_("contain booting (M-mode)\n");
    g_satp = dp_setup((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region));
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
