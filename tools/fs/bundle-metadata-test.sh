#!/usr/bin/env bash
# Bundle-metadata admission + rollback gate. This deliberately does NOT claim secure
# boot: cryptographic RSA/SHA-256 verification is qualified by rsa-verify-test, while
# this QEMU fixture covers metadata policy and the A/B rollback state machine. The
# verifier-to-loader exact-byte binding remains a separate integration requirement.
#
# Usage: tools/fs/bundle-metadata-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/arch/bundle_metadata_demo.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-bundle-metadata-test" || echo "bundle-metadata-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-function -Wno-unused-variable -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/bundle-metadata.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/bundle-metadata.o" $SUPPORT_OBJ -o "$WORK/bundle-metadata.bin"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/bundle-metadata.bin" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

if printf '%s' "$OUT" | grep -q "BUNDLE-METADATA-ACCEPT" \
   && printf '%s' "$OUT" | grep -q "BUNDLE-ROLLBACK-OK" \
   && printf '%s' "$OUT" | grep -q "BUNDLE-METADATA-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend enforced bundle metadata policy and rolled back a failed candidate under QEMU (cryptographic verification is qualified separately)"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected BUNDLE-METADATA-ACCEPT, BUNDLE-ROLLBACK-OK and BUNDLE-METADATA-OK in kernel output"
exit 1
