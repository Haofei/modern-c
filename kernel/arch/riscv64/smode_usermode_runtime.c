// S-mode port of usermode_runtime.c — the trap vector + syscall dispatch + privilege
// drop used by the CONFINED QuickJS agent when the kernel runs in S-mode under REAL
// OpenSBI (not the M-mode `-bios none` path).
//
// This is usermode_runtime.c with the M->S CSR rename (mtvec->stvec, mscratch->sscratch,
// mepc->sepc, mcause->scause, mstatus.MPP->SPP, mret->sret) and the bare-metal UART
// replaced by the SBI console (OpenSBI owns the UART in M-mode; S-mode reaches it via
// the legacy SBI putchar ecall). The SAME MC syscall table the M-mode path uses
// (syscall_setup / mc_syscall in app_run_demo.mc) is reused verbatim — only the
// privilege-mode asm/CSRs change. No PMP (OpenSBI configures it).
#include <stdint.h>
#include <stddef.h>

#define ECALL_FROM_U 8ULL
#define SYS_EXIT 3ULL // handled here (returns control to the kernel)

#define SCAUSE_INSTR_PAGE_FAULT 12ULL
#define SCAUSE_LOAD_PAGE_FAULT  13ULL
#define SCAUSE_STORE_PAGE_FAULT 15ULL

// ---- SBI console + power (legacy SBI: putchar EID=1, shutdown EID=8) ----
static void sbi_putchar(char c) {
    register long a0 __asm__("a0") = (unsigned char)c;
    register long a7 __asm__("a7") = 1;
    __asm__ volatile("ecall" : "+r"(a0) : "r"(a7) : "memory");
}
static void sbi_puts(const char *s) { for (; *s; ++s) sbi_putchar(*s); }
static void sbi_puthex(uint64_t v) {
    sbi_puts("0x");
    for (int i = 60; i >= 0; i -= 4) sbi_putchar("0123456789abcdef"[(v >> i) & 0xf]);
}
static void sbi_shutdown(void) {
    register long a7 __asm__("a7") = 8;
    __asm__ volatile("ecall" : : "r"(a7) : "memory");
    for (;;) {}
}

// The MC syscall table (app_run_demo.mc) — identical to the M-mode path. syscall_setup
// registers SYS_WRITE/SYS_READ/SYS_GETPID/SYS_SUBMIT/SYS_POLL; mc_syscall dispatches.
void syscall_setup(void);
uint64_t mc_syscall(uint64_t number, uint64_t arg0, uint64_t arg1, uint64_t arg2);

typedef struct {
    uint64_t ra, t0, t1, t2, t3, t4, t5, t6;
    uint64_t a0, a1, a2, a3, a4, a5, a6, a7;
    uint64_t s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11;
} Frame;

// Dispatcher: an environment call from user mode (scause==8). SYS_EXIT ends the agent and
// reports the mode it came from (proving U-mode). Everything else goes through the SAME MC
// syscall table the M-mode path uses. A page fault is contained (the kernel survives to
// report it and shut down — copy_*_user_pt validates user pointers, so a hostile pointer
// returns -E_FAULT and never faults here); any other trap fails closed.
__attribute__((used)) void s_trap_entry(Frame *f) {
    uint64_t scause, sepc, stval;
    __asm__ volatile("csrr %0, scause" : "=r"(scause));
    __asm__ volatile("csrr %0, sepc"   : "=r"(sepc));
    __asm__ volatile("csrr %0, stval"  : "=r"(stval));

    if (scause == ECALL_FROM_U) {
        if (f->a7 == SYS_EXIT) {
            sbi_puts("\nUSER-EXIT from U\n");
            sbi_shutdown();
        }
        f->a0 = mc_syscall(f->a7, f->a0, f->a1, f->a2);
        // advance past the ecall so we do not re-execute it
        __asm__ volatile("csrw sepc, %0" :: "r"(sepc + 4));
        return;
    }

    if (scause == SCAUSE_INSTR_PAGE_FAULT || scause == SCAUSE_LOAD_PAGE_FAULT || scause == SCAUSE_STORE_PAGE_FAULT) {
        sbi_puts("UNEXPECTED-TRAP scause="); sbi_puthex(scause);
        sbi_puts(" stval="); sbi_puthex(stval); sbi_putchar('\n');
        sbi_shutdown();
    }
    sbi_puts("UNEXPECTED-TRAP scause="); sbi_puthex(scause); sbi_putchar('\n');
    sbi_shutdown();
}

