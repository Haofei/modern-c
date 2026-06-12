#!/usr/bin/env sh
set -eu

MCC="${1:?usage: llvm-test.sh path/to/mcc}"
OUT_DIR="${2:-zig-out/llvm-test}"

mkdir -p "$OUT_DIR"
"$MCC" emit-llvm tests/c_emit/smoke.mc > "$OUT_DIR/smoke.ll"
llvm-as "$OUT_DIR/smoke.ll" -o "$OUT_DIR/smoke.bc"
"$MCC" emit-llvm tests/llvm/bool_switch.mc > "$OUT_DIR/bool_switch.ll"
llvm-as "$OUT_DIR/bool_switch.ll" -o "$OUT_DIR/bool_switch.bc"
"$MCC" emit-llvm tests/llvm/loops.mc > "$OUT_DIR/loops.ll"
llvm-as "$OUT_DIR/loops.ll" -o "$OUT_DIR/loops.bc"

grep -q '@llvm.uadd.with.overflow.i32' "$OUT_DIR/smoke.ll"
grep -q 'call void @mc_trap_IntegerOverflow()' "$OUT_DIR/smoke.ll"
! grep -q ' nsw ' "$OUT_DIR/smoke.ll"
! grep -q ' nuw ' "$OUT_DIR/smoke.ll"
grep -q 'br i1 %flag' "$OUT_DIR/bool_switch.ll"
grep -q 'icmp ugt i32 %x, 10' "$OUT_DIR/bool_switch.ll"
grep -q 'alloca i32' "$OUT_DIR/loops.ll"
grep -q 'store i32' "$OUT_DIR/loops.ll"
grep -q 'load i32' "$OUT_DIR/loops.ll"
grep -q 'br label %while_cond' "$OUT_DIR/loops.ll"
grep -q '@llvm.usub.with.overflow.i32' "$OUT_DIR/loops.ll"
