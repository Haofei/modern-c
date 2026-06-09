#!/usr/bin/env bash
# Log-level test: drive the leveled logger — events below the threshold are dropped
# (counted), the rest recorded with level + tracepoint id + value; raising the
# verbosity then admits lower-level events.
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: log-test (clang not found)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$HERE/tests/qemu/lang/log_demo.mc" -o "$WORK/log.o" >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern void     lg_init(uint32_t threshold);
extern void     lg_set(uint32_t threshold);
extern uint32_t lg_event(uint32_t level, uint32_t id, uint64_t value);
extern uint64_t lg_dropped(void);
extern uint64_t lg_count(void);
extern uint32_t lg_level(uintptr_t i);
extern uint32_t lg_id(uintptr_t i);
extern uint64_t lg_value(uintptr_t i);
enum { DEBUG, INFO, WARN, ERROR };
#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
int main(void) {
    lg_init(WARN); // only Warn and above are recorded

    CHECK(lg_event(DEBUG, 10, 100) == 0); // below threshold -> dropped
    CHECK(lg_event(INFO,  11, 101) == 0);
    CHECK(lg_dropped() == 2 && lg_count() == 0);

    CHECK(lg_event(WARN,  20, 200) == 1); // recorded
    CHECK(lg_event(ERROR, 21, 201) == 1);
    CHECK(lg_count() == 2 && lg_dropped() == 2);

    CHECK(lg_level(0) == WARN  && lg_id(0) == 20 && lg_value(0) == 200);
    CHECK(lg_level(1) == ERROR && lg_id(1) == 21 && lg_value(1) == 201);

    lg_set(DEBUG); // raise verbosity
    CHECK(lg_event(DEBUG, 30, 300) == 1);
    CHECK(lg_count() == 3 && lg_dropped() == 2);
    CHECK(lg_level(2) == DEBUG && lg_id(2) == 30 && lg_value(2) == 300);
    return 0;
}
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/log.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: log-test — leveled tracepoints: threshold filtering (dropped count), level+id+value recording, runtime verbosity change"; exit 0; fi
echo "FAIL: log-test — driver returned non-zero (failing CHECK line)"; exit 1
