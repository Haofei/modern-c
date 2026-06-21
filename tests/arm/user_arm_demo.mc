// M8 "AArch64 EL0 user hello" — MC side.
//
// The AArch64 analogue of tests/x86/user_x86_demo.mc (x86 M6) and
// tests/qemu/arch/smode_user_demo.mc (RISC-V M2). Build a stage-1 4 KiB-granule EL1 page table
// (kernel/arch/aarch64/paging.mc) that:
//   - identity-maps the kernel's running low RAM (QEMU virt RAM base 0x40000000) with 2 MiB
//     blocks as KERNEL pages (AP=0b00 => EL1 RW, EL0 none), so the EL1 kernel — text/data/
//     stack/heap/vectors all in low RAM — STAYS mapped under TTBR0 yet EL0 can NOT reach it;
//   - maps the PL011 UART page as Device memory (kernel RW) so prints survive MMU enable;
//   - maps the user's code page (AP=user, executable: UXN clear) and the user's stack page
//     (AP=user, RW) at chosen high VAs reachable only through this table's EL0-accessible leaves.
// The EL0/EL1 boundary: EL0 can touch only its own pages, so the user enters the kernel only by
// trapping (`svc #0`). sys_write_copyin then SOFTWARE-WALKS this table (page_table_lookup) to
// validate a user pointer BEFORE the kernel dereferences it, returning -EFAULT for an unmapped
// or non-EL0 pointer WITHOUT ever loading through it.
//
// No `unsafe` bypasses the EL0/present checks; the copy-in is a bounded, fail-closed walk. The
// C bring-up is kernel/arch/aarch64/user_runtime.c.

import "kernel/arch/aarch64/paging.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const UARM_PAGE: usize = 4096;
const UARM_BLOCK_2MIB: usize = 0x20_0000;        // 2 MiB (L2 block)
const UARM_RAM_BASE: usize = 0x4000_0000;        // QEMU virt RAM base (kernel image + heap)
const UARM_IDENTITY_LEN: usize = 0x400_0000;     // identity-map 64 MiB of low RAM as 2 MiB blocks
const UARM_UART_PA: usize = 0x0900_0000;         // PL011 UART (Device memory)

// The user's view of itself. Above the low-RAM kernel identity window, so these VAs resolve
// ONLY through this table's EL0-accessible (AP low bit set) leaves.
const UARM_CODE_VA: usize = 0x1000_0000;         // 256 MiB — user code/strings page
const UARM_STACK_VA: usize = 0x2000_0000;        // 512 MiB — user stack page

// User executable code page: EL0 RW + executable at EL0 (UXN clear). The paging bundles set UXN
// on every user/kernel data flag, so we build a dedicated code flag here: AP=user-RW, Normal WB
// (AttrIndx 0), UXN clear (EL0 may fetch), PXN set (EL1 must not execute user pages).
const UARM_ATTR_AP_URW: u64 = 0x40;              // bits 7:6 = 0b01 — EL1 RW, EL0 RW
const UARM_ATTR_PXN: u64 = 0x0020_0000_0000_0000; // bit 53 — privileged execute-never
const UARM_FLAGS_USER_CODE: u64 = UARM_ATTR_AP_URW | UARM_ATTR_PXN; // UXN clear => EL0-executable

// Linux-AArch64-conventional EFAULT, returned negated as a 2's-complement i64 (sign bit set) so
// the EL0 app sees x0 < 0.
const UARM_EFAULT: i64 = 14;

global g_uarm_heap: Heap;
global g_uarm_pt: PageTable;
global g_uarm_stack_len: usize;

// Map [virt, virt+len) -> [phys, phys+len) one 4 KiB page at a time with `flags`.
fn uarm_map_pages(virt_base: usize, phys_base: usize, len: usize, flags: u64) -> void {
    var off: usize = 0;
    while off < len {
        page_table_map(&g_uarm_pt, &g_uarm_heap, va(virt_base + off), pa(phys_base + off), flags);
        off = off + UARM_PAGE;
    }
}

