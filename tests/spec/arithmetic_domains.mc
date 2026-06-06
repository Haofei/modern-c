// SPEC: section=5.2,5.3,6.2,I.2,I.3
// SPEC: milestone=arithmetic-domains
// SPEC: phase=sema,mir,lower-c
// SPEC: expect=pass,inspect
// SPEC: check=arithmetic-domain-no-trap,arithmetic-domain-lowering

fn wrap_add(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> {
    return a + b;
}

fn wrap_bitwise(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> {
    return a & b;
}

fn sat_add(a: sat<u32>, b: sat<u32>) -> sat<u32> {
    return a + b;
}

fn sat_mul(a: sat<u16>, b: sat<u16>) -> sat<u16> {
    return a * b;
}
