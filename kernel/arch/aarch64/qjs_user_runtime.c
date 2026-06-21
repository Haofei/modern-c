// M9 "confined QuickJS agent on AArch64 EL0" — kernel C bring-up.
//
// The AArch64 sibling of kernel/arch/x86_64/qjs_user_runtime.c (M7) and a sibling of M8's
// kernel/arch/aarch64/user_runtime.c. It reuses M8's EL0 machinery — the full EL1 exception
// vector table (VBAR_EL1, the "Lower EL using AArch64, synchronous" entry where an EL0 svc/abort
// lands), the MAIR/TCR/SCTLR + CPACR FPEN bring-up, the `eret`-to-EL0 entry — but instead of a
// hand-assembled hello program it:
//   1. loads the REAL multi-segment QuickJS EL0 ELF (embedded as app_image[]) into an ISOLATED
//      stage-1 space via app_build_aarch64 (the MC fixture qjs_arm_demo.mc, which wraps the
//      aarch64 elf_loader + uaccess + paging), which ALSO adds the kernel's RAM identity window
//      EL1-only + the PL011 UART Device page so EL1 + the SVC trap path survive the TTBR0 switch;
//   2. installs VBAR_EL1, loads TTBR0_EL1, enables the MMU, and `eret`s into the QuickJS entry;
//   3. dispatches the FULL agent syscall set in its SVC handler: SYS_EXIT here (prints USER-EXIT
//      + halts), everything else (SYS_WRITE / SYS_READ §0 ingress / SYS_GETPID / SYS_SUBMIT /
//      SYS_POLL + the mock broker) through mc_syscall — the SAME MC syscall table the riscv/x86
//      paths use, reused verbatim; only the trap/entry asm + the UART MMIO is AArch64-specific.
//
// Console: the PL011 UART is MMIO (not port-IO), so unlike the x86 fixture the agent's TTBR0
// maps the UART page (Device, EL1-only). mc_console_putc is exported for the MC SYS_WRITE handler
// to print JS output over that MMIO; EL0 never touches the UART.
//
// FP/SIMD in EL0: CPACR_EL1.FPEN=0b11 is set before EL0 entry (as in vm_runtime.c/M8), so the
// FPU/NEON is usable at EL0 — QuickJS needs doubles (JS numbers) and the LLVM backend emits SIMD.
// The kernel never touches FP regs, so the agent's FP state survives across syscalls with no
// save/restore.
#include <stdint.h>

// ---- PL011 UART (EL1 only; EL0 never touches it) ----
#define PL011 ((volatile uint32_t *)0x09000000UL)
static void putc_(char c) { *PL011 = (uint32_t)(unsigned char)c; }
static void puts_(const char *s) { for (; *s; ++s) putc_(*s); }
static void puthex64(uint64_t v) {
    putc_('0'); putc_('x');
    for (int i = 60; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 0xf]);
}
static void halt_forever(void) { for (;;) __asm__ volatile("wfe"); }

// The MC SYS_WRITE handler prints JS/agent output through this (the PL011 UART MMIO).
__attribute__((used)) void mc_console_putc(uint8_t c) { putc_((char)c); }

// ---- freestanding C runtime helpers QuickJS / the MC backend may emit ----
void *memset(void *dst, int c, unsigned long n) {
    unsigned char *p = (unsigned char *)dst;
    for (unsigned long i = 0; i < n; i++) p[i] = (unsigned char)c;
    return dst;
}
void *memcpy(void *dst, const void *src, unsigned long n) {
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    for (unsigned long i = 0; i < n; i++) d[i] = s[i];
    return dst;
}
void *memmove(void *dst, const void *src, unsigned long n) {
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    if (d < s) {
        for (unsigned long i = 0; i < n; i++) d[i] = s[i];
    } else {
        for (unsigned long i = n; i > 0; i--) d[i - 1] = s[i - 1];
    }
    return dst;
}

// ---- MC fixture (qjs_arm_demo.mc) ----
extern uint32_t app_build_aarch64(uintptr_t image_base, uintptr_t image_len,
                                  uintptr_t region_base, uintptr_t region_len, uint64_t *out_ttbr0);
