#!/usr/bin/env bash
# Runnable kernel-thread test (cooperative context switching).
#
# Lowers the crash-containment demo through the selected backend, links it into a
# bare riscv64 image, and runs it under QEMU.
#
# Usage: tools/mem/contain-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/kernel/core/demand.mc"
RUNTIME="$HERE/tests/qemu/proc/contain_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-contain-test" || echo "contain-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/thread.o" "$WORK"
mkdir -p "$WORK/rt"
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK/rt"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
kernel_boot_link_run "$TEST_NAME" "CONTAINED-OK" \
    "$BACKEND backend MMU crash containment: a server dereferenced an unmapped address; the fault handler contained it (redirected to recovery, no panic) and the system continued (CONTAINED-OK) under QEMU" \
    "$WORK/freestanding.o" "$WORK/runtime.o" "$WORK/thread.o" $SUPPORT_OBJ
