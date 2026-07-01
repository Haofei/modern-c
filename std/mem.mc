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

fn check_power_of_two_align(align: usize) -> void {
    if align == 0 {
        unreachable;
    }
    if (align & (align - 1)) != 0 {
        unreachable;
    }
}

export fn is_aligned(addr: usize, align: usize) -> bool {
    check_power_of_two_align(align);
    return (addr % align) == 0;
}

export fn align_down(addr: usize, align: usize) -> usize {
    check_power_of_two_align(align);
    return addr - (addr % align);
}

export fn align_up(addr: usize, align: usize) -> usize {
    check_power_of_two_align(align);
    let bumped: usize = addr + (align - 1); // checked: traps on overflow
    return align_down(bumped, align);
}

// Overflow-safe capacity check: does `len` more bytes fit when `used` of `limit` are taken?
// Written as `len <= limit - used` (never `used + len <= limit`) so a hostile `len` cannot wrap
// the addition and trap — an oversized request returns false, letting callers fail closed with a
// typed error instead of aborting. `used > limit` (a corrupt counter) also returns false.
export fn fits_within(used: usize, len: usize, limit: usize) -> bool {
    if used > limit {
        return false;
    }
    return len <= limit - used;
}

// Copy `len` bytes from physical region `src` to `dst`. The raw load/store is the
// only unsafe operation; callers pass typed PAddrs. (Regions must not overlap with
// dst after src — like C memcpy.)
//
// Bulk copy runs 8 bytes (one u64 word) at a time — ~6-8x faster than the old
// byte-at-a-time loop on large copies (ELF load, DMA, CoW, uaccess, and every
// generated aggregate copy funnel through here). A byte HEAD aligns `dst` to 8, a
// word BODY copies the aligned middle, and a byte TAIL finishes the <8 remainder.
// SAFETY: the word path is only taken when src and dst share the same alignment
// mod 8 (`(d ^ s) & 7 == 0`); otherwise a u64 load/store would be unaligned, which
// faults on strict-align pre-MMU code — so we fall back to the byte loop.
export fn mem_copy(dst: PAddr, src: PAddr, len: usize) -> void {
    let d: usize = pa_value(dst);
    let s: usize = pa_value(src);
    if len > 0 {
        if d < (s + len) {
            if s < (d + len) {
                unreachable; // overlapping ranges: use a memmove-style helper instead
            }
        }
    }
    var i: usize = 0;
    // Word bulk: only when both ends share alignment mod 8 and there is a full word.
    if len >= 8 {
        if ((d ^ s) & 7) == 0 {
            // HEAD: advance byte-by-byte until dst is 8-aligned (< 8 iters, and
            // len >= 8 so this never overruns). src stays in lockstep alignment.
            while ((d + i) & 7) != 0 {
                unsafe {
                    let b: u8 = raw.load<u8>(pa_offset(src, i));
                    raw.store<u8>(pa_offset(dst, i), b);
                }
                i = i + 1;
            }
            // BODY: copy 8-byte words while a full word remains (`i <= len - 8`
            // avoids the checked-add overflow of `i + 8 <= len`).
            while i <= len - 8 {
                unsafe {
                    let w: u64 = raw.load<u64>(pa_offset(src, i));
                    raw.store<u64>(pa_offset(dst, i), w);
                }
                i = i + 8;
            }
        }
    }
    // TAIL (or the whole copy when the word path was skipped).
    while i < len {
        unsafe {
            let b: u8 = raw.load<u8>(pa_offset(src, i));
            raw.store<u8>(pa_offset(dst, i), b);
        }
        i = i + 1;
    }
}

// Fill `len` bytes at physical region `dst` with `value`.
//
// Same head/word-body/tail shape as `mem_copy`: the body stores a u64 built by
// replicating `value` across all 8 bytes. A single-buffer fill has no cross-buffer
// alignment concern, so the only guard is aligning `dst` to 8 before the word body.
export fn mem_set(dst: PAddr, value: u8, len: usize) -> void {
    let d: usize = pa_value(dst);
    var i: usize = 0;
    if len >= 8 {
        // Replicate the byte across a u64: 0xVV repeated 8 times (shift/or, no mul).
        var w: u64 = value as u64;
        w = w | (w << 8);
        w = w | (w << 16);
        w = w | (w << 32);
        // HEAD: byte fill until dst is 8-aligned.
        while ((d + i) & 7) != 0 {
            unsafe {
                raw.store<u8>(pa_offset(dst, i), value);
            }
            i = i + 1;
        }
        // BODY: word fill.
        while i <= len - 8 {
            unsafe {
                raw.store<u64>(pa_offset(dst, i), w);
            }
            i = i + 8;
        }
    }
    // TAIL (or whole fill when word path skipped).
    while i < len {
        unsafe {
            raw.store<u8>(pa_offset(dst, i), value);
        }
        i = i + 1;
    }
}
