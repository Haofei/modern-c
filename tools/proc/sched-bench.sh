#!/usr/bin/env bash
# Scheduler pick-path microbenchmark (Phase 2.2). NOT an m0 gate — run via
# `zig build sched-bench`. Lowers the sched-bench runtime + demo through the selected
# backend, links them with the shared context runtime into a bare riscv64 image, boots
# it under QEMU, and dumps the average cycles per next_runnable() pick (SCHED-CYCLES).
#
# Usage: tools/proc/sched-bench.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/proc/sched_bench_demo.mc"
RUNTIME="$HERE/tests/qemu/proc/sched_bench_runtime.mc"
SHARED="$HERE/tests/qemu/proc/context_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-sched-bench" || echo "sched-bench")

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

echo "--- sched-bench UART ($BACKEND) ---"
printf '%s\n' "$OUT"
echo "-----------------------------------"

if printf '%s' "$OUT" | grep -q "SCHED-BENCH-DONE"; then
    echo "PASS: $TEST_NAME — $BACKEND backend: sched-bench ran (see SCHED-CYCLES above)"
    exit 0
fi
echo "FAIL: $TEST_NAME — sched-bench did not complete"
exit 1
