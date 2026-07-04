// EXPECT: E_SWITCH_MULTI_BINDING_ARM
// A switch arm with MULTIPLE patterns may not introduce a binding — sema's checkSwitchArmBindings
// raises E_SWITCH_MULTI_BINDING_ARM (and binds NOTHING). Whether a switch `.bind`/`.tag_bind` binds
// is TYPE-DEPENDENT and validated by sema, so the async pre-sema transforms (src/async_lower.zig)
// must NOT pre-bind switch patterns: the dup-check no longer binds `ok(x)`/`err(x)`, so it no longer
// reports E_DUPLICATE_LOCAL (binding `x` twice) BEFORE sema can report the precise diagnostic. An
// async fn now reports the SAME code a non-async fn does for this arm. (See the positive half:
// tests/c_emit/fuzz_async_switch_pattern_sema.mc.)
import "std/task.mc";

global g_clock: u64 = 0;
struct ValFut { deadline: u64, val: i32 }
fn mk_val(deadline: u64, val: i32) -> ValFut {
    return .{ .deadline = deadline, .val = val };
}
impl Future for ValFut {
    fn poll(self: *mut ValFut) -> bool { return g_clock >= self.deadline; }
    fn cancel(self: *mut ValFut) -> void { self.val = 0; }
}
fn ValFut_take_result(self: *mut ValFut) -> i32 { return self.val; }
fn ValFut_cancel(self: *mut ValFut) -> void { self.val = 0; }

async fn multi(d: u64, r: Result<i32, i32>) -> i32 {
    let q: i32 = await mk_val(d, 7);
    switch r {
        ok(x), err(x) => { return x + q; },   // multi-pattern arm with a binding -> E_SWITCH_MULTI_BINDING_ARM
    }
}
