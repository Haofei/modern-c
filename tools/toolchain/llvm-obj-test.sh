#!/usr/bin/env sh
set -eu

MCC="${1:?usage: llvm-obj-test.sh path/to/mcc}"
OUT_DIR="${2:-zig-out/llvm-obj-test}"

command -v llc >/dev/null 2>&1 || { echo "SKIP: llvm-obj-test (llc not found)"; exit 0; }
command -v nm >/dev/null 2>&1 || { echo "SKIP: llvm-obj-test (nm not found)"; exit 0; }

mkdir -p "$OUT_DIR"

MCC="$MCC" tools/toolchain/mcc-llvm-cc.sh tests/c_emit/smoke.mc -o "$OUT_DIR/smoke.o"
MCC="$MCC" tools/toolchain/mcc-llvm-cc.sh tests/llvm/scalar_expressions.mc -o "$OUT_DIR/scalar_expressions.o"
MCC="$MCC" tools/toolchain/mcc-llvm-cc.sh tests/llvm/statement_workflow.mc -o "$OUT_DIR/statement_workflow.o"
MCC="$MCC" tools/toolchain/mcc-llvm-cc.sh tests/llvm/aggregate_rvalues.mc -o "$OUT_DIR/aggregate_rvalues.o"
MCC="$MCC" tools/toolchain/mcc-llvm-cc.sh tests/llvm/aggregate_abi.mc -o "$OUT_DIR/aggregate_abi.o"

test -s "$OUT_DIR/smoke.o"
test -s "$OUT_DIR/scalar_expressions.o"
test -s "$OUT_DIR/statement_workflow.o"
test -s "$OUT_DIR/aggregate_rvalues.o"
test -s "$OUT_DIR/aggregate_abi.o"

nm "$OUT_DIR/smoke.o" > "$OUT_DIR/smoke.nm"
nm "$OUT_DIR/scalar_expressions.o" > "$OUT_DIR/scalar_expressions.nm"
nm "$OUT_DIR/statement_workflow.o" > "$OUT_DIR/statement_workflow.nm"
nm "$OUT_DIR/aggregate_rvalues.o" > "$OUT_DIR/aggregate_rvalues.nm"
nm "$OUT_DIR/aggregate_abi.o" > "$OUT_DIR/aggregate_abi.nm"

grep -q ' add_one$' "$OUT_DIR/smoke.nm"
grep -q ' checked_left_shift$' "$OUT_DIR/scalar_expressions.nm"
grep -q ' flag_set$' "$OUT_DIR/scalar_expressions.nm"
grep -q ' void_call$' "$OUT_DIR/statement_workflow.nm"
grep -q ' contract_block_return$' "$OUT_DIR/statement_workflow.nm"
grep -q ' direct_array_call_index$' "$OUT_DIR/aggregate_rvalues.nm"
grep -q ' first_from_array_field_call$' "$OUT_DIR/aggregate_rvalues.nm"
grep -q ' make_pair$' "$OUT_DIR/aggregate_abi.nm"
grep -q ' take_pair$' "$OUT_DIR/aggregate_abi.nm"
