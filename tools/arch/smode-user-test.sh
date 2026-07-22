#!/usr/bin/env bash
# M2 "RISC-V S-mode user hello": under REAL OpenSBI (QEMU default firmware, S-mode),
# a tiny U-mode app calls SYS_WRITE and the kernel prints it; a SYS_WRITE from a BAD
# user pointer returns -EFAULT (the kernel validates via copy_from_user_pt and never
# dereferences it, so it does NOT crash); the app detects a0<0, emits "EFAULT-OK",
# then SYS_EXITs cleanly.
#
# Usage: tools/arch/smode-user-test.sh <path-to-mcc> [c|llvm]
# Skips (exit 0) when the riscv toolchain or QEMU is unavailable.
set -euo pipefail
MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"; LLD="${LLD:-ld.lld}"; LLC="${LLC:-llc}"; QEMU="${QEMU:-qemu-system-riscv64}"
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-smode-user-test" || echo "smode-user-test")
kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64 -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra -Wno-unused-parameter -Wno-unused-function -fno-builtin)
kernel_boot_compile_mc_object "$BACKEND" "$HERE/tests/qemu/arch/smode_user_demo.mc" "$WORK/mc.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$HERE/tests/qemu/sbi.ld" "$WORK/freestanding.o" "$WORK/mc.o" $SUPPORT_OBJ -o "$WORK/k.elf"
# NOTE: no '-bios none' -> QEMU loads OpenSBI (the real firmware) which boots our kernel in S-mode.
OUT="$(timeout 30 "$QEMU" -machine virt -m 256M -nographic -kernel "$WORK/k.elf" 2>/dev/null || true)"
echo "--- OpenSBI + kernel output ---"; printf '%s\n' "$OUT" | tail -16; echo "-------------------------------"
# PASS requires ALL of:
#   - OpenSBI actually ran (banner) — proves S-mode under the real firmware;
#   - the U-mode app's valid SYS_WRITE printed "HELLO-FROM-UMODE";
#   - the BAD-pointer SYS_WRITE returned negative (-EFAULT) AND the kernel survived to
#     run the app's follow-up, which emitted "EFAULT-OK" only because a0<0;
#   - the app exited cleanly from U-mode ("USER-EXIT from U").
if printf '%s' "$OUT" | grep -qi "OpenSBI" \
   && printf '%s' "$OUT" | grep -q "HELLO-FROM-UMODE" \
   && printf '%s' "$OUT" | grep -q "EFAULT-OK" \
   && printf '%s' "$OUT" | grep -q "USER-EXIT from U"; then
    echo "PASS: $TEST_NAME — $BACKEND backend ran a U-mode app under REAL OpenSBI in S-mode: valid SYS_WRITE printed, bad user pointer returned -EFAULT via copy_from_user_pt (kernel survived), app exited cleanly"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected OpenSBI banner + HELLO-FROM-UMODE + EFAULT-OK + USER-EXIT from U"; exit 1
