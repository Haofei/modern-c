// M2 "RISC-V S-mode user hello" — C bring-up.
//
// Under REAL OpenSBI the kernel is entered in S-mode at 0x80200000 (a0=hartid,
// a1=dtb). OpenSBI has already configured PMP and delegated U/S traps to S-mode
// (medeleg/mideleg), so this file uses ONLY S-mode CSRs — no M-mode prologue, no
// PMP, no mret. It is the S-mode port of usermode_runtime.c (M->S CSR rename:
// mtvec->stvec, mscratch->sscratch, mepc->sepc, mcause->scause, mstatus.MPP->SPP,
// mret->sret) composed with the SBI console of sbi_boot_runtime.c and the confined
// address-space builder of agent_confined_demo.mc (here ported to S-mode, where
// satp is effective so the kernel must stay supervisor-mapped).
//
// Flow:
//   1. build a tiny U-mode ELF (hand-assembled RV64) that does SYS_WRITE(valid),
//      SYS_WRITE(bad pointer), SYS_WRITE("EFAULT-OK") iff the bad call returned <0,
//      then SYS_EXIT;
//   2. load its segment into a physical landing frame;
//   3. build the agent's isolated Sv39 space (smode_space_build) — kernel supervisor
//      pages + agent user pages;
//   4. activate satp, install the S-mode trap vector, drop to U-mode (sret);
//   5. s_trap_handler routes ecall: SYS_WRITE -> sys_write_copyin (copy_from_user_pt
//      validates the user pointer, returns -EFAULT for the bad one, never deref'd);
//      SYS_EXIT -> SBI shutdown.
#include <stdint.h>
#include <stddef.h>

#define ECALL_FROM_U 8ULL
#define SCAUSE_INSTR_PAGE_FAULT 12ULL
#define SCAUSE_LOAD_PAGE_FAULT  13ULL
#define SCAUSE_STORE_PAGE_FAULT 15ULL

#define SYS_WRITE 1ULL
#define SYS_EXIT  3ULL

// ---- SBI console + power (legacy SBI: putchar EID=1, shutdown EID=8) ----
static void sbi_putchar(char c) {
    register long a0 __asm__("a0") = (unsigned char)c;
    register long a7 __asm__("a7") = 1;
    __asm__ volatile("ecall" : "+r"(a0) : "r"(a7) : "memory");
}
static void sbi_puts(const char *s) { for (; *s; ++s) sbi_putchar(*s); }
static void sbi_putn(const char *s, uint64_t n) { for (uint64_t i = 0; i < n; i++) sbi_putchar(s[i]); }
static void sbi_puthex(uint64_t v) {
    sbi_puts("0x");
    for (int i = 60; i >= 0; i -= 4) sbi_putchar("0123456789abcdef"[(v >> i) & 0xf]);
}
static void sbi_shutdown(void) {
    register long a7 __asm__("a7") = 8;
    __asm__ volatile("ecall" : : "r"(a7) : "memory");
    for (;;) {}
}

// ---- MC side (smode_user_demo.mc) ----
uint64_t smode_space_build(uintptr_t region_base, uintptr_t region_len,
                           uintptr_t code_phys, uintptr_t code_len,
                           uintptr_t stack_phys, uintptr_t stack_len);
uint64_t agent_code_va(void);
uint64_t agent_stack_top_va(void);
uint32_t kernel_not_user(uintptr_t kernel_va);
uint32_t agent_code_is_user(void);
int64_t  sys_write_copyin(uintptr_t user_ptr, uintptr_t len, uintptr_t kdst);
uint64_t elf_load_run(uintptr_t elf_base, uintptr_t elf_len, uintptr_t dst);

// ---- frame saved by the S-mode trap vector ----
typedef struct {
    uint64_t ra, t0, t1, t2, t3, t4, t5, t6;
    uint64_t a0, a1, a2, a3, a4, a5, a6, a7;
    uint64_t s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11;
} Frame;

