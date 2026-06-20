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
RUNTIME="$HERE/kernel/arch/riscv64/cnum_runtime.c"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
EXPECT="CNUM-OK"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-cnum-test" || echo "cnum-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/cnum.o" "$WORK"
kernel_boot_compile_c_object "$RUNTIME" "$WORK/runtime.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
# NOTE: no freestanding.o — cnum.mc IS the mem/str libc here.
"$LLD" -T "$LDSCRIPT" "$WORK/runtime.o" "$WORK/cnum.o" $SUPPORT_OBJ -o "$WORK/cnum.elf"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/cnum.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

if printf '%s' "$OUT" | grep -q "$EXPECT"; then
    echo "PASS: $TEST_NAME — $BACKEND backend ran the all-MC ctype + integer parsing correctly under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected '$EXPECT' in kernel output"
exit 1
