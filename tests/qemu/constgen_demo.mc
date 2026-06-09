// Const-generic struct parameters: one Ring<T, N> definition, instantiated at two
// caller-chosen capacities (2 and 8). Proves `[N]T` and `% N` specialize per instance —
// the production-grade generics the kernel's hand-rolled fixed rings wanted.

struct CRing<T, N> {
    slots: [N]T,
    head: usize,
    tail: usize,
    count: usize,
}

fn cring_push(comptime T: type, comptime N: usize, r: *mut CRing<T, N>, x: T) -> bool {
    if r.count == N {
        return false;
    }
    r.slots[r.head] = x;
    r.head = (r.head + 1) % N;
    r.count = r.count + 1;
    return true;
}
fn cring_pop(comptime T: type, comptime N: usize, r: *mut CRing<T, N>) -> T {
    let x: T = r.slots[r.tail];
    r.tail = (r.tail + 1) % N;
    r.count = r.count - 1;
    return x;
}
fn cring_full(comptime T: type, comptime N: usize, r: *mut CRing<T, N>) -> bool {
    return r.count == N;
}

const CAP_K: usize = 4; // a named const used as a const-generic argument (not a literal)

global g_small: CRing<u32, 2>;
global g_big: CRing<u32, 8>;
global g_k: CRing<u32, CAP_K>; // capacity from the const CAP_K

export fn constgen_run() -> u32 {
    var pass: u32 = 1;

    // capacity 2: fill, confirm full, reject overflow, FIFO pop
    if !cring_push(u32, 2, &g_small, 10) { pass = 0; }
    if !cring_push(u32, 2, &g_small, 20) { pass = 0; }
    if !cring_full(u32, 2, &g_small) { pass = 0; }
    if cring_push(u32, 2, &g_small, 30) { pass = 0; } // full -> rejected
    if cring_pop(u32, 2, &g_small) != 10 { pass = 0; }

    // capacity 8: same code, different N — 5 pushes, not full
    var i: u32 = 0;
    while i < 5 {
        if !cring_push(u32, 8, &g_big, i) { pass = 0; }
        i = i + 1;
    }
    if cring_full(u32, 8, &g_big) { pass = 0; } // 5 < 8
    if cring_pop(u32, 8, &g_big) != 0 { pass = 0; }

    // capacity from the named const CAP_K (=4): fill to 4, reject the 5th
    var j: u32 = 0;
    while j < 4 {
        if !cring_push(u32, CAP_K, &g_k, j) { pass = 0; }
        j = j + 1;
    }
    if !cring_full(u32, CAP_K, &g_k) { pass = 0; }       // full at CAP_K
    if cring_push(u32, CAP_K, &g_k, 99) { pass = 0; }    // rejected
    if cring_pop(u32, CAP_K, &g_k) != 0 { pass = 0; }    // FIFO

    return pass;
}
