// MC standard library — `barrier`: memory barriers (section 28.5). A descriptor
// must be fully written before the doorbell is rung, and a completion flag read
// after the interrupt. These lower to target-aware CPU fences via the `fence.*`
// builtins (`__atomic_thread_fence` → riscv `fence`, x86 `mfence`, arm `dmb`), so
// they order accesses on real hardware, not just against the compiler. Combined
// with `volatile` typed MMIO ordering (section 17), they make the virtqueue and
// device handshakes correct beyond QEMU's sequentially-consistent model.

export fn mb() -> void {
    fence.full();
}

export fn rmb() -> void {
    fence.acquire();
}

export fn wmb() -> void {
    fence.release();
}

export fn dma_wmb() -> void {
    fence.release();
}
