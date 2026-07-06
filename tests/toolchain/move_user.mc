// A linear `move` handle round-trips through the toolchain: `move` is a
// compile-time contract, erased to an ordinary struct at the C boundary. The
// consumer is defined in the C driver; the seam passes a pointer (extern fns
// must not pass or return structs by value — E_EXTERN_STRUCT_BY_VALUE, no C
// ABI classification yet), so the MC side consumes the linear handle
// (forget_unchecked) after the C consumer reads through it.
move struct Box {
    value: u32,
}

extern fn box_consume(b: *Box) -> u32;

fn box_new(v: u32) -> Box {
    return .{ .value = v };
}

export fn box_roundtrip(v: u32) -> u32 {
    let b: Box = box_new(v);
    let r: u32 = box_consume(&b);
    unsafe { forget_unchecked(b); }
    return r;
}
