#!/usr/bin/env bash
# F1 fault-isolation containment under REAL emulation.
#
# Lowers the integrated fault-isolation demo through the selected backend, links it with the asm
# context-switch runtime into a bare riscv64 image, and runs it under QEMU. Boots the heap +
# console, installs a REAL M-mode trap vector, spawns three sandboxed agents (A, B, C), then has
# agent C trigger a GENUINE illegal-instruction trap. The trap handler CONTAINS it — classifies
# the fault to agent C's domain, kills+reclaims C through the process death path, advances past
# the faulting instruction, and resumes the kernel — so A and B keep running and the machine does
# NOT halt. Greps the UART for the staged progress (1ABCD2) and FAULT-ISOLATION-OK.
#
# Usage: tools/proc/fault-isolation-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/proc/fault_isolation_demo.mc"
RUNTIME="$HERE/tests/qemu/proc/fault_isolation_runtime.mc"
SHARED="$HERE/tests/qemu/proc/context_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-fault-isolation-test" || echo "fault-isolation-test")

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
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/shared.o" "$WORK/runtime.o" "$WORK/thread.o" $SUPPORT_OBJ -o "$WORK/thread.elf"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/thread.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

if printf '%s' "$OUT" | grep -q "1ABCD2" \
   && printf '%s' "$OUT" | grep -q "FAULT-ISOLATION-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend booted one integrated image (heap+console), installed a real M-mode trap vector, and a sandboxed agent took a GENUINE illegal-instruction trap that the kernel CONTAINED (faulting agent killed+reclaimed, A,B survive, kernel did not halt: 1ABCD2, FAULT-ISOLATION-OK) under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected 1ABCD2 and FAULT-ISOLATION-OK in kernel output"
exit 1
