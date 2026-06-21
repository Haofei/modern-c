// kernel/core/uaccess_pt — the page-table-aware user/kernel copy path, arch-neutral.
//
// This is the single shared implementation of the `UserAddrSpace` copy contract used by the
// confined agents on every architecture. It is ARCH-NEUTRAL: it only calls the uniform paging
// interface (page_table_lookup / mapping_is_user / mapping_is_writable / page_table_translate)
// that each `kernel/arch/<arch>/paging.mc` exposes identically. It imports that paging module
// through the arch-selection seam (`kernel/arch/active/...`, plan R0b): the per-arch kernel
// binary is produced by compiling with `--arch=<arch>` (default riscv64), so x86_64 and
// aarch64 no longer need their own copies of this file (the former uaccess_x86.mc /
// uaccess_aarch64.mc, now deleted).
//
// Scope: only the page-table path. The full kernel/core/uaccess.mc additionally carries the
// numeric `UserSpace` bring-up path and the snapshot/taint generics; the confined QuickJS
// agent uses only the `UserAddrSpace` path here.
//
// Read side: a present, user-accessible page is readable on x86-64 (no separate readable bit)
// and aarch64 (EL0 AP implies read), so the read check needs only `mapping_is_user` — present
// is implied by a successful lookup. Writes additionally require `mapping_is_writable`.

import "std/addr.mc";
import "std/mem.mc";
import "kernel/arch/active/paging.mc";

const UA_PAGE_SIZE: usize = 4096;

enum UaccessError {
    OutOfRange,   // [addr, addr+len) is not wholly inside the user region
    NotMapped,    // a page in the range has no valid user mapping
    NotUserPage,  // a page is mapped but not user-accessible at every level
    NotWritable,  // a destination page is not writable
}

// A target address space: the process page table plus its [base, limit) user-region bound.
struct UserAddrSpace {
    pt: *PageTable,
    base: usize,
    limit: usize,
}

export fn user_addr_space(pt: *PageTable, base: usize, limit: usize) -> UserAddrSpace {
    return .{ .pt = pt, .base = base, .limit = limit };
}

// Validate one user page: mapped, user-accessible at every level, and — when writing —
// writable. A present, user-accessible page is always readable on the targeted arches, so the
// read side needs no separate readable check.
fn validate_page(uas: *UserAddrSpace, page: usize, need_write: bool) -> Result<bool, UaccessError> {
    switch page_table_lookup(uas.pt, va(page)) {
        ok(m) => {
            if !mapping_is_user(&m) {
                return err(.NotUserPage);
            }
            if need_write {
                if !mapping_is_writable(&m) {
                    return err(.NotWritable);
                }
            }
            return ok(true);
        }
        err(e) => {
            return err(.NotMapped);
        }
    }
}

// Whether each page touched by [addr, addr+len) is mapped, user-accessible, and has the
// required permission. All-or-nothing: if any page fails, the caller copies nothing.
fn check_pages(uas: *UserAddrSpace, addr: usize, len: usize, need_write: bool) -> Result<bool, UaccessError> {
    if addr < uas.base {
        return err(.OutOfRange);
    }
    if addr > uas.limit {
        return err(.OutOfRange);
    }
    let room: usize = uas.limit - addr;
    if len > room {
        return err(.OutOfRange);
    }
    if len == 0 {
        return ok(true);
    }
    var page: usize = addr - (addr % UA_PAGE_SIZE);
    let last: usize = addr + (len - 1);
    var more: bool = true;
    while more {
        switch validate_page(uas, page, need_write) {
            ok(v) => {}
            err(e) => { return err(e); }
        }
        if page >= (last - (last % UA_PAGE_SIZE)) {
            more = false;
        } else {
            page = page + UA_PAGE_SIZE;
        }
    }
    return ok(true);
}

// Copy `len` bytes from user VA `src` into the kernel buffer at `dst`, translating each page
// through the page table and requiring it be user-accessible. All-or-nothing.
export fn copy_from_user_pt(uas: *UserAddrSpace, dst: PAddr, src: UserPtr<u8>, len: usize) -> Result<bool, UaccessError> {
    let src_addr: usize = src as usize;
    switch check_pages(uas, src_addr, len, false) {
        ok(v) => {}
        err(e) => { return err(e); }
    }
    return copy_pages(uas, dst, src_addr, len, false);
}

// Copy `len` bytes from the kernel buffer at `src` to user VA `dst`, translating each page
// through the page table and requiring it be user-writable.
export fn copy_to_user_pt(uas: *UserAddrSpace, dst: UserPtr<u8>, src: PAddr, len: usize) -> Result<bool, UaccessError> {
    let dst_addr: usize = dst as usize;
    switch check_pages(uas, dst_addr, len, true) {
        ok(v) => {}
        err(e) => { return err(e); }
    }
    return copy_pages(uas, src, dst_addr, len, true);
}

// Copy `len` bytes between kernel buffer `kbuf` and user range [uaddr, uaddr+len), one
// page-slice at a time, re-validating each page right before its slice is copied.
fn copy_pages(uas: *UserAddrSpace, kbuf: PAddr, uaddr: usize, len: usize, to_user: bool) -> Result<bool, UaccessError> {
    var done: usize = 0;
    while done < len {
        let cur: usize = uaddr + done;
        let page: usize = cur - (cur % UA_PAGE_SIZE);
        switch validate_page(uas, page, to_user) {
            ok(v) => {}
            err(e) => { return err(e); }
        }
        let page_off: usize = cur % UA_PAGE_SIZE;
        var chunk: usize = UA_PAGE_SIZE - page_off;
        let remaining: usize = len - done;
        if chunk > remaining {
            chunk = remaining;
        }
        let user_pa: PAddr = page_table_translate(uas.pt, va(cur));
        let k: PAddr = pa_offset(kbuf, done);
        if to_user {
            mem_copy(user_pa, k, chunk);
        } else {
            mem_copy(k, user_pa, chunk);
        }
        done = done + chunk;
    }
    return ok(true);
}
