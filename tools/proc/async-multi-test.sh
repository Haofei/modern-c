#!/usr/bin/env bash
# async/await roadmap E6: the MULTI-FUTURE cooperative executor `drive_many`. THREE independent
# async fns (each awaiting its own broker request via a ReqFut leaf) are driven CONCURRENTLY by a
# single drive_many call, sleeping in `wfi` between ISR-delivered completions; a re-armed M-mode
# timer completes the in-flight requests OUT OF ORDER (highest id first), so they resolve
# interleaved. This generalizes drive_irq (one future) to N with the same lost-wakeup-free IRQ-off
# idle discipline.
#
# Lowers the async-multi demo + the timer/trap runtime through the selected backend, links with the
# context-switch runtime into a bare riscv64 image, and runs it under QEMU. Trace `W R` (W = futures
# constructed/about to drive, R = all driven to completion); ASYNC-MULTI-OK (result 1) proves
# drive_many returned 3, each future got its own id-encoded result with the out-of-order schedule,
# exactly 3 completions fired, and async_active_count returned to 0 (no leaked broker slot).
#
# Usage: tools/proc/async-multi-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/proc/async_multi_demo.mc"
RUNTIME="$HERE/tests/qemu/proc/async_multi_runtime.mc"
SHARED="$HERE/tests/qemu/proc/context_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-async-multi-test" || echo "async-multi-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/demo.o" "$WORK"
mkdir -p "$WORK/rt"
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK/rt"
kernel_boot_compile_c_object "$SHARED" "$WORK/shared.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/shared.o" "$WORK/runtime.o" "$WORK/demo.o" $SUPPORT_OBJ -o "$WORK/async.elf"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/async.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

if printf '%s' "$OUT" | grep -q "WR" \
   && printf '%s' "$OUT" | grep -q "ASYNC-MULTI-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend: three independent async fns were driven CONCURRENTLY by drive_many, resolving against real broker completions delivered OUT OF ORDER from a re-armed timer ISR; all three completed (drive_many=3), each got its own result, and the active-slot count returned to 0 (WR, ASYNC-MULTI-OK) under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected WR and ASYNC-MULTI-OK in kernel output"
exit 1
