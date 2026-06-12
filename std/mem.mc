// std/mem — address alignment + raw byte-move helpers for no-std kernel code.
//
// `align` must be a power of two. Overflow in `align_up` traps: MC arithmetic is
// checked by default, so the overflow *is* caught (a `checked_add` returning an
// option is unnecessary — the trap is the safety). These centralize the alignment
// math so allocators and mappers don't hand-roll `% PAGE_SIZE` everywhere.
//
// `mem_copy` / `mem_set` centralize byte moves between physical regions: the raw
// load/store is the *single* `unsafe` site, so callers (uaccess, the ELF loader, …)
// stop hand-rolling a `while { raw.store }` loop each with its own unsafe block.
//
// `mem.as_bytes(&value)` and `mem.bytes_equal(left, right)` are compiler-recognized
// byte-view operations from §14: `as_bytes` exposes a `[]const u8` view of typed
// storage, and `bytes_equal` compares byte slices explicitly, including padding.

import "std/addr.mc";

export fn is_aligned(addr: usize, align: usize) -> bool {
    return (addr % align) == 0;
}

export fn align_down(addr: usize, align: usize) -> usize {
    return addr - (addr % align);
}

export fn align_up(addr: usize, align: usize) -> usize {
    let bumped: usize = addr + (align - 1); // checked: traps on overflow
    return align_down(bumped, align);
}

// Copy `len` bytes from physical region `src` to `dst`. The raw load/store is the
// only unsafe operation; callers pass typed PAddrs. (Regions must not overlap with
// dst after src — like C memcpy.)
export fn mem_copy(dst: PAddr, src: PAddr, len: usize) -> void {
    var i: usize = 0;
    while i < len {
        unsafe {
            let b: u8 = raw.load<u8>(pa_offset(src, i));
            raw.store<u8>(pa_offset(dst, i), b);
        }
        i = i + 1;
    }
}

// Fill `len` bytes at physical region `dst` with `value`.
export fn mem_set(dst: PAddr, value: u8, len: usize) -> void {
    var i: usize = 0;
    while i < len {
        unsafe {
            raw.store<u8>(pa_offset(dst, i), value);
        }
        i = i + 1;
    }
}
