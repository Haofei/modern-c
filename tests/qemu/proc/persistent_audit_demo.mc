import "kernel/core/ipc_trace.mc";
import "kernel/core/persistent_audit.mc";
import "kernel/fs/blobstore.mc";

global g_trace: IpcTrace;
global g_store: BlobStore;

export fn persistent_audit_run() -> u32 {
    var pass: u32 = 1;
    blob_init(&g_store);

    switch persistent_policy_save(&g_store, 1, 7, 2, 4, 6, 11) {
        ok(n) => {}
        err(e) => { pass = 0; }
    }
    blob_reopen(&g_store);
    switch persistent_policy_load(&g_store, 1) {
        ok(p) => {
            if p.policy_version != 7 { pass = 0; }
            if p.throttle_at != 2 { pass = 0; }
            if p.revoke_at != 4 { pass = 0; }
            if p.kill_at != 6 { pass = 0; }
            if p.revocation_epoch != 11 { pass = 0; }
        }
        err(e) => { pass = 0; }
    }

    ipc_trace_init(&g_trace);
    if ipc_trace_record(&g_trace, 101, 1, 0x10, 64) != 0 { pass = 0; }
    if ipc_trace_record(&g_trace, 101, 0, 0x11, 65) != 1 { pass = 0; }
    if ipc_trace_record(&g_trace, 102, 1, 0x12, 66) != 2 { pass = 0; }

    switch persistent_audit_capture(&g_trace, &g_store, 2, 7, 1) {
        ok(n) => { if n != 3 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    if ipc_trace_len(&g_trace) != 0 { pass = 0; }

    blob_reopen(&g_store);
    switch persistent_audit_count(&g_store, 2) {
        ok(n) => { if n != 3 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    switch persistent_audit_policy_version(&g_store, 2) {
        ok(v) => { if v != 7 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    switch persistent_audit_boot_epoch(&g_store, 2) {
        ok(v) => { if v != 1 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    switch persistent_audit_trace_dropped(&g_store, 2) {
        ok(v) => { if v != 0 { pass = 0; } }
        err(e) => { pass = 0; }
    }

    switch persistent_audit_get(&g_store, 2, 1) {
        ok(ev) => {
            if ev.seq != 1 { pass = 0; }
            if ev.from != 101 { pass = 0; }
            if ev.to != 0 { pass = 0; }
            if ev.tag != 0x11 { pass = 0; }
            if ev.size != 65 { pass = 0; }
        }
        err(e) => { pass = 0; }
    }
    switch persistent_audit_get(&g_store, 2, 3) {
        ok(ev) => { pass = 0; }
        err(e) => {
            switch e {
                .OutOfRange => {}
                _ => { pass = 0; }
            }
        }
    }

    // Reboot simulation: reuse the same store, write a later boot epoch, and
    // verify both the old policy snapshot and new audit frame survive reopen.
    ipc_trace_init(&g_trace);
    if ipc_trace_record(&g_trace, 201, 0, 0x20, 32) != 0 { pass = 0; }
    switch persistent_audit_capture(&g_trace, &g_store, 3, 8, 2) {
        ok(n) => { if n != 1 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    blob_reopen(&g_store);
    switch persistent_policy_load(&g_store, 1) {
        ok(p) => { if p.policy_version != 7 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    switch persistent_audit_boot_epoch(&g_store, 3) {
        ok(v) => { if v != 2 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    switch persistent_audit_get(&g_store, 3, 0) {
        ok(ev) => {
            if ev.from != 201 { pass = 0; }
            if ev.tag != 0x20 { pass = 0; }
        }
        err(e) => { pass = 0; }
    }

    return pass;
}
