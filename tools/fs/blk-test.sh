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
SRC="$HERE/tests/qemu/fs/blk_demo.mc"
RUNTIME="$HERE/kernel/arch/riscv64/blk_runtime.c"
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
kernel_boot_compile_c_object "$RUNTIME" "$WORK/runtime.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
"$LLD" -T "$LDSCRIPT" "$WORK/runtime.o" "$WORK/virtio.o" $SUPPORT_OBJ -o "$WORK/virtio.elf"

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
