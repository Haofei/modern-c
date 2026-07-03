// EXPECT: E_EXTERN_STRUCT_BY_VALUE
// Exported functions cross the external ABI boundary. Struct returns must use an
// out pointer until MC implements target C ABI classification for by-value aggregates.

extern "C" struct Packet {
    value: u32,
}

export fn bad() -> Packet {
    return .{ .value = 1 };
}
