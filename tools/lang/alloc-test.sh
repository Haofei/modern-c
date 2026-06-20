#!/usr/bin/env bash
# Runtime test for the MC C-ABI allocator (user/libc/alloc.mc) on riscv64. Lowers the allocator
# through the selected backend, links it with a C runtime that drives malloc/free/calloc/realloc
# through the standard prototypes (as QuickJS will), and runs the image under QEMU. Proves the
# all-MC allocator — which reuses kernel/core/heap.mc's free-list — is correct on both backends.
#
# Usage: tools/lang/alloc-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/user/libc/alloc.mc"
RUNTIME="$HERE/kernel/arch/riscv64/alloc_runtime.c"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
EXPECT="ALLOC-OK"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-alloc-test" || echo "alloc-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# RISC-V freestanding target — the boot-lib C-compile helper consumes this `CFLAGS` array.
CFLAGS=(--target=riscv64-unknown-elf -march=rv64imafdc -mabi=lp64d
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

MC_FP=1 kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/alloc.o" "$WORK"
kernel_boot_compile_c_object "$RUNTIME" "$WORK/runtime.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/runtime.o" "$WORK/alloc.o" $SUPPORT_OBJ -o "$WORK/alloc.elf"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/alloc.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

if printf '%s' "$OUT" | grep -q "$EXPECT"; then
    echo "PASS: $TEST_NAME — $BACKEND backend ran the all-MC allocator (reusing heap.mc's free-list): malloc/free/calloc/realloc, reuse-after-free, calloc-zero, and realloc-preserve all correct under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected '$EXPECT' in kernel output"
exit 1
