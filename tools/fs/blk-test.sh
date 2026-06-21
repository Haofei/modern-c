#!/usr/bin/env bash
# Real virtio-blk driver execution test (virtio 1.x over virtio-mmio).
#
# Lowers the MC virtio-blk driver through the selected backend, links it into a
# bare-metal riscv64 image with the platform runtime, runs it under
# qemu-system-riscv64 -machine virt with an attached `virtio-blk-device`, and
# checks that the driver reads sector 0 through a 3-descriptor request chain.
#
# Usage: tools/fs/blk-test.sh <path-to-mcc> [c|llvm]
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
# PURE-MC M-mode runtime: the boot seam (`#[naked]` `_start` in .text.start), the
# bare-UART console, the virtio-mmio probe, and the vring globals are MC
# (blk_mmode_demo.mc, which imports the SAME blk_demo.mc driver as the S-mode path).
SRC="$HERE/tests/qemu/arch/blk_mmode_demo.mc"
# std/dma + std/time platform primitives (CLINT mtime + bump DMA pool) — a SEPARATE
# MC object so its definitions bind the std `extern fn` seam by name (a single MC
# unit may not both import the `extern fn` declaration and define it).
PLATFORM="$HERE/kernel/arch/riscv64/mmode_dma_time.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
EXPECT="BLK-READ DISK"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-blk-test" || echo "blk-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/virtio.o" "$WORK"
kernel_boot_compile_mc_object "$BACKEND" "$PLATFORM" "$WORK/platform.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/virtio.o" "$WORK/platform.o" $SUPPORT_OBJ -o "$WORK/virtio.elf"

# 3. Run under QEMU with an attached virtio-blk device.
printf 'DISK' >"$WORK/disk.img"; dd if=/dev/zero bs=1 count=508 >>"$WORK/disk.img" 2>/dev/null
OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -global virtio-mmio.force-legacy=false \
        -drive file="$WORK/disk.img",format=raw,if=none,id=d0 \
        -device virtio-blk-device,drive=d0 \
        -kernel "$WORK/virtio.elf" 2>/dev/null || true)"

echo "--- driver UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

if printf '%s' "$OUT" | grep -q "$EXPECT" && printf '%s' "$OUT" | grep -q "BLK-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend MC virtio-blk driver read sector 0 via a 3-descriptor request chain (got 'DISK') under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected '$EXPECT' and BLK-OK in driver output"
exit 1
