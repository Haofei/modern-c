extern fn next_addr() -> PAddr;
extern fn next_index() -> usize;
extern fn next_byte() -> u8;
extern fn make_raw_many() -> [*]mut u8;
extern fn consume_raw_many(p: [*]mut u8) -> void;
extern fn consume_byte_pointer(p: *mut u8) -> void;

fn read_u32(addr: PAddr) -> u32 {
    unsafe {
        return raw.load<u32>(addr);
    }
}

fn read_via_phys(addr: usize) -> u32 {
    unsafe {
        return raw.load<u32>(phys(addr));
    }
}

fn write_u32(addr: PAddr, value: u32) -> void {
    unsafe {
        raw.store<u32>(addr, value);
    }
}

fn copy_u32(src: PAddr, dst: PAddr) -> void {
    unsafe {
        let value: u32 = raw.load<u32>(src);
        raw.store<u32>(dst, value);
    }
}

fn write_computed() -> void {
    unsafe {
        raw.store<u8>(next_addr(), next_byte());
    }
}

fn ptr_from_addr(addr: PAddr) -> *mut u32 {
    unsafe {
        return raw.ptr<u32>(addr);
    }
}

fn pause_once() -> void {
    unsafe {
        cpu.pause();
    }
}

fn offset_return(p: [*]mut u8, i: usize) -> [*]mut u8 {
    unsafe {
        return p.offset(i);
    }
}

fn offset_deref(p: [*]const u8, i: usize) -> u8 {
    unsafe {
        return p.offset(i).*;
    }
}

fn offset_store(p: [*]mut u8, i: usize, value: u8) -> void {
    unsafe {
        p.offset(i).* = value;
    }
}

fn offset_address(p: [*]mut u8, i: usize) -> *mut u8 {
    unsafe {
        return &p.offset(i).*;
    }
}

fn offset_arg(p: [*]mut u8, i: usize) -> void {
    unsafe {
        consume_raw_many(p.offset(i));
    }
}

fn offset_call_base() -> u8 {
    unsafe {
        return make_raw_many().offset(next_index()).*;
    }
}
