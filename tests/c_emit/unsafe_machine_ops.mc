fn store_byte(addr: PAddr, value: u8) -> void {
    unsafe {
        raw.store<u8>(addr, value);
    }
}

extern fn next_addr() -> PAddr;
extern fn next_byte() -> u8;
extern fn box_byte(value: u8) -> u8;

fn store_computed() -> void {
    unsafe {
        raw.store<u8>(next_addr(), box_byte(next_byte()));
    }
}

fn store_literal(value: u32) -> void {
    unsafe {
        raw.store<u32>(phys(0x20000000), value);
    }
}

fn pause_once() -> void {
    unsafe {
        cpu.pause();
    }
}
