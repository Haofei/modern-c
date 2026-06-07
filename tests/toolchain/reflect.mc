// Comptime reflection (§22): `sizeof`/`alignof` fold to constants via the MC
// layout model. The comptime asserts here validate the *folding*; reflect-test.sh
// then emits the C and `_Static_assert`s the same numbers against clang's real
// `sizeof`/`_Alignof`, validating that the model matches the C ABI.
extern struct Packet {
    a: u8,
    b: u8,
    c: u8,
}

extern struct Quad {
    x: u32,
    y: u32,
}

extern struct Buf {
    data: [16]u8,
}

fn layout_checks() -> void {
    comptime {
        assert(sizeof(u8) == 1);
        assert(sizeof(u32) == 4);
        assert(sizeof(u64) == 8);
        assert(alignof(u64) == 8);
        assert(sizeof(Packet) == 3);
        assert(alignof(Packet) == 1);
        assert(sizeof(Quad) == 8);
        assert(alignof(Quad) == 4);
        assert(sizeof(Buf) == 16);
    }
}
