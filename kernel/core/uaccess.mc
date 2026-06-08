// kernel/core/uaccess — validated copies across the user/kernel boundary.
//
// A user pointer is the opaque `UserPtr` address class: the kernel cannot
// dereference it directly (E_USER_PTR_DEREF) or confuse it with a kernel address.
// Every user copy goes through this one bounds-checked path. The requested range
// is validated against the process's user region *before* any access; an
// out-of-range (or length-overflowing) request returns a typed error and copies
// nothing — fail closed, never a wild read/write. The single `unsafe` block is the
// raw byte copy, justified by the preceding validation and isolated here.

import "std/addr.mc";
import "std/mem.mc";

// The half-open user-accessible region [base, limit).
struct UserSpace {
    base: usize,
    limit: usize,
}

enum UaccessError {
    OutOfRange, // [addr, addr+len) is not wholly inside the user region
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
    let validated: bool = check_range(us, src_addr, len)?; // propagate OutOfRange via `?`
    mem_copy(dst, phys(src_addr), len); // range validated above; unsafe is in mem_copy
    return ok(true);
}

// Copy `len` bytes from the kernel buffer at `src` to user pointer `dst`, after
// validating the destination range.
export fn copy_to_user(us: *UserSpace, dst: UserPtr<u8>, src: PAddr, len: usize) -> Result<bool, UaccessError> {
    let dst_addr: usize = dst as usize;
    let validated: bool = check_range(us, dst_addr, len)?; // propagate OutOfRange via `?`
    mem_copy(phys(dst_addr), src, len); // range validated above; unsafe is in mem_copy
    return ok(true);
}
