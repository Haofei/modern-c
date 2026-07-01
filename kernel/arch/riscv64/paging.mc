// kernel/arch/riscv64/paging — Sv39 virtual memory (three-level page tables).
//
// A `PageTable` owns its structural frames (root + interior tables) allocated as
// raw `PAddr`s from a kernel heap — page-table frames are not transferable
// resources, so they are not linear `Page`s (the linear `Page` type stays for the
// leaf data pages handed to address spaces). All address math is typed/checked via
// std/addr; the single `unsafe` per accessor is the raw PTE load/store, isolated.
//
// Sv39 layout: VA = VPN2(9) | VPN1(9) | VPN0(9) | offset(12); a PTE holds a 44-bit
// PPN at bits 10..53 plus the permission flags at bits 0..7.

import "std/addr.mc";
import "kernel/core/heap.mc";
import "kernel/core/aspace.mc";

const PAGE_SIZE: usize = 4096;
const GIGAPAGE_SIZE: usize = 0x4000_0000;
const PTES_PER_TABLE: usize = 512;
const SV39_PPN_MASK: u64 = 0x0000_0FFF_FFFF_FFFF; // 44-bit PPN field

const PTE_V: u64 = 1;   // valid
const PTE_R: u64 = 2;   // readable
const PTE_W: u64 = 4;   // writable
const PTE_X: u64 = 8;   // executable
const PTE_U: u64 = 16;  // user-accessible

// The index into the table at `level` (0..2) for virtual address `a`.
fn vpn(a: VAddr, level: u32) -> usize {
    let shift: u32 = 12 + 9 * level;
    return (va_value(a) >> shift) & 0x1FF;
}

// Encode a PTE pointing at `target` (a frame or next-level table) with `flags`.
fn pte_for(target: PAddr, flags: u64) -> u64 {
    let ppn: u64 = (pa_value(target) >> 12) as u64;
    return (ppn << 10) | flags;
}

// The physical address a PTE points at.
fn pte_target(pte: u64) -> PAddr {
    let ppn: u64 = (pte >> 10) & SV39_PPN_MASK;
    return pa((ppn << 12) as usize);
}

fn pte_is_leaf(pte: u64) -> bool {
    return (pte & (PTE_R | PTE_W | PTE_X)) != 0;
}

fn page_offset(virt: VAddr, level: u32) -> usize {
    var size: usize = PAGE_SIZE;
    var i: u32 = 0;
    while i < level {
        size = size * PTES_PER_TABLE;
        i = i + 1;
    }
    return va_value(virt) % size;
}

fn pte_load(table: PAddr, index: usize) -> u64 {
    unsafe {
        return raw.load<u64>(pa_offset(table, index * 8));
    }
}

fn pte_store(table: PAddr, index: usize, value: u64) -> void {
    unsafe {
        raw.store<u64>(pa_offset(table, index * 8), value);
    }
}

fn zero_table(table: PAddr) -> void {
    var i: usize = 0;
    while i < PTES_PER_TABLE {
        pte_store(table, i, 0);
        i = i + 1;
    }
}

// Allocate and zero a fresh table frame from the heap.
fn alloc_table(h: *mut Heap) -> PAddr {
    let frame: PAddr = heap_alloc(h, PAGE_SIZE, PAGE_SIZE);
    zero_table(frame);
    return frame;
}

// Non-trapping interior-table allocation: returns OutOfFrames-able heap exhaustion as a
// typed error instead of trapping, for the dynamic map path used on hostile-input loads.
fn try_alloc_table(h: *mut Heap) -> Result<PAddr, HeapError> {
    switch heap_try_alloc(h, PAGE_SIZE, PAGE_SIZE) {
        ok(frame) => {
            zero_table(frame);
            return ok(frame);
        }
        err(e) => { return err(e); }
    }
}

struct PageTable {
    root: PAddr,
}

// The root physical address (for loading into `satp`).
export fn page_table_root(pt: *PageTable) -> PAddr {
    return pt.root;
}

// Create an empty page table (one zeroed root frame). Traps on heap exhaustion — for the
// boot/init paths where a fresh heap that cannot yield one root frame is a kernel bug.
export fn page_table_new(h: *mut Heap) -> PageTable {
    return .{ .root = alloc_table(h) };
}

