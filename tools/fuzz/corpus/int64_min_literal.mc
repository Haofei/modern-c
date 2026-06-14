// Regression (differential, C-backend): the most-negative i64 literal was emitted as
// `-(9223372036854775808)`, but 2^63 > LLONG_MAX so C typed the bare decimal *unsigned* and the
// negation stayed unsigned, flipping the sign of any comparison it fed. Fixed in lower_c.zig by
// emitting `(-9223372036854775807LL - 1)`. LLVM was always correct, so this surfaced as a
// C-vs-LLVM divergence.
export fn harness() -> u64 {
    var v: i64 = -9223372036854775808;
    var r: u64 = 0;
    if v < 0 { r = (r ^ 1); }
    if v < -1 { r = (r ^ 2); }
    return r;
}
