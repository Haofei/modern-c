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

fn accept_block_lexical_cleanup() -> void {
    defer {
        close_resource();
    };
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

fn reject_defer_block_return() -> void {
    // EXPECT_ERROR: E_DEFER_CONTROL_FLOW
    defer {
        return;
    };
}

fn reject_defer_switch_return(flag: bool) -> void {
    // EXPECT_ERROR: E_DEFER_CONTROL_FLOW
    defer {
        switch flag {
            true => { return; },
            _ => { close_resource(); },
        }
    };
    return;
}

fn reject_defer_block_trap() -> void {
    // EXPECT_ERROR: E_DEFER_CONTROL_FLOW
    defer {
        trap(.Assert);
    };
    return;
}

fn reject_defer_block_break(flag: bool) -> void {
    while flag {
        // EXPECT_ERROR: E_DEFER_CONTROL_FLOW
        defer {
            break;
        };
        break;
    }
}

fn reject_defer_block_continue(flag: bool) -> void {
    while flag {
        // EXPECT_ERROR: E_DEFER_CONTROL_FLOW
        defer {
            continue;
        };
        break;
    }
}
