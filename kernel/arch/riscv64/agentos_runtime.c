// Boot entry for the agent-OS governance demo (tests/qemu/proc/agentos_demo.mc). The
// context-switch primitives, UART, mc_halt, and _start come from context_runtime.c; this
// supplies the physical region the kernel carves the heap from, calls agentos_main, and
// reports the stage bitmask. Prints AGENTOS-OK when the full keystone passed.
#include <stdint.h>
#include <stddef.h>

void putc_(char c);
void puts_(const char *s);
void mc_halt(void);

uint32_t agentos_main(uintptr_t region_base, uintptr_t region_len);

__attribute__((aligned(4096))) static uint8_t heap_region[256 * 1024];

__attribute__((used)) void test_main(void) {
    puts_("\nagentos boot (governance keystone)\n");
    uint32_t stages = agentos_main((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region));
    puts_("\nstages=0x");
    putc_("0123456789abcdef"[(stages >> 4) & 0xf]);
    putc_("0123456789abcdef"[stages & 0xf]);
    putc_('\n');
    if (stages == 0x7) puts_("AGENTOS-OK\n"); // heap + console up and the keystone fully passed
    else puts_("AGENTOS-INCOMPLETE\n");
    mc_halt();
}
