const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const numeric = @import("numeric.zig");
const sema_model = @import("sema_model.zig");

const Context = sema_model.Context;
const TypeClass = sema_model.TypeClass;
const integerLiteralValue = numeric.integerLiteralValue;
const typeName = ast_query.typeName;

pub fn isTrapBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul, .div, .mod, .shl, .shr => true,
        else => false,
    };
}

pub fn isArithmeticBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul, .div, .mod => true,
        else => false,
    };
}

pub fn isPointerArithmeticBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub => true,
        else => false,
    };
}

pub fn isBitwiseBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .bit_and, .bit_or, .bit_xor, .shl, .shr => true,
        else => false,
    };
}

pub fn isLogicalBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .logical_and, .logical_or => true,
        else => false,
    };
}

pub fn isComparisonBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .eq, .ne, .lt, .le, .gt, .ge => true,
        else => false,
    };
}

pub fn isCheckedInt(kind: TypeClass) bool {
    return isCheckedUnsigned(kind) or isCheckedSigned(kind);
}

pub fn isIntegerLike(kind: TypeClass) bool {
    return isCheckedInt(kind) or kind == .int_literal;
}

// Sema mirror of the MIR builder's `divModProvablySafe` (annex E): a `div`/`mod` by a
// non-zero integer-literal divisor cannot divide by zero, and for a signed dividend it
// cannot hit the only checked overflow (`INT_MIN / -1`) unless the divisor is `-1`.
pub fn divModProvablySafe(op: ast.BinaryOp, left: TypeClass, divisor: ast.Expr) bool {
    if (op != .div and op != .mod) return false;
    const d = integerLiteralValue(divisor) orelse return false;
    if (d.magnitude == 0) return false;
    if (isCheckedSigned(left)) return !(d.negative and d.magnitude == 1);
    return !d.negative;
}

pub fn isCheckedUnsigned(kind: TypeClass) bool {
    return switch (kind) {
        .checked_u8, .checked_u16, .checked_u32, .checked_u64, .checked_u128, .checked_usize => true,
        else => false,
    };
}

pub fn isCheckedSigned(kind: TypeClass) bool {
    return switch (kind) {
        .checked_i8, .checked_i16, .checked_i32, .checked_i64, .checked_i128, .checked_isize => true,
        else => false,
    };
}

pub fn isPointerLike(kind: TypeClass) bool {
    return switch (kind) {
        .pointer, .raw_many_pointer, .slice, .c_void_pointer, .nullable_pointer, .nullable_c_void_pointer => true,
        else => false,
    };
}

pub fn isNullableValue(kind: TypeClass) bool {
    return switch (kind) {
        .nullable_pointer, .nullable_c_void_pointer, .nullable_dyn_trait, .nullable_value => true,
        else => false,
    };
}

pub fn isIndexType(kind: TypeClass) bool {
    return switch (kind) {
        .checked_usize, .int_literal, .never, .unknown => true,
        else => false,
    };
}

pub fn isIndexableBase(kind: TypeClass) bool {
    return switch (kind) {
        .array, .slice, .never, .unknown => true,
        else => false,
    };
}

pub fn isForIterableBase(kind: TypeClass) bool {
    return switch (kind) {
        .array, .slice, .never, .unknown => true,
        else => false,
    };
}

pub fn isConditionType(kind: TypeClass) bool {
    return switch (kind) {
        .bool, .never, .unknown => true,
        else => false,
    };
}

pub fn isTryOperand(kind: TypeClass) bool {
    return switch (kind) {
        .result, .nullable_pointer, .nullable_c_void_pointer, .nullable_dyn_trait, .nullable_value, .never, .unknown => true,
        else => false,
    };
}

pub fn tryResultType(kind: TypeClass) TypeClass {
    return switch (kind) {
        .nullable_pointer => .pointer,
        .nullable_c_void_pointer => .c_void_pointer,
        // The narrowed `*dyn Trait` carries no specific class - dispatch keys off
        // the narrowed binding's TypeExpr, like a bare dyn.
        .nullable_dyn_trait => .unknown,
        // The narrowed payload's specific class is recovered from the binding's
        // TypeExpr (nullableInnerType) at the `if let` / switch site; the class
        // itself is left unknown here (parallel to `.result`).
        .nullable_value => .unknown,
        .result => .unknown,
        else => kind,
    };
}

pub fn isOpaqueAddressClass(kind: TypeClass) bool {
    return switch (kind) {
        .paddr, .vaddr, .dma_addr, .user_ptr, .mmio_ptr, .phys_ptr => true,
        else => false,
    };
}

