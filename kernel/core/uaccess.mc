// kernel/core/uaccess — validated copies across the user/kernel boundary.
//
// A user pointer is the opaque `UserPtr` address class: the kernel cannot
// dereference it directly (E_USER_PTR_DEREF) or confuse it with a kernel address.
// Every user copy goes through a bounds-checked path that copies nothing on any
// validation failure — fail closed, never a wild read/write. The single `unsafe`
// block (in mem_copy) is the raw byte copy, justified by the preceding validation.
//
// Two backends:
//   - `UserSpace` (numeric): the user region is identity-mapped; validate the
//     [addr, addr+len) range against [base, limit) and copy via `phys(addr)`. This
//     is the bring-up path used before per-process page tables are active.
//   - `UserAddrSpace` (page-table-aware): translate every user virtual address
//     through the target process page table and validate PTE_U plus PTE_R/PTE_W
//     page by page before copying. This is the real user/kernel boundary — a
//     numeric range check alone cannot see unmapped holes or kernel-only pages.

import "std/addr.mc";
import "std/mem.mc";
import "kernel/arch/riscv64/paging.mc";

const UA_PAGE_SIZE: usize = 4096;

// The half-open user-accessible region [base, limit).
struct UserSpace {
    base: usize,
    limit: usize,
}

enum UaccessError {
    OutOfRange,      // [addr, addr+len) is not wholly inside the user region
    NotMapped,       // a page in the range has no valid user mapping
    NotUserPage,     // a page in the range is mapped but not user-accessible (no PTE_U)
    NotReadable,     // a source page is not readable (no PTE_R)
    NotWritable,     // a destination page is not writable (no PTE_W)
}

export fn user_space(base: usize, limit: usize) -> UserSpace {
    return .{ .base = base, .limit = limit };
}

// Is [addr, addr+len) wholly within the user region? Written to avoid any
// overflow: `addr <= limit` is checked first, so `limit - addr` cannot underflow,
// and a length that would run past the end (or wrap) is caught by `len > room`.
fn check_range(us: *UserSpace, addr: usize, len: usize) -> Result<bool, UaccessError> {
    if addr < us.base {
        return err(.OutOfRange);
    }
    if addr > us.limit {
        return err(.OutOfRange);
    }
    let room: usize = us.limit - addr;
    if len > room {
        return err(.OutOfRange);
    }
    return ok(true);
}

// Copy `len` bytes from user pointer `src` into the kernel buffer at `dst`, after
// validating the user range. Returns `OutOfRange` (copying nothing) if the source
// range escapes the user region.
export fn copy_from_user(us: *UserSpace, dst: PAddr, src: UserPtr<u8>, len: usize) -> Result<bool, UaccessError> {
    let src_addr: usize = src as usize;
    switch check_range(us, src_addr, len) {
        ok(v) => {}
        err(e) => { return err(e); } // out of range: copy nothing
    }
    mem_copy(dst, phys(src_addr), len); // range validated above; unsafe is in mem_copy
    return ok(true);
}

// Copy `len` bytes from the kernel buffer at `src` to user pointer `dst`, after
// validating the destination range.
export fn copy_to_user(us: *UserSpace, dst: UserPtr<u8>, src: PAddr, len: usize) -> Result<bool, UaccessError> {
    let dst_addr: usize = dst as usize;
    switch check_range(us, dst_addr, len) {
        ok(v) => {}
        err(e) => { return err(e); } // out of range: copy nothing
    }
    mem_copy(phys(dst_addr), src, len); // range validated above; unsafe is in mem_copy
    return ok(true);
}

// ----- single-snapshot discipline (U2: double-fetch / TOCTOU defense) -----
//
// The double-fetch (TOCTOU) bug class: the kernel copies a datum in from a
// `UserPtr`, validates it, then copies the SAME user pointer in a SECOND time to
// use it — and a concurrent thread (or a racing mapping) changed the bytes between
// the two reads, so the value validated is not the value used (the classic
// "validate, then it changes under you" CVE family, e.g. CVE-2016-6516).
//
// The structural fix is to copy a user datum in EXACTLY ONCE into a kernel-owned
// snapshot, then read only the snapshot. `UserSnapshot<T>` is that handle: it owns
// the copied-in bytes as an ordinary kernel value. There is no API to re-read the
// originating `UserPtr` from a snapshot, so a second fetch of the same datum is
// structurally unnecessary — validate and use both touch `.value`, immutable
// kernel memory the attacker cannot race. A snapshot is a value, not a borrow: once
// taken, the user pages may change freely; the decision is made against the frozen
// copy. The companion lint `tools/toolchain/double-fetch-audit.sh` flags code that
// copies the same `UserPtr` in twice — the pattern this type makes unnecessary.
struct UserSnapshot<T> {
    value: T,
}

