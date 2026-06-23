// EXPECT: E_AWAIT_OUTSIDE_ASYNC
// `await` outside an `async fn` must be rejected (not crash the compiler at sema).
fn mk() -> i32 { return 7; }
export fn bad() -> i32 {
    let r: i32 = await mk();
    return r;
}
