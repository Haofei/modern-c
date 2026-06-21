#!/usr/bin/env bash
# M8 "AArch64 EL0 user hello". Build a flat aarch64 kernel that, at EL1, installs a full EL1
# exception vector table (VBAR_EL1; EL0 sync -> syscall dispatch), builds a confined EL0 address
# space (kernel 2 MiB blocks EL1-only + UART Device + user code/stack EL0 pages via
# kernel/arch/aarch64/paging.mc), enables the MMU, and `eret`s into EL0. The EL0 program does
# SYS_WRITE(valid "HELLO-FROM-EL0"), SYS_WRITE(bad ptr -> -EFAULT via a SOFTWARE page-table walk,
# no data abort), SYS_WRITE("EFAULT-OK") iff the bad call returned x0<0, then SYS_EXIT. Boots under
# qemu-system-aarch64 'virt'; reports over the PL011 UART; the harness asserts HELLO-FROM-EL0 AND
# EFAULT-OK AND USER-EXIT.
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"; LLD="${LLD:-ld.lld}"; LLC="${LLC:-llc}"; QEMU="${QEMU:-qemu-system-aarch64}"
ARCH="$HERE/kernel/arch/aarch64"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-arm-user-test" || echo "arm-user-test")
skip(){ echo "SKIP: $TEST_NAME ($1)"; exit 0; }
command -v "$CLANG" >/dev/null 2>&1 || skip "no clang"
command -v "$LLD" >/dev/null 2>&1 || skip "no ld.lld"
command -v "$QEMU" >/dev/null 2>&1 || skip "no qemu-system-aarch64"
if [ "$BACKEND" = llvm ]; then command -v "$LLC" >/dev/null 2>&1 || skip "no llc"; fi
"$CLANG" --print-targets 2>/dev/null | grep -q aarch64 || skip "clang has no aarch64 target"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CFLAGS=(--target=aarch64-unknown-elf -ffreestanding -nostdlib -fno-pic -mgeneral-regs-only -O1 -Wall -Wextra -Wno-unused-parameter -Wno-unused-function)
case "$BACKEND" in
    c)
        "$MCC" emit-c "$HERE/tests/arm/user_arm_demo.mc" >"$WORK/user.c"
        "$CLANG" "${CFLAGS[@]}" -Wno-switch-bool -c "$WORK/user.c" -o "$WORK/user.o"
        ;;
    llvm)
        MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/tests/arm/user_arm_demo.mc" -o "$WORK/user.o" \
            -mtriple=aarch64-unknown-elf \
            -relocation-model=static \
            -code-model=small
        "$CLANG" "${CFLAGS[@]}" -c "$HERE/kernel/arch/riscv64/llvm_kernel_support.c" -o "$WORK/llvm-support.o"
        ;;
    *)
        echo "unknown kernel backend: $BACKEND" >&2
        exit 2
        ;;
esac
"$CLANG" "${CFLAGS[@]}" -c "$ARCH/user_runtime.c" -o "$WORK/user_runtime.o"
SUPPORT_OBJ=$([ "$BACKEND" = llvm ] && printf '%s' "$WORK/llvm-support.o" || true)
"$LLD" -T "$HERE/tests/arm/aarch64-user.ld" "$WORK/user_runtime.o" "$WORK/user.o" $SUPPORT_OBJ -o "$WORK/k.elf"
OUT="$(timeout 30 "$QEMU" -machine virt -cpu cortex-a72 -nographic -kernel "$WORK/k.elf" 2>/dev/null || true)"
echo "--- aarch64 USER kernel UART ---"; printf '%s\n' "$OUT" | grep -aE "boot|CurrentEL|VBAR|MAIR|program assembled|address space|ttbr0|CONFINED|LEAK|MMU|entering EL0|HELLO-FROM-EL0|EFAULT-OK|USER-EXIT|ARM64-USER-BAD|BAD-SYSCALL"
echo "--------------------------------"
if printf '%s' "$OUT" | grep -qa "HELLO-FROM-EL0" \
   && printf '%s' "$OUT" | grep -qa "EFAULT-OK" \
   && printf '%s' "$OUT" | grep -qa "USER-EXIT"; then
    echo "PASS: $TEST_NAME — $BACKEND backend: an EL0 program runs, SYS_WRITE prints via the kernel, a bad user pointer is rejected -EFAULT by a software page-table walk (no data abort), and the program SYS_EXITs cleanly"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected HELLO-FROM-EL0 AND EFAULT-OK AND USER-EXIT in UART output"; exit 1
