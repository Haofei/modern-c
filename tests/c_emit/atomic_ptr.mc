// Atomic operations on an atomic accessed BY POINTER (`*atomic<T>`) — the pointer value is the
// atomic's address, so the backends must NOT take its address again (`__atomic_load_n(p)` /
// `load atomic ... ptr %p`, not `&p`). Plus an atomic load compared directly in a `return`
// expression (a sequenced comparison whose operand is the load), which both backends must type
// and lower. Regression coverage for both.

fn read_through_ptr(a: *mut atomic<u32>) -> u32 {
    return a.load(.acquire);
}

fn write_through_ptr(a: *mut atomic<u32>, v: u32) -> void {
    a.store(v, .release);
}

fn add_through_ptr(a: *mut atomic<u32>, d: u32) -> u32 {
    return a.fetch_add(d, .acq_rel);
}

struct Counter {
    n: atomic<u32>,
}

// An atomic load compared in the return expression (the std/seqlock `seq_read_retry` shape).
fn counter_differs(c: *mut Counter, x: u32) -> bool {
    return c.n.load(.acquire) != x;
}

// Same comparison through a bare `*atomic<u32>` pointer.
fn ptr_differs(a: *mut atomic<u32>, x: u32) -> bool {
    return a.load(.acquire) != x;
}
