// SPEC: section=8,12
// SPEC: milestone=local-mutability
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_ASSIGN_TO_IMMUTABLE_LOCAL,E_DUPLICATE_PARAMETER,E_DUPLICATE_LOCAL

fn accept_assign_to_var() -> u32 {
    var x: u32 = 1;
    x = 2;
    return x;
}

fn reject_assign_to_let() -> u32 {
    let x: u32 = 1;
    // EXPECT_ERROR: E_ASSIGN_TO_IMMUTABLE_LOCAL
    x = 2;
    return x;
}

fn reject_assign_to_param(x: u32) -> u32 {
    // EXPECT_ERROR: E_ASSIGN_TO_IMMUTABLE_LOCAL
    x = 2;
    return x;
}

extern struct LocalPacket {
    value: u32,
}

extern fn local_array() -> [4]u32;

fn accept_assign_to_var_field(packet: LocalPacket) -> u32 {
    var local: LocalPacket = packet;
    local.value = 2;
    return local.value;
}

fn reject_assign_to_param_field(packet: LocalPacket) -> u32 {
    // EXPECT_ERROR: E_ASSIGN_TO_IMMUTABLE_LOCAL
    packet.value = 2;
    return packet.value;
}

fn reject_assign_to_let_field(packet: LocalPacket) -> u32 {
    let local: LocalPacket = packet;
    // EXPECT_ERROR: E_ASSIGN_TO_IMMUTABLE_LOCAL
    local.value = 2;
    return local.value;
}

fn reject_assign_to_let_array_element(i: usize, value: u32) -> u32 {
    let xs = local_array();
    // EXPECT_ERROR: E_ASSIGN_TO_IMMUTABLE_LOCAL
    xs[i] = value;
    return xs[i];
}

fn reject_duplicate_local() -> u32 {
    let x: u32 = 1;
    // EXPECT_ERROR: E_DUPLICATE_LOCAL
    let x: u32 = 2;
    return x;
}

// G20: `let`/`var` are BLOCK-scoped, so a name declared in one block may be reused by a
// DISJOINT sibling block (the first binding is dead once its block closes). This compiles.
fn accept_sibling_block_reuse(n: u32) -> u32 {
    var acc: u32 = 0;
    while acc < n {
        let t: u32 = acc;
        acc = acc + t + 1;
    }
    while acc > 10 {
        let t: u32 = acc;   // sibling reuse of `t` — the first `t` is out of scope here
        acc = acc - t + 5;
    }
    {
        let t: u32 = acc;   // another disjoint sibling block reusing `t`
        acc = t;
    }
    return acc;
}

// G20 boundary: reusing a name STILL LIVE in an ENCLOSING block is a live-shadow — rejected.
fn reject_nested_block_shadows_live_enclosing() -> u32 {
    var out: u32 = 0;
    {
        let t: u32 = 1;
        {
            // EXPECT_ERROR: E_DUPLICATE_LOCAL
            let t: u32 = 2;   // the enclosing block's `t` is still live here
            out = out + t;
        }
        out = out + t;
    }
    return out;
}

fn reject_for_binding_shadows_local(xs: []const u32) -> u32 {
    let x: u32 = 1;
    // EXPECT_ERROR: E_DUPLICATE_LOCAL
    for x in xs {
        let y: u32 = x;
    }
    return x;
}

fn reject_if_let_binding_shadows_local(maybe: ?*mut u8, fallback: *mut u8) -> *mut u8 {
    let p: *mut u8 = fallback;
    // EXPECT_ERROR: E_DUPLICATE_LOCAL
    if let p = maybe {
        return p;
    }
    return p;
}

enum LocalError: u8 {
    denied = 1,
}

extern fn local_result() -> Result<u32, LocalError>;

fn reject_result_if_let_binding_shadows_local() -> u32 {
    let v: u32 = 1;
    // EXPECT_ERROR: E_DUPLICATE_LOCAL
    if let ok(v) = local_result() {
        return v;
    }
    return v;
}

union LocalToken {
    int: u32,
    eof,
}

fn reject_switch_binding_shadows_local(token: LocalToken) -> u32 {
    let v: u32 = 1;
    switch token {
        // EXPECT_ERROR: E_DUPLICATE_LOCAL
        int(v) => { return v; },
        _ => { return v; },
    }
}

fn reject_nullable_switch_binding_shadows_local(maybe: ?*mut u8, fallback: *mut u8) -> *mut u8 {
    let p: *mut u8 = fallback;
    switch maybe {
        // EXPECT_ERROR: E_DUPLICATE_LOCAL
        p => { return p; },
        _ => { return fallback; },
    }
}

fn reject_result_switch_binding_shadows_local(result: Result<u32, LocalError>) -> u32 {
    let v: u32 = 1;
    switch result {
        // EXPECT_ERROR: E_DUPLICATE_LOCAL
        ok(v) => { return v; },
        err(e) => { return 0; },
    }
}

// EXPECT_ERROR: E_DUPLICATE_PARAMETER
fn reject_duplicate_parameter(x: u32, x: bool) -> u32 {
    return x;
}
