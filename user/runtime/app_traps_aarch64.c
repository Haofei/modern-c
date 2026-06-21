// user/runtime/app_traps_aarch64.c — the AArch64 sibling of user/runtime/app_traps_x86.c.
//
// The confined EL0 agent's handlers for MC's checked-arithmetic trap edges (overflow, bounds,
// null-unwrap, ...). In a confined agent there is nothing to recover: a tripped check means the
// agent hit undefined behavior, so we exit nonzero via SYS_EXIT — the kernel reclaims the agent.
// Identical in SHAPE to app_traps_x86.c; only the ecall asm is AArch64 (x8 = number, x0 = arg0,
// `svc #0`, matching the M8/M9 kernel SVC dispatcher).
//
// Weak, so the LLVM backend's support object (which also defines them) composes without a clash.
// The all-MC libc references these; they are platform glue, not libc.
#include <stdint.h>

// stdio stream objects: QuickJS passes these to fprintf, which (in the all-MC stdio.mc) ignores
// the stream. Platform symbols, like the syscall hooks — never dereferenced.
void *stdout = 0;
void *stderr = 0;
void *stdin = 0;

#define SYS_EXIT 3

__attribute__((noreturn)) static void trap_exit(void) {
    register uint64_t x8 asm("x8") = SYS_EXIT;
    register uint64_t x0 asm("x0") = 99; // nonzero: a checked edge tripped
    __asm__ volatile("svc #0" : : "r"(x8), "r"(x0) : "memory");
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