extern uint32_t app_build_status_aarch64(void);
extern uint64_t app_entry_aarch64(void);
extern uint32_t app_kernel_not_user_aarch64(uintptr_t kernel_va);
extern uint32_t app_entry_is_user_aarch64(void);
extern void     syscall_setup(void);
extern uint64_t mc_syscall(uint64_t number, uint64_t arg0, uint64_t arg1, uint64_t arg2);

// The embedded QuickJS agent ELF (the harness emits app_image.c).
extern const unsigned char app_image[];
extern const unsigned int app_image_len;

// Weak default for the §0 ingress (SYS_READ): no embedded agent source. A test that serves an
// agent.js via SYS_READ links a STRONG mc_agent_source (its embedded JS) overriding this.
__attribute__((weak)) uintptr_t mc_agent_source(uintptr_t *out_len) {
    *out_len = 0;
    return 0;
}

// The agent syscall ABI numbers (mirror user/abi.mc). SYS_EXIT is handled here (like the M8
// trap), everything else dispatches through mc_syscall.
#define SYS_EXIT 3ULL

#define KERNEL_VA 0x40000000ULL // QEMU virt RAM base: the kernel image load address

static const char *load_status_str(uint32_t s) {
    switch (s) {
        case 1: return "APP-LOAD-FAIL: BadElf\n";
        case 2: return "APP-LOAD-FAIL: TooManyPages\n";
        case 3: return "APP-LOAD-FAIL: NoFrame\n";
        case 4: return "APP-LOAD-FAIL: BadSegment\n";
        default: return "APP-LOAD-FAIL: unknown\n";
    }
}

// ========================= EL1 exception vector table =========================
// 16 entries x 0x80 bytes (4 groups). The table must be 2 KiB-aligned (VBAR_EL1 low 11 bits
// RES0). Only the "Lower EL using AArch64" synchronous entry (offset 0x400 — where an EL0 svc /
// data abort / instruction abort lands) takes the real save/dispatch path; the rest report-and-
// halt so any surprise is DIAGNOSED rather than silently looping.
//
// The trap frame pushed by the synchronous lower-EL entry (growing down): x0..x30 (31 regs),
// then ELR_EL1, SPSR_EL1 — 33 doublewords = 264 bytes. The dispatcher receives a pointer to x0.
struct trapframe {
    uint64_t x[31];   // x0..x30
    uint64_t elr;     // ELR_EL1 (return address for eret)
    uint64_t spsr;    // SPSR_EL1
};

__attribute__((used)) void qjs_arm_syscall(struct trapframe *f);

// Common report-and-halt path for any UNEXPECTED exception (x0 carries the vector "kind").
__attribute__((used)) void qjs_arm_unexpected(uint64_t kind) {
    uint64_t esr, elr, far, spsr;
    __asm__ volatile("mrs %0, esr_el1" : "=r"(esr));
    __asm__ volatile("mrs %0, elr_el1" : "=r"(elr));
    __asm__ volatile("mrs %0, far_el1" : "=r"(far));
    __asm__ volatile("mrs %0, spsr_el1" : "=r"(spsr));
    puts_("\nQJS-ARM64-BAD exception kind="); puthex64(kind);
    puts_(" ESR="); puthex64(esr);
    puts_(" EC="); puthex64((esr >> 26) & 0x3f);
    puts_(" ELR="); puthex64(elr);
    puts_(" FAR="); puthex64(far);
    puts_(" SPSR="); puthex64(spsr); putc_('\n');
    halt_forever();
}