// Non-trapping form: allocate the root frame fallibly, so a caller on a hostile-input path
// (e.g. the ELF loader's app_build) can turn even root-table exhaustion into a typed error
// rather than a kernel trap.
export fn page_table_try_new(h: *mut Heap) -> Result<PageTable, HeapError> {
    switch try_alloc_table(h) {
        ok(root) => { return ok(.{ .root = root }); }
        err(e) => { return err(e); }
    }
}

// Encode this page table's root as a portable `AddressSpace` handle. This is the one place
// the riscv64 satp bit layout lives: the satp word is MODE | PPN(root>>12), MODE=8 (Sv39) in
// bits 63:60. Portable core (cow/demand) calls this instead of open-coding the layout, so the
// satp encoding never leaks into architecture-independent code. The MODE constant is a local
// `let` (not a module-level const) so this arch file adds no `SATP_SV39` symbol that would
// collide with the demo runtimes that still define their own while paging.mc is included.
export fn riscv_aspace_of(pt: *PageTable) -> AddressSpace {
    let satp_sv39: u64 = 0x8000_0000_0000_0000; // MODE = 8 (Sv39) in bits 63:60
    return AddressSpace.from_root(satp_sv39 | ((pa_value(page_table_root(pt)) >> 12) as u64));
}

// Why a mapping request was rejected.
enum MapError {
    MisalignedAddress,   // `virt`/`phys` are not aligned to the mapping granularity
    AlreadyMapped,       // a valid leaf PTE already covers this VA (unmap it first)
    ConflictWithLargePage, // a larger leaf mapping already spans this VA
    OutOfFrames,         // heap exhausted while allocating an interior table
}

// Map `virt` (page-aligned) to `phys` with permission `flags` (R/W/X/U; V is added),
// returning a typed error instead of trapping. Interior tables are allocated from `h`
// as needed. This is the validated form callers use on dynamic paths (mmap, fault
// handlers) where a conflict or misalignment is a runtime condition to handle.
export fn page_table_try_map(pt: *mut PageTable, h: *mut Heap, virt: VAddr, phys_target: PAddr, flags: u64) -> Result<bool, MapError> {
    if (va_value(virt) % PAGE_SIZE) != 0 {
        return err(.MisalignedAddress);
    }
    if (pa_value(phys_target) % PAGE_SIZE) != 0 {
        return err(.MisalignedAddress);
    }
    var table: PAddr = pt.root;
    // Descend the two interior levels, allocating tables that don't exist yet.
    var level: u32 = 2;
    while level > 0 {
        let idx: usize = vpn(virt, level);
        let pte: u64 = pte_load(table, idx);
        if (pte & PTE_V) == 0 {
            var next: PAddr = uninit;
            switch try_alloc_table(h) {
                ok(frame) => { next = frame; }
                err(e) => { return err(.OutOfFrames); } // heap exhausted mid-walk
            }
            pte_store(table, idx, pte_for(next, PTE_V)); // pointer PTE: V, no R/W/X
            table = next;
        } else {
            if pte_is_leaf(pte) {
                return err(.ConflictWithLargePage); // a large page already spans this VA
            }
            table = pte_target(pte);
        }
        level = level - 1;
    }
    // Leaf entry at level 0.
    let leaf_idx: usize = vpn(virt, 0);
    if (pte_load(table, leaf_idx) & PTE_V) != 0 {
        return err(.AlreadyMapped); // remapping requires an explicit unmap first
    }
    pte_store(table, leaf_idx, pte_for(phys_target, flags | PTE_V));
    return ok(true);
}

// Trapping convenience wrapper: the boot/identity-map paths map known-disjoint,
// correctly-aligned regions, so a conflict there is a kernel bug, not a recoverable
// condition. Dynamic callers use `page_table_try_map` instead.
export fn page_table_map(pt: *mut PageTable, h: *mut Heap, virt: VAddr, phys_target: PAddr, flags: u64) -> void {
    switch page_table_try_map(pt, h, virt, phys_target, flags) {
        ok(v) => {}
        err(e) => { unreachable; } // mapping conflict on a path that must not conflict
    }
}

