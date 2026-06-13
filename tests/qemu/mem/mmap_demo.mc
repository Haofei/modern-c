// Build a page table, identity-map the kernel/devices, then mmap two *anonymous* pages
// at distinct VAs. The runtime activates satp and read/writes both VAs — proving the
// mapped pages are independent, demand-allocated RAM (not identity-mapped).

import "kernel/core/mmap.mc";
import "kernel/arch/riscv64/paging.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const GIB: usize = 0x4000_0000;
const SATP_SV39: u64 = 0x8000_0000_0000_0000;
const VA1: usize = 0xC000_0000; // 3 GiB
const VA2: usize = 0xC000_1000; // 3 GiB + 4 KiB

export fn mmap_demo(region_base: usize, region_len: usize) -> u64 {
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
    var pt: PageTable = page_table_new(&heap);
    let rwx: u64 = PTE_R | PTE_W | PTE_X;
    page_table_map_gigapage(&pt, va(0), pa(0), rwx);            // devices
    page_table_map_gigapage(&pt, va(2 * GIB), pa(2 * GIB), rwx); // kernel

    // Two distinct, previously-unmapped anonymous pages — both maps must succeed.
    switch mmap_anon(&pt, &heap, va(VA1), PTE_R | PTE_W) {
        ok(f) => {}
        err(e) => { return 0; } // 0 is an invalid satp: signals the mapping failed
    }
    switch mmap_anon(&pt, &heap, va(VA2), PTE_R | PTE_W) {
        ok(f) => {}
        err(e) => { return 0; }
    }

    let root: PAddr = page_table_root(&pt);
    return SATP_SV39 | ((pa_value(root) >> 12) as u64);
}
