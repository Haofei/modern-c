// examples/apps/wasm/wasi_hello.c — the Phase-1 guest: a STOCK wasm32-wasi program, built by an
// off-the-shelf toolchain (`zig cc -target wasm32-wasi`, which links zig's wasi-libc) and run
// UNMODIFIED by the WAMR host + WASI shim. The point of Phase 1 is exactly that a normal C
// program using libc `printf` (which wasi-libc lowers to fd_fdstat_get/fd_write/fd_seek/fd_close
// + proc_exit imports) runs as-is — no MC-specific guest code. See docs/wasm-migration-plan.md
// Phase 1, gate wasm-wasi-hello-test (mirrors qjs-confined-test).

#include <stdio.h>

int main(void) {
    printf("WASI-HELLO=ok\n");
    return 0;
}
