// std/mem — address alignment helpers for no-std kernel code.
//
// `align` must be a power of two. Overflow in `align_up` traps: MC arithmetic is
// checked by default, so the overflow *is* caught (a `checked_add` returning an
// option is unnecessary — the trap is the safety). These centralize the alignment
// math so allocators and mappers don't hand-roll `% PAGE_SIZE` everywhere.

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
