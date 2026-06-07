// MC standard library — `barrier`: memory barriers (section 28.5). A descriptor
// must be fully written before the doorbell is rung, and a completion flag read
// after the interrupt. v0 emits compiler barriers (a `"memory"` clobber), which
// — combined with `volatile` typed MMIO ordering (section 17) — order accesses
// for a polled/QEMU device. (Arch hardware fences, e.g. riscv `fence rw,rw`, are
// a per-target refinement.)

export fn mb() -> void {
    unsafe {
        asm opaque volatile {
            ""
            clobber("memory")
        }
    }
}

export fn rmb() -> void {
    unsafe {
        asm opaque volatile {
            ""
            clobber("memory")
        }
    }
}

export fn wmb() -> void {
    unsafe {
        asm opaque volatile {
            ""
            clobber("memory")
        }
    }
}

export fn dma_wmb() -> void {
    unsafe {
        asm opaque volatile {
            ""
            clobber("memory")
        }
    }
}
