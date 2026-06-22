#!/usr/bin/env bash
# Step-0 confined-agent test: load a separate ELF into an ISOLATED Sv39 address
# space and run it in U-mode with the kernel UNMAPPED — so the agent reaches the
# kernel only via syscalls, never by touching kernel memory directly.
#
# Lowers the confined-agent demo through the selected backend, links it with the
# asm user-mode runtime + the confined bring-up into a bare riscv64 image, and
# runs it under QEMU.
#
# Usage: tools/proc/agent-confined-tool-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/proc/agent_confined_tool_demo.mc"
RUNTIME="$HERE/kernel/arch/riscv64/agent_confined_tool_runtime.mc"
SHARED="$HERE/kernel/arch/riscv64/context_runtime.c"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-agent-confined-tool-test" || echo "agent-confined-tool-test")

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
kernel_boot_compile_c_object "$HERE/tests/qemu/proc/usermode_runtime.mc" "$WORK/usermode.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/shared.o" "$WORK/usermode.o" "$WORK/runtime.o" "$WORK/thread.o" $SUPPORT_OBJ -o "$WORK/thread.elf"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/thread.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

# PASS requires ALL of:
#   - the kernel verified the agent's space does not map the kernel (CONFINED);
#   - the agent's code page is user-only (CONFINED);
#   - the agent actually ran: it printed its marker "42" — and it could only do
#     so by executing at a VA that is valid ONLY through its isolated page table,
#     so the marker is itself proof the satp activated and the agent ran confined;
#   - it exited from U-mode (proving it ran unprivileged, reaching the kernel only
#     via ecall/syscall).
if printf '%s' "$OUT" | grep -q "CONFINED: kernel unmapped in agent space" \
   && printf '%s' "$OUT" | grep -q ">A<" \
   && printf '%s' "$OUT" | grep -q ">D<" \
   && printf '%s' "$OUT" | grep -q "USER-EXIT from U"; then
    echo "PASS: $TEST_NAME — $BACKEND backend: a confined U-mode agent (kernel unmapped) drove the capability tool front door via syscalls; its /workspace write was ALLOWED (>A<) and its /etc write DENIED (>D<), then it exited from U"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected CONFINED, an allowed (>A<) and a denied (>D<) tool verdict, and 'USER-EXIT from U'"
exit 1
