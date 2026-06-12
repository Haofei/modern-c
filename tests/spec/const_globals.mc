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
const WORD_SIZE: usize = sizeof(u32);

struct ConstPair {
    left: u32,
    right: u32,
}

extern struct ConstPacket {
    len: u16,
    tag: u8,
}

union ConstToken {
    number: u32,
    eof,
}

const fn align_up(x: usize, a: usize) -> usize {
    return (x + a - 1) & ~(a - 1);
}

const fn make_const_numbers() -> [4]u32 {
    return .{ 4, 5, 6, 7 };
}

const fn make_const_pair() -> ConstPair {
    return .{ .left = 8, .right = 9 };
}

const ALIGNED: usize = align_up(3, 4);
const PACKET_SIZE: usize = sizeof(ConstPacket);
const PACKET_TAG_OFFSET: usize = field_offset(ConstPacket, .tag);
const PACKET_TAG_BIT_OFFSET: usize = bit_offset(ConstPacket, .tag);
const TOKEN_REPR: usize = repr_of(ConstToken);
const CONST_NUMBERS: [4]u32 = make_const_numbers();
const CONST_PAIR: ConstPair = make_const_pair();

fn accept_const_global_array() -> [MAX]u8 {
    return .{1, 2, 3, 4};
}

fn accept_derived_const_global_array() -> [DOUBLE]u8 {
    return .{1, 2, 3, 4, 5, 6, 7, 8};
}

fn accept_const_fn_const_global_array() -> [ALIGNED]u8 {
    return .{1, 2, 3, 4};
}

fn accept_reflected_const_global_array() -> [WORD_SIZE]u8 {
    return .{1, 2, 3, 4};
}

fn accept_reflected_struct_const_global_array() -> [PACKET_SIZE]u8 {
    return .{1, 2, 3, 4};
}

fn accept_reflected_field_offset_const_global_array() -> [PACKET_TAG_OFFSET]u8 {
    return .{1, 2};
}

fn accept_reflected_tagged_union_repr_const_global_array() -> [TOKEN_REPR]u8 {
    return .{1, 2, 3, 4};
}

fn accept_const_global_runtime_use() -> usize {
    return DOUBLE;
}

fn accept_const_fn_aggregate_global_runtime_use() -> u32 {
    return CONST_NUMBERS[2] + CONST_PAIR.right;
}

fn accept_comptime_const_global_assert() -> void {
    comptime {
        assert(MAX == 4);
        assert(DOUBLE == 8);
        assert(ALIGNED == 4);
        assert(WORD_SIZE == 4);
        assert(PACKET_SIZE == 4);
        assert(PACKET_TAG_OFFSET == 2);
        assert(PACKET_TAG_BIT_OFFSET == 16);
        assert(TOKEN_REPR == 4);
        assert(DOUBLE == MAX * 2);
        assert(CONST_NUMBERS[1] == 5);
        assert(CONST_PAIR.left == 8);
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
