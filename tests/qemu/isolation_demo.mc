// Per-server MMU isolation + cross-address-space IPC. Two processes each run in their
// OWN page table (a private frame mapped at the same VA: A->0xA, B->0xB), so neither can
// read the other's memory by address. They exchange data only through kernel-mediated
// IPC (the ProcTable mailbox is in the kernel region, mapped in every address space).
// B confirms its own private page is 0xB (isolation) yet receives A's 0xA via IPC.

import "kernel/arch/riscv64/paging.mc";
import "kernel/core/process.mc";
import "kernel/arch/riscv64/idle.mc";
import "kernel/core/ipc.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const GIB: usize = 0x4000_0000;
const SATP_SV39: u64 = 0x8000_0000_0000_0000;
const TEST_VA: usize = 0xC000_0000;
const STACK_SIZE: usize = 8192;
const B_PID: u32 = 2;

global g_procs: ProcTable;
global g_seen_a: u32;
global g_seen_b: u32;
global g_from_a: u32;
global g_kernel_satp: u64;

fn identity_map(pt: *mut PageTable) -> void {
    let rwx: u64 = PTE_R | PTE_W | PTE_X;
    page_table_map_gigapage(pt, va(0), pa(0), rwx);
    page_table_map_gigapage(pt, va(2 * GIB), pa(2 * GIB), rwx); // kernel region (ProcTable, code)
}

fn build_space(heap: *mut Heap, value: u32) -> u64 {
    var pt: PageTable = page_table_new(heap);
    identity_map(&pt);
    let tf: PAddr = heap_alloc(heap, 4096, 4096);
    unsafe {
        raw.store<u32>(tf, value);
    }
    page_table_map(&pt, heap, va(TEST_VA), tf, PTE_R | PTE_W); // private frame at the shared VA
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

fn worker_a() -> void {
    unsafe {
        g_seen_a = raw.load<u32>(phys(TEST_VA)); // A's private frame -> 0xA
    }
    ipc_send(&g_procs, B_PID, 1, g_seen_a as u64, 0, 0); // hand A's value to B via the kernel
    proc_yield_vm(&g_procs);
}
fn worker_b() -> void {
    unsafe {
        g_seen_b = raw.load<u32>(phys(TEST_VA)); // B's private frame -> 0xB (not A's!)
    }
    var m: Message = message_zero();
    ipc_receive(&g_procs, &m); // A's message, delivered through the kernel mailbox
    g_from_a = m.a0 as u32;
    proc_yield_vm(&g_procs);
}

export fn isolation_kernel_satp() -> u64 {
    return g_kernel_satp;
}

export fn isolation_setup(region_base: usize, region_len: usize) -> void {
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
    g_kernel_satp = build_kernel_space(&heap);
    let satp_a: u64 = build_space(&heap, 0x0000_000A);
    let satp_b: u64 = build_space(&heap, 0x0000_000B);
    proc_table_init(&g_procs);
    install_idle(&g_procs); // wfi when nothing runnable
    proc_set_satp(&g_procs, 0, g_kernel_satp);
    let pid_a: u32 = proc_spawn(&g_procs, alloc_stack(&heap), worker_a);
    let pid_b: u32 = proc_spawn(&g_procs, alloc_stack(&heap), worker_b);
    proc_set_satp(&g_procs, pid_a as usize, satp_a);
    proc_set_satp(&g_procs, pid_b as usize, satp_b);
}

// Returns 1 iff: A and B each saw their own private frame (isolation) AND B received
// A's value across the address-space boundary via IPC.
export fn isolation_run() -> u32 {
    proc_yield_vm(&g_procs);
    if g_seen_a != 0x0000_000A {
        return 0;
    }
    if g_seen_b != 0x0000_000B {
        return 0; // B must see ITS frame, not A's (isolation)
    }
    if g_from_a != 0x0000_000A {
        return 0; // B got A's value only via IPC
    }
    return 1;
}
