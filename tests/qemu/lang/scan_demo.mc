import "std/scan.mc";

struct Target { value: u32 }
fn is_target(t: *mut Target, x: u32) -> bool {
    return x == t.value;
}

// Scalar-env predicate: the captured target is a bare `u32`, not a pointer. The
// closure's `void*`/`ptr` env slot is filled by widening the scalar through
// `uintptr_t`/`inttoptr`, and a compiler-generated thunk narrows it back here.
fn equals_target(target: u32, x: u32) -> bool {
    return x == target;
}

global g_t: Target;

export fn scan_run() -> u32 {
    var pass: u32 = 1;
    let arr: [8]u32 = .{ 10, 20, 30, 40, 0, 0, 0, 0 };

    g_t.value = 30;
    let p1: closure(u32) -> bool = bind(&g_t, is_target);
    if find_index(u32, 8, arr, p1) != 2 { pass = 0; } // 30 at index 2

    g_t.value = 99; // absent
    let p2: closure(u32) -> bool = bind(&g_t, is_target);
    if find_index(u32, 8, arr, p2) != 8 { pass = 0; } // not found -> N

    g_t.value = 99;
    let p3: closure(u32) -> bool = bind(&g_t, is_target);
    if any(u32, 8, arr, p3) { pass = 0; } // 99 absent

    g_t.value = 40;
    let p4: closure(u32) -> bool = bind(&g_t, is_target);
    if !any(u32, 8, arr, p4) { pass = 0; } // 40 present

    // Scalar-env closures: capture a `u32` directly (no pointer/global).
    let s1: closure(u32) -> bool = bind(20, equals_target);
    if find_index(u32, 8, arr, s1) != 1 { pass = 0; } // 20 at index 1

    let s2: closure(u32) -> bool = bind(7, equals_target);
    if find_index(u32, 8, arr, s2) != 8 { pass = 0; } // 7 absent -> N

    let s3: closure(u32) -> bool = bind(10, equals_target);
    if !any(u32, 8, arr, s3) { pass = 0; } // 10 present
    return pass;
}
