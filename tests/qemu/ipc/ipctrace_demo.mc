import "kernel/core/ipc_trace.mc";

// TRACE_CAP in kernel/core/ipc_trace.mc — keep in sync (it is module-private).
const CAP: usize = 16;

global g_tr: IpcTrace;

export fn ipctrace_run() -> u32 {
    var pass: u32 = 1;
    ipc_trace_init(&g_tr);
    if ipc_trace_len(&g_tr) != 0 { pass = 0; }
    if ipc_trace_dropped(&g_tr) != 0 { pass = 0; }

    // Record 3 events: seqs monotonic from 0 (0,1,2); len tracks.
    if ipc_trace_record(&g_tr, 10, 20, 0x100, 64) != 0 { pass = 0; }
    if ipc_trace_record(&g_tr, 11, 21, 0x101, 65) != 1 { pass = 0; }
    if ipc_trace_record(&g_tr, 12, 22, 0x102, 66) != 2 { pass = 0; }
    if ipc_trace_len(&g_tr) != 3 { pass = 0; }
    if ipc_trace_dropped(&g_tr) != 0 { pass = 0; }

    // Peek oldest-first: fields read back exactly, seqs 0,1,2 in order.
    var i: usize = 0;
    while i < 3 {
        switch ipc_trace_get(&g_tr, i) {
            ok(e) => {
                if e.seq != (i as u64) { pass = 0; }
                if e.from != (10 + (i as u32)) { pass = 0; }
                if e.to != (20 + (i as u32)) { pass = 0; }
                if e.tag != (0x100 + (i as u32)) { pass = 0; }
                if e.size != (64 + (i as u32)) { pass = 0; }
            }
            err(x) => { pass = 0; }
        }
        i = i + 1;
    }
    // Out-of-range peek is Empty.
    switch ipc_trace_get(&g_tr, 3) {
        ok(e) => { pass = 0; }
        err(x) => {}
    }

    // Fill PAST capacity: keep recording until well beyond CAP. We already have 3 events;
    // push CAP + 5 more total writes so the ring wraps and overwrites the oldest.
    // Total records after this loop: 3 + (CAP + 2) = CAP + 5 records ever; len caps at CAP.
    var n: usize = 0;
    while n < CAP + 2 {
        let s: u64 = ipc_trace_record(&g_tr, 100, 200, 0x200, 99);
        // seq is monotonic and equals the running total of records minus 1.
        if s != ((3 + n) as u64) { pass = 0; }
        n = n + 1;
    }
    // len caps at CAP; dropped accounts for everything overwritten.
    if ipc_trace_len(&g_tr) != CAP { pass = 0; }
    // Records ever = 3 + (CAP+2) = CAP+5; live = CAP; dropped = 5.
    if ipc_trace_dropped(&g_tr) != 5 { pass = 0; }

    // After overwrite the oldest live event must be the (dropped)-th recorded, i.e. seq 5.
    switch ipc_trace_get(&g_tr, 0) {
        ok(e) => { if e.seq != 5 { pass = 0; } }
        err(x) => { pass = 0; }
    }

    // Peek confirms seqs are still strictly monotonic oldest-first across the whole live ring.
    var prev_ok: bool = false;
    var prev: u64 = 0;
    var j: usize = 0;
    while j < ipc_trace_len(&g_tr) {
        switch ipc_trace_get(&g_tr, j) {
            ok(e) => {
                if prev_ok {
                    if e.seq != prev + 1 { pass = 0; } // contiguous & increasing
                }
                prev = e.seq;
                prev_ok = true;
            }
            err(x) => { pass = 0; }
        }
        j = j + 1;
    }

    // Drain (consuming pop) returns events oldest-first; len shrinks to 0; then Empty.
    var expect: u64 = 5; // oldest live seq after the overwrites
    var drained: usize = 0;
    var draining: bool = true;
    while draining {
        switch ipc_trace_drain(&g_tr) {
            ok(e) => {
                if e.seq != expect { pass = 0; }
                expect = expect + 1;
                drained = drained + 1;
            }
            err(x) => { draining = false; }
        }
    }
    if drained != CAP { pass = 0; }
    if ipc_trace_len(&g_tr) != 0 { pass = 0; }
    // dropped is monotonic accounting — unchanged by draining.
    if ipc_trace_dropped(&g_tr) != 5 { pass = 0; }

    return pass;
}
