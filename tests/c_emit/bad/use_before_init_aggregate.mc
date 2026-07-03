// Reject fixture (S0.1 definite-init): an aggregate `var x: T = uninit;` may be
// used as storage, but direct member/index/value reads before assignment or
// storage use are compile errors.
// EXPECT: E_USE_BEFORE_INIT

struct Header {
    len: u32,
}

fn read_uninit_aggregate_member() -> u32 {
    var h: Header = uninit;
    return h.len;
}
