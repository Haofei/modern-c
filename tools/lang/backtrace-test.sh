#!/usr/bin/env bash
# Runnable backtrace test.
#
# Lowers the symbol/backtrace demo through the selected backend, links it into a
# bare riscv64 image, and runs it under QEMU.
#
# Usage: tools/lang/backtrace-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/lang/symbols_demo.mc"
RUNTIME="$HERE/tests/qemu/lang/backtrace_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-backtrace-test" || echo "backtrace-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -fno-omit-frame-pointer -fno-optimize-sibling-calls -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/thread.o" "$WORK"
# The pure-MC backtrace runtime needs the frame pointer (s0) retained so its
# `#[noinline]` level1/level2/level3 functions each keep a walkable frame. The C
# path gets this from -fno-omit-frame-pointer in CFLAGS (above); the LLVM path gets
# it from -frame-pointer=all forwarded to llc via MC_LLC_EXTRA.
mkdir -p "$WORK/rt"
MC_LLC_EXTRA="-frame-pointer=all" \
    kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK/rt"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
kernel_boot_link_run "$TEST_NAME" "BT-OK" \
    "$BACKEND backend walked the frame-pointer chain and symbolized the captured frames under QEMU" \
    "$WORK/freestanding.o" "$WORK/runtime.o" "$WORK/thread.o" $SUPPORT_OBJ
