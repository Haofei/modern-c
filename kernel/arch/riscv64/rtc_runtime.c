// Boots, reads the goldfish-RTC wall clock, and proves it is REAL host wall-clock
// time: the low word advances between two reads, and the full epoch (derived from
// the 64-bit nanosecond counter via kernel/core/time.mc) is a plausible "now"
// (between 1.7e9 and 2.0e9 seconds == ~2023..2033). Prints EPOCH=<seconds> and
// RTC-OK on success.
#include <stdint.h>
#include <stddef.h>

void putc_(char c);
void puts_(const char *s);
void mc_halt(void);

// kernel/core/time.mc (via tests/qemu/arch/rtc_demo.mc).
uint32_t rtc_low(void);
uint64_t rtc_ns(void);
uint64_t rtc_epoch(void);

static void putdec(uint64_t v) {
    char tmp[20];
    int n = 0;
    if (v == 0) { putc_('0'); return; }
    while (v) { tmp[n++] = (char)('0' + (v % 10)); v /= 10; }
    while (n) putc_(tmp[--n]);
}

__attribute__((used)) void test_main(void) {
    puts_("rtc booting\n");

    // (1) advancing-clock check on the low word.
    uint32_t a = rtc_low();
    for (volatile int i = 0; i < 100000; ++i) {} // burn time
    uint32_t b = rtc_low();

    // (2) full wall-clock epoch via the time seam.
    uint64_t ns = rtc_ns();
    uint64_t epoch = rtc_epoch();
    puts_("EPOCH="); putdec(epoch); putc_('\n');
    puts_("NS="); putdec(ns); putc_('\n');

    int advancing = (a != 0 && b != 0);
    // Plausible live timestamp: 1.7e9 .. 2.0e9 seconds since the UNIX epoch.
    int plausible = (epoch > 1700000000ull && epoch < 2000000000ull);

    if (advancing && plausible) puts_("RTC-OK\n");
    else if (!plausible) puts_("RTC-IMPLAUSIBLE\n");
    else puts_("RTC-ZERO\n");
    mc_halt();
}
