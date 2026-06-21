// kernel/core/elf_loader_x86 — the x86-64 sibling of kernel/core/elf_loader.mc.
//
// Byte-for-byte the same multi-segment ELF64 loader, except it imports the x86-64 paging
// module and translates ELF p_flags into x86 PTE bits instead of RISC-V ones. On x86 a leaf
// PTE has no separate R/X permission bits: a present, user-accessible page (PTE_US) is
// readable and — unless NX is set, which boot.S does not enable — executable. Writability is
// the one extra bit (PTE_W). So:
//   - PTE_US is always set (a loaded image is user code);
//   - PF_W -> PTE_W;
//   - PF_R / PF_X contribute nothing extra (read + execute come for free with a present US page).
// W^X is still enforced structurally by rejecting a segment that is both writable and
// executable in the ELF (a normal toolchain emits distinct R|X / R / R|W segments).
//
// Why a copy rather than swapping the import in elf_loader.mc: that file hardcodes the riscv
// paging import (PTE_R/W/X/U bit values that differ from x86) and feeds the riscv kernel
// build. emit-c flattens per binary, so the x86 kernel includes only this x86-paging loader.

import "kernel/core/elf.mc";
import "kernel/arch/x86_64/paging.mc";
import "kernel/core/heap.mc";
import "std/bytes.mc";
import "std/addr.mc";
import "std/mem.mc";

const ELX_PAGE: usize = 4096;

// ELF program-header permission flags (p_flags bits), per the ELF spec.
const ELX_PF_X: u32 = 1; // executable
const ELX_PF_W: u32 = 2; // writable
const ELX_PF_R: u32 = 4; // readable

// Upper bound on the pages a single PT_LOAD segment may cover (16 MiB), bounding a hostile
// memsz and making the per-page loop provably terminating.
const ELX_MAX_SEGMENT_PAGES: usize = 4096;

enum LoadError {
    BadElf,
    TooManyPages,
    NoFrame,
    BadSegment,
}

fn elx_from_elf_error(e: ElfError) -> LoadError {
    return .BadElf;
}

fn elx_min(a: usize, b: usize) -> usize {
    if a < b {
        return a;
    }
    return b;
}

fn elx_max(a: usize, b: usize) -> usize {
    if a > b {
        return a;
    }
    return b;
}

// Translate ELF p_flags into x86 leaf-PTE bits. PTE_US is always set (loaded image = user
// code); PTE_W follows PF_W. Read/execute are implicit for a present US page (no NX). PTE_P
// is added by page_table_try_map itself.
fn elx_pte_flags_for(p_flags: u32) -> u64 {
    var flags: u64 = PTE_US;
    if (p_flags & ELX_PF_W) != 0 {
        flags = flags | PTE_W;
    }
    return flags;
}

// Materialize one PT_LOAD segment into `pt`.
fn elx_load_segment(elf: *ByteReader, pt: *mut PageTable, h: *mut Heap, p: *ProgramHeader) -> Result<bool, LoadError> {
    let vaddr: u64 = p.vaddr;
    let memsz: u64 = p.memsz;
    let filesz: u64 = p.filesz;
    let offset: u64 = p.offset;

    if filesz > memsz {
        return err(.BadSegment);
    }

    // W^X: reject a segment that is BOTH writable and executable in the ELF.
    if (p.flags & ELX_PF_W) != 0 && (p.flags & ELX_PF_X) != 0 {
        return err(.BadSegment);
    }

    if memsz == 0 {
        return ok(true);
    }

    let u64_max: u64 = 0xFFFF_FFFF_FFFF_FFFF;
    if vaddr > u64_max - memsz {
        return err(.BadSegment);
    }
    let vend: u64 = vaddr + memsz;

    let seg_start: usize = align_down(vaddr as usize, ELX_PAGE);
    let seg_end: usize = align_up(vend as usize, ELX_PAGE);
    let span: usize = seg_end - seg_start;
    let page_count: usize = span / ELX_PAGE;
    if page_count > ELX_MAX_SEGMENT_PAGES {
        return err(.TooManyPages);
    }

    let file_va_end: usize = (vaddr as usize) + (filesz as usize);
    let vaddr_u: usize = vaddr as usize;
    let offset_u: usize = offset as usize;

    var pi: usize = 0;
    while pi < page_count {
        let page_vaddr: usize = seg_start + pi * ELX_PAGE;

        var frame: PAddr = uninit;
        switch heap_try_alloc(h, ELX_PAGE, ELX_PAGE) {
            ok(f) => { frame = f; }
            err(e) => { return err(.NoFrame); }
        }
        mem_set(frame, 0, ELX_PAGE);

        switch page_table_try_map(pt, h, va(page_vaddr), frame, elx_pte_flags_for(p.flags)) {
            ok(v) => {}
            err(e) => {
                switch e {
                    .OutOfFrames => { return err(.NoFrame); }
                    .MisalignedAddress => { return err(.BadSegment); }
                    .AlreadyMapped => { return err(.BadSegment); }
                    .ConflictWithLargePage => { return err(.BadSegment); }
                }
            }
        }

        let page_end: usize = page_vaddr + ELX_PAGE;
        let copy_start: usize = elx_max(page_vaddr, vaddr_u);
        let copy_end: usize = elx_min(page_end, file_va_end);
        if copy_start < copy_end {
            let n: usize = copy_end - copy_start;
            let src_off: usize = offset_u + (copy_start - vaddr_u);
            let dst_in_page: usize = copy_start - page_vaddr;

            switch br_validate_len(elf, src_off, n) {
                ok(v) => {}
                err(e) => { return err(.BadSegment); }
            }

            br_copy_to(elf, src_off, pa_offset(frame, dst_in_page), n);
        }

        pi = pi + 1;
    }

    return ok(true);
}

// Load a complete ELF image into the page table `pt`. Returns the ELF entry point on success
// or a typed LoadError. `pt` is left partially populated on error.
export fn elf_load_image_x86(image_base: usize, image_len: usize, pt: *mut PageTable, h: *mut Heap) -> Result<u64, LoadError> {
    var r: ByteReader = byte_reader(pa(image_base), image_len);

    var hdr: ElfHeader = uninit;
    switch elf_parse_header(&r) {
        ok(v) => { hdr = v; }
        err(e) => { return err(elx_from_elf_error(e)); }
    }

    let phnum: usize = hdr.phnum as usize;
    let phoff: usize = hdr.phoff as usize;
    let phentsize: usize = hdr.phentsize as usize;
    var i: usize = 0;
    while i < phnum {
        var ph: ProgramHeader = elf_program_header(&r, phoff, phentsize, i);
        if ph_is_load(&ph) {
            switch elx_load_segment(&r, pt, h, &ph) {
                ok(v) => {}
                err(e) => { return err(e); }
            }
        }
        i = i + 1;
    }

    return ok(hdr.entry);
}
