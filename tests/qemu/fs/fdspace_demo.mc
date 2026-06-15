import "kernel/lib/fdspace.mc";
global g_fds: FdSpace;
global g_child: FdSpace;
export fn fdspace_run() -> u32 {
    var pass: u32 = 1;
    fd_init(&g_fds);

    // alloc: pipe -> fd 0, socket -> fd 1 (lowest free)
    switch fd_alloc(&g_fds, FD_PIPE, 10) {
        ok(fd) => { if fd != 0 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    switch fd_alloc(&g_fds, FD_SOCKET, 20) {
        ok(fd) => { if fd != 1 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    if fd_count(&g_fds) != 2 { pass = 0; }

    // kind/handle lookups
    switch fd_kind(&g_fds, 1) {
        ok(k) => { if k != FD_SOCKET { pass = 0; } }
        err(e) => { pass = 0; }
    }
    switch fd_handle(&g_fds, 1) {
        ok(h) => { if h != 20 { pass = 0; } }
        err(e) => { pass = 0; }
    }

    // nothing ready -> select is NoneReady (no 0xFFFF sentinel)
    switch fd_select(&g_fds) {
        ok(fd) => { pass = 0; }
        err(e) => {}
    }
    // socket becomes readable -> select finds fd 1
    switch fd_set_ready(&g_fds, 1, true) { ok(b) => {} err(e) => { pass = 0; } }
    switch fd_select(&g_fds) {
        ok(fd) => { if fd != 1 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    if !fd_is_ready(&g_fds, 1) { pass = 0; }

    // close fd 1 -> lookups BadFd, select NoneReady
    switch fd_close(&g_fds, 1) { ok(b) => {} err(e) => { pass = 0; } }
    switch fd_kind(&g_fds, 1) {
        ok(k) => { pass = 0; }
        err(e) => {}
    }
    switch fd_select(&g_fds) {
        ok(fd) => { pass = 0; }
        err(e) => {}
    }

    // reuse: alloc reuses the freed fd 1 (lowest free)
    switch fd_alloc(&g_fds, FD_FILE, 30) {
        ok(fd) => { if fd != 1 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    switch fd_kind(&g_fds, 1) {
        ok(k) => { if k != FD_FILE { pass = 0; } }
        err(e) => { pass = 0; }
    }

    // closing a never-opened fd errors (BadFd), not a silent no-op
    switch fd_close(&g_fds, 5) {
        ok(b) => { pass = 0; }
        err(e) => {}
    }

    // dup: fd 0 (pipe, handle 10) -> a fresh fd (lowest free = 2) onto the SAME (kind, handle),
    // an independent slot (the fd-inheritance / dup primitive).
    var dup_fd: usize = 0;
    switch fd_dup(&g_fds, 0) {
        ok(fd) => { dup_fd = fd; if fd != 2 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    switch fd_kind(&g_fds, dup_fd) {
        ok(k) => { if k != FD_PIPE { pass = 0; } }
        err(e) => { pass = 0; }
    }
    switch fd_handle(&g_fds, dup_fd) {
        ok(h) => { if h != 10 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    // closing the dup leaves the original fd 0 open — independent descriptors
    switch fd_close(&g_fds, dup_fd) { ok(b) => {} err(e) => { pass = 0; } }
    switch fd_kind(&g_fds, 0) {
        ok(k) => { if k != FD_PIPE { pass = 0; } }
        err(e) => { pass = 0; }
    }
    // dup of a never-opened fd is BadFd, not a silent slot
    switch fd_dup(&g_fds, 6) {
        ok(fd) => { pass = 0; }
        err(e) => {}
    }

    // --- fd_inherit (fork fd-space inheritance) ---
    // Build a parent space with a GAP, to prove inherit preserves EXACT fd numbers: alloc
    // fd 2 (SOCKET,40), then free fd 1 -> live set {0:PIPE/10, 2:SOCKET/40}, fd 1 free.
    switch fd_alloc(&g_fds, FD_SOCKET, 40) {
        ok(fd) => { if fd != 2 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    switch fd_close(&g_fds, 1) { ok(b) => {} err(e) => { pass = 0; } }
    if fd_count(&g_fds) != 2 { pass = 0; }
    // mark fd 0 ready, so we can prove inherited descriptors start NOT ready
    switch fd_set_ready(&g_fds, 0, true) { ok(b) => {} err(e) => { pass = 0; } }

    // fork: a fresh child inherits the whole space -> same fd NUMBERS (0 and 2, the gap at
    // fd 1 preserved), same (kind, handle), as independent slots.
    fd_init(&g_child);
    switch fd_inherit(&g_fds, &g_child) {
        ok(n) => { if n != 2 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    if fd_count(&g_child) != 2 { pass = 0; }
    // fd 0 inherited (PIPE,10) at the same number
    switch fd_kind(&g_child, 0) { ok(k) => { if k != FD_PIPE { pass = 0; } } err(e) => { pass = 0; } }
    switch fd_handle(&g_child, 0) { ok(h) => { if h != 10 { pass = 0; } } err(e) => { pass = 0; } }
    // fd 2 inherited (SOCKET,40) at the same number
    switch fd_kind(&g_child, 2) { ok(k) => { if k != FD_SOCKET { pass = 0; } } err(e) => { pass = 0; } }
    switch fd_handle(&g_child, 2) { ok(h) => { if h != 40 { pass = 0; } } err(e) => { pass = 0; } }
    // the gap at fd 1 is preserved (free in the child too)
    switch fd_kind(&g_child, 1) {
        ok(k) => { pass = 0; }
        err(e) => {}
    }
    // inherited descriptors start NOT ready (readiness is recomputed by the child's next poll)
    if fd_is_ready(&g_child, 0) { pass = 0; }
    if !fd_is_ready(&g_fds, 0) { pass = 0; }   // ... and the parent's readiness is untouched
    // independence: closing the child's fd 0 leaves the parent's fd 0 open (shared resource,
    // separate slots)
    switch fd_close(&g_child, 0) { ok(b) => {} err(e) => { pass = 0; } }
    switch fd_kind(&g_fds, 0) { ok(k) => { if k != FD_PIPE { pass = 0; } } err(e) => { pass = 0; } }

    return pass;
}
