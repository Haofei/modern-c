#!/usr/bin/env bash
# Real boot path: boot our kernel under OpenSBI (QEMU default firmware, the bootloader
# used on real RISC-V hardware) in S-mode, talking to console/power via SBI ecalls.
set -euo pipefail
MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"; LLD="${LLD:-ld.lld}"; LLC="${LLC:-llc}"; QEMU="${QEMU:-qemu-system-riscv64}"
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-sbi-boot-test" || echo "sbi-boot-test")
kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64 -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra)
# PURE-MC kernel: `_start` is `#[naked]` MC, the SBI console/shutdown seam is MC
# inline asm (sbi.mc), and arch_compute is MC — no .c runtime.
kernel_boot_compile_mc_object "$BACKEND" "$HERE/tests/qemu/arch/sbi_boot_demo.mc" "$WORK/mc.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$HERE/tests/qemu/sbi.ld" "$WORK/freestanding.o" "$WORK/mc.o" $SUPPORT_OBJ -o "$WORK/k.elf"
# NOTE: no '-bios none' -> QEMU loads OpenSBI (the real firmware) which boots our kernel.
OUT="$(timeout 30 "$QEMU" -machine virt -nographic -kernel "$WORK/k.elf" 2>/dev/null || true)"
echo "--- OpenSBI + kernel output ---"; printf '%s\n' "$OUT" | tail -8; echo "-------------------------------"
if printf '%s' "$OUT" | grep -q "SBI-BOOT-OK" && printf '%s' "$OUT" | grep -qi "OpenSBI"; then
    echo "PASS: $TEST_NAME — $BACKEND backend booted under OpenSBI (real RISC-V firmware) in S-mode; kernel ran + used SBI console/shutdown (SBI-BOOT-OK)"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected OpenSBI banner + SBI-BOOT-OK"; exit 1
