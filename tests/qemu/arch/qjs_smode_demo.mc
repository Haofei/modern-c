// M3a "confined QuickJS under S-mode/OpenSBI" — MC side.
//
// Composition of two things already on master:
//   - app_run_demo.mc: the REAL multi-segment ELF loader + isolated-Sv39 build + the
//     QuickJS syscall ABI (SYS_WRITE / SYS_READ §0 ingress / SYS_GETPID / SYS_SUBMIT /
//     SYS_POLL). We reuse it verbatim (imported, not modified) for app_build / app_entry
//     / mc_syscall / syscall_setup.
//   - smode_user_demo.mc: under REAL OpenSBI the kernel runs in S-mode, so satp IS
//     effective for the kernel itself. The agent's space must therefore ALSO map the
//     kernel as a SUPERVISOR-ONLY identity gigapage (R|W|X, NO PTE_U) so the S-mode trap
//     handler keeps running after satp activation, while staying unreachable from U-mode.
//
// app_build builds the agent's page table (agent user pages only — the kernel is left
// UNMAPPED, which is the M-mode confinement) and returns the satp. Here, for S-mode, we
// re-derive that page table's root from the satp and add the supervisor kernel gigapage
// to it (a single top-level leaf PTE — agent VAs live at VPN2 index 0, the kernel at
// 0x8000_0000 lives at VPN2 index 2, so they never collide and no interior frame is
// needed). The confinement proof is then M2's "kernel mapped but NOT user" (no PTE_U),
// not "kernel unmapped".

import "tests/qemu/proc/app_run_demo.mc"; // app_build / app_entry / syscall_setup / mc_syscall
import "kernel/arch/riscv64/paging.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

// (SATP_SV39 / PAGE are already defined by the imported app_run_demo.mc; we add only the
// names unique to this fixture.)
const SATP_PPN_MASK: u64 = 0x0000_0FFF_FFFF_FFFF; // 44-bit PPN in satp bits 43:0

// The supervisor (kernel) identity window: the whole 1 GiB gigapage containing the OpenSBI
// payload load address 0x8020_0000 and the kernel's 16 MiB frame region. R|W|X, NO PTE_U.
const KERNEL_GIGA_BASE: usize = 0x8000_0000;

// The 16550 UART transmit register (kernel/core/console.mc writes here directly). Under
// OpenSBI in S-mode satp is effective, so this MMIO page must be mapped — supervisor-only —
// for the agent's SYS_WRITE -> console_putc to reach the UART. It sits at VPN2 index 0, the
// same top-level slot as the agent's user pages (0x1_0000..), so it CANNOT be a gigapage; it
// is a single 4 KiB supervisor page added to the existing interior table.
const UART_MMIO_BASE: usize = 0x1000_0000;

// A small private heap, only for the interior page-table frames the UART 4 KiB mapping needs
// (two tables at most: VPN1 + VPN0). Disjoint from the loader's `region`.
global g_aux_heap: Heap;
global g_aux_region: [16384]u8;

// Reconstruct the PageTable value whose root is the frame the satp points at. The satp word
// is MODE | PPN(root>>12) (see riscv_aspace_of in paging.mc); the root PAddr is PPN<<12.
fn page_table_from_satp(satp: u64) -> PageTable {
    let ppn: u64 = satp & SATP_PPN_MASK;
    let root_pa: usize = (ppn << 12) as usize;
    return .{ .root = pa(root_pa) };
}

// Build the agent's isolated S-mode space: load the QuickJS ELF + ABI via app_build (reused),
// then add the supervisor-only kernel gigapage so the kernel survives satp activation. Returns
// the satp, or 0 on a load failure (app_build_status() carries the typed cause).
export fn qjs_smode_build(image_base: usize, image_len: usize, region_base: usize, region_len: usize) -> u64 {
    let satp: u64 = app_build(image_base, image_len, region_base, region_len);
    if satp == 0 {
        return 0; // loader failure — caller prints app_build_status()
    }
    var pt: PageTable = page_table_from_satp(satp);

    // The kernel image + frame region: one supervisor-only gigapage (R|W|X, NO PTE_U). VPN2
    // index 2 — free, agent pages live at index 0 — so no interior frame is needed.
    page_table_map_gigapage(&pt, va(KERNEL_GIGA_BASE), pa(KERNEL_GIGA_BASE), PTE_R | PTE_W | PTE_X);

    // The UART MMIO page (supervisor-only): the agent's SYS_WRITE handler writes JS output
    // here via console_putc. A single 4 KiB page added to the existing VPN2-index-0 subtree;
    // interior tables come from a small private heap, storing PTEs into the same root frame.
    g_aux_heap = heap_new(phys_range(pa((&g_aux_region[0]) as usize), 16384));
    page_table_map(&pt, &g_aux_heap, va(UART_MMIO_BASE), pa(UART_MMIO_BASE), PTE_R | PTE_W);
    return satp;
}

// Confinement proof (S-mode form): the kernel VA is mapped (so the S-mode trap path keeps
// running) but is NOT user-accessible (no PTE_U), so a direct kernel touch from U-mode faults.
// Returns 1 iff the kernel gigapage lacks PTE_U. Mirrors smode_user_demo.mc's kernel_not_user.
export fn qjs_smode_kernel_not_user(satp: u64, kernel_va: usize) -> u32 {
    var pt: PageTable = page_table_from_satp(satp);
    switch page_table_lookup(&pt, va(kernel_va)) {
        ok(m) => { if mapping_is_user(&m) { return 0; } return 1; }
        err(e) => { return 0; } // unmapped: the kernel couldn't run — not proven
    }
}
