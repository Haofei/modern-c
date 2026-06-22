#!/usr/bin/env bash
# Runnable kernel-thread test (cooperative context switching).
#
# Lowers the user-mode syscall demo through the selected backend, links it with
# the asm user-mode runtime into a bare riscv64 image, and runs it under QEMU.
#
# Usage: tools/lang/user-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/lang/syscall_demo.mc"
RUNTIME="$HERE/tests/qemu/lang/user_runtime.mc"
SHARED="$HERE/kernel/arch/riscv64/context_runtime.c"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-user-test" || echo "user-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/thread.o" "$WORK"
mkdir -p "$WORK/rt"
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK/rt"
kernel_boot_compile_c_object "$SHARED" "$WORK/shared.o"
kernel_boot_compile_c_object "$HERE/tests/qemu/proc/usermode_runtime.mc" "$WORK/usermode.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/shared.o" "$WORK/usermode.o" "$WORK/runtime.o" "$WORK/thread.o" $SUPPORT_OBJ -o "$WORK/thread.elf"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/thread.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

# The U-mode task prints USR via syscalls; copy_from_user validates + copies a user
# buffer (FROMUSER) and rejects an out-of-range pointer (the task then prints R);
# the exit ecall coming from U-mode proves the privilege drop.
if printf '%s' "$OUT" | grep -q "USR" \
   && printf '%s' "$OUT" | grep -q "FROMUSER" \
   && printf '%s' "$OUT" | grep -q "R" \
   && printf '%s' "$OUT" | grep -q "USER-EXIT from U"; then
    echo "PASS: $TEST_NAME — $BACKEND backend U-mode task: syscalls (USR), validated copy_from_user (FROMUSER + rejected bad ptr), exit from U under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected USR, FROMUSER, R, and 'USER-EXIT from U' in kernel output"
exit 1
