#!/usr/bin/env bash
# Runnable kernel-thread test (cooperative context switching).
#
# Lowers the context-switch demo (which uses the typed `Context` + function-pointer
# thread entry) to C, links it with the asm context-switch runtime into a bare
# riscv64 image, and runs it under QEMU. `main` and one worker ping-pong by
# switching into each other, so the interleaved output proves the switch works.
#
# Usage: tools/lang/user-test.sh <path-to-mcc>
# Skips (exit 0) when the riscv toolchain or QEMU is unavailable.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/qemu/lang/userserver_demo.mc"
RUNTIME="$HERE/kernel/arch/riscv64/userserver_runtime.c"
SHARED="$HERE/kernel/arch/riscv64/context_runtime.c"
LDSCRIPT="$HERE/tests/qemu/virt.ld"

CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
QEMU="${QEMU:-qemu-system-riscv64}"

skip() { echo "SKIP: user-test ($1)"; exit 0; }
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
"$CLANG" "${CFLAGS[@]}" -c "$HERE/kernel/arch/riscv64/usermode_runtime.c" -o "$WORK/usermode.o"
"$LLD" -T "$LDSCRIPT" "$WORK/shared.o" "$WORK/usermode.o" "$WORK/runtime.o" "$WORK/thread.o" -o "$WORK/thread.elf"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/thread.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

# The U-mode task prints USERVER-OK via syscalls; copy_from_user validates + copies a user
# buffer (FROMUSER) and rejects an out-of-range pointer (the task then prints R);
# the exit ecall coming from U-mode proves the privilege drop.
if printf '%s' "$OUT" | grep -q "USERVER-OK" \
   && printf '%s' "$OUT" | grep -q "USER-EXIT from U"; then
    echo "PASS: userserver-test — a server running in U-mode (privilege-isolated) serviced requests entirely via syscalls (doubled 10/20/30 -> USERVER-OK) and exited from U-mode under QEMU"
    exit 0
fi
echo "FAIL: userserver-test — expected USERVER-OK and USER-EXIT from U"
exit 1
