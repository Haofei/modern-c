#!/usr/bin/env bash
# Closure test: bind() a captured pointer + function into a closure value, call it
# twice, and confirm the captured object is mutated across calls (real capture).
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: closure-test (clang not found)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/lang/closure_demo.mc" -o "$WORK/cl.o" >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t cl_run(void);
#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
int main(void) {
    CHECK(cl_run() == 220); // 105 + 115: closure captured &counter, state persisted
    return 0;
}
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/cl.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: closure-test — bind() closure captures a pointer + fn, callable with no ctx word/casts; capture mutated across calls"; exit 0; fi
echo "FAIL: closure-test"; exit 1
