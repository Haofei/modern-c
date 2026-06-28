#!/usr/bin/env bash
# WASM-agent Phase 5 CPU-runaway watchdog gate. A thin wrapper over wasm-confined-test.sh that arms
# the machine-timer watchdog (WD_TICKS budget) and runs the runaway guest (examples/apps/wasm/
# wasi_runaway.c — an infinite CPU loop that never syscalls). Success = the confined agent is
# preempted and KILLED ("WATCHDOG-KILL"), i.e. an untrusted agent cannot wedge the system with
# unbounded CPU; the system fails closed instead of hanging to the QEMU timeout. See
# docs/wasm-migration-plan.md Phase 5 (fuel/budgets). Coarse liveness bound, NOT deterministic fuel.
#
# Usage: tools/lang/wasm-watchdog-test.sh <mcc> [c|llvm]
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
exec env WD_TICKS="${WD_TICKS:-20}" bash "$HERE/tools/lang/wasm-confined-test.sh" \
    "$MCC" "$BACKEND" examples/apps/wasm/wasi_runaway.c "WATCHDOG-KILL" wasm-watchdog
