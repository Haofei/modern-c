// SPEC: section=3,9,10,12
// SPEC: milestone=global-initializers
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_GLOBAL_REQUIRES_TYPE,E_VOID_STORAGE,E_NO_IMPLICIT_CONVERSION,E_NULL_NON_NULL_POINTER,E_INTEGER_LITERAL_OUT_OF_RANGE,E_NO_IMPLICIT_POINTER_CONVERSION,E_UNINIT_REQUIRES_STORAGE,E_GLOBAL_INITIALIZER_NOT_STATIC

extern fn make_mut_u8_pointer() -> *mut u8;
extern fn make_seed() -> u32;

struct Table {
    items: [2]u32,
}

struct Pair {
    left: u32,
    right: u32,
}

global seed: u32 = 1;
global copied_seed: u32 = seed;
global letter: u8 = 'A';
global gain: f32 = 1.5;
global bias: f64 = -(0.25);
global cast_seed: u32 = 1 as u32;
global cast_copied_seed: u32 = seed as u32;
global first_index: usize = 0;
global values: [2]u32 = .{ 7, 8 };
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
global nullable_handle: ?*mut u8 = null;

// EXPECT_ERROR: E_VOID_STORAGE
global reject_void_global: void = ();

// EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
global reject_bool_initializer: u32 = false;

// EXPECT_ERROR: E_NULL_NON_NULL_POINTER
global reject_null_nonnull_initializer: *mut u8 = null;

// EXPECT_ERROR: E_GLOBAL_REQUIRES_TYPE
global reject_untyped_initializer = 1;

// EXPECT_ERROR: E_GLOBAL_REQUIRES_TYPE
global reject_untyped_declaration;

// EXPECT_ERROR: E_INTEGER_LITERAL_OUT_OF_RANGE
global reject_out_of_range_initializer: u8 = 256;

// EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
global reject_pointer_initializer_element_mismatch: *mut u16 = make_mut_u8_pointer();

// EXPECT_ERROR: E_UNINIT_REQUIRES_STORAGE
global reject_uninit_initializer: u32 = uninit;

// EXPECT_ERROR: E_GLOBAL_INITIALIZER_NOT_STATIC
global reject_runtime_initializer: u32 = make_seed();
