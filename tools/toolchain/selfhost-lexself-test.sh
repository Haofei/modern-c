#!/usr/bin/env bash
# selfhost-lexself-test: the LANDMARK self-compile milestone — mcc2 compiling its OWN lexer. After
# gaining CHARACTER LITERALS (`'a'`/`'\n'`/`'\\'`/`'0'` -> a `char_literal` primary typed `u8`,
# emitted as a C char literal) and MODULE-LEVEL `const` declarations (`const NAME: T = <const-expr>;`
# and `export const` -> a file-scope `static const`), mcc2 can lower `selfhost/lexer.mc` (its own
# real lexer, 650 lines, plus its std deps mem/ascii/addr/alloc/dynarray) all the way to clang-clean C.
#
#   Stage BUILD:     mcc-cc.sh selfhost/main.mc -> main.o ; clang link with mcc2_rt.c -> mcc2
#   Stage LANDMARK:  `mcc2 <root> > lexer.c`, then `clang -std=gnu11 -c lexer.c` — mcc2 compiles ITS
#                    OWN LEXER (selfhost/lexer.mc) to C with NO parse/sema diagnostics on stderr, and
#                    that C compiles clean. lexer.mc imports std deps; the macOS host cannot resolve a
#                    cwd-relative import (G29), so a tiny ROOT wrapper at the repo root
#                    (`import "selfhost/lexer.mc";`) is used — the concat loader's ROOT-dir-relative
#                    resolution then finds lexer.mc AND its transitive std deps under the repo root.
#   Stage UNIT:      `mcc2 selfhost_charconst_user.mc > unit.c`, clang-compile (-Werror) unit.c + a
#                    driver, and assert char-literal comparisons (`'a'`/`'\n'`/`'\\'`/`'0'`), a char
#                    const (`const NL: u8 = '\n'`), and an integer const (`const STRIDE: u32 = 5`) all
#                    behave correctly AT RUNTIME — behavior, not just compile.
#
# A green run proves mcc2 (lex->parse->sema->emit_c) turned its OWN lexer source into clang-clean C.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/selfhost/main.mc"
RT="$HERE/tools/toolchain/mcc2_rt.c"
LEXER="$HERE/selfhost/lexer.mc"
FIXTURE="$HERE/tests/toolchain/selfhost_charconst_user.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: selfhost-lexself-test (clang not found)"; exit 0; }

# ROOT wrapper at the repo root so the concat loader's root-dir-relative resolution finds lexer.mc
# (and, transitively, its std deps). Cleaned up on exit.
ROOT="$HERE/.selfhost_lexself_root_$$.mc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" "$ROOT"' EXIT

# ----- Stage BUILD: compile selfhost/main.mc and link the mcc2 CLI -----
MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/main.o" --profile=hosted >/dev/null
"$CLANG" "$WORK/main.o" "$RT" -lm -o "$WORK/mcc2"

# ----- Stage LANDMARK: mcc2 compiles its OWN lexer selfhost/lexer.mc -> clang-clean C -----
[ -f "$LEXER" ] || { echo "FAIL: selfhost-lexself-test — selfhost/lexer.mc not found at $LEXER"; exit 1; }
printf 'import "selfhost/lexer.mc";\n' > "$ROOT"
"$WORK/mcc2" "$ROOT" > "$WORK/lexer.c" 2> "$WORK/lexer.err"
if [ -s "$WORK/lexer.err" ]; then
    echo "FAIL: selfhost-lexself-test — mcc2 reported diagnostics compiling its own lexer selfhost/lexer.mc:"
    cat "$WORK/lexer.err"
    exit 1
fi
if [ ! -s "$WORK/lexer.c" ]; then echo "FAIL: selfhost-lexself-test — mcc2 emitted no C for selfhost/lexer.mc"; exit 1; fi
# Sanity: the emitted C must contain the lexer's own artifacts — a char-literal comparison and the
# module const emitted as a file-scope static const.
grep -q "static const" "$WORK/lexer.c" || { echo "FAIL: selfhost-lexself-test — emitted lexer.c has no module const (static const)"; exit 1; }
grep -q "keyword_kind" "$WORK/lexer.c" || { echo "FAIL: selfhost-lexself-test — emitted lexer.c is missing the lexer body (keyword_kind)"; exit 1; }

