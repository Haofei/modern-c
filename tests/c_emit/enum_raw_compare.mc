// Differential fixture for language gap G23: a comparison whose left operand is a
// call, an open-enum `.raw()` conversion, or a struct-field read off a call result,
// used in a VALUE context (return / let-init) rather than an `if` condition. The C
// backend routes such comparisons through the "sequenced" temp path (the operands can
// have side effects, so C's unspecified evaluation order forces per-operand temps),
// which needs to recover each operand's storage type. Before the fix that recovery
// only worked for `if` conditions (which the C backend can emit inline); in a value
// context `e.raw() == 1`, `f(x) == k`, and `mk(x).v == k` all failed UnsupportedCEmission.
// The LLVM backend types via sema/HIR and already handled these; this fixture pins that
// both backends now agree (entry mode diffs the C and LLVM return).

open enum E: u32 {
    a = 0,
    b = 1,
    c = 2,
}

struct S {
    v: u32,
}

fn mk(x: u32) -> S {
    let s: S = .{ .v = x };
    return s;
}

fn identity(x: u32) -> u32 {
    return x;
}

// --- open-enum `.raw()` operand, both value contexts ---

fn raw_ret(e: E) -> bool {
    return e.raw() == 1;
}

fn raw_let(e: E) -> bool {
    let r: bool = e.raw() == 1;
    return r;
}

// --- plain call operand, both value contexts ---

fn call_ret(x: u32) -> bool {
    return identity(x) == 5;
}

fn call_let(x: u32) -> bool {
    let r: bool = identity(x) == 5;
    return r;
}

// --- struct-field read off a call result, both value contexts ---

fn field_ret(x: u32) -> bool {
    return mk(x).v == 7;
}

fn field_let(x: u32) -> bool {
    let r: bool = mk(x).v == 7;
    return r;
}

export fn enum_raw_compare_run() -> u32 {
    var acc: u32 = 0;

    // `.raw()` == literal, truthy + falsy, in return and let-init
    if raw_ret(.b) { acc = acc | 0x001; }
    if !raw_ret(.a) { acc = acc | 0x002; }
    if raw_let(.b) { acc = acc | 0x004; }
    if !raw_let(.a) { acc = acc | 0x008; }

    // call == literal, truthy + falsy, in return and let-init
    if call_ret(5) { acc = acc | 0x010; }
    if !call_ret(4) { acc = acc | 0x020; }
    if call_let(5) { acc = acc | 0x040; }
    if !call_let(4) { acc = acc | 0x080; }

    // field-off-call == literal, truthy + falsy, in return and let-init
    if field_ret(7) { acc = acc | 0x100; }
    if !field_ret(6) { acc = acc | 0x200; }
    if field_let(7) { acc = acc | 0x400; }
    if !field_let(6) { acc = acc | 0x800; }

    // entry-mode contract: 1 = pass, 0 = fail. All twelve bits must be set.
    if acc != 0xFFF { return 0; }
    return 1;
}
