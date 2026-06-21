#!/usr/bin/env bash
# Runtime test for the MC mem/string core (user/libc/cstr.mc) on riscv64. Lowers cstr.mc through
# the selected backend and links it with a C runtime that drives memcpy/memset/memmove/memcmp/
# strlen/strcmp/strncmp/strchr/memchr through the standard prototypes (as QuickJS will), then
# runs under QEMU. Linked WITHOUT freestanding.c so the MC definitions are the only mem/str libc.
#
# Usage: tools/lang/cstr-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/user/libc/cstr.mc"
# The boot seam + driver is now PURE MC (no .c runtime): `_start` is `#[naked]` MC, the
# console is mmio_console over the bare 16550, and the mem/str symbols under test are
# declared `extern fn` and driven directly. Linked as a SECOND MC object alongside cstr.mc.
RUNTIME="$HERE/tests/qemu/arch/cstr_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
EXPECT="CSTR-OK"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-cstr-test" || echo "cstr-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imafdc -mabi=lp64d
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

MC_FP=1 kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/cstr.o" "$WORK"
MC_FP=1 kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
# NOTE: no freestanding.o — cstr.mc IS the mem/str libc here.
"$LLD" -T "$LDSCRIPT" "$WORK/runtime.o" "$WORK/cstr.o" $SUPPORT_OBJ -o "$WORK/cstr.elf"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/cstr.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

if printf '%s' "$OUT" | grep -q "$EXPECT"; then
    echo "PASS: $TEST_NAME — $BACKEND backend ran the all-MC mem/string core (mem*/str*) correctly under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected '$EXPECT' in kernel output"
exit 1
