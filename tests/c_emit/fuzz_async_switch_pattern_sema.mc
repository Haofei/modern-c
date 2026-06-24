// Switch-pattern bindings are TYPE-DEPENDENT and thus undeterminable PRE-sema, so the async
// pre-sema transforms (src/async_lower.zig) must NOT model their binding semantics — sema is
// authoritative. This fixture is the POSITIVE half (the negative diagnostics live in
// tests/c_emit/bad/async_switch_multi_binding.mc + bad/async_switch_bind_shadow.mc):
//
//   * dupCheckPattern / the `.@"switch"` dup-check no longer pre-binds switch patterns. A
//     `.tag_bind` payload no longer spuriously trips E_DUPLICATE_LOCAL against an outer same-named
//     binding that lives in a DISJOINT scope (the only locally-valid collision; a STILL-LIVE one is
//     E_DUPLICATE_LOCAL, see bad/async_switch_bind_shadow.mc).
//   * the alpha-renamer (general path) no longer renames switch-arm pattern names: a payload read
//     stays bare and resolves to the PAYLOAD without renaming; the identifier rewriters' shadowRemove
//     (keyed on the original pattern name) keeps it from becoming `self.<field>`.
//
// VALUE-SENSITIVE: each arm must read its PAYLOAD (a union/Result case binding), distinct from the
// captured awaited value carried in a self.* field. A pre-fix read of the captured field for the
// payload — or a dropped capture — would mis-sum. Covers the FAST path (one leading await + tail
// switch) and the GENERAL structured-CFG path (two await-bearing ifs force it). Both backends agree.

import "std/task.mc";

global g_clock: u64 = 0;
fn tick_idle() -> void { g_clock = g_clock + 1; }

struct ValFut { deadline: u64, val: i32 }
fn mk_val(deadline: u64, val: i32) -> ValFut {
    var f: ValFut = uninit;
    f.deadline = deadline;
    f.val = val;
    return f;
}
impl Future for ValFut {
    fn poll(self: *mut ValFut) -> bool { return g_clock >= self.deadline; }
    fn cancel(self: *mut ValFut) -> void { self.val = 0; }
}
fn ValFut_take_result(self: *mut ValFut) -> i32 { return self.val; }
fn ValFut_cancel(self: *mut ValFut) -> void { self.val = 0; }

union Tok { number: i32, eof }

// ---- FAST path: a leading await into the captured `y`, then a tail union switch. The `number(z)`
// arm reads its PAYLOAD z and the captured y; the `.eof` arm (no binding) reads only y. A pre-fix
// read of self.z (no such field) or of the captured y for the payload would mis-sum.
//   fast(number(7)): y = await(10); arm number -> y + z = 10 + 7 = 17.
//   fast(eof):       y = await(10); arm eof    -> y      = 10.
async fn fast(d: u64, t: Tok) -> i32 {
    let y: i32 = await mk_val(d, 10);
    switch t {
        number(z) => { return y + z; },
        .eof => { return y; },
    }
}

// ---- GENERAL path: two await-bearing ifs force the structured-CFG path (the alpha-renamer). The
// trailing union switch's `number(z)` arm must STILL read its payload z (renamer no longer renames
// the pattern); the captured running total survives as a self.* field.
//   gen(number(5), cond=true): total = await(20) (=20); second await-if runs; arm number -> total + z = 25.
//   gen(eof,       cond=true): arm eof -> total = 20.
async fn gen(d: u64, t: Tok, cond: bool) -> i32 {
    var total: i32 = 0;
    if cond { let a: i32 = await mk_val(d, 20); total = total + a; }
    if cond { let w: i32 = await mk_val(d, 0); }
    switch t {
        number(z) => { return total + z; },
        .eof => { return total; },
    }
}

// ---- Result tag_bind payloads (ok/err) on the fast path: each arm reads its narrowed payload plus
// the captured awaited base.
//   resf(ok):  base = await(3); RFut yields ok(40)  -> arm ok  reads x=40 -> base + x = 43.
//   resf(err): base = await(3); RFut yields err(-9) -> arm err reads e=-9 -> base + e = -6.
struct RFut { deadline: u64, v: i32 }
fn mk_r(deadline: u64, v: i32) -> RFut { var f: RFut = uninit; f.deadline = deadline; f.v = v; return f; }
impl Future for RFut { fn poll(self: *mut RFut) -> bool { return g_clock >= self.deadline; } fn cancel(self: *mut RFut) -> void { self.v = 0; } }
fn RFut_take_result(self: *mut RFut) -> Result<i32, i32> { if self.v < 0 { return err(self.v); } return ok(self.v); }
fn RFut_cancel(self: *mut RFut) -> void { self.v = 0; }

async fn resf(d: u64) -> i32 {
    let base: i32 = await mk_val(d, 3);
    let r: Result<i32, i32> = await mk_r(d, 40);
    switch r {
        ok(x) => { return base + x; },
        err(e) => { return base + e; },
    }
}
async fn resf_err(d: u64) -> i32 {
    let base: i32 = await mk_val(d, 3);
    let r: Result<i32, i32> = await mk_r(d, -9);
    switch r {
        ok(x) => { return base + x; },
        err(e) => { return base + e; },
    }
}

export fn async_switch_pattern_sema_run() -> u32 {
    var acc: u32 = 0;

    g_clock = 0;
    var a: fast__Fut = fast(0, number(7));
    run_to_completion(&a, tick_idle);
    if fast__Fut_take_result(&a) == 17 { acc = acc ^ 0x01; }

    g_clock = 0;
    var ae: fast__Fut = fast(0, eof());
    run_to_completion(&ae, tick_idle);
    if fast__Fut_take_result(&ae) == 10 { acc = acc ^ 0x02; }

    g_clock = 0;
    var b: gen__Fut = gen(0, number(5), true);
    run_to_completion(&b, tick_idle);
    if gen__Fut_take_result(&b) == 25 { acc = acc ^ 0x04; }

    g_clock = 0;
    var be: gen__Fut = gen(0, eof(), true);
    run_to_completion(&be, tick_idle);
    if gen__Fut_take_result(&be) == 20 { acc = acc ^ 0x08; }

    g_clock = 0;
    var c: resf__Fut = resf(0);
    run_to_completion(&c, tick_idle);
    if resf__Fut_take_result(&c) == 43 { acc = acc ^ 0x10; }

    g_clock = 0;
    var ce: resf_err__Fut = resf_err(0);
    run_to_completion(&ce, tick_idle);
    if resf_err__Fut_take_result(&ce) == -6 { acc = acc ^ 0x20; }

    if acc != 0x3F { return 0; }
    return 1;
}
