#!/usr/bin/env bash
# Native debug-info smoke gate for the LLVM backend: prove selected MC source
# file/function/line mappings survive textual LLVM IR and llc object lowering
# into DWARF sections.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
LLC="${LLC:-llc}"
DWARFDUMP="${LLVM_DWARFDUMP:-llvm-dwarfdump}"
READELF="${READELF:-readelf}"

command -v "$LLC" >/dev/null 2>&1 || { echo "SKIP: llvm-debug-test (llc not found)"; exit 0; }
command -v "$DWARFDUMP" >/dev/null 2>&1 || { echo "SKIP: llvm-debug-test (llvm-dwarfdump not found)"; exit 0; }
command -v "$READELF" >/dev/null 2>&1 || { echo "SKIP: llvm-debug-test (readelf not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

OBJ="$WORK/statement_workflow.o"
MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/tests/llvm/statement_workflow.mc" -o "$OBJ" >/dev/null

"$READELF" -S "$OBJ" >"$WORK/sections.txt"
grep -q '\.debug_info' "$WORK/sections.txt"
grep -q '\.debug_line' "$WORK/sections.txt"

"$DWARFDUMP" "$OBJ" >"$WORK/dwarf.txt"
"$DWARFDUMP" --debug-line "$OBJ" >"$WORK/debug-line.txt"

grep -q 'DW_AT_producer.*mcc emit-llvm' "$WORK/dwarf.txt"
grep -q 'DW_AT_name.*tests/llvm/statement_workflow.mc' "$WORK/dwarf.txt"
grep -q 'DW_AT_name.*void_call' "$WORK/dwarf.txt"
grep -q 'DW_AT_name.*scoped_block' "$WORK/dwarf.txt"
grep -q 'DW_AT_name.*assignment_workflow' "$WORK/dwarf.txt"
grep -q 'DW_AT_name.*contract_block_return' "$WORK/dwarf.txt"
grep -q 'statement_workflow.mc' "$WORK/debug-line.txt"

grep -Eq '0x[0-9a-f]+[[:space:]]+13[[:space:]]+9[[:space:]]+1' "$WORK/debug-line.txt"
grep -Eq '0x[0-9a-f]+[[:space:]]+36[[:space:]]+5[[:space:]]+1' "$WORK/debug-line.txt"
grep -Eq '0x[0-9a-f]+[[:space:]]+43[[:space:]]+9[[:space:]]+1' "$WORK/debug-line.txt"

echo "PASS: llvm-debug-test - LLVM object contains DWARF file, function, and source line mappings"
