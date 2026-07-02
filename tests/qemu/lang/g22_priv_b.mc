// G22 helper B. A second "strict" file whose FILE-PRIVATE `advance` has a DIFFERENT
// signature (TWO arguments) and computes a distinct value. If A's `a_step` were wrongly
// bound to this `advance` (symbol collision / wrong resolution), it would be a 1-arg call to
// a 2-arg function — a hard compile error — so a mis-binding cannot pass silently.
pub fn b_step(x: u32, y: u32) -> u32 {
    return advance(x, y); // must bind to THIS file's advance, not A's
}

fn advance(a: u32, b: u32) -> u32 {
    return a * b + 7;
}
