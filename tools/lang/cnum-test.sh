#!/usr/bin/env bash
# Runtime test for the MC mem/string core (user/libc/cnum.mc) on riscv64. Lowers cnum.mc through
# the selected backend and links it with a C runtime that drives memcpy/memset/memmove/memcmp/
# strlen/strcmp/strncmp/strchr/memchr through the standard prototypes (as QuickJS will), then
# runs under QEMU. Linked WITHOUT freestanding.c so the MC definitions are the only mem/str libc.
#
# Usage: tools/lang/cnum-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/user/libc/cnum.mc"
# The boot seam + driver is now PURE MC (no .c runtime): `_start` is `#[naked]` MC, the
# console is mmio_console over the bare 16550, and the ctype/strtol symbols under test are
# declared `extern fn` and driven directly. Linked as a SECOND MC object alongside cnum.mc.
RUNTIME="$HERE/tests/qemu/arch/cnum_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
EXPECT="CNUM-OK"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-cnum-test" || echo "cnum-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imafdc -mabi=lp64d
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

MC_FP=1 kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/cnum.o" "$WORK"
MC_FP=1 kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
bash "$HERE/tools/user/build-openlibm.sh" "$WORK/libm.a" >/dev/null
# NOTE: no freestanding.o — cnum.mc IS the mem/str libc here.
kernel_boot_link_run "$TEST_NAME" "$EXPECT" \
    "$BACKEND backend ran the all-MC ctype + integer parsing correctly under QEMU" \
    "$WORK/runtime.o" "$WORK/cnum.o" $SUPPORT_OBJ "$WORK/libm.a"
