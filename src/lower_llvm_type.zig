//! LLVM backend — scalar/primitive type mapping & classification helpers.
//!
//! Pure (no `LlvmEmitter` state) helpers that classify MC types for LLVM
//! lowering: pointer-likeness, integer widths, signedness, scalar-name
//! recognition, library-scalar LLVM spellings, and small AST/literal shape
//! queries used by the type machinery. Extracted from `lower_llvm.zig`
//! verbatim as part of the Phase-2c structural split; behavior is unchanged.
//! The spine references these through re-export aliases so call sites read
//! unchanged. Mirrors `lower_c_type.zig` to keep the two backends parallel.

const std = @import("std");

const ast = @import("ast.zig");
const scalar_repr = @import("scalar_repr.zig");
const ast_query = @import("ast_query.zig");

const typeName = ast_query.typeName;

pub fn simpleType(span: ast.Span, name: []const u8) ast.TypeExpr {
    return .{ .span = span, .kind = .{ .name = .{ .span = span, .text = name } } };
}

pub fn exprAsType(expr: ast.Expr) ?ast.TypeExpr {
    return switch (expr.kind) {
        .ident => |ident| simpleType(ident.span, ident.text),
        .grouped => |inner| exprAsType(inner.*),
        else => null,
    };
}

pub fn isPointerLikeType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .pointer, .raw_many_pointer => true,
        .qualified => |node| isPointerLikeType(node.child.*),
        else => false,
    };
}

// True when `ty` is a `*dyn Trait` fat pointer (a two-word `{ data, vtable }` value).
pub fn isDynTraitLlvmType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .dyn_trait => true,
        .qualified => |node| isDynTraitLlvmType(node.child.*),
        else => false,
    };
}

pub fn alignForward(value: i128, alignment: i128) ?i128 {
    if (alignment <= 0) return null;
    const rem = @rem(value, alignment);
    if (rem == 0) return value;
    return std.math.add(i128, value, alignment - rem) catch null;
}

pub fn isPointerWidthIntegerTypeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "isize");
}

pub fn isOpaqueAddressGenericName(name: []const u8) bool {
    return std.mem.eql(u8, name, "UserPtr") or
        std.mem.eql(u8, name, "PhysPtr");
}

pub fn isPayloadDomainGenericName(name: []const u8) bool {
    return std.mem.eql(u8, name, "wrap") or
        std.mem.eql(u8, name, "sat") or
        std.mem.eql(u8, name, "serial") or
        std.mem.eql(u8, name, "counter") or
        std.mem.eql(u8, name, "Duration") or
        // `Secret<T>` is a constant-time tag, fully transparent in codegen: it
        // shares T's LLVM type, size, alignment, and (checked, not wrapping —
        // it is not in isWrapDomainType/isSatDomainType) arithmetic. The
        // secret-flow rules are enforced in sema.
        std.mem.eql(u8, name, "Secret");
}

pub fn libraryScalarLlvmType(name: []const u8) ?[]const u8 {
    const info = scalar_repr.integer(name) orelse return null;
    return if (scalar_repr.isLibraryInteger(name)) info.llvm_type else null;
}

pub fn typeNameEql(ty: ast.TypeExpr, expected: []const u8) bool {
    return switch (ty.kind) {
        .name => |name| std.mem.eql(u8, name.text, expected),
        else => false,
    };
}

pub fn secretInnerType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .generic => |node| if (std.mem.eql(u8, node.base.text, "Secret") and node.args.len == 1) node.args[0] else null,
        .qualified => |node| secretInnerType(node.child.*),
        else => null,
    };
}

pub fn constGetIndexArg(ty: ast.TypeExpr) ?u64 {
    return switch (ty.kind) {
        .name => |name| parseU64Literal(name.text),
        .qualified => |node| constGetIndexArg(node.child.*),
        else => null,
    };
}

pub fn rawScalarTypeName(ty: ast.TypeExpr) ?[]const u8 {
    const name = typeName(ty) orelse return null;
    if (std.mem.eql(u8, name, "u8")) return name;
    if (std.mem.eql(u8, name, "u16")) return name;
    if (std.mem.eql(u8, name, "u32")) return name;
    if (std.mem.eql(u8, name, "u64")) return name;
    if (std.mem.eql(u8, name, "u128")) return name;
    if (std.mem.eql(u8, name, "usize")) return name;
    if (std.mem.eql(u8, name, "i8")) return name;
    if (std.mem.eql(u8, name, "i16")) return name;
    if (std.mem.eql(u8, name, "i32")) return name;
    if (std.mem.eql(u8, name, "i64")) return name;
    if (std.mem.eql(u8, name, "isize")) return name;
    if (std.mem.eql(u8, name, "f32")) return name;
    if (std.mem.eql(u8, name, "f64")) return name;
    return null;
}

pub fn literalArrayLenValue(expr: ast.Expr) ?u64 {
    return switch (expr.kind) {
        .int_literal => |literal| parseU64Literal(literal),
        .grouped => |inner| literalArrayLenValue(inner.*),
        else => null,
    };
}

pub fn parseU64Literal(literal: []const u8) ?u64 {
    var value: u64 = 0;
    for (literal) |ch| {
        if (ch == '_') continue;
        if (ch < '0' or ch > '9') return null;
        value = std.math.mul(u64, value, 10) catch return null;
        value = std.math.add(u64, value, ch - '0') catch return null;
    }
    return value;
}

pub fn integerBits(ty: ast.TypeExpr) ?u16 {
    const name = switch (ty.kind) {
        .name => |name| name.text,
        else => return null,
    };
    return if (scalar_repr.integer(name)) |info| info.bits else null;
}

pub fn isSignedInteger(ty: ast.TypeExpr) bool {
    const name = switch (ty.kind) {
        .name => |name| name.text,
        else => return false,
    };
    return if (scalar_repr.integer(name)) |info| info.signed else false;
}

pub fn isFloatType(ty: ast.TypeExpr) bool {
    const name = switch (ty.kind) {
        .name => |name| name.text,
        else => return false,
    };
    return std.mem.eql(u8, name, "f32") or std.mem.eql(u8, name, "f64");
}

pub fn signedMinLiteral(ty: ast.TypeExpr) ?[]const u8 {
    const name = switch (ty.kind) {
        .name => |name| name.text,
        else => return null,
    };
    if (std.mem.eql(u8, name, "i8")) return "-128";
    if (std.mem.eql(u8, name, "i16")) return "-32768";
    if (std.mem.eql(u8, name, "i32")) return "-2147483648";
    if (std.mem.eql(u8, name, "i64") or std.mem.eql(u8, name, "isize")) return "-9223372036854775808";
    if (std.mem.eql(u8, name, "i128")) return "-170141183460469231731687303715884105728";
    return null;
}

pub fn intrinsicBits(name: []const u8) ?u16 {
    if (std.mem.endsWith(u8, name, ".i8")) return 8;
    if (std.mem.endsWith(u8, name, ".i16")) return 16;
    if (std.mem.endsWith(u8, name, ".i32")) return 32;
    if (std.mem.endsWith(u8, name, ".i64")) return 64;
    return null;
}
