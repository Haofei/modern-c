#!/usr/bin/env bash
# selfhost-trait-test: prove P5.10 TRAITS + `*mut dyn` DYNAMIC DISPATCH in mcc2
# (selfhost/parser.mc + sema.mc + emit_c.mc) end to end. The fixture
# (tests/toolchain/selfhost_trait_user.mc) runs the FULL front end (lex -> parse -> sema -> emit) on
# this mcc2-subset source (the Allocator pattern in miniature):
#
#   trait Counter { fn bump(self: *mut Self, n: u32) -> u32 }
#   struct Acc { total: u32 }
#   impl Counter for Acc {
#       fn bump(self: *mut Acc, n: u32) -> u32 { self.total = self.total + n; return self.total; }
#   }
#   fn drive(c: *mut dyn Counter, n: u32) -> u32 { return c.bump(n); }
#   export fn run() -> u32 { var a: Acc = .{ .total = 0 }; return drive(&a, 5) + drive(&a, 3); }
#
# Stage A dumps the emitted C (sema reports zero errors) and asserts the trait-object lowerings: the
# `Counter__vtable` fn-pointer typedef, the `Counter__dyn` {data,vtable} fat-pointer typedef, the impl
# method desugared to a free fn `Acc__bump` with `self->total` pointer field access, the `void*`-self
# thunk `Acc__bump__dyn`, the rodata `static const Counter__vtable Acc__Counter__vtable`, the coercion
# `(Counter__dyn){ .data = (void*)(&(a)), .vtbl = &Acc__Counter__vtable }`, and the dispatch
# `(c).vtbl->bump((c).data, n)`. Stage B clang-compiles the emitted C with a driver `main` that
# asserts run()==13 (5 then 8: Acc.total accumulates across two dispatched calls through one fat ptr).
#
# A green run proves mcc2 parsed, type-checked, and emitted C for a program using a trait + an impl +
# `*mut dyn` dynamic dispatch (vtable + thunk + fat-pointer coercion) that clang compiled and ran —
# the exact shape mcc2's own containers use (they thread `*mut dyn Allocator` on nearly every line).
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/selfhost_trait_user.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: selfhost-trait-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/trait.o" >/dev/null

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

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/dumper.c" "$WORK/trait.o" -o "$WORK/dumper"
"$WORK/dumper" "$WORK/out.c"

echo "----- emitted out.c (trait vtable + fat pointer + thunk + coercion + dispatch) -----"
cat "$WORK/out.c"

# ----- assert the emitted C contains the trait-object lowerings -----
gfails=0
grep -q "typedef struct Counter__vtable" "$WORK/out.c" || { echo "FAIL: emitted C missing 'typedef struct Counter__vtable' (vtable typedef)"; gfails=$((gfails+1)); }
grep -q "uint32_t (\*bump)(void\* self, uint32_t n);" "$WORK/out.c" || { echo "FAIL: emitted C missing the 'bump' vtable slot 'uint32_t (*bump)(void* self, uint32_t n);'"; gfails=$((gfails+1)); }
grep -q "typedef struct Counter__dyn" "$WORK/out.c" || { echo "FAIL: emitted C missing 'typedef struct Counter__dyn' (fat-pointer typedef)"; gfails=$((gfails+1)); }
grep -q "const Counter__vtable\* vtbl;" "$WORK/out.c" || { echo "FAIL: emitted C missing the fat-pointer 'const Counter__vtable* vtbl;' member"; gfails=$((gfails+1)); }
grep -q "uint32_t Acc__bump(Acc\* self, uint32_t n)" "$WORK/out.c" || { echo "FAIL: emitted C missing the desugared free fn 'uint32_t Acc__bump(Acc* self, uint32_t n)'"; gfails=$((gfails+1)); }
grep -q "self->total = " "$WORK/out.c" || { echo "FAIL: emitted C missing pointer field access 'self->total ='"; gfails=$((gfails+1)); }
grep -q "static uint32_t Acc__bump__dyn(void\* self, uint32_t n)" "$WORK/out.c" || { echo "FAIL: emitted C missing the void*-self thunk 'static uint32_t Acc__bump__dyn(void* self, uint32_t n)'"; gfails=$((gfails+1)); }
grep -q "return Acc__bump((Acc\*)self, n);" "$WORK/out.c" || { echo "FAIL: emitted C missing the thunk body 'return Acc__bump((Acc*)self, n);'"; gfails=$((gfails+1)); }
grep -q "static const Counter__vtable Acc__Counter__vtable = { &Acc__bump__dyn };" "$WORK/out.c" || { echo "FAIL: emitted C missing the rodata vtable 'static const Counter__vtable Acc__Counter__vtable = { &Acc__bump__dyn };'"; gfails=$((gfails+1)); }
grep -q "(Counter__dyn){ .data = (void\*)(&(a)), .vtbl = &Acc__Counter__vtable }" "$WORK/out.c" || { echo "FAIL: emitted C missing the fat-pointer coercion at the call site"; gfails=$((gfails+1)); }
grep -q "(c).vtbl->bump((c).data, n)" "$WORK/out.c" || { echo "FAIL: emitted C missing the dynamic dispatch '(c).vtbl->bump((c).data, n)'"; gfails=$((gfails+1)); }
if [ "$gfails" != "0" ]; then echo "FAIL: selfhost-trait-test — emitted-C content assertions failed"; exit 1; fi

# ----- Stage B: compile the emitted C + a driver main that asserts the numbers -----
cat >"$WORK/main.c" <<'EOF'
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>

extern uint32_t run(void);

int main(void) {
    if (run() != 13) { printf("FAIL: run()=%u want 13\n", run()); return 1; }
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/out.c" "$WORK/main.c" -o "$WORK/prog"
if "$WORK/prog"; then
    echo "PASS: selfhost-trait-test — mcc2 (parser+sema+emit_c) handled P5.10 TRAITS + \`*mut dyn\` DYNAMIC DISPATCH: a trait decl -> a Counter__vtable fn-pointer typedef + a Counter__dyn {data,vtable} fat pointer; an impl -> a desugared free fn Acc__bump (with self->total pointer field access) + a void*-self thunk Acc__bump__dyn + a rodata Acc__Counter__vtable; a *mut TYPE arg coerced to a {data,vtable} fat pointer at the call site; and c.bump(n) dispatched as (c).vtbl->bump((c).data, n) -> C that clang ran (run()==13: Acc.total accumulated 5 then 8 across two dispatched calls through one fat pointer)"
    exit 0
fi
echo "FAIL: selfhost-trait-test — program returned non-zero"
exit 1
