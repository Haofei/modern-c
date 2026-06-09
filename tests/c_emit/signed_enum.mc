// Signed-repr enums may carry negative discriminants. The enum-value emitter
// must handle the negation, not just bare integer literals.

enum SignedIrq: i8 {
    negative = -1,
    zero = 0,
    positive = 1,
}

fn pass(s: SignedIrq) -> SignedIrq {
    return s;
}

fn make_negative() -> SignedIrq {
    return .negative;
}
