// UB class: read of an uninitialized object (C indeterminate value / trap representation).
// MC handling: STATICALLY FORBIDDEN by default — an ordinary `var x: i32;` with no
// initializer is a compile error (section 12: "Ordinary variables must be initialized").
// Explicit `= uninit` storage is allowed for buffers, but its bytes are *unspecified, not
// UB* (no trap representations, no poison) — the program just writes before it reads.  This
// fixture writes every byte it later reads; the rejected "read before init" case is shown in
// the matrix (it would not compile).
export fn ub_uninit_run() -> u32 {
    var pass: u32 = 1;
    var buf: [4]u8 = uninit;   // explicit unspecified bytes (allowed; not UB)
    buf[0] = 1; buf[1] = 2; buf[2] = 3; buf[3] = 4;   // fully written before any read
    var sum: u32 = 0;
    var i: usize = 0;
    while i < 4 {
        sum = sum + (buf[i] as u32);
        i = i + 1;
    }
    if sum != 10 { pass = 0; }
    let x: i32 = 0;            // ordinary vars must be initialized (a bare `var x: i32;` is rejected)
    if x != 0 { pass = 0; }
    return pass;
}