// S-mode trap vector: swap to the kernel stack via sscratch, save a full integer frame,
// dispatch, restore, sret. (Port of usermode_runtime.c's trap_vector — mscratch->sscratch,
// mret->sret.)
//
// LIMITATION (U-mode-trap only): the `csrrw sp, sscratch, sp` below UNCONDITIONALLY swaps to
// the kernel stack, which is correct ONLY for traps taken from U-mode (sstatus.SPP=0) — the
// current polled syscall/fault path. It does NOT handle a trap taken while already in S-mode
// (SPP=1): a nested kernel fault or an asynchronous interrupt arriving in kernel context would
// swap sp the wrong way and corrupt the kernel stack. Before enabling real timer/PLIC
// interrupts this must branch on SPP (swap only when SPP==0) and keep a separate nested-trap
// stack — tracked in docs/platform-portability-plan.md §12 (S-mode PLIC interrupt integration).
__attribute__((naked, aligned(4))) void s_trap_vector(void) {
    __asm__ volatile(
        "csrrw sp, sscratch, sp\n"
        "addi sp, sp, -256\n"
        "sd ra,  0(sp)\n"  "sd t0,  8(sp)\n"  "sd t1, 16(sp)\n"  "sd t2, 24(sp)\n"
        "sd t3, 32(sp)\n"  "sd t4, 40(sp)\n"  "sd t5, 48(sp)\n"  "sd t6, 56(sp)\n"
        "sd a0, 64(sp)\n"  "sd a1, 72(sp)\n"  "sd a2, 80(sp)\n"  "sd a3, 88(sp)\n"
        "sd a4, 96(sp)\n"  "sd a5,104(sp)\n"  "sd a6,112(sp)\n"  "sd a7,120(sp)\n"
        "sd s0,128(sp)\n"  "sd s1,136(sp)\n"  "sd s2,144(sp)\n"  "sd s3,152(sp)\n"
        "sd s4,160(sp)\n"  "sd s5,168(sp)\n"  "sd s6,176(sp)\n"  "sd s7,184(sp)\n"
        "sd s8,192(sp)\n"  "sd s9,200(sp)\n"  "sd s10,208(sp)\n" "sd s11,216(sp)\n"
        "mv a0, sp\n"
        "call s_trap_entry\n"
        "ld ra,  0(sp)\n"  "ld t0,  8(sp)\n"  "ld t1, 16(sp)\n"  "ld t2, 24(sp)\n"
        "ld t3, 32(sp)\n"  "ld t4, 40(sp)\n"  "ld t5, 48(sp)\n"  "ld t6, 56(sp)\n"
        "ld a0, 64(sp)\n"  "ld a1, 72(sp)\n"  "ld a2, 80(sp)\n"  "ld a3, 88(sp)\n"
        "ld a4, 96(sp)\n"  "ld a5,104(sp)\n"  "ld a6,112(sp)\n"  "ld a7,120(sp)\n"
        "ld s0,128(sp)\n"  "ld s1,136(sp)\n"  "ld s2,144(sp)\n"  "ld s3,152(sp)\n"
        "ld s4,160(sp)\n"  "ld s5,168(sp)\n"  "ld s6,176(sp)\n"  "ld s7,184(sp)\n"
        "ld s8,192(sp)\n"  "ld s9,200(sp)\n"  "ld s10,208(sp)\n" "ld s11,216(sp)\n"
        "addi sp, sp, 256\n"
        "csrrw sp, sscratch, sp\n"
        "sret\n");
}

// Drop to U-mode (S-mode port of enter_user): set sepc + user sp, clear sstatus.SPP (mask
// 0x100, =0 for U), enable the FPU (sstatus.FS = Initial 0x2000) — QuickJS computes on
// doubles (JS numbers are doubles), so the F/D unit must be on. The kernel is built
// integer-only and never touches FP registers, so the agent's FP state survives across
// syscalls with no save/restore. sret.
__attribute__((naked)) void enter_user(uintptr_t entry, uintptr_t user_sp) {
    __asm__ volatile(
        "csrw sepc, a0\n"
        "mv sp, a1\n"
        "li t0, 0x100\n"     // SPP (sstatus bit 8)
        "csrc sstatus, t0\n" // SPP <- 0 (U-mode)
        "li t1, 0x2000\n"    // FS field = Initial (sstatus 14:13 = 01): enable the FPU
        "csrs sstatus, t1\n"
        "sret\n");
}

__attribute__((aligned(16))) static uint8_t kernel_stack[8192];

// Install the S-mode trap vector + the kernel trap stack, and register the syscall table.
// Call once before enter_user. No PMP — OpenSBI configures it for S-mode.
void usermode_setup(void) {
    __asm__ volatile("csrw stvec, %0" ::"r"(&s_trap_vector));
    __asm__ volatile("csrw sscratch, %0" ::"r"((uintptr_t)(kernel_stack + sizeof(kernel_stack))));
    syscall_setup();
}
