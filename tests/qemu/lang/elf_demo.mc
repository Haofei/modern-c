// Test wrappers around the ELF parser for the host driver: parse a byte buffer and
// return a single scalar (entry / error code / segment vaddr) so the C side can
// assert without decoding the Result/struct ABI.

import "kernel/core/elf.mc";
import "std/addr.mc";

fn err_ordinal(e: ElfError) -> u32 {
    switch e {
        .TooSmall => {
            return 0;
        }
        .BadMagic => {
            return 1;
        }
        .UnsupportedClass => {
            return 2;
        }
        .UnsupportedData => {
            return 3;
        }
        .BadProgramHeaders => {
            return 4;
        }
    }
}

export fn elf_entry(base: usize, len: usize) -> u64 {
    var r: ByteReader = byte_reader(pa(base), len);
    switch elf_parse_header(&r) {
        ok(h) => {
            return h.entry;
        }
        err(e) => {
            return 0;
        }
    }
}

// 999 if the header parses, else the error's ordinal.
export fn elf_error_code(base: usize, len: usize) -> u32 {
    var r: ByteReader = byte_reader(pa(base), len);
    switch elf_parse_header(&r) {
        ok(h) => {
            return 999;
        }
        err(e) => {
            return err_ordinal(e);
        }
    }
}

// The vaddr of the i-th program header, or 0 if the header doesn't parse.
export fn elf_seg_vaddr(base: usize, len: usize, i: usize) -> u64 {
    var r: ByteReader = byte_reader(pa(base), len);
    switch elf_parse_header(&r) {
        ok(h) => {
            var ph: ProgramHeader = elf_program_header(&r, h.phoff as usize, h.phentsize as usize, i);
            return ph.vaddr;
        }
        err(e) => {
            return 0;
        }
    }
}

// Load the first PT_LOAD segment to `dst` and return its filesz (0 if none / bad).
export fn elf_load_first(base: usize, len: usize, dst: usize) -> u64 {
    var r: ByteReader = byte_reader(pa(base), len);
    switch elf_parse_header(&r) {
        ok(h) => {
            var i: u16 = 0;
            while i < h.phnum {
                var ph: ProgramHeader = elf_program_header(&r, h.phoff as usize, h.phentsize as usize, i as usize);
                if ph_is_load(&ph) {
                    switch elf_load_segment(&r, &ph, pa(dst)) {
                        ok(u) => { return ph.filesz; }
                        err(e) => { return 0; }
                    }
                }
                i = i + 1;
            }
            return 0;
        }
        err(e) => {
            return 0;
        }
    }
}

// Whether the i-th program header is a PT_LOAD segment (1/0).
export fn elf_seg_is_load(base: usize, len: usize, i: usize) -> u32 {
    var r: ByteReader = byte_reader(pa(base), len);
    switch elf_parse_header(&r) {
        ok(h) => {
            var ph: ProgramHeader = elf_program_header(&r, h.phoff as usize, h.phentsize as usize, i);
            if ph_is_load(&ph) {
                return 1;
            }
            return 0;
        }
        err(e) => {
            return 0;
        }
    }
}
