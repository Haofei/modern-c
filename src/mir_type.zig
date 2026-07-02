const std = @import("std");

const ast = @import("ast.zig");
const mir_model = @import("mir_model.zig");
const mir_summary = @import("mir_summary.zig");
const mir_syntax = @import("mir_syntax.zig");
const mir_verify_util = @import("mir_verify_util.zig");
const numeric = @import("numeric.zig");

const AddressClass = mir_model.AddressClass;
const ArithmeticDomain = mir_verify_util.ArithmeticDomain;
const EnumSummary = mir_summary.EnumSummary;
const IntBounds = numeric.IntBounds;
const PackedBitsSummary = mir_summary.PackedBitsSummary;
const PointerShape = mir_model.PointerShape;
const PointerKind = mir_model.PointerKind;
const StructSummary = mir_summary.StructSummary;
const ValueType = mir_model.ValueType;

const integerLiteralValue = numeric.integerLiteralValue;
const maxUnsigned = numeric.maxUnsigned;
const signedBounds = numeric.signedBounds;
const typeText = mir_syntax.typeText;

pub fn isVoidLike(ty: ValueType) bool {
    return ty == .void;
}

pub fn nullabilityFinding(target_ty: ValueType, source_ty: ValueType) ?[]const u8 {
    if (target_ty == .pointer and source_ty == .nullable_pointer) {
        return switch (source_ty) {
            .nullable_pointer => |shape| if (isNullPointerShape(shape)) "null_to_nonnull" else "nullable_to_nonnull",
            else => null,
        };
    }
    return null;
}

pub fn conversionFinding(ctx: mir_verify_util.ConversionContext, target: ValueType, source: ValueType) []const u8 {
    // Arrays never implicitly decay to pointers (section 9), in any context.
    if (source == .array and isPointerLikeType(target)) return "array_to_pointer_decay";
    const c_void_conversion = isCVoidPointerConversion(target, source);
    const pointer_conversion = isPointerViewConversion(target, source);
    return switch (ctx) {
        .return_ => if (c_void_conversion) "return_c_void_conversion" else if (pointer_conversion) "return_pointer_conversion" else "return_type_mismatch",
        .initializer => if (c_void_conversion) "initializer_c_void_conversion" else if (pointer_conversion) "initializer_pointer_conversion" else "initializer_type_mismatch",
        .assignment => if (c_void_conversion) "assignment_c_void_conversion" else if (pointer_conversion) "assignment_pointer_conversion" else "assignment_type_mismatch",
        .call_arg => if (c_void_conversion) "call_arg_c_void_conversion" else if (pointer_conversion) "call_arg_pointer_conversion" else "call_arg_type_mismatch",
        .condition => "condition_type_mismatch",
    };
}

pub fn integerLiteralRangeFinding(target_ty: ValueType, expr: ast.Expr) ?[]const u8 {
    const value = integerLiteralValue(expr) orelse return null;
    const bounds = mirCheckedIntBounds(target_ty) orelse return null;
    if (value.negative) {
        if (!bounds.signed or value.magnitude > bounds.min_abs) return "integer_literal_out_of_range";
        return null;
    }
    if (value.magnitude > bounds.max) return "integer_literal_out_of_range";
    return null;
}

pub fn integerLiteralFitsTarget(target_ty: ValueType, expr: ast.Expr) bool {
    if (integerLiteralValue(expr) == null) return false;
    return mirCheckedIntBounds(target_ty) != null and integerLiteralRangeFinding(target_ty, expr) == null;
}

fn mirCheckedIntBounds(ty: ValueType) ?IntBounds {
    return switch (ty) {
        .integer => |name| checkedIntBoundsByName(name),
        else => null,
    };
}

