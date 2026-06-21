#!/usr/bin/env bash
# Runnable kernel-thread test (cooperative context switching).
#
# Lowers the per-process address-space demo through the selected backend, links
# it into a bare riscv64 image, and runs it under QEMU.
#
# Usage: tools/mem/vmspace-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/mem/vmspace_demo.mc"
RUNTIME="$HERE/tests/qemu/mem/vmspace_runtime.mc"
STUBS="$HERE/tests/qemu/mem/proc_ctx_stubs.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-vmspace-test" || echo "vmspace-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/thread.o" "$WORK"
mkdir -p "$WORK/rt" "$WORK/stubs"
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK/rt"
kernel_boot_compile_mc_object "$BACKEND" "$STUBS" "$WORK/stubs.o" "$WORK/stubs"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/runtime.o" "$WORK/stubs.o" "$WORK/thread.o" $SUPPORT_OBJ -o "$WORK/thread.elf"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/thread.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

# Both harts must check in (the boot hart reports the total).
if printf '%s' "$OUT" | grep -q "VMSPACE-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend gave each process its own page table (satp); each saw its own value at the same VA under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected 'VMSPACE-OK' in kernel output"
exit 1
