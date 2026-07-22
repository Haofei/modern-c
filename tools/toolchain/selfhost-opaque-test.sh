#!/usr/bin/env bash
# selfhost-opaque-test: prove `opaque struct` support in mcc2 (selfhost/parser.mc + sema.mc +
# emit_c.mc) end to end, through the standalone mcc2 CLI. `opaque struct` is the address-/access-
# class qualifier the std memory layer leans on pervasively (`opaque struct PAddr` in std/addr.mc),
# and it was the concrete next blocker for a literal self-compile. The subset does NOT enforce
# opacity (a cross-module access-control concern, §31); it compiles an `opaque struct` exactly as a
# regular struct.
#
#   Stage BUILD:      mcc-cc.sh selfhost/main.mc -> main.o ; clang link with mcc2_rt.c -> mcc2
#   Stage FUNCTIONAL: `mcc2 selfhost_opaque_user.mc > out.c` (an `opaque struct P { v: u32 }` plus a
#                     fn constructing it into a typed local, writing/reading `.v`, returning the
#                     field), clang-compile out.c + a driver calling mk(2,3), assert == 5 — the
#                     lex -> parse -> sema -> emit -> clang -> run round-trip over an opaque struct.
#
# A green run proves mcc2 parsed, type-checked and emitted C for an `opaque struct` program that
# clang compiled and ran.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/selfhost/main.mc"
RT="$HERE/tools/toolchain/mcc2_rt.c"
FIXTURE="$HERE/tests/toolchain/selfhost_opaque_user.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: selfhost-opaque-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ----- Stage BUILD: compile selfhost/main.mc and link the mcc2 CLI -----
MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/main.o" --profile=hosted >/dev/null
"$CLANG" "$WORK/main.o" "$RT" -lm -o "$WORK/mcc2"

# ----- Stage FUNCTIONAL: mcc2 opaque.mc -> out.c -> clang -> run, assert mk(2,3)==5 -----
"$WORK/mcc2" "$FIXTURE" > "$WORK/out.c"
if [ ! -s "$WORK/out.c" ]; then echo "FAIL: selfhost-opaque-test — mcc2 emitted no C for the opaque-struct source"; exit 1; fi

echo "----- emitted out.c (opaque struct P + mk) -----"
cat "$WORK/out.c"

cat >"$WORK/main.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>

extern uint32_t mk(uint32_t a, uint32_t b);

int main(void) {
    int fails = 0;
    if (mk(2, 3) != 5)   { printf("FAIL: mk(2,3)=%u want 5\n", mk(2, 3)); fails++; }
    if (mk(10, 5) != 15) { printf("FAIL: mk(10,5)=%u want 15\n", mk(10, 5)); fails++; }
    if (fails != 0) { printf("FAIL: selfhost-opaque-test — %d assertion(s) failed\n", fails); return 1; }
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/out.c" "$WORK/main.c" -o "$WORK/prog"
if "$WORK/prog"; then
    echo "PASS: selfhost-opaque-test — mcc2 (parser+sema+emit_c) compiled an opaque-struct program: opaque struct decl, typed var, struct literal, member read/write, returned field -> C that clang ran (mk(2,3)==5, mk(10,5)==15)"
    exit 0
fi
echo "FAIL: selfhost-opaque-test — program returned non-zero"
exit 1