pub fn checkedIntBoundsByName(name: []const u8) ?IntBounds {
    if (std.mem.eql(u8, name, "u8")) return .{ .signed = false, .max = maxUnsigned(8) };
    if (std.mem.eql(u8, name, "u16")) return .{ .signed = false, .max = maxUnsigned(16) };
    if (std.mem.eql(u8, name, "u32")) return .{ .signed = false, .max = maxUnsigned(32) };
    if (std.mem.eql(u8, name, "u64")) return .{ .signed = false, .max = maxUnsigned(64) };
    if (std.mem.eql(u8, name, "u128")) return .{ .signed = false, .max = maxUnsigned(128) };
    if (std.mem.eql(u8, name, "usize")) return .{ .signed = false, .max = maxUnsigned(64) };
    if (std.mem.eql(u8, name, "i8")) return signedBounds(8);
    if (std.mem.eql(u8, name, "i16")) return signedBounds(16);
    if (std.mem.eql(u8, name, "i32")) return signedBounds(32);
    if (std.mem.eql(u8, name, "i64")) return signedBounds(64);
    if (std.mem.eql(u8, name, "i128")) return signedBounds(128);
    if (std.mem.eql(u8, name, "isize")) return signedBounds(64);
    return null;
}

pub fn isTryCapableType(ty: ValueType) bool {
    return isResultType(ty) or ty == .nullable_pointer or ty == .nullable_value;
}

pub fn isResultType(ty: ValueType) bool {
    return std.meta.activeTag(ty) == .result;
}

pub fn isMirNullableValue(ty: ValueType) bool {
    return switch (ty) {
        .nullable_pointer, .nullable_dyn_trait, .nullable_value, .unknown, .never => true,
        else => false,
    };
}

pub fn isMirEnum(ty: ValueType) bool {
    return switch (ty) {
        .closed_enum, .open_enum => true,
        else => false,
    };
}

pub fn isMirIntegerLike(ty: ValueType) bool {
    return switch (ty) {
        .integer => true,
        else => false,
    };
}

pub fn unknownResultType() ValueType {
    return .{ .result = .{ .ok = "unknown", .err = "unknown" } };
}

pub fn typesAreCompatible(target: ValueType, source: ValueType) bool {
    if (target == .unknown or source == .unknown or source == .never) return true;
    if (target == .value or source == .value) return true;
    if (target == .nullable_pointer and source == .pointer) {
        return switch (target) {
            .nullable_pointer => |target_shape| samePointerShape(target_shape, switch (source) {
                .pointer => |source_shape| source_shape,
                else => unreachable,
            }),
            else => unreachable,
        };
    }
    if (target == .nullable_pointer and source == .nullable_pointer) {
        return switch (source) {
            .nullable_pointer => |source_shape| if (isNullPointerShape(source_shape)) true else samePointerShape(source_shape, switch (target) {
                .nullable_pointer => |target_shape| target_shape,
                else => unreachable,
            }),
            else => unreachable,
        };
    }
    // `?*dyn Trait` target accepts the checked coercion (a `*T`/`*dyn` source, `.pointer`),
    // a `null` literal (typed `.nullable_pointer`), and another `?*dyn` value. Sema already
    // enforced trait conformance (E_TRAIT_NOT_SATISFIED) and forge-safety (E_DYN_FORGE);
    // the MIR check is structural.
    if (target == .nullable_dyn_trait) {
        return switch (source) {
            .nullable_dyn_trait, .pointer, .nullable_pointer => true,
            else => false,
        };
    }
    // A value optional `?T` accepts: a `null` literal (typed `.nullable_pointer` with the
    // "null" shape), a present payload value assignable to T, and another `?T`. Sema already
    // enforced the payload match; the MIR check is structural (name-based).
    if (target == .nullable_value) {
        return switch (source) {
            .nullable_value => |src_child| std.mem.eql(u8, src_child, switch (target) {
                .nullable_value => |tgt_child| tgt_child,
                else => unreachable,
            }),
            .nullable_pointer => |shape| isNullPointerShape(shape),
            // A present payload value (integer/float/bool/struct/enum/address, or a
            // comptime literal). Sema validated the specific payload type.
            .integer, .float, .bool, .struct_, .closed_enum, .open_enum, .address => true,
            else => false,
        };
    }
    if (std.meta.activeTag(target) != std.meta.activeTag(source)) return false;
    return switch (target) {
        .integer => |target_name| std.mem.eql(u8, target_name, switch (source) {
            .integer => |source_name| source_name,
            else => unreachable,
        }) or std.mem.eql(u8, switch (source) {
            .integer => |source_name| source_name,
            else => unreachable,
        }, "comptime_int"),
        .float => |target_name| std.mem.eql(u8, target_name, switch (source) {
            .float => |source_name| source_name,
            else => unreachable,
        }) or std.mem.eql(u8, switch (source) {
            .float => |source_name| source_name,
            else => unreachable,
        }, "comptime_float"),
        .pointer => |target_shape| blk: {
            const source_shape = switch (source) {
                .pointer => |shape| shape,
                else => unreachable,
            };
            if (samePointerShape(target_shape, source_shape)) break :blk true;
            break :blk viewConstNarrowing(target_shape, source_shape);
        },
        .nullable_pointer => |target_shape| samePointerShape(target_shape, switch (source) {
            .nullable_pointer => |source_shape| source_shape,
            else => unreachable,
        }),
        .slice => true,
        .array => true,
        .closed_enum => |target_name| std.mem.eql(u8, target_name, switch (source) {
            .closed_enum => |source_name| source_name,
            else => unreachable,
        }),
        .open_enum => |target_name| std.mem.eql(u8, target_name, switch (source) {
            .open_enum => |source_name| source_name,
            else => unreachable,
        }),
        .struct_ => |target_name| std.mem.eql(u8, target_name, switch (source) {
            .struct_ => |source_name| source_name,
            else => unreachable,
        }),
        .address => |target_kind| target_kind == switch (source) {
            .address => |source_kind| source_kind,
            else => unreachable,
        },
        .result => |target_shape| blk: {
            const source_shape = switch (source) {
                .result => |shape| shape,
                else => unreachable,
            };
            break :blk std.mem.eql(u8, target_shape.ok, source_shape.ok) and std.mem.eql(u8, target_shape.err, source_shape.err);
        },
        // `.nullable_value` is fully handled by the early branch above (structural,
        // name-based); it never reaches this activeTag-equal switch.
        .void, .never, .bool, .contract, .branch, .trap, .unknown, .value, .nullable_dyn_trait, .nullable_value => true,
    };
}

