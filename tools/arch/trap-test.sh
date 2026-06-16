#!/usr/bin/env bash
# Runnable trap/timer test (the typed CPU's interrupt path).
#
# Lowers the MC trap handler + hart typestate through the selected backend, links
# it with the asm trap vector runtime into a bare-metal riscv64 image, and runs it
# under QEMU. The typed kernel installs the trap vector through the hart typestate,
# enables interrupts, and counts CLINT timer ticks.
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
SRC="$HERE/kernel/arch/riscv64/trap.mc"
RUNTIME="$HERE/kernel/arch/riscv64/trap_runtime.c"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
EXPECT="TIMER-OK"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-trap-test" || echo "trap-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/trap.o" "$WORK"
kernel_boot_compile_c_object "$RUNTIME" "$WORK/runtime.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/runtime.o" "$WORK/trap.o" $SUPPORT_OBJ -o "$WORK/trap.elf"

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
