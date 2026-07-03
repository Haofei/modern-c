#!/usr/bin/env bash
# IPC latency microbench (Phase 1.4 O(1) mailbox + 1.5 provenance-off-hot-path).
#
# Lowers the IPC bench (N ipc_send + ipc_receive round-trips over a ProcTable, bracketed by
# rdcycle) through the selected backend, links it into a bare riscv64 image, and runs it under
# QEMU. Prints "IPC-CYCLES <n>" (cycles per round-trip). Not an m0 gate — a measurement tool.
#
# Usage: tools/ipc/ipc-bench.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/ipc/ipc_bench_demo.mc"
RUNTIME="$HERE/tests/qemu/ipc/ipc_bench_runtime.mc"
SHARED="$HERE/tests/qemu/proc/context_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-ipc-bench" || echo "ipc-bench")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/bench.o" "$WORK"
mkdir -p "$WORK/rt"
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK/rt"
kernel_boot_compile_c_object "$SHARED" "$WORK/shared.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/shared.o" "$WORK/runtime.o" "$WORK/bench.o" $SUPPORT_OBJ -o "$WORK/bench.elf"

OUT="$(timeout 60 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/bench.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

if printf '%s' "$OUT" | grep -q "IPC-CYCLES" \
   && printf '%s' "$OUT" | grep -q "ipc-bench done"; then
    CYC="$(printf '%s' "$OUT" | grep "IPC-CYCLES" | head -1)"
    echo "PASS: $TEST_NAME — $BACKEND backend IPC round-trip bench under QEMU ($CYC cycles/round-trip)"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected IPC-CYCLES and 'ipc-bench done' in kernel output"
exit 1
