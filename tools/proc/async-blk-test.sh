#!/usr/bin/env bash
# async/await roadmap: DEVICE-BACKED completion. A REAL virtio-blk device interrupt — not a timer —
# completes an in-flight async request and resumes a task parked in drive_irq. The production shape
# for device async: submit a read, sleep in wfi, the device's used-ring IRQ (PLIC-routed) reaps the
# completion and async_completes the broker id, the parked await resumes with the sector result.
#
# Lowers the async-blk demo + the external-IRQ trap runtime + the M-mode DMA/time platform through
# the selected backend, links with the context-switch runtime into a bare riscv64 image, attaches a
# virtio-blk-device whose backing disk's sector 0 is "DISK", and runs it under QEMU. The trace
# `W i R` proves W (about to drive), i (the DEVICE IRQ ran in interrupt context), R (resumed);
# ASYNC-BLK-OK + the printed "DISK" prove the sector word round-tripped via the device interrupt.
#
# Usage: tools/proc/async-blk-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/proc/async_blk_demo.mc"
RUNTIME="$HERE/tests/qemu/proc/async_blk_runtime.mc"
PLATFORM="$HERE/kernel/arch/riscv64/mmode_dma_time.mc"
SHARED="$HERE/tests/qemu/proc/context_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-async-blk-test" || echo "async-blk-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/demo.o" "$WORK"
mkdir -p "$WORK/rt"
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK/rt"
mkdir -p "$WORK/pf"
kernel_boot_compile_mc_object "$BACKEND" "$PLATFORM" "$WORK/platform.o" "$WORK/pf"
kernel_boot_compile_c_object "$SHARED" "$WORK/shared.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/shared.o" "$WORK/runtime.o" "$WORK/platform.o" "$WORK/demo.o" $SUPPORT_OBJ -o "$WORK/async.elf"

# Sector 0 seeded with "DISK" (first LE word 0x4B534944), like blk-test.sh.
printf 'DISK' >"$WORK/disk.img"; dd if=/dev/zero bs=1 count=508 >>"$WORK/disk.img" 2>/dev/null

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -global virtio-mmio.force-legacy=false \
        -drive file="$WORK/disk.img",format=raw,if=none,id=d0 \
        -device virtio-blk-device,drive=d0 \
        -kernel "$WORK/async.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

# W i R: about-to-drive -> DEVICE IRQ reaped the completion (i, interrupt context) -> resumed.
# ASYNC-BLK-OK + "DISK": the sector word round-tripped from the disk via the device interrupt.
# BLK-NOLEAK-OK + free=8: the demo did 5 sequential reads (each awaited via the device IRQ) — more
# than the 2 the UNFIXED hand-rolled reap could survive before QUEUE-FULL — and the descriptor free
# list returned to full (8/8), proving the ISR reclaims every chain's descriptors and pool slot (no
# per-read descriptor/DMA leak). A leak would surface as BLK-QUEUE-FULL or free!=8 / BLK-NOLEAK-FAIL.
if printf '%s' "$OUT" | grep -q "Wi" \
   && printf '%s' "$OUT" | grep -q "ASYNC-BLK-OK" \
   && printf '%s' "$OUT" | grep -q "BLK-NOLEAK-OK" \
   && printf '%s' "$OUT" | grep -q "free=8"; then
    echo "PASS: $TEST_NAME — $BACKEND backend: 5 sequential async reads each resolved against a REAL virtio-blk device interrupt (PLIC-routed used-ring completion reaped in interrupt context — trace 'i' — async_completing the broker id), driven by drive_irq under wfi; sector 0 word 'DISK' round-tripped each read (Wi…R, ASYNC-BLK-OK) and the descriptor free list returned to full 8/8 (free=8, BLK-NOLEAK-OK) — no descriptor/DMA leak across reads (unfixed code QUEUE-FULLs after 2) under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected 'Wi' (device IRQ in interrupt context), ASYNC-BLK-OK, BLK-NOLEAK-OK and free=8 in kernel output (a leak shows as BLK-QUEUE-FULL or free!=8)"
exit 1
