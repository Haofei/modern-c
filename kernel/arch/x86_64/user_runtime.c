// M6 "x86-64 ring-3 user hello" — C bring-up.
//
// The x86-64 analogue of kernel/arch/riscv64/smode_user_runtime.c (RISC-V M2). In 64-bit long
// mode (reached from boot.S, which identity-maps the low 1 GiB and runs us at 1 MiB):
//
//   1. build a fresh GDT with ring-0 code/data, ring-3 code/data, and a TSS descriptor; load
//      it (lgdt) and load the task register (ltr). TSS.RSP0 = top of a kernel trap stack, so a
//      ring-3 -> ring-0 trap (our int $0x80) switches to a safe kernel stack;
//   2. install an IDT with #GP(13) + #PF(14) handlers (print a marker + halt, so a bug is
//      DIAGNOSED, not a triple fault) and a SYSCALL gate at vector 0x80 with DPL=3 so ring-3's
//      `int $0x80` is permitted;
//   3. hand-assemble a tiny ring-3 program (raw x86-64 bytes) into a physical landing frame:
//      SYS_WRITE(valid "HELLO-FROM-RING3\n"), SYS_WRITE(bad 0xDEAD0000), and — iff the bad call
//      returned RAX<0 — SYS_WRITE("EFAULT-OK\n"), then SYS_EXIT;
//   4. build the user address space via the MC fixture user_x86_demo.mc (kernel identity no-US
//      + user code/stack US), load CR3, and `iretq` into ring 3 (enter_user);
//   5. the vector-0x80 ISR saves registers, reads RAX/RDI/RSI from the saved frame, calls the
//      C dispatcher (SYS_WRITE -> sys_write_copyin software-walk-validates the user pointer,
//      returning -EFAULT for the bad one WITHOUT dereferencing it; SYS_EXIT -> print USER-EXIT
//      and shut down), writes the return value back into the saved RAX, and iretq's to ring 3.
//
// Syscall convention (kept consistent with the hand-assembled program below):
//   RAX = syscall number, RDI = arg0 (user pointer), RSI = arg1 (length); RAX = return value.
#include <stdint.h>

// ---- COM1 serial (port IO from ring 0; ring-3 never touches it) ----
static inline void outb(uint16_t port, uint8_t val) {
    __asm__ volatile("outb %0, %1" : : "a"(val), "Nd"(port));
}
static inline uint8_t inb(uint16_t port) {
    uint8_t r;
    __asm__ volatile("inb %1, %0" : "=a"(r) : "Nd"(port));
    return r;
}
#define COM1 0x3F8
static void serial_init(void) {
    outb(COM1 + 1, 0x00);
    outb(COM1 + 3, 0x80);
    outb(COM1 + 0, 0x03);
    outb(COM1 + 1, 0x00);
    outb(COM1 + 3, 0x03);
    outb(COM1 + 2, 0xC7);
    outb(COM1 + 4, 0x0B);
}
static void putc_(char c) {
    while ((inb(COM1 + 5) & 0x20) == 0) {
    }
    outb(COM1, (uint8_t)c);
}
static void puts_(const char *s) {
    while (*s) putc_(*s++);
}
static void putn_(const char *s, uint64_t n) {
    for (uint64_t i = 0; i < n; i++) putc_(s[i]);
}
static void puthex64(uint64_t v) {
    putc_('0'); putc_('x');
    for (int i = 60; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 0xf]);
}
static void qemu_exit(uint8_t code) { outb(0xf4, code); }
static void halt_forever(void) { for (;;) __asm__ volatile("hlt"); }

// ---- freestanding C runtime helpers the compiler may emit ----
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

// ---- MC fixture (user_x86_demo.mc) ----
extern uint32_t user_x86_build(uintptr_t region_base, uintptr_t region_len,
                               uintptr_t code_phys, uintptr_t code_len,
                               uintptr_t stack_phys, uintptr_t stack_len,
                               uint64_t *out_cr3);
extern uint64_t user_code_va(void);
extern uint64_t user_stack_top_va(void);
extern uint32_t kernel_not_user(uintptr_t kernel_va);
extern uint32_t user_code_is_user(void);
extern int64_t  sys_write_copyin(uintptr_t user_ptr, uintptr_t len, uintptr_t kdst);

#define SYS_WRITE 1ULL
#define SYS_EXIT  2ULL

