// Scalar type layout — the size and alignment of MC's fixed-width builtin types.
//
// The same name→{size, alignment} table was copied into sema.zig, mir.zig, lower_c.zig, and
// lower_llvm.zig (the checker sizes types, the MIR optimizer reasons about them, both backends
// emit them). One definition keeps every pass agreeing on how wide each type is — a divergence
// here would mean the front-end and a backend disagree on a struct's layout.

const std = @import("std");

/// Size and (natural) alignment in bytes. For the scalar builtins these are equal.
pub const ScalarLayout = struct { size: u32, alignment: u32 };

/// The comptime-computed layout of a struct: its total size and alignment, plus the byte
/// offset of a particular field when one was requested. Both backends compute this identically.
pub const ComptimeStructLayout = struct {
    size: i128,
    alignment: i128,
    field_offset: ?i128,
};

/// The layout of a scalar builtin type named `name`, or null if `name` is not one. Opaque
/// address classes (`PAddr`/`VAddr`/`DmaAddr`) lower to pointer-width integers.
pub fn scalarLayout(name: []const u8) ?ScalarLayout {
    const table = [_]struct { n: []const u8, s: u32 }{
        .{ .n = "u8", .s = 1 },    .{ .n = "i8", .s = 1 },    .{ .n = "bool", .s = 1 },
        .{ .n = "u16", .s = 2 },   .{ .n = "i16", .s = 2 },   .{ .n = "u32", .s = 4 },
        .{ .n = "i32", .s = 4 },   .{ .n = "f32", .s = 4 },   .{ .n = "u64", .s = 8 },
        .{ .n = "i64", .s = 8 },   .{ .n = "f64", .s = 8 },   .{ .n = "usize", .s = 8 },
        .{ .n = "isize", .s = 8 }, .{ .n = "PAddr", .s = 8 }, .{ .n = "VAddr", .s = 8 },
        .{ .n = "DmaAddr", .s = 8 },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, name, entry.n)) return .{ .size = entry.s, .alignment = entry.s };
    }
    return null;
}
