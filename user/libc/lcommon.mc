// user/libc/lcommon — the shared low-level helpers for the all-MC libc: raw byte load/store at
// an absolute address, and the C-ABI pointer<->address conversions. Factored out so the libc
// modules (alloc/cstr/cnum/stdio) can be aggregated into ONE compilation unit (user/libc/libc.mc)
// without each redefining these (which would be a duplicate top-level declaration).
//
// As in every libc module: work is done on `usize` ADDRESSES; `*mut u8` pointers are only minted
// at a C-ABI return / consumed from a C-ABI param, so nothing fights MC's pointer-representation
// rules. `*mut u8` is ABI-identical to C `void*`/`char*`.

import "std/addr.mc";

// Read one byte at an absolute address.
export fn lc_ld8(addr: usize) -> u8 {
    var b: u8 = 0;
    unsafe {
        b = raw.load<u8>(pa(addr));
    }
    return b;
}

// Write one byte at an absolute address.
export fn lc_st8(addr: usize, value: u8) -> void {
    unsafe {
        raw.store<u8>(pa(addr), value);
    }
}

// Mint a `*mut u8` user pointer from an address (0 -> the C NULL pointer).
export fn lc_as_ptr(addr: usize) -> *mut u8 {
    unsafe {
        return raw.ptr<u8>(addr);
    }
}

// The integer address behind a `*mut u8`.
export fn lc_ptr_addr(p: *mut u8) -> usize {
    unsafe {
        return p as usize;
    }
}
