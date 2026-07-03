#!/usr/bin/env bash
# selfhost-slice-test: prove P5.7 PROPER SLICES (fat pointers) in mcc2 (selfhost/parser.mc + sema.mc
# + emit_c.mc) end to end. The fixture (tests/toolchain/selfhost_slice_user.mc) runs the FULL front
# end (lex -> parse -> sema -> emit) on two sources:
#
#   ACCEPT: `fn sumslice(s: []const u32) -> u32 { var i: usize = 0; var acc: u32 = 0;
#              let n: usize = s.len; while i < n { acc = acc + s[i]; i = i + 1; } return acc; }
#            export fn run() -> u32 {
#              var buf: [4]u32 = .{ 1, 2, 3, 4 };
#              let s: []const u32 = buf[0..4];   // ARRAY-base sub-slice -> fat pointer
#              let mid: []const u32 = s[1..3];   // SLICE-base sub-slice -> fat pointer
#              let a: u32 = sumslice(s); let m: u32 = sumslice(mid); return a + m;  // 10+5 = 15
#            }
#            export fn abtest() -> u8 {
#              var b8: [3]u8 = .{ 7, 8, 9 }; let bs: []const u8 = mem.as_bytes(&b8);
#              let n: usize = bs.len; var i: usize = 0; var acc: u8 = 0;
#              while i < n { acc = acc + bs[i]; i = i + 1; } return acc;            // 7+8+9 = 24
#            }`
#           — a slice TYPE `[]const T`, `.len`, element indexing (`s[i]` -> `s.ptr[i]`), sub-slicing
#           from BOTH an array base and a slice base, passing/returning slices by value, and the
#           `mem.as_bytes(&arr)` byte-view builtin (`&` address-of). Stage A dumps the emitted C
#           (sema reports zero errors) and asserts it contains the fat-pointer typedefs
#           `typedef struct mc_slice_const_u32 { const uint32_t* ptr; size_t len; }` and
#           `mc_slice_const_u8`, `.ptr[` element access, and a sub-slice compound literal. Stage B
#           clang-compiles it with a `main` and asserts run()==15 and abtest()==24.
#   REJECT: a `[4]u32` array sub-slice bound to a `[]const u8` (`let s: []const u8 = buf2[0..4]`) —
#           an element-type mismatch. Sema must report >= 1 error whose first code is `type_mismatch`
#           (SmErr ordinal 7).
#
# A green run proves mcc2 parsed, type-checked, and emitted C for a program using proper FAT-POINTER
# slices that clang compiled and ran — the #1 self-compile blocker (mcc2's own source uses
# `[]const u8` ~120 times: .len, indexing, sub-slicing, by-value passing everywhere).
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/selfhost_slice_user.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: selfhost-slice-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/slice.o" >/dev/null

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

/* SmErr.type_mismatch ordinal (see selfhost/sema.mc). */
enum { SE_TYPE_MISMATCH = 7 };

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: dumper out.c\n"); return 2; }
    int fails = 0;
    if (accept_err_count() != 0) { printf("FAIL: accept sema errors = %u want 0\n", accept_err_count()); fails++; }
    if (reject_err_count() == 0) { printf("FAIL: reject sema errors = 0, expected >= 1\n"); fails++; }
    if (reject_first_err() != SE_TYPE_MISMATCH) { printf("FAIL: reject first-err = %u want %u (type_mismatch)\n", reject_first_err(), SE_TYPE_MISMATCH); fails++; }
    if (fails != 0) return 1;

    FILE *f = fopen(argv[1], "wb");
    if (!f) { perror("fopen"); return 3; }
    uint32_t n = emit_len();
    for (uint32_t i = 0; i < n; i++) fputc((int)emit_byte(i), f);
    fclose(f);
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/dumper.c" "$WORK/slice.o" -o "$WORK/dumper"
"$WORK/dumper" "$WORK/out.c"

