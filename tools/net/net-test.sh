#!/usr/bin/env bash
# Kernel virtio-net RX/TX execution test (the typed-OS net path).
#
# Lowers the MC kernel virtio-net driver + net stack (ethernet/arp) to C, links it
# into a bare-metal riscv64 image with the platform runtime, and runs it under
# qemu-system-riscv64 -machine virt with a virtio-net-device on QEMU user
# networking. The guest sends a broadcast ARP request for the gateway (10.0.2.2)
# and must receive slirp's ARP reply on the RX queue — exercising the descriptor
# free list, multi-buffer DMA, RX completion, and the byte-view net builders.
#
# Usage: tools/net/net-test.sh <path-to-mcc>
# Skips (exit 0) when the riscv toolchain or QEMU is unavailable.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/kernel/main.mc"
RUNTIME="$HERE/kernel/drivers/virtio/net_runtime.c"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
EXPECT="NET-PING-OK"

CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
QEMU="${QEMU:-qemu-system-riscv64}"

skip() { echo "SKIP: net-test ($1)"; exit 0; }
command -v "$CLANG" >/dev/null 2>&1 || skip "clang not found"
command -v "$LLD" >/dev/null 2>&1 || skip "ld.lld not found"
command -v "$QEMU" >/dev/null 2>&1 || skip "$QEMU not found"
"$CLANG" --print-targets 2>/dev/null | grep -q riscv64 || skip "clang has no riscv64 target"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-function)

# 1. MC -> C (the typed kernel net driver + stack).
"$MCC" emit-c "$SRC" >"$WORK/net.c"

# 2. Compile + link the bare-metal image.
"$CLANG" "${CFLAGS[@]}" -c "$WORK/net.c" -o "$WORK/net.o"
"$CLANG" "${CFLAGS[@]}" -c "$RUNTIME" -o "$WORK/runtime.o"
"$LLD" -T "$LDSCRIPT" "$WORK/runtime.o" "$WORK/net.o" -o "$WORK/net.elf"

# 3. Run under QEMU with a virtio-net device on user networking (pcap capture).
OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -global virtio-mmio.force-legacy=false \
        -netdev user,id=n0 \
        -device virtio-net-device,netdev=n0 \
        -object filter-dump,id=f0,netdev=n0,file="$WORK/net.pcap" \
        -kernel "$WORK/net.elf" 2>/dev/null || true)"

echo "--- driver UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

if printf '%s' "$OUT" | grep -q "$EXPECT"; then
    PCAP_NOTE=""
    if [ -s "$WORK/net.pcap" ]; then PCAP_NOTE=" (captured $(wc -c <"$WORK/net.pcap") bytes of pcap)"; fi
    echo "PASS: net-test — MC kernel pinged the gateway (ARP + ICMP echo round-trip) over virtio-net under QEMU${PCAP_NOTE}"
    exit 0
fi
echo "FAIL: net-test — expected '$EXPECT' in driver output"
exit 1
