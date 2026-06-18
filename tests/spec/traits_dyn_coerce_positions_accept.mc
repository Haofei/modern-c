// SPEC: section=32.4
// SPEC: milestone=traits-tier2
// SPEC: phase=parse,sema,lower-c
// SPEC: expect=pass
// SPEC: check=traits-tier2-dyn-accept

// The uniform `*T -> *dyn Trait` coercion (review #2): a `*dyn Shape` is formed
// from a `*T` VALUE (a `*Square` parameter, not `&x`) at a RETURN, a STRUCT FIELD
// init, and a CALL ARGUMENT. The vtable is synthesized from the static pointee
// type T at each site. Must compile and lower on both backends (valid fat pointer
// with an initialized vtable). No diagnostics.

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

struct Holder {
    inner: *dyn Shape,
}

// RETURN: coerce a `*Square` parameter to a returned `*dyn Shape`.
fn as_dyn(p: *Square) -> *dyn Shape {
    return p;
}

// STRUCT FIELD: initialize a `*dyn Shape` field from a `*Square` parameter.
fn hold(p: *Square) -> Holder {
    return .{ .inner = p };
}

// CALL ARGUMENT: dispatch through a `*dyn Shape` formed at the call site.
fn dispatch(s: *dyn Shape) -> u32 {
    return s.area();
}

export fn traits_dyn_positions() -> u32 {
    var sq: Square = .{ .side = 5 };
    let p: *Square = &sq;

    let d: *dyn Shape = as_dyn(p);   // return-formed
    let h: Holder = hold(p);          // field-formed
    let arg_area: u32 = dispatch(p);  // arg-formed (coercion at the call)

    return d.area() + h.inner.area() + arg_area; // 25 + 25 + 25 = 75
}
