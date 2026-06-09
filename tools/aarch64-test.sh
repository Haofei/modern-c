#!/usr/bin/env bash
# Second-architecture gate: an MC computation compiled for aarch64 + a minimal ARM64
# boot runtime, booted on qemu-system-aarch64 'virt'. Proves portability beyond riscv64.
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"; HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"; LLD="${LLD:-ld.lld}"; QEMU="${QEMU:-qemu-system-aarch64}"
skip(){ echo "SKIP: aarch64-test ($1)"; exit 0; }
command -v "$CLANG" >/dev/null 2>&1 || skip "no clang"
command -v "$LLD" >/dev/null 2>&1 || skip "no ld.lld"
command -v "$QEMU" >/dev/null 2>&1 || skip "no qemu-system-aarch64"
"$CLANG" --print-targets 2>/dev/null | grep -q aarch64 || skip "clang has no aarch64 target"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CFLAGS=(--target=aarch64-unknown-elf -ffreestanding -nostdlib -fno-pic -mgeneral-regs-only -O1 -Wall -Wextra)
"$MCC" emit-c "$HERE/tests/qemu/arch/arch_demo.mc" >"$WORK/c.c"
"$CLANG" "${CFLAGS[@]}" -c "$WORK/c.c" -o "$WORK/c.o"
"$CLANG" "${CFLAGS[@]}" -c "$HERE/kernel/arch/aarch64/boot_runtime.c" -o "$WORK/boot.o"
"$LLD" -T "$HERE/tests/qemu/aarch64.ld" "$WORK/boot.o" "$WORK/c.o" -o "$WORK/k.elf"
OUT="$(timeout 30 "$QEMU" -machine virt -cpu cortex-a53 -nographic -kernel "$WORK/k.elf" 2>/dev/null || true)"
echo "--- aarch64 UART ---"; printf '%s\n' "$OUT"; echo "--------------------"
if printf '%s' "$OUT" | grep -q "ARM64-OK"; then
    echo "PASS: aarch64-test — MC code compiled + booted on a second architecture (aarch64 QEMU virt): arch_compute ran (ARM64-OK)"
    exit 0
fi
echo "FAIL: aarch64-test — expected ARM64-OK"; exit 1
