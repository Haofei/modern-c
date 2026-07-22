#!/usr/bin/env bash
# Item (1): REAL S-mode EXTERNAL interrupt delivery through the PLIC under OpenSBI —
# the companion to the S-mode timer proof. Where smode-timer-test proves the S-mode
# *timer* interrupt, this proves an S-mode *external device* interrupt routed via the
# PLIC (the path that lets virtio/net be interrupt-driven instead of polled).
#
# Builds the flat S-mode kernel (PURE MC, tests/qemu/arch/smode_plic_demo.mc: `_start`
# and the trap vector are `#[naked]` MC; CSR/PLIC/UART access is MC inline asm + raw
# MMIO) with the OpenSBI payload linker script (sbi.ld) and runs it WITHOUT
# `-bios none`, so QEMU loads REAL OpenSBI which boots our kernel in S-mode at
# 0x80200000. The kernel programs the PLIC S-mode context (context 1), enables the
# 16550 UART THRE interrupt as a deterministic source, and claims+completes the
# external interrupt in its trap handler — parking in `wfi`. PASS requires the OpenSBI
# banner + `SMODE-PLIC-OK` + `IRQS` >= 1 (a real S-mode external interrupt delivered
# by the PLIC and serviced; the demo is single-shot — see smode_plic_demo.mc header).
#
# Usage: tools/arch/smode-plic-test.sh <path-to-mcc> [c|llvm]
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
RUNTIME="$HERE/tests/qemu/arch/smode_plic_demo.mc"
LDSCRIPT="$HERE/tests/qemu/sbi.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-smode-plic-test" || echo "smode-plic-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/runtime.o" $SUPPORT_OBJ -o "$WORK/plic.elf"

# NO '-bios none' -> QEMU loads OpenSBI which boots our kernel in S-mode. `wfi`
# parks the hart between interrupts; a no-delivery bug hangs into this timeout
# instead of printing SMODE-PLIC-OK.
OUT="$(timeout 30 "$QEMU" -machine virt -m 256M -nographic \
        -kernel "$WORK/plic.elf" 2>/dev/null || true)"

echo "--- OpenSBI + S-mode PLIC output ---"
printf '%s\n' "$OUT"
echo "------------------------------------"

IRQS="$(printf '%s' "$OUT" | sed -n 's/.*SMODE-PLIC IRQS=\([0-9][0-9]*\).*/\1/p' | tail -n1)"
if printf '%s' "$OUT" | grep -qi "OpenSBI" \
   && printf '%s' "$OUT" | grep -q "SMODE-PLIC-OK" \
   && [ -n "$IRQS" ] && [ "$IRQS" -ge 1 ]; then
    echo "PASS: $TEST_NAME — $BACKEND backend flat S-mode kernel took $IRQS REAL S-mode EXTERNAL interrupt (PLIC S-mode context 1; UART THRE source line 10; sie.SEIE+sstatus.SIE; claim/complete; wfi-parked) under REAL OpenSBI in S-mode"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected OpenSBI banner + SMODE-PLIC-OK + IRQS>=1 (got IRQS='${IRQS:-<none>}')"
exit 1
