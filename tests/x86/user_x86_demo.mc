// M6 "x86-64 ring-3 user hello" — MC side.
//
// The x86-64 analogue of tests/qemu/arch/smode_user_demo.mc (RISC-V M2). Build a 4-level
// page table (kernel/arch/x86_64/paging.mc) that:
//   - identity-maps the low 1 GiB with 2 MiB huge pages as KERNEL pages (PTE_W, NO PTE_US),
//     so the long-mode kernel — text/data/stack/heap/IDT/GDT all under 1 GiB — STAYS mapped
//     after CR3 reload, yet ring-3 can NOT reach any of it (no US bit on the leaf); and
//   - maps the user's code (R|X|U) and stack (R|W|U) as USER pages at high VAs, reachable
//     only through this table.
// The MMU boundary: ring-3 can touch its own pages but not the kernel's, so the user can
// only enter the kernel by trapping (`int $0x80`). sys_write_copyin then SOFTWARE-WALKS this
// page table (page_table_lookup) to validate a user pointer BEFORE the kernel touches it,
// returning -EFAULT for an unmapped / non-user pointer without ever dereferencing it.
//
// x86 has no uaccess layer yet, so the copy-in is a bounded, fail-closed page-table walk via
// paging.mc's lookup (no `unsafe` to bypass the US/present checks). The C bring-up is
// kernel/arch/x86_64/user_runtime.c.

import "kernel/arch/x86_64/paging.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const USER_PAGE: usize = 4096;
const USER_GIB: usize = 0x4000_0000;
const USER_HUGE_2MIB: usize = 0x20_0000;

// The user's view of itself. Above the low-1-GiB kernel identity window, so these VAs
// resolve ONLY through the user page table's US leaves.
const USER_CODE_VA: usize = 0x4000_0000; // 1 GiB
const USER_STACK_VA: usize = 0x5000_0000; // 1.25 GiB

// Linux-conventional EFAULT, returned negated as a 2's-complement i64 (sign bit set) so the
// ring-3 app sees RAX < 0.
const EFAULT: i64 = 14;

global g_heap: Heap;
global g_pt: PageTable;
global g_stack_len: usize;

// Map [virt, virt+len) -> [phys, phys+len) one 4 KiB page at a time with `flags`.
fn map_pages(virt_base: usize, phys_base: usize, len: usize, flags: u64) -> void {
    var off: usize = 0;
    while off < len {
        page_table_map(&g_pt, &g_heap, va(virt_base + off), pa(phys_base + off), flags);
        off = off + USER_PAGE;
    }
}

// Build the user address space. `region` backs the page tables. `code_phys`/`stack_phys` are
// physical frames the bring-up already populated. Returns the CR3 (PML4 phys) to activate via
// an out-pointer (no by-value FFI struct return; see X2 ABI note). Returns 1 on success.
export fn user_x86_build(region_base: usize, region_len: usize,
                         code_phys: usize, code_len: usize,
                         stack_phys: usize, stack_len: usize,
                         out_cr3: *mut u64) -> u32 {
    g_heap = heap_new(phys_range(pa(region_base), region_len));
    g_pt = page_table_new(&g_heap);
    g_stack_len = stack_len;

    // Kernel identity window: low 1 GiB, 2 MiB huge pages, writable but NOT user (US clear),
    // so the long-mode kernel keeps running after CR3 reload while staying unreachable from
    // ring-3. PTE_W only -> US stays clear -> mapping_is_user is false here.
    let kflags: u64 = 2; // PTE_W (present added by the API); US clear => kernel page
    var off: usize = 0;
    while off < USER_GIB {
        page_table_map_2mib(&g_pt, &g_heap, va(off), pa(off), kflags);
        off = off + USER_HUGE_2MIB;
    }

    // The user's own pages (US set). Code is R|X|U; stack is R|W|U.
    map_pages(USER_CODE_VA, code_phys, code_len, PTE_W | PTE_US); // R|W|X|U leaf (X default-on, no NX)
    map_pages(USER_STACK_VA, stack_phys, stack_len, PTE_W | PTE_US);

    *out_cr3 = page_table_cr3(&g_pt);
    return 1;
}

export fn user_code_va() -> u64 { return USER_CODE_VA as u64; }
export fn user_stack_top_va() -> u64 { return (USER_STACK_VA + g_stack_len) as u64; }

// Confinement proof: a kernel VA is mapped (so long mode runs) but is NOT user-accessible.
// 1 iff the kernel page lacks PTE_US (US-AND across the walk is false).
export fn kernel_not_user(kernel_va: usize) -> u32 {
    switch page_table_lookup(&g_pt, va(kernel_va)) {
        ok(m) => { if mapping_is_user(&m) { return 0; } return 1; }
        err(e) => { return 0; }
    }
}

// Confinement proof #2: the user's code page IS user-accessible (its own page).
export fn user_code_is_user() -> u32 {
    switch page_table_lookup(&g_pt, va(USER_CODE_VA)) {
        ok(m) => { if mapping_is_user(&m) { return 1; } return 0; }
        err(e) => { return 0; }
    }
}

// SYS_WRITE copy-in handler (x86 analogue of smode_user_demo.mc's sys_write_copyin). Software-
// walks the user page table for EVERY page spanned by [user_ptr, user_ptr+len): each leaf must
// be present AND user-accessible (US at every level). On success copies the bytes into the
// kernel buffer at `kdst` and returns `len`; on any failure (unmapped / non-user) returns
// -EFAULT WITHOUT dereferencing the user pointer. `len` is clamped by the caller's bounded
// buffer. Reads go through the identity-mapped physical address the walk resolves to.
export fn sys_write_copyin(user_ptr: usize, len: usize, kdst: usize) -> i64 {
    if len == 0 {
        return 0;
    }
    var i: usize = 0;
    while i < len {
        let va_i: VAddr = va(user_ptr + i);
        switch page_table_lookup(&g_pt, va_i) {
            ok(m) => {
                if !mapping_is_user(&m) {
                    return -EFAULT; // present but kernel-only: reject, do not read
                }
                // The resolved physical address is identity-mapped in the kernel's low 1 GiB,
                // so we can load it directly to copy the validated byte.
                let src: PAddr = mapping_phys(&m);
                unsafe {
                    let b: u8 = raw.load<u8>(src);
                    raw.store<u8>(pa(kdst + i), b);
                }
            }
            err(e) => {
                return -EFAULT; // unmapped: reject, never dereferenced
            }
        }
        i = i + 1;
    }
    return len as i64;
}
