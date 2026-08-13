// kernel/core/elf_loader — a real multi-segment ELF64 loader.
//
// Where `elf.mc` is the bounds-checked PARSER (header + program headers, validated
// against the image through std/bytes), this module is the LOADER: it walks every
// PT_LOAD program header and materializes the segment into a fresh address space.
// For each segment it allocates one zeroed frame per covered 4 KiB page, maps it into
// the caller's `PageTable` with the segment's R/W/X permissions (plus PTE_U, since a
// loaded image is user code), then copies the segment's `filesz` file bytes into the
// mapped frames page by page — leaving the bss tail (memsz > filesz) zero by virtue of
// the frames being zeroed at allocation. The ELF entry point is returned on success.
//
// This is the substrate for running an untrusted confined app in its own
// isolated Sv39 space: the loader never trusts a program-header field. Each segment's
// vaddr/memsz is range-checked for overflow and against a sane page-count cap before a
// single frame is touched, and the file-byte source range is validated by the parser's
// `br_validate_len` discipline (reused via the per-page copy below). A hostile or
// malformed image yields a typed `LoadError`, never a wild map or a wild copy.
//
// Per-page copy math (the crux): a segment occupies virtual [vaddr, vaddr+memsz) and
// its file bytes occupy [vaddr, vaddr+filesz) sourced from image [offset, offset+filesz).
// We map the page range [align_down(vaddr), align_up(vaddr+memsz)). For each page we
// intersect the page's VA window with the file-byte window [vaddr, vaddr+filesz): the
// overlap (if any) is copied from image (offset + (overlap_start - vaddr)) into the
// frame at (overlap_start - page_vaddr). Everything outside the overlap — a leading
// gap when vaddr is not page-aligned, and the trailing bss — is already zero in the
// freshly-zeroed frame. This handles the first and last partial pages uniformly.

import "kernel/core/elf.mc";
import "kernel/arch/active/paging.mc"; // arch-selection seam (R0b): --arch picks the paging module
import "kernel/core/heap.mc";
import "std/bytes.mc";
import "std/addr.mc";
import "std/mem.mc";

const PAGE: usize = 4096;

// ELF program-header permission flags (p_flags bits), per the ELF spec.
const PF_X: u32 = 1; // executable
const PF_W: u32 = 2; // writable
const PF_R: u32 = 4; // readable

// Upper bound on the pages a single PT_LOAD segment may cover. A sane image's
// segments are kilobytes-to-megabytes; this caps a hostile memsz that would otherwise
// drive an unbounded map/alloc loop (and also bounds the per-page loop so it is
// provably terminating). 4096 pages = 16 MiB per segment.
const MAX_SEGMENT_PAGES: usize = 4096;
const MAX_LOAD_SEGMENTS: usize = 64;
const MAX_TOTAL_PAGES: usize = 8192;

// Why a load was rejected. A malformed/hostile image maps to one of these instead of
// trapping or mapping wild memory.
enum LoadError {
    BadElf,        // the parser rejected the header / program-header table
    TooManyPages,  // a segment covers more than MAX_SEGMENT_PAGES pages
    NoFrame,       // heap exhausted allocating a page frame or interior page table
    BadSegment,    // a segment's vaddr/memsz/filesz is absurd or overflows
}

// Roll back leaf mappings and their data frames for a page range. Interior page
// tables remain owned by the address space and are reclaimed when that address
// space is destroyed; no ELF payload frame survives a failed load.
fn rollback_pages(pt: *mut PageTable, h: *mut Heap, start: usize, count: usize) -> void {
    var i: usize = 0;
    while i < count {
        let page: VAddr = va(start + i * PAGE);
        let frame: PAddr = page_table_translate(pt, page);
        page_table_unmap(pt, page);
        heap_free(h, frame, PAGE);
        i = i + 1;
    }
}

// Map elf.mc's parse error into our LoadError (every parse failure is a BadElf to the
// loader's caller — the distinction is internal to the parser).
fn from_elf_error(e: ElfError) -> LoadError {
    return .BadElf;
}

