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

fn nested_unsafe_raw_store(addr: PAddr, value: u8) -> void {
    {
        unsafe {
            raw.store<u8>(addr, value);
        }
    }
}
