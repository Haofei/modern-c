#!/usr/bin/env bash
# Interrupt-backed async virtio-blk completion under REAL OpenSBI in S-mode.
#
# Builds tests/qemu/arch/blk_smode_irq_demo.mc as a flat S-mode kernel. The demo
# submits an async read of sector 0, parks in wfi, takes the virtio-blk S-mode
# PLIC interrupt, reaps the used ring with blk_irq_reap, and drains the completed
# broker id through async_poll_many (the kernel-side SYS_POLL shape).
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
SRC="$HERE/tests/qemu/arch/blk_smode_irq_demo.mc"
CONTEXT="$HERE/tests/qemu/arch/smode_context_runtime.mc"
PLATFORM="$HERE/kernel/arch/riscv64/sbi_dma_time.mc"
LDSCRIPT="$HERE/tests/qemu/sbi.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-blk-smode-irq-test" || echo "blk-smode-irq-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/demo.o" "$WORK"
mkdir -p "$WORK/ctx"
kernel_boot_compile_mc_object "$BACKEND" "$CONTEXT" "$WORK/context.o" "$WORK/ctx"
mkdir -p "$WORK/pf"
kernel_boot_compile_mc_object "$BACKEND" "$PLATFORM" "$WORK/platform.o" "$WORK/pf"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/demo.o" "$WORK/context.o" "$WORK/platform.o" $SUPPORT_OBJ -o "$WORK/blk-smode-irq.elf"

printf 'DISK' >"$WORK/disk.img"; dd if=/dev/zero bs=1 count=508 >>"$WORK/disk.img" 2>/dev/null

OUT="$(timeout 30 "$QEMU" -machine virt -m 256M -nographic \
        -global virtio-mmio.force-legacy=false \
        -drive file="$WORK/disk.img",format=raw,if=none,id=d0 \
        -device virtio-blk-device,drive=d0 \
        -kernel "$WORK/blk-smode-irq.elf" 2>/dev/null || true)"

echo "--- OpenSBI + S-mode async blk IRQ output ---"
printf '%s\n' "$OUT"
echo "---------------------------------------------"

IRQS="$(printf '%s' "$OUT" | sed -n 's/.*BLK-SMODE-IRQ IRQS=\([0-9][0-9]*\).*/\1/p' | tail -n1)"
REAPED="$(printf '%s' "$OUT" | sed -n 's/.*REAPED=\([0-9][0-9]*\).*/\1/p' | tail -n1)"
if printf '%s' "$OUT" | grep -qi "OpenSBI" \
   && printf '%s' "$OUT" | grep -q "BLK-SMODE-IRQ WORD=DISK" \
   && printf '%s' "$OUT" | grep -q "POLL=1" \
   && printf '%s' "$OUT" | grep -q "BLK-SMODE-IRQ-OK" \
   && [ -n "$IRQS" ] && [ "$IRQS" -ge 1 ] \
   && [ -n "$REAPED" ] && [ "$REAPED" -ge 1 ]; then
    echo "PASS: $TEST_NAME — $BACKEND backend async virtio-blk read completed from a REAL S-mode PLIC interrupt under OpenSBI, then drained through async_poll_many/SYS_POLL shape (IRQS=$IRQS REAPED=$REAPED POLL=1, sector word DISK)"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected OpenSBI banner + BLK-SMODE-IRQ WORD=DISK + POLL=1 + BLK-SMODE-IRQ-OK + IRQS/REAPED >= 1"
exit 1
