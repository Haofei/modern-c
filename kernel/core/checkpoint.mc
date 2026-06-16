// kernel/core/checkpoint — a first-cut agent checkpoint/restore over the durable BlobStore.
//
// An "agent" here is a process whose interesting durable state is the two rich per-process
// resources the kernel already models: its file-descriptor space (`FdSpace`, via proc_fds)
// and its memory account (`ResourceAccount`, via proc_macct). `checkpoint_save` serializes a
// snapshot { pid, FdSpace, ResourceAccount } of one slot into a durable blob; `checkpoint_restore`
// spawns a FRESH process slot and replays the saved FdSpace + ResourceAccount into it, so the
// new process carries the old agent's resource state even though its predecessor is gone.
//
// This is deliberately the simplified cut: only the fd-space and memory account travel (not the
// saved register Context, address space, mailbox, signals, …); the richer full-context checkpoint
// is later work. It is layered strictly on EXISTING exported accessors — proc_fds / proc_macct
// (both return `*mut`, so the restore writes straight through them), proc_pid_at, proc_spawn —
// and the P1.7 BlobStore (blob_put / blob_get / blob_len). It adds no accessor to process.mc.
//
// BLOB LAYOUT (a single framed byte run, all sub-regions copied verbatim as raw struct bytes):
//
//     offset                       size                       contents
//     ------                       ----                       --------
//     0                            8 (CKPT_PID_BYTES)          pid, a u32 widened to a usize word
//     8                            sizeof(FdSpace)             the FdSpace struct's raw bytes
//     8 + sizeof(FdSpace)          sizeof(ResourceAccount)     the ResourceAccount struct's bytes
//
// Total framed length is CKPT_PID_BYTES + sizeof(FdSpace) + sizeof(ResourceAccount). Serialization
// is a raw struct-byte copy through std/mem `mem_copy` (the same byte move blob_put/blob_get use):
// because both save and restore go through the identical byte layout, the round-trip is exact and
// backend-independent — no field-by-field encoding, no padding interpretation. A scratch staging
// buffer (CkptFrame) holds the frame so the whole snapshot is one blob_put / one blob_get.

import "std/addr.mc";
import "std/mem.mc";
import "kernel/fs/blobstore.mc";
import "kernel/lib/fdspace.mc";
import "kernel/lib/resacct.mc";
import "kernel/core/process.mc";

// The pid occupies a full usize-sized word at the head of the frame (a u32 value widened), so the
// two struct regions that follow start on a natural word boundary regardless of struct alignment.
const CKPT_PID_BYTES: usize = 8;

enum CkptError {
    NotFound,  // no checkpoint blob with that id (restore of a never-saved id)
    PutFailed, // the BlobStore refused the write (directory Full / arena TooLarge)
    GetFailed, // the BlobStore read back fewer bytes than the frame needs (corrupt/short blob)
}

// A staging frame sized to hold the whole snapshot contiguously: pid word, then the two structs'
// raw bytes. Laid out as fields (not a flat byte array) so each sub-region is naturally aligned and
// the struct's own size IS the frame length — save copies into it then blob_puts it; restore
// blob_gets into it then copies the sub-regions back out.
struct CkptFrame {
    pid: usize,            // the saved pid, widened from u32 (CKPT_PID_BYTES at offset 0)
    fds: FdSpace,          // the saved file-descriptor space (verbatim struct bytes)
    macct: ResourceAccount, // the saved memory account (verbatim struct bytes)
}

// Serialize slot `slot`'s { pid, FdSpace, ResourceAccount } into durable blob `id`.
// Reads the live state through the existing accessors (proc_pid_at / proc_fds / proc_macct),
// stages it into one contiguous frame, and writes that frame as a single blob. PutFailed on any
// BlobStore rejection (never a partial write — blob_put fails closed).
export fn checkpoint_save(t: *mut ProcTable, slot: usize, store: *mut BlobStore, id: u32) -> Result<usize, CkptError> {
    var frame: CkptFrame = uninit;
    frame.pid = proc_pid_at(t, slot) as usize;

    // Copy the live FdSpace and ResourceAccount into the frame as raw bytes (the accessors hand
    // back `*mut`, whose address is the source region for the byte move).
    let fds_src: PAddr = pa((proc_fds(t, slot)) as usize);
    let macct_src: PAddr = pa((proc_macct(t, slot)) as usize);
    mem_copy(pa((&frame.fds) as usize), fds_src, sizeof(FdSpace));
    mem_copy(pa((&frame.macct) as usize), macct_src, sizeof(ResourceAccount));

    let frame_len: usize = sizeof(CkptFrame);
    switch blob_put(store, id, pa((&frame) as usize), frame_len) {
        ok(n) => { return ok(n); }
        err(e) => { return err(.PutFailed); }
    }
}

// Restore checkpoint blob `id` into a FRESH process slot. Spawns a new process (its own pid /
// generation — restore makes a NEW process carrying the old resource state, per the design), reads
// the saved frame back, and replays the saved FdSpace + ResourceAccount into the new slot through
// the mutable accessors. Returns the new slot. NotFound if `id` was never saved; GetFailed if the
// stored blob is shorter than a frame (the saved pid is informational and intentionally discarded).
export fn checkpoint_restore(t: *mut ProcTable, store: *mut BlobStore, id: u32, stack_top: usize, entry: fn() -> void) -> Result<usize, CkptError> {
    // Fail before spawning if the blob is absent, so a bad restore does not consume a slot.
    switch blob_len(store, id) {
        ok(n) => { if n < sizeof(CkptFrame) { return err(.GetFailed); } }
        err(e) => { return err(.NotFound); }
    }

    let frame_len: usize = sizeof(CkptFrame);
    var frame: CkptFrame = uninit;
    switch blob_get(store, id, pa((&frame) as usize), frame_len) {
        ok(n) => { if n < frame_len { return err(.GetFailed); } }
        err(e) => { return err(.NotFound); }
    }

    // A fresh slot for the restored agent (its own pid/gen; the saved pid is not reused).
    let slot: usize = proc_spawn(t, stack_top, entry) as usize;

    // Replay the saved resource state straight through the mutable accessors (verbatim bytes back).
    let fds_dst: PAddr = pa((proc_fds(t, slot)) as usize);
    let macct_dst: PAddr = pa((proc_macct(t, slot)) as usize);
    mem_copy(fds_dst, pa((&frame.fds) as usize), sizeof(FdSpace));
    mem_copy(macct_dst, pa((&frame.macct) as usize), sizeof(ResourceAccount));

    return ok(slot);
}
