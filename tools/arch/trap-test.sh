#!/usr/bin/env bash
# Runnable trap/timer test (the typed CPU's interrupt path).
#
# Lowers the MC trap handler + hart typestate to C, links it with the asm trap
# vector runtime into a bare-metal riscv64 image, and runs it under QEMU. The
# typed kernel installs the trap vector through the hart typestate, enables
# interrupts, and counts CLINT timer ticks — proving the trap actually fires.
#
# Usage: tools/arch/trap-test.sh <path-to-mcc>
# Skips (exit 0) when the riscv toolchain or QEMU is unavailable.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/kernel/arch/riscv64/trap.mc"
RUNTIME="$HERE/kernel/arch/riscv64/trap_runtime.c"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
EXPECT="TIMER-OK"

CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
QEMU="${QEMU:-qemu-system-riscv64}"

skip() { echo "SKIP: trap-test ($1)"; exit 0; }
command -v "$CLANG" >/dev/null 2>&1 || skip "clang not found"
command -v "$LLD" >/dev/null 2>&1 || skip "ld.lld not found"
command -v "$QEMU" >/dev/null 2>&1 || skip "$QEMU not found"
"$CLANG" --print-targets 2>/dev/null | grep -q riscv64 || skip "clang has no riscv64 target"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function)

"$MCC" emit-c "$SRC" >"$WORK/trap.c"
"$CLANG" "${CFLAGS[@]}" -c "$WORK/trap.c" -o "$WORK/trap.o"
"$CLANG" "${CFLAGS[@]}" -c "$RUNTIME" -o "$WORK/runtime.o"
"$LLD" -T "$LDSCRIPT" "$WORK/runtime.o" "$WORK/trap.o" -o "$WORK/trap.elf"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/trap.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

# The timer path must work, and the unexpected M-mode ecall (mcause 0xb) must hit
# the fail-closed panic path with diagnostics rather than silently resuming.
if printf '%s' "$OUT" | grep -q "$EXPECT" \
   && printf '%s' "$OUT" | grep -q "PANIC c=0x000000000000000b"; then
    echo "PASS: trap-test — timer ticks counted, and an unexpected trap fails closed via panic diagnostics under QEMU"
    exit 0
fi
echo "FAIL: trap-test — expected '$EXPECT' and a PANIC diagnostic in kernel output"
exit 1
