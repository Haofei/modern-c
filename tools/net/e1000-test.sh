#!/usr/bin/env bash
# Real e1000 PCI NIC probe test.
#
# Lowers the e1000 probe through the selected backend, links it with the RISC-V
# runtime into a bare image, and runs it under QEMU with an emulated e1000.
#
# Usage: tools/net/e1000-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/net/e1000_demo.mc"
RUNTIME="$HERE/kernel/arch/riscv64/e1000_runtime.c"
SHARED="$HERE/kernel/arch/riscv64/context_runtime.c"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-e1000-test" || echo "e1000-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/thread.o" "$WORK"
kernel_boot_compile_c_object "$RUNTIME" "$WORK/runtime.o"
kernel_boot_compile_c_object "$SHARED" "$WORK/shared.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
"$LLD" -T "$LDSCRIPT" "$WORK/shared.o" "$WORK/runtime.o" "$WORK/thread.o" $SUPPORT_OBJ -o "$WORK/thread.elf"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/thread.elf" -device e1000 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

if printf '%s' "$OUT" | grep -q "E1000-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend real-hardware NIC driver: PCI-enumerated + found the Intel e1000 (vendor 0x8086/dev 0x100E) and read its BAR over ECAM config space (E1000-OK) under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected E1000-OK"
exit 1
