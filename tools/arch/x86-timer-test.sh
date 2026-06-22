#!/usr/bin/env bash
# Build a bootable x86-64 multiboot kernel that, in 64-bit long mode, masks the legacy 8259 PICs,
# enables the Local APIC, programs its timer in PERIODIC mode at IDT vector 0x20, enables
# interrupts (sti), and parks on `hlt` until enough REAL timer interrupts have been delivered —
# proving non-polled interrupt delivery on x86-64. Boots under qemu-system-x86_64; reports over
# COM1; the harness greps for `X86-TIMER-OK` and that TICKS>=3.
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"; LLD="${LLD:-ld.lld}"; LLC="${LLC:-llc}"; OBJCOPY="${OBJCOPY:-llvm-objcopy}"; QEMU="${QEMU:-qemu-system-x86_64}"
ARCH="$HERE/kernel/arch/x86_64"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-x86-timer-test" || echo "x86-timer-test")
# CI-aware skip: in CI / MC_REQUIRE_TOOLS a missing toolchain FAILS (a gate must not look green
# because qemu/clang/lld were absent); locally it still skips. Same policy as the other x86 gates.
source "$HERE/tools/qemu/kernel-boot-lib.sh"
skip() { kernel_boot_skip "$TEST_NAME" "$1"; }
command -v "$CLANG"   >/dev/null 2>&1 || skip "clang not found"
command -v "$LLD"     >/dev/null 2>&1 || skip "ld.lld not found"
if [ "$BACKEND" = llvm ]; then command -v "$LLC" >/dev/null 2>&1 || skip "llc not found"; fi
command -v "$OBJCOPY" >/dev/null 2>&1 || skip "llvm-objcopy not found"
command -v "$QEMU"    >/dev/null 2>&1 || skip "$QEMU not found"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CF="--target=x86_64-unknown-elf -ffreestanding -fno-pic -fno-pie -mno-red-zone -nostdlib -O1 -Wall -Wextra -Wno-unused-parameter -Wno-unused-function"
# The kmain runtime is now PURE MC (tests/x86/timer_x86_runtime.mc), which imports the MC timer
# fixture (timer_target/timer_ok) and the pure-MC port_io console: one MC compilation unit yields
# kmain + the fixture. boot.S (the 32-bit multiboot header + long-mode trampoline MC cannot target)
# links first and `call kmain`s into the MC object. The old timer_runtime.c is deleted.
case "$BACKEND" in
  c)
    "$MCC" emit-c "$HERE/tests/x86/timer_x86_runtime.mc" > "$WORK/timer.c"
    $CLANG $CF -Wno-switch-bool -c "$WORK/timer.c" -o "$WORK/timer.o"
    ;;
  llvm)
    MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/tests/x86/timer_x86_runtime.mc" -o "$WORK/timer.o" \
      -mtriple=x86_64-unknown-elf \
      -relocation-model=static \
      -code-model=kernel
    $CLANG $CF -x c -c /dev/null -o "$WORK/llvm-support.o"
    ;;
  *)
    echo "unknown kernel backend: $BACKEND" >&2
    exit 2
    ;;
esac
$CLANG --target=x86_64-unknown-elf -ffreestanding -c "$ARCH/boot.S" -o "$WORK/boot.o"
# Freestanding mem*: the backends emit memset/memcpy calls for aggregate init/copy. The shared
# freestanding libc object supplies them (arch-neutral C; -fno-builtin so the loops are not
# rewritten into calls to themselves), exactly as the riscv kernel images do.
"$MCC" emit-c "$HERE/kernel/lib/freestanding.mc" > "$WORK/freestanding_gen.c" # freestanding mem* is now pure MC
$CLANG $CF -fno-builtin -c "$WORK/freestanding_gen.c" -o "$WORK/freestanding.o"
SUPPORT_OBJ=$([ "$BACKEND" = llvm ] && printf '%s' "$WORK/llvm-support.o" || true)
$LLD -T "$HERE/tests/x86/x86-multiboot.ld" "$WORK/boot.o" "$WORK/timer.o" "$WORK/freestanding.o" $SUPPORT_OBJ -o "$WORK/kernel.elf"
$OBJCOPY -O binary "$WORK/kernel.elf" "$WORK/kernel.bin"
OUT="$(timeout 30 "$QEMU" -kernel "$WORK/kernel.bin" -nographic -no-reboot \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 2>/dev/null || true)"
echo "--- x86 LAPIC-timer kernel serial output ---"; printf '%s\n' "$OUT" | grep -aE "boot OK|masked|IDT|MMIO|enabled|target|waiting|X86-TIMER"
echo "--------------------------------------------"
TICKS="$(printf '%s' "$OUT" | grep -aoE "X86-TIMER TICKS=[0-9]+" | grep -aoE "[0-9]+" | tail -1)"
if printf '%s' "$OUT" | grep -qa "X86-TIMER-OK" && [ -n "${TICKS:-}" ] && [ "$TICKS" -ge 3 ]; then
  echo "PASS: $TEST_NAME — $BACKEND backend: x86-64 enabled the Local APIC, programmed its periodic timer at IDT vec 0x20, and observed $TICKS REAL (non-polled, PIC-masked) timer interrupts"
  exit 0
fi
echo "FAIL: $TEST_NAME — expected 'X86-TIMER-OK' with TICKS>=3 (got TICKS='${TICKS:-none}')"; exit 1