pub fn isAddressClass(kind: TypeClass) bool {
    return switch (kind) {
        .paddr, .vaddr, .dma_addr, .user_ptr, .mmio_ptr, .phys_ptr => true,
        else => false,
    };
}

pub fn isBitcastLayoutClass(kind: TypeClass) bool {
    return isCheckedInt(kind) or isFloat(kind) or kind == .bool or isPointerLike(kind) or isAddressClass(kind);
}

pub fn isDerefablePointerClass(kind: TypeClass) bool {
    return switch (kind) {
        .pointer, .raw_many_pointer, .slice, .c_void_pointer, .nullable_pointer, .nullable_c_void_pointer => true,
        else => false,
    };
}

pub fn isRuntimePointerDerefClass(kind: TypeClass) bool {
    return switch (kind) {
        .pointer, .raw_many_pointer, .c_void_pointer, .nullable_pointer, .nullable_c_void_pointer, .paddr, .vaddr, .dma_addr, .user_ptr, .mmio_ptr, .phys_ptr => true,
        else => false,
    };
}

pub fn isNonNullPointerLike(kind: TypeClass) bool {
    return switch (kind) {
        .pointer, .raw_many_pointer, .c_void_pointer => true,
        else => false,
    };
}

pub fn isSingleObjectPointerLike(kind: TypeClass) bool {
    return switch (kind) {
        .pointer, .c_void_pointer => true,
        else => false,
    };
}

pub fn isNullablePointerLike(kind: TypeClass) bool {
    return switch (kind) {
        .nullable_pointer, .nullable_c_void_pointer => true,
        else => false,
    };
}

pub fn isForbiddenBitwisePolicy(kind: TypeClass) bool {
    return switch (kind) {
        .sat, .serial, .counter => true,
        else => false,
    };
}

pub fn isForbiddenOrderingDomain(kind: TypeClass) bool {
    return switch (kind) {
        .wrap, .serial, .counter => true,
        else => false,
    };
}

pub fn isArithmeticDomain(kind: TypeClass) bool {
    return switch (kind) {
        .wrap, .sat, .serial, .counter => true,
        else => false,
    };
}

pub fn isFloat(kind: TypeClass) bool {
    return kind == .f32 or kind == .f64;
}

pub fn isFloatish(kind: TypeClass) bool {
    return isFloat(kind) or kind == .float_literal;
}

// IEEE floating-point arithmetic never raises a language trap: division by zero
// and overflow yield infinities or NaN rather than `.DivideByZero`/`.IntegerOverflow`.
pub fn isNonTrappingFloatOp(op: ast.BinaryOp, left: TypeClass, right: TypeClass) bool {
    if (!isFloatish(left) or !isFloatish(right)) return false;
    if (!isFloat(left) and !isFloat(right)) return false;
    return switch (op) {
        .add, .sub, .mul, .div => true,
        else => false,
    };
}

pub fn isDiagnosticNeutralOperand(kind: TypeClass) bool {
    return kind == .unknown or kind == .never;
}

pub fn isArithmeticOperand(kind: TypeClass) bool {
    return isDiagnosticNeutralOperand(kind) or isIntegerLike(kind) or isArithmeticDomain(kind) or isFloatish(kind) or kind == .secret;
}

pub fn isBitwiseOperand(kind: TypeClass) bool {
    return isDiagnosticNeutralOperand(kind) or isCheckedUnsigned(kind) or kind == .int_literal or kind == .wrap or kind == .secret;
}

pub fn isOrderedComparisonOperand(kind: TypeClass) bool {
    return isArithmeticOperand(kind);
}

pub fn isEqualityOperand(kind: TypeClass) bool {
    return isDiagnosticNeutralOperand(kind) or
        isIntegerLike(kind) or
        isArithmeticDomain(kind) or
        isFloatish(kind) or
        kind == .bool or
        kind == .secret or
        isPointerLike(kind) or
        kind == .nullable_value or
        kind == .null_literal;
}

