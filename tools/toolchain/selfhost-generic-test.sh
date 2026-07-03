#!/usr/bin/env bash
# selfhost-generic-test: prove P5.5 GENERICS (monomorphized) in mcc2 (selfhost/parser.mc + sema.mc
# + emit_c.mc) end to end. The fixture (tests/toolchain/selfhost_generic_user.mc) runs the FULL
# front end (lex -> parse -> sema -> emit) on two sources:
#
#   ACCEPT: `struct Box<T> { v: T }
#            fn unbox(comptime T: type, b: Box<T>) -> T { return b.v; }
#            fn add1(x: u32) -> u32 { return x + 1; }
#            fn box_plus_one(comptime T: type, b: Box<T>) -> T { return add1(b.v); }
#            export fn run(a: u32, c: u32) -> u32 {
#              var bi: Box<u32> = .{ .v = a }; var bj: Box<u32> = .{ .v = c };
#              return unbox(u32, bi) + unbox(u32, bj) + box_plus_one(u32, bi); }
#            export fn run64(a: u64) -> u64 { var b: Box<u64> = .{ .v = a }; return unbox(u64, b); }`
#           — a generic struct + generic fn instantiated at TWO distinct scalar types (u32 and u64),
#           with the two `Box<u32>` uses and two `unbox(u32, ..)` calls deduped to ONE copy each.
#           It also proves a monomorphic generic body can call a regular helper (`box_plus_one_u32`
#           calls `add1`). Stage A dumps the emitted C (sema reports zero errors) and asserts it
#           contains the monomorphic `Box_u32`, `unbox_u32`, `box_plus_one_u32`, `Box_u64`, and
#           `unbox_u64` (and NOT the generic template names). Stage B clang-compiles it with a `main`
#           and asserts run(2,3)==8 (2+3+3), run(10,20)==41, run64(7)==7.
#   REJECT: a generic call with the WRONG arity (`unbox(u32)`, missing the value arg) — sema must
#           report >= 1 error whose first code is `arg_count` (SmErr ordinal 2).
#
# A green run proves mcc2 parsed, type-checked, MONOMORPHIZED, and emitted C for a generic program
# that clang compiled and ran — the decisive self-compile blocker (mcc2's own data structures are
# all Vec<T>/StrHashMap<V>).
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/selfhost_generic_user.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: selfhost-generic-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/generic.o" >/dev/null

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

/* SmErr.arg_count ordinal (see selfhost/sema.mc). */
enum { SE_ARG_COUNT = 2 };

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: dumper out.c\n"); return 2; }
    int fails = 0;
    if (accept_err_count() != 0) { printf("FAIL: accept sema errors = %u want 0\n", accept_err_count()); fails++; }
    if (reject_err_count() == 0) { printf("FAIL: reject sema errors = 0, expected >= 1\n"); fails++; }
    if (reject_first_err() != SE_ARG_COUNT) { printf("FAIL: reject first-err = %u want %u (arg_count)\n", reject_first_err(), SE_ARG_COUNT); fails++; }
    if (fails != 0) return 1;

    FILE *f = fopen(argv[1], "wb");
    if (!f) { perror("fopen"); return 3; }
    uint32_t n = emit_len();
    for (uint32_t i = 0; i < n; i++) fputc((int)emit_byte(i), f);
    fclose(f);
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/dumper.c" "$WORK/generic.o" -o "$WORK/dumper"
"$WORK/dumper" "$WORK/out.c"

echo "----- emitted out.c (monomorphized Box_u32/unbox_u32 + Box_u64/unbox_u64) -----"
cat "$WORK/out.c"

# ----- assert the emitted C contains the monomorphic names (and not the raw template spellings) ---
gfails=0
for want in "Box_u32" "unbox_u32" "box_plus_one_u32" "Box_u64" "unbox_u64"; do
    grep -q "$want" "$WORK/out.c" || { echo "FAIL: emitted C missing monomorphic '$want'"; gfails=$((gfails+1)); }
done
grep -q "return add1(b.v);" "$WORK/out.c" || { echo "FAIL: emitted C missing regular helper call from generic body"; gfails=$((gfails+1)); }
# The generic type usage `Box<u32>` and the abstract-typed template `<T>` must NOT survive into C.
grep -q "Box<" "$WORK/out.c" && { echo "FAIL: emitted C still contains a generic type usage 'Box<'"; gfails=$((gfails+1)); }
# Exactly one Box_u32 typedef (dedup): count the 'typedef struct Box_u32' occurrences.
n_u32=$(grep -c "typedef struct Box_u32 {" "$WORK/out.c" || true)
[ "$n_u32" = "1" ] || { echo "FAIL: expected exactly 1 'typedef struct Box_u32' (dedup), got $n_u32"; gfails=$((gfails+1)); }
if [ "$gfails" != "0" ]; then echo "FAIL: selfhost-generic-test — emitted-C content assertions failed"; exit 1; fi

# ----- Stage B: compile the emitted C + a driver main that calls run / run64 -----
cat >"$WORK/main.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>

extern uint32_t run(uint32_t a, uint32_t c);
extern uint64_t run64(uint64_t a);

int main(void) {
    int fails = 0;
    if (run(2, 3) != 8)    { printf("FAIL: run(2,3)=%u want 8\n", run(2, 3)); fails++; }
    if (run(10, 20) != 41) { printf("FAIL: run(10,20)=%u want 41\n", run(10, 20)); fails++; }
    if (run64(7) != 7)     { printf("FAIL: run64(7)=%llu want 7\n", (unsigned long long)run64(7)); fails++; }
    if (fails != 0) { printf("FAIL: selfhost-generic-test — %d assertion(s) failed\n", fails); return 1; }
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/out.c" "$WORK/main.c" -o "$WORK/prog"
if "$WORK/prog"; then
    echo "PASS: selfhost-generic-test — mcc2 (parser+sema+emit_c) MONOMORPHIZED a generic program: generic struct Box<T> + generic fns unbox/box_plus_one instantiated at u32/u64 as needed (Box<u32>/unbox(u32) deduped to one copy each; box_plus_one_u32 calls regular helper add1) -> C that clang ran (run(2,3)==8, run(10,20)==41, run64(7)==7); and rejected a wrong-arity generic call (first-err arg_count)"
    exit 0
fi
echo "FAIL: selfhost-generic-test — program returned non-zero"
exit 1
