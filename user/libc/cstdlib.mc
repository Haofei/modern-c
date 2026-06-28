// user/libc/cstdlib — the C stdlib search/sort/tokenize trio the all-MC libc was missing, added for
// the WAMR engine (its symbol tables use bsearch/qsort; bh_common uses strtok_r). Standard C-ABI
// semantics. Work is done on `usize` ADDRESSES (per the libc convention in lcommon.mc); `*mut u8`
// pointers are minted only at the C-ABI boundary. Comparators are C `int(*)(const void*,const void*)`
// function pointers, modeled as `fn(*const u8, *const u8) -> i32`.

import "user/libc/lcommon.mc";
import "std/addr.mc";

// 64-bit load/store at an absolute address (for strtok_r's `char **saveptr`).
fn lc_ld64(addr: usize) -> usize {
    var v: u64 = 0;
    unsafe { v = raw.load<u64>(pa(addr)); }
    return v as usize;
}
fn lc_st64(addr: usize, value: usize) -> void {
    unsafe { raw.store<u64>(pa(addr), value as u64); }
}

// bsearch(key, base, nmemb, size, cmp): binary search over a sorted array; returns the matching
// element or NULL. cmp(key, elem) follows the C sign convention (<0 / 0 / >0).
export fn bsearch(key: *const u8, base: *const u8, nmemb: usize, size: usize,
                  cmp: fn(*const u8, *const u8) -> i32) -> *mut u8 {
    let b0: usize = base as usize;
    var lo: usize = 0;
    var hi: usize = nmemb;
    while lo < hi {
        let mid: usize = lo + (hi - lo) / 2;
        let elem: usize = b0 + mid * size;
        let c: i32 = cmp(key, lc_as_ptr(elem) as *const u8);
        if c < 0 {
            hi = mid;
        } else if c > 0 {
            lo = mid + 1;
        } else {
            return lc_as_ptr(elem);
        }
    }
    return lc_as_ptr(0);
}

fn lc_swap(a: usize, b: usize, size: usize) -> void {
    var i: usize = 0;
    while i < size {
        let t: u8 = lc_ld8(a + i);
        lc_st8(a + i, lc_ld8(b + i));
        lc_st8(b + i, t);
        i = i + 1;
    }
}

// qsort(base, nmemb, size, cmp): insertion sort. O(n^2) but correct for any input; the arrays the
// engine sorts (native-symbol tables) are small, sorted once at load. A stable, allocation-free sort
// is preferable here to a recursive quicksort in the confined agent.
export fn qsort(base: *mut u8, nmemb: usize, size: usize,
                cmp: fn(*const u8, *const u8) -> i32) -> void {
    if nmemb < 2 {
        return;
    }
    let b0: usize = base as usize;
    var i: usize = 1;
    while i < nmemb {
        var j: usize = i;
        while j > 0 {
            let a: usize = b0 + (j - 1) * size;
            let b: usize = b0 + j * size;
            if cmp(lc_as_ptr(a) as *const u8, lc_as_ptr(b) as *const u8) > 0 {
                lc_swap(a, b, size);
                j = j - 1;
            } else {
                j = 0; // sorted into place; stop scanning down
            }
        }
        i = i + 1;
    }
}

fn lc_in_delim(c: u8, delim: usize) -> bool {
    var i: usize = 0;
    while lc_ld8(delim + i) != 0 {
        if lc_ld8(delim + i) == c {
            return true;
        }
        i = i + 1;
    }
    return false;
}

// strtok_r(str, delim, saveptr): reentrant tokenizer. saveptr is a C `char**` (an address holding the
// saved char*); pass str==NULL to continue from the saved position.
export fn strtok_r(str: *mut u8, delim: *const u8, saveptr: *mut u8) -> *mut u8 {
    let sp: usize = saveptr as usize;
    let d: usize = delim as usize;
    var s: usize = str as usize;
    if s == 0 {
        s = lc_ld64(sp);
    }
    while lc_ld8(s) != 0 && lc_in_delim(lc_ld8(s), d) {
        s = s + 1;
    }
    if lc_ld8(s) == 0 {
        lc_st64(sp, s);
        return lc_as_ptr(0);
    }
    let tok: usize = s;
    while lc_ld8(s) != 0 && !lc_in_delim(lc_ld8(s), d) {
        s = s + 1;
    }
    if lc_ld8(s) != 0 {
        lc_st8(s, 0);
        s = s + 1;
    }
    lc_st64(sp, s);
    return lc_as_ptr(tok);
}
