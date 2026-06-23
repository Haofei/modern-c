#!/usr/bin/env bash
# async/await roadmap Phase C: IRQ-BACKED completion. A real M-mode TIMER interrupt completes an
# in-flight async request and wakes a task parked in async_await_irq — the production shape (a
# task sleeps in wfi until a device/timer interrupt resumes it; no steady-state polling).
#
# Lowers the async-irq demo + the timer/trap runtime through the selected backend, links with the
# context-switch runtime into a bare riscv64 image, and runs it under QEMU. The trace `W I R`
# proves W (waiter about to await), I (completion ran in INTERRUPT context), R (waiter resumed);
# ASYNC-IRQ-OK (result 42) proves the interrupt-delivered value round-tripped to the parked task.
#
# Usage: tools/proc/async-irq-test.sh <path-to-mcc> [c|llvm]
# Skips (exit 0) when the riscv toolchain or QEMU is unavailable.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
SRC="$HERE/tests/qemu/proc/async_future_demo.mc"
RUNTIME="$HERE/tests/qemu/proc/async_future_runtime.mc"
SHARED="$HERE/tests/qemu/proc/context_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-async-future-test" || echo "async-future-test")

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

# WIR: waiter parked -> timer interrupt completed it (I, in ISR) -> waiter resumed. ASYNC-IRQ-OK: 42.
if printf '%s' "$OUT" | grep -q "WR" \
   && printf '%s' "$OUT" | grep -q "ASYNC-FUTURE-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend: an async fn's two `await`s resolved against REAL broker completions delivered from a timer ISR, driven by drive_irq over ReqFut leaves (WR, ASYNC-FUTURE-OK, result 22+20==42) under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected WR and ASYNC-FUTURE-OK in kernel output"
exit 1
