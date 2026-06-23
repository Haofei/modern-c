#!/usr/bin/env bash
# STEADY-STATE (re-armed) S-mode EXTERNAL interrupt delivery through the PLIC under
# OpenSBI — the multi-shot companion to smode-plic-test. Where smode-plic-test proves a
# SINGLE claimed+completed external interrupt, this re-arms the UART THRE source in the
# handler and takes 3 DISCRETE external interrupts, exercising the repeated
# trap->service->sret->re-trap path that interrupt-driven device drivers depend on.
#
# This is the regression gate for the former "C-backend S-mode async-IRQ reset": the C
# backend used to reset-loop here because the `#[naked]` trap vector could land 2-byte
# aligned, and a RISC-V `stvec` base must be 4-byte aligned (its low two bits are the MODE
# field). The fix is the `#[align(4)]` on the vector (and `#[naked]` defaulting to 4-byte
# alignment); both backends now pass. See docs/smode-irq-cbackend-reset.md.
#
# PASS requires the OpenSBI banner + `SMODE-PLIC-OK` + `IRQS` == 3.
#
# Usage: tools/arch/smode-plic-multishot-test.sh <path-to-mcc> [c|llvm]
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
RUNTIME="$HERE/tests/qemu/arch/smode_plic_multishot_demo.mc"
LDSCRIPT="$HERE/tests/qemu/sbi.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-smode-plic-multishot-test" || echo "smode-plic-multishot-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/runtime.o" -o "$WORK/plic.elf"

# Assert the trap vector is 4-byte aligned (the whole point of the fix): a misaligned
# stvec base sets a reserved MODE and traps to the wrong PC. Fail loudly if it regresses.
VADDR="$(llvm-objdump -d "$WORK/plic.elf" 2>/dev/null | sed -n 's/^0*\([0-9a-f]*\) <s_trap_vector>:.*/\1/p' | head -n1)"
if [ -n "$VADDR" ] && [ $(( 0x$VADDR & 3 )) -ne 0 ]; then
    echo "FAIL: $TEST_NAME — s_trap_vector at 0x$VADDR is NOT 4-byte aligned (stvec MODE would be reserved)"
    exit 1
fi

OUT="$(timeout 30 "$QEMU" -machine virt -m 256M -nographic \
        -kernel "$WORK/plic.elf" 2>/dev/null || true)"

echo "--- OpenSBI + S-mode PLIC multishot output ---"
printf '%s\n' "$OUT"
echo "----------------------------------------------"

IRQS="$(printf '%s' "$OUT" | sed -n 's/.*SMODE-PLIC IRQS=\([0-9][0-9]*\).*/\1/p' | tail -n1)"
if printf '%s' "$OUT" | grep -qi "OpenSBI" \
   && printf '%s' "$OUT" | grep -q "SMODE-PLIC-OK" \
   && [ -n "$IRQS" ] && [ "$IRQS" -eq 3 ]; then
    echo "PASS: $TEST_NAME — $BACKEND backend flat S-mode kernel took 3 REAL re-armed S-mode EXTERNAL interrupts (PLIC S-mode context 1; UART THRE line 10; claim/mask/complete/re-arm; vector 4-byte aligned @0x$VADDR; wfi-parked) under REAL OpenSBI"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected OpenSBI banner + SMODE-PLIC-OK + IRQS==3 (got IRQS='${IRQS:-<none>}')"
exit 1
