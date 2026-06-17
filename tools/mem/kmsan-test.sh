#!/usr/bin/env bash
# D2.2 hardening: KMSAN-style uninitialized-HEAP-use detection under QEMU, built on the D2.1
# ksan shadow.
#
# Lowers tests/qemu/mem/kmsan_demo.mc through the selected backend WITH the KMSAN profile
# (`--checks=msan`, via MC_CHECKS=msan), so the compiler wraps every raw.store with
# `mc_ksan_store(addr,size)` (marks bytes initialized) and every raw.load with
# `mc_ksan_check(addr,size)` (traps on a still-uninit, or freed/redzone, byte). Links it with
# the bare M-mode KMSAN shadow runtime (kernel/arch/riscv64/kmsan_runtime.c), which hands out
# allocations marked UNINIT, into a riscv64 image and boots it under QEMU in two scenarios:
#   1. clean  : alloc, WRITE every byte (each store marks it initialized), then READ -> all
#               initialized shadow, nothing traps -> KMSAN-OK
#   2. uninit : alloc, then READ a never-written byte -> its shadow is still UNINIT ->
#               mc_ksan_check traps before the load -> KMSAN-DETECTED
#
# This is the dynamic, through-pointer complement to S0.1's static use-of-uninitialized check.
#
# PASS requires KMSAN-OK (clean path) AND KMSAN-DETECTED (the init-state shadow check actually
# fired on a real uninitialized read) AND no *-MISSED line.
#
# Usage: tools/mem/kmsan-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/mem/kmsan_demo.mc"
RUNTIME="$HERE/kernel/arch/riscv64/kmsan_runtime.c"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-kmsan-test" || echo "kmsan-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

# MC object (shared by both scenarios), built with the KMSAN init-tracking instrumentation,
# plus the LLVM-backend support object if needed.
MC_CHECKS=msan kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/demo.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"

# Build + boot one scenario; echo the UART output. $1 = extra cflag macro, $2 = tag.
run_scenario() {
    local macro="$1" tag="$2"
    "$CLANG" "${CFLAGS[@]}" ${macro:+"$macro"} -c "$RUNTIME" -o "$WORK/runtime_$tag.o"
    "$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/runtime_$tag.o" "$WORK/demo.o" \
        $SUPPORT_OBJ -o "$WORK/kmsan_$tag.elf"
    timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/kmsan_$tag.elf" 2>/dev/null || true
}

CLEAN="$(run_scenario "" clean)"
UNINIT="$(run_scenario "-DUNINIT_SCENARIO=1" uninit)"
# ---- empirical per-access-path coverage audit (verify each claim by EXECUTION) ----
# DETECT-claimed (must trap): pointer struct-field LOAD of UNINIT, scalar global LOAD of poison.
FLOAD="$(run_scenario "-DFIELD_LOAD_SCENARIO=1" fload)"
GLOAD="$(run_scenario "-DGLOBAL_LOAD_SCENARIO=1" gload)"
# MISS-claimed (documented gap — recorded, not gated): freed-WRITE under msan (the store path
# uses mc_ksan_store only, no mc_ksan_check, so a write to freed/poisoned memory is not caught).
FWRITE="$(run_scenario "-DFREED_WRITE_SCENARIO=1" fwrite)"

echo "--- clean (write-before-read) scenario UART ---"
printf '%s\n' "$CLEAN"
echo "--- uninitialized-read scenario UART ---"
printf '%s\n' "$UNINIT"
echo "--- struct-field UNINIT LOAD scenario UART ---"
printf '%s\n' "$FLOAD"
echo "--- global poisoned LOAD scenario UART ---"
printf '%s\n' "$GLOAD"
echo "--- [MISS-expected] freed-write-under-msan scenario UART ---"
printf '%s\n' "$FWRITE"
echo "-----------------------------------------------"

fail=0
if ! printf '%s' "$CLEAN" | grep -q "KMSAN-OK"; then
    echo "FAIL: $TEST_NAME — clean path missing KMSAN-OK"; fail=1
fi
if printf '%s' "$CLEAN" | grep -q "KMSAN-DETECTED"; then
    echo "FAIL: $TEST_NAME — clean path trapped (false positive on initialized memory)"; fail=1
fi
# DETECT cases — gate-assert that each bad access actually trapped.
detect() { # haystack tag
    local out="$1" tag="$2"
    if ! printf '%s' "$out" | grep -q "KMSAN-DETECTED"; then
        echo "FAIL: $TEST_NAME — $tag NOT detected (no KMSAN-DETECTED)"; fail=1
    fi
    if printf '%s' "$out" | grep -q "MISSED"; then
        echo "FAIL: $TEST_NAME — $tag shadow check failed to fire (got *-MISSED)"; fail=1
    fi
}
detect "$UNINIT" "uninitialized read"
detect "$FLOAD" "struct-field UNINIT load"
detect "$GLOAD" "global poisoned load"
# Documented MISS — confirm the freed-write under msan is NOT caught (reached its marker).
if printf '%s' "$FWRITE" | grep -q "KMSAN-DETECTED"; then
    echo "NOTE: $TEST_NAME — freed-write-under-msan now TRAPS (was a documented MISS) — coverage improved"
fi
if ! printf '%s' "$FWRITE" | grep -q "FREED-WRITE-MISSED"; then
    echo "FAIL: $TEST_NAME — freed-write scenario did not reach its documented-MISS marker; harness broken"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "PASS: $TEST_NAME — $BACKEND backend: write-before-read clean path (KMSAN-OK); uninitialized-use detection VERIFIED under QEMU on the raw.load, struct-field LOAD, and scalar global LOAD paths (KMSAN-DETECTED, gate-asserted); and the documented gap confirmed — a freed-WRITE under msan is NOT caught (the store path marks-init without a pre-check), reaching FREED-WRITE-MISSED with no trap"
    exit 0
fi
exit 1