// The synchronous lower-EL (EL0) entry: save the full EL0 GP state + ELR/SPSR, call the C
// dispatcher with the frame pointer, restore, and `eret`. On an SVC the CPU already set ELR_EL1
// to the instruction AFTER the svc, so we must NOT advance it. We run on the EL1 stack (SP_EL1).
__attribute__((naked, used)) void qjs_arm_sync_lower(void) {
    __asm__ volatile(
        "sub sp, sp, #(33*8)\n"
        "stp x0, x1,   [sp, #(0*8)]\n"
        "stp x2, x3,   [sp, #(2*8)]\n"
        "stp x4, x5,   [sp, #(4*8)]\n"
        "stp x6, x7,   [sp, #(6*8)]\n"
        "stp x8, x9,   [sp, #(8*8)]\n"
        "stp x10, x11, [sp, #(10*8)]\n"
        "stp x12, x13, [sp, #(12*8)]\n"
        "stp x14, x15, [sp, #(14*8)]\n"
        "stp x16, x17, [sp, #(16*8)]\n"
        "stp x18, x19, [sp, #(18*8)]\n"
        "stp x20, x21, [sp, #(20*8)]\n"
        "stp x22, x23, [sp, #(22*8)]\n"
        "stp x24, x25, [sp, #(24*8)]\n"
        "stp x26, x27, [sp, #(26*8)]\n"
        "stp x28, x29, [sp, #(28*8)]\n"
        "mrs x1, elr_el1\n"
        "stp x30, x1,  [sp, #(30*8)]\n"   // x30 + ELR
        "mrs x2, spsr_el1\n"
        "str x2,       [sp, #(32*8)]\n"   // SPSR
        "mov x0, sp\n"                     // arg0 = &trapframe (points at saved x0)
        "bl qjs_arm_syscall\n"
        // restore (ELR/SPSR reloaded so eret returns to EL0)
        "ldr x2,       [sp, #(32*8)]\n"
        "msr spsr_el1, x2\n"
        "ldp x30, x1,  [sp, #(30*8)]\n"
        "msr elr_el1, x1\n"
        "ldp x0, x1,   [sp, #(0*8)]\n"
        "ldp x2, x3,   [sp, #(2*8)]\n"
        "ldp x4, x5,   [sp, #(4*8)]\n"
        "ldp x6, x7,   [sp, #(6*8)]\n"
        "ldp x8, x9,   [sp, #(8*8)]\n"
        "ldp x10, x11, [sp, #(10*8)]\n"
        "ldp x12, x13, [sp, #(12*8)]\n"
        "ldp x14, x15, [sp, #(14*8)]\n"
        "ldp x16, x17, [sp, #(16*8)]\n"
        "ldp x18, x19, [sp, #(18*8)]\n"
        "ldp x20, x21, [sp, #(20*8)]\n"
        "ldp x22, x23, [sp, #(22*8)]\n"
        "ldp x24, x25, [sp, #(24*8)]\n"
        "ldp x26, x27, [sp, #(26*8)]\n"
        "ldp x28, x29, [sp, #(28*8)]\n"
        "add sp, sp, #(33*8)\n"
        "eret\n");
}

// Report-and-halt trampoline for the non-syscall vectors.
__attribute__((naked, used)) void qjs_arm_exc_halt(void) {
    __asm__ volatile("bl qjs_arm_unexpected\n 1: wfe\n b 1b\n");
}

// The 16-entry vector table. Each entry is 0x80 bytes. Only the "Lower EL AArch64 sync" entry
// (group 3, offset 0x400) takes the real syscall path; the rest stamp a kind and halt.
__attribute__((naked, aligned(2048), used, section(".text.vectors")))
void qjs_arm_vectors(void) {
    __asm__ volatile(
        // --- Current EL with SP0 ---
        ".balign 0x80\n mov x0, #0\n b qjs_arm_exc_halt\n"
        ".balign 0x80\n mov x0, #1\n b qjs_arm_exc_halt\n"
        ".balign 0x80\n mov x0, #2\n b qjs_arm_exc_halt\n"
        ".balign 0x80\n mov x0, #3\n b qjs_arm_exc_halt\n"
        // --- Current EL with SPx ---
        ".balign 0x80\n mov x0, #4\n b qjs_arm_exc_halt\n"
        ".balign 0x80\n mov x0, #5\n b qjs_arm_exc_halt\n"
        ".balign 0x80\n mov x0, #6\n b qjs_arm_exc_halt\n"
        ".balign 0x80\n mov x0, #7\n b qjs_arm_exc_halt\n"
        // --- Lower EL using AArch64 (offset 0x400) ---
        ".balign 0x80\n b qjs_arm_sync_lower\n"             // 0x400: synchronous (SVC/abort)
        ".balign 0x80\n mov x0, #9\n b qjs_arm_exc_halt\n"  // 0x480: IRQ
        ".balign 0x80\n mov x0, #10\n b qjs_arm_exc_halt\n" // 0x500: FIQ
        ".balign 0x80\n mov x0, #11\n b qjs_arm_exc_halt\n" // 0x580: SError
        // --- Lower EL using AArch32 ---
        ".balign 0x80\n mov x0, #12\n b qjs_arm_exc_halt\n"
        ".balign 0x80\n mov x0, #13\n b qjs_arm_exc_halt\n"
        ".balign 0x80\n mov x0, #14\n b qjs_arm_exc_halt\n"
        ".balign 0x80\n mov x0, #15\n b qjs_arm_exc_halt\n");
}

