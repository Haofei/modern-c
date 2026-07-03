// SPEC: section=32.7
// SPEC: milestone=traits-tier2
// SPEC: phase=parse,sema
// SPEC: expect=compile_error
// SPEC: check=E_NULLABLE_DYN_NARROW

trait CharDevice {
    fn putc(self: *Self, b: u8) -> void;
}

fn reject_nullable_dyn_without_narrowing(maybe: ?*dyn CharDevice) -> *dyn CharDevice {
    return maybe; // EXPECT_ERROR: E_NULLABLE_DYN_NARROW
}