# Compile-check the emitted C (the milestone assertion). `-std=gnu11` because the subset's Result/
# optional lowering (present transitively via the std deps) relies on GNU statement-expressions.
"$CLANG" -std=gnu11 -c "$WORK/lexer.c" -o "$WORK/lexer.o" 2> "$WORK/lexer.cc.err" || {
    echo "FAIL: selfhost-lexself-test — clang could not compile mcc2's emitted lexer.c:"
    head -20 "$WORK/lexer.cc.err"
    exit 1
}
echo "LANDMARK: mcc2 compiled its OWN lexer selfhost/lexer.mc -> clang-clean C (clang -std=gnu11 -c lexer.c OK)"

# ----- Stage UNIT: char literals + module const behavioral round-trip -----
[ -f "$FIXTURE" ] || { echo "FAIL: selfhost-lexself-test — fixture not found at $FIXTURE"; exit 1; }
"$WORK/mcc2" "$FIXTURE" > "$WORK/unit.c" 2> "$WORK/unit.err"
if [ -s "$WORK/unit.err" ]; then
    echo "FAIL: selfhost-lexself-test — mcc2 reported diagnostics compiling the char/const fixture:"
    cat "$WORK/unit.err"
    exit 1
fi
if [ ! -s "$WORK/unit.c" ]; then echo "FAIL: selfhost-lexself-test — mcc2 emitted no C for the char/const fixture"; exit 1; fi
grep -q "static const" "$WORK/unit.c" || { echo "FAIL: selfhost-lexself-test — fixture C has no module const (static const)"; exit 1; }

echo "----- emitted unit.c (char literals + module const -> C char literals + file-scope static const) -----"
cat "$WORK/unit.c"

cat >"$WORK/main.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>

extern uint32_t classify(uint8_t c);
extern uint32_t stride_of(uint32_t n);
extern uint32_t newline_code(void);
extern uint8_t tab_byte(void);

int main(void) {
    int fails = 0;
    /* char-literal comparisons across the escape forms */
    if (classify('a')  != 1) { printf("FAIL: classify('a')=%u\n",  classify('a'));  fails++; }
    if (classify('Z')  != 2) { printf("FAIL: classify('Z')=%u\n",  classify('Z'));  fails++; }
    if (classify('\n') != 3) { printf("FAIL: classify('\\n')=%u\n", classify('\n')); fails++; }
    if (classify('\\') != 4) { printf("FAIL: classify('\\\\')=%u\n", classify('\\')); fails++; }
    if (classify('0')  != 5) { printf("FAIL: classify('0')=%u\n",  classify('0'));  fails++; }
    if (classify('q')  != 0) { printf("FAIL: classify('q')=%u\n",  classify('q'));  fails++; }
    /* module const in arithmetic (STRIDE == 5) */
    if (stride_of(3)  != 15) { printf("FAIL: stride_of(3)=%u\n",  stride_of(3));  fails++; }
    /* char const read as a byte value (NL == '\n' == 10) */
    if (newline_code() != 10) { printf("FAIL: newline_code()=%u\n", newline_code()); fails++; }
    /* char literal returned directly as a byte ('\t' == 9) */
    if (tab_byte() != 9) { printf("FAIL: tab_byte()=%u\n", (unsigned)tab_byte()); fails++; }
    if (fails != 0) { printf("FAIL: selfhost-lexself-test — %d assertion(s) failed\n", fails); return 1; }
    return 0;
}
EOF

"$CLANG" -std=gnu11 -Wall -Wextra -Werror "$WORK/unit.c" "$WORK/main.c" -o "$WORK/prog"
if ! "$WORK/prog"; then
    echo "FAIL: selfhost-lexself-test — char/const behavioral program returned non-zero"
    exit 1
fi
echo "PASS: selfhost-lexself-test — mcc2 compiled its OWN lexer selfhost/lexer.mc to clang-clean C (the self-compile landmark), and char literals ('a'/'\\n'/'\\\\'/'0') + a char const (const NL: u8) + an integer const (const STRIDE: u32) all ran correctly through clang (-Werror)"
exit 0
