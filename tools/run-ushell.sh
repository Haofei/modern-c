#!/usr/bin/env bash
# Build + boot the user-mode MC shell in QEMU. Commands run in U-mode; the kernel mediates
# console I/O via syscalls. Type echo/true/false/exit. Quit QEMU with Ctrl-A then X.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
MCC="${MCC:-zig-out/bin/mcc}"; CLANG="${CLANG:-clang}"; LLD="${LLD:-ld.lld}"; QEMU="${QEMU:-qemu-system-riscv64}"
[ -x "$MCC" ] || zig build >/dev/null
CF=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64 -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wno-switch-bool -Wno-parentheses-equality)
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
"$MCC" emit-c tests/qemu/shell_user_demo.mc > "$W/sh.c"
"$CLANG" "${CF[@]}" -c "$W/sh.c" -o "$W/mc.o"
"$CLANG" "${CF[@]}" -c kernel/arch/riscv64/shell_user_runtime.c -o "$W/rt.o"
"$CLANG" "${CF[@]}" -c kernel/arch/riscv64/usermode_runtime.c -o "$W/um.o"
"$CLANG" "${CF[@]}" -c kernel/arch/riscv64/context_runtime.c -o "$W/ctx.o"
"$LLD" -T tests/qemu/virt.ld "$W/ctx.o" "$W/um.o" "$W/rt.o" "$W/mc.o" -o "$W/shell.elf"
echo "=== mc-shell in user mode (Ctrl-A X to quit) ==="
exec "$QEMU" -machine virt -bios none -nographic -kernel "$W/shell.elf"