// Map a 1 GiB gigapage: a leaf PTE at the top level (level 2). `virt` and `phys`
// must be 1 GiB-aligned. Returns a typed error instead of trapping.
export fn page_table_try_map_gigapage(pt: *mut PageTable, virt: VAddr, phys_target: PAddr, flags: u64) -> Result<bool, MapError> {
    if (va_value(virt) % GIGAPAGE_SIZE) != 0 {
        return err(.MisalignedAddress);
    }
    if (pa_value(phys_target) % GIGAPAGE_SIZE) != 0 {
        return err(.MisalignedAddress);
    }
    let idx: usize = vpn(virt, 2);
    if (pte_load(pt.root, idx) & PTE_V) != 0 {
        return err(.AlreadyMapped); // remapping requires an explicit unmap first
    }
    pte_store(pt.root, idx, pte_for(phys_target, flags | PTE_V));
    return ok(true);
}

// Trapping convenience wrapper for the boot identity map (see `page_table_map`).
export fn page_table_map_gigapage(pt: *mut PageTable, virt: VAddr, phys_target: PAddr, flags: u64) -> void {
    switch page_table_try_map_gigapage(pt, virt, phys_target, flags) {
        ok(v) => {}
        err(e) => { unreachable; } // gigapage conflict on a path that must not conflict
    }
}

// Is `virt`'s leaf currently mapped (valid)?
export fn page_table_is_mapped(pt: *PageTable, virt: VAddr) -> bool {
    var table: PAddr = pt.root;
    var level: u32 = 2;
    while level > 0 {
        let pte: u64 = pte_load(table, vpn(virt, level));
        if (pte & PTE_V) == 0 {
            return false;
        }
        if pte_is_leaf(pte) {
            return true;
        }
        table = pte_target(pte);
        level = level - 1;
    }
    return (pte_load(table, vpn(virt, 0)) & PTE_V) != 0;
}

// Remove the mapping for `virt` (clear its leaf PTE). Interior tables are left in
// place. Traps if no interior path exists.
export fn page_table_unmap(pt: *mut PageTable, virt: VAddr) -> void {
    var table: PAddr = pt.root;
    var level: u32 = 2;
    while level > 0 {
        let pte: u64 = pte_load(table, vpn(virt, level));
        if (pte & PTE_V) == 0 {
            unreachable; // no mapping to remove
        }
        if pte_is_leaf(pte) {
            pte_store(table, vpn(virt, level), 0);
            return;
        }
        table = pte_target(pte);
        level = level - 1;
    }
    pte_store(table, vpn(virt, 0), 0);
}

// ----- editing the *active* address space -----
//
// page_table_map/unmap only store PTEs; that is correct for *building an inactive* page table
// (no translations use it yet). But on RISC-V a store to a page table that is *currently in
// use* is not ordered with subsequent implicit translation-table reads — stale TLB entries can
// persist — so any edit to the active address space must be followed by `sfence.vma` for the
// affected page. The fault handlers (demand paging, COW) use the `_active` wrappers below.

// Synchronize a page-table edit for `virt` with address translation (flush its TLB entry for
// all ASIDs). A full implementation would also shoot down other harts that share this address
// space; this is the single-hart fence.
export fn sfence_vma_page(virt: VAddr) -> void {
    let v: usize = va_value(virt);
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "sfence.vma %0, zero"
                in("r") v: usize
            }
        }
    }
}

// Flush the ENTIRE TLB for all ASIDs (`sfence.vma` with no operands — rs1=x0, rs2=x0). Used to
// batch a bulk address-space edit: instead of one address-scoped `sfence.vma va` per page (a fence
// per 4 KiB — 16384 fences for a 64 MiB grow), map all pages then issue ONE global fence. A single
// global fence correctly invalidates any stale/negative entries across the whole range (the pages
// were freshly mapped), so it is sound for the bulk-map/bulk-unmap case in sys_sbrk. Single-hart: a
// full implementation would also shoot down other harts sharing this address space.
export fn sfence_vma_all() -> void {
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "sfence.vma"
            }
        }
    }
}

