// M8 "AArch64 EL0 user hello" — C bring-up.
//
// The AArch64 analogue of kernel/arch/x86_64/user_runtime.c (M6) and
// kernel/arch/riscv64/smode_user_runtime.c (M2). QEMU 'virt' with `-kernel` loads this flat
// image at RAM base 0x40000000 and (for cortex-a72) enters at EL1 (we drop EL2->EL1 if needed).
// We mirror vm_runtime.c's setup (CPACR FPEN, MAIR/TCR, PL011 UART, identity low RAM), but instead
// of a translation-only proof we:
//
//   1. install a full EL1 exception vector table at a 2 KiB-aligned VBAR_EL1; the "Lower EL using
//      AArch64, synchronous" entry (offset 0x400 — where an EL0 `svc`/abort lands) saves the EL0
//      GP regs + ELR_EL1 + SPSR_EL1 into a frame and calls a C dispatcher;
//   2. build a confined EL0 address space via the MC fixture user_arm_demo.mc (kernel 2 MiB blocks
//      EL1-only + UART Device + user code/stack EL0 pages), load TTBR0_EL1, enable the MMU;
//   3. hand-assemble a tiny EL0 program (raw AArch64 words) into a physical landing frame:
//      SYS_WRITE(valid "HELLO-FROM-EL0\n"), SYS_WRITE(bad 0xDEAD0000), and — iff the bad call
//      returned x0<0 — SYS_WRITE("EFAULT-OK\n"), then SYS_EXIT;
//   4. `eret` into EL0 (enter_user: SP_EL0=user_sp, ELR_EL1=entry, SPSR_EL1=EL0t).
//   5. the synchronous-exception dispatcher decodes ESR_EL1.EC: EC=0x15 (SVC from AArch64) ->
//      read x8/x0/x1/x2 from the saved frame, call the C syscall handler (SYS_WRITE ->
//      sys_write_copyin software-walk-validates the user pointer, returning -EFAULT for the bad
//      one WITHOUT dereferencing it; SYS_EXIT -> print USER-EXIT and halt), write the return value
//      back into the saved x0, return, eret to EL0. An UNEXPECTED data/instruction abort prints a
//      marker (ESR/FAR) + halts, so a bug is diagnosed rather than silently looping.
//
// Syscall convention (kept consistent with the hand-assembled program below):
//   x8 = syscall number, x0/x1/x2 = args; x0 = return value.  (Linux-AArch64 style.)
#include <stdint.h>

// ---- PL011 UART (EL1 only; EL0 never touches it) ----
#define PL011 ((volatile uint32_t *)0x09000000UL)
static void putc_(char c) { *PL011 = (uint32_t)(unsigned char)c; }
static void puts_(const char *s) { for (; *s; ++s) putc_(*s); }
static void putn_(const char *s, uint64_t n) { for (uint64_t i = 0; i < n; i++) putc_(s[i]); }
static void puthex64(uint64_t v) {
    putc_('0'); putc_('x');
    for (int i = 60; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 0xf]);
}
static void halt_forever(void) { for (;;) __asm__ volatile("wfe"); }

// ---- freestanding C runtime helpers the MC-emitted code may reference ----
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

// ---- MC fixture (user_arm_demo.mc) ----
extern uint32_t user_arm_build(uintptr_t region_base, uintptr_t region_len,
                               uintptr_t code_phys, uintptr_t code_len,
                               uintptr_t stack_phys, uintptr_t stack_len,
                               uint64_t *out_ttbr0);
extern uint64_t user_arm_code_va(void);
extern uint64_t user_arm_stack_top_va(void);
extern uint32_t user_arm_kernel_not_user(uintptr_t kernel_va);
extern uint32_t user_arm_code_is_user(void);
extern int64_t  sys_write_copyin(uintptr_t user_ptr, uintptr_t len, uintptr_t kdst);

#define SYS_WRITE 1ULL
#define SYS_EXIT  2ULL

