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
RUNTIME="$HERE/tests/qemu/mem/redzone_runtime.mc"
SCEN_OVERFLOW="$HERE/tests/qemu/mem/redzone_scenario_overflow.mc"
SCEN_CANARY="$HERE/tests/qemu/mem/redzone_scenario_canary.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-redzone-test" || echo "redzone-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

# MC demo object + the shared MC runtime object (common boot/trap/clean-path, builds
# once) + per-scenario MC objects + the LLVM-backend support object if needed. Each
# MC object is built in its own $WORK subdir.
kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/demo.o" "$WORK"
mkdir -p "$WORK/rt"
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK/rt"
mkdir -p "$WORK/ovf"
kernel_boot_compile_mc_object "$BACKEND" "$SCEN_OVERFLOW" "$WORK/scen_overflow.o" "$WORK/ovf"
mkdir -p "$WORK/can"
kernel_boot_compile_mc_object "$BACKEND" "$SCEN_CANARY" "$WORK/scen_canary.o" "$WORK/can"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"

# Build + boot one scenario; echo the UART output. $1 = scenario object, $2 = tag.
run_scenario() {
    local scen="$1" tag="$2"
    "$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/runtime.o" "$scen" "$WORK/demo.o" \
        $SUPPORT_OBJ -o "$WORK/redzone_$tag.elf"
    timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/redzone_$tag.elf" 2>/dev/null || true
}

OVF="$(run_scenario "$WORK/scen_overflow.o" overflow)"
CAN="$(run_scenario "$WORK/scen_canary.o" canary)"

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
