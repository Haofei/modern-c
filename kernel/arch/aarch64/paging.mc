// kernel/arch/aarch64/paging — AArch64 stage-1 EL1 virtual memory, 4 KiB granule, 48-bit VA.
//
// The aarch64 sibling of kernel/arch/riscv64/paging and kernel/arch/x86_64/paging. Same
// shape and API so later phases (uaccess, user mode) can target any of the three arches by
// import: a `PageTable` owns its structural frames (root + interior tables) allocated as raw
// `PAddr`s from a kernel heap. All address math is typed/checked via std/addr; the single
// `unsafe` per accessor is the raw descriptor load/store, isolated to pte_load/pte_store —
// exactly mirroring riscv64/paging.mc and x86_64/paging.mc.
//
// 48-bit VA, 4 KiB granule => four translation levels:
//   VA = L0(9) | L1(9) | L2(9) | L3(9) | offset(12)
// We number levels x86-style for a shared descend loop: 3 = L0 (top), 2 = L1, 1 = L2,
// 0 = L3 (leaf). Index shift at `level` = 12 + 9*level. A descriptor holds the 4 KiB-aligned
// output address in bits 47:12.
//
// VMSAv8-64 descriptor encoding (bits[1:0] = descriptor type):
//   * Table descriptor (at L0..L2):  next_table_pa | 0b11.
//   * Block descriptor (at L1 = 1 GiB, L2 = 2 MiB):  output_pa | 0b01  + leaf attrs.
//   * Page  descriptor (at L3 = 4 KiB):              output_pa | 0b11  + leaf attrs.
// (At L3, 0b11 means "page"; at L0..L2, 0b11 means "table" and 0b01 means "block". So the
// type bits are context-dependent on level — handled below.)
//
// Leaf lower attributes (this is where the permission/memory model lives):
//   AF       (bit 10)   access flag — REQUIRED set, else a translation fault on access.
//   SH       (bits 9:8) shareability — 0b11 inner-shareable (correct for Normal WB memory).
//   AP       (bits 7:6) data access permission:
//                         0b00 = EL1 RW, EL0 none   (kernel RW)
//                         0b01 = EL1 RW, EL0 RW     (user RW)
//                         0b10 = EL1 RO, EL0 none   (kernel RO)
//                         0b11 = EL1 RO, EL0 RO     (user RO)
//                       => EL0-accessible (user) iff AP == 0b01 or 0b11 (low AP bit set).
//   AttrIndx (bits 4:2) index into MAIR_EL1: 0 = Normal WB, 1 = Device-nGnRE.
// Leaf upper attributes:
//   UXN (bit 54) unprivileged execute-never; PXN (bit 53) privileged execute-never.
//
// W^X is DEFERRED for this VM milestone: the kernel identity map is RWX (PXN=0) so the text it
// executes is fetchable. A later hardening phase splits text(RX)/data(RW,PXN) — see the flag
// constants below which already carry PXN/UXN so callers can opt in without an encoding change.

import "std/addr.mc";
import "kernel/core/heap.mc";
import "kernel/core/aspace.mc";

const PAGE_SIZE: usize = 4096;
const BLOCK_2MIB: usize = 0x20_0000;          // 2 MiB (L2 block)
const PTES_PER_TABLE: usize = 512;
const A64_OA_MASK: u64 = 0x0000_FFFF_FFFF_F000; // bits 47:12 — the output address field

// Descriptor type bits (bits[1:0]).
const DESC_VALID: u64 = 1;          // bit 0 — entry is valid
const DESC_TYPE_MASK: u64 = 3;      // bits[1:0] — descriptor type field
const DESC_TABLE: u64 = 3;          // 0b11 — table (L0..L2) / page (L3)
const DESC_BLOCK: u64 = 1;          // 0b01 — block (L1/L2)
const DESC_PAGE: u64 = 3;           // 0b11 — page (L3)

