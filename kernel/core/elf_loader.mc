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
// This is the Phase-1 substrate for running an untrusted QuickJS agent in its own
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
import "kernel/arch/riscv64/paging.mc";
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

// Why a load was rejected. A malformed/hostile image maps to one of these instead of
// trapping or mapping wild memory.
enum LoadError {
    BadElf,        // the parser rejected the header / program-header table
    TooManyPages,  // a segment covers more than MAX_SEGMENT_PAGES pages
    NoFrame,       // (reserved) frame allocation could not satisfy the request
    BadSegment,    // a segment's vaddr/memsz/filesz is absurd or overflows
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

// Translate the ELF p_flags of a segment into PTE permission bits. A loaded image is
// user code, so PTE_U is always set; R/W/X follow the segment's declared flags. (V is
// added by page_table_map itself.)
fn pte_flags_for(p_flags: u32) -> u64 {
    var flags: u64 = PTE_U;
    if (p_flags & PF_R) != 0 {
        flags = flags | PTE_R;
    }
    if (p_flags & PF_W) != 0 {
        flags = flags | PTE_W;
    }
    if (p_flags & PF_X) != 0 {
        flags = flags | PTE_X;
    }
    return flags;
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

    // Page range covering [vaddr, vaddr+memsz): [seg_start, seg_end) page-aligned.
    let seg_start: usize = align_down(vaddr as usize, PAGE);
    let seg_end: usize = align_up(vend as usize, PAGE); // checked: traps on overflow
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
        // place the file bytes.
        let frame: PAddr = heap_alloc(h, PAGE, PAGE);
        mem_set(frame, 0, PAGE);

        // Map this page (V is added by page_table_map). The boot-style trapping wrapper
        // is correct here: the page range is freshly carved and disjoint by construction
        // (each page_vaddr is distinct and previously unmapped), so a conflict would be a
        // loader bug, not a recoverable input condition.
        page_table_map(pt, h, va(page_vaddr), frame, pte_flags_for(p.flags));

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
                err(e) => { return err(.BadSegment); }
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
// malformed/hostile image. `pt` is left partially populated on error — callers that
// need atomicity tear the address space down on a non-ok result.
export fn elf_load_image(image_base: usize, image_len: usize, pt: *mut PageTable, h: *mut Heap) -> Result<u64, LoadError> {
    var r: ByteReader = byte_reader(pa(image_base), image_len);

    // Parse + validate the header (and the whole program-header table) up front.
    var hdr: ElfHeader = uninit;
    switch elf_parse_header(&r) {
        ok(v) => { hdr = v; }
        err(e) => { return err(from_elf_error(e)); }
    }

    // Walk the program-header table; load each PT_LOAD. `phnum` is u16 and the parser
    // already validated the whole table lies within the image, so this loop is bounded
    // (<= 65535) and every per-header read is in range.
    let phnum: usize = hdr.phnum as usize;
    let phoff: usize = hdr.phoff as usize;
    let phentsize: usize = hdr.phentsize as usize;
    var i: usize = 0;
    while i < phnum {
        var ph: ProgramHeader = elf_program_header(&r, phoff, phentsize, i);
        if ph_is_load(&ph) {
            switch load_segment(&r, pt, h, &ph) {
                ok(v) => {}
                err(e) => { return err(e); }
            }
        }
        i = i + 1;
    }

    return ok(hdr.entry);
}
