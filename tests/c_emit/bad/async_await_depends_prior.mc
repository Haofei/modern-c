// EXPECT: E_ASYNC_AWAIT_DEPENDS_ON_PRIOR
// v0: a later awaited call may not reference an earlier `await` result (children built up front).
fn mk(x: i32) -> i32 { return x; }
async fn bad() -> i32 {
    let a: i32 = await mk(1);
    let b: i32 = await mk(a);
    return a + b;
}
