#!/usr/bin/env bash
# selfhost-lowlevel-test: prove P5.8 the LOW-LEVEL LAYER in mcc2 (selfhost/parser.mc + sema.mc +
# emit_c.mc) end to end. The fixture (tests/toolchain/selfhost_lowlevel_user.mc) runs the FULL front
# end (lex -> parse -> sema -> emit) on this source:
#
#   extern "C" fn mc_scratch() -> usize;
#   export fn probe() -> u32 {
#       let addr: usize = mc_scratch();
#       var out: u32 = 0;
#       unsafe {
#           raw.store<u32>(addr, 7);              // (*(uint32_t*)(addr) = (7))
#           let v: u32 = raw.load<u32>(addr);     // (*(uint32_t*)(addr))
#           let p: *mut u32 = raw.ptr<u32>(addr); // (uint32_t*)(addr)
#           p.* = p.* + v;                        // (*(p)) = ((*(p)) + v)   -> 7 + 7
#           out = p.*;
#       }
#       return out;                               // 14
#   }
#
# — an `extern "C"` prototype, an `unsafe` block (lowered to a plain `{ ... }`), all three `raw.*`
# intrinsics (cast-through-pointer), and pointer deref `p.*`. Stage A dumps the emitted C (sema
# reports zero errors) and asserts it contains the extern prototype `size_t mc_scratch(void);`, the
# `raw.store`/`raw.load`/`raw.ptr` cast lowerings, and the `(*(p))` deref. Stage B clang-compiles it
# with a driver that provides `mc_scratch` (a static buffer) and a `main` asserting probe()==14.
#
# A green run proves mcc2 parsed, type-checked, and emitted C for a program using the low-level layer
# that clang compiled and ran — the memory/container primitives self-compile needs (dynarray/mem/
# strbuf use unsafe+raw.* pervasively; lexer/main use extern "C").
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/selfhost_lowlevel_user.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: selfhost-lowlevel-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/ll.o" >/dev/null

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

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/dumper.c" "$WORK/ll.o" -o "$WORK/dumper"
"$WORK/dumper" "$WORK/out.c"

echo "----- emitted out.c (extern proto + raw.* cast lowerings + p.* deref) -----"
cat "$WORK/out.c"

# ----- assert the emitted C contains the low-level lowerings -----
gfails=0
grep -q "size_t mc_scratch(void);" "$WORK/out.c" || { echo "FAIL: emitted C missing extern prototype 'size_t mc_scratch(void);'"; gfails=$((gfails+1)); }
grep -q "(\*(uint32_t\*)(addr) = (7))" "$WORK/out.c" || { echo "FAIL: emitted C missing raw.store lowering '(*(uint32_t*)(addr) = (7))'"; gfails=$((gfails+1)); }
grep -q "(\*(uint32_t\*)(addr))" "$WORK/out.c" || { echo "FAIL: emitted C missing raw.load lowering '(*(uint32_t*)(addr))'"; gfails=$((gfails+1)); }
grep -q "uint32_t\* p = (uint32_t\*)(addr);" "$WORK/out.c" || { echo "FAIL: emitted C missing raw.ptr lowering 'uint32_t* p = (uint32_t*)(addr);'"; gfails=$((gfails+1)); }
grep -q "(\*(p)) = ((\*(p)) + v)" "$WORK/out.c" || { echo "FAIL: emitted C missing p.* deref lowering '(*(p)) = ((*(p)) + v)'"; gfails=$((gfails+1)); }
if [ "$gfails" != "0" ]; then echo "FAIL: selfhost-lowlevel-test — emitted-C content assertions failed"; exit 1; fi

# ----- Stage B: compile the emitted C + a driver main that supplies mc_scratch + calls probe -----
cat >"$WORK/main.c" <<'EOF'
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>

/* A static scratch cell; the emitted program stores/loads a u32 through its address. */
static uint32_t g_scratch;
size_t mc_scratch(void) { return (size_t)(uintptr_t)&g_scratch; }

extern uint32_t probe(void);

int main(void) {
    uint32_t r = probe();
    if (r != 14) { printf("FAIL: probe()=%u want 14\n", r); return 1; }
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/out.c" "$WORK/main.c" -o "$WORK/prog"
if "$WORK/prog"; then
    echo "PASS: selfhost-lowlevel-test — mcc2 (parser+sema+emit_c) handled the LOW-LEVEL LAYER: an 'extern \"C\" fn' prototype, an 'unsafe' block, all three raw.* intrinsics (raw.store<u32> -> (*(uint32_t*)(addr) = (7)), raw.load<u32> -> (*(uint32_t*)(addr)), raw.ptr<u32> -> (uint32_t*)(addr)), and pointer deref p.* -> (*(p)) -> C that clang ran (probe()==14)"
    exit 0
fi
echo "FAIL: selfhost-lowlevel-test — program returned non-zero"
exit 1
