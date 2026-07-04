// SPEC: section=22
// SPEC: milestone=monomorphize-pattern-type-mentions
// SPEC: phase=parse,sema
// SPEC: expect=compile_error
// SPEC: check=E_NO_IMPLICIT_CONVERSION

// A switch literal pattern can make an otherwise concrete function type-generic
// because the pattern expression mentions a comptime type parameter in type
// position. The casted pattern is still rejected by sema's literal-pattern rule;
// this fixture pins the monomorphizer's body scan before that diagnostic.

fn switch_pattern_cast_type_param(comptime T: type, value: u32) -> u32 {
    switch value {
        0 as T => { return 1; }, // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
        _ => { return 0; },
    }
}

fn reject_switch_pattern_cast_type_param(x: u32) -> u32 {
    return switch_pattern_cast_type_param(u32, x);
}
