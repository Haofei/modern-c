// Host driver for std/time wrap-correct timeout arithmetic (§28.4).
//
// std/time's tick source and busy-wait are platform primitives; the wrappers under
// test (t_elapsed / t_timed_out) are pure wrap<u64> arithmetic and never call them,
// but read_ticks/poll_until/udelay are emitted into the object and must resolve, so
// they are stubbed here. The interesting property is wrap-correctness: when the tick
// counter rolls past u64 max between two reads, the elapsed difference must still be
// the true (small) magnitude, and the timeout decision (>=) must follow it.
#include <stdint.h>
#include <stdio.h>

uint64_t mc_read_ticks(void) { return 0; }
void mc_udelay(uint32_t us) { (void)us; }

extern uint64_t t_elapsed(uint64_t start, uint64_t now);
extern uint32_t t_timed_out(uint64_t start, uint64_t now, uint64_t limit);

int main(void) {
    // Plain forward interval.
    if (t_elapsed(100, 250) != 150) { printf("FAIL: forward elapsed\n"); return 1; }
    // Wrap-around: 0x0F - 0xFFFF...F0 (mod 2^64) = 0x1F, not a huge bogus span.
    if (t_elapsed(0xFFFFFFFFFFFFFFF0ULL, 0x0FULL) != 0x1FULL) { printf("FAIL: wrap-around elapsed\n"); return 2; }
    // timed_out is >= : elapsed == limit times out; one tick short does not.
    if (!t_timed_out(0, 100, 100)) { printf("FAIL: boundary should time out\n"); return 3; }
    if (t_timed_out(0, 99, 100))   { printf("FAIL: under-limit should not time out\n"); return 4; }
    // Wrap-around timeout follows the wrap-correct elapsed (0x1F): >= 0x10 yes, >= 0x20 no.
    if (!t_timed_out(0xFFFFFFFFFFFFFFF0ULL, 0x0FULL, 0x10ULL)) { printf("FAIL: wrap timeout should fire\n"); return 5; }
    if (t_timed_out(0xFFFFFFFFFFFFFFF0ULL, 0x0FULL, 0x20ULL))  { printf("FAIL: wrap timeout fired early\n"); return 6; }
    printf("time wrap-arithmetic: forward + wrap-around elapsed and timeout decisions all correct\n");
    return 0;
}
