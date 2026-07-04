// SPEC: section=12
// SPEC: milestone=local-initialization
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_LOCAL_REQUIRES_INITIALIZER,E_UNINIT_REQUIRES_STORAGE,E_LITERAL_REQUIRES_TARGET,E_INTEGER_LITERAL_OUT_OF_RANGE,E_NO_IMPLICIT_CONVERSION,E_CALL_ARG_COUNT,E_USE_BEFORE_INIT

fn takes_u32(value: u32) -> u32 {
    return value;
}

extern struct Node {
    value: u32,
}

struct Header {
    len: u32,
    cap: u32,
}

fn accept_initialized_local() -> u32 {
    var x: u32 = 1;
    return x;
}

fn accept_explicit_uninit_storage() -> u32 {
    var buf: [4096]u8 = uninit;
    return 0;
}

fn accept_maybe_uninit_storage() -> u32 {
    var x: MaybeUninit<Node> = uninit;
    return 0;
}

fn accept_maybe_uninit_write_assume_init() -> u32 {
    var x: MaybeUninit<Node> = uninit;
    x.write(.{ .value = 7 });
    let node: Node = x.assume_init();
    return node.value;
}

fn accept_grouped_maybe_uninit_write_payload() -> u32 {
    var x: MaybeUninit<Node> = uninit;
    x.write((.{ .value = 9 }));
    let node: Node = x.assume_init();
    return node.value;
}

// S0.1 definite-initialization: a scalar `var x: T = uninit;` must be assigned on
// every path before it is read; a read-before-assign is a compile error.
fn reject_read_uninit_scalar_before_assign() -> u32 {
    var x: u32 = uninit;
    // EXPECT_ERROR: E_USE_BEFORE_INIT
    return x;
}

fn reject_read_uninit_scalar_after_address_taken() -> u32 {
    var x: u32 = uninit;
    let p: *u32 = &x;
    // EXPECT_ERROR: E_USE_BEFORE_INIT
    return x;
}

fn accept_uninit_scalar_address_taken_then_assigned() -> u32 {
    var x: u32 = uninit;
    let p: *u32 = &x;
    x = 5;
    return x;
}

fn accept_uninit_scalar_assigned_before_read() -> u32 {
    var x: u32 = uninit;
    x = 5;
    return x;
}

fn accept_uninit_scalar_assigned_both_branches(c: bool) -> u32 {
    var x: u32 = uninit;
    if c {
        x = 1;
    } else {
        x = 2;
    }
    return x;
}

fn reject_uninit_scalar_assigned_one_branch(c: bool) -> u32 {
    var x: u32 = uninit;
    if c {
        x = 1;
    }
    // EXPECT_ERROR: E_USE_BEFORE_INIT
    return x;
}

// (bug #3) A `defer` body runs at scope EXIT, after later statements — not at its
// lexical position. So a defer reading a var that is assigned LATER (before exit) must
// be accepted, and its reads are checked against the function's exit init-state.
fn accept_defer_reads_var_assigned_after_defer() -> u32 {
    var x: u32 = uninit;
    defer takes_u32(x);   // runs at exit, where x is already 5 — accepted
    x = 5;
    return x;
}

// A defer reading a var that is NEVER assigned on the exit path is still a genuine
// use-before-init (the deferred read runs with the var still uninitialized).
fn reject_defer_reads_never_assigned_var() -> u32 {
    var x: u32 = uninit;
    // EXPECT_ERROR: E_USE_BEFORE_INIT
    defer takes_u32(x);
    return 0;
}

// (bug #1, regression) A `defer` ALSO runs on EARLY-exit edges (`return`/`?`), not just
// fall-through. On the early `return` below, x is still uninit when the deferred read runs,
// so this must be rejected even though x is assigned on the fall-through path.
fn reject_defer_reads_uninit_on_early_return(flag: bool) -> void {
    var x: u32 = uninit;
    // EXPECT_ERROR: E_USE_BEFORE_INIT
    defer takes_u32(x);
    if flag {
        return;        // x still uninit here — deferred read is use-before-init
    }
    x = 5;
    return;
}

// The dual valid case: x is assigned on EVERY exit edge the defer runs on, so the deferred
// read is fine. (Must still be accepted — do not regress into a false positive.)
fn accept_defer_reads_var_assigned_on_every_exit_edge() -> u32 {
    var x: u32 = uninit;
    defer takes_u32(x);
    x = 5;
    return x;
}

// Aggregates initialized with `uninit` are pending until whole assignment or, for
// fixed arrays, until DI can prove the read element was written. Partial member
// writes and address-taking remain storage uses; they do not prove aggregate
// initialization. Element/member/value reads without proof are rejected.
fn reject_read_uninit_array_element() -> u8 {
    var buf: [4]u8 = uninit;
    // EXPECT_ERROR: E_USE_BEFORE_INIT
    return buf[0];
}

