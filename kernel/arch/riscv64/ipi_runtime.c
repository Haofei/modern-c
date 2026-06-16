// IPI runtime: two harts boot; hart 1 installs a machine-software-interrupt
// handler and arms MSIE, then waits. Hart 0 raises an IPI on hart 1 (via the MC
// CLINT helper), and hart 1 traps, clears + counts it. Hart 0 confirms delivery.
#include <stdint.h>
#include <stddef.h>

#define NHARTS 2
#define HSTACK 4096
#define MIE_MSIE (1u << 3)    // machine software interrupt enable (mie)
#define MSTATUS_MIE (1u << 3) // global machine interrupt enable (mstatus)
#define CAUSE_MSI 0x8000000000000003ULL // interrupt bit | machine software interrupt

#define UART ((volatile uint8_t *)0x10000000UL)
#define FINISHER ((volatile uint32_t *)0x00100000UL)

static void putc_(char c) { *UART = (uint8_t)c; }
static void puts_(const char *s) { for (; *s; ++s) putc_(*s); }

// MC entry points (tests/qemu/ipi_demo.mc).
void     ipi_send(uint32_t target);
void     ipi_clear(uint32_t hart);
uint32_t ipi_arrive(void);
uint32_t ipi_count(void);
void     hart1_set_ready(void);
uint32_t hart1_is_ready(void);

__attribute__((aligned(16), used)) uint8_t hart_stacks[NHARTS][HSTACK];

// Called from the trap vector with mcause. A delivered IPI is a machine software
// interrupt: deassert it (clear MSIP) then count it.
__attribute__((used)) void ipi_handler(uint64_t mcause) {
    if (mcause == CAUSE_MSI) {
        uint64_t h;
        __asm__ volatile("csrr %0, mhartid" : "=r"(h));
        ipi_clear((uint32_t)h);
        ipi_arrive();
    }
}

__attribute__((naked, aligned(4))) static void ipi_trap_vector(void) {
    __asm__ volatile(
        "addi sp, sp, -64\n"
        "sd ra, 0(sp)\n" "sd t0, 8(sp)\n" "sd t1, 16(sp)\n" "sd t2, 24(sp)\n"
        "sd a0, 32(sp)\n" "sd a1, 40(sp)\n" "sd a2, 48(sp)\n" "sd a3, 56(sp)\n"
        "csrr a0, mcause\n"
        "call ipi_handler\n"
        "ld ra, 0(sp)\n" "ld t0, 8(sp)\n" "ld t1, 16(sp)\n" "ld t2, 24(sp)\n"
        "ld a0, 32(sp)\n" "ld a1, 40(sp)\n" "ld a2, 48(sp)\n" "ld a3, 56(sp)\n"
        "addi sp, sp, 64\n"
        "mret\n");
}

__attribute__((used)) void hart_main(uint64_t hartid) {
    if (hartid == 1) {
        // Arm machine software interrupts and wait to be poked.
        __asm__ volatile("csrw mtvec, %0" ::"r"((uintptr_t)&ipi_trap_vector));
        __asm__ volatile("csrs mie, %0" ::"r"((uintptr_t)MIE_MSIE));
        __asm__ volatile("csrs mstatus, %0" ::"r"((uintptr_t)MSTATUS_MIE));
        hart1_set_ready();
        for (;;) { __asm__ volatile("wfi"); }
    }

    // Hart 0: wait until hart 1 is armed, send it an IPI, await delivery.
    while (!hart1_is_ready()) {}
    ipi_send(1);
    while (ipi_count() < 1) {}
    puts_("IPI-OK\n");
    *FINISHER = 0x5555;
    for (;;) { __asm__ volatile("wfi"); }
}

__attribute__((naked, section(".text.start"))) void _start(void) {
    __asm__ volatile(
        "csrr a0, mhartid\n"
        "la   t0, hart_stacks\n"
        "li   t1, 4096\n"
        "addi t2, a0, 1\n"
        "mul  t2, t2, t1\n"
        "add  sp, t0, t2\n"
        "call hart_main\n"
        "1: wfi\n"
        "j 1b\n");
}
