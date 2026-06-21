#!/usr/bin/env bash
# D2.3 hardening: KCSAN-style data-race detection under QEMU.
#
# Lowers tests/qemu/proc/csan_demo.mc through the selected backend WITH the KCSAN profile
# (`--checks=csan`, via MC_CHECKS=csan), so every UNSYNCHRONIZED raw.load/raw.store in the
# demo is wrapped by the compiler with the data-race watchpoint hooks mc_csan_read /
# mc_csan_write. Links it with the bare M-mode csan watchpoint runtime
# (kernel/arch/riscv64/csan_runtime.c) into a riscv64 image and boots it under QEMU in two
# scenarios:
#   1. RACE  : the boot thread does an UNSYNCHRONIZED access to a shared word while a
#              preempting CLINT timer IRQ performs a conflicting UNSYNCHRONIZED write to the
#              same word. The watchpoint conflict check (one side a live write watchpoint)
#              fires -> CSAN-DETECTED. (REAL asynchronous preemption; the watch window is
#              widened so a tick deterministically lands inside the racy access.)
#   2. CLEAN : the boot thread and the timer IRQ both touch a shared SYNCHRONIZED global,
#              which lowers to the mc_race_* relaxed-atomic accessors (NO watchpoint), so no
#              conflict is ever possible -> CSAN-OK.
#
# The detection is a REAL conflict check on the watchpoint table (csan_access in the
# runtime), not a scripted print: the IRQ-side hook only traps when it finds the boot
# thread's live, overlapping watchpoint with a write on at least one side.
#
# PASS requires: scenario 1 prints CSAN-DETECTED and NOT RACE-MISSED; scenario 2 prints
# CSAN-OK and NOT CSAN-DETECTED.
#
# Usage: tools/mem/kcsan-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/proc/csan_demo.mc"
RUNTIME="$HERE/tests/qemu/proc/csan_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-kcsan-test" || echo "kcsan-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

# MC demo object (shared by both scenarios), built WITH the KCSAN watchpoint instrumentation
# (--checks=csan), plus the LLVM-backend support object if needed.
MC_CHECKS=csan kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/demo.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"

# The PURE-MC KCSAN watchpoint runtime — built UN-instrumented (no MC_CHECKS) in its own work
# subdir, so its own watchpoint-table reads/writes never recurse through mc_csan_*. It DEFINES
# mc_csan_read / mc_csan_write (the compiler now yields its weak no-op stubs to these strong
# definitions). A single runtime object serves both scenarios; the scenario is selected per-LINK
# via a linker-defined `mc_scenario` symbol (the MC runtime reads its address with `la`).
mkdir -p "$WORK/rt"
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/rt/runtime.o" "$WORK/rt"

# Build + boot one scenario; echo the UART output. $1 = scenario id (mc_scenario), $2 = tag.
run_scenario() {
    local scenario="$1" tag="$2"
    "$LLD" -T "$LDSCRIPT" --defsym=mc_scenario="$scenario" \
        "$WORK/freestanding.o" "$WORK/rt/runtime.o" "$WORK/demo.o" \
        $SUPPORT_OBJ -o "$WORK/csan_$tag.elf"
    timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/csan_$tag.elf" 2>/dev/null || true
}

RACE="$(run_scenario 2 race)"
CLEAN="$(run_scenario 1 clean)"

echo "--- RACE scenario UART ---"
printf '%s\n' "$RACE"
echo "--- CLEAN scenario UART ---"
printf '%s\n' "$CLEAN"
echo "--------------------------"

fail=0
if ! printf '%s' "$RACE" | grep -q "CSAN-DETECTED"; then
    echo "FAIL: $TEST_NAME — race scenario did NOT detect the data race (no CSAN-DETECTED)"; fail=1
fi
if printf '%s' "$RACE" | grep -q "RACE-MISSED"; then
    echo "FAIL: $TEST_NAME — race scenario watchpoint check failed to fire (RACE-MISSED)"; fail=1
fi
if ! printf '%s' "$CLEAN" | grep -q "CSAN-OK"; then
    echo "FAIL: $TEST_NAME — clean scenario missing CSAN-OK"; fail=1
fi
if printf '%s' "$CLEAN" | grep -q "CSAN-DETECTED"; then
    echo "FAIL: $TEST_NAME — clean (synchronized) scenario FALSE-POSITIVED (CSAN-DETECTED)"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "PASS: $TEST_NAME — $BACKEND backend: an unsynchronized boot-thread access racing a preempting timer-IRQ access caught by the watchpoint conflict check (CSAN-DETECTED), and a properly-synchronized (mc_race_*) access clean (CSAN-OK) under QEMU"
    exit 0
fi
exit 1
