#!/usr/bin/env bash
# Function-pointer test: compile the fn-pointer fixture (callback param, struct
# vtable field, fn-pointer return) to an object, link a C driver, and verify the
# indirect calls compute correctly at runtime.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: fnptr-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$HERE/tests/c_emit/fn_pointer.mc" -o "$WORK/fnptr.o" >/dev/null

cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t run(void);
int main(void) {
    // apply(add,3,4) + dispatch(mul,3,4) = 7 + 12 = 19
    return run() == 19 ? 0 : 1;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/fnptr.o" -o "$WORK/app"
if "$WORK/app"; then
    echo "PASS: fnptr-test — function pointers (callback, vtable field, fn-pointer return) call indirectly and compute correctly"
    exit 0
fi
echo "FAIL: fnptr-test — indirect calls produced the wrong result"
exit 1
