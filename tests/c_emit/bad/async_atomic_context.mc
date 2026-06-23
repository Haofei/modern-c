// EXPECT: E_ASYNC_FORBIDDEN_CONTEXT
// `atomic_context` is an irq-context synonym, so `async fn` is forbidden here too.
fn mk() -> i32 { return 7; }
#[atomic_context]
async fn bad() -> i32 {
    let r: i32 = await mk();
    return r;
}
