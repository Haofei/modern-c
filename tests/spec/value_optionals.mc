// SPEC: section=10
// SPEC: milestone=value-optionals
// SPEC: phase=parse,sema,lower-c,lower-ir
// SPEC: expect=pass
// SPEC: check=value-optional-tagged-repr

// Value optionals `?T` (language gap G11): a `?T` for a sized VALUE payload (e.g. `?u32`,
// `?usize`, `?Point`) has no spare sentinel value, so it lowers to a TAGGED aggregate
// `{ present, value }` (C: mc_opt_<T>; LLVM: `{ i1, T }`) — distinct from the pointer
// nullables (`?*T`, `?c_void*`, `?*dyn`), which keep the null-sentinel repr. The optional
// surface (`null`, `if let`, `== null`, `?` unwrap) is shared; only the lowering differs.

struct Point { x: u32, y: u32 }

// Construction: a `T` value coerces to `?T` (present); `null` coerces to `?T` (absent).
fn some_u32(x: u32) -> ?u32 {
    return x;
}

fn none_u32() -> ?u32 {
    return null;
}

fn some_point() -> ?Point {
    let p: Point = .{ .x = 1, .y = 2 };
    return p;
}

// `if let` narrows the payload to `v: u32` in the then-branch.
fn iflet(o: ?u32, fallback: u32) -> u32 {
    if let v = o {
        return v;
    }
    return fallback;
}

// `== null` / `!= null` test the present tag, yielding bool.
fn is_absent(o: ?u32) -> bool {
    return o == null;
}

fn is_present(o: ?u32) -> bool {
    return o != null;
}

// `?` unwrap yields the payload (traps on absent).
fn unwrap(o: ?u32) -> u32 {
    return o?;
}

// A value optional passes by value across a call and round-trips.
fn passthrough(o: ?usize) -> ?usize {
    return o;
}

// Narrowing a struct payload optional exposes its fields.
fn point_sum(o: ?Point) -> u32 {
    if let p = o {
        return p.x + p.y;
    }
    return 0;
}
