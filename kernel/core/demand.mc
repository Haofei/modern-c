// kernel/core/demand — demand paging (a single-region demonstration, not yet a general VM
// subsystem: there is one global address space and one allowed demand region, no per-process
// VMA table or page-level permission policy). The kernel maps its own region + devices but
// leaves the demand region unmapped; the first access to it faults, the S-mode page-fault
// handler calls `dp_handle_fault`, which — only for a fault inside that region — allocates a
// frame and maps it at the faulting page, and the faulting instruction is retried.

// RISC-V-specific: this demo uses Sv39 gigapage mapping (page_table_map_gigapage), the satp
// AddressSpace encoding (riscv_aspace_of), and active-AS map + sfence — none of which are in
// the arch-neutral paging interface. So it imports the RISC-V paging module directly rather
// than the kernel/arch/active seam.
import "kernel/arch/riscv64/paging.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const GIB: usize = 0x4000_0000;
const PAGE: usize = 4096;

global g_heap: Heap;
global g_pt: PageTable;
// The one region that may be filled on demand: [3 GiB, 4 GiB). A fault outside it is a real
// fault, not lazy paging — the stand-in for a per-process VMA table's region+permission check.
global g_demand_base: usize;
global g_demand_end: usize;

// Build the address space: identity-map devices + kernel, leave the demand region
// unmapped. Returns the satp value to activate.
export fn dp_setup(region_base: usize, region_len: usize) -> u64 {
    g_heap = heap_new(phys_range(pa(region_base), region_len));
    g_pt = page_table_new(&g_heap);
    let rwx: u64 = PTE_R | PTE_W | PTE_X;
    page_table_map_gigapage(&g_pt, va(0), pa(0), rwx);             // devices
    page_table_map_gigapage(&g_pt, va(2 * GIB), pa(2 * GIB), rwx); // kernel + heap
    // the demand region [3 GiB, 4 GiB) is intentionally left unmapped — filled on demand
    g_demand_base = 3 * GIB;
    g_demand_end = 4 * GIB;
    // dp_setup returns a raw satp word consumed by the C demand/contain runtimes, so it stays
    // a u64 at this C-FFI boundary: build the opaque AddressSpace via the arch helper, then
    // unwrap. The satp bit layout itself no longer appears in this architecture-independent file.
    return AddressSpace.raw(riscv_aspace_of(&g_pt));
}

// Page-fault handler: map a fresh page at the faulting page — but only if the fault falls in
// the allowed demand region. A fault anywhere else is not a lazy-paging fault (it is a wild
// access / a real protection fault), so it fails closed instead of silently materializing a
// page for any address. (A full VM would consult the faulting process's VMA list and the
// fault kind here; this single global region is the bounded stand-in.)
export fn dp_handle_fault(fault_va: usize) -> void {
    let aligned: usize = fault_va - (fault_va % PAGE);
    var in_region: bool = true;
    if aligned < g_demand_base {
        in_region = false;
    }
    if aligned >= g_demand_end {
        in_region = false;
    }
    if !in_region {
        unreachable; // fault outside the demand region — fail closed, do not map
    }
    let frame: PAddr = heap_alloc(&g_heap, PAGE, PAGE);
    // Editing the *active* address space: map then sfence.vma so the new translation is seen.
    page_table_map_active(&g_pt, &g_heap, va(aligned), frame, PTE_R | PTE_W);
}
