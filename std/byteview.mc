// MC standard library — `byteview`: a fixed-capacity inline byte buffer (`ByteBuf<N>`)
// with bounds-checked element access and bulk copy to/from a physical address. Inline
// packet/file/DMA buffers can copy in one call instead of a hand-rolled raw.store loop,
// concentrating the unsafe MMIO/DMA access in one audited place (std/mem).

import "std/mem.mc";
import "std/addr.mc";

struct ByteBuf<N> {
    data: [N]u8,
    len: usize,
}

export fn bytebuf_init(comptime N: usize, b: *mut ByteBuf<N>) -> void {
    b.len = 0;
}
export fn bytebuf_len(comptime N: usize, b: *mut ByteBuf<N>) -> usize {
    return b.len;
}
export fn bytebuf_set(comptime N: usize, b: *mut ByteBuf<N>, i: usize, v: u8) -> void {
    if i < N {
        b.data[i] = v;
    }
}
export fn bytebuf_get(comptime N: usize, b: *mut ByteBuf<N>, i: usize) -> u8 {
    if i < N {
        return b.data[i];
    }
    return 0;
}

// Copy `n` bytes from physical address `src` into the buffer (clamped to N); sets len.
export fn bytebuf_copy_from(comptime N: usize, b: *mut ByteBuf<N>, src: PAddr, n: usize) -> usize {
    var m: usize = n;
    if m > N {
        m = N;
    }
    mem_copy(pa((&b.data[0]) as usize), src, m);
    b.len = m;
    return m;
}

// Copy `n` bytes (clamped to N) from the buffer to physical address `dst`.
export fn bytebuf_copy_to(comptime N: usize, b: *mut ByteBuf<N>, dst: PAddr, n: usize) -> usize {
    var m: usize = n;
    if m > N {
        m = N;
    }
    mem_copy(dst, pa((&b.data[0]) as usize), m);
    return m;
}
