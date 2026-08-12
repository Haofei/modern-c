//! LLVM backend type-shape helpers.

const std = @import("std");

const ast = @import("ast.zig");
const lower_llvm_model = @import("lower_llvm_model.zig");
const lower_llvm_type = @import("lower_llvm_type.zig");
const type_bridge = @import("type_bridge.zig");

const ResultTypeInfo = lower_llvm_model.ResultTypeInfo;
const isPayloadDomainGenericName = lower_llvm_type.isPayloadDomainGenericName;
const isPointerWidthIntegerTypeName = lower_llvm_type.isPointerWidthIntegerTypeName;
const isOpaqueAddressTypeName = type_bridge.isOpaqueAddressTypeName;

pub fn isPointerLikeType(type_aliases: *const std.StringHashMap(ast.TypeExpr), ty: ast.TypeExpr) bool {
    const resolved_ty = type_bridge.resolveAliasType(type_aliases, ty);
    return switch (resolved_ty.kind) {
        .pointer, .raw_many_pointer => true,
        .qualified => |node| isPointerLikeType(type_aliases, node.child.*),
        else => false,
    };
}

pub fn isFloatTypeOf(type_aliases: *const std.StringHashMap(ast.TypeExpr), ty: ast.TypeExpr) bool {
    return lower_llvm_type.isFloatType(type_bridge.resolveAliasType(type_aliases, ty));
}

pub fn isF32TypeOf(type_aliases: *const std.StringHashMap(ast.TypeExpr), ty: ast.TypeExpr) bool {
    const resolved_ty = type_bridge.resolveAliasType(type_aliases, ty);
    return switch (resolved_ty.kind) {
        .name => |name| std.mem.eql(u8, name.text, "f32"),
        .qualified => |node| isF32TypeOf(type_aliases, node.child.*),
        else => false,
    };
}

// `MmioPtr<T>` is the typed device-register pointer (lowers to `ptr`). The
// audited unsafe boundary mints it from a pointer-width integer / opaque address
// (a probed MMIO base) and extracts it back to an integer; both are pointer
// <-> address coercions, lowered as inttoptr/ptrtoint by the emitter.
pub fn isMmioPtrType(type_aliases: *const std.StringHashMap(ast.TypeExpr), ty: ast.TypeExpr) bool {
    const resolved_ty = type_bridge.resolveAliasType(type_aliases, ty);
    return switch (resolved_ty.kind) {
        .generic => |node| std.mem.eql(u8, node.base.text, "MmioPtr") and node.args.len == 1,
        .qualified => |node| isMmioPtrType(type_aliases, node.child.*),
        else => false,
    };
}

pub fn pointerAddressCoercion(type_aliases: *const std.StringHashMap(ast.TypeExpr), source_ty: ast.TypeExpr, target_ty: ast.TypeExpr) bool {
    const source = type_bridge.resolveAliasType(type_aliases, source_ty);
    const target = type_bridge.resolveAliasType(type_aliases, target_ty);
    // MmioPtr<T> <-> pointer-width integer / opaque address (the device-register
    // mint/extract boundary). MmioPtr lowers to `ptr`, so this is inttoptr/ptrtoint.
    if (isMmioPtrType(type_aliases, source)) {
        return switch (target.kind) {
            .name => |name| isOpaqueAddressTypeName(name.text) or isPointerWidthIntegerTypeName(name.text),
            .pointer, .raw_many_pointer, .nullable => true,
            else => false,
        };
    }
    if (isMmioPtrType(type_aliases, target)) {
        return switch (source.kind) {
            .name => |name| isOpaqueAddressTypeName(name.text) or isPointerWidthIntegerTypeName(name.text),
            .pointer, .raw_many_pointer, .nullable, .fn_pointer => true,
            else => false,
        };
    }
    return switch (source.kind) {
        // `.fn_pointer` (a code pointer, e.g. `&trap_vector`) coerces to a
        // pointer-width integer just like a data pointer — needed to install a
        // vector by address.
        .pointer, .raw_many_pointer, .nullable, .fn_pointer => switch (target.kind) {
            .name => |name| isOpaqueAddressTypeName(name.text) or isPointerWidthIntegerTypeName(name.text),
            else => false,
        },
        .name => |name| if (isOpaqueAddressTypeName(name.text)) switch (target.kind) {
            .pointer, .raw_many_pointer, .nullable => true,
            else => false,
        } else false,
        else => false,
    };
}

