/* C harness for tests/mem/heap_host_driver.mc (see tools/lib/host-mc-logic-test.sh).
   Mirrors NO MC struct: it only supplies the trap/ksan stubs the heap references, a pool,
   and main() calling the MC entry, which builds and asserts the heap entirely in MC. */
#include <stdint.h>
#include <stddef.h>

void mc_trap_Assert(void) { __builtin_trap(); }
void mc_trap_Bounds(void) { __builtin_trap(); }
void mc_trap_DivideByZero(void) { __builtin_trap(); }
void mc_trap_IntegerOverflow(void) { __builtin_trap(); }
void mc_trap_InvalidRepresentation(void) { __builtin_trap(); }
void mc_trap_InvalidShift(void) { __builtin_trap(); }
void mc_trap_NullUnwrap(void) { __builtin_trap(); }
void mc_trap_Unreachable(void) { __builtin_trap(); }

/* Referenced only by heap.mc's never-taken ksan branch (default heap has ksan==0). */
void mc_ksan_poison(uintptr_t addr, uintptr_t size) { (void)addr; (void)size; }
void mc_ksan_unpoison(uintptr_t addr, uintptr_t size) { (void)addr; (void)size; }

extern uint32_t heap_host_test(uintptr_t pool_start, uintptr_t pool_len);

static uint8_t pool[8192] __attribute__((aligned(4096)));

int main(void) {
    return (int)heap_host_test((uintptr_t)pool, sizeof(pool));
}
