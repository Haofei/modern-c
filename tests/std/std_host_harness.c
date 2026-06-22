/* C harness for tests/std/std_host_driver.mc (see tools/lib/host-mc-logic-test.sh).
   Mirrors no MC type (the U32Decimal/PhysRange checks live in MC): just the trap stubs
   and main() calling the MC entry. Shared by std-test (C) and llvm-std-test (LLVM). */
#include <stdint.h>

void mc_trap_Assert(void) { __builtin_trap(); }
void mc_trap_Bounds(void) { __builtin_trap(); }
void mc_trap_DivideByZero(void) { __builtin_trap(); }
void mc_trap_IntegerOverflow(void) { __builtin_trap(); }
void mc_trap_InvalidRepresentation(void) { __builtin_trap(); }
void mc_trap_InvalidShift(void) { __builtin_trap(); }
void mc_trap_NullUnwrap(void) { __builtin_trap(); }
void mc_trap_Unreachable(void) { __builtin_trap(); }

extern uint32_t std_host_test(void);

int main(void) {
    return (int)std_host_test(); /* 0 = all checks passed; nonzero = first failed check id */
}
