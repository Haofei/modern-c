#!/usr/bin/env bash
# Parallel m0 runner.
#
# `zig build m0-full` runs SERIALLY: zig 0.16's build runner executes side-effecting Run steps (which all
# our QEMU/script gates are) one at a time, so a full matrix takes ~sum-of-all-gates wall time even on a
# many-core box. This runner executes the SAME gate set as concurrent `zig build <gate>` PROCESSES —
# process-level parallelism, which the OS does spread across all cores (verified) — for the same
# pass/fail at a fraction of the wall time. Use it for fast local full-matrix runs; `zig build m0-full`
# remains the canonical (deterministic, serial) release gate.
#
# Usage: tools/m0-parallel.sh [jobs]      (jobs default: host CPU count)
#
# On every completed run the runner writes both a machine-readable ranking and
# a short top-20 bottleneck report under .wamr-cache/. These reports are
# telemetry only: they never participate in a gate's pass/fail result.
set -euo pipefail
cd "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=tools/lib/test-env.sh
. "tools/lib/test-env.sh"

HOST_JOBS="$(mc_host_jobs)"
J="${1:-$HOST_JOBS}"
case "$J" in
    ''|*[!0-9]*|0) echo "usage: tools/m0-parallel.sh [positive-jobs]" >&2; exit 2 ;;
esac

# Gate processes are the outer parallelism. Bound nested fuzz/compiler worker
# pools to their fair share of the same CPU budget instead of allowing every
# gate to independently consume all host CPUs.
INNER_DEFAULT="$(mc_inner_jobs "$J" "$HOST_JOBS")"
export JOBS="${JOBS:-${MC_M0_INNER_JOBS:-$INNER_DEFAULT}}"
OUT=".wamr-cache/m0p-logs"; rm -rf "$OUT"; mkdir -p "$OUT"

# Build the compiler ONCE up front so the parallel gate processes don't race to build/install it.
echo "[m0-parallel] building compiler (zig build install) ..."
zig build install >"$OUT/_install.log" 2>&1 || { echo "[m0-parallel] install FAILED"; tail -20 "$OUT/_install.log"; exit 1; }

# The full gate set is the ctx.cmd("...") dependency list in tiers.zig's m0-full block (between
# the m0_full_step and m0_step declarations). Single source of truth — no separate list to drift.
GATES=()
while IFS= read -r gate; do
    GATES+=("$gate")
done < <(awk '/const m0_full_step = b.step/{f=1} /const m0_step = b.step/{f=0} f' build/tiers.zig \
    | grep -oE 'ctx\.cmd\("[^"]+"\)' | sed -E 's/.*\("([^"]+)"\)/\1/' | sort -u)
[ "${#GATES[@]}" -gt 0 ] || { echo "[m0-parallel] no gates extracted from build/tiers.zig"; exit 1; }

# Some gates operate on the whole source tree or otherwise contend badly with
# unrelated build steps. Keep them out of the parallel pool and run them once
# after the parallel pass.
SERIAL_GATES=(compiler-coverage)
PARALLEL_GATES=()
for g in "${GATES[@]}"; do
    serial=0
    for s in "${SERIAL_GATES[@]}"; do
        if [ "$g" = "$s" ]; then serial=1; break; fi
    done
    if [ "$serial" -eq 0 ]; then
        PARALLEL_GATES+=("$g")
    fi
done
GATES=("${PARALLEL_GATES[@]}")

# Longest-processing-time-first: by default use build-runner step timings, which
# are less distorted by m0-parallel resource contention. A previous m0-parallel
# profile is still recorded and can be selected explicitly with
# MC_M0_USE_PARALLEL_PROFILE=1. Missing timings are estimated conservatively so
# known-heavy fuzz/coverage gates do not get stranded at the tail.
PROFILE_TIMES=".wamr-cache/m0-parallel-times.tsv"
REPORT_TSV=".wamr-cache/m0-parallel-report.tsv"
REPORT_SUMMARY=".wamr-cache/m0-parallel-report.txt"
TIMES=".wamr-cache/step-times.tsv"
if [ "${MC_M0_USE_PARALLEL_PROFILE:-0}" = 1 ] && [ -s "$PROFILE_TIMES" ]; then
    TIMES="$PROFILE_TIMES"
fi
estimate_ms() {
    local gate="$1"
    case "$gate" in
        lowering-coverage)
            echo 45000 ;;
        parser-fuzz-test|sched-difftest)
            echo 25000 ;;
        fuzz-*|*-fuzz)
            echo 5000 ;;
        llvm-host-suite-test|diff-backend|sanitize|*sweep*)
            echo 60000 ;;
        *smode*|arm-*|llvm-arm-*|aarch64*|llvm-aarch64*)
            echo 30000 ;;
        *)
            echo 1000 ;;
    esac
}
if [ -s "$TIMES" ]; then
    ORDERED=()
    while IFS= read -r gate; do
        ORDERED+=("$gate")
    done < <(
        for g in "${GATES[@]}"; do
            ms=$(awk -F'\t' -v g="$g" '$1==g{value=$2} END{print value}' "$TIMES")
            if [ -z "$ms" ]; then
                ms="$(estimate_ms "$g")"
            fi
            printf '%s\t%s\n' "${ms:-0}" "$g"
        done | sort -t$'\t' -k1 -nr | cut -f2)
    GATES=("${ORDERED[@]}")