// ========================= EL1 exception vector table =========================
// 16 entries x 0x80 bytes, 4 groups. The table must be 2 KiB-aligned (VBAR_EL1 low 11 bits RES0).
// We only need real behavior on the "Lower EL using AArch64" group (offset 0x400) — that's where
// an EL0 svc / data abort / instruction abort lands. Every entry branches to a common trampoline
// stamped with a "kind" id; the synchronous lower-EL entry (0x400) takes the real save/dispatch
// path, the rest report-and-halt so any surprise is diagnosed.
//
// The trap frame layout pushed by the synchronous lower-EL entry (in this exact order, growing
// down): x0..x30 (31 regs), then ELR_EL1, SPSR_EL1 — 33 doublewords = 264 bytes. The dispatcher
// receives a pointer to x0 (the lowest address).
struct trapframe {
    uint64_t x[31];   // x0..x30
    uint64_t elr;     // ELR_EL1 (return address for eret)
    uint64_t spsr;    // SPSR_EL1
};

__attribute__((used)) void arm_user_syscall(struct trapframe *f);

// Common report-and-halt path for any UNEXPECTED exception (x0 carries the vector "kind").
__attribute__((used)) void arm_user_unexpected(uint64_t kind) {
    uint64_t esr, elr, far, spsr;
    __asm__ volatile("mrs %0, esr_el1" : "=r"(esr));
    __asm__ volatile("mrs %0, elr_el1" : "=r"(elr));
    __asm__ volatile("mrs %0, far_el1" : "=r"(far));
    __asm__ volatile("mrs %0, spsr_el1" : "=r"(spsr));
    puts_("\nARM64-USER-BAD exception kind="); puthex64(kind);
    puts_(" ESR="); puthex64(esr);
    puts_(" EC="); puthex64((esr >> 26) & 0x3f);
    puts_(" ELR="); puthex64(elr);
    puts_(" FAR="); puthex64(far);
    puts_(" SPSR="); puthex64(spsr); putc_('\n');
    halt_forever();
}

