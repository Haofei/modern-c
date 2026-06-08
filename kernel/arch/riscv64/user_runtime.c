// Test entry for the hand-written user-mode task. The user-mode trap vector,
// privilege drop, and syscall plumbing are in usermode_runtime.c.
#include <stdint.h>

#define SYS_PUTC 2ULL
#define SYS_WRITE 4ULL
#define SYS_EXIT 3ULL

void puts_(const char *s);
void mc_halt(void);
void usermode_setup(void);
void enter_user(uintptr_t entry, uintptr_t user_sp);
uint64_t do_ecall(uint64_t number, uint64_t arg0, uint64_t arg1, uint64_t arg2);

// A message in user memory, passed to the kernel by pointer (copied in via
// copy_from_user, which validates the range).
static const char user_msg[8] = {'F', 'R', 'O', 'M', 'U', 'S', 'E', 'R'};
__attribute__((aligned(16))) static uint8_t user_stack[8192];

// The user program. Runs in U-mode; reaches the kernel only through ecalls.
__attribute__((used)) static void user_main(void) {
    do_ecall(SYS_PUTC, (uint64_t)'U', 0, 0);
    do_ecall(SYS_PUTC, (uint64_t)'S', 0, 0);
    do_ecall(SYS_PUTC, (uint64_t)'R', 0, 0);
    do_ecall(SYS_WRITE, (uint64_t)(uintptr_t)user_msg, sizeof(user_msg), 0); // valid copy
    uint64_t bad = do_ecall(SYS_WRITE, 0x10, 8, 0);                          // out of range
    do_ecall(SYS_PUTC, bad == (uint64_t)-1 ? (uint64_t)'R' : (uint64_t)'X', 0, 0);
    do_ecall(SYS_EXIT, 0, 0, 0);
    for (;;) {
    }
}

__attribute__((used)) void test_main(void) {
    puts_("kernel: configuring user mode\n");
    usermode_setup();
    puts_("kernel: entering user\n");
    enter_user((uintptr_t)&user_main, (uintptr_t)(user_stack + sizeof(user_stack)));
    mc_halt(); // not reached
}
