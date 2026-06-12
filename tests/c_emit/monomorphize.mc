// Comptime-parameter monomorphization (§22): a type-generic function whose
// comptime parameter drives a type (`[N]u8`) is specialized per call. Each
// distinct argument yields one concrete C function (`fill__4`, `fill__8`) with
// `N` substituted in both the type and the body; call sites use the mangled
// name. The whole thing must lower to compilable C.

fn fill(comptime N: usize, value: u8) -> [N]u8 {
    var a: [N]u8 = uninit;
    var i: usize = 0;
    while i < N {
        a[i] = value;
        i = i + 1;
    }
    return a;
}

fn make_small() -> [4]u8 {
    return fill(4, 1);
}

fn make_big() -> [8]u8 {
    return fill(8, 2);
}

fn first_of_small() -> u8 {
    let a: [4]u8 = fill(4, 9);
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
