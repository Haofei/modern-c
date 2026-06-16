/* Minimal freestanding <string.h> shim for building BearSSL into the bare-metal
   MC kernel. The hosted clang's <string.h> is unavailable under
   --target=riscv64-unknown-elf -ffreestanding -nostdlib, but BearSSL only needs a
   handful of declarations. The definitions are provided by the kernel runtime
   (bearssl_smoke_runtime.c: memcpy/memmove/memset/strlen). This header only
   DECLARES them; it pulls in no OS. */
#ifndef MC_BEARSSL_FREESTANDING_STRING_H
#define MC_BEARSSL_FREESTANDING_STRING_H

#include <stddef.h>

void *memcpy(void *dst, const void *src, size_t n);
void *memmove(void *dst, const void *src, size_t n);
void *memset(void *dst, int c, size_t n);
int memcmp(const void *a, const void *b, size_t n);
size_t strlen(const char *s);

#endif /* MC_BEARSSL_FREESTANDING_STRING_H */