pub fn isMirForIterable(ty: ValueType) bool {
    return switch (ty) {
        .array, .slice, .unknown, .never => true,
        .pointer => |shape| shape.kind == .slice,
        else => false,
    };
}

pub fn isMirIndexableBase(ty: ValueType) bool {
    return switch (ty) {
        .array, .slice, .unknown, .never => true,
        .pointer => |shape| shape.kind == .slice,
        else => false,
    };
}

pub fn isMirIndexType(ty: ValueType) bool {
    return switch (ty) {
        .integer => |name| std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "comptime_int"),
        .unknown, .never => true,
        else => false,
    };
}

pub fn isPointerViewConversion(target: ValueType, source: ValueType) bool {
    return isPointerLikeType(target) and isPointerLikeType(source);
}

pub fn isCVoidPointerConversion(target: ValueType, source: ValueType) bool {
    if (!isPointerLikeType(target) or !isPointerLikeType(source)) return false;
    return isCVoidPointerType(target) != isCVoidPointerType(source);
}

pub fn isCVoidPointerType(ty: ValueType) bool {
    return switch (ty) {
        .pointer => |shape| std.mem.eql(u8, shape.child, "c_void"),
        .nullable_pointer => |shape| std.mem.eql(u8, shape.child, "c_void"),
        else => false,
    };
}

pub fn isPointerLikeType(ty: ValueType) bool {
    return ty == .pointer or ty == .nullable_pointer;
}

// A `[]mut T` / `*mut T` source is compatible with a `[]const T` / `*const T` target (safe
// const-narrowing): both sides are the SAME pointer kind over the same element type and only
// the pointee's constness differs. Representation is identical (a plain pointer for a single
// object, a `{ptr,len}` fat pointer for a slice), so this is a no-op coercion (see sema
// constNarrowingViewConversionCtx). Scoped to single pointers (G30) + slices (G12); raw-many
// (`[*]mut`) const-narrows stay explicit.
pub fn viewConstNarrowing(target: PointerShape, source: PointerShape) bool {
    return target.kind == source.kind and
        (target.kind == .slice or target.kind == .single) and
        source.mutability == .mut and target.mutability != .mut and
        std.mem.eql(u8, target.child, source.child);
}

