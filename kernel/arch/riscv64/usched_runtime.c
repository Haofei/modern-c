#include <stdint.h>
#include <stddef.h>
void putc_(char c); void puts_(const char *s); void mc_halt(void);
uint32_t usched_run(uintptr_t region_base, uintptr_t region_len);
__attribute__((aligned(4096))) static uint8_t heap_region[256 * 1024];
__attribute__((used)) void test_main(void) {
    puts_("usched booting\n");
    if (usched_run((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region)) == 1) puts_("USCHED-OK\n"); else puts_("USCHED-BAD\n");
    mc_halt();
}
