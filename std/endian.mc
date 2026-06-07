// MC standard library — `endian`: byte-order conversion (section 28.3). Device
// registers and on-wire packet headers have a fixed endianness; the host may
// differ. These are pure `const fn`s (comptime-foldable, linkable) — explicit
// conversions, never an implicit reinterpret.

export const fn swap_u16(x: u16) -> u16 {
    return ((x & 0x00FF) << 8) | ((x >> 8) & 0x00FF);
}

export const fn swap_u32(x: u32) -> u32 {
    return ((x & 0x0000_00FF) << 24)
         | ((x & 0x0000_FF00) << 8)
         | ((x >> 8) & 0x0000_FF00)
         | ((x >> 24) & 0x0000_00FF);
}

export const fn swap_u64(x: u64) -> u64 {
    return ((x & 0x0000_0000_0000_00FF) << 56)
         | ((x & 0x0000_0000_0000_FF00) << 40)
         | ((x & 0x0000_0000_00FF_0000) << 24)
         | ((x & 0x0000_0000_FF00_0000) << 8)
         | ((x >> 8) & 0x0000_0000_FF00_0000)
         | ((x >> 24) & 0x0000_0000_00FF_0000)
         | ((x >> 40) & 0x0000_0000_0000_FF00)
         | ((x >> 56) & 0x0000_0000_0000_00FF);
}

// Host ↔ explicit-endian conversions. v0 assumes a little-endian host (x86,
// riscv64, aarch64 LE — the usual MC targets): big-endian (network order) is a
// swap, little-endian is identity. (A `__BYTE_ORDER__`-aware variant is a
// follow-on for big-endian hosts.)

export const fn to_be16(x: u16) -> u16 { return swap_u16(x); }
export const fn from_be16(x: u16) -> u16 { return swap_u16(x); }
export const fn to_be32(x: u32) -> u32 { return swap_u32(x); }
export const fn from_be32(x: u32) -> u32 { return swap_u32(x); }
export const fn to_be64(x: u64) -> u64 { return swap_u64(x); }
export const fn from_be64(x: u64) -> u64 { return swap_u64(x); }

export const fn to_le16(x: u16) -> u16 { return x; }
export const fn from_le16(x: u16) -> u16 { return x; }
export const fn to_le32(x: u32) -> u32 { return x; }
export const fn from_le32(x: u32) -> u32 { return x; }
export const fn to_le64(x: u64) -> u64 { return x; }
export const fn from_le64(x: u64) -> u64 { return x; }
