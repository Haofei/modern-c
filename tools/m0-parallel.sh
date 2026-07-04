#!/usr/bin/env bash
# Parallel m0 runner.
#
# `zig build m0` runs SERIALLY: zig 0.16's build runner executes side-effecting Run steps (which all
# our QEMU/script gates are) one at a time, so a full m0 takes ~sum-of-all-gates wall time even on a
# many-core box. This runner executes the SAME gate set as concurrent `zig build <gate>` PROCESSES —
# process-level parallelism, which the OS does spread across all cores (verified) — for the same
# pass/fail at a fraction of the wall time. Use it for fast local milestone runs; `zig build m0`
# remains the canonical (deterministic, serial) gate.
#
# Usage: tools/m0-parallel.sh [jobs]      (jobs default: nproc)
set -euo pipefail
cd "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=tools/lib/test-env.sh
. "tools/lib/test-env.sh"

J="${1:-$(mc_host_jobs)}"
OUT=".wamr-cache/m0p-logs"; rm -rf "$OUT"; mkdir -p "$OUT"

# Build the compiler ONCE up front so the parallel gate processes don't race to build/install it.
echo "[m0-parallel] building compiler (zig build install) ..."
zig build install >"$OUT/_install.log" 2>&1 || { echo "[m0-parallel] install FAILED"; tail -20 "$OUT/_install.log"; exit 1; }

# The m0 gate set is the ctx.cmd("...") dependency list in tiers.zig's m0 block (between the m0_step
# and c0_step declarations). Single source of truth — no separate list to drift.
GATES=()
while IFS= read -r gate; do
    GATES+=("$gate")
done < <(awk '/const m0_step = b.step/{f=1} /const c0_step = b.step/{f=0} f' build/tiers.zig \
    | grep -oE 'ctx\.cmd\("[^"]+"\)' | sed -E 's/.*\("([^"]+)"\)/\1/' | sort -u)
[ "${#GATES[@]}" -gt 0 ] || { echo "[m0-parallel] no gates extracted from build/tiers.zig"; exit 1; }

# Longest-processing-time-first: if a prior profiling run left step-times.tsv (MC_TIME_STEPS=1),
# order gates by descending recorded wall time so the slow aarch64-QEMU long poles launch first and
# overlap with everything else (shrinks the tail). Unknown/new gates sort first (assumed heavy).
TIMES=".wamr-cache/step-times.tsv"
if [ -s "$TIMES" ]; then
    ORDERED=()
    while IFS= read -r gate; do
        ORDERED+=("$gate")
    done < <(
        for g in "${GATES[@]}"; do
            ms=$(awk -F'\t' -v g="$g" '$1==g{print $2; exit}' "$TIMES"); printf '%s\t%s\n' "${ms:-999999}" "$g"
        done | sort -t$'\t' -k1 -nr | cut -f2)
    GATES=("${ORDERED[@]}")
fi
echo "[m0-parallel] ${#GATES[@]} gates, -P $J $( [ -s "$TIMES" ] && echo '(LPT-ordered)' )"

S=$(date +%s)
printf '%s\n' "${GATES[@]}" | xargs -P "$J" -I{} bash -c '
    g="$1"
    if zig build "$g" >".wamr-cache/m0p-logs/$g.log" 2>&1; then echo "PASS $g"; else echo "FAIL $g"; fi
' _ {} | tee "$OUT/summary.txt"
E=$(date +%s)

pass=$(awk '/^PASS / { n++ } END { print n + 0 }' "$OUT/summary.txt")
fail=$(awk '/^FAIL / { n++ } END { print n + 0 }' "$OUT/summary.txt")
echo "[m0-parallel] parallel pass: PASS=$pass FAIL=$fail  wall=$((E - S))s  (-P $J)"

# Re-verify failures SERIALLY. Under high parallelism some gates false-fail on contention (fixed
# QEMU ports, CPU starvation past a harness's internal `timeout`); they pass when run alone. A gate
# that fails BOTH the parallel run and the serial re-verify is a REAL failure. This keeps the speed
# (only failures retry) while matching `zig build m0`'s verdict.
FAILED=()
while IFS= read -r gate; do
    FAILED+=("$gate")
done < <(awk '/^FAIL / { print $2 }' "$OUT/summary.txt")
real_fail=0
if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "[m0-parallel] re-verifying ${#FAILED[@]} failed gate(s) serially (contention filter) ..."
    for g in "${FAILED[@]}"; do
        if zig build "$g" >"$OUT/$g.retry.log" 2>&1; then
            echo "  recovered (contention): $g"
        else
            echo "  REAL FAILURE: $g  (see $OUT/$g.retry.log)"
            real_fail=$((real_fail + 1))
        fi
    done
fi
EE=$(date +%s)
echo "[m0-parallel] DONE  real_failures=$real_fail  total_wall=$((EE - S))s"
[ "$real_fail" -eq 0 ] || exit 1
