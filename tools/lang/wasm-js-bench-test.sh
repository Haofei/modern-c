#!/usr/bin/env bash
# WASM-agent Phase 7 (docs/wasm-migration-plan.md §5): JS performance benchmark — QuickJS-on-WASM vs
# native QuickJS. Runs the SAME deterministic JS workload on both confined paths under QEMU:
#   - native: the hand-written C host (qjs_host.c) evaluating examples/agents/agent_bench.js;
#   - wasm:   QuickJS compiled to wasm32-wasi on WAMR, evaluating examples/apps/wasm/wasi_js_bench.c
#             (the byte-equivalent computation).
# Emits a report artifact (zig-out/wasm-js-bench.json) with each path's QEMU wall time + U-mode image
# size + their ratios, the backend, and the git commit. The GATE is functional-parity-based (the two
# paths must produce the SAME numeric result — deterministic), plus report completeness; the timings
# are recorded for the Phase-8 retirement decision (QEMU numbers are INDICATIVE — the production
# decision must use the target-board profile, per §4). It does NOT hard-fail on a timing ratio (QEMU
# wall time is not deterministic); only a missing measurement or a path failure fails the gate.
#
# Usage: tools/lang/wasm-js-bench-test.sh <mcc> [c|llvm]
# NB: no `set -e` — the marker extractions below use grep, which returns non-zero on no-match; the
# explicit fail() checks classify the outcome (and print the offending path's tail) instead.
set -uo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
BACKEND="${2:-c}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-wasm-js-bench-test" || echo "wasm-js-bench-test")

# Run both confined paths with the benchmark hooks on (BENCH=1 makes the harnesses also print
# BENCH-QEMU-MS + BENCH-AGENT-ELF-BYTES). Capture full output; tolerate sub-script non-zero exit
# (we classify SKIP/FAIL ourselves from the markers).
NAT="$(BENCH=1 bash "$HERE/tools/lang/qjs-agent-test.sh" "$MCC" "$BACKEND" examples/agents/agent_bench.js "BENCH-RESULT=" qjs-jsbench 2>&1 || true)"
WAS="$(BENCH=1 bash "$HERE/tools/lang/wasm-confined-test.sh" "$MCC" "$BACKEND" examples/apps/wasm/wasi_js_bench.c "BENCH-RESULT=" wasm-jsbench qjs 2>&1 || true)"

# Environment skips (no riscv toolchain / qemu) propagate as a skip, not a failure.
if printf '%s\n%s' "$NAT" "$WAS" | grep -q "^SKIP:"; then
    echo "SKIP: $TEST_NAME — a confined path self-skipped (toolchain/qemu unavailable)"
    exit 0
fi

field() { printf '%s' "$2" | grep -oE "$1=[0-9-]+" | head -1 | cut -d= -f2; }
NAT_RES="$(field BENCH-RESULT "$NAT")"; WAS_RES="$(field BENCH-RESULT "$WAS")"
NAT_MS="$(printf '%s' "$NAT" | grep -oE 'BENCH-QEMU-MS: [0-9]+' | head -1 | awk '{print $2}')"
WAS_MS="$(printf '%s' "$WAS" | grep -oE 'BENCH-QEMU-MS: [0-9]+' | head -1 | awk '{print $2}')"
NAT_ELF="$(printf '%s' "$NAT" | grep -oE 'BENCH-AGENT-ELF-BYTES: [0-9]+' | head -1 | awk '{print $2}')"
WAS_ELF="$(printf '%s' "$WAS" | grep -oE 'BENCH-AGENT-ELF-BYTES: [0-9]+' | head -1 | awk '{print $2}')"
NAT_PASS=$(printf '%s' "$NAT" | grep -cE "^PASS:") ; WAS_PASS=$(printf '%s' "$WAS" | grep -cE "^PASS:")

echo "--- Phase-7 JS benchmark ($BACKEND) ---"
echo "native: pass=$NAT_PASS result=${NAT_RES:-?} qemu_ms=${NAT_MS:-?} elf_bytes=${NAT_ELF:-?}"
echo "wasm:   pass=$WAS_PASS result=${WAS_RES:-?} qemu_ms=${WAS_MS:-?} elf_bytes=${WAS_ELF:-?}"

fail() { echo "FAIL: $TEST_NAME — $1"; exit 1; }
[ "$NAT_PASS" -ge 1 ] || { printf '%s\n' "$NAT" | tail -20; fail "native QuickJS path did not pass"; }
[ "$WAS_PASS" -ge 1 ] || { printf '%s\n' "$WAS" | tail -20; fail "QuickJS-on-WASM path did not pass"; }
[ -n "$NAT_RES" ] && [ -n "$WAS_RES" ] || fail "missing BENCH-RESULT on one path"
[ "$NAT_RES" = "$WAS_RES" ] || fail "result mismatch (native=$NAT_RES wasm=$WAS_RES) — not functional parity"
[ -n "$NAT_MS" ] && [ -n "$WAS_MS" ] && [ -n "$NAT_ELF" ] && [ -n "$WAS_ELF" ] || fail "a required measurement is missing"

# Ratios (integer ×100 to avoid floats). Recorded for the decision; not a gate threshold.
ratio() { [ "$2" -gt 0 ] && echo $(( $1 * 100 / $2 )) || echo 0; }
MS_RATIO="$(ratio "$WAS_MS" "$NAT_MS")"     # wasm/native QEMU wall time, ×100
ELF_RATIO="$(ratio "$WAS_ELF" "$NAT_ELF")"  # wasm/native U-mode image size, ×100
COMMIT="$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo unknown)"

mkdir -p "$HERE/zig-out"
REPORT="$HERE/zig-out/wasm-js-bench${BACKEND:+-$BACKEND}.json"
cat > "$REPORT" <<JSON
{
  "phase": 7,
  "backend": "$BACKEND",
  "commit": "$COMMIT",
  "qemu_indicative": true,
  "result": $NAT_RES,
  "native":  { "qemu_ms": $NAT_MS, "elf_bytes": $NAT_ELF },
  "wasm":    { "qemu_ms": $WAS_MS, "elf_bytes": $WAS_ELF },
  "ratio_x100": { "qemu_ms": $MS_RATIO, "elf_bytes": $ELF_RATIO }
}
JSON
echo "report: $REPORT"
echo "  qemu_ms wasm/native = ${MS_RATIO}%   elf_bytes wasm/native = ${ELF_RATIO}%"

# Generous absolute sanity cap (a hung/broken path; the 120s sub-script timeout would already FAIL it).
if [ "$WAS_MS" -gt 600000 ]; then fail "wasm QEMU wall time ${WAS_MS}ms exceeds the 600s sanity cap"; fi

echo "PASS: $TEST_NAME — $BACKEND backend: native QuickJS and QuickJS-on-WASM evaluated the same JS workload to the SAME result ($NAT_RES) confined under QEMU; benchmark report emitted (timings indicative; production decision uses the target-board profile)"
exit 0
