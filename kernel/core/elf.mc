// kernel/core/elf — a bounds-checked ELF64 parser (little-endian, the loader's
// front end). Reads the header and program headers through std/bytes, so a
// truncated or malformed image yields a typed error (or traps on an out-of-bounds
// field) instead of reading wild memory. Returns the entry point and lets the
// caller walk PT_LOAD segments to copy into memory.

import "std/bytes.mc";
import "std/mem.mc";

const EH_SIZE: usize = 64;     // ELF64 header size
const PH_SIZE: usize = 56;     // ELF64 program-header size
const ELFCLASS64: u8 = 2;      // e_ident[EI_CLASS]
const ELFDATA2LSB: u8 = 1;     // e_ident[EI_DATA]
const PT_LOAD: u32 = 1;        // loadable segment

enum ElfError {
    TooSmall,        // buffer shorter than the header
    BadMagic,        // not 0x7F 'E' 'L' 'F'
    UnsupportedClass, // not ELFCLASS64
    UnsupportedData,  // not little-endian
    BadProgramHeaders, // phoff/phnum/phentsize escape the buffer
}

struct ElfHeader {
    entry: u64,
    phoff: u64,
    phnum: u16,
    phentsize: u16,
}

struct ProgramHeader {
    p_type: u32,
    flags: u32,
    offset: u64,
    vaddr: u64,
    filesz: u64,
    memsz: u64,
}

// Parse + validate the ELF64 header (field offsets per the ELF64 spec).
export fn elf_parse_header(r: *ByteReader) -> Result<ElfHeader, ElfError> {
    if br_len(r) < EH_SIZE {
        return err(.TooSmall);
    }
    if br_u8(r, 0) != 0x7F {
        return err(.BadMagic);
    }
    if br_u8(r, 1) != 0x45 {
        return err(.BadMagic); // 'E'
    }
    if br_u8(r, 2) != 0x4C {
        return err(.BadMagic); // 'L'
    }
    if br_u8(r, 3) != 0x46 {
        return err(.BadMagic); // 'F'
    }
    if br_u8(r, 4) != ELFCLASS64 {
        return err(.UnsupportedClass);
    }
    if br_u8(r, 5) != ELFDATA2LSB {
        return err(.UnsupportedData);
    }
    let entry: u64 = br_le64(r, 24);     // e_entry
    let phoff: u64 = br_le64(r, 32);     // e_phoff
    let phentsize: u16 = br_le16(r, 54); // e_phentsize
    let phnum: u16 = br_le16(r, 56);     // e_phnum

    // The program-header table is sized by UNTRUSTED count/entsize fields (e_phnum,
    // e_phentsize) and located by an untrusted offset (e_phoff). P2: validate that the
    // whole claimed table lies within the buffer up front (named check) before any
    // program header is read — a hostile phnum/phentsize/phoff is rejected cleanly here.
    //
    // The aggregate `phnum*phentsize` check ALONE is not enough: `elf_program_header`
    // reads fixed Elf64 fields up to off+48 of each entry with TRAPPING br_le32/br_le64,
    // so a hostile `phentsize < 56` (e.g. 8) would pass the aggregate check yet make the
    // per-entry reads run past the validated region and trap on attacker input. Reject any
    // `phentsize` smaller than the real Elf64 program-header size (PH_SIZE) so every entry
    // is at least as large as the fields the parser reads — then the per-PH reads below
    // can never walk off the validated table.
    if (phentsize as usize) < PH_SIZE {
        return err(.BadProgramHeaders);
    }
    let table_bytes: usize = (phnum as usize) * (phentsize as usize);
    switch br_validate_len(r, phoff as usize, table_bytes) {
        ok(u) => {}
        err(e) => { return err(.BadProgramHeaders); }
    }
    return ok(.{ .entry = entry, .phoff = phoff, .phnum = phnum, .phentsize = phentsize });
}

// Parse the i-th program header. `table_off` = e_phoff, `entsize` = e_phentsize.
export fn elf_program_header(r: *ByteReader, table_off: usize, entsize: usize, i: usize) -> ProgramHeader {
    let off: usize = table_off + i * entsize;
    return .{
        .p_type = br_le32(r, off + 0),
        .flags = br_le32(r, off + 4),
        .offset = br_le64(r, off + 8),
        .vaddr = br_le64(r, off + 16),
        .filesz = br_le64(r, off + 32),
        .memsz = br_le64(r, off + 40),
    };
}

export fn ph_is_load(p: *ProgramHeader) -> bool {
    return p.p_type == PT_LOAD;
}

// Copy a PT_LOAD segment into memory at `dst`: `filesz` bytes from the image, then
// zero-fill the bss tail up to `memsz`.
//
// P2: `p.filesz` and `p.offset` are UNTRUSTED lengths/offsets from the program header
// that drive the source copy. Validate that [offset, offset+filesz) actually lies in
// the image up front (named check) BEFORE the copy — a hostile filesz/offset that
// claims more than the image holds is rejected cleanly (BadProgramHeaders) instead of
// driving br_copy_to's trapping reads off the end. On success returns the number of
// bytes copied from the image (filesz) so the loader can advance; err stops the load.
export fn elf_load_segment(elf: *ByteReader, p: *ProgramHeader, dst: PAddr) -> Result<usize, ElfError> {
    let filesz: usize = p.filesz as usize;
    let memsz: usize = p.memsz as usize;
    let src_off: usize = p.offset as usize;
    switch br_validate_len(elf, src_off, filesz) {
        ok(n) => {}
        err(e) => { return err(.BadProgramHeaders); }
    }
    br_copy_to(elf, src_off, dst, filesz); // image -> dst (read now proven in range)
    if memsz > filesz {
        mem_set(pa_offset(dst, filesz), 0, memsz - filesz); // zero the bss tail
    }
    return ok(filesz);
}
