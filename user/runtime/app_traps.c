// user/runtime/app_traps.c — the confined app's handlers for MC's checked-arithmetic trap edges
// (overflow, bounds, null-unwrap, ...). In a confined U-mode agent there is nothing to recover:
// a tripped check means the agent hit undefined behavior, so we exit nonzero via SYS_EXIT — the
// kernel reclaims the agent. Weak, so the LLVM backend's support object (which also defines them)
// composes without a clash. The all-MC libc references these; they are platform glue, not libc.
#include <stdint.h>

// stdio stream objects: QuickJS passes these to fprintf, which (in the all-MC stdio.mc) ignores
// the stream. Platform symbols, like the syscall hooks — never dereferenced.
void *stdout = 0;
void *stderr = 0;
void *stdin = 0;

#define SYS_EXIT 3

__attribute__((noreturn)) static void trap_exit(void) {
    register uint64_t a7 asm("a7") = SYS_EXIT;
    register uint64_t a0 asm("a0") = 99; // nonzero: a checked edge tripped
    asm volatile("ecall" : : "r"(a7), "r"(a0) : "memory");
    for (;;) {
    }
}

__attribute__((weak, noreturn)) void mc_trap_IntegerOverflow(void) { trap_exit(); }
__attribute__((weak, noreturn)) void mc_trap_Bounds(void) { trap_exit(); }
__attribute__((weak, noreturn)) void mc_trap_DivideByZero(void) { trap_exit(); }
__attribute__((weak, noreturn)) void mc_trap_InvalidShift(void) { trap_exit(); }
__attribute__((weak, noreturn)) void mc_trap_InvalidRepresentation(void) { trap_exit(); }
__attribute__((weak, noreturn)) void mc_trap_Assert(void) { trap_exit(); }
__attribute__((weak, noreturn)) void mc_trap_NullUnwrap(void) { trap_exit(); }
__attribute__((weak, noreturn)) void mc_trap_Unreachable(void) { trap_exit(); }
