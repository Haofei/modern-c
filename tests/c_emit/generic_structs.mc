// User-defined generic structs (§22): `struct Name<T> { … }` is monomorphized
// per type argument — each `Name<U>` use becomes a concrete `Name__U` struct
// with `T` substituted in its field types, and the generic declaration is
// dropped. Generic functions and generic structs compose
// (`make_pair(comptime T: type) -> Pair<T>`).

struct Pair<T> {
    a: T,
    b: T,
}

fn make_pair(comptime T: type, x: T, y: T) -> Pair<T> {
    return .{ .a = x, .b = y };
}

fn first(p: Pair<u32>) -> u32 {
    return p.a;
}

fn second(p: Pair<u32>) -> u32 {
    return p.b;
}

fn use_u32(x: u32, y: u32) -> u32 {
    let p: Pair<u32> = make_pair(u32, x, y);
    return first(p) + second(p);
}

fn use_u8(x: u8) -> u8 {
    let p: Pair<u8> = make_pair(u8, x, x);
    return p.a;
}