pub fn equalityOperandsCompatible(left: TypeClass, right: TypeClass) bool {
    if (!isEqualityOperand(left) or !isEqualityOperand(right)) return false;
    if (isDiagnosticNeutralOperand(left) or isDiagnosticNeutralOperand(right)) return true;
    if (left == .secret or right == .secret) {
        return (left == .secret or isIntegerLike(left)) and (right == .secret or isIntegerLike(right));
    }
    // A value optional `?T` (tagged repr) compares only against `null` (present tag test).
    if (left == .nullable_value or right == .nullable_value) {
        return (left == .nullable_value and right == .null_literal) or (right == .nullable_value and left == .null_literal);
    }
    if (left == .null_literal or right == .null_literal) return isPointerLike(left) or isPointerLike(right);
    if (left == .bool or right == .bool) return left == .bool and right == .bool;
    if (isPointerLike(left) or isPointerLike(right)) return isPointerLike(left) and isPointerLike(right);
    if (isArithmeticDomain(left) or isArithmeticDomain(right)) return left == right;
    if (isFloatish(left) or isFloatish(right)) return floatOperandsCompatible(left, right);
    return isIntegerLike(left) and isIntegerLike(right);
}

pub fn floatOperandsCompatible(left: TypeClass, right: TypeClass) bool {
    if (!isFloatish(left) or !isFloatish(right)) return false;
    if (isFloat(left) and isFloat(right)) return left == right;
    return true;
}

pub fn arithmeticDomainsImplicitlyMix(left: TypeClass, right: TypeClass) bool {
    if (left == .unknown or right == .unknown or left == .never or right == .never) return false;
    if (isArithmeticDomain(left) or isArithmeticDomain(right)) return left != right;
    return false;
}

pub fn isNoTrapArithmeticDomainOp(op: ast.BinaryOp, left: TypeClass, right: TypeClass) bool {
    if (left != right) return false;
    return switch (left) {
        .wrap => switch (op) {
            .add, .sub, .mul => true,
            else => false,
        },
        .sat => switch (op) {
            .add, .sub, .mul => true,
            else => false,
        },
        else => false,
    };
}

pub fn mergeArithmetic(left: TypeClass, right: TypeClass) TypeClass {
    if (left == .secret or right == .secret) return .secret;
    if (left == .f64 or right == .f64) return .f64;
    if (left == .f32 or right == .f32) return .f32;
    if (left == .float_literal or right == .float_literal) return .float_literal;
    if (left == .wrap or right == .wrap) return .wrap;
    if (left == .sat or right == .sat) return .sat;
    if (isCheckedSigned(left)) return left;
    if (isCheckedSigned(right)) return right;
    if (isCheckedUnsigned(left)) return left;
    if (isCheckedUnsigned(right)) return right;
    return .unknown;
}

pub fn classifyGenericTypeName(name: []const u8) TypeClass {
    if (std.mem.eql(u8, name, "Result")) return .result;
    if (std.mem.eql(u8, name, "atomic")) return .atomic;
    if (std.mem.eql(u8, name, "DmaBuf")) return .dma_buf;
    if (std.mem.eql(u8, name, "UserPtr")) return .user_ptr;
    if (std.mem.eql(u8, name, "MmioPtr")) return .mmio_ptr;
    if (std.mem.eql(u8, name, "PhysPtr")) return .phys_ptr;
    if (std.mem.eql(u8, name, "Secret")) return .secret;
    if (std.mem.eql(u8, name, "wrap")) return .wrap;
    if (std.mem.eql(u8, name, "sat")) return .sat;
    if (std.mem.eql(u8, name, "serial")) return .serial;
    if (std.mem.eql(u8, name, "counter")) return .counter;
    if (std.mem.eql(u8, name, "Duration")) return .duration;
    return .unknown;
}

pub fn isConversionName(name: []const u8) bool {
    return std.mem.eql(u8, name, "from") or
        std.mem.eql(u8, name, "try_from") or
        std.mem.eql(u8, name, "trap_from") or
        std.mem.eql(u8, name, "wrap_from") or
        std.mem.eql(u8, name, "sat_from") or
        std.mem.eql(u8, name, "from_mod");
}

pub fn isNarrowingConversionName(name: []const u8) bool {
    return std.mem.eql(u8, name, "try_from") or
        std.mem.eql(u8, name, "trap_from") or
        std.mem.eql(u8, name, "wrap_from") or
        std.mem.eql(u8, name, "sat_from");
}

pub fn isSerialOperationName(name: []const u8) bool {
    return std.mem.eql(u8, name, "before") or
        std.mem.eql(u8, name, "after") or
        std.mem.eql(u8, name, "distance") or
        std.mem.eql(u8, name, "compare");
}

pub fn isCounterOperationName(name: []const u8) bool {
    return std.mem.eql(u8, name, "delta_mod") or
        std.mem.eql(u8, name, "elapsed_assume_within") or
        std.mem.eql(u8, name, "elapsed_bounded");
}