// ---- the U-mode program: a hand-assembled RV64 ELF ----
static void put_u16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void put_u32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i)); }
static void put_u64(uint8_t *p, uint64_t v) { for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i)); }

#define VADDR 0x40000000ULL // must match AGENT_CODE_VA in smode_user_demo.mc
#define EH 64
#define PH 56

// Code + data laid out in one PT_LOAD segment (R|X|U). Strings live in the same
// segment, so they are valid user VAs the agent can pass to SYS_WRITE.
#define HELLO "HELLO-FROM-UMODE\n"
#define EFOK  "EFAULT-OK\n"
#define HELLO_LEN 17
#define EFOK_LEN 10
#define BAD_PTR 0xDEAD0000ULL // NOT mapped in the agent's space

// 25 instructions (100 bytes), then the two strings. Layout:
//   WRITE(hello): li a7,a0,a1 (6) + ecall (1)          = 7   insns [ 0.. 6]
//   WRITE(bad):   li a7,a0,a1 (6) + ecall (1)          = 7   insns [ 7..13]
//   bgez a0, +28  (skip the EFOK block)                = 1   insn  [14]
//   WRITE(efok):  li a7,a0,a1 (6) + ecall (1)          = 7   insns [15..21]
//   EXIT:         li a7 (2) + ecall (1)                = 3   insns [22..24]
#define NINSN 25
#define CODE_BYTES (NINSN * 4)
#define DATA_OFF  CODE_BYTES
#define HELLO_OFF DATA_OFF
#define EFOK_OFF  (DATA_OFF + HELLO_LEN)
#define SEG_BYTES (DATA_OFF + HELLO_LEN + EFOK_LEN)

static uint8_t user_elf[EH + PH + SEG_BYTES];
__attribute__((aligned(4096))) static uint8_t load_buf[4096];
__attribute__((aligned(16)))   static uint8_t user_stack[8192];
__attribute__((aligned(4096))) static uint8_t heap_region[262144];

// Build li for a 32-bit constant into a register via lui+addi (handles the sign
// extension of addi's 12-bit immediate). Emits exactly 2 instructions.
static void emit_li32(uint8_t *code, int *idx, int rd, uint32_t val) {
    // lui rd, up20 ; addi rd, rd, low12 — with the standard sign correction so the
    // sign-extended 12-bit addi immediate composes back to `val`.
    int32_t low12 = (int32_t)(val << 20) >> 20;    // sign-extended low 12 bits
    uint32_t up20 = (val - (uint32_t)low12) >> 12; // upper 20 bits for lui
    put_u32(&code[(*idx)++ * 4], (up20 << 12) | (uint32_t)(rd << 7) | 0x37);
    put_u32(&code[(*idx)++ * 4], (((uint32_t)low12 & 0xfff) << 20) | (uint32_t)(rd << 15) | (uint32_t)(rd << 7) | 0x13);
}

