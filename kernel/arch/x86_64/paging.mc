// kernel/arch/x86_64/paging — x86-64 4-level virtual memory (PML4 -> PDPT -> PD -> PT).
//
// The x86-64 sibling of kernel/arch/riscv64/paging. Same shape and API so later phases
// (uaccess, user mode) can target either arch by import: a `PageTable` owns its structural
// frames (root + interior tables) allocated as raw `PAddr`s from a kernel heap. All address
// math is typed/checked via std/addr; the single `unsafe` per accessor is the raw PTE
// load/store, isolated to pte_load/pte_store — exactly mirroring riscv64/paging.mc.
//
// x86-64 4-level layout: VA = sign-ext(16) | PML4(9) | PDPT(9) | PD(9) | PT(9) | offset(12);
// a PTE holds the 4 KiB-aligned physical address in bits 51:12 plus flag bits.
//
// PTE flag bits handled here:
//   PTE_P  (bit 0)  present
//   PTE_W  (bit 1)  writable
//   PTE_US (bit 2)  user-accessible
//   PTE_PS (bit 7)  page-size (a 2 MiB leaf at PD level)
//   PTE_NX (bit 63) no-execute — REQUIRES EFER.NXE=1; boot.S does not enable it, so a
//                   PTE with PTE_NX set is only valid after the runtime sets EFER.NXE
//                   (the vm_x86 runtime does). With NXE off, bit 63 is reserved and a
//                   set bit faults, so we never *implicitly* set PTE_NX; callers opt in.
//
// Interior-US policy (documented, honest): an x86 leaf is user-accessible only if US is set
// at EVERY level on the walk (PML4e & PDPTe & PDe & PTe). We set US on every interior table
// entry we allocate (PTE_P|PTE_W|PTE_US) so a user leaf is always reachable, and gate access
// purely at the leaf US bit. `mapping_is_user` is nonetheless implemented as the true x86
// AND across all levels (not a shortcut), so the predicate stays correct even if a caller
// later installs a US-clear interior entry by hand.

import "std/addr.mc";
import "kernel/core/heap.mc";
import "kernel/core/aspace.mc";

const PAGE_SIZE: usize = 4096;
const HUGE_2MIB: usize = 0x20_0000;          // 2 MiB
const PTES_PER_TABLE: usize = 512;
const X86_PA_MASK: u64 = 0x000F_FFFF_FFFF_F000; // bits 51:12 — the frame address field

const PTE_P: u64 = 1;            // present
const PTE_W: u64 = 2;            // writable        (1 << 1)
const PTE_US: u64 = 4;           // user-accessible (1 << 2)
const PTE_PS: u64 = 0x80;        // page-size: 2 MiB leaf at PD level (1 << 7)
const PTE_NX: u64 = 0x8000_0000_0000_0000; // no-execute (1 << 63); needs EFER.NXE

// The 9-bit index into the table at `level` for virtual address `a`.
// level 3 = PML4 (>>39), 2 = PDPT (>>30), 1 = PD (>>21), 0 = PT (>>12).
fn pte_index(a: VAddr, level: u32) -> usize {
    let shift: u32 = 12 + 9 * level;
    return (va_value(a) >> shift) & 0x1FF;
}

// Encode a PTE pointing at `target` (a frame or next-level table) with `flags`.
fn pte_for(target: PAddr, flags: u64) -> u64 {
    return ((pa_value(target) as u64) & X86_PA_MASK) | flags;
}

// The physical address a PTE points at (its frame field, offset cleared).
fn pte_target(pte: u64) -> PAddr {
    return pa((pte & X86_PA_MASK) as usize);
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

// Allocate and zero a fresh table frame from the heap (traps on exhaustion).
fn alloc_table(h: *mut Heap) -> PAddr {
    let frame: PAddr = heap_alloc(h, PAGE_SIZE, PAGE_SIZE);
    zero_table(frame);
    return frame;
}

// Non-trapping interior-table allocation: heap exhaustion becomes a typed error
// instead of a trap, for the dynamic map path used on hostile-input loads.
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
    root: PAddr, // the PML4 frame
}