// The synchronous lower-EL (EL0) entry: save the full EL0 GP state + ELR/SPSR, call the C
// dispatcher with the frame pointer, restore, and `eret`. On an SVC the CPU already set ELR_EL1
// to the instruction AFTER the svc, so we must NOT advance it. We run on the EL1 stack (SP_EL1),
// which was active on entry (vectors taken to EL1h use SP_EL1).
__attribute__((naked, used)) void arm_user_sync_lower(void) {
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
        "bl arm_user_syscall\n"
        // restore (ELR/SPSR may have been left unchanged; reload them so eret returns to EL0)
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
__attribute__((naked, used)) void arm_user_exc_halt(void) {
    __asm__ volatile("bl arm_user_unexpected\n 1: wfe\n b 1b\n");
}

// The 16-entry vector table. Each entry is 0x80 bytes. Only the "Lower EL AArch64 sync" entry
// (group 3, offset 0x400) takes the real syscall path; the rest stamp a kind and halt.
__attribute__((naked, aligned(2048), used, section(".text.vectors")))
void arm_user_vectors(void) {
    __asm__ volatile(
        // --- Current EL with SP0 ---
        ".balign 0x80\n mov x0, #0\n b arm_user_exc_halt\n"
        ".balign 0x80\n mov x0, #1\n b arm_user_exc_halt\n"
        ".balign 0x80\n mov x0, #2\n b arm_user_exc_halt\n"
        ".balign 0x80\n mov x0, #3\n b arm_user_exc_halt\n"
        // --- Current EL with SPx ---
        ".balign 0x80\n mov x0, #4\n b arm_user_exc_halt\n"
        ".balign 0x80\n mov x0, #5\n b arm_user_exc_halt\n"
        ".balign 0x80\n mov x0, #6\n b arm_user_exc_halt\n"
        ".balign 0x80\n mov x0, #7\n b arm_user_exc_halt\n"
        // --- Lower EL using AArch64 (offset 0x400) ---
        ".balign 0x80\n b arm_user_sync_lower\n"             // 0x400: synchronous (SVC/abort)
        ".balign 0x80\n mov x0, #9\n b arm_user_exc_halt\n"  // 0x480: IRQ
        ".balign 0x80\n mov x0, #10\n b arm_user_exc_halt\n" // 0x500: FIQ
        ".balign 0x80\n mov x0, #11\n b arm_user_exc_halt\n" // 0x580: SError
        // --- Lower EL using AArch32 ---
        ".balign 0x80\n mov x0, #12\n b arm_user_exc_halt\n"
        ".balign 0x80\n mov x0, #13\n b arm_user_exc_halt\n"
        ".balign 0x80\n mov x0, #14\n b arm_user_exc_halt\n"
        ".balign 0x80\n mov x0, #15\n b arm_user_exc_halt\n");
}

static void install_vbar(void) {
    extern void arm_user_vectors(void);
    uint64_t base = (uint64_t)(uintptr_t)&arm_user_vectors;
    __asm__ volatile("msr vbar_el1, %0\n isb\n" : : "r"(base));
}

// ========================= syscall dispatcher =========================
static uint8_t kbuf[256]; // bounded copy-in landing buffer

__attribute__((used)) void arm_user_syscall(struct trapframe *f) {
    uint64_t esr;
    __asm__ volatile("mrs %0, esr_el1" : "=r"(esr));
    uint64_t ec = (esr >> 26) & 0x3f;
    if (ec != 0x15) {
        // Not an SVC from AArch64 EL0: an unexpected synchronous exception (e.g. a data/instr
        // abort, EC 0x20/0x21/0x24/0x25). Diagnose with ESR/FAR + halt rather than loop.
        arm_user_unexpected(0x100 | ec);
        return; // unreachable
    }
    // SVC: x8 = syscall number, x0/x1/x2 = args. On SVC, ELR_EL1 already points past the svc, so
    // we leave f->elr untouched.
    uint64_t nr = f->x[8];
    if (nr == SYS_EXIT) {
        puts_("\nUSER-EXIT from EL0\n");
        halt_forever();
    } else if (nr == SYS_WRITE) {
        uint64_t uptr = f->x[0];
        uint64_t len  = f->x[1];
        if (len > sizeof(kbuf)) len = sizeof(kbuf); // clamp to the bounded buffer
        int64_t res = sys_write_copyin((uintptr_t)uptr, (uintptr_t)len, (uintptr_t)kbuf);
        if (res >= 0) {
            putn_((const char *)kbuf, (uint64_t)res); // print the validated bytes
        }
        f->x[0] = (uint64_t)res; // negative -> -EFAULT; the app sees x0 < 0
    } else {
        puts_("BAD-SYSCALL nr="); puthex64(nr); putc_('\n');
        halt_forever();
    }
}

// ========================= EL0 entry =========================
// Set SP_EL0 = user_sp, ELR_EL1 = entry, SPSR_EL1 = EL0t (M[3:0]=0) with DAIF masked (IRQs off in
// EL0 for this demo — there is no timer/IRQ source we service), then `eret` into EL0.
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

// ========================= the EL0 program (hand-assembled AArch64) =========================
// Layout: a block of instructions (32-bit words) followed by two strings, all in ONE EL0-mapped
// page so the strings are valid EL0 VAs the program passes to SYS_WRITE. The program's VA base is
// UARM_CODE_VA (0x10000000, matching user_arm_demo.mc); string VAs are base + their byte offset.
#define HELLO "HELLO-FROM-EL0\n"
#define EFOK  "EFAULT-OK\n"
#define HELLO_LEN 15
#define EFOK_LEN 10
#define BAD_PTR 0xDEAD0000ULL // unmapped in the EL0 space -> software walk -> -EFAULT

#define USER_VA 0x10000000ULL

// ---- AArch64 instruction encoders ----
// movz xd, #imm16, lsl #(shift)  — hw = shift/16 in {0,1,2,3}
static uint32_t enc_movz(int rd, uint16_t imm, int hw) {
    return 0xD2800000u | ((uint32_t)hw << 21) | ((uint32_t)imm << 5) | (uint32_t)(rd & 31);
}
// movk xd, #imm16, lsl #(shift)
static uint32_t enc_movk(int rd, uint16_t imm, int hw) {
    return 0xF2800000u | ((uint32_t)hw << 21) | ((uint32_t)imm << 5) | (uint32_t)(rd & 31);
}
#define ENC_SVC0 0xD4000001u  // svc #0

// Emit a full 64-bit immediate into xd via movz + up to three movk (low->high). Returns the
// number of 32-bit words emitted. We always emit movz for hw0 then movk for any non-zero higher
// halfword, so the count is value-dependent; callers that need a fixed code size use values whose
// high halfwords are known.
static int emit_mov_imm64(uint32_t *code, int *p, int rd, uint64_t imm) {
    int start = *p;
    code[(*p)++] = enc_movz(rd, (uint16_t)(imm & 0xFFFF), 0);
    for (int hw = 1; hw < 4; hw++) {
        uint16_t part = (uint16_t)((imm >> (16 * hw)) & 0xFFFF);
        if (part != 0) code[(*p)++] = enc_movk(rd, part, hw);
    }
    return *p - start;
}

#define MAX_WORDS 64
static uint32_t user_words[MAX_WORDS];
static uint8_t user_image[MAX_WORDS * 4 + HELLO_LEN + EFOK_LEN];
static int g_image_len;

// Build the EL0 program. The string VAs depend on the total code byte length, so we assemble in
// two passes: pass 1 lays out the instructions to learn CODE_BYTES, pass 2 re-emits with the now-
// known string VAs (their offsets are CODE_BYTES and CODE_BYTES+HELLO_LEN). The instruction shape
// is identical across passes (same immediates' halfword occupancy), so CODE_BYTES is stable.
static void build_user_program(void) {
    uint32_t code_bytes = 0;
    for (int pass = 0; pass < 2; pass++) {
        int p = 0;
        uint64_t hello_va = USER_VA + code_bytes;
        uint64_t efok_va  = USER_VA + code_bytes + HELLO_LEN;

        // 1) SYS_WRITE(HELLO):  x8=1, x0=&HELLO, x1=len ; svc #0
        emit_mov_imm64(user_words, &p, 8, SYS_WRITE);
        emit_mov_imm64(user_words, &p, 0, hello_va);
        emit_mov_imm64(user_words, &p, 1, HELLO_LEN);
        user_words[p++] = ENC_SVC0;
        // 2) SYS_WRITE(BAD_PTR) -> x0 < 0:  x8=1, x0=bad, x1=len ; svc #0
        emit_mov_imm64(user_words, &p, 8, SYS_WRITE);
        emit_mov_imm64(user_words, &p, 0, BAD_PTR);
        emit_mov_imm64(user_words, &p, 1, HELLO_LEN);
        user_words[p++] = ENC_SVC0;
        // 3) if x0 >= 0 (sign bit clear) skip the EFOK write: tbz x0, #63, skip
        //    tbz xt,#bit,off : 0x36000000 base (b5 in bit31 for bit>=32). bit=63 -> b5=1,b40=31.
        //    imm14 (bits[18:5]) is the relative offset in words. Skip target = after the EFOK
        //    block: tbz(1) + [movz+movk(x8) ... EFOK write]. We patch imm14 once we know it.
        int tbz_pos = p;
        user_words[p++] = 0; // placeholder for tbz
        int efok_start = p;
        // 4) SYS_WRITE(EFOK):  x8=1, x0=&EFOK, x1=len ; svc #0
        emit_mov_imm64(user_words, &p, 8, SYS_WRITE);
        emit_mov_imm64(user_words, &p, 0, efok_va);
        emit_mov_imm64(user_words, &p, 1, EFOK_LEN);
        user_words[p++] = ENC_SVC0;
        int skip_target = p; // tbz branches here when x0 >= 0
        // Encode tbz x0, #63, (skip_target - tbz_pos): b5=1, b40=31, imm14=offset words, Rt=0.
        int off_words = skip_target - tbz_pos;
        uint32_t tbz = 0x36000000u
                     | (1u << 31)                              // b5 = bit[5] of test bit = 1 (bit 63)
                     | ((uint32_t)(31u & 0x1f) << 19)          // b40 = low 5 bits of test bit = 31
                     | (((uint32_t)off_words & 0x3fff) << 5)   // imm14
                     | 0u;                                     // Rt = x0
        user_words[tbz_pos] = tbz;
        (void)efok_start;
        // 5) SYS_EXIT:  x8=2 ; svc #0
        emit_mov_imm64(user_words, &p, 8, SYS_EXIT);
        user_words[p++] = ENC_SVC0;

        code_bytes = (uint32_t)(p * 4);

        if (pass == 1) {
            // Serialize words (little-endian) then append the strings.
            for (int i = 0; i < p; i++) {
                user_image[i * 4 + 0] = (uint8_t)(user_words[i]);
                user_image[i * 4 + 1] = (uint8_t)(user_words[i] >> 8);
                user_image[i * 4 + 2] = (uint8_t)(user_words[i] >> 16);
                user_image[i * 4 + 3] = (uint8_t)(user_words[i] >> 24);
            }
            static const char hello[] = HELLO;
            static const char efok[]  = EFOK;
            for (int k = 0; k < HELLO_LEN; k++) user_image[code_bytes + k] = (uint8_t)hello[k];
            for (int k = 0; k < EFOK_LEN; k++)  user_image[code_bytes + HELLO_LEN + k] = (uint8_t)efok[k];
            g_image_len = (int)code_bytes + HELLO_LEN + EFOK_LEN;
        }
    }
}

// ---- backing store (all within the identity-mapped low RAM) ----
__attribute__((aligned(4096))) static uint8_t heap_region[4 * 1024 * 1024];
__attribute__((aligned(4096))) static uint8_t user_page[4096];   // EL0 code/strings landing frame
__attribute__((aligned(4096))) static uint8_t user_stack[8192];  // EL0 stack frames

static void config_mair_tcr(void) {
    // Identical to vm_runtime.c: MAIR Attr0=Normal WB, Attr1=Device-nGnRE; TCR 48-bit VA, 4 KiB.
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

__attribute__((used)) void usermain(void) {
    // CPACR_EL1.FPEN=0b11 (LLVM backend SIMD), as in vm_runtime.c.
    {
        uint64_t cpacr;
        __asm__ volatile("mrs %0, cpacr_el1" : "=r"(cpacr));
        cpacr |= (3UL << 20);
        __asm__ volatile("msr cpacr_el1, %0\n isb\n" : : "r"(cpacr));
    }

    puts_("aarch64 EL0 USER demo boot\n");

    uint64_t cel;
    __asm__ volatile("mrs %0, CurrentEL" : "=r"(cel));
    puts_("user: CurrentEL="); puthex64((cel >> 2) & 3); putc_('\n');

    install_vbar();
    puts_("user: VBAR_EL1 installed (EL0 sync -> syscall dispatch)\n");

    config_mair_tcr();
    puts_("user: MAIR/TCR configured\n");

    // Assemble the EL0 program into the physical landing frame.
    build_user_program();
    for (int i = 0; i < g_image_len; i++) user_page[i] = user_image[i];
    puts_("user: EL0 program assembled, bytes="); puthex64((uint64_t)g_image_len); putc_('\n');

    // Build the confined EL0 address space and get TTBR0.
    uint64_t ttbr0 = 0;
    user_arm_build((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region),
                   (uintptr_t)user_page, (uintptr_t)sizeof(user_page),
                   (uintptr_t)user_stack, (uintptr_t)sizeof(user_stack), &ttbr0);
    puts_("user: address space built, ttbr0="); puthex64(ttbr0); putc_('\n');

    if (user_arm_kernel_not_user((uintptr_t)0x40000000ULL))
        puts_("CONFINED: kernel mapped EL1-only (no EL0 access) in user space\n");
    else
        puts_("LEAK: kernel EL0-accessible in user space\n");
    if (user_arm_code_is_user())
        puts_("CONFINED: user code page is EL0-accessible\n");
    else
        puts_("LEAK: user code not EL0-accessible\n");

    enable_mmu(ttbr0);
    puts_("user: MMU enabled (TTBR0 active); entering EL0\n");

    enter_user(user_arm_code_va(), user_arm_stack_top_va());
    // enter_user does not return (the program SYS_EXITs from EL0).
}

// EL2->EL1 drop helper + EL1 entry (mirrors vm_runtime.c's _start; sets SP then calls usermain).
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
