// selfhost_optunit_user — behavioral fixture for mcc2's VALUE OPTIONALS (`?usize`, G11 in the
// subset). It is compiled by the standalone mcc2 CLI to C, linked with the driver in
// tools/toolchain/selfhost-mem-test.sh, and its exported functions are called + asserted. This proves
// the value-optional lowering (tagged `mc_opt_usize {present,value}`) RUNS correctly through clang —
// not merely that it compiles. It uses no imports so it needs no multi-file loader.
//
// The producer `find_ge` returns a `?usize` (`x` when `x >= t`, else `null`); the two consumers
// exercise the two narrowing forms the plan requires: `if let` (payload binding) and `== null`.

// Returns `x` if it meets the threshold, else the absent optional.
fn find_ge(x: usize, t: usize) -> ?usize {
    if x >= t {
        return x;
    }
    return null;
}

// Consume via `if let`: payload + 1 when present, else 0.
export fn iflet_or_zero(x: usize, t: usize) -> usize {
    if let v = find_ge(x, t) {
        return v + 1;
    }
    return 0;
}

// Consume via `== null`: 1 when absent, 0 when present. Also exercises a `?usize` local + coercion of
// a call result into an optional-typed `let`.
export fn is_absent(x: usize, t: usize) -> usize {
    let r: ?usize = find_ge(x, t);
    if r == null {
        return 1;
    }
    return 0;
}

// Consume via `!= null` on a directly-returned optional (no local temp).
export fn is_present(x: usize, t: usize) -> usize {
    if find_ge(x, t) != null {
        return 1;
    }
    return 0;
}
