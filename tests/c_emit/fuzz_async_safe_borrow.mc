// A borrow of a captured local used ONLY in the tail (after all awaits) does NOT cross a suspend,
// so it must be ACCEPTED (no false positive from E_ASYNC_BORROW_ACROSS_AWAIT). The borrow is formed
// in a poll state (the tail), where `self` is at its stable final address — never in the constructor.
import "std/task.mc";
global g_clock: u64 = 0;
fn tick_idle() -> void { g_clock = g_clock + 1; }
struct ValFut { deadline: u64, val: i32 }
fn mk_val(deadline: u64, val: i32) -> ValFut { var f: ValFut = uninit; f.deadline = deadline; f.val = val; return f; }
impl Future for ValFut { fn poll(self: *mut ValFut) -> bool { return g_clock >= self.deadline; } }
fn ValFut_take_result(self: *mut ValFut) -> i32 { return self.val; }
fn ValFut_cancel(self: *mut ValFut) -> void { self.val = 0; }

async fn f(d: u64, v: i32) -> i32 {
    let r: i32 = await mk_val(d, v);    // the only await; straight-line tail follows
    var acc: i32 = r;
    let p: *mut i32 = &acc;             // borrow formed in the TAIL (after the await) -> safe
    *p = *p + 1;
    return acc;
}
export fn async_safe_borrow_run() -> u32 {
    g_clock = 0;
    var ff: f__Fut = f(1, 20);
    run_to_completion(&ff, tick_idle);
    if f__Fut_take_result(&ff) == 21 { return 1; }
    return 0;
}
