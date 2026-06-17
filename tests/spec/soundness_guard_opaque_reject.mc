// SPEC: section=31
// SPEC: milestone=opaque-guard
// SPEC: phase=sema
// SPEC: expect=compile_error
// SPEC: check=E_PRIVATE_FIELD

// SOUNDNESS REGRESSION LOCK — `Guard` must be opaque.
//
// `std/guarded.mc`'s `Guard<T>` is the lock witness: its `state` (the lock word) and `data`
// (the borrow of the protected value) are the whole security boundary. If `Guard` were a
// plain (non-opaque) `move struct`, outside code could read `g.data` to reach the protected
// datum WITHOUT going through `Guard.get`, wrong-lock by copying `gb.data` into `ga.data`, or
// FORGE a witness with a struct literal `.{ .state = ..., .data = ... }` — all bypassing the
// lock discipline. Making `Guard` an `opaque move struct` turns each of those into
// E_PRIVATE_FIELD. This fixture reads `g.data` from outside the `impl Guard`; it must reject.
import "std/guarded.mc";

fn leak(g: *Guard<u32>) -> *mut u32 {
    return g.data; // private field of an opaque type, read outside impl Guard
}

fn main() -> i32 {
    return 0;
}
