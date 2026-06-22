fn initialized_local() -> u32 {
    var x: u32 = 1;
    return x;
}

extern struct Node {
    value: u32,
}

fn explicit_uninit_scalar(value: u32) -> u32 {
    var x: u32 = uninit;
    x = value;
    return x;
}

fn explicit_grouped_uninit_scalar(value: u32) -> u32 {
    var x: u32 = (uninit);
    x = value;
    return x;
}

fn explicit_uninit_array() -> u8 {
    var buf: [4]u8 = uninit;
    buf[0] = 7;
    return buf[0];
}

// NOTE: the scalar read-before-assign negative case (`var x: u32 = uninit; return x;`) is a
// compile error (E_USE_BEFORE_INIT), so it lives in the reject corpus, not here:
//   tests/c_emit/bad/use_before_init_scalar.mc
// Reading an uninit *array element* below is NOT flagged — aggregates are the programmer's
// obligation (c-ub-matrix row 7) — so it stays a valid must-compile fixture.

fn read_materialized_uninit_byte() -> u8 {
    var buf: [4]u8 = uninit;
    return buf[0];
}

fn maybe_uninit_write_assume_init() -> u32 {
    var x: MaybeUninit<Node> = uninit;
    x.write(.{ .value = 7 });
    let node: Node = x.assume_init();
    return node.value;
}

fn grouped_maybe_uninit_write_assume_init() -> u32 {
    var x: MaybeUninit<Node> = uninit;
    x.write((.{ .value = 9 }));
    let node: Node = x.assume_init();
    return node.value;
}
