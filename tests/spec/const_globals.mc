// SPEC: section=22
// SPEC: milestone=const-globals
// SPEC: phase=parse,sema,lower-c
// SPEC: expect=pass,compile_error
// SPEC: check=E_ARRAY_LITERAL_LENGTH,E_COMPTIME_TRAP

// Named compile-time constants (section 22). A `const NAME: T = <comptime
// constant>` global folds at compile time and can drive array lengths and
// comptime assertions; an initializer may reference earlier const globals.

const MAX: usize = 4;
const DOUBLE: usize = MAX * 2;

const fn align_up(x: usize, a: usize) -> usize {
    return (x + a - 1) & ~(a - 1);
}

const ALIGNED: usize = align_up(3, 4);

fn accept_const_global_array() -> [MAX]u8 {
    return .{1, 2, 3, 4};
}

fn accept_derived_const_global_array() -> [DOUBLE]u8 {
    return .{1, 2, 3, 4, 5, 6, 7, 8};
}

fn accept_const_fn_const_global_array() -> [ALIGNED]u8 {
    return .{1, 2, 3, 4};
}

fn accept_const_global_runtime_use() -> usize {
    return DOUBLE;
}

fn accept_comptime_const_global_assert() -> void {
    comptime {
        assert(MAX == 4);
        assert(DOUBLE == 8);
        assert(ALIGNED == 4);
        assert(DOUBLE == MAX * 2);
    }
}

fn reject_const_global_array_length() -> [MAX]u8 {
    // EXPECT_ERROR: E_ARRAY_LITERAL_LENGTH
    return .{1, 2, 3};
}

fn reject_comptime_const_global_assert() -> void {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_TRAP
        assert(DOUBLE == 9);
    }
}
