#!/usr/bin/env bash
# Item (4): REAL S-mode timer-interrupt delivery under OpenSBI — the RISC-V
# analogue of the x86 X4 LAPIC-timer proof.
#
# Builds the flat S-mode kernel — now PURE MC (tests/qemu/arch/smode_timer_demo.mc,
# NO C: `_start` and the trap vector are `#[naked]` MC; the SBI seam, CSR access,
# rdtime and wfi are MC inline asm) — with the OpenSBI payload linker script
# (sbi.ld) and runs it WITHOUT `-bios none`, so QEMU loads the REAL OpenSBI
# firmware which boots our kernel in S-mode at 0x80200000. The kernel programs the
# SBI TIME extension, enables S-mode timer interrupts (sie.STIE + sstatus.SIE), and
# counts ticks in its trap handler — re-arming each time and parking in `wfi`
# between ticks. PASS requires the OpenSBI banner + `SMODE-TIMER-OK` + `TICKS` >= 3
# (3 real S-mode timer interrupts delivered by the SBI timer and serviced).
#
# Usage: tools/arch/smode-timer-test.sh <path-to-mcc> [c|llvm]
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
# The flat S-mode timer kernel is now PURE MC — no .c runtime, no boot.S: `_start`
# and the trap vector are `#[naked]` MC functions, and the SBI/CSR seam is MC
# inline asm.
RUNTIME="$HERE/tests/qemu/arch/smode_timer_demo.mc"
LDSCRIPT="$HERE/tests/qemu/sbi.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-smode-timer-test" || echo "smode-timer-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-function -fno-builtin)

# Compile the PURE-MC kernel on the selected backend (c: emit-c -> clang; llvm:
# emit-llvm -> llc). The LLVM object references the safety-check trap symbols
# (mc_trap_*) that llvm_kernel_support.c provides; the C object inlines them.
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/runtime.o" $SUPPORT_OBJ -o "$WORK/timer.elf"

# NO '-bios none' -> QEMU loads OpenSBI (the real firmware) which boots our
# kernel in S-mode. `wfi` parks the hart between ticks; a no-delivery bug would
# hang into this timeout instead of printing SMODE-TIMER-OK.
OUT="$(timeout 30 "$QEMU" -machine virt -m 256M -nographic \
        -kernel "$WORK/timer.elf" 2>/dev/null || true)"

echo "--- OpenSBI + S-mode timer output ---"
printf '%s\n' "$OUT"
echo "-------------------------------------"

TICKS="$(printf '%s' "$OUT" | sed -n 's/.*SMODE-TIMER TICKS=\([0-9][0-9]*\).*/\1/p' | tail -n1)"
if printf '%s' "$OUT" | grep -qi "OpenSBI" \
   && printf '%s' "$OUT" | grep -q "SMODE-TIMER-OK" \
   && [ -n "$TICKS" ] && [ "$TICKS" -ge 3 ]; then
    echo "PASS: $TEST_NAME — $BACKEND backend flat S-mode kernel took $TICKS REAL S-mode timer interrupts (SBI TIME extension; sie.STIE+sstatus.SIE; rdtime CSR; re-armed each tick; wfi-parked) under REAL OpenSBI in S-mode"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected OpenSBI banner + SMODE-TIMER-OK + TICKS>=3 (got TICKS='${TICKS:-<none>}')"
exit 1
