#!/usr/bin/env bash
# Kernel virtio-net RX/TX execution test (the typed-OS net path).
#
# Lowers the MC kernel virtio-net driver + net stack (ethernet/arp) through the
# selected backend, links it into a bare-metal riscv64 image with the platform
# runtime, and runs it under qemu-system-riscv64 -machine virt with a
# virtio-net-device on QEMU user
# networking. The guest sends a broadcast ARP request for the gateway (10.0.2.2)
# and must receive slirp's ARP reply on the RX queue — exercising the descriptor
# free list, multi-buffer DMA, RX completion, and the byte-view net builders.
#
# Usage: tools/net/net-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/kernel/main.mc"
RUNTIME="$HERE/kernel/drivers/virtio/net_runtime.c"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
EXPECT="NET-PING-OK"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-net-test" || echo "net-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/net.o" "$WORK"
kernel_boot_compile_c_object "$RUNTIME" "$WORK/runtime.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/runtime.o" "$WORK/net.o" $SUPPORT_OBJ -o "$WORK/net.elf"

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
    echo "PASS: $TEST_NAME — $BACKEND backend MC kernel pinged the gateway (ARP + ICMP echo round-trip) over virtio-net under QEMU${PCAP_NOTE}"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected '$EXPECT' in driver output"
exit 1
