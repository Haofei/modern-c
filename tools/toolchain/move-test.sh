#!/usr/bin/env bash
# Linear `move` runtime test: a `move`-typed handle is erased to an ordinary
# struct, links against a C-defined consumer, and runs.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/move_user.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: move-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/move.o" >/dev/null

cat >"$WORK/driver.c" <<'CEOF'
#include <stdint.h>
struct Box { uint32_t value; };
uint32_t box_consume(struct Box b) { return b.value * 2; }
extern uint32_t box_roundtrip(uint32_t v);
int main(void) {
    if (box_roundtrip(21) != 42) return 1;
    if (box_roundtrip(0) != 0) return 2;
    return 0;
}
CEOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/move.o" -o "$WORK/prog"
if "$WORK/prog"; then
    echo "PASS: move-test — linear move handle erased, linked, and ran"
    exit 0
fi
echo "FAIL: move-test — program returned non-zero"
exit 1
