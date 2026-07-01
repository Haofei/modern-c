// user/libc/alloc — the C-ABI heap allocator (malloc/free/realloc/calloc), in MC.
//
// This REUSES kernel/core/heap.mc — the project's proven, bounds-checked first-fit free-list
// with coalescing — rather than hand-rolling an allocator in unsafe C. The arena is a static
// byte region in the app's .bss (mapped + zeroed by the loader); heap_new builds the free-list
// over it on first use.
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
// ABI-identical to `void*`: alloc.mc and the engine are separate translation units, so the
// `void*` prototype in <stdlib.h> and this `uint8_t*` definition never meet to conflict.

import "kernel/core/heap.mc";
import "std/addr.mc";
import "std/mem.mc";
import "user/libc/lcommon.mc";

// Arena size. Lives in .bss, so the cost is page-table coverage, not file size. QuickJS runtime
// init + evaluation needs several MiB; the WASM path needs more — the wasm3 engine allocates its
// per-function M3 code pages AND the guest's linear memory from this heap, and QuickJS-on-wasm
// (the Phase-4 keystone, docs/wasm-migration-plan.md §4 "Javy double-layering cost") stacks a JS
// heap inside that linear memory on top. 14 MiB is the most that fits the confined agent: it sits
// just under the elf_loader's 16 MiB-per-segment cap (with the 512 KiB stack) and within the
// confined runtime's 16 MiB frame region. NOBITS .bss (no file cost); QEMU runs with -m 256.
const ARENA_BYTES: usize = 14680064; // 14 MiB

// 16-byte header in front of every user block: keeps the user pointer 16-aligned and stores
// the total (header + payload) block size so free() can return it to the free-list.
const HEADER: usize = 16;

global g_arena: [ARENA_BYTES]u8;
global g_heap: Heap;
global g_inited: u8;

// Build the free-list over the arena on first allocation (the arena is zeroed by the loader).
fn ensure_init() -> void {
    if g_inited == 0 {
        g_heap = heap_new(phys_range(pa((&g_arena[0]) as usize), ARENA_BYTES));
        g_inited = 1;
    }
}

// ---- demand growth past the fixed arena (SYS_SBRK) ----
//
// When the arena is exhausted, allocations spill into a SECOND heap backed by frames the kernel maps
// ON DEMAND at HEAP_BASE (through the __sbrk seam). Keeping the two heaps separate leaves the arena
// path byte-for-byte unchanged for the common case (an agent that stays within the arena never sbrk's
// and never touches this code), while letting a hungry agent — e.g. a WASM engine growing its linear
// memory — grow into real RAM instead of a compile-time .bss array. free()/realloc route by address:
// anything at or above HEAP_BASE lives in the grown heap. __sbrk is a WEAK default here that reports
// "growth unavailable" (returns the -1 sentinel); user/libc/syscall_user.mc overrides it with the real
// ecall, so ONLY a confined agent that can ecall actually grows — plain host-side libc users keep the
// fixed arena and identical behaviour.
const SBRK_FAIL: usize = 0xFFFF_FFFF_FFFF_FFFF;
const GROW_CHUNK: usize = 4194304;            // 4 MiB per SYS_SBRK, amortizing the syscall over small mallocs
const GROW_PAGE: usize = 4096;

global g_grown: Heap;
global g_grown_inited: u8;

// Demand growth is OPT-IN. Default OFF: an agent (and every host-side libc user) keeps the fixed 14
// MiB arena and prior behaviour byte-for-byte — malloc returns NULL at arena exhaustion, exactly as
// before. An agent that wants to grow into real RAM calls mc_heap_grow_enable() once at start. This
// keeps the WASM host's linear-memory bound unchanged for now: correct large-scale WASM memory.grow
// (WAMR reallocs the whole linear buffer, an O(n^2) copy pattern) is a separate, later step — until
// then only agents that explicitly opt in grow.
global g_grow_enabled: u8;

export fn mc_heap_grow_enable() -> void {
    g_grow_enabled = 1;
}

// Weak default: no syscall shim linked -> the heap is the fixed arena only (growth unavailable).
#[weak]
export fn __sbrk(delta: usize) -> usize {
    return SBRK_FAIL;
}

// Does `user` point inside the static arena's payload region? Used to route free()/realloc() to the
// right heap without assuming any absolute address layout (the arena may sit above OR below the grown
// heap depending on M-mode/host vs confined-U-mode link). g_arena is a real object, so base + len
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

// Is `sbrk`'s return an error (a negative errno, or the -1 unavailable sentinel)? Valid break VAs are
// small positive addresses (the HEAP_BASE region), so the sign bit distinguishes cleanly.
fn sbrk_failed(r: usize) -> bool {
    return r >= 0x8000_0000_0000_0000;
}

// Lazily build the grown heap rooted at the current break. Returns false if growth is unavailable
// (weak __sbrk) — callers then simply fail the allocation (NULL), exactly as the fixed arena did.
fn grown_ensure_init() -> bool {
    if g_grown_inited == 0 {
        let base: usize = __sbrk(0); // query the current break without growing
        if sbrk_failed(base) {
            return false;
        }
        g_grown = heap_new(phys_range(pa(base), 0)); // empty; extended as we sbrk
        g_grown_inited = 1;
    }
    return true;
}

