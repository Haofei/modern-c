// examples/apps/wasm/hello.c — the Phase-0 guest module for wasm-run-test.
//
// A minimal, REAL wasm32 module: compiled by `clang --target=wasm32` + `wasm-ld` (not hand-
// assembled bytes), it imports the two WASI-shaped functions the host links — fd_write and
// proc_exit — and prints a fixed marker, then exits clean. This proves a genuine .wasm runs
// end-to-end on the freestanding wasm3 engine behind the kernel's narrow syscall ABI.
//
// The import names mirror WASI Preview 1 deliberately: Phase 1 swaps this hand-built guest for
// an off-the-shelf `wasm32-wasi` toolchain output against the same fd_write/proc_exit imports.
//
// Build: clang --target=wasm32 -nostdlib -O2 \
//          -Wl,--no-entry -Wl,--export=_start -Wl,--allow-undefined hello.c -o hello.wasm

#include <stddef.h>
#include <stdint.h>

#define WASI "wasi_snapshot_preview1"

// fd_write(fd, *iovs, iovs_len, *nwritten) -> errno  (WASI Preview 1 shape).
__attribute__((import_module(WASI), import_name("fd_write")))
extern int32_t fd_write(int32_t fd, const void *iovs, int32_t iovs_len, int32_t *nwritten);

// proc_exit(code) -> noreturn.
__attribute__((import_module(WASI), import_name("proc_exit"), noreturn))
extern void proc_exit(int32_t code);

// WASI ciovec: a (buf, len) pair where buf is an offset into the module's linear memory.
typedef struct {
    uint32_t buf;
    uint32_t len;
} ciovec_t;

static const char msg[] = "WASM=ok\n";

__attribute__((export_name("_start")))
void _start(void) {
    static ciovec_t iov;
    // In wasm32 a data pointer IS its linear-memory offset, so this cast is the offset the host
    // resolves against the instance memory.
    iov.buf = (uint32_t)(uintptr_t)msg;
    iov.len = (uint32_t)(sizeof(msg) - 1);

    int32_t nwritten = 0;
    fd_write(1, &iov, 1, &nwritten);
    proc_exit(0);
}
