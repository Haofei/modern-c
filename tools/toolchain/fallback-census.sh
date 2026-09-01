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
#   tools/toolchain/fallback-census.sh --check [root.mc ...]
#
# With no args report mode sweeps the differential corpus (tests/**/*.mc). Roots
# that fail to compile are skipped (the census still captures whatever emitted
# before the error). Output: a ranked report on stdout; raw JSONL in
# $OUTDIR/census.jsonl.
#
# --check is the repeatable gate mode. With no explicit roots it uses
# tools/toolchain/fallback-census-roots.txt, a C/LLVM-positive corpus, fails on
# any compile crash/error/timeout, then compares the result with the checked-in
# baseline.
#
# Env:
#   MCC        compiler binary (default: zig-out/bin/mcc; built if absent)
#   OUTDIR     work/output dir (default: zig-out/fallback-census)
#   BACKENDS   space-separated subset of "c llvm" (default: both)
#   JOBS       maximum concurrent compiler invocations (default: 4)
#   FALLBACK_CENSUS_BASELINE
#              baseline TSV for --check (default: tools/toolchain/fallback-census-baseline.tsv)
set -euo pipefail

SRC_ROOT="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
cd "$SRC_ROOT"

MCC_DEFAULT=0
if [ -z "${MCC+x}" ]; then
    MCC="zig-out/bin/mcc"
    MCC_DEFAULT=1
fi
OUTDIR="${OUTDIR:-zig-out/fallback-census}"
BACKENDS="${BACKENDS:-c llvm}"
JOBS="${JOBS:-4}"
CMD_TIMEOUT="${CMD_TIMEOUT:-20}"   # per-invocation wall clock; a fixture must never hang the sweep
BASELINE="${FALLBACK_CENSUS_BASELINE:-tools/toolchain/fallback-census-baseline.tsv}"
CHECK=0
case "$JOBS" in
    ''|*[!0-9]*|0)
        echo "JOBS must be a positive integer (got: $JOBS)" >&2
        exit 2
        ;;