// Grow the grown heap by at least `min_bytes` (rounded up to GROW_CHUNK + a page of slack, page-aligned)
// via SYS_SBRK, then extend the heap over the freshly-mapped, contiguous tail. Returns false on failure.
fn grown_grow(min_bytes: usize) -> bool {
    let usize_max: usize = 0xFFFF_FFFF_FFFF_FFFF;
    // headroom for the block header + heap alignment slack so a request of exactly `min_bytes` fits.
    if min_bytes > usize_max - GROW_PAGE {
        return false;
    }
    var want: usize = min_bytes + GROW_PAGE;
    if want < GROW_CHUNK {
        want = GROW_CHUNK;
    }
    if want > usize_max - (GROW_PAGE - 1) {
        return false;
    }
    want = ((want + (GROW_PAGE - 1)) / GROW_PAGE) * GROW_PAGE; // whole pages
    let old: usize = __sbrk(want);
    if sbrk_failed(old) {
        return false;
    }
    // The kernel mapped [old, old+want) R|W|U and contiguously with the grown heap's current end.
    heap_extend(&g_grown, want);
    return true;
}

// Extend the grown heap's backing range (via SYS_SBRK) until its end reaches at least `target_end`.
// Returns true once the range covers target_end. Used by realloc's in-place grow path so a topmost
// linear-memory buffer can be enlarged without copying.
fn grow_grown_to(target_end: usize) -> bool {
    if !grown_ensure_init() {
        return false;
    }
    var guard: u32 = 0;
    while pa_value(heap_range_end(&g_grown)) < target_end {
        let cur_end: usize = pa_value(heap_range_end(&g_grown));
        let deficit: usize = target_end - cur_end; // target_end > cur_end by the loop condition
        if !grown_grow(deficit) {
            return false; // sbrk/cap reached
        }
        guard = guard + 1;
        if guard > 4096 {
            return false; // defensive: never spin
        }
    }
    return true;
}

// Try to satisfy `total` bytes from the grown heap, growing it once if needed. 0 == failure.
fn grown_alloc(total: usize) -> usize {
    if !grown_ensure_init() {
        return 0;
    }
    switch heap_try_alloc(&g_grown, total, HEADER) {
        ok(b) => {
            unsafe { raw.store<usize>(b, total); }
            return pa_value(pa_offset(b, HEADER));
        }
        err(e) => {}
    }
    if !grown_grow(total) {
        return 0;
    }
    switch heap_try_alloc(&g_grown, total, HEADER) {
        ok(b) => {
            unsafe { raw.store<usize>(b, total); }
            return pa_value(pa_offset(b, HEADER));
        }
        err(e) => { return 0; }
    }
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
    // pass the check yet trap inside heap_alloc. That trap is reachable from untrusted guest code
    // (e.g. a WASM engine's allocations) and surfaces as an illegal-instruction crash. Route through
    // the FALLIBLE `heap_try_alloc` and fail closed (return NULL) on any error instead.
    var block: PAddr = uninit;
    switch heap_try_alloc(&g_heap, total, HEADER) {
        ok(b) => { block = b; }
        err(e) => {
            // Arena exhausted. If the agent opted into demand growth, spill into the sbrk-backed
            // grown heap (returns 0/NULL if growth is unavailable or the per-agent cap is reached —
            // never a trap). Otherwise fail exactly as the fixed arena always did.
            if g_grow_enabled == 0 {
                return 0;
            }
            return grown_alloc(total);
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
    // Route by the arena's ACTUAL range, not a fixed VA: a block that falls inside the static arena
    // came from g_heap; anything else was carved from the demand-grown heap. (Routing by a fixed
    // HEAP_BASE is wrong — in M-mode/host builds the .bss arena itself sits above HEAP_BASE, so an
    // arena block would misroute into the uninitialized grown heap and trap. The arena-range test is
    // correct in both the confined agent and the flat host layout.)
    if in_arena(user) {
        heap_free(&g_heap, block, total);
    } else {
        heap_free(&g_grown, block, total);
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
    // without moving a byte. This is what makes a repeatedly-grown buffer (a WASM engine enlarging its
    // linear memory through realloc) O(n) instead of O(n^2). Falls through to allocate-copy-free when
    // the block isn't at the frontier.
    if in_arena(old) {
        if heap_try_grow_in_place(&g_heap, block, old_total, new_total) {
            unsafe { raw.store<usize>(block, new_total); }
            return old;
        }
    } else {
        if g_grown_inited != 0 {
            // Try directly; if the block is topmost but the grown range is too short, SYS_SBRK more
            // contiguous frames (grown_grow extends the range) and retry, then extend in place.
            if heap_try_grow_in_place(&g_grown, block, old_total, new_total) {
                unsafe { raw.store<usize>(block, new_total); }
                return old;
            }
            if heap_is_frontier_block(&g_grown, block, old_total) {
                if grow_grown_to(pa_value(pa_offset(block, new_total))) {
                    if heap_try_grow_in_place(&g_grown, block, old_total, new_total) {
                        unsafe { raw.store<usize>(block, new_total); }
                        return old;
                    }
                }
            }
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