echo "----- emitted out.c (fat-pointer slice typedefs + .ptr[] index + sub-slice literals) -----"
cat "$WORK/out.c"

# ----- assert the emitted C contains the fat-pointer representation + slice lowerings -----
gfails=0
grep -q "typedef struct mc_slice_const_u32 {" "$WORK/out.c" || { echo "FAIL: emitted C missing 'typedef struct mc_slice_const_u32'"; gfails=$((gfails+1)); }
grep -q "const uint32_t\* ptr;" "$WORK/out.c" || { echo "FAIL: emitted C missing slice ptr field 'const uint32_t* ptr;'"; gfails=$((gfails+1)); }
grep -q "size_t len;" "$WORK/out.c" || { echo "FAIL: emitted C missing slice len field 'size_t len;'"; gfails=$((gfails+1)); }
grep -q "typedef struct mc_slice_const_u8 {" "$WORK/out.c" || { echo "FAIL: emitted C missing 'typedef struct mc_slice_const_u8'"; gfails=$((gfails+1)); }
grep -q "mc_slice_const_u32 sumslice(mc_slice_const_u32 s)" "$WORK/out.c" && { echo "FAIL: unexpected"; }
grep -q "uint32_t sumslice(mc_slice_const_u32 s)" "$WORK/out.c" || { echo "FAIL: emitted C missing by-value slice param 'sumslice(mc_slice_const_u32 s)'"; gfails=$((gfails+1)); }
grep -q "(s).ptr\[i\]" "$WORK/out.c" || { echo "FAIL: emitted C missing slice element access '(s).ptr[i]'"; gfails=$((gfails+1)); }
grep -q "s.len" "$WORK/out.c" || { echo "FAIL: emitted C missing slice '.len' access"; gfails=$((gfails+1)); }
grep -q "(mc_slice_const_u32){ .ptr = (buf) + (0)" "$WORK/out.c" || { echo "FAIL: emitted C missing array-base sub-slice literal"; gfails=$((gfails+1)); }
grep -q "(mc_slice_const_u32){ .ptr = (s).ptr + (1)" "$WORK/out.c" || { echo "FAIL: emitted C missing slice-base sub-slice literal"; gfails=$((gfails+1)); }
grep -q "(mc_slice_const_u8){ .ptr = (const uint8_t\*)(&(b8)), .len = sizeof(b8) }" "$WORK/out.c" || { echo "FAIL: emitted C missing mem.as_bytes byte-view literal"; gfails=$((gfails+1)); }
if [ "$gfails" != "0" ]; then echo "FAIL: selfhost-slice-test — emitted-C content assertions failed"; exit 1; fi

# ----- Stage B: compile the emitted C + a driver main that calls run / abtest -----
cat >"$WORK/main.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>

extern uint32_t run(void);
extern uint8_t  abtest(void);

int main(void) {
    int fails = 0;
    if (run() != 15)    { printf("FAIL: run()=%u want 15\n", run()); fails++; }
    if (abtest() != 24) { printf("FAIL: abtest()=%u want 24\n", abtest()); fails++; }
    if (fails != 0) { printf("FAIL: selfhost-slice-test — %d assertion(s) failed\n", fails); return 1; }
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/out.c" "$WORK/main.c" -o "$WORK/prog"
if "$WORK/prog"; then
    echo "PASS: selfhost-slice-test — mcc2 (parser+sema+emit_c) handled PROPER FAT-POINTER SLICES: a []const T lowered to 'typedef struct mc_slice_const_T { const T* ptr; size_t len; }', with .len, element indexing (s.ptr[i]), sub-slicing from both array and slice bases, by-value passing, and mem.as_bytes(&arr) -> []const u8 (run()==15, abtest()==24) -> C that clang ran; and rejected an element-type-mismatched sub-slice (first-err type_mismatch)"
    exit 0
fi
echo "FAIL: selfhost-slice-test — program returned non-zero"
exit 1
