#!/usr/bin/env bash
# Parallel fast-tier runner.
#
# `zig build fast` is the canonical serial host-only confidence gate. This runner
# executes the same `fast_step.dependOn(ctx.cmd(...))` gate set as concurrent
# `zig build <gate>` processes, then re-runs any failures serially to filter
# contention. It is for local wall-time reduction; `zig build fast` remains the
# deterministic truth for the tier.
#
# Usage: tools/fast-parallel.sh [jobs]
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=tools/lib/test-env.sh
. "$ROOT/tools/lib/test-env.sh"

OUTER_JOBS="${1:-$(mc_host_jobs)}"
# Aggregate `fast` launches many fuzz/diff gates at once. Leave single-gate
# defaults alone, but cap nested worker pools for this aggregate runner unless
# the caller explicitly chose a value.
export JOBS="${JOBS:-${MC_FAST_INNER_JOBS:-1}}"
# Keep the local parallel confidence pass bounded. Canonical `zig build fast`
# and CI still use each gate's own default count unless COUNT is set there too.
export COUNT="${COUNT:-${MC_FAST_FUZZ_COUNT:-40}}"

OUT=".wamr-cache/fastp-logs"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "[fast-parallel] building compiler (zig build install) ..."
zig build install >"$OUT/_install.log" 2>&1 || {
    echo "[fast-parallel] install FAILED"
    tail -20 "$OUT/_install.log"
    exit 1
}

# Single source of truth: the fast tier's ctx.cmd("...") dependency list.
GATES=()
while IFS= read -r gate; do
    GATES+=("$gate")
done < <(awk '/const fast_step = b.step/{f=1} /const c0_step = b.step/{f=0} f' build/tiers.zig \
    | grep -oE 'ctx\.cmd\("[^"]+"\)' | sed -E 's/.*\("([^"]+)"\)/\1/' | sort -u)
[ "${#GATES[@]}" -gt 0 ] || {
    echo "[fast-parallel] no gates extracted from build/tiers.zig"
    exit 1
}

# Longest-processing-time-first when prior timing data exists.
TIMES=".wamr-cache/step-times.tsv"
if [ -s "$TIMES" ]; then
    ORDERED=()
    while IFS= read -r gate; do
        ORDERED+=("$gate")
    done < <(
        for g in "${GATES[@]}"; do
            ms=$(awk -F'\t' -v g="$g" '$1==g{print $2; exit}' "$TIMES")
            printf '%s\t%s\n' "${ms:-999999}" "$g"
        done | sort -t$'\t' -k1 -nr | cut -f2)
    GATES=("${ORDERED[@]}")
fi

echo "[fast-parallel] ${#GATES[@]} gates, outer -P $OUTER_JOBS, inner JOBS=$JOBS, COUNT=$COUNT $( [ -s "$TIMES" ] && echo '(LPT-ordered)' )"

S=$(date +%s)
set +e
printf '%s\n' "${GATES[@]}" | xargs -P "$OUTER_JOBS" -I{} bash -c '
    g="$1"
    if zig build "$g" >".wamr-cache/fastp-logs/$g.log" 2>&1; then
        echo "PASS $g"
    else
        echo "FAIL $g"
    fi
' _ {} | tee "$OUT/summary.txt"
pipe_status=("${PIPESTATUS[@]}")
xargs_rc=${pipe_status[0]}
tee_rc=${pipe_status[1]}
set -e
E=$(date +%s)

pass=$(awk '/^PASS / { n++ } END { print n + 0 }' "$OUT/summary.txt")
fail=$(awk '/^FAIL / { n++ } END { print n + 0 }' "$OUT/summary.txt")
echo "[fast-parallel] parallel pass: PASS=$pass FAIL=$fail wall=$((E - S))s (outer -P $OUTER_JOBS, inner JOBS=$JOBS, COUNT=$COUNT)"
if [ "$tee_rc" -ne 0 ]; then
    echo "[fast-parallel] tee failed with status $tee_rc"
    exit "$tee_rc"
fi
if [ "$xargs_rc" -ne 0 ] && [ "$fail" -eq 0 ]; then
    echo "[fast-parallel] xargs failed with status $xargs_rc before reporting a failed gate"
    exit "$xargs_rc"
fi

FAILED=()
while IFS= read -r gate; do
    FAILED+=("$gate")
done < <(awk '/^FAIL / { print $2 }' "$OUT/summary.txt")
real_fail=0
if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "[fast-parallel] re-verifying ${#FAILED[@]} failed gate(s) serially (contention filter) ..."
    for g in "${FAILED[@]}"; do
        if zig build "$g" >"$OUT/$g.retry.log" 2>&1; then
            echo "  recovered (contention): $g"
        else
            echo "  REAL FAILURE: $g (see $OUT/$g.retry.log)"
            real_fail=$((real_fail + 1))
        fi
    done
fi

EE=$(date +%s)
echo "[fast-parallel] DONE real_failures=$real_fail xargs_status=$xargs_rc total_wall=$((EE - S))s"
[ "$real_fail" -eq 0 ] || exit 1
