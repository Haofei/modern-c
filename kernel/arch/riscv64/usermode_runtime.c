// Shared user-mode bring-up: the M-mode trap vector that routes `ecall` to the MC
// syscall table, the privilege drop into U-mode, and the kernel trap stack. Used by
// both the hand-written user task (user_runtime.c) and the ELF-loaded user program
// (elf_run_runtime.c). UART/mc_halt/_start come from context_runtime.c; the syscall
// table from the MC syscall demo.
#include <stdint.h>
#include <stddef.h>

// Freestanding mem* for bare-metal link: heap/Process struct growth made the
// backend emit memset/memcpy for large aggregate init/copy (e.g. heap_new,
// process_demo). Verbatim from kmain_runtime.c; memmove added for safety.
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
void *memmove(void *d, const void *s, size_t n) {
    uint8_t *dp = (uint8_t *)d; const uint8_t *sp = (const uint8_t *)s;
    if (dp < sp) { for (size_t i = 0; i < n; ++i) dp[i] = sp[i]; }
    else { for (size_t i = n; i > 0; --i) dp[i-1] = sp[i-1]; }
    return d;
}

#define ECALL_FROM_U 8ULL
#define ECALL_FROM_M 11ULL
#define SYS_EXIT 3ULL // handled here (returns control to the kernel)

void putc_(char c);
void puts_(const char *s);
void mc_halt(void);

void syscall_setup(void);
uint64_t mc_syscall(uint64_t number, uint64_t arg0, uint64_t arg1, uint64_t arg2);

// ---- UART RX interrupt: drain bytes into a ring so the shell can block (wfi) instead
// of busy-polling. Only active if the kernel enables the UART IRQ + PLIC (irq_setup);
// otherwise this code is never reached (e.g. the plain user-task test). ----
#define UART_RBR 0x10000000UL
#define UART_LSR 0x10000005UL
#define PLIC_CLAIM 0x0C200004UL // hart 0, M-mode context
#define UART_IRQ 10

#define RX_CAP 64
static volatile uint8_t rx_buf[RX_CAP];
static volatile uint32_t rx_head = 0, rx_tail = 0;

static void uart_rx_push(uint8_t ch) {
    uint32_t next = (rx_head + 1) % RX_CAP;
    if (next != rx_tail) { // drop on overflow
        rx_buf[rx_head] = ch;
        rx_head = next;
    }
}

// Pop one received byte, or 0x100 if the ring is empty (called from SYS_GETC).
uint64_t uart_rx_pop(void) {
    if (rx_head == rx_tail) return 0x100;
    uint8_t ch = rx_buf[rx_tail];
    rx_tail = (rx_tail + 1) % RX_CAP;
    return (uint64_t)ch;
}

typedef struct {
    uint64_t ra, t0, t1, t2, t3, t4, t5, t6;
    uint64_t a0, a1, a2, a3, a4, a5, a6, a7;
    uint64_t s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11;
} Frame;

// Dispatcher: an environment call from user (8) or machine (11) mode. SYS_EXIT ends
// the user program and reports which mode it came from (proving U-mode). Any other
// trap fails closed.
__attribute__((used)) void trap_entry(Frame *f) {
    uint64_t mcause;
    __asm__ volatile("csrr %0, mcause" : "=r"(mcause));
    // Interrupt (high bit set)? Service the UART RX IRQ and resume (mepc unchanged).
    if ((int64_t)mcause < 0) {
        if ((mcause & 0xff) == 11) { // machine external interrupt
            uint32_t irq = *(volatile uint32_t *)PLIC_CLAIM; // claim
            if (irq == UART_IRQ) {
                while (*(volatile uint8_t *)UART_LSR & 0x01) {
                    uart_rx_push(*(volatile uint8_t *)UART_RBR); // drain the FIFO
                }
                *(volatile uint32_t *)PLIC_CLAIM = irq; // complete
            }
        }
        return; // an interrupt resumes the interrupted instruction (no mepc bump)
    }
    if (mcause == ECALL_FROM_U || mcause == ECALL_FROM_M) {
        if (f->a7 == SYS_EXIT) {
            puts_("\nUSER-EXIT from ");
            putc_(mcause == ECALL_FROM_U ? 'U' : 'M');
            putc_('\n');
            mc_halt();
        }
        f->a0 = mc_syscall(f->a7, f->a0, f->a1, f->a2);
        uint64_t mepc;
        __asm__ volatile("csrr %0, mepc" : "=r"(mepc));
        __asm__ volatile("csrw mepc, %0" ::"r"(mepc + 4));
    } else {
        mc_halt();
    }
}

