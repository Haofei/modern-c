// SPEC: section=20.1
// SPEC: milestone=no-lang-trap
// SPEC: phase=verifier
// SPEC: expect=reject,pass
// SPEC: check=E_NO_LANG_TRAP_EDGE,no-language-trap-edge

#[no_lang_trap]
fn reject_checked_add(a: u32, b: u32) -> u32 {
    // EXPECT_ERROR: E_NO_LANG_TRAP_EDGE
    return a + b;
}

#[no_lang_trap]
fn reject_bounds_check(buf: []const u8, i: usize) -> u8 {
    // EXPECT_ERROR: E_NO_LANG_TRAP_EDGE
    return buf[i];
}

#[no_lang_trap]
fn reject_assert(flag: bool) -> void {
    // EXPECT_ERROR: E_NO_LANG_TRAP_EDGE
    assert(flag);
}

#[no_lang_trap]
fn reject_reachable_unreachable() -> never {
    // EXPECT_ERROR: E_NO_LANG_TRAP_EDGE
    return unreachable;
}

#[no_lang_trap]
fn reject_explicit_trap() -> never {
    // EXPECT_ERROR: E_NO_LANG_TRAP_EDGE
    return trap(.Assert);
}

#[no_lang_trap]
fn reject_nullable_try(maybe: ?*const u8) -> *const u8 {
    // EXPECT_ERROR: E_NO_LANG_TRAP_EDGE
    return maybe?;
}

#[no_lang_trap]
fn reject_unwrap_call(maybe: ?*const u8) -> *const u8 {
    // EXPECT_ERROR: E_NO_LANG_TRAP_EDGE
    return unwrap(maybe);
}

#[no_lang_trap]
fn reject_right_shift(a: u32, n: u32) -> u32 {
    // EXPECT_ERROR: E_NO_LANG_TRAP_EDGE
    return a >> n;
}

#[no_lang_trap]
fn reject_checked_negation(a: i32) -> i32 {
    // EXPECT_ERROR: E_NO_LANG_TRAP_EDGE
    return -a;
}

fn trapping_add(a: u32, b: u32) -> u32 {
    return a + b;
}

#[no_lang_trap]
fn reject_call_trapping_fn(a: u32, b: u32) -> u32 {
    // EXPECT_ERROR: E_NO_LANG_TRAP_EDGE
    return trapping_add(a, b);
}

#[no_lang_trap]
fn allow_wrapping_add(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> {
    // EXPECT: verifier accepts because wrapping add has no language-trap edge.
    return wrapping.add(a, b);
}

#[no_lang_trap]
fn allow_wrapping_neg(a: wrap<u32>) -> wrap<u32> {
    // EXPECT: verifier accepts because wrapping negation has no language-trap edge.
    return -a;
}

#[no_lang_trap]
fn allow_saturating_add(a: sat<u32>, b: sat<u32>) -> sat<u32> {
    // EXPECT: verifier accepts because saturating add has no language-trap edge.
    return a + b;
}

#[no_lang_trap]
fn allow_call_no_lang_trap_fn(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> {
    // EXPECT: verifier accepts calls to functions also marked #[no_lang_trap].
    return allow_wrapping_add(a, b);
}

#[no_lang_trap]
fn allow_raw_many_offset_deref(p: [*]const u8, i: usize) -> u8 {
    // EXPECT: verifier accepts unsafe raw pointer access as target-fault capable, not a language trap.
    unsafe {
        return p.offset(i).*;
    }
}

#[naked]
#[no_lang_trap]
export fn allow_boot_asm() -> never {
    // EXPECT: verifier accepts opaque volatile asm as target-fault capable, not a language trap.
    unsafe {
        asm opaque volatile {
            "cli"
            "hlt"
        }
    }
}
