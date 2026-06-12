extern mmio struct Uart16550 {
    thr: Reg<u8, .write>,
}

fn raw_store_in_unsafe(addr: PAddr, value: u64) -> void {
    unsafe {
        raw.store<u64>(addr, value);
    }
}

fn asm_in_unsafe() -> void {
    unsafe {
        asm opaque volatile {
            "cli"
        }
    }
}

fn mmio_map_in_unsafe(pa: PAddr) -> MmioPtr<Uart16550> {
    unsafe {
        return mmio.map<Uart16550>(pa)?;
    }
}

fn nested_unsafe_raw_store(addr: PAddr, value: u8) -> void {
    {
        unsafe {
            raw.store<u8>(addr, value);
        }
    }
}
