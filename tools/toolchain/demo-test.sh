#!/usr/bin/env bash
# Demo-suite gate: lower every demo driver in demo/ to C and compile-check it.
# The demos showcase typed-hardware patterns (typed MMIO + access permissions,
# pin/IRQ capabilities, device state machines, bus-transaction and DMA ownership,
# descriptor lifecycle, device-visible memory). virtio-net additionally runs on
# real emulated hardware via `zig build virtio-test`.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: demo-test (clang not found)"; exit 0; }
"$CLANG" --print-targets 2>/dev/null | grep -q riscv64 || { echo "SKIP: demo-test (no riscv64 target)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The demos are freestanding RISC-V kernel drivers (virtio-net boots under QEMU-riscv
# via virtio-test) and one carries RISC-V inline asm (_start's `la sp,_stack_top`), so
# they must be compile-checked for riscv64 — NOT the host default, which cannot assemble
# that asm. Portable demos compile for riscv64 just as well.
CFLAGS="--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64 -std=c11 -nostdlib -ffreestanding -fno-pic -mcmodel=medany -Wall -Wextra -Wno-unused-parameter -Wno-unused-function"

# 1. Positive demos must lower to compilable C.
count=0
for src in "$HERE"/demo/*/*.mc; do
    case "$src" in */demo/bad/*) continue ;; esac # the bad/ cases must NOT compile
    name="$(basename "$(dirname "$src")")/$(basename "$src")"
    if ! "$MCC" emit-c "$src" >"$WORK/out.c" 2>"$WORK/err"; then
        echo "FAIL: demo-test — $name did not lower to C"
        cat "$WORK/err"
        exit 1
    fi
    if ! "$CLANG" $CFLAGS -c "$WORK/out.c" -o /dev/null 2>"$WORK/cerr"; then
        echo "FAIL: demo-test — $name produced C that does not compile"
        head "$WORK/cerr"
        exit 1
    fi
    count=$((count + 1))
done

# 2. Compile-fail demos: each must be rejected with the error its `EXPECT:` line
#    names — this is where the type-safety value is demonstrated.
rejects=0
for src in "$HERE"/demo/bad/*.mc; do
    [ -e "$src" ] || continue
    name="bad/$(basename "$src")"
    want="$(grep -o 'EXPECT: [A-Z_]*' "$src" | awk '{print $2}')"
    # A reject fixture must FAIL `check` (nonzero exit) AND name its diagnostic — asserting
    # only on the message lets a fixture that actually COMPILES pass. Capture status, not `|| true`.
    set +e
    out="$("$MCC" check "$src" 2>&1)"
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        echo "FAIL: demo-test — $name should have been REJECTED ($want) but check succeeded (rc=0)"
        exit 1
    fi
    if ! printf '%s' "$out" | grep -q "$want"; then
        echo "FAIL: demo-test — $name rejected, but not with $want"
        printf '%s\n' "$out" | head
        exit 1
    fi
    rejects=$((rejects + 1))
done

echo "PASS: demo-test — $count demo drivers lower to compilable C; $rejects misuses correctly rejected"
exit 0