// True when `target`/`source` are the value types of a safe view const-narrowing (used by
// the MIR builder to treat an explicit `as` cast as transparent).
pub fn isViewConstNarrowCast(target: ValueType, source: ValueType) bool {
    const target_shape = switch (target) {
        .pointer => |shape| shape,
        else => return false,
    };
    const source_shape = switch (source) {
        .pointer => |shape| shape,
        else => return false,
    };
    return viewConstNarrowing(target_shape, source_shape);
}

pub fn samePointerShape(left: PointerShape, right: PointerShape) bool {
    return left.kind == right.kind and
        left.mutability == right.mutability and
        std.mem.eql(u8, left.child, right.child);
}

pub fn isNullPointerShape(shape: PointerShape) bool {
    return std.mem.eql(u8, shape.child, "null");
}

pub fn addressClassMismatch(target: ValueType, source: ValueType) ?AddressClass {
    const target_class = switch (target) {
        .address => |kind| kind,
        else => return null,
    };
    const source_class = switch (source) {
        .address => |kind| kind,
        else => return null,
    };
    if (target_class == source_class) return null;
    return source_class;
}

pub fn isDynTraitMirType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .dyn_trait => true,
        .qualified => |node| isDynTraitMirType(node.child.*),
        else => false,
    };
}

pub fn valueTypeFromExpr(expr: ast.Expr) ValueType {
    return switch (expr.kind) {
        .bool_literal => .bool,
        .void_literal => .void,
        .unreachable_expr => .never,
        .int_literal => .{ .integer = "comptime_int" },
        .float_literal => .{ .float = "comptime_float" },
        .null_literal => .{ .nullable_pointer = nullPointerShape() },
        else => .value,
    };
}

pub fn valueTypeFromType(ty: ast.TypeExpr, enums: *const std.StringHashMap(EnumSummary), structs: *const std.StringHashMap(StructSummary)) ValueType {
    return switch (ty.kind) {
        .name => |name| namedValueType(name.text, enums, structs),
        .enum_literal => .value,
        .member => .value,
        .nullable => |child| blk: {
            const child_ty = valueTypeFromType(child.*, enums, structs);
            break :blk switch (child_ty) {
                .pointer => |shape| .{ .nullable_pointer = shape },
                // A known, sized value payload → tagged value optional. `.value`
                // (a bare generic param / opaque) stays `.value` (may be a pointer).
                .integer, .float, .bool, .struct_, .closed_enum, .open_enum, .address => .{ .nullable_value = typeText(child.*) },
                else => if (isDynTraitMirType(child.*)) ValueType.nullable_dyn_trait else .value,
            };
        },
        .qualified => |node| valueTypeFromType(node.child.*, enums, structs),
        .pointer => |node| .{ .pointer = pointerShape(.single, node.mutability, node.child.*) },
        .raw_many_pointer => |node| .{ .pointer = pointerShape(.raw_many, node.mutability, node.child.*) },
        .slice => |node| .{ .pointer = pointerShape(.slice, node.mutability, node.child.*) },
        .array => .{ .array = "array" },
        .generic => |node| genericValueType(node, enums, structs),
    };
}

pub fn valueTypeFromTypeAlias(ty: ast.TypeExpr, enums: *const std.StringHashMap(EnumSummary), structs: *const std.StringHashMap(StructSummary), packed_bits: *const std.StringHashMap(PackedBitsSummary), aliases: *const std.StringHashMap(ast.TypeExpr)) ValueType {
    return valueTypeFromTypeAliasDepth(ty, enums, structs, packed_bits, aliases, 0);
}