// Map a page in the active address space, then fence so the new translation is visible.
export fn page_table_map_active(pt: *mut PageTable, h: *mut Heap, virt: VAddr, phys_target: PAddr, flags: u64) -> void {
    page_table_map(pt, h, virt, phys_target, flags);
    sfence_vma_page(virt);
}

// Unmap a page in the active address space, then fence so the stale translation is dropped.
export fn page_table_unmap_active(pt: *mut PageTable, virt: VAddr) -> void {
    page_table_unmap(pt, virt);
    sfence_vma_page(virt);
}

// A resolved leaf mapping: the physical address `virt` resolves to, plus the raw
// leaf PTE so callers can inspect its permission bits without knowing the encoding.
struct LeafMapping {
    phys: PAddr,
    flags: u64,
}

enum LookupError {
    NotMapped, // no valid leaf PTE covers `virt`
}

// Resolve `virt` to its leaf mapping without trapping — the building block for
// permission-checked user/kernel access. Returns `NotMapped` if any level on the
// path is invalid. Handles leaf PTEs at any level (gigapage/megapage/4 KiB).
export fn page_table_lookup(pt: *PageTable, virt: VAddr) -> Result<LeafMapping, LookupError> {
    var table: PAddr = pt.root;
    var level: u32 = 2;
    while level > 0 {
        let pte: u64 = pte_load(table, vpn(virt, level));
        if (pte & PTE_V) == 0 {
            return err(.NotMapped);
        }
        if pte_is_leaf(pte) {
            return ok(.{ .phys = pa_offset(pte_target(pte), page_offset(virt, level)), .flags = pte });
        }
        table = pte_target(pte);
        level = level - 1;
    }
    let leaf: u64 = pte_load(table, vpn(virt, 0));
    if (leaf & PTE_V) == 0 {
        return err(.NotMapped);
    }
    let offset: usize = va_value(virt) & 0xFFF;
    return ok(.{ .phys = pa_offset(pte_target(leaf), offset), .flags = leaf });
}

// Permission predicates on a resolved mapping (the PTE bit encoding stays here).
export fn mapping_phys(m: *LeafMapping) -> PAddr { return m.phys; }
export fn mapping_is_user(m: *LeafMapping) -> bool { return (m.flags & PTE_U) != 0; }
export fn mapping_is_readable(m: *LeafMapping) -> bool { return (m.flags & PTE_R) != 0; }
export fn mapping_is_writable(m: *LeafMapping) -> bool { return (m.flags & PTE_W) != 0; }

// Arch hook for the generic ELF loader (kernel/core/elf_loader.mc): translate a user
// segment's R/W/X intent into leaf-PTE permission bits. A loaded image is user code, so
// PTE_U is always set; R/W/X follow the segment. (PTE_V is added by page_table_map.) On
// RISC-V every permission is an explicit bit, so all three are honored.
export fn pte_flags_for_user(r: bool, w: bool, x: bool) -> u64 {
    var flags: u64 = PTE_U;
    if r { flags = flags | PTE_R; }
    if w { flags = flags | PTE_W; }
    if x { flags = flags | PTE_X; }
    return flags;
}

// Translate `virt` to its mapped physical address (including the page offset).
// Traps if the address is not mapped — callers verify a mapping exists first.
export fn page_table_translate(pt: *PageTable, virt: VAddr) -> PAddr {
    var table: PAddr = pt.root;
    var level: u32 = 2;
    while level > 0 {
        let pte: u64 = pte_load(table, vpn(virt, level));
        if (pte & PTE_V) == 0 {
            unreachable; // unmapped interior level
        }
        if pte_is_leaf(pte) {
            return pa_offset(pte_target(pte), page_offset(virt, level));
        }
        table = pte_target(pte);
        level = level - 1;
    }
    let leaf: u64 = pte_load(table, vpn(virt, 0));
    if (leaf & PTE_V) == 0 {
        unreachable; // unmapped leaf
    }
    let offset: usize = va_value(virt) & 0xFFF;
    return pa_offset(pte_target(leaf), offset);
}
