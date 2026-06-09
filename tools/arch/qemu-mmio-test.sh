#!/usr/bin/env bash
# QEMU MMIO execution test (TODO: "Hardware MMIO execution tests").
#
# Lowers a typed-MMIO MC program to C, links it into a bare-metal riscv64 image,
# runs it under qemu-system-riscv64 -machine virt, and checks that the emulated
# 16550 UART actually received the bytes written through the MMIO lowering.
#
# Usage: tools/arch/qemu-mmio-test.sh <path-to-mcc>
# Skips (exit 0) when the riscv toolchain or QEMU is unavailable.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/qemu/arch/uart_mmio.mc"
RUNTIME="$HERE/tests/qemu/runtime.c"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
EXPECT="MMIO-OK"

CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
QEMU="${QEMU:-qemu-system-riscv64}"

skip() { echo "SKIP: qemu-mmio-test ($1)"; exit 0; }
command -v "$CLANG" >/dev/null 2>&1 || skip "clang not found"
command -v "$LLD" >/dev/null 2>&1 || skip "ld.lld not found"
command -v "$QEMU" >/dev/null 2>&1 || skip "$QEMU not found"
"$CLANG" --print-targets 2>/dev/null | grep -q riscv64 || skip "clang has no riscv64 target"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra)

# 1. MC -> C (the typed-MMIO lowering under test).
"$MCC" emit-c "$SRC" >"$WORK/uart.c"

# 2. Compile the lowered MMIO code + the bare-metal runtime, and link at the
#    `virt` RAM base.
"$CLANG" "${CFLAGS[@]}" -c "$WORK/uart.c" -o "$WORK/uart.o"
"$CLANG" "${CFLAGS[@]}" -c "$RUNTIME" -o "$WORK/runtime.o"
"$LLD" -T "$LDSCRIPT" "$WORK/runtime.o" "$WORK/uart.o" -o "$WORK/test.elf"

# 3. Run on emulated hardware and capture the UART output.
OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic -kernel "$WORK/test.elf" 2>/dev/null || true)"

if printf '%s' "$OUT" | grep -q "$EXPECT"; then
    echo "PASS: qemu-mmio-test — UART received '$EXPECT' via typed MMIO"
    exit 0
fi
echo "FAIL: qemu-mmio-test — expected '$EXPECT' in UART output, got:"
printf '%s\n' "$OUT"
exit 1
