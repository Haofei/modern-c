#include <stdint.h>
#include <stdio.h>

// P6 bundle/OTA admission fuzz oracle — drive kernel/core/production_ops.mc's update-admission
// surface over adversarial headers + random op sequences and prove totality (no trap, fail-closed).
//
// The exported fuzz_* fns (tests/qemu/proc/bundle_fuzz_demo.mc) each RETURN a typed outcome; a trap
// (checked-arith underflow / OOB) would abort THIS process (SIGABRT) before we print success, so
// completing every iteration and printing is the proof of totality. DETERMINISTIC: fixed seeds, no
// RNG here and none in the fixture beyond a seeded xorshift — the same inputs run every time.

extern uint32_t fuzz_valid(void);
extern uint32_t fuzz_corrupt(uint32_t which);
extern uint32_t fuzz_bundle(uint32_t seed);
extern uint32_t fuzz_rollback(uint32_t seed);

#define ITERS 200000u

int main(void) {
    // 1. Anchor the accept path: the valid+signed header MUST be accepted (0). If this rejects,
    //    the fuzzer's "reject everything" would be vacuous.
    if (fuzz_valid() != 0) {
        fprintf(stderr, "bundle-fuzz FAIL: a valid+signed header was rejected\n");
        return 1;
    }

    // 2. Single-field corruption MUST reject (1) for every field (teeth: a dropped guard makes one
    //    return 0 = accept a corrupt/unsigned bundle). Sweep each selector many times.
    uint64_t corrupt_rejected = 0;
    for (uint32_t w = 0; w < 7u; w++) {
        for (uint32_t rep = 0; rep < 1000u; rep++) {
            if (fuzz_corrupt(w) != 1) {
                fprintf(stderr, "bundle-fuzz FAIL: corrupt field %u was ACCEPTED\n", w);
                return 1;
            }
            corrupt_rejected++;
        }
    }

    // 3. Random headers: every parse must TERMINATE (no trap). Both accept and reject paths must
    //    occur (the boundary is real, not short-circuited).
    uint64_t total = 0, accepted = 0, rejected = 0;
    for (uint32_t s = 1; s <= ITERS; s++) {
        uint32_t r = fuzz_bundle(s * 2654435761u + 1u);
        if (r == 0) accepted++; else rejected++;
        total++;
    }

    // 4. Random rollback op sequences: the A/B slot invariant must hold every op with no trap.
    uint64_t rollback_runs = 0;
    for (uint32_t s = 1; s <= 50000u; s++) {
        if (fuzz_rollback(s * 40503u + 7u) != 0) {
            fprintf(stderr, "bundle-fuzz FAIL: rollback slot invariant violated (seed %u)\n", s);
            return 1;
        }
        rollback_runs++;
    }

    // Reaching here means nothing ever trapped. Require both bundle outcomes to have occurred.
    if (total == ITERS && accepted > 0 && rejected > 0 && corrupt_rejected == 7000 && rollback_runs == 50000) {
        printf("bundle-fuzz: %llu random headers (%llu accepted, %llu rejected), %llu single-field corruptions all rejected, %llu rollback op-sequences invariant-clean, 0 traps\n",
               (unsigned long long)total, (unsigned long long)accepted, (unsigned long long)rejected,
               (unsigned long long)corrupt_rejected, (unsigned long long)rollback_runs);
        return 0;
    }
    fprintf(stderr, "bundle-fuzz FAIL: unexpected counts total=%llu accepted=%llu rejected=%llu\n",
            (unsigned long long)total, (unsigned long long)accepted, (unsigned long long)rejected);
    return 1;
}
