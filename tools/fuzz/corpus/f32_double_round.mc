// Regression (floatbits, C-backend): f32 constant/arith expressions were computed in C `double`
// and then narrowed (~1 ULP off the LLVM f32 op). Fixed by suffixing f32 literals with `f`
// (emitF32Expr) so the arithmetic happens in float. Observed by bitcast so the rounding bits are
// part of the result (a comparison fold would hide the ~1-ULP divergence).
export fn harness() -> u64 {
    var a: f32 = 0.1;
    var b: f32 = 0.2;
    var c: f32 = (a + b);
    return (bitcast<u32>(c) as u64);
}
