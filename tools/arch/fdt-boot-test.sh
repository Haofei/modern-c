#!/usr/bin/env bash
# Real boot path + FDT discovery: boot our kernel under OpenSBI (QEMU default firmware)
# in S-mode, PRESERVING OpenSBI's a0/a1 (hartid, dtb physaddr). The kernel prints the
# hart id and dtb pointer, then walks the device tree's /memory node (pure MC, in
# kernel/core/fdt.mc) and reports the RAM base/size. We assert all four against the
# deterministic `-m 256M` QEMU virt machine.
#
# QEMU virt with `-m 256M` reports a single /memory node: reg = <0x0 0x80000000  0x0
# 0x10000000>, i.e. base = 0x0000000080000000 (RAM base), size = 0x10000000 (256 MiB).
# These are the values asserted below (confirmed against the real OpenSBI-provided DTB).
set -euo pipefail
MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"; LLD="${LLD:-ld.lld}"; LLC="${LLC:-llc}"; QEMU="${QEMU:-qemu-system-riscv64}"
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-fdt-boot-test" || echo "fdt-boot-test")
kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64 -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra)
# PURE-MC kernel: `_start` is `#[naked]` MC and every accessor is MC — no .c runtime.
kernel_boot_compile_mc_object "$BACKEND" "$HERE/tests/qemu/arch/fdt_boot_demo.mc" "$WORK/mc.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$HERE/tests/qemu/sbi.ld" "$WORK/freestanding.o" "$WORK/mc.o" $SUPPORT_OBJ -o "$WORK/k.elf"
# NOTE: no '-bios none' -> QEMU loads OpenSBI (the real firmware) which boots our kernel.
# Deterministic '-m 256M' so the expected /memory size (0x10000000) is exact.
OUT="$(timeout 30 "$QEMU" -machine virt -m 256M -nographic -kernel "$WORK/k.elf" 2>/dev/null || true)"
echo "--- OpenSBI + kernel output ---"; printf '%s\n' "$OUT" | tail -12; echo "-------------------------------"
if printf '%s' "$OUT" | grep -qi "OpenSBI" \
   && printf '%s' "$OUT" | grep -q "hart=0" \
   && printf '%s' "$OUT" | grep -q "mem_base=0x0000000080000000" \
   && printf '%s' "$OUT" | grep -q "mem_size=0x0000000010000000" \
   && printf '%s' "$OUT" | grep -q "FDT-BOOT-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend booted under OpenSBI (real RISC-V firmware) in S-mode; preserved a0/a1 (hart=0), parsed DTB /memory (base=0x80000000 size=0x10000000), FDT-BOOT-OK"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected OpenSBI banner + hart=0 + mem_base=0x0000000080000000 + mem_size=0x0000000010000000 + FDT-BOOT-OK"; exit 1
