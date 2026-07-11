const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const sema_model = @import("sema_model.zig");
const sema_type = @import("sema_type.zig");

const TypeClass = sema_model.TypeClass;
const ContractKind = sema_model.ContractKind;

pub const ReflectionKind = enum {
    size,
    alignment,
    field_offset,
    field_type,
    bit_offset,
    repr,
};

pub const ReflectionTarget = struct {
    ty: ast.TypeExpr,
    args: []const ast.Expr,
};

pub fn reflectionKind(callee: ast.Expr) ?ReflectionKind {
    return switch (callee.kind) {
        .ident => |ident| {
            if (std.mem.eql(u8, ident.text, "size_of") or std.mem.eql(u8, ident.text, "sizeof")) return .size;
            if (std.mem.eql(u8, ident.text, "alignof")) return .alignment;
            if (std.mem.eql(u8, ident.text, "field_offset")) return .field_offset;
            if (std.mem.eql(u8, ident.text, "field_type")) return .field_type;
            if (std.mem.eql(u8, ident.text, "bit_offset")) return .bit_offset;
            if (std.mem.eql(u8, ident.text, "repr_of")) return .repr;
            return null;
        },
        .grouped => |inner| return reflectionKind(inner.*),
        else => null,
    };
}

pub fn reflectionTypeExprFromArg(expr: ast.Expr) ?ast.TypeExpr {
    return switch (expr.kind) {
        .ident => |ident| .{ .span = ident.span, .kind = .{ .name = ident } },
        .grouped => |inner| reflectionTypeExprFromArg(inner.*),
        else => null,
    };
}

pub fn reflectionRequiresField(kind: ReflectionKind) bool {
    return switch (kind) {
        .field_offset, .field_type, .bit_offset => true,
        .size, .alignment, .repr => false,
    };
}

pub fn reflectionReturnClass(kind: ReflectionKind) TypeClass {
    return switch (kind) {
        .size, .alignment, .field_offset, .bit_offset, .repr => .checked_usize,
        .field_type => .unknown,
    };
}

pub fn reflectionGenericHasWrongArity(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .generic => |node| if (genericTypeExpectedArgs(node.base.text)) |expected| node.args.len != expected else false,
        .qualified => |node| reflectionGenericHasWrongArity(node.child.*),
        else => false,
    };
}

pub fn genericTypeExpectedArgs(name: []const u8) ?usize {
    if (std.mem.eql(u8, name, "Reg")) return 2;
    if (std.mem.eql(u8, name, "RegBits")) return 3;
    if (std.mem.eql(u8, name, "MmioPtr")) return 1;
    if (std.mem.eql(u8, name, "UserPtr")) return 1;
    if (std.mem.eql(u8, name, "PhysPtr")) return 1;
    if (std.mem.eql(u8, name, "DmaBuf")) return 2;
    if (std.mem.eql(u8, name, "MaybeUninit")) return 1;
    if (std.mem.eql(u8, name, "atomic")) return 1;
    if (std.mem.eql(u8, name, "Result")) return 2;
    if (std.mem.eql(u8, name, "wrap")) return 1;
    if (std.mem.eql(u8, name, "sat")) return 1;
    if (std.mem.eql(u8, name, "serial")) return 1;
    if (std.mem.eql(u8, name, "counter")) return 1;
    if (std.mem.eql(u8, name, "Duration")) return 1;
    return null;
}

pub fn isKnownGenericTypeName(name: []const u8) bool {
    if (sema_type.classifyGenericTypeName(name) != .unknown) return true;
    if (std.mem.eql(u8, name, "Reg")) return true;
    if (std.mem.eql(u8, name, "RegBits")) return true;
    if (std.mem.eql(u8, name, "DmaBuf")) return true;
    if (std.mem.eql(u8, name, "MaybeUninit")) return true;
    if (std.mem.eql(u8, name, "atomic")) return true;
    return false;
}

pub fn isArithmeticDomainTypeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "wrap") or
        std.mem.eql(u8, name, "sat") or
        std.mem.eql(u8, name, "serial") or
        std.mem.eql(u8, name, "counter");
}

pub fn genericHoldsArgsByValue(name: []const u8) bool {
    return std.mem.eql(u8, name, "Result");
}

pub fn genericHasStoragePayload(name: []const u8) bool {
    return std.mem.eql(u8, name, "MaybeUninit") or
        std.mem.eql(u8, name, "atomic") or
        std.mem.eql(u8, name, "UserPtr") or
        std.mem.eql(u8, name, "MmioPtr") or
        std.mem.eql(u8, name, "PhysPtr") or
        std.mem.eql(u8, name, "DmaBuf");
}

pub fn isMmioAccessMode(mode: []const u8) bool {
    return std.mem.eql(u8, mode, "read") or
        std.mem.eql(u8, mode, "write") or
        std.mem.eql(u8, mode, "read_write");
}

