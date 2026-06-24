//! C backend — operator spelling + checked/saturating-arithmetic helpers.
//!
//! Pure (no `CEmitter` state) helpers that map MC operators to their C
//! spellings and to the runtime checked/saturating helper names, plus the
//! trap-kind classification used during arithmetic lowering. Extracted verbatim
//! from `lower_c.zig` as part of the Phase-2a structural split; behavior is
//! unchanged. Call sites in the spine reference these through re-export aliases.

const std = @import("std");

const ast = @import("ast.zig");

const lower_c_type = @import("lower_c_type.zig");
const checkedTypeSuffix = lower_c_type.checkedTypeSuffix;
const unsignedTypeSuffix = lower_c_type.unsignedTypeSuffix;

pub fn unaryCOp(op: ast.UnaryOp) []const u8 {
    return switch (op) {
        .neg => "-",
        .bit_not => "~",
        .logical_not => "!",
    };
}

pub fn binaryCOp(op: ast.BinaryOp) []const u8 {
    return switch (op) {
        .logical_or => "||",
        .logical_and => "&&",
        .eq => "==",
        .ne => "!=",
        .lt => "<",
        .le => "<=",
        .gt => ">",
        .ge => ">=",
        .bit_or => "|",
        .bit_xor => "^",
        .bit_and => "&",
        .shl => "<<",
        .shr => ">>",
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .mod => "%",
    };
}

pub fn isCheckedBinaryOp(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul, .div, .mod, .shl, .shr => true,
        else => false,
    };
}

pub fn isComparisonOp(op: ast.BinaryOp) bool {
    return switch (op) {
        .eq, .ne, .lt, .le, .gt, .ge => true,
        else => false,
    };
}

pub fn isNoTrapBitwiseInfixOp(op: ast.BinaryOp) bool {
    return switch (op) {
        .bit_and, .bit_or, .bit_xor => true,
        else => false,
    };
}

pub const CheckedHelperParts = struct {
    prefix: []const u8,
    suffix: []const u8,
};

pub fn checkedHelperParts(op: ast.BinaryOp, type_name: []const u8) ?CheckedHelperParts {
    const suffix = checkedTypeSuffix(type_name) orelse return null;
    const prefix = switch (op) {
        .add => "mc_checked_add_",
        .sub => "mc_checked_sub_",
        .mul => "mc_checked_mul_",
        .div => "mc_checked_div_",
        .mod => "mc_checked_mod_",
        .shl => "mc_checked_shl_",
        .shr => "mc_checked_shr_",
        else => return null,
    };
    return .{ .prefix = prefix, .suffix = suffix };
}

pub fn satHelperParts(op: ast.BinaryOp, type_name: []const u8) ?CheckedHelperParts {
    const suffix = unsignedTypeSuffix(type_name) orelse return null;
    const prefix = switch (op) {
        .add => "mc_sat_add_",
        .sub => "mc_sat_sub_",
        .mul => "mc_sat_mul_",
        else => return null,
    };
    return .{ .prefix = prefix, .suffix = suffix };
}

pub fn isWrapPreservingBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr => true,
        else => false,
    };
}

pub fn arithmeticDomainOpName(op: ast.BinaryOp) []const u8 {
    return switch (op) {
        .add => "add",
        .sub => "sub",
        .mul => "mul",
        .bit_and => "bit_and",
        .bit_or => "bit_or",
        .bit_xor => "bit_xor",
        .shl => "shl",
        .shr => "shr",
        else => "unknown",
    };
}

pub fn trapHelperForCall(call: anytype) ?[]const u8 {
    if (!isTrapCallee(call.callee.*) or call.args.len != 1) return null;
    return switch (call.args[0].kind) {
        .enum_literal => |literal| trapHelperForKind(literal.text),
        else => null,
    };
}

pub fn isTrapCallee(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, "trap"),
        .grouped => |inner| isTrapCallee(inner.*),
        else => false,
    };
}

pub fn trapHelperForKind(kind: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, kind, "Bounds")) return "mc_trap_Bounds";
    if (std.mem.eql(u8, kind, "NullUnwrap")) return "mc_trap_NullUnwrap";
    if (std.mem.eql(u8, kind, "IntegerOverflow")) return "mc_trap_IntegerOverflow";
    if (std.mem.eql(u8, kind, "DivideByZero")) return "mc_trap_DivideByZero";
    if (std.mem.eql(u8, kind, "InvalidShift")) return "mc_trap_InvalidShift";
    if (std.mem.eql(u8, kind, "InvalidRepresentation")) return "mc_trap_InvalidRepresentation";
    if (std.mem.eql(u8, kind, "Assert")) return "mc_trap_Assert";
    if (std.mem.eql(u8, kind, "Unreachable")) return "mc_trap_Unreachable";
    return null;
}

pub const CheckedOp = union(enum) {
    binary: ast.BinaryOp,
    neg,
};

pub const TrapKind = enum {
    integer_overflow,
    divide_by_zero,
    invalid_shift,

    pub fn text(self: TrapKind) []const u8 {
        return switch (self) {
            .integer_overflow => "IntegerOverflow",
            .divide_by_zero => "DivideByZero",
            .invalid_shift => "InvalidShift",
        };
    }
};

pub fn checkedOpName(op: CheckedOp) ?[]const u8 {
    return switch (op) {
        .neg => "neg",
        .binary => |binary| switch (binary) {
            .add => "add",
            .sub => "sub",
            .mul => "mul",
            .div => "div",
            .mod => "mod",
            .shl => "shl",
            .shr => "shr",
            else => null,
        },
    };
}

pub fn isOverflowOp(op: CheckedOp) bool {
    return switch (op) {
        .neg => true,
        .binary => |binary| switch (binary) {
            .add, .sub, .mul, .div, .mod, .shl => true,
            else => false,
        },
    };
}

pub fn trapKindForBinary(node: anytype, ty: []const u8) TrapKind {
    if ((node.op == .div or node.op == .mod) and isSignedIntType(ty) and isNegativeOne(node.right.*)) return .integer_overflow;
    if (node.op == .div or node.op == .mod) return .divide_by_zero;
    return .integer_overflow;
}

pub fn isSignedIntType(ty: []const u8) bool {
    return ty.len >= 2 and ty[0] == 'i' and std.ascii.isDigit(ty[1]);
}

pub fn isNegativeOne(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .unary => |node| node.op == .neg and isIntLiteral(node.expr.*, "1"),
        else => false,
    };
}

pub fn isIntLiteral(expr: ast.Expr, value: []const u8) bool {
    return switch (expr.kind) {
        .int_literal => |literal| std.mem.eql(u8, literal, value),
        else => false,
    };
}

pub fn widthBits(width: []const u8) []const u8 {
    if (std.mem.eql(u8, width, "usize") or std.mem.eql(u8, width, "isize")) return "ptr";
    if (width.len > 1 and (width[0] == 'u' or width[0] == 'i')) return width[1..];
    if (std.mem.eql(u8, width, "bool")) return "1";
    return "unknown";
}