fn valueTypeFromTypeAliasDepth(ty: ast.TypeExpr, enums: *const std.StringHashMap(EnumSummary), structs: *const std.StringHashMap(StructSummary), packed_bits: *const std.StringHashMap(PackedBitsSummary), aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ValueType {
    if (depth > 64) return .value;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved|
            valueTypeFromTypeAliasDepth(resolved, enums, structs, packed_bits, aliases, depth + 1)
        else
            namedValueTypeAlias(name.text, enums, structs, packed_bits),
        .enum_literal => .value,
        .member => .value,
        .fn_pointer => .value,
        .closure_type => .value,
        .dyn_trait => .value,
        .nullable => |child| blk: {
            const child_ty = valueTypeFromTypeAliasDepth(child.*, enums, structs, packed_bits, aliases, depth + 1);
            break :blk switch (child_ty) {
                .pointer => |shape| .{ .nullable_pointer = shape },
                .integer, .float, .bool, .struct_, .closed_enum, .open_enum, .address => .{ .nullable_value = typeText(aggregateTargetTypeAlias(child.*, aliases)) },
                else => if (isDynTraitMirType(child.*)) ValueType.nullable_dyn_trait else .value,
            };
        },
        .qualified => |node| valueTypeFromTypeAliasDepth(node.child.*, enums, structs, packed_bits, aliases, depth + 1),
        .pointer => |node| .{ .pointer = pointerShapeAlias(.single, node.mutability, node.child.*, aliases) },
        .raw_many_pointer => |node| .{ .pointer = pointerShapeAlias(.raw_many, node.mutability, node.child.*, aliases) },
        .slice => |node| .{ .pointer = pointerShapeAlias(.slice, node.mutability, node.child.*, aliases) },
        .array => .{ .array = "array" },
        .generic => |node| genericValueTypeAlias(node, enums, structs, packed_bits, aliases),
    };
}

pub fn valueTypeFromTypeName(name: []const u8, enums: *const std.StringHashMap(EnumSummary), structs: *const std.StringHashMap(StructSummary)) ValueType {
    if (std.mem.startsWith(u8, name, "*")) return .{ .pointer = pointerShapeFromName(name) };
    if (std.mem.startsWith(u8, name, "[*]")) return .{ .pointer = pointerShapeFromName(name) };
    if (std.mem.eql(u8, name, "[]")) return .{ .slice = "[]" };
    if (std.mem.eql(u8, name, "?")) return .{ .nullable_pointer = .{ .kind = .single, .mutability = .none, .child = "unknown" } };
    if (std.mem.eql(u8, name, "Result")) return unknownResultType();
    return namedValueType(name, enums, structs);
}

pub fn valueTypeFromTypeNameAlias(name: []const u8, enums: *const std.StringHashMap(EnumSummary), structs: *const std.StringHashMap(StructSummary), packed_bits: *const std.StringHashMap(PackedBitsSummary)) ValueType {
    if (std.mem.startsWith(u8, name, "*")) return .{ .pointer = pointerShapeFromName(name) };
    if (std.mem.startsWith(u8, name, "[*]")) return .{ .pointer = pointerShapeFromName(name) };
    if (std.mem.eql(u8, name, "[]")) return .{ .slice = "[]" };
    if (std.mem.eql(u8, name, "?")) return .{ .nullable_pointer = .{ .kind = .single, .mutability = .none, .child = "unknown" } };
    if (std.mem.eql(u8, name, "Result")) return unknownResultType();
    return namedValueTypeAlias(name, enums, structs, packed_bits);
}

pub fn aggregateTargetType(ty: ast.TypeExpr) ast.TypeExpr {
    return switch (ty.kind) {
        .qualified => |node| aggregateTargetType(node.child.*),
        else => ty,
    };
}

pub fn aggregateTargetTypeAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) ast.TypeExpr {
    return aggregateTargetTypeAliasDepth(ty, aliases, 0);
}

fn aggregateTargetTypeAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ast.TypeExpr {
    if (depth > 64) return ty;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| aggregateTargetTypeAliasDepth(resolved, aliases, depth + 1) else ty,
        .qualified => |node| aggregateTargetTypeAliasDepth(node.child.*, aliases, depth + 1),
        else => ty,
    };
}

pub fn arrayElementType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .array => |node| node.child.*,
        .qualified => |node| arrayElementType(node.child.*),
        else => null,
    };
}

pub fn arrayElementTypeAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) ?ast.TypeExpr {
    return arrayElementTypeAliasDepth(ty, aliases, 0);
}

fn arrayElementTypeAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ?ast.TypeExpr {
    if (depth > 64) return null;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| arrayElementTypeAliasDepth(resolved, aliases, depth + 1) else null,
        .array => |node| node.child.*,
        .qualified => |node| arrayElementTypeAliasDepth(node.child.*, aliases, depth + 1),
        else => null,
    };
}

pub fn storageElementTypeAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) ?ast.TypeExpr {
    return storageElementTypeAliasDepth(ty, aliases, 0);
}

