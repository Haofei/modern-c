// Test entry for the capability/driver-server demo (tests/qemu/cap_demo.mc). The
// console server writes "HI" to the UART via its capability; the client only sends IPC.
#include <stdint.h>
void putc_(char c);
void puts_(const char *s);
void mc_halt(void);
uint32_t cap_demo(uintptr_t region_base, uintptr_t region_len);
__attribute__((aligned(4096))) static uint8_t heap_region[256 * 1024];
__attribute__((used)) void test_main(void) {
    puts_("cap booting\n[");
    uint32_t reaped = cap_demo((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region));
    puts_("]\nreaped=");
    putc_((char)('0' + reaped % 10));
    putc_('\n');
    if (reaped == 2) puts_("CAP-OK\n");
    else puts_("CAP-FAIL\n");
    mc_halt();
}
