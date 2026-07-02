#!/usr/bin/env bash
# selfhost-mem-test: the value-optional milestone — prove mcc2 compiles a SECOND real std module,
# `std/mem.mc`, end to end, after adding value optionals (`?usize` / `return null;` / `if let` /
# `== null`) to mcc2's subset (G11 mirrored inside mcc2). std/mem.mc's byte-search helpers return a
# value optional `?usize`, so mcc2 could not compile it until now.
#
#   Stage BUILD:     mcc-cc.sh selfhost/main.mc -> main.o ; clang link with mcc2_rt.c -> mcc2
#   Stage MILESTONE: `mcc2 <root> > mem.c`, then clang -std=c11 -c mem.c — mcc2 must compile the real
#                    std module std/mem.mc to clang-clean C with NO parse/sema diagnostics on stderr.
#                    std/mem.mc imports std/addr.mc; the macOS host cannot resolve a cwd-relative
#                    import (G29 — openat(AT_FDCWD,..) gap), so a tiny ROOT wrapper at the repo root
#                    (`import "std/mem.mc";`) is used: the concat loader's ROOT-dir-relative resolution
#                    then finds both std/mem.mc and (transitively) std/addr.mc under the repo root, and
#                    the emitted C contains the real std/mem.mc functions (plus its addr.mc dependency).
#   Stage UNIT:      `mcc2 selfhost_optunit_user.mc > unit.c`, clang-compile unit.c + a driver, assert
#                    a `?usize`-returning fn consumed via `if let` (payload binding) and `== null` /
#                    `!= null` behaves correctly at runtime — behavior, not just compile.
#
# A green run proves mcc2 (lex->parse->sema->emit_c) turned a second actual std module into clang-clean
# C, and that its value-optional lowering (tagged `mc_opt_usize {present,value}`) runs correctly through
# clang (-Werror).
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/selfhost/main.mc"
RT="$HERE/tools/toolchain/mcc2_rt.c"
MEM="$HERE/std/mem.mc"
FIXTURE="$HERE/tests/toolchain/selfhost_optunit_user.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: selfhost-mem-test (clang not found)"; exit 0; }

# A ROOT wrapper placed at the repo root so the concat loader's root-dir-relative resolution finds
# std/mem.mc (and, transitively, std/addr.mc) — see the MILESTONE note above. Cleaned up on exit.
ROOT="$HERE/.selfhost_mem_root_$$.mc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" "$ROOT"' EXIT

# ----- Stage BUILD: compile selfhost/main.mc and link the mcc2 CLI -----
MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/main.o" --profile=hosted >/dev/null
"$CLANG" "$WORK/main.o" "$RT" -lm -o "$WORK/mcc2"

# ----- Stage MILESTONE: mcc2 compiles the real std/mem.mc -> clang-clean C -----
[ -f "$MEM" ] || { echo "FAIL: selfhost-mem-test — std/mem.mc not found at $MEM"; exit 1; }
printf 'import "std/mem.mc";\n' > "$ROOT"
"$WORK/mcc2" "$ROOT" > "$WORK/mem.c" 2> "$WORK/mem.err"
if [ -s "$WORK/mem.err" ]; then
    echo "FAIL: selfhost-mem-test — mcc2 reported diagnostics compiling std/mem.mc:"
    cat "$WORK/mem.err"
    exit 1
fi
if [ ! -s "$WORK/mem.c" ]; then echo "FAIL: selfhost-mem-test — mcc2 emitted no C for std/mem.mc"; exit 1; fi
# Sanity: the emitted C must contain the value-optional lowering for the ?usize returns.
grep -q "mc_opt_usize" "$WORK/mem.c" || { echo "FAIL: selfhost-mem-test — emitted mem.c has no mc_opt_usize (value optional) typedef/use"; exit 1; }

echo "----- emitted mem.c (real std module std/mem.mc via mcc2; value optionals -> mc_opt_usize) -----"
cat "$WORK/mem.c"

# Compile-check the emitted C for the real std module (the milestone assertion).
"$CLANG" -std=c11 -c "$WORK/mem.c" -o "$WORK/mem.o"
echo "MILESTONE: mcc2 compiled std/mem.mc -> clang-clean C (clang -std=c11 -c mem.c OK)"

# ----- Stage UNIT: behavioral round-trip of ?usize via if let / == null / != null -----
"$WORK/mcc2" "$FIXTURE" > "$WORK/unit.c" 2> "$WORK/unit.err"
if [ -s "$WORK/unit.err" ]; then
    echo "FAIL: selfhost-mem-test — mcc2 reported diagnostics compiling the opt-unit fixture:"
    cat "$WORK/unit.err"
    exit 1
fi
if [ ! -s "$WORK/unit.c" ]; then echo "FAIL: selfhost-mem-test — mcc2 emitted no C for the opt-unit fixture"; exit 1; fi

echo "----- emitted unit.c (?usize consumed via if let + == null / != null) -----"
cat "$WORK/unit.c"

cat >"$WORK/main.c" <<'EOF'
#include <stddef.h>
#include <stdio.h>

extern size_t iflet_or_zero(size_t x, size_t t);
extern size_t is_absent(size_t x, size_t t);
extern size_t is_present(size_t x, size_t t);

int main(void) {
    int fails = 0;
    /* if let: payload+1 when present (5>=3 -> 6), 0 when absent (2<3) */
    if (iflet_or_zero(5, 3) != 6) { printf("FAIL: iflet_or_zero(5,3)=%zu\n", iflet_or_zero(5, 3)); fails++; }
    if (iflet_or_zero(2, 3) != 0) { printf("FAIL: iflet_or_zero(2,3)=%zu\n", iflet_or_zero(2, 3)); fails++; }
    /* == null: 1 when absent, 0 when present */
    if (is_absent(2, 3) != 1) { printf("FAIL: is_absent(2,3)=%zu\n", is_absent(2, 3)); fails++; }
    if (is_absent(5, 3) != 0) { printf("FAIL: is_absent(5,3)=%zu\n", is_absent(5, 3)); fails++; }
    /* != null: 1 when present, 0 when absent */
    if (is_present(5, 3) != 1) { printf("FAIL: is_present(5,3)=%zu\n", is_present(5, 3)); fails++; }
    if (is_present(2, 3) != 0) { printf("FAIL: is_present(2,3)=%zu\n", is_present(2, 3)); fails++; }
    if (fails != 0) { printf("FAIL: selfhost-mem-test — %d assertion(s) failed\n", fails); return 1; }
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/unit.c" "$WORK/main.c" -o "$WORK/prog"
if "$WORK/prog"; then
    echo "PASS: selfhost-mem-test — mcc2 compiled the REAL std module std/mem.mc to clang-clean C (the value-optional milestone), and its ?usize lowering (tagged mc_opt_usize {present,value}) consumed via if let / == null / != null ran correctly through clang (-Werror): iflet_or_zero/is_absent/is_present all correct"
    exit 0
fi
echo "FAIL: selfhost-mem-test — opt-unit program returned non-zero"
exit 1
