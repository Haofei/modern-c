// EXPECT: E_ASYNC_BRANCH_UNSUPPORTED
// async v0 supports an await inside an if/else, but each arm must FALL THROUGH to the shared
// continuation — a `return` inside an await-bearing arm is outside v0 and must be rejected (not
// silently mislowered). The else arm's `return` is the violation.
struct ValFut { v: i32 }
fn mk_val(v: i32) -> ValFut { var f: ValFut = uninit; f.v = v; return f; }
impl Future for ValFut { fn poll(self: *mut ValFut) -> bool { return true; } }
fn ValFut_take_result(self: *mut ValFut) -> i32 { return self.v; }
fn ValFut_cancel(self: *mut ValFut) -> void { }

async fn bad(sel: bool) -> i32 {
    var out: i32 = 0;
    if sel { let a: i32 = await mk_val(1); out = a; }
    else   { let b: i32 = await mk_val(2); return b; }
    return out;
}
