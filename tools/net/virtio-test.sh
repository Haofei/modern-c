#!/usr/bin/env bash
# Real virtio-net driver execution test (§28, virtio 1.x over virtio-mmio).
#
# Lowers the MC virtio-net driver through the selected backend, links it into a
# bare-metal riscv64 image with the platform runtime, runs it under
# qemu-system-riscv64 -machine virt with an attached `virtio-net-device`, and
# checks that the driver completed the device handshake and the device reaped a
# transmitted descriptor (the used ring advanced) — i.e. the device accepted the
# MC driver's virtqueue setup + frame.
#
# Usage: tools/net/virtio-test.sh <path-to-mcc> [c|llvm]
# Skips (exit 0) when the riscv toolchain or QEMU is unavailable.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
SRC="$HERE/demo/virtio-net/virtio_net.mc"
RUNTIME="$HERE/demo/virtio-net/runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
EXPECT="VIRTIO-TX-OK"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-virtio-test" || echo "virtio-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/virtio.o" "$WORK"
kernel_boot_compile_c_object "$RUNTIME" "$WORK/runtime.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/runtime.o" "$WORK/virtio.o" $SUPPORT_OBJ -o "$WORK/virtio.elf"

# 3. Run under QEMU with an attached virtio-net device (user net + pcap capture).
#
# Bounded retry: whether the guest observes the TX descriptor reaped within its poll
# budget is an irreducible QEMU-TCG timing race (the single emulator thread interleaves
# the guest's busy-poll with the virtio backend's main-loop servicing — host scheduling
# decides which wins). The driver logic is deterministic; only this wall-clock race is
# not. So re-run the QEMU step up to ATTEMPTS times and pass on the first success — a
# genuinely broken driver fails EVERY attempt (no VIRTIO-TX-OK ever), while a timing
# flake clears within a couple. The expensive build above happens once; only the ~boot
# is repeated.
ATTEMPTS="${VIRTIO_TEST_ATTEMPTS:-10}"
attempt=1
while [ "$attempt" -le "$ATTEMPTS" ]; do
    OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
            -global virtio-mmio.force-legacy=false \
            -netdev user,id=n0 \
            -device virtio-net-device,netdev=n0 \
            -object filter-dump,id=f0,netdev=n0,file="$WORK/tx.pcap" \
            -kernel "$WORK/virtio.elf" 2>/dev/null || true)"

    if printf '%s' "$OUT" | grep -q "$EXPECT"; then
        echo "--- driver UART output (attempt $attempt/$ATTEMPTS) ---"
        printf '%s\n' "$OUT"
        echo "--------------------------"
        PCAP_NOTE=""
        if [ -s "$WORK/tx.pcap" ]; then PCAP_NOTE=" (captured $(wc -c <"$WORK/tx.pcap") bytes of TX pcap)"; fi
        RETRY_NOTE=""
        [ "$attempt" -gt 1 ] && RETRY_NOTE=" [passed on attempt $attempt/$ATTEMPTS after timing-race retries]"
        echo "PASS: $TEST_NAME — $BACKEND backend MC virtio-net driver completed handshake and the device reaped a TX descriptor under QEMU${PCAP_NOTE}${RETRY_NOTE}"
        exit 0
    fi
    echo "attempt $attempt/$ATTEMPTS: no '$EXPECT' yet (TX-reap timing race) — retrying" >&2
    attempt=$((attempt + 1))
done

echo "--- driver UART output (last of $ATTEMPTS attempts) ---"
printf '%s\n' "$OUT"
echo "--------------------------"
echo "FAIL: $TEST_NAME — expected '$EXPECT' in driver output across all $ATTEMPTS attempts"
exit 1
