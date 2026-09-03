//! LLVM backend registry/type lookup helpers.

const std = @import("std");

const ast_bridge = @import("ast_bridge.zig");
const lower_llvm_model = @import("lower_llvm_model.zig");
const type_bridge = @import("type_bridge.zig");

const PackedBitsInfo = lower_llvm_model.PackedBitsInfo;
const OverlayUnionInfo = lower_llvm_model.OverlayUnionInfo;
const TaggedUnionInfo = lower_llvm_model.TaggedUnionInfo;

pub fn structDeclForType(
    type_aliases: *const std.StringHashMap(ast_bridge.TypeExpr),
    struct_types: *const std.StringHashMap(ast_bridge.StructDecl),
    ty: ast_bridge.TypeExpr,
) ?ast_bridge.StructDecl {
    const resolved_ty = type_bridge.resolveAliasType(type_aliases, ty);
    return switch (resolved_ty.kind) {
        .name => |name| struct_types.get(name.text),
        else => null,
    };
}

pub fn packedBitsInfoForType(
    type_aliases: *const std.StringHashMap(ast_bridge.TypeExpr),
    packed_bits: *const std.StringHashMap(PackedBitsInfo),
    ty: ast_bridge.TypeExpr,
) ?PackedBitsInfo {
    const resolved_ty = type_bridge.resolveAliasType(type_aliases, ty);
    return switch (resolved_ty.kind) {
        .name => |name| packed_bits.get(name.text),
        else => null,
    };
}

pub fn overlayInfoForType(
    type_aliases: *const std.StringHashMap(ast_bridge.TypeExpr),
    overlay_unions: *const std.StringHashMap(OverlayUnionInfo),
    ty: ast_bridge.TypeExpr,
) ?OverlayUnionInfo {
    const resolved_ty = type_bridge.resolveAliasType(type_aliases, ty);
    return switch (resolved_ty.kind) {
        .name => |name| overlay_unions.get(name.text),
        else => null,
    };
}

pub fn taggedUnionForType(
    type_aliases: *const std.StringHashMap(ast_bridge.TypeExpr),
    tagged_unions: *const std.StringHashMap(TaggedUnionInfo),
    ty: ast_bridge.TypeExpr,
) ?ast_bridge.UnionDecl {
    const resolved_ty = type_bridge.resolveAliasType(type_aliases, ty);
    return switch (resolved_ty.kind) {
        .name => |name| if (tagged_unions.get(name.text)) |info| info.decl else null,
        else => null,
    };
}

pub fn enumDeclForType(
    type_aliases: *const std.StringHashMap(ast_bridge.TypeExpr),
    enum_types: *const std.StringHashMap(ast_bridge.EnumDecl),
    ty: ast_bridge.TypeExpr,
) ?ast_bridge.EnumDecl {
    const resolved_ty = type_bridge.resolveAliasType(type_aliases, ty);
    return switch (resolved_ty.kind) {
        .name => |name| enum_types.get(name.text),
        else => null,
    };
}

pub fn memberBaseStructType(type_aliases: *const std.StringHashMap(ast_bridge.TypeExpr), ty: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
    const resolved_ty = type_bridge.resolveAliasType(type_aliases, ty);
    return switch (resolved_ty.kind) {
        .pointer => |node| node.child.*,
        .generic => |node| if (std.mem.eql(u8, node.base.text, "MmioPtr") and node.args.len == 1) node.args[0] else ty,
        else => ty,
    };
}

pub fn memberBaseStructDecl(
    type_aliases: *const std.StringHashMap(ast_bridge.TypeExpr),
    struct_types: *const std.StringHashMap(ast_bridge.StructDecl),
    ty: ast_bridge.TypeExpr,
) ?ast_bridge.StructDecl {
    const struct_ty = memberBaseStructType(type_aliases, ty) orelse return null;
    return structDeclForType(type_aliases, struct_types, struct_ty);
}

pub fn taggedUnionCaseIndex(union_decl: ast_bridge.UnionDecl, case_name: []const u8) ?usize {
    for (union_decl.cases, 0..) |case, i| {
        if (std.mem.eql(u8, case.name.text, case_name)) return i;
    }
    return null;
}

pub fn packedBitsFieldIndex(info: PackedBitsInfo, field_name: []const u8) ?usize {
    for (info.fields, 0..) |field, i| {
        if (std.mem.eql(u8, field.name.text, field_name)) return i;
    }
    return null;
}
