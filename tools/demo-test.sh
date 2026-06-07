#!/usr/bin/env bash
# Demo-suite gate: lower every demo driver in demo/ to C and compile-check it.
# The demos showcase typed-hardware patterns (typed MMIO + access permissions,
# pin/IRQ capabilities, device state machines, bus-transaction and DMA ownership,
# descriptor lifecycle, device-visible memory). virtio-net additionally runs on
# real emulated hardware via `zig build virtio-test`.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: demo-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

count=0
for src in "$HERE"/demo/*/*.mc; do
    name="$(basename "$(dirname "$src")")/$(basename "$src")"
    if ! "$MCC" emit-c "$src" >"$WORK/out.c" 2>"$WORK/err"; then
        echo "FAIL: demo-test — $name did not lower to C"
        cat "$WORK/err"
        exit 1
    fi
    if ! "$CLANG" -std=c11 -ffreestanding -Wall -Wextra -Wno-unused-parameter \
            -Wno-unused-function -c "$WORK/out.c" -o /dev/null 2>"$WORK/cerr"; then
        echo "FAIL: demo-test — $name produced C that does not compile"
        head "$WORK/cerr"
        exit 1
    fi
    count=$((count + 1))
done

echo "PASS: demo-test — $count demo drivers lowered to compilable C"
exit 0
