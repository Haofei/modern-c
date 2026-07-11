const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const eval = @import("eval.zig");
const lower_llvm_model = @import("lower_llvm_model.zig");
const lower_llvm_type = @import("lower_llvm_type.zig");

const PackedBitsInfo = lower_llvm_model.PackedBitsInfo;
const integerBits = lower_llvm_type.integerBits;
const simpleType = lower_llvm_type.simpleType;

pub const MemberCallee = struct {
    base: *ast.Expr,
    name: ast.Ident,
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

pub fn assignmentIdent(target: ast.Expr) ?ast.Ident {
    return switch (target.kind) {
        .ident => |ident| ident,
        .grouped => |inner| assignmentIdent(inner.*),
        else => null,
    };
}

pub fn derefTarget(target: ast.Expr) ?ast.Expr {
    return switch (target.kind) {
        .deref => |inner| inner.*,
        .grouped => |inner| derefTarget(inner.*),
        else => null,
    };
}

pub fn structFieldIndex(struct_decl: ast.StructDecl, field_name: []const u8) ?usize {
    for (struct_decl.fields, 0..) |field, i| {
        if (std.mem.eql(u8, field.name.text, field_name)) return i;
    }
    return null;
}

pub fn structLiteralField(fields: []const ast.StructLiteralField, field_name: []const u8) ?ast.Expr {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name.text, field_name)) return field.value;
    }
    return null;
}

// The slot index of trait method `name` (the vtable lists methods in declaration order).
pub fn traitMethodIndex(trait: ast.TraitDecl, name: []const u8) ?usize {
    for (trait.methods, 0..) |m, i| {
        if (std.mem.eql(u8, m.name.text, name)) return i;
    }
    return null;
}

// Mirrors sema.traitIsObjectSafe; the backend emits a vtable only for object-safe traits.
pub fn llvmTraitIsObjectSafe(t: ast.TraitDecl) bool {
    for (t.methods) |m| {
        switch (m.self_mode) {
            .by_ptr, .by_mut_ptr => {},
            else => return false,
        }
        for (m.params) |p| if (p.is_comptime) return false;
    }
    return true;
}

// The mangled `Type__m` free function an impl provides for trait method `name`.
pub fn implMethodMangledLlvm(methods: []const ast.ImplTraitMethod, name: []const u8) ?[]const u8 {
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

pub fn builtinCallReturnType(call: anytype) ?ast.TypeExpr {
    if (isPhysCall(call.callee.*) and call.type_args.len == 0 and call.args.len == 1) return simpleType(call.callee.*.span, "PAddr");
    if (isAssumeNoaliasCall(call)) return null;
    if (ast_query.rawLoadCallReturnType(call)) |ty| return ty;
    if (ast_query.rawPtrCallReturnType(call)) |ty| return ty;
    return null;
}

pub fn isDeclassifyCall(call: anytype) bool {
    const name = switch (call.callee.kind) {
        .ident => |ident| ident.text,
        .grouped => |inner| switch (inner.kind) {
            .ident => |ident| ident.text,
            else => return false,
        },
        else => return false,
    };
    return std.mem.eql(u8, name, "declassify") or std.mem.eql(u8, name, "reveal");
}

pub fn isAssumeNoaliasCall(call: anytype) bool {
    if (call.type_args.len != 0 or call.args.len != 2) return false;
    return isAssumeNoaliasCallee(call.callee.*);
}

fn isAssumeNoaliasCallee(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |member| std.mem.eql(u8, member.name.text, "assume_noalias_unchecked") and ast_query.isIdentNamed(member.base.*, "compiler"),
        .ident => |ident| std.mem.eql(u8, ident.text, "compiler.assume_noalias_unchecked") or std.mem.eql(u8, ident.text, "assume_noalias_unchecked"),
        .grouped => |inner| isAssumeNoaliasCallee(inner.*),
        else => false,
    };
}

pub fn isPhysCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, "phys"),
        .grouped => |inner| isPhysCall(inner.*),
        else => false,
    };
}

// `drop(x)` and `forget_unchecked(x)` lower identically; they differ only in the checker.
pub fn isDropCall(callee: ast.Expr) bool {
    return ast_query.isIdentNamed(callee, "drop") or ast_query.isIdentNamed(callee, "forget_unchecked");
}

pub fn isUninitExpr(expr: ast.Expr) bool {
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

pub const ReflectionCallKind = enum {
    size,
    repr,
    alignment,
    field_offset,
    bit_offset,
};

pub fn reflectionCallKind(callee: ast.Expr) ?ReflectionCallKind {
    return switch (callee.kind) {
        .ident => |ident| {
            if (std.mem.eql(u8, ident.text, "size_of") or std.mem.eql(u8, ident.text, "sizeof")) return .size;
            if (std.mem.eql(u8, ident.text, "repr_of")) return .repr;
            if (std.mem.eql(u8, ident.text, "alignof")) return .alignment;
            if (std.mem.eql(u8, ident.text, "field_offset")) return .field_offset;
            if (std.mem.eql(u8, ident.text, "bit_offset")) return .bit_offset;
            return null;
        },
        .grouped => |inner| reflectionCallKind(inner.*),
        else => null,
    };
}

pub fn isResultConstructorCall(call: anytype) ?[]const u8 {
    if (call.type_args.len != 0 or call.args.len != 1) return null;
    const name = switch (call.callee.kind) {
        .ident => |ident| ident.text,
        .grouped => |inner| switch (inner.kind) {
            .ident => |ident| ident.text,
            else => return null,
        },
        else => return null,
    };
    if (std.mem.eql(u8, name, "ok") or std.mem.eql(u8, name, "err")) return name;
    return null;
}

pub fn taggedUnionConstructorName(callee: ast.Expr) ?[]const u8 {
    return switch (callee.kind) {
        .ident => |ident| ident.text,
        .grouped => |inner| taggedUnionConstructorName(inner.*),
        else => null,
    };
}

pub fn isBindCall(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .call => |call| isBindCallByNode(call),
        .grouped => |inner| isBindCall(inner.*),
        else => false,
    };
}

pub fn isBindCallByNode(call: anytype) bool {
    return call.type_args.len == 0 and call.args.len == 2 and ast_query.isIdentNamed(call.callee.*, "bind");
}