fn storageElementTypeAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ?ast.TypeExpr {
    if (depth > 64) return null;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| storageElementTypeAliasDepth(resolved, aliases, depth + 1) else null,
        .pointer => |node| node.child.*,
        .raw_many_pointer => |node| node.child.*,
        .slice => |node| node.child.*,
        .array => |node| node.child.*,
        .qualified => |node| storageElementTypeAliasDepth(node.child.*, aliases, depth + 1),
        else => null,
    };
}

pub fn sliceTypeForBaseAlias(ty: ast.TypeExpr, span: ast.Span, aliases: *const std.StringHashMap(ast.TypeExpr)) ?ast.TypeExpr {
    return sliceTypeForBaseAliasDepth(ty, span, aliases, 0);
}

fn sliceTypeForBaseAliasDepth(ty: ast.TypeExpr, span: ast.Span, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ?ast.TypeExpr {
    if (depth > 64) return null;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| sliceTypeForBaseAliasDepth(resolved, span, aliases, depth + 1) else null,
        .slice => ty,
        .array => |node| .{ .span = span, .kind = .{ .slice = .{ .mutability = .mut, .child = node.child } } },
        .qualified => |node| sliceTypeForBaseAliasDepth(node.child.*, span, aliases, depth + 1),
        else => null,
    };
}

pub fn tryPayloadTypeExprAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) ?ast.TypeExpr {
    return tryPayloadTypeExprAliasDepth(ty, aliases, 0);
}

fn tryPayloadTypeExprAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ?ast.TypeExpr {
    if (depth > 64) return null;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| tryPayloadTypeExprAliasDepth(resolved, aliases, depth + 1) else null,
        .nullable => |child| child.*,
        .generic => |node| if (std.mem.eql(u8, node.base.text, "Result") and node.args.len >= 1) aggregateTargetTypeAlias(node.args[0], aliases) else null,
        .qualified => |node| tryPayloadTypeExprAliasDepth(node.child.*, aliases, depth + 1),
        else => null,
    };
}

pub fn resultPayloadTypeExprAlias(ty: ast.TypeExpr, tag: []const u8, aliases: *const std.StringHashMap(ast.TypeExpr)) ?ast.TypeExpr {
    return resultPayloadTypeExprAliasDepth(ty, tag, aliases, 0);
}

fn resultPayloadTypeExprAliasDepth(ty: ast.TypeExpr, tag: []const u8, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ?ast.TypeExpr {
    if (depth > 64) return null;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| resultPayloadTypeExprAliasDepth(resolved, tag, aliases, depth + 1) else null,
        .generic => |node| if (std.mem.eql(u8, node.base.text, "Result")) blk: {
            if (std.mem.eql(u8, tag, "ok") and node.args.len >= 1) break :blk aggregateTargetTypeAlias(node.args[0], aliases);
            if (std.mem.eql(u8, tag, "err") and node.args.len >= 2) break :blk aggregateTargetTypeAlias(node.args[1], aliases);
            break :blk null;
        } else null,
        .qualified => |node| resultPayloadTypeExprAliasDepth(node.child.*, tag, aliases, depth + 1),
        else => null,
    };
}

pub fn structTypeNameAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) ?[]const u8 {
    return structTypeNameAliasDepth(ty, aliases, 0);
}

fn structTypeNameAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ?[]const u8 {
    if (depth > 64) return null;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| structTypeNameAliasDepth(resolved, aliases, depth + 1) else name.text,
        .qualified => |node| structTypeNameAliasDepth(node.child.*, aliases, depth + 1),
        .pointer => |node| structTypeNameAliasDepth(node.child.*, aliases, depth + 1),
        else => null,
    };
}

pub fn isDynTraitTypeAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
    return isDynTraitTypeAliasDepth(ty, aliases, 0);
}

fn isDynTraitTypeAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) bool {
    if (depth > 64) return false;
    return switch (ty.kind) {
        .dyn_trait => true,
        .name => |name| if (aliases.get(name.text)) |resolved| isDynTraitTypeAliasDepth(resolved, aliases, depth + 1) else false,
        .qualified => |node| isDynTraitTypeAliasDepth(node.child.*, aliases, depth + 1),
        .nullable => |child| isDynTraitTypeAliasDepth(child.*, aliases, depth + 1),
        .pointer => |node| isDynTraitTypeAliasDepth(node.child.*, aliases, depth + 1),
        else => false,
    };
}

