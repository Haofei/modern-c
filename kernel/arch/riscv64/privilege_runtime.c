#include <stdint.h>
#include <stddef.h>
void putc_(char c); void puts_(const char *s); void mc_halt(void);
uint32_t privilege_demo(void);
__attribute__((used)) void test_main(void) {
    puts_("privilege booting\n");
    if (privilege_demo() == 1) puts_("PRIV-OK\n"); else puts_("PRIV-FAIL\n");
    mc_halt();
}
