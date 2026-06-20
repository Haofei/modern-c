#!/usr/bin/env bash
# Runtime test for the MC printf family (user/libc/stdio.mc) on riscv64. Lowers stdio.mc (+
# cstr.mc, which supplies the memset/memcpy the struct copies need) through the selected backend,
# links a C runtime that provides the mc_console_write hook and checks snprintf output against
# expected strings, and runs under QEMU. Linked WITHOUT freestanding.c — the MC libc is the only
# mem/str/stdio.
#
# Usage: tools/lang/stdio-test.sh <path-to-mcc> [c|llvm]
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
# Compile the WHOLE aggregated libc (one unit) — the artifact QuickJS links: snprintf/printf +
# the memset/memcpy the struct copies need, with no cross-object std/* duplication.
LIBC="$HERE/user/libc/libc.mc"
RUNTIME="$HERE/kernel/arch/riscv64/stdio_runtime.c"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
EXPECT="STDIO-OK"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-stdio-test" || echo "stdio-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imafdc -mabi=lp64d
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

MC_FP=1 kernel_boot_compile_mc_object "$BACKEND" "$LIBC" "$WORK/libc.o" "$WORK"
kernel_boot_compile_c_object "$RUNTIME" "$WORK/runtime.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
bash "$HERE/tools/user/build-openlibm.sh" "$WORK/libm.a" >/dev/null
"$LLD" -T "$LDSCRIPT" "$WORK/runtime.o" "$WORK/libc.o" $SUPPORT_OBJ "$WORK/libm.a" -o "$WORK/stdio.elf"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/stdio.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

if printf '%s' "$OUT" | grep -q "$EXPECT"; then
    echo "PASS: $TEST_NAME — $BACKEND backend ran the all-MC printf family (snprintf/printf, integer/string/char/pointer specifiers, flags/width/precision/length, truncation) under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected '$EXPECT' in kernel output"
exit 1
