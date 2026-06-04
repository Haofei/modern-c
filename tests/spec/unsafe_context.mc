// SPEC: section=1.2,D.1
// SPEC: milestone=strict-unsafe-context
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_UNSAFE_REQUIRED

extern mmio struct Uart16550 {
    thr: Reg<u8, .write>,
}

fn accept_raw_store_in_unsafe(addr: PAddr, value: u64) -> void {
    unsafe {
        raw.store<u64>(addr, value);
    }
}

fn accept_mmio_map_in_unsafe(pa: PAddr) -> MmioPtr<Uart16550> {
    unsafe {
        return mmio.map<Uart16550>(pa)?;
    }
}

fn accept_asm_in_unsafe() -> void {
    unsafe {
        asm opaque volatile {
            "cli"
        }
    }
}

fn reject_raw_store_outside_unsafe(addr: PAddr, value: u64) -> void {
    // EXPECT_ERROR: E_UNSAFE_REQUIRED
    raw.store<u64>(addr, value);
}

fn reject_mmio_map_outside_unsafe(pa: PAddr) -> MmioPtr<Uart16550> {
    // EXPECT_ERROR: E_UNSAFE_REQUIRED
    return mmio.map<Uart16550>(pa)?;
}

fn reject_asm_outside_unsafe() -> void {
    // EXPECT_ERROR: E_UNSAFE_REQUIRED
    asm opaque volatile {
        "cli"
    }
}
