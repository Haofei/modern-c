// SPEC: section=31
// SPEC: milestone=lock-guards-data
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_PRIVATE_FIELD,E_USE_AFTER_MOVE,E_RESOURCE_LEAK

// C1 — lock-guards-data: data guarded by a lock, Rust `Mutex<T>` style. The protected `T`
// lives INSIDE a `Guarded<T>` and is reachable ONLY through a linear `Guard<T>` obtained by
// locking. This mirrors `std/guarded` inline (spec fixtures are parsed standalone, without
// imports). Two existing mechanisms compose — no new sema:
//   - `opaque struct` makes the protected field private → a DIRECT access is E_PRIVATE_FIELD.
//   - `move struct` makes the guard linear → it can't be copied, must be released
//     (E_RESOURCE_LEAK if forgotten), and can't be used after release (E_USE_AFTER_MOVE).
// "Forgot to take the lock" is thus not expressible: there is no path to the data that
// bypasses `Guarded.lock`.

// The protected value lives inside the lock; its fields are private (opaque).
opaque struct Guarded<T> {
    state: u32,
    data: T,
}

// A live, linear (`move`) witness: holding it is the only way to reach the inner T.
move struct Guard<T> {
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
    // The SOLE path to the data: only this associated fn may take the address of `m.data`
    // (private).
    fn lock(comptime T: type, m: *mut Guarded<T>) -> Guard<T> {
        while m.state != 0 {
        }
        m.state = 1;
        return Guard.mk(T, &m.state, &m.data);
    }
}

// --- accepted: access ONLY through the guard, guard consumed exactly once ---

fn accept_access_through_guard() -> u32 {
    var m: Guarded<u32> = Guarded.make(u32, 41);
    var g: Guard<u32> = Guarded.lock(u32, &m); // the only path to the data
    let p: *mut u32 = Guard.get(u32, &g);          // borrow the data through the live guard
    p.* = p.* + 1;
    let v: u32 = p.*;
    Guard.unlock(u32, g);                          // consume the guard (release the lock)
    return v;                                       // 42
}

fn accept_relock_after_release() -> u32 {
    var m: Guarded<u32> = Guarded.make(u32, 10);
    var g1: Guard<u32> = Guarded.lock(u32, &m);
    let a: u32 = Guard.get(u32, &g1).*;
    Guard.unlock(u32, g1);                          // first critical section ends
    var g2: Guard<u32> = Guarded.lock(u32, &m); // distinct, fresh guard — re-acquire is fine
    let b: u32 = Guard.get(u32, &g2).*;
    Guard.unlock(u32, g2);
    return a + b;
}

// --- rejected: direct access to the protected data WITHOUT a guard ---
// The inner value is a private field of the opaque `Guarded<T>`; naming it outside the
// `impl Guarded` is a compile error — this is the "forgot to take the lock" attempt.

fn reject_direct_read(m: *Guarded<u32>) -> u32 {
    // EXPECT_ERROR: E_PRIVATE_FIELD
    return m.data;
}

fn reject_direct_write(m: *mut Guarded<u32>) -> void {
    // EXPECT_ERROR: E_PRIVATE_FIELD
    m.data = 7;
}

fn reject_forge_guarded() -> Guarded<u32> {
    // EXPECT_ERROR: E_PRIVATE_FIELD
    return .{ .state = 0, .data = 99 };
}

// --- rejected: the guard is linear — use after release is rejected by the move checker ---

fn reject_use_after_release() -> u32 {
    var m: Guarded<u32> = Guarded.make(u32, 1);
    var g: Guard<u32> = Guarded.lock(u32, &m);
    Guard.unlock(u32, g); // consumes the guard
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let p: *mut u32 = Guard.get(u32, &g);
    return p.*;
}

// --- rejected: the guard is linear — forgetting to release leaks the resource ---

fn reject_forget_release() -> u32 {
    var m: Guarded<u32> = Guarded.make(u32, 2);
    // EXPECT_ERROR: E_RESOURCE_LEAK
    var g: Guard<u32> = Guarded.lock(u32, &m); // never unlocked
    let p: *mut u32 = Guard.get(u32, &g);
    return p.*;
}
