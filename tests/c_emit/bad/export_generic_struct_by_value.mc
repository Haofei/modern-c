// EXPECT: E_EXTERN_STRUCT_BY_VALUE
// Exported generic instantiations still cross the external ABI boundary after
// monomorphization. A struct return must stay rejected until target C ABI
// classification for by-value aggregates exists.

struct Box<T> {
    value: T,
}

export fn bad_generic_u32(value: u32) -> Box<u32> {
    return .{ .value = value };
}
