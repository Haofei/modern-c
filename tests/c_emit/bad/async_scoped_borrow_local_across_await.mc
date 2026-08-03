// EXPECT: E_ASYNC_BORROW_ACROSS_AWAIT
// Explicit scoped borrow locals are lexical in Scoped Affine Ownership v0. A binding
// created before an await remains live until the block ends, so it must be scoped away
// before suspension.
import "std/task.mc";
global g_clock: u64 = 0;

struct Delay { deadline: u64 }
fn delay(deadline: u64) -> Delay { return .{ .deadline = deadline }; }
impl Future for Delay {
    fn poll(self: *mut Delay) -> bool { return g_clock >= self.deadline; }
    fn cancel(self: *mut Delay) -> void { }
}
fn Delay_take_result(self: *mut Delay) -> u32 { return 1; }
fn Delay_cancel(self: *mut Delay) -> void { }

async fn reject_borrow_local_crosses_await(value: u32, deadline: u64) -> u32 {
    let ptr = borrow value;
    let waited: u32 = await delay(deadline);
    return ptr.* + waited;
}

async fn accept_borrow_scoped_before_await(value: u32, deadline: u64) -> u32 {
    {
        let ptr = borrow value;
        let snapshot: u32 = ptr.*;
    }
    let waited: u32 = await delay(deadline);
    return value + waited;
}
