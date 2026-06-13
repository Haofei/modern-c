#!/usr/bin/env bash
# Kernel-suite gate: lower every kernel/ module to C, compile-check it for the
# riscv64 freestanding target, and verify the kernel/bad/ typestate misuses are
# rejected. (The runnable net path is gated separately by `net-test`.)
#
# Each module is an independent compile-check, so both phases fan out across the
# available cores (override with JOBS=N). Parallelism only changes output
# ordering; a single failing module still fails the whole gate.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: kernel-test (clang not found)"; exit 0; }
"$CLANG" --print-targets 2>/dev/null | grep -q riscv64 || { echo "SKIP: kernel-test (no riscv64 target)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS="--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64 -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra -Wno-unused-parameter -Wno-unused-function"

export MCC CLANG WORK HERE CFLAGS

# 1. Every kernel module must lower to C that compiles for riscv64. Each worker
# lowers + compiles one module into a per-module scratch file (named from the
# source path so parallel workers never collide) and returns non-zero on the
# first problem; xargs then fails the gate.
kt_compile_one() {
    local src="$1"
    local name="${src#"$HERE"/}"
    local id; id="$(printf '%s' "$name" | tr -c 'A-Za-z0-9' '_')"
    local c="$WORK/$id.c"
    local e="$WORK/$id.err"
    if ! "$MCC" emit-c "$src" >"$c" 2>"$e"; then
        echo "FAIL: kernel-test — $name did not lower to C"; cat "$e"; return 1
    fi
    if ! "$CLANG" $CFLAGS -c "$c" -o /dev/null 2>"$e"; then
        echo "FAIL: kernel-test — $name produced C that does not compile for riscv64"; head "$e"; return 1
    fi
}
export -f kt_compile_one

mapfile -t modules < <(find "$HERE/kernel" -name '*.mc' ! -path '*/kernel/bad/*' | sort)
count="${#modules[@]}"
printf '%s\0' "${modules[@]}" | xargs -0 -P "$JOBS" -I{} bash -c 'kt_compile_one "$@"' _ {}

# 2. Typestate misuses must be rejected with the error their EXPECT: line names (parallel).
kt_reject_one() {
    local src="$1"
    local name="bad/$(basename "$src")"
    local want; want="$(grep -o 'EXPECT: [A-Z_]*' "$src" | awk '{print $2}')"
    local out; out="$("$MCC" check "$src" 2>&1 || true)"
    if ! printf '%s' "$out" | grep -q "$want"; then
        echo "FAIL: kernel-test — $name should be rejected with $want"; printf '%s\n' "$out" | head; return 1
    fi
}
export -f kt_reject_one

rejects=0
if compgen -G "$HERE/kernel/bad/*.mc" >/dev/null; then
    mapfile -t bads < <(find "$HERE/kernel/bad" -name '*.mc' | sort)
    rejects="${#bads[@]}"
    printf '%s\0' "${bads[@]}" | xargs -0 -P "$JOBS" -I{} bash -c 'kt_reject_one "$@"' _ {}
fi

echo "PASS: kernel-test — $count kernel modules compile for riscv64; $rejects typestate misuses rejected"
exit 0
