// Test entry for the driver-framework demo (tests/qemu/driver_demo.mc). UART,
// mc_halt, and _start come from context_runtime.c; the demo writes "DRV" to the
// console through the registered char-device driver.
#include <stdint.h>
#include <stddef.h>

void putc_(char c);
void puts_(const char *s);
void mc_halt(void);

uint32_t driver_demo(void);

__attribute__((used)) void test_main(void) {
    puts_("driver booting\n");
    uint32_t id = driver_demo(); // writes "DRV" through the registered driver
    puts_("\nDRIVER-OK ");
    putc_((char)('0' + (id % 10)));
    putc_('\n');
    mc_halt();
}
