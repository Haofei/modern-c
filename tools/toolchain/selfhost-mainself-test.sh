#!/usr/bin/env bash
# selfhost-mainself-test: the FIFTH and FINAL core self-compile milestone — mcc2 compiling its OWN CLI
# driver (selfhost/main.mc), after the lexer (selfhost-lexself-test), parser (selfhost-parseself-test),
# sema (selfhost-semaself-test), and emitter (selfhost-emitself-test). With this, ALL FIVE mcc2 source
# modules compile through mcc2 itself.
#
# main.mc is the standalone `mcc2` command: it packages the whole subset front end (lexer -> parser ->
# sema -> emit_c) plus a textual-concatenation import loader and a hosted-I/O file reader, exporting
# `mc_main` (linked against tools/toolchain/mcc2_rt.c). Getting it all the way to clang-clean C
# required ONE new language construct plus two emitter fixes, all verified end-to-end here:
#   * module-level `global NAME: T [= init];` — a MUTABLE file-scope variable (parser `global_decl`,
#     sema registers it as a mutable global, emitter lowers `static T NAME [= init];`); main.mc uses
#     globals for its read/concat buffers and import-path queue. Writes to a global (whole-variable,
#     `[i]`, `.f`) are permitted and address-of-a-global (`(&g) as usize`) resolves;
#   * a chained sub-slice / index of a `mem.as_bytes(&g)` slice VALUE (`as_bytes(&g)[a..b]` /
#     `as_bytes(&g)[i]`): the emitter now recognizes an `as_bytes` call as a slice base (reading its
#     `.ptr` fat-pointer field) instead of mis-lowering it as an array decay.
#
#   Stage BUILD:     mcc-cc.sh selfhost/main.mc -> main.o ; clang link with mcc2_rt.c -> mcc2
#   Stage LANDMARK:  `mcc2 <root> > main.c`, then `clang -std=gnu11 -c main.c` — mcc2 compiles ITS OWN
#                    CLI driver (selfhost/main.mc, + its full front-end + std deps) to C with NO
#                    parse/sema diagnostics on stderr, and that C compiles clean. A tiny ROOT wrapper
#                    at the repo root (`import "selfhost/main.mc";`) lets the concat loader's
#                    root-dir-relative resolution find main.mc AND all of its deps (G29).
#   Stage UNIT:      `mcc2 <root-of-fixture> > unit.c`, clang-compile (-Werror) unit.c + a driver, and
#                    assert AT RUNTIME that module-level `global`s (scalar-with-init, array, and
#                    whole-variable + `[i]` writes + address-of) behave correctly — behavior, not just
#                    compilation.
#
# A green run proves mcc2 (lex->parse->sema->emit_c) turned its OWN CLI driver into clang-clean C —
# the 5th and FINAL core module: every mcc2 source module now self-compiles.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/selfhost/main.mc"
RT="$HERE/tools/toolchain/mcc2_rt.c"
FIXTURE="$HERE/tests/toolchain/selfhost_mainself_unit_user.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: selfhost-mainself-test (clang not found)"; exit 0; }

# ROOT wrappers at the repo root so the concat loader's root-dir-relative resolution finds the target
# .mc (and, transitively, its std deps). Cleaned up on exit.
MROOT="$HERE/.selfhost_mainself_root_$$.mc"
UROOT="$HERE/.selfhost_mainself_unit_$$.mc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" "$MROOT" "$UROOT"' EXIT

# ----- Stage BUILD: compile selfhost/main.mc and link the mcc2 CLI -----
MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/main.o" --profile=hosted >/dev/null
"$CLANG" "$WORK/main.o" "$RT" -lm -o "$WORK/mcc2"

# ----- Stage LANDMARK: mcc2 compiles its OWN CLI driver selfhost/main.mc -> clang-clean C -----
[ -f "$SRC" ] || { echo "FAIL: selfhost-mainself-test — selfhost/main.mc not found at $SRC"; exit 1; }
printf 'import "selfhost/main.mc";\n' > "$MROOT"
"$WORK/mcc2" "$MROOT" > "$WORK/main.c" 2> "$WORK/main.err"
if [ -s "$WORK/main.err" ]; then
    echo "FAIL: selfhost-mainself-test — mcc2 reported diagnostics compiling its own CLI driver selfhost/main.mc:"
    cat "$WORK/main.err"
    exit 1
