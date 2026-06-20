// Differential-coverage fixture: explicit `@offset(N)` MMIO register layouts, observed via
// comptime `sizeof`/`field_offset` folded into a host-runnable u32 — the exact construct class
// behind the latent `comptimeStructLayout` (src/layout.zig) C/LLVM divergence. MMIO structs are
// not host-runnable (volatile loads to fixed addresses), so the layout is observed PURELY through
// comptime folding, which both backends must compute identically.
//
// Edge cases covered:
//   - tightly-packed adjacent fields (offset == running offset, the boundary the guard allows),
//   - large gaps (reserved padding to a far offset),
//   - mixed widths (u8/u16/u32) so alignment-forwarding participates.

extern mmio struct OffTight {
    a: Reg<u32, .read_write> @offset(0x000),
    b: Reg<u8, .read> @offset(0x004),
    c: Reg<u8, .write> @offset(0x005),
    d: Reg<u16, .read_write> @offset(0x006),
}

extern mmio struct OffGapped {
    id: Reg<u32, .read> @offset(0x000),
    ctrl: Reg<u32, .read_write> @offset(0x010),
    status: Reg<u32, .read> @offset(0x070),
    doorbell: Reg<u32, .write> @offset(0x100),
}

extern mmio struct OffMixed {
    lo: Reg<u8, .read_write> @offset(0x000),
    mid: Reg<u16, .read> @offset(0x002),
    hi: Reg<u32, .read_write> @offset(0x008),
}

// Each observer is a comptime fold; XOR them into one u32 and check it against the
// known-correct layout snapshot. Both backends must fold the @offset/sizeof layout
// identically (the comptimeStructLayout divergence this guards), so a mismatch on
// EITHER backend — or any future layout regression — makes entry() return 0. Returns
// 1 iff the layout is exactly as declared (self-verifying host-harness entry).
const OFFSET_LAYOUT_SNAPSHOT: u64 = 0xDD4;

export fn entry() -> u32 {
    var acc: u64 = 0;
    acc = (acc ^ (sizeof(OffTight) as u64));
    acc = (acc ^ ((field_offset(OffTight, .d) as u64) << 1));
    acc = (acc ^ ((sizeof(OffGapped) as u64) << 2));
    acc = (acc ^ ((field_offset(OffGapped, .doorbell) as u64) << 3));
    acc = (acc ^ ((sizeof(OffMixed) as u64) << 4));
    acc = (acc ^ ((field_offset(OffMixed, .hi) as u64) << 5));
    if (acc & 0xFFFFFFFF) != OFFSET_LAYOUT_SNAPSHOT { return 0; }
    return 1;
}
