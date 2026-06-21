#!/usr/bin/env bash
# Build a bootable x86-64 multiboot kernel that, in 64-bit long mode, builds a FRESH 4-level
# page table (kernel/arch/x86_64/paging.mc), software-walks it, loads it into CR3, and reads a
# translation-only test VA back — proving real virtual->physical translation. Boots under
# qemu-system-x86_64; reports over COM1; the harness greps for X86-VM-OK.
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"; LLD="${LLD:-ld.lld}"; LLC="${LLC:-llc}"; OBJCOPY="${OBJCOPY:-llvm-objcopy}"; QEMU="${QEMU:-qemu-system-x86_64}"
ARCH="$HERE/kernel/arch/x86_64"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-x86-vm-test" || echo "x86-vm-test")
skip() { echo "SKIP: $TEST_NAME ($1)"; exit 0; }
command -v "$CLANG"   >/dev/null 2>&1 || skip "clang not found"
command -v "$LLD"     >/dev/null 2>&1 || skip "ld.lld not found"
if [ "$BACKEND" = llvm ]; then command -v "$LLC" >/dev/null 2>&1 || skip "llc not found"; fi
command -v "$OBJCOPY" >/dev/null 2>&1 || skip "llvm-objcopy not found"
command -v "$QEMU"    >/dev/null 2>&1 || skip "$QEMU not found"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CF="--target=x86_64-unknown-elf -ffreestanding -fno-pic -fno-pie -mno-red-zone -nostdlib -O1 -Wall -Wextra -Wno-unused-parameter -Wno-unused-function"
case "$BACKEND" in
  c)
    "$MCC" emit-c "$HERE/tests/x86/vm_x86_demo.mc" > "$WORK/vm.c"
    $CLANG $CF -Wno-switch-bool -c "$WORK/vm.c" -o "$WORK/vm.o"
    ;;
  llvm)
    MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/tests/x86/vm_x86_demo.mc" -o "$WORK/vm.o" \
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
$CLANG $CF -c "$ARCH/vm_runtime.c" -o "$WORK/vm_runtime.o"
$CLANG --target=x86_64-unknown-elf -ffreestanding -c "$ARCH/boot.S" -o "$WORK/boot.o"
SUPPORT_OBJ=$([ "$BACKEND" = llvm ] && printf '%s' "$WORK/llvm-support.o" || true)
$LLD -T "$HERE/tests/x86/x86-multiboot.ld" "$WORK/boot.o" "$WORK/vm_runtime.o" "$WORK/vm.o" $SUPPORT_OBJ -o "$WORK/kernel.elf"
$OBJCOPY -O binary "$WORK/kernel.elf" "$WORK/kernel.bin"
OUT="$(timeout 30 "$QEMU" -kernel "$WORK/kernel.bin" -nographic -no-reboot \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 2>/dev/null || true)"
echo "--- x86 VM kernel serial output ---"; printf '%s\n' "$OUT" | grep -aE "boot OK|IDT|table built|CR3|readback|X86-VM"
echo "-----------------------------------"
if printf '%s' "$OUT" | grep -qa "X86-VM-OK"; then
  echo "PASS: $TEST_NAME — $BACKEND backend: x86-64 builds a fresh 4-level page table, software-walks it, loads CR3, and reads a translation-only VA back (real VA->PA translation)"
  exit 0
fi
echo "FAIL: $TEST_NAME — expected 'X86-VM-OK' in serial output"; exit 1
