// Test entry + ecall trap wiring for the syscall skeleton
// (tests/qemu/syscall_demo.mc). UART, mc_halt, and _start come from
// context_runtime.c. Here: the trap vector that routes `ecall` to the MC
// dispatcher, and `test_main` which issues a few ecalls and checks the results.
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

#define MCAUSE_M_ECALL 11ULL
#define SYS_ADD 1ULL
#define SYS_PUTC 2ULL

void putc_(char c);
void puts_(const char *s);
void mc_halt(void);

// MC entry points (tests/qemu/syscall_demo.mc).
void syscall_setup(void);
uint64_t mc_syscall(uint64_t number, uint64_t arg0, uint64_t arg1);

// The saved integer frame (matches the trap vector's layout below): ra, t0-t6,
// a0-a7, s0-s11. The syscall ABI lives in a0 (arg0/return), a1 (arg1), a7 (number).
typedef struct {
    uint64_t ra, t0, t1, t2, t3, t4, t5, t6;
    uint64_t a0, a1, a2, a3, a4, a5, a6, a7;
    uint64_t s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11;
} Frame;

// Dispatcher invoked by the trap vector. On an environment call, route it to the
// MC syscall dispatcher (number in a7, args in a0/a1, result back to a0) and step
// mepc past the 4-byte ecall so mret resumes after it. Anything else fails closed.
__attribute__((used)) void trap_entry(Frame *f) {
    uint64_t mcause;
    __asm__ volatile("csrr %0, mcause" : "=r"(mcause));
    if (mcause == MCAUSE_M_ECALL) {
        f->a0 = mc_syscall(f->a7, f->a0, f->a1);
        uint64_t mepc;
        __asm__ volatile("csrr %0, mepc" : "=r"(mepc));
        __asm__ volatile("csrw mepc, %0" ::"r"(mepc + 4));
    } else {
        mc_halt();
    }
}

// M-mode trap vector: save the integer frame, pass its address to trap_entry, then
// restore (a0 now holds the syscall result) and mret.
__attribute__((naked, aligned(4))) void trap_vector(void) {
    __asm__ volatile(
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
        "mret\n");
}

static uint64_t do_ecall(uint64_t number, uint64_t arg0, uint64_t arg1) {
    register uint64_t a7 __asm__("a7") = number;
    register uint64_t a0 __asm__("a0") = arg0;
    register uint64_t a1 __asm__("a1") = arg1;
    __asm__ volatile("ecall" : "+r"(a0) : "r"(a7), "r"(a1) : "memory");
    return a0;
}

__attribute__((used)) void test_main(void) {
    puts_("syscall booting\n");
    __asm__ volatile("csrw mtvec, %0" ::"r"(&trap_vector));
    syscall_setup();

    uint64_t sum = do_ecall(SYS_ADD, 3, 4);     // -> 7
    do_ecall(SYS_PUTC, (uint64_t)'X', 0);       // prints 'X'
    uint64_t bad = do_ecall(99, 0, 0);          // unregistered -> ENOSYS

    puts_("\nSYS-ADD=");
    putc_((char)('0' + (sum % 10)));
    puts_(" ENOSYS=");
    putc_(bad == (uint64_t)-1 ? 'Y' : 'N');
    puts_("\nSYSCALL-OK\n");
    mc_halt();
}