static void build_elf(void) {
    for (unsigned i = 0; i < sizeof(user_elf); i++) user_elf[i] = 0;
    user_elf[0] = 0x7F; user_elf[1] = 'E'; user_elf[2] = 'L'; user_elf[3] = 'F';
    user_elf[4] = 2; user_elf[5] = 1; // ELFCLASS64, little-endian
    put_u64(&user_elf[24], VADDR);    // e_entry
    put_u64(&user_elf[32], EH);       // e_phoff
    put_u16(&user_elf[54], PH);       // e_phentsize
    put_u16(&user_elf[56], 1);        // e_phnum

    uint8_t *ph = &user_elf[EH];
    put_u32(&ph[0], 1);               // p_type = PT_LOAD
    put_u32(&ph[4], 5);               // p_flags = R|X
    put_u64(&ph[8], EH + PH);         // p_offset
    put_u64(&ph[16], VADDR);          // p_vaddr (== entry)
    put_u64(&ph[32], SEG_BYTES);      // p_filesz (code + strings)
    put_u64(&ph[40], SEG_BYTES);      // p_memsz

    uint8_t *code = &user_elf[EH + PH];
    int i = 0;
    // --- SYS_WRITE(HELLO, HELLO_LEN): expect a0 = HELLO_LEN ---
    emit_li32(code, &i, 17, (uint32_t)SYS_WRITE);            // a7 = SYS_WRITE
    emit_li32(code, &i, 10, (uint32_t)(VADDR + HELLO_OFF));  // a0 = &HELLO
    emit_li32(code, &i, 11, HELLO_LEN);                      // a1 = HELLO_LEN
    put_u32(&code[i++ * 4], 0x00000073);                     // ecall
    // --- SYS_WRITE(BAD_PTR, HELLO_LEN): expect a0 < 0 (-EFAULT) ---
    emit_li32(code, &i, 17, (uint32_t)SYS_WRITE);            // a7 = SYS_WRITE
    emit_li32(code, &i, 10, (uint32_t)BAD_PTR);              // a0 = bad pointer
    emit_li32(code, &i, 11, HELLO_LEN);                      // a1 = len
    put_u32(&code[i++ * 4], 0x00000073);                     // ecall  (a0 <- result)
    // --- if a0 >= 0, skip the EFAULT-OK report (branch straight to SYS_EXIT) ---
    // The skipped EFOK block is 7 insns (li a7/a0/a1 = 6, ecall = 1) = 28 bytes; the
    // branch itself is at index 14, so +32 lands on the EXIT block at index 22.
    put_u32(&code[i++ * 4], 0x02055063);                     // bgez a0, +32
    // --- a0 < 0: SYS_WRITE(EFOK, EFOK_LEN) ---
    emit_li32(code, &i, 17, (uint32_t)SYS_WRITE);            // a7 = SYS_WRITE
    emit_li32(code, &i, 10, (uint32_t)(VADDR + EFOK_OFF));   // a0 = &EFOK
    emit_li32(code, &i, 11, EFOK_LEN);                       // a1 = EFOK_LEN
    put_u32(&code[i++ * 4], 0x00000073);                     // ecall
    // --- SYS_EXIT(0) ---
    emit_li32(code, &i, 17, (uint32_t)SYS_EXIT);             // a7 = SYS_EXIT
    put_u32(&code[i++ * 4], 0x00000073);                     // ecall

    // (i must equal NINSN; if not the assembler offsets are wrong.)
    // strings
    static const char hello[] = HELLO;
    static const char efok[]  = EFOK;
    for (int k = 0; k < HELLO_LEN; k++) code[HELLO_OFF + k] = (uint8_t)hello[k];
    for (int k = 0; k < EFOK_LEN; k++)  code[EFOK_OFF + k]  = (uint8_t)efok[k];
}

// ---- S-mode trap dispatch ----
__attribute__((aligned(16))) static uint8_t kernel_stack[8192];
static uint8_t kbuf[256]; // bounded copy-in landing buffer

__attribute__((used)) void s_trap_handler(Frame *f) {
    uint64_t scause, sepc, stval;
    __asm__ volatile("csrr %0, scause" : "=r"(scause));
    __asm__ volatile("csrr %0, sepc"   : "=r"(sepc));
    __asm__ volatile("csrr %0, stval"  : "=r"(stval));

    if (scause == ECALL_FROM_U) {
        if (f->a7 == SYS_EXIT) {
            sbi_puts("\nUSER-EXIT from U\n");
            sbi_shutdown();
        } else if (f->a7 == SYS_WRITE) {
            uint64_t len = f->a1;
            if (len > sizeof(kbuf)) len = sizeof(kbuf); // clamp to the bounded buffer
            int64_t r = sys_write_copyin((uintptr_t)f->a0, (uintptr_t)len, (uintptr_t)kbuf);
            if (r >= 0) {
                sbi_putn((const char *)kbuf, (uint64_t)r); // print the validated bytes
                f->a0 = (uint64_t)r;
            } else {
                f->a0 = (uint64_t)r; // negative -> -EFAULT, the app sees a0 < 0
            }
        } else {
            sbi_puts("BAD-SYSCALL a7="); sbi_puthex(f->a7); sbi_putchar('\n');
            sbi_shutdown();
        }
        // advance past the ecall so we do not re-execute it
        __asm__ volatile("csrw sepc, %0" :: "r"(sepc + 4));
        return;
    }

    // The bad-pointer case must NOT fault — copy_from_user_pt handles it. Any page
    // fault here is unexpected; fail closed (but contained: the kernel survives to
    // print and shut down, it does not crash).
    if (scause == SCAUSE_INSTR_PAGE_FAULT || scause == SCAUSE_LOAD_PAGE_FAULT || scause == SCAUSE_STORE_PAGE_FAULT) {
        sbi_puts("UNEXPECTED-TRAP scause="); sbi_puthex(scause);
        sbi_puts(" stval="); sbi_puthex(stval); sbi_putchar('\n');
        sbi_shutdown();
    }
    sbi_puts("UNEXPECTED-TRAP scause="); sbi_puthex(scause); sbi_putchar('\n');
    sbi_shutdown();
}

