// exec test entry. Program A (U-mode) prints 'A', then calls sys_exec on a tiny
// hand-assembled ELF (program B) that prints 'B' and exits — so the kernel loads B
// and runs it in U-mode in place of A. UART/_start from context_runtime.c; the
// user-mode trap path from usermode_runtime.c; the syscall table from exec_demo.mc.
#include <stdint.h>
#include <stddef.h>

#define SYS_PUTC 2ULL
#define SYS_EXIT 3ULL
#define SYS_EXEC 10ULL

void puts_(const char *s);
void mc_halt(void);
void usermode_setup(void);
void enter_user(uintptr_t entry, uintptr_t user_sp);
uint64_t do_ecall(uint64_t number, uint64_t arg0, uint64_t arg1, uint64_t arg2);
void set_exec_target(uintptr_t load_addr, uint64_t user_sp);
void icache_flush(void) { __asm__ volatile("fence.i" ::: "memory"); }

static void put_u16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void put_u32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i)); }
static void put_u64(uint8_t *p, uint64_t v) { for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i)); }

#define VADDR 0x80000000ULL
#define EH 64
#define PH 56
#define CODE 20 // 5 instructions

static uint8_t prog_b[EH + PH + CODE];
__attribute__((aligned(4096))) static uint8_t load_buf[4096]; // exec landing zone
__attribute__((aligned(16))) static uint8_t stack_a[8192];
__attribute__((aligned(16))) static uint8_t stack_b[8192];

// Program B: SYS_PUTC 'B'; SYS_EXIT.
static void build_prog_b(void) {
    for (unsigned i = 0; i < sizeof(prog_b); i++) prog_b[i] = 0;
    prog_b[0] = 0x7F; prog_b[1] = 'E'; prog_b[2] = 'L'; prog_b[3] = 'F';
    prog_b[4] = 2; prog_b[5] = 1;
    put_u64(&prog_b[24], VADDR);
    put_u64(&prog_b[32], EH);
    put_u16(&prog_b[54], PH);
    put_u16(&prog_b[56], 1);
    uint8_t *ph = &prog_b[EH];
    put_u32(&ph[0], 1);        // PT_LOAD
    put_u32(&ph[4], 5);        // R|X
    put_u64(&ph[8], EH + PH);  // p_offset
    put_u64(&ph[16], VADDR);   // p_vaddr
    put_u64(&ph[32], CODE);    // p_filesz
    put_u64(&ph[40], CODE);    // p_memsz
    uint8_t *code = &prog_b[EH + PH];
    put_u32(&code[0],  0x00200893); // li a7, 2 (SYS_PUTC)
    put_u32(&code[4],  0x04200513); // li a0, 'B' (0x42)
    put_u32(&code[8],  0x00000073); // ecall
    put_u32(&code[12], 0x00300893); // li a7, 3 (SYS_EXIT)
    put_u32(&code[16], 0x00000073); // ecall
}

// Program A: print 'A', then exec program B (never returns to here).
__attribute__((used)) static void user_main_a(void) {
    do_ecall(SYS_PUTC, (uint64_t)'A', 0, 0);
    do_ecall(SYS_EXEC, (uint64_t)(uintptr_t)prog_b, (uint64_t)sizeof(prog_b), 0);
    do_ecall(SYS_PUTC, (uint64_t)'X', 0, 0); // only if exec failed
    for (;;) {}
}

__attribute__((used)) void test_main(void) {
    puts_("exec booting\n");
    build_prog_b();
    usermode_setup();
    set_exec_target((uintptr_t)load_buf, (uint64_t)(uintptr_t)(stack_b + sizeof(stack_b)));
    puts_("entering program A\n");
    enter_user((uintptr_t)&user_main_a, (uintptr_t)(stack_a + sizeof(stack_a)));
    mc_halt(); // not reached
}
