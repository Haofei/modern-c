#!/usr/bin/env bash
# Runtime test for MC C-ABI varargs on riscv64. Lowers a variadic MC function
# (tests/qemu/lang/vararg_demo.mc) through the selected backend, links it with a C runtime
# that calls it with several argument counts (incl. stack-spilled varargs), and runs the image
# under QEMU. Proves the `va.*` intrinsics implement the platform varargs ABI on BOTH backends.
#
# Usage: tools/lang/vararg-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/lang/vararg_demo.mc"
# The boot seam + driver is now PURE MC (no .c runtime): `_start` is `#[naked]` MC, the
# console is mmio_console over the bare 16550, and `sum_args` is bound through a fixed
# C-ABI prototype (see the runtime's header). Linked as a SECOND MC object alongside the
# variadic unit under test, exactly as the old vararg_runtime.c object was.
RUNTIME="$HERE/tests/qemu/arch/vararg_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
EXPECT="VARARG-OK"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-vararg-test" || echo "vararg-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# RISC-V freestanding target — the boot-lib C-compile helper consumes this `CFLAGS` array.
CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/vararg.o" "$WORK"
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
kernel_boot_link_run "$TEST_NAME" "$EXPECT" \
    "$BACKEND backend lowered a C-ABI variadic MC fn; va.start/va.arg/va.end read all argument counts (incl. stack-spilled) correctly under QEMU" \
    "$WORK/freestanding.o" "$WORK/runtime.o" "$WORK/vararg.o" $SUPPORT_OBJ
