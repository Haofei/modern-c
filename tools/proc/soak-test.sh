#!/usr/bin/env bash
# Runnable SOAK test.
#
# Lowers the soak workload (tests/qemu/proc/soak_demo.mc — spawn/charge/supervise/reclaim/reap over
# thousands of iterations in a single boot) through the selected backend, links it with the shared
# M-mode bring-up runtime into a bare riscv64 image, and runs it under QEMU. Where the unit gates
# (proc-supervisor-test, ledger-test) each prove one primitive once, this proves that MANY
# repetitions of the full lifecycle churn leave no residue: every spawned process is reclaimed and
# reaped, every ledger charge is released, and no monotonic counter wraps into a checked-arithmetic
# trap. SOAK-OK is printed only when every per-iteration invariant held and the final baseline
# (zero live agents, zero zombies, ledger used==0, bounded slot table) is intact.
#
# The iteration count (ITERS in soak_demo.mc) is tuned high enough to be meaningful (12000 spawns +
# reclaims) yet bounded so the run finishes well inside the QEMU timeout. Deterministic: no RNG, no
# wall-clock — the same workload runs identically every boot.
#
# Usage: tools/proc/soak-test.sh <path-to-mcc> [c|llvm]
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
SRC="$HERE/tests/qemu/proc/soak_demo.mc"
RUNTIME="$HERE/tests/qemu/proc/soak_runtime.mc"
SHARED="$HERE/tests/qemu/proc/context_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-soak-test" || echo "soak-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/thread.o" "$WORK"
mkdir -p "$WORK/rt"
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK/rt"
kernel_boot_compile_c_object "$SHARED" "$WORK/shared.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/shared.o" "$WORK/runtime.o" "$WORK/thread.o" $SUPPORT_OBJ -o "$WORK/thread.elf"

OUT="$(timeout 60 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/thread.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

# SOAK-OK appears only when soak_run returned 1 — i.e. every per-iteration leak/overflow invariant
# held across all iterations and the final baseline was intact. SOAK-FAIL means an invariant broke.
if printf '%s' "$OUT" | grep -q "SOAK-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend soak: thousands of spawn/charge/supervise/reclaim/reap cycles in one boot returned to baseline with no leak and no counter-overflow trap under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected SOAK-OK in kernel output"
exit 1
