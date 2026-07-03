#!/usr/bin/env bash
# selfhost-match-test: prove P5.11 MATCH-statement support in mcc2 (selfhost/parser.mc + sema.mc +
# emit_c.mc) end to end. The fixture (tests/toolchain/selfhost_match_user.mc) runs the FULL front
# end (lex -> parse -> sema -> emit) on three sources:
#
#   ACCEPT: `open enum Op: u32 { add, sub, mul } export fn ev(o: u32, a: u32, b: u32) -> u32 {
#            var k: Op = .add; if o == 1 { k = .sub; } if o == 2 { k = .mul; } var r: u32 = 0;
#            match k { .add => { r = a + b; }, .sub => { r = a - b; }, .mul => { r = a * b; },
#            _ => { r = 0; } } return r; }`
#           — a `match` over an enum subject with `.variant` arms + a `_` default. Stage A dumps the
#           emitted C (sema reports zero errors) and asserts it lowered to a plain C `switch` (in the
#           checked subset a `match` has no payload to bind, so it desugars to `switch_stmt`); Stage B
#           clang-compiles it with a `main` asserting ev(0,7,3)==10, ev(1,7,3)==4, ev(2,7,3)==21.
#   REJECT #1 (unknown variant): a `match` arm names `.div`, absent from `Op` — sema must report
#           >= 1 error whose first code is `unknown_variant` (SmErr ordinal 10).
#   REJECT #2 (nonexhaustive): a CLOSED `enum E { a, b, c }` matched over `.a`/`.b` only, no `_` —
#           sema must report >= 1 error whose first code is `nonexhaustive_switch` (SmErr ordinal 12).
#
# A green run proves mcc2 parsed, type-checked (with real exhaustiveness), and emitted C for a
# `match` program that clang compiled and ran, and rejected both an unknown variant arm and a
# nonexhaustive closed-enum match — i.e. the `match` keyword flows the whole pipeline like `switch`.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/selfhost_match_user.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: selfhost-match-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/match.o" >/dev/null

# ----- Stage A: dump the emitted C for the accept case + assert sema diagnostics -----
cat >"$WORK/dumper.c" <<'EOF'
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>

size_t mc_malloc(size_t n){ return (size_t)malloc(n); }
void   mc_free(size_t a, size_t n){ (void)n; free((void*)a); }

extern uint32_t emit_len(void);
extern uint32_t emit_byte(uint32_t i);
extern uint32_t accept_err_count(void);
extern uint32_t unknown_err_count(void);
extern uint32_t unknown_first_err(void);
extern uint32_t nonex_err_count(void);
extern uint32_t nonex_first_err(void);

/* SmErr ordinals (see selfhost/sema.mc). */
enum { SE_UNKNOWN_VARIANT = 10, SE_NONEXHAUSTIVE = 12 };

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: dumper out.c\n"); return 2; }
    int fails = 0;
    if (accept_err_count() != 0) { printf("FAIL: accept sema errors = %u want 0\n", accept_err_count()); fails++; }
    if (unknown_err_count() == 0) { printf("FAIL: unknown-variant reject sema errors = 0, expected >= 1\n"); fails++; }
    if (unknown_first_err() != SE_UNKNOWN_VARIANT) { printf("FAIL: unknown-variant first-err = %u want %u (unknown_variant)\n", unknown_first_err(), SE_UNKNOWN_VARIANT); fails++; }
    if (nonex_err_count() == 0) { printf("FAIL: nonexhaustive reject sema errors = 0, expected >= 1\n"); fails++; }
    if (nonex_first_err() != SE_NONEXHAUSTIVE) { printf("FAIL: nonexhaustive first-err = %u want %u (nonexhaustive_switch)\n", nonex_first_err(), SE_NONEXHAUSTIVE); fails++; }
    if (fails != 0) return 1;

    FILE *f = fopen(argv[1], "wb");
    if (!f) { perror("fopen"); return 3; }
    uint32_t n = emit_len();
    for (uint32_t i = 0; i < n; i++) fputc((int)emit_byte(i), f);
    fclose(f);
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/dumper.c" "$WORK/match.o" -o "$WORK/dumper"
"$WORK/dumper" "$WORK/out.c"

echo "----- emitted out.c (enum Op + match lowered to C switch in ev) -----"
cat "$WORK/out.c"

# ----- assert `match` lowered to a plain C `switch` (match == switch in the subset) -----
grep -q "switch (" "$WORK/out.c" || { echo "FAIL: emitted C missing 'switch (' — match should desugar to a C switch"; exit 1; }
grep -q "case Op_add:" "$WORK/out.c" || { echo "FAIL: emitted C missing 'case Op_add:' arm label"; exit 1; }
grep -q "default: " "$WORK/out.c" || { echo "FAIL: emitted C missing 'default:' for the _ arm"; exit 1; }

# ----- Stage B: compile the emitted C + a driver main that calls ev -----
cat >"$WORK/main.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>

extern uint32_t ev(uint32_t o, uint32_t a, uint32_t b);

int main(void) {
    int fails = 0;
    if (ev(0,7,3) != 10) { printf("FAIL: ev(0,7,3)=%u want 10\n", ev(0,7,3)); fails++; }
    if (ev(1,7,3) != 4)  { printf("FAIL: ev(1,7,3)=%u want 4\n", ev(1,7,3)); fails++; }
    if (ev(2,7,3) != 21) { printf("FAIL: ev(2,7,3)=%u want 21\n", ev(2,7,3)); fails++; }
    if (fails != 0) { printf("FAIL: selfhost-match-test — %d assertion(s) failed\n", fails); return 1; }
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/out.c" "$WORK/main.c" -o "$WORK/prog"
if "$WORK/prog"; then
    echo "PASS: selfhost-match-test — mcc2 (parser+sema+emit_c) compiled a match program: match over an enum subject with .variant arms + a _ default -> a plain C switch that clang ran (ev(0,7,3)==10, ev(1,7,3)==4, ev(2,7,3)==21); and rejected an unknown .variant arm (first-err unknown_variant) and a nonexhaustive closed-enum match (first-err nonexhaustive_switch). match == switch in the subset (no tagged-union payload to bind)"
    exit 0
fi
echo "FAIL: selfhost-match-test — program returned non-zero"
exit 1