pub fn isDmaBufMode(mode: []const u8) bool {
    return std.mem.eql(u8, mode, "coherent") or
        std.mem.eql(u8, mode, "noncoherent");
}

pub fn isUnwrapCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, "unwrap"),
        .member => |node| std.mem.eql(u8, node.name.text, "unwrap"),
        else => false,
    };
}

pub fn isTrapCall(callee: ast.Expr) bool {
    return ast_query.isIdentNamed(callee, "trap");
}

pub fn isDropCall(callee: ast.Expr) bool {
    return ast_query.isIdentNamed(callee, "drop");
}

pub fn isForgetUncheckedCall(callee: ast.Expr) bool {
    return ast_query.isIdentNamed(callee, "forget_unchecked");
}

pub fn isTrappingConversionCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |node| std.mem.eql(u8, node.name.text, "trap_from"),
        .grouped => |inner| isTrappingConversionCall(inner.*),
        else => false,
    };
}

pub fn isLanguageTrapKind(name: []const u8) bool {
    const names = [_][]const u8{
        "Bounds",
        "NullUnwrap",
        "IntegerOverflow",
        "DivideByZero",
        "InvalidShift",
        "InvalidRepresentation",
        "Assert",
        "Unreachable",
    };
    for (names) |known| {
        if (std.mem.eql(u8, name, known)) return true;
    }
    return false;
}

pub fn isCAbiOpaqueBoundary(ty: ast.TypeExpr) bool {
    return isTypeName(ty, "void") or isTypeName(ty, "c_void");
}

pub fn isTypeName(ty: ast.TypeExpr, name: []const u8) bool {
    return switch (ty.kind) {
        .name => |ident| std.mem.eql(u8, ident.text, name),
        .qualified => |node| isTypeName(node.child.*, name),
        else => false,
    };
}

pub fn enumLiteralName(expr: ast.Expr) ?ast.Ident {
    return switch (expr.kind) {
        .enum_literal => |literal| literal,
        .grouped => |inner| enumLiteralName(inner.*),
        else => null,
    };
}

pub fn uncheckedRequirement(expr: ast.Expr) ?ContractKind {
    return switch (expr.kind) {
        .member => |node| {
            if (ast_query.isIdentNamed(node.base.*, "unchecked")) return .no_overflow;
            if (ast_query.isIdentNamed(node.base.*, "compiler") and std.mem.eql(u8, node.name.text, "assume_noalias_unchecked")) return .noalias_contract;
            return null;
        },
        .ident => |ident| if (std.mem.eql(u8, ident.text, "assume_noalias_unchecked")) .noalias_contract else null,
        else => null,
    };
}

pub fn isUnsafeOperationCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |node| {
            if (ast_query.isIdentNamed(node.base.*, "raw") and (std.mem.eql(u8, node.name.text, "store") or std.mem.eql(u8, node.name.text, "load"))) return true;
            if (ast_query.isIdentNamed(node.base.*, "mmio") and std.mem.eql(u8, node.name.text, "map")) return true;
            if (ast_query.isIdentNamed(node.base.*, "va") and std.mem.eql(u8, node.name.text, "arg")) return true;
            return false;
        },
        .grouped => |inner| isUnsafeOperationCall(inner.*),
        else => false,
    };
}

pub fn isBuiltinNamespaceMember(member: anytype) bool {
    const base = switch (member.base.kind) {
        .ident => |ident| ident.text,
        .grouped => |inner| switch (inner.kind) {
            .ident => |ident| ident.text,
            else => return false,
        },
        else => return false,
    };
    if (std.mem.eql(u8, base, "raw")) return std.mem.eql(u8, member.name.text, "store") or std.mem.eql(u8, member.name.text, "load") or std.mem.eql(u8, member.name.text, "ptr");
    if (std.mem.eql(u8, base, "va")) return std.mem.eql(u8, member.name.text, "start") or std.mem.eql(u8, member.name.text, "arg") or std.mem.eql(u8, member.name.text, "end");
    if (std.mem.eql(u8, base, "fence")) return std.mem.eql(u8, member.name.text, "full") or std.mem.eql(u8, member.name.text, "acquire") or std.mem.eql(u8, member.name.text, "release");
    if (std.mem.eql(u8, base, "mmio")) return std.mem.eql(u8, member.name.text, "map");
    if (std.mem.eql(u8, base, "unchecked")) return isUncheckedNoOverflowMember(member.name.text);
    if (std.mem.eql(u8, base, "wrapping")) return std.mem.eql(u8, member.name.text, "add");
    if (std.mem.eql(u8, base, "reduce")) return std.mem.eql(u8, member.name.text, "sum_checked") or std.mem.eql(u8, member.name.text, "sum_left") or std.mem.eql(u8, member.name.text, "sum_fast");
    if (std.mem.eql(u8, base, "mem")) return std.mem.eql(u8, member.name.text, "as_bytes") or std.mem.eql(u8, member.name.text, "bytes_equal");
    if (std.mem.eql(u8, base, "compiler")) return std.mem.eql(u8, member.name.text, "assume_noalias_unchecked");
    if (std.mem.eql(u8, base, "cpu")) return std.mem.eql(u8, member.name.text, "pause");
    if (std.mem.eql(u8, base, "atomic")) return std.mem.eql(u8, member.name.text, "init");
    if (std.mem.eql(u8, base, "cache")) return std.mem.eql(u8, member.name.text, "clean") or std.mem.eql(u8, member.name.text, "invalidate");
    if (std.mem.eql(u8, base, "lock")) return std.mem.eql(u8, member.name.text, "acquire");
    if (std.mem.eql(u8, base, "heap")) return std.mem.eql(u8, member.name.text, "alloc");
    if (std.mem.eql(u8, base, "device")) return std.mem.eql(u8, member.name.text, "wait_irq");
    if (std.mem.eql(u8, base, "fs")) return std.mem.eql(u8, member.name.text, "read");
    return false;
}

