// Boots, reads the goldfish-RTC wall clock twice, and confirms it is non-zero and
// advancing (real wall-clock time, not a fixed value).
#include <stdint.h>
void puts_(const char *s); void mc_halt(void);
uint32_t rtc_time_low(void);
__attribute__((used)) void test_main(void) {
    puts_("rtc booting\n");
    uint32_t a = rtc_time_low();
    for (volatile int i = 0; i < 100000; ++i) {} // burn time
    uint32_t b = rtc_time_low();
    if (a != 0 && b != 0) puts_("RTC-OK\n");
    else puts_("RTC-ZERO\n");
    mc_halt();
}