// S-mode trap vector: swap to the kernel stack via sscratch, save a full integer
// frame, dispatch, restore, sret. (Port of usermode_runtime.c's trap_vector.)
__attribute__((naked, aligned(4))) void s_trap(void) {
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
        "call s_trap_handler\n"
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

// Drop to U-mode (S-mode port of enter_user): set sepc + user sp, clear sstatus.SPP
// (mask 0x100, =0 for U), set sstatus.FS = Initial (0x2000), sret.
__attribute__((naked)) void enter_user(uintptr_t entry, uintptr_t user_sp) {
    __asm__ volatile(
        "csrw sepc, a0\n"
        "mv sp, a1\n"
        "li t0, 0x100\n"     // SPP (sstatus bit 8)
        "csrc sstatus, t0\n" // SPP <- 0 (U-mode)
        "li t1, 0x2000\n"    // FS field = Initial (sstatus 14:13 = 01)
        "csrs sstatus, t1\n"
        "sret\n");
}

__attribute__((used)) void s_entry(void) {
    sbi_puts("kernel up in S-mode under OpenSBI (M2 user hello)\n");
    build_elf();

    // Land the agent's segment into a physical frame; it will run through its OWN
    // page table at VADDR, not at this physical address.
    elf_load_run((uintptr_t)user_elf, (uintptr_t)sizeof(user_elf), (uintptr_t)load_buf);
    __asm__ volatile("fence.i"); // loaded bytes are instructions

    uint64_t satp = smode_space_build((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region),
                                      (uintptr_t)load_buf, (uintptr_t)SEG_BYTES,
                                      (uintptr_t)user_stack, (uintptr_t)sizeof(user_stack));

    if (kernel_not_user((uintptr_t)0x80200000ULL))
        sbi_puts("CONFINED: kernel mapped supervisor-only (no PTE_U) in agent space\n");
    else
        sbi_puts("LEAK: kernel user-accessible in agent space\n");
    if (agent_code_is_user())
        sbi_puts("CONFINED: agent code is U-only\n");
    else
        sbi_puts("LEAK: agent code not user\n");

    // Install the S-mode trap vector + kernel trap stack, then activate satp. In
    // S-mode satp IS effective immediately, so the kernel's supervisor identity
    // window (built above) keeps this code + the trap path running.
    __asm__ volatile("csrw stvec, %0" :: "r"(&s_trap) : "memory");
    __asm__ volatile("csrw sscratch, %0" :: "r"((uintptr_t)(kernel_stack + sizeof(kernel_stack))));
    __asm__ volatile("csrw satp, %0\n sfence.vma" :: "r"(satp) : "memory");

    sbi_puts("kernel: entering confined U-mode agent\n");
    enter_user((uintptr_t)agent_code_va(), (uintptr_t)agent_stack_top_va());
    sbi_shutdown(); // not reached
}

// OpenSBI enters here in S-mode (a0=hartid, a1=dtb).
__attribute__((naked, section(".text.boot"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call s_entry\n"
        "1: j 1b\n");
}
