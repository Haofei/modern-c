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
# The boot seam + driver is now PURE MC (no .c runtime): `_start` is `#[naked]` MC, the
# console is mmio_console over the bare 16550, and malloc/free/calloc/realloc are declared
# `extern fn` and driven directly. Linked as a SECOND MC object alongside alloc.mc.
RUNTIME="$HERE/tests/qemu/arch/alloc_runtime.mc"
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
MC_FP=1 kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
kernel_boot_link_run "$TEST_NAME" "$EXPECT" \
    "$BACKEND backend ran the all-MC allocator (reusing heap.mc's free-list): malloc/free/calloc/realloc, reuse-after-free, calloc-zero, and realloc-preserve all correct under QEMU" \
    "$WORK/freestanding.o" "$WORK/runtime.o" "$WORK/alloc.o" $SUPPORT_OBJ
