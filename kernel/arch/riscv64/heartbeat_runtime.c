#include <stdint.h>
#include <stddef.h>
void putc_(char c); void puts_(const char *s); void mc_halt(void);
uint32_t heartbeat_demo(uintptr_t region_base, uintptr_t region_len);
__attribute__((aligned(4096))) static uint8_t heap_region[256 * 1024];
__attribute__((used)) void test_main(void) {
    puts_("heartbeat booting\n");
    if (heartbeat_demo((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region)) == 1) puts_("HB-OK\n"); else puts_("HB-FAIL\n");
    mc_halt();
}
