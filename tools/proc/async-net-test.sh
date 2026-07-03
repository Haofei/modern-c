#!/usr/bin/env bash
# async/await roadmap: DEVICE-BACKED completion over the NETWORK CARD. A REAL virtio-net TX used-ring
# device interrupt — not a timer, not the disk — completes an in-flight async frame send and resumes
# a task parked in drive_irq. The production shape for NIC async: submit a frame, sleep in wfi, the
# device's TX used-ring IRQ (PLIC-routed) reaps the completion and async_completes the broker id, the
# parked await resumes with NET_TX_DONE.
#
# Lowers the async-net demo + the external-IRQ trap runtime + the M-mode DMA/time platform through
# the selected backend, links with the context-switch runtime into a bare riscv64 image, attaches a
# virtio-net-device (user/slirp netdev, like tools/net/virtio-test.sh), and runs it under QEMU. The
# trace `W i R` proves W (about to drive), i (the DEVICE IRQ ran in interrupt context), R (resumed);
# ASYNC-NET-OK proves the TX completion round-tripped via the device interrupt.
#
# Usage: tools/proc/async-net-test.sh <path-to-mcc> [c|llvm]
# Skips (exit 0) when the riscv toolchain or QEMU is unavailable.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
SRC="$HERE/tests/qemu/proc/async_net_demo.mc"
RUNTIME="$HERE/tests/qemu/proc/async_net_runtime.mc"
PLATFORM="$HERE/kernel/arch/riscv64/mmode_dma_time.mc"
SHARED="$HERE/tests/qemu/proc/context_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-async-net-test" || echo "async-net-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/demo.o" "$WORK"
mkdir -p "$WORK/rt"
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK/rt"
mkdir -p "$WORK/pf"
kernel_boot_compile_mc_object "$BACKEND" "$PLATFORM" "$WORK/platform.o" "$WORK/pf"
kernel_boot_compile_c_object "$SHARED" "$WORK/shared.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/shared.o" "$WORK/runtime.o" "$WORK/platform.o" "$WORK/demo.o" $SUPPORT_OBJ -o "$WORK/async.elf"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -global virtio-mmio.force-legacy=false \
        -netdev user,id=n0 \
        -device virtio-net-device,netdev=n0 \
        -object filter-dump,id=f0,netdev=n0,file="$WORK/tx.pcap" \
        -kernel "$WORK/async.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

# W i R: about-to-drive -> DEVICE IRQ reaped the completion (i, interrupt context) -> resumed.
# ASYNC-NET-OK: the TX completion (NET_TX_DONE) round-tripped via the device interrupt.
# NET-NOLEAK-OK + free=8: the demo did 3 sequential sends (each awaited via the TX device IRQ) and
# the TX descriptor free list returned to full (8/8), proving the ISR reclaims every frame's
# descriptor + pool slot (no per-send descriptor/DMA leak). A leak would surface as NET-QUEUE-FULL or
# free!=8 / NET-NOLEAK-FAIL.
if printf '%s' "$OUT" | grep -q "Wi" \
   && printf '%s' "$OUT" | grep -q "ASYNC-NET-OK" \
   && printf '%s' "$OUT" | grep -q "NET-NOLEAK-OK" \
   && printf '%s' "$OUT" | grep -q "free=8"; then
    echo "PASS: $TEST_NAME — $BACKEND backend: 3 sequential async frame sends each resolved against a REAL virtio-net TX device interrupt (PLIC-routed used-ring completion reaped in interrupt context — trace 'i' — async_completing the broker id), driven by drive_irq under wfi (Wi…R, ASYNC-NET-OK); the TX descriptor free list returned to full 8/8 (free=8, NET-NOLEAK-OK) — no descriptor/DMA leak across sends — under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected 'Wi' (device IRQ in interrupt context), ASYNC-NET-OK, NET-NOLEAK-OK and free=8 in kernel output (a leak shows as NET-QUEUE-FULL or free!=8)"
exit 1
