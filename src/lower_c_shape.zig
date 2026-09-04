//! C backend shape/type metadata helpers.
//!
//! These helpers classify AST type and declaration shapes and build passive
//! backend model records. They do not depend on `CEmitter` state.

const std = @import("std");

const ast_bridge = @import("ast_bridge.zig");
const lower_c_const = @import("lower_c_const.zig");
const lower_c_expr = @import("lower_c_expr.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_op = @import("lower_c_op.zig");
const lower_c_type = @import("lower_c_type.zig");
const type_bridge = @import("type_bridge.zig");

const GlobalInfo = lower_c_model.GlobalInfo;
const MmioField = lower_c_model.MmioField;
const cType = lower_c_type.cType;
const intLiteralText = lower_c_expr.intLiteralText;
const typeName = type_bridge.typeName;
const widthBits = lower_c_op.widthBits;
const TypeExpr = ast_bridge.TypeExpr;

pub fn globalInfoFromType(ty: ast_bridge.TypeExpr) GlobalInfo {
    const name = typeName(ty) orelse "unknown";
    if (globalArrayElementType(ty)) |element_ty| {
        const element_name = typeName(element_ty) orelse "unknown";
        return .{
            .type_name = name,
            .c_type = cType(ty),
            .race_type_name = name,
            .race_c_type = cType(ty),
            .width_bits = widthBits(name),
            .pointer_like = false,
            .aggregate = true,
            .source_ty = ty,
            .array_element_info = .{
                .source_ty = element_ty,
                .c_type = cType(element_ty),
                .race_type_name = element_name,
                .race_c_type = cType(element_ty),
                .aggregate = element_ty.kind == .array,
            },
            .array_len = globalArrayLenText(ty),
        };
    }
    return .{
        .type_name = name,
        .c_type = cType(ty),
        .race_type_name = name,
        .race_c_type = cType(ty),
        .width_bits = widthBits(name),
        .pointer_like = isPointerLikeGlobalType(ty),
        .source_ty = ty,
    };
}

pub fn globalArrayElementType(ty: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
    return switch (ty.kind) {
        .array => |node| node.child.*,
        .qualified => |node| globalArrayElementType(node.child.*),
        else => null,
    };
}

pub fn globalArrayLenText(ty: ast_bridge.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .array => |node| intLiteralText(node.len),
        .qualified => |node| globalArrayLenText(node.child.*),
        else => null,
    };
}

pub fn arrayElementType(ty: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
    return switch (ty.kind) {
        .array => |node| node.child.*,
        .qualified => |node| arrayElementType(node.child.*),
        else => null,
    };
}

pub fn resolvedArrayChildType(ty: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
    return switch (ty.kind) {
        .array => |node| node.child.*,
        .qualified => |node| switch (node.child.kind) {
            .array => |array_node| array_node.child.*,
            else => null,
        },
        else => null,
    };
}

pub fn sliceElementType(ty: ast_bridge.TypeExpr) ?ast_bridge.TypeExpr {
    return switch (ty.kind) {
        .slice => |node| node.child.*,
        .qualified => |node| sliceElementType(node.child.*),
        else => null,
    };
}

pub fn isPointerLikeGlobalType(ty: ast_bridge.TypeExpr) bool {
    return switch (ty.kind) {
        .name => |name| std.mem.eql(u8, name.text, "cstr"),
        .pointer, .raw_many_pointer, .slice => true,
        .nullable => |child| isPointerLikeGlobalType(child.*),
        .qualified => |node| isPointerLikeGlobalType(node.child.*),
        else => false,
    };
}

// C target-policy matrix for the `mc_race_load_<T>`/`mc_race_store_<T>` family.
// Both runtime emission and lowering eligibility consume this list. It is a
// target capability, not a source-level semantic fact: types not listed here
// (currently u128/i128) must fail C emission closed under spec §I.13.
pub const RaceScalarHelper = struct {
    name: []const u8,
    c_type: []const u8,
};