// Leaf lower attributes.
const ATTR_AF: u64 = 0x400;         // bit 10 — access flag (REQUIRED)
const ATTR_SH_INNER: u64 = 0x300;   // bits 9:8 = 0b11 — inner shareable
const ATTR_AP_KRW: u64 = 0x0;       // bits 7:6 = 0b00 — EL1 RW, EL0 none (kernel RW)
const ATTR_AP_URW: u64 = 0x40;      // bits 7:6 = 0b01 — EL1 RW, EL0 RW   (user RW)
const ATTR_AP_KRO: u64 = 0x80;      // bits 7:6 = 0b10 — EL1 RO, EL0 none (kernel RO)
const ATTR_AP_URO: u64 = 0xC0;      // bits 7:6 = 0b11 — EL1 RO, EL0 RO   (user RO)
const ATTR_AP_LOW: u64 = 0x40;      // bit 6 — set in AP iff EL0-accessible (0b01 or 0b11)
const ATTR_ATTRIDX0: u64 = 0x0;     // bits 4:2 = 0 — MAIR Attr0 (Normal WB)
const ATTR_ATTRIDX1: u64 = 0x4;     // bits 4:2 = 1 — MAIR Attr1 (Device-nGnRE)

// Leaf upper attributes.
const ATTR_UXN: u64 = 0x0040_0000_0000_0000; // bit 54 — unprivileged execute-never
const ATTR_PXN: u64 = 0x0020_0000_0000_0000; // bit 53 — privileged execute-never

// Convenience leaf-attribute bundles callers pass as `flags` (the descriptor's type bits and
// AF/SH are added by the map functions; these carry AP + AttrIndx + XN policy).
//
// Kernel Normal-memory RWX page (PXN=0 so EL1 may fetch instructions; UXN=1, EL0 cannot exec).
export const FLAGS_KERNEL_RWX: u64 = ATTR_AP_KRW | ATTR_ATTRIDX0 | ATTR_UXN;
// Kernel Normal-memory data page (no execute at all): PXN=1, UXN=1.
export const FLAGS_KERNEL_DATA: u64 = ATTR_AP_KRW | ATTR_ATTRIDX0 | ATTR_PXN | ATTR_UXN;
// Device memory (UART MMIO): Device-nGnRE, kernel RW, no execute.
export const FLAGS_DEVICE: u64 = ATTR_AP_KRW | ATTR_ATTRIDX1 | ATTR_PXN | ATTR_UXN;
// User Normal-memory RW data page: EL0 RW, PXN=1 (EL1 cannot exec user data), UXN=1.
export const FLAGS_USER_RW: u64 = ATTR_AP_URW | ATTR_ATTRIDX0 | ATTR_PXN | ATTR_UXN;

// The 9-bit index into the table at `level` for virtual address `a`.
// level 3 = L0 (>>39), 2 = L1 (>>30), 1 = L2 (>>21), 0 = L3 (>>12).
fn pte_index(a: VAddr, level: u32) -> usize {
    let shift: u32 = 12 + 9 * level;
    return (va_value(a) >> shift) & 0x1FF;
}

// Encode a descriptor pointing at `target` (a frame or next-level table) with `bits`.
fn desc_for(target: PAddr, bits: u64) -> u64 {
    return ((pa_value(target) as u64) & A64_OA_MASK) | bits;
}

// The physical address a descriptor points at (output-address field, offset cleared).
fn desc_target(desc: u64) -> PAddr {
    return pa((desc & A64_OA_MASK) as usize);
}

// Is this descriptor a leaf (block/page) rather than a table pointer? At L0..L2 a 0b01 entry
// is a block leaf; a 0b11 entry is a table. At L3 (level 0) a 0b11 entry is a page leaf. The
// caller passes the level so the type bits are interpreted in context.
fn desc_is_leaf(desc: u64, level: u32) -> bool {
    if level == 0 {
        return (desc & DESC_TYPE_MASK) == DESC_PAGE; // L3: page
    }
    return (desc & DESC_TYPE_MASK) == DESC_BLOCK;    // L0..L2: block
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

// Non-trapping interior-table allocation: heap exhaustion becomes a typed error instead of a
// trap, for the dynamic map path used on hostile-input loads.
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
    root: PAddr, // the L0 table frame
}

