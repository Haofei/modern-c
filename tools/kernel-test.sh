#!/usr/bin/env bash
# Kernel-suite gate: lower every kernel/ module to C, compile-check it for the
# riscv64 freestanding target, and verify the kernel/bad/ typestate misuses are
# rejected. (The runnable net path is gated separately by `net-test`.)
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: kernel-test (clang not found)"; exit 0; }
"$CLANG" --print-targets 2>/dev/null | grep -q riscv64 || { echo "SKIP: kernel-test (no riscv64 target)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function)

# 1. Every kernel module must lower to C that compiles for riscv64.
count=0
for src in $(find "$HERE/kernel" -name '*.mc' | sort); do
    case "$src" in */kernel/bad/*) continue ;; esac
    name="${src#"$HERE"/}"
    if ! "$MCC" emit-c "$src" >"$WORK/out.c" 2>"$WORK/err"; then
        echo "FAIL: kernel-test — $name did not lower to C"; cat "$WORK/err"; exit 1
    fi
    if ! "$CLANG" "${CFLAGS[@]}" -c "$WORK/out.c" -o /dev/null 2>"$WORK/cerr"; then
        echo "FAIL: kernel-test — $name produced C that does not compile for riscv64"; head "$WORK/cerr"; exit 1
    fi
    count=$((count + 1))
done

# 2. Typestate misuses must be rejected with the error their EXPECT: line names.
rejects=0
for src in "$HERE"/kernel/bad/*.mc; do
    [ -e "$src" ] || continue
    name="bad/$(basename "$src")"
    want="$(grep -o 'EXPECT: [A-Z_]*' "$src" | awk '{print $2}')"
    out="$("$MCC" check "$src" 2>&1 || true)"
    if ! printf '%s' "$out" | grep -q "$want"; then
        echo "FAIL: kernel-test — $name should be rejected with $want"; printf '%s\n' "$out" | head; exit 1
    fi
    rejects=$((rejects + 1))
done

echo "PASS: kernel-test — $count kernel modules compile for riscv64; $rejects typestate misuses rejected"
exit 0
