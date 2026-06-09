// Build an Sv39 page table and return the satp value that activates it. The kernel
// identity-maps the device region [0,1GiB) and its own region [2GiB,3GiB) with two
// gigapages (so it keeps running with paging on), and adds a single 4 KiB mapping at
// 3 GiB — a virtual address reachable ONLY through translation — pointing at a frame
// holding a known value. The runtime then turns on satp and reads the test VA, so a
// correct read proves real virtual->physical translation.

import "kernel/arch/riscv64/paging.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const GIB: usize = 0x4000_0000;
const SATP_SV39: u64 = 0x8000_0000_0000_0000; // mode = 8 (Sv39) in bits 63:60
const TEST_VA: usize = 0xC000_0000;           // 3 GiB — not identity-mapped
const TEST_VALUE: u32 = 0xCAFE_BABE;

export fn paging_activate(region_base: usize, region_len: usize) -> u64 {
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
    var pt: PageTable = page_table_new(&heap);

    let rwx: u64 = PTE_R | PTE_W | PTE_X;
    // Identity-map devices (UART/CLINT/finisher) and the kernel itself.
    page_table_map_gigapage(&pt, va(0), pa(0), rwx);
    page_table_map_gigapage(&pt, va(2 * GIB), pa(2 * GIB), rwx);

    // A test frame with a known value, mapped at a non-identity virtual address.
    let tf: PAddr = heap_alloc(&heap, 4096, 4096);
    unsafe {
        raw.store<u32>(tf, TEST_VALUE);
    }
    page_table_map(&pt, &heap, va(TEST_VA), tf, PTE_R | PTE_W);

    let root: PAddr = page_table_root(&pt);
    return SATP_SV39 | ((pa_value(root) >> 12) as u64);
}
