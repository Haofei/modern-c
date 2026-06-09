// Per-process address spaces switched *by the context switch*. Builds two thread
// address spaces (each mapping VA 3 GiB to its own frame: A->0xA, B->0xB) plus a
// kernel space (identity only). The runtime's context switch loads the target
// thread's satp as it swaps registers, so each thread, reading the same VA, sees its
// own value — proving the address space is part of the switched context.

import "kernel/arch/riscv64/paging.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const GIB: usize = 0x4000_0000;
const SATP_SV39: u64 = 0x8000_0000_0000_0000;
const TEST_VA: usize = 0xC000_0000;

global g_satp_a: u64;
global g_satp_b: u64;
global g_satp_kernel: u64;

fn identity_map(pt: *mut PageTable) -> void {
    let rwx: u64 = PTE_R | PTE_W | PTE_X;
    page_table_map_gigapage(pt, va(0), pa(0), rwx);
    page_table_map_gigapage(pt, va(2 * GIB), pa(2 * GIB), rwx);
}

fn build_space(heap: *mut Heap, value: u32) -> u64 {
    var pt: PageTable = page_table_new(heap);
    identity_map(&pt);
    let tf: PAddr = heap_alloc(heap, 4096, 4096);
    unsafe {
        raw.store<u32>(tf, value);
    }
    page_table_map(&pt, heap, va(TEST_VA), tf, PTE_R | PTE_W);
    let root: PAddr = page_table_root(&pt);
    return SATP_SV39 | ((pa_value(root) >> 12) as u64);
}

fn build_kernel_space(heap: *mut Heap) -> u64 {
    var pt: PageTable = page_table_new(heap);
    identity_map(&pt); // no TEST_VA mapping
    let root: PAddr = page_table_root(&pt);
    return SATP_SV39 | ((pa_value(root) >> 12) as u64);
}

export fn vmctx_setup(region_base: usize, region_len: usize) -> void {
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
    g_satp_kernel = build_kernel_space(&heap);
    g_satp_a = build_space(&heap, 0x0000_000A);
    g_satp_b = build_space(&heap, 0x0000_000B);
}

export fn vmctx_satp_a() -> u64 {
    return g_satp_a;
}
export fn vmctx_satp_b() -> u64 {
    return g_satp_b;
}
export fn vmctx_satp_kernel() -> u64 {
    return g_satp_kernel;
}
