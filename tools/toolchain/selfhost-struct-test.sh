#!/usr/bin/env bash
# selfhost-struct-test: prove P5.1 STRUCT support in mcc2 (selfhost/parser.mc + sema.mc +
# emit_c.mc) end to end. The fixture (tests/toolchain/selfhost_struct_user.mc) runs the FULL front
# end (lex -> parse -> sema -> emit) on two sources:
#
#   ACCEPT: `struct Point { x: u32, y: u32 } export fn mk(a,b) -> u32 {
#            var p: Point = .{ .x = a, .y = b }; p.x = p.x + 1; return p.x + p.y; }`
#           — a struct decl, a typed `var`, a struct literal in a typed position, member read/write,
#           and a returned field. Stage A dumps the emitted C (sema reports zero errors); Stage B
#           clang-compiles it with a `main` calling mk(2,3) and asserts == 6 (2+1 + 3).
#   REJECT: the same struct with a literal naming a field `.z` that does not exist — sema must
#           report >= 1 error whose first code is `unknown_field` (SmErr ordinal 8).
#
# A green run proves mcc2 parsed, type-checked, and emitted C for a struct program that clang
# compiled and ran — the highest-value grammar feature toward true self-compile.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/selfhost_struct_user.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: selfhost-struct-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/struct.o" >/dev/null

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

/* SmErr.unknown_field ordinal (see selfhost/sema.mc). */
enum { SE_UNKNOWN_FIELD = 8 };

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: dumper out.c\n"); return 2; }
    int fails = 0;
    if (accept_err_count() != 0) { printf("FAIL: accept sema errors = %u want 0\n", accept_err_count()); fails++; }
    if (reject_err_count() == 0) { printf("FAIL: reject sema errors = 0, expected >= 1\n"); fails++; }
    if (reject_first_err() != SE_UNKNOWN_FIELD) { printf("FAIL: reject first-err = %u want %u (unknown_field)\n", reject_first_err(), SE_UNKNOWN_FIELD); fails++; }
    if (fails != 0) return 1;

    FILE *f = fopen(argv[1], "wb");
    if (!f) { perror("fopen"); return 3; }
    uint32_t n = emit_len();
    for (uint32_t i = 0; i < n; i++) fputc((int)emit_byte(i), f);
    fclose(f);
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/dumper.c" "$WORK/struct.o" -o "$WORK/dumper"
"$WORK/dumper" "$WORK/out.c"

echo "----- emitted out.c (struct Point + mk) -----"
cat "$WORK/out.c"

# ----- Stage B: compile the emitted C + a driver main that calls mk -----
cat >"$WORK/main.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>

extern uint32_t mk(uint32_t a, uint32_t b);

int main(void) {
    int fails = 0;
    if (mk(2, 3) != 6)  { printf("FAIL: mk(2,3)=%u want 6\n", mk(2, 3)); fails++; }
    if (mk(10, 5) != 16){ printf("FAIL: mk(10,5)=%u want 16\n", mk(10, 5)); fails++; }
    if (fails != 0) { printf("FAIL: selfhost-struct-test — %d assertion(s) failed\n", fails); return 1; }
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/out.c" "$WORK/main.c" -o "$WORK/prog"
if "$WORK/prog"; then
    echo "PASS: selfhost-struct-test — mcc2 (parser+sema+emit_c) compiled a struct program: struct decl, typed var, struct literal, member read/write, returned field -> C that clang ran (mk(2,3)==6, mk(10,5)==16); and rejected an unknown struct-literal field (first-err unknown_field)"
    exit 0
fi
echo "FAIL: selfhost-struct-test — program returned non-zero"
exit 1
