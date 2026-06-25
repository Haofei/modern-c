#!/usr/bin/env bash
# Interrupt-backed async virtio-net TX completion under REAL OpenSBI in S-mode.
#
# Builds tests/qemu/arch/net_smode_irq_demo.mc as a flat S-mode kernel. The demo
# submits an async TX frame, parks in wfi, takes the virtio-net S-mode PLIC
# interrupt, reaps the TX used ring with net_irq_reap, and drains the completed
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
SRC="$HERE/tests/qemu/arch/net_smode_irq_demo.mc"
CONTEXT="$HERE/tests/qemu/arch/smode_context_runtime.mc"
PLATFORM="$HERE/kernel/arch/riscv64/sbi_dma_time.mc"
LDSCRIPT="$HERE/tests/qemu/sbi.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-net-smode-irq-test" || echo "net-smode-irq-test")

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
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/demo.o" "$WORK/context.o" "$WORK/platform.o" $SUPPORT_OBJ -o "$WORK/net-smode-irq.elf"

OUT="$(timeout 30 "$QEMU" -machine virt -m 256M -nographic \
        -global virtio-mmio.force-legacy=false \
        -netdev user,id=n0 \
        -device virtio-net-device,netdev=n0 \
        -kernel "$WORK/net-smode-irq.elf" 2>/dev/null || true)"

echo "--- OpenSBI + S-mode async net IRQ output ---"
printf '%s\n' "$OUT"
echo "---------------------------------------------"

IRQS="$(printf '%s' "$OUT" | sed -n 's/.*NET-SMODE-IRQ RESULT=[0-9][0-9]* IRQS=\([0-9][0-9]*\).*/\1/p' | tail -n1)"
REAPED="$(printf '%s' "$OUT" | sed -n 's/.*REAPED=\([0-9][0-9]*\).*/\1/p' | tail -n1)"
if printf '%s' "$OUT" | grep -qi "OpenSBI" \
   && printf '%s' "$OUT" | grep -q "NET-SMODE-IRQ RESULT=1" \
   && printf '%s' "$OUT" | grep -q "POLL=1" \
   && printf '%s' "$OUT" | grep -q "NET-SMODE-IRQ-OK" \
   && [ -n "$IRQS" ] && [ "$IRQS" -ge 1 ] \
   && [ -n "$REAPED" ] && [ "$REAPED" -ge 1 ]; then
    echo "PASS: $TEST_NAME — $BACKEND backend async virtio-net TX completed from a REAL S-mode PLIC interrupt under OpenSBI, then drained through async_poll_many/SYS_POLL shape (IRQS=$IRQS REAPED=$REAPED POLL=1)"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected OpenSBI banner + NET-SMODE-IRQ RESULT=1 + POLL=1 + NET-SMODE-IRQ-OK + IRQS/REAPED >= 1"
exit 1
