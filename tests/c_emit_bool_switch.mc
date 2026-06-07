// A `switch` on a boolean *expression* (a comparison or logical op) must lower
// to compilable C: the subject is cast to int and a trap default is emitted, so
// clang's -Wswitch-bool and -Wreturn-type are satisfied. Previously the emitter
// only recognised a bool *variable* subject, so these tripped -Werror.

fn min_u32(a: u32, b: u32) -> u32 {
    switch a < b {
        true => { return a; },
        false => { return b; },
    }
}

fn either(a: bool, b: bool) -> u32 {
    switch a && b {
        true => { return 1; },
        false => { return 0; },
    }
}

fn negated(flag: bool) -> u32 {
    switch !flag {
        true => { return 1; },
        false => { return 0; },
    }
}
