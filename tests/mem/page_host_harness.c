/* C harness for tests/mem/page_host_driver.mc (see tools/lib/host-mc-logic-test.sh).
   Mirrors no MC type: it only passes the pool's raw base/length (plain words) and reads
   back a u32 result code; the whole test runs in MC. */
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

extern uint32_t page_host_test(uintptr_t pool_start, uintptr_t pool_len);

#define PAGE 4096u
static uint8_t pool[16 * PAGE] __attribute__((aligned(PAGE)));

int main(void) {
    return (int)page_host_test((uintptr_t)pool, sizeof(pool));
}
