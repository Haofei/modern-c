#!/usr/bin/env bash
# Generic ring-buffer test: exercise std/ring's in-place Ring<T> at Ring<u32> —
# push/pop FIFO order, length, empty/full, and wrap-around past capacity.
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: ring-test (clang not found)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/ring_demo.mc" -o "$WORK/ring.o" >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern void     rg_init(void);
extern uint32_t rg_push(uint32_t x);
extern uint32_t rg_pop(void);
extern uint32_t rg_len(void);
extern uint32_t rg_empty(void);
extern uint32_t rg_full(void);
#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
int main(void) {
    rg_init();
    CHECK(rg_empty() == 1 && rg_len() == 0);
    CHECK(rg_push(10) == 1 && rg_push(20) == 1 && rg_push(30) == 1);
    CHECK(rg_len() == 3 && rg_empty() == 0);
    CHECK(rg_pop() == 10 && rg_pop() == 20);   // FIFO
    CHECK(rg_len() == 1);
    // Fill to capacity (16): one already queued (30), push 15 more.
    for (uint32_t i = 0; i < 15; i++) CHECK(rg_push(100 + i) == 1);
    CHECK(rg_full() == 1 && rg_len() == 16);
    CHECK(rg_push(999) == 0);                   // full -> rejected
    CHECK(rg_pop() == 30);                       // the original tail
    for (uint32_t i = 0; i < 15; i++) CHECK(rg_pop() == 100 + i); // wrap-around order
    CHECK(rg_empty() == 1);
    return 0;
}
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/ring.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: ring-test — generic in-place Ring<T> (instantiated at u32): FIFO push/pop, len, empty/full, wrap-around"; exit 0; fi
echo "FAIL: ring-test — driver returned non-zero (failing CHECK line)"; exit 1
