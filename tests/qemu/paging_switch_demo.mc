// Per-process address spaces: build two independent Sv39 page tables that map the
// SAME virtual address (3 GiB) to DIFFERENT physical frames holding different values.
// Switching satp between them changes what that virtual address resolves to — the
// essence of per-process virtual memory. Each space identity-maps devices + the
// kernel (gigapages) so the kernel keeps running across the switch.

import "kernel/arch/riscv64/paging.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const GIB: usize = 0x4000_0000;
const SATP_SV39: u64 = 0x8000_0000_0000_0000;
const TEST_VA: usize = 0xC000_0000;

global g_satp1: u64;
global g_satp2: u64;

// Build one address space whose TEST_VA holds `test_value`; return its satp.
fn build_space(heap: *mut Heap, test_value: u32) -> u64 {
    var pt: PageTable = page_table_new(heap);
    let rwx: u64 = PTE_R | PTE_W | PTE_X;
    page_table_map_gigapage(&pt, va(0), pa(0), rwx);
    page_table_map_gigapage(&pt, va(2 * GIB), pa(2 * GIB), rwx);
    let tf: PAddr = heap_alloc(heap, 4096, 4096);
    unsafe {
        raw.store<u32>(tf, test_value);
    }
    page_table_map(&pt, heap, va(TEST_VA), tf, PTE_R | PTE_W);
    let root: PAddr = page_table_root(&pt);
    return SATP_SV39 | ((pa_value(root) >> 12) as u64);
}

export fn build_spaces(region_base: usize, region_len: usize) -> void {
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
    g_satp1 = build_space(&heap, 0x1111_1111);
    g_satp2 = build_space(&heap, 0x2222_2222);
}

export fn satp1() -> u64 {
    return g_satp1;
}
export fn satp2() -> u64 {
    return g_satp2;
}
