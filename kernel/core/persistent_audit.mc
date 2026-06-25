// kernel/core/persistent_audit — durable policy/audit checkpoint substrate.
//
// This is the production-shaped layer above the volatile IPC audit ring. It
// snapshots policy metadata and drains audit events into BlobStore-backed framed
// records so they survive a reopen/remount of the store. It is intentionally not
// the final block-device journal yet; BlobStore is the existing durable backing
// abstraction used by checkpoint/record tests.

import "std/addr.mc";
import "kernel/core/ipc_trace.mc";
import "kernel/fs/blobstore.mc";

const PERSIST_AUDIT_CAP: usize = 16;
const PERSIST_AUDIT_MAGIC: u32 = 0x50415544; // "PAUD"
const PERSIST_POLICY_MAGIC: u32 = 0x50504f4c; // "PPOL"

enum PersistentAuditError {
    PutFailed,
    NotFound,
    ShortRead,
    BadMagic,
    OutOfRange,
}

struct PersistentPolicySnapshot {
    magic: u32,
    policy_version: u64,
    throttle_at: u32,
    revoke_at: u32,
    kill_at: u32,
    revocation_epoch: u64,
}

struct PersistentAuditFrame {
    magic: u32,
    policy_version: u64,
    boot_epoch: u64,
    trace_dropped: u64,
    count: usize,
    events: [PERSIST_AUDIT_CAP]IpcEvent,
}

fn persistent_audit_frame_len(count: usize) -> usize {
    return sizeof(u32) + sizeof(u64) + sizeof(u64) + sizeof(u64) + sizeof(usize) + (count * sizeof(IpcEvent));
}

export fn persistent_policy_save(
    store: *mut BlobStore,
    id: u32,
    policy_version: u64,
    throttle_at: u32,
    revoke_at: u32,
    kill_at: u32,
    revocation_epoch: u64,
) -> Result<usize, PersistentAuditError> {
    var snap: PersistentPolicySnapshot = .{
        .magic = PERSIST_POLICY_MAGIC,
        .policy_version = policy_version,
        .throttle_at = throttle_at,
        .revoke_at = revoke_at,
        .kill_at = kill_at,
        .revocation_epoch = revocation_epoch,
    };
    switch blob_put(store, id, pa((&snap) as usize), sizeof(PersistentPolicySnapshot)) {
        ok(n) => { return ok(n); }
        err(e) => { return err(.PutFailed); }
    }
}

export fn persistent_policy_load(store: *mut BlobStore, id: u32) -> Result<PersistentPolicySnapshot, PersistentAuditError> {
    var snap: PersistentPolicySnapshot = uninit;
    let need: usize = sizeof(PersistentPolicySnapshot);
    switch blob_get(store, id, pa((&snap) as usize), need) {
        ok(n) => {
            if n < need { return err(.ShortRead); }
            if snap.magic != PERSIST_POLICY_MAGIC { return err(.BadMagic); }
            return ok(snap);
        }
        err(e) => { return err(.NotFound); }
    }
}

export fn persistent_audit_capture(
    trace: *mut IpcTrace,
    store: *mut BlobStore,
    id: u32,
    policy_version: u64,
    boot_epoch: u64,
) -> Result<usize, PersistentAuditError> {
    var frame: PersistentAuditFrame = uninit;
    frame.magic = PERSIST_AUDIT_MAGIC;
    frame.policy_version = policy_version;
    frame.boot_epoch = boot_epoch;
    frame.trace_dropped = ipc_trace_dropped(trace);
    frame.count = 0;

    var draining: bool = true;
    while draining {
        if frame.count >= PERSIST_AUDIT_CAP {
            draining = false;
        } else {
            switch ipc_trace_drain(trace) {
                ok(ev) => {
                    frame.events[frame.count] = ev;
                    frame.count = frame.count + 1;
                }
                err(e) => { draining = false; }
            }
        }
    }

    let n: usize = frame.count;
    switch blob_put(store, id, pa((&frame) as usize), persistent_audit_frame_len(n)) {
        ok(wrote) => { return ok(n); }
        err(e) => { return err(.PutFailed); }
    }
}

fn persistent_audit_load_frame(store: *mut BlobStore, id: u32) -> Result<PersistentAuditFrame, PersistentAuditError> {
    var frame: PersistentAuditFrame = uninit;
    let header: usize = persistent_audit_frame_len(0);
    switch blob_get(store, id, pa((&frame) as usize), header) {
        ok(n) => { if n < header { return err(.ShortRead); } }
        err(e) => { return err(.NotFound); }
    }
    if frame.magic != PERSIST_AUDIT_MAGIC {
        return err(.BadMagic);
    }
    if frame.count > PERSIST_AUDIT_CAP {
        return err(.BadMagic);
    }
    let need: usize = persistent_audit_frame_len(frame.count);
    switch blob_get(store, id, pa((&frame) as usize), need) {
        ok(n) => {
            if n < need { return err(.ShortRead); }
            return ok(frame);
        }
        err(e) => { return err(.NotFound); }
    }
}

export fn persistent_audit_count(store: *mut BlobStore, id: u32) -> Result<usize, PersistentAuditError> {
    switch persistent_audit_load_frame(store, id) {
        ok(frame) => { return ok(frame.count); }
        err(e) => { return err(e); }
    }
}

export fn persistent_audit_policy_version(store: *mut BlobStore, id: u32) -> Result<u64, PersistentAuditError> {
    switch persistent_audit_load_frame(store, id) {
        ok(frame) => { return ok(frame.policy_version); }
        err(e) => { return err(e); }
    }
}

export fn persistent_audit_boot_epoch(store: *mut BlobStore, id: u32) -> Result<u64, PersistentAuditError> {
    switch persistent_audit_load_frame(store, id) {
        ok(frame) => { return ok(frame.boot_epoch); }
        err(e) => { return err(e); }
    }
}

export fn persistent_audit_trace_dropped(store: *mut BlobStore, id: u32) -> Result<u64, PersistentAuditError> {
    switch persistent_audit_load_frame(store, id) {
        ok(frame) => { return ok(frame.trace_dropped); }
        err(e) => { return err(e); }
    }
}

export fn persistent_audit_get(store: *mut BlobStore, id: u32, i: usize) -> Result<IpcEvent, PersistentAuditError> {
    switch persistent_audit_load_frame(store, id) {
        ok(frame) => {
            if i >= frame.count {
                return err(.OutOfRange);
            }
            return ok(frame.events[i]);
        }
        err(e) => { return err(e); }
    }
}
