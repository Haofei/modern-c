// Load a REAL multi-segment app ELF (built by tools/user/build-app.sh from an MC `main`)
// into an ISOLATED Sv39 space via elf_load_image, register the userspace syscall ABI, and
// return the satp to activate. The C runtime (app_runtime.c) sets satp + enter_user; SYS_EXIT
// is handled by the shared M-mode trap (usermode_runtime.c). The kernel is NOT mapped in the
// agent's address space — that omission is the confinement; the agent reaches the kernel only
// through `ecall`, and SYS_WRITE's user buffer is copied in through the agent's page table
// (copy_from_user_pt), never dereferenced raw.

import "kernel/core/elf_loader.mc";
import "kernel/arch/riscv64/paging.mc";
import "kernel/core/heap.mc";
import "kernel/core/syscall.mc";
import "kernel/core/uaccess.mc";
import "kernel/core/console.mc";
import "std/addr.mc";

const SATP_SV39: u64 = 0x8000_0000_0000_0000;
const SYS_WRITE: usize = 0;
const SYS_GETPID: usize = 2;
// Async I/O (Phase 7): SYS_SUBMIT queues a non-blocking op and returns a request id; SYS_POLL
// drains one completion ((id, result) written to a user buffer). The agent's event loop submits,
// keeps running, and resolves the matching JS Promise when the completion arrives.
const SYS_SUBMIT: usize = 4;
const SYS_POLL: usize = 5;
const COMP_CAP: usize = 8;
const USER_BASE: usize = 0x10000;
// Upper bound for uaccess validation. Must cover the agent's whole VA span — for the QuickJS
// agent that includes the multi-MiB heap arena + stack high in .bss, so a small app's 1 MiB is
// far too low (SYS_WRITE buffers live above it). 16 MiB covers the confined-agent images.
const USER_LIMIT: usize = 0x0100_0000;
const KBUF: usize = 256;
const AGENT_PID: u64 = 7;

global g_heap: Heap;
global g_pt: PageTable;
global g_uas: UserAddrSpace;
global g_syscalls: SyscallTable;
global g_kbuf: [KBUF]u8;
global g_entry: u64;

// Completion queue (FIFO) for the async-I/O syscalls + a 16-byte staging buffer for SYS_POLL.
global g_comp_id: [COMP_CAP]u64;
global g_comp_val: [COMP_CAP]u64;
global g_comp_count: usize;
global g_next_req: u64;
global g_pollbuf: [16]u8;

// Forge a UserPtr<u8> from a user-supplied integer address (the uaccess idiom): re-tagging
// an int into the UserPtr class needs `unsafe`; copy_from_user_pt still validates it per-page.
fn uptr(a: usize) -> UserPtr<u8> {
    var p: UserPtr<u8> = uninit;
    unsafe {
        p = a as UserPtr<u8>;
    }
    return p;
}

// SYS_WRITE(fd, buf, len): copy the user buffer in through the agent's page table, then emit
// it to the console. Capped at the kernel staging buffer. Returns bytes written (0 on a bad
// user pointer — copy_from_user_pt fails closed, writing nothing).
fn sys_write(fd: u64, buf: u64, len: u64) -> u64 {
    var n: usize = len as usize;
    if n > KBUF {
        n = KBUF;
    }
    let dst: PAddr = pa((&g_kbuf[0]) as usize);
    switch copy_from_user_pt(&g_uas, dst, uptr(buf as usize), n) {
        ok(v) => {}
        err(e) => { return 0; }
    }
    var i: usize = 0;
    while i < n {
        console_putc(g_kbuf[i]);
        i = i + 1;
    }
    return n as u64;
}

fn sys_getpid(a: u64, b: u64, c: u64) -> u64 {
    return AGENT_PID;
}

// SYS_SUBMIT(op, arg): start a non-blocking op. Here the op is a toy compute (`arg + 2`) whose
// completion is enqueued immediately; a real op would complete later off an IRQ/DMA event onto
// the same queue. Returns the request id so the agent can match the completion to its Promise.
fn sys_submit(op: u64, arg: u64, c: u64) -> u64 {
    let id: u64 = g_next_req;
    g_next_req = g_next_req + 1;
    if g_comp_count < COMP_CAP {
        g_comp_id[g_comp_count] = id;
        g_comp_val[g_comp_count] = arg + 2; // the op's result
        g_comp_count = g_comp_count + 1;
    }
    return id;
}

// SYS_POLL(buf): drain ONE completion into the user buffer as two u64s [id, result]. Returns 1
// if a completion was delivered, 0 if the queue is empty (the agent's loop then knows to stop
// once nothing is in flight). The buffer is written through the agent's page table (copy_to_user).
fn sys_poll(buf: u64, b: u64, c: u64) -> u64 {
    if g_comp_count == 0 {
        return 0;
    }
    let id: u64 = g_comp_id[0];
    let val: u64 = g_comp_val[0];
    // FIFO shift-down
    var i: usize = 1;
    while i < g_comp_count {
        g_comp_id[i - 1] = g_comp_id[i];
        g_comp_val[i - 1] = g_comp_val[i];
        i = i + 1;
    }
    g_comp_count = g_comp_count - 1;
    // stage [id, result] and copy out through the agent's page table
    let base: PAddr = pa((&g_pollbuf[0]) as usize);
    unsafe {
        raw.store<u64>(base, id);
        raw.store<u64>(pa_offset(base, 8), val);
    }
    switch copy_to_user_pt(&g_uas, uptr(buf as usize), base, 16) {
        ok(v) => {}
        err(e) => { return 0; }
    }
    return 1;
}

// Register the userspace ABI handlers. Called by usermode_setup() (the shared C trap
// bring-up) before the app runs; the handlers reference g_uas, which app_build sets before
// any ecall can occur.
export fn syscall_setup() -> void {
    syscall_init(&g_syscalls);
    syscall_register(&g_syscalls, SYS_WRITE, sys_write);
    syscall_register(&g_syscalls, SYS_GETPID, sys_getpid);
    syscall_register(&g_syscalls, SYS_SUBMIT, sys_submit);
    syscall_register(&g_syscalls, SYS_POLL, sys_poll);
}

// Called by the C trap for each ecall (number a7, args a0..a2). SYS_EXIT is handled by the
// trap before this; everything else dispatches through the registered table.
export fn mc_syscall(number: u64, arg0: u64, arg1: u64, arg2: u64) -> u64 {
    return syscall_dispatch(&g_syscalls, number, arg0, arg1, arg2);
}

// Build the agent's isolated address space from the app image, register the ABI, return the
// satp to activate. Returns 0 on a malformed/hostile image.
export fn app_build(image_base: usize, image_len: usize, region_base: usize, region_len: usize) -> u64 {
    g_heap = heap_new(phys_range(pa(region_base), region_len));
    g_pt = page_table_new(&g_heap);

    switch elf_load_image(image_base, image_len, &g_pt, &g_heap) {
        ok(e) => { g_entry = e; }
        err(e) => { return 0; }
    }

    g_uas = user_addr_space(&g_pt, USER_BASE, USER_LIMIT);

    let root: PAddr = page_table_root(&g_pt);
    return SATP_SV39 | ((pa_value(root) >> 12) as u64);
}

export fn app_entry() -> u64 {
    return g_entry;
}

// Confinement proof: the kernel VA is NOT mapped in the agent's address space.
export fn app_kernel_unmapped(kernel_va: usize) -> u32 {
    if page_table_is_mapped(&g_pt, va(kernel_va)) {
        return 0;
    }
    return 1;
}
