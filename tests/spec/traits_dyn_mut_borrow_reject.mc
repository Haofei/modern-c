// SPEC: section=32.4
// SPEC: milestone=traits-tier2
// SPEC: phase=parse,sema
// SPEC: expect=compile_error
// SPEC: check=E_DYN_MUT_BORROW

trait Shape {
    fn area(self: *mut Self) -> u32;
}

struct Square {
    side: u32,
}

impl Shape for Square {
    fn area(self: *mut Square) -> u32 {
        return self.side * self.side;
    }
}

fn reject_mut_dyn_from_immutable_place() -> u32 {
    let sq: Square = .{ .side = 5 };
    let d: *mut dyn Shape = &sq; // EXPECT_ERROR: E_DYN_MUT_BORROW
    return 0;
}
