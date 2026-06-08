import "kernel/core/fdtable.mc";
global g_fds: FdTable;
export fn fdtable_run() -> u32 {
    var pass: u32 = 1;
    fd_init(&g_fds);
    let p: usize = fd_alloc(&g_fds, FD_PIPE, 10);   // fd 0 -> pipe
    let s: usize = fd_alloc(&g_fds, FD_SOCKET, 20); // fd 1 -> socket
    if p != 0 { pass = 0; }
    if s != 1 { pass = 0; }
    if fd_kind(&g_fds, s) != FD_SOCKET { pass = 0; }
    if fd_select(&g_fds) != FD_NONE { pass = 0; } // nothing ready
    fd_set_ready(&g_fds, s, true);                  // socket becomes readable
    if fd_select(&g_fds) != 1 { pass = 0; }         // select finds fd 1
    fd_close(&g_fds, s);
    if fd_kind(&g_fds, s) != FD_FREE { pass = 0; }
    if fd_select(&g_fds) != FD_NONE { pass = 0; }
    return pass;
}
