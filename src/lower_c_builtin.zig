//! C backend builtin-call classifiers and source-text helpers.

const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const lower_c_model = @import("lower_c_model.zig");

const ReflectionCallKind = lower_c_model.ReflectionCallKind;
const isIdentNamed = ast_query.isIdentNamed;
const memberCallee = ast_query.memberCallee;

pub fn knownContractCalleeName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .ident => |ident| if (std.mem.eql(u8, ident.text, "compiler.assume_noalias_unchecked")) ident.text else null,
        .member => |member| {
            const base = switch (member.base.kind) {
                .ident => |ident| ident.text,
                else => return null,
            };
            if (std.mem.eql(u8, base, "unchecked")) {
                if (std.mem.eql(u8, member.name.text, "add")) return "unchecked.add";
                if (std.mem.eql(u8, member.name.text, "sub")) return "unchecked.sub";
                if (std.mem.eql(u8, member.name.text, "mul")) return "unchecked.mul";
            }
            if (std.mem.eql(u8, base, "compiler") and std.mem.eql(u8, member.name.text, "assume_noalias_unchecked")) return "compiler.assume_noalias_unchecked";
            if (std.mem.eql(u8, base, "raw") and std.mem.eql(u8, member.name.text, "store")) return "raw.store";
            return null;
        },
        .grouped => |inner| knownContractCalleeName(inner.*),
        else => null,
    };
}

pub fn contractMatchesCallee(contract: []const u8, callee: []const u8) bool {
    if (std.mem.eql(u8, contract, "no_overflow")) return std.mem.startsWith(u8, callee, "unchecked.");
    if (std.mem.eql(u8, contract, "noalias")) return std.mem.eql(u8, callee, "compiler.assume_noalias_unchecked");
    return false;
}

pub fn reflectionCallKind(callee: ast.Expr) ?ReflectionCallKind {
    return switch (callee.kind) {
        .ident => |ident| {
            if (std.mem.eql(u8, ident.text, "size_of") or std.mem.eql(u8, ident.text, "sizeof")) return .size;
            if (std.mem.eql(u8, ident.text, "alignof")) return .alignment;
            if (std.mem.eql(u8, ident.text, "field_offset")) return .field_offset;
            if (std.mem.eql(u8, ident.text, "bit_offset")) return .bit_offset;
            if (std.mem.eql(u8, ident.text, "repr_of")) return .repr;
            return null;
        },
        .grouped => |inner| reflectionCallKind(inner.*),
        else => null,
    };
}

pub fn isAssumeNoaliasCall(call: anytype) bool {
    if (call.type_args.len != 0 or call.args.len != 2) return false;
    const member = memberCallee(call.callee.*) orelse return false;
    return isIdentNamed(member.base.*, "compiler") and std.mem.eql(u8, member.name.text, "assume_noalias_unchecked");
}
