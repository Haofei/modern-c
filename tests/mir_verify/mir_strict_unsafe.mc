extern mmio struct Uart16550 {
    thr: Reg<u8, .write>,
}

fn reject_raw_store(addr: PAddr, value: u64) -> void {
    raw.store<u64>(addr, value);
}

fn reject_mmio_map(pa: PAddr) -> void {
    mmio.map<Uart16550>(pa);
}

fn reject_asm() -> void {
    asm opaque volatile {
        "cli"
    }
}

fn reject_raw_many_deref(p: [*]mut u8) -> u8 {
    return p.*;
}

fn accept_unsafe_effects(addr: PAddr, value: u64, pa: PAddr) -> void {
    unsafe {
        raw.store<u64>(addr, value);
        mmio.map<Uart16550>(pa);
        asm opaque volatile {
            "cli"
        }
    }
}