pub fn unionTypeNameAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) ?[]const u8 {
    return unionTypeNameAliasDepth(ty, aliases, 0);
}

fn unionTypeNameAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ?[]const u8 {
    if (depth > 64) return null;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| unionTypeNameAliasDepth(resolved, aliases, depth + 1) else name.text,
        .qualified => |node| unionTypeNameAliasDepth(node.child.*, aliases, depth + 1),
        else => null,
    };
}

pub fn pointerShape(kind: PointerKind, mutability: ast.Mutability, child: ast.TypeExpr) PointerShape {
    return .{ .kind = kind, .mutability = mutability, .child = typeText(child) };
}

pub fn pointerShapeAlias(kind: PointerKind, mutability: ast.Mutability, child: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) PointerShape {
    return .{ .kind = kind, .mutability = mutability, .child = typeText(aggregateTargetTypeAlias(child, aliases)) };
}

pub fn nullPointerShape() PointerShape {
    return .{ .kind = .single, .mutability = .none, .child = "null" };
}

pub fn pointerShapeFromName(name: []const u8) PointerShape {
    if (std.mem.startsWith(u8, name, "[*]")) {
        return .{ .kind = .raw_many, .mutability = pointerMutabilityFromName(name), .child = pointerChildFromName(name) };
    }
    if (std.mem.startsWith(u8, name, "[]")) {
        return .{ .kind = .slice, .mutability = pointerMutabilityFromName(name), .child = pointerChildFromName(name) };
    }
    return .{ .kind = .single, .mutability = pointerMutabilityFromName(name), .child = pointerChildFromName(name) };
}

fn pointerMutabilityFromName(name: []const u8) ast.Mutability {
    if (std.mem.indexOf(u8, name, "mut") != null) return .mut;
    if (std.mem.indexOf(u8, name, "const") != null) return .@"const";
    return .none;
}

fn pointerChildFromName(name: []const u8) []const u8 {
    if (std.mem.indexOf(u8, name, "c_void") != null) return "c_void";
    if (std.mem.indexOf(u8, name, "u16") != null) return "u16";
    if (std.mem.indexOf(u8, name, "u32") != null) return "u32";
    if (std.mem.indexOf(u8, name, "u8") != null) return "u8";
    return "unknown";
}

fn namedValueType(name: []const u8, enums: *const std.StringHashMap(EnumSummary), structs: *const std.StringHashMap(StructSummary)) ValueType {
    if (std.mem.eql(u8, name, "void")) return .void;
    if (std.mem.eql(u8, name, "never")) return .never;
    if (std.mem.eql(u8, name, "bool")) return .bool;
    if (std.mem.eql(u8, name, "PAddr")) return .{ .address = .paddr };
    if (std.mem.eql(u8, name, "VAddr")) return .{ .address = .vaddr };
    if (std.mem.eql(u8, name, "DmaAddr")) return .{ .address = .dma_addr };
    if (enums.get(name)) |info| return if (info.is_open) .{ .open_enum = name } else .{ .closed_enum = name };
    if (structs.contains(name)) return .{ .struct_ = name };
    if (std.mem.startsWith(u8, name, "u") or std.mem.startsWith(u8, name, "i") or std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "isize")) return .{ .integer = name };
    if (std.mem.eql(u8, name, "f32") or std.mem.eql(u8, name, "f64")) return .{ .float = name };
    return .value;
}

fn namedValueTypeAlias(name: []const u8, enums: *const std.StringHashMap(EnumSummary), structs: *const std.StringHashMap(StructSummary), packed_bits: *const std.StringHashMap(PackedBitsSummary)) ValueType {
    if (packed_bits.contains(name)) return .{ .struct_ = name };
    return namedValueType(name, enums, structs);
}

fn genericValueType(node: anytype, enums: *const std.StringHashMap(EnumSummary), structs: *const std.StringHashMap(StructSummary)) ValueType {
    const name = node.base.text;
    if (std.mem.eql(u8, name, "Result")) {
        return .{ .result = .{
            .ok = if (node.args.len >= 1) typeText(node.args[0]) else "unknown",
            .err = if (node.args.len >= 2) typeText(node.args[1]) else "unknown",
        } };
    }
    if (std.mem.eql(u8, name, "UserPtr")) return .{ .address = .user_ptr };
    if (std.mem.eql(u8, name, "MmioPtr")) return .{ .address = .mmio_ptr };
    if (std.mem.eql(u8, name, "PhysPtr")) return .{ .address = .phys_ptr };
    return namedValueType(name, enums, structs);
}

