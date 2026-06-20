// user/libc/cstr — the C-ABI mem/string core (memcpy/memmove/memset/memcmp, strlen/strcmp/
// strncmp/strchr/memchr), in MC. The freestanding bytes QuickJS leans on constantly.
//
// Reuses std/mem (mem_copy/mem_set) for the bulk routines. Like the allocator, all work is done
// on `usize` ADDRESSES — pointer params are consumed to an address immediately and result
// pointers are minted only at the return — so nothing fights MC's pointer-representation rules.
// Exports return `*mut u8` (== C void*/char* in ABI; separate TU, so no <string.h> conflict).

import "std/addr.mc";
import "std/mem.mc";

// Read / write one byte at an absolute address.
fn ld8(addr: usize) -> u8 {
    var b: u8 = 0;
    unsafe {
        b = raw.load<u8>(pa(addr));
    }
    return b;
}

fn st8(addr: usize, value: u8) -> void {
    unsafe {
        raw.store<u8>(pa(addr), value);
    }
}

fn as_ptr(addr: usize) -> *mut u8 {
    unsafe {
        return raw.ptr<u8>(addr);
    }
}

// ---- memory ----

export fn memcpy(dst: *mut u8, src: *const u8, n: usize) -> *mut u8 {
    let d: usize = dst as usize;
    let s: usize = src as usize;
    mem_copy(pa(d), pa(s), n);
    return as_ptr(d);
}

export fn memset(dst: *mut u8, c: i32, n: usize) -> *mut u8 {
    let d: usize = dst as usize;
    mem_set(pa(d), c as u8, n);
    return as_ptr(d);
}

export fn memmove(dst: *mut u8, src: *const u8, n: usize) -> *mut u8 {
    let d: usize = dst as usize;
    let s: usize = src as usize;
    if d == s || n == 0 {
        return as_ptr(d);
    }
    if d < s {
        // forward copy is safe when the destination is below the source
        mem_copy(pa(d), pa(s), n);
    } else {
        // overlapping with dst above src: copy backwards
        var i: usize = n;
        while i > 0 {
            i = i - 1;
            st8(d + i, ld8(s + i));
        }
    }
    return as_ptr(d);
}

export fn memcmp(a: *const u8, b: *const u8, n: usize) -> i32 {
    let pa_addr: usize = a as usize;
    let pb_addr: usize = b as usize;
    var i: usize = 0;
    while i < n {
        let ca: u8 = ld8(pa_addr + i);
        let cb: u8 = ld8(pb_addr + i);
        if ca != cb {
            return (ca as i32) - (cb as i32);
        }
        i = i + 1;
    }
    return 0;
}

export fn memchr(s: *const u8, c: i32, n: usize) -> *mut u8 {
    let base: usize = s as usize;
    let target: u8 = c as u8;
    var i: usize = 0;
    while i < n {
        if ld8(base + i) == target {
            return as_ptr(base + i);
        }
        i = i + 1;
    }
    return as_ptr(0); // NULL
}

// ---- strings (NUL-terminated) ----

export fn strlen(s: *const u8) -> usize {
    let base: usize = s as usize;
    var n: usize = 0;
    while ld8(base + n) != 0 {
        n = n + 1;
    }
    return n;
}

export fn strcmp(a: *const u8, b: *const u8) -> i32 {
    let pa_addr: usize = a as usize;
    let pb_addr: usize = b as usize;
    var i: usize = 0;
    // bounded by the shorter string + its NUL; a mismatch (incl. one ending early) returns.
    while true {
        let ca: u8 = ld8(pa_addr + i);
        let cb: u8 = ld8(pb_addr + i);
        if ca != cb {
            return (ca as i32) - (cb as i32);
        }
        if ca == 0 {
            return 0;
        }
        i = i + 1;
    }
    return 0; // unreachable; keeps the type checker happy
}

export fn strncmp(a: *const u8, b: *const u8, n: usize) -> i32 {
    let pa_addr: usize = a as usize;
    let pb_addr: usize = b as usize;
    var i: usize = 0;
    while i < n {
        let ca: u8 = ld8(pa_addr + i);
        let cb: u8 = ld8(pb_addr + i);
        if ca != cb {
            return (ca as i32) - (cb as i32);
        }
        if ca == 0 {
            return 0;
        }
        i = i + 1;
    }
    return 0;
}

export fn strchr(s: *const u8, c: i32) -> *mut u8 {
    let base: usize = s as usize;
    let target: u8 = c as u8;
    var i: usize = 0;
    while true {
        let ch: u8 = ld8(base + i);
        if ch == target {
            return as_ptr(base + i); // also matches the NUL when target == 0
        }
        if ch == 0 {
            return as_ptr(0); // NULL: not found
        }
        i = i + 1;
    }
    return as_ptr(0); // unreachable
}
