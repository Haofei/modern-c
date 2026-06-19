// Step 0 — a GENUINELY confined untrusted agent: a separate ELF loaded into an
// ISOLATED Sv39 address space and run in U-mode with NO ambient authority.
//
// The existing elf-run demo proves U-mode execution, but it runs in the kernel's
// single (bare) address space with PMP open to all memory — so that "user"
// program could touch kernel memory directly. That is the gap this closes: the
// agent here runs in its OWN page table that maps ONLY its code (R|X|U) and stack
// (R|W|U) and DOES NOT map the kernel at all. With that satp active in U-mode,
// the agent can reach the kernel only by trapping (`ecall` → syscall); any
// attempt to load/execute a kernel address faults, because it is simply not in
// the agent's address space. The MMU, not goodwill, is the boundary.
//
// Self-contained on purpose: it carries its own minimal syscall table (just the
// SYS_PUTC the agent uses + SYS_EXIT, which the trap path handles directly) so it
// does not depend on the shared syscall demo. The C bring-up
// (agent_confined_runtime.c) calls elf_load_run to land the segment, then
// agent_confined_build to construct the isolated space, then enters U-mode.

import "kernel/core/elf.mc";
import "kernel/arch/riscv64/paging.mc";
import "kernel/core/heap.mc";
import "kernel/core/syscall.mc";
import "kernel/core/console.mc";
import "std/bytes.mc";
import "std/addr.mc";

const SATP_SV39: u64 = 0x8000_0000_0000_0000;
const PAGE: usize = 4096;
const SYS_PUTC: usize = 2;

// The agent's view of itself. Deliberately far from the kernel's physical load
// address (0x8000_0000) and from MMIO, so these VAs are valid ONLY through the
// agent's page table — if the satp did not activate, a fetch here would fault.
const AGENT_CODE_VA: usize = 0x4000_0000;
const AGENT_STACK_VA: usize = 0x5000_0000;

global g_heap: Heap;
global g_pt: PageTable;
global g_syscalls: SyscallTable;

// ----- the agent's syscall surface (the only way out of its address space) -----

fn sys_putc(ch: u64, a: u64, b: u64) -> u64 {
    console_putc(ch as u8);
    return 0;
}

// Called by the U-mode runtime before any ecall (via usermode_setup).
export fn syscall_setup() -> void {
    syscall_init(&g_syscalls);
    syscall_register(&g_syscalls, SYS_PUTC, sys_putc);
}

// The trap vector routes an ecall here (number a7, args a0/a1/a2; result a0).
export fn mc_syscall(number: u64, arg0: u64, arg1: u64, arg2: u64) -> u64 {
    return syscall_dispatch(&g_syscalls, number, arg0, arg1, arg2);
}

// ----- ELF load (parse + copy the PT_LOAD segment to a physical landing frame) -----

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

// ----- the isolated address space -----

// Map [virt, virt+len) -> [phys, phys+len) one page at a time with `flags`.
fn map_pages(virt_base: usize, phys_base: usize, len: usize, flags: u64) -> void {
    var off: usize = 0;
    while off < len {
        page_table_map(&g_pt, &g_heap, va(virt_base + off), pa(phys_base + off), flags);
        off = off + PAGE;
    }
}

// Build the agent's isolated address space from a heap carved out of [region].
// `code_phys`/`stack_phys` are the physical frames the bring-up already loaded the
// ELF segment and reserved for the stack. Returns the Sv39 satp value to activate.
// The kernel region is intentionally NOT mapped — that omission is the confinement.
export fn agent_confined_build(region_base: usize, region_len: usize, code_phys: usize, code_len: usize, stack_phys: usize, stack_len: usize) -> u64 {
    g_heap = heap_new(phys_range(pa(region_base), region_len));
    g_pt = page_table_new(&g_heap);
    map_pages(AGENT_CODE_VA, code_phys, code_len, PTE_R | PTE_X | PTE_U);
    map_pages(AGENT_STACK_VA, stack_phys, stack_len, PTE_R | PTE_W | PTE_U);
    let root: PAddr = page_table_root(&g_pt);
    return SATP_SV39 | ((pa_value(root) >> 12) as u64);
}

export fn agent_code_va() -> u64 {
    return AGENT_CODE_VA as u64;
}

// Top of the agent's user stack (exclusive), as a VA in the isolated space.
export fn agent_stack_top_va(stack_len: usize) -> u64 {
    return (AGENT_STACK_VA + stack_len) as u64;
}

// Confinement proof #1: the kernel VA is NOT reachable from the agent's space.
// 1 iff unmapped (so a direct kernel access from U-mode would fault).
export fn agent_kernel_unmapped(kernel_va: usize) -> u32 {
    if page_table_is_mapped(&g_pt, va(kernel_va)) {
        return 0;
    }
    return 1;
}

// Confinement proof #2: the agent's code page is user-accessible (PTE_U) — it is
// the agent's own, not a kernel page exposed by accident.
export fn agent_code_is_user() -> u32 {
    switch page_table_lookup(&g_pt, va(AGENT_CODE_VA)) {
        ok(m) => {
            if mapping_is_user(&m) {
                return 1;
            }
            return 0;
        }
        err(e) => { return 0; }
    }
}
