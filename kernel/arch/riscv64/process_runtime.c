// Test entry for the process-lifecycle demo (tests/qemu/process_demo.mc). The
// context-switch primitive, thread priming, UART, and _start come from
// context_runtime.c. This supplies the physical region the kernel heap carves
// process stacks from.
#include <stdint.h>

void putc_(char c);
void puts_(const char *s);
void mc_halt(void);

uint32_t process_demo(uintptr_t region_base, uintptr_t region_len);

__attribute__((aligned(4096))) static uint8_t heap_region[256 * 1024];

__attribute__((used)) void test_main(void) {
    puts_("process booting\n");
    uint32_t sum = process_demo((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region));
    puts_("\nPROC-OK ");
    putc_((char)('0' + (sum % 10)));
    putc_('\n');
    mc_halt();
}
