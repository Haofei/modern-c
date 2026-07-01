#!/usr/bin/env bash
# QEMU correctness gate for the word-aligned mem ops (Phase 1.1).
#
# Lowers the self-contained mem-ops runtime (tests/qemu/mem/mem_ops_runtime.mc)
# through the selected backend, links it with the freestanding libc object
# (kernel/lib/freestanding.mc — whose word-aligned memcpy/memmove/memset are under
# test) into a riscv64 image, and boots it `-bios none`. The runtime runs mem_copy/
# mem_set/memmove across boundary lengths and alignments and prints MEM-OK iff every
# case is byte-exact (MEM-BAD on a mismatch, MEM-TRAP on an unexpected fault).
#
# Usage: tools/mem/mem-test.sh <path-to-mcc> <c|llvm>
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
SRC="$HERE/tests/qemu/mem/mem_ops_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-mem-test" || echo "mem-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/mem_ops.o" "$WORK"
kernel_boot_compile_rt "$WORK/freestanding.o"

"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/mem_ops.o" -o "$WORK/mem.elf"

OUT="$(timeout 60 "$QEMU" -machine virt -bios none -nographic \
    -kernel "$WORK/mem.elf" 2>/dev/null || true)"

echo "--- mem-test UART ($BACKEND) ---"
printf '%s\n' "$OUT"
echo "--------------------------------"

if printf '%s' "$OUT" | grep -q "MEM-OK" \
    && ! printf '%s' "$OUT" | grep -qE "MEM-(BAD|TRAP)"; then
    echo "PASS: $TEST_NAME — $BACKEND backend: mem_copy/mem_set/memmove byte-exact across lengths+alignments under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — missing MEM-OK or saw MEM-BAD/MEM-TRAP"
exit 1
