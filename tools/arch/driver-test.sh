#!/usr/bin/env bash
# Runnable driver-framework test.
#
# Lowers the driver-framework demo through the selected backend, links it with
# the scheduler/context runtime into a bare riscv64 image, and runs it under QEMU.
#
# Usage: tools/arch/driver-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/arch/driver_demo.mc"
# The test-entry runtime is now PURE MC (no .c): it prints the banner, runs the demo
# (which writes "DRV" through the registered driver), reports the device id, and halts.
# `_start`/`mc_halt` still come from the shared C bring-up runtime, linked beside it.
RUNTIME="$HERE/tests/qemu/arch/driver_runtime.mc"
SHARED="$HERE/tests/qemu/proc/context_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-driver-test" || echo "driver-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/thread.o" "$WORK"
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK"
kernel_boot_compile_c_object "$SHARED" "$WORK/shared.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/shared.o" "$WORK/runtime.o" "$WORK/thread.o" $SUPPORT_OBJ -o "$WORK/thread.elf"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/thread.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

# The driver framework writes "DRV" through the registered char device.
if printf '%s' "$OUT" | grep -q "DRV" \
   && printf '%s' "$OUT" | grep -q "DRIVER-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend char-device driver framework dispatched putc through a function-pointer vtable (DRV) under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected DRV and DRIVER-OK in kernel output"
exit 1
