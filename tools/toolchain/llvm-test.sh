#!/usr/bin/env sh
set -eu

MCC="${1:?usage: llvm-test.sh path/to/mcc}"
OUT_DIR="${2:-zig-out/llvm-test}"

mkdir -p "$OUT_DIR"
"$MCC" emit-llvm tests/c_emit/smoke.mc > "$OUT_DIR/smoke.ll"
llvm-as "$OUT_DIR/smoke.ll" -o "$OUT_DIR/smoke.bc"

grep -q '@llvm.uadd.with.overflow.i32' "$OUT_DIR/smoke.ll"
grep -q 'call void @mc_trap_IntegerOverflow()' "$OUT_DIR/smoke.ll"
! grep -q ' nsw ' "$OUT_DIR/smoke.ll"
! grep -q ' nuw ' "$OUT_DIR/smoke.ll"
