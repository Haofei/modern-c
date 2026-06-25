// kernel/core/block_persistent_audit — block-backed policy/audit persistence.
//
// This is the production-path counterpart to `persistent_audit.mc`'s BlobStore seed:
// policy metadata and drained audit records are serialized into fixed 512-byte records and
// written through the generic BlockDevice trait. A RAM disk can gate the behavior on host,
// while virtio-blk can provide the same trait on QEMU/board paths.

import "std/addr.mc";
import "std/mem.mc";
import "kernel/core/ipc_trace.mc";
import "kernel/fs/blockdev.mc";

const BPA_BLOCK_SIZE: usize = 512;
const BPA_AUDIT_CAP: usize = 8;
const BPA_POLICY_MAGIC: u32 = 0x42504f4c; // "BPOL"
const BPA_AUDIT_MAGIC: u32 = 0x42415544; // "BAUD"

enum BlockPersistentAuditError {
    IoError,
    ShortRead,
    BadMagic,
    OutOfRange,
}

struct BlockPolicySnapshot {
    magic: u32,
    policy_version: u64,
    throttle_at: u32,
    revoke_at: u32,
    kill_at: u32,
    revocation_epoch: u64,
}

struct BlockAuditFrame {
    magic: u32,
    policy_version: u64,
    boot_epoch: u64,
    trace_dropped: u64,
    count: usize,
    events: [BPA_AUDIT_CAP]IpcEvent,
}

global g_bpa_block: [BPA_BLOCK_SIZE]u8;

fn clear_block() -> void {
    mem_set(pa((&g_bpa_block[0]) as usize), 0, BPA_BLOCK_SIZE);
}

fn write_record(dev: *dyn BlockDevice, block: u64, src: usize, len: usize) -> Result<bool, BlockPersistentAuditError> {
    if len > BPA_BLOCK_SIZE {
        return err(.OutOfRange);
    }
    clear_block();
    mem_copy(pa((&g_bpa_block[0]) as usize), pa(src), len);
    switch bd_write_block(dev, block, (&g_bpa_block[0]) as usize) {
        ok(v) => { return ok(v); }
        err(e) => { return err(.IoError); }
    }
}

fn read_record(dev: *dyn BlockDevice, block: u64, dst: usize, len: usize) -> Result<bool, BlockPersistentAuditError> {
    if len > BPA_BLOCK_SIZE {
        return err(.OutOfRange);
    }
    clear_block();
    switch bd_read_block(dev, block, (&g_bpa_block[0]) as usize) {
        ok(v) => {
            mem_copy(pa(dst), pa((&g_bpa_block[0]) as usize), len);
            return ok(v);
        }
        err(e) => { return err(.IoError); }
    }
}

export fn block_persistent_policy_save(
    dev: *dyn BlockDevice,
    block: u64,
    policy_version: u64,
    throttle_at: u32,
    revoke_at: u32,
    kill_at: u32,
    revocation_epoch: u64,
) -> Result<bool, BlockPersistentAuditError> {
    var snap: BlockPolicySnapshot = .{
        .magic = BPA_POLICY_MAGIC,
        .policy_version = policy_version,
        .throttle_at = throttle_at,
        .revoke_at = revoke_at,
        .kill_at = kill_at,
        .revocation_epoch = revocation_epoch,
    };
    return write_record(dev, block, (&snap) as usize, sizeof(BlockPolicySnapshot));
}

export fn block_persistent_policy_load(dev: *dyn BlockDevice, block: u64) -> Result<BlockPolicySnapshot, BlockPersistentAuditError> {
    var snap: BlockPolicySnapshot = uninit;
    switch read_record(dev, block, (&snap) as usize, sizeof(BlockPolicySnapshot)) {
        ok(v) => {}
        err(e) => { return err(e); }
    }
    if snap.magic != BPA_POLICY_MAGIC {
        return err(.BadMagic);
    }
    return ok(snap);
}

export fn block_persistent_audit_capture(
    trace: *mut IpcTrace,
    dev: *dyn BlockDevice,
    block: u64,
    policy_version: u64,
    boot_epoch: u64,
) -> Result<usize, BlockPersistentAuditError> {
    var frame: BlockAuditFrame = uninit;
    frame.magic = BPA_AUDIT_MAGIC;
    frame.policy_version = policy_version;
    frame.boot_epoch = boot_epoch;
    frame.trace_dropped = ipc_trace_dropped(trace);
    frame.count = 0;

    var draining: bool = true;
    while draining {
        if frame.count >= BPA_AUDIT_CAP {
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
    switch write_record(dev, block, (&frame) as usize, sizeof(BlockAuditFrame)) {
        ok(v) => { return ok(n); }
        err(e) => { return err(e); }
    }
}

fn block_persistent_audit_load_frame(dev: *dyn BlockDevice, block: u64) -> Result<BlockAuditFrame, BlockPersistentAuditError> {
    var frame: BlockAuditFrame = uninit;
    switch read_record(dev, block, (&frame) as usize, sizeof(BlockAuditFrame)) {
        ok(v) => {}
        err(e) => { return err(e); }
    }
    if frame.magic != BPA_AUDIT_MAGIC {
        return err(.BadMagic);
    }
    if frame.count > BPA_AUDIT_CAP {
        return err(.BadMagic);
    }
    return ok(frame);
}

export fn block_persistent_audit_count(dev: *dyn BlockDevice, block: u64) -> Result<usize, BlockPersistentAuditError> {
    switch block_persistent_audit_load_frame(dev, block) {
        ok(frame) => { return ok(frame.count); }
        err(e) => { return err(e); }
    }
}

export fn block_persistent_audit_policy_version(dev: *dyn BlockDevice, block: u64) -> Result<u64, BlockPersistentAuditError> {
    switch block_persistent_audit_load_frame(dev, block) {
        ok(frame) => { return ok(frame.policy_version); }
        err(e) => { return err(e); }
    }
}

export fn block_persistent_audit_boot_epoch(dev: *dyn BlockDevice, block: u64) -> Result<u64, BlockPersistentAuditError> {
    switch block_persistent_audit_load_frame(dev, block) {
        ok(frame) => { return ok(frame.boot_epoch); }
        err(e) => { return err(e); }
    }
}

export fn block_persistent_audit_trace_dropped(dev: *dyn BlockDevice, block: u64) -> Result<u64, BlockPersistentAuditError> {
    switch block_persistent_audit_load_frame(dev, block) {
        ok(frame) => { return ok(frame.trace_dropped); }
        err(e) => { return err(e); }
    }
}

export fn block_persistent_audit_get(dev: *dyn BlockDevice, block: u64, i: usize) -> Result<IpcEvent, BlockPersistentAuditError> {
    switch block_persistent_audit_load_frame(dev, block) {
        ok(frame) => {
            if i >= frame.count {
                return err(.OutOfRange);
            }
            return ok(frame.events[i]);
        }
        err(e) => { return err(e); }
    }
}
