#!/usr/bin/env bash
# D2.1 hardening: KASAN-style shadow-memory access-time UAF/OOB detection under QEMU.
#
# Lowers tests/qemu/mem/ksan_demo.mc through the selected backend WITH the KASAN profile
# (`--checks=ksan`, via MC_CHECKS=ksan), so every raw.load/raw.store in the demo is wrapped
# by the compiler with `mc_ksan_check(addr, size)`. Links it with the bare M-mode KASAN
# shadow runtime (kernel/arch/riscv64/ksan_runtime.c) into a riscv64 image and boots it
# under QEMU in two scenarios:
#   1. use-after-free : clean alloc/use/free prints KASAN-OK, then a REAL read of the freed
#                       pointer hits a poisoned shadow byte -> mc_ksan_check traps -> DETECTED
#   2. out-of-bounds  : clean path prints KASAN-OK, then a read one past the user region
#                       (a poisoned trailing redzone) traps in mc_ksan_check -> DETECTED
#
# This is strictly finer than D2.4 (redzone-test.sh): D2.4 catches a redzone clobber on
# FREE; KASAN catches a use-after-free / OOB on the ACCESS itself, before any reuse, via a
# real shadow lookup on the exact dereferenced address.
#
# PASS requires, in BOTH scenarios, KASAN-OK (clean path) AND KASAN-DETECTED (the shadow
# check actually fired on a real poisoned access) AND no *-MISSED line.
#
# Usage: tools/mem/ksan-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/mem/ksan_demo.mc"
RUNTIME="$HERE/kernel/arch/riscv64/ksan_runtime.c"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-ksan-test" || echo "ksan-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

# MC object (shared by both scenarios), built with the KASAN access instrumentation, plus
# the LLVM-backend support object if needed.
MC_CHECKS=ksan kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/demo.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"

# Build + boot one scenario; echo the UART output. $1 = extra cflag macro, $2 = tag.
run_scenario() {
    local macro="$1" tag="$2"
    "$CLANG" "${CFLAGS[@]}" ${macro:+"$macro"} -c "$RUNTIME" -o "$WORK/runtime_$tag.o"
    "$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/runtime_$tag.o" "$WORK/demo.o" \
        $SUPPORT_OBJ -o "$WORK/ksan_$tag.elf"
    timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/ksan_$tag.elf" 2>/dev/null || true
}

UAF="$(run_scenario "" uaf)"
OOB="$(run_scenario "-DOOB_SCENARIO=1" oob)"
# New coverage (this change): a UAF reached through a STRUCT FIELD — NOT a raw.load — is now
# instrumented and must trap. Before the field instrumentation this load bypassed mc_ksan_check
# entirely and the UAF was silently MISSED.
FIELD="$(run_scenario "-DFIELD_SCENARIO=1" field)"

echo "--- use-after-free scenario UART ---"
printf '%s\n' "$UAF"
echo "--- out-of-bounds scenario UART ---"
printf '%s\n' "$OOB"
echo "--- struct-field UAF scenario UART ---"
printf '%s\n' "$FIELD"
echo "------------------------------------"

fail=0
check() { # haystack tag
    local out="$1" tag="$2"
    if ! printf '%s' "$out" | grep -q "KASAN-OK"; then
        echo "FAIL: $TEST_NAME — $tag missing clean-path KASAN-OK"; fail=1
    fi
    if ! printf '%s' "$out" | grep -q "KASAN-DETECTED"; then
        echo "FAIL: $TEST_NAME — $tag did NOT detect the poisoned access (no KASAN-DETECTED)"; fail=1
    fi
    if printf '%s' "$out" | grep -q "MISSED"; then
        echo "FAIL: $TEST_NAME — $tag shadow check failed to fire (got *-MISSED)"; fail=1
    fi
}
check "$UAF" "use-after-free"
check "$OOB" "out-of-bounds"
check "$FIELD" "struct-field-uaf"

if [ "$fail" -eq 0 ]; then
    echo "PASS: $TEST_NAME — $BACKEND backend: KASAN heap clean path (KASAN-OK), a REAL read of freed memory caught at access time by the shadow check (KASAN-DETECTED), a read past the allocation caught by the shadow (KASAN-DETECTED), AND a use-after-free reached through a STRUCT FIELD (not raw.load) now caught by the extended instrumentation (KASAN-DETECTED) under QEMU"
    exit 0
fi
exit 1
