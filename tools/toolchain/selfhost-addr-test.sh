#!/usr/bin/env bash
# selfhost-addr-test: the self-hosting capstone — prove mcc2 compiles a REAL std module,
# `std/addr.mc`, end to end, and that the two constructs that unlocked it (bool literals `true`/
# `false`, and the builtin address-class model: `PAddr`/`VAddr`/`DmaAddr` opaque word-backed scalars
# + the `phys()` minting builtin + `as`-cast minting) behave correctly at runtime.
#
#   Stage BUILD:     mcc-cc.sh selfhost/main.mc -> main.o ; clang link with mcc2_rt.c -> mcc2
#   Stage MILESTONE: `mcc2 std/addr.mc > addr.c`, then clang -std=c11 -c addr.c — mcc2 must compile
#                    the real std module to clang-clean C with NO parse/sema errors on its stderr.
#   Stage UNIT:      `mcc2 selfhost_addrunit_user.mc > unit.c`, clang-compile unit.c + a driver,
#                    assert bool-literal returns + a PAddr/VAddr round-trip + a PRange (address-class
#                    struct field + `return .{...}` compound literal) — behavior, not just compile.
#
# A green run proves mcc2 (lex->parse->sema->emit_c) turned an actual std module into clang-clean C,
# and that its new bool-literal + address-class lowering runs correctly through clang (-Werror).
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/selfhost/main.mc"
RT="$HERE/tools/toolchain/mcc2_rt.c"
ADDR="$HERE/std/addr.mc"
FIXTURE="$HERE/tests/toolchain/selfhost_addrunit_user.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: selfhost-addr-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ----- Stage BUILD: compile selfhost/main.mc and link the mcc2 CLI -----
MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/main.o" --profile=hosted >/dev/null
"$CLANG" "$WORK/main.o" "$RT" -lm -o "$WORK/mcc2"

# ----- Stage MILESTONE: mcc2 compiles the real std/addr.mc -> clang-clean C -----
# (mcc2 needs an ABSOLUTE path for its input on macOS — G29 relative-path/AT_FDCWD gap.)
"$WORK/mcc2" "$ADDR" > "$WORK/addr.c" 2> "$WORK/addr.err"
if [ -s "$WORK/addr.err" ]; then
    echo "FAIL: selfhost-addr-test — mcc2 reported diagnostics compiling std/addr.mc:"
    cat "$WORK/addr.err"
    exit 1
fi
if [ ! -s "$WORK/addr.c" ]; then echo "FAIL: selfhost-addr-test — mcc2 emitted no C for std/addr.mc"; exit 1; fi

echo "----- emitted addr.c (real std module std/addr.mc via mcc2) -----"
cat "$WORK/addr.c"

# Compile-check the emitted C for the real std module (the milestone assertion).
"$CLANG" -std=c11 -c "$WORK/addr.c" -o "$WORK/addr.o"
echo "MILESTONE: mcc2 compiled std/addr.mc -> clang-clean C (clang -std=c11 -c addr.c OK)"

# ----- Stage UNIT: behavioral round-trip of bool literals + address-class model -----
"$WORK/mcc2" "$FIXTURE" > "$WORK/unit.c" 2> "$WORK/unit.err"
if [ -s "$WORK/unit.err" ]; then
    echo "FAIL: selfhost-addr-test — mcc2 reported diagnostics compiling the addr-unit fixture:"
    cat "$WORK/unit.err"
    exit 1
fi
if [ ! -s "$WORK/unit.c" ]; then echo "FAIL: selfhost-addr-test — mcc2 emitted no C for the addr-unit fixture"; exit 1; fi

echo "----- emitted unit.c (bool literals + PAddr/VAddr round-trip + PRange) -----"
cat "$WORK/unit.c"

cat >"$WORK/main.c" <<'EOF'
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdio.h>

extern bool   ge10(size_t x);
extern size_t pa_roundtrip(size_t v);
extern size_t va_roundtrip(size_t v);
extern size_t built_len(size_t start, size_t len);

int main(void) {
    int fails = 0;
    /* bool literals: `false` when x<10, `true` otherwise */
    if (ge10(5)  != false) { printf("FAIL: ge10(5) not false\n");  fails++; }
    if (ge10(20) != true)  { printf("FAIL: ge10(20) not true\n");  fails++; }
    /* phys() mint + `as usize` read-back is an identity word round-trip */
    if (pa_roundtrip(0x1000u) != 0x1000u) { printf("FAIL: pa_roundtrip(0x1000)=%zu\n", pa_roundtrip(0x1000u)); fails++; }
    if (pa_roundtrip(0u)      != 0u)      { printf("FAIL: pa_roundtrip(0)=%zu\n", pa_roundtrip(0u)); fails++; }
    /* `as VAddr` mint + `as usize` read-back */
    if (va_roundtrip(0x2000u) != 0x2000u) { printf("FAIL: va_roundtrip(0x2000)=%zu\n", va_roundtrip(0x2000u)); fails++; }
    /* PRange built via `return .{...}`; end-start == len */
    if (built_len(0x5000u, 0x100u) != 0x100u) { printf("FAIL: built_len(0x5000,0x100)=%zu\n", built_len(0x5000u, 0x100u)); fails++; }
    if (built_len(0u, 0x40u)       != 0x40u)  { printf("FAIL: built_len(0,0x40)=%zu\n", built_len(0u, 0x40u)); fails++; }
    if (fails != 0) { printf("FAIL: selfhost-addr-test — %d assertion(s) failed\n", fails); return 1; }
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/unit.c" "$WORK/main.c" -o "$WORK/prog"
if "$WORK/prog"; then
    echo "PASS: selfhost-addr-test — mcc2 compiled the REAL std module std/addr.mc to clang-clean C (the milestone), and its bool-literal + address-class (phys/as-mint/PAddr struct field/compound-literal return) lowering ran correctly through clang (-Werror): ge10/pa_roundtrip/va_roundtrip/built_len all correct"
    exit 0
fi
echo "FAIL: selfhost-addr-test — addr-unit program returned non-zero"
exit 1