// The smaller of two sizes. (Named distinctly from std/core's min/max so this module
// stays self-contained and free of any cross-module top-level name clash.)
fn seg_min(a: usize, b: usize) -> usize {
    if a < b {
        return a;
    }
    return b;
}

// The larger of two sizes.
fn seg_max(a: usize, b: usize) -> usize {
    if a > b {
        return a;
    }
    return b;
}

// Translate a segment's ELF p_flags into arch leaf-PTE permission bits. The ELF->R/W/X
// decoding lives here (arch-neutral); the arch-specific bit translation is the paging
// module's `pte_flags_for_user` hook (resolved per --arch). W^X is enforced separately
// below by rejecting a segment that is both writable and executable.
fn pte_flags_for(p_flags: u32) -> u64 {
    return pte_flags_for_user((p_flags & PF_R) != 0, (p_flags & PF_W) != 0, (p_flags & PF_X) != 0);
}

// Materialize one PT_LOAD segment into `pt`: allocate+zero+map one frame per covered
// page, then copy the file bytes. `elf` is the validated image reader. Returns ok on
// success or a typed LoadError; nothing is mapped past the point of a rejected field.
fn load_segment(elf: *ByteReader, pt: *mut PageTable, h: *mut Heap, p: *ProgramHeader) -> Result<bool, LoadError> {
    let vaddr: u64 = p.vaddr;
    let memsz: u64 = p.memsz;
    let filesz: u64 = p.filesz;
    let offset: u64 = p.offset;

    // filesz must not exceed memsz (the file image cannot be larger than the in-memory
    // image of the segment) — otherwise the "bss tail" math underflows.
    if filesz > memsz {
        return err(.BadSegment);
    }

    // W^X: reject a segment that is BOTH writable and executable. A loaded image's pages must
    // never be writable+executable at once (defense in depth against an agent writing then
    // executing code); a normal toolchain emits distinct R|X / R / R|W segments.
    if (p.flags & PF_W) != 0 && (p.flags & PF_X) != 0 {
        return err(.BadSegment);
    }
    // The admitted user-image profile has no execute-only or write-only pages.
    // Requiring R keeps the three architecture encodings identical.
    if (p.flags & PF_R) == 0 {
        return err(.BadSegment);
    }

    // A zero-size segment maps nothing (a degenerate but legal PT_LOAD); skip it.
    if memsz == 0 {
        return ok(true);
    }

    // Reject a segment whose virtual end wraps the address space. We do the overflow
    // check on u64 BEFORE narrowing to usize so a hostile 64-bit vaddr/memsz cannot
    // wrap silently. (U64_MAX - vaddr) is the room above vaddr; memsz must fit.
    let u64_max: u64 = 0xFFFF_FFFF_FFFF_FFFF;
    if vaddr > u64_max - memsz {
        return err(.BadSegment); // vaddr + memsz wraps
    }
    let vend: u64 = vaddr + memsz;

    // align_up(vend, PAGE) adds (PAGE-1) and would TRAP on overflow for a hostile vend within
    // PAGE-1 of the top of the address space (the vaddr+memsz wrap check above does not cover it).
    // Reject such a segment with BadSegment instead of aborting the loader on untrusted input.
    let page_u64: u64 = PAGE as u64;
    if vend > (0xFFFF_FFFF_FFFF_FFFF as u64) - (page_u64 - 1) {
        return err(.BadSegment); // page-aligned end would overflow the address space
    }

    // Page range covering [vaddr, vaddr+memsz): [seg_start, seg_end) page-aligned.
    let seg_start: usize = align_down(vaddr as usize, PAGE);
    let seg_end: usize = align_up(vend as usize, PAGE);
    let span: usize = seg_end - seg_start;              // multiple of PAGE, > 0
    let page_count: usize = span / PAGE;
    if page_count > MAX_SEGMENT_PAGES {
        return err(.TooManyPages);
    }

    // The file-byte window in virtual terms is [vaddr, vaddr+filesz). Source bytes for a
    // virtual address `v` in that window live at image offset `offset + (v - vaddr)`.
    let file_va_end: usize = (vaddr as usize) + (filesz as usize); // <= vend, no wrap (filesz<=memsz)
    let vaddr_u: usize = vaddr as usize;
    let offset_u: usize = offset as usize;

    // Walk the covered pages. `page_count <= MAX_SEGMENT_PAGES` bounds this loop.
    var pi: usize = 0;
    while pi < page_count {
        let page_vaddr: usize = seg_start + pi * PAGE;

        // Allocate a fresh frame and zero it: the bss tail and any leading/trailing
        // gap within this page are zero by construction, so the copy below need only
        // place the file bytes. The NON-trapping allocator turns heap exhaustion (a
        // hostile image can stay under MAX_SEGMENT_PAGES per segment yet drain the loader
        // heap across segments) into a typed NoFrame rather than a kernel trap.
        var frame: PAddr = uninit;
        switch heap_try_alloc(h, PAGE, PAGE) {
            ok(f) => { frame = f; }
            err(e) => {
                rollback_pages(pt, h, seg_start, pi);
                return err(.NoFrame);
            }
        }
        mem_set(frame, 0, PAGE);

        // Map this page with the NON-trapping variant: a hostile ELF can present PT_LOAD
        // segments whose page ranges OVERLAP (AlreadyMapped / large-page conflict) or
        // exhaust the heap allocating interior tables (OutOfFrames). Neither is a loader
        // bug — convert overlap into BadSegment and exhaustion into NoFrame, never panic.
        switch page_table_try_map(pt, h, va(page_vaddr), frame, pte_flags_for(p.flags)) {
            ok(v) => {}
            err(e) => {
                // The new data frame is not mapped on any error. Return it
                // before rolling back pages installed earlier in this segment.
                heap_free(h, frame, PAGE);
                rollback_pages(pt, h, seg_start, pi);
                switch e {
                    .OutOfFrames => { return err(.NoFrame); }
                    .MisalignedAddress => { return err(.BadSegment); }
                    .AlreadyMapped => { return err(.BadSegment); }
                    .ConflictWithLargePage => { return err(.BadSegment); }
                }
            }
        }

        // Intersect this page's VA window [page_vaddr, page_vaddr+PAGE) with the file-byte
        // window [vaddr, vaddr+filesz). The overlap is the slice to copy into this frame.
        let page_end: usize = page_vaddr + PAGE;
        let copy_start: usize = seg_max(page_vaddr, vaddr_u);
        let copy_end: usize = seg_min(page_end, file_va_end);
        if copy_start < copy_end {
            let n: usize = copy_end - copy_start;
            let src_off: usize = offset_u + (copy_start - vaddr_u); // file offset of these bytes
            let dst_in_page: usize = copy_start - page_vaddr;       // offset within this frame

            // Validate the source range against the image up front (the parser's
            // discipline): a hostile offset/filesz that claims more than the image holds
            // is rejected cleanly before br_copy_to's reads run off the end.
            switch br_validate_len(elf, src_off, n) {
                ok(v) => {}
                err(e) => {
                    rollback_pages(pt, h, seg_start, pi + 1);
                    return err(.BadSegment);
                }
            }

            // We already hold this page's physical frame from the allocation above, so
            // copy the file bytes straight into it — no need to translate the VA back
            // (which would also require a non-mut PageTable borrow).
            br_copy_to(elf, src_off, pa_offset(frame, dst_in_page), n);
        }

        pi = pi + 1;
    }

    return ok(true);
}

