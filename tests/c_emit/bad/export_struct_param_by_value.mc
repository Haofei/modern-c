// EXPECT: E_EXTERN_STRUCT_BY_VALUE
// Exported functions cross the external ABI boundary. Struct parameters must stay
// behind pointers until MC implements target C ABI classification for by-value aggregates.

struct Plain {
    value: u32,
}

export fn bad(plain: Plain) -> u32 {
    return plain.value;
}
