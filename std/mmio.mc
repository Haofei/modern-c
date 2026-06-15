// MC standard library — `mmio`: register bit-field helpers and ordered IO-memory
// copy, layered on top of the language's typed MMIO (`Reg`/`RegBits`/`MmioPtr` and
// the `fence`/`cpu` intrinsics — spec §17, §28.6).
//
// The typed `Reg<u32, .read_write>` gives a driver an ordered, width-correct
// read()/write() of *one* register. What it does not give is the bit arithmetic in
// between: a driver that wants to flip one field of a control register still hand-
// rolls `(v & ~(MASK << SHIFT)) | (x << SHIFT)`, and every such open-coded shift is
// a place to invert a mask or shift by the wrong amount. This module names that
// arithmetic once — a `RegField` is a `(shift, width)` slice of a 32-bit register,
// and `reg_field_get/_set` extract or replace it with the mask built (and bounds-
// checked) in exactly one place. The field helpers are pure `const fn`s, so they
// also fold at comptime: a field built from constant `(shift, width)` is verified
// at compile time.
//
// `mmio_*_block` / `mmio_*32` are the IO-memory copy: a byte/word burst between CPU
// memory and a device window with the ordering fence on the correct side (release
// before writes become visible to the device, acquire after reads complete), so a
// driver does not pair a raw loop with an easy-to-forget barrier.

import "std/math.mc";
import "std/addr.mc";

// ===== register bit-fields (pure; fold at comptime) =========================

// A contiguous field occupying bits [shift, shift+width) of a 32-bit register.
struct RegField {
    shift: u32,
    width: u32,
}

// Build a field, trapping on a nonsensical geometry (so a bad `(shift, width)` is a
// comptime error when the arguments are constant, not a silent wrong mask).
export const fn reg_field(shift: u32, width: u32) -> RegField {
    if width == 0 {
        unreachable; // a zero-width field selects no bits
    }
    if shift >= 32 {
        unreachable; // shift past the top of a 32-bit register
    }
    if (shift + width) > 32 {
        unreachable; // field runs past bit 31
    }
    return .{ .shift = shift, .width = width };
}

// The all-ones value for a `width`-bit field, before it is shifted into place.
// width==32 is handled by the wrapping subtract (1<<32 wraps to 0, 0-1 -> 0xFFFFFFFF)
// rather than trapping on the checked `0 - 1`.
const fn field_value_mask(width: u32) -> u32 {
    return wrapping_sub_u32(wrapping_shl_u32(1, width), 1);
}

// The field's mask positioned in the register (1s over [shift, shift+width)).
export const fn reg_field_mask(f: RegField) -> u32 {
    return wrapping_shl_u32(field_value_mask(f.width), f.shift);
}

// Extract `f`'s value from a register word (right-justified).
export const fn reg_field_get(reg: u32, f: RegField) -> u32 {
    return (reg >> f.shift) & field_value_mask(f.width);
}

// Return `reg` with field `f` replaced by `value` (value is masked to the field
// width, so an over-wide value cannot bleed into a neighbouring field).
export const fn reg_field_set(reg: u32, f: RegField, value: u32) -> u32 {
    let cleared: u32 = reg & (~reg_field_mask(f));
    let placed: u32 = wrapping_shl_u32(value & field_value_mask(f.width), f.shift);
    return cleared | placed;
}

// ----- single-bit convenience (bit `n`, 0..31) -----

export const fn reg_bit(n: u32) -> u32 {
    if n >= 32 {
        unreachable;
    }
    return wrapping_shl_u32(1, n);
}

export const fn reg_bit_set(reg: u32, n: u32) -> u32 {
    return reg | reg_bit(n);
}

export const fn reg_bit_clear(reg: u32, n: u32) -> u32 {
    return reg & (~reg_bit(n));
}

export const fn reg_bit_toggle(reg: u32, n: u32) -> u32 {
    return reg ^ reg_bit(n);
}

export const fn reg_bit_test(reg: u32, n: u32) -> bool {
    return (reg & reg_bit(n)) != 0;
}

// ===== IO-memory copy (ordered; runtime) ====================================
//
// `dst`/`src` are physical addresses; the raw load/store is the single `unsafe`
// site. The fence is on the side that makes the burst ordered with respect to the
// surrounding code: a *write* to a device must be preceded by a release fence so
// every prior CPU store is visible first; a *read* from a device must be followed
// by an acquire fence so later loads observe the data the burst brought in.

// Copy `len` bytes from CPU memory `src` into device window `dst`.
export fn mmio_write_block(dst: PAddr, src: PAddr, len: usize) -> void {
    fence.release();
    var i: usize = 0;
    while i < len {
        unsafe {
            let b: u8 = raw.load<u8>(pa_offset(src, i));
            raw.store<u8>(pa_offset(dst, i), b);
        }
        i = i + 1;
    }
}

// Copy `len` bytes from device window `src` into CPU memory `dst`.
export fn mmio_read_block(dst: PAddr, src: PAddr, len: usize) -> void {
    var i: usize = 0;
    while i < len {
        unsafe {
            let b: u8 = raw.load<u8>(pa_offset(src, i));
            raw.store<u8>(pa_offset(dst, i), b);
        }
        i = i + 1;
    }
    fence.acquire();
}

// Single ordered 32-bit register store/load at a computed address — for a register
// bank reached by offset (where a static `mmio struct` layout does not fit).
export fn mmio_write32(reg: PAddr, value: u32) -> void {
    fence.release();
    unsafe {
        raw.store<u32>(reg, value);
    }
}

export fn mmio_read32(reg: PAddr) -> u32 {
    var value: u32 = 0;
    unsafe {
        value = raw.load<u32>(reg);
    }
    fence.acquire();
    return value;
}

// Read-modify-write one field of a 32-bit register bank slot, ordered on both
// edges — the read/modify/write a driver does to flip a control field.
export fn mmio_modify_field(reg: PAddr, f: RegField, value: u32) -> void {
    let current: u32 = mmio_read32(reg);
    mmio_write32(reg, reg_field_set(current, f, value));
}