// Build the EL0 user address space. `region` backs the page tables. `code_phys`/`stack_phys`
// are physical frames the bring-up already populated. Writes the TTBR0_EL1 root (L0 table phys)
// through an out-pointer (no by-value FFI struct return; matches the X2 ABI note). Returns 1.
export fn user_arm_build(region_base: usize, region_len: usize,
                         code_phys: usize, code_len: usize,
                         stack_phys: usize, stack_len: usize,
                         out_ttbr0: *mut u64) -> u32 {
    g_uarm_heap = heap_new(phys_range(pa(region_base), region_len));
    g_uarm_pt = page_table_new(&g_uarm_heap);
    g_uarm_stack_len = stack_len;

    // Kernel identity window: low RAM, 2 MiB blocks, AP=0b00 (EL1 RW, EL0 none) + PXN clear so
    // the EL1 kernel keeps fetching/executing after the TTBR0 switch while staying unreachable
    // from EL0. FLAGS_KERNEL_RWX => not EL0-accessible (mapping_is_user is false here).
    var off: usize = 0;
    while off < UARM_IDENTITY_LEN {
        let addr: usize = UARM_RAM_BASE + off;
        page_table_map_block_2mib(&g_uarm_pt, &g_uarm_heap, va(addr), pa(addr), FLAGS_KERNEL_RWX);
        off = off + UARM_BLOCK_2MIB;
    }

    // PL011 UART page as Device memory (kernel RW, no execute) so prints survive MMU enable.
    page_table_map(&g_uarm_pt, &g_uarm_heap, va(UARM_UART_PA), pa(UARM_UART_PA), FLAGS_DEVICE);

    // The user's own pages (AP low bit set => EL0-accessible). Code is EL0 R|W|X; stack EL0 R|W.
    uarm_map_pages(UARM_CODE_VA, code_phys, code_len, UARM_FLAGS_USER_CODE);
    uarm_map_pages(UARM_STACK_VA, stack_phys, stack_len, FLAGS_USER_RW);

    *out_ttbr0 = page_table_ttbr0(&g_uarm_pt);
    return 1;
}

export fn user_arm_code_va() -> u64 { return UARM_CODE_VA as u64; }
export fn user_arm_stack_top_va() -> u64 { return (UARM_STACK_VA + g_uarm_stack_len) as u64; }

// Confinement proof: a kernel VA is mapped (so EL1 runs) but is NOT EL0-accessible.
// 1 iff the kernel leaf's AP low bit is clear (mapping_is_user false).
export fn user_arm_kernel_not_user(kernel_va: usize) -> u32 {
    switch page_table_lookup(&g_uarm_pt, va(kernel_va)) {
        ok(m) => { if mapping_is_user(&m) { return 0; } return 1; }
        err(e) => { return 0; }
    }
}

// Confinement proof #2: the user's code page IS EL0-accessible (its own page).
export fn user_arm_code_is_user() -> u32 {
    switch page_table_lookup(&g_uarm_pt, va(UARM_CODE_VA)) {
        ok(m) => { if mapping_is_user(&m) { return 1; } return 0; }
        err(e) => { return 0; }
    }
}

// SYS_WRITE copy-in handler (AArch64 analogue of M6's sys_write_copyin). Software-walks the
// EL0 page table for EVERY byte spanned by [user_ptr, user_ptr+len): each leaf must be present
// AND EL0-accessible. On success copies the bytes into the kernel buffer at `kdst` and returns
// `len`; on any failure (unmapped / non-EL0) returns -EFAULT WITHOUT dereferencing the user
// pointer. Reads go through the identity-mapped physical address the walk resolves to. `len` is
// clamped by the caller's bounded buffer.
export fn sys_write_copyin(user_ptr: usize, len: usize, kdst: usize) -> i64 {
    if len == 0 {
        return 0;
    }
    var i: usize = 0;
    while i < len {
        let va_i: VAddr = va(user_ptr + i);
        switch page_table_lookup(&g_uarm_pt, va_i) {
            ok(m) => {
                if !mapping_is_user(&m) {
                    return -UARM_EFAULT; // present but EL1-only: reject, do not read
                }
                // The resolved physical address is identity-mapped in the kernel's low RAM, so
                // we can load it directly to copy the validated byte.
                let src: PAddr = mapping_phys(&m);
                unsafe {
                    let b: u8 = raw.load<u8>(src);
                    raw.store<u8>(pa(kdst + i), b);
                }
            }
            err(e) => {
                return -UARM_EFAULT; // unmapped: reject, never dereferenced
            }
        }
        i = i + 1;
    }
    return len as i64;
}
