// SPEC: section=18.1,22
// SPEC: milestone=diagnostic-fixtures
// SPEC: phase=parse,sema
// SPEC: expect=compile_error
// SPEC: check=E_TRIVIAL_DROP_NOT_MOVE,E_TYPE_ARG_REQUIRED

#[trivial_drop] // EXPECT_ERROR: E_TRIVIAL_DROP_NOT_MOVE
struct Plain {
    value: u32,
}

fn type_id(comptime T: type) -> usize {
    return 0;
}

fn reject_runtime_type_argument(value: usize) -> usize {
    return type_id(value); // EXPECT_ERROR: E_TYPE_ARG_REQUIRED
}
