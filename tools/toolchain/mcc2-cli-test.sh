#!/usr/bin/env bash
# mcc2-cli-test: build the standalone `mcc2` CLI (selfhost/main.mc + tools/toolchain/mcc2_rt.c),
# the step after Phase 4 of docs/self-host.md (§1), then (1) prove the CLI round-trip functionally
# and (2) MEASURE its throughput at scale (the "or slow" deliverable that fills the perf ledger).
#
#   Stage BUILD:      mcc-cc.sh selfhost/main.mc -> main.o ; clang link with mcc2_rt.c -> mcc2
#   Stage FUNCTIONAL: `mcc2 add.mc > out.c`, clang-compile out.c + a driver calling add(2,3),
#                     assert == 5 (the lex->parse->sema->emit->clang->run CLI round-trip).
#   Stage PERF:       generate ~1000 subset-valid functions, time `mcc2 big.mc > big.c`, report
#                     input size / #functions, mcc2 wall time, emitted C size, and clang -O0 time.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/selfhost/main.mc"
RT="$HERE/tools/toolchain/mcc2_rt.c"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: mcc2-cli-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ----- Stage BUILD: compile selfhost/main.mc and link the mcc2 CLI -----
MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/main.o" --profile=hosted >/dev/null
"$CLANG" "$WORK/main.o" "$RT" -lm -o "$WORK/mcc2"

# ----- Stage FUNCTIONAL: mcc2 add.mc -> out.c -> clang -> run, assert add(2,3)==5 -----
printf 'export fn add(a: u32, b: u32) -> u32 { return a + b; }\n' > "$WORK/add.mc"
"$WORK/mcc2" "$WORK/add.mc" > "$WORK/out.c"
if [ ! -s "$WORK/out.c" ]; then echo "FAIL: mcc2-cli-test — mcc2 emitted no C for add.mc"; exit 1; fi
cat >"$WORK/drv.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>
extern uint32_t add(uint32_t a, uint32_t b);
int main(void) {
    if (add(2, 3) != 5) { printf("FAIL: add(2,3)=%u want 5\n", add(2, 3)); return 1; }
    return 0;
}
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/out.c" "$WORK/drv.c" -o "$WORK/prog"
if ! "$WORK/prog"; then echo "FAIL: mcc2-cli-test — round-trip add(2,3)!=5"; exit 1; fi
echo "PASS: mcc2-cli-test — CLI round-trip: mcc2 add.mc -> C -> clang -> run, add(2,3)==5"

# ----- Stage EXIT-CODE: invalid input must FAIL (nonzero), valid must succeed (0) -----
# Regression guard: mcc2 emits best-effort C even on error, but the EXIT CODE must reflect
# validity so CI/scripts reject bad MC (previously a semantic error still exited 0).
"$WORK/mcc2" "$WORK/add.mc" >/dev/null 2>&1 || { echo "FAIL: mcc2-cli-test — valid input did not exit 0"; exit 1; }
printf 'export fn bad() -> u32 { return no_such_fn(1); }\n' > "$WORK/bad.mc"
if "$WORK/mcc2" "$WORK/bad.mc" >/dev/null 2>&1; then echo "FAIL: mcc2-cli-test — invalid MC (unknown call) exited 0; CI would accept bad input"; exit 1; fi
echo "PASS: mcc2-cli-test — exit code reflects validity (valid=0, semantic-error=nonzero)"

# ----- Stage PERF: ~1000 subset-valid functions; time mcc2 and clang -----
NFUNS=1000
awk -v n="$NFUNS" 'BEGIN {
    for (i = 0; i < n; i++)
        printf "export fn f_%d(a: u32, b: u32) -> u32 { let x: u32 = a + b; let y: u32 = x * 2; return y + %d; }\n", i, i
}' > "$WORK/big.mc"
IN_BYTES=$(wc -c < "$WORK/big.mc" | tr -d ' ')

t0=$(date +%s.%N)
"$WORK/mcc2" "$WORK/big.mc" > "$WORK/big.c"
rc=$?
t1=$(date +%s.%N)
if [ "$rc" -ne 0 ]; then echo "FAIL: mcc2-cli-test — mcc2 exited $rc on big.mc"; exit 1; fi
if [ ! -s "$WORK/big.c" ]; then echo "FAIL: mcc2-cli-test — mcc2 emitted empty big.c"; exit 1; fi
MCC2_WALL=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.3f", b - a }')
OUT_BYTES=$(wc -c < "$WORK/big.c" | tr -d ' ')

t2=$(date +%s.%N)
"$CLANG" -O0 -std=c11 -c "$WORK/big.c" -o "$WORK/big.o"
t3=$(date +%s.%N)
CLANG_WALL=$(awk -v a="$t2" -v b="$t3" 'BEGIN { printf "%.3f", b - a }')

FPS=$(awk -v n="$NFUNS" -v w="$MCC2_WALL" 'BEGIN { if (w > 0) printf "%.0f", n / w; else printf "inf" }')
KBPS=$(awk -v bytes="$IN_BYTES" -v w="$MCC2_WALL" 'BEGIN { if (w > 0) printf "%.0f", (bytes / 1024) / w; else printf "inf" }')

echo "PERF: input=${IN_BYTES} bytes, functions=${NFUNS}"
echo "PERF: mcc2 wall=${MCC2_WALL}s, emitted C=${OUT_BYTES} bytes"
echo "PERF: clang -O0 wall=${CLANG_WALL}s"
echo "PERF: throughput ~${FPS} functions/sec (~${KBPS} KB-source/sec)"
echo "PASS: mcc2-cli-test — built mcc2, functional round-trip + perf measured"
exit 0
