global shared_cell: u32 = 0;
global seed: u32 = 1;
global copied_seed: u32 = seed;
global signed_seed: i32 = -1;
global grouped_signed_seed: i16 = (-12);
global global_const_ptr: *const u32 = &shared_cell;
global global_mut_ptr: *mut u32 = &shared_cell;
global nullable_handle: ?*mut u8 = null;

fn read_shared_cell() -> u32 {
    return shared_cell;
}

fn read_copied_seed() -> u32 {
    return copied_seed;
}

fn read_signed_seed() -> i32 {
    return signed_seed;
}

fn read_grouped_signed_seed() -> i16 {
    return grouped_signed_seed;
}

fn read_global_const_ptr() -> u32 {
    return global_const_ptr.*;
}

fn write_global_mut_ptr(value: u32) -> void {
    global_mut_ptr.* = value;
}

fn retarget_global_mut_ptr(next: *mut u32) -> void {
    global_mut_ptr = next;
}

fn read_nullable_handle() -> ?*mut u8 {
    return nullable_handle;
}

fn set_nullable_handle(next: ?*mut u8) -> void {
    nullable_handle = next;
}
