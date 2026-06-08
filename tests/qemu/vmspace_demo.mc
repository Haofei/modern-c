// Per-process address spaces tied to the process table: build a distinct Sv39 page
// table for each of three processes (each mapping the same VA, 3 GiB, to its own
// frame with a per-process value) and store each as that Process's satp. The runtime
// "context-switches" between processes by loading proc_satp(idx) — so each process
// sees its own value at the same virtual address.

import "kernel/arch/riscv64/paging.mc";
import "kernel/core/process.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const GIB: usize = 0x4000_0000;
const SATP_SV39: u64 = 0x8000_0000_0000_0000;
const TEST_VA: usize = 0xC000_0000;

global g_procs: ProcTable;

fn build_space(heap: *mut Heap, value: u32) -> u64 {
    var pt: PageTable = page_table_new(heap);
    let rwx: u64 = PTE_R | PTE_W | PTE_X;
    page_table_map_gigapage(&pt, va(0), pa(0), rwx);
    page_table_map_gigapage(&pt, va(2 * GIB), pa(2 * GIB), rwx);
    let tf: PAddr = heap_alloc(heap, 4096, 4096);
    unsafe {
        raw.store<u32>(tf, value);
    }
    page_table_map(&pt, heap, va(TEST_VA), tf, PTE_R | PTE_W);
    let root: PAddr = page_table_root(&pt);
    return SATP_SV39 | ((pa_value(root) >> 12) as u64);
}

export fn vmspace_setup(region_base: usize, region_len: usize) -> void {
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
    proc_table_init(&g_procs);
    proc_set_satp(&g_procs, 0, build_space(&heap, 0xAAAA_0000));
    proc_set_satp(&g_procs, 1, build_space(&heap, 0xBBBB_0001));
    proc_set_satp(&g_procs, 2, build_space(&heap, 0xCCCC_0002));
}

// The address space of process `idx` (what a context switch loads into satp).
export fn vmspace_satp(idx: usize) -> u64 {
    return proc_satp(&g_procs, idx);
}
