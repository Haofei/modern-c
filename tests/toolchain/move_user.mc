// A linear `move` handle round-trips through the toolchain: `move` is a
// compile-time contract, erased to an ordinary struct at the C boundary. The
// consumer is defined in the C driver (it "consumes" the handle by value).
move struct Box {
    value: u32,
}

extern fn box_consume(b: Box) -> u32;

fn box_new(v: u32) -> Box {
    return .{ .value = v };
}

export fn box_roundtrip(v: u32) -> u32 {
    let b: Box = box_new(v);
    return box_consume(b);
}
