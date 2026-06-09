global shared_value: u32 = 0;
global copied_value: u32 = shared_value;

fn takes_u32(value: u32) -> u32 {
    return value;
}

fn same_integer_assignment(value: u32) -> u32 {
    var x: u32 = 0;
    x = value;
    return x;
}

fn call_argument_type(value: u32) -> u32 {
    return takes_u32(value);
}

fn same_bool_assignment(flag: bool) -> bool {
    var x: bool = false;
    x = flag;
    return x;
}

fn nullable_null_assignment() -> ?*mut u8 {
    var p: ?*mut u8 = null;
    p = null;
    return p;
}

fn same_pointer_assignment(p: *mut u32) -> *mut u32 {
    var q: *mut u32 = p;
    q = p;
    return q;
}

fn global_assignment(value: u32) -> u32 {
    shared_value = value;
    return shared_value;
}

fn local_shadows_global_assignment() -> bool {
    var shared_value: bool = false;
    shared_value = true;
    return shared_value;
}
