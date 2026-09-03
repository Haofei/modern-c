//! Syntax-free mechanics for module-owned callable signature types.
//!
//! This deliberately operates on `SignatureTypeTable` only.  It is shared by
//! backend admission/rendering and must never reconstruct an AST TypeExpr.

const std = @import("std");
const mir = @import("mir_model.zig");

pub const Error = error{ InvalidSignatureType, UnsupportedSignatureType };

pub fn shape(table: mir.SignatureTypeTable, id: mir.SignatureTypeId) Error!mir.TypeShape {
    return table.get(id) orelse error.InvalidSignatureType;
}

pub fn isVoid(table: mir.SignatureTypeTable, id: mir.SignatureTypeId) Error!bool {
    return switch (try shape(table, id)) {
        .name => |name| std.mem.eql(u8, name, "void") or std.mem.eql(u8, name, "never"),
        .qualified => |node| isVoid(table, node.child),
        else => false,
    };
}

/// Returns a nominal type spelling after transparent qualifiers.  This is
/// intentionally narrow: generic aliases and projections are not names.
pub fn nominalName(table: mir.SignatureTypeTable, id: mir.SignatureTypeId) Error!?[]const u8 {
    return switch (try shape(table, id)) {
        .name => |name| name,
        .enum_literal => |name| name,
        .qualified => |node| nominalName(table, node.child),
        else => null,
    };
}

test "signature mechanics rejects invalid type ids" {
    const shapes = [_]mir.TypeShape{ .{ .name = "u32" }, .{ .dyn_trait = .{ .mutability = .none, .trait_name = "T" } } };
    const table = mir.SignatureTypeTable{ .shapes = &shapes };
    try std.testing.expectError(error.InvalidSignatureType, isVoid(table, .invalid));
}
