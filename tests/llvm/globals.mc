global shared: u32 = 7;
global flag: bool = false;
global shared_ptr: *mut u32 = &shared;

fn read_shared() -> u32 {
    return shared;
}

fn write_shared(value: u32) -> u32 {
    shared = value;
    return shared;
}

fn read_flag() -> bool {
    return flag;
}

fn write_through_global_pointer(value: u32) -> u32 {
    *shared_ptr = value;
    return shared;
}
