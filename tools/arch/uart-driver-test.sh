#!/usr/bin/env bash
# Plan item R6 / first-class UART console driver. Boot our kernel under OpenSBI
# (QEMU default firmware) in S-mode, PRESERVING OpenSBI's a0/a1 (hartid, dtb
# physaddr). The kernel discovers the UART MMIO base FROM THE DEVICE TREE via the
# arch-neutral BootInfo contract (bootinfo_console_pa) — never a hardcoded
# constant — then brings up the first-class NS16550 driver
# (kernel/drivers/uart/ns16550.mc) at that base and emits the proof bytes
# LSR-polled THROUGH the driver. The proof: the discovered base printed and
# "UART-DRIVER-OK" both come out the FDT-discovered, LSR-polled path.
#
# Confirmed against the real OpenSBI-provided DTB (-machine virt):
#   console : serial@10000000  "ns16550a"  base 0x10000000
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"; LLD="${LLD:-ld.lld}"; LLC="${LLC:-llc}"; QEMU="${QEMU:-qemu-system-riscv64}"
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-uart-driver-test" || echo "uart-driver-test")
kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64 -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra)
kernel_boot_compile_mc_object "$BACKEND" "$HERE/tests/qemu/arch/uart_driver_demo.mc" "$WORK/mc.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$HERE/tests/qemu/sbi.ld" "$WORK/freestanding.o" "$WORK/mc.o" $SUPPORT_OBJ -o "$WORK/k.elf"
# NOTE: no '-bios none' -> QEMU loads OpenSBI (the real firmware) which boots our kernel.
OUT="$(timeout 30 "$QEMU" -machine virt -m 256M -nographic -kernel "$WORK/k.elf" 2>/dev/null || true)"
echo "--- OpenSBI + kernel output ---"; printf '%s\n' "$OUT" | tail -16; echo "-------------------------------"
if printf '%s' "$OUT" | grep -qi "OpenSBI" \
   && printf '%s' "$OUT" | grep -q "UART base=0x0000000010000000" \
   && printf '%s' "$OUT" | grep -q "UART-DRIVER-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend booted under OpenSBI in S-mode; discovered the UART base from the device tree (0x10000000), brought up the first-class LSR-polled NS16550 driver, and emitted UART base=0x...10000000 + UART-DRIVER-OK THROUGH that driver"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected OpenSBI banner + UART base=0x...10000000 + UART-DRIVER-OK (FDT-discovered base, LSR-polled driver)"; exit 1
