// Internal functions may continue to pass and return plain structs by value.

struct Plain {
    x: u32,
}

fn roundtrip(p: Plain) -> Plain {
    return p;
}

export fn entry() -> u32 {
    let p: Plain = .{ .x = 7 };
    let q: Plain = roundtrip(p);
    return q.x;
}
