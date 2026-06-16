// Test entry for the IPC-completeness demo (multi-slot + source filter + notify).
#include <stdint.h>
#include <stddef.h>
void putc_(char c);
void puts_(const char *s);
void mc_halt(void);
uint32_t ipc2_demo(uintptr_t region_base, uintptr_t region_len);
__attribute__((aligned(4096))) static uint8_t heap_region[256 * 1024];
__attribute__((used)) void test_main(void) {
    puts_("ipc2 booting\n");
    uint32_t ok = ipc2_demo((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region));
    if (ok == 1) puts_("IPC2-OK\n");
    else puts_("IPC2-FAIL\n");
    mc_halt();
}
