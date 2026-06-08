// kernel/core/dynlink — the core of dynamic/PIE loading: applying relocations. For each
// R_RISCV_RELATIVE entry the loader patches a slot in the loaded image to (load_base +
// addend), so a position-independent image works at whatever base it was placed. (Symbol
// resolution / PLT-GOT for shared objects layer on top of this relocation pass.)

import "std/addr.mc";

// Apply `n` RELATIVE relocations: image[off[i]] = base + addend[i].
export fn apply_relative(image: PAddr, base: u64, off: PAddr, addend: PAddr, n: usize) -> void {
    var i: usize = 0;
    while i < n {
        var o: u64 = 0;
        var a: u64 = 0;
        unsafe {
            o = raw.load<u64>(pa_offset(off, i * 8));
            a = raw.load<u64>(pa_offset(addend, i * 8));
        }
        unsafe {
            raw.store<u64>(pa_offset(image, o as usize), base + a);
        }
        i = i + 1;
    }
}
