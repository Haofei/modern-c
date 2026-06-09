// MC standard library — `mask`: a 32-bit set (`Mask32`) with checked bit operations.
// Privilege allow-lists, kernel-call masks, pending-signal sets, and IRQ-enable masks are
// all 32-bit masks; this concentrates the `1 << bit` shifts in one place (bounds-checked,
// so an out-of-range bit is a no-op rather than undefined behavior) and names the intent.

import "std/math.mc";

struct Mask32 {
    bits: u32,
}

export fn mask32_zero() -> Mask32 {
    return .{ .bits = 0 };
}
export fn mask32_from(bits: u32) -> Mask32 {
    return .{ .bits = bits };
}
export fn mask32_raw(m: *mut Mask32) -> u32 {
    return m.bits;
}

// Set / clear / test bit `b` (0..31). An out-of-range bit is ignored.
export fn mask32_set(m: *mut Mask32, b: u32) -> void {
    if b < 32 {
        m.bits = m.bits | wrapping_shl_u32(1, b);
    }
}
export fn mask32_clear(m: *mut Mask32, b: u32) -> void {
    if b < 32 {
        m.bits = m.bits & (~wrapping_shl_u32(1, b));
    }
}
export fn mask32_contains(m: *mut Mask32, b: u32) -> bool {
    if b >= 32 {
        return false;
    }
    return (m.bits & wrapping_shl_u32(1, b)) != 0;
}

export fn mask32_is_empty(m: *mut Mask32) -> bool {
    return m.bits == 0;
}

// Remove and return the lowest set bit's index, or 32 if the set is empty.
export fn mask32_take_first(m: *mut Mask32) -> u32 {
    var b: u32 = 0;
    while b < 32 {
        if (m.bits & wrapping_shl_u32(1, b)) != 0 {
            m.bits = m.bits & (~wrapping_shl_u32(1, b));
            return b;
        }
        b = b + 1;
    }
    return 32;
}