// Copy a single `T` in from `src` (numeric UserSpace path) exactly once, returning
// an immutable kernel snapshot. Callers MUST make every decision against `.value`
// and MUST NOT re-fetch `src` — one fetch, one truth. On any validation failure
// nothing is copied and the snapshot is never returned (fail closed).
export fn fetch_user(comptime T: type, us: *UserSpace, src: UserPtr<T>) -> Result<UserSnapshot<T>, UaccessError> {
    var snap: UserSnapshot<T> = uninit; // .value is fully overwritten by the copy below, or never returned
    let dst: PAddr = pa((&snap.value) as usize);
    switch copy_from_user(us, dst, (src as usize) as UserPtr<u8>, sizeof(T)) {
        ok(v) => { return ok(snap); }
        err(e) => { return err(e); }
    }
}

// Page-table-aware single-fetch snapshot: copy one `T` in through the process page
// table exactly once. Same contract as `fetch_user`: use `.value`, never re-fetch.
export fn fetch_user_pt(comptime T: type, uas: *UserAddrSpace, src: UserPtr<T>) -> Result<UserSnapshot<T>, UaccessError> {
    var snap: UserSnapshot<T> = uninit;
    let dst: PAddr = pa((&snap.value) as usize);
    switch copy_from_user_pt(uas, dst, (src as usize) as UserPtr<u8>, sizeof(T)) {
        ok(v) => { return ok(snap); }
        err(e) => { return err(e); }
    }
}

// ----- tainted untrusted scalars (U3: bound-check user-derived lengths/indices) -----
//
// A value that ORIGINATES from user space is untrusted ("tainted"): the kernel must
// not use it as a length, index, copy-size, or loop bound until it has passed an
// explicit bounds check against a kernel-chosen limit. Skipping that check is the
// heartbleed shape: trust an attacker-supplied length and over-read past the buffer
// (CVE-2014-0160) — or under-index/overflow with an attacker-supplied index.
//
// `Tainted<T>` is the carrier. It wraps a scalar that came in from user space (via a
// `UserSnapshot` — see `taint`) and, crucially, exposes NO way to read the raw value:
// there is no `.value` field and no untaint-without-check accessor. The ONLY way to
// extract a usable scalar is to pass it through `checked_len` / `checked_index` /
// `validate_bound`, each of which returns `err(.OutOfRange)` (yielding nothing) when
// the value is outside `[0, limit]` (length) or `[0, limit)` (index). So a tainted
// length/index cannot reach a copy or a loop bound without first being validated — the
// discipline is structural, and the companion lint `tools/toolchain/taint-audit.sh`
// independently flags any user-derived value used as a length/index/loop-bound without
// passing one of these validators.
struct Tainted<T> {
    raw: T, // private-by-convention: read it ONLY through checked_len/checked_index/validate_bound
}

// Mark a freshly-snapshotted user scalar as tainted. Taking a snapshot is the moment a
// value crosses from user space into the kernel, so it is exactly where taint begins.
export fn taint(comptime T: type, snap: UserSnapshot<T>) -> Tainted<T> {
    return .{ .raw = snap.value };
}

// Validate a tainted value as a usable LENGTH: accept it only if it is <= `limit`
// (a length may equal the buffer size — it bounds a half-open copy of `v` bytes into
// a `limit`-byte buffer). Returns the now-trusted scalar, or `OutOfRange` if the
// attacker-supplied length would run past the buffer. Fail closed: on rejection no
// value is produced, so an over-long length can never drive a copy.
export fn checked_len(comptime T: type, t: Tainted<T>, limit: T) -> Result<T, UaccessError> {
    if t.raw > limit {
        return err(.OutOfRange);
    }
    return ok(t.raw);
}

// Validate a tainted value as a usable INDEX: accept it only if it is < `limit`
// (an index into a `limit`-element array is in [0, limit)). Returns the trusted
// index, or `OutOfRange`. Fail closed: an out-of-bounds index never reaches the
// subscript.
export fn checked_index(comptime T: type, t: Tainted<T>, limit: T) -> Result<T, UaccessError> {
    if t.raw >= limit {
        return err(.OutOfRange);
    }
    return ok(t.raw);
}

