// Test entry for ELF load-and-run. Builds a tiny in-memory ELF64 whose single
// PT_LOAD segment is hand-assembled RV64 code that prints "OK" and exits via
// syscalls. The MC loader (elf_load_run) parses + loads it; usermode_setup +
// enter_user run it in U-mode. UART/_start come from context_runtime.c; the
// user-mode trap path from usermode_runtime.c; the syscall table from the MC.
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

void puts_(const char *s);
void mc_halt(void);
void usermode_setup(void);
void enter_user(uintptr_t entry, uintptr_t user_sp);
uint64_t elf_load_run(uintptr_t elf_base, uintptr_t elf_len, uintptr_t dst);

static void put_u16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void put_u32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i)); }
static void put_u64(uint8_t *p, uint64_t v) { for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i)); }

#define VADDR 0x80000000ULL
#define EH 64
#define PH 56
#define CODE 28 // 7 instructions

static uint8_t user_elf[EH + PH + CODE];
__attribute__((aligned(4096))) static uint8_t load_buf[4096]; // segment landing zone (exec in U)
__attribute__((aligned(16))) static uint8_t user_stack[8192];

// A user program: SYS_PUTC 'O'; SYS_PUTC 'K'; SYS_EXIT. (SYS_PUTC=2, SYS_EXIT=3.)
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
    put_u64(&ph[8], EH + PH);         // p_offset (code follows the program header)
    put_u64(&ph[16], VADDR);          // p_vaddr (== entry, so entry offset is 0)
    put_u64(&ph[32], CODE);           // p_filesz
    put_u64(&ph[40], CODE);           // p_memsz

    uint8_t *code = &user_elf[EH + PH];
    put_u32(&code[0],  0x00200893);   // li a7, 2     (SYS_PUTC)
    put_u32(&code[4],  0x04f00513);   // li a0, 'O'
    put_u32(&code[8],  0x00000073);   // ecall
    put_u32(&code[12], 0x04b00513);   // li a0, 'K'
    put_u32(&code[16], 0x00000073);   // ecall
    put_u32(&code[20], 0x00300893);   // li a7, 3     (SYS_EXIT)
    put_u32(&code[24], 0x00000073);   // ecall
}

__attribute__((used)) void test_main(void) {
    puts_("kernel: loading user ELF\n");
    build_elf();
    usermode_setup();
    uint64_t entry = elf_load_run((uintptr_t)user_elf, (uintptr_t)sizeof(user_elf), (uintptr_t)load_buf);
    __asm__ volatile("fence.i"); // the loaded bytes are instructions
    puts_("kernel: running loaded ELF\n");
    enter_user((uintptr_t)entry, (uintptr_t)(user_stack + sizeof(user_stack)));
    mc_halt(); // not reached
}
