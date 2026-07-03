#!/usr/bin/env bash
# QEMU MMIO execution test.
#
# Lowers a typed-MMIO MC program through the selected backend, links it into a
# bare-metal riscv64 image, runs it under qemu-system-riscv64 -machine virt, and
# checks that the emulated 16550 UART actually received the bytes written through
# the MMIO lowering.
#
# Usage: tools/arch/qemu-mmio-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/arch/uart_mmio.mc"
RUNTIME="$HERE/tests/qemu/runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
EXPECT="MMIO-OK"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-qemu-mmio-test" || echo "qemu-mmio-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/uart.o" "$WORK"
kernel_boot_compile_c_object "$RUNTIME" "$WORK/runtime.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/runtime.o" "$WORK/uart.o" $SUPPORT_OBJ -o "$WORK/test.elf"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic -kernel "$WORK/test.elf" 2>/dev/null || true)"

if printf '%s' "$OUT" | grep -q "$EXPECT"; then
    echo "PASS: $TEST_NAME — $BACKEND backend UART received '$EXPECT' via typed MMIO"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected '$EXPECT' in UART output, got:"
printf '%s\n' "$OUT"
exit 1
