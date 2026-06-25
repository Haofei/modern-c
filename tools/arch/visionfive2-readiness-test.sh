#!/usr/bin/env bash
# VisionFive 2 readiness surrogate: boot under OpenSBI on QEMU `virt`, preserve
# firmware a0/a1, normalize the DTB through BootInfo, and check the selected
# board profile's FDT-driven resource contract. This is surrogate evidence only:
# it is not a hardware boot claim for VisionFive 2.
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"; LLD="${LLD:-ld.lld}"; LLC="${LLC:-llc}"; QEMU="${QEMU:-qemu-system-riscv64}"
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-visionfive2-readiness-test" || echo "visionfive2-readiness-test")
kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64 -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra)
kernel_boot_compile_mc_object "$BACKEND" "$HERE/tests/qemu/arch/visionfive2_readiness_demo.mc" "$WORK/mc.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$HERE/tests/qemu/sbi.ld" "$WORK/freestanding.o" "$WORK/mc.o" $SUPPORT_OBJ -o "$WORK/k.elf"
OUT="$(timeout 30 "$QEMU" -machine virt -m 256M -nographic -kernel "$WORK/k.elf" 2>/dev/null || true)"
echo "--- OpenSBI + kernel output ---"; printf '%s\n' "$OUT" | tail -14; echo "-------------------------------"
if printf '%s' "$OUT" | grep -qi "OpenSBI" \
   && printf '%s' "$OUT" | grep -q "vf2_boot_cpu=0" \
   && printf '%s' "$OUT" | grep -q "vf2_fdt=0x" \
   && printf '%s' "$OUT" | grep -q "vf2_console=0x0000000010000000" \
   && printf '%s' "$OUT" | grep -q "vf2_plic=0x000000000c000000" \
   && printf '%s' "$OUT" | grep -q "vf2_virtio_mmio_count=8" \
   && printf '%s' "$OUT" | grep -q "VF2-QEMU-SURROGATE-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend validated the VisionFive 2 FDT-resource readiness adapter against the QEMU/OpenSBI surrogate"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected OpenSBI banner + VisionFive 2 surrogate resource summary + VF2-QEMU-SURROGATE-OK"; exit 1
