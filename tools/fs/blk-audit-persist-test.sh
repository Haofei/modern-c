#!/usr/bin/env bash
# Durable policy/audit persistence gate (production-readiness §3.1 #3): prove the block-backed
# policy/audit checkpoint (kernel/core/block_persistent_audit.mc) survives a real reboot over
# virtio-blk. Build the fixture (tests/qemu/arch/blk_audit_persist_demo.mc, which checkpoints a
# policy snapshot to the disk on the first boot and re-verifies every field on the second), then
# boot QEMU TWICE against the SAME -drive file. The kernel + RAM are fresh each boot; only the disk
# image persists. PASS requires the first boot to report AUDIT-PERSIST-WROTE and the second (fresh)
# boot to report AUDIT-PERSIST-OK.
#
# Usage: tools/fs/blk-audit-persist-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/arch/blk_audit_persist_demo.mc"
PLATFORM="$HERE/kernel/arch/riscv64/mmode_dma_time.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-blk-audit-persist-test" || echo "blk-audit-persist-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/blk.o" "$WORK"
kernel_boot_compile_mc_object "$BACKEND" "$PLATFORM" "$WORK/platform.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/blk.o" "$WORK/platform.o" $SUPPORT_OBJ -o "$WORK/blk.elf"

# A fresh, zeroed disk image — no checkpoint present, so the first boot must write it.
dd if=/dev/zero of="$WORK/disk.img" bs=512 count=16 2>/dev/null

run_boot() { # one QEMU boot against the persistent disk image; echoes the UART output
    timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -global virtio-mmio.force-legacy=false \
        -drive file="$WORK/disk.img",format=raw,if=none,id=d0 \
        -device virtio-blk-device,drive=d0 \
        -kernel "$WORK/blk.elf" 2>/dev/null || true
}

echo "=== boot 1 (fresh disk: expect AUDIT-PERSIST-WROTE) ==="
OUT1="$(run_boot)"; printf '%s\n' "$OUT1"
echo "=== boot 2 (same disk, fresh kernel+RAM: expect AUDIT-PERSIST-OK) ==="
OUT2="$(run_boot)"; printf '%s\n' "$OUT2"
echo "--------------------------"

if printf '%s' "$OUT1" | grep -q "AUDIT-PERSIST-WROTE" && printf '%s' "$OUT2" | grep -q "AUDIT-PERSIST-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend: a policy/audit checkpoint written to virtio-blk on boot 1 was loaded and field-verified on a fresh boot 2 (durable policy state survives reboot)"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected AUDIT-PERSIST-WROTE on boot 1 and AUDIT-PERSIST-OK on boot 2 (boot1='$OUT1' boot2='$OUT2')"
exit 1
