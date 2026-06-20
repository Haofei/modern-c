// C1 — lock-guards-data demo (Rust `Mutex<T>` style). The protected counter lives inside a
// `Guarded<u32>` and is reachable ONLY through the linear guard returned by `Guarded.lock`.
// Each critical section: lock -> mutate via the guard's `*mut T` -> unlock (consumes the
// linear guard). A direct field access (`m.data`) would be E_PRIVATE_FIELD; a use of the
// guard after `unlock` would be E_USE_AFTER_MOVE; forgetting `unlock` would be
// E_RESOURCE_LEAK. The entry is self-verifying (returns 1 iff the guarded counter ends at
// 42), so both the host-harness entry contract and the differential C-vs-LLVM comparison of
// the opaque/move machinery are satisfied.
//
// The opaque/move types are defined inline (mirroring std/guarded.mc and the spec fixture
// tests/spec/lock_guards_data.mc) rather than imported: the lock discipline lives in `impl`
// associated functions, which are module-private, so a cross-module `Guarded.make` call is
// not resolvable. Defining them here keeps the fixture self-contained and exercises the same
// opaque-struct + linear-`move` machinery the differential test is meant to lower.

// The protected value lives inside the lock; its fields are private (opaque).
opaque struct Guarded<T> {
    state: u32,
    data: T,
}

// A live, linear (`move`) witness: holding it is the only way to reach the inner T.
opaque move struct Guard<T> {
    state: *mut u32,
    data: *mut T,
}

impl Guard {
    fn mk(comptime T: type, state: *mut u32, data: *mut T) -> Guard<T> {
        return .{ .state = state, .data = data };
    }
    fn get(comptime T: type, g: *Guard<T>) -> *mut T {
        return g.data;
    }
    fn unlock(comptime T: type, g: Guard<T>) -> void {
        let state: *mut u32 = g.state; // borrow the lock word out of the guard
        state.* = 0;                   // release the lock
        unsafe { forget_unchecked(g); } // destructor: consume the linear guard husk
    }
}

impl Guarded {
    fn make(comptime T: type, value: T) -> Guarded<T> {
        return .{ .state = 0, .data = value };
    }
    // The SOLE path to the data: only this associated fn may take the address of `m.data`.
    fn lock(comptime T: type, m: *mut Guarded<T>) -> Guard<T> {
        while m.state != 0 {
        }
        m.state = 1;
        return Guard.mk(T, &m.state, &m.data);
    }
}

export fn guarded_run() -> u32 {
    var m: Guarded<u32> = Guarded.make(u32, 0);

    // critical section 1: set to 40 through the guard
    var g1: Guard<u32> = Guarded.lock(u32, &m);
    let p1: *mut u32 = Guard.get(u32, &g1);
    p1.* = 40;
    Guard.unlock(u32, g1); // releases the lock; consumes the linear guard

    // critical section 2: re-acquire a fresh guard and bump by 2
    var g2: Guard<u32> = Guarded.lock(u32, &m);
    let p2: *mut u32 = Guard.get(u32, &g2);
    p2.* = p2.* + 2;
    let result: u32 = p2.*;
    Guard.unlock(u32, g2);

    if result != 42 { return 0; } // 40 + 2, mutated only through the guards
    return 1;
}
