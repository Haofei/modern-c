#!/usr/bin/env bash
# selfhost-semaself-test: the THIRD self-compile milestone — mcc2 compiling its OWN semantic analyzer
# (selfhost/sema.mc), after the lexer (selfhost-lexself-test) and parser (selfhost-parseself-test).
# sema.mc is the first mcc2 module to instantiate generic containers over its OWN struct types at
# scale (`Vec<SmSig>`, `Vec<SmType>`, `StrHashMap<u32>`, `StrHashMap<SmType>`), and it imports the
# string-keyed hash map (`std/collections/hashmap.mc`), whose `Entry<V>` stores a generic (here
# struct) value. Getting it all the way to clang-clean C required four fixes verified end-to-end here:
#   * comma-less `}`-block switch arms (mcc2's parser now treats the arm-separator comma as optional);
#   * a `>>`-splitting generic close (so a nested `raw.ptr<Entry<V>>` / `Entry<V>>` parses);
#   * a visited-set in the transitive generic-instance collector (the lexeme-only type-param match
#     otherwise blows up exponentially on hashmap's `V`-named generics + call cycle);
#   * `Entry<struct>` typedef induction from the generic fns that use it, `mem.bytes_equal` builtin
#     lowering, module-qualified `mod.fn` calls, and `_` digit-separator stripping in int literals.
#
#   Stage BUILD:     mcc-cc.sh selfhost/main.mc -> main.o ; clang link with mcc2_rt.c -> mcc2
#   Stage LANDMARK:  `mcc2 <root> > sema.c`, then `clang -std=gnu11 -c sema.c` — mcc2 compiles ITS
#                    OWN SEMA (selfhost/sema.mc) to C with NO parse/sema diagnostics on stderr, and
#                    that C compiles clean. sema.mc imports std + parser deps; the macOS host cannot
#                    resolve a cwd-relative import (G29), so a tiny ROOT wrapper at the repo root
#                    (`import "selfhost/sema.mc";`) is used — the concat loader's root-dir-relative
#                    resolution then finds sema.mc AND its transitive deps under the repo root.
#   Stage UNIT:      `mcc2 <root-of-fixture> > unit.c`, clang-compile (-Werror) unit.c + a driver, and
#                    assert AT RUNTIME that a comma-less block `switch` and a `StrHashMap<Rec>` (a
#                    hash map over a STRUCT value: put/get_or struct values, incl. an absent-key
#                    fallback) behave correctly — behavior, not just compilation.
#
# A green run proves mcc2 (lex->parse->sema->emit_c) turned its OWN sema into clang-clean C.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/selfhost/main.mc"
RT="$HERE/tools/toolchain/mcc2_rt.c"
SEMA="$HERE/selfhost/sema.mc"
FIXTURE="$HERE/tests/toolchain/selfhost_commaswitch_user.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: selfhost-semaself-test (clang not found)"; exit 0; }

# ROOT wrappers at the repo root so the concat loader's root-dir-relative resolution finds the target
# .mc (and, transitively, its std deps). Cleaned up on exit.
SROOT="$HERE/.selfhost_semaself_root_$$.mc"
UROOT="$HERE/.selfhost_semaself_unit_$$.mc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" "$SROOT" "$UROOT"' EXIT

# ----- Stage BUILD: compile selfhost/main.mc and link the mcc2 CLI -----
MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/main.o" --profile=hosted >/dev/null
"$CLANG" "$WORK/main.o" "$RT" -lm -o "$WORK/mcc2"

# ----- Stage LANDMARK: mcc2 compiles its OWN sema selfhost/sema.mc -> clang-clean C -----
[ -f "$SEMA" ] || { echo "FAIL: selfhost-semaself-test — selfhost/sema.mc not found at $SEMA"; exit 1; }
printf 'import "selfhost/sema.mc";\n' > "$SROOT"
"$WORK/mcc2" "$SROOT" > "$WORK/sema.c" 2> "$WORK/sema.err"
if [ -s "$WORK/sema.err" ]; then
    echo "FAIL: selfhost-semaself-test — mcc2 reported diagnostics compiling its own sema selfhost/sema.mc:"
    cat "$WORK/sema.err"
    exit 1