// ========================= GDT + TSS =========================
// Segment selectors (index<<3 | RPL). Our GDT layout:
//   [0] null  [1] ring-0 code  [2] ring-0 data  [3] ring-3 code  [4] ring-3 data
//   [5..6] TSS (a 64-bit system descriptor occupies two 8-byte slots)
#define SEL_KCODE 0x08
#define SEL_KDATA 0x10
#define SEL_UCODE (0x18 | 3) // ring-3 code, RPL=3
#define SEL_UDATA (0x20 | 3) // ring-3 data, RPL=3
#define SEL_TSS   0x28

struct tss64 {
    uint32_t reserved0;
    uint64_t rsp0;   // stack loaded on a ring3->ring0 trap
    uint64_t rsp1;
    uint64_t rsp2;
    uint64_t reserved1;
    uint64_t ist[7];
    uint64_t reserved2;
    uint16_t reserved3;
    uint16_t iomap_base;
} __attribute__((packed));

static struct tss64 g_tss;

// GDT: 5 code/data descriptors (8 bytes each) + a 16-byte TSS descriptor = 7 quadwords.
static uint64_t g_gdt[7];

struct gdt_ptr {
    uint16_t limit;
    uint64_t base;
} __attribute__((packed));
static struct gdt_ptr g_gdtr;

// A flat 64-bit code/data descriptor. `code`=1 => code segment (executable + L bit for long
// mode); `dpl` is the descriptor privilege level (0 kernel, 3 user).
static uint64_t make_seg(int code, int dpl) {
    uint64_t d = 0;
    d |= (1ULL << 44); // S = 1 (code/data, not system)
    d |= (1ULL << 47); // P = 1 (present)
    d |= ((uint64_t)(dpl & 3)) << 45;
    if (code) {
        d |= (1ULL << 43); // executable
        d |= (1ULL << 53); // L = 1 (64-bit code segment)
    } else {
        d |= (1ULL << 41); // writable (data)
    }
    return d;
}

static void gdt_install(void) {
    g_gdt[0] = 0;                  // null
    g_gdt[1] = make_seg(1, 0);     // ring-0 code
    g_gdt[2] = make_seg(0, 0);     // ring-0 data
    g_gdt[3] = make_seg(1, 3);     // ring-3 code
    g_gdt[4] = make_seg(0, 3);     // ring-3 data

    // 64-bit TSS descriptor (two 8-byte slots, indices 5 and 6).
    uint64_t base = (uint64_t)(uintptr_t)&g_tss;
    uint32_t limit = (uint32_t)(sizeof(g_tss) - 1);
    uint64_t lo = 0;
    lo |= (limit & 0xFFFFULL);
    lo |= ((base & 0xFFFFFFULL) << 16);
    lo |= (0x9ULL << 40);          // type = 0x9 (available 64-bit TSS)
    lo |= (1ULL << 47);            // present
    lo |= (((uint64_t)(limit >> 16) & 0xFULL) << 48);
    lo |= (((base >> 24) & 0xFFULL) << 56);
    g_gdt[5] = lo;
    g_gdt[6] = (base >> 32) & 0xFFFFFFFFULL; // high 32 bits of base

    g_gdtr.limit = (uint16_t)(sizeof(g_gdt) - 1);
    g_gdtr.base = (uint64_t)(uintptr_t)&g_gdt[0];
    __asm__ volatile("lgdt %0" : : "m"(g_gdtr) : "memory");

    // Reload the data segment registers and CS (CS via a far return). SS must be a ring-0
    // data selector while we run in ring 0.
    __asm__ volatile(
        "mov %0, %%ax\n"
        "mov %%ax, %%ds\n"
        "mov %%ax, %%es\n"
        "mov %%ax, %%ss\n"
        "mov %%ax, %%fs\n"
        "mov %%ax, %%gs\n"
        : : "r"((uint16_t)SEL_KDATA) : "rax");
    __asm__ volatile(
        "lea 1f(%%rip), %%rax\n"
        "push %0\n"          // new CS
        "push %%rax\n"       // new RIP
        "lretq\n"            // far return reloads CS
        "1:\n"
        : : "i"(SEL_KCODE) : "rax", "memory");

    // Load the task register with the TSS selector.
    __asm__ volatile("ltr %0" : : "r"((uint16_t)SEL_TSS));
}

// ========================= IDT =========================
struct idt_entry {
    uint16_t off_lo;
    uint16_t sel;
    uint8_t  ist;
    uint8_t  type_attr;
    uint16_t off_mid;
    uint32_t off_hi;
    uint32_t zero;
} __attribute__((packed));
struct idt_ptr {
    uint16_t limit;
    uint64_t base;
} __attribute__((packed));
static struct idt_entry g_idt[256];
static struct idt_ptr g_idtr;

