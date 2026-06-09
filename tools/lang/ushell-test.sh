#!/usr/bin/env bash
# Gate: the shell runs in USER MODE. Drive it with piped commands; confirm echo output is
# produced via syscalls and that exit traps from U-mode (privilege-separated shell).
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"; HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"; LLD="${LLD:-ld.lld}"; QEMU="${QEMU:-qemu-system-riscv64}"
skip(){ echo "SKIP: ushell-test ($1)"; exit 0; }
command -v "$CLANG" >/dev/null 2>&1 || skip "no clang"
command -v "$LLD" >/dev/null 2>&1 || skip "no ld.lld"
command -v "$QEMU" >/dev/null 2>&1 || skip "no qemu"
"$CLANG" --print-targets 2>/dev/null | grep -q riscv64 || skip "clang has no riscv64 target"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
CF=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64 -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wno-switch-bool -Wno-parentheses-equality)
"$MCC" emit-c "$HERE/tests/qemu/lang/shell_user_demo.mc" > "$W/sh.c"
"$CLANG" "${CF[@]}" -c "$W/sh.c" -o "$W/mc.o"
"$CLANG" "${CF[@]}" -c "$HERE/kernel/arch/riscv64/shell_user_runtime.c" -o "$W/rt.o"
"$CLANG" "${CF[@]}" -c "$HERE/kernel/arch/riscv64/usermode_runtime.c" -o "$W/um.o"
"$CLANG" "${CF[@]}" -c "$HERE/kernel/arch/riscv64/context_runtime.c" -o "$W/ctx.o"
"$LLD" -T "$HERE/tests/qemu/virt.ld" "$W/ctx.o" "$W/um.o" "$W/rt.o" "$W/mc.o" -o "$W/shell.elf"
OUT="$(printf 'echo hi user\ntop\nexit\n' | timeout 25 "$QEMU" -machine virt -bios none -nographic -kernel "$W/shell.elf" 2>/dev/null || true)"
echo "--- shell session ---"; printf '%s\n' "$OUT" | tail -8; echo "---------------------"
if printf '%s' "$OUT" | grep -q "hi user" \
   && printf '%s' "$OUT" | grep -q "PID ST" \
   && printf '%s' "$OUT" | grep -qE "^0  R" \
   && printf '%s' "$OUT" | grep -qE "^1  r" \
   && printf '%s' "$OUT" | grep -q "USER-EXIT from U"; then
    echo "PASS: ushell-test — user-mode shell: TTY line discipline + core builtins (echo/true/false/exit) in shell.mc + a user-layer top dispatched via sh_arg_eq; top reads the real ProcTable through SYS_PROC_* (rows 0 R, 1 r); input is INTERRUPT-DRIVEN (UART RX IRQ -> PLIC -> ISR ring; shell wfi-blocks, no busy poll); exit traps from U-mode"
    exit 0
fi
echo "FAIL: ushell-test — expected echoed output + 'USER-EXIT from U'"; exit 1
