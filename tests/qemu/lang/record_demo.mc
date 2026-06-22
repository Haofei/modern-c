import "kernel/core/ipc_trace.mc";
import "kernel/fs/blobstore.mc";
import "kernel/lib/record.mc";

global g_tr: IpcTrace;
global g_store: BlobStore;

const N: usize = 5; // a handful of distinct events to record

export fn record_run() -> u32 {
    var pass: u32 = 1;

    // Build a trace ring with N events, each with distinct from/to/tag/size.
    ipc_trace_init(&g_tr);
    var k: usize = 0;
    while k < N {
        let s: u64 = ipc_trace_record(&g_tr, 10 + (k as u32), 20 + (k as u32), 0x300 + (k as u32), 64 + (k as u32));
        if s != (k as u64) { pass = 0; }
        k = k + 1;
    }
    if ipc_trace_len(&g_tr) != N { pass = 0; }

    // Capture: drain the ring oldest-first into a durable log; returns the count recorded.
    var store: *mut BlobStore = &g_store;
    blob_init(store);
    switch record_capture(&g_tr, store, 1) {
        ok(c) => { if c != N { pass = 0; } }
        err(e) => { pass = 0; }
    }
    // Capture consumed the ring (a drainer's consuming read): nothing left to drain.
    if ipc_trace_len(&g_tr) != 0 { pass = 0; }

    // record_count matches the number captured.
    switch record_count(store, 1) {
        ok(c) => { if c != N { pass = 0; } }
        err(e) => { pass = 0; }
    }

    // record_get returns each event in order, oldest-first, with fields intact.
    var i: usize = 0;
    while i < N {
        switch record_get(store, 1, i) {
            ok(e) => {
                if e.seq != (i as u64) { pass = 0; }
                if e.from != (10 + (i as u32)) { pass = 0; }
                if e.to != (20 + (i as u32)) { pass = 0; }
                if e.tag != (0x300 + (i as u32)) { pass = 0; }
                if e.size != (64 + (i as u32)) { pass = 0; }
            }
            err(x) => { pass = 0; }
        }
        i = i + 1;
    }

    // Out-of-range index fails typed (OutOfRange), does not return an event.
    switch record_get(store, 1, N) {
        ok(e) => { pass = 0; }
        err(x) => {
            switch x {
                .OutOfRange => {}
                _ => { pass = 0; }
            }
        }
    }

    // A never-recorded id is NotFound, not a silent empty.
    switch record_count(store, 99) {
        ok(c) => { pass = 0; }
        err(x) => {
            switch x {
                .NotFound => {}
                _ => { pass = 0; }
            }
        }
    }

    return pass;
}