// Load a complete ELF image into the page table `pt`, mapping every PT_LOAD segment and
// copying its file bytes (bss left zeroed). Frames and interior page-table pages come
// from `h`. Returns the ELF entry point on success, or a typed LoadError for a
// malformed/hostile image. Payload mappings and frames installed by this call
// are rolled back on error. `expected_machine` binds the image to the active
// architecture (for example EM_RISCV=243), and every non-empty segment must
// remain within the caller's admitted [user_start,user_end) VA window.
#[mc_abi]
export fn elf_load_image_for(image_base: usize, image_len: usize, expected_machine: u16, user_start: usize, user_end: usize, pt: *mut PageTable, h: *mut Heap) -> Result<u64, LoadError> {
    var r: ByteReader = byte_reader(pa(image_base), image_len);

    // Parse + validate the header (and the whole program-header table) up front.
    var hdr: ElfHeader = uninit;
    switch elf_parse_header_for(&r, expected_machine) {
        ok(v) => { hdr = v; }
        err(e) => { return err(from_elf_error(e)); }
    }

    // Plan the complete image before allocating the first payload frame. This
    // establishes aggregate resource bounds and proves the entry lies in an
    // executable PT_LOAD segment.
    let phnum: usize = hdr.phnum as usize;
    let phoff: usize = hdr.phoff as usize;
    let phentsize: usize = hdr.phentsize as usize;
    var load_segments: usize = 0;
    var total_pages: usize = 0;
    var entry_is_executable: bool = false;
    if user_start >= user_end {
        return err(.BadSegment);
    }
    var i: usize = 0;
    while i < phnum {
        var ph: ProgramHeader = elf_program_header(&r, phoff, phentsize, i);
        if ph_is_load(&ph) {
            load_segments = load_segments + 1;
            if load_segments > MAX_LOAD_SEGMENTS {
                return err(.TooManyPages);
            }
            if ph.filesz > ph.memsz {
                return err(.BadSegment);
            }
            if !ph_alignment_valid(&ph) {
                return err(.BadSegment);
            }
            if ph.memsz != 0 {
                if ph.vaddr > 0xFFFF_FFFF_FFFF_FFFF - ph.memsz {
                    return err(.BadSegment);
                }
                let end: u64 = ph.vaddr + ph.memsz;
                if ph.vaddr < (user_start as u64) || end > (user_end as u64) {
                    return err(.BadSegment);
                }
                if end > 0xFFFF_FFFF_FFFF_FFFF - ((PAGE as u64) - 1) {
                    return err(.BadSegment);
                }
                let start_page: usize = align_down(ph.vaddr as usize, PAGE);
                let end_page: usize = align_up(end as usize, PAGE);
                let pages: usize = (end_page - start_page) / PAGE;
                if pages > MAX_SEGMENT_PAGES {
                    return err(.TooManyPages);
                }
                if total_pages > MAX_TOTAL_PAGES - pages {
                    return err(.TooManyPages);
                }
                total_pages = total_pages + pages;
                if (ph.flags & PF_X) != 0 {
                    if hdr.entry >= ph.vaddr && hdr.entry < end {
                        entry_is_executable = true;
                    }
                }
            }
        }
        i = i + 1;
    }
    if !entry_is_executable {
        return err(.BadSegment);
    }

    // Execute the validated plan. load_segment is segment-atomic; if a later
    // segment fails, unwind every earlier successful PT_LOAD.
    i = 0;
    while i < phnum {
        var ph: ProgramHeader = elf_program_header(&r, phoff, phentsize, i);
        if ph_is_load(&ph) {
            switch load_segment(&r, pt, h, &ph) {
                ok(v) => {}
                err(e) => {
                    var j: usize = 0;
                    while j < i {
                        var prior: ProgramHeader = elf_program_header(&r, phoff, phentsize, j);
                        if ph_is_load(&prior) && prior.memsz != 0 {
                            let prior_end: usize = (prior.vaddr + prior.memsz) as usize;
                            let prior_start_page: usize = align_down(prior.vaddr as usize, PAGE);
                            let prior_end_page: usize = align_up(prior_end, PAGE);
                            rollback_pages(pt, h, prior_start_page, (prior_end_page - prior_start_page) / PAGE);
                        }
                        j = j + 1;
                    }
                    return err(e);
                }
            }
        }
        i = i + 1;
    }

    return ok(hdr.entry);
}
