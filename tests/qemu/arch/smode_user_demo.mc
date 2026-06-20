// M2 "RISC-V S-mode user hello" — MC side.
//
// Under REAL OpenSBI the kernel runs in S-mode (not M-mode), so satp IS effective
// for the kernel itself. We therefore build an Sv39 space that:
//   - identity-maps the kernel image + its working memory as SUPERVISOR pages
//     (R|W|X, NO PTE_U) via a gigapage, so the S-mode trap handler keeps running
//     after the satp is activated; and
//   - maps the agent's code (R|X|U) and stack (R|W|U) as USER pages at VAs far from
//     the kernel, valid ONLY through this page table.
// The MMU boundary: U-mode can reach the agent's own pages but NOT the kernel's
// (no PTE_U on the gigapage), so the agent can only enter the kernel by trapping
// (ecall -> SYS_WRITE / SYS_EXIT). copy_from_user_pt then walks THIS page table to
// validate a user pointer before the kernel ever touches it, returning -EFAULT for
// an unmapped/non-user/straddling pointer without dereferencing it.
//
// This is the S-mode analogue of agent_confined_demo.mc (which relies on M-mode
// ignoring satp). The C bring-up is smode_user_runtime.c.

import "kernel/core/elf.mc";
import "kernel/arch/riscv64/paging.mc";
import "kernel/core/heap.mc";
import "kernel/core/uaccess.mc";
import "std/addr.mc";
import "std/bytes.mc";

const SATP_SV39: u64 = 0x8000_0000_0000_0000;
const PAGE: usize = 4096;
const GIGA: usize = 0x4000_0000; // 1 GiB Sv39 gigapage

// The agent's view of itself. Deliberately far from the kernel (0x8000_0000) and
// MMIO, so these VAs resolve ONLY through the agent's page table.
const AGENT_CODE_VA: usize = 0x4000_0000;
const AGENT_STACK_VA: usize = 0x5000_0000;

// The supervisor (kernel) identity window: the whole 1 GiB gigapage containing the
// OpenSBI payload load address 0x8020_0000. Mapped R|W|X with NO PTE_U.
const KERNEL_GIGA_BASE: usize = 0x8000_0000;

// Linux-conventional EFAULT. No E_FAULT symbol exists in-tree; we use 14 and return
// it negated as a 2's-complement i64 (sign bit set) so the U-mode app sees a0 < 0.
const EFAULT: i64 = 14;

global g_heap: Heap;
global g_pt: PageTable;
global g_stack_len: usize;

// ELF load (parse + copy the PT_LOAD segment to a physical landing frame). Same shape
// as agent_confined_demo.mc — the bring-up calls this before smode_space_build.
export fn elf_load_run(elf_base: usize, elf_len: usize, dst: usize) -> u64 {
    var r: ByteReader = byte_reader(pa(elf_base), elf_len);
    switch elf_parse_header(&r) {
        ok(h) => {
            var i: u16 = 0;
            while i < h.phnum {
                var ph: ProgramHeader = elf_program_header(&r, h.phoff as usize, h.phentsize as usize, i as usize);
                if ph_is_load(&ph) {
                    switch elf_load_segment(&r, &ph, pa(dst)) {
                        ok(u) => { return (dst as u64) + (h.entry - ph.vaddr); }
                        err(e) => { return 0; }
                    }
                }
                i = i + 1;
            }
            return 0;
        }
        err(e) => { return 0; }
    }
}

// Map [virt, virt+len) -> [phys, phys+len) one 4 KiB page at a time with `flags`.
fn map_pages(virt_base: usize, phys_base: usize, len: usize, flags: u64) -> void {
    var off: usize = 0;
    while off < len {
        page_table_map(&g_pt, &g_heap, va(virt_base + off), pa(phys_base + off), flags);
        off = off + PAGE;
    }
}

// Build the agent's Sv39 space. `region` backs the page tables. `code_phys`/`stack_phys`
// are physical frames the bring-up already populated. Returns the satp to activate.
export fn smode_space_build(region_base: usize, region_len: usize, code_phys: usize, code_len: usize, stack_phys: usize, stack_len: usize) -> u64 {
    g_heap = heap_new(phys_range(pa(region_base), region_len));
    g_pt = page_table_new(&g_heap);
    g_stack_len = stack_len;

    // Supervisor identity window for the kernel (no PTE_U): keeps the S-mode trap
    // handler executing after satp activation, while remaining unreachable from U.
    page_table_map_gigapage(&g_pt, va(KERNEL_GIGA_BASE), pa(KERNEL_GIGA_BASE), PTE_R | PTE_W | PTE_X);

    // The agent's user pages.
    map_pages(AGENT_CODE_VA, code_phys, code_len, PTE_R | PTE_X | PTE_U);
    map_pages(AGENT_STACK_VA, stack_phys, stack_len, PTE_R | PTE_W | PTE_U);

    let root: PAddr = page_table_root(&g_pt);
    return SATP_SV39 | ((pa_value(root) >> 12) as u64);
}

export fn agent_code_va() -> u64 { return AGENT_CODE_VA as u64; }
export fn agent_stack_top_va() -> u64 { return (AGENT_STACK_VA + g_stack_len) as u64; }

// Confinement proof: a kernel VA is mapped (so S-mode runs) but is NOT user-accessible,
// so a direct kernel touch from U-mode faults. 1 iff kernel page lacks PTE_U.
export fn kernel_not_user(kernel_va: usize) -> u32 {
    switch page_table_lookup(&g_pt, va(kernel_va)) {
        ok(m) => { if mapping_is_user(&m) { return 0; } return 1; }
        err(e) => { return 0; } // unmapped: the kernel couldn't run — treat as not-proven
    }
}

// Confinement proof #2: the agent's code page is user-accessible (its own page).
export fn agent_code_is_user() -> u32 {
    switch page_table_lookup(&g_pt, va(AGENT_CODE_VA)) {
        ok(m) => { if mapping_is_user(&m) { return 1; } return 0; }
        err(e) => { return 0; }
    }
}

// Re-tag an integer user VA into the UserPtr<u8> address class (audited boundary —
// copy_from_user_pt still validates it against the page table). Matches the uaccess idiom.
fn uptr(a: usize) -> UserPtr<u8> {
    var p: UserPtr<u8> = uninit;
    unsafe { p = a as UserPtr<u8>; }
    return p;
}

// SYS_WRITE copy-in handler: validate [user_ptr, user_ptr+len) against the agent's
// page table and copy into the kernel buffer at `kdst`. Returns bytes copied on Ok, or
// -EFAULT on any validation failure (unmapped / non-user / straddling) — the kernel
// never dereferences a bad user pointer. `len` is clamped by the caller's bounded buffer.
export fn sys_write_copyin(user_ptr: usize, len: usize, kdst: usize) -> i64 {
    // The agent's whole user range; copy_from_user_pt does the per-page PTE_U/PTE_R walk.
    var uas: UserAddrSpace = user_addr_space(&g_pt, 0, 0x8000_0000);
    switch copy_from_user_pt(&uas, pa(kdst), uptr(user_ptr), len) {
        ok(v) => { return len as i64; }
        err(e) => { return -EFAULT; }
    }
}
