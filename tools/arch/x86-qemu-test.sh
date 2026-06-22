#!/usr/bin/env bash
# Build a bootable x86-64 multiboot kernel (32->64-bit long mode) and boot it under
# qemu-system-x86_64; the kmain runs the cooperative scheduler and reports over COM1.
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"; LLD="${LLD:-ld.lld}"; LLC="${LLC:-llc}"; OBJCOPY="${OBJCOPY:-llvm-objcopy}"; QEMU="${QEMU:-qemu-system-x86_64}"
ARCH="$HERE/kernel/arch/x86_64"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-x86-qemu-test" || echo "x86-qemu-test")
# CI-aware skip: in CI / MC_REQUIRE_TOOLS a missing toolchain FAILS (a gate must not look green
# because qemu/clang/lld were absent); locally it still skips. Same policy as the riscv gates.
source "$HERE/tools/qemu/kernel-boot-lib.sh"
skip() { kernel_boot_skip "$TEST_NAME" "$1"; }
command -v "$CLANG"   >/dev/null 2>&1 || skip "clang not found"
command -v "$LLD"     >/dev/null 2>&1 || skip "ld.lld not found"
if [ "$BACKEND" = llvm ]; then command -v "$LLC" >/dev/null 2>&1 || skip "llc not found"; fi
command -v "$OBJCOPY" >/dev/null 2>&1 || skip "llvm-objcopy not found"
command -v "$QEMU"    >/dev/null 2>&1 || skip "$QEMU not found"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CF="--target=x86_64-unknown-elf -ffreestanding -fno-pic -fno-pie -mno-red-zone -nostdlib -O1 -Wall -Wextra -Wno-unused-parameter -Wno-unused-function"
# The kmain runtime (tests/x86/sched_x86_runtime.mc) and the context-switch primitives
# (kernel/arch/x86_64/context_runtime.mc) are now PURE MC, alongside the pure-MC scheduler
# demo (tests/x86/sched_x86_demo.mc). Three MC objects link with boot.S (the genuine 32-bit
# multiboot header + long-mode trampoline MC cannot target), which still links first and
# `call kmain`s into the MC object. The old kmain_runtime.c / context_runtime.c are deleted.
case "$BACKEND" in
  c)
    "$MCC" emit-c "$HERE/tests/x86/sched_x86_demo.mc" > "$WORK/sched.c"
    $CLANG $CF -Wno-switch-bool -c "$WORK/sched.c" -o "$WORK/sched.o"
    "$MCC" emit-c "$HERE/tests/x86/sched_x86_runtime.mc" > "$WORK/kmain.c"
    $CLANG $CF -Wno-switch-bool -c "$WORK/kmain.c" -o "$WORK/kmain.o"
    "$MCC" emit-c "$HERE/kernel/arch/x86_64/context_runtime.mc" > "$WORK/ctx.c"
    $CLANG $CF -Wno-switch-bool -c "$WORK/ctx.c" -o "$WORK/ctx.o"
    ;;
  llvm)
    MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/tests/x86/sched_x86_demo.mc" -o "$WORK/sched.o" \
      -mtriple=x86_64-unknown-elf \
      -relocation-model=static \
      -code-model=kernel
    MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/tests/x86/sched_x86_runtime.mc" -o "$WORK/kmain.o" \
      -mtriple=x86_64-unknown-elf \
      -relocation-model=static \
      -code-model=kernel
    MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/kernel/arch/x86_64/context_runtime.mc" -o "$WORK/ctx.o" \
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
# Freestanding mem*: the backends emit memset/memcpy for aggregate init/copy; link the shared
# freestanding libc object (arch-neutral C; -fno-builtin so the loops are not rewritten into
# calls to themselves), exactly as the x86 vm/timer images do now that the kmain is pure MC.
"$MCC" emit-c "$HERE/kernel/lib/freestanding.mc" > "$WORK/freestanding_gen.c" # freestanding mem* is now pure MC
$CLANG $CF -fno-builtin -c "$WORK/freestanding_gen.c" -o "$WORK/freestanding.o"
SUPPORT_OBJ=$([ "$BACKEND" = llvm ] && printf '%s' "$WORK/llvm-support.o" || true)
$LLD -T "$HERE/tests/x86/x86-multiboot.ld" "$WORK/boot.o" "$WORK/kmain.o" "$WORK/sched.o" "$WORK/ctx.o" "$WORK/freestanding.o" $SUPPORT_OBJ -o "$WORK/kernel.elf"
$OBJCOPY -O binary "$WORK/kernel.elf" "$WORK/kernel.bin"
OUT="$(timeout 30 "$QEMU" -kernel "$WORK/kernel.bin" -nographic -no-reboot \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 2>/dev/null || true)"
echo "--- x86 kernel serial output ---"; printf '%s\n' "$OUT" | grep -aE "boot OK|X86-"
echo "--------------------------------"
if printf '%s' "$OUT" | grep -qa "X86-OK"; then
  echo "PASS: $TEST_NAME — $BACKEND backend x86-64 kernel boots under QEMU: multiboot -> 32->64-bit long mode (paging/PAE/SSE/GDT) -> cooperative scheduler (ABCABCABC) over COM1"
  exit 0
fi
echo "FAIL: $TEST_NAME — expected 'X86-OK' in serial output"; exit 1
