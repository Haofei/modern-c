#!/usr/bin/env bash
# Runnable kernel-thread test (cooperative context switching).
#
# Lowers the context-switch demo (which uses the typed `Context` + function-pointer
# thread entry) to C, links it with the asm context-switch runtime into a bare
# riscv64 image, and runs it under QEMU. `main` and one worker ping-pong by
# switching into each other, so the interleaved output proves the switch works.
#
# Usage: tools/lang/syscall-test.sh <path-to-mcc>
# Skips (exit 0) when the riscv toolchain or QEMU is unavailable.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/qemu/lang/syscall_demo.mc"
RUNTIME="$HERE/kernel/arch/riscv64/syscall_runtime.c"
SHARED="$HERE/kernel/arch/riscv64/context_runtime.c"
LDSCRIPT="$HERE/tests/qemu/virt.ld"

CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
QEMU="${QEMU:-qemu-system-riscv64}"

skip() { echo "SKIP: syscall-test ($1)"; exit 0; }
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

# ecall dispatch through the fn-pointer table: sys_putc prints X, sys_add returns
# 7, and an unregistered number fails closed with ENOSYS.
if printf '%s' "$OUT" | grep -q "X" \
   && printf '%s' "$OUT" | grep -q "SYS-ADD=7" \
   && printf '%s' "$OUT" | grep -q "ENOSYS=Y" \
   && printf '%s' "$OUT" | grep -q "SYSCALL-OK"; then
    echo "PASS: syscall-test — ecall dispatched through the fn-pointer syscall table (add, putc, ENOSYS) under QEMU"
    exit 0
fi
echo "FAIL: syscall-test — expected X, SYS-ADD=7, ENOSYS=Y, SYSCALL-OK in kernel output"
exit 1