// The root physical address (for loading into TTBR0_EL1).
export fn page_table_root(pt: *PageTable) -> PAddr {
    return pt.root;
}

// Create an empty page table (one zeroed L0 frame). Traps on heap exhaustion — for boot/init
// paths where a fresh heap that cannot yield one root frame is a kernel bug.
export fn page_table_new(h: *mut Heap) -> PageTable {
    return .{ .root = alloc_table(h) };
}

// Non-trapping form: allocate the root L0 frame fallibly, so a caller on a hostile-input path
// can turn even root-table exhaustion into a typed error.
export fn page_table_try_new(h: *mut Heap) -> Result<PageTable, HeapError> {
    switch try_alloc_table(h) {
        ok(root) => { return ok(.{ .root = root }); }
        err(e) => { return err(e); }
    }
}

// Encode this page table's root as a portable `AddressSpace` handle. On AArch64 TTBR0_EL1 is
// the physical address of the L0 table (low bits 0; ASID unused here), so the handle carries
// the raw root address. This is the one place the aarch64 TTBR layout lives.
export fn aarch64_aspace_of(pt: *PageTable) -> AddressSpace {
    return AddressSpace.from_root(pa_value(page_table_root(pt)) as u64);
}

// The TTBR0_EL1 value that activates this page table (L0 table physical address).
export fn page_table_ttbr0(pt: *PageTable) -> u64 {
    return pa_value(page_table_root(pt)) as u64;
}

// Why a mapping request was rejected.
enum MapError {
    MisalignedAddress,     // `virt`/`phys` are not aligned to the mapping granularity
    AlreadyMapped,         // a valid leaf descriptor already covers this VA (unmap first)
    ConflictWithLargePage, // a larger block leaf already spans this VA
    OutOfFrames,           // heap exhausted while allocating an interior table
}