fi
if [ ! -s "$WORK/sema.c" ]; then echo "FAIL: selfhost-semaself-test — mcc2 emitted no C for selfhost/sema.mc"; exit 1; fi
# Sanity: the emitted C must contain the struct-value hash-map monomorphization artifacts — a
# `StrHashMap_SmType` typedef and the induced `Entry_SmType` typedef (a generic struct instantiated at
# a struct value, reachable only through the generic hashmap functions).
grep -q "StrHashMap_SmType" "$WORK/sema.c" || { echo "FAIL: selfhost-semaself-test — emitted sema.c has no monomorphic StrHashMap_SmType"; exit 1; }
grep -q "Entry_SmType" "$WORK/sema.c" || { echo "FAIL: selfhost-semaself-test — emitted sema.c has no induced Entry_SmType typedef (Entry<struct> not monomorphized)"; exit 1; }

# Compile-check the emitted C (the milestone assertion). `-std=gnu11` because the subset's Result/
# optional lowering (present transitively via the std deps) relies on GNU statement-expressions.
"$CLANG" -std=gnu11 -c "$WORK/sema.c" -o "$WORK/sema.o" 2> "$WORK/sema.cc.err" || {
    echo "FAIL: selfhost-semaself-test — clang could not compile mcc2's emitted sema.c:"
    head -30 "$WORK/sema.cc.err"
    exit 1
}
echo "LANDMARK: mcc2 compiled its OWN sema selfhost/sema.mc -> clang-clean C (clang -std=gnu11 -c sema.c OK)"

# ----- Stage UNIT: comma-less block switch + StrHashMap<struct> behavioral round-trip -----
[ -f "$FIXTURE" ] || { echo "FAIL: selfhost-semaself-test — fixture not found at $FIXTURE"; exit 1; }
printf 'import "tests/toolchain/selfhost_commaswitch_user.mc";\n' > "$UROOT"
"$WORK/mcc2" "$UROOT" > "$WORK/unit.c" 2> "$WORK/unit.err"
if [ -s "$WORK/unit.err" ]; then
    echo "FAIL: selfhost-semaself-test — mcc2 reported diagnostics compiling the comma-switch fixture:"
    cat "$WORK/unit.err"
    exit 1
fi
if [ ! -s "$WORK/unit.c" ]; then echo "FAIL: selfhost-semaself-test — mcc2 emitted no C for the fixture"; exit 1; fi
grep -q "StrHashMap_Rec" "$WORK/unit.c" || { echo "FAIL: selfhost-semaself-test — fixture C has no monomorphic StrHashMap_Rec (StrHashMap<struct>)"; exit 1; }
grep -q "Entry_Rec" "$WORK/unit.c" || { echo "FAIL: selfhost-semaself-test — fixture C has no induced Entry_Rec typedef"; exit 1; }

cat >"$WORK/main.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

/* The allocator seam the fixture's `extern "C"` decls bind to (libc-backed). */
size_t mc_malloc(size_t n){ return (size_t)malloc(n); }
void   mc_free(size_t a, size_t n){ (void)n; free((void*)a); }

extern uint32_t color_code(int c);
extern uint32_t map_sum(void);
extern uint32_t map_missing(void);

int main(void) {
    int fails = 0;
    /* comma-less block switch arms select the right code per variant */
    if (color_code(0) != 1) { printf("FAIL: color_code(red)=%u\n",   color_code(0)); fails++; }
    if (color_code(1) != 2) { printf("FAIL: color_code(green)=%u\n",  color_code(1)); fails++; }
    if (color_code(2) != 3) { printf("FAIL: color_code(blue)=%u\n",   color_code(2)); fails++; }
    /* StrHashMap<Rec>: two struct values round-trip; (5+7)+(10+20)=42 */
    if (map_sum() != 42)    { printf("FAIL: map_sum()=%u\n", map_sum()); fails++; }
    /* an absent key yields the struct fallback (a.7 + b.0) = 7 */
    if (map_missing() != 7) { printf("FAIL: map_missing()=%u\n", map_missing()); fails++; }
    if (fails != 0) { printf("FAIL: selfhost-semaself-test — %d assertion(s) failed\n", fails); return 1; }
    return 0;
}
EOF

"$CLANG" -std=gnu11 -Wall -Wextra -Werror "$WORK/unit.c" "$WORK/main.c" -o "$WORK/prog"
if ! "$WORK/prog"; then
    echo "FAIL: selfhost-semaself-test — comma-switch + StrHashMap<struct> behavioral program returned non-zero"
    exit 1
fi
echo "PASS: selfhost-semaself-test — mcc2 compiled its OWN sema selfhost/sema.mc to clang-clean C (the 3rd self-compile module), and a comma-less block switch + a StrHashMap<Rec> (a hash map over a STRUCT value: put/get_or + absent-key fallback) ran correctly through clang (-Werror)"
exit 0