// The root physical address (for loading into CR3).
export fn page_table_root(pt: *PageTable) -> PAddr {
    return pt.root;
}

// Create an empty page table (one zeroed PML4 frame). Traps on heap exhaustion — for
// boot/init paths where a fresh heap that cannot yield one root frame is a kernel bug.
pub fn page_table_new(h: *mut Heap) -> PageTable {
    return .{ .root = alloc_table(h) };
}

// Non-trapping form: allocate the root PML4 frame fallibly, so a caller on a
// hostile-input path can turn even root-table exhaustion into a typed error.
export fn page_table_try_new(h: *mut Heap) -> Result<PageTable, HeapError> {
    switch try_alloc_table(h) {
        ok(root) => { return ok(.{ .root = root }); }
        err(e) => { return err(e); }
    }
}

// Encode this page table's root as a portable `AddressSpace` handle. On x86-64 CR3 is
// simply the physical address of the PML4 (low bits 0; PCID/flags unused here), so the
// handle carries the raw root address. This is the one place the x86 CR3 layout lives.
pub fn x86_aspace_of(pt: *PageTable) -> AddressSpace {
    return AddressSpace.from_root(pa_value(page_table_root(pt)) as u64);
}

// The CR3 value that activates this page table (PML4 physical address).
export fn page_table_cr3(pt: *PageTable) -> u64 {
    return pa_value(page_table_root(pt)) as u64;
}

// Why a mapping request was rejected.
enum MapError {
    MisalignedAddress,     // `virt`/`phys` are not aligned to the mapping granularity
    AlreadyMapped,         // a present leaf PTE already covers this VA (unmap it first)
    ConflictWithLargePage, // a larger leaf mapping (2 MiB PS) already spans this VA
    OutOfFrames,           // heap exhausted while allocating an interior table
}

// Walk PML4->PDPT->PD, allocating interior tables as needed, and install a 4 KiB leaf at
// the PT level mapping `virt` -> `phys` with `flags | PTE_P`. Interior entries are linked
// PTE_P|PTE_W|PTE_US (see interior-US policy at the top). Returns a typed error instead of
// trapping — the validated form callers use on dynamic paths (mmap, fault handlers).
export fn page_table_try_map(pt: *mut PageTable, h: *mut Heap, virt: VAddr, phys_target: PAddr, flags: u64) -> Result<bool, MapError> {
    if (va_value(virt) % PAGE_SIZE) != 0 {
        return err(.MisalignedAddress);
    }
    if (pa_value(phys_target) % PAGE_SIZE) != 0 {
        return err(.MisalignedAddress);
    }
    let interior: u64 = PTE_P | PTE_W | PTE_US;
    var table: PAddr = pt.root;
    // Descend the three interior levels (PML4=3, PDPT=2, PD=1), allocating as needed.
    var level: u32 = 3;
    while level > 0 {
        let idx: usize = pte_index(virt, level);
        let pte: u64 = pte_load(table, idx);
        if (pte & PTE_P) == 0 {
            var next: PAddr = uninit;
            switch try_alloc_table(h) {
                ok(frame) => { next = frame; }
                err(e) => { return err(.OutOfFrames); } // heap exhausted mid-walk
            }
            pte_store(table, idx, pte_for(next, interior));
            table = next;
        } else {
            if (pte & PTE_PS) != 0 {
                return err(.ConflictWithLargePage); // a 2 MiB page already spans this VA
            }
            table = pte_target(pte);
        }
        level = level - 1;
    }
    // Leaf entry at the PT level (level 0).
    let leaf_idx: usize = pte_index(virt, 0);
    if (pte_load(table, leaf_idx) & PTE_P) != 0 {
        return err(.AlreadyMapped); // remapping requires an explicit unmap first
    }
    pte_store(table, leaf_idx, pte_for(phys_target, flags | PTE_P));
    return ok(true);
}

// Trapping convenience wrapper: the boot/identity-map paths map known-disjoint, correctly
// aligned regions, so a conflict there is a kernel bug. Dynamic callers use try_map.
export fn page_table_map(pt: *mut PageTable, h: *mut Heap, virt: VAddr, phys_target: PAddr, flags: u64) -> void {
    switch page_table_try_map(pt, h, virt, phys_target, flags) {
        ok(v) => {}
        err(e) => { unreachable; } // mapping conflict on a path that must not conflict
    }
}

