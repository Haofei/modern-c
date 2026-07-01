// Differential-coverage fixture (language gap G11: value optionals `?T`).
// A `?T` for a sized VALUE payload (e.g. `?u32`, `?usize`, `?Point`) has no spare
// sentinel, so it lowers to a TAGGED aggregate `{ present, value }` (C: mc_opt_<T>;
// LLVM: `{ i1, T }`) — distinct from the pointer nullables (null-sentinel repr).
// Both backends must agree on: construction (present value / absent `null`), `if let`
// narrowing, `== null` / `!= null` tag tests, `?` unwrap (trap on absent), returning
// `?T`, and passing `?T` by value across a call. The entry folds every observation
// into a status word; any divergence on EITHER backend makes it return 0.

struct Point { x: u32, y: u32 }

// Construct present (`return v`) and absent (`return null`) `?u32`.
fn maybe_u32(x: u32) -> ?u32 {
    if x > 0 { return x; }
    return null;
}

fn maybe_usize(x: usize) -> ?usize {
    if x > 0 { return x; }
    return null;
}

fn maybe_point(f: bool) -> ?Point {
    if f {
        let p: Point = .{ .x = 3, .y = 4 };
        return p;
    }
    return null;
}

// `if let` narrowing binds the payload `v: u32`.
fn iflet_or(x: u32, fallback: u32) -> u32 {
    if let v = maybe_u32(x) { return v; }
    return fallback;
}

// `== null` / `!= null` tag tests.
fn is_present(x: u32) -> u32 {
    let o: ?u32 = maybe_u32(x);
    if o != null { return 1; }
    return 0;
}

fn is_absent(x: u32) -> u32 {
    let o: ?u32 = maybe_u32(x);
    if o == null { return 1; }
    return 0;
}

// `?` unwrap: yields the payload, traps on absent (only reached when present here).
fn unwrap_present(x: u32) -> u32 {
    let o: ?u32 = maybe_u32(x);
    return o?;
}

// Pass a `?T` by value across a call and observe it through `if let`.
fn passthrough(o: ?u32) -> ?u32 {
    return o;
}

fn iflet_struct(f: bool) -> u32 {
    if let p = maybe_point(f) { return p.x + p.y; }
    return 0;
}

export fn value_optionals_run() -> u32 {
    // present / absent `if let`
    if iflet_or(7, 99) != 7 { return 0; }
    if iflet_or(0, 99) != 99 { return 0; }

    // `!= null` / `== null`
    if is_present(5) != 1 { return 0; }
    if is_present(0) != 0 { return 0; }
    if is_absent(5) != 0 { return 0; }
    if is_absent(0) != 1 { return 0; }

    // `?` unwrap of a present optional
    if unwrap_present(42) != 42 { return 0; }

    // ?usize round-trip
    if let n = maybe_usize(11) {
        if (n as u32) != 11 { return 0; }
    } else {
        return 0;
    }
    if maybe_usize(0) != null { return 0; }

    // pass ?T by value, then narrow
    let forwarded: ?u32 = passthrough(maybe_u32(8));
    if let v = forwarded { if v != 8 { return 0; } } else { return 0; }
    if passthrough(maybe_u32(0)) != null { return 0; }

    // ?Point struct payload
    if iflet_struct(true) != 7 { return 0; }
    if iflet_struct(false) != 0 { return 0; }

    return 1;
}
