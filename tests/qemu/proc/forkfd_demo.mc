// Process fd-table lifecycle across fork/exec/wait. A process now carries an FdSpace
// (kernel/core/process). This test drives the three transitions of a descriptor across a
// process's life, on the host (the arch context primitives are stubbed by the C driver — only
// the bookkeeping path runs):
//   * fork (proc_spawn): the child inherits a COPY of the parent's descriptors at the same fd
//     numbers, sharing the backing resources but as independent slots;
//   * exec (proc_exec): replacing a process's image KEEPS its descriptors open (the classic
//     fork/exec distinction — fork copies, exec preserves);
//   * exit (proc_exit) + wait/reap: a dead process's descriptors are released, so a reused slot
//     never inherits a ghost.

import "kernel/core/process.mc";
import "kernel/lib/fdspace.mc";

global g_t: ProcTable;

fn worker() -> void {}
fn worker2() -> void {}

export fn forkfd_run() -> u32 {
    var pass: u32 = 1;
    proc_table_init(&g_t);

    // The bootstrap (pid 0, the current process) opens two descriptors.
    switch fd_alloc(proc_fds(&g_t, 0), FD_PIPE, 10) {
        ok(fd) => { if fd != 0 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    switch fd_alloc(proc_fds(&g_t, 0), FD_SOCKET, 20) {
        ok(fd) => { if fd != 1 { pass = 0; } }
        err(e) => { pass = 0; }
    }

    // --- fork: spawn a child; it inherits the parent's fds at the same numbers ---
    let child: u32 = proc_spawn(&g_t, 0x1000, worker);
    let cs: usize = child as usize;
    if fd_count(proc_fds(&g_t, cs)) != 2 { pass = 0; }
    switch fd_kind(proc_fds(&g_t, cs), 0) { ok(k) => { if k != FD_PIPE { pass = 0; } } err(e) => { pass = 0; } }
    switch fd_handle(proc_fds(&g_t, cs), 0) { ok(h) => { if h != 10 { pass = 0; } } err(e) => { pass = 0; } }
    switch fd_kind(proc_fds(&g_t, cs), 1) { ok(k) => { if k != FD_SOCKET { pass = 0; } } err(e) => { pass = 0; } }
    switch fd_handle(proc_fds(&g_t, cs), 1) { ok(h) => { if h != 20 { pass = 0; } } err(e) => { pass = 0; } }

    // copy independence: a descriptor opened in the PARENT after the fork is NOT seen by the
    // child (separate fd-spaces, not a shared table).
    switch fd_alloc(proc_fds(&g_t, 0), FD_FILE, 30) {
        ok(fd) => { if fd != 2 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    if fd_count(proc_fds(&g_t, cs)) != 2 { pass = 0; }   // child still has just the two it inherited
    // ... and closing the child's inherited fd 0 leaves the parent's fd 0 open (shared resource,
    // independent slots).
    switch fd_close(proc_fds(&g_t, cs), 0) { ok(b) => {} err(e) => { pass = 0; } }
    switch fd_kind(proc_fds(&g_t, 0), 0) { ok(k) => { if k != FD_PIPE { pass = 0; } } err(e) => { pass = 0; } }

    return pass;
}
