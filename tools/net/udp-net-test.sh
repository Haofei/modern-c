#!/usr/bin/env bash
# Real virtio-net driver execution test (§28, virtio 1.x over virtio-mmio).
#
# Lowers the MC UDP-over-virtio-net driver through the selected backend, links it
# into a bare-metal riscv64 image with the platform runtime, runs it under
# qemu-system-riscv64 -machine virt with an attached `virtio-net-device`, and
# checks that the transmitted UDP payload reached the QEMU pcap.
#
# Usage: tools/net/udp-net-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/demo/virtio-net/udp_send.mc"
RUNTIME="$HERE/demo/virtio-net/udp_runtime.c"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
EXPECT="UDP-TX-OK"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-udp-net-test" || echo "udp-net-test")

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
    echo "PASS: $TEST_NAME — $BACKEND backend MC built + transmitted a real UDP/IP/Ethernet datagram over virtio-net; payload captured in the TX pcap"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected '$EXPECT' in driver output"
exit 1
