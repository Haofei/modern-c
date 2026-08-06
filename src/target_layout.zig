const std = @import("std");

/// Modern C v0's admitted codegen targets are all 64-bit little-endian.
///
/// This is an explicit target-data contract, not a portable-target abstraction:
/// adding a 32-bit or big-endian backend must extend this file first and then
/// thread the selected layout through eval, layout, MIR, and both backends.
pub const endian: std.builtin.Endian = .little;
pub const pointer_width_bits: u16 = 64;
pub const pointer_width_bytes: u32 = pointer_width_bits / 8;

pub fn pointerSizedIntegerBits(name: []const u8) ?u16 {
    if (std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "isize")) return pointer_width_bits;
    return null;
}

pub fn pointerSizedScalarBytes(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "usize") or
        std.mem.eql(u8, name, "isize") or
        std.mem.eql(u8, name, "PAddr") or
        std.mem.eql(u8, name, "VAddr") or
        std.mem.eql(u8, name, "DmaAddr"))
    {
        return pointer_width_bytes;
    }
    return null;
}

test "target layout contract is the v0 64-bit little-endian target set" {
    try std.testing.expectEqual(std.builtin.Endian.little, endian);
    try std.testing.expectEqual(@as(u16, 64), pointer_width_bits);
    try std.testing.expectEqual(@as(u32, 8), pointer_width_bytes);
    try std.testing.expectEqual(@as(?u16, 64), pointerSizedIntegerBits("usize"));
    try std.testing.expectEqual(@as(?u16, 64), pointerSizedIntegerBits("isize"));
    try std.testing.expectEqual(@as(?u32, 8), pointerSizedScalarBytes("PAddr"));
    try std.testing.expect(pointerSizedIntegerBits("u32") == null);
    try std.testing.expect(pointerSizedScalarBytes("u32") == null);
}
