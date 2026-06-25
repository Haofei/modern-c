#!/usr/bin/env bash
# Repeat the selected RISC-V QEMU surrogate gates enough to catch obvious flake/regression
# without claiming a long-duration hardware soak. Use MC_SOAK_ITERS=N to raise the count.
set -euo pipefail

ITERS="${MC_SOAK_ITERS:-3}"

for i in $(seq 1 "$ITERS"); do
    echo "soak-smoke iteration $i/$ITERS"
    zig build \
        smode-timer-test \
        smode-plic-multishot-test \
        blk-smode-irq-test \
        net-smode-irq-test \
        net-smode-rx-irq-test \
        qjs-smode-net-irq-tool-test \
        qjs-smode-blk-irq-tool-test \
        visionfive2-readiness-test
done

echo "PASS: riscv-qemu-soak-smoke — $ITERS repeated RISC-V QEMU/OpenSBI surrogate iterations completed"
