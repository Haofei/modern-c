#!/usr/bin/env bash
# async/await roadmap Phase B: request-id-keyed PARK/WAKE completion broker
# (kernel/lib/async.mc) under the real cooperative scheduler.
#
# Lowers the async demo (two processes: a waiter that PARKS on submitted requests and a
# completer that wakes it, out of order) through the selected backend, links it with the
# context-switch runtime into a bare riscv64 image, and runs it under QEMU. The console trace
# `W C R` proves the waiter parked and yielded the CPU (so the completer ran) and then resumed
# after being woken; `ASYNC-OK` (result 42) proves both completions reached the waiter.
#
# Usage: tools/proc/async-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/proc/async_demo.mc"
RUNTIME="$HERE/tests/qemu/proc/async_runtime.mc"
SHARED="$HERE/tests/qemu/proc/context_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-async-test" || echo "async-test")

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

# WCR: waiter parked+yielded -> completer ran -> waiter resumed after wake. ASYNC-OK: 22+20==42.
if printf '%s' "$OUT" | grep -q "WCR" \
   && printf '%s' "$OUT" | grep -q "ASYNC-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend request-id park/wake broker: a task PARKED awaiting a submitted request, a completer woke it (out-of-order completions), result 22+20==42 (WCR, ASYNC-OK) under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected WCR and ASYNC-OK in kernel output"
exit 1
