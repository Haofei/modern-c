// Domain (wrap/sat) arithmetic used directly as a comparison operand, in targetless
// position — `(a + b) == c`, `(a - b) != a`, and the same inside an `if` condition.
// These have no target type at the comparison site, so the operand's domain type must
// be recovered and the modular/saturating op emitted (not the trapping checked helper).
// Both backends must lower them identically; this is regression coverage for the
// emit-c targetless-domain-operand path (the LLVM side already handled it).

// wrap<T>: modular, equality only (ordered comparison on a modular domain is rejected).
fn wrap_eq_sum(a: wrap<u32>, b: wrap<u32>) -> bool {
    return (a + b) == b;
}
fn wrap_ne_diff(a: wrap<u32>, b: wrap<u32>) -> bool {
    return (a - b) != a;
}
fn wrap_eq_prod(a: wrap<u32>, b: wrap<u32>) -> bool {
    return (a * b) == a;
}
fn wrap_if_operand(a: wrap<u32>, b: wrap<u32>) -> u32 {
    if (a + b) != b {
        return 1;
    }
    return 0;
}

// sat<T>: saturating, supports both equality and ordered comparison.
fn sat_eq_sum(a: sat<u8>, b: sat<u8>) -> bool {
    return (a + b) == b;
}
fn sat_ge_sum(a: sat<u8>, b: sat<u8>) -> bool {
    return (a + b) >= a;
}
fn sat_if_operand(a: sat<u16>, b: sat<u16>) -> u32 {
    if (a + b) > a {
        return 1;
    }
    return 0;
}

// Mixed: a domain arithmetic operand on each side of one comparison.
fn wrap_both_sides(a: wrap<u32>, b: wrap<u32>) -> bool {
    return (a + b) == (b + a);
}
