#!/usr/bin/env bash
# Phase R5b / §3.1 BootInfo: boot our kernel under OpenSBI (QEMU default firmware)
# in S-mode, PRESERVING OpenSBI's a0/a1 (hartid, dtb physaddr). The kernel
# normalizes the firmware device tree into the architecture-neutral BootInfo
# contract (pure MC, kernel/core/bootinfo.mc — the first real consumer of §3.1)
# and prints a structured boot summary. We assert every field against the
# deterministic `-machine virt -m 256M` QEMU virt machine, plus BOOTINFO-OK.
#
# Confirmed against the real OpenSBI-provided DTB (-machine virt,dumpdtb):
#   boot_cpu = 0 (hartid OpenSBI booted us on)
#   /memory  : base 0x80000000, size 0x10000000 (256 MiB)
#   console  : serial@10000000  "ns16550a"                     base 0x10000000
#   PLIC     : plic@c000000     "sifive,plic-1.0.0"/"riscv,plic0" base 0x0c000000
#   virtio   : 8 nodes virtio_mmio@10001000..@10008000; first-in-tree base 0x10008000
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"; LLD="${LLD:-ld.lld}"; LLC="${LLC:-llc}"; QEMU="${QEMU:-qemu-system-riscv64}"
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-bootinfo-test" || echo "bootinfo-test")
kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64 -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra)
kernel_boot_compile_mc_object "$BACKEND" "$HERE/tests/qemu/arch/bootinfo_demo.mc" "$WORK/mc.o" "$WORK"
kernel_boot_compile_c_object "$HERE/kernel/arch/riscv64/bootinfo_runtime.c" "$WORK/boot.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$HERE/tests/qemu/sbi.ld" "$WORK/freestanding.o" "$WORK/boot.o" "$WORK/mc.o" $SUPPORT_OBJ -o "$WORK/k.elf"
# NOTE: no '-bios none' -> QEMU loads OpenSBI (the real firmware) which boots our kernel.
# Deterministic '-m 256M' so the discovered RAM range + device set is exactly asserted.
OUT="$(timeout 30 "$QEMU" -machine virt -m 256M -nographic -kernel "$WORK/k.elf" 2>/dev/null || true)"
echo "--- OpenSBI + kernel output ---"; printf '%s\n' "$OUT" | tail -16; echo "-------------------------------"
if printf '%s' "$OUT" | grep -qi "OpenSBI" \
   && printf '%s' "$OUT" | grep -q "boot_cpu=0" \
   && printf '%s' "$OUT" | grep -q "mem=\[0x0000000080000000,+0x0000000010000000)" \
   && printf '%s' "$OUT" | grep -q "console=0x0000000010000000" \
   && printf '%s' "$OUT" | grep -q "plic=0x000000000c000000" \
   && printf '%s' "$OUT" | grep -q "virtio_mmio=0x0000000010008000 x8" \
   && printf '%s' "$OUT" | grep -q "BOOTINFO-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend booted under OpenSBI in S-mode; normalized firmware into BootInfo: boot_cpu=0, mem=[0x80000000,+0x10000000), console@0x10000000, plic@0x0c000000, virtio first@0x10008000 x8, BOOTINFO-OK"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected OpenSBI banner + boot_cpu=0 + mem=[0x...80000000,+0x...10000000) + console=0x...10000000 + plic=0x...0c000000 + virtio_mmio=0x...10008000 x8 + BOOTINFO-OK"; exit 1
