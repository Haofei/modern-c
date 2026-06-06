// SPEC: section=3,5.2,5.3
// SPEC: milestone=scalar-domain-conversions
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_CONVERSION_OPERATION,E_CALL_ARG_COUNT

type W = wrap<u32>;
type Level = sat<u8>;

// Even safe widening is explicit (section 3).
fn widen(a: u32) -> u64 {
    return u64.from(a);
}

// Narrowing names its failure mode (section 3).
fn narrow_trap(x: u32) -> u8 {
    return u8.trap_from(x);
}

fn narrow_wrap(x: u32) -> u8 {
    return u8.wrap_from(x);
}

fn narrow_sat(x: u32) -> u8 {
    return u8.sat_from(x);
}

fn narrow_try(x: u32) -> Result<u8, ConversionError> {
    return u8.try_from(x);
}

// Domain constructors (section 5.2).
fn make_wrap(a: u32) -> W {
    return W.from(a);
}

fn make_wrap_mod() -> W {
    return W.from_mod(300);
}

// residue() exposes the raw modulo representative (section 5.2).
fn raw(word: W) -> u32 {
    return word.residue();
}

// Conversions take exactly one source argument.
fn reject_conv_arity(a: u32) -> u64 {
    // EXPECT_ERROR: E_CALL_ARG_COUNT
    return u64.from(a, a);
}

// Unknown type-level operations are rejected.
fn reject_unknown_conv(x: u32) -> u32 {
    // EXPECT_ERROR: E_CONVERSION_OPERATION
    return u32.into(x);
}

// from_mod is defined only on wrap<T>.
fn reject_from_mod_non_wrap(x: u8) -> Level {
    // EXPECT_ERROR: E_CONVERSION_OPERATION
    return Level.from_mod(x);
}

// residue() is defined only on wrap<T> values.
fn reject_residue_non_wrap(level: Level) -> u8 {
    // EXPECT_ERROR: E_CONVERSION_OPERATION
    return level.residue();
}
