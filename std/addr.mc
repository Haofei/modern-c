// std/addr — checked, typed physical-address arithmetic over MC's opaque address
// classes.
//
// `PAddr` is an opaque address class: raw `+`, deref, ordering and equality on it
// are compile errors (E_ADDRESS_CLASS_OPERATION / E_PADDR_DEREF), which prevents
// address-class confusion and unchecked pointer math. That safety is also why
// kernel code otherwise falls back to a bare `usize`. This module gives the kernel
// the *safe* operations it needs — offset, alignment, distance, ordering, ranges
// — by funnelling each through one audited `usize` boundary, where MC's
// checked-by-default arithmetic catches overflow. The kernel never hand-rolls
// address math on a raw `usize` again.
//
// VAddr / DmaAddr / UserAddr get the same shape as page tables, DMA, and user mode
// land; PAddr is the physical-memory path the frame/page allocators need now.

// ----- construction / raw access (the only usize<->PAddr boundary) -----

// Wrap a raw physical address value (e.g. from the platform/device tree).
export fn pa(value: usize) -> PAddr {
    return phys(value);
}

// The raw value of a physical address — use only at the hardware/raw-access edge.
export fn pa_value(a: PAddr) -> usize {
    return a as usize;
}

// ----- checked arithmetic -----

// `a + n`, trapping on address-space overflow (MC arithmetic is checked).
export fn pa_offset(a: PAddr, n: usize) -> PAddr {
    return phys((a as usize) + n);
}

// Bytes from `from` to `to`; requires `from <= to` (checked subtraction traps).
export fn pa_diff(from: PAddr, to: PAddr) -> usize {
    return (to as usize) - (from as usize);
}

// ----- alignment (`align` must be a power of two) -----

export fn pa_is_aligned(a: PAddr, align: usize) -> bool {
    return ((a as usize) % align) == 0;
}

export fn pa_align_down(a: PAddr, align: usize) -> PAddr {
    if align == 0 {
        unreachable; // alignment must be non-zero (else `% align` divides by zero)
    }
    if (align & (align - 1)) != 0 {
        unreachable; // alignment must be a power of two (matches pa_align_up)
    }
    let v: usize = a as usize;
    return phys(v - (v % align));
}

export fn pa_align_up(a: PAddr, align: usize) -> PAddr {
    if align == 0 {
        unreachable; // alignment must be non-zero
    }
    if (align & (align - 1)) != 0 {
        unreachable; // alignment must be a power of two (matches std/mem's stricter check)
    }
    let v: usize = a as usize;
    let bumped: usize = v + (align - 1); // checked: traps on overflow
    return phys(bumped - (bumped % align));
}

// ----- ordering / equality (the opaque class forbids `<` / `==` directly) -----

export fn pa_lt(a: PAddr, b: PAddr) -> bool {
    return (a as usize) < (b as usize);
}
export fn pa_le(a: PAddr, b: PAddr) -> bool {
    return (a as usize) <= (b as usize);
}
export fn pa_eq(a: PAddr, b: PAddr) -> bool {
    return (a as usize) == (b as usize);
}

// ----- a half-open physical range [start, end) -----

struct PhysRange {
    start: PAddr,
    end: PAddr,
}

// Build a range of `len` bytes from `start`, trapping if `start + len` overflows.
export fn phys_range(start: PAddr, len: usize) -> PhysRange {
    return .{ .start = start, .end = pa_offset(start, len) };
}

export fn pr_start(r: *PhysRange) -> PAddr {
    return r.start;
}

export fn pr_end(r: *PhysRange) -> PAddr {
    return r.end;
}

export fn pr_len(r: *PhysRange) -> usize {
    return pa_diff(r.start, r.end);
}

// Does the range contain address `a` (start <= a < end)?
export fn pr_contains(r: *PhysRange, a: PAddr) -> bool {
    if pa_lt(a, r.start) {
        return false;
    }
    return pa_lt(a, r.end);
}

// ----- VAddr (virtual) — same checked operations over the virtual address class.
// Used by the page-table / virtual-memory code; kept symmetric with PAddr so the
// two cannot be confused (E_ADDRESS_CLASS_MISMATCH).

export fn va(value: usize) -> VAddr {
    return value as VAddr;
}

export fn va_value(a: VAddr) -> usize {
    return a as usize;
}

export fn va_offset(a: VAddr, n: usize) -> VAddr {
    return ((a as usize) + n) as VAddr; // checked: traps on overflow
}

export fn va_diff(from: VAddr, to: VAddr) -> usize {
    return (to as usize) - (from as usize);
}

export fn va_is_aligned(a: VAddr, align: usize) -> bool {
    if align == 0 {
        unreachable; // alignment must be non-zero (else `% align` divides by zero)
    }
    if (align & (align - 1)) != 0 {
        unreachable; // alignment must be a power of two (matches va_align_up)
    }
    return ((a as usize) % align) == 0;
}

export fn va_align_down(a: VAddr, align: usize) -> VAddr {
    if align == 0 {
        unreachable; // alignment must be non-zero (else `% align` divides by zero)
    }
    if (align & (align - 1)) != 0 {
        unreachable; // alignment must be a power of two (matches va_align_up)
    }
    let v: usize = a as usize;
    return (v - (v % align)) as VAddr;
}

export fn va_align_up(a: VAddr, align: usize) -> VAddr {
    if align == 0 {
        unreachable; // alignment must be non-zero
    }
    if (align & (align - 1)) != 0 {
        unreachable; // alignment must be a power of two (matches pa_align_up / std/mem)
    }
    let v: usize = a as usize;
    let bumped: usize = v + (align - 1); // checked: traps on overflow
    return (bumped - (bumped % align)) as VAddr;
}

export fn va_lt(a: VAddr, b: VAddr) -> bool {
    return (a as usize) < (b as usize);
}
export fn va_le(a: VAddr, b: VAddr) -> bool {
    return (a as usize) <= (b as usize);
}
export fn va_eq(a: VAddr, b: VAddr) -> bool {
    return (a as usize) == (b as usize);
}
