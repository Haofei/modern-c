//! LLVM backend — operator/predicate spelling, trap-helper, and literal
//! normalization helpers.
//!
//! Pure (no `LlvmEmitter` state) helpers that map MC binary operators to LLVM
//! comparison predicates, recognize wrapping/unchecked builtin ops, resolve
//! trap-helper symbol names, and normalize integer/float/char literals to
//! their LLVM textual forms. Extracted from `lower_llvm.zig` verbatim as part
//! of the Phase-2c structural split; behavior is unchanged. The spine
//! references these through re-export aliases so call sites read unchanged.
//! Mirrors `lower_c_op.zig` to keep the two backends parallel.

const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const numeric = @import("numeric.zig");

const isIdentNamed = ast_query.isIdentNamed;

pub fn binaryIsComparison(op: ast.BinaryOp) bool {
    return switch (op) {
        .eq, .ne, .lt, .le, .gt, .ge => true,
        else => false,
    };
}

pub fn comparisonPredicate(op: ast.BinaryOp, signed: bool) ?[]const u8 {
    return switch (op) {
        .eq => "eq",
        .ne => "ne",
        .lt => if (signed) "slt" else "ult",
        .le => if (signed) "sle" else "ule",
        .gt => if (signed) "sgt" else "ugt",
        .ge => if (signed) "sge" else "uge",
        else => null,
    };
}

pub fn floatComparisonPredicate(op: ast.BinaryOp) ?[]const u8 {
    return switch (op) {
        .eq => "oeq",
        .ne => "une",
        .lt => "olt",
        .le => "ole",
        .gt => "ogt",
        .ge => "oge",
        else => null,
    };
}

pub fn wrappingBuiltinOp(callee: ast.Expr) ?[]const u8 {
    return switch (callee.kind) {
        .member => |member| if (isIdentNamed(member.base.*, "wrapping"))
            if (std.mem.eql(u8, member.name.text, "add"))
                "add"
            else if (std.mem.eql(u8, member.name.text, "sub"))
                "sub"
            else if (std.mem.eql(u8, member.name.text, "mul"))
                "mul"
            else
                null
        else
            null,
        .grouped => |inner| wrappingBuiltinOp(inner.*),
        else => null,
    };
}

pub fn uncheckedBuiltinOp(callee: ast.Expr) ?[]const u8 {
    return switch (callee.kind) {
        .member => |member| if (isIdentNamed(member.base.*, "unchecked"))
            if (std.mem.eql(u8, member.name.text, "add"))
                "add"
            else if (std.mem.eql(u8, member.name.text, "sub"))
                "sub"
            else if (std.mem.eql(u8, member.name.text, "mul"))
                "mul"
            else
                null
        else
            null,
        .grouped => |inner| uncheckedBuiltinOp(inner.*),
        else => null,
    };
}

pub fn trapHelperForCall(call: anytype) ?[]const u8 {
    const callee = switch (call.callee.kind) {
        .ident => |ident| ident.text,
        .grouped => |inner| switch (inner.kind) {
            .ident => |ident| ident.text,
            else => return null,
        },
        else => return null,
    };
    if (!std.mem.eql(u8, callee, "trap") or call.type_args.len != 0 or call.args.len != 1) return null;
    return switch (call.args[0].kind) {
        .enum_literal => |literal| trapHelperForKind(literal.text),
        .grouped => |inner| switch (inner.kind) {
            .enum_literal => |literal| trapHelperForKind(literal.text),
            else => null,
        },
        else => null,
    };
}

pub fn trapHelperForKind(kind: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, kind, "Bounds")) return "mc_trap_Bounds";
    if (std.mem.eql(u8, kind, "IntegerOverflow")) return "mc_trap_IntegerOverflow";
    if (std.mem.eql(u8, kind, "DivideByZero")) return "mc_trap_DivideByZero";
    if (std.mem.eql(u8, kind, "InvalidShift")) return "mc_trap_InvalidShift";
    if (std.mem.eql(u8, kind, "InvalidRepresentation")) return "mc_trap_InvalidRepresentation";
    if (std.mem.eql(u8, kind, "Assert")) return "mc_trap_Assert";
    if (std.mem.eql(u8, kind, "Unreachable")) return "mc_trap_Unreachable";
    return null;
}

pub fn normalizedIntLiteral(allocator: std.mem.Allocator, literal: []const u8) ![]const u8 {
    var cleaned: std.ArrayList(u8) = .empty;
    for (literal) |ch| {
        if (ch != '_') try cleaned.append(allocator, ch);
    }
    const text = try cleaned.toOwnedSlice(allocator);
    const value = std.fmt.parseInt(i128, text, 0) catch return text;
    return std.fmt.allocPrint(allocator, "{d}", .{value});
}

pub fn normalizedFloatLiteral(allocator: std.mem.Allocator, literal: []const u8, f32_target: bool) ![]const u8 {
    var cleaned: std.ArrayList(u8) = .empty;
    for (literal) |ch| {
        if (ch != '_') try cleaned.append(allocator, ch);
    }
    const text = try cleaned.toOwnedSlice(allocator);
    if (!f32_target) return text;
    const parsed = std.fmt.parseFloat(f32, text) catch return text;
    const widened: f64 = parsed;
    const bits: u64 = @bitCast(widened);
    return std.fmt.allocPrint(allocator, "0x{X:0>16}", .{bits});
}

pub fn charLiteralValue(allocator: std.mem.Allocator, literal: []const u8) ![]const u8 {
    const value = numeric.parseCharLiteral(literal) orelse return error.UnsupportedLlvmEmission;
    return std.fmt.allocPrint(allocator, "{d}", .{value});
}

pub fn hexDigit(value: u8) u8 {
    return if (value < 10) '0' + value else 'A' + (value - 10);
}