// Number of arguments a serial/counter domain operation takes. The first two are
// always the domain operands; a third (where present) is an external interval.
pub fn domainOperationArgCount(op: []const u8) usize {
    if (std.mem.eql(u8, op, "elapsed_assume_within") or std.mem.eql(u8, op, "elapsed_bounded")) return 3;
    return 2;
}

pub fn isIntegerScalarName(name: []const u8) bool {
    return switch (classifyTypeName(name)) {
        .checked_u8, .checked_u16, .checked_u32, .checked_u64, .checked_u128, .checked_usize, .checked_i8, .checked_i16, .checked_i32, .checked_i64, .checked_i128, .checked_isize => true,
        else => false,
    };
}

pub fn isFloatScalarName(name: []const u8) bool {
    return std.mem.eql(u8, name, "f32") or std.mem.eql(u8, name, "f64");
}

pub fn classifyTypeName(name: []const u8) TypeClass {
    if (std.mem.eql(u8, name, "bool")) return .bool;
    if (std.mem.eql(u8, name, "u8")) return .checked_u8;
    if (std.mem.eql(u8, name, "u16")) return .checked_u16;
    if (std.mem.eql(u8, name, "u32")) return .checked_u32;
    if (std.mem.eql(u8, name, "u64")) return .checked_u64;
    if (std.mem.eql(u8, name, "u128")) return .checked_u128;
    if (std.mem.eql(u8, name, "usize")) return .checked_usize;
    if (std.mem.eql(u8, name, "i8")) return .checked_i8;
    if (std.mem.eql(u8, name, "i16")) return .checked_i16;
    if (std.mem.eql(u8, name, "i32")) return .checked_i32;
    if (std.mem.eql(u8, name, "i64")) return .checked_i64;
    if (std.mem.eql(u8, name, "i128")) return .checked_i128;
    if (std.mem.eql(u8, name, "isize")) return .checked_isize;
    if (std.mem.eql(u8, name, "f32")) return .f32;
    if (std.mem.eql(u8, name, "f64")) return .f64;
    if (std.mem.eql(u8, name, "Order")) return .order;
    if (std.mem.eql(u8, name, "never")) return .never;
    if (std.mem.eql(u8, name, "void")) return .void;
    if (std.mem.eql(u8, name, "bool")) return .bool;
    if (std.mem.eql(u8, name, "PAddr")) return .paddr;
    if (std.mem.eql(u8, name, "VAddr")) return .vaddr;
    if (std.mem.eql(u8, name, "DmaAddr")) return .dma_addr;
    return .unknown;
}

pub fn classifyType(ty: ast.TypeExpr) TypeClass {
    return switch (ty.kind) {
        .name => |name| classifyTypeName(name.text),
        .pointer => |node| if (typeNameEql(node.child.*, "c_void")) .c_void_pointer else .pointer,
        .raw_many_pointer => |node| if (typeNameEql(node.child.*, "c_void")) .c_void_pointer else .raw_many_pointer,
        .slice => |node| if (typeNameEql(node.child.*, "c_void")) .c_void_pointer else .slice,
        .array => .array,
        .nullable => |child| classifyNullableType(child.*),
        .qualified => |node| classifyType(node.child.*),
        .generic => |node| classifyGenericTypeName(node.base.text),
        .fn_pointer => .fn_pointer,
        .closure_type => .closure,
        else => .unknown,
    };
}

pub fn classifyTypeCtx(ty: ast.TypeExpr, ctx: Context) TypeClass {
    const resolved = resolveAliasType(ty, ctx);
    // A value optional `?Struct`/`?EnumAlias`/… whose payload is a NAMED aggregate
    // classifies as `.unknown` under the ctx-free `classifyType` (it has no type
    // tables). With ctx we can tell a concrete named value type (→ value optional)
    // from a bare generic type parameter (→ stays unknown, may be a pointer).
    if (classifyType(resolved) == .unknown) {
        if (nullableInnerType(resolved)) |inner| {
            const resolved_inner = resolveAliasType(inner, ctx);
            if (isDynTraitTypeExpr(resolved_inner)) return .nullable_dyn_trait;
            if (namedTypeIsKnownValue(resolved_inner, ctx)) return .nullable_value;
        }
    }
    return classifyType(resolved);
}