fn reject_read_uninit_struct_member() -> u32 {
    var h: Header = uninit;
    // EXPECT_ERROR: E_USE_BEFORE_INIT
    return h.len;
}

fn reject_read_uninit_struct_value() -> Header {
    var h: Header = uninit;
    // EXPECT_ERROR: E_USE_BEFORE_INIT
    return h;
}

fn accept_uninit_array_partial_write_then_read_same_const_element() -> u8 {
    var buf: [4]u8 = uninit;
    buf[0] = 7;
    return buf[0];
}

fn accept_uninit_array_partial_write_then_read_same_dynamic_element() -> u8 {
    var buf: [4]u8 = uninit;
    let i: usize = 2;
    buf[i] = 9;
    return buf[i];
}

fn reject_uninit_array_dynamic_element_after_index_assignment() -> u8 {
    var buf: [4]u8 = uninit;
    var i: usize = 2;
    buf[i] = 9;
    i = 1;
    // EXPECT_ERROR: E_USE_BEFORE_INIT
    return buf[i];
}

fn reject_uninit_array_partial_write_then_read_sibling_element() -> u8 {
    var buf: [4]u8 = uninit;
    buf[0] = 7;
    // EXPECT_ERROR: E_USE_BEFORE_INIT
    return buf[1];
}

fn reject_uninit_struct_partial_write_then_read_same_field() -> u32 {
    var h: Header = uninit;
    h.len = 9;
    // EXPECT_ERROR: E_USE_BEFORE_INIT
    return h.len;
}

fn reject_uninit_struct_partial_write_then_read_sibling_field() -> u32 {
    var h: Header = uninit;
    h.len = 9;
    // EXPECT_ERROR: E_USE_BEFORE_INIT
    return h.cap;
}

fn accept_uninit_array_all_const_elements_written_then_dynamic_read() -> u8 {
    var buf: [4]u8 = uninit;
    buf[0] = 1;
    buf[1] = 2;
    buf[2] = 3;
    buf[3] = 4;
    let i: usize = 2;
    return buf[i];
}

fn accept_uninit_array_whole_assignment_then_read() -> u8 {
    var buf: [4]u8 = uninit;
    buf = .{ 1, 2, 3, 4 };
    return buf[1];
}

fn accept_uninit_struct_whole_assignment_then_read() -> u32 {
    var h: Header = uninit;
    h = .{ .len = 11, .cap = 12 };
    return h.len;
}

fn reject_uninitialized_var() -> u32 {
    // EXPECT_ERROR: E_LOCAL_REQUIRES_INITIALIZER
    var x: i32;
    return 0;
}

fn reject_uninitialized_let() -> u32 {
    // EXPECT_ERROR: E_LOCAL_REQUIRES_INITIALIZER
    let y: u32;
    return 0;
}

fn reject_uninit_let_initializer() -> u32 {
    // EXPECT_ERROR: E_UNINIT_REQUIRES_STORAGE
    let y: u32 = uninit;
    return y;
}

fn reject_uninit_inferred_var_initializer() -> u32 {
    // EXPECT_ERROR: E_UNINIT_REQUIRES_STORAGE
    var x = uninit;
    return 0;
}

fn reject_uninit_return() -> u32 {
    // EXPECT_ERROR: E_UNINIT_REQUIRES_STORAGE
    return uninit;
}

fn reject_grouped_uninit_return() -> u32 {
    // EXPECT_ERROR: E_UNINIT_REQUIRES_STORAGE
    return (uninit);
}

fn reject_uninit_assignment() -> u32 {
    var x: u32 = 0;
    // EXPECT_ERROR: E_UNINIT_REQUIRES_STORAGE
    x = uninit;
    return x;
}

fn reject_uninit_call_argument() -> u32 {
    // EXPECT_ERROR: E_UNINIT_REQUIRES_STORAGE
    return takes_u32(uninit);
}

fn reject_maybe_uninit_write_wrong_payload() -> void {
    var x: MaybeUninit<Node> = uninit;
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    x.write(7);
}

fn reject_maybe_uninit_assume_init_arg() -> Node {
    var x: MaybeUninit<Node> = uninit;
    // EXPECT_ERROR: E_CALL_ARG_COUNT
    return x.assume_init(1);
}

fn reject_targetless_string_literal() -> void {
    // EXPECT_ERROR: E_LITERAL_REQUIRES_TARGET
    let text = "hello";
}

fn reject_targetless_char_literal() -> void {
    // EXPECT_ERROR: E_LITERAL_REQUIRES_TARGET
    let ch = 'x';
}

fn reject_grouped_targetless_char_literal() -> void {
    // EXPECT_ERROR: E_LITERAL_REQUIRES_TARGET
    var ch = ('x');
}

fn reject_targetless_integer_larger_than_u128() -> void {
    // EXPECT_ERROR: E_INTEGER_LITERAL_OUT_OF_RANGE
    let y = 340282366920938463463374607431768211456;
}
