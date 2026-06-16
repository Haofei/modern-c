// Test entry for the reincarnation demo (tests/qemu/restart_demo.mc). The server
// crashes once ('X'); the supervisor restarts it ('R'); the system recovers.
#include <stdint.h>
#include <stddef.h>

void putc_(char c);
void puts_(const char *s);
void mc_halt(void);
uint32_t restart_demo(uintptr_t region_base, uintptr_t region_len);
__attribute__((aligned(4096))) static uint8_t heap_region[256 * 1024];
__attribute__((used)) void test_main(void) {
    puts_("restart booting\n[");
    uint32_t restarts = restart_demo((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region));
    puts_("]\nrestarts=");
    putc_((char)('0' + restarts % 10));
    putc_('\n');
    if (restarts == 1) puts_("RESTART-OK\n");
    else puts_("RESTART-FAIL\n");
    mc_halt();
}
