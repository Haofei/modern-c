// EXPECT: E_ASYNC_ON_BRANCH
// The stackless async/await surface was moved to the `experimental-surface`
// branch. The parser rejects both contextual keywords and names that branch, so
// a reader of this tree is told where the feature went instead of getting a
// generic parse error.
async fn poll_once() -> i32 {
    return 1;
}
