#!/usr/bin/env bash
# QEMU microbenchmark for the page-table-aware uaccess hot path (Phase 2.4). NOT an m0
# gate — run via `zig build uaccess-bench`. Lowers tests/qemu/mem/uaccess_bench_runtime.mc
# through the selected backend, links with the freestanding libc, boots `-bios none`, and
# dumps the rdcycle totals (UACCESS-TO-CYCLES / UACCESS-FROM-CYCLES / UACCESS-CYCLES) for a
# 32x 1 MiB copy through copy_to_user_pt / copy_from_user_pt.
#
# Usage: tools/mem/uaccess-bench.sh <path-to-mcc> <c|llvm>
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
SRC="$HERE/tests/qemu/mem/uaccess_bench_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-uaccess-bench" || echo "uaccess-bench")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/uaccess_bench.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"

"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/uaccess_bench.o" \
    $SUPPORT_OBJ -o "$WORK/bench.elf"

OUT="$(timeout 120 "$QEMU" -machine virt -m 256M -bios none -nographic \
    -kernel "$WORK/bench.elf" 2>/dev/null || true)"

echo "--- uaccess-bench UART ($BACKEND) ---"
printf '%s\n' "$OUT"
echo "-------------------------------------"

if printf '%s' "$OUT" | grep -q "UACCESS-BENCH-DONE" \
    && ! printf '%s' "$OUT" | grep -q "UACCESS-BENCH-BAD"; then
    echo "PASS: $TEST_NAME — $BACKEND backend: uaccess-bench ran (see UACCESS-CYCLES above)"
    exit 0
fi
echo "FAIL: $TEST_NAME — uaccess-bench did not complete (missing UACCESS-BENCH-DONE or saw BAD)"
exit 1
