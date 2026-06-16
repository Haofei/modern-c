// UB class: strict aliasing (accessing an object through an incompatible-type lvalue).
// MC handling: DEFINED AWAY at emit for reinterpretation — `bitcast<T>` lowers to a
// `__builtin_memcpy` reinterpret (mc_bitcast_memcpy), never a type-punned pointer
// dereference, so there is no aliasing UB regardless of the optimizer.  The one place MC
// does cast `uintptr_t -> volatile T*` is the raw hardware-register path (raw.load/store,
// MMIO); that relies on the `-fno-strict-aliasing` emit flag (see docs/c-ub-matrix.md),
// demonstrated here by a round-trip through a real backing word.
import "std/addr.mc";
import "std/mmio.mc";

global g_word: [1]u32;

export fn ub_strict_aliasing_run() -> u32 {
    var pass: u32 = 1;

    // (a) bitcast reinterpret: f32 bits <-> u32, via memcpy (no aliasing UB).
    let bits: u32 = bitcast<u32>(1.5 as f32);
    if bits != 0x3FC00000 { pass = 0; }            // IEEE-754 single for 1.5
    let back: f32 = bitcast<f32>(bits);
    if (back as f64) != 1.5 { pass = 0; }

    // (b) raw MMIO round-trip through a typed address: store u32, read u32 back.
    // Lowers to a `volatile uint32_t *` cast from uintptr_t — alias-safe under
    // -fno-strict-aliasing (the flag this row pins down).
    g_word[0] = 0;
    let reg: PAddr = pa((&g_word[0]) as usize);
    mmio_write32(reg, 0xDEADBEEF);
    if mmio_read32(reg) != 0xDEADBEEF { pass = 0; }

    return pass;
}
