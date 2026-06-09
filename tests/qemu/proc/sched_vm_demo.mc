// The scheduler with per-process address spaces: two processes are spawned with
// their own Sv39 page tables (each mapping VA 3 GiB to its own frame, A->0xA, B->0xB)
// stored as each Process's satp. `proc_yield_vm` switches process *and* address space
// together, so each process, reading the same VA, sees its own frame — the scheduler
// driving per-process virtual memory.

import "kernel/arch/riscv64/paging.mc";
import "kernel/core/process.mc";
import "kernel/arch/riscv64/idle.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const GIB: usize = 0x4000_0000;
const SATP_SV39: u64 = 0x8000_0000_0000_0000;
const TEST_VA: usize = 0xC000_0000;
const STACK_SIZE: usize = 8192;

global g_procs: ProcTable;
global g_seen_a: u32;
global g_seen_b: u32;
global g_kernel_satp: u64;

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
    identity_map(&pt);
    let root: PAddr = page_table_root(&pt);
    return SATP_SV39 | ((pa_value(root) >> 12) as u64);
}

fn alloc_stack(h: *mut Heap) -> usize {
    let base: PAddr = heap_alloc(h, STACK_SIZE, 16);
    return pa_value(base) + STACK_SIZE;
}

// Each worker reads the shared test VA (resolved in *its* address space) and records
// what it saw, then yields to the next process.
fn worker_a() -> void {
    unsafe {
        g_seen_a = raw.load<u32>(phys(TEST_VA));
    }
    proc_yield_vm(&g_procs);
}
fn worker_b() -> void {
    unsafe {
        g_seen_b = raw.load<u32>(phys(TEST_VA));
    }
    proc_yield_vm(&g_procs);
}

export fn sched_vm_setup(region_base: usize, region_len: usize) -> void {
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
    g_kernel_satp = build_kernel_space(&heap);
    let satp_a: u64 = build_space(&heap, 0x0000_000A);
    let satp_b: u64 = build_space(&heap, 0x0000_000B);

    proc_table_init(&g_procs);
    install_idle(&g_procs); // wfi when nothing runnable
    proc_set_satp(&g_procs, 0, g_kernel_satp); // the bootstrap runs in the kernel map
    let pid_a: u32 = proc_spawn(&g_procs, alloc_stack(&heap), worker_a);
    let pid_b: u32 = proc_spawn(&g_procs, alloc_stack(&heap), worker_b);
    proc_set_satp(&g_procs, pid_a as usize, satp_a);
    proc_set_satp(&g_procs, pid_b as usize, satp_b);
}

export fn sched_vm_kernel_satp() -> u64 {
    return g_kernel_satp;
}

// Run the two processes (each in its own address space), then check each saw its own
// frame. Returns 1 on success.
export fn sched_vm_run() -> u32 {
    proc_yield_vm(&g_procs); // A runs, yields to B, B yields back here
    if g_seen_a == 0x0000_000A {
        if g_seen_b == 0x0000_000B {
            return 1;
        }
    }
    return 0;
}
