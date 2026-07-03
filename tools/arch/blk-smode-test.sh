#!/usr/bin/env bash
# Real virtio-blk driver execution test under REAL OpenSBI firmware in S-mode.
#
# Same EXISTING MC virtio-blk driver (tests/qemu/fs/blk_demo.mc) as the M-mode
# blk-test, but linked with the S-mode/OpenSBI runtime (blk_smode_runtime.c) and
# the OpenSBI payload linker script (sbi.ld), and run WITHOUT `-bios none` so
# QEMU loads the real OpenSBI firmware which boots our kernel in S-mode at
# 0x80200000. The driver reads sector 0 of the attached virtio-blk-device via a
# 3-descriptor request chain (satp=0 Bare mode = flat physical; OpenSBI's PMP
# permits S-mode RAM+MMIO so the DMA works unchanged).
#
# Usage: tools/arch/blk-smode-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/arch/blk_smode_demo.mc"
LDSCRIPT="$HERE/tests/qemu/sbi.ld"
EXPECT="BLK-READ DISK"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-blk-smode-test" || echo "blk-smode-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-function -fno-builtin)

# PURE-MC kernel: `_start` + boot seam are `#[naked]` MC; the SBI seam and the
# virtio-mmio probe are MC (sbi.mc / sbi_virtio_probe.mc); the virtio-blk driver is
# the same MC driver as the M-mode path — no .c runtime. The std/dma + std/time
# platform primitives (rdtime time source + bump DMA pool) are MC too
# (sbi_dma_time.mc), compiled as a SEPARATE object and linked so its definitions
# bind the std `extern fn` seam by name (a single MC unit may not both import the
# `extern fn` declaration and define it).
kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/virtio.o" "$WORK"
kernel_boot_compile_mc_object "$BACKEND" "$HERE/kernel/arch/riscv64/sbi_dma_time.mc" "$WORK/platform.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/virtio.o" "$WORK/platform.o" $SUPPORT_OBJ -o "$WORK/virtio.elf"

# Run under QEMU with an attached virtio-blk device. NO '-bios none' -> QEMU
# loads OpenSBI (the real firmware) which boots our kernel in S-mode.
printf 'DISK' >"$WORK/disk.img"; dd if=/dev/zero bs=1 count=508 >>"$WORK/disk.img" 2>/dev/null
OUT="$(timeout 30 "$QEMU" -machine virt -m 256M -nographic \
        -global virtio-mmio.force-legacy=false \
        -drive file="$WORK/disk.img",format=raw,if=none,id=d0 \
        -device virtio-blk-device,drive=d0 \
        -kernel "$WORK/virtio.elf" 2>/dev/null || true)"

echo "--- OpenSBI + driver UART output ---"
printf '%s\n' "$OUT"
echo "------------------------------------"

if printf '%s' "$OUT" | grep -qi "OpenSBI" \
   && printf '%s' "$OUT" | grep -q "$EXPECT" \
   && printf '%s' "$OUT" | grep -q "BLK-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend MC virtio-blk driver read sector 0 via a 3-descriptor request chain (got 'DISK') under REAL OpenSBI in S-mode (satp=0 Bare; OpenSBI PMP permits S-mode virtio-mmio + RAM DMA; time via rdtime CSR)"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected OpenSBI banner + '$EXPECT' + BLK-OK in driver output"
exit 1
