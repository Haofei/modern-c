#!/usr/bin/env bash
# Runnable M-mode trap/timer test (the typed CPU's interrupt path), in PURE MC.
#
# Builds the flat bare-metal M-mode kernel — now PURE MC (no .c runtime, no boot.S:
# `_start` and the M-mode trap vector are `#[naked]` MC, and the CSR/CLINT/UART seam
# plus the mc_halt/mc_read_ticks/mc_udelay platform primitives are MC inline asm +
# raw MMIO) — through the selected backend, links it into a bare-metal riscv64 image,
# and runs it under QEMU with `-bios none` (no firmware: QEMU jumps straight to
# 0x80000000 in M-mode). The typed kernel installs the M-mode trap vector through the
# hart typestate, enables M-timer interrupts (mie.MTIE + mstatus.MIE), programs the
# CLINT mtimecmp, and counts timer ticks — then a deliberate M-mode `ecall` (mcause
# 0xb) hits the fail-closed panic path with diagnostics rather than silently mret-ing.
#
# Usage: tools/arch/trap-test.sh <path-to-mcc> [c|llvm]
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
# The flat M-mode timer kernel is now PURE MC — no .c runtime, no boot.S: `_start`
# and the M-mode trap vector are `#[naked]` MC functions, and the CSR/CLINT/UART seam
# is MC inline asm + raw MMIO.
RUNTIME="$HERE/tests/qemu/arch/mmode_timer_demo.mc"
# The platform primitives (mc_halt/mc_read_ticks/mc_udelay) DEFINE the symbols
# panic.mc/std/time.mc declare `extern fn`, so they live in their OWN MC unit
# (which imports neither) and are linked in as a second object — the all-MC
# replacement for the old trap_runtime.c.
PLATFORM="$HERE/tests/qemu/arch/mmode_platform.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
EXPECT="TIMER-OK"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-trap-test" || echo "trap-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

# Compile the PURE-MC kernel on the selected backend (c: emit-c -> clang; llvm:
# emit-llvm -> llc). The LLVM object references the safety-check trap symbols
# (mc_trap_*) that llvm_kernel_support.c provides; the C object inlines them.
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK"
kernel_boot_compile_mc_object "$BACKEND" "$PLATFORM" "$WORK/platform.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/runtime.o" "$WORK/platform.o" $SUPPORT_OBJ -o "$WORK/trap.elf"

# `-bios none` -> no firmware: QEMU jumps straight to 0x80000000 in M-mode, where
# our `_start` lives.
OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/trap.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

# The timer path must work, and the unexpected M-mode ecall (mcause 0xb) must hit
# the fail-closed panic path with diagnostics rather than silently resuming.
if printf '%s' "$OUT" | grep -q "$EXPECT" \
   && printf '%s' "$OUT" | grep -q "PANIC c=0x000000000000000b"; then
    echo "PASS: $TEST_NAME — $BACKEND backend timer ticks counted, and an unexpected trap fails closed via panic diagnostics under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected '$EXPECT' and a PANIC diagnostic in kernel output"
exit 1