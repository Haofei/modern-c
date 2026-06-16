// Test entry for file syscalls: a U-mode user program writes a file and reads it
// back, entirely through ecalls (open/write/close/read). The user-mode trap path +
// privilege drop come from usermode_runtime.c; the VFS-backed syscall table from
// the MC fs_syscall_demo.
#include <stdint.h>
#include <stddef.h>

#define SYS_PUTC 2ULL
#define SYS_EXIT 3ULL
#define SYS_OPEN 5ULL
#define SYS_FWRITE 6ULL
#define SYS_FREAD 7ULL
#define SYS_FCLOSE 8ULL

void puts_(const char *s);
void mc_halt(void);
void usermode_setup(void);
void enter_user(uintptr_t entry, uintptr_t user_sp);
uint64_t do_ecall(uint64_t number, uint64_t arg0, uint64_t arg1, uint64_t arg2);

static const char fname[1] = {'f'};
static const char content[2] = {'H', 'I'};
__attribute__((aligned(16))) static uint8_t user_stack[8192];

// Runs in U-mode; touches the filesystem only through syscalls.
__attribute__((used)) static void user_main(void) {
    uint64_t fd = do_ecall(SYS_OPEN, (uintptr_t)fname, 1, 0);
    do_ecall(SYS_FWRITE, fd, (uintptr_t)content, 2);
    do_ecall(SYS_FCLOSE, fd, 0, 0);

    uint64_t rfd = do_ecall(SYS_OPEN, (uintptr_t)fname, 1, 0); // fresh fd at pos 0
    char buf[8];
    uint64_t n = do_ecall(SYS_FREAD, rfd, (uintptr_t)buf, 8);

    do_ecall(SYS_PUTC, (uint64_t)'F', 0, 0); // marker, then the bytes read back
    for (uint64_t i = 0; i < n; i++) do_ecall(SYS_PUTC, (uint64_t)(uint8_t)buf[i], 0, 0);
    do_ecall(SYS_EXIT, 0, 0, 0);
    for (;;) {
    }
}

__attribute__((used)) void test_main(void) {
    puts_("fs-syscall booting\n");
    usermode_setup();
    puts_("entering user\n");
    enter_user((uintptr_t)&user_main, (uintptr_t)(user_stack + sizeof(user_stack)));
    mc_halt(); // not reached
}
