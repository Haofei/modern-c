// kernel/fs/vfs — a file-descriptor table over the ramfs.
//
// `open` finds-or-creates a named file and returns a small integer fd that carries
// a read/write position; `read`/`write` advance it; `close` frees it. This is the
// minimal VFS layer the syscall interface dispatches to. fds are bounds-checked and
// validated (use-after-close / bad fd is a typed error, never a wild access).

import "kernel/fs/ramfs.mc";

const MAX_FDS: usize = 16;
const FILE_CAPACITY: usize = 512; // per-file data reservation in the ramfs pool

struct Fd {
    file_idx: usize,
    pos: usize,
    active: bool,
}

struct Vfs {
    fs: Ramfs,
    fds: [MAX_FDS]Fd,
}

enum VfsError {
    TooManyOpen, // fd table full
    BadFd,       // fd out of range or not open
    FsFull,      // underlying ramfs is full
    WriteFailed, // underlying ramfs write error
}

export fn vfs_init(v: *mut Vfs) -> void {
    ramfs_init((&v.fs) as *mut Ramfs);
    var i: usize = 0;
    while i < MAX_FDS {
        v.fds[i].active = false;
        i = i + 1;
    }
}

fn alloc_fd(v: *mut Vfs, file_idx: usize) -> Result<usize, VfsError> {
    var i: usize = 0;
    while i < MAX_FDS {
        if !v.fds[i].active {
            v.fds[i].file_idx = file_idx;
            v.fds[i].pos = 0;
            v.fds[i].active = true;
            return ok(i);
        }
        i = i + 1;
    }
    return err(.TooManyOpen);
}

// Open `name`, creating it if absent. Returns a fresh fd positioned at 0.
export fn vfs_open(v: *mut Vfs, name: usize, name_len: usize) -> Result<usize, VfsError> {
    switch ramfs_find((&v.fs) as *mut Ramfs, name, name_len) {
        ok(idx) => {
            return alloc_fd(v, idx);
        }
        err(e) => {
            switch ramfs_create((&v.fs) as *mut Ramfs, name, name_len, FILE_CAPACITY) {
                ok(idx) => {
                    return alloc_fd(v, idx);
                }
                err(e2) => {
                    return err(.FsFull);
                }
            }
        }
    }
}

// Resolve an fd to its file index, or BadFd.
fn fd_file(v: *mut Vfs, fd: usize) -> Result<usize, VfsError> {
    if fd >= MAX_FDS {
        return err(.BadFd);
    }
    if !v.fds[fd].active {
        return err(.BadFd);
    }
    return ok(v.fds[fd].file_idx);
}

// Write `len` bytes from `src` to fd `fd`, advancing its position.
export fn vfs_write(v: *mut Vfs, fd: usize, src: usize, len: usize) -> Result<usize, VfsError> {
    let file_idx: usize = fd_file(v, fd)?; // VfsError -> VfsError (plain propagate)
    let n: usize = ramfs_write((&v.fs) as *mut Ramfs, file_idx, src, len)? else .WriteFailed;
    v.fds[fd].pos = v.fds[fd].pos + n;
    return ok(n);
}

// Read up to `len` bytes from fd `fd` (at its position) into `dst`, advancing it.
export fn vfs_read(v: *mut Vfs, fd: usize, dst: usize, len: usize) -> Result<usize, VfsError> {
    let file_idx: usize = fd_file(v, fd)?; // VfsError -> VfsError (plain propagate)
    let pos: usize = v.fds[fd].pos;
    let n: usize = ramfs_read_at((&v.fs) as *mut Ramfs, file_idx, pos, dst, len);
    v.fds[fd].pos = pos + n;
    return ok(n);
}

export fn vfs_close(v: *mut Vfs, fd: usize) -> Result<bool, VfsError> {
    if fd >= MAX_FDS {
        return err(.BadFd);
    }
    if !v.fds[fd].active {
        return err(.BadFd);
    }
    v.fds[fd].active = false;
    return ok(true);
}
