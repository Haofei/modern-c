// Comptime-parameter monomorphization (§22): a type-generic function whose
// comptime parameter drives a type (`[N]u8`) is specialized per call. Each
// distinct argument yields one concrete C function with `N` substituted in both
// the type expression and the body; call sites use the mangled name. The whole
// thing must lower to compilable C.

fn fill_size(comptime N: usize, value: u8) -> usize {
    return sizeof([N]u8) + (value as usize);
}

fn make_small() -> usize {
    return fill_size(4, 1);
}

fn make_big() -> usize {
    return fill_size(8, 2);
}

fn first_of_small() -> u8 {
    let a: [4]u8 = .{ 9, 0, 0, 0 };
    return a[0];
}

struct ReflectBox<T> {
    value: T,
}

fn reflected_box_size(comptime T: type) -> usize {
    return sizeof(ReflectBox<T>);
}

fn reflected_box_alignment(comptime T: type) -> usize {
    return alignof(ReflectBox<T>);
}

fn use_reflected_box_layout() -> usize {
    return reflected_box_size(u32) + reflected_box_alignment(u32);
}
