#!/usr/bin/env bash
# Function-body fallback census (P0 codegen-ingress worklist).
#
# Runs an ordinary `mcc emit-c` and `mcc emit-llvm` over a corpus with the
# MC_FALLBACK_CENSUS recorder armed (see src/fallback_census.zig), then aggregates
# the per-invocation JSONL into a frequency-ranked table of which function shapes
# still fall back to the transitional AST body instead of lowering from verified
# MIR. Purpose: replace blind shape-by-shape enumeration with a head-of-
# distribution worklist — attack the biggest remaining buckets first.
#
# The census hooks the REAL admission branch in each backend's
# emitFunctionDefinitions (no re-run), so the counts are exactly what codegen does.
#
# Usage:
#   tools/toolchain/fallback-census.sh [root.mc ...]
# With no args it sweeps the differential corpus (tests/**/*.mc). Roots that fail
# to compile are skipped (the census still captures whatever emitted before the
# error). Output: a ranked report on stdout; raw JSONL in $OUTDIR/census.jsonl.
#
# Env:
#   MCC        compiler binary (default: zig-out/bin/mcc; built if absent)
#   OUTDIR     work/output dir (default: zig-out/fallback-census)
#   BACKENDS   space-separated subset of "c llvm" (default: both)
set -euo pipefail

SRC_ROOT="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
cd "$SRC_ROOT"

MCC="${MCC:-zig-out/bin/mcc}"
OUTDIR="${OUTDIR:-zig-out/fallback-census}"
BACKENDS="${BACKENDS:-c llvm}"
CMD_TIMEOUT="${CMD_TIMEOUT:-20}"   # per-invocation wall clock; a fixture must never hang the sweep
case "$OUTDIR" in /*) ;; *) OUTDIR="$SRC_ROOT/$OUTDIR" ;; esac

# A fixture can hang mcc (fuzz-y inputs, pathological programs); bound each run.
TIMEOUT=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT="timeout $CMD_TIMEOUT";
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT="gtimeout $CMD_TIMEOUT"; fi

if [ ! -x "$MCC" ]; then
    echo "building mcc..." >&2
    zig build >&2
fi

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR/parts"
CENSUS="$OUTDIR/census.jsonl"
: > "$CENSUS"
SCRATCH="$OUTDIR/scratch.out"

# Corpus: explicit roots, else the differential fixture tree.
ROOTS=()
if [ "$#" -gt 0 ]; then
    ROOTS=("$@")
else
    # Portable (bash 3.2 has no `mapfile`).
    while IFS= read -r f; do ROOTS+=("$f"); done < <(find tests -name '*.mc' | sort)
fi

emit_cmd() {
    # $1 backend -> the mcc subcommand
    case "$1" in
        c) echo "emit-c" ;;
        llvm) echo "emit-llvm" ;;
        *) echo "" ;;
    esac
}

n_roots=0
n_runs=0
for root in "${ROOTS[@]}"; do
    [ -f "$root" ] || continue
    n_roots=$((n_roots + 1))
    for be in $BACKENDS; do
        sub="$(emit_cmd "$be")"
        [ -n "$sub" ] || continue
        part="$OUTDIR/parts/part.$n_runs.jsonl"
        # Best-effort: a fixture that fails to compile still leaves whatever it
        # emitted before erroring; negative/ill-typed fixtures simply contribute
        # nothing. Never let one root abort the sweep.
        MC_FALLBACK_CENSUS="$part" $TIMEOUT "$MCC" "$sub" "$root" -o "$SCRATCH" >/dev/null 2>&1 || true
        if [ -s "$part" ]; then
            cat "$part" >> "$CENSUS"
        fi
        n_runs=$((n_runs + 1))
    done
done

echo "swept $n_roots roots across [$BACKENDS] ($n_runs runs) -> $CENSUS" >&2
python3 "$SRC_ROOT/tools/toolchain/fallback-census-report.py" "$CENSUS"
