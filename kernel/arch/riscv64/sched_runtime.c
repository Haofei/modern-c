// Test entry for the round-robin scheduler demo (tests/qemu/sched_demo.mc). The
// context-switch primitive + bring-up live in context_runtime.c. This supplies the
// physical memory region the kernel heap carves thread stacks from.
#include <stdint.h>

void putc_(char c);
void puts_(const char *s);
void mc_halt(void);

// Backing store for the kernel heap (the scheduler allocates thread stacks here).
__attribute__((aligned(4096))) static uint8_t heap_region[256 * 1024];

uint32_t sched_demo(uintptr_t region_base, uintptr_t region_len);

__attribute__((used)) void test_main(void) {
    puts_("scheduler booting\n");
    uint32_t rounds = sched_demo((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region));
    puts_("\nSCHED-OK ");
    putc_((char)('0' + (rounds % 10)));
    putc_('\n');
    mc_halt();
}
