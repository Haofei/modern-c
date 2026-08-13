// user/libc/alloc — the C-ABI heap allocator (malloc/free/realloc/calloc), in MC.
//
// This REUSES tests/support/heap.mc — the project's bounds-checked first-fit free-list with
// coalescing — rather than hand-rolling an allocator in unsafe C. The arena is a fixed static
// byte region; heap_new builds the free-list over it on first use.
//
// The one impedance mismatch: C's `free(ptr)` carries no size, but `heap_free` needs one. So
// every allocation is widened by a 16-byte header that stores the total block size; the user
// pointer is returned 16 bytes in (which also keeps it 16-aligned). free/realloc recover the
// size from the header. A failed allocation yields address 0 (the C NULL).
//
// Structure (to stay inside MC's pointer-representation rules): ALL allocator logic operates on
// `usize` addresses — `*mut u8` pointers (which a failed malloc makes null, an invalid `*mut`
// representation) are only MINTED at the export return and CONSUMED from the incoming param, at
// the C-ABI boundary. The exported functions return `*mut u8` (C `uint8_t*`), which is
// ABI-identical to `void*`: alloc.mc and any C-ABI driver are separate translation units, so
// a C `void*` prototype and this `uint8_t*` definition never meet to conflict.

import "tests/support/heap.mc";
import "std/addr.mc";
import "std/mem.mc";
import "user/libc/lcommon.mc";

// Arena size. This allocator is retained as C-ABI validation for MC lowering and
// heap reuse, not as a general confined-app runtime heap. Keep the footprint
// small and explicit; larger integration workloads should bring their own arena.
const ARENA_BYTES: usize = 1048576; // 1 MiB

// 16-byte header in front of every user block: keeps the user pointer 16-aligned and stores
// the total (header + payload) block size so free() can return it to the free-list.
const HEADER: usize = 16;

global g_arena: [ARENA_BYTES]u8;
global g_heap: Heap;
global g_inited: u8;

// Build the free-list over the arena on first allocation (the arena is zeroed by the loader).
fn ensure_init() -> void {
    if g_inited == 0 {
        heap_init_untracked(&g_heap, phys_range(pa((&g_arena[0]) as usize), ARENA_BYTES));
        g_inited = 1;
    }
}

// Does `user` point inside the static arena's payload region? Used to route free()/realloc() to the
// arena heap without assuming any absolute address layout. g_arena is a real object, so base + len
// cannot overflow the address space.
fn in_arena(user: usize) -> bool {
    let base: usize = (&g_arena[0]) as usize;
    if user < base {
        return false;
    }
    if user >= base + ARENA_BYTES {
        return false;
    }
    return true;
}

// ---- internal allocator, entirely in usize addresses (0 == failure / NULL) ----

fn malloc_addr(size: usize) -> usize {
    ensure_init();
    if size == 0 {
        return 0;
    }
    let total: usize = size + HEADER;
    // C malloc must return NULL on failure, NEVER trap. `heap_alloc` is the INFALLIBLE allocator —
    // it traps (unreachable) on exhaustion / no-fit, and a plain `heap_available >= total` pre-check
    // does not match its real requirement (alignment slack), so a near-full or fragmented heap could
    // pass the check yet trap inside heap_alloc. That trap is reachable from guest allocation
    // requests and surfaces as an illegal-instruction crash. Route through the FALLIBLE
    // `heap_try_alloc` and fail closed (return NULL) on any error instead.
    var block: PAddr = uninit;
    switch heap_try_alloc(&g_heap, total, HEADER) {
        ok(b) => { block = b; }
        err(e) => {
            return 0;
        }
    }
    unsafe {
        raw.store<usize>(block, total); // header: total block size
    }
    return pa_value(pa_offset(block, HEADER));
}

fn free_addr(user: usize) -> void {
    if user == 0 {
        return;
    }
    let block: PAddr = pa(user - HEADER);
    var total: usize = 0;
    unsafe {
        total = raw.load<usize>(block);
    }
    if in_arena(user) {
        heap_free(&g_heap, block, total);
    }
}

fn realloc_addr(old: usize, size: usize) -> usize {
    if old == 0 {
        return malloc_addr(size);
    }
    if size == 0 {
        free_addr(old);
        return 0;
    }
    let block: PAddr = pa(old - HEADER);
    var old_total: usize = 0;
    unsafe {
        old_total = raw.load<usize>(block);
    }
    let old_payload: usize = old_total - HEADER;
    // Shrink or same size: keep the existing block (no split — simple and never copies).
    if size <= old_payload {
        return old;
    }
    let new_total: usize = size + HEADER;

    // GROW-IN-PLACE fast path: if this block is the topmost frontier block of its heap, extend it
    // without moving a byte. This keeps repeatedly-grown buffers O(n) instead of O(n^2). Falls
    // through to allocate-copy-free when the block isn't at the frontier.
    if in_arena(old) {
        if heap_try_grow_in_place(&g_heap, block, old_total, new_total) {
            unsafe { raw.store<usize>(block, new_total); }
            return old;
        }
    }

    // Fallback: allocate a fresh block, copy the payload, free the old one.
    let new_addr: usize = malloc_addr(size);
    if new_addr == 0 {
        return 0; // old block left intact on failure
    }
    mem_copy(pa(new_addr), pa(old), old_payload); // size > old_payload here, so copy the whole payload
    free_addr(old);
    return new_addr;
}

// ---- C-ABI boundary: mint/consume `*mut u8` (== void*) only here (via lcommon) ----

export fn malloc(size: usize) -> *mut u8 {
    return lc_as_ptr(malloc_addr(size));
}

// `free` is an MC built-in (linear-value drop), so the function is named `mc_free` and the
// emitted object symbol is renamed to `free` for the C ABI.
#[backend_name("free")]
export fn mc_free(p: *mut u8) -> void {
    free_addr(lc_ptr_addr(p));
}

export fn calloc(count: usize, size: usize) -> *mut u8 {
    // C calloc returns NULL on size overflow; MC's `*` would trap. Guard it (reachable from
    // untrusted JS, e.g. a huge typed-array length): if count*size would overflow, fail closed.
    if size != 0 {
        let max: usize = 0xFFFF_FFFF_FFFF_FFFF;
        if count > max / size {
            return lc_as_ptr(0); // NULL
        }
    }
    let total: usize = count * size; // guarded above: cannot overflow
    let addr: usize = malloc_addr(total);
    if addr != 0 {
        mem_set(pa(addr), 0, total);
    }
    return lc_as_ptr(addr);
}

export fn realloc(p: *mut u8, size: usize) -> *mut u8 {
    return lc_as_ptr(realloc_addr(lc_ptr_addr(p), size));
}