// True when `ty` names a concrete, sized value type known to the module (a struct,
// packed-bits, enum, or tagged union) — as opposed to a bare generic type parameter.
fn namedTypeIsKnownValue(ty: ast.TypeExpr, ctx: Context) bool {
    const name = typeName(ty) orelse return false;
    if (ctx.type_params) |tps| {
        if (tps.contains(name)) return false;
    }
    if (ctx.structs) |m| if (m.contains(name)) return true;
    if (ctx.packed_bits) |m| if (m.contains(name)) return true;
    if (ctx.enums) |m| if (m.contains(name)) return true;
    if (ctx.tagged_unions) |m| if (m.contains(name)) return true;
    return false;
}

pub fn resolveAliasType(ty: ast.TypeExpr, ctx: Context) ast.TypeExpr {
    return resolveAliasTypeDepth(ty, ctx, 0);
}

pub fn nullableInnerType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .nullable => |child| child.*,
        .qualified => |node| nullableInnerType(node.child.*),
        else => null,
    };
}

pub fn resultPayloadType(ty: ast.TypeExpr, tag: []const u8) ?ast.TypeExpr {
    return switch (ty.kind) {
        .generic => |node| {
            if (!std.mem.eql(u8, node.base.text, "Result") or node.args.len != 2) return null;
            if (std.mem.eql(u8, tag, "ok")) return node.args[0];
            if (std.mem.eql(u8, tag, "err")) return node.args[1];
            return null;
        },
        .qualified => |node| resultPayloadType(node.child.*, tag),
        else => null,
    };
}

pub fn atomicPayloadType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .generic => |node| {
            if (!std.mem.eql(u8, node.base.text, "atomic") or node.args.len != 1) return null;
            return node.args[0];
        },
        .qualified => |node| atomicPayloadType(node.child.*),
        else => null,
    };
}

pub fn maybeUninitPayloadType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .generic => |node| {
            if (!std.mem.eql(u8, node.base.text, "MaybeUninit") or node.args.len != 1) return null;
            return node.args[0];
        },
        .qualified => |node| maybeUninitPayloadType(node.child.*),
        else => null,
    };
}

fn resolveAliasTypeDepth(ty: ast.TypeExpr, ctx: Context, depth: usize) ast.TypeExpr {
    if (depth > 64) return ty;
    return switch (ty.kind) {
        .name => |name| {
            const aliases = ctx.type_aliases orelse return ty;
            const target = aliases.get(name.text) orelse return ty;
            if (typeName(target)) |target_name| {
                if (std.mem.eql(u8, target_name, name.text)) return ty;
            }
            return resolveAliasTypeDepth(target, ctx, depth + 1);
        },
        .qualified => |node| resolveAliasTypeDepth(node.child.*, ctx, depth),
        else => ty,
    };
}

fn classifyNullableType(child: ast.TypeExpr) TypeClass {
    const child_class = classifyType(child);
    return switch (child_class) {
        .c_void_pointer => .nullable_c_void_pointer,
        .pointer, .raw_many_pointer => .nullable_pointer,
        // A `*dyn Trait` classifies as `.unknown` (dispatch keys off the TypeExpr
        // kind, not the class), so recognize the trait-object niche explicitly.
        // `.unknown` (a bare generic type param, `*dyn`, or a named struct/enum
        // without ctx) stays unknown here; classifyTypeCtx recovers a concrete
        // named value payload (→ nullable_value) with the module's type tables.
        .unknown => if (isDynTraitTypeExpr(child)) .nullable_dyn_trait else .unknown,
        // A sized, KNOWN scalar/domain/address payload is a value optional (tagged
        // repr). Arrays, slices, fn-pointers, secret/atomic/dma views etc. are NOT
        // covered (deferred); they fall through to unknown.
        else => if (isValueOptionalPayloadClass(child_class)) .nullable_value else .unknown,
    };
}

// The payload classes that a `?T` value optional supports (tagged `{present,value}`
// repr). Kept in sync with mir_type.valueTypeFrom* and the backends' opt registries.
pub fn isValueOptionalPayloadClass(kind: TypeClass) bool {
    return isCheckedInt(kind) or isFloat(kind) or isOpaqueAddressClass(kind) or kind == .bool;
}

// True when `ty` is a `*dyn Trait` fat pointer (possibly behind `const`/`mut`
// qualifiers). Alias resolution is not applied here (classifyType has no ctx); a
// direct `?*dyn Trait` is the supported form.
fn isDynTraitTypeExpr(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .dyn_trait => true,
        .qualified => |node| isDynTraitTypeExpr(node.child.*),
        else => false,
    };
}

