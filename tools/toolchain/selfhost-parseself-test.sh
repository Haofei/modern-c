#!/usr/bin/env bash
# selfhost-parseself-test: the LANDMARK self-compile milestone — mcc2 compiling its OWN parser. After
# gaining STRUCT-type-argument monomorphization (a generic container/function instantiated at a NAMED
# struct type: `Vec<Node>`, `vec_push(Node, ..)`, `vec_get(Node, ..)`, not just scalars) plus a
# dependency-ordered struct emission (a struct that embeds another BY VALUE — `Parser { tl: TokenList,
# nodes: Vec<Node> }` — is emitted AFTER what it embeds), mcc2 can lower `selfhost/parser.mc` (its own
# real index-arena parser, ~1.7k lines, plus its std deps mem/ascii/addr/alloc/dynarray/lexer) all the
# way to clang-clean C.
#
#   Stage BUILD:     mcc-cc.sh selfhost/main.mc -> main.o ; clang link with mcc2_rt.c -> mcc2
#   Stage LANDMARK:  `mcc2 <root> > parser.c`, then `clang -std=gnu11 -c parser.c` — mcc2 compiles ITS
#                    OWN PARSER (selfhost/parser.mc) to C with NO parse/sema diagnostics on stderr, and
#                    that C compiles clean. parser.mc imports std + lexer deps; the macOS host cannot
#                    resolve a cwd-relative import (G29), so a tiny ROOT wrapper at the repo root
#                    (`import "selfhost/parser.mc";`) is used — the concat loader's ROOT-dir-relative
#                    resolution then finds parser.mc AND its transitive deps under the repo root.
#   Stage UNIT:      `mcc2 <root-of-fixture> > unit.c`, clang-compile (-Werror) unit.c + a driver, and
#                    assert that a `Vec<Pt>` (a generic container over a STRUCT element) round-trips
#                    struct values through push/get and that a field read off a get'd element is correct
#                    AT RUNTIME — behavior, not just compile.
#
# A green run proves mcc2 (lex->parse->sema->emit_c) turned its OWN parser source into clang-clean C.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/selfhost/main.mc"
RT="$HERE/tools/toolchain/mcc2_rt.c"
PARSER="$HERE/selfhost/parser.mc"
FIXTURE="$HERE/tests/toolchain/selfhost_genstruct_user.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: selfhost-parseself-test (clang not found)"; exit 0; }

# ROOT wrappers at the repo root so the concat loader's root-dir-relative resolution finds the target
# .mc (and, transitively, its std deps). Cleaned up on exit.
PROOT="$HERE/.selfhost_parseself_root_$$.mc"
UROOT="$HERE/.selfhost_parseself_unit_$$.mc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" "$PROOT" "$UROOT"' EXIT

# ----- Stage BUILD: compile selfhost/main.mc and link the mcc2 CLI -----
MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/main.o" --profile=hosted >/dev/null
"$CLANG" "$WORK/main.o" "$RT" -lm -o "$WORK/mcc2"

# ----- Stage LANDMARK: mcc2 compiles its OWN parser selfhost/parser.mc -> clang-clean C -----
[ -f "$PARSER" ] || { echo "FAIL: selfhost-parseself-test — selfhost/parser.mc not found at $PARSER"; exit 1; }
printf 'import "selfhost/parser.mc";\n' > "$PROOT"
"$WORK/mcc2" "$PROOT" > "$WORK/parser.c" 2> "$WORK/parser.err"
if [ -s "$WORK/parser.err" ]; then
    echo "FAIL: selfhost-parseself-test — mcc2 reported diagnostics compiling its own parser selfhost/parser.mc:"
    cat "$WORK/parser.err"
    exit 1
