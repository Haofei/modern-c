// selfhost_emitself_unit_user — the behavioral unit for selfhost-emitself-test. It exercises the two
// language constructs that had to land for mcc2 to compile its OWN emitter (selfhost/emit_c.mc):
//
//   1. PREFIX pointer deref `*p` (C-style, distinct from the postfix `p.*` form) — read AND write
//      through a pointer, including the RE-BORROW `&*p` (address-of a prefix-deref, the idiom
//      emit_c.mc uses as `e_arg_present(p, &*out, ..)` to pass a `*mut Vec<u32>` where a `*Vec<u32>`
//      is wanted). `bump` mutates through `*p`; `deref_roundtrip` also passes `&*px`.
//
//   2. A string literal passed to a `*const u8` PARAMETER — MC string literals coerce to BOTH
//      `[]const u8` and `*const u8` (G12); the emitter must emit the bare C string (not the
//      `[]const u8` fat-pointer slice) at such a call site (`sb_put_cstr(sb, "...")` in emit_c.mc).
//      `first_byte` takes a `*const u8` and reads its first byte with a PREFIX deref, and `str_first`
//      calls it with a string literal.
//
// A C driver (in the gate) links these and asserts the results AT RUNTIME under `clang -Werror`.

// Add `delta` to the u32 pointed to by `p`, in place, via a PREFIX deref (read and write), and return
// the new value (also via prefix deref).
fn bump(p: *mut u32, delta: u32) -> u32 {
    *p = *p + delta;
    return *p;
}

// Prefix deref for read+write, plus the `&*` re-borrow: `&*px` is `&(*px)`, a fresh `*mut u32` alias.
export fn deref_roundtrip() -> u32 {
    var x: u32 = 10;
    let r1: u32 = bump(&x, 5); // x = 15
    let px: *mut u32 = &x;
    let r2: u32 = bump(&*px, 100); // x = 115 (reborrow through &*px)
    return r1 + r2; // 15 + 115 = 130
}

// A `*const u8` parameter, read with a PREFIX deref. Exercises the emitter's bare-C-string lowering
// at the call site AND prefix deref of a `*const u8`.
fn first_byte(s: *const u8) -> u32 {
    let b: u8 = *s;
    return b as u32;
}

// Pass a STRING LITERAL to the `*const u8` parameter: 'A' = 65.
export fn str_first() -> u32 {
    return first_byte("Alpha");
}

// A second string-literal-to-`*const u8` call to prove the lowering is not a one-off: 'Z' = 90.
export fn str_first2() -> u32 {
    return first_byte("Zeta");
}
