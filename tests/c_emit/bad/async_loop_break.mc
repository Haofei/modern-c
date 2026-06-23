// EXPECT: E_ASYNC_LOOP_UNSUPPORTED
// async v0 supports an `await` inside a `while` loop, but the body must be a leading await-run then
// straight-line code that FALLS THROUGH to the loop head (back-edge). A `break` inside an
// await-bearing loop body is outside v0 and must be rejected (not silently mislowered).
struct ValFut { v: i32 }
fn mk_val(v: i32) -> ValFut { var f: ValFut = uninit; f.v = v; return f; }
impl Future for ValFut { fn poll(self: *mut ValFut) -> bool { return true; } }
fn ValFut_take_result(self: *mut ValFut) -> i32 { return self.v; }
fn ValFut_cancel(self: *mut ValFut) -> void { }

async fn bad(n: i32) -> i32 {
    var acc: i32 = 0;
    var i: i32 = 0;
    while i < n { let a: i32 = await mk_val(i); acc = acc + a; break; }
    return acc;
}
