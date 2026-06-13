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

struct PageTable {
    root: PAddr,
}

// The root physical address (for loading into `satp`).
export fn page_table_root(pt: *PageTable) -> PAddr {
    return pt.root;
}

// Create an empty page table (one zeroed root frame).
export fn page_table_new(h: *mut Heap) -> PageTable {
    return .{ .root = alloc_table(h) };
}

// Why a mapping request was rejected. (Heap exhaustion while allocating an interior
// table is fatal — `heap_alloc` traps — so it is not a recoverable variant here.)
enum MapError {
    MisalignedAddress,   // `virt`/`phys` are not aligned to the mapping granularity
    AlreadyMapped,       // a valid leaf PTE already covers this VA (unmap it first)
    ConflictWithLargePage, // a larger leaf mapping already spans this VA
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
            let next: PAddr = alloc_table(h);
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
