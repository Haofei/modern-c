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
const USER_BASE: usize = 0x10000;
const USER_LIMIT: usize = 0x0010_0000; // covers the app's text/rodata/data/stack VAs
const KBUF: usize = 256;
const AGENT_PID: u64 = 7;

global g_heap: Heap;
global g_pt: PageTable;
global g_uas: UserAddrSpace;
global g_syscalls: SyscallTable;
global g_kbuf: [KBUF]u8;
global g_entry: u64;

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

// Register the userspace ABI handlers. Called by usermode_setup() (the shared C trap
// bring-up) before the app runs; the handlers reference g_uas, which app_build sets before
// any ecall can occur.
export fn syscall_setup() -> void {
    syscall_init(&g_syscalls);
    syscall_register(&g_syscalls, SYS_WRITE, sys_write);
    syscall_register(&g_syscalls, SYS_GETPID, sys_getpid);
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
