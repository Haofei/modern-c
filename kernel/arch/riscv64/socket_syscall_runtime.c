// Test entry for socket syscalls: a U-mode program calls recvfrom and prints the
// datagram the kernel pre-delivered to its socket. User-mode trap path + privilege
// drop come from usermode_runtime.c; the socket-backed syscall table from the MC
// socket_syscall_demo.
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

#define SYS_PUTC 2ULL
#define SYS_EXIT 3ULL
#define SYS_RECVFROM 9ULL

void puts_(const char *s);
void mc_halt(void);
void usermode_setup(void);
void enter_user(uintptr_t entry, uintptr_t user_sp);
uint64_t do_ecall(uint64_t number, uint64_t arg0, uint64_t arg1, uint64_t arg2);

__attribute__((aligned(16))) static uint8_t user_stack[8192];

__attribute__((used)) static void user_main(void) {
    char buf[16];
    for (int i = 0; i < 16; i++) buf[i] = 0;
    uint64_t n = do_ecall(SYS_RECVFROM, 0, (uintptr_t)buf, 16); // socket 0

    do_ecall(SYS_PUTC, (uint64_t)'R', 0, 0); // marker, then the received bytes
    for (uint64_t i = 0; i < n; i++) do_ecall(SYS_PUTC, (uint64_t)(uint8_t)buf[i], 0, 0);
    do_ecall(SYS_EXIT, 0, 0, 0);
    for (;;) {
    }
}

__attribute__((used)) void test_main(void) {
    puts_("socket-syscall booting\n");
    usermode_setup();
    puts_("entering user\n");
    enter_user((uintptr_t)&user_main, (uintptr_t)(user_stack + sizeof(user_stack)));
    mc_halt();
}
