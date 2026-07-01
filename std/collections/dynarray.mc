// std/dynarray — `Vec<T>`: a heap-backed, growable array over an `Allocator`.
//
// This is the growable container the fixed-capacity `Stack`/`Ring`/`SlotMap` cannot be:
// capacity is not part of the type, and `vec_push` grows the backing storage on demand.
// It exists because a compiler (and any unbounded producer) needs a container whose size
// is a runtime value, not a `comptime N`.
//
// OWNERSHIP: `Vec<T>` is a plain COPYABLE struct (like `SlotMap`/`Ring`), not a linear
// `move` type — so it composes freely (stored in other structs, returned, kept in arrays).
// The cost is that freeing is manual: call `vec_free` exactly once when done, and do not
// copy-then-free-both (that double-frees). For the common arena/"allocate a batch, free
// together" pattern the backing allocator reclaims everything at once and `vec_free` is a
// no-op you may skip. `T` must be COPYABLE (grow does a raw element-by-element copy); a
// `Vec<MoveT>` is not supported (hold linear resources behind a copyable handle).
//
// GROWTH MODEL: the `Allocator` trait (std/alloc) exposes only `alloc`/`free` — no
// `realloc` — so growth is allocate-new + copy + free-old. Amortized O(1) push via
// capacity doubling (start 4, then ×2). See docs/self-host-plan.md §3 step 0.0.
//
// ELEMENT ACCESS: every get/set/grow-copy mints a typed `*mut T` with `raw.ptr<T>` and
// dereferences it (`p.* = x` / `out = p.*`). This is deliberate: `raw.load<T>`/`raw.store<T>`
// only lower for SCALAR T on the C backend (an aggregate T yields UnsupportedCEmission), but
// `raw.ptr<T>` + whole-struct deref lowers for both scalar AND struct T on both backends —
// so `Vec<T>` works for struct element types (e.g. `Vec<Token>`, `Vec<AstNode>`), which the
// self-hosting compiler needs pervasively. (Self-host gap ledger G19.)
//
// The allocator is stored in the Vec (its provenance, like `Arc`), so element ops don't
// re-thread it; it is borrowed and must outlive the Vec.

import "std/addr.mc";
import "std/alloc/alloc.mc";

struct Vec<T> {
    data: PAddr,               // backing storage; pa(0) while cap == 0
    len: usize,                // number of live elements
    cap: usize,                // element capacity of `data`
    a: *mut dyn Allocator,     // backing allocator (borrowed provenance)
}

// A fresh empty vector bound to allocator `a`. No allocation happens until the first push.
export fn vec_new(comptime T: type, a: *mut dyn Allocator) -> Vec<T> {
    return .{ .data = pa(0), .len = 0, .cap = 0, .a = a };
}

// Number of live elements.
export fn vec_len(comptime T: type, v: *Vec<T>) -> usize {
    return v.len;
}

// Grow (if needed) so `data` holds at least `need` elements. Allocate-new + copy + free-old.
fn vec_reserve(comptime T: type, v: *mut Vec<T>, need: usize) -> void {
    if v.cap >= need {
        return;
    }
    var newcap: usize = 4;
    if v.cap != 0 {
        newcap = v.cap * 2;
    }
    if newcap < need {
        newcap = need;
    }
    let newdata: PAddr = alloc_bytes(v.a, newcap * sizeof(T), alignof(T));
    var i: usize = 0;
    while i < v.len {
        unsafe {
            let src: *T = raw.ptr<T>(pa_offset(v.data, i * sizeof(T)));
            let dst: *mut T = raw.ptr<T>(pa_offset(newdata, i * sizeof(T)));
            dst.* = src.*;
        }
        i = i + 1;
    }
    if v.cap != 0 {
        free_bytes(v.a, v.data, v.cap * sizeof(T));
    }
    v.data = newdata;
    v.cap = newcap;
}

// Append `x`, growing storage if full. Amortized O(1).
export fn vec_push(comptime T: type, v: *mut Vec<T>, x: T) -> void {
    vec_reserve(T, v, v.len + 1);
    unsafe {
        let p: *mut T = raw.ptr<T>(pa_offset(v.data, v.len * sizeof(T)));
        p.* = x;
    }
    v.len = v.len + 1;
}

// Element at `i` (bounds-checked: out of range traps).
export fn vec_get(comptime T: type, v: *Vec<T>, i: usize) -> T {
    if i >= v.len {
        unreachable; // index out of bounds
    }
    var out: T = uninit;
    unsafe {
        let p: *T = raw.ptr<T>(pa_offset(v.data, i * sizeof(T)));
        out = p.*;
    }
    return out;
}

// Overwrite element `i` (bounds-checked).
export fn vec_set(comptime T: type, v: *mut Vec<T>, i: usize, x: T) -> void {
    if i >= v.len {
        unreachable; // index out of bounds
    }
    unsafe {
        let p: *mut T = raw.ptr<T>(pa_offset(v.data, i * sizeof(T)));
        p.* = x;
    }
}

// Remove and return the last element (traps if empty).
export fn vec_pop(comptime T: type, v: *mut Vec<T>) -> T {
    if v.len == 0 {
        unreachable; // pop from empty vector
    }
    v.len = v.len - 1;
    var out: T = uninit;
    unsafe {
        let p: *T = raw.ptr<T>(pa_offset(v.data, v.len * sizeof(T)));
        out = p.*;
    }
    return out;
}

// Drop all elements (keeps the backing storage for reuse).
export fn vec_clear(comptime T: type, v: *mut Vec<T>) -> void {
    v.len = 0;
}

// Release the backing storage. Call exactly once; the Vec becomes empty (len==cap==0) and
// may be reused (a subsequent push re-allocates). A no-op when nothing is allocated.
export fn vec_free(comptime T: type, v: *mut Vec<T>) -> void {
    if v.cap != 0 {
        free_bytes(v.a, v.data, v.cap * sizeof(T));
    }
    v.data = pa(0);
    v.len = 0;
    v.cap = 0;
}
