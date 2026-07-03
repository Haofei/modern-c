#!/usr/bin/env bash
# selfhost-array-test: prove P5.6 FIXED `[N]T` ARRAYS in mcc2 (selfhost/parser.mc + sema.mc +
# emit_c.mc) end to end. The fixture (tests/toolchain/selfhost_array_user.mc) runs the FULL front
# end (lex -> parse -> sema -> emit) on two sources:
#
#   ACCEPT: `export fn asum() -> u32 {
#              var a: [4]u32 = .{ 0, 10, 20, 30 };
#              var i: u32 = 0; var s: u32 = 0;
#              while i < 4 { s = s + a[i]; i = i + 1; }
#              a[0] = 5;
#              return s + a[0];            // (0+10+20+30) + 5 = 65
#            }
#            struct Buf<T> { data: [4]T, len: usize }
#            fn mkbuf(comptime T: type, x: T) -> Buf<T> { .. }   // generic, array field
#            fn first(comptime T: type, b: Buf<T>) -> T { return b.data[0]; }
#            export fn bufsum() -> u32 { var b: Buf<u32> = mkbuf(u32, 7); return first(u32, b) + first(u32, b); }`  // 14
#           — a fixed-size array type + positional array literal + element read/write, PLUS a generic
#           struct with a `[4]T` field monomorphized at u32 (`[4]T` -> `uint32_t data[4]`). Stage A
#           dumps the emitted C (sema reports zero errors) and asserts it contains `uint32_t a[4]`
#           and the monomorphic `Buf_u32` with a `uint32_t data[4]` field. Stage B clang-compiles it
#           with a `main` and asserts asum()==65 and bufsum()==14.
#   REJECT: an array literal whose element count != the target `[4]u32`'s N (`.{ 0, 10, 20 }`) — sema
#           must report >= 1 error whose first code is `array_length` (SmErr ordinal 15).
#
# A green run proves mcc2 parsed, type-checked, MONOMORPHIZED (arrays-in-generics), and emitted C for
# a program using fixed arrays that clang compiled and ran — a self-compile blocker (mcc2's own AST
# fixtures + byte tables use `[N]T` pervasively).
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/selfhost_array_user.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: selfhost-array-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/array.o" >/dev/null

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

/* SmErr.array_length ordinal (see selfhost/sema.mc). */
enum { SE_ARRAY_LENGTH = 15 };

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: dumper out.c\n"); return 2; }
    int fails = 0;
    if (accept_err_count() != 0) { printf("FAIL: accept sema errors = %u want 0\n", accept_err_count()); fails++; }
    if (reject_err_count() == 0) { printf("FAIL: reject sema errors = 0, expected >= 1\n"); fails++; }
    if (reject_first_err() != SE_ARRAY_LENGTH) { printf("FAIL: reject first-err = %u want %u (array_length)\n", reject_first_err(), SE_ARRAY_LENGTH); fails++; }
    if (fails != 0) return 1;

    FILE *f = fopen(argv[1], "wb");
    if (!f) { perror("fopen"); return 3; }
    uint32_t n = emit_len();
    for (uint32_t i = 0; i < n; i++) fputc((int)emit_byte(i), f);
    fclose(f);
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/dumper.c" "$WORK/array.o" -o "$WORK/dumper"
"$WORK/dumper" "$WORK/out.c"

echo "----- emitted out.c (fixed arrays + monomorphized Buf_u32 with uint32_t data[4]) -----"
cat "$WORK/out.c"

# ----- assert the emitted C contains the fixed-array declarators (and no surviving generic type) ---
gfails=0
grep -q "uint32_t a\[4\]" "$WORK/out.c" || { echo "FAIL: emitted C missing fixed-array local 'uint32_t a[4]'"; gfails=$((gfails+1)); }
grep -q "typedef struct Buf_u32 {" "$WORK/out.c" || { echo "FAIL: emitted C missing monomorphic 'typedef struct Buf_u32'"; gfails=$((gfails+1)); }
grep -q "uint32_t data\[4\]" "$WORK/out.c" || { echo "FAIL: emitted C missing monomorphic array field 'uint32_t data[4]'"; gfails=$((gfails+1)); }
grep -q "Buf<" "$WORK/out.c" && { echo "FAIL: emitted C still contains a generic type usage 'Buf<'"; gfails=$((gfails+1)); }
if [ "$gfails" != "0" ]; then echo "FAIL: selfhost-array-test — emitted-C content assertions failed"; exit 1; fi

# ----- Stage B: compile the emitted C + a driver main that calls asum / bufsum -----
cat >"$WORK/main.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>

extern uint32_t asum(void);
extern uint32_t bufsum(void);

int main(void) {
    int fails = 0;
    if (asum() != 65)   { printf("FAIL: asum()=%u want 65\n", asum()); fails++; }
    if (bufsum() != 14) { printf("FAIL: bufsum()=%u want 14\n", bufsum()); fails++; }
    if (fails != 0) { printf("FAIL: selfhost-array-test — %d assertion(s) failed\n", fails); return 1; }
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/out.c" "$WORK/main.c" -o "$WORK/prog"
if "$WORK/prog"; then
    echo "PASS: selfhost-array-test — mcc2 (parser+sema+emit_c) handled FIXED [N]T ARRAYS: a [4]u32 local with a positional array literal + element read/write (asum()==65), and a generic struct Buf<T> with a [4]T field monomorphized at u32 to 'uint32_t data[4]' (bufsum()==14) -> C that clang ran; and rejected a wrong-length array literal (first-err array_length)"
    exit 0
fi
echo "FAIL: selfhost-array-test — program returned non-zero"
exit 1
