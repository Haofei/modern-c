// SPEC: section=32.7
// SPEC: milestone=traits-tier2
// SPEC: phase=parse,sema
// SPEC: expect=compile_error
// SPEC: check=E_NULLABLE_DYN_DISPATCH

// Must-narrow rule (docs/spec §32.7): a `?*dyn Trait` is NOT directly dispatchable — it
// may be `none` (the niche has no vtable). Calling a method on an un-narrowed nullable
// trait object is E_NULLABLE_DYN_DISPATCH; you must `if let` / `switch` / `unwrap` first.
// (Without this gate the call is accepted by sema but un-lowerable on both backends.)

trait CharDevice {
    fn putc(self: *Self, b: u8) -> void;
}

struct Uart {
    base: usize,
}

impl CharDevice for Uart {
    fn putc(self: *Uart, b: u8) -> void {}
}

struct Holder {
    dev: ?*dyn CharDevice,
}

fn dispatch_without_narrowing(h: *Holder, b: u8) -> void {
    h.dev.putc(b); // EXPECT_ERROR: E_NULLABLE_DYN_DISPATCH
}
