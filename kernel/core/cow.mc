// kernel/core/cow — copy-on-write, the core mechanism of fork+COW, shown on a single shared
// page (a demonstration of the per-page mechanism, not yet a general COW subsystem: there are
// no per-frame share counts or COW PTE bits, just one read-only shared frame and one writable
// copy on the first write). Two address spaces (a "parent" and a forked "child") share a frame
// mapped READ-ONLY at the same VA. A write faults; the COW handler allocates a private copy,
// copies the bytes, and remaps it writable in the faulting space — so the writer diverges
// while the other still sees the original.

import "kernel/arch/riscv64/paging.mc";
import "kernel/core/heap.mc";
import "std/mem.mc";
import "std/addr.mc";

const GIB: usize = 0x4000_0000;
const SATP_SV39: u64 = 0x8000_0000_0000_0000;
const COW_VA: usize = 0xE000_0000;
const PAGE: usize = 4096;

global g_heap: Heap;
global g_pt_parent: PageTable;
global g_pt_child: PageTable;
global g_shared: PAddr;

fn id_map(pt: *mut PageTable) -> void {
    let rwx: u64 = PTE_R | PTE_W | PTE_X;
    page_table_map_gigapage(pt, va(0), pa(0), rwx);
    page_table_map_gigapage(pt, va(2 * GIB), pa(2 * GIB), rwx);
}

fn satp_of(pt: *PageTable) -> u64 {
    let root: PAddr = page_table_root(pt);
    return SATP_SV39 | ((pa_value(root) >> 12) as u64);
}

export fn cow_setup(region_base: usize, region_len: usize) -> void {
    g_heap = heap_new(phys_range(pa(region_base), region_len));
    g_pt_parent = page_table_new(&g_heap);
    id_map(&g_pt_parent);
    g_pt_child = page_table_new(&g_heap);
    id_map(&g_pt_child);
    g_shared = heap_alloc(&g_heap, PAGE, PAGE);
    unsafe {
        raw.store<u32>(g_shared, 0x1111_1111); // the shared initial contents
    }
    // both spaces map the VA to the same frame, READ-ONLY (write triggers COW)
    page_table_map(&g_pt_parent, &g_heap, va(COW_VA), g_shared, PTE_R);
    page_table_map(&g_pt_child, &g_heap, va(COW_VA), g_shared, PTE_R);
}

export fn cow_satp_parent() -> u64 {
    return satp_of(&g_pt_parent);
}
export fn cow_satp_child() -> u64 {
    return satp_of(&g_pt_child);
}

// COW fault (parent's space active): give the parent a private, writable copy. Only the one
// shared COW page is copy-on-write here; a write fault at any other address is a real fault,
// not a COW miss, so it fails closed rather than copying an unrelated page.
export fn cow_handle_fault(fault_va: usize) -> void {
    let aligned: usize = fault_va - (fault_va % PAGE);
    if aligned != COW_VA {
        unreachable; // write fault outside the COW page — fail closed, do not copy
    }
    let copy: PAddr = heap_alloc(&g_heap, PAGE, PAGE);
    mem_copy(copy, g_shared, PAGE);
    page_table_unmap(&g_pt_parent, va(aligned));
    page_table_map(&g_pt_parent, &g_heap, va(aligned), copy, PTE_R | PTE_W);
}
