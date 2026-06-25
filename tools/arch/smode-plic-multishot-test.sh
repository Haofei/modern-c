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
# alignment); both backends now pass. See docs/platform-portability-plan.md §12 "Do now" item 2.
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
# Used ONLY for the optional static vector-alignment assertion below. Must be riscv-capable
# (a host GNU `objdump` typically cannot disassemble riscv64); when it is unavailable the
# assertion is skipped but the QEMU behavioral proof — which itself catches a misaligned
# vector (the reset-loop hangs into the timeout) — still runs.
OBJDUMP="${OBJDUMP:-llvm-objdump}"

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

# Optional static assertion: the trap vector must be 4-byte aligned (the whole point of the
# fix) — a misaligned stvec base sets a reserved MODE and traps to the wrong PC. Only run it
# when a riscv-capable objdump is available; the QEMU run below is the load-bearing proof.
# (`... | head -n1` closes the pipe early; under `set -o pipefail` the upstream SIGPIPE would
# abort the script, so the extraction is isolated with `|| true`.)
VADDR=""
ALIGN_NOTE="alignment asserted via QEMU"
if command -v "$OBJDUMP" >/dev/null 2>&1; then
    VADDR="$("$OBJDUMP" -d "$WORK/plic.elf" 2>/dev/null | sed -n 's/^0*\([0-9a-f]*\) <s_trap_vector>:.*/\1/p' | head -n1 || true)"
    if [ -n "$VADDR" ] && [ $(( 0x$VADDR & 3 )) -ne 0 ]; then
        echo "FAIL: $TEST_NAME — s_trap_vector at 0x$VADDR is NOT 4-byte aligned (stvec MODE would be reserved)"
        exit 1
    fi
    [ -n "$VADDR" ] && ALIGN_NOTE="vector 4-byte aligned @0x$VADDR"
else
    echo "note: $OBJDUMP unavailable — skipping the static vector-alignment assertion (QEMU still proves delivery)"
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
    echo "PASS: $TEST_NAME — $BACKEND backend flat S-mode kernel took 3 REAL re-armed S-mode EXTERNAL interrupts (PLIC S-mode context 1; UART THRE line 10; claim/mask/complete/re-arm; $ALIGN_NOTE; wfi-parked) under REAL OpenSBI"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected OpenSBI banner + SMODE-PLIC-OK + IRQS==3 (got IRQS='${IRQS:-<none>}')"
exit 1
