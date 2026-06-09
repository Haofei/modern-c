fn accept_raw_many_mut_param(p: [*]mut u8) -> [*]mut u8 {
    let q: [*]mut u8 = p;
    return q;
}

fn accept_raw_many_const_param(p: [*]const u8) -> [*]const u8 {
    let q: [*]const u8 = p;
    return q;
}

fn accept_raw_many_c_void(p: [*]mut c_void) -> [*]mut c_void {
    let q: [*]mut c_void = p;
    return q;
}

fn accept_nullable_raw_many_pointer_null() -> ?[*]mut u8 {
    let p: ?[*]mut u8 = null;
    return p;
}

fn accept_raw_many_offset(p: [*]mut u8, i: usize) -> [*]mut u8 {
    unsafe {
        return p.offset(i);
    }
}

fn accept_raw_many_offset_deref(p: [*]const u8, i: usize) -> u8 {
    unsafe {
        return p.offset(i).*;
    }
}

fn accept_raw_many_offset_inferred_local(p: [*]mut u8, i: usize) -> [*]mut u8 {
    unsafe {
        let q = p.offset(i);
        return q;
    }
}

extern fn make_raw_many() -> [*]mut u8;
extern fn next_index() -> usize;
extern fn next_byte() -> u8;
extern fn consume_raw_many(p: [*]mut u8) -> void;
extern fn consume_byte(value: u8) -> void;
extern fn consume_byte_pointer(p: *mut u8) -> void;

fn ordered_raw_many_offset_return(p: [*]mut u8) -> [*]mut u8 {
    unsafe {
        return p.offset(next_index());
    }
}

fn ordered_raw_many_offset_base_return() -> [*]mut u8 {
    unsafe {
        return make_raw_many().offset(next_index());
    }
}

fn ordered_raw_many_offset_local(p: [*]mut u8) -> [*]mut u8 {
    unsafe {
        let q: [*]mut u8 = p.offset(next_index());
        return q;
    }
}

fn ordered_raw_many_offset_inferred_local(p: [*]mut u8) -> [*]mut u8 {
    unsafe {
        let q = p.offset(next_index());
        return q;
    }
}

fn ordered_raw_many_offset_assignment(p: [*]mut u8) -> [*]mut u8 {
    var q: [*]mut u8 = p;
    unsafe {
        q = p.offset(next_index());
    }
    return q;
}

fn ordered_raw_many_offset_arg(p: [*]mut u8) -> void {
    unsafe {
        consume_raw_many(p.offset(next_index()));
    }
}

fn ordered_raw_many_offset_deref_return(p: [*]const u8) -> u8 {
    unsafe {
        return p.offset(next_index()).*;
    }
}

fn ordered_raw_many_offset_deref_base_return() -> u8 {
    unsafe {
        return make_raw_many().offset(next_index()).*;
    }
}

fn ordered_raw_many_offset_deref_local(p: [*]const u8) -> u8 {
    unsafe {
        let value: u8 = p.offset(next_index()).*;
        return value;
    }
}

fn ordered_raw_many_offset_deref_inferred_local(p: [*]const u8) -> u8 {
    unsafe {
        let value = p.offset(next_index()).*;
        return value;
    }
}

fn ordered_raw_many_offset_deref_assignment(p: [*]const u8) -> u8 {
    var value: u8 = 0;
    unsafe {
        value = p.offset(next_index()).*;
    }
    return value;
}

fn ordered_raw_many_offset_deref_arg(p: [*]const u8) -> void {
    unsafe {
        consume_byte(p.offset(next_index()).*);
    }
}

fn ordered_raw_many_offset_deref_target_index(p: [*]mut u8, value: u8) -> void {
    unsafe {
        p.offset(next_index()).* = value;
    }
}

fn ordered_raw_many_offset_deref_target_value(p: [*]mut u8, i: usize) -> void {
    unsafe {
        p.offset(i).* = next_byte();
    }
}

fn ordered_raw_many_offset_deref_target_base(value: u8) -> void {
    unsafe {
        make_raw_many().offset(next_index()).* = value;
    }
}

fn ordered_raw_many_offset_address_return(p: [*]mut u8) -> *mut u8 {
    unsafe {
        return &p.offset(next_index()).*;
    }
}

fn ordered_raw_many_offset_address_base_return() -> *mut u8 {
    unsafe {
        return &make_raw_many().offset(next_index()).*;
    }
}

fn ordered_raw_many_offset_address_local(p: [*]mut u8) -> *mut u8 {
    unsafe {
        let q: *mut u8 = &p.offset(next_index()).*;
        return q;
    }
}

fn ordered_raw_many_offset_address_assignment(p: [*]mut u8, fallback: *mut u8) -> *mut u8 {
    var q: *mut u8 = fallback;
    unsafe {
        q = &p.offset(next_index()).*;
    }
    return q;
}

fn ordered_raw_many_offset_address_arg(p: [*]mut u8) -> void {
    unsafe {
        consume_byte_pointer(&p.offset(next_index()).*);
    }
}
