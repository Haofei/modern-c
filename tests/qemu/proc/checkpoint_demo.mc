// Agent checkpoint/restore (kernel/core/checkpoint) over the durable BlobStore. An "agent" is a
// process carrying two rich resources — its fd-space (proc_fds) and memory account (proc_macct).
// This drives the simplified first cut on the host (the arch context primitives are stubbed by the
// C driver, so only the bookkeeping path runs):
//   * set up an agent (a spawned child): open a couple of fds in its fd-space, charge its account;
//   * checkpoint_save it to a durable blob (id=1);
//   * proc_exit the child — its live state is released (fds gone, account reset, slot a zombie);
//   * checkpoint_restore the blob into a FRESH slot — its own pid, but carrying the SAVED state;
//   * assert the restored fd-space has the same fds (kind/handle) and the same account used/limit.
// Returns 1 only if every check passes.

import "kernel/core/process.mc";
import "kernel/core/checkpoint.mc";
import "kernel/lib/fdspace.mc";
import "kernel/lib/resacct.mc";
import "kernel/fs/blobstore.mc";

global g_t: ProcTable;
global g_store: BlobStore;

fn worker() -> void {}
fn restored() -> void {}

export fn checkpoint_run() -> u32 {
    var pass: u32 = 1;
    proc_table_init(&g_t);
    blob_init(&g_store);

    // --- set up an agent: a spawned child with its own fds + a charged memory account ---
    let child: u32 = proc_spawn(&g_t, 0x1000, worker);
    let cs: usize = child as usize;

    // Open two descriptors in the child's fd-space (it inherits none here — bootstrap had none).
    switch fd_alloc(proc_fds(&g_t, cs), FD_PIPE, 11) {
        ok(fd) => { if fd != 0 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    switch fd_alloc(proc_fds(&g_t, cs), FD_SOCKET, 22) {
        ok(fd) => { if fd != 1 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    if fd_count(proc_fds(&g_t, cs)) != 2 { pass = 0; }

    // Charge the child's memory account so it carries a non-trivial used value.
    switch resacct_charge(proc_macct(&g_t, cs), 4096) {
        ok(u) => { if u != 4096 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    let saved_used: usize = resacct_used(proc_macct(&g_t, cs));
    // limit is read as used + available (resacct exposes no direct limit getter).
    let saved_limit: usize = resacct_used(proc_macct(&g_t, cs)) + resacct_available(proc_macct(&g_t, cs));
    if saved_used != 4096 { pass = 0; }

    // --- checkpoint the agent into a durable blob (id=1) ---
    switch checkpoint_save(&g_t, cs, &g_store, 1) {
        ok(n) => { if n == 0 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    if blob_count(&g_store) != 1 { pass = 0; }

    // --- the child exits: its live state is released (state is gone) ---
    g_t.current = cs;
    proc_exit(&g_t, 0);          // child -> Zombie; fds released, account reset
    g_t.current = 0;             // back to the bootstrap (the scheduler stub does not restore this)
    if fd_count(proc_fds(&g_t, cs)) != 0 { pass = 0; }              // fds gone
    if resacct_used(proc_macct(&g_t, cs)) != 0 { pass = 0; }        // account reset

    // --- restore the blob into a FRESH slot: a new process carrying the saved resource state ---
    var rs: usize = 0;
    switch checkpoint_restore(&g_t, &g_store, 1, 0x2000, restored) {
        ok(slot) => { rs = slot; }
        err(e) => { pass = 0; }
    }

    // The restored fd-space has the same descriptors (kind + handle) as the original agent.
    if fd_count(proc_fds(&g_t, rs)) != 2 { pass = 0; }
    switch fd_kind(proc_fds(&g_t, rs), 0) { ok(k) => { if k != FD_PIPE { pass = 0; } } err(e) => { pass = 0; } }
    switch fd_handle(proc_fds(&g_t, rs), 0) { ok(h) => { if h != 11 { pass = 0; } } err(e) => { pass = 0; } }
    switch fd_kind(proc_fds(&g_t, rs), 1) { ok(k) => { if k != FD_SOCKET { pass = 0; } } err(e) => { pass = 0; } }
    switch fd_handle(proc_fds(&g_t, rs), 1) { ok(h) => { if h != 22 { pass = 0; } } err(e) => { pass = 0; } }

    // ... and the restored account has the same used + limit as the saved one.
    if resacct_used(proc_macct(&g_t, rs)) != saved_used { pass = 0; }
    let restored_limit: usize = resacct_used(proc_macct(&g_t, rs)) + resacct_available(proc_macct(&g_t, rs));
    if restored_limit != saved_limit { pass = 0; }

    return pass;
}
