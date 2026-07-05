// kernel/core/page_alloc — a physical frame allocator. Safety stories:
//   * `MemoryMap<Unvalidated> → Validated`: you can only build an allocator from
//     a region that has been validated (phantom typestate).
//   * `Page` is a linear `move` resource: a page must be freed exactly once, can
//     never be used after it is freed, and cannot be double-freed.
//   * addresses are typed `PAddr` with checked arithmetic (std/addr) — no raw
//     `usize` pointer math, no hand-rolled overflow checks.
// Allocation pulls from an intrusive LIFO free list first (O(1) alloc + free with
// real reclaim), then bumps the unused frontier. Arch-neutral.

import "std/addr.mc";
import "std/mem.mc";

const PAGE_SIZE: usize = 4096;

// A region of physical memory, with a validation typestate.
struct Unvalidated {}
struct Validated {}
struct MemoryMap<State> {
    range: PhysRange,
}

// A single owned page frame (linear). Freed exactly once.
move struct Page {
    addr: PAddr,
}

// The allocator: a bump frontier plus an intrusive free list. A freed frame stores
// the previous free-list head in its first word, so reclaim needs no side table.
struct PageAllocator {
    next: PAddr,       // bump frontier
    end: PAddr,        // one past the region
    free_head: usize,  // raw addr of the first free frame, 0 = list empty
    free_count: usize, // frames currently on the free list
}

// Describe a region from raw platform values. `phys_range` traps if base+size
// overflows the address space; alignment/size policy is checked by `validate`.
pub fn memory_map(base: usize, size: usize) -> MemoryMap<Unvalidated> {
    return .{ .range = phys_range(pa(base), size) };
}

// Validate the region: page-aligned base and size, at least one page. A bad map is
// a platform/config error (the bring-up code supplies it), so this traps.
pub fn validate(m: MemoryMap<Unvalidated>) -> MemoryMap<Validated> {
    if !pa_is_aligned(pr_start(&m.range), PAGE_SIZE) {
        unreachable; // base must be page-aligned
    }
    let len: usize = pr_len(&m.range);
    if !is_aligned(len, PAGE_SIZE) {
        unreachable; // size must be a whole number of pages
    }
    if len < PAGE_SIZE {
        unreachable; // region too small
    }
    return .{ .range = m.range };
}

pub fn page_allocator_from(m: MemoryMap<Validated>) -> PageAllocator {
    return .{ .next = pr_start(&m.range), .end = pr_end(&m.range), .free_head = 0, .free_count = 0 };
}

// Allocate one page: reuse a freed frame if any, otherwise bump. Traps only when
// the region is genuinely exhausted (callers gate on `pages_available`).
pub fn page_alloc(a: *mut PageAllocator) -> Page {
    if a.free_count != 0 {
        let frame: PAddr = pa(a.free_head);
        unsafe {
            a.free_head = raw.load<usize>(frame); // pop: next link becomes the head
        }
        a.free_count = a.free_count - 1;
        return .{ .addr = frame };
    }
    if pa_diff(a.next, a.end) < PAGE_SIZE {
        unreachable; // out of memory
    }
    let frame: PAddr = a.next;
    a.next = pa_offset(a.next, PAGE_SIZE);
    return .{ .addr = frame };
}

// Free a page (consumes the linear handle) and return its frame to the free list.
pub fn page_free(a: *mut PageAllocator, p: Page) -> void {
    let frame: PAddr = p.addr; // borrow before consuming
    unsafe { forget_unchecked(p); }
    unsafe {
        raw.store<usize>(frame, a.free_head); // push: store old head in this frame
    }
    a.free_head = pa_value(frame);
    a.free_count = a.free_count + 1;
}

// How many pages remain (bump frontier + reclaimed free list).
export fn pages_available(a: *mut PageAllocator) -> usize {
    return (pa_diff(a.next, a.end) / PAGE_SIZE) + a.free_count;
}

// The physical address of a page (borrow) — a typed `PAddr`, not a raw `usize`.
export fn page_addr(p: *Page) -> PAddr {
    return p.addr;
}