static void idt_set(int vec, void (*handler)(void), uint8_t dpl) {
    uint64_t addr = (uint64_t)(uintptr_t)handler;
    g_idt[vec].off_lo = (uint16_t)(addr & 0xFFFF);
    g_idt[vec].sel = SEL_KCODE;
    g_idt[vec].ist = 0;
    // present, given DPL, type=0xE (64-bit interrupt gate).
    g_idt[vec].type_attr = (uint8_t)(0x8E | ((dpl & 3) << 5));
    g_idt[vec].off_mid = (uint16_t)((addr >> 16) & 0xFFFF);
    g_idt[vec].off_hi = (uint32_t)((addr >> 32) & 0xFFFFFFFF);
    g_idt[vec].zero = 0;
}

__attribute__((used)) static void on_gp(void) {
    puts_("\nX86-USER-BAD #GP\n");
    qemu_exit(1);
    halt_forever();
}
__attribute__((used)) static void on_pf(void) {
    uint64_t cr2;
    __asm__ volatile("mov %%cr2, %0" : "=r"(cr2));
    puts_("\nX86-USER-BAD #PF at "); puthex64(cr2); putc_('\n');
    qemu_exit(1);
    halt_forever();
}
__attribute__((naked, used)) static void gp_stub(void) {
    __asm__ volatile("cli\n call on_gp\n 1: hlt\n jmp 1b\n");
}
__attribute__((naked, used)) static void pf_stub(void) {
    __asm__ volatile("cli\n call on_pf\n 1: hlt\n jmp 1b\n");
}

// ---- syscall (int $0x80) ISR ----
// The C dispatcher receives a pointer to the saved general-purpose registers (in the order the
// asm stub pushes them) and may modify the saved RAX (the syscall return value). int $0x80 is a
// trap WITHOUT a CPU error code, so the stub does not pop one.
struct regs {
    uint64_t rdi, rsi, rdx, rcx, rbx, rax, rbp;
    uint64_t r8, r9, r10, r11, r12, r13, r14, r15;
};

static uint8_t kbuf[256]; // bounded copy-in landing buffer

__attribute__((used)) static void syscall_dispatch(struct regs *r) {
    uint64_t nr = r->rax;
    if (nr == SYS_EXIT) {
        puts_("\nUSER-EXIT from ring3\n");
        qemu_exit(0);
        halt_forever();
    } else if (nr == SYS_WRITE) {
        uint64_t len = r->rsi;
        if (len > sizeof(kbuf)) len = sizeof(kbuf); // clamp to the bounded buffer
        int64_t res = sys_write_copyin((uintptr_t)r->rdi, (uintptr_t)len, (uintptr_t)kbuf);
        if (res >= 0) {
            putn_((const char *)kbuf, (uint64_t)res); // print the validated bytes
            r->rax = (uint64_t)res;
        } else {
            r->rax = (uint64_t)res; // negative -> -EFAULT; the app sees RAX < 0
        }
    } else {
        puts_("BAD-SYSCALL nr="); puthex64(nr); putc_('\n');
        qemu_exit(1);
        halt_forever();
    }
}

// Saves the GP registers (matching struct regs layout), calls the dispatcher with RSP (the
// frame pointer) in RDI, restores, and iretq's back to ring 3. The CPU already pushed
// SS/RSP/RFLAGS/CS/RIP and switched to TSS.RSP0 on the ring3->ring0 transition.
__attribute__((naked, used)) static void syscall_stub(void) {
    __asm__ volatile(
        "push %%r15\n push %%r14\n push %%r13\n push %%r12\n"
        "push %%r11\n push %%r10\n push %%r9\n push %%r8\n"
        "push %%rbp\n push %%rax\n push %%rbx\n push %%rcx\n"
        "push %%rdx\n push %%rsi\n push %%rdi\n"
        "mov %%rsp, %%rdi\n"        // arg0 = &saved regs
        "call syscall_dispatch\n"
        "pop %%rdi\n pop %%rsi\n pop %%rdx\n"
        "pop %%rcx\n pop %%rbx\n pop %%rax\n pop %%rbp\n"
        "pop %%r8\n pop %%r9\n pop %%r10\n pop %%r11\n"
        "pop %%r12\n pop %%r13\n pop %%r14\n pop %%r15\n"
        "iretq\n"
        : : : "memory");
}

static void idt_install(void) {
    for (int i = 0; i < 256; i++) idt_set(i, gp_stub, 0);
    idt_set(13, gp_stub, 0);
    idt_set(14, pf_stub, 0);
    idt_set(0x80, syscall_stub, 3); // DPL=3 so ring-3 `int $0x80` is allowed
    g_idtr.limit = (uint16_t)(sizeof(g_idt) - 1);
    g_idtr.base = (uint64_t)(uintptr_t)&g_idt[0];
    __asm__ volatile("lidt %0" : : "m"(g_idtr) : "memory");
}