// Validate a tainted value against an explicit half-open bound `[lo, hi)`. The general
// form behind `checked_len`/`checked_index` for callers that need a non-zero floor.
export fn validate_bound(comptime T: type, t: Tainted<T>, lo: T, hi: T) -> Result<T, UaccessError> {
    if t.raw < lo {
        return err(.OutOfRange);
    }
    if t.raw >= hi {
        return err(.OutOfRange);
    }
    return ok(t.raw);
}

// ----- page-table-aware path -----
//
// A target address space: the process page table plus its [base, limit) user-region
// bound. Copies translate each user VA through `pt` and check PTE_U plus the access
// direction's permission, so unmapped holes and kernel-only pages in the middle of a
// range are caught — something a numeric range check cannot do.
struct UserAddrSpace {
    pt: *PageTable,
    base: usize,
    limit: usize,
}

export fn user_addr_space(pt: *PageTable, base: usize, limit: usize) -> UserAddrSpace {
    return .{ .pt = pt, .base = base, .limit = limit };
}

// Validate one user page: mapped, user-accessible (PTE_U), and with the required permission
// (PTE_W when `need_write`, else PTE_R).
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
            } else {
                if !mapping_is_readable(&m) {
                    return err(.NotReadable);
                }
            }
            return ok(true);
        }
        err(e) => {
            return err(.NotMapped);
        }
    }
}

// Whether each page touched by [addr, addr+len) is mapped, user-accessible, and has
// the required permission (PTE_W when `need_write`, else PTE_R). Validates the whole
// range up front so a copy is all-or-nothing: if any page fails, the caller copies
// nothing. `addr <= limit` is checked before `limit - addr` to avoid underflow.
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
    // Walk page by page from the page containing `addr` to the page containing the
    // last byte, so a multi-page range with a hole in the middle is rejected.
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

// Copy `len` bytes from user VA `src` (in `uas`) into the kernel buffer at `dst`,
// translating each page through the page table and requiring it be user-readable.
// Validated all-or-nothing: on any failure, nothing is copied.
export fn copy_from_user_pt(uas: *UserAddrSpace, dst: PAddr, src: UserPtr<u8>, len: usize) -> Result<bool, UaccessError> {
    let src_addr: usize = src as usize;
    switch check_pages(uas, src_addr, len, false) { // require PTE_U + PTE_R on every page
        ok(v) => {}
        err(e) => { return err(e); } // copy nothing on any unmapped/permission failure
    }
    return copy_pages(uas, dst, src_addr, len, false);
}

// Copy `len` bytes from the kernel buffer at `src` to user VA `dst` (in `uas`),
// translating each page through the page table and requiring it be user-writable.
export fn copy_to_user_pt(uas: *UserAddrSpace, dst: UserPtr<u8>, src: PAddr, len: usize) -> Result<bool, UaccessError> {
    let dst_addr: usize = dst as usize;
    switch check_pages(uas, dst_addr, len, true) { // require PTE_U + PTE_W on every page
        ok(v) => {}
        err(e) => { return err(e); } // copy nothing on any unmapped/permission failure
    }
    return copy_pages(uas, src, dst_addr, len, true);
}

// Copy `len` bytes between kernel buffer `kbuf` and user range [uaddr, uaddr+len), one
// page-slice at a time (each user page may map to a discontiguous frame). When `to_user` is
// true the user range is the destination, else the source.
//
// Each page is re-validated immediately before its slice is copied — not only by the up-front
// check_pages — so the validate→copy window shrinks to a single page. (Under cooperative
// single-core scheduling nothing changes the address space mid-copy; this is defense for when
// preemption/SMP land, where a fuller fix also locks the address space against concurrent
// unmap/TLB shootdown.) On a page that became invalid, the copy stops and returns the error,
// having copied the earlier pages.
fn copy_pages(uas: *UserAddrSpace, kbuf: PAddr, uaddr: usize, len: usize, to_user: bool) -> Result<bool, UaccessError> {
    var done: usize = 0;
    while done < len {
        let cur: usize = uaddr + done;
        let page: usize = cur - (cur % UA_PAGE_SIZE);
        switch validate_page(uas, page, to_user) { // re-check this page right before copying it
            ok(v) => {}
            err(e) => { return err(e); }
        }
        let page_off: usize = cur % UA_PAGE_SIZE;
        var chunk: usize = UA_PAGE_SIZE - page_off; // bytes left in this user page
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
