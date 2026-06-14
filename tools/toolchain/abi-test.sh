#!/usr/bin/env bash
# Advanced packed/overlay/MMIO ABI golden test. Three layers:
#   1. MC layout model: `mcc check` folds the module's `comptime { assert(sizeof…) }`
#      (any disagreement is E_COMPTIME_TRAP).
#   2. Host C ABI: emit the module to C and `_Static_assert` the SAME sizes/alignments/
#      offsets against clang's real sizeof/_Alignof/offsetof — proving MC's advanced-ABI
#      layout (nested packed-bits fields, overlay unions, MMIO `@offset` register blocks)
#      matches the host C ABI. Also asserts the C backend actually emits `volatile` on the
#      MMIO registers and the expected `@offset` padding.
#   3. Cross-backend: if the LLVM tools are present, emit LLVM IR, validate it with
#      llvm-as, and check the overlay byte-array and volatile MMIO load/store shape — so
#      both backends agree on the same ABI. Skipped (not failed) when llvm-as is absent.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/abi_layout.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: abi-test (clang not found)"; exit 0; }

# 1. MC's comptime layout asserts must fold.
if ! "$MCC" check "$SRC" >/dev/null 2>&1; then
    echo "FAIL: abi-test — MC comptime layout assertions did not hold"
    "$MCC" check "$SRC" 2>&1 | head
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 2. The same numbers must match clang's real layout, and the MMIO registers must be
#    emitted volatile with the expected `@offset` padding.
"$MCC" emit-c "$SRC" 2>/dev/null > "$WORK/abi.c"

{
    cat "$WORK/abi.c"
    cat <<'EOF'
#include <stddef.h>
_Static_assert(sizeof(Lsr) == 1 && _Alignof(Lsr) == 1, "Lsr");
_Static_assert(sizeof(Ctrl) == 2, "Ctrl");
_Static_assert(sizeof(Word) == 4 && _Alignof(Word) == 4, "Word");
_Static_assert(sizeof(Frame) == 8 && offsetof(Frame, status) == 0 && offsetof(Frame, seq) == 2 && offsetof(Frame, payload) == 4, "Frame");
_Static_assert(sizeof(Tagged) == 8 && _Alignof(Tagged) == 4 && offsetof(Tagged, body) == 4, "Tagged");
_Static_assert(sizeof(Uart) == 12 && offsetof(Uart, ctrl) == 2 && offsetof(Uart, div) == 8, "Uart");
EOF
} | "$CLANG" -std=c11 -Wall -Wextra -Werror -x c - -c -o /dev/null

# Volatile + `@offset` padding must be present in the MMIO register block.
grep -q 'uint8_t volatile thr;'  "$WORK/abi.c" || { echo "FAIL: abi-test — MMIO field 'thr' not emitted volatile"; exit 1; }
grep -q 'uint32_t volatile div;' "$WORK/abi.c" || { echo "FAIL: abi-test — MMIO field 'div' not emitted volatile"; exit 1; }
grep -Eq 'uint8_t _pad[0-9]+\[' "$WORK/abi.c"   || { echo "FAIL: abi-test — MMIO @offset padding not emitted"; exit 1; }

# 3. Cross-backend: the LLVM backend must agree on the same ABI shape.
if command -v llvm-as >/dev/null 2>&1; then
    "$MCC" emit-llvm "$SRC" 2>/dev/null > "$WORK/abi.ll"
    llvm-as "$WORK/abi.ll" -o /dev/null
    grep -q '\[4 x i8\]' "$WORK/abi.ll" || { echo "FAIL: abi-test — overlay union not lowered to a 4-byte array in LLVM"; exit 1; }
    grep -Eq '(load|store) volatile' "$WORK/abi.ll" || { echo "FAIL: abi-test — MMIO access not volatile in LLVM"; exit 1; }
    echo "PASS: abi-test — MC layout matches clang's C ABI; volatile/offset shape agrees on C and LLVM"
else
    echo "PASS: abi-test — MC layout matches clang's C ABI; volatile/offset shape verified (LLVM check skipped: llvm-as absent)"
fi
