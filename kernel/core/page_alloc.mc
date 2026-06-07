// kernel/core/page_alloc — a typed page allocator. Two safety stories:
//   * `MemoryMap<Unvalidated> → Validated`: you can only build an allocator from
//     a region that has been validated (phantom typestate).
//   * `Page` is a linear `move` resource: a page must be freed exactly once, can
//     never be used after it is freed, and cannot be double-freed.
// Arch-neutral. v1 is a bump allocator (no per-page reclaim); the linear `Page`
// type is what the safety rests on, independent of the reclaim policy.

const PAGE_SIZE: usize = 4096;

// A region of physical memory, with a validation typestate.
struct Unvalidated {}
struct Validated {}
struct MemoryMap<State> {
    base: usize,
    size: usize,
}

// A single owned page frame (linear). Freed exactly once.
move struct Page {
    addr: usize,
}

// The allocator state: a bump pointer over a validated region.
struct PageAllocator {
    next: usize,
    end: usize,
}

export fn memory_map(base: usize, size: usize) -> MemoryMap<Unvalidated> {
    return .{ .base = base, .size = size };
}

// Validate the region (page-aligned base, nonzero size). Only a validated map can
// back an allocator.
export fn validate(m: MemoryMap<Unvalidated>) -> MemoryMap<Validated> {
    if (m.base % PAGE_SIZE) != 0 {
        unreachable; // region base must be page-aligned
    }
    if m.size < PAGE_SIZE {
        unreachable; // region too small
    }
    return .{ .base = m.base, .size = m.size };
}

export fn page_allocator_from(m: MemoryMap<Validated>) -> PageAllocator {
    return .{ .next = m.base, .end = m.base + m.size };
}

// Allocate one page. Traps when the region is exhausted (callers can gate on
// `pages_available`).
export fn page_alloc(a: *mut PageAllocator) -> Page {
    if a.next + PAGE_SIZE > a.end {
        unreachable; // out of memory
    }
    let addr: usize = a.next;
    a.next = a.next + PAGE_SIZE;
    return .{ .addr = addr };
}

// How many pages remain.
export fn pages_available(a: *mut PageAllocator) -> usize {
    return (a.end - a.next) / PAGE_SIZE;
}

// The physical address of a page (borrow).
export fn page_addr(p: *Page) -> usize {
    return p.addr;
}

// Free a page (consumes it). v1 bump allocator does not recycle the frame; the
// linear type still guarantees no use-after-free and no double-free.
export fn page_free(p: Page) -> void {
    drop(p);
}
