#!/usr/bin/env bash
# End-to-end agent-on-OS showcase under REAL emulation.
#
# Lowers the integrated e2e agent demo through the selected backend, links it with the asm
# context-switch runtime into a bare riscv64 image, and runs it under QEMU. Boots the heap +
# console, then runs a sandboxed agent INLINE on the boot thread: the agent makes
# capability-checked, budget-bounded, AUDITED tool calls — an allowed tool dispatches (L,P),
# a forbidden tool is Denied (D), the call budget is Exhausted (X), and the audit transcript is
# exactly the dispatched calls (A). Greps the UART for the 1SLPDLPXA2 stage trace and AGENT-E2E-OK.
#
# Usage: tools/proc/agent-e2e-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/proc/agent_e2e_demo.mc"
RUNTIME="$HERE/kernel/arch/riscv64/agent_e2e_runtime.mc"
SHARED="$HERE/kernel/arch/riscv64/context_runtime.c"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-agent-e2e-test" || echo "agent-e2e-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

mkdir -p "$WORK/rt"
kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/thread.o" "$WORK"
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

if printf '%s' "$OUT" | grep -q "1SLPDLPXA2" \
   && printf '%s' "$OUT" | grep -q "AGENT-E2E-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend booted one integrated agent-OS image (heap+console), then ran a sandboxed agent inline that made capability-checked/budgeted/audited tool calls (allowed dispatch L,P; forbidden Denied D; budget Exhausted X; audit correct A: 1SLPDLPXA2, AGENT-E2E-OK) under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected 1SLPDLPXA2 and AGENT-E2E-OK in kernel output"
exit 1
