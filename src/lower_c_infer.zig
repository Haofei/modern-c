//! C backend expression type inference helpers.
//!
//! These are passive return-type classifiers used by the emitter; they inspect
//! collected function and enum metadata but do not emit C.

const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const lower_c_alias = @import("lower_c_alias.zig");
const lower_c_expr = @import("lower_c_expr.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_shape = @import("lower_c_shape.zig");
const lower_c_type = @import("lower_c_type.zig");
const mir = @import("mir.zig");

const FnInfo = lower_c_model.FnInfo;
const GlobalInfo = lower_c_model.GlobalInfo;
const LocalInfo = lower_c_model.LocalInfo;
const calleeIdentName = ast_query.calleeIdentName;
const simpleNameType = ast_query.simpleNameType;
const exprIsNumericLiteral = lower_c_expr.exprIsNumericLiteral;
const isNumericValueBinaryOp = lower_c_expr.isNumericValueBinaryOp;
const resultPayloadTypeForTag = lower_c_shape.resultPayloadTypeForTag;
const isBoolType = lower_c_type.isBoolType;
const isNumericStorageType = lower_c_type.isNumericStorageType;
const sameCStorageType = lower_c_type.sameCStorageType;
const typeName = ast_query.typeName;

pub const SourceTypeFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr;
pub const CallReturnTypeFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr;
pub const MirTargetTypeFn = *const fn (ctx: *anyopaque, kind: mir.TargetTypeKind, span: ast.Span) ?ast.TypeExpr;
pub const MirOwnedTargetTypeFn = *const fn (ctx: *anyopaque, kind: mir.TargetTypeKind, span: ast.Span, target_owner: []const u8, target_index: ?usize) ?ast.TypeExpr;

pub const TypeQueryContext = struct {
    type_aliases: *const std.StringHashMap(ast.TypeExpr),
    functions: *const std.StringHashMap(FnInfo),
    globals: *const std.StringHashMap(GlobalInfo),
    structs: *const std.StringHashMap(ast.StructDecl),
    enums: *const std.StringHashMap(ast.EnumDecl),
    tagged_unions: *const std.StringHashMap(ast.UnionDecl),
    source_ctx: *anyopaque,
    source_type_for_expr: SourceTypeFn,
    call_return_type_for_expr: CallReturnTypeFn,
    mir_target_type: MirTargetTypeFn,
    mir_owned_target_type: MirOwnedTargetTypeFn,
};

pub fn sliceReturnTypeForCall(ctx: TypeQueryContext, call: anytype) ?ast.TypeExpr {
    const return_ty = callReturnType(ctx, call) orelse return null;
    return if (return_ty.kind == .slice) return_ty else null;
}

pub fn sliceReturnTypeForExpr(ctx: TypeQueryContext, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
    return switch (expr.kind) {
        .call => |call| sliceReturnTypeForCall(ctx, call),
        .slice => |node| if (ctx.source_type_for_expr(ctx.source_ctx, node.base.*, locals)) |base_ty| sliceTypeForBase(ctx, base_ty, node.base.*.span) else null,
        .grouped => |inner| sliceReturnTypeForExpr(ctx, inner.*, locals),
        else => null,
    };
}

pub fn sliceReturnTypeForIndexBase(ctx: TypeQueryContext, expr: ast.Expr) ?ast.TypeExpr {
    return switch (expr.kind) {
        .call => |call| sliceReturnTypeForCall(ctx, call),
        .grouped => |inner| sliceReturnTypeForIndexBase(ctx, inner.*),
        else => null,
    };
}

pub fn sliceTypeForBase(ctx: TypeQueryContext, ty: ast.TypeExpr, span: ast.Span) ?ast.TypeExpr {
    const resolved = resolveAliasType(ctx, ty);
    return switch (resolved.kind) {
        .slice => resolved,
        .array => |node| .{ .span = span, .kind = .{ .slice = .{ .mutability = .mut, .child = node.child } } },
        else => null,
    };
}

pub fn arrayReturnTypeForExpr(ctx: TypeQueryContext, expr: ast.Expr) ?ast.TypeExpr {
    return switch (expr.kind) {
        .call => |node| blk: {
            const ret_ty = callReturnType(ctx, node) orelse break :blk null;
            break :blk if (ret_ty.kind == .array) ret_ty else null;
        },
        .grouped => |inner| arrayReturnTypeForExpr(ctx, inner.*),
        else => null,
    };
}

pub fn enumReturnTypeForExpr(ctx: TypeQueryContext, expr: ast.Expr) ?ast.TypeExpr {
    return switch (expr.kind) {
        .call => |node| blk: {
            const ret_ty = callReturnType(ctx, node) orelse break :blk null;
            const enum_name = typeName(ret_ty) orelse break :blk null;
            break :blk if (ctx.enums.contains(enum_name)) ret_ty else null;
        },
        .grouped => |inner| enumReturnTypeForExpr(ctx, inner.*),
        else => null,
    };
}

pub fn enumNameForExpr(ctx: TypeQueryContext, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
    if (operandEmitType(ctx, expr, locals)) |ty| {
        if (enumNameForType(ctx, ty)) |name| return name;
    }
    return switch (expr.kind) {
        .ident => |ident| enumNameForIdentValue(ctx, ident.text, locals),
        .call, .cast => enumNameForValueExpr(ctx, expr, locals),
        .grouped => |inner| enumNameForExpr(ctx, inner.*, locals),
        else => null,
    };
}

pub fn enumNameForValueExpr(ctx: TypeQueryContext, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
    if (operandEmitType(ctx, expr, locals)) |ty| {
        if (enumNameForType(ctx, ty)) |name| return name;
    }
    return switch (expr.kind) {
        .ident => |ident| enumNameForIdentValue(ctx, ident.text, locals),
        .call => |node| enumNameForCallValue(ctx, node),
        .cast => |node| enumNameForType(ctx, node.ty.*),
        .member => |node| enumNameForVariantPath(ctx, node, locals),
        .grouped => |inner| enumNameForValueExpr(ctx, inner.*, locals),
        else => null,
    };
}

// A variant-path literal `Enum.variant` has the enum's own type; return the enum
// name so `Enum.variant.raw()` resolves. The base must name an enum TYPE, not a
// local/global value shadowing it, and the member must be one of its cases.
fn enumNameForVariantPath(ctx: TypeQueryContext, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
    _ = locals;
    const ty = ctx.mir_target_type(ctx.source_ctx, .enum_variant_path_result, node.base.*.span) orelse return null;
    return typeName(ty);
}

pub fn enumNameForType(ctx: TypeQueryContext, ty: ast.TypeExpr) ?[]const u8 {
    const name = typeName(resolveAliasType(ctx, ty)) orelse return null;
    return if (ctx.enums.contains(name)) name else null;
}

fn enumNameForIdentValue(ctx: TypeQueryContext, name_text: []const u8, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
    if (locals) |local_set| {
        if (local_set.get(name_text)) |info| {
            if (info.source_type_name) |name| if (ctx.enums.contains(name)) return name;
        }
    }
    if (ctx.globals.get(name_text)) |global| {
        if (ctx.enums.contains(global.type_name)) return global.type_name;
    }
    return null;
}

fn enumNameForCallValue(ctx: TypeQueryContext, node: anytype) ?[]const u8 {
    const ret_ty = callReturnType(ctx, node) orelse return null;
    return enumNameForType(ctx, ret_ty);
}

pub fn exprIsBoolForEmission(ctx: TypeQueryContext, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
    return switch (expr.kind) {
        .bool_literal => true,
        .ident => |ident| identIsBoolForEmission(ctx, ident.text, locals),
        .call => if (ctx.call_return_type_for_expr(ctx.source_ctx, expr, locals)) |ty| isBoolType(ty) else false,
        .index, .member => operandIsBoolForEmission(ctx, expr, locals),
        .grouped => |inner| exprIsBoolForEmission(ctx, inner.*, locals),
        .binary => |node| binaryOpProducesBool(node.op),
        .unary => |node| node.op == .logical_not,
        else => false,
    };
}

fn identIsBoolForEmission(ctx: TypeQueryContext, name: []const u8, locals: ?*std.StringHashMap(LocalInfo)) bool {
    if (locals) |local_set| {
        if (local_set.get(name)) |info| {
            if (info.source_ty) |ty| return isBoolType(ty);
        }
    }
    if (ctx.globals.get(name)) |global| {
        if (global.source_ty) |ty| return isBoolType(ty);
    }
    return false;
}

fn operandIsBoolForEmission(ctx: TypeQueryContext, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
    const ty = operandEmitType(ctx, expr, locals) orelse return false;
    return isBoolType(resolveAliasType(ctx, ty));
}

fn binaryOpProducesBool(op: ast.BinaryOp) bool {
    return switch (op) {
        .eq, .ne, .lt, .le, .gt, .ge, .logical_and, .logical_or => true,
        else => false,
    };
}

pub fn nullableReturnTypeForExpr(ctx: TypeQueryContext, expr: ast.Expr) ?ast.TypeExpr {
    return switch (expr.kind) {
        .call => |node| blk: {
            const ret_ty = callReturnType(ctx, node) orelse break :blk null;
            break :blk if (resolveAliasType(ctx, ret_ty).kind == .nullable) ret_ty else null;
        },
        .grouped => |inner| nullableReturnTypeForExpr(ctx, inner.*),
        else => null,
    };
}

pub fn taggedUnionReturnTypeForExpr(ctx: TypeQueryContext, expr: ast.Expr) ?ast.TypeExpr {
    return switch (expr.kind) {
        .call => |node| blk: {
            // A qualified constructor `Union.variant(...)` is self-typed to its owner,
            // so an untyped `let t = Token.number(9)` infers `Token`.
            if (ctx.mir_target_type(ctx.source_ctx, .qualified_union_result, expr.span)) |ty| break :blk ty;
            const ret_ty = callReturnType(ctx, node) orelse break :blk null;
            const type_name = typeName(resolveAliasType(ctx, ret_ty)) orelse break :blk null;
            break :blk if (ctx.tagged_unions.contains(type_name)) ret_ty else null;
        },
        .grouped => |inner| taggedUnionReturnTypeForExpr(ctx, inner.*),
        else => null,
    };
}

pub fn taggedUnionTypeForExpr(ctx: TypeQueryContext, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
    const ty = switch (expr.kind) {
        .call => taggedUnionReturnTypeForExpr(ctx, expr) orelse return null,
        .cast => |node| node.ty.*,
        .grouped => |inner| return taggedUnionTypeForExpr(ctx, inner.*, locals),
        else => operandEmitType(ctx, expr, locals) orelse ctx.source_type_for_expr(ctx.source_ctx, expr, locals) orelse return null,
    };
    const type_name = typeName(resolveAliasType(ctx, ty)) orelse return null;
    return if (ctx.tagged_unions.contains(type_name)) ty else null;
}

pub fn resultReturnTypeForCall(ctx: TypeQueryContext, call: anytype) ?ast.TypeExpr {
    const ret_ty = callReturnType(ctx, call) orelse return null;
    const resolved = resolveAliasType(ctx, ret_ty);
    return if (resultPayloadTypeForTag(resolved, "ok") != null and resultPayloadTypeForTag(resolved, "err") != null) ret_ty else null;
}

pub fn resultTypeForExpr(ctx: TypeQueryContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
    if (resultTypeFromSourceExpr(ctx, expr, locals)) |ty| return ty;
    return switch (expr.kind) {
        .ident => |ident| blk: {
            const info = locals.get(ident.text) orelse break :blk null;
            break :blk info.result_ty;
        },
        .call => |node| resultReturnTypeForCall(ctx, node),
        .grouped => |inner| resultTypeForExpr(ctx, inner.*, locals),
        else => null,
    };
}

pub fn resultTypeFromSourceExpr(ctx: TypeQueryContext, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
    const ty = operandEmitType(ctx, expr, locals) orelse ctx.source_type_for_expr(ctx.source_ctx, expr, locals) orelse return null;
    const resolved = resolveAliasType(ctx, ty);
    return if (resultPayloadTypeForTag(resolved, "ok") != null and resultPayloadTypeForTag(resolved, "err") != null) ty else null;
}

pub fn operandEmitType(ctx: TypeQueryContext, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
    switch (expr.kind) {
        .ident => |ident| return sourceTypeForIdent(ctx, ident.text, locals),
        .grouped => |inner| return operandEmitType(ctx, inner.*, locals),
        .member => |node| {
            const base_ty = operandEmitType(ctx, node.base.*, locals) orelse ctx.source_type_for_expr(ctx.source_ctx, node.base.*, locals) orelse return null;
            const struct_name = structNameFromType(ctx, base_ty) orelse return null;
            const struct_decl = ctx.structs.get(struct_name) orelse return null;
            for (struct_decl.fields) |field| {
                if (std.mem.eql(u8, field.name.text, node.name.text)) return field.ty;
            }
            return null;
        },
        .index => |node| {
            const base_ty = operandEmitType(ctx, node.base.*, locals) orelse ctx.source_type_for_expr(ctx.source_ctx, node.base.*, locals) orelse return null;
            const resolved = resolveAliasType(ctx, base_ty);
            return switch (resolved.kind) {
                .array => resolved.kind.array.child.*,
                .slice => resolved.kind.slice.child.*,
                else => null,
            };
        },
        else => return null,
    }
}

pub fn arrayTypeForExpr(ctx: TypeQueryContext, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
    switch (expr.kind) {
        .ident => |ident| {
            const resolved_source_ty = sourceTypeForIdentNoLocalFallback(ctx, ident.text, locals) orelse return null;
            const resolved = resolveAliasType(ctx, resolved_source_ty);
            return if (resolved.kind == .array) resolved else null;
        },
        .grouped => |inner| return arrayTypeForExpr(ctx, inner.*, locals),
        .index => |node| {
            const base_arr = arrayTypeForExpr(ctx, node.base.*, locals) orelse return null;
            const resolved_child = resolveAliasType(ctx, base_arr.kind.array.child.*);
            return if (resolved_child.kind == .array) resolved_child else null;
        },
        .member => |node| {
            const struct_name = structTypeNameForExpr(ctx, node.base.*, locals) orelse return null;
            const struct_decl = ctx.structs.get(struct_name) orelse return null;
            for (struct_decl.fields) |field| {
                if (std.mem.eql(u8, field.name.text, node.name.text)) {
                    const resolved = resolveAliasType(ctx, field.ty);
                    return if (resolved.kind == .array) resolved else null;
                }
            }
            return null;
        },
        // `pa.*[i]` — deref of a pointer-to-array indexes the pointee array.
        .deref => |inner| {
            const pointee = derefPointeeType(ctx, inner.*, locals) orelse return null;
            const resolved = resolveAliasType(ctx, pointee);
            return if (resolved.kind == .array) resolved else null;
        },
        else => return null,
    }
}

pub fn exprIsPointer(ctx: TypeQueryContext, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
    const set = locals orelse return false;
    return switch (expr.kind) {
        .ident => |id| blk: {
            const info = set.get(id.text) orelse break :blk false;
            const ty = info.source_ty orelse break :blk false;
            break :blk resolveAliasType(ctx, ty).kind == .pointer;
        },
        .member => |m| blk: {
            const sname = structTypeNameForExpr(ctx, m.base.*, locals) orelse break :blk false;
            const sdecl = ctx.structs.get(sname) orelse break :blk false;
            for (sdecl.fields) |f| {
                if (std.mem.eql(u8, f.name.text, m.name.text)) {
                    break :blk resolveAliasType(ctx, f.ty).kind == .pointer;
                }
            }
            break :blk false;
        },
        .grouped => |inner| exprIsPointer(ctx, inner.*, locals),
        else => false,
    };
}

pub fn derefPointeeType(ctx: TypeQueryContext, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
    return switch (expr.kind) {
        .ident => |id| pointeeTypeFromPointerLike(ctx, sourceTypeForIdent(ctx, id.text, locals) orelse return null),
        .call => |node| pointeeTypeFromPointerLike(ctx, ctx.mir_target_type(ctx.source_ctx, .raw_many_offset_result, node.callee.*.span) orelse callReturnType(ctx, node) orelse return null),
        .cast => |node| pointeeTypeFromPointerLike(ctx, node.ty.*),
        .member, .index => pointeeTypeFromPointerLike(ctx, operandEmitType(ctx, expr, locals) orelse return null),
        .grouped => |inner| derefPointeeType(ctx, inner.*, locals),
        else => null,
    };
}

fn pointeeTypeFromPointerLike(ctx: TypeQueryContext, ty: ast.TypeExpr) ?ast.TypeExpr {
    const resolved = resolveAliasType(ctx, ty);
    return switch (resolved.kind) {
        .pointer => |p| p.child.*,
        .raw_many_pointer => |p| p.child.*,
        else => null,
    };
}

pub fn structTypeNameForExpr(ctx: TypeQueryContext, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
    return switch (expr.kind) {
        .ident => |id| blk: {
            const ty = sourceTypeForIdentNoLocalFallback(ctx, id.text, locals) orelse break :blk null;
            break :blk structNameFromType(ctx, ty);
        },
        .member => |m| blk: {
            const sname = structTypeNameForExpr(ctx, m.base.*, locals) orelse break :blk null;
            const sdecl = ctx.structs.get(sname) orelse break :blk null;
            for (sdecl.fields) |f| {
                if (std.mem.eql(u8, f.name.text, m.name.text)) break :blk structNameFromType(ctx, f.ty);
            }
            break :blk null;
        },
        .index => blk: {
            const ty = operandEmitType(ctx, expr, locals) orelse break :blk null;
            break :blk structNameFromType(ctx, ty);
        },
        .grouped => |inner| structTypeNameForExpr(ctx, inner.*, locals),
        else => null,
    };
}

pub fn numericExprTypeForEmission(ctx: TypeQueryContext, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
    return switch (expr.kind) {
        .ident => |ident| {
            const source_ty = sourceTypeForIdent(ctx, ident.text, locals) orelse return null;
            return if (isNumericStorageType(source_ty)) source_ty else null;
        },
        .call => {
            const return_ty = ctx.call_return_type_for_expr(ctx.source_ctx, expr, locals) orelse return null;
            return if (isNumericStorageType(return_ty)) return_ty else null;
        },
        // A numeric struct field (`s.len`) recovers its declared type, so
        // `s.len + 1` and similar lower through the checked helper.
        .member => |node| {
            const struct_name = structTypeNameForExpr(ctx, node.base.*, locals) orelse return null;
            const struct_decl = ctx.structs.get(struct_name) orelse return null;
            for (struct_decl.fields) |field| {
                if (std.mem.eql(u8, field.name.text, node.name.text)) {
                    const resolved = resolveAliasType(ctx, field.ty);
                    return if (isNumericStorageType(resolved)) resolved else null;
                }
            }
            return null;
        },
        .index => |node| {
            const elem = arrayTypeForExpr(ctx, node.base.*, locals) orelse return null;
            const resolved = resolveAliasType(ctx, elem.kind.array.child.*);
            return if (isNumericStorageType(resolved)) resolved else null;
        },
        // `p.*` over `p: *T` recovers `T`, so `p.* + 1` lowers checked.
        .deref => |inner| {
            const pointee = derefPointeeType(ctx, inner.*, locals) orelse return null;
            const resolved = resolveAliasType(ctx, pointee);
            return if (isNumericStorageType(resolved)) resolved else null;
        },
        // A cast's result type is its target type, so `(x as u32) << 8` and
        // similar recover their width.
        .cast => |node| {
            const resolved = resolveAliasType(ctx, node.ty.*);
            return if (isNumericStorageType(resolved)) resolved else null;
        },
        .grouped => |inner| numericExprTypeForEmission(ctx, inner.*, locals),
        .unary => |node| numericExprTypeForEmission(ctx, node.expr.*, locals),
        .binary => |node| {
            if (!isNumericValueBinaryOp(node.op)) return null;
            const left_ty = numericExprTypeForEmission(ctx, node.left.*, locals);
            // A shift's result type is the left (shifted) operand's type; the
            // shift amount may be a different width (`u64 >> u32`), so it does
            // not have to match.
            if (node.op == .shl or node.op == .shr) return left_ty;
            const right_ty = numericExprTypeForEmission(ctx, node.right.*, locals);
            if (left_ty != null and right_ty != null) {
                return if (sameCStorageType(left_ty.?, right_ty.?)) left_ty else null;
            }
            // A bare numeric literal adopts its sibling operand's storage
            // type, so `i + 1` resolves to `i`'s type (e.g. as a comparison
            // or loop-condition operand: `while (i + 1) < n`).
            if (left_ty) |lt| return if (exprIsNumericLiteral(node.right.*)) lt else null;
            if (right_ty) |rt| return if (exprIsNumericLiteral(node.left.*)) rt else null;
            return null;
        },
        else => null,
    };
}

pub fn conditionOperandTypeForEmission(ctx: TypeQueryContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
    return switch (expr.kind) {
        .ident => |ident| sourceTypeForIdent(ctx, ident.text, locals),
        .bool_literal => simpleNameType("bool", expr.span),
        .int_literal => simpleNameType("u32", expr.span),
        .call => ctx.call_return_type_for_expr(ctx.source_ctx, expr, locals),
        .grouped => |inner| conditionOperandTypeForEmission(ctx, inner.*, locals),
        .unary => |node| conditionOperandTypeForEmission(ctx, node.expr.*, locals),
        .binary => numericExprTypeForEmission(ctx, expr, locals),
        .index => operandEmitType(ctx, expr, locals),
        // A struct-field read — including one off a call result (`mk(x).v == 7`) —
        // resolves through operandEmitType, which walks the base (calls included via
        // source_type_for_expr) to the field's declared type. Without this a sequenced
        // comparison in a value context (return / let-init) could not recover the
        // operand type and failed UnsupportedCEmission.
        .member => operandEmitType(ctx, expr, locals),
        else => null,
    };
}

fn callReturnType(ctx: TypeQueryContext, call: anytype) ?ast.TypeExpr {
    const fn_name = calleeIdentName(call.callee.*) orelse return null;
    const info = ctx.functions.get(fn_name) orelse return null;
    const fact_ty = ctx.mir_owned_target_type(ctx.source_ctx, .direct_call_result, call.callee.*.span, fn_name, null) orelse return null;
    if (info.return_type) |declared_ty| {
        if (!std.meta.eql(fact_ty, declared_ty)) return null;
    } else if (!lower_c_type.isVoidType(fact_ty)) return null;
    return fact_ty;
}

fn sourceTypeForIdent(ctx: TypeQueryContext, name: []const u8, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
    if (locals) |local_set| {
        if (local_set.get(name)) |info| return info.source_ty;
    }
    if (ctx.globals.get(name)) |global| return global.source_ty;
    return null;
}

fn sourceTypeForIdentNoLocalFallback(ctx: TypeQueryContext, name: []const u8, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
    const local_ty = if (locals) |local_set| blk: {
        if (local_set.get(name)) |info| break :blk info.source_ty orelse return null;
        if (local_set.contains(name)) return null;
        break :blk null;
    } else null;
    return local_ty orelse if (ctx.globals.get(name)) |global| global.source_ty else null;
}

fn structNameFromType(ctx: TypeQueryContext, ty: ast.TypeExpr) ?[]const u8 {
    const resolved = resolveAliasType(ctx, ty);
    return switch (resolved.kind) {
        .name => |n| n.text,
        .pointer => |p| switch (resolveAliasType(ctx, p.child.*).kind) {
            .name => |n| n.text,
            else => null,
        },
        else => null,
    };
}

fn resolveAliasType(ctx: TypeQueryContext, ty: ast.TypeExpr) ast.TypeExpr {
    return lower_c_alias.resolveAliasType(ctx.type_aliases, ty);
}
