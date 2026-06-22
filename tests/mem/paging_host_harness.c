/* C harness for tests/mem/paging_host_driver.mc (see tools/lib/host-mc-logic-test.sh).
   Mirrors no MC type: it supplies trap/ksan stubs and a page-aligned pool, then calls the
   MC entry which builds the page table and runs every check entirely in MC. */
#include <stdint.h>

void mc_trap_Assert(void) { __builtin_trap(); }
void mc_trap_Bounds(void) { __builtin_trap(); }
void mc_trap_DivideByZero(void) { __builtin_trap(); }
void mc_trap_IntegerOverflow(void) { __builtin_trap(); }
void mc_trap_InvalidRepresentation(void) { __builtin_trap(); }
void mc_trap_InvalidShift(void) { __builtin_trap(); }
void mc_trap_NullUnwrap(void) { __builtin_trap(); }
void mc_trap_Unreachable(void) { __builtin_trap(); }

/* KASAN shadow hooks: referenced by the heap's (never-taken) ksan branch in a default
   non-ksan heap, so they must link but are never called here. */
void mc_ksan_poison(uintptr_t addr, uintptr_t size) { (void)addr; (void)size; }
void mc_ksan_unpoison(uintptr_t addr, uintptr_t size) { (void)addr; (void)size; }

extern uint32_t paging_host_test(uintptr_t pool_start, uintptr_t pool_len);

/* A page-aligned pool standing in for the physical region the page table carves its
   table frames from. 64 pages is ample for the handful of interior tables the checks
   build. */
static uint8_t pool[64 * 4096] __attribute__((aligned(4096)));

int main(void) {
    uint32_t rc = paging_host_test((uintptr_t)pool, sizeof(pool));
    return (int)rc; /* 0 = all checks passed; nonzero = id of the first failed check */
}
