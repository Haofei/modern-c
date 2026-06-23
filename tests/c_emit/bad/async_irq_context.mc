// EXPECT: E_ASYNC_FORBIDDEN_CONTEXT
// `async fn` is forbidden in a #[irq_context] context (it suspends + uses indirect dispatch).
fn mk() -> i32 { return 7; }
#[irq_context]
async fn bad() -> i32 {
    let r: i32 = await mk();
    return r;
}