esac
case "$OUTDIR" in /*) ;; *) OUTDIR="$SRC_ROOT/$OUTDIR" ;; esac
case "$BASELINE" in /*) ;; *) BASELINE="$SRC_ROOT/$BASELINE" ;; esac

usage() {
    sed -n '1,34p' "$0" >&2
}

POSITIONAL=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --check)
            CHECK=1
            ;;
        --baseline)
            shift
            if [ "$#" -eq 0 ]; then
                echo "missing value for --baseline" >&2
                exit 2
            fi
            BASELINE="$1"
            case "$BASELINE" in /*) ;; *) BASELINE="$SRC_ROOT/$BASELINE" ;; esac
            ;;
        --baseline=*)
            BASELINE="${1#--baseline=}"
            case "$BASELINE" in /*) ;; *) BASELINE="$SRC_ROOT/$BASELINE" ;; esac
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            while [ "$#" -gt 0 ]; do POSITIONAL+=("$1"); shift; done
            break
            ;;
        -*)
            echo "unknown option: $1" >&2
            usage
            exit 2
            ;;
        *)
            POSITIONAL+=("$1")
            ;;
    esac
    shift
done
if [ "${#POSITIONAL[@]}" -gt 0 ]; then
    set -- "${POSITIONAL[@]}"
else
    set --
fi

# A fixture can hang mcc (fuzz-y inputs, pathological programs); bound each run.
TIMEOUT_CMD=()
if command -v timeout >/dev/null 2>&1; then TIMEOUT_CMD=(timeout "$CMD_TIMEOUT");
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_CMD=(gtimeout "$CMD_TIMEOUT"); fi

if [ "$MCC_DEFAULT" -eq 1 ]; then
    # The installed launcher is intentionally stable and therefore has an old
    # timestamp. Always refresh its private compiler before measuring; merely
    # checking whether `zig-out/bin/mcc` exists silently ran stale code after
    # source edits and produced convincing but invalid migration numbers.
    zig build install >&2
elif [ ! -x "$MCC" ]; then
    echo "MCC is not executable: $MCC" >&2
    exit 2
fi

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR/parts"
CENSUS="$OUTDIR/census.jsonl"
: > "$CENSUS"

# Corpus: explicit roots, else report mode uses the broad differential fixture
# tree and check mode uses a C/LLVM-positive gate corpus.
ROOTS=()
if [ "$#" -gt 0 ]; then
    ROOTS=("$@")
elif [ "$CHECK" -eq 1 ]; then
    while IFS= read -r f; do
        case "$f" in ""|\#*) continue ;; esac
        ROOTS+=("$f")
    done < "$SRC_ROOT/tools/toolchain/fallback-census-roots.txt"
else
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

# Each child owns all of its writable paths.  It always returns success to the
# shell so `set -e` cannot terminate the parent before the batch has been
# reaped; the compiler status is recorded separately for deterministic handling
# by finish_batch.
run_one() {
    local run_id="$1"
    local sub="$2"
    local root="$3"
    local part="$OUTDIR/parts/part.$run_id.jsonl"
    local log="$OUTDIR/parts/part.$run_id.log"
    local status="$OUTDIR/parts/part.$run_id.status"
    local scratch="$OUTDIR/parts/scratch.$run_id.out"
    local rc=0

    : > "$part"
    : > "$log"
    if MC_FALLBACK_CENSUS="$part" "${TIMEOUT_CMD[@]}" "$MCC" "$sub" "$root" -o "$scratch" >"$log" 2>&1; then
        rc=0
    else
        rc=$?
    fi
    # The emitted artifact is only a vehicle for exercising admission. Keep
    # the census/log, but discard per-run artifacts once mcc has closed them so
    # a broad parallel sweep does not multiply disk usage by the corpus size.
    rm -f -- "$scratch" "$scratch.mcmeta" "$scratch.mcmeta.json" || true
    printf '%s\n' "$rc" > "$status"
    return 0
}

BATCH_PIDS=()
BATCH_RUN_IDS=()
RUN_ROOTS=()
RUN_SUBS=()

# Wait for a bounded batch in launch order.  Check mode stops before launching
# the next batch when any member failed.  The other already-running members are
# still reaped, which keeps logs complete and makes the selected failure
# deterministic (the lowest numeric run id in the failed batch).
finish_batch() {
    local position pid run_id rc wait_rc
    local failed_run=""

    position=0
    while [ "$position" -lt "${#BATCH_PIDS[@]}" ]; do
        pid="${BATCH_PIDS[$position]}"
        run_id="${BATCH_RUN_IDS[$position]}"
        wait_rc=0
        wait "$pid" || wait_rc=$?
        if [ -f "$OUTDIR/parts/part.$run_id.status" ]; then
            rc="$(sed -n '1p' "$OUTDIR/parts/part.$run_id.status")"
        else
            rc="${wait_rc:-125}"
            [ "$rc" -ne 0 ] || rc=125
        fi
        if [ "$CHECK" -eq 1 ] && [ "${rc:-125}" -ne 0 ] && [ -z "$failed_run" ]; then
            failed_run="$run_id"
        fi
        position=$((position + 1))
    done
    BATCH_PIDS=()
    BATCH_RUN_IDS=()

    if [ -n "$failed_run" ]; then
        echo "FAIL: fallback-census-ratchet-test - ${RUN_SUBS[$failed_run]} failed for ${RUN_ROOTS[$failed_run]}" >&2
        sed -n '1,120p' "$OUTDIR/parts/part.$failed_run.log" >&2
        exit 1
    fi
}

n_roots=0
n_runs=0
for root in "${ROOTS[@]}"; do
    [ -f "$root" ] || continue
    n_roots=$((n_roots + 1))
    for be in $BACKENDS; do
        sub="$(emit_cmd "$be")"
        [ -n "$sub" ] || continue
        RUN_ROOTS[$n_runs]="$root"
        RUN_SUBS[$n_runs]="$sub"
        run_one "$n_runs" "$sub" "$root" &
        BATCH_PIDS+=("$!")
        BATCH_RUN_IDS+=("$n_runs")
        n_runs=$((n_runs + 1))
        if [ "${#BATCH_PIDS[@]}" -ge "$JOBS" ]; then
            finish_batch
        fi
    done
done
if [ "${#BATCH_PIDS[@]}" -gt 0 ]; then
    finish_batch
fi

# Child completion order is intentionally irrelevant.  Concatenate only after
# every batch has finished, in the numeric launch order used by the serial
# implementation, so raw JSONL and all derived summaries remain reproducible.
run_id=0
while [ "$run_id" -lt "$n_runs" ]; do
    part="$OUTDIR/parts/part.$run_id.jsonl"
    if [ -s "$part" ]; then
        cat "$part" >> "$CENSUS"
    fi
    run_id=$((run_id + 1))
done

echo "swept $n_roots roots across [$BACKENDS] ($n_runs runs, jobs=$JOBS) -> $CENSUS" >&2
python3 "$SRC_ROOT/tools/toolchain/fallback-census-report.py" "$CENSUS"
if [ "$CHECK" -eq 1 ]; then
    python3 "$SRC_ROOT/tools/toolchain/fallback-census-ratchet.py" --baseline "$BASELINE" "$CENSUS"
fi