pub const race_scalar_helpers = [_]RaceScalarHelper{
    .{ .name = "bool", .c_type = "bool" },
    .{ .name = "u8", .c_type = "uint8_t" },
    .{ .name = "u16", .c_type = "uint16_t" },
    .{ .name = "u32", .c_type = "uint32_t" },
    .{ .name = "u64", .c_type = "uint64_t" },
    .{ .name = "usize", .c_type = "uintptr_t" },
    .{ .name = "i8", .c_type = "int8_t" },
    .{ .name = "i16", .c_type = "int16_t" },
    .{ .name = "i32", .c_type = "int32_t" },
    .{ .name = "i64", .c_type = "int64_t" },
    .{ .name = "isize", .c_type = "intptr_t" },
    .{ .name = "f32", .c_type = "float" },
    .{ .name = "f64", .c_type = "double" },
};

pub fn raceScalarHelperExists(race_type_name: []const u8) bool {
    for (race_scalar_helpers) |helper| {
        if (std.mem.eql(u8, race_type_name, helper.name)) return true;
    }
    return false;
}

test "race scalar helper target policy is finite and fail closed" {
    for (race_scalar_helpers) |helper| {
        try std.testing.expect(raceScalarHelperExists(helper.name));
        try std.testing.expect(helper.c_type.len != 0);
    }
    try std.testing.expect(!raceScalarHelperExists("u128"));
    try std.testing.expect(!raceScalarHelperExists("i128"));
}

pub fn mmioFieldFromType(ty: ast_bridge.TypeExpr) ?MmioField {
    const generic = switch (ty.kind) {
        .generic => |node| node,
        else => return null,
    };
    if (std.mem.eql(u8, generic.base.text, "Reg")) {
        if (generic.args.len == 0) return null;
        const width = typeName(generic.args[0]) orelse "unknown";
        return .{ .value_type = width, .width = width };
    }
    if (std.mem.eql(u8, generic.base.text, "RegBits")) {
        if (generic.args.len == 0) return null;
        const width = typeName(generic.args[0]) orelse "unknown";
        const value_type = if (generic.args.len > 1) typeName(generic.args[1]) orelse width else width;
        return .{ .value_type = value_type, .width = width };
    }
    return null;
}

pub fn resultPayloadTypeForTag(ty: ast_bridge.TypeExpr, tag: []const u8) ?ast_bridge.TypeExpr {
    return switch (ty.kind) {
        .generic => |node| {
            if (!std.mem.eql(u8, node.base.text, "Result") or node.args.len != 2) return null;
            if (std.mem.eql(u8, tag, "ok")) return node.args[0];
            if (std.mem.eql(u8, tag, "err")) return node.args[1];
            return null;
        },
        .qualified => |node| resultPayloadTypeForTag(node.child.*, tag),
        else => null,
    };
}

pub fn structFieldType(struct_decl: ast_bridge.StructDecl, field_name: []const u8) ?ast_bridge.TypeExpr {
    for (struct_decl.fields) |field| {
        if (std.mem.eql(u8, field.name.text, field_name)) return field.ty;
    }
    return null;
}

pub fn genericChildType(ty: TypeExpr, base_name: []const u8) ?TypeExpr {
    return switch (ty.kind) {
        .generic => |node| {
            if (!std.mem.eql(u8, node.base.text, base_name) or node.args.len != 1) return null;
            return node.args[0];
        },
        .qualified => |node| genericChildType(node.child.*, base_name),
        else => null,
    };
}

pub fn atomicPayloadOfType(ty: TypeExpr) ?TypeExpr {
    return atomicPayloadOfTypeDepth(ty, false);
}

fn atomicPayloadOfTypeDepth(ty: TypeExpr, saw_pointer: bool) ?TypeExpr {
    return switch (ty.kind) {
        .pointer => |node| if (saw_pointer) null else atomicPayloadOfTypeDepth(node.child.*, true),
        .qualified => |node| atomicPayloadOfTypeDepth(node.child.*, saw_pointer),
        else => genericChildType(ty, "atomic"),
    };
}

pub fn isVoidLiteralExpr(expr: ast_bridge.Expr) bool {
    return switch (expr.kind) {
        .void_literal => true,
        .grouped => |inner| isVoidLiteralExpr(inner.*),
        else => false,
    };
}
