#!/usr/bin/env bash
# Real boot path: boot our kernel under OpenSBI (QEMU default firmware, the bootloader
# used on real RISC-V hardware) in S-mode, talking to console/power via SBI ecalls.
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"; HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"; LLD="${LLD:-ld.lld}"; QEMU="${QEMU:-qemu-system-riscv64}"
skip(){ echo "SKIP: sbi-boot-test ($1)"; exit 0; }
command -v "$CLANG" >/dev/null 2>&1 || skip "no clang"
command -v "$LLD" >/dev/null 2>&1 || skip "no ld.lld"
command -v "$QEMU" >/dev/null 2>&1 || skip "no qemu"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64 -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra)
"$MCC" emit-c "$HERE/tests/qemu/arch/arch_demo.mc" >"$WORK/c.c"
"$CLANG" "${CFLAGS[@]}" -c "$WORK/c.c" -o "$WORK/c.o"
"$CLANG" "${CFLAGS[@]}" -c "$HERE/kernel/arch/riscv64/sbi_boot_runtime.c" -o "$WORK/boot.o"
"$LLD" -T "$HERE/tests/qemu/sbi.ld" "$WORK/boot.o" "$WORK/c.o" -o "$WORK/k.elf"
# NOTE: no '-bios none' -> QEMU loads OpenSBI (the real firmware) which boots our kernel.
OUT="$(timeout 30 "$QEMU" -machine virt -nographic -kernel "$WORK/k.elf" 2>/dev/null || true)"
echo "--- OpenSBI + kernel output ---"; printf '%s\n' "$OUT" | tail -8; echo "-------------------------------"
if printf '%s' "$OUT" | grep -q "SBI-BOOT-OK" && printf '%s' "$OUT" | grep -qi "OpenSBI"; then
    echo "PASS: sbi-boot-test — booted under OpenSBI (real RISC-V firmware) in S-mode; kernel ran + used SBI console/shutdown (SBI-BOOT-OK)"
    exit 0
fi
echo "FAIL: sbi-boot-test — expected OpenSBI banner + SBI-BOOT-OK"; exit 1
