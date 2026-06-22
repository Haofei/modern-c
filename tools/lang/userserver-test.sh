#!/usr/bin/env bash
# Runnable user-mode server test.
#
# Lowers the user-mode server demo through the selected backend, links it with
# the syscall/context runtime into a bare riscv64 image, and runs it under QEMU.
#
# Usage: tools/lang/userserver-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/lang/userserver_demo.mc"
# PURE-MC test entry (test_main + U-mode server_main + user stack); `_start`/
# `mc_halt`/`puts_` from context_runtime.c, `usermode_setup`/`enter_user`/`do_ecall`
# from the shared usermode_runtime.c.
RUNTIME="$HERE/tests/qemu/lang/userserver_runtime.mc"
SHARED="$HERE/tests/qemu/proc/context_runtime.mc"
USERMODE="$HERE/tests/qemu/proc/usermode_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-userserver-test" || echo "userserver-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/thread.o" "$WORK"
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK"
kernel_boot_compile_c_object "$SHARED" "$WORK/shared.o"
kernel_boot_compile_c_object "$USERMODE" "$WORK/usermode.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/shared.o" "$WORK/usermode.o" "$WORK/runtime.o" "$WORK/thread.o" $SUPPORT_OBJ -o "$WORK/thread.elf"

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
    echo "PASS: $TEST_NAME — $BACKEND backend server running in U-mode (privilege-isolated) serviced requests entirely via syscalls (doubled 10/20/30 -> USERVER-OK) and exited from U-mode under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected USERVER-OK and USER-EXIT from U"
exit 1
