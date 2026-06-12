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

fn first_from_slice(xs: []const u32) -> u32 {
    for x in xs {
        return x;
    }
    return 0;
}

fn first_from_array(xs: [4]u32) -> u32 {
    for x in xs {
        return x;
    }
    return 0;
}

fn first_from_call() -> u32 {
    for x in make_u32_slice() {
        return x;
    }
    return 0;
}

fn for_continue(xs: []const u32) -> u32 {
    var total: u32 = 0;
    for x in xs {
        total = total + x;
        continue;
    }
    return total;
}

fn for_break(xs: []const u32) -> u32 {
    var seen: u32 = 0;
    for x in xs {
        seen = x;
        break;
    }
    return seen;
}
