// SPEC: section=22
// SPEC: milestone=comptime-value-eval
// SPEC: phase=parse,sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_COMPTIME_TRAP,E_COMPTIME_ERROR

// Extended comptime value evaluation (section 22): the const folder evaluates floats,
// byte strings, bitcast, expression-switch, optionals/Result, and wrap/sat/checked
// arithmetic domains — but never computes types. A provably-false `comptime { assert(…) }`
// is E_COMPTIME_TRAP; `comptime_error("…")` is E_COMPTIME_ERROR.

const fn area(r: f64) -> f64 { return r * r * 3.0; }
const fn classify(x: u32) -> u32 { let r: u32 = switch x { 0 => 100, _ => 200 }; return r; }
const fn result_or(r: Result<u32, bool>, d: u32) -> u32 { switch r { ok(v) => { return v; }, err(e) => { return d; }, } }
const fn result_ok(r: Result<u32, bool>) -> u32 { if let ok(v) = r { return v; } return 0; }

// --- accepted: every comptime evaluation folds to the expected value ---
fn accept_floats() -> void {
    comptime {
        assert((1.5 * 2.0) == 3.0);
        assert(area(2.0) == 12.0);
        assert((5 as f64) == 5.0);
        assert((3.9 as u32) == 3);
    }
}

fn accept_bitcast() -> void {
    comptime {
        assert(bitcast<u32>(1.0 as f32) == 1065353216);
        assert(bitcast<f32>(1065353216 as u32) == 1.0);
    }
}

// (Byte-string comptime reads — `"abc".len`, `"abc"[0]`, byte compare — also fold; they
// are exercised by the const-folder unit tests rather than here, since a string-literal
// index is not lowerable outside comptime and this fixture is also emit-swept.)

fn accept_expr_switch() -> void {
    comptime {
        assert(classify(0) == 100);
        assert(classify(7) == 200);
    }
}

fn accept_result() -> void {
    comptime {
        assert(result_or(ok(5), 0) == 5);
        assert(result_or(err(true), 9) == 9);
        assert(result_ok(ok(42)) == 42);
    }
}

// (wrap<uN>/sat<uN> domain folding — `wrap_add(200,100)==44`, `sat_add==255` — also folds;
// it is exercised by the const-folder unit tests, as a `(a+b) as u8` over wrap/sat operands
// is comptime-only and this fixture is emit-swept. The checked-overflow trap below does emit.)

// --- rejected: a provably-false comptime assertion is a trap ---
fn reject_false_float_assert() -> void {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_TRAP
        assert((1.5 + 1.5) == 4.0);
    }
}

// --- rejected: checked arithmetic that overflows its declared width traps at comptime ---
const fn checked_add(a: u8, b: u8) -> u8 { return a + b; }
fn reject_checked_overflow() -> void {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_TRAP
        let _x: u8 = checked_add(200, 100);
    }
}

// --- rejected: a custom comptime diagnostic ---
fn reject_comptime_error() -> void {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_ERROR
        comptime_error("capacity must be a power of two");
    }
}
