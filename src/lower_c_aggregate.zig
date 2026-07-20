//! C aggregate dependency-order and construction helpers.
//!
//! The emitter owns actual output and C spelling, but the by-value dependency
//! traversal is passive enough to keep out of the large emitter implementation.

const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const lower_c_access = @import("lower_c_access.zig");
const lower_c_alias = @import("lower_c_alias.zig");
const lower_c_global = @import("lower_c_global.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_shape = @import("lower_c_shape.zig");
const lower_c_type = @import("lower_c_type.zig");

const AggregateEmitUnit = lower_c_model.AggregateEmitUnit;
const ArrayInfo = lower_c_model.ArrayInfo;
const cPayloadFieldName = lower_c_type.cPayloadFieldName;
const calleeIdentName = ast_query.calleeIdentName;
const GlobalAccess = lower_c_model.GlobalAccess;
const LocalInfo = lower_c_model.LocalInfo;
const OverlayUnionInfo = lower_c_model.OverlayUnionInfo;
const PackedBitsInfo = lower_c_model.PackedBitsInfo;
const packedBitsMaskLiteral = lower_c_access.packedBitsMaskLiteral;
const resolvedArrayChildType = lower_c_shape.resolvedArrayChildType;
const resultPayloadTypeForTag = lower_c_shape.resultPayloadTypeForTag;
const SequencedArgTemp = lower_c_model.SequencedArgTemp;
const structFieldType = lower_c_shape.structFieldType;
const taggedUnionCase = ast_query.taggedUnionCase;
const typeName = ast_query.typeName;
const simpleNameType = ast_query.simpleNameType;

pub const DepNameFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8;
pub const EmitUnitFn = *const fn (ctx: *anyopaque, unit: AggregateEmitUnit) anyerror!void;
pub const EmitExprWithTargetFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) anyerror!void;
pub const CTypeFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8;
pub const CIdentFn = *const fn (ctx: *anyopaque, name: []const u8) anyerror![]const u8;
pub const EmitUncheckedAddValueTempFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, range_target: []const u8) anyerror!?SequencedArgTemp;
pub const OperandEmitTypeFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr;
pub const GlobalAssignmentTargetFn = *const fn (ctx: *anyopaque, target: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?GlobalAccess;
pub const EmitAssignTargetFn = *const fn (ctx: *anyopaque, target: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void;

pub const DepContext = struct {
    type_aliases: *const std.StringHashMap(ast.TypeExpr),
    structs: *const std.StringHashMap(ast.StructDecl),
    tagged_unions: *const std.StringHashMap(ast.UnionDecl),
    enums: *const std.StringHashMap(ast.EnumDecl),
    packed_bits: *const std.StringHashMap(PackedBitsInfo),
    overlay_unions: *const std.StringHashMap(OverlayUnionInfo),
    array_types: *const std.StringHashMap(ArrayInfo),
    name_ctx: *anyopaque,
    name_for_type: DepNameFn,
};

pub const EmitContext = struct {
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: *usize,
    temp_index: *usize,
    type_aliases: *const std.StringHashMap(ast.TypeExpr),
    structs: *const std.StringHashMap(ast.StructDecl),
    tagged_unions: *const std.StringHashMap(ast.UnionDecl),
    packed_bits: *const std.StringHashMap(PackedBitsInfo),
    emit_ctx: *anyopaque,
    emit_expr_with_target: EmitExprWithTargetFn,
    emit_unchecked_add_value_temp: EmitUncheckedAddValueTempFn,
    operand_emit_type: OperandEmitTypeFn,
    global_assignment_target: GlobalAssignmentTargetFn,
    emit_assign_target: EmitAssignTargetFn,
    c_type: CTypeFn,
    c_ident: CIdentFn,
};

pub fn emitArrayLiteral(ctx: EmitContext, items: []const ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!void {
    const resolved_target_ty = lower_c_alias.resolveAliasType(ctx.type_aliases, target_ty);
    const child_ty = resolvedArrayChildType(resolved_target_ty) orelse return error.UnsupportedCEmission;
    if (locals == null) {
        try ctx.out.print(ctx.allocator, "({s}){{ .elems = {{ ", .{try ctx.c_type(ctx.emit_ctx, resolved_target_ty)});
        for (items, 0..) |item, i| {
            if (i != 0) try ctx.out.appendSlice(ctx.allocator, ", ");
            try emitExprOrTargetTypedUninit(ctx, item, null, child_ty);
        }
        try ctx.out.appendSlice(ctx.allocator, " } }");
        return;
    }
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(ctx.scratch);
    try ctx.out.appendSlice(ctx.allocator, "({ ");
    for (items) |item| {
        const name = try nextTempName(ctx);
        try names.append(ctx.scratch, name);
        try ctx.out.print(ctx.allocator, "{s} {s} = ", .{ try ctx.c_type(ctx.emit_ctx, child_ty), name });
        try emitExprOrTargetTypedUninit(ctx, item, locals, child_ty);
        try ctx.out.appendSlice(ctx.allocator, "; ");
    }
    try ctx.out.print(ctx.allocator, "({s}){{ .elems = {{ ", .{try ctx.c_type(ctx.emit_ctx, resolved_target_ty)});
    for (names.items, 0..) |name, i| {
        if (i != 0) try ctx.out.appendSlice(ctx.allocator, ", ");
        try ctx.out.appendSlice(ctx.allocator, name);
    }
    try ctx.out.appendSlice(ctx.allocator, " } }; })");
}

pub fn emitStructLiteral(ctx: EmitContext, fields: []const ast.StructLiteralField, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!void {
    const resolved_target_ty = lower_c_alias.resolveAliasType(ctx.type_aliases, target_ty);
    const struct_decl = structDeclForResolvedTarget(ctx, resolved_target_ty) orelse return error.UnsupportedCEmission;
    if (locals == null) {
        if (struct_decl.is_c_union) {
            var active: ?ast.StructLiteralField = null;
            for (fields) |field| {
                if (field.value.kind != .uninit_literal) active = field;
            }
            const field = active orelse fields[0];
            const field_ty = structFieldType(struct_decl, field.name.text) orelse return error.UnsupportedCEmission;
            try ctx.out.print(ctx.allocator, "({s}){{ .{s} = ", .{ try ctx.c_type(ctx.emit_ctx, resolved_target_ty), try ctx.c_ident(ctx.emit_ctx, field.name.text) });
            try emitExprOrTargetTypedUninit(ctx, field.value, null, field_ty);
            try ctx.out.appendSlice(ctx.allocator, " }");
            return;
        }
        try ctx.out.print(ctx.allocator, "({s}){{ ", .{try ctx.c_type(ctx.emit_ctx, resolved_target_ty)});
        for (fields, 0..) |field, i| {
            if (i != 0) try ctx.out.appendSlice(ctx.allocator, ", ");
            const field_ty = structFieldType(struct_decl, field.name.text) orelse return error.UnsupportedCEmission;
            try ctx.out.print(ctx.allocator, ".{s} = ", .{try ctx.c_ident(ctx.emit_ctx, field.name.text)});
            try emitExprOrTargetTypedUninit(ctx, field.value, null, field_ty);
        }
        try ctx.out.appendSlice(ctx.allocator, " }");
        return;
    }
    if (struct_decl.is_c_union) {
        var active: ?ast.StructLiteralField = null;
        for (fields) |field| {
            if (field.value.kind != .uninit_literal) active = field;
        }
        const field = active orelse fields[0];
        const field_ty = structFieldType(struct_decl, field.name.text) orelse return error.UnsupportedCEmission;
        const name = try nextTempName(ctx);
        try ctx.out.print(ctx.allocator, "({{ {s} {s} = ", .{ try ctx.c_type(ctx.emit_ctx, field_ty), name });
        try emitExprOrTargetTypedUninit(ctx, field.value, locals, field_ty);
        try ctx.out.print(ctx.allocator, "; ({s}){{ .{s} = {s} }}; }})", .{ try ctx.c_type(ctx.emit_ctx, resolved_target_ty), try ctx.c_ident(ctx.emit_ctx, field.name.text), name });
        return;
    }
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(ctx.scratch);
    try ctx.out.appendSlice(ctx.allocator, "({ ");
    for (fields) |field| {
        const field_ty = structFieldType(struct_decl, field.name.text) orelse return error.UnsupportedCEmission;
        const name = try nextTempName(ctx);
        try names.append(ctx.scratch, name);
        try ctx.out.print(ctx.allocator, "{s} {s} = ", .{ try ctx.c_type(ctx.emit_ctx, field_ty), name });
        try emitExprOrTargetTypedUninit(ctx, field.value, locals, field_ty);
        try ctx.out.appendSlice(ctx.allocator, "; ");
    }
    try ctx.out.print(ctx.allocator, "({s}){{ ", .{try ctx.c_type(ctx.emit_ctx, resolved_target_ty)});
    for (fields, names.items, 0..) |field, name, i| {
        if (i != 0) try ctx.out.appendSlice(ctx.allocator, ", ");
        try ctx.out.print(ctx.allocator, ".{s} = ", .{try ctx.c_ident(ctx.emit_ctx, field.name.text)});
        try ctx.out.appendSlice(ctx.allocator, name);
    }
    try ctx.out.appendSlice(ctx.allocator, " }; })");
}

pub fn emitArrayLiteralWithTemps(ctx: EmitContext, items: []const ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, temps: []const ?SequencedArgTemp) anyerror!void {
    const resolved_target_ty = lower_c_alias.resolveAliasType(ctx.type_aliases, target_ty);
    const child_ty = resolvedArrayChildType(resolved_target_ty) orelse return error.UnsupportedCEmission;
    try ctx.out.print(ctx.allocator, "({s}){{ .elems = {{ ", .{try ctx.c_type(ctx.emit_ctx, resolved_target_ty)});
    for (items, 0..) |item, i| {
        if (i != 0) try ctx.out.appendSlice(ctx.allocator, ", ");
        if (i < temps.len) {
            if (temps[i]) |temp| {
                try ctx.out.appendSlice(ctx.allocator, temp.name);
                continue;
            }
        }
        try emitExprOrTargetTypedUninit(ctx, item, locals, child_ty);
    }
    try ctx.out.appendSlice(ctx.allocator, " } }");
}

pub fn emitStructLiteralWithTemps(ctx: EmitContext, fields: []const ast.StructLiteralField, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, temps: []const ?SequencedArgTemp) anyerror!void {
    const resolved_target_ty = lower_c_alias.resolveAliasType(ctx.type_aliases, target_ty);
    const struct_decl = structDeclForResolvedTarget(ctx, resolved_target_ty) orelse return error.UnsupportedCEmission;
    try ctx.out.print(ctx.allocator, "({s}){{ ", .{try ctx.c_type(ctx.emit_ctx, resolved_target_ty)});
    if (struct_decl.is_c_union) {
        var active_index: usize = 0;
        for (fields, 0..) |field, i| {
            if (field.value.kind != .uninit_literal) active_index = i;
        }
        const field = fields[active_index];
        const field_ty = structFieldType(struct_decl, field.name.text) orelse return error.UnsupportedCEmission;
        try ctx.out.print(ctx.allocator, ".{s} = ", .{try ctx.c_ident(ctx.emit_ctx, field.name.text)});
        if (active_index < temps.len) {
            if (temps[active_index]) |temp| {
                try ctx.out.appendSlice(ctx.allocator, temp.name);
            } else {
                try emitExprOrTargetTypedUninit(ctx, field.value, locals, field_ty);
            }
        } else {
            try emitExprOrTargetTypedUninit(ctx, field.value, locals, field_ty);
        }
        try ctx.out.appendSlice(ctx.allocator, " }");
        return;
    }
    for (fields, 0..) |field, i| {
        if (i != 0) try ctx.out.appendSlice(ctx.allocator, ", ");
        const field_ty = structFieldType(struct_decl, field.name.text) orelse return error.UnsupportedCEmission;
        try ctx.out.print(ctx.allocator, ".{s} = ", .{try ctx.c_ident(ctx.emit_ctx, field.name.text)});
        if (i < temps.len) {
            if (temps[i]) |temp| {
                try ctx.out.appendSlice(ctx.allocator, temp.name);
                continue;
            }
        }
        try emitExprOrTargetTypedUninit(ctx, field.value, locals, field_ty);
    }
    try ctx.out.appendSlice(ctx.allocator, " }");
}

fn emitExprOrTargetTypedUninit(ctx: EmitContext, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!void {
    if (expr.kind == .uninit_literal) {
        try ctx.out.print(ctx.allocator, "({s}){{0}}", .{try ctx.c_type(ctx.emit_ctx, target_ty)});
        return;
    }
    try ctx.emit_expr_with_target(ctx.emit_ctx, expr, locals, target_ty);
}

fn emitCUnionLiteralFields(ctx: EmitContext, struct_decl: ast.StructDecl, fields: []const ast.StructLiteralField, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
    var active: ?ast.StructLiteralField = null;
    for (fields) |field| {
        if (field.value.kind != .uninit_literal) active = field;
    }
    const field = active orelse fields[0];
    const field_ty = structFieldType(struct_decl, field.name.text) orelse return error.UnsupportedCEmission;
    try ctx.out.print(ctx.allocator, ".{s} = ", .{try ctx.c_ident(ctx.emit_ctx, field.name.text)});
    try emitExprOrTargetTypedUninit(ctx, field.value, locals, field_ty);
}

pub fn arrayChildTypeForTarget(ctx: EmitContext, target_ty: ast.TypeExpr) ?ast.TypeExpr {
    return resolvedArrayChildType(lower_c_alias.resolveAliasType(ctx.type_aliases, target_ty));
}

pub fn structDeclForTarget(ctx: EmitContext, target_ty: ast.TypeExpr) ?ast.StructDecl {
    return structDeclForResolvedTarget(ctx, lower_c_alias.resolveAliasType(ctx.type_aliases, target_ty));
}

pub fn emitUncheckedAddAggregateCallArgTemp(ctx: EmitContext, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
    return switch (arg.kind) {
        .grouped => |inner| try emitUncheckedAddAggregateCallArgTemp(ctx, inner.*, locals, target_ty),
        .array_literal => |items| try emitUncheckedAddArrayAggregateCallArgTemp(ctx, items, locals, target_ty),
        .struct_literal => |fields| try emitUncheckedAddStructAggregateCallArgTemp(ctx, fields, locals, target_ty),
        else => null,
    };
}

pub fn emitUncheckedAddAggregateReturn(ctx: EmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
    const target_ty = return_ty orelse return false;
    return switch (expr.kind) {
        .grouped => |inner| try emitUncheckedAddAggregateReturn(ctx, inner.*, locals, return_ty),
        .array_literal => |items| try emitUncheckedAddArrayAggregateReturn(ctx, items, locals, target_ty),
        .struct_literal => |fields| try emitUncheckedAddStructAggregateReturn(ctx, fields, locals, target_ty),
        else => false,
    };
}

pub fn emitUncheckedAddAggregateLocalInit(ctx: EmitContext, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    return switch (initializer.kind) {
        .grouped => |inner| try emitUncheckedAddAggregateLocalInit(ctx, name, decl_ty, inner.*, locals),
        .array_literal => |items| try emitUncheckedAddArrayAggregateLocalInit(ctx, name, decl_ty, items, locals),
        .struct_literal => |fields| try emitUncheckedAddStructAggregateLocalInit(ctx, name, decl_ty, fields, locals),
        else => false,
    };
}

pub fn emitUncheckedAddAggregateAssignmentStmt(ctx: EmitContext, assignment: anytype, locals: *std.StringHashMap(LocalInfo), target_ty_override: ?ast.TypeExpr) !bool {
    const target_ty = target_ty_override orelse if (ctx.operand_emit_type(ctx.emit_ctx, assignment.target, locals)) |ty| ty else blk: {
        const target = ctx.global_assignment_target(ctx.emit_ctx, assignment.target, locals) orelse return false;
        break :blk simpleNameType(target.info.type_name, assignment.value.span);
    };
    return switch (assignment.value.kind) {
        .grouped => |inner| try emitUncheckedAddAggregateAssignmentStmt(ctx, .{ .target = assignment.target, .value = inner.* }, locals, target_ty_override),
        .array_literal => |items| try emitUncheckedAddArrayAggregateAssignmentStmt(ctx, assignment.target, items, locals, target_ty),
        .struct_literal => |fields| try emitUncheckedAddStructAggregateAssignmentStmt(ctx, assignment.target, fields, locals, target_ty),
        else => false,
    };
}

fn emitUncheckedAddArrayAggregateReturn(ctx: EmitContext, items: []const ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) !bool {
    var temps: std.ArrayList(?SequencedArgTemp) = .empty;
    defer temps.deinit(ctx.scratch);
    if (!try collectUncheckedAddArrayLiteralTemps(ctx, items, locals, target_ty, &temps)) return false;

    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "return ");
    try emitArrayLiteralWithTemps(ctx, items, locals, target_ty, temps.items);
    try ctx.out.appendSlice(ctx.allocator, ";\n");
    return true;
}

fn emitUncheckedAddStructAggregateReturn(ctx: EmitContext, fields: []const ast.StructLiteralField, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) !bool {
    var temps: std.ArrayList(?SequencedArgTemp) = .empty;
    defer temps.deinit(ctx.scratch);
    if (!try collectUncheckedAddStructLiteralTemps(ctx, fields, locals, target_ty, &temps)) return false;

    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "return ");
    try emitStructLiteralWithTemps(ctx, fields, locals, target_ty, temps.items);
    try ctx.out.appendSlice(ctx.allocator, ";\n");
    return true;
}

fn emitUncheckedAddArrayAggregateLocalInit(ctx: EmitContext, name: []const u8, decl_ty: ast.TypeExpr, items: []const ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    var temps: std.ArrayList(?SequencedArgTemp) = .empty;
    defer temps.deinit(ctx.scratch);
    if (!try collectUncheckedAddArrayLiteralTemps(ctx, items, locals, decl_ty, &temps)) return false;

    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = ", .{ try ctx.c_type(ctx.emit_ctx, decl_ty), try ctx.c_ident(ctx.emit_ctx, name) });
    try emitArrayLiteralWithTemps(ctx, items, locals, decl_ty, temps.items);
    try ctx.out.appendSlice(ctx.allocator, ";\n");
    return true;
}

fn emitUncheckedAddStructAggregateLocalInit(ctx: EmitContext, name: []const u8, decl_ty: ast.TypeExpr, fields: []const ast.StructLiteralField, locals: *std.StringHashMap(LocalInfo)) !bool {
    var temps: std.ArrayList(?SequencedArgTemp) = .empty;
    defer temps.deinit(ctx.scratch);
    if (!try collectUncheckedAddStructLiteralTemps(ctx, fields, locals, decl_ty, &temps)) return false;

    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = ", .{ try ctx.c_type(ctx.emit_ctx, decl_ty), try ctx.c_ident(ctx.emit_ctx, name) });
    try emitStructLiteralWithTemps(ctx, fields, locals, decl_ty, temps.items);
    try ctx.out.appendSlice(ctx.allocator, ";\n");
    return true;
}

fn emitUncheckedAddArrayAggregateCallArgTemp(ctx: EmitContext, items: []const ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
    var temps: std.ArrayList(?SequencedArgTemp) = .empty;
    defer temps.deinit(ctx.scratch);
    if (!try collectUncheckedAddArrayLiteralTemps(ctx, items, locals, target_ty, &temps)) return null;

    const temp_name = try nextTempName(ctx);
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = ", .{ try ctx.c_type(ctx.emit_ctx, target_ty), temp_name });
    try emitArrayLiteralWithTemps(ctx, items, locals, target_ty, temps.items);
    try ctx.out.appendSlice(ctx.allocator, ";\n");
    return .{ .name = temp_name, .ty = target_ty };
}

fn emitUncheckedAddStructAggregateCallArgTemp(ctx: EmitContext, fields: []const ast.StructLiteralField, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
    var temps: std.ArrayList(?SequencedArgTemp) = .empty;
    defer temps.deinit(ctx.scratch);
    if (!try collectUncheckedAddStructLiteralTemps(ctx, fields, locals, target_ty, &temps)) return null;

    const temp_name = try nextTempName(ctx);
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = ", .{ try ctx.c_type(ctx.emit_ctx, target_ty), temp_name });
    try emitStructLiteralWithTemps(ctx, fields, locals, target_ty, temps.items);
    try ctx.out.appendSlice(ctx.allocator, ";\n");
    return .{ .name = temp_name, .ty = target_ty };
}

fn emitUncheckedAddArrayAggregateAssignmentStmt(ctx: EmitContext, target_expr: ast.Expr, items: []const ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) !bool {
    var temps: std.ArrayList(?SequencedArgTemp) = .empty;
    defer temps.deinit(ctx.scratch);
    if (!try collectUncheckedAddArrayLiteralTemps(ctx, items, locals, target_ty, &temps)) return false;

    try writeIndent(ctx);
    if (ctx.global_assignment_target(ctx.emit_ctx, target_expr, locals)) |target| {
        try lower_c_global.appendGlobalStorePrefix(ctx.allocator, ctx.out, target);
        try emitArrayLiteralWithTemps(ctx, items, locals, target_ty, temps.items);
        try lower_c_global.appendGlobalStoreSuffix(ctx.allocator, ctx.out, target);
    } else {
        try ctx.emit_assign_target(ctx.emit_ctx, target_expr, locals);
        try ctx.out.appendSlice(ctx.allocator, " = ");
        try emitArrayLiteralWithTemps(ctx, items, locals, target_ty, temps.items);
        try ctx.out.appendSlice(ctx.allocator, ";\n");
    }
    return true;
}

fn emitUncheckedAddStructAggregateAssignmentStmt(ctx: EmitContext, target_expr: ast.Expr, fields: []const ast.StructLiteralField, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) !bool {
    var temps: std.ArrayList(?SequencedArgTemp) = .empty;
    defer temps.deinit(ctx.scratch);
    if (!try collectUncheckedAddStructLiteralTemps(ctx, fields, locals, target_ty, &temps)) return false;

    try writeIndent(ctx);
    if (ctx.global_assignment_target(ctx.emit_ctx, target_expr, locals)) |target| {
        try lower_c_global.appendGlobalStorePrefix(ctx.allocator, ctx.out, target);
        try emitStructLiteralWithTemps(ctx, fields, locals, target_ty, temps.items);
        try lower_c_global.appendGlobalStoreSuffix(ctx.allocator, ctx.out, target);
    } else {
        try ctx.emit_assign_target(ctx.emit_ctx, target_expr, locals);
        try ctx.out.appendSlice(ctx.allocator, " = ");
        try emitStructLiteralWithTemps(ctx, fields, locals, target_ty, temps.items);
        try ctx.out.appendSlice(ctx.allocator, ";\n");
    }
    return true;
}

pub fn collectUncheckedAddArrayLiteralTemps(ctx: EmitContext, items: []const ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, temps: *std.ArrayList(?SequencedArgTemp)) !bool {
    const child_ty = arrayChildTypeForTarget(ctx, target_ty) orelse return false;
    var emitted = false;
    for (items) |item| {
        const temp = try ctx.emit_unchecked_add_value_temp(ctx.emit_ctx, item, locals, child_ty, "aggregate_element");
        if (temp != null) emitted = true;
        try temps.append(ctx.scratch, temp);
    }
    return emitted;
}

pub fn collectUncheckedAddStructLiteralTemps(ctx: EmitContext, fields: []const ast.StructLiteralField, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, temps: *std.ArrayList(?SequencedArgTemp)) !bool {
    const struct_decl = structDeclForTarget(ctx, target_ty) orelse return false;
    var emitted = false;
    for (fields) |field| {
        const field_ty = structFieldType(struct_decl, field.name.text) orelse return error.UnsupportedCEmission;
        const temp = try ctx.emit_unchecked_add_value_temp(ctx.emit_ctx, field.value, locals, field_ty, field.name.text);
        if (temp != null) emitted = true;
        try temps.append(ctx.scratch, temp);
    }
    return emitted;
}

pub fn emitPackedBitsLiteral(ctx: EmitContext, fields: []const ast.StructLiteralField, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!bool {
    const resolved_target_ty = lower_c_alias.resolveAliasType(ctx.type_aliases, target_ty);
    const packed_name = typeName(resolved_target_ty) orelse return false;
    const info = ctx.packed_bits.get(packed_name) orelse return false;
    var temps: std.ArrayList([]const u8) = .empty;
    defer temps.deinit(ctx.scratch);
    if (locals) |scope| {
        if (fields.len != 0) try ctx.out.appendSlice(ctx.allocator, "({ ");
        for (fields) |field| {
            const temp = try nextTempName(ctx);
            try temps.append(ctx.scratch, temp);
            try ctx.out.print(ctx.allocator, "bool {s} = ", .{temp});
            try ctx.emit_expr_with_target(ctx.emit_ctx, field.value, scope, ast_query.simpleNameType("bool", field.value.span));
            try ctx.out.appendSlice(ctx.allocator, "; ");
        }
    }
    try ctx.out.print(ctx.allocator, "({s})(", .{packed_name});
    if (fields.len == 0) {
        try ctx.out.print(ctx.allocator, "({s})0", .{packed_name});
    }
    for (fields, 0..) |field, i| {
        if (i != 0) try ctx.out.appendSlice(ctx.allocator, " | ");
        const packed_field = info.fields.get(field.name.text) orelse return error.UnsupportedCEmission;
        const mask = try packedBitsMaskLiteral(ctx.scratch, info, packed_field.bit_index);
        try ctx.out.appendSlice(ctx.allocator, "(");
        if (temps.items.len != 0) {
            try ctx.out.appendSlice(ctx.allocator, temps.items[i]);
        } else {
            try ctx.emit_expr_with_target(ctx.emit_ctx, field.value, locals, ast_query.simpleNameType("bool", field.value.span));
        }
        try ctx.out.print(ctx.allocator, " ? {s} : ({s})0)", .{ mask, packed_name });
    }
    try ctx.out.appendSlice(ctx.allocator, ")");
    if (temps.items.len != 0) try ctx.out.appendSlice(ctx.allocator, "; })");
    return true;
}

fn structDeclForResolvedTarget(ctx: EmitContext, target_ty: ast.TypeExpr) ?ast.StructDecl {
    const struct_name = typeName(target_ty) orelse return null;
    return ctx.structs.get(struct_name);
}

fn nextTempName(ctx: EmitContext) ![]const u8 {
    const temp_name = try std.fmt.allocPrint(ctx.scratch, "mc_tmp{d}", .{ctx.temp_index.*});
    ctx.temp_index.* += 1;
    return temp_name;
}

fn writeIndent(ctx: EmitContext) !void {
    for (0..ctx.indent.*) |_| try ctx.out.appendSlice(ctx.allocator, "    ");
}

pub fn emitResultConstructor(ctx: EmitContext, call: anytype, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, tag: []const u8) !bool {
    if (call.type_args.len != 0 or call.args.len != 1) return false;
    const payload_ty = resultPayloadTypeForTag(target_ty, tag) orelse return false;
    const result_ty = try ctx.c_type(ctx.emit_ctx, target_ty);

    try ctx.out.print(ctx.allocator, "(({s}){{ .is_ok = ", .{result_ty});
    try ctx.out.appendSlice(ctx.allocator, if (std.mem.eql(u8, tag, "ok")) "true, .payload.ok = " else "false, .payload.err = ");
    try ctx.emit_expr_with_target(ctx.emit_ctx, call.args[0], locals, payload_ty);
    try ctx.out.appendSlice(ctx.allocator, " })");
    return true;
}

pub fn emitTaggedUnionConstructor(ctx: EmitContext, call: anytype, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) !bool {
    const tag = calleeIdentName(call.callee.*) orelse return false;
    const union_name = typeName(target_ty) orelse return false;
    const union_decl = ctx.tagged_unions.get(union_name) orelse return false;
    return emitTaggedUnionCase(ctx, call, locals, union_decl, union_name, tag, target_ty);
}

// `Union.variant(...)` — qualified, self-typed tagged-union constructor. The union is
// the callee owner (not a target type), so this lowers the same in any position.
pub fn emitQualifiedUnionConstructor(ctx: EmitContext, call: anytype, locals: ?*std.StringHashMap(LocalInfo), union_ty: ast.TypeExpr) !bool {
    const q = ast_query.qualifiedMemberCallee(call.callee.*) orelse return false;
    const union_name = typeName(union_ty) orelse return false;
    if (!std.mem.eql(u8, union_name, q.owner)) return error.UnsupportedCEmission;
    const union_decl = ctx.tagged_unions.get(union_name) orelse return false;
    return emitTaggedUnionCase(ctx, call, locals, union_decl, union_name, q.member.text, union_ty);
}

fn emitTaggedUnionCase(ctx: EmitContext, call: anytype, locals: ?*std.StringHashMap(LocalInfo), union_decl: ast.UnionDecl, union_name: []const u8, tag: []const u8, union_ty: ast.TypeExpr) !bool {
    const case = taggedUnionCase(union_decl, tag) orelse return false;
    const c_union_ty = try ctx.c_type(ctx.emit_ctx, union_ty);

    if (case.ty) |payload_ty| {
        if (call.args.len != 1) return error.UnsupportedCEmission;
        try ctx.out.print(ctx.allocator, "(({s}){{ .tag = {s}Tag_{s}, .payload.{s} = ", .{
            c_union_ty,
            union_name,
            tag,
            try cPayloadFieldName(ctx.scratch, tag),
        });
        try ctx.emit_expr_with_target(ctx.emit_ctx, call.args[0], locals, payload_ty);
        try ctx.out.appendSlice(ctx.allocator, " })");
        return true;
    }

    if (call.args.len != 0) return error.UnsupportedCEmission;
    try ctx.out.print(ctx.allocator, "(({s}){{ .tag = {s}Tag_{s} }})", .{ c_union_ty, union_name, tag });
    return true;
}

pub fn emitUnitsInDependencyOrder(
    ctx: DepContext,
    allocator: std.mem.Allocator,
    units: []const AggregateEmitUnit,
    emit_ctx: *anyopaque,
    emit_unit: EmitUnitFn,
) !void {
    var emitted = std.StringHashMap(void).init(allocator);
    defer emitted.deinit();
    const done = try allocator.alloc(bool, units.len);
    @memset(done, false);

    var remaining = units.len;
    while (remaining > 0) {
        var progressed = false;
        for (units, 0..) |unit, i| {
            if (done[i]) continue;
            if (!try aggregateDepsSatisfied(ctx, unit, &emitted)) continue;
            try emit_unit(emit_ctx, unit);
            try emitted.put(aggregateUnitName(unit), {});
            done[i] = true;
            remaining -= 1;
            progressed = true;
        }
        if (progressed) continue;

        // No progress: an unexpected dependency cycle. Emit the rest as-is so
        // output stays complete; the downstream C compiler will flag bad order.
        for (units, 0..) |unit, i| {
            if (done[i]) continue;
            try emit_unit(emit_ctx, unit);
            done[i] = true;
        }
        break;
    }
}

// Append `struct_decl` and every type it transitively embeds: nested structs,
// generated array wrappers, tagged unions, plus scalar named typedefs that
// must be emitted before the closure.
pub fn collectStructClosure(
    ctx: DepContext,
    allocator: std.mem.Allocator,
    struct_decl: ast.StructDecl,
    units: *std.ArrayList(AggregateEmitUnit),
    seen: *std.StringHashMap(void),
    scalar_deps: *std.ArrayList([]const u8),
) anyerror!void {
    if ((try seen.getOrPut(struct_decl.name.text)).found_existing) return;
    for (struct_decl.fields) |field| try collectTypeClosure(ctx, allocator, field.ty, units, seen, scalar_deps);
    try units.append(allocator, .{ .struct_decl = struct_decl });
}

// Pull in by-value aggregate references and named scalar typedef dependencies.
// Pointer and slice fields lower through pointers, so they impose no by-value
// dependency; nullable and qualified wrappers keep the inner by-name shape.
pub fn collectTypeClosure(
    ctx: DepContext,
    allocator: std.mem.Allocator,
    ty: ast.TypeExpr,
    units: *std.ArrayList(AggregateEmitUnit),
    seen: *std.StringHashMap(void),
    scalar_deps: *std.ArrayList([]const u8),
) anyerror!void {
    const resolved = lower_c_alias.resolveAliasType(ctx.type_aliases, ty);
    switch (resolved.kind) {
        .array => {
            const wrapper = try ctx.name_for_type(ctx.name_ctx, resolved);
            if (ctx.array_types.get(wrapper)) |info| {
                if (!(try seen.getOrPut(wrapper)).found_existing) {
                    try collectTypeClosure(ctx, allocator, info.element_ty, units, seen, scalar_deps);
                    try units.append(allocator, .{ .array = info });
                }
            }
        },
        .name => |ident| {
            if (ctx.structs.get(ident.text)) |nested| {
                try collectStructClosure(ctx, allocator, nested, units, seen, scalar_deps);
            } else if (ctx.tagged_unions.get(ident.text)) |union_decl| {
                if (!(try seen.getOrPut(ident.text)).found_existing) {
                    for (union_decl.cases) |case| {
                        if (case.ty) |case_ty| try collectTypeClosure(ctx, allocator, case_ty, units, seen, scalar_deps);
                    }
                    try units.append(allocator, .{ .tagged_union = union_decl });
                }
            } else if (ctx.enums.contains(ident.text) or ctx.packed_bits.contains(ident.text) or ctx.overlay_unions.contains(ident.text)) {
                if (!(try seen.getOrPut(ident.text)).found_existing) try scalar_deps.append(allocator, ident.text);
            }
        },
        .nullable => |child| {
            // A value optional `?T` field embeds `mc_opt_<T>` by value: pull in the payload
            // closure, then the opt typedef unit. Pointer nullables impose no by-value dep.
            if (lower_c_type.nullablePayloadIsValueType(ctx.type_aliases, child.*)) {
                const opt_name = try ctx.name_for_type(ctx.name_ctx, resolved);
                if (!(try seen.getOrPut(opt_name)).found_existing) {
                    try collectTypeClosure(ctx, allocator, child.*, units, seen, scalar_deps);
                    try units.append(allocator, .{ .opt = .{ .name = opt_name, .payload_ty = child.* } });
                }
            } else {
                try collectTypeClosure(ctx, allocator, child.*, units, seen, scalar_deps);
            }
        },
        .qualified => |node| try collectTypeClosure(ctx, allocator, node.child.*, units, seen, scalar_deps),
        else => {},
    }
}

pub fn aggregateDepsSatisfied(ctx: DepContext, unit: AggregateEmitUnit, emitted: *std.StringHashMap(void)) !bool {
    switch (unit) {
        .struct_decl => |s| for (s.fields) |field| {
            if (try aggregateDepName(ctx, field.ty)) |dep| if (!emitted.contains(dep)) return false;
        },
        .array => |a| {
            if (try aggregateDepName(ctx, a.element_ty)) |dep| if (!emitted.contains(dep)) return false;
        },
        .result => |r| {
            if (try aggregateDepName(ctx, r.ok_ty)) |dep| if (!emitted.contains(dep)) return false;
            if (try aggregateDepName(ctx, r.err_ty)) |dep| if (!emitted.contains(dep)) return false;
        },
        .tagged_union => |u| for (u.cases) |case| {
            if (case.ty) |ty| if (try aggregateDepName(ctx, ty)) |dep| if (!emitted.contains(dep)) return false;
        },
        .opt => |o| {
            if (try aggregateDepName(ctx, o.payload_ty)) |dep| if (!emitted.contains(dep)) return false;
        },
    }
    return true;
}

// The typedef name of the by-value aggregate `ty` refers to, if it is one
// this pass emits (struct, array, Result, tagged union). Slices, pointers,
// and nullable pointers reference their pointee only through a pointer, so
// they impose no ordering and return null; scalars and enums likewise.
pub fn aggregateDepName(ctx: DepContext, ty: ast.TypeExpr) !?[]const u8 {
    const resolved = lower_c_alias.resolveAliasType(ctx.type_aliases, ty);
    return switch (resolved.kind) {
        .array => try ctx.name_for_type(ctx.name_ctx, resolved),
        .qualified => |node| try aggregateDepName(ctx, node.child.*),
        .generic => |node| if (std.mem.eql(u8, node.base.text, "Result"))
            try ctx.name_for_type(ctx.name_ctx, resolved)
        else
            null,
        // A value optional `?T` embeds its payload by value in a `mc_opt_<T>` typedef, so a
        // struct/Result/array embedding `?T` must wait for that typedef. Pointer nullables
        // reference through a pointer and impose no ordering.
        .nullable => |child| if (lower_c_type.nullablePayloadIsValueType(ctx.type_aliases, child.*))
            try ctx.name_for_type(ctx.name_ctx, resolved)
        else
            null,
        .name => |ident| if (ctx.structs.contains(ident.text) or ctx.tagged_unions.contains(ident.text)) ident.text else null,
        else => null,
    };
}

fn aggregateUnitName(unit: AggregateEmitUnit) []const u8 {
    return switch (unit) {
        .struct_decl => |s| s.name.text,
        .array => |a| a.name,
        .result => |r| r.name,
        .tagged_union => |u| u.name.text,
        .opt => |o| o.name,
    };
}
