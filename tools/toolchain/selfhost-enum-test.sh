#!/usr/bin/env bash
# selfhost-enum-test: prove P5.2 ENUM support in mcc2 (selfhost/parser.mc + sema.mc + emit_c.mc)
# end to end. The fixture (tests/toolchain/selfhost_enum_user.mc) runs the FULL front end
# (lex -> parse -> sema -> emit) on two sources:
#
#   ACCEPT: `open enum Color: u32 { red, green, blue } export fn pick(n: u32) -> u32 {
#            var c: Color = .red; if n == 1 { c = .green; } if n == 2 { c = .blue; }
#            return c.raw(); }`
#           — an open enum decl with a repr type, `.variant` literals in a typed `var` init and in
#           assignments, and `.raw()` on an enum value. Stage A dumps the emitted C (sema reports
#           zero errors); Stage B clang-compiles it with a `main` asserting pick(0)==0, pick(1)==1,
#           pick(2)==2.
#   REJECT: the same enum with a literal `.purple` naming a case that does not exist — sema must
#           report >= 1 error whose first code is `unknown_variant` (SmErr ordinal 10).
#
# A green run proves mcc2 parsed, type-checked, and emitted C for an enum program that clang
# compiled and ran — the next grammar feature toward true self-compile (mcc2's own source is built
# on `open enum` tags).
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/selfhost_enum_user.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: selfhost-enum-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/enum.o" >/dev/null

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
extern uint32_t reject_err_count(void);
extern uint32_t reject_first_err(void);

/* SmErr.unknown_variant ordinal (see selfhost/sema.mc). */
enum { SE_UNKNOWN_VARIANT = 10 };

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: dumper out.c\n"); return 2; }
    int fails = 0;
    if (accept_err_count() != 0) { printf("FAIL: accept sema errors = %u want 0\n", accept_err_count()); fails++; }
    if (reject_err_count() == 0) { printf("FAIL: reject sema errors = 0, expected >= 1\n"); fails++; }
    if (reject_first_err() != SE_UNKNOWN_VARIANT) { printf("FAIL: reject first-err = %u want %u (unknown_variant)\n", reject_first_err(), SE_UNKNOWN_VARIANT); fails++; }
    if (fails != 0) return 1;

    FILE *f = fopen(argv[1], "wb");
    if (!f) { perror("fopen"); return 3; }
    uint32_t n = emit_len();
    for (uint32_t i = 0; i < n; i++) fputc((int)emit_byte(i), f);
    fclose(f);
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/dumper.c" "$WORK/enum.o" -o "$WORK/dumper"
"$WORK/dumper" "$WORK/out.c"

echo "----- emitted out.c (enum Color + pick) -----"
cat "$WORK/out.c"

# ----- Stage B: compile the emitted C + a driver main that calls pick -----
cat >"$WORK/main.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>

extern uint32_t pick(uint32_t n);

int main(void) {
    int fails = 0;
    if (pick(0) != 0) { printf("FAIL: pick(0)=%u want 0\n", pick(0)); fails++; }
    if (pick(1) != 1) { printf("FAIL: pick(1)=%u want 1\n", pick(1)); fails++; }
    if (pick(2) != 2) { printf("FAIL: pick(2)=%u want 2\n", pick(2)); fails++; }
    if (fails != 0) { printf("FAIL: selfhost-enum-test — %d assertion(s) failed\n", fails); return 1; }
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/out.c" "$WORK/main.c" -o "$WORK/prog"
if "$WORK/prog"; then
    echo "PASS: selfhost-enum-test — mcc2 (parser+sema+emit_c) compiled an enum program: open enum decl with repr, .variant literals in a typed var init and assignments, and .raw() -> C that clang ran (pick(0)==0, pick(1)==1, pick(2)==2); and rejected an unknown .variant literal (first-err unknown_variant)"
    exit 0
fi
echo "FAIL: selfhost-enum-test — program returned non-zero"
exit 1