// Walk L0->L1->L2, allocating interior tables as needed (linked as table descriptors), and
// install a 4 KiB page leaf at L3 mapping `virt` -> `phys` with `flags`. AF + inner-shareable
// + page type bits are added here. Returns a typed error instead of trapping — the validated
// form callers use on dynamic paths (mmap, fault handlers).
export fn page_table_try_map(pt: *mut PageTable, h: *mut Heap, virt: VAddr, phys_target: PAddr, flags: u64) -> Result<bool, MapError> {
    if (va_value(virt) % PAGE_SIZE) != 0 {
        return err(.MisalignedAddress);
    }
    if (pa_value(phys_target) % PAGE_SIZE) != 0 {
        return err(.MisalignedAddress);
    }
    var table: PAddr = pt.root;
    // Descend the three interior levels (L0=3, L1=2, L2=1), allocating as needed.
    var level: u32 = 3;
    while level > 0 {
        let idx: usize = pte_index(virt, level);
        let pte: u64 = pte_load(table, idx);
        if (pte & DESC_VALID) == 0 {
            var next: PAddr = uninit;
            switch try_alloc_table(h) {
                ok(frame) => { next = frame; }
                err(e) => { return err(.OutOfFrames); } // heap exhausted mid-walk
            }
            pte_store(table, idx, desc_for(next, DESC_TABLE)); // table descriptor (0b11)
            table = next;
        } else {
            if desc_is_leaf(pte, level) {
                return err(.ConflictWithLargePage); // a block already spans this VA
            }
            table = desc_target(pte);
        }
        level = level - 1;
    }
    // Leaf page at L3 (level 0).
    let leaf_idx: usize = pte_index(virt, 0);
    if (pte_load(table, leaf_idx) & DESC_VALID) != 0 {
        return err(.AlreadyMapped); // remapping requires an explicit unmap first
    }
    let leaf: u64 = desc_for(phys_target, flags | ATTR_AF | ATTR_SH_INNER | DESC_PAGE);
    pte_store(table, leaf_idx, leaf);
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

// Map a 2 MiB block: a block leaf at L2 (level 1) reached through L0->L1. `virt` and `phys`
// must be 2 MiB-aligned. Interior L0/L1 tables are allocated as needed. The cheap way to
// identity-map kernel RAM ranges. Returns a typed error instead of trapping.
export fn page_table_try_map_block_2mib(pt: *mut PageTable, h: *mut Heap, virt: VAddr, phys_target: PAddr, flags: u64) -> Result<bool, MapError> {
    if (va_value(virt) % BLOCK_2MIB) != 0 {
        return err(.MisalignedAddress);
    }
    if (pa_value(phys_target) % BLOCK_2MIB) != 0 {
        return err(.MisalignedAddress);
    }
    var table: PAddr = pt.root;
    // Descend L0 (3) and L1 (2); stop at L2 (level 1) to install the block leaf.
    var level: u32 = 3;
    while level > 1 {
        let idx: usize = pte_index(virt, level);
        let pte: u64 = pte_load(table, idx);
        if (pte & DESC_VALID) == 0 {
            var next: PAddr = uninit;
            switch try_alloc_table(h) {
                ok(frame) => { next = frame; }
                err(e) => { return err(.OutOfFrames); }
            }
            pte_store(table, idx, desc_for(next, DESC_TABLE));
            table = next;
        } else {
            if desc_is_leaf(pte, level) {
                return err(.ConflictWithLargePage);
            }
            table = desc_target(pte);
        }
        level = level - 1;
    }
    // L2-level block leaf (level 1): type bits 0b01 (block).
    let l2_idx: usize = pte_index(virt, 1);
    if (pte_load(table, l2_idx) & DESC_VALID) != 0 {
        return err(.AlreadyMapped);
    }
    let leaf: u64 = desc_for(phys_target, flags | ATTR_AF | ATTR_SH_INNER | DESC_BLOCK);
    pte_store(table, l2_idx, leaf);
    return ok(true);
}

// Trapping convenience wrapper for the boot identity map (see page_table_map).
export fn page_table_map_block_2mib(pt: *mut PageTable, h: *mut Heap, virt: VAddr, phys_target: PAddr, flags: u64) -> void {
    switch page_table_try_map_block_2mib(pt, h, virt, phys_target, flags) {
        ok(v) => {}
        err(e) => { unreachable; } // block conflict on a path that must not conflict
    }
}

// Is `virt`'s leaf currently mapped (valid)? Honors 2 MiB block leaves.
export fn page_table_is_mapped(pt: *PageTable, virt: VAddr) -> bool {
    var table: PAddr = pt.root;
    var level: u32 = 3;
    while level > 0 {
        let pte: u64 = pte_load(table, pte_index(virt, level));
        if (pte & DESC_VALID) == 0 {
            return false;
        }
        if desc_is_leaf(pte, level) {
            return true; // a block leaf at this level covers `virt`
        }
        table = desc_target(pte);
        level = level - 1;
    }
    return (pte_load(table, pte_index(virt, 0)) & DESC_VALID) != 0;
}

// Remove the mapping for `virt` (clear its leaf descriptor). Interior tables are left in
// place. Traps if no valid interior path exists.
export fn page_table_unmap(pt: *mut PageTable, virt: VAddr) -> void {
    var table: PAddr = pt.root;
    var level: u32 = 3;
    while level > 0 {
        let idx: usize = pte_index(virt, level);
        let pte: u64 = pte_load(table, idx);
        if (pte & DESC_VALID) == 0 {
            unreachable; // no mapping to remove
        }
        if desc_is_leaf(pte, level) {
            pte_store(table, idx, 0); // clear the block leaf
            return;
        }
        table = desc_target(pte);
        level = level - 1;
    }
    pte_store(table, pte_index(virt, 0), 0);
}

// The byte offset within a leaf at `level` (0 = 4 KiB page, 1 = 2 MiB block).
fn leaf_offset(virt: VAddr, level: u32) -> usize {
    if level == 1 {
        return va_value(virt) & (BLOCK_2MIB - 1);
    }
    return va_value(virt) & (PAGE_SIZE - 1);
}

// A resolved leaf mapping: the physical address `virt` resolves to, plus the raw leaf
// descriptor so callers can inspect its permission/attribute bits without knowing the encoding.
struct LeafMapping {
    phys: PAddr,
    flags: u64,  // the raw leaf descriptor
}

enum LookupError {
    NotMapped, // no valid leaf descriptor covers `virt`
}

// Resolve `virt` to its leaf mapping without trapping — the building block for permission-
// checked user/kernel access. Returns NotMapped if any level is invalid. Handles 2 MiB block
// leaves at L2 and 4 KiB page leaves at L3.
export fn page_table_lookup(pt: *PageTable, virt: VAddr) -> Result<LeafMapping, LookupError> {
    var table: PAddr = pt.root;
    var level: u32 = 3;
    while level > 0 {
        let pte: u64 = pte_load(table, pte_index(virt, level));
        if (pte & DESC_VALID) == 0 {
            return err(.NotMapped);
        }
        if desc_is_leaf(pte, level) {
            return ok(.{ .phys = pa_offset(desc_target(pte), leaf_offset(virt, level)), .flags = pte });
        }
        table = desc_target(pte);
        level = level - 1;
    }
    let leaf: u64 = pte_load(table, pte_index(virt, 0));
    if (leaf & DESC_VALID) == 0 {
        return err(.NotMapped);
    }
    let offset: usize = va_value(virt) & (PAGE_SIZE - 1);
    return ok(.{ .phys = pa_offset(desc_target(leaf), offset), .flags = leaf });
}

// Permission predicates on a resolved mapping (the descriptor bit encoding stays here).
export fn mapping_phys(m: *LeafMapping) -> PAddr { return m.phys; }
// AArch64 semantics: EL0-accessible (user) iff the low AP bit is set (AP == 0b01 or 0b11).
export fn mapping_is_user(m: *LeafMapping) -> bool { return (m.flags & ATTR_AP_LOW) != 0; }
// Writable iff the high AP bit is clear (AP == 0bx0 => RW; AP == 0bx1 => RO).
export fn mapping_is_writable(m: *LeafMapping) -> bool { return (m.flags & 0x80) == 0; }

// Arch hook for the generic ELF loader (kernel/core/elf_loader.mc): translate a user segment's
// R/W/X intent into stage-1 leaf attributes. An executable segment is EL0-fetchable (UXN clear,
// PXN set so EL1 cannot fetch user pages); a non-executable segment is plain user RW data
// (FLAGS_USER_RW sets UXN). AF/SH/page-type bits are added by page_table_try_map. Both forms use
// EL0 RW (ATTR_AP_URW); the loader's W^X check rejects a W&X segment, so a writable code page
// never occurs. (r is implied: an EL0-accessible page is always readable.)
export fn pte_flags_for_user(r: bool, w: bool, x: bool) -> u64 {
    if x {
        return ATTR_AP_URW | ATTR_PXN; // EL0 R|X (ATTR_ATTRIDX0 is 0; UXN clear => EL0-executable)
    }
    return FLAGS_USER_RW; // EL0 R|W data (UXN set)
}

// Translate `virt` to its mapped physical address (including the page offset). Traps if the
// address is not mapped — callers verify a mapping exists first (or use lookup).
export fn page_table_translate(pt: *PageTable, virt: VAddr) -> PAddr {
    switch page_table_lookup(pt, virt) {
        ok(m) => { return m.phys; }
        err(e) => { unreachable; } // unmapped address on an infallible translate
    }
}
