// QEMU-mode test for kernel/core/elf_loader: construct a SYNTHETIC multi-segment
// ELF64 image in a global buffer, load it into a real Sv39 page table backed by a
// global pool, and assert the loader did the right thing — entry point, per-segment
// page mappings, faithful text bytes read back through the mapping, and a zeroed bss
// tail in the data segment.
//
// Imports paging.mc (sfence.vma in the active-edit helpers won't assemble for the
// host), so this is wired as a QEMU gate, not a host test. The page-table walk used
// here is in software (no satp), so the load + the readbacks exercise the real mapping
// logic under QEMU without needing the MMU active.
//
// The synthetic image (all little-endian, field offsets per elf.mc / the ELF64 spec):
//   ELF header  @0   (64 bytes): magic, class=64, data=LSB, e_entry, e_phoff=64,
//                                 e_phentsize=56, e_phnum=2
//   PH[0] "text" @64 (56 bytes): PT_LOAD, R|X, offset=0x1000, vaddr=0x10000,
//                                 filesz=memsz=16
//   PH[1] "data" @120(56 bytes): PT_LOAD, R|W, offset=0x2000, vaddr=0x12000,
//                                 filesz=8, memsz=16  (8-byte bss tail)
//   text bytes  @0x1000 (16 bytes of known content)
//   data bytes  @0x2000 (8 bytes of known content)
// ELF invariant honored: offset % PAGE == vaddr % PAGE (both 0) for each segment.

import "kernel/core/elf_loader.mc";
import "kernel/arch/riscv64/paging.mc";
import "kernel/core/heap.mc";
import "std/bytes.mc";
import "std/addr.mc";

// Distinct names from elf_loader.mc / elf.mc top-level consts (the import graph is
// flattened into one namespace, so `PAGE`/`PT_LOAD`/`PF_*` would collide).
const TPAGE: usize = 4096;

const TEXT_VADDR: usize = 0x10000;
const TEXT_OFF: usize = 0x1000;
const TEXT_SZ: usize = 16;

const DATA_VADDR: usize = 0x12000;
const DATA_OFF: usize = 0x2000;
const DATA_FILESZ: usize = 8;
const DATA_MEMSZ: usize = 16;

const ENTRY: u64 = 0x10000;

const T_PT_LOAD: u32 = 1;
const T_PF_X: u32 = 1;
const T_PF_W: u32 = 2;
const T_PF_R: u32 = 4;

// The synthetic ELF image. Big enough to hold the header, the PH table, and the two
// segment payloads at their page-aligned file offsets (data ends at 0x2008).
const IMAGE_CAP: usize = 0x3000;
global g_image: [IMAGE_CAP]u8;

// The backing store for the page table (root + interior tables) and the per-page leaf
// frames the loader allocates (two segments span 1 page each here, plus a few interior
// table frames). 256 KiB is ample.
global g_pool: [262144]u8;

// ----- little-endian writers into the global image buffer -----

fn img_u8(off: usize, v: u8) -> void {
    g_image[off] = v;
}

fn img_u16(off: usize, v: u16) -> void {
    img_u8(off + 0, (v & 0x00FF) as u8);
    img_u8(off + 1, ((v >> 8) & 0x00FF) as u8);
}

fn img_u32(off: usize, v: u32) -> void {
    img_u8(off + 0, (v & 0x0000_00FF) as u8);
    img_u8(off + 1, ((v >> 8) & 0x0000_00FF) as u8);
    img_u8(off + 2, ((v >> 16) & 0x0000_00FF) as u8);
    img_u8(off + 3, ((v >> 24) & 0x0000_00FF) as u8);
}

fn img_u64(off: usize, v: u64) -> void {
    img_u32(off + 0, (v & 0xFFFF_FFFF) as u32);
    img_u32(off + 4, ((v >> 32) & 0xFFFF_FFFF) as u32);
}

