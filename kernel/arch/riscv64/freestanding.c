// Shared freestanding libc for the bare-metal riscv64 kernel images.
//
// Every QEMU kernel image is linked against this single object (see
// kernel_boot_compile_rt in tools/qemu/kernel-boot-lib.sh). It supplies the
// handful of mem*/str* symbols the freestanding link needs: the backends emit
// calls to memset/memcpy/memmove for aggregate init/copy, and the BearSSL TLS
// runtimes additionally reference memcmp/strlen.
//
// History: these definitions used to be copy-pasted into ~57 per-image runtime
// .c files. Struct growth twice made an image emit a memset/memcpy the local
// copy did not cover, producing a link/emit failure. Consolidating to one
// object retires that bug class -- add a symbol here once and every image gets it.
//
// Built with -ffreestanding -fno-builtin (see CFLAGS in the test scripts) so the
// compiler will not rewrite these loops into calls to themselves.
#include <stdint.h>
#include <stddef.h>

void *memset(void *d, int c, size_t n) {
    uint8_t *p = (uint8_t *)d;
    for (size_t i = 0; i < n; ++i) p[i] = (uint8_t)c;
    return d;
}

void *memcpy(void *d, const void *s, size_t n) {
    uint8_t *dp = (uint8_t *)d;
    const uint8_t *sp = (const uint8_t *)s;
    for (size_t i = 0; i < n; ++i) dp[i] = sp[i];
    return d;
}

void *memmove(void *d, const void *s, size_t n) {
    uint8_t *dp = (uint8_t *)d;
    const uint8_t *sp = (const uint8_t *)s;
    if (dp == sp || n == 0) return d;
    if (dp < sp) {
        for (size_t i = 0; i < n; ++i) dp[i] = sp[i];
    } else {
        for (size_t i = n; i != 0; --i) dp[i - 1] = sp[i - 1];
    }
    return d;
}

int memcmp(const void *a, const void *b, size_t n) {
    const uint8_t *pa = (const uint8_t *)a;
    const uint8_t *pb = (const uint8_t *)b;
    for (size_t i = 0; i < n; ++i) {
        if (pa[i] != pb[i]) return (int)pa[i] - (int)pb[i];
    }
    return 0;
}

size_t strlen(const char *s) {
    const char *p = s;
    while (*p) ++p;
    return (size_t)(p - s);
}