static void install_vbar(void) {
    extern void qjs_arm_vectors(void);
    uint64_t base = (uint64_t)(uintptr_t)&qjs_arm_vectors;
    __asm__ volatile("msr vbar_el1, %0\n isb\n" : : "r"(base));
}

// ========================= syscall dispatcher =========================
// SVC from EL0: ESR_EL1.EC = 0x15. SYS_EXIT is handled here (print USER-EXIT + halt); everything
// else dispatches through the SAME MC syscall table the riscv/x86 paths use (SYS_WRITE / SYS_READ
// / SYS_GETPID / SYS_SUBMIT / SYS_POLL). Args follow the M8 convention: x8 = number, x0/x1/x2 =
// args; the return value goes back into the saved x0. An UNEXPECTED synchronous exception (data/
// instruction abort) is diagnosed with ESR/FAR + halts rather than looping.
__attribute__((used)) void qjs_arm_syscall(struct trapframe *f) {
    uint64_t esr;
    __asm__ volatile("mrs %0, esr_el1" : "=r"(esr));
    uint64_t ec = (esr >> 26) & 0x3f;
    if (ec != 0x15) {
        qjs_arm_unexpected(0x100 | ec);
        return; // unreachable
    }
    uint64_t nr = f->x[8];
    if (nr == SYS_EXIT) {
        puts_("\nUSER-EXIT from EL0\n");
        halt_forever();
    }
    // Everything else: the SAME MC syscall table the riscv/x86 paths use. On SVC, ELR_EL1 already
    // points past the svc, so we leave f->elr untouched.
    f->x[0] = mc_syscall(nr, f->x[0], f->x[1], f->x[2]);
}

// ========================= EL0 entry =========================
// Set SP_EL0 = user_sp, ELR_EL1 = entry, SPSR_EL1 = EL0t (M[3:0]=0) with DAIF masked (IRQs off in
// EL0 — the agent uses polled host I/O over svc, there is no IRQ source we service), then `eret`
// into EL0. crt0_aarch64's _start sets SP_EL0 to __user_stack_top, so user_sp here is overwritten
// — pass entry as a harmless placeholder, mirroring the x86 M7 path.
__attribute__((noreturn, used)) static void enter_user(uint64_t entry, uint64_t user_sp) {
    __asm__ volatile(
        "msr sp_el0, %1\n"
        "msr elr_el1, %0\n"
        "mov x2, #0x3c0\n"      // SPSR_EL1: D,A,I,F masked (0x3c0) + mode EL0t (M[3:0]=0b0000)
        "msr spsr_el1, x2\n"
        "isb\n"
        "eret\n"
        : : "r"(entry), "r"(user_sp) : "x2", "memory");
    __builtin_unreachable();
}

// ========================= MMU bring-up (mirrors M8 user_runtime.c) =========================
static void config_mair_tcr(void) {
    // MAIR Attr0 = Normal WB, Attr1 = Device-nGnRE; TCR 48-bit VA, 4 KiB granule.
    uint64_t mair = (0xFFUL << 0) | (0x04UL << 8);
    __asm__ volatile("msr mair_el1, %0" : : "r"(mair));
    uint64_t tcr =
        (16UL << 0) | (0UL << 14) | (1UL << 8) | (1UL << 10) | (3UL << 12) |
        (1UL << 23) | (5UL << 32);
    __asm__ volatile("msr tcr_el1, %0" : : "r"(tcr));
    __asm__ volatile("isb");
}

static void enable_mmu(uint64_t ttbr0) {
    __asm__ volatile("msr ttbr0_el1, %0" : : "r"(ttbr0));
    __asm__ volatile("dsb ish\n isb\n");
    __asm__ volatile("tlbi vmalle1\n dsb ish\n isb\n");
    uint64_t sctlr;
    __asm__ volatile("mrs %0, sctlr_el1" : "=r"(sctlr));
    sctlr |= (1UL << 0) | (1UL << 2) | (1UL << 12); // M, C, I
    __asm__ volatile("msr sctlr_el1, %0\n isb\n" : : "r"(sctlr) : "memory");
}

