#!/usr/bin/env bash
# selfhost-emitself-test: the FOURTH self-compile milestone — mcc2 compiling its OWN C-code emitter
# (selfhost/emit_c.mc), after the lexer (selfhost-lexself-test), parser (selfhost-parseself-test),
# and sema (selfhost-semaself-test). emit_c.mc is the LARGEST mcc2 module (~3.4k lines): it is the
# monomorphizer + `StrBuf`-based C emitter, so it stresses the whole subset at scale. Getting it all
# the way to clang-clean C required three fixes verified end-to-end here:
#   * PREFIX pointer deref `*p` (C-style, distinct from postfix `p.*`), including the `&*p` re-borrow
#     that passes a `*mut Vec<u32>` where a `*Vec<u32>` is wanted (`e_arg_present(p, &*out, ..)`);
#   * a string literal passed to a `*const u8` PARAMETER — string literals coerce to BOTH `[]const u8`
#     and `*const u8` in MC (G12), so sema accepts the arg leniently and the emitter emits the bare C
#     string (not the `[]const u8` fat-pointer slice) at such call sites (`sb_put_cstr(sb, "...")`);
#   * renaming `ok`/`err`-shaped local variables (they are Result-constructor keywords in the subset).
#
#   Stage BUILD:     mcc-cc.sh selfhost/main.mc -> main.o ; clang link with mcc2_rt.c -> mcc2
#   Stage LANDMARK:  `mcc2 <root> > emit.c`, then `clang -std=gnu11 -c emit.c` — mcc2 compiles ITS
#                    OWN EMITTER (selfhost/emit_c.mc, + its std/parser deps) to C with NO parse/sema
#                    diagnostics on stderr, and that C compiles clean. As with the sema landmark, a
#                    tiny ROOT wrapper at the repo root (`import "selfhost/emit_c.mc";`) is used so the
#                    concat loader's root-dir-relative resolution finds emit_c.mc AND its deps (G29).
#   Stage UNIT:      `mcc2 <root-of-fixture> > unit.c`, clang-compile (-Werror) unit.c + a driver, and
#                    assert AT RUNTIME that prefix deref `*p` (read/write + `&*` re-borrow) and a
#                    string literal passed to a `*const u8` param behave correctly — behavior, not
#                    just compilation.
#
# A green run proves mcc2 (lex->parse->sema->emit_c) turned its OWN emitter into clang-clean C.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/selfhost/main.mc"
RT="$HERE/tools/toolchain/mcc2_rt.c"
EMIT="$HERE/selfhost/emit_c.mc"
FIXTURE="$HERE/tests/toolchain/selfhost_emitself_unit_user.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: selfhost-emitself-test (clang not found)"; exit 0; }

# ROOT wrappers at the repo root so the concat loader's root-dir-relative resolution finds the target
# .mc (and, transitively, its std deps). Cleaned up on exit.
EROOT="$HERE/.selfhost_emitself_root_$$.mc"
UROOT="$HERE/.selfhost_emitself_unit_$$.mc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" "$EROOT" "$UROOT"' EXIT

# ----- Stage BUILD: compile selfhost/main.mc and link the mcc2 CLI -----
MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/main.o" --profile=hosted >/dev/null
"$CLANG" "$WORK/main.o" "$RT" -lm -o "$WORK/mcc2"

# ----- Stage LANDMARK: mcc2 compiles its OWN emitter selfhost/emit_c.mc -> clang-clean C -----
[ -f "$EMIT" ] || { echo "FAIL: selfhost-emitself-test — selfhost/emit_c.mc not found at $EMIT"; exit 1; }
printf 'import "selfhost/emit_c.mc";\n' > "$EROOT"
"$WORK/mcc2" "$EROOT" > "$WORK/emit.c" 2> "$WORK/emit.err"
if [ -s "$WORK/emit.err" ]; then
    echo "FAIL: selfhost-emitself-test — mcc2 reported diagnostics compiling its own emitter selfhost/emit_c.mc:"
    cat "$WORK/emit.err"
    exit 1
