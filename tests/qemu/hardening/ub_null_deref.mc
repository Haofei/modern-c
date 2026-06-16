// UB class: null pointer dereference.  MC handling: a nullable pointer `?*mut T` cannot be
// dereferenced until it is narrowed.  The narrowing forms are checked: `if let p = maybe`
// only binds `p` on the non-null branch, and postfix `maybe?` traps (mc_trap_NullUnwrap)
// when the value is null instead of dereferencing it.  So a null deref is either STATICALLY
// FORBIDDEN (must narrow first) or CHECKED + TRAP (`?`).  The `-fno-delete-null-pointer-checks`
// emit flag (see docs/c-ub-matrix.md) keeps the optimizer from assuming a prior access
// proved non-null and deleting a later guard.  This fixture takes only the safe branches.
global g_cell: [1]u32;

fn read_or(maybe: ?*mut u32, fallback: u32) -> u32 {
    if let p = maybe {       // binds only when non-null; no deref on the null path
        return *p;
    }
    return fallback;
}

export fn ub_null_deref_run() -> u32 {
    var pass: u32 = 1;
    g_cell[0] = 77;
    let p: *mut u32 = &g_cell[0];
    // non-null nullable -> if let binds and dereferences safely
    if read_or(p, 0) != 77 { pass = 0; }
    // null nullable -> if let does NOT bind, fallback returned (no deref attempted)
    let n: ?*mut u32 = null;
    if read_or(n, 99) != 99 { pass = 0; }
    return pass;
}
