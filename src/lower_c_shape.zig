//! C backend shape/type metadata helpers.
//!
//! These helpers classify AST type and declaration shapes and build passive
//! backend model records. They do not depend on `CEmitter` state.

const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const eval = @import("eval.zig");
const lower_c_const = @import("lower_c_const.zig");
const lower_c_expr = @import("lower_c_expr.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_op = @import("lower_c_op.zig");
const lower_c_reflect = @import("lower_c_reflect.zig");
const lower_c_type = @import("lower_c_type.zig");

const GlobalInfo = lower_c_model.GlobalInfo;
const MmioField = lower_c_model.MmioField;
const OverlayLayout = lower_c_model.OverlayLayout;
const cType = lower_c_type.cType;
const constArrayLenValue = lower_c_const.constArrayLenValue;
const intLiteralText = lower_c_expr.intLiteralText;
const typeName = ast_query.typeName;
const widthBits = lower_c_op.widthBits;

pub fn globalInfoFromType(ty: ast.TypeExpr) GlobalInfo {
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

pub fn globalArrayElementType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .array => |node| node.child.*,
        .qualified => |node| globalArrayElementType(node.child.*),
        else => null,
    };
}

pub fn globalArrayLenText(ty: ast.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .array => |node| intLiteralText(node.len),
        .qualified => |node| globalArrayLenText(node.child.*),
        else => null,
    };
}

pub fn arrayElementType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .array => |node| node.child.*,
        .qualified => |node| arrayElementType(node.child.*),
        else => null,
    };
}

pub fn resolvedArrayChildType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .array => |node| node.child.*,
        .qualified => |node| switch (node.child.kind) {
            .array => |array_node| array_node.child.*,
            else => null,
        },
        else => null,
    };
}

pub fn sliceElementType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .slice => |node| node.child.*,
        .qualified => |node| sliceElementType(node.child.*),
        else => null,
    };
}

pub fn isPointerLikeGlobalType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .name => |name| std.mem.eql(u8, name.text, "cstr"),
        .pointer, .raw_many_pointer, .slice => true,
        .nullable => |child| isPointerLikeGlobalType(child.*),
        .qualified => |node| isPointerLikeGlobalType(node.child.*),
        else => false,
    };
}

// The `mc_race_load_<T>`/`mc_race_store_<T>` helper family is emitted for exactly
// these scalar spellings (the MC_DEFINE_RACE_SCALAR list in lower_c_runtime.zig).
// Any other non-aggregate, non-pointer-shaped scalar (u128/i128) has no sound
// race-tolerant C lowering, so callers must fail emission closed (spec §I.13)
// instead of naming a helper that does not exist.
pub fn raceScalarHelperExists(race_type_name: []const u8) bool {
    const helpers = [_][]const u8{
        "bool", "u8", "u16", "u32", "u64", "usize", "i8", "i16", "i32", "i64", "isize", "f32", "f64",
    };
    for (helpers) |helper| {
        if (std.mem.eql(u8, race_type_name, helper)) return true;
    }
    return false;
}

pub fn mmioFieldFromType(ty: ast.TypeExpr) ?MmioField {
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

pub fn overlayFieldLayout(
    ty: ast.TypeExpr,
    const_fns: *const std.StringHashMap(ast.FnDecl),
    const_globals: *const std.StringHashMap(eval.ComptimeValue),
    reflect_env: *lower_c_reflect.ReflectEnv,
) ?OverlayLayout {
    switch (ty.kind) {
        .array => |node| {
            const child = overlayFieldLayout(node.child.*, const_fns, const_globals, reflect_env) orelse return null;
            const len = constArrayLenValue(node.len, const_fns, const_globals, lower_c_reflect.comptimeReflectThunk, reflect_env) orelse return null;
            return .{ .size = child.size * len, .alignment = child.alignment };
        },
        .qualified => |node| return overlayFieldLayout(node.child.*, const_fns, const_globals, reflect_env),
        else => {},
    }
    const name = typeName(ty) orelse return null;
    if (std.mem.eql(u8, name, "bool")) return .{ .size = 1, .alignment = 1 };
    if (std.mem.eql(u8, name, "u8") or std.mem.eql(u8, name, "i8")) return .{ .size = 1, .alignment = 1 };
    if (std.mem.eql(u8, name, "u16") or std.mem.eql(u8, name, "i16")) return .{ .size = 2, .alignment = 2 };
    if (std.mem.eql(u8, name, "u32") or std.mem.eql(u8, name, "i32")) return .{ .size = 4, .alignment = 4 };
    if (std.mem.eql(u8, name, "u64") or std.mem.eql(u8, name, "i64")) return .{ .size = 8, .alignment = 8 };
    return null;
}

pub fn resultPayloadTypeForTag(ty: ast.TypeExpr, tag: []const u8) ?ast.TypeExpr {
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

pub fn structFieldType(struct_decl: ast.StructDecl, field_name: []const u8) ?ast.TypeExpr {
    for (struct_decl.fields) |field| {
        if (std.mem.eql(u8, field.name.text, field_name)) return field.ty;
    }
    return null;
}

pub fn genericChildType(ty: ast.TypeExpr, base_name: []const u8) ?ast.TypeExpr {
    return switch (ty.kind) {
        .generic => |node| {
            if (!std.mem.eql(u8, node.base.text, base_name) or node.args.len != 1) return null;
            return node.args[0];
        },
        .qualified => |node| genericChildType(node.child.*, base_name),
        else => null,
    };
}

pub fn atomicPayloadOfType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .pointer => |node| atomicPayloadOfType(node.child.*),
        .qualified => |node| atomicPayloadOfType(node.child.*),
        else => genericChildType(ty, "atomic"),
    };
}

pub fn isVoidLiteralExpr(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .void_literal => true,
        .grouped => |inner| isVoidLiteralExpr(inner.*),
        else => false,
    };
}

pub fn cTraitIsObjectSafe(t: ast.TraitDecl) bool {
    for (t.methods) |m| {
        switch (m.self_mode) {
            .by_ptr, .by_mut_ptr => {},
            else => return false,
        }
        for (m.params) |p| if (p.is_comptime) return false;
    }
    return true;
}

pub fn implMethodMangled(methods: []const ast.ImplTraitMethod, name: []const u8) ?[]const u8 {
    for (methods) |m| {
        if (std.mem.eql(u8, m.name.text, name)) return m.mangled;
    }
    return null;
}
