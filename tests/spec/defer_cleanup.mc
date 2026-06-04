// SPEC: section=21
// SPEC: milestone=defer-cleanup
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_DEFER_CONTROL_FLOW

fn close_resource() -> void;

fn accept_lexical_cleanup() -> void {
    defer close_resource();
    return;
}

fn reject_defer_trap() -> void {
    // EXPECT_ERROR: E_DEFER_CONTROL_FLOW
    defer trap(.Assert);
    return;
}

fn reject_defer_unreachable() -> void {
    // EXPECT_ERROR: E_DEFER_CONTROL_FLOW
    defer unreachable;
    return;
}

fn reject_defer_try(maybe: ?*const u8) -> void {
    // EXPECT_ERROR: E_DEFER_CONTROL_FLOW
    defer maybe?;
    return;
}
