// kernel/lib/fdspace — a process's file-descriptor space: each fd maps to a (kind, handle)
// with a readiness bit, over a std `SlotMap` (so slot allocation / liveness / bounds are
// not hand-rolled). A reusable OS building block — the basis for BSD-sockets-as-fds and
// select/poll. No sentinels: alloc/select/lookup return typed `Result`s, so a caller can
// never confuse a real fd with a 0xFFFF "none".

import "std/slotmap.mc";

const FD_MAX: usize = 8;

// Conventional descriptor kinds (the meaning is the caller's; fdspace only stores it).
const FD_PIPE: u32 = 1;
const FD_SOCKET: u32 = 2;
const FD_FILE: u32 = 3;

enum FdError {
    Full,      // no free descriptor
    BadFd,     // fd out of range or not open
    NoneReady, // select found no ready descriptor
}

struct FdEntry {
    kind: u32,
    handle: u32,
    ready: bool,
}

struct FdSpace {
    slots: SlotMap<FdEntry, FD_MAX>,
}

export fn fd_init(s: *mut FdSpace) -> void {
    slotmap_init(FdEntry, FD_MAX, &s.slots);
}

export fn fd_count(s: *mut FdSpace) -> usize {
    return slotmap_count(FdEntry, FD_MAX, &s.slots);
}

// Allocate the lowest free fd for (kind, handle); Full if the space is exhausted.
export fn fd_alloc(s: *mut FdSpace, kind: u32, handle: u32) -> Result<usize, FdError> {
    switch slotmap_alloc(FdEntry, FD_MAX, &s.slots) {
        ok(fd) => {
            let e: FdEntry = .{ .kind = kind, .handle = handle, .ready = false };
            switch slotmap_set(FdEntry, FD_MAX, &s.slots, fd, e) {
                ok(b) => {}
                err(x) => {}
            }
            return ok(fd);
        }
        err(x) => {
            return err(.Full);
        }
    }
}

export fn fd_kind(s: *mut FdSpace, fd: usize) -> Result<u32, FdError> {
    switch slotmap_get(FdEntry, FD_MAX, &s.slots, fd) {
        ok(e) => {
            return ok(e.kind);
        }
        err(x) => {
            return err(.BadFd);
        }
    }
}

export fn fd_handle(s: *mut FdSpace, fd: usize) -> Result<u32, FdError> {
    switch slotmap_get(FdEntry, FD_MAX, &s.slots, fd) {
        ok(e) => {
            return ok(e.handle);
        }
        err(x) => {
            return err(.BadFd);
        }
    }
}

export fn fd_set_ready(s: *mut FdSpace, fd: usize, r: bool) -> Result<bool, FdError> {
    switch slotmap_get(FdEntry, FD_MAX, &s.slots, fd) {
        ok(e) => {
            var ne: FdEntry = e;
            ne.ready = r;
            switch slotmap_set(FdEntry, FD_MAX, &s.slots, fd, ne) {
                ok(b) => {}
                err(x) => {}
            }
            return ok(true);
        }
        err(x) => {
            return err(.BadFd);
        }
    }
}

export fn fd_is_ready(s: *mut FdSpace, fd: usize) -> bool {
    switch slotmap_get(FdEntry, FD_MAX, &s.slots, fd) {
        ok(e) => {
            return e.ready;
        }
        err(x) => {
            return false;
        }
    }
}

export fn fd_close(s: *mut FdSpace, fd: usize) -> Result<bool, FdError> {
    switch slotmap_free(FdEntry, FD_MAX, &s.slots, fd) {
        ok(b) => {
            return ok(true);
        }
        err(x) => {
            return err(.BadFd);
        }
    }
}

// Duplicate an fd: a fresh (lowest free) descriptor referring to the same (kind, handle). The
// two descriptors share the underlying resource (the same socket/pipe/file handle) but are
// independent fd slots — the primitive fd inheritance across fork builds on. The dup starts
// not-ready (its readiness is recomputed by the next poll). BadFd if `fd` is not open.
export fn fd_dup(s: *mut FdSpace, fd: usize) -> Result<usize, FdError> {
    switch slotmap_get(FdEntry, FD_MAX, &s.slots, fd) {
        ok(e) => {
            return fd_alloc(s, e.kind, e.handle);
        }
        err(x) => {
            return err(.BadFd);
        }
    }
}

// Inherit a parent's whole descriptor space into a fresh child space — fork() fd semantics.
// Every live parent descriptor is copied to the SAME fd number in the child (numbers preserved,
// including gaps), referring to the same (kind, handle) backing resource: independent child
// slots that share the underlying socket/pipe/file, exactly like `fd_dup` applied across the
// table. `child` must be freshly `fd_init`'d (empty); inherited descriptors start not-ready
// (readiness is recomputed by the next poll). Returns the count inherited, or `Full` if the
// child could not hold a descriptor (only possible when `child` was not empty).
export fn fd_inherit(parent: *mut FdSpace, child: *mut FdSpace) -> Result<usize, FdError> {
    var i: usize = 0;
    var inherited: usize = 0;
    while i < FD_MAX {
        if slotmap_live(FdEntry, FD_MAX, &parent.slots, i) {
            switch slotmap_get(FdEntry, FD_MAX, &parent.slots, i) {
                ok(e) => {
                    switch slotmap_alloc_at(FdEntry, FD_MAX, &child.slots, i) {
                        ok(fd) => {
                            let ne: FdEntry = .{ .kind = e.kind, .handle = e.handle, .ready = false };
                            switch slotmap_set(FdEntry, FD_MAX, &child.slots, fd, ne) {
                                ok(b) => {}
                                err(x) => {}
                            }
                            inherited = inherited + 1;
                        }
                        err(x) => {
                            return err(.Full);
                        }
                    }
                }
                err(x) => {}
            }
        }
        i = i + 1;
    }
    return ok(inherited);
}

// select/poll: the lowest open fd that is ready, or NoneReady.
export fn fd_select(s: *mut FdSpace) -> Result<usize, FdError> {
    var i: usize = 0;
    while i < FD_MAX {
        if slotmap_live(FdEntry, FD_MAX, &s.slots, i) {
            switch slotmap_get(FdEntry, FD_MAX, &s.slots, i) {
                ok(e) => {
                    if e.ready {
                        return ok(i);
                    }
                }
                err(x) => {}
            }
        }
        i = i + 1;
    }
    return err(.NoneReady);
}
