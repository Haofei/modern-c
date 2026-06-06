// SPEC: section=20.1,3,5
// SPEC: milestone=no-lang-trap-conversions
// SPEC: phase=verifier
// SPEC: expect=reject,pass
// SPEC: check=E_NO_LANG_TRAP_EDGE

type W = wrap<u32>;
type S = serial<u32>;
type T = counter<u64>;

// Non-trapping conversions are legal in #[no_lang_trap] (sections 3, 5): a pure
// widening cast, a truncating wrap, a clamping saturate, modulo construction,
// and the raw modulo representative never raise a language trap.
#[no_lang_trap]
fn widen(x: u32) -> u64 {
    return u64.from(x);
}

#[no_lang_trap]
fn truncate_wrap(x: u32) -> u8 {
    return u8.wrap_from(x);
}

#[no_lang_trap]
fn clamp(x: u32) -> u8 {
    return u8.sat_from(x);
}

#[no_lang_trap]
fn make_mod() -> W {
    return W.from_mod(300);
}

#[no_lang_trap]
fn raw(word: W) -> u32 {
    return word.residue();
}

// Non-trapping domain operations are legal too (sections 5.4, 5.5).
#[no_lang_trap]
fn seq_before(a: S, b: S) -> bool {
    return S.before(a, b);
}

#[no_lang_trap]
fn tick_delta(now: T, start: T) -> wrap<u64> {
    return T.delta_mod(now, start);
}

// IEEE floating-point arithmetic never traps (overflow/÷0 give inf/NaN), so it
// is legal in #[no_lang_trap] (section 8.3).
#[no_lang_trap]
fn fmul(x: f32, y: f32) -> f32 {
    return x * y;
}

#[no_lang_trap]
fn fdiv(x: f64, y: f64) -> f64 {
    return x / y;
}

#[no_lang_trap]
fn fneg(x: f64) -> f64 {
    return -x;
}

// trap_from CAN raise a range trap, so it is rejected in #[no_lang_trap].
#[no_lang_trap]
fn narrow_trap(x: u32) -> u8 {
    // EXPECT_ERROR: E_NO_LANG_TRAP_EDGE
    return u8.trap_from(x);
}
