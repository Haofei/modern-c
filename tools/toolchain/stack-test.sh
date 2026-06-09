#!/usr/bin/env bash
# Generic-collection test: a module imports the generic `std/stack` collection,
# uses it at a concrete element type (monomorphized), and is linked/run.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/stack_user.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: stack-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/stack.o" >/dev/null

cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t stack_top_two_sum(uint32_t a, uint32_t b, uint32_t c);
// pushes a,b,c; returns get(1)+get(2)+len == b + c + 3.
int main(void) {
    if (stack_top_two_sum(1, 2, 3) != 8) return 1;       // 2 + 3 + 3
    if (stack_top_two_sum(10, 20, 30) != 53) return 2;   // 20 + 30 + 3
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/stack.o" -o "$WORK/prog"
if "$WORK/prog"; then
    echo "PASS: stack-test — generic std/stack collection monomorphized, linked, and ran"
    exit 0
fi
echo "FAIL: stack-test — program returned non-zero"
exit 1
