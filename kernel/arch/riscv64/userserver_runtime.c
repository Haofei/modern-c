// Test entry for the U-mode server (tests/qemu/userserver_demo.mc). The server runs in
// user mode and reaches the kernel only through ecalls; usermode_setup wires the trap +
// the MC syscall table, then we enter the server loop.
#include <stdint.h>
#include <stddef.h>

#define SYS_RECV 5ULL
#define SYS_REPLY 6ULL
#define SYS_VERIFY 7ULL
#define SYS_EXIT 3ULL
#define DONE 0xFFFFFFFFFFFFFFFFULL

void puts_(const char *s);
void mc_halt(void);
void usermode_setup(void);
void enter_user(uintptr_t entry, uintptr_t user_sp);
uint64_t do_ecall(uint64_t number, uint64_t a0, uint64_t a1, uint64_t a2);

__attribute__((aligned(16))) static uint8_t user_stack[8192];

// Runs in U-mode: pull requests, reply doubled, then ask the kernel to verify + exit.
__attribute__((used)) static void server_main(void) {
    for (;;) {
        uint64_t r = do_ecall(SYS_RECV, 0, 0, 0);
        if (r == DONE) break;
        do_ecall(SYS_REPLY, r * 2, 0, 0);
    }
    do_ecall(SYS_VERIFY, 0, 0, 0);
    do_ecall(SYS_EXIT, 0, 0, 0);
    for (;;) {}
}

__attribute__((used)) void test_main(void) {
    puts_("userserver booting\n");
    usermode_setup(); // installs trap vector, PMP, and the MC syscall table
    puts_("kernel: entering U-mode server\n");
    enter_user((uintptr_t)&server_main, (uintptr_t)(user_stack + sizeof(user_stack)));
    mc_halt();
}
