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

// ---- internal allocator, entirely in usize addresses (0 == failure / NULL) ----

fn malloc_addr(size: usize) -> usize {
    ensure_init();
    if size == 0 {
        return 0;
    }
    let total: usize = size + HEADER;
    if heap_available(&g_heap) < total {
        return 0; // fail closed rather than trapping
    }
    let block: PAddr = heap_alloc(&g_heap, total, HEADER);
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
    heap_free(&g_heap, block, total);
}

fn realloc_addr(old: usize, size: usize) -> usize {
    if old == 0 {
        return malloc_addr(size);
    }
    if size == 0 {
        free_addr(old);
        return 0;
    }
    var old_total: usize = 0;
    unsafe {
        old_total = raw.load<usize>(pa(old - HEADER));
    }
    let old_payload: usize = old_total - HEADER;
    let new_addr: usize = malloc_addr(size);
    if new_addr == 0 {
        return 0; // old block left intact on failure
    }
    var copy: usize = old_payload;
    if size < old_payload {
        copy = size;
    }
    mem_copy(pa(new_addr), pa(old), copy);
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
