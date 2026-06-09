// Checked integer arithmetic used as a comparison operand has no target type
// of its own, but must still lower through the checked helper so the overflow
// trap edge survives. Exercises add/sub/mul/div, unsigned and signed, in both
// operand positions, nested, and under logical connectives.

fn add_eq(a: u32, b: u32, c: u32) -> bool {
    return (a + b) == c;
}

fn mul_both(a: u32, b: u32, c: u32, d: u32) -> bool {
    return (a * b) != (c * d);
}

fn sub_signed(a: i32, b: i32) -> bool {
    return (a - b) > b;
}

fn div_unsigned(a: u32, b: u32) -> bool {
    return (a / b) <= a;
}

fn nested(a: u32, b: u32) -> bool {
    return ((a + b) + a) != b;
}

fn under_logical(a: u32, b: u32) -> bool {
    return (a + b) == b && (a * b) != a;
}

// Signed negation can overflow (`-INT_MIN`); as a targetless comparison
// operand it must still route through the checked-negation helper.
fn neg_signed(a: i32, b: i32) -> bool {
    return (-a) == b;
}

// A bare numeric literal operand adopts its sibling's type, so `a + 1` resolves
// to `a`'s type even with no explicit target (comparison and loop condition).
fn literal_sibling(a: u32) -> bool {
    return (a + 1) == a;
}

fn loop_condition(n: u32) -> u32 {
    var i: u32 = 0;
    while (i + 1) < n {
        i = i + 1;
    }
    return i;
}
