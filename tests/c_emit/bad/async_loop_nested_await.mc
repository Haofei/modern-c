// EXPECT: E_ASYNC_LOOP_UNSUPPORTED
// E3a/E3b lifted `return`/`break`/`continue` inside an await-bearing loop body, but an `await` NESTED
// inside inner control flow (here an `if` INSIDE the `while`) is still outside the v0 lowering: it
// would create a suspend point the flat per-construct state allocator cannot number (that is E3c, a
// proper per-suspend-point CFG, deferred). It must be rejected, not silently mislowered.
struct ValFut { v: i32 }
fn mk_val(v: i32) -> ValFut { var f: ValFut = uninit; f.v = v; return f; }
impl Future for ValFut { fn poll(self: *mut ValFut) -> bool { return true; } fn cancel(self: *mut ValFut) -> void { } }
fn ValFut_take_result(self: *mut ValFut) -> i32 { return self.v; }
fn ValFut_cancel(self: *mut ValFut) -> void { }

async fn bad(n: i32) -> i32 {
    var acc: i32 = 0;
    var i: i32 = 0;
    while i < n {
        let a: i32 = await mk_val(i);
        if a > 0 { let b: i32 = await mk_val(a); acc = acc + b; }   // await NESTED in an inner if
        i = i + 1;
    }
    return acc;
}
