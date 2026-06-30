#!/usr/bin/env bash
# Runnable supervisor-loop test.
#
# Lowers the running supervisor-loop demo through the selected backend, links it with the
# context runtime into a bare riscv64 image, and runs it under QEMU. Where the unit-level
# scheduler-test exercises the supervision PRIMITIVES in isolation, this proves the running
# LOOP: proc_supervisor_scan folds proc_supervise_step over every supervised slot each tick and
# actuates the verdict (record + re-arm a restart, give up on a crash-looper) across three real
# spawned processes -- one stays healthy, one is restarted once, one is given up exactly once.
#
# Usage: tools/proc/proc-supervisor-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/proc/proc_supervisor_demo.mc"
RUNTIME="$HERE/tests/qemu/proc/proc_supervisor_runtime.mc"
SHARED="$HERE/tests/qemu/proc/context_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-proc-supervisor-test" || echo "proc-supervisor-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/thread.o" "$WORK"
mkdir -p "$WORK/rt"
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK/rt"
kernel_boot_compile_c_object "$SHARED" "$WORK/shared.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/shared.o" "$WORK/runtime.o" "$WORK/thread.o" $SUPPORT_OBJ -o "$WORK/thread.elf"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/thread.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

# SUPERVISOR-SCAN-OK proves every per-tick scan verdict held (healthy untouched, transient
# restarted, crash-looper given up); SUPERVISOR-LOOP-OK proves the full loop including
# "given up exactly once, not restarted forever".
if printf '%s' "$OUT" | grep -q "SUPERVISOR-SCAN-OK" \
   && printf '%s' "$OUT" | grep -q "SUPERVISOR-LOOP-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend running supervisor loop: proc_supervisor_scan restarted a transient miss once and gave up on a crash-looper exactly once over 3 processes under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected SUPERVISOR-SCAN-OK and SUPERVISOR-LOOP-OK in kernel output"
exit 1
