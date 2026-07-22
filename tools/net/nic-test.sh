#!/usr/bin/env bash
# Demo NIC driver execution test (Driver Library Profile, §28).
#
# Lowers the demo NIC driver — which composes std/{sync,dma,ring,endian,barrier}
# plus typed MMIO — through the selected backend, links it into a bare-metal
# riscv64 image with the platform runtime, runs it under qemu-system-riscv64
# -machine virt, and checks that the frame the driver "transmitted" arrived at
# the emulated UART.
#
# Usage: tools/net/nic-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/net/nic_driver.mc"
RUNTIME="$HERE/tests/qemu/nic_runtime.c"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
EXPECT="NIC-TX-OK"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-nic-test" || echo "nic-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/nic.o" "$WORK"
kernel_boot_compile_c_object "$RUNTIME" "$WORK/runtime.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/runtime.o" "$WORK/nic.o" $SUPPORT_OBJ -o "$WORK/nic.elf"

# 3. Run on emulated hardware and capture the UART output.
OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic -kernel "$WORK/nic.elf" 2>/dev/null || true)"

if printf '%s' "$OUT" | grep -q "$EXPECT"; then
    echo "PASS: $TEST_NAME — $BACKEND backend demo NIC driver transmitted '$EXPECT' (sync+dma+ring+endian+barrier+MMIO) under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected '$EXPECT' in UART output, got:"
printf '%s\n' "$OUT" | od -c | head
exit 1
