#!/usr/bin/env bash
# QEMU microbenchmark for the mem hot path (Phase 0). NOT an m0 gate — run via
# `zig build mem-bench`. Lowers tests/qemu/mem/mem_bench_runtime.mc through the
# selected backend, links with the freestanding libc, boots `-bios none`, and dumps
# the rdcycle totals (MEMCPY-CYCLES / MEMSET-CYCLES) for a 64x 1 MiB copy/fill.
#
# Usage: tools/mem/mem-bench.sh <path-to-mcc> <c|llvm>
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
SRC="$HERE/tests/qemu/mem/mem_bench_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-mem-bench" || echo "mem-bench")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/mem_bench.o" "$WORK"
kernel_boot_compile_rt "$WORK/freestanding.o"

"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/mem_bench.o" -o "$WORK/bench.elf"

OUT="$(timeout 120 "$QEMU" -machine virt -m 256M -bios none -nographic \
    -kernel "$WORK/bench.elf" 2>/dev/null || true)"

echo "--- mem-bench UART ($BACKEND) ---"
printf '%s\n' "$OUT"
echo "---------------------------------"

if printf '%s' "$OUT" | grep -q "MEM-BENCH-DONE"; then
    echo "PASS: $TEST_NAME — $BACKEND backend: mem-bench ran (see MEMCPY-CYCLES / MEMSET-CYCLES above)"
    exit 0
fi
echo "FAIL: $TEST_NAME — mem-bench did not complete"
exit 1
