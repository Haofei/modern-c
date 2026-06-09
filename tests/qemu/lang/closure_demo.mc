// Demonstrates capturing function values (closures): bind() bundles a typed captured
// pointer with a function into a single callable, with no ctx word and no casts in
// MC source. The closure mutates the captured object across calls.

struct Counter { value: u32 }

fn counter_add(c: *mut Counter, delta: u32) -> u32 {
    c.value = c.value + delta;
    return c.value;
}

global g_counter: Counter;

export fn cl_run() -> u32 {
    g_counter.value = 100;
    let add: closure(u32) -> u32 = bind(&g_counter, counter_add);
    let first: u32 = add(5);   // captured g_counter.value -> 105
    let second: u32 = add(10); // -> 115 (state persisted in the captured object)
    return first + second;     // 220 — both calls observed, capture mutated across calls
}
