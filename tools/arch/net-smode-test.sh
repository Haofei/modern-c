#!/usr/bin/env bash
# Real virtio-net RX/TX driver execution test under REAL OpenSBI firmware in S-mode.
#
# Same EXISTING MC virtio-net driver + net stack (kernel/main.mc's kernel_main) as
# the M-mode net-test, but linked with the S-mode/OpenSBI runtime
# (net_smode_runtime.c) and the OpenSBI payload linker script (sbi.ld), and run
# WITHOUT `-bios none` so QEMU loads the real OpenSBI firmware which boots our
# kernel in S-mode at 0x80200000. The guest sends a broadcast ARP request for the
# gateway (10.0.2.2) and an ICMP echo, and must receive slirp's replies on the RX
# queue (pcap-captured) — exercising the descriptor free list, multi-buffer DMA,
# RX completion, and the byte-view net builders. (satp=0 Bare mode = flat
# physical; OpenSBI's PMP permits S-mode RAM+MMIO so the DMA works unchanged;
# time via the rdtime CSR since the CLINT mtime MMIO faults under OpenSBI.)
#
# Usage: tools/arch/net-smode-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/arch/net_smode_demo.mc"
LDSCRIPT="$HERE/tests/qemu/sbi.ld"
EXPECT="NET-PING-OK"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-net-smode-test" || echo "net-smode-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-function -fno-builtin)

# PURE-MC kernel: `_start` + boot seam are `#[naked]` MC; the SBI seam and the
# virtio-mmio probe are MC (sbi.mc / sbi_virtio_probe.mc); the virtio-net driver +
# net stack are the same MC as the M-mode path (kernel_main) — no .c runtime. The
# std/dma + std/time platform primitives (rdtime time source + bump DMA pool) are
# MC too (sbi_dma_time.mc), compiled as a SEPARATE object and linked so its
# definitions bind the std `extern fn` seam by name.
kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/net.o" "$WORK"
kernel_boot_compile_mc_object "$BACKEND" "$HERE/kernel/arch/riscv64/sbi_dma_time.mc" "$WORK/platform.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/net.o" "$WORK/platform.o" $SUPPORT_OBJ -o "$WORK/net.elf"

# Run under QEMU with a virtio-net device on user networking (pcap capture). NO
# '-bios none' -> QEMU loads OpenSBI (the real firmware) which boots our kernel
# in S-mode.
OUT="$(timeout 30 "$QEMU" -machine virt -m 256M -nographic \
        -global virtio-mmio.force-legacy=false \
        -netdev user,id=n0 \
        -device virtio-net-device,netdev=n0 \
        -object filter-dump,id=f0,netdev=n0,file="$WORK/net.pcap" \
        -kernel "$WORK/net.elf" 2>/dev/null || true)"

echo "--- OpenSBI + driver UART output ---"
printf '%s\n' "$OUT"
echo "------------------------------------"

if printf '%s' "$OUT" | grep -qi "OpenSBI" \
   && printf '%s' "$OUT" | grep -q "$EXPECT"; then
    PCAP_NOTE=""
    if [ -s "$WORK/net.pcap" ]; then PCAP_NOTE=" (captured $(wc -c <"$WORK/net.pcap") bytes of pcap)"; fi
    echo "PASS: $TEST_NAME — $BACKEND backend MC kernel pinged the gateway (ARP + ICMP echo round-trip) over virtio-net under REAL OpenSBI in S-mode${PCAP_NOTE} (satp=0 Bare; OpenSBI PMP permits S-mode virtio-mmio + RAM DMA; time via rdtime CSR)"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected OpenSBI banner + '$EXPECT' in driver output"
exit 1
