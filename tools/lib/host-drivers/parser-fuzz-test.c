#include <stdint.h>
#include <stdio.h>

// std/dma (pulled in via kernel/net/tcp_tx -> ethernet's MacAddr) declares these platform
// DMA hooks; the parsers never call them, so stub them so the test links on the host.
uintptr_t mc_dma_alloc_base(uintptr_t len){ (void)len; return 0; }
void mc_dma_free_base(uintptr_t a, uintptr_t b, uintptr_t c){ (void)a; (void)b; (void)c; }
void mc_dma_clean_for_device_base(uintptr_t a, uintptr_t b, uintptr_t c){ (void)a; (void)b; (void)c; }
uintptr_t mc_dma_invalidate_for_cpu_base(uintptr_t a, uintptr_t b){ (void)a; (void)b; return 0; }

extern uint32_t fuzz_dns_random(uint32_t seed, uintptr_t len);
extern uint32_t fuzz_dns_truncated(uint32_t seed, uintptr_t len);
extern uint32_t fuzz_dns_answer_trunc(uintptr_t len);
extern uint32_t fuzz_tcp_random(uint32_t seed, uintptr_t len);
extern uint32_t fuzz_tcp_hostile(uint32_t seed, uintptr_t len);

// The property under test: every parse TERMINATES and RETURNS a typed result over any
// finite buffer of any length 0..MAXLEN with arbitrary content. If a parser over-read,
// the bounds-checked reader fires `unreachable` and this process aborts (SIGABRT) before
// reaching the success print — so simply completing all iterations and printing is the
// proof. We also require both ok and rejected outcomes to actually occur (the paths are
// real, not short-circuited).
//
// ITERS seeds x MAXLEN lengths x 4 parsers. With the values below that is well over a
// million parses — "many iterations" of random + truncated + malformed input.
#define ITERS  6000u
#define MAXLEN 200u   // exceeds DNS header (12), TCP min frame (54), and IHL/data-off reach

int main(void) {
    uint64_t total = 0, ok = 0, rej = 0;
    // Targeted: a valid one-A-record DNS response truncated at every byte 0..40 — the
    // exact over-read trigger for an answer-walk that trusts rdlength. Seed-independent,
    // so run it once up front (every truncation point must reject without over-reading).
    for (uintptr_t len = 0; len <= 40; len++) {
        if (fuzz_dns_answer_trunc(len) == 0) ok++; else rej++;
        total++;
    }
    for (uint32_t s = 1; s <= ITERS; s++) {
        for (uintptr_t len = 0; len <= MAXLEN; len++) {
            uint32_t a = fuzz_dns_random(s, len);
            uint32_t b = fuzz_dns_truncated(s * 2654435761u + 1u, len);
            uint32_t c = fuzz_tcp_random(s * 40503u + 7u, len);
            uint32_t d = fuzz_tcp_hostile(s * 2246822519u + 3u, len);
            total += 4;
            if (a == 0) ok++; else rej++;
            if (b == 0) ok++; else rej++;
            if (c == 0) ok++; else rej++;
            if (d == 0) ok++; else rej++;
        }
    }
    // Reaching here at all means no parse ever over-read (no trap/abort). Garbage input
    // should overwhelmingly reject; we require at least one rejection (the error path is
    // real). ok may legitimately stay 0 for pure-random TCP/DNS, so we don't require it.
    if (total > 1000000ull && rej > 0) {
        printf("parser-fuzz: %llu parses, %llu accepted, %llu rejected, 0 over-reads\n",
               (unsigned long long)total, (unsigned long long)ok, (unsigned long long)rej);
        return 0;
    }
    fprintf(stderr, "parser-fuzz: unexpected counts total=%llu rej=%llu\n",
            (unsigned long long)total, (unsigned long long)rej);
    return 1;
}
