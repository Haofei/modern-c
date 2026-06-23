#!/usr/bin/env bash
# async/await roadmap Phase D step 6 (runtime half): the broker-side CANCELLATION primitive
# (kernel/lib/async.mc `async_cancel`) under the real bring-up runtime.
#
# Lowers the async-cancel demo (fill the inflight quota, cancel one in-flight request, prove the
# slot is reclaimed by a fresh submit, a late completion on the canceled id is a no-op, and a
# double-cancel is idempotent) through the selected backend, links it with the context-switch
# runtime into a bare riscv64 image, and runs it under QEMU. The trace `FXR` (filled / canceled /
# reused) plus `ASYNC-CANCEL-OK` proves a dropped pending request does not leak its MAX_INFLIGHT
# slot — the correctness gap that, unfixed, eventually wedges submission on an agent OS.
#
# Usage: tools/proc/async-cancel-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/proc/async_cancel_demo.mc"
RUNTIME="$HERE/tests/qemu/proc/async_cancel_runtime.mc"
SHARED="$HERE/tests/qemu/proc/context_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-async-cancel-test" || echo "async-cancel-test")

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
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/shared.o" "$WORK/runtime.o" "$WORK/demo.o" $SUPPORT_OBJ -o "$WORK/async-cancel.elf"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/async-cancel.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

# FXR: filled the quota -> canceled one -> reused the reclaimed slot. ASYNC-CANCEL-OK: all checks.
if printf '%s' "$OUT" | grep -q "FXR" \
   && printf '%s' "$OUT" | grep -q "ASYNC-CANCEL-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend async_cancel reclaims a dropped request's inflight slot: filled MAX_INFLIGHT, canceled one, a fresh submit reused the slot, a late completion on the canceled id was a no-op, double-cancel idempotent (FXR, ASYNC-CANCEL-OK) under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected FXR and ASYNC-CANCEL-OK in kernel output"
exit 1
