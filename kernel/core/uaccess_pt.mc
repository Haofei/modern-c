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

pub fn user_addr_space(pt: *PageTable, base: usize, limit: usize) -> UserAddrSpace {
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

// SMP / preemption guard for the copy pass (see copy_pages). FALSE today: the kernel is
// cooperative — no other hart and no preemption run between check_pages and the copy, so a
// page validated up front cannot be unmapped mid-copy. When preemptive scheduling or SMP
// lands, set this TRUE: it restores per-page RE-VALIDATION immediately before each slice is
// copied (a concurrent unmap could invalidate a page after check_pages passed), which — with
// an address-space lock / TLB-shootdown discipline — closes the validate→use window. Do NOT
// silently drop this re-validation for a future SMP config; it is a safety property.
const UACCESS_REVALIDATE_PER_PAGE: bool = false;

// Copy `len` bytes between kernel buffer `kbuf` and user range [uaddr, uaddr+len), one
// page-slice at a time.
//
// SINGLE-PASS (Phase 2.4): the whole range was already validated all-or-nothing by the
// up-front check_pages, so this pass does exactly ONE page-table walk per page —
// `page_table_lookup` returns BOTH the leaf flags and the offset-correct physical address, so
// the previously separate `page_table_translate` walk AND the redundant per-page
// re-validation walk are gone (the old path walked the table three times per page: check,
// re-check, translate). Fail-closed is preserved: check_pages proved every page here is
// mapped + user + correctly-permissioned before any byte moves. Under the SMP guard the flags
// from that same lookup are re-checked before each slice; on an invalidated page the copy
// stops and returns the error, having copied the earlier pages.
fn copy_pages(uas: *UserAddrSpace, kbuf: PAddr, uaddr: usize, len: usize, to_user: bool) -> Result<bool, UaccessError> {
    var done: usize = 0;
    while done < len {
        let cur: usize = uaddr + done;
        // One walk per page: resolve `cur` to its frame (offset included) and, only under the
        // SMP guard, re-validate the leaf flags — no second lookup, no separate translate.
        var user_pa: PAddr = uninit;
        switch page_table_lookup(uas.pt, va(cur)) {
            ok(m) => {
                if UACCESS_REVALIDATE_PER_PAGE {
                    if !mapping_is_user(&m) {
                        return err(.NotUserPage);
                    }
                    if to_user {
                        if !mapping_is_writable(&m) {
                            return err(.NotWritable);
                        }
                    }
                }
                user_pa = mapping_phys(&m);
            }
            err(e) => { return err(.NotMapped); } // only reachable under a concurrent unmap (SMP)
        }
        let page_off: usize = cur % UA_PAGE_SIZE;
        var chunk: usize = UA_PAGE_SIZE - page_off;
        let remaining: usize = len - done;
        if chunk > remaining {
            chunk = remaining;
        }
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
