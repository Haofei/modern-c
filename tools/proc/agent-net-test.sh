#!/usr/bin/env bash
# Agent-OS NETWORK MODEL showcase under REAL emulation.
#
# Lowers the integrated agent-net demo through the selected backend, links it with the asm
# context-switch runtime into a bare riscv64 image, and runs it under QEMU. Boots the heap +
# console, then runs a sandboxed agent INLINE on the boot thread that reaches the network ONLY
# through the BROKER: it reaches its allowed endpoints (llm N, metrics M), is EGRESS-BLOCKED from a
# disallowed host (Denied D), is network-budget-bounded (Budget B), and the dispatched egresses are
# audited (A). Greps the UART for the 1SNMDBA2 stage trace and AGENT-NET-OK.
#
# Usage: tools/proc/agent-net-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/proc/agent_net_demo.mc"
RUNTIME="$HERE/kernel/arch/riscv64/agent_net_runtime.mc"
SHARED="$HERE/tests/qemu/proc/context_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-agent-net-test" || echo "agent-net-test")

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
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/shared.o" "$WORK/runtime.o" "$WORK/thread.o" $SUPPORT_OBJ -o "$WORK/thread.elf"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/thread.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

if printf '%s' "$OUT" | grep -q "1SNMDBA2" \
   && printf '%s' "$OUT" | grep -q "AGENT-NET-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend booted one integrated agent-OS image (heap+console), then ran a sandboxed agent inline that reached the network only through the broker: reached its allowed endpoints (llm N, metrics M), was egress-Blocked from a disallowed host (Denied D), was network-budget-bounded (Budget B), and the dispatched egresses were audited (A: 1SNMDBA2, AGENT-NET-OK) under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected 1SNMDBA2 and AGENT-NET-OK in kernel output"
exit 1
