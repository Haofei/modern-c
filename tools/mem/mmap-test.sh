#!/usr/bin/env bash
# Runnable kernel-thread test (cooperative context switching).
#
# Lowers the anonymous mmap demo through the selected backend, links it into a
# bare riscv64 image, and runs it under QEMU.
#
# Usage: tools/mem/mmap-test.sh <path-to-mcc> [c|llvm]
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
# PURE-MC M-mode kernel: the runtime imports tests/qemu/mem/mmap_demo.mc for the work;
# the boot seam, bare-UART console, and M->S privilege drop are all MC now (no .c).
SRC="$HERE/tests/qemu/mem/mmap_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-mmap-test" || echo "mmap-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The C backend lowers the MC kernel to C, then clang assembles it for bare riscv64.
CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/thread.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
kernel_boot_link_run "$TEST_NAME" "MMAP-OK" \
    "$BACKEND backend mmap two anonymous pages into a page table; under active satp both VAs read/write independent RAM (MMAP-OK) under QEMU" \
    "$WORK/freestanding.o" "$WORK/thread.o" $SUPPORT_OBJ
