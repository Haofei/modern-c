// user/runtime/usys.h — C syscall wrappers for a confined C app (QuickJS and its libc are C).
// Thin inline wrappers over mc_ecall (user/runtime/crt0.c); the ABI numbers mirror user/abi.mc.
#ifndef MC_USYS_H
#define MC_USYS_H
#include <stdint.h>
#include <stddef.h>

uint64_t mc_ecall(uint64_t number, uint64_t a0, uint64_t a1, uint64_t a2);

#define SYS_WRITE 0u
#define SYS_GETPID 2u
#define SYS_EXIT 3u
#define FD_STDOUT 1u

// write(fd, buf, len) -> bytes written (>=0) or negative -errno.
static inline long sys_write(uint64_t fd, const void *buf, size_t len) {
    return (long)mc_ecall(SYS_WRITE, fd, (uint64_t)(uintptr_t)buf, (uint64_t)len);
}
static inline long sys_print(const void *buf, size_t len) {
    return sys_write(FD_STDOUT, buf, len);
}
static inline uint64_t sys_getpid(void) {
    return mc_ecall(SYS_GETPID, 0, 0, 0);
}
static inline void sys_exit(uint64_t code) {
    mc_ecall(SYS_EXIT, code, 0, 0);
    for (;;) {
    }
}

#endif
