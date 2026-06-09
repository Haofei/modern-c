// MC standard library — `byteview`: a fixed-capacity inline byte buffer (`ByteBuf<N>`)
// with bounds-checked element access and bulk copy to/from a physical address. Inline
// packet/file/DMA buffers can copy in one call instead of a hand-rolled raw.store loop,
// concentrating the unsafe MMIO/DMA access in one audited place (std/mem).
//
// The bulk copies and the mutating set return a typed `OutOfBounds` error rather than
// silently clamping/dropping — for kernel buffers a quiet short copy is worse than a
// visible failure. (`bytebuf_get` is the one saturating accessor: it returns 0 for an
// out-of-range index, a deliberate safe read.)
//
// `len` is the logical length: the bytes [0, len) are the meaningful contents. copy_from
// sets it; set extends it when writing at/after the end; copy_to refuses to read past it,
// so a caller can never copy stale/uninitialized bytes beyond what was actually written.

import "std/mem.mc";
import "std/addr.mc";

struct ByteBuf<N> {
    data: [N]u8,
    len: usize,
}

enum ByteError {
    OutOfBounds, // a requested index or length exceeds the buffer capacity N
}

export fn bytebuf_init(comptime N: usize, b: *mut ByteBuf<N>) -> void {
    b.len = 0;
}
export fn bytebuf_len(comptime N: usize, b: *mut ByteBuf<N>) -> usize {
    return b.len;
}

// Store `v` at index `i`; OutOfBounds if i >= N (does not silently drop the write). Writing
// at or past the current end extends the logical length so copy_to sees the new byte.
export fn bytebuf_set(comptime N: usize, b: *mut ByteBuf<N>, i: usize, v: u8) -> Result<bool, ByteError> {
    if i >= N {
        return err(.OutOfBounds);
    }
    b.data[i] = v;
    if i >= b.len {
        b.len = i + 1;
    }
    return ok(true);
}

// Saturating read: byte at index `i`, or 0 if i >= N.
export fn bytebuf_get(comptime N: usize, b: *mut ByteBuf<N>, i: usize) -> u8 {
    if i < N {
        return b.data[i];
    }
    return 0;
}

// Copy `n` bytes from physical address `src` into the buffer; OutOfBounds if n > N. On
// success sets len = n.
export fn bytebuf_copy_from(comptime N: usize, b: *mut ByteBuf<N>, src: PAddr, n: usize) -> Result<usize, ByteError> {
    if n > N {
        return err(.OutOfBounds);
    }
    mem_copy(pa((&b.data[0]) as usize), src, n);
    b.len = n;
    return ok(n);
}

// Copy `n` bytes from the buffer to physical address `dst`; OutOfBounds if n exceeds the
// logical length (so only meaningful bytes are copied, never stale ones past `len`).
export fn bytebuf_copy_to(comptime N: usize, b: *mut ByteBuf<N>, dst: PAddr, n: usize) -> Result<usize, ByteError> {
    if n > b.len {
        return err(.OutOfBounds);
    }
    mem_copy(dst, pa((&b.data[0]) as usize), n);
    return ok(n);
}
