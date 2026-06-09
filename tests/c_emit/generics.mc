// User-defined generics (§22 type parameters): a `comptime T: type` parameter
// makes a function generic over a type. Each call is monomorphized — one
// concrete C function per type argument (`max__u32`, `max__i32`), with `T`
// substituted everywhere and the type argument dropped from the signature.

fn max(comptime T: type, a: T, b: T) -> T {
    switch a > b {
        true => { return a; },
        false => { return b; },
    }
}

fn identity(comptime T: type, x: T) -> T {
    return x;
}

fn use_max_u32(a: u32, b: u32) -> u32 {
    return max(u32, a, b);
}

fn use_max_i32(a: i32, b: i32) -> i32 {
    return max(i32, a, b);
}

fn use_identity(x: u8) -> u8 {
    return identity(u8, x);
}