// Map a 2 MiB huge page: a leaf PTE at the PD level (PTE_PS) reached through PML4->PDPT->PD.
// `virt` and `phys` must be 2 MiB-aligned. Interior PML4/PDPT tables are allocated as needed.
// Cheap way to identity-map kernel RAM ranges. Returns a typed error instead of trapping.
export fn page_table_try_map_2mib(pt: *mut PageTable, h: *mut Heap, virt: VAddr, phys_target: PAddr, flags: u64) -> Result<bool, MapError> {
    if (va_value(virt) % HUGE_2MIB) != 0 {
        return err(.MisalignedAddress);
    }
    if (pa_value(phys_target) % HUGE_2MIB) != 0 {
        return err(.MisalignedAddress);
    }
    let interior: u64 = PTE_P | PTE_W | PTE_US;
    var table: PAddr = pt.root;
    // Descend PML4 (3) and PDPT (2); stop at the PD (level 1) to install the PS leaf.
    var level: u32 = 3;
    while level > 1 {
        let idx: usize = pte_index(virt, level);
        let pte: u64 = pte_load(table, idx);
        if (pte & PTE_P) == 0 {
            var next: PAddr = uninit;
            switch try_alloc_table(h) {
                ok(frame) => { next = frame; }
                err(e) => { return err(.OutOfFrames); }
            }
            pte_store(table, idx, pte_for(next, interior));
            table = next;
        } else {
            if (pte & PTE_PS) != 0 {
                return err(.ConflictWithLargePage);
            }
            table = pte_target(pte);
        }
        level = level - 1;
    }
    // PD-level leaf (level 1): set PTE_PS so the entry is a 2 MiB page.
    let pd_idx: usize = pte_index(virt, 1);
    if (pte_load(table, pd_idx) & PTE_P) != 0 {
        return err(.AlreadyMapped);
    }
    pte_store(table, pd_idx, pte_for(phys_target, flags | PTE_P | PTE_PS));
    return ok(true);
}

// Trapping convenience wrapper for the boot identity map (see page_table_map).
export fn page_table_map_2mib(pt: *mut PageTable, h: *mut Heap, virt: VAddr, phys_target: PAddr, flags: u64) -> void {
    switch page_table_try_map_2mib(pt, h, virt, phys_target, flags) {
        ok(v) => {}
        err(e) => { unreachable; } // huge-page conflict on a path that must not conflict
    }
}

// Is `virt`'s leaf currently mapped (present)? Honors 2 MiB PS leaves.
export fn page_table_is_mapped(pt: *PageTable, virt: VAddr) -> bool {
    var table: PAddr = pt.root;
    var level: u32 = 3;
    while level > 0 {
        let pte: u64 = pte_load(table, pte_index(virt, level));
        if (pte & PTE_P) == 0 {
            return false;
        }
        if (pte & PTE_PS) != 0 {
            return true; // a PS leaf at this level covers `virt`
        }
        table = pte_target(pte);
        level = level - 1;
    }
    return (pte_load(table, pte_index(virt, 0)) & PTE_P) != 0;
}

// Remove the mapping for `virt` (clear its leaf PTE). Interior tables are left in place.
// Traps if no present interior path exists.
export fn page_table_unmap(pt: *mut PageTable, virt: VAddr) -> void {
    var table: PAddr = pt.root;
    var level: u32 = 3;
    while level > 0 {
        let idx: usize = pte_index(virt, level);
        let pte: u64 = pte_load(table, idx);
        if (pte & PTE_P) == 0 {
            unreachable; // no mapping to remove
        }
        if (pte & PTE_PS) != 0 {
            pte_store(table, idx, 0); // clear the 2 MiB PS leaf
            return;
        }
        table = pte_target(pte);
        level = level - 1;
    }
    pte_store(table, pte_index(virt, 0), 0);
}

