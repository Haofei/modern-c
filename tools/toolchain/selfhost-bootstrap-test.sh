#!/usr/bin/env bash
# selfhost-bootstrap-test: the subset bootstrap/fixpoint gate (docs/self-host.md (§1)). Where the
# five selfhost-*self-test gates each prove ONE mcc2 module self-compiles to clang-clean C, this
# gate proves the current selfhost subset closes a bootstrap loop: the selected compiler builds
# mcc2, mcc2 emits mcc2', and the two produce byte-identical output — a fixpoint. This is a subset
# bootstrap/fixpoint check, not a full compiler-replacement proof.
#
#   Stage-1 BUILD:   mcc-cc.sh selfhost/main.mc -> main.o ; clang link with mcc2_rt.c -> mcc2
#                    (the selected `mcc` builds the first-generation mcc2, exactly as mcc2-cli-test
#                    does).
#   Stage-2 EMIT:    `mcc2 <root> > mcc2prime.c` — mcc2's textual-concatenation import loader flattens
#                    the ENTIRE import graph (main + emit_c + sema + parser + lexer + all std deps)
#                    into one C translation unit. Asserts mcc2 exits 0 with EMPTY stderr (mcc2 emits
#                    ZERO diagnostics compiling its own full source). A tiny ROOT wrapper at the repo
#                    root (`import "selfhost/main.mc";`) lets the loader's root-dir-relative resolution
#                    (G29) find main.mc AND all of its transitive deps.
#   Stage-2 BUILD:   `clang -std=gnu11 mcc2prime.c mcc2_rt.c -lm -o mcc2prime` — the mcc2-emitted C
#                    links into a second-generation compiler, mcc2'. (`-std=gnu11`, warnings ALLOWED:
#                    the emitted C has the same known-harmless -Wswitch-bool/-Wreturn-type warnings
#                    from std/ascii + switch-on-bool lowerings as the emitself/mainself gates; NO
#                    -Werror here.)
#   FIXPOINT+RUN:    compile a small program with BOTH mcc2 and mcc2', assert the emitted C is
#                    BYTE-IDENTICAL (the fixpoint: gen-1 and gen-2 agree), AND clang-compile+run
#                    mcc2''s output to prove mcc2' produces working code (add(2,3) == 5).
#
# A green run is the subset bootstrap loop: mcc2 compiled mcc2 (mcc2'), the fixpoint is exact, and
# mcc2' compiles+runs a program.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-${MCC:-zig-out/bin/mcc}}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/selfhost/main.mc"
RT="$HERE/tools/toolchain/mcc2_rt.c"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: selfhost-bootstrap-test (clang not found)"; exit 0; }

[ -f "$SRC" ] || { echo "FAIL: selfhost-bootstrap-test — selfhost/main.mc not found at $SRC"; exit 1; }

# ROOT wrapper at the repo root so the concat loader's root-dir-relative resolution finds main.mc
# (and, transitively, all of its deps). Cleaned up on exit.
MROOT="$HERE/.selfhost_bootstrap_root_$$.mc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" "$MROOT"' EXIT

# ----- Stage-1 BUILD: the selected `mcc` builds the first-generation mcc2 (as mcc2-cli-test does) -----
MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/main.o" --profile=hosted >/dev/null
"$CLANG" "$WORK/main.o" "$RT" -lm -o "$WORK/mcc2"

# ----- Stage-2 EMIT: mcc2 compiles its OWN full source to one C TU, diagnostic-clean -----
printf 'import "selfhost/main.mc";\n' > "$MROOT"
"$WORK/mcc2" "$MROOT" > "$WORK/mcc2prime.c" 2> "$WORK/mcc2prime.err"
if [ -s "$WORK/mcc2prime.err" ]; then
    echo "FAIL: selfhost-bootstrap-test — mcc2 reported diagnostics compiling its OWN full source:"
    cat "$WORK/mcc2prime.err"
    exit 1
fi
if [ ! -s "$WORK/mcc2prime.c" ]; then echo "FAIL: selfhost-bootstrap-test — mcc2 emitted no C for its own source"; exit 1; fi
# Sanity: the flattened TU must carry mcc2's own artifacts — the mc_main entry point (the CLI driver)
# and the mc_slice_const_u8 fat-pointer slice type the whole front end is built on.
grep -q "mc_main" "$WORK/mcc2prime.c" || { echo "FAIL: selfhost-bootstrap-test — emitted mcc2prime.c has no mc_main entry point"; exit 1; }
grep -q "mc_slice_const_u8" "$WORK/mcc2prime.c" || { echo "FAIL: selfhost-bootstrap-test — emitted mcc2prime.c has no mc_slice_const_u8 slice type"; exit 1; }

# ----- Stage-2 BUILD: the mcc2-emitted C links into the second-generation mcc2' -----
# `-std=gnu11`, warnings allowed (NO -Werror): the emitted C has known-harmless -Wswitch-bool/
# -Wreturn-type warnings from std/ascii + switch-on-bool lowerings (same as emitself/mainself).
"$CLANG" -std=gnu11 "$WORK/mcc2prime.c" "$RT" -lm -o "$WORK/mcc2prime" 2> "$WORK/mcc2prime.cc.err" || {
    echo "FAIL: selfhost-bootstrap-test — clang could not link mcc2's self-emitted mcc2prime.c:"
    head -30 "$WORK/mcc2prime.cc.err"
    exit 1
}

# ----- FIXPOINT + RUN: mcc2 and mcc2' produce byte-identical C; mcc2' output compiles+runs -----
printf 'export fn add(a: u32, b: u32) -> u32 { return a + b; }\n' > "$WORK/add.mc"
"$WORK/mcc2"      "$WORK/add.mc" > "$WORK/out_a.c" 2> "$WORK/out_a.err"
"$WORK/mcc2prime" "$WORK/add.mc" > "$WORK/out_b.c" 2> "$WORK/out_b.err"
if [ ! -s "$WORK/out_a.c" ]; then echo "FAIL: selfhost-bootstrap-test — mcc2 emitted no C for add.mc"; exit 1; fi
if [ ! -s "$WORK/out_b.c" ]; then echo "FAIL: selfhost-bootstrap-test — mcc2' (mcc2prime) emitted no C for add.mc"; exit 1; fi
if ! cmp -s "$WORK/out_a.c" "$WORK/out_b.c"; then
    echo "FAIL: selfhost-bootstrap-test — FIXPOINT BROKEN: mcc2 and mcc2' produced different C for add.mc:"
    diff "$WORK/out_a.c" "$WORK/out_b.c" | head -30
    exit 1
fi

# mcc2''s output must be working code: clang-compile out_b.c + a driver calling add(2,3), assert == 5.
cat >"$WORK/drv.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>
extern uint32_t add(uint32_t a, uint32_t b);
int main(void) {
    if (add(2, 3) != 5) { printf("FAIL: add(2,3)=%u want 5\n", add(2, 3)); return 1; }
    return 0;
}
EOF
"$CLANG" -std=gnu11 "$WORK/out_b.c" "$WORK/drv.c" -o "$WORK/prog" 2> "$WORK/prog.cc.err" || {
    echo "FAIL: selfhost-bootstrap-test — clang could not compile mcc2''s emitted out_b.c:"
    head -30 "$WORK/prog.cc.err"
    exit 1
}
if ! "$WORK/prog"; then
    echo "FAIL: selfhost-bootstrap-test — mcc2''-produced program returned non-zero (add(2,3)!=5)"
    exit 1
fi

echo "PASS: selfhost-bootstrap-test — subset bootstrap fixpoint byte-identical; mcc2' compiles+runs a program"
exit 0
