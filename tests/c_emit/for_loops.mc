extern fn make_u32_slice() -> []const u32;
extern fn make_u32_slice_from(seed: u32) -> []const u32;
extern fn make_u32_array_from(seed: u32) -> [4]u32;
extern fn next_seed() -> u32;

global global_xs: [3]u32 = .{ 1, 2, 3 };
global global_matrix: [2][2]u32 = .{ .{ 1, 2 }, .{ 3, 4 } };

struct ForBag {
    values: [3]u32,
    rows: [2][2]u32,
}

struct SliceBag {
    values: []const u32,
}

extern fn make_for_bag() -> ForBag;
extern fn make_slice_bag() -> SliceBag;

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

fn first_from_global_array() -> u32 {
    for x in global_xs {
        return x;
    }
    return 0;
}

fn second_from_global_nested_row() -> u32 {
    for row in global_matrix {
        return row[1];
    }
    return 0;
}

fn first_from_array_field(bag: ForBag) -> u32 {
    for x in bag.values {
        return x;
    }
    return 0;
}

fn second_from_field_nested_row(bag: ForBag) -> u32 {
    for row in bag.rows {
        return row[1];
    }
    return 0;
}

fn first_from_call_array_field() -> u32 {
    for x in make_for_bag().values {
        return x;
    }
    return 0;
}

fn first_from_call_slice_field() -> u32 {
    for x in make_slice_bag().values {
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

fn first_from_slice_call_seed() -> u32 {
    for x in make_u32_slice_from(next_seed()) {
        return x;
    }
    return 0;
}

fn first_from_array_call_seed() -> u32 {
    for x in make_u32_array_from(next_seed()) {
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
