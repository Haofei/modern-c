// user/libc/cstr — the C-ABI mem/string core (memcpy/memmove/memset/memcmp, strlen/strcmp/
// strncmp/strchr/memchr), in MC. The freestanding bytes QuickJS leans on constantly.
//
// Reuses std/mem (mem_copy/mem_set) for the bulk routines. Like the allocator, all work is done
// on `usize` ADDRESSES — pointer params are consumed to an address immediately and result
// pointers are minted only at the return — so nothing fights MC's pointer-representation rules.
// Exports return `*mut u8` (== C void*/char* in ABI; separate TU, so no <string.h> conflict).

import "std/addr.mc";
import "std/mem.mc";
import "user/libc/lcommon.mc";

// ---- memory ----

export fn memcpy(dst: *mut u8, src: *const u8, n: usize) -> *mut u8 {
    let d: usize = dst as usize;
    let s: usize = src as usize;
    mem_copy(pa(d), pa(s), n);
    return lc_as_ptr(d);
}

export fn memset(dst: *mut u8, c: i32, n: usize) -> *mut u8 {
    let d: usize = dst as usize;
    mem_set(pa(d), c as u8, n);
    return lc_as_ptr(d);
}

export fn memmove(dst: *mut u8, src: *const u8, n: usize) -> *mut u8 {
    let d: usize = dst as usize;
    let s: usize = src as usize;
    if d == s || n == 0 {
        return lc_as_ptr(d);
    }
    if d < s {
        // forward copy is safe when the destination is below the source
        mem_copy(pa(d), pa(s), n);
    } else {
        // overlapping with dst above src: copy backwards
        var i: usize = n;
        while i > 0 {
            i = i - 1;
            lc_st8(d + i, lc_ld8(s + i));
        }
    }
    return lc_as_ptr(d);
}

export fn memcmp(a: *const u8, b: *const u8, n: usize) -> i32 {
    let pa_addr: usize = a as usize;
    let pb_addr: usize = b as usize;
    var i: usize = 0;
    while i < n {
        let ca: u8 = lc_ld8(pa_addr + i);
        let cb: u8 = lc_ld8(pb_addr + i);
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
        if lc_ld8(base + i) == target {
            return lc_as_ptr(base + i);
        }
        i = i + 1;
    }
    return lc_as_ptr(0); // NULL
}

// ---- strings (NUL-terminated) ----

export fn strlen(s: *const u8) -> usize {
    let base: usize = s as usize;
    var n: usize = 0;
    while lc_ld8(base + n) != 0 {
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
        let ca: u8 = lc_ld8(pa_addr + i);
        let cb: u8 = lc_ld8(pb_addr + i);
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
        let ca: u8 = lc_ld8(pa_addr + i);
        let cb: u8 = lc_ld8(pb_addr + i);
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

export fn strrchr(s: *const u8, c: i32) -> *mut u8 {
    let base: usize = s as usize;
    let target: u8 = c as u8;
    var last: usize = 0; // 0 == not found yet (NULL)
    var i: usize = 0;
    while true {
        let ch: u8 = lc_ld8(base + i);
        if ch == target {
            last = base + i + 1; // +1 so address 0 stays the not-found sentinel
        }
        if ch == 0 {
            break;
        }
        i = i + 1;
    }
    if last == 0 {
        return lc_as_ptr(0);
    }
    return lc_as_ptr(last - 1);
}

export fn strstr(haystack: *const u8, needle: *const u8) -> *mut u8 {
    let h0: usize = haystack as usize;
    let n0: usize = needle as usize;
    if lc_ld8(n0) == 0 {
        return lc_as_ptr(h0); // empty needle matches at the start
    }
    var i: usize = 0;
    while lc_ld8(h0 + i) != 0 {
        var j: usize = 0;
        while lc_ld8(n0 + j) != 0 && lc_ld8(h0 + i + j) == lc_ld8(n0 + j) {
            j = j + 1;
        }
        if lc_ld8(n0 + j) == 0 {
            return lc_as_ptr(h0 + i);
        }
        i = i + 1;
    }
    return lc_as_ptr(0); // not found
}

export fn strchr(s: *const u8, c: i32) -> *mut u8 {
    let base: usize = s as usize;
    let target: u8 = c as u8;
    var i: usize = 0;
    while true {
        let ch: u8 = lc_ld8(base + i);
        if ch == target {
            return lc_as_ptr(base + i); // also matches the NUL when target == 0
        }
        if ch == 0 {
            return lc_as_ptr(0); // NULL: not found
        }
        i = i + 1;
    }
    return lc_as_ptr(0); // unreachable
}
