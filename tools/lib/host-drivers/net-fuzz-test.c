#include <stdint.h>
#include <stdio.h>
extern void     fuzz_init(void);
extern uint32_t fuzz_random(uint32_t seed, uintptr_t len);
extern uint32_t fuzz_udp(uint32_t seed, uintptr_t len);
int main(void) {
    fuzz_init();
    uint64_t ok = 0, err = 0, total = 0;
    for (uint32_t s = 1; s <= 20000; s++) {
        uintptr_t rlen = (uintptr_t)(s % 120);          // 0..119, incl. < and > 42
        if (fuzz_random(s, rlen) == 0) ok++; else err++; total++;
        uintptr_t ulen = (uintptr_t)(42 + (s % 80));     // 42..121, full-parse path
        if (fuzz_udp(s * 2654435761u + 1u, ulen) == 0) ok++; else err++; total++;
    }
    // Completing 40000 parses without an OOB trap is the property. Both paths must hit.
    if (total == 40000 && err > 0 && ok > 0) {
        printf("fuzz: %llu parses, %llu ok, %llu rejected\n",
               (unsigned long long)total, (unsigned long long)ok, (unsigned long long)err);
        return 0;
    }
    return 1;
}
