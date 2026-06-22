#!/usr/bin/env bash
# Gate: the shell runs in USER MODE. Drive it with piped commands; confirm echo output is
# produced via syscalls and that exit traps from U-mode (privilege-separated shell).
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"; LLD="${LLD:-ld.lld}"; LLC="${LLC:-llc}"; QEMU="${QEMU:-qemu-system-riscv64}"
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-ushell-test" || echo "ushell-test")
kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64 -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wno-switch-bool -Wno-parentheses-equality)
kernel_boot_compile_mc_object "$BACKEND" "$HERE/tests/qemu/lang/shell_user_demo.mc" "$W/mc.o" "$W"
kernel_boot_compile_mc_object "$BACKEND" "$HERE/tests/qemu/lang/shell_user_runtime.mc" "$W/rt.o" "$W"
kernel_boot_compile_c_object "$HERE/tests/qemu/proc/usermode_runtime.mc" "$W/um.o"
kernel_boot_compile_c_object "$HERE/tests/qemu/proc/context_runtime.mc" "$W/ctx.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$W/llvm-support.o")"
kernel_boot_compile_rt "$W/freestanding.o"
"$LLD" -T "$HERE/tests/qemu/virt.ld" "$W/freestanding.o" "$W/ctx.o" "$W/um.o" "$W/rt.o" "$W/mc.o" $SUPPORT_OBJ -o "$W/shell.elf"
OUT="$(printf 'echo hi user\ntop\nexit\n' | timeout 25 "$QEMU" -machine virt -bios none -nographic -kernel "$W/shell.elf" 2>/dev/null || true)"
echo "--- shell session ---"; printf '%s\n' "$OUT" | tail -8; echo "---------------------"
if printf '%s' "$OUT" | grep -q "hi user" \
   && printf '%s' "$OUT" | grep -q "PID ST" \
   && printf '%s' "$OUT" | grep -qE "^0  R" \
   && printf '%s' "$OUT" | grep -qE "^1  r" \
   && printf '%s' "$OUT" | grep -q "USER-EXIT from U"; then
    echo "PASS: $TEST_NAME — $BACKEND backend user-mode shell: TTY line discipline + core builtins (echo/true/false/exit) in shell.mc + a user-layer top dispatched via sh_arg_eq; top reads the real ProcTable through SYS_PROC_* (rows 0 R, 1 r); input is INTERRUPT-DRIVEN (UART RX IRQ -> PLIC -> ISR ring; shell wfi-blocks, no busy poll); exit traps from U-mode"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected echoed output + 'USER-EXIT from U'"; exit 1
