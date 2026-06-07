// kernel/core/page_alloc — a typed page allocator. Two safety stories:
//   * `MemoryMap<Unvalidated> → Validated`: you can only build an allocator from
//     a region that has been validated (phantom typestate).
//   * `Page` is a linear `move` resource: a page must be freed exactly once, can
//     never be used after it is freed, and cannot be double-freed.
// Arch-neutral. v1 is a bump allocator (no per-page reclaim); the linear `Page`
// type is what the safety rests on, independent of the reclaim policy.

import "std/mem.mc";

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

const USIZE_MAX: usize = 0xFFFF_FFFF_FFFF_FFFF;


// Validate the region: page-aligned base and size, at least one page, and
// `base + size` must not overflow the address space. Only a validated map can
// back an allocator. A bad map is a platform/config error (the bring-up code
// supplies it), so this traps rather than returning a recoverable error.
export fn validate(m: MemoryMap<Unvalidated>) -> MemoryMap<Validated> {
    if !is_aligned(m.base, PAGE_SIZE) {
        unreachable; // base must be page-aligned
    }
    if !is_aligned(m.size, PAGE_SIZE) {
        unreachable; // size must be a whole number of pages
    }
    if m.size < PAGE_SIZE {
        unreachable; // region too small
    }
    if m.base > USIZE_MAX - m.size {
        unreachable; // base + size would overflow the address space
    }
    return .{ .base = m.base, .size = m.size };
}

export fn page_allocator_from(m: MemoryMap<Validated>) -> PageAllocator {
    // `base + size` is overflow-checked in validate(), so `end` is exact.
    return .{ .next = m.base, .end = m.base + m.size };
}

// Allocate one page. Traps when the region is exhausted (callers gate on
// `pages_available`). NB: returning `Result<Page, _>` here would lose the linear
// tracking of `Page` — the move checker does not yet track a move value bound by
// a `switch`/`if let` pattern, so use-after-free of a destructured page goes
// undetected. Keeping the direct `Page` return preserves the linear guarantee;
// the recoverable-OOM `Result` is deferred to that move-checker improvement.
export fn page_alloc(a: *mut PageAllocator) -> Page {
    if a.next > a.end - PAGE_SIZE {
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