// Trap vector. `mscratch` holds the kernel stack top; swap to it on entry so a user
// trap runs on kernel — not user — memory, and swap back before mret.
__attribute__((naked, aligned(4))) void trap_vector(void) {
    __asm__ volatile(
        "csrrw sp, mscratch, sp\n"
        "addi sp, sp, -256\n"
        "sd ra,  0(sp)\n"  "sd t0,  8(sp)\n"  "sd t1, 16(sp)\n"  "sd t2, 24(sp)\n"
        "sd t3, 32(sp)\n"  "sd t4, 40(sp)\n"  "sd t5, 48(sp)\n"  "sd t6, 56(sp)\n"
        "sd a0, 64(sp)\n"  "sd a1, 72(sp)\n"  "sd a2, 80(sp)\n"  "sd a3, 88(sp)\n"
        "sd a4, 96(sp)\n"  "sd a5,104(sp)\n"  "sd a6,112(sp)\n"  "sd a7,120(sp)\n"
        "sd s0,128(sp)\n"  "sd s1,136(sp)\n"  "sd s2,144(sp)\n"  "sd s3,152(sp)\n"
        "sd s4,160(sp)\n"  "sd s5,168(sp)\n"  "sd s6,176(sp)\n"  "sd s7,184(sp)\n"
        "sd s8,192(sp)\n"  "sd s9,200(sp)\n"  "sd s10,208(sp)\n" "sd s11,216(sp)\n"
        "mv a0, sp\n"
        "call trap_entry\n"
        "ld ra,  0(sp)\n"  "ld t0,  8(sp)\n"  "ld t1, 16(sp)\n"  "ld t2, 24(sp)\n"
        "ld t3, 32(sp)\n"  "ld t4, 40(sp)\n"  "ld t5, 48(sp)\n"  "ld t6, 56(sp)\n"
        "ld a0, 64(sp)\n"  "ld a1, 72(sp)\n"  "ld a2, 80(sp)\n"  "ld a3, 88(sp)\n"
        "ld a4, 96(sp)\n"  "ld a5,104(sp)\n"  "ld a6,112(sp)\n"  "ld a7,120(sp)\n"
        "ld s0,128(sp)\n"  "ld s1,136(sp)\n"  "ld s2,144(sp)\n"  "ld s3,152(sp)\n"
        "ld s4,160(sp)\n"  "ld s5,168(sp)\n"  "ld s6,176(sp)\n"  "ld s7,184(sp)\n"
        "ld s8,192(sp)\n"  "ld s9,200(sp)\n"  "ld s10,208(sp)\n" "ld s11,216(sp)\n"
        "addi sp, sp, 256\n"
        "csrrw sp, mscratch, sp\n"
        "mret\n");
}

// A U-mode program makes a syscall through this (number a7, args a0/a1/a2, result
// a0).
uint64_t do_ecall(uint64_t number, uint64_t arg0, uint64_t arg1, uint64_t arg2) {
    register uint64_t a7 __asm__("a7") = number;
    register uint64_t a0 __asm__("a0") = arg0;
    register uint64_t a1 __asm__("a1") = arg1;
    register uint64_t a2 __asm__("a2") = arg2;
    __asm__ volatile("ecall" : "+r"(a0) : "r"(a7), "r"(a1), "r"(a2) : "memory");
    return a0;
}

// Drop to U-mode: set the return PC + user stack, clear MPP to 0 (U), and mret.
__attribute__((naked)) void enter_user(uintptr_t entry, uintptr_t user_sp) {
    __asm__ volatile(
        "csrw mepc, a0\n"
        "mv sp, a1\n"
        "li t0, 0x1800\n"    // MPP field (mstatus 12:11)
        "csrc mstatus, t0\n" // MPP <- 0 (U-mode)
        "mret\n");
}

__attribute__((aligned(16))) static uint8_t kernel_stack[8192];

// Install PMP (U-mode access to all memory), the trap vector, the kernel trap
// stack, and the syscall table. Call once before enter_user.
void usermode_setup(void) {
    __asm__ volatile("csrw pmpaddr0, %0" ::"r"(~(uintptr_t)0));
    __asm__ volatile("csrw pmpcfg0, %0" ::"r"((uintptr_t)0x1F)); // NAPOT | R|W|X
    __asm__ volatile("csrw mtvec, %0" ::"r"(&trap_vector));
    __asm__ volatile("csrw mscratch, %0" ::"r"((uintptr_t)(kernel_stack + sizeof(kernel_stack))));
    syscall_setup();
}
