#!/usr/bin/env bash
# QEMU microbenchmark for the kernel heap's free path (Phase 2.1). NOT an m0 gate — run via
# `zig build heap-bench`. Lowers tests/qemu/mem/heap_bench_runtime.mc through the selected
# backend, links with the freestanding libc, boots `-bios none`, and dumps the rdcycle total
# (HEAPFREE-CYCLES) for the adversarial fragment-and-coalesce free sequence. Flip
# HEAP_COMPACT_FREELIST in kernel/core/heap.mc to compare legacy vs compacted coalesce.
#
# Usage: tools/mem/heap-bench.sh <path-to-mcc> <c|llvm>
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
SRC="$HERE/tests/qemu/mem/heap_bench_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-heap-bench" || echo "heap-bench")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/heap_bench.o" "$WORK"
kernel_boot_compile_rt "$WORK/freestanding.o"

"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/heap_bench.o" -o "$WORK/bench.elf"

OUT="$(timeout 120 "$QEMU" -machine virt -m 256M -bios none -nographic \
    -kernel "$WORK/bench.elf" 2>/dev/null || true)"

echo "--- heap-bench UART ($BACKEND) ---"
printf '%s\n' "$OUT"
echo "----------------------------------"

if printf '%s' "$OUT" | grep -q "HEAP-BENCH-DONE"; then
    echo "PASS: $TEST_NAME — $BACKEND backend: heap-bench ran (see HEAPFREE-CYCLES above)"
    exit 0
fi
echo "FAIL: $TEST_NAME — heap-bench did not complete"
exit 1
