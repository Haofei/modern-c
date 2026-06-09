// Inter-processor interrupts via the CLINT software-interrupt registers (MSIP).
// Writing 1 to a hart's MSIP word raises a machine software interrupt on that hart;
// the handler clears it and counts it. The MSIP MMIO is reached through typed
// addresses (phys + raw.store), and the cross-hart counters are atomics.

const CLINT_MSIP_BASE: usize = 0x0200_0000; // MSIP[h] at base + h*4 on QEMU virt

global g_ipi_received: atomic<u32> = atomic.init(0);
global g_hart1_ready: atomic<u32> = atomic.init(0);

// Raise a software interrupt on `target`.
export fn ipi_send(target: u32) -> void {
    let addr: usize = CLINT_MSIP_BASE + (target as usize) * 4;
    unsafe {
        raw.store<u32>(phys(addr), 1);
    }
}

// Deassert the software interrupt on `hart` (called from its handler).
export fn ipi_clear(hart: u32) -> void {
    let addr: usize = CLINT_MSIP_BASE + (hart as usize) * 4;
    unsafe {
        raw.store<u32>(phys(addr), 0);
    }
}

// Count a delivered IPI; returns the new total.
export fn ipi_arrive() -> u32 {
    let prev: u32 = g_ipi_received.fetch_add(1, .acq_rel);
    return prev + 1;
}

export fn ipi_count() -> u32 {
    return g_ipi_received.load(.acquire);
}

export fn hart1_set_ready() -> void {
    g_hart1_ready.store(1, .release);
}

export fn hart1_is_ready() -> u32 {
    return g_hart1_ready.load(.acquire);
}
