#!/usr/bin/env bash
# Runnable kernel-thread test (timer-driven preemptive scheduler.
#
# Lowers the context-switch demo (which uses the typed `Context` + function-pointer
# thread entry) to C, links it with the asm context-switch runtime into a bare
# riscv64 image, and runs it under QEMU. `main` and one worker ping-pong by
# switching into each other, so the interleaved output proves the switch works.
#
# Usage: tools/preempt-test.sh <path-to-mcc>
# Skips (exit 0) when the riscv toolchain or QEMU is unavailable.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$HERE/tests/qemu/proc/preempt_demo.mc"
RUNTIME="$HERE/kernel/arch/riscv64/preempt_runtime.c"
SHARED="$HERE/kernel/arch/riscv64/context_runtime.c"
LDSCRIPT="$HERE/tests/qemu/virt.ld"

CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
QEMU="${QEMU:-qemu-system-riscv64}"

skip() { echo "SKIP: preempt-test ($1)"; exit 0; }
command -v "$CLANG" >/dev/null 2>&1 || skip "clang not found"
command -v "$LLD" >/dev/null 2>&1 || skip "ld.lld not found"
command -v "$QEMU" >/dev/null 2>&1 || skip "$QEMU not found"
"$CLANG" --print-targets 2>/dev/null | grep -q riscv64 || skip "clang has no riscv64 target"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function)

"$MCC" emit-c "$SRC" >"$WORK/thread.c"
"$CLANG" "${CFLAGS[@]}" -c "$WORK/thread.c" -o "$WORK/thread.o"
"$CLANG" "${CFLAGS[@]}" -c "$RUNTIME" -o "$WORK/runtime.o"
"$CLANG" "${CFLAGS[@]}" -c "$SHARED" -o "$WORK/shared.o"
"$LLD" -T "$LDSCRIPT" "$WORK/shared.o" "$WORK/runtime.o" "$WORK/thread.o" -o "$WORK/thread.elf"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/thread.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

# Each non-yielding worker prints its letter once when the timer first preempts
# into it, so all of A, B, C appearing proves preemption reached every thread, and
# PREEMPT-OK proves the bootstrap regained control and the run completed.
if printf '%s' "$OUT" | grep -q "A" \
   && printf '%s' "$OUT" | grep -q "B" \
   && printf '%s' "$OUT" | grep -q "C" \
   && printf '%s' "$OUT" | grep -q "PREEMPT-OK"; then
    echo "PASS: preempt-test — timer preemption rotated 3 non-yielding threads (A,B,C all ran) under QEMU"
    exit 0
fi
echo "FAIL: preempt-test — expected A, B, C and PREEMPT-OK in kernel output"
exit 1
