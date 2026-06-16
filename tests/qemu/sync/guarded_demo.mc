// C1 — lock-guards-data demo (Rust `Mutex<T>` style). The protected counter lives inside a
// `Guarded<u32>` and is reachable ONLY through the linear guard returned by `Guarded.lock`.
// Each critical section: lock -> mutate via the guard's `*mut T` -> unlock (consumes the
// linear guard). A direct field access (`m.data`) would be E_PRIVATE_FIELD; a use of the
// guard after `unlock` would be E_USE_AFTER_MOVE; forgetting `unlock` would be
// E_RESOURCE_LEAK. This entry returns the final guarded value (42) so the differential
// backend test can compare C vs LLVM lowering of the opaque/move machinery.

import "std/guarded.mc";

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

    return result; // 42
}
