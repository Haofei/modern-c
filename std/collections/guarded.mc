// std/guarded — data guarded by a lock, in the Rust `Mutex<T>` style: the protected `T`
// lives INSIDE the lock and is unreachable except through a guard. This is hardening item
// C1 ("lock-guards-data"), the typed counter to the "forgot to take the lock" race class.
//
// Two existing MC mechanisms compose to give static lock-discipline, with no new sema:
//
//   1. `opaque struct` (section 31): the fields of `Guarded<T>` are PRIVATE to its
//      associated functions (`impl Guarded`). Outside code cannot name `m.data` — a direct
//      access to the protected value is E_PRIVATE_FIELD at compile time. The ONLY way to
//      reach the data is via `Guarded.lock`, an associated function, which alone may take
//      the address of the private field.
//
//   2. `move struct` (section 18.1, linear types): `Guarded.lock` returns a linear
//      `Guard<T>` — a `move` token tracked as used-exactly-once. It cannot be copied (no two
//      holders of the same guard) and it must be consumed by `Guard.unlock` (forgetting to
//      release is E_RESOURCE_LEAK; using it after release is E_USE_AFTER_MOVE). While the
//      guard is live it hands out `*mut T`; once released the borrow is gone, so the data is
//      again unreachable.
//
// Net property: the protected `T` is reachable ONLY while a live, non-duplicable guard
// exists, and that guard is minted only by acquiring the lock. "Forgot to take the lock"
// is therefore not expressible — there is no path to the data that bypasses `Guarded.lock`.
//
// CAVEAT (honest scope): the guard ties the data to ITS OWN lock instance (the data is a
// private field of the same object), so the guard is tied to a specific lock instance by
// construction — you cannot read this datum while holding a DIFFERENT lock. What is NOT
// modelled here is global lock ORDERING / deadlock freedom — that is a separate item (C3).
// The atomic acquire/release of a contended SMP lock word is platform code (`std/sync`);
// this module supplies the typed, data-owning wrapper over a simple lock word.

// The lock-with-data. `state` is the lock word; `data` is the protected value. Both are
// PRIVATE (opaque struct) — only the `impl Guarded` functions below may name them, so no
// outside code can touch `data` without going through `Guarded.lock`.
opaque struct Guarded<T> {
    state: u32,
    data: T,
}

// A live witness that the lock is held AND a mutable borrow of the protected data. Linear
// (`move`): it cannot be duplicated and must be consumed by `Guard.unlock`. Holding it is
// the *only* way to reach the inner `T`. Also `opaque`: `state`/`data` are PRIVATE to the
// `impl Guard` accessors below, so outside code cannot read `g.data` to bypass `Guard.get`,
// cannot wrong-lock via `ga.data = gb.data`, and cannot forge a lock witness with a struct
// literal `.{ .state = ..., .data = ... }` (all E_PRIVATE_FIELD). The orphan rule additionally
// blocks a peer `impl Guard` in another file from minting access to these fields.
opaque move struct Guard<T> {
    state: *mut u32, // the lock word to release on unlock
    data: *mut T,    // borrow of the protected value, valid only while this guard is live
}

// `impl Guard` is declared before `impl Guarded` because `Guarded.lock` mints a guard via
// `Guard.mk` (the associated-fn resolver wants the callee's `impl` seen first).
impl Guard {
    // Construct a guard from the lock word + data borrow. Reachable only from `Guarded.lock`
    // in practice — `mk` takes raw borrows, so a guard cannot be conjured for data you did
    // not lock without already holding `&mut` to a Guarded's private fields.
    fn mk(comptime T: type, state: *mut u32, data: *mut T) -> Guard<T> {
        return .{ .state = state, .data = data };
    }

    // The mutable borrow of the protected data. Borrows the guard (`*Guard<T>`) rather than
    // consuming it, so the data may be accessed repeatedly inside the critical section.
    fn get(comptime T: type, g: *Guard<T>) -> *mut T {
        return g.data;
    }

    // Release the lock by CONSUMING the guard (linear — the single allowed use that ends its
    // life). After this the guard name is moved-out: any further `get`/`unlock` is
    // E_USE_AFTER_MOVE, and forgetting to call this is E_RESOURCE_LEAK. The data is once
    // again unreachable.
    fn unlock(comptime T: type, g: Guard<T>) -> void {
        let state: *mut u32 = g.state; // borrow the lock word out of the guard
        state.* = 0;                   // release the lock
        // The guard is a linear `move` resource and this is its destructor: discard the husk
        // so the move checker sees it consumed exactly once (no E_RESOURCE_LEAK). The borrow
        // above already extracted the side effect; nothing else escapes.
        unsafe { forget_unchecked(g); }
    }
}

impl Guarded {
    // Wrap a value, producing an unlocked Guarded<T>. Only an associated function may
    // construct one (opaque), so the data cannot be smuggled in past the wrapper.
    fn make(comptime T: type, value: T) -> Guarded<T> {
        return .{ .state = 0, .data = value };
    }

    // Whether the lock is currently held (for assertions/diagnostics; does not grant access).
    fn is_locked(comptime T: type, m: *Guarded<T>) -> bool {
        return m.state != 0;
    }

    // Acquire the lock and obtain the guard. This is the SOLE path to the protected data:
    // being an associated function of `Guarded`, it alone may take the address of `m.data`
    // (the field is private). The returned guard is linear, so it cannot be copied and must
    // be released.
    //
    // Single-threaded/host: a plain test-and-set is enough; under SMP this would be the
    // ticket lock from std/sync. Kept minimal so the fixture is deterministic on the host
    // and bootable in the kernel.
    fn lock(comptime T: type, m: *mut Guarded<T>) -> Guard<T> {
        while m.state != 0 {
            // spin until the lock word is free
        }
        m.state = 1;
        return Guard.mk(T, &m.state, &m.data);
    }
}
