#!/usr/bin/env bash
# Runnable structured-metrics + deterministic-replay test.
#
# Lowers the metrics demo (tests/qemu/proc/metrics_demo.mc) through the selected backend, links it
# with the bare-metal entry runtime + the shared M-mode bring-up runtime into a bare riscv64 image,
# and runs it under QEMU. The demo drives a fixed event mix through BOTH a live Metrics and an
# EventLog, replays the log into a fresh Metrics, and asserts byte-identical counters (REPLAY-OK)
# plus counter totals and the bounded-log invariant (METRICS-OK) — printing METRICS-REPLAY-OK iff
# all assertions hold.
#
# Usage: tools/proc/metrics-test.sh <path-to-mcc> [c|llvm]
# Skips (exit 0) when the riscv toolchain or QEMU is unavailable.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
SRC="$HERE/tests/qemu/proc/metrics_demo.mc"
RUNTIME="$HERE/tests/qemu/proc/metrics_runtime.mc"
SHARED="$HERE/tests/qemu/proc/context_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-metrics-test" || echo "metrics-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/metrics.bin.o" "$WORK"
mkdir -p "$WORK/rt"
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK/rt"
kernel_boot_compile_c_object "$SHARED" "$WORK/shared.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/shared.o" "$WORK/runtime.o" "$WORK/metrics.bin.o" $SUPPORT_OBJ -o "$WORK/metrics.elf"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/metrics.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

# REPLAY-OK proves replayed counters == live counters byte-for-byte; METRICS-OK proves the totals
# + bounded-log invariant; METRICS-REPLAY-OK is printed only when every assertion held.
if printf '%s' "$OUT" | grep -q "REPLAY-OK" \
   && printf '%s' "$OUT" | grep -q "METRICS-OK" \
   && printf '%s' "$OUT" | grep -q "METRICS-REPLAY-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend metrics counters aggregated + a bounded event log replayed deterministically to identical state under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected REPLAY-OK, METRICS-OK and METRICS-REPLAY-OK in kernel output"
exit 1
