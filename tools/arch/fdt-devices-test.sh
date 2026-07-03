#!/usr/bin/env bash
# Phase R5 device discovery: boot our kernel under OpenSBI (QEMU default firmware)
# in S-mode, PRESERVING OpenSBI's a0/a1 (hartid, dtb physaddr). The kernel walks
# the device tree by `compatible` string (pure MC, kernel/core/fdt.mc) for the
# UART, the PLIC, and the virtio-mmio devices, decoding each `reg` with the
# parent node's #address-cells/#size-cells, and reports their bases + the
# virtio-mmio count. We assert all of them against the deterministic
# `-machine virt -m 256M` QEMU virt machine.
#
# Confirmed against the real OpenSBI-provided DTB (-machine virt,dumpdtb):
#   UART  : node serial@10000000, compatible "ns16550a",            base 0x10000000
#   PLIC  : node plic@c000000,    compatible "sifive,plic-1.0.0"/"riscv,plic0", base 0x0c000000
#   virtio: 8 nodes virtio_mmio@10001000..@10008000 (stride 0x1000). NOTE: QEMU
#           emits them in DESCENDING address order in the structure block, so the
#           FIRST node in tree order (what fdt_first_virtio_mmio returns) is
#           @10008000, not @10001000 — verified via dumpdtb structure-block walk.
# All three device classes live under /soc (depth 3), whose #address-cells /
# #size-cells are 2/2 — read via the depth-indexed cell stack in fdt.mc.
set -euo pipefail
MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"; LLD="${LLD:-ld.lld}"; LLC="${LLC:-llc}"; QEMU="${QEMU:-qemu-system-riscv64}"
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-fdt-devices-test" || echo "fdt-devices-test")
kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64 -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra)
# PURE-MC kernel: `_start` is `#[naked]` MC and every accessor is MC — no .c runtime.
kernel_boot_compile_mc_object "$BACKEND" "$HERE/tests/qemu/arch/fdt_devices_demo.mc" "$WORK/mc.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$HERE/tests/qemu/sbi.ld" "$WORK/freestanding.o" "$WORK/mc.o" $SUPPORT_OBJ -o "$WORK/k.elf"
# NOTE: no '-bios none' -> QEMU loads OpenSBI (the real firmware) which boots our kernel.
# Deterministic '-m 256M' so the discovered device set is exactly the asserted one.
OUT="$(timeout 30 "$QEMU" -machine virt -m 256M -nographic -kernel "$WORK/k.elf" 2>/dev/null || true)"
echo "--- OpenSBI + kernel output ---"; printf '%s\n' "$OUT" | tail -14; echo "-------------------------------"
if printf '%s' "$OUT" | grep -qi "OpenSBI" \
   && printf '%s' "$OUT" | grep -q "hart=0" \
   && printf '%s' "$OUT" | grep -q "uart=0x0000000010000000" \
   && printf '%s' "$OUT" | grep -q "plic=0x000000000c000000" \
   && printf '%s' "$OUT" | grep -q "virtio_mmio_first=0x0000000010008000" \
   && printf '%s' "$OUT" | grep -q "virtio_mmio_count=8" \
   && printf '%s' "$OUT" | grep -q "FDT-DEV-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend booted under OpenSBI in S-mode; discovered UART@0x10000000, PLIC@0x0c000000, virtio-mmio first-in-tree@0x10008000 (count=8), FDT-DEV-OK"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected OpenSBI banner + hart=0 + uart=0x...10000000 + plic=0x...0c000000 + virtio_mmio_first=0x...10008000 + virtio_mmio_count=8 + FDT-DEV-OK"; exit 1