// A resolved leaf mapping: the physical address `virt` resolves to, plus the raw leaf PTE
// so callers can inspect permission bits, AND the running-AND of US across all levels (so
// the honest x86 "user-accessible iff US at every level" predicate is computable).
struct LeafMapping {
    phys: PAddr,
    flags: u64,  // the raw leaf PTE
    us_all: bool, // US set at every level on the walk (PML4e..leaf)
}

enum LookupError {
    NotMapped, // no present leaf PTE covers `virt`
}

// Resolve `virt` to its leaf mapping without trapping — the building block for
// permission-checked user/kernel access. Returns NotMapped if any level is not present.
// Handles 2 MiB PS leaves at the PD level and 4 KiB leaves at the PT level, tracking the
// US-AND across the walk for an honest `mapping_is_user`.
export fn page_table_lookup(pt: *PageTable, virt: VAddr) -> Result<LeafMapping, LookupError> {
    var table: PAddr = pt.root;
    var us_all: bool = true;
    var level: u32 = 3;
    while level > 0 {
        let pte: u64 = pte_load(table, pte_index(virt, level));
        if (pte & PTE_P) == 0 {
            return err(.NotMapped);
        }
        if (pte & PTE_US) == 0 {
            us_all = false;
        }
        if (pte & PTE_PS) != 0 {
            // 2 MiB PS leaf at this level: offset is the low 21 bits.
            let off: usize = va_value(virt) & (HUGE_2MIB - 1);
            return ok(.{ .phys = pa_offset(pte_target(pte), off), .flags = pte, .us_all = us_all });
        }
        table = pte_target(pte);
        level = level - 1;
    }
    let leaf: u64 = pte_load(table, pte_index(virt, 0));
    if (leaf & PTE_P) == 0 {
        return err(.NotMapped);
    }
    if (leaf & PTE_US) == 0 {
        us_all = false;
    }
    let offset: usize = va_value(virt) & 0xFFF;
    return ok(.{ .phys = pa_offset(pte_target(leaf), offset), .flags = leaf, .us_all = us_all });
}

// Permission predicates on a resolved mapping (the PTE bit encoding stays here).
export fn mapping_phys(m: *LeafMapping) -> PAddr { return m.phys; }
// x86 semantics: user-accessible iff US is set at EVERY level on the walk.
export fn mapping_is_user(m: *LeafMapping) -> bool { return m.us_all && (m.flags & PTE_US) != 0; }
export fn mapping_is_writable(m: *LeafMapping) -> bool { return (m.flags & PTE_W) != 0; }
export fn mapping_is_present(m: *LeafMapping) -> bool { return (m.flags & PTE_P) != 0; }
// Part of the uniform paging interface (used by kernel/core/uaccess.mc). On x86-64 a leaf has
// no separate readable bit — a present page is readable (NX governs execute, not read) — so
// readability is just presence. A LeafMapping only exists for a present page, so this is true.
export fn mapping_is_readable(m: *LeafMapping) -> bool { return (m.flags & PTE_P) != 0; }

// Arch hook for the generic ELF loader (kernel/core/elf_loader.mc): translate a user segment's
// R/W/X intent into leaf-PTE bits. On x86-64 a leaf has no separate R/X bits — a present,
// user-accessible page (PTE_US) is readable and (NX not enabled in boot.S) executable — so only
// writability is an extra bit. PTE_US is always set (loaded image = user); PTE_P is added by
// page_table_try_map. r/x come for free with a present US page; only w maps to a bit. (W^X is
// still enforced structurally by the loader rejecting a W&X segment.)
export fn pte_flags_for_user(r: bool, w: bool, x: bool) -> u64 {
    var flags: u64 = PTE_US;
    if w { flags = flags | PTE_W; }
    return flags;
}

// Translate `virt` to its mapped physical address (including the page offset). Traps if
// the address is not mapped — callers verify a mapping exists first (or use lookup).
export fn page_table_translate(pt: *PageTable, virt: VAddr) -> PAddr {
    switch page_table_lookup(pt, virt) {
        ok(m) => { return m.phys; }
        err(e) => { unreachable; } // unmapped address on an infallible translate
    }
}
