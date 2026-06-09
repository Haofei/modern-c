#!/usr/bin/env bash
# Toolchain test: compile an MC module to an object with the mcc-cc driver and
# verify the exported symbol is present and linkable.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/lib.mc"
SYM="mc_add3"

CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: mcc-cc-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$SRC" -o "$WORK/lib.o" >/dev/null

# The exported function must be a defined text symbol in the object.
if command -v nm >/dev/null 2>&1; then
    if ! nm "$WORK/lib.o" | grep -qE "T $SYM\$|T _$SYM\$"; then
        echo "FAIL: mcc-cc-test — symbol '$SYM' not defined in object:"
        nm "$WORK/lib.o"
        exit 1
    fi
fi

# It must also link into an executable against a tiny C driver that calls it.
cat >"$WORK/main.c" <<EOF
#include <stdint.h>
extern uint32_t $SYM(uint32_t, uint32_t, uint32_t);
int main(void) { return $SYM(1, 2, 3) == 6 ? 0 : 1; }
EOF
"$CLANG" -std=c11 "$WORK/main.c" "$WORK/lib.o" -o "$WORK/app"
if "$WORK/app"; then
    echo "PASS: mcc-cc-test — MC module compiled to an object, linked, and ran ($SYM(1,2,3)==6)"
    exit 0
fi
echo "FAIL: mcc-cc-test — linked program returned non-zero"
exit 1
