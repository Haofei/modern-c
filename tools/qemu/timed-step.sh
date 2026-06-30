#!/usr/bin/env bash
# Profiling wrapper (opt-in via MC_TIME_STEPS=1 at `zig build` configure time): records the wall
# time of a single build step, then execs it unchanged. Output: one "<name>\t<ms>" line appended to
# $MC_STEP_TIMES (default .wamr-cache/step-times.tsv). A no-op for correctness — the wrapped command
# sees identical argv and its exit code is propagated — so it never affects pass/fail, only telemetry.
#   usage: timed-step.sh <step-name> -- <argv...>
set -uo pipefail
name="$1"; shift
[ "${1:-}" = "--" ] && shift
out="${MC_STEP_TIMES:-.wamr-cache/step-times.tsv}"
mkdir -p "$(dirname "$out")" 2>/dev/null || true
s=$(date +%s%N 2>/dev/null || echo 0)
"$@"; rc=$?
e=$(date +%s%N 2>/dev/null || echo 0)
printf '%s\t%d\t%d\n' "$name" "$(( (e - s) / 1000000 ))" "$rc" >> "$out"
exit "$rc"
