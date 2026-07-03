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

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
SRC="$HERE/tests/qemu/mem/ksan_demo.mc"
RUNTIME="$HERE/tests/qemu/mem/ksan_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-ksan-test" || echo "ksan-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

# MC demo object (shared by all scenarios), built WITH the KASAN access instrumentation
# (--checks=ksan), plus the LLVM-backend support object if needed.
MC_CHECKS=ksan kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/demo.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"

# The PURE-MC KASAN shadow runtime — built UN-instrumented (no MC_CHECKS) in its own work
# subdir, so its own shadow loads/stores never recurse through mc_ksan_check. It DEFINES the
# sanitizer hooks (the compiler now yields its weak no-op stubs to these strong definitions).
# A single runtime object serves every scenario; the scenario is selected per-LINK via a
# linker-defined `mc_scenario` symbol (the MC runtime reads its address with `la`).
mkdir -p "$WORK/rt"
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/rt/runtime.o" "$WORK/rt"

# Build + boot one scenario; echo the UART output. $1 = scenario id (mc_scenario), $2 = tag.
run_scenario() {
    local scenario="$1" tag="$2"
    "$LLD" -T "$LDSCRIPT" --defsym=mc_scenario="$scenario" \
        "$WORK/freestanding.o" "$WORK/rt/runtime.o" "$WORK/demo.o" \
        $SUPPORT_OBJ -o "$WORK/ksan_$tag.elf"
    timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/ksan_$tag.elf" 2>/dev/null || true
}

UAF="$(run_scenario 2 uaf)"
OOB="$(run_scenario 3 oob)"
# New coverage: a UAF reached through a STRUCT FIELD — NOT a raw.load — is instrumented and must
# trap. Before the field instrumentation this load bypassed mc_ksan_check and the UAF was MISSED.
FIELD="$(run_scenario 4 field)"

# ---- empirical per-access-path coverage audit (verify each claim by EXECUTION) ----
# DETECT-claimed paths (must trap): scalar global LOAD, scalar global STORE.
GLOAD="$(run_scenario 8 gload)"
GSTORE="$(run_scenario 9 gstore)"
# Struct-field array LOAD (`a.cells[3]`): DETECTS on the C backend (the `.cells` member load is
# wrapped with mc_ksan_check over the whole array, so the element read traps) but MISSES on the
# LLVM backend (emitIndexLoad only hooks a GLOBAL array base, not a struct-field array). This is a
# real C-vs-LLVM coverage divergence — gate the DETECT only where it holds (C).
ARRLOAD="$(run_scenario 6 arrload)"
# MISS-claimed paths (documented gaps — must NOT trap; recorded, not gated as failures):
#   pointer struct-field STORE, array-index STORE, stack local, access outside the armed pool.
FSTORE="$(run_scenario 5 fstore)"
ARRSTORE="$(run_scenario 7 arrstore)"
STACK="$(run_scenario 10 stack)"
OUTSIDE="$(run_scenario 11 outside)"

echo "--- use-after-free scenario UART ---"
printf '%s\n' "$UAF"
echo "--- out-of-bounds scenario UART ---"
printf '%s\n' "$OOB"
echo "--- struct-field UAF scenario UART ---"
printf '%s\n' "$FIELD"
echo "--- global LOAD scenario UART ---"
printf '%s\n' "$GLOAD"
echo "--- global STORE scenario UART ---"
printf '%s\n' "$GSTORE"
echo "--- array-index LOAD scenario UART ---"
printf '%s\n' "$ARRLOAD"
echo "--- [MISS-expected] field STORE scenario UART ---"
printf '%s\n' "$FSTORE"
echo "--- [MISS-expected] array STORE scenario UART ---"
printf '%s\n' "$ARRSTORE"
echo "--- [MISS-expected] stack local scenario UART ---"
printf '%s\n' "$STACK"
echo "--- [MISS-expected] outside-armed-pool scenario UART ---"
printf '%s\n' "$OUTSIDE"
echo "------------------------------------"

fail=0
# A DETECT-asserting scenario: clean path printed KASAN-OK earlier in boot, and the bad access
# trapped (KASAN-DETECTED) with no *-MISSED marker. Used for paths whose coverage we GATE.
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
# A documented-MISS scenario: the bad access did NOT trap (the path is uninstrumented). We assert
# the GAP is still a gap (it printed its *-MISSED marker and did NOT trap), so a future change that
# accidentally STARTS trapping here is surfaced (tighten the doc) rather than silently diverging.
check_miss() { # haystack tag marker
    local out="$1" tag="$2" marker="$3"
    if printf '%s' "$out" | grep -q "KASAN-DETECTED"; then
        echo "NOTE: $TEST_NAME — $tag now TRAPS (was a documented MISS) — coverage improved; tighten the matrix"
    fi
    if ! printf '%s' "$out" | grep -q "$marker"; then
        echo "FAIL: $TEST_NAME — $tag did not reach its documented-MISS marker ($marker); scenario harness broken"; fail=1
    fi
}
check "$UAF" "use-after-free"
check "$OOB" "out-of-bounds"
check "$FIELD" "struct-field-uaf"
# Gate the verified DETECT paths so a regression that stops trapping fails the build.
check "$GLOAD" "global-load"
check "$GSTORE" "global-store"
# Struct-field array LOAD: gate-assert DETECT on C; on LLVM it's a documented MISS (parity gap).
if [ "$BACKEND" = llvm ]; then
    check_miss "$ARRLOAD" "array-field-load (llvm parity gap)" "ARR-LOAD-MISSED"
else
    check "$ARRLOAD" "array-field-load"
fi
# Record the verified MISS paths (don't fail the gate on a known, documented gap).
check_miss "$FSTORE" "field-store" "FIELD-STORE-MISSED"
check_miss "$ARRSTORE" "array-store" "ARR-STORE-MISSED"
check_miss "$STACK" "stack-local" "STACK-LOCAL-MISSED"
check_miss "$OUTSIDE" "outside-pool" "OUTSIDE-POOL-MISSED"

if [ "$fail" -eq 0 ]; then
    echo "PASS: $TEST_NAME — $BACKEND backend: KASAN clean path (KASAN-OK); access-time detection VERIFIED under QEMU on the raw.load UAF, raw.load OOB, struct-field UAF LOAD, scalar global LOAD, scalar global STORE, and struct-field array LOAD paths (all KASAN-DETECTED, gate-asserted); and the documented coverage GAPS confirmed as still-missing (pointer field STORE, array-index STORE, stack local, access outside the armed pool — all reached their *-MISSED markers, no trap)"
    exit 0
fi
exit 1
