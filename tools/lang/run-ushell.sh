#!/usr/bin/env bash
# Build + boot the user-mode MC shell in QEMU. Commands run in U-mode; the kernel mediates
# console I/O via syscalls. Type echo/true/false/exit. Quit QEMU with Ctrl-A then X.
set -euo pipefail
cd "$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
BACKEND="${1:-${BACKEND:-c}}"
MCC="${MCC_UNDER_TEST:-${MCC:-zig-out/bin/mcc}}"; CLANG="${CLANG:-clang}"; LLD="${LLD:-ld.lld}"; LLC="${LLC:-llc}"; QEMU="${QEMU:-qemu-system-riscv64}"
[ -x "$MCC" ] || zig build >/dev/null
source tools/qemu/kernel-boot-lib.sh
HERE="$(pwd)"
CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64 -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wno-switch-bool -Wno-parentheses-equality)
kernel_boot_require_riscv "run-ushell" "$BACKEND"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
kernel_boot_compile_mc_object "$BACKEND" tests/qemu/lang/shell_user_demo.mc "$W/mc.o" "$W"
kernel_boot_compile_mc_object "$BACKEND" tests/qemu/lang/shell_user_runtime.mc "$W/rt.o" "$W"
kernel_boot_compile_c_object tests/qemu/proc/usermode_runtime.mc "$W/um.o"
kernel_boot_compile_c_object tests/qemu/proc/context_runtime.mc "$W/ctx.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$W/llvm-support.o")"
kernel_boot_compile_rt "$W/freestanding.o"
"$LLD" -T tests/qemu/virt.ld "$W/freestanding.o" "$W/ctx.o" "$W/um.o" "$W/rt.o" "$W/mc.o" $SUPPORT_OBJ -o "$W/shell.elf"
echo "=== mc-shell in user mode [$BACKEND] (Ctrl-A X to quit) ==="
exec "$QEMU" -machine virt -bios none -nographic -kernel "$W/shell.elf"