// ========================= ring-3 entry =========================
// Push a ring-3 iretq frame (SS, RSP, RFLAGS, CS, RIP) and iretq into ring 3. RFLAGS=0x202
// (IF set, reserved bit 1). DS/ES set to the ring-3 data selector.
__attribute__((naked, used)) static void enter_user(uint64_t entry, uint64_t user_rsp) {
    __asm__ volatile(
        "mov %0, %%ax\n"
        "mov %%ax, %%ds\n"
        "mov %%ax, %%es\n"
        "mov %%ax, %%fs\n"
        "mov %%ax, %%gs\n"
        "push %1\n"            // SS = ring-3 data
        "push %%rsi\n"         // RSP = user_rsp (2nd arg)
        "push $0x202\n"        // RFLAGS (IF | reserved)
        "push %2\n"            // CS = ring-3 code
        "push %%rdi\n"         // RIP = entry (1st arg)
        "iretq\n"
        : : "i"(SEL_UDATA), "i"(SEL_UDATA), "i"(SEL_UCODE) : "rax", "memory");
}

// ========================= the ring-3 program (hand-assembled x86-64) =========================
// Layout: a block of code followed by two strings, all in ONE user-mapped page so the strings
// are valid ring-3 VAs the program passes to SYS_WRITE. The program's VA base is USER_CODE_VA
// (0x40000000, matching user_x86_demo.mc); string VAs are USER_CODE_VA + their offset.
#define HELLO "HELLO-FROM-RING3\n"
#define EFOK  "EFAULT-OK\n"
#define HELLO_LEN 17
#define EFOK_LEN 10
#define BAD_PTR 0xDEAD0000ULL // unmapped in the user space -> software walk -> -EFAULT

#define USER_VA 0x40000000ULL

// Emit `mov r32, imm32` (B8+rd id) — zero-extends into the 64-bit register, fine for our
// values (all < 2^32). rd: 0=rax,6=rsi,7=rdi.
static void emit_mov_imm32(uint8_t *buf, int *p, int rd, uint32_t imm) {
    buf[(*p)++] = (uint8_t)(0xB8 + rd);
    buf[(*p)++] = (uint8_t)(imm);
    buf[(*p)++] = (uint8_t)(imm >> 8);
    buf[(*p)++] = (uint8_t)(imm >> 16);
    buf[(*p)++] = (uint8_t)(imm >> 24);
}
static void emit_int80(uint8_t *buf, int *p) { buf[(*p)++] = 0xCD; buf[(*p)++] = 0x80; }

#define MAX_CODE 128
static uint8_t user_code[MAX_CODE + HELLO_LEN + EFOK_LEN];
static int g_code_len;

