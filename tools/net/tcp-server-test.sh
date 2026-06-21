#!/usr/bin/env bash
# Runnable TCP server test.
#
# Lowers the TCP server demo through the selected backend, links it with the
# scheduler/context runtime into a bare riscv64 image, and runs it under QEMU.
#
# Usage: tools/net/tcp-server-test.sh <path-to-mcc> [c|llvm]
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
# Boot seam now PURE MC (imports tcp_server_demo.mc; provides test_main). context_runtime.c
# (the green-thread context switch) stays C and provides the .text.start _start that calls it.
SRC="$HERE/tests/qemu/net/tcp_server_mmode_demo.mc"
SHARED="$HERE/kernel/arch/riscv64/context_runtime.c"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-tcp-server-test" || echo "tcp-server-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/thread.o" "$WORK"
kernel_boot_compile_c_object "$SHARED" "$WORK/shared.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/shared.o" "$WORK/thread.o" $SUPPORT_OBJ -o "$WORK/thread.elf"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/thread.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

# The TCP server must complete a passive-open handshake through IPC.
if printf '%s' "$OUT" | grep -q "TCPSRV-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend TCP as a user-mode server: a client drove a passive-open handshake (LISTEN/SYN/ACK) over IPC and the connection reached ESTABLISHED (TCPSRV-OK) under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected TCPSRV-OK in kernel output"
exit 1
