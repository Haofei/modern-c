global shared_cell: u32 = 0;
global global_const_ptr: *const u32 = &shared_cell;
global global_mut_ptr: *mut u32 = &shared_cell;

fn assign_through_mut_pointer(p: *mut u32, value: u32) -> void {
    p.* = value;
}

fn assign_through_global_mut_pointer(value: u32) -> void {
    global_mut_ptr.* = value;
}

fn local_shadow_global_const_pointer(global_const_ptr: *mut u32, value: u32) -> void {
    global_const_ptr.* = value;
}

fn inferred_local_shadow_global_const_pointer(p: *mut u32, value: u32) -> void {
    let global_const_ptr = p;
    global_const_ptr.* = value;
}

fn assign_through_mut_slice(xs: []mut u32, i: usize, value: u32) -> void {
    xs[i] = value;
}
