extern fn make_u32_slice() -> []const u32;

fn break_in_while(flag: bool) -> void {
    while flag {
        break;
    }
}

fn continue_in_while(flag: bool) -> void {
    while flag {
        continue;
    }
}

fn break_continue_in_for(xs: []const u32) -> void {
    for x in xs {
        continue;
    }

    for y in xs {
        break;
    }
}

fn for_binding_slice_element(xs: []const u32) -> u32 {
    for x in xs {
        return x;
    }
    return 0;
}

fn for_binding_array_element(xs: [4]u32) -> u32 {
    for x in xs {
        return x;
    }
    return 0;
}

fn for_binding_direct_call_slice_element() -> u32 {
    for x in make_u32_slice() {
        return x;
    }
    return 0;
}
