// kernel/core/fdtable — a per-process file-descriptor table: each fd maps to a kind
// (pipe/socket/file) and a backing handle, with a readiness bit. Built on std `SlotMap`,
// so the free-slot scan / liveness tracking / bounds checks are not hand-rolled here —
// only the fd-specific bits (kinds, readiness, select) live in this file.

import "std/slotmap.mc";

const FD_MAX: usize = 8;
const FD_FREE: u32 = 0;
const FD_PIPE: u32 = 1;
const FD_SOCKET: u32 = 2;
const FD_FILE: u32 = 3;
const FD_NONE: usize = 0xFFFF; // no ready fd

struct FdEntry {
    kind: u32,
    handle: u32,
    ready: bool,
}

struct FdTable {
    slots: SlotMap<FdEntry, FD_MAX>,
}

export fn fd_init(t: *mut FdTable) -> void {
    slotmap_init(FdEntry, FD_MAX, &t.slots);
}

// Allocate the lowest free fd for (kind, handle); returns the fd, or FD_NONE if full.
export fn fd_alloc(t: *mut FdTable, kind: u32, handle: u32) -> usize {
    switch slotmap_alloc(FdEntry, FD_MAX, &t.slots) {
        ok(fd) => {
            let e: FdEntry = .{ .kind = kind, .handle = handle, .ready = false };
            switch slotmap_set(FdEntry, FD_MAX, &t.slots, fd, e) {
                ok(b) => {}
                err(x) => {}
            }
            return fd;
        }
        err(x) => {
            return FD_NONE;
        }
    }
}

export fn fd_kind(t: *mut FdTable, fd: usize) -> u32 {
    switch slotmap_get(FdEntry, FD_MAX, &t.slots, fd) {
        ok(e) => {
            return e.kind;
        }
        err(x) => {
            return FD_FREE;
        }
    }
}

export fn fd_set_ready(t: *mut FdTable, fd: usize, r: bool) -> void {
    switch slotmap_get(FdEntry, FD_MAX, &t.slots, fd) {
        ok(e) => {
            var ne: FdEntry = e;
            ne.ready = r;
            switch slotmap_set(FdEntry, FD_MAX, &t.slots, fd, ne) {
                ok(b) => {}
                err(x) => {}
            }
        }
        err(x) => {}
    }
}

export fn fd_close(t: *mut FdTable, fd: usize) -> void {
    switch slotmap_free(FdEntry, FD_MAX, &t.slots, fd) {
        ok(b) => {}
        err(x) => {}
    }
}

// select/poll: the lowest open fd that is ready, or FD_NONE.
export fn fd_select(t: *mut FdTable) -> usize {
    var i: usize = 0;
    while i < FD_MAX {
        if slotmap_live(FdEntry, FD_MAX, &t.slots, i) {
            switch slotmap_get(FdEntry, FD_MAX, &t.slots, i) {
                ok(e) => {
                    if e.ready {
                        return i;
                    }
                }
                err(x) => {}
            }
        }
        i = i + 1;
    }
    return FD_NONE;
}
