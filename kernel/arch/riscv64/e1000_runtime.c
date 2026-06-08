// Boots, then probes the PCI bus for the real Intel e1000 NIC (added via -device e1000).
#include <stdint.h>
void puts_(const char *s); void mc_halt(void);
uint32_t e1000_run(void);
__attribute__((used)) void test_main(void) {
    puts_("e1000 probe booting\n");
    if (e1000_run() == 1) puts_("E1000-OK\n");
    else puts_("E1000-ABSENT\n");
    mc_halt();
}