// ---- backing store ----
// The agent's page tables + the per-page frames the loader allocates. QuickJS needs MiB: the
// 8 MiB malloc arena (host) + the engine text/rodata/data + the 512 KiB user stack + interior
// tables. 16 MiB, matching the x86/riscv confined runtimes. Lives in .bss within the kernel's
// low-RAM identity window (mapped EL1-only in the agent's TTBR0).
__attribute__((aligned(4096))) static uint8_t region[16u << 20];

__attribute__((used)) void usermain(void) {
    // CPACR_EL1.FPEN=0b11 (QuickJS doubles + the LLVM backend's SIMD), as in vm_runtime.c/M8.
    {
        uint64_t cpacr;
        __asm__ volatile("mrs %0, cpacr_el1" : "=r"(cpacr));
        cpacr |= (3UL << 20);
        __asm__ volatile("msr cpacr_el1, %0\n isb\n" : : "r"(cpacr));
    }

    puts_("aarch64 EL0: confined QuickJS agent boot OK\n");

    uint64_t cel;
    __asm__ volatile("mrs %0, CurrentEL" : "=r"(cel));
    puts_("qjs: CurrentEL="); puthex64((cel >> 2) & 3); putc_('\n');

    install_vbar();
    puts_("qjs: VBAR_EL1 installed (EL0 sync -> syscall dispatch)\n");

    config_mair_tcr();
    puts_("qjs: MAIR/TCR configured\n");

    // Register the MC syscall table (SYS_WRITE/READ/GETPID/SUBMIT/POLL) before any svc.
    syscall_setup();

    // Build the agent's isolated space: load the QuickJS ELF + add the kernel RAM/UART window.
    uint64_t ttbr0 = 0;
    uint32_t ok = app_build_aarch64((uintptr_t)app_image, (uintptr_t)app_image_len,
                                    (uintptr_t)region, (uintptr_t)sizeof(region), &ttbr0);
    if (!ok || ttbr0 == 0) {
        puts_(load_status_str(app_build_status_aarch64()));
        halt_forever();
    }
    puts_("qjs: agent address space built, ttbr0="); puthex64(ttbr0); putc_('\n');

    // Confinement proof (M8 form): the kernel is mapped (so EL1 + the trap path survive the TTBR0
    // switch) but is NOT EL0-accessible — a direct kernel touch from EL0 would fault.
    if (app_kernel_not_user_aarch64((uintptr_t)KERNEL_VA))
        puts_("CONFINED: kernel mapped EL1-only (no EL0 access) in agent space\n");
    else
        puts_("LEAK: kernel EL0-accessible in agent space\n");
    if (app_entry_is_user_aarch64())
        puts_("CONFINED: agent entry is EL0-accessible\n");
    else
        puts_("LEAK: agent entry not EL0-accessible\n");

    uint64_t entry = app_entry_aarch64();
    enable_mmu(ttbr0);
    puts_("qjs: MMU enabled (TTBR0 active); entering confined QuickJS agent\n");

    enter_user(entry, entry);
    // enter_user does not return (the agent SYS_EXITs from EL0).
}

// EL2->EL1 drop helper + EL1 entry (mirrors vm_runtime.c/M8's _start; sets SP then calls usermain).
__attribute__((naked, used, section(".text.boot"))) void _start(void) {
    __asm__ volatile(
        "ldr x1, =_stack_top\n"
        "mov sp, x1\n"
        "mrs x0, CurrentEL\n"
        "lsr x0, x0, #2\n"
        "and x0, x0, #3\n"
        "cmp x0, #2\n"
        "b.ne 2f\n"
        // --- at EL2: drop to EL1 ---
        "mov x0, #(1 << 31)\n"     // HCR_EL2.RW = 1 (EL1 is AArch64)
        "msr hcr_el2, x0\n"
        "mov x0, #0x3c5\n"         // SPSR_EL2: D,A,I,F masked + mode EL1h
        "msr spsr_el2, x0\n"
        "adr x0, 1f\n"
        "msr elr_el2, x0\n"
        "isb\n"
        "eret\n"
        "1:\n"
        "ldr x1, =_stack_top\n"
        "mov sp, x1\n"
        "2:\n"
        "bl usermain\n"
        "3: wfe\n b 3b\n");
}
