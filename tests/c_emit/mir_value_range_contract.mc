// MIR value-range fact consumption under `#[unsafe_contract(no_overflow)]`.
//
// Distinct from `c_emit_value_range.mc` (which proves *constant-operand* trap
// elimination): here the optimizer consumes MIR `no_overflow` range facts for
// `unchecked.add/sub/mul`, lowering them to plain C arithmetic (no checked
// helper, no trap edge) across the shapes the MIR builder records facts for —
// return, local, cast-wrapped local, nested operands, and aggregate fields.
// Each emitted op is preceded by an `MC_MIR_RANGE` provenance marker.

// Top-level return: the covered op lowers to plain `+`.
fn ret_add(a: u32, b: u32) -> u32 {
    #[unsafe_contract(no_overflow)]
    {
        return unchecked.add(a, b);
    }
}

// Typed local initializer.
fn local_sub(a: u32, b: u32) -> u32 {
    #[unsafe_contract(no_overflow)]
    {
        let x: u32 = unchecked.sub(a, b);
        return x;
    }
}

// Nested operands: an outer covered op whose operands are themselves covered
// ops all flatten to plain arithmetic (`(a + b) + (c * d)`), no checked call.
fn nested_chain(a: u32, b: u32, c: u32, d: u32) -> u32 {
    #[unsafe_contract(no_overflow)]
    {
        let x: u32 = unchecked.add(unchecked.add(a, b), unchecked.mul(c, d));
        return x;
    }
}

// Cast-wrapped: the range fact survives a widening cast on the result.
fn cast_local(a: u16, b: u16) -> u32 {
    #[unsafe_contract(no_overflow)]
    {
        let x: u32 = unchecked.add(a, b) as u32;
        return x;
    }
}

struct Pair { lo: u32, hi: u32 }

// Aggregate field initializers each carry their own range fact (`target=lo`,
// `target=hi`) and lower to plain arithmetic.
fn aggregate_field(a: u32, b: u32) -> Pair {
    #[unsafe_contract(no_overflow)]
    {
        return .{ .lo = unchecked.add(a, b), .hi = unchecked.mul(a, b) };
    }
}
