#!/usr/bin/env bash
# D2.4 hardening: heap-redzone + stack-canary runtime detection under QEMU.
#
# Lowers tests/qemu/mem/redzone_demo.mc through the selected backend, links it with
# the bare M-mode redzone runtime into a riscv64 image, and boots it under QEMU in
# two scenarios:
#   1. heap overflow : clean alloc/use/free prints D2.4-OK, then a REAL one-past-the-
#                      end write into the trailing redzone is caught on free -> DETECTED
#   2. stack canary  : clean path prints D2.4-OK, then a smashed stack guard is caught
#                      by guard_check -> DETECTED
#
# PASS requires, in BOTH scenarios, D2.4-OK (clean path) AND DETECTED (the redzone /
# canary check actually fired on real corruption) AND no *-MISSED line.
#
# Usage: tools/mem/redzone-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/mem/redzone_demo.mc"
RUNTIME="$HERE/kernel/arch/riscv64/redzone_runtime.c"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-redzone-test" || echo "redzone-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

# MC object (shared by both scenarios) + the LLVM-backend support object if needed.
kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/demo.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"

# Build + boot one scenario; echo the UART output. $1 = extra cflag macro, $2 = tag.
run_scenario() {
    local macro="$1" tag="$2"
    "$CLANG" "${CFLAGS[@]}" ${macro:+"$macro"} -c "$RUNTIME" -o "$WORK/runtime_$tag.o"
    "$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/runtime_$tag.o" "$WORK/demo.o" \
        $SUPPORT_OBJ -o "$WORK/redzone_$tag.elf"
    timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/redzone_$tag.elf" 2>/dev/null || true
}

OVF="$(run_scenario "" overflow)"
CAN="$(run_scenario "-DCANARY_SCENARIO=1" canary)"

echo "--- heap-overflow scenario UART ---"
printf '%s\n' "$OVF"
echo "--- stack-canary scenario UART ---"
printf '%s\n' "$CAN"
echo "-----------------------------------"

fail=0
check() { # haystack tag
    local out="$1" tag="$2"
    if ! printf '%s' "$out" | grep -q "D2.4-OK"; then
        echo "FAIL: $TEST_NAME — $tag missing clean-path D2.4-OK"; fail=1
    fi
    if ! printf '%s' "$out" | grep -q "DETECTED"; then
        echo "FAIL: $TEST_NAME — $tag did NOT detect the corruption (no DETECTED)"; fail=1
    fi
    if printf '%s' "$out" | grep -q "MISSED"; then
        echo "FAIL: $TEST_NAME — $tag check failed to fire (got *-MISSED)"; fail=1
    fi
}
check "$OVF" "heap-overflow"
check "$CAN" "stack-canary"

if [ "$fail" -eq 0 ]; then
    echo "PASS: $TEST_NAME — $BACKEND backend: redzoned heap clean path (D2.4-OK), real heap overflow into the trailing redzone caught on free (DETECTED), and a smashed stack canary caught by guard_check (DETECTED) under QEMU"
    exit 0
fi
exit 1
