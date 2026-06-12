// SPEC: section=12
// SPEC: milestone=local-initialization
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_LOCAL_REQUIRES_INITIALIZER,E_UNINIT_REQUIRES_STORAGE,E_LITERAL_REQUIRES_TARGET,E_NO_IMPLICIT_CONVERSION,E_CALL_ARG_COUNT

fn takes_u32(value: u32) -> u32 {
    return value;
}

extern struct Node {
    value: u32,
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

fn accept_read_materialized_uninit_scalar() -> u32 {
    var x: u32 = uninit;
    return x;
}

fn accept_read_materialized_uninit_byte() -> u8 {
    var buf: [4]u8 = uninit;
    return buf[0];
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
