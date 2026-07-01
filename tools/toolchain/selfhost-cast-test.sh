#!/usr/bin/env bash
# selfhost-cast-test: prove P5.9 `as` CASTS + the `sizeof(T)`/`alignof(T)` builtins in mcc2
# (selfhost/parser.mc + sema.mc + emit_c.mc) end to end. The fixture
# (tests/toolchain/selfhost_cast_user.mc) runs the FULL front end (lex -> parse -> sema -> emit) on
# this mcc2-subset source:
#
#   fn size2() -> u32 { return sizeof(u32) as u32 * 2; }         // 4 * 2 = 8
#   fn align2() -> u32 { return alignof(u32) as u32; }           // 4
#   fn widen(a: u32) -> u64 { let x: u64 = a as u64; return x; } // widening cast u32 -> u64
#   fn mixed(s_len: u64, b: u32) -> u32 { return s_len as u32 + b; } // narrowing cast -> mixed-width add
#   fn tsize(comptime T: type) -> usize { return sizeof(T); }    // sizeof(T) inside a generic fn
#   export fn probe() -> u32 {
#       let a: usize = tsize(u32);                               // tsize_u32() = sizeof(uint32_t) = 4
#       let b: usize = tsize(u64);                               // tsize_u64() = sizeof(uint64_t) = 8
#       return size2() + (a as u32) + (b as u32);               // 8 + 4 + 8 = 20
#   }
#
# Stage A dumps the emitted C (sema reports zero errors) and asserts it contains the cast lowerings
# (`((uint64_t)(a))`, `((uint32_t)(s_len))`), the `sizeof(uint32_t)`/`_Alignof(uint32_t)` builtins,
# and BOTH monomorphic `sizeof` bodies (`sizeof(uint32_t)` in tsize_u32, `sizeof(uint64_t)` in
# tsize_u64) — proving the generic type-param substitution. Stage B clang-compiles the emitted C with
# a driver `main` that asserts the numbers (probe()==20, size2()==8, align2()==4, widen(9)==9,
# mixed(100,23)==123, tsize_u32()==4, tsize_u64()==8).
#
# A green run proves mcc2 parsed, type-checked, and emitted C for a program using casts + sizeof/alignof
# (incl. sizeof of a generic type param) that clang compiled and ran — the operations the memory/
# container deps use on nearly every line (`i * sizeof(T)`, `x as u32`).
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/selfhost_cast_user.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: selfhost-cast-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/cast.o" >/dev/null

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

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: dumper out.c\n"); return 2; }
    if (accept_err_count() != 0) { printf("FAIL: accept sema errors = %u want 0\n", accept_err_count()); return 1; }

    FILE *f = fopen(argv[1], "wb");
    if (!f) { perror("fopen"); return 3; }
    uint32_t n = emit_len();
    for (uint32_t i = 0; i < n; i++) fputc((int)emit_byte(i), f);
    fclose(f);
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/dumper.c" "$WORK/cast.o" -o "$WORK/dumper"
"$WORK/dumper" "$WORK/out.c"

echo "----- emitted out.c (cast + sizeof/alignof lowerings + generic sizeof substitution) -----"
cat "$WORK/out.c"

# ----- assert the emitted C contains the cast + sizeof/alignof lowerings -----
gfails=0
grep -q "((uint64_t)(a))" "$WORK/out.c" || { echo "FAIL: emitted C missing widening cast '((uint64_t)(a))'"; gfails=$((gfails+1)); }
grep -q "((uint32_t)(s_len))" "$WORK/out.c" || { echo "FAIL: emitted C missing narrowing cast '((uint32_t)(s_len))'"; gfails=$((gfails+1)); }
grep -q "((uint32_t)(sizeof(uint32_t)))" "$WORK/out.c" || { echo "FAIL: emitted C missing 'sizeof(u32) as u32' lowering '((uint32_t)(sizeof(uint32_t)))'"; gfails=$((gfails+1)); }
grep -q "((uint32_t)(_Alignof(uint32_t)))" "$WORK/out.c" || { echo "FAIL: emitted C missing 'alignof(u32) as u32' lowering '((uint32_t)(_Alignof(uint32_t)))'"; gfails=$((gfails+1)); }
# The generic sizeof(T) must substitute the concrete type per instantiation.
grep -q "size_t tsize_u32(void)" "$WORK/out.c" || { echo "FAIL: emitted C missing monomorphic 'size_t tsize_u32(void)'"; gfails=$((gfails+1)); }
grep -q "size_t tsize_u64(void)" "$WORK/out.c" || { echo "FAIL: emitted C missing monomorphic 'size_t tsize_u64(void)'"; gfails=$((gfails+1)); }
grep -q "return sizeof(uint64_t);" "$WORK/out.c" || { echo "FAIL: emitted C missing substituted 'return sizeof(uint64_t);' (sizeof(T) at T=u64)"; gfails=$((gfails+1)); }
if [ "$gfails" != "0" ]; then echo "FAIL: selfhost-cast-test — emitted-C content assertions failed"; exit 1; fi

# ----- Stage B: compile the emitted C + a driver main that asserts the numbers -----
cat >"$WORK/main.c" <<'EOF'
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>

extern uint32_t probe(void);
extern uint32_t size2(void);
extern uint32_t align2(void);
extern uint64_t widen(uint32_t a);
extern uint32_t mixed(uint64_t s_len, uint32_t b);
extern size_t   tsize_u32(void);
extern size_t   tsize_u64(void);

int main(void) {
    if (size2() != 8)   { printf("FAIL: size2()=%u want 8\n", size2()); return 1; }
    if (align2() != 4)  { printf("FAIL: align2()=%u want 4\n", align2()); return 1; }
    if (widen(9) != 9)  { printf("FAIL: widen(9)=%llu want 9\n", (unsigned long long)widen(9)); return 1; }
    if (mixed(100, 23) != 123) { printf("FAIL: mixed(100,23)=%u want 123\n", mixed(100,23)); return 1; }
    if (tsize_u32() != 4) { printf("FAIL: tsize_u32()=%zu want 4\n", tsize_u32()); return 1; }
    if (tsize_u64() != 8) { printf("FAIL: tsize_u64()=%zu want 8\n", tsize_u64()); return 1; }
    if (probe() != 20)  { printf("FAIL: probe()=%u want 20\n", probe()); return 1; }
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/out.c" "$WORK/main.c" -o "$WORK/prog"
if "$WORK/prog"; then
    echo "PASS: selfhost-cast-test — mcc2 (parser+sema+emit_c) handled P5.9 CASTS + sizeof/alignof: a widening cast (a as u64), a narrowing cast enabling mixed-width arithmetic (s_len as u32 + b), sizeof(u32)/alignof(u32) in arithmetic (size2()==8, align2()==4), and sizeof(T) inside a generic fn instantiated at TWO types (tsize_u32()==4, tsize_u64()==8 — substitution proven) -> C that clang ran (probe()==20)"
    exit 0
fi
echo "FAIL: selfhost-cast-test — program returned non-zero"
exit 1
