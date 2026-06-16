// Test entry for the cooperative ping-pong demo (tests/qemu/thread_demo.mc). The
// context-switch primitive + bring-up live in context_runtime.c.
#include <stdint.h>
#include <stddef.h>

void putc_(char c);
void puts_(const char *s);
void mc_halt(void);

// One worker stack for the single-worker ping-pong. The scheduler demo allocates
// per-thread stacks from the kernel heap instead.
__attribute__((aligned(16))) static uint8_t worker_stack[8192];

uint32_t thread_demo(uintptr_t worker_stack_top);

__attribute__((used)) void test_main(void) {
    puts_("threads booting\n");
    uint32_t rounds = thread_demo((uintptr_t)(worker_stack + sizeof(worker_stack)));
    puts_("\nTHREADS-OK ");
    putc_((char)('0' + (rounds % 10)));
    putc_('\n');
    mc_halt();
}
