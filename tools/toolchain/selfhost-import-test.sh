#!/usr/bin/env bash
# selfhost-import-test: prove P5.4 MULTI-MODULE `import` resolution in mcc2 (selfhost/main.mc loader
# + selfhost/parser.mc `import_decl` + emit_c forward prototypes), the step after P5.3, end to end.
#
# mcc2 has no separate module model: an `import "path";` is resolved by TEXTUAL INCLUSION. The loader
# reads the root file, transitively reads every distinct imported file (deduped by import string),
# and concatenates all module sources into one buffer, then runs the existing single-source pipeline
# once. This gate builds the mcc2 CLI, then exercises two graphs:
#
#   Stage BUILD:   mcc-cc.sh selfhost/main.mc -> main.o ; clang link with mcc2_rt.c -> mcc2
#   Stage LINEAR:  mainmod.mc `import "mathlib.mc"` + calls dbl(); `mcc2 mainmod.mc > out.c`,
#                  clang out.c + a driver asserting compute(5)==11 (dbl(5)+1) -> run.
#   Stage DIAMOND: a.mc imports b.mc and c.mc; b.mc and c.mc BOTH import d.mc. mcc2 must flatten the
#                  graph WITHOUT a duplicate-decl error for d (dedup), emit d exactly once, and the
#                  compiled program must assert a(5)==122 (b=16, c=106).
#
# A green run proves mcc2 resolved import paths, deduped a diamond, flattened the modules into one
# translation unit, and emitted C that clang compiled and ran across module boundaries.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/selfhost/main.mc"
RT="$HERE/tools/toolchain/mcc2_rt.c"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: selfhost-import-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ----- Stage BUILD: compile selfhost/main.mc and link the mcc2 CLI -----
MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/main.o" --profile=hosted >/dev/null
"$CLANG" "$WORK/main.o" "$RT" -lm -o "$WORK/mcc2"

# ----- Stage LINEAR: a two-module program (importer calls an exported fn from the import) -----
printf 'export fn dbl(x: u32) -> u32 { return x + x; }\n' > "$WORK/mathlib.mc"
printf 'import "mathlib.mc";\nexport fn compute(n: u32) -> u32 { return dbl(n) + 1; }\n' > "$WORK/mainmod.mc"
"$WORK/mcc2" "$WORK/mainmod.mc" > "$WORK/lin.c"
if [ ! -s "$WORK/lin.c" ]; then echo "FAIL: selfhost-import-test — mcc2 emitted no C for mainmod.mc"; exit 1; fi
cat >"$WORK/lin_drv.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>
extern uint32_t compute(uint32_t n);
int main(void) {
    if (compute(5) != 11) { printf("FAIL: compute(5)=%u want 11\n", compute(5)); return 1; }
    return 0;
}
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/lin.c" "$WORK/lin_drv.c" -o "$WORK/lin"
if ! "$WORK/lin"; then echo "FAIL: selfhost-import-test — linear round-trip compute(5)!=11"; exit 1; fi
echo "PASS: selfhost-import-test — linear import: mcc2 mainmod.mc (import mathlib.mc) -> C -> run, compute(5)==11"

# ----- Stage DIAMOND: a -> {b, c} -> d ; d must be included exactly once (dedup) -----
printf 'export fn d(x: u32) -> u32 { return x + 1; }\n' > "$WORK/d.mc"
printf 'import "d.mc";\nexport fn b(x: u32) -> u32 { return d(x) + 10; }\n' > "$WORK/b.mc"
printf 'import "d.mc";\nexport fn c(x: u32) -> u32 { return d(x) + 100; }\n' > "$WORK/c.mc"
printf 'import "b.mc";\nimport "c.mc";\nexport fn a(x: u32) -> u32 { return b(x) + c(x); }\n' > "$WORK/a.mc"
"$WORK/mcc2" "$WORK/a.mc" > "$WORK/dia.c"
if [ ! -s "$WORK/dia.c" ]; then echo "FAIL: selfhost-import-test — mcc2 emitted no C for a.mc"; exit 1; fi
NDEFS=$(grep -c 'uint32_t d(uint32_t x) {' "$WORK/dia.c" || true)
if [ "$NDEFS" != "1" ]; then echo "FAIL: selfhost-import-test — diamond emitted d() ${NDEFS} times, want 1 (dedup broken)"; exit 1; fi
cat >"$WORK/dia_drv.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>
extern uint32_t a(uint32_t x);
int main(void) {
    if (a(5) != 122) { printf("FAIL: a(5)=%u want 122\n", a(5)); return 1; }
    return 0;
}
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/dia.c" "$WORK/dia_drv.c" -o "$WORK/dia"
if ! "$WORK/dia"; then echo "FAIL: selfhost-import-test — diamond round-trip a(5)!=122"; exit 1; fi
echo "PASS: selfhost-import-test — diamond dedup: a->{b,c}->d flattened once (d emitted 1x), a(5)==122"

echo "PASS: selfhost-import-test — built mcc2, multi-module import + diamond dedup verified"
exit 0
