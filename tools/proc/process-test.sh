#!/usr/bin/env bash
# Runnable kernel-thread test (round-robin scheduler (3 threads, heap stacks).
#
# Lowers the process lifecycle demo through the selected backend, links it with
# the asm context-switch runtime into a bare riscv64 image, and runs it under QEMU.
#
# Usage: tools/proc/process-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/proc/process_demo.mc"
RUNTIME="$HERE/kernel/arch/riscv64/process_runtime.c"
SHARED="$HERE/kernel/arch/riscv64/context_runtime.c"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-process-test" || echo "process-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/thread.o" "$WORK"
kernel_boot_compile_c_object "$RUNTIME" "$WORK/runtime.o"
kernel_boot_compile_c_object "$SHARED" "$WORK/shared.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
"$LLD" -T "$LDSCRIPT" "$WORK/shared.o" "$WORK/runtime.o" "$WORK/thread.o" $SUPPORT_OBJ -o "$WORK/thread.elf"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/thread.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

# main/worker must interleave (MWMWMW) and the demo must return cleanly.
if printf '%s' "$OUT" | grep -q "ABC123" \
   && printf '%s' "$OUT" | grep -q "PROC-OK 3"; then
    echo "PASS: $TEST_NAME — $BACKEND backend 3 processes ran + exited with codes (ABC), the bootstrap blocking-waited (proc_wait) + reaped all three (123, PROC-OK 3) under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected ABC123 and PROC-OK 3 in kernel output"
exit 1
