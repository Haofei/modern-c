#!/usr/bin/env bash
# Real virtio-net driver execution test (§28, virtio 1.x over virtio-mmio).
#
# Lowers the MC virtio-net driver to C, links it into a bare-metal riscv64 image
# with the platform runtime, runs it under qemu-system-riscv64 -machine virt with
# an attached `virtio-net-device`, and checks that the driver completed the
# device handshake and the device reaped a transmitted descriptor (the used ring
# advanced) — i.e. the device accepted the MC driver's virtqueue setup + frame.
#
# Usage: tools/udp-net-test.sh <path-to-mcc>
# Skips (exit 0) when the riscv toolchain or QEMU is unavailable.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/demo/virtio-net/udp_send.mc"
RUNTIME="$HERE/demo/virtio-net/udp_runtime.c"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
EXPECT="UDP-TX-OK"

CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
QEMU="${QEMU:-qemu-system-riscv64}"

skip() { echo "SKIP: udp-net-test ($1)"; exit 0; }
command -v "$CLANG" >/dev/null 2>&1 || skip "clang not found"
command -v "$LLD" >/dev/null 2>&1 || skip "ld.lld not found"
command -v "$QEMU" >/dev/null 2>&1 || skip "$QEMU not found"
"$CLANG" --print-targets 2>/dev/null | grep -q riscv64 || skip "clang has no riscv64 target"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-function)

# 1. MC -> C (the typed virtio-net driver).
"$MCC" emit-c "$SRC" >"$WORK/virtio.c"

# 2. Compile + link the bare-metal image.
"$CLANG" "${CFLAGS[@]}" -c "$WORK/virtio.c" -o "$WORK/virtio.o"
"$CLANG" "${CFLAGS[@]}" -c "$RUNTIME" -o "$WORK/runtime.o"
"$LLD" -T "$LDSCRIPT" "$WORK/runtime.o" "$WORK/virtio.o" -o "$WORK/virtio.elf"

# 3. Run under QEMU with an attached virtio-net device (user net + pcap capture).
OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -global virtio-mmio.force-legacy=false \
        -netdev user,id=n0 \
        -device virtio-net-device,netdev=n0 \
        -object filter-dump,id=f0,netdev=n0,file="$WORK/tx.pcap" \
        -kernel "$WORK/virtio.elf" 2>/dev/null || true)"

echo "--- driver UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

if printf '%s' "$OUT" | grep -q "$EXPECT" && grep -aq "UDPTEST" "$WORK/tx.pcap"; then
    PCAP_NOTE=""
    if [ -s "$WORK/tx.pcap" ]; then PCAP_NOTE=" (captured $(wc -c <"$WORK/tx.pcap") bytes of TX pcap)"; fi
    echo "PASS: udp-net-test — MC built + transmitted a real UDP/IP/Ethernet datagram over virtio-net; payload captured in the TX pcap"
    exit 0
fi
echo "FAIL: udp-net-test — expected '$EXPECT' in driver output"
exit 1
