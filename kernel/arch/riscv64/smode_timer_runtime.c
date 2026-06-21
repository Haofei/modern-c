// Item (4): REAL S-mode timer-interrupt delivery under OpenSBI — the RISC-V
// analogue of the x86 X4 LAPIC-timer proof.
//
// A flat S-mode kernel (booted by REAL OpenSBI at 0x80200000, satp=0 Bare mode)
// programs the SBI TIME extension to fire an S-mode timer interrupt, enables
// S-mode timer interrupts, and counts ticks in its trap handler — re-arming the
// timer each tick. It parks the hart in `wfi` between ticks, so a no-delivery
// bug HANGS into the QEMU timeout (it is NOT a busy poll that would mask a
// missing interrupt). After TARGET real interrupts have been delivered and
// serviced, it reports `SMODE-TIMER TICKS=<n>` + `SMODE-TIMER-OK` over the SBI
// console and shuts down.
//
// This is a STANDALONE runtime: it deliberately does NOT touch the shared
// confinement vector in smode_usermode_runtime.c. Because this kernel is pure
// S-mode (NO U-mode), every trap is taken with sstatus.SPP=1, so the trap
// vector does NOT swap sscratch — it just saves a full integer frame on the
// current kernel stack, dispatches, restores, and `sret`s.
#include <stdint.h>

// --- SBI seam (mirrors blk_smode_runtime.c) --------------------------------
static long sbi_ecall(long ext, long fid, long arg0, long arg1) {
    register long a0 __asm__("a0") = arg0;
    register long a1 __asm__("a1") = arg1;
    register long a6 __asm__("a6") = fid;
    register long a7 __asm__("a7") = ext;
    __asm__ volatile("ecall" : "+r"(a0) : "r"(a1), "r"(a6), "r"(a7) : "memory");
    return a0;
}
// Legacy SBI: console putchar = EID 1, shutdown = EID 8.
static void sbi_putchar(char c) { sbi_ecall(1, 0, (unsigned char)c, 0); }
static void sbi_puts(const char *s) { for (; *s; ++s) sbi_putchar(*s); }
static void sbi_shutdown(void) { sbi_ecall(8, 0, 0, 0); }

// SBI TIME extension: EID "TIME" = 0x54494D45, fid 0, arg0 = absolute stime to
// fire the next S-mode timer interrupt at. Setting a new deadline also clears
// the pending STIP, so re-arming inside the handler dismisses the interrupt.
#define SBI_EXT_TIME 0x54494D45L
static void sbi_set_timer(uint64_t stime) { sbi_ecall(SBI_EXT_TIME, 0, (long)stime, 0); }

// Architectural S-mode time source. Under OpenSBI the CLINT mtime MMIO is NOT
// mapped into S-mode (a direct load faults), so read the `time` CSR (rdtime),
// which OpenSBI keeps in sync with the 10 MHz QEMU virt mtimer.
static uint64_t rdtime(void) {
    uint64_t t;
    __asm__ volatile("rdtime %0" : "=r"(t));
    return t;
}

static void put_dec(uint64_t v) {
    char buf[20];
    int i = 0;
    if (v == 0) { sbi_putchar('0'); return; }
    while (v) { buf[i++] = (char)('0' + (v % 10)); v /= 10; }
    while (i) sbi_putchar(buf[--i]);
}

static void put_hex(uint64_t v) {
    sbi_puts("0x");
    for (int s = 60; s >= 0; s -= 4) {
        unsigned nib = (unsigned)((v >> s) & 0xF);
        sbi_putchar((char)(nib < 10 ? '0' + nib : 'a' + (nib - 10)));
    }
}

// QEMU virt timebase is 10 MHz, so 1_000_000 time units ~= 0.1 s/tick. TARGET=3
// ticks => ~0.3 s, comfortably inside the QEMU timeout.
#define INTERVAL 1000000ULL
#define TARGET   3

// scause for an S-mode timer interrupt: interrupt bit (63) set + cause 5.
#define SCAUSE_S_TIMER 0x8000000000000005ULL

static volatile uint64_t g_ticks = 0;

// C trap handler. On an S-timer interrupt: count it and re-arm (which also
// clears STIP). On ANY other cause (a real fault), fail closed: report and
// shut down — do NOT loop (a fault loop would otherwise spin forever).
__attribute__((used)) void s_timer_trap(uint64_t scause) {
    if (scause == SCAUSE_S_TIMER) {
        g_ticks++;
        sbi_set_timer(rdtime() + INTERVAL);
        return;
    }
    sbi_puts("SMODE-TIMER-BAD scause=");
    put_hex(scause);
    sbi_putchar('\n');
    sbi_shutdown();
    for (;;) {}
}

