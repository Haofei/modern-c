// Load-and-run: the kernel parses an in-memory ELF64, loads its PT_LOAD segment,
// and returns the user entry address; the runtime then drops to U-mode there. The
// loaded program reaches the kernel only through the syscall table (reused from the
// syscall demo).

import "tests/qemu/lang/syscall_demo.mc";
import "kernel/core/elf.mc";
import "std/addr.mc";

// Parse `elf`, load its first PT_LOAD segment to `dst`, and return the entry's
// physical address (dst adjusted by entry - vaddr). 0 if the image is invalid.
export fn elf_load_run(elf_base: usize, elf_len: usize, dst: usize) -> u64 {
    var r: ByteReader = byte_reader(pa(elf_base), elf_len);
    switch elf_parse_header(&r) {
        ok(h) => {
            var i: u16 = 0;
            while i < h.phnum {
                var ph: ProgramHeader = elf_program_header(&r, h.phoff as usize, h.phentsize as usize, i as usize);
                if ph_is_load(&ph) {
                    switch elf_load_segment(&r, &ph, pa(dst)) {
                        ok(u) => { return (dst as u64) + (h.entry - ph.vaddr); }
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
