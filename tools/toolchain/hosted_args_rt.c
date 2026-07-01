/* hosted_args_rt: the C runtime shim that gives a hosted MC program its argv.
 *
 * MC emits a nullary, freestanding entry, so a hosted MC program cannot see the
 * process argument vector on its own. This shim owns the real C `main(argc,
 * argv)`: it stashes the vector in file-static storage, then calls the MC entry
 * point `mc_main` (which a program exports via `export fn mc_main() -> i32`). The
 * process exit code is `mc_main`'s return value.
 *
 * The three `mc_*` accessors are the machine contract behind `std/hosted_args.mc`:
 *   mc_argc()      -> argument count (== C `argc`, includes argv[0])
 *   mc_argv(i)     -> address of argument i as an integer (0 if out of range)
 *   mc_arg_len(i)  -> strlen of argument i          (0 if out of range)
 *
 * Link it with the object emitted from the MC program, e.g.:
 *   tools/toolchain/mcc-cc.sh prog.mc -o prog.o
 *   clang prog.o tools/toolchain/hosted_args_rt.c -o prog
 *   ./prog arg1 arg2
 */
#include <stddef.h>
#include <stdint.h>
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

/* Provided by the MC program: `export fn mc_main() -> i32`. */
extern int32_t mc_main(void);

int main(int argc, char **argv) {
    g_argc = argc;
    g_argv = argv;
    return (int)mc_main();
}
