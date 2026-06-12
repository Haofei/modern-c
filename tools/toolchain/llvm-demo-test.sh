#!/usr/bin/env bash
# LLVM demo-driver object gate: compile the hardware-oriented demo drivers that
# are in the current LLVM backend surface to non-empty objects through llc.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
LLC="${LLC:-llc}"
command -v "$LLC" >/dev/null 2>&1 || { echo "SKIP: llvm-demo-test (llc not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

demos=(
    "demo/framebuffer/framebuffer.mc"
    "demo/gpio/gpio.mc"
    "demo/irq/irq.mc"
    "demo/spi/spi.mc"
    "demo/timer/timer.mc"
    "demo/uart/uart.mc"
)

count=0
for rel in "${demos[@]}"; do
    src="$HERE/$rel"
    out="$WORK/${rel//\//_}.o"
    if ! MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$src" -o "$out" >/dev/null 2>"$WORK/err"; then
        echo "FAIL: llvm-demo-test - $rel did not compile through LLVM"
        cat "$WORK/err"
        exit 1
    fi
    if [ ! -s "$out" ]; then
        echo "FAIL: llvm-demo-test - $rel produced an empty object"
        exit 1
    fi
    count=$((count + 1))
done

echo "PASS: llvm-demo-test - $count hardware demo drivers compiled to LLVM objects"
