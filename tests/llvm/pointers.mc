fn load_ptr(p: *mut u32) -> u32 {
    return *p;
}

fn store_ptr(p: *mut u32, value: u32) -> u32 {
    *p = value;
    return *p;
}

fn local_address(value: u32) -> u32 {
    var x: u32 = value;
    let p: *mut u32 = &x;
    *p = x + 1;
    return x;
}