pub fn nullableInnerType(type_aliases: *const std.StringHashMap(ast.TypeExpr), ty: ast.TypeExpr) ?ast.TypeExpr {
    const resolved_ty = type_bridge.resolveAliasType(type_aliases, ty);
    return switch (resolved_ty.kind) {
        .nullable => |child| child.*,
        else => null,
    };
}

pub fn atomicPayloadType(type_aliases: *const std.StringHashMap(ast.TypeExpr), ty: ast.TypeExpr) ?ast.TypeExpr {
    const resolved_ty = type_bridge.resolveAliasType(type_aliases, ty);
    return switch (resolved_ty.kind) {
        .generic => |node| {
            if (!std.mem.eql(u8, node.base.text, "atomic") or node.args.len != 1) return null;
            return node.args[0];
        },
        .qualified => |node| atomicPayloadType(type_aliases, node.child.*),
        else => null,
    };
}

pub fn maybeUninitPayloadType(type_aliases: *const std.StringHashMap(ast.TypeExpr), ty: ast.TypeExpr) ?ast.TypeExpr {
    const resolved_ty = type_bridge.resolveAliasType(type_aliases, ty);
    return switch (resolved_ty.kind) {
        .generic => |node| {
            if (!std.mem.eql(u8, node.base.text, "MaybeUninit") or node.args.len != 1) return null;
            return node.args[0];
        },
        .qualified => |node| maybeUninitPayloadType(type_aliases, node.child.*),
        else => null,
    };
}

pub fn resultInfo(type_aliases: *const std.StringHashMap(ast.TypeExpr), ty: ast.TypeExpr) ?ResultTypeInfo {
    const resolved_ty = type_bridge.resolveAliasType(type_aliases, ty);
    return switch (resolved_ty.kind) {
        .generic => |node| {
            if (!std.mem.eql(u8, node.base.text, "Result") or node.args.len != 2) return null;
            return .{ .ok_ty = node.args[0], .err_ty = node.args[1] };
        },
        .qualified => |node| resultInfo(type_aliases, node.child.*),
        else => null,
    };
}

pub fn domainPayloadType(type_aliases: *const std.StringHashMap(ast.TypeExpr), ty: ast.TypeExpr) ?ast.TypeExpr {
    const resolved_ty = type_bridge.resolveAliasType(type_aliases, ty);
    return switch (resolved_ty.kind) {
        .generic => |node| {
            if (!isPayloadDomainGenericName(node.base.text) or node.args.len != 1) return null;
            return node.args[0];
        },
        .qualified => |node| domainPayloadType(type_aliases, node.child.*),
        else => null,
    };
}

pub fn isWrapDomainType(type_aliases: *const std.StringHashMap(ast.TypeExpr), ty: ast.TypeExpr) bool {
    const resolved_ty = type_bridge.resolveAliasType(type_aliases, ty);
    return switch (resolved_ty.kind) {
        .generic => |node| std.mem.eql(u8, node.base.text, "wrap") and node.args.len == 1,
        .qualified => |node| isWrapDomainType(type_aliases, node.child.*),
        else => false,
    };
}

pub fn isSatDomainType(type_aliases: *const std.StringHashMap(ast.TypeExpr), ty: ast.TypeExpr) bool {
    const resolved_ty = type_bridge.resolveAliasType(type_aliases, ty);
    return switch (resolved_ty.kind) {
        .generic => |node| std.mem.eql(u8, node.base.text, "sat") and node.args.len == 1,
        .qualified => |node| isSatDomainType(type_aliases, node.child.*),
        else => false,
    };
}