pub fn isUncheckedNoOverflowMember(name: []const u8) bool {
    return std.mem.eql(u8, name, "add") or
        std.mem.eql(u8, name, "sub") or
        std.mem.eql(u8, name, "mul");
}

pub fn comptimeErrorMessage(expr: ast.Expr) ?[]const u8 {
    const call = switch (expr.kind) {
        .call => |node| node,
        .grouped => |inner| return comptimeErrorMessage(inner.*),
        else => return null,
    };
    if (!ast_query.isIdentNamed(call.callee.*, "comptime_error") or call.args.len != 1) return null;
    return switch (call.args[0].kind) {
        .string_literal => |lit| if (lit.len >= 2) lit[1 .. lit.len - 1] else lit,
        else => null,
    };
}

pub fn isBuiltinFunctionName(name: []const u8) bool {
    if (std.mem.eql(u8, name, "trap")) return true;
    if (std.mem.eql(u8, name, "comptime_error")) return true;
    if (std.mem.eql(u8, name, "drop")) return true;
    if (std.mem.eql(u8, name, "forget_unchecked")) return true;
    if (std.mem.eql(u8, name, "bind")) return true;
    if (std.mem.eql(u8, name, "unwrap")) return true;
    if (std.mem.eql(u8, name, "bitcast")) return true;
    if (std.mem.eql(u8, name, "phys")) return true;
    if (std.mem.eql(u8, name, "ok")) return true;
    if (std.mem.eql(u8, name, "err")) return true;
    if (std.mem.eql(u8, name, "size_of")) return true;
    if (std.mem.eql(u8, name, "sizeof")) return true;
    if (std.mem.eql(u8, name, "alignof")) return true;
    if (std.mem.eql(u8, name, "field_offset")) return true;
    if (std.mem.eql(u8, name, "field_type")) return true;
    if (std.mem.eql(u8, name, "bit_offset")) return true;
    if (std.mem.eql(u8, name, "repr_of")) return true;
    return mathBuiltinFloatClass(name) != null;
}

pub fn mathBuiltinFloatClass(name: []const u8) ?TypeClass {
    if (std.mem.eql(u8, name, "__builtin_sqrtf")) return .f32;
    if (std.mem.eql(u8, name, "__builtin_sqrt")) return .f64;
    return null;
}

pub fn mathBuiltinCallReturnClass(callee: ast.Expr) ?TypeClass {
    return switch (callee.kind) {
        .ident => |ident| mathBuiltinFloatClass(ident.text),
        .grouped => |inner| mathBuiltinCallReturnClass(inner.*),
        else => null,
    };
}

pub fn isBitcastCallName(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, "bitcast"),
        .grouped => |inner| isBitcastCallName(inner.*),
        else => false,
    };
}

pub fn secretPayloadType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .generic => |node| if (std.mem.eql(u8, node.base.text, "Secret") and node.args.len == 1) node.args[0] else null,
        .qualified => |node| secretPayloadType(node.child.*),
        else => null,
    };
}

pub fn isComptimeForbiddenCall(callee: ast.Expr) bool {
    return isUnsafeOperationCall(callee) or isCpuPauseCall(callee) or isFenceCall(callee);
}

pub fn isFenceCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |node| ast_query.isIdentNamed(node.base.*, "fence") and
            (std.mem.eql(u8, node.name.text, "full") or std.mem.eql(u8, node.name.text, "acquire") or std.mem.eql(u8, node.name.text, "release")),
        .grouped => |inner| isFenceCall(inner.*),
        else => false,
    };
}

pub fn isCpuPauseCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |node| ast_query.isIdentNamed(node.base.*, "cpu") and std.mem.eql(u8, node.name.text, "pause"),
        .grouped => |inner| isCpuPauseCall(inner.*),
        else => false,
    };
}
