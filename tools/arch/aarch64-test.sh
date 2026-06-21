#!/usr/bin/env bash
# Second-architecture gate: an MC computation compiled for aarch64 + a minimal ARM64
# boot runtime, booted on qemu-system-aarch64 'virt'. Proves portability beyond riscv64.
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"; LLD="${LLD:-ld.lld}"; LLC="${LLC:-llc}"; QEMU="${QEMU:-qemu-system-aarch64}"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-aarch64-test" || echo "aarch64-test")
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
# NOTE: NO -mgeneral-regs-only. The boot runtime is now PURE MC (tests/arm/boot_arm_runtime.mc),
# which imports the arch-neutral MC computation (arch_demo.mc): ONE MC compilation unit yields
# cmain + arch_compute, plus the naked `_start` (EL2->EL1 drop). There is no boot.S. The LLVM
# backend may emit SIMD/FP for aggregate ops, so we let the assembler use SIMD registers. The
# old boot_runtime.c is deleted.
CFLAGS=(--target=aarch64-unknown-elf -ffreestanding -nostdlib -fno-pic -O1 -Wall -Wextra -Wno-unused-parameter -Wno-unused-function)
case "$BACKEND" in
    c)
        "$MCC" emit-c "$HERE/tests/arm/boot_arm_runtime.mc" >"$WORK/c.c"
        "$CLANG" "${CFLAGS[@]}" -Wno-switch-bool -c "$WORK/c.c" -o "$WORK/mc.o"
        ;;
    llvm)
        MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/tests/arm/boot_arm_runtime.mc" -o "$WORK/mc.o" \
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
# Freestanding mem*: both backends may emit memset/memcpy for aggregate init/copy.
"$CLANG" "${CFLAGS[@]}" -fno-builtin -c "$HERE/kernel/arch/riscv64/freestanding.c" -o "$WORK/freestanding.o"
SUPPORT_OBJ=$([ "$BACKEND" = llvm ] && printf '%s' "$WORK/llvm-support.o" || true)
"$LLD" -T "$HERE/tests/qemu/aarch64.ld" "$WORK/mc.o" "$WORK/freestanding.o" $SUPPORT_OBJ -o "$WORK/k.elf"
OUT="$(timeout 30 "$QEMU" -machine virt -cpu cortex-a53 -nographic -kernel "$WORK/k.elf" 2>/dev/null || true)"
echo "--- aarch64 UART ---"; printf '%s\n' "$OUT"; echo "--------------------"
if printf '%s' "$OUT" | grep -q "ARM64-OK"; then
    echo "PASS: $TEST_NAME — $BACKEND backend MC code compiled + booted on a second architecture (aarch64 QEMU virt): arch_compute ran (ARM64-OK)"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected ARM64-OK"; exit 1