fn typeNameEql(ty: ast.TypeExpr, expected: []const u8) bool {
    return if (typeName(ty)) |name| std.mem.eql(u8, name, expected) else false;
}

pub fn isPointerLikeClass(class: TypeClass) bool {
    return isNonNullPointerLike(class) or isNullablePointerLike(class);
}

pub fn isConstStorageType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .pointer => |node| node.mutability == .@"const",
        .raw_many_pointer => |node| node.mutability == .@"const",
        .slice => |node| node.mutability == .@"const",
        .nullable => |child| isConstStorageType(child.*),
        .qualified => |node| isConstStorageType(node.child.*),
        else => false,
    };
}

pub const ViewKind = enum {
    pointer,
    raw_many_pointer,
    slice,
};

pub const ViewType = struct {
    kind: ViewKind,
    mutability: ast.Mutability,
    nullable: bool = false,
};

pub fn viewType(ty: ast.TypeExpr) ?ViewType {
    return switch (ty.kind) {
        .pointer => |node| .{ .kind = .pointer, .mutability = node.mutability },
        .raw_many_pointer => |node| .{ .kind = .raw_many_pointer, .mutability = node.mutability },
        .slice => |node| .{ .kind = .slice, .mutability = node.mutability },
        .nullable => |child| {
            var view = viewType(child.*) orelse return null;
            view.nullable = true;
            return view;
        },
        .qualified => |node| viewType(node.child.*),
        else => null,
    };
}

pub fn viewElementType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .pointer => |node| node.child.*,
        .raw_many_pointer => |node| node.child.*,
        .slice => |node| node.child.*,
        .nullable => |child| viewElementType(child.*),
        .qualified => |node| viewElementType(node.child.*),
        else => null,
    };
}

pub fn isCVoidPointerClass(kind: TypeClass) bool {
    return switch (kind) {
        .c_void_pointer, .nullable_c_void_pointer => true,
        else => false,
    };
}

pub fn isPrimitiveLayoutType(name: []const u8) bool {
    return classifyTypeName(name) != .unknown;
}

pub fn isFixedUnsignedMmioWidth(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .name => |name| std.mem.eql(u8, name.text, "u8") or
            std.mem.eql(u8, name.text, "u16") or
            std.mem.eql(u8, name.text, "u32") or
            std.mem.eql(u8, name.text, "u64"),
        .qualified => |node| isFixedUnsignedMmioWidth(node.child.*),
        else => false,
    };
}

pub fn sameTypeSyntax(left: ast.TypeExpr, right: ast.TypeExpr) bool {
    if (std.meta.activeTag(left.kind) != std.meta.activeTag(right.kind)) return false;
    return switch (left.kind) {
        .name => |left_name| std.mem.eql(u8, left_name.text, switch (right.kind) {
            .name => |right_name| right_name.text,
            else => unreachable,
        }),
        .enum_literal => |left_name| std.mem.eql(u8, left_name.text, switch (right.kind) {
            .enum_literal => |right_name| right_name.text,
            else => unreachable,
        }),
        .member => |left_node| blk: {
            const right_node = switch (right.kind) {
                .member => |node| node,
                else => unreachable,
            };
            break :blk sameTypeSyntax(left_node.base.*, right_node.base.*) and
                std.mem.eql(u8, left_node.field.text, right_node.field.text);
        },
        .nullable => |left_child| sameTypeSyntax(left_child.*, switch (right.kind) {
            .nullable => |right_child| right_child.*,
            else => unreachable,
        }),
        .qualified => |left_node| blk: {
            const right_node = switch (right.kind) {
                .qualified => |node| node,
                else => unreachable,
            };
            break :blk left_node.mutability == right_node.mutability and
                sameTypeSyntax(left_node.child.*, right_node.child.*);
        },
        .pointer => |left_node| blk: {
            const right_node = switch (right.kind) {
                .pointer => |node| node,
                else => unreachable,
            };
            break :blk left_node.mutability == right_node.mutability and
                sameTypeSyntax(left_node.child.*, right_node.child.*);
        },
        .raw_many_pointer => |left_node| blk: {
            const right_node = switch (right.kind) {
                .raw_many_pointer => |node| node,
                else => unreachable,
            };
            break :blk left_node.mutability == right_node.mutability and
                sameTypeSyntax(left_node.child.*, right_node.child.*);
        },
        .slice => |left_node| blk: {
            const right_node = switch (right.kind) {
                .slice => |node| node,
                else => unreachable,
            };
            break :blk left_node.mutability == right_node.mutability and
                sameTypeSyntax(left_node.child.*, right_node.child.*);
        },
        .array => |left_node| blk: {
            const right_node = switch (right.kind) {
                .array => |node| node,
                else => unreachable,
            };
            break :blk sameExprSyntax(left_node.len, right_node.len) and
                sameTypeSyntax(left_node.child.*, right_node.child.*);
        },
        .generic => |left_node| blk: {
            const right_node = switch (right.kind) {
                .generic => |node| node,
                else => unreachable,
            };
            if (!std.mem.eql(u8, left_node.base.text, right_node.base.text)) break :blk false;
            if (left_node.args.len != right_node.args.len) break :blk false;
            for (left_node.args, right_node.args) |left_arg, right_arg| {
                if (!sameTypeSyntax(left_arg, right_arg)) break :blk false;
            }
            break :blk true;
        },
        .fn_pointer => |left_node| blk: {
            const right_node = switch (right.kind) {
                .fn_pointer => |node| node,
                else => unreachable,
            };
            if (left_node.params.len != right_node.params.len) break :blk false;
            for (left_node.params, right_node.params) |left_param, right_param| {
                if (!sameTypeSyntax(left_param, right_param)) break :blk false;
            }
            break :blk sameTypeSyntax(left_node.ret.*, right_node.ret.*);
        },
        .closure_type => |left_node| blk: {
            const right_node = switch (right.kind) {
                .closure_type => |node| node,
                else => unreachable,
            };
            if (left_node.params.len != right_node.params.len) break :blk false;
            for (left_node.params, right_node.params) |left_param, right_param| {
                if (!sameTypeSyntax(left_param, right_param)) break :blk false;
            }
            break :blk sameTypeSyntax(left_node.ret.*, right_node.ret.*);
        },
        .dyn_trait => |left_node| blk: {
            const right_node = switch (right.kind) {
                .dyn_trait => |node| node,
                else => unreachable,
            };
            break :blk left_node.mutability == right_node.mutability and
                std.mem.eql(u8, left_node.trait_name.text, right_node.trait_name.text);
        },
    };
}

