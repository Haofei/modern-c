fn return_ptr_param(p: *mut u8) -> *mut u8 {
    return p;
}

fn read_ptr_param(p: *mut u8) -> u8 {
    return p.*;
}
