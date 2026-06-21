// kernel/core/elf_loader_aarch64 — the AArch64 sibling of kernel/core/elf_loader_x86.mc.
//
// Byte-for-byte the same multi-segment ELF64 loader, except it imports the AArch64 paging
// module and translates ELF p_flags into AArch64 stage-1 leaf attributes instead of x86/RISC-V
// PTE bits. On AArch64 a user leaf carries an AP field (EL0 RW), an AttrIndx (Normal WB), and
// the execute-never bits UXN/PXN. The paging module exports `FLAGS_USER_RW` (EL0 RW data, UXN
// set => EL0 cannot execute); for an executable segment we need UXN CLEAR (EL0 may fetch) so we
// build a dedicated user-code flag here (AP=EL0-RW, AttrIndx0, PXN set, UXN clear). W^X is still
// enforced structurally by rejecting a segment that is both writable and executable in the ELF.
//
// Why a copy rather than swapping the import in elf_loader.mc / _x86.mc: those files hardcode a
// different arch's paging import (different leaf-bit encodings) and feed their own kernel build.
// emit-c flattens per binary, so the aarch64 kernel includes only this aarch64-paging loader —
// riscv/x86 untouched.

import "kernel/core/elf.mc";
import "kernel/arch/aarch64/paging.mc";
import "kernel/core/heap.mc";
import "std/bytes.mc";
import "std/addr.mc";
import "std/mem.mc";

const ELA_PAGE: usize = 4096;

// ELF program-header permission flags (p_flags bits), per the ELF spec.
const ELA_PF_X: u32 = 1; // executable
const ELA_PF_W: u32 = 2; // writable
const ELA_PF_R: u32 = 4; // readable

// AArch64 user-code leaf attributes: EL0 RW (AP=0b01), Normal WB (AttrIndx0), PXN set (EL1 must
// not execute user pages), UXN CLEAR (EL0 may fetch). FLAGS_USER_RW sets UXN, so a writable data
// segment uses it directly; an executable segment uses this code flag. AF + inner-shareable +
// page type bits are added by page_table_try_map itself.
const ELA_ATTR_AP_URW: u64 = 0x40;               // bits 7:6 = 0b01 — EL1 RW, EL0 RW
const ELA_ATTR_PXN: u64 = 0x0020_0000_0000_0000; // bit 53 — privileged execute-never
const ELA_FLAGS_USER_CODE: u64 = ELA_ATTR_AP_URW | ELA_ATTR_PXN; // UXN clear => EL0-executable

// Upper bound on the pages a single PT_LOAD segment may cover (16 MiB), bounding a hostile
// memsz and making the per-page loop provably terminating.
const ELA_MAX_SEGMENT_PAGES: usize = 4096;

enum LoadError {
    BadElf,
    TooManyPages,
    NoFrame,
    BadSegment,
}

fn ela_from_elf_error(e: ElfError) -> LoadError {
    return .BadElf;
}

fn ela_min(a: usize, b: usize) -> usize {
    if a < b {
        return a;
    }
    return b;
}

fn ela_max(a: usize, b: usize) -> usize {
    if a > b {
        return a;
    }
    return b;
}

// Translate ELF p_flags into AArch64 user leaf attributes. An executable segment is EL0-fetchable
// (UXN clear); a non-executable segment is plain user RW data (UXN set, via FLAGS_USER_RW). AF /
// SH / page-type bits are added by page_table_try_map.
fn ela_leaf_flags_for(p_flags: u32) -> u64 {
    if (p_flags & ELA_PF_X) != 0 {
        return ELA_FLAGS_USER_CODE; // EL0 R|X (W^X already rejects W|X below)
    }
    return FLAGS_USER_RW; // EL0 R|W data
}

// Materialize one PT_LOAD segment into `pt`.
fn ela_load_segment(elf: *ByteReader, pt: *mut PageTable, h: *mut Heap, p: *ProgramHeader) -> Result<bool, LoadError> {
    let vaddr: u64 = p.vaddr;
    let memsz: u64 = p.memsz;
    let filesz: u64 = p.filesz;
    let offset: u64 = p.offset;

    if filesz > memsz {
        return err(.BadSegment);
    }

    // W^X: reject a segment that is BOTH writable and executable in the ELF.
    if (p.flags & ELA_PF_W) != 0 && (p.flags & ELA_PF_X) != 0 {
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

    let seg_start: usize = align_down(vaddr as usize, ELA_PAGE);
    let seg_end: usize = align_up(vend as usize, ELA_PAGE);
    let span: usize = seg_end - seg_start;
    let page_count: usize = span / ELA_PAGE;
    if page_count > ELA_MAX_SEGMENT_PAGES {
        return err(.TooManyPages);
    }

    let file_va_end: usize = (vaddr as usize) + (filesz as usize);
    let vaddr_u: usize = vaddr as usize;
    let offset_u: usize = offset as usize;

    var pi: usize = 0;
    while pi < page_count {
        let page_vaddr: usize = seg_start + pi * ELA_PAGE;

        var frame: PAddr = uninit;
        switch heap_try_alloc(h, ELA_PAGE, ELA_PAGE) {
            ok(f) => { frame = f; }
            err(e) => { return err(.NoFrame); }
        }
        mem_set(frame, 0, ELA_PAGE);

        switch page_table_try_map(pt, h, va(page_vaddr), frame, ela_leaf_flags_for(p.flags)) {
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

        let page_end: usize = page_vaddr + ELA_PAGE;
        let copy_start: usize = ela_max(page_vaddr, vaddr_u);
        let copy_end: usize = ela_min(page_end, file_va_end);
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
export fn elf_load_image_aarch64(image_base: usize, image_len: usize, pt: *mut PageTable, h: *mut Heap) -> Result<u64, LoadError> {
    var r: ByteReader = byte_reader(pa(image_base), image_len);

    var hdr: ElfHeader = uninit;
    switch elf_parse_header(&r) {
        ok(v) => { hdr = v; }
        err(e) => { return err(ela_from_elf_error(e)); }
    }

    let phnum: usize = hdr.phnum as usize;
    let phoff: usize = hdr.phoff as usize;
    let phentsize: usize = hdr.phentsize as usize;
    var i: usize = 0;
    while i < phnum {
        var ph: ProgramHeader = elf_program_header(&r, phoff, phentsize, i);
        if ph_is_load(&ph) {
            switch ela_load_segment(&r, pt, h, &ph) {
                ok(v) => {}
                err(e) => { return err(e); }
            }
        }
        i = i + 1;
    }

    return ok(hdr.entry);
}
