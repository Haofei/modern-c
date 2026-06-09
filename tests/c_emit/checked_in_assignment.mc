// Checked arithmetic assigned into a struct field or array element has no
// target type carried by the assignment path (assignmentTargetType only knows
// idents), so the value must still infer its type from the operands and lower
// through the checked helper.

struct S { v: u32 }

fn field_target(s: S, a: u32, b: u32) -> S {
    var r: S = s;
    r.v = a + b;
    return r;
}

fn element_target(a: u32, b: u32) -> u32 {
    var xs: [4]u32 = uninit;
    xs[0] = a + b;
    return xs[0];
}

fn field_mul(s: S, a: u32) -> S {
    var r: S = s;
    r.v = a * 2;
    return r;
}
