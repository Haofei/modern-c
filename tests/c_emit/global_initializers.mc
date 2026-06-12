struct Table {
    items: [2]u32,
}

global shared_cell: u32 = 0;
global seed: u32 = 1;
global copied_seed: u32 = seed;
global cast_seed: u32 = 1 as u32;
global cast_copied_seed: u32 = seed as u32;
global signed_seed: i32 = -1;
global grouped_signed_seed: i16 = (-12);
global first_index: usize = 0;
global values: [2]u32 = .{ 7, 8 };
global first_value_ptr: *const u32 = &values[first_index];
global table: Table = .{ .items = .{ 11, 12 } };
global table_item_ptr: *const u32 = &table.items[first_index];
global global_const_ptr: *const u32 = &shared_cell;
global global_mut_ptr: *mut u32 = &shared_cell;
global nullable_handle: ?*mut u8 = null;

fn read_shared_cell() -> u32 {
    return shared_cell;
}

fn read_copied_seed() -> u32 {
    return copied_seed;
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

fn read_table_item_ptr() -> u32 {
    return table_item_ptr.*;
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
