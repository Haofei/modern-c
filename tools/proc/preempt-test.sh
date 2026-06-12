#!/usr/bin/env bash
# Runnable preemptive scheduler test.
#
# Lowers the preemptive scheduler demo through the selected backend, links it
# with the trap/context runtime into a bare riscv64 image, and runs it under QEMU.
#
# Usage: tools/proc/preempt-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/proc/preempt_demo.mc"
RUNTIME="$HERE/kernel/arch/riscv64/preempt_runtime.c"
SHARED="$HERE/kernel/arch/riscv64/context_runtime.c"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-preempt-test" || echo "preempt-test")

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

# Each non-yielding worker prints its letter once when the timer first preempts
# into it, so all of A, B, C appearing proves preemption reached every thread, and
# PREEMPT-OK proves the bootstrap regained control and the run completed.
if printf '%s' "$OUT" | grep -q "A" \
   && printf '%s' "$OUT" | grep -q "B" \
   && printf '%s' "$OUT" | grep -q "C" \
   && printf '%s' "$OUT" | grep -q "PREEMPT-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend timer preemption rotated 3 non-yielding threads (A,B,C all ran) under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected A, B, C and PREEMPT-OK in kernel output"
exit 1
