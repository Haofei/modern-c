#!/usr/bin/env bash
# Instrumented-process-table integration test.
#
# Lowers the instrumented-process-table demo through the selected backend, links it with the
# context runtime into a bare riscv64 image, and runs it under QEMU. It proves the three polish
# items wired onto the shared process core in one run: the UNIFIED LEDGER charges/releases on real
# IPC + block-I/O + DMA ops and rejects over-limit work without trapping (LEDGER-WIRED-OK); the
# METRICS counters reflect exact spawn/ipc/blk/preempt activity (METRICS-WIRED-OK); and a
# SUPERVISION TREE with LEASES gives up a crash-looping parent, cascades the give-up to its
# child/grandchild while an unrelated slot survives, and treats an expired lease like a missed
# heartbeat (SUPTREE-OK). INSTRUMENT-OK is printed only when all three held.
#
# Usage: tools/proc/instrument-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/proc/instrument_demo.mc"
RUNTIME="$HERE/tests/qemu/proc/instrument_runtime.mc"
SHARED="$HERE/tests/qemu/proc/context_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-instrument-test" || echo "instrument-test")

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

# All four markers must appear: the three subsystem proofs plus the final all-held gate.
if printf '%s' "$OUT" | grep -q "LEDGER-WIRED-OK" \
   && printf '%s' "$OUT" | grep -q "METRICS-WIRED-OK" \
   && printf '%s' "$OUT" | grep -q "SUPTREE-OK" \
   && printf '%s' "$OUT" | grep -q "INSTRUMENT-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend: unified ledger gated real IPC/blk/DMA ops (no trap), metrics counted exact spawn/ipc/blk/preempt, and the supervision tree cascaded a crash-looping parent's give-up to its child/grandchild with an expired lease driving action, under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected LEDGER-WIRED-OK, METRICS-WIRED-OK, SUPTREE-OK and INSTRUMENT-OK in kernel output"
exit 1
