// SPEC: section=traits
// SPEC: milestone=traits-tier2
// SPEC: phase=parse,sema,lower-c
// SPEC: expect=pass
// SPEC: check=traits-tier2-dyn-accept

// Tier 2 accept (docs/traits-design.md §4,5,8): an object-safe trait (one borrow-self
// method), an impl, the checked coercion `&x` -> `*dyn Shape`, and a dynamic dispatch
// `s.area()` through the rodata vtable. No diagnostics.

trait Shape {
    fn area(self: *Self) -> u32;
}

struct Square {
    side: u32,
}

impl Shape for Square {
    fn area(self: *Square) -> u32 {
        return self.side * self.side;
    }
}

fn dispatch(s: *dyn Shape) -> u32 {
    return s.area(); // dynamic dispatch: s.vtable->area(s.data)
}

export fn traits_dyn_accept() -> u32 {
    var sq: Square = .{ .side = 5 };
    let s: *dyn Shape = &sq; // checked coercion: emits {data=&sq, vtable=&__vt_Square_Shape}
    return dispatch(s);      // 25
}
