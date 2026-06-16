#!/usr/bin/env bash
# Runnable kernel-thread test (cooperative context switching).
#
# Lowers the socket-syscall demo through the selected backend, links it with the
# asm user-mode runtime into a bare riscv64 image, and runs it under QEMU.
#
# Usage: tools/net/socket-syscall-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/net/socket_syscall_demo.mc"
RUNTIME="$HERE/kernel/arch/riscv64/socket_syscall_runtime.c"
SHARED="$HERE/kernel/arch/riscv64/context_runtime.c"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-socket-syscall-test" || echo "socket-syscall-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/thread.o" "$WORK"
kernel_boot_compile_c_object "$RUNTIME" "$WORK/runtime.o"
kernel_boot_compile_c_object "$SHARED" "$WORK/shared.o"
kernel_boot_compile_c_object "$HERE/kernel/arch/riscv64/usermode_runtime.c" "$WORK/usermode.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/shared.o" "$WORK/usermode.o" "$WORK/runtime.o" "$WORK/thread.o" $SUPPORT_OBJ -o "$WORK/thread.elf"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/thread.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

# The U-mode program recvfrom's the datagram the kernel delivered to its socket;
# "RHELLO" proves the payload crossed socket -> syscall -> copy_to_user -> user.
if printf '%s' "$OUT" | grep -q "RHELLO" \
   && printf '%s' "$OUT" | grep -q "USER-EXIT from U"; then
    echo "PASS: $TEST_NAME — $BACKEND backend U-mode recvfrom pulled a demultiplexed UDP datagram through the socket layer (RHELLO) under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected RHELLO and 'USER-EXIT from U' in kernel output"
exit 1
