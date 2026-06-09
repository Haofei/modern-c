#!/usr/bin/env bash
# Comptime-reflection ABI test: the module's `comptime { assert(sizeof…) }`
# folds via the MC layout model (checked by `mcc check`). This script then emits
# the C and `_Static_assert`s the same sizes/alignments against clang's actual
# `sizeof`/`_Alignof`, proving the MC layout model agrees with the C ABI.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/reflect.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: reflect-test (clang not found)"; exit 0; }

# 1. The MC comptime asserts must fold (any false one is E_COMPTIME_TRAP).
if ! "$MCC" check "$SRC" >/dev/null 2>&1; then
    echo "FAIL: reflect-test — comptime layout assertions did not hold"
    "$MCC" check "$SRC" 2>&1 | head
    exit 1
fi

# 2. The same numbers must match clang's real layout.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
{
    "$MCC" emit-c "$SRC" 2>/dev/null
    cat <<'EOF'
_Static_assert(sizeof(Packet) == 3 && _Alignof(Packet) == 1, "Packet");
_Static_assert(sizeof(Quad) == 8 && _Alignof(Quad) == 4, "Quad");
_Static_assert(sizeof(Buf) == 16, "Buf");
EOF
} | "$CLANG" -std=c11 -Wall -Wextra -Werror -x c - -c -o /dev/null

echo "PASS: reflect-test — MC comptime sizeof/alignof match clang's C ABI layout"
