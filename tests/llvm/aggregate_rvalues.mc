struct Bag {
    values: [4]u32,
    tail: []const u32,
}

extern fn make_values(seed: u32) -> [4]u32;
extern fn make_bag(seed: u32) -> Bag;
extern fn next_seed() -> u32;

fn direct_array_call_index(seed: u32, index: usize) -> u32 {
    return make_values(seed)[index];
}

fn call_array_field_index(seed: u32, index: usize) -> u32 {
    return make_bag(seed).values[index];
}

fn call_slice_field_index(seed: u32, index: usize) -> u32 {
    return make_bag(seed).tail[index];
}

fn first_from_array_call(seed: u32) -> u32 {
    for value in make_values(seed) {
        return value;
    }
    return 0;
}

fn first_from_array_field_call(seed: u32) -> u32 {
    for value in make_bag(seed).values {
        return value;
    }
    return 0;
}

fn first_from_seeded_array_call() -> u32 {
    for value in make_values(next_seed()) {
        return value;
    }
    return 0;
}
