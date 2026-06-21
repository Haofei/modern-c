#!/usr/bin/env bash
# Runnable kernel-thread test (round-robin scheduler (3 threads, heap stacks).
#
# Lowers the integrated kernel demo through the selected backend, links it with
# the asm context-switch runtime into a bare riscv64 image, and runs it under QEMU.
#
# Usage: tools/proc/kmain-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/proc/kmain_demo.mc"
# The boot entry is now PURE MC (no .c): it owns the 256 KiB heap region, calls
# kmain, and reports the stage bitmask. The context-switch primitives, `_start`, and
# `mc_halt` still come from the shared C bring-up runtime, linked beside it.
RUNTIME="$HERE/tests/qemu/proc/kmain_runtime.mc"
SHARED="$HERE/kernel/arch/riscv64/context_runtime.c"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-kmain-test" || echo "kmain-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin
        # UB-defining defensive flags for the kernel-image cc path (S0.3; see
        # docs/c-ub-matrix.md). -ffreestanding/-fno-builtin are already here; add the
        # aliasing + null-check + signed-wrap hardening so the emitted MC C (and the C
        # runtime it links with) inherit the same UB-defining contract as the host path.
        -fno-strict-aliasing -fno-delete-null-pointer-checks -fwrapv)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/thread.o" "$WORK"
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK"
kernel_boot_compile_c_object "$SHARED" "$WORK/shared.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/shared.o" "$WORK/runtime.o" "$WORK/thread.o" $SUPPORT_OBJ -o "$WORK/thread.elf"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/thread.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

if printf '%s' "$OUT" | grep -q "123AB45" \
   && printf '%s' "$OUT" | grep -q "KERNEL-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend booted one integrated kernel image with heap+console+logger+VFS+scheduler, then ran a session-pool+arena workload (123AB45, KERNEL-OK) under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected 123AB45 and KERNEL-OK in kernel output"
exit 1
