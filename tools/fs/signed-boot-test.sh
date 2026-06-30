#!/usr/bin/env bash
# Signed-image admission + rollback gate (production-readiness: secure boot). Lowers the
# secure-boot fixture (tests/qemu/arch/signed_boot_demo.mc, which drives the bundle-admission
# and A/B rollback state machine in kernel/core/production_ops.mc end to end), links it into a
# bare riscv64 M-mode image, and boots it ONCE under QEMU. PASS requires all three markers:
#   SIGBOOT-ACCEPT      — a correctly-signed, in-range, trusted-key bundle was admitted
#   SIGBOOT-ROLLBACK-OK — failed-boot rollback reverted to the prior good image; success committed
#   SIGNED-BOOT-OK      — every accept/reject/rollback assertion held
#
# Usage: tools/fs/signed-boot-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/arch/signed_boot_demo.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-signed-boot-test" || echo "signed-boot-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-function -Wno-unused-variable -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/sigboot.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/sigboot.o" $SUPPORT_OBJ -o "$WORK/sigboot.bin"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/sigboot.bin" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

if printf '%s' "$OUT" | grep -q "SIGBOOT-ACCEPT" \
   && printf '%s' "$OUT" | grep -q "SIGBOOT-ROLLBACK-OK" \
   && printf '%s' "$OUT" | grep -q "SIGNED-BOOT-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend admitted a correctly-signed in-range bundle, rejected every tamper case, and rolled back a failed boot to the prior good image under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected SIGBOOT-ACCEPT, SIGBOOT-ROLLBACK-OK and SIGNED-BOOT-OK in kernel output"
exit 1
