struct Table {
    items: [2]u32,
}

struct Pair {
    left: u32,
    right: u32,
}

struct MaybeBox {
    ptr: ?*mut u32,
}

enum InitError {
    failed,
}

union GlobalToken {
    number: u32,
    eof,
}

const fn static_add(a: u32, b: u32) -> u32 {
    return a + b;
}

const fn static_values() -> [2]u32 {
    return .{ 13, 14 };
}

const fn static_pair() -> Pair {
    return .{ .left = 15, .right = 16 };
}

const fn static_type_size(comptime T: type) -> usize {
    return sizeof(T);
}

const fn static_type_alignment(comptime T: type) -> usize {
    return alignof(T);
}

extern fn consume_default_slice(xs: []const u8) -> usize;

global shared_cell: u32 = 0;
global seed: u32 = 1;
global folded_sum: u32 = 1 + 2;
global folded_call: u32 = static_add(5, 6);
global folded_type_size: usize = static_type_size(u32);
global folded_type_alignment: usize = static_type_alignment(u32);
global copied_seed: u32 = seed;
global letter: u8 = 'A';
global gain: f32 = 1.5;
global bias: f64 = -(0.25);
global cast_seed: u32 = 1 as u32;
global cast_copied_seed: u32 = seed as u32;
global signed_seed: i32 = -1;
global grouped_signed_seed: i16 = (-12);
global first_index: usize = 0;
global values: [2]u32 = .{ 7, 8 };
global folded_values: [2]u32 = static_values();
global copied_values: [2]u32 = values;
global names: [2]*const u8 = .{ "alpha", "beta" };
global copied_names: [2]*const u8 = names;
global raws: [2][*]const u8 = .{ "raw-a", "raw-b" };
global first_value_ptr: *const u32 = &values[first_index];
global table: Table = .{ .items = .{ 11, 12 } };
global copied_table: Table = table;
global pair: Pair = .{ .left = 3, .right = 4 };
global copied_pair: Pair = pair;
global table_item_ptr: *const u32 = &table.items[first_index];
global message: *const u8 = "ready";
global maybe_ptrs: [2]?*mut u32 = .{ null, &seed };
global maybe_box: MaybeBox = .{ .ptr = &seed };
global folded_pair: Pair = static_pair();
global global_const_ptr: *const u32 = &shared_cell;
global global_mut_ptr: *mut u32 = &shared_cell;
global nullable_handle: ?*mut u8 = null;
global default_slice: []const u8;
global default_result: Result<u32, InitError>;
global default_token: GlobalToken;

fn read_shared_cell() -> u32 {
    return shared_cell;
}

fn read_copied_seed() -> u32 {
    return copied_seed;
}

fn read_folded_sum() -> u32 {
    return folded_sum;
}

fn read_folded_call() -> u32 {
    return folded_call;
}

fn read_folded_type_size() -> usize {
    return folded_type_size;
}

fn read_folded_type_alignment() -> usize {
    return folded_type_alignment;
}

fn read_letter() -> u8 {
    return letter;
}

fn read_gain() -> f32 {
    return gain;
}

fn read_bias() -> f64 {
    return bias;
}

fn read_cast_seed() -> u32 {
    return cast_seed;
}

fn read_cast_copied_seed() -> u32 {
    return cast_copied_seed;
}

fn read_signed_seed() -> i32 {
    return signed_seed;
}

fn read_grouped_signed_seed() -> i16 {
    return grouped_signed_seed;
}

fn read_first_value_ptr() -> u32 {
    return first_value_ptr.*;
}

fn read_copied_value() -> u32 {
    return copied_values[1];
}

fn read_folded_value() -> u32 {
    return folded_values[1];
}

fn read_name() -> *const u8 {
    return names[1];
}

fn read_copied_name() -> *const u8 {
    return copied_names[0];
}

fn read_raw_name() -> [*]const u8 {
    return raws[0];
}

fn read_table_item_ptr() -> u32 {
    return table_item_ptr.*;
}

fn read_copied_table_item() -> u32 {
    return copied_table.items[1];
}

fn read_copied_pair() -> u32 {
    return copied_pair.right;
}

fn read_folded_pair() -> u32 {
    return folded_pair.right;
}

fn inferred_pair_right() -> u32 {
    let p = pair;
    return p.right;
}

fn inferred_values_second() -> u32 {
    let xs = values;
    return xs[1];
}

fn inferred_values_first_loop() -> u32 {
    let xs = values;
    for x in xs {
        return x;
    }
    return 0;
}

fn read_message() -> *const u8 {
    return message;
}

fn read_maybe_ptr() -> ?*mut u32 {
    return maybe_ptrs[1];
}

fn set_maybe_ptr(next: ?*mut u32) -> void {
    maybe_ptrs[0] = next;
}

fn read_maybe_box() -> ?*mut u32 {
    return maybe_box.ptr;
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

fn default_slice_len() -> usize {
    return consume_default_slice(default_slice);
}

fn inferred_default_slice_len() -> usize {
    let xs = default_slice;
    return consume_default_slice(xs);
}

fn default_result_value() -> u32 {
    switch default_result {
        ok(v) => { return v; },
        err(e) => { return 0; },
    }
}

fn inferred_default_result_value() -> u32 {
    let result = default_result;
    switch result {
        ok(v) => { return v; },
        err(e) => { return 0; },
    }
}

fn default_token_value() -> u32 {
    switch default_token {
        number(v) => { return v; },
        .eof => { return 0; },
    }
}

fn inferred_default_token_value() -> u32 {
    let token = default_token;
    switch token {
        number(v) => { return v; },
        .eof => { return 0; },
    }
}
