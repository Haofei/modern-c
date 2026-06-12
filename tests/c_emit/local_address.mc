global shared_counter: u32 = 0;

extern fn next_index() -> usize;
extern fn make_mut_slice() -> []mut u32;
extern fn make_array() -> [4]u32;
extern fn consume_mut_pointer(p: *mut u32) -> void;

fn return_parameter_pointer(p: *mut u32) -> *mut u32 {
    return p;
}

fn return_const_parameter_pointer(p: *const u32) -> *const u32 {
    return p;
}

fn return_global_address() -> *mut u32 {
    return &shared_counter;
}

fn return_global_address_alias() -> *mut u32 {
    let p: *mut u32 = &shared_counter;
    return p;
}

fn return_slice_element_address(xs: []mut u32, i: usize) -> *mut u32 {
    return &xs[i];
}

fn return_slice_element_address_next(xs: []mut u32) -> *mut u32 {
    return &xs[next_index()];
}

fn local_slice_element_address_next(xs: []mut u32) -> *mut u32 {
    let p: *mut u32 = &xs[next_index()];
    return p;
}

fn assign_slice_element_address_next(xs: []mut u32, fallback: *mut u32) -> *mut u32 {
    var p: *mut u32 = fallback;
    p = &xs[next_index()];
    return p;
}

fn pass_slice_element_address_next(xs: []mut u32) -> void {
    consume_mut_pointer(&xs[next_index()]);
}

fn return_call_slice_element_address() -> *mut u32 {
    return &make_mut_slice()[next_index()];
}

fn pass_call_slice_element_address() -> void {
    consume_mut_pointer(&make_mut_slice()[next_index()]);
}

fn pass_call_array_element_address() -> void {
    consume_mut_pointer(&make_array()[next_index()]);
}

fn pass_local_array_element_address_next() -> void {
    var xs: [4]u32 = uninit;
    consume_mut_pointer(&xs[next_index()]);
}

fn cleared_local_pointer_alias(p: *mut u32) -> *mut u32 {
    var x: u32 = 1;
    var out: *mut u32 = &x;
    out = p;
    return out;
}

fn cleared_local_pointer_with_global() -> *mut u32 {
    var x: u32 = 1;
    var out: *mut u32 = &x;
    out = &shared_counter;
    return out;
}
