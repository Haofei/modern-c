// Full-selfhost P0 negative diagnostic fixture.
//
// EXPECT: E_USE_BEFORE_INIT

fn full_selfhost_bad_read() -> u32 {
    var x: u32 = uninit;
    return x;
}
