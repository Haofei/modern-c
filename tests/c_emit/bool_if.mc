// Boolean `if` (desugars to a bool `switch`): guards, `else`, `else if`, and a
// `!` condition all lower to compilable C.
fn classify(x: u32, flag: bool) -> u32 {
    if x == 0 {
        return 10;
    }
    if !flag {
        return 20;
    }
    if x > 100 {
        return 30;
    } else if x > 10 {
        return 31;
    } else {
        return 32;
    }
}
