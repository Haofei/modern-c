import "kernel/lib/fdspace.mc";
global g_fds: FdSpace;
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
    return pass;
}
