#!/usr/bin/env bash
# Regression for review issue #3: a `defer` must run on the error branch of `?`.
# Builds tests/toolchain/try_defer_cleanup.mc through BOTH the C and LLVM backends,
# links each against a driver whose `bump()` counts cleanup runs, and asserts the
# program propagated the error (returns 7) and ran the deferred cleanup exactly once.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/try_defer_cleanup.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: try-defer-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/driver.c" <<'CEOF'
#include <stdint.h>
static int bumped = 0;
void bump(void) { bumped = bumped + 1; }
extern uint32_t run_try_defer(void);
int main(void) {
    uint32_t r = run_try_defer();
    if (r != 7) return 1;       /* the `?` error must have propagated out */
    if (bumped != 1) return 2;  /* the defer must run exactly once on the error path */
    return 0;
}
CEOF

run_backend() {
    local label="$1" cc_script="$2"
    MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/$cc_script" "$SRC" -o "$WORK/try.o" >/dev/null
    "$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/try.o" -o "$WORK/prog"
    if "$WORK/prog"; then
        echo "PASS: try-defer-test ($label) — defer ran on the ? error branch"
    else
        echo "FAIL: try-defer-test ($label) — defer did not run on the ? error branch (or value not propagated)"
        exit 1
    fi
}

run_backend "C backend" "mcc-cc.sh"
if command -v llc >/dev/null 2>&1; then
    run_backend "LLVM backend" "mcc-llvm-cc.sh"
else
    echo "SKIP: try-defer-test (LLVM backend) — llc not found"
fi
