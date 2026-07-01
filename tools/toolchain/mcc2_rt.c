/* mcc2_rt: the C runtime shim for the standalone `mcc2` CLI (selfhost/main.mc).
 *
 * It provides everything the hosted `mcc2` program needs from the C side:
 *   - the real `main(argc, argv)`, which stashes the argument vector and then calls
 *     the MC entry point `mc_main` (std/hosted_args contract); the process exit code
 *     is `mc_main`'s return value;
 *   - the three `mc_*` argv accessors behind std/hosted_args.mc;
 *   - `mc_malloc`/`mc_free` over libc, the allocator selfhost/main.mc threads into the
 *     parser arena + emit buffer.
 *
 * Link it with the object emitted from selfhost/main.mc, e.g.:
 *   tools/toolchain/mcc-cc.sh --profile=hosted selfhost/main.mc -o main.o
 *   clang main.o tools/toolchain/mcc2_rt.c -o mcc2
 *   ./mcc2 input.mc > out.c
 */
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static int    g_argc = 0;
static char **g_argv = NULL;

int32_t mc_argc(void) {
    return (int32_t)g_argc;
}

size_t mc_argv(int32_t i) {
    if (i < 0 || i >= g_argc) {
        return 0;
    }
    return (size_t)(uintptr_t)g_argv[i];
}

size_t mc_arg_len(int32_t i) {
    if (i < 0 || i >= g_argc) {
        return 0;
    }
    return strlen(g_argv[i]);
}

size_t mc_malloc(size_t n) {
    return (size_t)(uintptr_t)malloc(n);
}

void mc_free(size_t a, size_t n) {
    (void)n;
    free((void *)(uintptr_t)a);
}

/* Provided by the MC program: `export fn mc_main() -> i32`. */
extern int32_t mc_main(void);

int main(int argc, char **argv) {
    g_argc = argc;
    g_argv = argv;
    return (int)mc_main();
}