fi
if [ ! -s "$WORK/parser.c" ]; then echo "FAIL: selfhost-parseself-test — mcc2 emitted no C for selfhost/parser.mc"; exit 1; fi
# Sanity: the emitted C must contain the STRUCT-type-argument monomorphization artifacts — a
# `Vec_Node` typedef and a `vec_push_Node` function (the parser's index-arena `Vec<Node>`).
grep -q "Vec_Node" "$WORK/parser.c" || { echo "FAIL: selfhost-parseself-test — emitted parser.c has no monomorphic Vec_Node (struct type-arg not instantiated)"; exit 1; }
grep -q "vec_push_Node" "$WORK/parser.c" || { echo "FAIL: selfhost-parseself-test — emitted parser.c has no vec_push_Node (generic fn over a struct type-arg not instantiated)"; exit 1; }

# Compile-check the emitted C (the milestone assertion). `-std=gnu11` because the subset's Result/
# optional lowering (present transitively via the std deps) relies on GNU statement-expressions.
"$CLANG" -std=gnu11 -c "$WORK/parser.c" -o "$WORK/parser.o" 2> "$WORK/parser.cc.err" || {
    echo "FAIL: selfhost-parseself-test — clang could not compile mcc2's emitted parser.c:"
    head -30 "$WORK/parser.cc.err"
    exit 1
}
echo "LANDMARK: mcc2 compiled its OWN parser selfhost/parser.mc -> clang-clean C (clang -std=gnu11 -c parser.c OK)"

# ----- Stage UNIT: Vec<struct> monomorphization behavioral round-trip -----
[ -f "$FIXTURE" ] || { echo "FAIL: selfhost-parseself-test — fixture not found at $FIXTURE"; exit 1; }
printf 'import "tests/toolchain/selfhost_genstruct_user.mc";\n' > "$UROOT"
"$WORK/mcc2" "$UROOT" > "$WORK/unit.c" 2> "$WORK/unit.err"
if [ -s "$WORK/unit.err" ]; then
    echo "FAIL: selfhost-parseself-test — mcc2 reported diagnostics compiling the Vec<struct> fixture:"
    cat "$WORK/unit.err"
    exit 1
fi
if [ ! -s "$WORK/unit.c" ]; then echo "FAIL: selfhost-parseself-test — mcc2 emitted no C for the Vec<struct> fixture"; exit 1; fi
grep -q "Vec_Pt" "$WORK/unit.c" || { echo "FAIL: selfhost-parseself-test — fixture C has no monomorphic Vec_Pt (Vec<struct>)"; exit 1; }
grep -q "vec_push_Pt" "$WORK/unit.c" || { echo "FAIL: selfhost-parseself-test — fixture C has no vec_push_Pt"; exit 1; }

cat >"$WORK/main.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

/* The allocator seam the fixture's `extern "C"` decls bind to (libc-backed). */
size_t mc_malloc(size_t n){ return (size_t)malloc(n); }
void   mc_free(size_t a, size_t n){ (void)n; free((void*)a); }

extern uint32_t sum_pts(void);
extern uint32_t second_y(uint32_t n);

int main(void) {
    int fails = 0;
    /* push two Pt struct values into a Vec<Pt>, read them back, sum their fields: (3+4)+(10+20)=37 */
    if (sum_pts() != 37)      { printf("FAIL: sum_pts()=%u\n", sum_pts()); fails++; }
    /* len tracks pushes (2) and a field read off a get'd struct element is correct: 2*100 + (5+5) */
    if (second_y(5) != 210)   { printf("FAIL: second_y(5)=%u\n", second_y(5)); fails++; }
    if (second_y(9) != 218)   { printf("FAIL: second_y(9)=%u\n", second_y(9)); fails++; }
    if (fails != 0) { printf("FAIL: selfhost-parseself-test — %d assertion(s) failed\n", fails); return 1; }
    return 0;
}
EOF

"$CLANG" -std=gnu11 -Wall -Wextra -Werror "$WORK/unit.c" "$WORK/main.c" -o "$WORK/prog"
if ! "$WORK/prog"; then
    echo "FAIL: selfhost-parseself-test — Vec<struct> behavioral program returned non-zero"
    exit 1
fi
echo "PASS: selfhost-parseself-test — mcc2 compiled its OWN parser selfhost/parser.mc to clang-clean C (the self-compile landmark), and a Vec<Pt> (generic container over a STRUCT element: push/get struct values + read a field) ran correctly through clang (-Werror)"
exit 0
