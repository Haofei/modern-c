// kernel/core/demand — demand paging. The kernel maps its own region + devices but
// leaves a region unmapped; the first access to it faults, the S-mode page-fault
// handler calls `dp_handle_fault`, which allocates a frame and maps it at the faulting
// page — and the faulting instruction is retried transparently. Lazy, fault-driven
// virtual memory (vs the eager identity mapping).

import "kernel/arch/riscv64/paging.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const GIB: usize = 0x4000_0000;
const SATP_SV39: u64 = 0x8000_0000_0000_0000;

global g_heap: Heap;
global g_pt: PageTable;

// Build the address space: identity-map devices + kernel, leave the demand region
// unmapped. Returns the satp value to activate.
export fn dp_setup(region_base: usize, region_len: usize) -> u64 {
    g_heap = heap_new(phys_range(pa(region_base), region_len));
    g_pt = page_table_new(&g_heap);
    let rwx: u64 = PTE_R | PTE_W | PTE_X;
    page_table_map_gigapage(&g_pt, va(0), pa(0), rwx);             // devices
    page_table_map_gigapage(&g_pt, va(2 * GIB), pa(2 * GIB), rwx); // kernel + heap
    // the demand region (>= 3 GiB) is intentionally left unmapped
    let root: PAddr = page_table_root(&g_pt);
    return SATP_SV39 | ((pa_value(root) >> 12) as u64);
}

// Page-fault handler: map a fresh page at the faulting (page-aligned) address.
export fn dp_handle_fault(fault_va: usize) -> void {
    let aligned: usize = fault_va - (fault_va % 4096);
    let frame: PAddr = heap_alloc(&g_heap, 4096, 4096);
    page_table_map(&g_pt, &g_heap, va(aligned), frame, PTE_R | PTE_W);
}
