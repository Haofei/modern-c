#!/usr/bin/env bash
# Trace ring-buffer test: compile kernel/core/trace.mc (via the test wrappers) to an
# object, link a C driver that records events and checks retention, wrap-around, and
# sequence numbering.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: trace-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/lang/trace_demo.mc" -o "$WORK/trace.o" >/dev/null

cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>

extern void     t_init(void);
extern void     t_record(uint32_t id, uint64_t value);
extern uint64_t t_total(void);
extern uint64_t t_len(void);
extern uint64_t t_seq(uintptr_t i);
extern uint32_t t_id(uintptr_t i);
extern uint64_t t_value(uintptr_t i);

#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)

int main(void) {
    // Below capacity: events are retained in order from seq 0.
    t_init();
    t_record(10, 100);
    t_record(20, 200);
    t_record(30, 300);
    CHECK(t_total() == 3 && t_len() == 3);
    CHECK(t_seq(0) == 0 && t_id(0) == 10 && t_value(0) == 100);
    CHECK(t_seq(2) == 2 && t_id(2) == 30 && t_value(2) == 300);

    // Overflow capacity (64): record 67 events; the oldest 3 are dropped.
    t_init();
    for (uint32_t i = 0; i < 67; i++) t_record(i + 1, (uint64_t)(i + 1) * 100);
    CHECK(t_total() == 67);
    CHECK(t_len() == 64);
    // Oldest retained has seq 3 (events 0..2 were overwritten).
    CHECK(t_seq(0) == 3 && t_id(0) == 4 && t_value(0) == 400);
    // Newest retained has seq 66.
    CHECK(t_seq(63) == 66 && t_id(63) == 67 && t_value(63) == 6700);

    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/trace.o" -o "$WORK/app"
if "$WORK/app"; then
    echo "PASS: trace-test — trace ring buffer: ordered retention, wrap-around (oldest dropped), sequence numbering"
    exit 0
fi
echo "FAIL: trace-test — driver returned non-zero (failing CHECK line)"
exit 1