// Trait-conformance signature comparison: like `sameTypeSyntax`, but the trait
// side (`trait_ty`) may write `Self` in ANY position (parameter or return type,
// at any depth: `Self`, `*Self`, `*mut Self`, `*const Self`, `[]Self`, `?Self`,
// nested in generics/tuples via the recursive descent). Wherever the trait writes
// the bare name `Self`, it must match the concrete impl type `self_name` on the
// impl side. Everything else compares identically to `sameTypeSyntax`, so a
// GENUINE mismatch (impl writes `*OtherType` where the trait says `*Self`, or a
// different concrete type on both sides) is still rejected.
pub fn sameTraitTypeSyntax(trait_ty: ast.TypeExpr, impl_ty: ast.TypeExpr, self_name: []const u8) bool {
    // A bare `Self` on the trait side stands for the impl type. It matches either
    // the concrete `self_name` or a literal `Self` on the impl side (the impl may
    // legitimately keep writing `Self`).
    switch (trait_ty.kind) {
        .name => |trait_name| if (std.mem.eql(u8, trait_name.text, "Self")) {
            return switch (impl_ty.kind) {
                .name => |impl_name| std.mem.eql(u8, impl_name.text, self_name) or
                    std.mem.eql(u8, impl_name.text, "Self"),
                else => false,
            };
        },
        else => {},
    }
    if (std.meta.activeTag(trait_ty.kind) != std.meta.activeTag(impl_ty.kind)) return false;
    return switch (trait_ty.kind) {
        .name => |trait_name| std.mem.eql(u8, trait_name.text, switch (impl_ty.kind) {
            .name => |impl_name| impl_name.text,
            else => unreachable,
        }),
        .enum_literal => |trait_name| std.mem.eql(u8, trait_name.text, switch (impl_ty.kind) {
            .enum_literal => |impl_name| impl_name.text,
            else => unreachable,
        }),
        .member => |left_node| blk: {
            const right_node = switch (impl_ty.kind) {
                .member => |node| node,
                else => unreachable,
            };
            break :blk sameTraitTypeSyntax(left_node.base.*, right_node.base.*, self_name) and
                std.mem.eql(u8, left_node.field.text, right_node.field.text);
        },
        .nullable => |left_child| sameTraitTypeSyntax(left_child.*, switch (impl_ty.kind) {
            .nullable => |right_child| right_child.*,
            else => unreachable,
        }, self_name),
        .qualified => |left_node| blk: {
            const right_node = switch (impl_ty.kind) {
                .qualified => |node| node,
                else => unreachable,
            };
            break :blk left_node.mutability == right_node.mutability and
                sameTraitTypeSyntax(left_node.child.*, right_node.child.*, self_name);
        },
        .pointer => |left_node| blk: {
            const right_node = switch (impl_ty.kind) {
                .pointer => |node| node,
                else => unreachable,
            };
            break :blk left_node.mutability == right_node.mutability and
                sameTraitTypeSyntax(left_node.child.*, right_node.child.*, self_name);
        },
        .raw_many_pointer => |left_node| blk: {
            const right_node = switch (impl_ty.kind) {
                .raw_many_pointer => |node| node,
                else => unreachable,
            };
            break :blk left_node.mutability == right_node.mutability and
                sameTraitTypeSyntax(left_node.child.*, right_node.child.*, self_name);
        },
        .slice => |left_node| blk: {
            const right_node = switch (impl_ty.kind) {
                .slice => |node| node,
                else => unreachable,
            };
            break :blk left_node.mutability == right_node.mutability and
                sameTraitTypeSyntax(left_node.child.*, right_node.child.*, self_name);
        },
        .array => |left_node| blk: {
            const right_node = switch (impl_ty.kind) {
                .array => |node| node,
                else => unreachable,
            };
            break :blk sameExprSyntax(left_node.len, right_node.len) and
                sameTraitTypeSyntax(left_node.child.*, right_node.child.*, self_name);
        },
        .generic => |left_node| blk: {
            const right_node = switch (impl_ty.kind) {
                .generic => |node| node,
                else => unreachable,
            };
            if (!std.mem.eql(u8, left_node.base.text, right_node.base.text)) break :blk false;
            if (left_node.args.len != right_node.args.len) break :blk false;
            for (left_node.args, right_node.args) |left_arg, right_arg| {
                if (!sameTraitTypeSyntax(left_arg, right_arg, self_name)) break :blk false;
            }
            break :blk true;
        },
        .fn_pointer => |left_node| blk: {
            const right_node = switch (impl_ty.kind) {
                .fn_pointer => |node| node,
                else => unreachable,
            };
            if (left_node.params.len != right_node.params.len) break :blk false;
            for (left_node.params, right_node.params) |left_param, right_param| {
                if (!sameTraitTypeSyntax(left_param, right_param, self_name)) break :blk false;
            }
            break :blk sameTraitTypeSyntax(left_node.ret.*, right_node.ret.*, self_name);
        },
        .closure_type => |left_node| blk: {
            const right_node = switch (impl_ty.kind) {
                .closure_type => |node| node,
                else => unreachable,
            };
            if (left_node.params.len != right_node.params.len) break :blk false;
            for (left_node.params, right_node.params) |left_param, right_param| {
                if (!sameTraitTypeSyntax(left_param, right_param, self_name)) break :blk false;
            }
            break :blk sameTraitTypeSyntax(left_node.ret.*, right_node.ret.*, self_name);
        },
        .dyn_trait => |left_node| blk: {
            const right_node = switch (impl_ty.kind) {
                .dyn_trait => |node| node,
                else => unreachable,
            };
            break :blk left_node.mutability == right_node.mutability and
                std.mem.eql(u8, left_node.trait_name.text, right_node.trait_name.text);
        },
    };
}

fn sameExprSyntax(left: ast.Expr, right: ast.Expr) bool {
    if (std.meta.activeTag(left.kind) != std.meta.activeTag(right.kind)) return false;
    return switch (left.kind) {
        .ident => |left_ident| std.mem.eql(u8, left_ident.text, switch (right.kind) {
            .ident => |right_ident| right_ident.text,
            else => unreachable,
        }),
        .int_literal => |left_text| std.mem.eql(u8, left_text, switch (right.kind) {
            .int_literal => |right_text| right_text,
            else => unreachable,
        }),
        .bool_literal => |left_value| left_value == switch (right.kind) {
            .bool_literal => |right_value| right_value,
            else => unreachable,
        },
        .null_literal, .uninit_literal, .unreachable_expr, .void_literal => true,
        .enum_literal => |left_ident| std.mem.eql(u8, left_ident.text, switch (right.kind) {
            .enum_literal => |right_ident| right_ident.text,
            else => unreachable,
        }),
        .grouped => |left_inner| sameExprSyntax(left_inner.*, switch (right.kind) {
            .grouped => |right_inner| right_inner.*,
            else => unreachable,
        }),
        else => false,
    };
}
