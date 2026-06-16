// Test entry for the microkernel IPC demo (tests/qemu/ipc_demo.mc). Context-switch,
// UART, mc_halt, and _start come from context_runtime.c; this supplies the physical
// region the kernel heap carves process stacks from, and reports the round-trip result.
#include <stdint.h>
#include <stddef.h>

void putc_(char c);
void puts_(const char *s);
void mc_halt(void);

uint32_t ipc_demo(uintptr_t region_base, uintptr_t region_len);

__attribute__((aligned(4096))) static uint8_t heap_region[256 * 1024];

__attribute__((used)) void test_main(void) {
    puts_("ipc booting\n");
    uint32_t r = ipc_demo((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region));
    puts_("\nresult=");
    putc_((char)('0' + (r / 10) % 10));
    putc_((char)('0' + r % 10));
    putc_('\n');
    if (r == 42) puts_("IPC-OK\n");
    else puts_("IPC-FAIL\n");
    mc_halt();
}