fn genericValueTypeAlias(node: anytype, enums: *const std.StringHashMap(EnumSummary), structs: *const std.StringHashMap(StructSummary), packed_bits: *const std.StringHashMap(PackedBitsSummary), aliases: *const std.StringHashMap(ast.TypeExpr)) ValueType {
    const name = node.base.text;
    if (std.mem.eql(u8, name, "Result")) {
        return .{ .result = .{
            .ok = if (node.args.len >= 1) typeText(aggregateTargetTypeAlias(node.args[0], aliases)) else "unknown",
            .err = if (node.args.len >= 2) typeText(aggregateTargetTypeAlias(node.args[1], aliases)) else "unknown",
        } };
    }
    if (std.mem.eql(u8, name, "UserPtr")) return .{ .address = .user_ptr };
    if (std.mem.eql(u8, name, "MmioPtr")) return .{ .address = .mmio_ptr };
    if (std.mem.eql(u8, name, "PhysPtr")) return .{ .address = .phys_ptr };
    if (std.mem.eql(u8, name, "Secret") and node.args.len == 1) return valueTypeFromTypeAlias(node.args[0], enums, structs, packed_bits, aliases);
    if (aliases.get(name)) |resolved| return valueTypeFromTypeAlias(resolved, enums, structs, packed_bits, aliases);
    return namedValueTypeAlias(name, enums, structs, packed_bits);
}

pub fn addressClassFromName(name: []const u8) ?AddressClass {
    if (std.mem.eql(u8, name, "PAddr")) return .paddr;
    if (std.mem.eql(u8, name, "VAddr")) return .vaddr;
    if (std.mem.eql(u8, name, "DmaAddr")) return .dma_addr;
    if (std.mem.eql(u8, name, "UserPtr")) return .user_ptr;
    if (std.mem.eql(u8, name, "MmioPtr")) return .mmio_ptr;
    if (std.mem.eql(u8, name, "PhysPtr")) return .phys_ptr;
    return null;
}

pub fn isWrapTypeAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
    return isWrapTypeAliasDepth(ty, aliases, 0);
}

fn isWrapTypeAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) bool {
    if (depth > 64) return false;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| isWrapTypeAliasDepth(resolved, aliases, depth + 1) else false,
        .generic => |node| std.mem.eql(u8, node.base.text, "wrap"),
        .qualified => |node| isWrapTypeAliasDepth(node.child.*, aliases, depth + 1),
        else => false,
    };
}

pub fn isSatTypeAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
    return isSatTypeAliasDepth(ty, aliases, 0);
}

fn isSatTypeAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) bool {
    if (depth > 64) return false;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| isSatTypeAliasDepth(resolved, aliases, depth + 1) else false,
        .generic => |node| std.mem.eql(u8, node.base.text, "sat"),
        .qualified => |node| isSatTypeAliasDepth(node.child.*, aliases, depth + 1),
        else => false,
    };
}

pub fn arithmeticDomainTypeAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) ?ArithmeticDomain {
    return arithmeticDomainTypeAliasDepth(ty, aliases, 0);
}

fn arithmeticDomainTypeAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ?ArithmeticDomain {
    if (depth > 64) return null;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| arithmeticDomainTypeAliasDepth(resolved, aliases, depth + 1) else null,
        .generic => |node| arithmeticDomainName(node.base.text),
        .qualified => |node| arithmeticDomainTypeAliasDepth(node.child.*, aliases, depth + 1),
        else => null,
    };
}

fn arithmeticDomainName(name: []const u8) ?ArithmeticDomain {
    if (std.mem.eql(u8, name, "wrap")) return .wrap;
    if (std.mem.eql(u8, name, "sat")) return .sat;
    if (std.mem.eql(u8, name, "serial")) return .serial;
    if (std.mem.eql(u8, name, "counter")) return .counter;
    return null;
}
