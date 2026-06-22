#!/usr/bin/env bash
# Native debug-info gate for the LLVM backend: prove selected MC source
# file/function/line mappings survive textual LLVM IR and llc object lowering
# into DWARF sections across calls, control flow, atomics/fences, and narrowing.
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

compile_fixture() {
    local rel="$1"
    local stem="$2"
    local obj="$WORK/$stem.o"
    # Pin the triple: emit-llvm emits none, so llc would inherit the host default (aarch64
    # in the dev container) whose line-table column attribution differs from the line/column
    # rows asserted below — those were calibrated for x86-64/riscv64. Without this the gate is
    # host-dependent (the expected `<line> <col> 1` DWARF rows simply do not appear on aarch64).
    MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/$rel" -o "$obj" -mtriple=x86_64-unknown-none >/dev/null

    "$READELF" -S "$obj" >"$WORK/$stem.sections.txt"
    grep -q '\.debug_info' "$WORK/$stem.sections.txt"
    grep -q '\.debug_line' "$WORK/$stem.sections.txt"

    "$DWARFDUMP" "$obj" >"$WORK/$stem.dwarf.txt"
    "$DWARFDUMP" --debug-line "$obj" >"$WORK/$stem.debug-line.txt"

    grep -q 'DW_AT_producer.*mcc emit-llvm' "$WORK/$stem.dwarf.txt"
    grep -q "DW_AT_name.*$rel" "$WORK/$stem.dwarf.txt"
    grep -q "$(basename "$rel")" "$WORK/$stem.debug-line.txt"
}

line_row() {
    local stem="$1"
    local line="$2"
    local column="$3"
    grep -Eq "0x[0-9a-f]+[[:space:]]+$line[[:space:]]+$column[[:space:]]+1" "$WORK/$stem.debug-line.txt"
}

function_die() {
    local stem="$1"
    local name="$2"
    grep -q "DW_AT_name.*$name" "$WORK/$stem.dwarf.txt"
}

compile_fixture tests/llvm/statement_workflow.mc statement_workflow
function_die statement_workflow void_call
function_die statement_workflow scoped_block
function_die statement_workflow assignment_workflow
function_die statement_workflow contract_block_return
line_row statement_workflow 13 9
line_row statement_workflow 36 5
line_row statement_workflow 43 9

compile_fixture tests/llvm/atomics.mc atomics
function_die atomics load_acquire
function_die atomics fetch_add_acq_rel
function_die atomics read_ticks
function_die atomics explicit_fences
line_row atomics 10 5
line_row atomics 15 5
line_row atomics 39 5
line_row atomics 49 5

compile_fixture tests/llvm/bool_conditions.mc bool_conditions
function_die bool_conditions bool_and
function_die bool_conditions require_complex
function_die bool_conditions bool_arg
line_row bool_conditions 5 5
line_row bool_conditions 17 5
line_row bool_conditions 21 5
line_row bool_conditions 25 5

compile_fixture tests/c_emit/if_let_narrowing.mc if_let_narrowing
function_die if_let_narrowing optional_pointer
function_die if_let_narrowing result_ok
function_die if_let_narrowing result_err
function_die if_let_narrowing switch_result_ok_binding_type
line_row if_let_narrowing 6 5
line_row if_let_narrowing 7 9
line_row if_let_narrowing 27 5
line_row if_let_narrowing 48 5
line_row if_let_narrowing 56 20
line_row if_let_narrowing 57 16

echo "PASS: llvm-debug-test - LLVM objects contain DWARF file, function, and source line mappings across calls, control flow, atomics, fences, and narrowing"