fi
if [ ! -s "$WORK/emit.c" ]; then echo "FAIL: selfhost-emitself-test — mcc2 emitted no C for selfhost/emit_c.mc"; exit 1; fi
# Sanity: the emitted C must contain the emitter's own monomorphization artifacts — a `Vec_Node`
# typedef (the index-arena AST vector over the `Node` struct) and the `mc_slice_const_u8` fat-pointer
# slice type (the `[]const u8` lowering the emitter is built on).
grep -q "Vec_Node" "$WORK/emit.c" || { echo "FAIL: selfhost-emitself-test — emitted emit.c has no monomorphic Vec_Node"; exit 1; }
grep -q "mc_slice_const_u8" "$WORK/emit.c" || { echo "FAIL: selfhost-emitself-test — emitted emit.c has no mc_slice_const_u8 slice type"; exit 1; }

# Compile-check the emitted C (the milestone assertion). `-std=gnu11` because the subset's Result/
# optional lowering (present transitively via the std deps) relies on GNU statement-expressions.
"$CLANG" -std=gnu11 -c "$WORK/emit.c" -o "$WORK/emit.o" 2> "$WORK/emit.cc.err" || {
    echo "FAIL: selfhost-emitself-test — clang could not compile mcc2's emitted emit.c:"
    head -30 "$WORK/emit.cc.err"
    exit 1
}
echo "LANDMARK: mcc2 compiled its OWN emitter selfhost/emit_c.mc -> clang-clean C (clang -std=gnu11 -c emit.c OK)"

# ----- Stage UNIT: prefix deref + string-literal-to-`*const u8` behavioral round-trip -----
[ -f "$FIXTURE" ] || { echo "FAIL: selfhost-emitself-test — fixture not found at $FIXTURE"; exit 1; }
printf 'import "tests/toolchain/selfhost_emitself_unit_user.mc";\n' > "$UROOT"
"$WORK/mcc2" "$UROOT" > "$WORK/unit.c" 2> "$WORK/unit.err"
if [ -s "$WORK/unit.err" ]; then
    echo "FAIL: selfhost-emitself-test — mcc2 reported diagnostics compiling the emitself fixture:"
    cat "$WORK/unit.err"
    exit 1
fi
if [ ! -s "$WORK/unit.c" ]; then echo "FAIL: selfhost-emitself-test — mcc2 emitted no C for the fixture"; exit 1; fi
# The bare-C-string lowering must appear (a string literal cast to the `uint8_t*` param type), NOT a
# `[]const u8` fat-pointer slice at that call site.
grep -q '(uint8_t\*)"Alpha"' "$WORK/unit.c" || { echo "FAIL: selfhost-emitself-test — fixture C did not lower a string literal to a bare *const u8 argument"; exit 1; }

cat >"$WORK/main.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>

extern uint32_t deref_roundtrip(void);
extern uint32_t str_first(void);
extern uint32_t str_first2(void);

int main(void) {
    int fails = 0;
    /* prefix deref read/write + `&*` re-borrow: 15 + 115 = 130 */
    if (deref_roundtrip() != 130) { printf("FAIL: deref_roundtrip()=%u\n", deref_roundtrip()); fails++; }
    /* string literal -> *const u8 param, first byte read via prefix deref: 'A' = 65 */
    if (str_first() != 65) { printf("FAIL: str_first()=%u\n", str_first()); fails++; }
    /* second string-literal call proves it is not a one-off: 'Z' = 90 */
    if (str_first2() != 90) { printf("FAIL: str_first2()=%u\n", str_first2()); fails++; }
    if (fails != 0) { printf("FAIL: selfhost-emitself-test — %d assertion(s) failed\n", fails); return 1; }
    return 0;
}
EOF

"$CLANG" -std=gnu11 -Wall -Wextra -Werror "$WORK/unit.c" "$WORK/main.c" -o "$WORK/prog"
if ! "$WORK/prog"; then
    echo "FAIL: selfhost-emitself-test — prefix-deref + string-literal-to-*const-u8 behavioral program returned non-zero"
    exit 1
fi
echo "PASS: selfhost-emitself-test — mcc2 compiled its OWN emitter selfhost/emit_c.mc to clang-clean C (the 4th self-compile module), and prefix deref (*p read/write + &* re-borrow) plus a string literal passed to a *const u8 param ran correctly through clang (-Werror)"
exit 0