// Write one ELF64 program header (56 bytes) at `off`.
fn img_phdr(off: usize, p_type: u32, flags: u32, offset: u64, vaddr: u64, filesz: u64, memsz: u64) -> void {
    img_u32(off + 0, p_type);   // p_type
    img_u32(off + 4, flags);    // p_flags
    img_u64(off + 8, offset);   // p_offset
    img_u64(off + 16, vaddr);   // p_vaddr
    img_u64(off + 24, vaddr);   // p_paddr (unused by the loader; mirror vaddr)
    img_u64(off + 32, filesz);  // p_filesz
    img_u64(off + 40, memsz);   // p_memsz
    img_u64(off + 48, TPAGE as u64); // p_align (informational)
}

// Build the whole synthetic image into g_image.
fn build_image() -> void {
    // Zero the buffer first (so unspecified header bytes / gaps are well-defined and the
    // data segment's source bytes past filesz don't matter).
    var i: usize = 0;
    while i < IMAGE_CAP {
        g_image[i] = 0;
        i = i + 1;
    }

    // --- ELF64 header @0 ---
    img_u8(0, 0x7F);
    img_u8(1, 0x45); // 'E'
    img_u8(2, 0x4C); // 'L'
    img_u8(3, 0x46); // 'F'
    img_u8(4, 2);    // EI_CLASS = ELFCLASS64
    img_u8(5, 1);    // EI_DATA  = ELFDATA2LSB
    img_u8(6, 1);    // EI_VERSION
    img_u64(24, ENTRY);     // e_entry
    img_u64(32, 64);        // e_phoff (PH table right after the 64-byte header)
    img_u16(54, 56);        // e_phentsize (ELF64 program-header size)
    img_u16(56, 2);         // e_phnum

    // --- program headers @64 ---
    img_phdr(64, T_PT_LOAD, T_PF_R | T_PF_X, TEXT_OFF as u64, TEXT_VADDR as u64, TEXT_SZ as u64, TEXT_SZ as u64);
    img_phdr(120, T_PT_LOAD, T_PF_R | T_PF_W, DATA_OFF as u64, DATA_VADDR as u64, DATA_FILESZ as u64, DATA_MEMSZ as u64);

    // --- text payload @0x1000: bytes 0xA0, 0xA1, ... ---
    var t: usize = 0;
    while t < TEXT_SZ {
        g_image[TEXT_OFF + t] = (0xA0 + (t as u8));
        t = t + 1;
    }

    // --- data payload @0x2000: first DATA_FILESZ bytes nonzero; the rest is bss ---
    var d: usize = 0;
    while d < DATA_FILESZ {
        g_image[DATA_OFF + d] = (0xD0 + (d as u8));
        d = d + 1;
    }
}

// Build a HOSTILE image whose two PT_LOAD segments OVERLAP (both map page 0x10000): PH[0] is
// the same text segment, PH[1] claims the SAME vaddr. Each header is individually well-formed,
// so this exercises the loader's per-page map specifically — the second segment's page is already
// mapped. The loader must reject this (BadSegment) rather than panic via the trapping mapper.
fn build_overlap_image() -> void {
    var i: usize = 0;
    while i < IMAGE_CAP {
        g_image[i] = 0;
        i = i + 1;
    }

    // ELF64 header @0 (identical to the valid image).
    img_u8(0, 0x7F);
    img_u8(1, 0x45);
    img_u8(2, 0x4C);
    img_u8(3, 0x46);
    img_u8(4, 2);
    img_u8(5, 1);
    img_u8(6, 1);
    img_u64(24, ENTRY);
    img_u64(32, 64);
    img_u16(54, 56);
    img_u16(56, 2);

    // PH[0]: text @vaddr 0x10000. PH[1]: data claiming the SAME vaddr 0x10000 (the overlap).
    img_phdr(64, T_PT_LOAD, T_PF_R | T_PF_X, TEXT_OFF as u64, TEXT_VADDR as u64, TEXT_SZ as u64, TEXT_SZ as u64);
    img_phdr(120, T_PT_LOAD, T_PF_R | T_PF_W, DATA_OFF as u64, TEXT_VADDR as u64, DATA_FILESZ as u64, DATA_MEMSZ as u64);

    var t: usize = 0;
    while t < TEXT_SZ {
        g_image[TEXT_OFF + t] = (0xA0 + (t as u8));
        t = t + 1;
    }
    var d: usize = 0;
    while d < DATA_FILESZ {
        g_image[DATA_OFF + d] = (0xD0 + (d as u8));
        d = d + 1;
    }
}

