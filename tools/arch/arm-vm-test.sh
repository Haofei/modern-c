#!/usr/bin/env bash
# AArch64 paging gate: build a flat aarch64 kernel that, at EL1, builds a FRESH stage-1 4 KiB-
# granule page table (kernel/arch/aarch64/paging.mc), software-walks it, enables the MMU
# (SCTLR_EL1.M=1), and reads a translation-only test VA back — proving real VA->PA translation.
# Boots under qemu-system-aarch64 'virt'; reports over the PL011 UART; greps for ARM64-VM-OK.
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"; LLD="${LLD:-ld.lld}"; LLC="${LLC:-llc}"; QEMU="${QEMU:-qemu-system-aarch64}"
ARCH="$HERE/kernel/arch/aarch64"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-arm-vm-test" || echo "arm-vm-test")
# CI-aware skip: in CI / MC_REQUIRE_TOOLS a missing toolchain FAILS (a gate must not look green
# because qemu/clang/lld were absent); locally it still skips. Same policy as the riscv gates.
source "$HERE/tools/qemu/kernel-boot-lib.sh"
skip() { kernel_boot_skip "$TEST_NAME" "$1"; }
command -v "$CLANG" >/dev/null 2>&1 || skip "no clang"
command -v "$LLD" >/dev/null 2>&1 || skip "no ld.lld"
command -v "$QEMU" >/dev/null 2>&1 || skip "no qemu-system-aarch64"
if [ "$BACKEND" = llvm ]; then command -v "$LLC" >/dev/null 2>&1 || skip "no llc"; fi
"$CLANG" --print-targets 2>/dev/null | grep -q aarch64 || skip "clang has no aarch64 target"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# NOTE: NO -mgeneral-regs-only. The kmain is now PURE MC (tests/arm/vm_arm_runtime.mc), which
# imports the MC paging demo (vm_arm_build): ONE MC compilation unit yields both `kmain` and
# `vm_arm_build`, plus the naked `_start` (EL2->EL1 drop) and the EL1 vector table. There is no
# boot.S — the whole boot seam is MC. The LLVM backend may emit SIMD/FP for struct init/copy, so
# kmain enables CPACR_EL1.FPEN and we let the assembler use SIMD registers. The old vm_runtime.c
# is deleted.
CFLAGS=(--target=aarch64-unknown-elf -ffreestanding -nostdlib -fno-pic -O1 -Wall -Wextra -Wno-unused-parameter -Wno-unused-function)
case "$BACKEND" in
    c)
        "$MCC" emit-c "$HERE/tests/arm/vm_arm_runtime.mc" >"$WORK/vm.c"
        "$CLANG" "${CFLAGS[@]}" -Wno-switch-bool -c "$WORK/vm.c" -o "$WORK/vm.o"
        ;;
    llvm)
        MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/tests/arm/vm_arm_runtime.mc" -o "$WORK/vm.o" \
            -mtriple=aarch64-unknown-elf \
            -relocation-model=static \
            -code-model=small
        "$CLANG" "${CFLAGS[@]}" -c "$HERE/kernel/arch/riscv64/llvm_kernel_support.c" -o "$WORK/llvm-support.o"
        ;;
    *)
        echo "unknown kernel backend: $BACKEND" >&2
        exit 2
        ;;
esac
# Freestanding mem*: both backends emit memset/memcpy for aggregate init/copy. The old
# vm_runtime.c carried local copies; the pure-MC kmain links the shared arch-neutral
# freestanding object instead (-fno-builtin so the loops are not rewritten into self-calls).
"$CLANG" "${CFLAGS[@]}" -fno-builtin -c "$HERE/kernel/arch/riscv64/freestanding.c" -o "$WORK/freestanding.o"
SUPPORT_OBJ=$([ "$BACKEND" = llvm ] && printf '%s' "$WORK/llvm-support.o" || true)
"$LLD" -T "$HERE/tests/arm/aarch64-vm.ld" "$WORK/vm.o" "$WORK/freestanding.o" $SUPPORT_OBJ -o "$WORK/k.elf"
OUT="$(timeout 30 "$QEMU" -machine virt -cpu cortex-a72 -nographic -kernel "$WORK/k.elf" 2>/dev/null || true)"
echo "--- aarch64 VM kernel UART ---"; printf '%s\n' "$OUT" | grep -aE "boot|CurrentEL|VBAR|MAIR|table built|ttbr0|MMU|readback|ARM64-VM"
echo "------------------------------"
if printf '%s' "$OUT" | grep -qa "ARM64-VM-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend: aarch64 builds a fresh stage-1 4 KiB-granule page table, software-walks it, enables the MMU, and reads a translation-only VA back (real VA->PA translation)"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected 'ARM64-VM-OK' in UART output"; exit 1
