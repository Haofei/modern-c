// Reject fixture (S0.1 definite-init): an aggregate `var x: T = uninit;`
// remains pending until whole assignment; member/index/value reads before that
// are compile errors.
// EXPECT: E_USE_BEFORE_INIT

struct Header {
    len: u32,
}

fn read_uninit_aggregate_member() -> u32 {
    var h: Header = uninit;
    return h.len;
}
