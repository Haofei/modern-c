#!/usr/bin/env bash
# Build a bootable x86-64 multiboot kernel that, in 64-bit long mode, enumerates the PCI bus via
# the legacy port-I/O CAM mechanism (CONFIG_ADDRESS 0xCF8 / CONFIG_DATA 0xCFC), finds the
# virtio-blk-pci device QEMU attaches (PCI vendor 0x1AF4), and reports its identity (vendor,
# device, class, BAR0) over COM1 — REAL PCI device discovery on x86-64 (the analogue of the
# RISC-V FDT/ECAM discovery). Boots under qemu-system-x86_64 with a virtio-blk-pci device actually
# present on the bus; the harness greps COM1 for the discovered `vendor=1af4` line and `X86-PCI-OK`.
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"; LLD="${LLD:-ld.lld}"; LLC="${LLC:-llc}"; OBJCOPY="${OBJCOPY:-llvm-objcopy}"; QEMU="${QEMU:-qemu-system-x86_64}"
ARCH="$HERE/kernel/arch/x86_64"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-x86-pci-test" || echo "x86-pci-test")
# CI-aware skip: in CI / MC_REQUIRE_TOOLS a missing toolchain FAILS (a gate must not look green
# because qemu/clang/lld were absent); locally it still skips. Same policy as the other x86 gates.
source "$HERE/tools/qemu/kernel-boot-lib.sh"
skip() { kernel_boot_skip "$TEST_NAME" "$1"; }
command -v "$CLANG"   >/dev/null 2>&1 || skip "clang not found"
command -v "$LLD"     >/dev/null 2>&1 || skip "ld.lld not found"
if [ "$BACKEND" = llvm ]; then command -v "$LLC" >/dev/null 2>&1 || skip "llc not found"; fi
command -v "$OBJCOPY" >/dev/null 2>&1 || skip "llvm-objcopy not found"
command -v "$QEMU"    >/dev/null 2>&1 || skip "$QEMU not found"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CF="--target=x86_64-unknown-elf -ffreestanding -fno-pic -fno-pie -mno-red-zone -nostdlib -O1 -Wall -Wextra -Wno-unused-parameter -Wno-unused-function"
case "$BACKEND" in
  c)
    "$MCC" emit-c "$HERE/tests/x86/pci_x86_demo.mc" > "$WORK/pci.c"
    $CLANG $CF -Wno-switch-bool -c "$WORK/pci.c" -o "$WORK/pci.o"
    ;;
  llvm)
    MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/tests/x86/pci_x86_demo.mc" -o "$WORK/pci.o" \
      -mtriple=x86_64-unknown-elf \
      -relocation-model=static \
      -code-model=kernel
    $CLANG $CF -c "$HERE/kernel/arch/riscv64/llvm_kernel_support.c" -o "$WORK/llvm-support.o"
    ;;
  *)
    echo "unknown kernel backend: $BACKEND" >&2
    exit 2
    ;;
esac
$CLANG $CF -c "$ARCH/pci_runtime.c" -o "$WORK/pci_runtime.o"
$CLANG --target=x86_64-unknown-elf -ffreestanding -c "$ARCH/boot.S" -o "$WORK/boot.o"
SUPPORT_OBJ=$([ "$BACKEND" = llvm ] && printf '%s' "$WORK/llvm-support.o" || true)
$LLD -T "$HERE/tests/x86/x86-multiboot.ld" "$WORK/boot.o" "$WORK/pci_runtime.o" "$WORK/pci.o" $SUPPORT_OBJ -o "$WORK/kernel.elf"
$OBJCOPY -O binary "$WORK/kernel.elf" "$WORK/kernel.bin"
# A tiny raw disk with a known first sector, so a virtio-blk-pci device is actually present on the
# PCI bus for the kernel to discover (mirrors the RISC-V blk test's disk image).
printf 'DISK' >"$WORK/disk.img"; dd if=/dev/zero bs=1 count=508 >>"$WORK/disk.img" 2>/dev/null
OUT="$(timeout 30 "$QEMU" -kernel "$WORK/kernel.bin" -nographic -no-reboot \
        -drive id=hd0,file="$WORK/disk.img",format=raw,if=none \
        -device virtio-blk-pci,drive=hd0 \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 2>/dev/null || true)"
echo "--- x86 PCI-discovery kernel serial output ---"; printf '%s\n' "$OUT" | grep -aE "boot OK|IDT|host-bridge|X86-PCI"
echo "----------------------------------------------"
# The proof: real config-space enumeration found the QEMU virtio device (vendor 1af4, not all-ones).
if printf '%s' "$OUT" | grep -qa "X86-PCI-OK" && printf '%s' "$OUT" | grep -qaE "X86-PCI virtio vendor=1af4 device="; then
  VLINE="$(printf '%s' "$OUT" | grep -aoE "X86-PCI virtio vendor=1af4 device=[0-9a-f]+ class=[0-9a-f]+ subclass=[0-9a-f]+ bar0=0x[0-9a-f]+" | tail -1)"
  echo "PASS: $TEST_NAME — $BACKEND backend: x86-64 enumerated PCI bus 0 via legacy CAM port I/O and discovered the QEMU virtio-pci device — $VLINE"
  exit 0
fi
echo "FAIL: $TEST_NAME — expected 'X86-PCI-OK' and a real 'X86-PCI virtio vendor=1af4 device=...' discovery line"; exit 1
