const std = @import("std");

const ast_bridge = @import("ast_bridge.zig");
const declaration_artifacts = @import("declaration_artifacts.zig");
const eval = @import("eval.zig");
const lower_llvm_model = @import("lower_llvm_model.zig");
const lower_llvm_type = @import("lower_llvm_type.zig");

const PackedBitsInfo = lower_llvm_model.PackedBitsInfo;
const integerBits = lower_llvm_type.integerBits;

pub const MemberCallee = struct {
    base: *ast_bridge.Expr,
    name: ast_bridge.Ident,
};

pub fn memberCallee(call: anytype) ?MemberCallee {
    const member = switch (call.callee.kind) {
        .member => |node| node,
        .grouped => |inner| switch (inner.kind) {
            .member => |node| node,
            else => return null,
        },
        else => return null,
    };
    return .{ .base = member.base, .name = member.name };
}

pub fn assignmentIdent(target: ast_bridge.Expr) ?ast_bridge.Ident {
    return switch (target.kind) {
        .ident => |ident| ident,
        .grouped => |inner| assignmentIdent(inner.*),
        else => null,
    };
}

pub fn derefTarget(target: ast_bridge.Expr) ?ast_bridge.Expr {
    return switch (target.kind) {
        .deref => |inner| inner.*,
        .grouped => |inner| derefTarget(inner.*),
        else => null,
    };
}

pub fn structFieldIndex(struct_decl: ast_bridge.StructDecl, field_name: []const u8) ?usize {
    for (struct_decl.fields, 0..) |field, i| {
        if (std.mem.eql(u8, field.name.text, field_name)) return i;
    }
    return null;
}

pub fn structLiteralField(fields: []const ast_bridge.StructLiteralField, field_name: []const u8) ?ast_bridge.Expr {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name.text, field_name)) return field.value;
    }
    return null;
}

// The slot index of trait method `name` (the vtable lists methods in declaration order).
pub fn traitMethodIndex(trait: declaration_artifacts.TraitDeclArtifact, name: []const u8) ?usize {
    for (trait.facts.methods, 0..) |m, i| {
        if (std.mem.eql(u8, m.name.text, name)) return i;
    }
    return null;
}

// Mirrors sema.traitIsObjectSafe; the backend emits a vtable only for object-safe traits.
pub fn llvmTraitIsObjectSafe(t: declaration_artifacts.TraitDeclArtifact) bool {
    for (t.facts.methods) |m| {
        switch (m.self_mode) {
            .by_ptr, .by_mut_ptr => {},
            else => return false,
        }
        for (m.params) |p| if (p.is_comptime) return false;
    }
    return true;
}

// The mangled `Type__m` free function an impl provides for trait method `name`.
pub fn implMethodMangledLlvm(methods: []const ast_bridge.ImplTraitMethod, name: []const u8) ?[]const u8 {
    for (methods) |m| {
        if (std.mem.eql(u8, m.name.text, name)) return m.mangled;
    }
    return null;
}

pub fn packedBitsMask(bit_index: usize) u64 {
    return @as(u64, 1) << @intCast(bit_index);
}

pub fn packedBitsClearMask(info: PackedBitsInfo, bit_index: usize) ?u64 {
    const bits = integerBits(info.repr) orelse return null;
    if (bits >= 64) return ~packedBitsMask(bit_index);
    return ((@as(u64, 1) << @intCast(bits)) - 1) & ~packedBitsMask(bit_index);
}

pub fn isUninitExpr(expr: ast_bridge.Expr) bool {
    return switch (expr.kind) {
        .uninit_literal => true,
        .grouped => |inner| isUninitExpr(inner.*),
        else => false,
    };
}

pub fn comptimeStructFieldValue(fields: []const eval.ComptimeStructField, name: []const u8) ?eval.ComptimeValue {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field.value;
    }
    return null;
}

pub fn taggedUnionConstructorName(callee: ast_bridge.Expr) ?[]const u8 {
    return switch (callee.kind) {
        .ident => |ident| ident.text,
        .grouped => |inner| taggedUnionConstructorName(inner.*),
        else => null,
    };
}
