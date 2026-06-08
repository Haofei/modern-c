// kernel/core/fdtable — a per-process file-descriptor table: each fd maps to a kind
// (pipe/socket/file) and a backing handle, with a readiness bit. fd_select scans for a
// ready descriptor — the basis for BSD sockets-as-fds and select/poll.

const FD_MAX: usize = 8;
const FD_FREE: u32 = 0;
const FD_PIPE: u32 = 1;
const FD_SOCKET: u32 = 2;
const FD_FILE: u32 = 3;
const FD_NONE: usize = 0xFFFF; // no ready fd

struct FdTable {
    kind: [FD_MAX]u32,
    handle: [FD_MAX]u32,
    ready: [FD_MAX]bool,
}

export fn fd_init(t: *mut FdTable) -> void {
    var i: usize = 0;
    while i < FD_MAX {
        t.kind[i] = FD_FREE;
        t.ready[i] = false;
        i = i + 1;
    }
}

// Allocate the lowest free fd for (kind, handle); returns the fd, or FD_NONE if full.
export fn fd_alloc(t: *mut FdTable, kind: u32, handle: u32) -> usize {
    var i: usize = 0;
    while i < FD_MAX {
        if t.kind[i] == FD_FREE {
            t.kind[i] = kind;
            t.handle[i] = handle;
            t.ready[i] = false;
            return i;
        }
        i = i + 1;
    }
    return FD_NONE;
}

export fn fd_kind(t: *mut FdTable, fd: usize) -> u32 {
    if fd < FD_MAX {
        return t.kind[fd];
    }
    return FD_FREE;
}

export fn fd_set_ready(t: *mut FdTable, fd: usize, r: bool) -> void {
    if fd < FD_MAX {
        t.ready[fd] = r;
    }
}

export fn fd_close(t: *mut FdTable, fd: usize) -> void {
    if fd < FD_MAX {
        t.kind[fd] = FD_FREE;
        t.ready[fd] = false;
    }
}

// select/poll: the lowest open fd that is ready, or FD_NONE.
export fn fd_select(t: *mut FdTable) -> usize {
    var i: usize = 0;
    while i < FD_MAX {
        if t.kind[i] != FD_FREE {
            if t.ready[i] {
                return i;
            }
        }
        i = i + 1;
    }
    return FD_NONE;
}