// Read a byte from a mapped VA by translating through the page table to its frame.
fn read_va(pt: *PageTable, vaddr: usize) -> u8 {
    let phys: PAddr = page_table_translate(pt, va(vaddr));
    var b: u8 = 0;
    unsafe {
        b = raw.load<u8>(phys);
    }
    return b;
}

export fn elf_loader_run() -> u32 {
    build_image();

    var pass: u32 = 1;

    var heap: Heap = heap_new(phys_range(pa((&g_pool[0]) as usize), 262144));
    var pt: PageTable = page_table_new(&heap);

    let image_base: usize = (&g_image[0]) as usize;

    // Load the image.
    var entry: u64 = 0;
    switch elf_load_image(image_base, IMAGE_CAP, &pt, &heap) {
        ok(e) => { entry = e; }
        err(e) => { return 0; } // load failed outright
    }

    // (a) entry point matches the ELF header.
    if entry != ENTRY {
        pass = 0;
    }

    // (b) each segment's covering page is mapped.
    if !page_table_is_mapped(&pt, va(TEXT_VADDR)) {
        pass = 0;
    }
    if !page_table_is_mapped(&pt, va(DATA_VADDR)) {
        pass = 0;
    }

    // (c) the text bytes read back correctly through the mapping.
    var t: usize = 0;
    while t < TEXT_SZ {
        if read_va(&pt, TEXT_VADDR + t) != (0xA0 + (t as u8)) {
            pass = 0;
        }
        t = t + 1;
    }

    // (d) the data segment's file bytes read back, and its bss tail [filesz, memsz) is
    //     zero (the loader maps a fresh zeroed frame and copies only filesz bytes).
    var d: usize = 0;
    while d < DATA_FILESZ {
        if read_va(&pt, DATA_VADDR + d) != (0xD0 + (d as u8)) {
            pass = 0;
        }
        d = d + 1;
    }
    var b: usize = DATA_FILESZ;
    while b < DATA_MEMSZ {
        if read_va(&pt, DATA_VADDR + b) != 0 {
            pass = 0;
        }
        b = b + 1;
    }

    // (e) permission divergence: read the leaf PTEs and confirm the text page is
    //     executable (and not writable) while the data page is writable (and not
    //     executable) — the loader honored each segment's p_flags.
    switch page_table_lookup(&pt, va(TEXT_VADDR)) {
        ok(m) => {
            if !mapping_is_user(&m) { pass = 0; }
            if mapping_is_writable(&m) { pass = 0; } // text is R|X, not writable
        }
        err(e) => { pass = 0; }
    }
    switch page_table_lookup(&pt, va(DATA_VADDR)) {
        ok(m) => {
            if !mapping_is_user(&m) { pass = 0; }
            if !mapping_is_writable(&m) { pass = 0; } // data is R|W
        }
        err(e) => { pass = 0; }
    }

    // (f) HOSTILE-INPUT regression (review finding 5): a malformed ELF with OVERLAPPING PT_LOAD
    //     segments must be REJECTED cleanly (the loader uses the non-trapping mapper and converts
    //     the AlreadyMapped conflict into BadSegment) — it must NOT panic the kernel. A fresh
    //     page table over the same pool; loading must fail (err), and we must reach this line.
    build_overlap_image();
    var heap2: Heap = heap_new(phys_range(pa((&g_pool[0]) as usize), 262144));
    var pt2: PageTable = page_table_new(&heap2);
    switch elf_load_image((&g_image[0]) as usize, IMAGE_CAP, &pt2, &heap2) {
        ok(e) => { pass = 0; } // overlapping segments must NOT load successfully
        err(e) => {} // rejected (BadSegment) without panicking — correct
    }

    return pass;
}
