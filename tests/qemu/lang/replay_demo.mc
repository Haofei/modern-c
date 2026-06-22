import "kernel/core/ipc_trace.mc";
import "kernel/fs/blobstore.mc";
import "kernel/lib/record.mc";

global g_tr: IpcTrace;
global g_store: BlobStore;

const N: usize = 5; // a handful of distinct events to record and replay

// Play the whole stream once from a fresh cursor, checking every event matches the recorded
// fields in order, that replay_remaining decrements correctly, and that the call past the last
// event signals the typed end-of-stream (Done). Returns 1 if this replay pass is fully correct.
fn replay_pass(store: *mut BlobStore) -> u32 {
    var pass: u32 = 1;

    switch replay_open(store, 1) {
        ok(c0) => {
            var c: ReplayCursor = c0;
            // Before stepping, the whole stream is remaining.
            if replay_remaining(&c) != N { pass = 0; }

            var i: usize = 0;
            while i < N {
                switch replay_next(store, &c) {
                    ok(e) => {
                        // Same events, same order, fields intact (mirrors how they were recorded).
                        if e.seq != (i as u64) { pass = 0; }
                        if e.from != (10 + (i as u32)) { pass = 0; }
                        if e.to != (20 + (i as u32)) { pass = 0; }
                        if e.tag != (0x300 + (i as u32)) { pass = 0; }
                        if e.size != (64 + (i as u32)) { pass = 0; }
                    }
                    err(x) => { pass = 0; }
                }
                i = i + 1;
                // remaining decremented by exactly one per successful next.
                let want: usize = N - i;
                if replay_remaining(&c) != want { pass = 0; }
            }

            // Stream exhausted: remaining is 0 and the next call is the typed Done.
            if replay_remaining(&c) != 0 { pass = 0; }
            switch replay_next(store, &c) {
                ok(e) => { pass = 0; } // must not hand back an event past the end
                err(x) => {
                    switch x {
                        .Done => {}
                        _ => { pass = 0; }
                    }
                }
            }
        }
        err(e) => { pass = 0; }
    }

    return pass;
}

export fn replay_run() -> u32 {
    var pass: u32 = 1;

    // Build a trace ring with N distinct events, each with distinct from/to/tag/size.
    ipc_trace_init(&g_tr);
    var k: usize = 0;
    while k < N {
        let s: u64 = ipc_trace_record(&g_tr, 10 + (k as u32), 20 + (k as u32), 0x300 + (k as u32), 64 + (k as u32));
        if s != (k as u64) { pass = 0; }
        k = k + 1;
    }

    // Capture the ordered stream into durable log id=1.
    var store: *mut BlobStore = &g_store;
    blob_init(store);
    switch record_capture(&g_tr, store, 1) {
        ok(c) => { if c != N { pass = 0; } }
        err(e) => { pass = 0; }
    }

    // First replay pass: events come back in the SAME order with fields intact, Done at the end.
    if replay_pass(store) != 1 { pass = 0; }

    // Deterministic: re-open and replay again → identical sequence and end-of-stream.
    if replay_pass(store) != 1 { pass = 0; }

    // Opening a never-recorded id is typed NotFound, not a silent empty cursor.
    switch replay_open(store, 99) {
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
