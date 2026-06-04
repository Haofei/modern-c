// SPEC: section=8
// SPEC: milestone=loop-control-flow
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_BREAK_OUTSIDE_LOOP,E_CONTINUE_OUTSIDE_LOOP

fn accept_break_in_while(flag: bool) -> void {
    while flag {
        break;
    }
}

fn accept_continue_in_while(flag: bool) -> void {
    while flag {
        continue;
    }
}

fn accept_break_continue_in_for(xs: []const u32) -> void {
    for x in xs {
        continue;
    }

    for y in xs {
        break;
    }
}

fn reject_break_outside_loop() -> void {
    // EXPECT_ERROR: E_BREAK_OUTSIDE_LOOP
    break;
}

fn reject_continue_outside_loop() -> void {
    // EXPECT_ERROR: E_CONTINUE_OUTSIDE_LOOP
    continue;
}
