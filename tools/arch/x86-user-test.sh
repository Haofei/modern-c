#!/usr/bin/env bash
# M6 "x86-64 ring-3 user hello". Build a bootable x86-64 multiboot kernel that, in 64-bit long
# mode, installs a GDT (ring0/ring3 + TSS) and IDT (syscall vector 0x80), builds a confined user
# address space (kernel identity no-US + user code/stack US via kernel/arch/x86_64/paging.mc),
# loads CR3, and iretq's into ring 3. The ring-3 program does SYS_WRITE(valid), SYS_WRITE(bad ptr
# -> -EFAULT via a SOFTWARE page-table walk), SYS_WRITE("EFAULT-OK") iff the bad call returned
# RAX<0, then SYS_EXIT. Boots under qemu-system-x86_64; reports over COM1; the harness asserts
# HELLO-FROM-RING3 AND EFAULT-OK AND USER-EXIT.
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"; LLD="${LLD:-ld.lld}"; LLC="${LLC:-llc}"; OBJCOPY="${OBJCOPY:-llvm-objcopy}"; QEMU="${QEMU:-qemu-system-x86_64}"
ARCH="$HERE/kernel/arch/x86_64"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-x86-user-test" || echo "x86-user-test")
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
# The kmain runtime is now PURE MC (tests/x86/user_x86_runtime.mc); it imports port_io.mc and
# declares the user_x86_demo fixture's functions extern (demo built as a separate object below).
# boot.S (the 32-bit multiboot header + long-mode trampoline MC cannot target) still links first
# and `call kmain`s into the MC object. The old user_runtime.c is deleted.
case "$BACKEND" in
  c)
    "$MCC" emit-c "$HERE/tests/x86/user_x86_demo.mc" > "$WORK/user.c"
    $CLANG $CF -Wno-switch-bool -c "$WORK/user.c" -o "$WORK/user.o"
    "$MCC" emit-c "$HERE/tests/x86/user_x86_runtime.mc" > "$WORK/runtime.c"
    $CLANG $CF -Wno-switch-bool -c "$WORK/runtime.c" -o "$WORK/user_runtime.o"
    ;;
  llvm)
    MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/tests/x86/user_x86_demo.mc" -o "$WORK/user.o" \
      -mtriple=x86_64-unknown-elf \
      -relocation-model=static \
      -code-model=kernel
    MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/tests/x86/user_x86_runtime.mc" -o "$WORK/user_runtime.o" \
      -mtriple=x86_64-unknown-elf \
      -relocation-model=static \
      -code-model=kernel
    $CLANG $CF -c "$HERE/kernel/arch/riscv64/llvm_kernel_support.c" -o "$WORK/llvm-support.o"
    ;;
  *)
    echo "unknown kernel backend: $BACKEND" >&2
    exit 2
    ;;
esac
$CLANG --target=x86_64-unknown-elf -ffreestanding -c "$ARCH/boot.S" -o "$WORK/boot.o"
# Freestanding mem*: the backends emit memset/memcpy for aggregate init/copy (the old runtime.c
# carried local copies); link the shared arch-neutral freestanding object instead.
$CLANG $CF -fno-builtin -c "$HERE/kernel/arch/riscv64/freestanding.c" -o "$WORK/freestanding.o"
SUPPORT_OBJ=$([ "$BACKEND" = llvm ] && printf '%s' "$WORK/llvm-support.o" || true)
$LLD -T "$HERE/tests/x86/x86-multiboot.ld" "$WORK/boot.o" "$WORK/user_runtime.o" "$WORK/user.o" "$WORK/freestanding.o" $SUPPORT_OBJ -o "$WORK/kernel.elf"
$OBJCOPY -O binary "$WORK/kernel.elf" "$WORK/kernel.bin"
OUT="$(timeout 30 "$QEMU" -kernel "$WORK/kernel.bin" -nographic -no-reboot \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 2>/dev/null || true)"
echo "--- x86 USER kernel serial output ---"; printf '%s\n' "$OUT" | grep -aE "boot OK|GDT|IDT|address space|cr3|CONFINED|LEAK|entering ring 3|HELLO-FROM-RING3|EFAULT-OK|USER-EXIT|X86-USER-BAD|BAD-SYSCALL"
echo "-------------------------------------"
if printf '%s' "$OUT" | grep -qa "HELLO-FROM-RING3" \
   && printf '%s' "$OUT" | grep -qa "EFAULT-OK" \
   && printf '%s' "$OUT" | grep -qa "USER-EXIT"; then
  echo "PASS: $TEST_NAME — $BACKEND backend: ring-3 program runs, SYS_WRITE prints via the kernel, a bad user pointer is rejected -EFAULT by a software page-table walk (no #PF), and the program SYS_EXITs cleanly"
  exit 0
fi
echo "FAIL: $TEST_NAME — expected HELLO-FROM-RING3 AND EFAULT-OK AND USER-EXIT in serial output"; exit 1
