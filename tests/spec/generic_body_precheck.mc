// SPEC: section=22,25
// SPEC: milestone=generic-body-precheck
// SPEC: phase=parse,sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_UNKNOWN_IDENTIFIER,E_TRAIT_BOUND_MEMBER

// Type-generic function templates are dropped after monomorphization when they
// have no concrete instantiations. Their bodies must still be semantically
// prechecked so unused templates cannot hide bad names until a later call site.

fn accept_unused_generic_identity(comptime T: type, value: T) -> T {
    return value;
}

fn reject_unused_generic_bad_body(comptime T: type, value: T) -> T {
    drop(value);
    // EXPECT_ERROR: E_UNKNOWN_IDENTIFIER
    return missing_generic_value;
}

trait Shape {
    fn area(self: *Self) -> u32;
}

fn reject_unused_generic_member_without_bound(comptime T: type, x: *T) -> u32 {
    return T.nope(x); // EXPECT_ERROR: E_TRAIT_BOUND_MEMBER
}

fn reject_unused_generic_bound_missing_member(comptime T: type, x: *T) -> u32 where T: Shape {
    return T.nope(x); // EXPECT_ERROR: E_TRAIT_BOUND_MEMBER
}

fn accept_unused_generic_bound_method(comptime T: type, x: *T) -> u32 where T: Shape {
    return T.area(x);
}
