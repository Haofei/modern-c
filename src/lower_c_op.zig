//! C backend — operator spelling + checked/saturating-arithmetic helpers.
//!
//! Pure (no `CEmitter` state) helpers that map MC operators to their C
//! spellings and to the runtime checked/saturating helper names, plus the
//! trap-kind classification used during arithmetic lowering. Extracted verbatim
//! from `lower_c.zig` as part of the Phase-2a structural split; behavior is
//! unchanged. Call sites in the spine reference these through re-export aliases.

const std = @import("std");

const lower_c_type = @import("lower_c_type.zig");
const syntax_bridge = @import("syntax_bridge.zig");
const checkedTypeSuffix = lower_c_type.checkedTypeSuffix;
const isNegativeOne = syntax_bridge.isNegativeOne;
const unsignedTypeSuffix = lower_c_type.unsignedTypeSuffix;

pub fn unaryCOp(op: anytype) []const u8 {
    return switch (op) {
        .neg => "-",
        .bit_not => "~",
        .logical_not => "!",
    };
}

pub fn binaryCOp(op: anytype) []const u8 {
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

pub fn isCheckedBinaryOp(op: anytype) bool {
    return switch (op) {
        .add, .sub, .mul, .div, .mod, .shl, .shr => true,
        else => false,
    };
}

pub fn isComparisonOp(op: anytype) bool {
    return switch (op) {
        .eq, .ne, .lt, .le, .gt, .ge => true,
        else => false,
    };
}

pub fn isNoTrapBitwiseInfixOp(op: anytype) bool {
    return switch (op) {
        .bit_and, .bit_or, .bit_xor => true,
        else => false,
    };
}

pub const CheckedHelperParts = struct {
    prefix: []const u8,
    suffix: []const u8,
};

pub fn checkedHelperParts(op: anytype, type_name: []const u8) ?CheckedHelperParts {
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

pub fn satHelperParts(op: anytype, type_name: []const u8) ?CheckedHelperParts {
    const suffix = unsignedTypeSuffix(type_name) orelse return null;
    const prefix = switch (op) {
        .add => "mc_sat_add_",
        .sub => "mc_sat_sub_",
        .mul => "mc_sat_mul_",
        else => return null,
    };
    return .{ .prefix = prefix, .suffix = suffix };
}

pub fn isWrapPreservingBinary(op: anytype) bool {
    return switch (op) {
        .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr => true,
        else => false,
    };
}

pub fn arithmeticDomainOpName(op: anytype) []const u8 {
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

pub const CheckedOp = union(enum) {
    binary: []const u8,
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
        .binary => |binary| binary,
    };
}

pub fn checkedOpForBinary(op: anytype) ?CheckedOp {
    return if (checkedBinaryOpName(op)) |name| .{ .binary = name } else null;
}

pub fn checkedBinaryOpName(op: anytype) ?[]const u8 {
    return switch (op) {
        .add => "add",
        .sub => "sub",
        .mul => "mul",
        .div => "div",
        .mod => "mod",
        .shl => "shl",
        .shr => "shr",
        else => null,
    };
}

pub fn isOverflowOp(op: CheckedOp) bool {
    return switch (op) {
        .neg => true,
        .binary => |binary| std.mem.eql(u8, binary, "add") or
            std.mem.eql(u8, binary, "sub") or
            std.mem.eql(u8, binary, "mul") or
            std.mem.eql(u8, binary, "div") or
            std.mem.eql(u8, binary, "mod") or
            std.mem.eql(u8, binary, "shl"),
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

pub fn widthBits(width: []const u8) []const u8 {
    if (std.mem.eql(u8, width, "usize") or std.mem.eql(u8, width, "isize")) return "ptr";
    if (width.len > 1 and (width[0] == 'u' or width[0] == 'i')) return width[1..];
    if (std.mem.eql(u8, width, "bool")) return "1";
    return "unknown";
}