// Naked S-mode trap vector. Pure S-mode kernel: every trap comes from S-mode
// (sstatus.SPP=1), so NO sscratch swap — save a full integer frame on the
// current kernel stack, pass scause to the C handler, restore, `sret`.
__attribute__((naked, aligned(4))) void s_trap_vector(void) {
    __asm__ volatile(
        "addi sp, sp, -256\n"
        "sd ra,  0(sp)\n"  "sd t0,  8(sp)\n"  "sd t1, 16(sp)\n"  "sd t2, 24(sp)\n"
        "sd t3, 32(sp)\n"  "sd t4, 40(sp)\n"  "sd t5, 48(sp)\n"  "sd t6, 56(sp)\n"
        "sd a0, 64(sp)\n"  "sd a1, 72(sp)\n"  "sd a2, 80(sp)\n"  "sd a3, 88(sp)\n"
        "sd a4, 96(sp)\n"  "sd a5,104(sp)\n"  "sd a6,112(sp)\n"  "sd a7,120(sp)\n"
        "sd s0,128(sp)\n"  "sd s1,136(sp)\n"  "sd s2,144(sp)\n"  "sd s3,152(sp)\n"
        "sd s4,160(sp)\n"  "sd s5,168(sp)\n"  "sd s6,176(sp)\n"  "sd s7,184(sp)\n"
        "sd s8,192(sp)\n"  "sd s9,200(sp)\n"  "sd s10,208(sp)\n" "sd s11,216(sp)\n"
        "csrr a0, scause\n"
        "call s_timer_trap\n"
        "ld ra,  0(sp)\n"  "ld t0,  8(sp)\n"  "ld t1, 16(sp)\n"  "ld t2, 24(sp)\n"
        "ld t3, 32(sp)\n"  "ld t4, 40(sp)\n"  "ld t5, 48(sp)\n"  "ld t6, 56(sp)\n"
        "ld a0, 64(sp)\n"  "ld a1, 72(sp)\n"  "ld a2, 80(sp)\n"  "ld a3, 88(sp)\n"
        "ld a4, 96(sp)\n"  "ld a5,104(sp)\n"  "ld a6,112(sp)\n"  "ld a7,120(sp)\n"
        "ld s0,128(sp)\n"  "ld s1,136(sp)\n"  "ld s2,144(sp)\n"  "ld s3,152(sp)\n"
        "ld s4,160(sp)\n"  "ld s5,168(sp)\n"  "ld s6,176(sp)\n"  "ld s7,184(sp)\n"
        "ld s8,192(sp)\n"  "ld s9,200(sp)\n"  "ld s10,208(sp)\n" "ld s11,216(sp)\n"
        "addi sp, sp, 256\n"
        "sret\n");
}

__attribute__((used)) void s_entry(uint64_t hartid, uint64_t dtb) {
    (void)hartid; (void)dtb;
    sbi_puts("smode-timer: S-mode under OpenSBI\n");

    // stvec in Direct mode (low 2 bits = 0): all traps vector to s_trap_vector.
    __asm__ volatile("csrw stvec, %0" ::"r"((uintptr_t)&s_trap_vector));

    // Arm the first deadline BEFORE enabling, so the interrupt is pending the
    // moment we open the gate.
    sbi_set_timer(rdtime() + INTERVAL);

    // Enable S-timer interrupts (sie.STIE = bit 5), then global S-interrupts
    // (sstatus.SIE = bit 1). OpenSBI delegates the S-timer to S-mode by default
    // (mideleg), so the SBI-programmed timer raises an S-mode interrupt here.
    __asm__ volatile("csrs sie, %0" ::"r"((uintptr_t)(1u << 5)));
    __asm__ volatile("csrs sstatus, %0" ::"r"((uintptr_t)(1u << 1)));

    // Park the hart until each interrupt fires. A no-delivery bug hangs here
    // into the QEMU timeout rather than busy-polling g_ticks (which would mask
    // a missing interrupt).
    while (g_ticks < TARGET) {
        __asm__ volatile("wfi");
    }

    sbi_puts("SMODE-TIMER TICKS=");
    put_dec(g_ticks);
    sbi_putchar('\n');
    sbi_puts("SMODE-TIMER-OK\n");
    sbi_shutdown();
    for (;;) {}
}

// OpenSBI enters in S-mode at 0x80200000 with a0=hartid, a1=dtb. Set the stack
// but do NOT clobber a0/a1 before the call.
__attribute__((naked, section(".text.boot"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call s_entry\n"
        "1: j 1b\n");
}