fi
if [ ! -s "$WORK/main.c" ]; then echo "FAIL: selfhost-mainself-test — mcc2 emitted no C for selfhost/main.mc"; exit 1; fi
# Sanity: the emitted C must contain the driver's own artifacts — one of its module-level `global`
# buffers (lowered to a `static` file-scope array) and the `mc_slice_const_u8` fat-pointer slice type.
grep -q "g_concat" "$WORK/main.c" || { echo "FAIL: selfhost-mainself-test — emitted main.c has no g_concat global"; exit 1; }
grep -q "mc_slice_const_u8" "$WORK/main.c" || { echo "FAIL: selfhost-mainself-test — emitted main.c has no mc_slice_const_u8 slice type"; exit 1; }

# Compile-check the emitted C (the milestone assertion). `-std=gnu11` because the subset's Result/
# optional lowering (present transitively via the std deps) relies on GNU statement-expressions.
"$CLANG" -std=gnu11 -c "$WORK/main.c" -o "$WORK/main.self.o" 2> "$WORK/main.cc.err" || {
    echo "FAIL: selfhost-mainself-test — clang could not compile mcc2's emitted main.c:"
    head -30 "$WORK/main.cc.err"
    exit 1
}
echo "LANDMARK: mcc2 compiled its OWN CLI driver selfhost/main.mc -> clang-clean C (clang -std=gnu11 -c main.c OK) — the 5th and FINAL core module"

# ----- Stage UNIT: module-level `global` behavioral round-trip -----
[ -f "$FIXTURE" ] || { echo "FAIL: selfhost-mainself-test — fixture not found at $FIXTURE"; exit 1; }
printf 'import "tests/toolchain/selfhost_mainself_unit_user.mc";\n' > "$UROOT"
"$WORK/mcc2" "$UROOT" > "$WORK/unit.c" 2> "$WORK/unit.err"
if [ -s "$WORK/unit.err" ]; then
    echo "FAIL: selfhost-mainself-test — mcc2 reported diagnostics compiling the mainself fixture:"
    cat "$WORK/unit.err"
    exit 1
fi
if [ ! -s "$WORK/unit.c" ]; then echo "FAIL: selfhost-mainself-test — mcc2 emitted no C for the fixture"; exit 1; fi
# The `global` lowering must appear: a scalar global with an initializer -> a mutable file-scope
# `static` (NOT a `static const`).
grep -q "static uint32_t g_counter = 7;" "$WORK/unit.c" || { echo "FAIL: selfhost-mainself-test — fixture C did not lower a scalar global to 'static uint32_t g_counter = 7;'"; exit 1; }
grep -q "static uint32_t g_arr\[4\];" "$WORK/unit.c" || { echo "FAIL: selfhost-mainself-test — fixture C did not lower an array global to 'static uint32_t g_arr[4];'"; exit 1; }

cat >"$WORK/main.c.driver" <<'EOF'
#include <stdint.h>
#include <stdio.h>

extern uint32_t bump_counter(uint32_t delta);
extern uint32_t arr_set_get(uint32_t i, uint32_t v);
extern uint32_t arr_addr_nonzero(void);

int main(void) {
    int fails = 0;
    /* scalar global with initializer (7) + whole-variable write: 7 + 5 = 12 */
    uint32_t c = bump_counter(5);
    if (c != 12) { printf("FAIL: bump_counter(5)=%u\n", c); fails++; }
    /* it is a real mutable global: a second bump accumulates: 12 + 3 = 15 */
    uint32_t c2 = bump_counter(3);
    if (c2 != 15) { printf("FAIL: bump_counter(3)=%u\n", c2); fails++; }
    /* array global element write via `[i] =` then read back */
    uint32_t a = arr_set_get(2, 99);
    if (a != 99) { printf("FAIL: arr_set_get(2,99)=%u\n", a); fails++; }
    /* address-of a global array, cast to usize, is non-zero */
    if (arr_addr_nonzero() != 1) { printf("FAIL: arr_addr_nonzero()=%u\n", arr_addr_nonzero()); fails++; }
    if (fails != 0) { printf("FAIL: selfhost-mainself-test — %d assertion(s) failed\n", fails); return 1; }
    return 0;
}
EOF
mv "$WORK/main.c.driver" "$WORK/driver.c"

"$CLANG" -std=gnu11 -Wall -Wextra -Werror "$WORK/unit.c" "$WORK/driver.c" -o "$WORK/prog"
if ! "$WORK/prog"; then
    echo "FAIL: selfhost-mainself-test — module-level `global` behavioral program returned non-zero"
    exit 1
fi
echo "PASS: selfhost-mainself-test — mcc2 compiled its OWN CLI driver selfhost/main.mc to clang-clean C (the 5th and FINAL core module — all five mcc2 modules now self-compile), and module-level globals (scalar-with-init, array, whole-variable + [i] writes + address-of) ran correctly through clang (-Werror)"
exit 0
