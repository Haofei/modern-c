#!/usr/bin/env bash
# Agent-OS governance keystone under REAL emulation.
#
# Lowers the integrated agent-OS demo through the selected backend, links it with the
# asm context-switch runtime into a bare riscv64 image, and runs it under QEMU. Boots the
# heap + console, then runs the OOM-kill / reclaim keystone inline (a live runaway agent is
# OOM-killed and reclaimed while the others survive) and greps the UART for AGENTOS-OK.
#
# Usage: tools/proc/agentos-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/proc/agentos_demo.mc"
RUNTIME="$HERE/kernel/arch/riscv64/agentos_runtime.c"
SHARED="$HERE/kernel/arch/riscv64/context_runtime.c"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-agentos-test" || echo "agentos-test")

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

if printf '%s' "$OUT" | grep -q "1ABC2" \
   && printf '%s' "$OUT" | grep -q "AGENTOS-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend booted one integrated agent-OS image (heap+console), then ran the governance keystone (a live runaway OOM-killed + reclaimed while A,B survive: 1ABC2, AGENTOS-OK) under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected 1ABC2 and AGENTOS-OK in kernel output"
exit 1
