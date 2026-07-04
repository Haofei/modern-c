// EXPECT: E_DUPLICATE_LOCAL
// The switch subject is a NULLABLE-returning CALL (`id_nullable(source)`) — a shape whose type the
// async pre-sema lowering cannot resolve syntactically (it would need to type the callee's return).
// This is the case that motivated the ROOT FIX: rather than the lowering re-deriving subject
// nullability leaf-by-leaf (param, then typed local, then qualified, then call, then member, ...), the
// lowering only DETECTS the collision (the bare `.bind` name `x` shadows the enclosing `let x`, which
// the general path lifts to a `self.*` field) and sets SwitchArm.dup_local_if_binds. Sema — which has
// the RESOLVED subject type — then reports E_DUPLICATE_LOCAL iff it actually binds the `.bind` (nullable
// subject). So every subject shape is handled by the same mechanism with real type info; a non-nullable
// call subject (the bare `.bind` binds nothing) is still accepted. A nullable MEMBER subject
// (`switch box.field { x => }`) rejects identically — same mechanism.
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
fn id_nullable(p: ?*mut i32) -> ?*mut i32 { return p; }

async fn call_nullable_shadow_general(d: u64, source: ?*mut i32, p: *mut i32, cond: bool) -> usize {
    let x: *mut i32 = p;                         // still live below
    if cond { let q: i32 = await mk_val(d, 7); if q == 999 { return 0; } }
    if cond { let w: i32 = await mk_val(d, 0); if w == 999 { return 0; } }
    switch id_nullable(source) {
        x => { return x as usize; },             // call-returned nullable unwrap `x` shadows live outer `x` -> E_DUPLICATE_LOCAL
        _ => { return x as usize; },
    }
}
