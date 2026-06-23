// LLVM-backend parity regression: a `*dyn` trait-object dispatch call used DIRECTLY as an
// if-condition whose body TERMINATES (`if self.inner.poll() { return true; }`). The C backend
// always lowered this; the LLVM backend previously bailed (UnsupportedLlvmEmission) because
// callReturnType() did not resolve a dispatch call's type, so the if/switch SUBJECT could not be
// typed. Now both backends lower it (std/task.mc Race2/Timeout rely on this — no hoist needed).

trait Future { fn poll(self: *mut Self) -> bool; }

struct Leaf { ticks: i32 }
impl Future for Leaf {
    fn poll(self: *mut Leaf) -> bool {
        if self.ticks <= 0 { return true; }
        self.ticks = self.ticks - 1;
        return false;
    }
}

// `inner` is a `*mut dyn Future`; its poll() is dispatched and used directly as the if-condition.
struct Wrap { inner: *mut dyn Future, polls: i32 }
impl Future for Wrap {
    fn poll(self: *mut Wrap) -> bool {
        self.polls = self.polls + 1;
        if self.inner.poll() { return true; }   // direct *dyn dispatch as if-cond, terminating body
        return false;
    }
}

export fn dyn_ifcond_run() -> u32 {
    var acc: u32 = 0;

    // Leaf ready after 2 polls; Wrap forwards. Drive to completion, counting polls.
    var l: Leaf = uninit; l.ticks = 2;
    var w: Wrap = uninit; w.inner = &l; w.polls = 0;
    var done: bool = false;
    while !done { done = Wrap.poll(&w); }
    if w.polls == 3 { acc = acc ^ 0x1; }     // 2 false (ticks 2->1->0) + 1 true
    if Wrap.poll(&w) { acc = acc ^ 0x2; }    // idempotent: inner stays ready

    if acc != 0x3 { return 0; }
    return 1;
}