fi
echo "[m0-parallel] $((${#GATES[@]} + ${#SERIAL_GATES[@]})) gates (${#GATES[@]} parallel + ${#SERIAL_GATES[@]} serial), outer -P $J, inner JOBS=$JOBS, COUNT=${COUNT:-300} $( [ -s "$TIMES" ] && echo '(LPT-ordered)' )"

S=$(date +%s)
mkdir -p "$OUT/times"
printf '%s\n' "${GATES[@]}" | xargs -P "$J" -I{} bash -c '
    g="$1"
    log=".wamr-cache/m0p-logs/$g.log"
    time_log=".wamr-cache/m0p-logs/times/$g.tsv"
    start=$(date +%s)
    rc=0
    if zig build "$g" >"$log" 2>&1; then
        if [ "${MC_REQUIRE_TOOLS:-0}" = 1 ] && grep -q "^SKIP:" "$log"; then
            echo "FAIL $g"
            rc=1
        else
            echo "PASS $g"
        fi
    else
        echo "FAIL $g"
        rc=1
    fi
    end=$(date +%s)
    printf "%s\t%s\t%s\n" "$g" "$(((end - start) * 1000))" "$rc" >"$time_log"
' _ {} | tee "$OUT/summary.txt"
E=$(date +%s)

pass=$(awk '/^PASS / { n++ } END { print n + 0 }' "$OUT/summary.txt")
fail=$(awk '/^FAIL / { n++ } END { print n + 0 }' "$OUT/summary.txt")
echo "[m0-parallel] parallel pass: PASS=$pass FAIL=$fail  wall=$((E - S))s  (-P $J)"

# Re-verify failures SERIALLY. Under high parallelism some gates false-fail on contention (fixed
# QEMU ports, CPU starvation past a harness's internal `timeout`); they pass when run alone. A gate
# that fails BOTH the parallel run and the serial re-verify is a REAL failure. This keeps the speed
# (only failures retry) while matching `zig build m0-full`'s verdict.
FAILED=()
while IFS= read -r gate; do
    FAILED+=("$gate")
done < <(awk '/^FAIL / { print $2 }' "$OUT/summary.txt")
real_fail=0
if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "[m0-parallel] re-verifying ${#FAILED[@]} failed gate(s) serially (contention filter) ..."
    for g in "${FAILED[@]}"; do
        retry_log="$OUT/$g.retry.log"
        if zig build "$g" >"$retry_log" 2>&1 &&
            { [ "${MC_REQUIRE_TOOLS:-0}" != 1 ] || ! grep -q '^SKIP:' "$retry_log"; }; then
            echo "  recovered (contention): $g"
        else
            echo "  REAL FAILURE: $g  (see $retry_log)"
            real_fail=$((real_fail + 1))
        fi
    done
fi
if [ "${#SERIAL_GATES[@]}" -gt 0 ]; then
    echo "[m0-parallel] running ${#SERIAL_GATES[@]} serialized gate(s) ..."
    for g in "${SERIAL_GATES[@]}"; do
        log="$OUT/$g.log"
        time_log="$OUT/times/$g.tsv"
        start=$(date +%s)
        if zig build "$g" >"$log" 2>&1 &&
            { [ "${MC_REQUIRE_TOOLS:-0}" != 1 ] || ! grep -q '^SKIP:' "$log"; }; then
            echo "  PASS(serial): $g"
            rc=0
        else
            echo "  REAL FAILURE(serial): $g  (see $log)"
            rc=1
            real_fail=$((real_fail + 1))
        fi
        end=$(date +%s)
        printf "%s\t%s\t%s\n" "$g" "$(((end - start) * 1000))" "$rc" >"$time_log"
    done
fi
find "$OUT/times" -type f -name '*.tsv' -print0 | xargs -0 cat | sort -t$'\t' -k1,1 >"$PROFILE_TIMES"
EE=$(date +%s)
python3 tools/toolchain/m0-timing-report.py \
    --input "$PROFILE_TIMES" \
    --tsv "$REPORT_TSV" \
    --summary "$REPORT_SUMMARY" \
    --wall-ms "$(((EE - S) * 1000))" \
    --outer-jobs "$J" \
    --inner-jobs "$JOBS"
echo "[m0-parallel] timing report: $REPORT_SUMMARY (all rows: $REPORT_TSV)"
sed -n '1,23p' "$REPORT_SUMMARY"
echo "[m0-parallel] DONE  real_failures=$real_fail  total_wall=$((EE - S))s"
[ "$real_fail" -eq 0 ] || exit 1