static void build_user_program(void) {
    // The instruction sequence is fixed-size, so the strings' offset (= total code length) is
    // known analytically up front, which resolves the code-references-string chicken-and-egg
    // without a second pass:
    //   each `mov r32,imm32` = 5 bytes, `int 0x80` = 2, `test rax,rax` = 3, `jns rel8` = 2.
    //   WRITE = 3 movs (15) + int (2) = 17 bytes; ×2 (HELLO + BAD) = 34
    //   test (3) + jns (2)                                         =  5
    //   WRITE EFOK                                                 = 17
    //   EXIT = mov (5) + int (2)                                   =  7
    //   total code = 34 + 5 + 17 + 7                               = 63 bytes
    // so the strings start at offset 63 and their VAs are USER_VA + 63 (+ HELLO_LEN for EFOK).
    int p = 0;
    const int CODE_LEN = 63;
    const uint32_t hello_va = (uint32_t)(USER_VA + CODE_LEN);
    const uint32_t efok_va  = (uint32_t)(USER_VA + CODE_LEN + HELLO_LEN);

    // 1) SYS_WRITE(HELLO)
    emit_mov_imm32(user_code, &p, 0, (uint32_t)SYS_WRITE);   // mov eax,1
    emit_mov_imm32(user_code, &p, 7, hello_va);              // mov edi,&HELLO
    emit_mov_imm32(user_code, &p, 6, HELLO_LEN);             // mov esi,len
    emit_int80(user_code, &p);
    // 2) SYS_WRITE(BAD_PTR) -> rax < 0
    emit_mov_imm32(user_code, &p, 0, (uint32_t)SYS_WRITE);   // mov eax,1
    emit_mov_imm32(user_code, &p, 7, (uint32_t)BAD_PTR);     // mov edi,bad
    emit_mov_imm32(user_code, &p, 6, HELLO_LEN);             // mov esi,len
    emit_int80(user_code, &p);
    // 3) test rax,rax ; jns skip  (skip the EFOK write if rax >= 0)
    user_code[p++] = 0x48; user_code[p++] = 0x85; user_code[p++] = 0xC0; // test rax,rax
    user_code[p++] = 0x79;                                               // jns rel8
    int jns_operand_pos = p;
    user_code[p++] = 0x00;                                               // placeholder
    int after_jns = p;
    // 4) SYS_WRITE(EFOK)
    emit_mov_imm32(user_code, &p, 0, (uint32_t)SYS_WRITE);   // mov eax,1
    emit_mov_imm32(user_code, &p, 7, efok_va);              // mov edi,&EFOK
    emit_mov_imm32(user_code, &p, 6, EFOK_LEN);             // mov esi,len
    emit_int80(user_code, &p);
    int skip_target = p;
    user_code[jns_operand_pos] = (uint8_t)(skip_target - after_jns); // rel8 forward
    // 5) SYS_EXIT
    emit_mov_imm32(user_code, &p, 0, (uint32_t)SYS_EXIT);    // mov eax,2
    emit_int80(user_code, &p);

    // (p must equal CODE_LEN; if the analytic CODE_LEN is wrong the string VAs are wrong.)
    // Append the strings right after the code.
    static const char hello[] = HELLO;
    static const char efok[]  = EFOK;
    for (int k = 0; k < HELLO_LEN; k++) user_code[CODE_LEN + k] = (uint8_t)hello[k];
    for (int k = 0; k < EFOK_LEN; k++)  user_code[CODE_LEN + HELLO_LEN + k] = (uint8_t)efok[k];
    g_code_len = CODE_LEN + HELLO_LEN + EFOK_LEN;

    if (p != CODE_LEN) {
        puts_("X86-USER-BAD code-len mismatch p="); puthex64((uint64_t)p); putc_('\n');
        qemu_exit(1);
        halt_forever();
    }
}

// ---- backing store ----
__attribute__((aligned(4096))) static uint8_t heap_region[1024 * 1024];
__attribute__((aligned(4096))) static uint8_t user_page[4096];    // physical landing frame
__attribute__((aligned(4096))) static uint8_t user_stack[8192];   // user stack frames
__attribute__((aligned(16)))   static uint8_t kernel_trap_stack[8192]; // RSP0

void kmain(void) {
    serial_init();
    puts_("x86-64 long mode: USER demo boot OK\n");

    gdt_install();
    puts_("user: GDT+TSS installed (ring0/ring3 segments, TR loaded)\n");
    idt_install();
    puts_("user: IDT installed (#GP=13, #PF=14, syscall=0x80 DPL3)\n");

    // TSS.RSP0 = top of the kernel trap stack (used on the ring3->ring0 trap entry).
    g_tss.rsp0 = (uint64_t)(uintptr_t)(kernel_trap_stack + sizeof(kernel_trap_stack));
    g_tss.iomap_base = (uint16_t)sizeof(g_tss); // no I/O bitmap

    // Assemble the ring-3 program into the physical landing frame.
    build_user_program();
    for (int i = 0; i < g_code_len; i++) user_page[i] = user_code[i];

    // Build the user address space (kernel identity no-US + user code/stack US) and get CR3.
    uint64_t cr3 = 0;
    user_x86_build((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region),
                   (uintptr_t)user_page, (uintptr_t)sizeof(user_page),
                   (uintptr_t)user_stack, (uintptr_t)sizeof(user_stack), &cr3);
    puts_("user: address space built, cr3="); puthex64(cr3); putc_('\n');

    if (kernel_not_user((uintptr_t)0x100000ULL)) // 1 MiB: kernel image
        puts_("CONFINED: kernel mapped supervisor-only (no PTE_US) in user space\n");
    else
        puts_("LEAK: kernel user-accessible in user space\n");
    if (user_code_is_user())
        puts_("CONFINED: user code is ring-3 accessible\n");
    else
        puts_("LEAK: user code not user-accessible\n");

    // Activate the user CR3 (kernel stays mapped no-US, so this code keeps running).
    __asm__ volatile("mov %0, %%cr3" : : "r"(cr3) : "memory");
    puts_("user: CR3 reloaded; entering ring 3\n");

    enter_user(user_code_va(), user_stack_top_va());

    // enter_user does not return (the program SYS_EXITs from ring 3).
    puts_("X86-USER-BAD (enter_user returned)\n");
    qemu_exit(1);
    halt_forever();
}
