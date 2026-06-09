global shared_counter: u32 = 0;
global shared_delta: i32 = 0;
global shared_flag: bool = false;
global shared_index: usize = 0;

struct SharedPair {
    value: u32,
}

global shared_pair: SharedPair;
global shared_values: [4]u32;

fn local_non_racing_access() -> u32 {
    var local: u32 = 1;
    local = local + 1;
    return local;
}

fn possibly_racing_store(x: u32) -> void {
    shared_counter = x;
}

fn possibly_racing_load() -> u32 {
    return shared_counter;
}

fn possibly_racing_signed_store(x: i32) -> void {
    shared_delta = x;
}

fn possibly_racing_signed_load() -> i32 {
    return shared_delta;
}

fn possibly_racing_bool_store(flag: bool) -> void {
    shared_flag = flag;
}

fn possibly_racing_bool_load() -> bool {
    return shared_flag;
}

fn possibly_racing_usize_store(index: usize) -> void {
    shared_index = index;
}

fn possibly_racing_usize_load() -> usize {
    return shared_index;
}

fn possibly_racing_field_store(x: u32) -> void {
    shared_pair.value = x;
}

fn possibly_racing_field_load() -> u32 {
    return shared_pair.value;
}

fn possibly_racing_array_store(index: usize, value: u32) -> void {
    shared_values[index] = value;
}

fn possibly_racing_array_load(index: usize) -> u32 {
    return shared_values[index];
}

fn racing_increment_is_not_atomic() -> void {
    let x = possibly_racing_load();
    possibly_racing_store(x + 1);
}
