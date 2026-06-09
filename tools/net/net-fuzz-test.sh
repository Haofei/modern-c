#!/usr/bin/env bash
# Packet-parser fuzz test: drive net_rx_deliver with thousands of pseudo-random and
# random-UDP-shaped frames of every length; it must always return a typed result and
# never read out of bounds (an OOB would trap the bounds-checked reader -> abort, so
# completing the run is the property under test). Confirms both ok + error paths hit.
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: net-fuzz-test (clang not found)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$HERE/tests/qemu/net/net_fuzz_demo.mc" -o "$WORK/fuzz.o" >/dev/null
cat >"$WORK/driver.c" <<'EOF'
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
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/fuzz.o" -o "$WORK/app"
if OUT="$("$WORK/app")"; then
    echo "$OUT"
    echo "PASS: net-fuzz-test — 40000 random/UDP-shaped frames parsed with no out-of-bounds read; ok + rejected paths both exercised"
    exit 0
fi
echo "FAIL: net-fuzz-test — a fuzzed frame crashed the parser or coverage was incomplete"
exit 1
