//! C backend expression traversal helpers for hoist/replacement passes.
//!
//! The emitter owns the leaf behavior that writes C. This module keeps the
//! repeated expression-tree traversal for `?` and call-based hoist collection.

const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const error_from = @import("error_from.zig");
const lower_c_access = @import("lower_c_access.zig");
const lower_c_alias = @import("lower_c_alias.zig");
const lower_c_arith = @import("lower_c_arith.zig");
const lower_c_call = @import("lower_c_call.zig");
const lower_c_global = @import("lower_c_global.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_op = @import("lower_c_op.zig");
const lower_c_shape = @import("lower_c_shape.zig");
const lower_c_type = @import("lower_c_type.zig");

const LocalInfo = lower_c_model.LocalInfo;
const FnInfo = lower_c_model.FnInfo;
const GlobalAccess = lower_c_model.GlobalAccess;
const ResultTrySequenceMode = lower_c_model.ResultTrySequenceMode;
const SequencedArgTemp = lower_c_model.SequencedArgTemp;
const TryReplacement = lower_c_model.TryReplacement;
const appendGlobalStoreValue = lower_c_global.appendGlobalStoreValue;
const appendGlobalStorePrefix = lower_c_global.appendGlobalStorePrefix;
const appendGlobalStoreSuffix = lower_c_global.appendGlobalStoreSuffix;
const calleeIdentName = ast_query.calleeIdentName;
const callExpr = ast_query.callExpr;
const resultPayloadTypeForTag = lower_c_shape.resultPayloadTypeForTag;

pub const TryPredicateFn = *const fn (ctx: *anyopaque, operand: ast.Expr) bool;
pub const TryPredicateErrorFn = *const fn (ctx: *anyopaque, operand: ast.Expr) anyerror!bool;
pub const TryHoistFn = *const fn (ctx: *anyopaque, expr: ast.Expr) anyerror!bool;
pub const CallScanResult = enum { found, ignored, descend };
pub const CallHoistResult = enum { hoisted, ignored, descend };
pub const CallScanFn = *const fn (ctx: *anyopaque, expr: ast.Expr) CallScanResult;
pub const CallHoistFn = *const fn (ctx: *anyopaque, expr: ast.Expr) anyerror!CallHoistResult;
pub const BinaryGuardFn = *const fn (ctx: *anyopaque, expr: ast.Expr) anyerror!?bool;
pub const EmitExprFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(lower_c_model.LocalInfo)) anyerror!void;
pub const EmitExprWithTargetFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(lower_c_model.LocalInfo), target_ty: ?ast.TypeExpr) anyerror!void;
pub const CTypeFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8;
pub const EmitDeclaratorFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr, name: []const u8) anyerror!void;
pub const OperandEmitTypeFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr;
pub const GlobalAssignmentTargetFn = *const fn (ctx: *anyopaque, target: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?GlobalAccess;
pub const EmitAssignTargetFn = *const fn (ctx: *anyopaque, target: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void;
pub const EmitResultTrySequencedBinaryValueTempFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, return_ty: ?ast.TypeExpr, mode: ResultTrySequenceMode) anyerror!?SequencedArgTemp;
pub const EmitNullableTrySequencedBinaryValueTempFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp;
pub const ExprContainsResultTryFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) bool;
pub const CallArgsContainResultTryFn = *const fn (ctx: *anyopaque, args: []const ast.Expr, locals: *std.StringHashMap(LocalInfo)) bool;
pub const CallArgsContainNullableTryFn = *const fn (ctx: *anyopaque, args: []const ast.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!bool;
pub const CollectResultTryHoistsForStmtFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, replacements: *std.ArrayList(lower_c_model.TryReplacement)) anyerror!bool;
pub const CollectResultTryHoistsForLocalInitFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), enclosing_return_ty: ast.TypeExpr, replacements: *std.ArrayList(lower_c_model.TryReplacement)) anyerror!bool;
pub const CollectNullableTryHoistsForReturnFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), replacements: *std.ArrayList(lower_c_model.TryReplacement)) anyerror!bool;
pub const ResultTypeForExprFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?ast.TypeExpr;
pub const NullableInnerCTypeForExprFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!?[]const u8;
pub const EmitDeferredCleanupsFn = *const fn (ctx: *anyopaque, locals: *std.StringHashMap(LocalInfo), return_ty: ast.TypeExpr) anyerror!void;

pub const TryReplacementMode = enum { result, nullable };

pub const TryReplacementEmitContext = struct {
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: *usize,
    temp_index: *usize,
    type_aliases: *const std.StringHashMap(ast.TypeExpr),
    functions: *const std.StringHashMap(lower_c_model.FnInfo),
    emit_ctx: *anyopaque,
    emit_expr: EmitExprFn,
    emit_expr_with_target: EmitExprWithTargetFn,
    c_type: CTypeFn,
    emit_declarator: EmitDeclaratorFn,
    operand_emit_type: OperandEmitTypeFn,
    global_assignment_target: GlobalAssignmentTargetFn,
    emit_assign_target: EmitAssignTargetFn,
    emit_result_try_sequenced_binary_value_temp: EmitResultTrySequencedBinaryValueTempFn,
    emit_nullable_try_sequenced_binary_value_temp: EmitNullableTrySequencedBinaryValueTempFn,
};

pub const TryCallEmitContext = struct {
    replacement: TryReplacementEmitContext,
    call_ctx: lower_c_call.TempContext,
    emit_sequenced_arg_temp: lower_c_call.EmitSequencedArgTempFn,
    expr_contains_result_try: ExprContainsResultTryFn,
    call_args_contain_result_try: CallArgsContainResultTryFn,
    call_args_contain_nullable_try: CallArgsContainNullableTryFn,
    collect_result_try_hoists_for_stmt: CollectResultTryHoistsForStmtFn,
    collect_result_try_hoists_for_local_init: CollectResultTryHoistsForLocalInitFn,
    collect_nullable_try_hoists_for_return: CollectNullableTryHoistsForReturnFn,
};

pub const TryDirectEmitContext = struct {
    arith: lower_c_arith.Context,
    replacement: TryReplacementEmitContext,
    result_type_for_expr: ResultTypeForExprFn,
    nullable_inner_c_type_for_expr: NullableInnerCTypeForExprFn,
    emit_deferred_cleanups: EmitDeferredCleanupsFn,
};

pub const TryStmtEmitContext = struct {
    direct: TryDirectEmitContext,
    call: TryCallEmitContext,
};

const ResultTryOperand = struct {
    expr: ast.Expr,
    mapped: ?*ast.Expr,
};

const DirectTryHoistContext = struct {
    ctx: TryDirectEmitContext,
    locals: *std.StringHashMap(LocalInfo),
    replacements: *std.ArrayList(lower_c_model.TryReplacement),
    enclosing_return_ty: ?ast.TypeExpr = null,
};

const ResultTrySequencedBinaryContext = struct {
    ctx: TryDirectEmitContext,
    return_ty: ?ast.TypeExpr,
    mode: ResultTrySequenceMode,
};

const NullableTrySequencedBinaryContext = struct {
    ctx: TryDirectEmitContext,
};

const DirectTryScanContext = struct {
    ctx: TryDirectEmitContext,
    locals: *std.StringHashMap(LocalInfo),
};

pub fn emitTryExprWithReplacements(
    ctx: TryReplacementEmitContext,
    mode: TryReplacementMode,
    expr: ast.Expr,
    locals: ?*std.StringHashMap(lower_c_model.LocalInfo),
    target_ty: ?ast.TypeExpr,
    replacements: []const lower_c_model.TryReplacement,
) anyerror!void {
    if (!lower_c_access.exprHasTryReplacement(expr, replacements)) return ctx.emit_expr_with_target(ctx.emit_ctx, expr, locals, target_ty);
    switch (expr.kind) {
        .try_expr => {
            const temp_name = lower_c_access.tryReplacementForSpan(expr.span, replacements).?;
            switch (mode) {
                .result => try ctx.out.print(ctx.allocator, "{s}.payload.ok", .{temp_name}),
                .nullable => try ctx.out.appendSlice(ctx.allocator, temp_name),
            }
        },
        .grouped => |inner| {
            try ctx.out.appendSlice(ctx.allocator, "(");
            try emitTryExprWithReplacements(ctx, mode, inner.*, locals, target_ty, replacements);
            try ctx.out.appendSlice(ctx.allocator, ")");
        },
        .call => |node| {
            if (ast_query.isMmioMapCallName(node.callee.*)) {
                const payload_ty = ast_query.mmioMapCallPayloadType(node) orelse return error.UnsupportedCEmission;
                if (node.args.len != 1) return error.UnsupportedCEmission;
                try ctx.out.print(ctx.allocator, "(({s})", .{try ctx.c_type(ctx.emit_ctx, payload_ty)});
                try emitTryExprWithReplacements(ctx, mode, node.args[0], locals, null, replacements);
                try ctx.out.appendSlice(ctx.allocator, ")");
                return;
            }
            const fn_info = if (ast_query.calleeIdentName(node.callee.*)) |name| ctx.functions.get(name) else null;
            try ctx.emit_expr(ctx.emit_ctx, node.callee.*, locals);
            try ctx.out.appendSlice(ctx.allocator, "(");
            for (node.args, 0..) |arg, i| {
                if (i != 0) try ctx.out.appendSlice(ctx.allocator, ", ");
                const arg_target_ty = if (fn_info) |info| if (i < info.params.len) info.params[i].ty else null else null;
                try emitTryExprWithReplacements(ctx, mode, arg, locals, arg_target_ty, replacements);
            }
            try ctx.out.appendSlice(ctx.allocator, ")");
        },
        .unary => |node| {
            if (try emitCheckedUnaryTryReplacement(ctx, mode, node, locals, target_ty, replacements)) return;
            try ctx.out.appendSlice(ctx.allocator, lower_c_op.unaryCOp(node.op));
            try ctx.out.appendSlice(ctx.allocator, "(");
            try emitTryExprWithReplacements(ctx, mode, node.expr.*, locals, null, replacements);
            try ctx.out.appendSlice(ctx.allocator, ")");
        },
        .binary => |node| {
            if (lower_c_op.isCheckedBinaryOp(node.op)) {
                const target = target_ty orelse return error.UnsupportedCEmission;
                const target_name = ast_query.typeName(target) orelse return error.UnsupportedCEmission;
                const helper = lower_c_op.checkedHelperParts(node.op, target_name) orelse return error.UnsupportedCEmission;
                try ctx.out.print(ctx.allocator, "{s}{s}(", .{ helper.prefix, helper.suffix });
                try emitTryExprWithReplacements(ctx, mode, node.left.*, locals, target, replacements);
                try ctx.out.appendSlice(ctx.allocator, ", ");
                try emitTryExprWithReplacements(ctx, mode, node.right.*, locals, target, replacements);
                try ctx.out.appendSlice(ctx.allocator, ")");
            } else {
                try ctx.out.appendSlice(ctx.allocator, "(");
                try emitTryExprWithReplacements(ctx, mode, node.left.*, locals, null, replacements);
                try ctx.out.print(ctx.allocator, " {s} ", .{lower_c_op.binaryCOp(node.op)});
                try emitTryExprWithReplacements(ctx, mode, node.right.*, locals, null, replacements);
                try ctx.out.appendSlice(ctx.allocator, ")");
            }
        },
        .cast => |node| {
            try ctx.out.print(ctx.allocator, "(({s})", .{try ctx.c_type(ctx.emit_ctx, node.ty.*)});
            try emitTryExprWithReplacements(ctx, mode, node.value.*, locals, null, replacements);
            try ctx.out.appendSlice(ctx.allocator, ")");
        },
        else => try ctx.emit_expr_with_target(ctx.emit_ctx, expr, locals, target_ty),
    }
}

pub fn emitTryLocalInitWithReplacements(ctx: TryReplacementEmitContext, mode: TryReplacementMode, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo), replacements: []const lower_c_model.TryReplacement) !void {
    try writeIndent(ctx);
    try ctx.emit_declarator(ctx.emit_ctx, decl_ty, name);
    try ctx.out.appendSlice(ctx.allocator, " = ");
    try emitTryExprWithReplacements(ctx, mode, initializer, locals, decl_ty, replacements);
    try ctx.out.appendSlice(ctx.allocator, ";\n");
}

pub fn emitTryOperandTempWithReplacements(ctx: TryReplacementEmitContext, mode: TryReplacementMode, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, replacements: []const lower_c_model.TryReplacement) !SequencedArgTemp {
    const temp_name = try std.fmt.allocPrint(ctx.scratch, "mc_tmp{d}", .{ctx.temp_index.*});
    ctx.temp_index.* += 1;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = ", .{ try ctx.c_type(ctx.emit_ctx, target_ty), temp_name });
    try emitTryExprWithReplacements(ctx, mode, expr, locals, target_ty, replacements);
    try ctx.out.appendSlice(ctx.allocator, ";\n");
    return .{ .name = temp_name, .ty = target_ty };
}

pub fn emitTryExprStmtWithReplacements(ctx: TryReplacementEmitContext, mode: TryReplacementMode, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), replacements: []const lower_c_model.TryReplacement) !void {
    try writeIndent(ctx);
    try emitTryExprWithReplacements(ctx, mode, expr, locals, null, replacements);
    try ctx.out.appendSlice(ctx.allocator, ";\n");
}

pub fn emitTryAssignmentWithReplacements(ctx: TryReplacementEmitContext, mode: TryReplacementMode, assignment: anytype, locals: *std.StringHashMap(LocalInfo), replacements: []const lower_c_model.TryReplacement) !void {
    try writeIndent(ctx);
    if (ctx.global_assignment_target(ctx.emit_ctx, assignment.target, locals)) |target| {
        try appendGlobalStorePrefix(ctx.allocator, ctx.out, target);
        try emitTryExprWithReplacements(ctx, mode, assignment.value, locals, null, replacements);
        try appendGlobalStoreSuffix(ctx.allocator, ctx.out, target);
    } else {
        try ctx.emit_assign_target(ctx.emit_ctx, assignment.target, locals);
        try ctx.out.appendSlice(ctx.allocator, " = ");
        try emitTryExprWithReplacements(ctx, mode, assignment.value, locals, null, replacements);
        try ctx.out.appendSlice(ctx.allocator, ";\n");
    }
}

pub fn emitResultTrySequencedBinaryReturn(ctx: TryReplacementEmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
    const target_ty = return_ty orelse return false;
    const temp = (try ctx.emit_result_try_sequenced_binary_value_temp(ctx.emit_ctx, expr, locals, target_ty, return_ty, .stmt)) orelse return false;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "return {s};\n", .{temp.name});
    return true;
}

pub fn emitNullableTrySequencedBinaryReturn(ctx: TryReplacementEmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
    const target_ty = return_ty orelse return false;
    const temp = (try ctx.emit_nullable_try_sequenced_binary_value_temp(ctx.emit_ctx, expr, locals, target_ty)) orelse return false;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "return {s};\n", .{temp.name});
    return true;
}

pub fn emitResultTrySequencedBinaryLocalInit(ctx: TryReplacementEmitContext, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo), enclosing_return_ty: ast.TypeExpr) !bool {
    const temp = (try ctx.emit_result_try_sequenced_binary_value_temp(ctx.emit_ctx, initializer, locals, decl_ty, enclosing_return_ty, .local_init)) orelse return false;
    try writeIndent(ctx);
    try ctx.emit_declarator(ctx.emit_ctx, decl_ty, name);
    try ctx.out.print(ctx.allocator, " = {s};\n", .{temp.name});
    return true;
}

pub fn emitNullableTrySequencedBinaryLocalInit(ctx: TryReplacementEmitContext, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const temp = (try ctx.emit_nullable_try_sequenced_binary_value_temp(ctx.emit_ctx, initializer, locals, decl_ty)) orelse return false;
    try writeIndent(ctx);
    try ctx.emit_declarator(ctx.emit_ctx, decl_ty, name);
    try ctx.out.print(ctx.allocator, " = {s};\n", .{temp.name});
    return true;
}

pub fn emitResultTrySequencedBinaryAssignment(ctx: TryReplacementEmitContext, assignment: anytype, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
    const target_ty = assignmentTargetType(ctx, assignment, locals) orelse return false;
    const temp = (try ctx.emit_result_try_sequenced_binary_value_temp(ctx.emit_ctx, assignment.value, locals, target_ty, return_ty, .stmt)) orelse return false;
    try emitAssignmentFromTemp(ctx, assignment.target, locals, temp.name);
    return true;
}

pub fn emitNullableTrySequencedBinaryAssignment(ctx: TryReplacementEmitContext, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
    const target_ty = assignmentTargetType(ctx, assignment, locals) orelse return false;
    const temp = (try ctx.emit_nullable_try_sequenced_binary_value_temp(ctx.emit_ctx, assignment.value, locals, target_ty)) orelse return false;
    try emitAssignmentFromTemp(ctx, assignment.target, locals, temp.name);
    return true;
}

pub fn emitResultTryCallLocalInit(ctx: TryCallEmitContext, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo), enclosing_return_ty: ast.TypeExpr) !bool {
    const call = callExpr(initializer) orelse return false;
    if (!ctx.call_args_contain_result_try(ctx.replacement.emit_ctx, call.args, locals)) return false;
    const fn_info = if (calleeIdentName(call.callee.*)) |callee_name| ctx.replacement.functions.get(callee_name) orelse return false else return false;
    if (fn_info.params.len < call.args.len) return false;

    var temps = try emitResultTryCallArgTemps(ctx, call, locals, fn_info, enclosing_return_ty, .local_init);
    defer temps.deinit(ctx.replacement.scratch);

    try lower_c_call.emitSequencedCallLocalValue(ctx.call_ctx, name, decl_ty, call, locals, temps.items, true);
    return true;
}

pub fn emitNullableTryCallLocalInit(ctx: TryCallEmitContext, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const call = callExpr(initializer) orelse return false;
    if (!try ctx.call_args_contain_nullable_try(ctx.replacement.emit_ctx, call.args, locals)) return false;
    const fn_info = if (calleeIdentName(call.callee.*)) |callee_name| ctx.replacement.functions.get(callee_name) orelse return false else return false;
    if (fn_info.params.len < call.args.len) return false;

    var temps = try emitNullableTryCallArgTemps(ctx, call, locals, fn_info);
    defer temps.deinit(ctx.replacement.scratch);

    try lower_c_call.emitSequencedCallLocalValue(ctx.call_ctx, name, decl_ty, call, locals, temps.items, false);
    return true;
}

pub fn emitResultTryCallAssignment(ctx: TryCallEmitContext, assignment: anytype, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
    const call = callExpr(assignment.value) orelse return false;
    if (!ctx.call_args_contain_result_try(ctx.replacement.emit_ctx, call.args, locals)) return false;
    const fn_info = if (calleeIdentName(call.callee.*)) |callee_name| ctx.replacement.functions.get(callee_name) orelse return false else return false;
    const call_return_ty = fn_info.return_type orelse return false;
    if (lower_c_type.isVoidType(call_return_ty) or fn_info.params.len < call.args.len) return false;

    var temps = try emitResultTryCallArgTemps(ctx, call, locals, fn_info, return_ty, .stmt);
    defer temps.deinit(ctx.replacement.scratch);

    const result_temp = try lower_c_call.emitSequencedCallResultTemp(ctx.call_ctx, call, call_return_ty, locals, temps.items);
    try emitAssignmentFromTemp(ctx.replacement, assignment.target, locals, result_temp);
    return true;
}

pub fn emitNullableTryCallAssignment(ctx: TryCallEmitContext, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
    const call = callExpr(assignment.value) orelse return false;
    if (!try ctx.call_args_contain_nullable_try(ctx.replacement.emit_ctx, call.args, locals)) return false;
    const fn_info = if (calleeIdentName(call.callee.*)) |callee_name| ctx.replacement.functions.get(callee_name) orelse return false else return false;
    const call_return_ty = fn_info.return_type orelse return false;
    if (lower_c_type.isVoidType(call_return_ty) or fn_info.params.len < call.args.len) return false;

    var temps = try emitNullableTryCallArgTemps(ctx, call, locals, fn_info);
    defer temps.deinit(ctx.replacement.scratch);

    const result_temp = try lower_c_call.emitSequencedCallResultTemp(ctx.call_ctx, call, call_return_ty, locals, temps.items);
    try emitAssignmentFromTemp(ctx.replacement, assignment.target, locals, result_temp);
    return true;
}

pub fn emitResultTryCallExprStmt(ctx: TryCallEmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
    const call = callExpr(expr) orelse return false;
    if (!ctx.call_args_contain_result_try(ctx.replacement.emit_ctx, call.args, locals)) return false;
    const fn_info = if (calleeIdentName(call.callee.*)) |callee_name| ctx.replacement.functions.get(callee_name) orelse return false else return false;
    if (fn_info.params.len < call.args.len) return false;

    var temps = try emitResultTryCallArgTemps(ctx, call, locals, fn_info, return_ty, .stmt);
    defer temps.deinit(ctx.replacement.scratch);

    try lower_c_call.emitSequencedCallExprStmtValue(ctx.call_ctx, call, locals, temps.items);
    return true;
}

pub fn emitNullableTryCallExprStmt(ctx: TryCallEmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const call = callExpr(expr) orelse return false;
    if (!try ctx.call_args_contain_nullable_try(ctx.replacement.emit_ctx, call.args, locals)) return false;
    const fn_info = if (calleeIdentName(call.callee.*)) |callee_name| ctx.replacement.functions.get(callee_name) orelse return false else return false;
    if (fn_info.params.len < call.args.len) return false;

    var temps = try emitNullableTryCallArgTemps(ctx, call, locals, fn_info);
    defer temps.deinit(ctx.replacement.scratch);

    try lower_c_call.emitSequencedCallExprStmtValue(ctx.call_ctx, call, locals, temps.items);
    return true;
}

pub fn emitResultTryCallReturn(ctx: TryCallEmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const call = callExpr(expr) orelse return false;
    if (!ctx.call_args_contain_result_try(ctx.replacement.emit_ctx, call.args, locals)) return false;

    const fn_info = if (calleeIdentName(call.callee.*)) |name| ctx.replacement.functions.get(name) orelse return false else return false;
    if (fn_info.params.len < call.args.len) return false;

    var temps = try emitResultTryCallArgTemps(ctx, call, locals, fn_info, null, .stmt);
    defer temps.deinit(ctx.replacement.scratch);

    try lower_c_call.emitSequencedCallReturnValue(ctx.call_ctx, call, locals, temps.items);
    return true;
}

pub fn emitNullableTryCallReturn(ctx: TryCallEmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const call = callExpr(expr) orelse return false;
    if (!try ctx.call_args_contain_nullable_try(ctx.replacement.emit_ctx, call.args, locals)) return false;

    const fn_info = if (calleeIdentName(call.callee.*)) |name| ctx.replacement.functions.get(name) orelse return false else return false;
    if (fn_info.params.len < call.args.len) return false;

    var temps = try emitNullableTryCallArgTemps(ctx, call, locals, fn_info);
    defer temps.deinit(ctx.replacement.scratch);

    try lower_c_call.emitSequencedCallReturnValue(ctx.call_ctx, call, locals, temps.items);
    return true;
}

pub fn emitResultTryConstructorReturn(ctx: TryCallEmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
    const target_ty = return_ty orelse return false;
    const call = callExpr(expr) orelse return false;
    const tag = calleeIdentName(call.callee.*) orelse return false;
    if (!std.mem.eql(u8, tag, "ok") and !std.mem.eql(u8, tag, "err")) return false;
    if (call.args.len != 1) return false;
    if (!ctx.expr_contains_result_try(ctx.replacement.emit_ctx, call.args[0], locals)) return false;
    const payload_ty = resultPayloadTypeForTag(target_ty, tag) orelse return false;

    const temp = try emitResultTryCallArgTempWithMode(ctx, call.args[0], locals, payload_ty, return_ty, .stmt);

    try writeIndent(ctx.replacement);
    try ctx.replacement.out.print(ctx.replacement.allocator, "return (({s}){{ .is_ok = ", .{try ctx.replacement.c_type(ctx.replacement.emit_ctx, target_ty)});
    try ctx.replacement.out.appendSlice(ctx.replacement.allocator, if (std.mem.eql(u8, tag, "ok")) "true, .payload.ok = " else "false, .payload.err = ");
    try ctx.replacement.out.appendSlice(ctx.replacement.allocator, temp.name);
    try ctx.replacement.out.appendSlice(ctx.replacement.allocator, " });\n");
    return true;
}

pub fn emitResultTryLocalInit(ctx: TryDirectEmitContext, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
    const operand = switch (initializer.kind) {
        .try_expr => tryOperandForExpr(initializer).?,
        .grouped => |inner| return try emitResultTryLocalInit(ctx, name, decl_ty, inner.*, locals, return_ty),
        else => return false,
    };
    const enclosing_return_ty = return_ty orelse return false;
    if (resultPayloadTypeForTag(enclosing_return_ty, "err") == null) return false;
    const operand_result_ty = ctx.result_type_for_expr(ctx.replacement.emit_ctx, operand.expr, locals) orelse return false;
    _ = resultPayloadTypeForTag(operand_result_ty, "ok") orelse return false;
    _ = resultPayloadTypeForTag(operand_result_ty, "err") orelse return false;

    const temp_name = try emitResultTryLocalOperandTemp(ctx, operand.expr, locals, operand_result_ty);
    try emitResultTryErrGuard(ctx, enclosing_return_ty, temp_name, operand.mapped, operand_result_ty, locals);
    try emitResultTryOkLocal(ctx, name, decl_ty, temp_name);
    return true;
}

pub fn emitResultTryReturn(ctx: TryDirectEmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
    const operand = switch (expr.kind) {
        .try_expr => |inner| inner.operand.*,
        .grouped => |inner| return try emitResultTryReturn(ctx, inner.*, locals, return_ty),
        else => return false,
    };
    const operand_result_ty = ctx.result_type_for_expr(ctx.replacement.emit_ctx, operand, locals) orelse return false;
    _ = resultPayloadTypeForTag(operand_result_ty, "ok") orelse return false;
    _ = resultPayloadTypeForTag(operand_result_ty, "err") orelse return false;
    const temp_name = try emitResultTryLocalOperandTemp(ctx, operand, locals, operand_result_ty);
    try emitResultTryTrapGuard(ctx, temp_name);
    try emitResultTryOkReturn(ctx, temp_name);
    return true;
}

pub fn emitNullableTryReturn(ctx: TryDirectEmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const operand = switch (expr.kind) {
        .try_expr => |inner| inner.operand.*,
        .grouped => |inner| return try emitNullableTryReturn(ctx, inner.*, locals),
        else => return false,
    };
    // Value optional `?T` (tagged repr): unwrap traps on absent, then yields `.value`.
    if (try valueOptionalCType(ctx, operand, locals)) |opt_c_type| {
        const temp_name = try nextTempName(ctx.replacement);
        try writeIndent(ctx.replacement);
        try ctx.replacement.out.print(ctx.replacement.allocator, "{s} {s} = ", .{ opt_c_type, temp_name });
        try ctx.replacement.emit_expr(ctx.replacement.emit_ctx, operand, locals);
        try ctx.replacement.out.appendSlice(ctx.replacement.allocator, ";\n");
        try writeIndent(ctx.replacement);
        try ctx.replacement.out.print(ctx.replacement.allocator, "if (!{s}.present) mc_trap_NullUnwrap();\n", .{temp_name});
        try writeIndent(ctx.replacement);
        try ctx.replacement.out.print(ctx.replacement.allocator, "return {s}.value;\n", .{temp_name});
        return true;
    }
    const inner_c_type = try ctx.nullable_inner_c_type_for_expr(ctx.replacement.emit_ctx, operand, locals) orelse return false;
    const temp_name = try nextTempName(ctx.replacement);

    try writeIndent(ctx.replacement);
    try ctx.replacement.out.print(ctx.replacement.allocator, "{s} {s} = ", .{ inner_c_type, temp_name });
    try ctx.replacement.emit_expr(ctx.replacement.emit_ctx, operand, locals);
    try ctx.replacement.out.appendSlice(ctx.replacement.allocator, ";\n");

    try emitNullableTryTrapGuard(ctx, temp_name, inner_c_type);
    try writeIndent(ctx.replacement);
    try ctx.replacement.out.print(ctx.replacement.allocator, "return {s};\n", .{temp_name});
    return true;
}

// If `operand` has a value-optional `?T` type, returns its `mc_opt_<T>` C type name.
fn valueOptionalCType(ctx: TryDirectEmitContext, operand: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !?[]const u8 {
    const ty = ctx.replacement.operand_emit_type(ctx.replacement.emit_ctx, operand, locals) orelse return null;
    const resolved = lower_c_alias.resolveAliasType(ctx.replacement.type_aliases, ty);
    if (resolved.kind != .nullable) return null;
    if (!lower_c_type.nullablePayloadIsValueType(ctx.replacement.type_aliases, resolved.kind.nullable.*)) return null;
    return try ctx.replacement.c_type(ctx.replacement.emit_ctx, resolved);
}

pub fn collectResultTryHoistsForReturn(ctx: TryDirectEmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), replacements: *std.ArrayList(lower_c_model.TryReplacement)) !bool {
    var hoist_ctx = DirectTryHoistContext{ .ctx = ctx, .locals = locals, .replacements = replacements };
    return collectTryHoists(&hoist_ctx, expr, emitResultTryTrapHoist);
}

pub fn collectResultTryHoistsForStmt(ctx: TryDirectEmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, replacements: *std.ArrayList(lower_c_model.TryReplacement)) !bool {
    if (return_ty) |ty| {
        if (resultPayloadTypeForTag(ty, "err") != null) {
            return try collectResultTryHoistsForLocalInit(ctx, expr, locals, ty, replacements);
        }
    }
    return try collectResultTryHoistsForReturn(ctx, expr, locals, replacements);
}

pub fn collectResultTryHoistsForLocalInit(ctx: TryDirectEmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), enclosing_return_ty: ast.TypeExpr, replacements: *std.ArrayList(lower_c_model.TryReplacement)) !bool {
    var hoist_ctx = DirectTryHoistContext{ .ctx = ctx, .locals = locals, .replacements = replacements, .enclosing_return_ty = enclosing_return_ty };
    return collectTryHoists(&hoist_ctx, expr, emitResultTryPropagateHoist);
}

pub fn collectNullableTryHoistsForReturn(ctx: TryDirectEmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), replacements: *std.ArrayList(lower_c_model.TryReplacement)) !bool {
    var hoist_ctx = DirectTryHoistContext{ .ctx = ctx, .locals = locals, .replacements = replacements };
    return collectTryHoists(&hoist_ctx, expr, emitNullableTryTrapHoist);
}

pub fn emitResultTryExprLocalInit(ctx: TryStmtEmitContext, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
    const propagates = resultTryLocalInitPropagates(return_ty);

    if (propagates) {
        const enclosing_return_ty = return_ty.?;
        if (try emitResultTrySequencedBinaryLocalInit(ctx.direct.replacement, name, decl_ty, initializer, locals, enclosing_return_ty)) return true;
        if (try emitResultTryCallLocalInit(ctx.call, name, decl_ty, initializer, locals, enclosing_return_ty)) return true;
    }

    var replacements: std.ArrayList(TryReplacement) = .empty;
    defer replacements.deinit(ctx.direct.replacement.scratch);
    if (!try collectResultTryLocalInitHoists(ctx.direct, initializer, locals, return_ty, propagates, &replacements)) return false;
    try emitTryLocalInitWithReplacements(ctx.direct.replacement, .result, name, decl_ty, initializer, locals, replacements.items);
    return true;
}

pub fn emitNullableTryExprLocalInit(ctx: TryStmtEmitContext, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    if (try emitNullableTrySequencedBinaryLocalInit(ctx.direct.replacement, name, decl_ty, initializer, locals)) return true;
    if (try emitNullableTryCallLocalInit(ctx.call, name, decl_ty, initializer, locals)) return true;

    var replacements: std.ArrayList(TryReplacement) = .empty;
    defer replacements.deinit(ctx.direct.replacement.scratch);
    if (!try collectNullableTryHoistsForReturn(ctx.direct, initializer, locals, &replacements)) return false;

    try emitTryLocalInitWithReplacements(ctx.direct.replacement, .nullable, name, decl_ty, initializer, locals, replacements.items);
    return true;
}

pub fn emitResultTryAssignmentStmt(ctx: TryStmtEmitContext, assignment: anytype, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
    if (try emitResultTrySequencedBinaryAssignment(ctx.direct.replacement, assignment, locals, return_ty)) return true;
    if (try emitResultTryCallAssignment(ctx.call, assignment, locals, return_ty)) return true;

    var replacements: std.ArrayList(TryReplacement) = .empty;
    defer replacements.deinit(ctx.direct.replacement.scratch);
    if (!try collectResultTryHoistsForStmt(ctx.direct, assignment.value, locals, return_ty, &replacements)) return false;

    try emitTryAssignmentWithReplacements(ctx.direct.replacement, .result, assignment, locals, replacements.items);
    return true;
}

pub fn emitNullableTryAssignmentStmt(ctx: TryStmtEmitContext, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
    if (try emitNullableTrySequencedBinaryAssignment(ctx.direct.replacement, assignment, locals)) return true;
    if (try emitNullableTryCallAssignment(ctx.call, assignment, locals)) return true;

    var replacements: std.ArrayList(TryReplacement) = .empty;
    defer replacements.deinit(ctx.direct.replacement.scratch);
    if (!try collectNullableTryHoistsForReturn(ctx.direct, assignment.value, locals, &replacements)) return false;

    try emitTryAssignmentWithReplacements(ctx.direct.replacement, .nullable, assignment, locals, replacements.items);
    return true;
}

pub fn emitResultTryOperandTemp(ctx: TryDirectEmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, return_ty: ?ast.TypeExpr, mode: ResultTrySequenceMode) anyerror!SequencedArgTemp {
    var replacements: std.ArrayList(TryReplacement) = .empty;
    defer replacements.deinit(ctx.replacement.scratch);
    const found = switch (mode) {
        .local_init => blk: {
            const enclosing_return_ty = return_ty orelse return error.UnsupportedCEmission;
            break :blk try collectResultTryHoistsForLocalInit(ctx, expr, locals, enclosing_return_ty, &replacements);
        },
        .stmt => try collectResultTryHoistsForStmt(ctx, expr, locals, return_ty, &replacements),
    };
    _ = found;
    return emitTryOperandTempWithReplacements(ctx.replacement, .result, expr, locals, target_ty, replacements.items);
}

pub fn emitNullableTryOperandTemp(ctx: TryDirectEmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!SequencedArgTemp {
    var replacements: std.ArrayList(TryReplacement) = .empty;
    defer replacements.deinit(ctx.replacement.scratch);
    _ = try collectNullableTryHoistsForReturn(ctx, expr, locals, &replacements);

    return emitTryOperandTempWithReplacements(ctx.replacement, .nullable, expr, locals, target_ty, replacements.items);
}

pub fn emitResultTrySequencedBinaryValueTemp(ctx: TryDirectEmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, return_ty: ?ast.TypeExpr, mode: ResultTrySequenceMode) anyerror!?SequencedArgTemp {
    var seq_ctx = ResultTrySequencedBinaryContext{ .ctx = ctx, .return_ty = return_ty, .mode = mode };
    return lower_c_arith.emitSequencedBinaryValueTemp(.{
        .arith = ctx.arith,
        .emit_ctx = &seq_ctx,
        .expr_needs_sequenced_binary = resultTryExprNeedsSequencedBinary,
        .emit_operand_temp = emitResultTrySequencedBinaryOperandTemp,
    }, expr, locals, target_ty);
}

pub fn emitNullableTrySequencedBinaryValueTemp(ctx: TryDirectEmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
    var seq_ctx = NullableTrySequencedBinaryContext{ .ctx = ctx };
    return lower_c_arith.emitSequencedBinaryValueTemp(.{
        .arith = ctx.arith,
        .emit_ctx = &seq_ctx,
        .expr_needs_sequenced_binary = nullableTryExprNeedsSequencedBinary,
        .emit_operand_temp = emitNullableTrySequencedBinaryOperandTemp,
    }, expr, locals, target_ty);
}

pub fn emitResultTryExprStmt(ctx: TryStmtEmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
    if (try emitResultTryCallExprStmt(ctx.call, expr, locals, return_ty)) return true;

    var replacements: std.ArrayList(TryReplacement) = .empty;
    defer replacements.deinit(ctx.direct.replacement.scratch);
    if (!try collectResultTryHoistsForStmt(ctx.direct, expr, locals, return_ty, &replacements)) return false;
    if (lower_c_access.resultTryOperand(expr) != null) return true;

    try emitTryExprStmtWithReplacements(ctx.direct.replacement, .result, expr, locals, replacements.items);
    return true;
}

pub fn emitNullableTryExprStmt(ctx: TryStmtEmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    if (try emitNullableTryCallExprStmt(ctx.call, expr, locals)) return true;

    var replacements: std.ArrayList(TryReplacement) = .empty;
    defer replacements.deinit(ctx.direct.replacement.scratch);
    if (!try collectNullableTryHoistsForReturn(ctx.direct, expr, locals, &replacements)) return false;
    if (lower_c_access.resultTryOperand(expr) != null) return true;

    try emitTryExprStmtWithReplacements(ctx.direct.replacement, .nullable, expr, locals, replacements.items);
    return true;
}

fn resultTryLocalInitPropagates(return_ty: ?ast.TypeExpr) bool {
    const ty = return_ty orelse return false;
    return resultPayloadTypeForTag(ty, "err") != null;
}

fn collectResultTryLocalInitHoists(
    ctx: TryDirectEmitContext,
    initializer: ast.Expr,
    locals: *std.StringHashMap(LocalInfo),
    return_ty: ?ast.TypeExpr,
    propagates: bool,
    replacements: *std.ArrayList(TryReplacement),
) !bool {
    return if (propagates)
        try collectResultTryHoistsForLocalInit(ctx, initializer, locals, return_ty.?, replacements)
    else
        try collectResultTryHoistsForReturn(ctx, initializer, locals, replacements);
}

fn resultTryExprNeedsSequencedBinary(ctx_ptr: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!bool {
    const ctx: *ResultTrySequencedBinaryContext = @ptrCast(@alignCast(ctx_ptr));
    var scan_ctx = DirectTryScanContext{ .ctx = ctx.ctx, .locals = locals };
    return exprContainsTry(&scan_ctx, expr, directResultTryOperandIsResult);
}

fn nullableTryExprNeedsSequencedBinary(ctx_ptr: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!bool {
    const ctx: *NullableTrySequencedBinaryContext = @ptrCast(@alignCast(ctx_ptr));
    var scan_ctx = DirectTryScanContext{ .ctx = ctx.ctx, .locals = locals };
    return try exprContainsTryError(&scan_ctx, expr, directNullableTryOperandIsNullable);
}

fn emitResultTrySequencedBinaryOperandTemp(ctx_ptr: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!SequencedArgTemp {
    const ctx: *ResultTrySequencedBinaryContext = @ptrCast(@alignCast(ctx_ptr));
    return emitResultTryOperandTemp(ctx.ctx, expr, locals, target_ty, ctx.return_ty, ctx.mode);
}

fn emitNullableTrySequencedBinaryOperandTemp(ctx_ptr: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!SequencedArgTemp {
    const ctx: *NullableTrySequencedBinaryContext = @ptrCast(@alignCast(ctx_ptr));
    return emitNullableTryOperandTemp(ctx.ctx, expr, locals, target_ty);
}

fn directResultTryOperandIsResult(ctx_ptr: *anyopaque, operand: ast.Expr) bool {
    const ctx: *DirectTryScanContext = @ptrCast(@alignCast(ctx_ptr));
    return ctx.ctx.result_type_for_expr(ctx.ctx.replacement.emit_ctx, operand, ctx.locals) != null;
}

fn directNullableTryOperandIsNullable(ctx_ptr: *anyopaque, operand: ast.Expr) anyerror!bool {
    const ctx: *DirectTryScanContext = @ptrCast(@alignCast(ctx_ptr));
    return (try ctx.ctx.nullable_inner_c_type_for_expr(ctx.ctx.replacement.emit_ctx, operand, ctx.locals)) != null;
}

fn emitResultTryCallArgTemps(ctx: TryCallEmitContext, call: anytype, locals: *std.StringHashMap(LocalInfo), fn_info: FnInfo, return_ty: ?ast.TypeExpr, mode: ResultTrySequenceMode) anyerror!std.ArrayList(SequencedArgTemp) {
    var temps: std.ArrayList(SequencedArgTemp) = .empty;
    errdefer temps.deinit(ctx.replacement.scratch);
    for (call.args, 0..) |arg, i| {
        try temps.append(ctx.replacement.scratch, try emitResultTryCallArgTempWithMode(ctx, arg, locals, fn_info.params[i].ty, return_ty, mode));
    }
    return temps;
}

fn emitResultTryCallArgTempWithMode(ctx: TryCallEmitContext, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, return_ty: ?ast.TypeExpr, mode: ResultTrySequenceMode) anyerror!SequencedArgTemp {
    var replacements: std.ArrayList(lower_c_model.TryReplacement) = .empty;
    defer replacements.deinit(ctx.replacement.scratch);
    const found_try = switch (mode) {
        .local_init => blk: {
            const enclosing_return_ty = return_ty orelse return error.UnsupportedCEmission;
            break :blk try ctx.collect_result_try_hoists_for_local_init(ctx.replacement.emit_ctx, arg, locals, enclosing_return_ty, &replacements);
        },
        .stmt => try ctx.collect_result_try_hoists_for_stmt(ctx.replacement.emit_ctx, arg, locals, return_ty, &replacements),
    };
    if (!found_try) {
        return try ctx.emit_sequenced_arg_temp(ctx.replacement.emit_ctx, arg, locals, target_ty);
    }

    return emitTryOperandTempWithReplacements(ctx.replacement, .result, arg, locals, target_ty, replacements.items);
}

fn emitNullableTryCallArgTemp(ctx: TryCallEmitContext, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!SequencedArgTemp {
    var replacements: std.ArrayList(lower_c_model.TryReplacement) = .empty;
    defer replacements.deinit(ctx.replacement.scratch);
    if (!try ctx.collect_nullable_try_hoists_for_return(ctx.replacement.emit_ctx, arg, locals, &replacements)) {
        return try ctx.emit_sequenced_arg_temp(ctx.replacement.emit_ctx, arg, locals, target_ty);
    }

    return emitTryOperandTempWithReplacements(ctx.replacement, .nullable, arg, locals, target_ty, replacements.items);
}

fn emitNullableTryCallArgTemps(ctx: TryCallEmitContext, call: anytype, locals: *std.StringHashMap(LocalInfo), fn_info: FnInfo) anyerror!std.ArrayList(SequencedArgTemp) {
    var temps: std.ArrayList(SequencedArgTemp) = .empty;
    errdefer temps.deinit(ctx.replacement.scratch);
    for (call.args, 0..) |arg, i| {
        try temps.append(ctx.replacement.scratch, try emitNullableTryCallArgTemp(ctx, arg, locals, fn_info.params[i].ty));
    }
    return temps;
}

fn tryOperandForExpr(expr: ast.Expr) ?ResultTryOperand {
    return switch (expr.kind) {
        .try_expr => |inner| .{ .expr = inner.operand.*, .mapped = inner.mapped },
        else => null,
    };
}

fn emitTryErrReturn(ctx: TryDirectEmitContext, enclosing_return_ty: ast.TypeExpr, temp_name: []const u8, mapped: ?*ast.Expr, operand_result_ty: ast.TypeExpr, locals: ?*std.StringHashMap(LocalInfo)) !void {
    if (locals) |l| try ctx.emit_deferred_cleanups(ctx.replacement.emit_ctx, l, enclosing_return_ty);
    try writeIndent(ctx.replacement);
    const ret_c = try ctx.replacement.c_type(ctx.replacement.emit_ctx, enclosing_return_ty);
    if (mapped) |m| {
        try emitMappedTryErrReturn(ctx, enclosing_return_ty, ret_c, m.*, locals);
    } else {
        try emitPropagatedTryErrReturn(ctx, ret_c, temp_name, enclosing_return_ty, operand_result_ty);
    }
}

fn emitMappedTryErrReturn(ctx: TryDirectEmitContext, enclosing_return_ty: ast.TypeExpr, ret_c: []const u8, mapped: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) !void {
    try ctx.replacement.out.print(ctx.replacement.allocator, "return (({s}){{ .is_ok = false, .payload.err = ", .{ret_c});
    if (resultPayloadTypeForTag(enclosing_return_ty, "err")) |err_ty| {
        try ctx.replacement.emit_expr_with_target(ctx.replacement.emit_ctx, mapped, locals, err_ty);
    } else {
        try ctx.replacement.emit_expr(ctx.replacement.emit_ctx, mapped, locals);
    }
    try ctx.replacement.out.appendSlice(ctx.replacement.allocator, " });\n");
}

fn emitPropagatedTryErrReturn(ctx: TryDirectEmitContext, ret_c: []const u8, temp_name: []const u8, enclosing_return_ty: ast.TypeExpr, operand_result_ty: ast.TypeExpr) !void {
    // G8: when the operand's error type (E1) differs from the function's error type
    // (E2), invoke the resolved `#[error_from]` conversion on the propagated error.
    // When E1 == E2 no conversion resolves and this is byte-identical to before.
    if (errorConversionFn(ctx, enclosing_return_ty, operand_result_ty)) |fname| {
        try ctx.replacement.out.print(ctx.replacement.allocator, "return (({s}){{ .is_ok = false, .payload.err = {s}({s}.payload.err) }});\n", .{ ret_c, fname, temp_name });
        return;
    }
    try ctx.replacement.out.print(ctx.replacement.allocator, "return (({s}){{ .is_ok = false, .payload.err = {s}.payload.err }});\n", .{ ret_c, temp_name });
}

fn errorConversionFn(ctx: TryDirectEmitContext, enclosing_return_ty: ast.TypeExpr, operand_result_ty: ast.TypeExpr) ?[]const u8 {
    const e1 = resultPayloadTypeForTag(operand_result_ty, "err") orelse return null;
    const e2 = resultPayloadTypeForTag(enclosing_return_ty, "err") orelse return null;
    return error_from.resolveTypes(ctx.replacement.functions, e1, e2);
}

fn emitResultTryLocalOperandTemp(ctx: TryDirectEmitContext, operand: ast.Expr, locals: *std.StringHashMap(LocalInfo), operand_result_ty: ast.TypeExpr) ![]const u8 {
    const temp_name = try nextTempName(ctx.replacement);
    try writeIndent(ctx.replacement);
    try ctx.replacement.out.print(ctx.replacement.allocator, "{s} {s} = ", .{ try ctx.replacement.c_type(ctx.replacement.emit_ctx, operand_result_ty), temp_name });
    try ctx.replacement.emit_expr(ctx.replacement.emit_ctx, operand, locals);
    try ctx.replacement.out.appendSlice(ctx.replacement.allocator, ";\n");
    return temp_name;
}

fn emitResultTryErrGuard(ctx: TryDirectEmitContext, enclosing_return_ty: ast.TypeExpr, temp_name: []const u8, mapped: ?*ast.Expr, operand_result_ty: ast.TypeExpr, locals: *std.StringHashMap(LocalInfo)) !void {
    try writeIndent(ctx.replacement);
    try ctx.replacement.out.print(ctx.replacement.allocator, "if (!{s}.is_ok) {{\n", .{temp_name});
    ctx.replacement.indent.* += 1;
    try emitTryErrReturn(ctx, enclosing_return_ty, temp_name, mapped, operand_result_ty, locals);
    ctx.replacement.indent.* -= 1;
    try writeIndent(ctx.replacement);
    try ctx.replacement.out.appendSlice(ctx.replacement.allocator, "}\n");
}

fn emitResultTryOkLocal(ctx: TryDirectEmitContext, name: []const u8, decl_ty: ast.TypeExpr, temp_name: []const u8) !void {
    try writeIndent(ctx.replacement);
    try ctx.replacement.emit_declarator(ctx.replacement.emit_ctx, decl_ty, name);
    try ctx.replacement.out.print(ctx.replacement.allocator, " = {s}.payload.ok;\n", .{temp_name});
}

fn emitResultTryTrapGuard(ctx: TryDirectEmitContext, temp_name: []const u8) !void {
    try writeIndent(ctx.replacement);
    try ctx.replacement.out.print(ctx.replacement.allocator, "if (!{s}.is_ok) mc_trap_InvalidRepresentation();\n", .{temp_name});
}

fn emitResultTryOkReturn(ctx: TryDirectEmitContext, temp_name: []const u8) !void {
    try writeIndent(ctx.replacement);
    try ctx.replacement.out.print(ctx.replacement.allocator, "return {s}.payload.ok;\n", .{temp_name});
}

fn emitNullableTryTrapGuard(ctx: TryDirectEmitContext, temp_name: []const u8, inner_c_type: []const u8) !void {
    try writeIndent(ctx.replacement);
    try ctx.replacement.out.print(ctx.replacement.allocator, "if ({s}{s} == NULL) mc_trap_NullUnwrap();\n", .{ temp_name, if (lower_c_type.isDynCTypeName(inner_c_type)) ".data" else "" });
}

fn emitResultTryTrapHoist(ctx_ptr: *anyopaque, expr: ast.Expr) anyerror!bool {
    const ctx: *DirectTryHoistContext = @ptrCast(@alignCast(ctx_ptr));
    const inner = switch (expr.kind) {
        .try_expr => |node| node,
        else => return false,
    };
    const temp_name = (try emitResultTryHoistTemp(ctx, expr.span, inner.operand.*)) orelse return false;

    try emitResultTryTrapGuard(ctx.ctx, temp_name);
    return true;
}

fn emitResultTryPropagateHoist(ctx_ptr: *anyopaque, expr: ast.Expr) anyerror!bool {
    const ctx: *DirectTryHoistContext = @ptrCast(@alignCast(ctx_ptr));
    const enclosing_return_ty = ctx.enclosing_return_ty orelse return false;
    const inner = switch (expr.kind) {
        .try_expr => |node| node,
        else => return false,
    };
    const temp_name = (try emitResultTryHoistTemp(ctx, expr.span, inner.operand.*)) orelse return false;
    const operand_result_ty = ctx.ctx.result_type_for_expr(ctx.ctx.replacement.emit_ctx, inner.operand.*, ctx.locals) orelse return false;

    try writeIndent(ctx.ctx.replacement);
    try ctx.ctx.replacement.out.print(ctx.ctx.replacement.allocator, "if (!{s}.is_ok) {{\n", .{temp_name});
    ctx.ctx.replacement.indent.* += 1;
    try emitTryErrReturn(ctx.ctx, enclosing_return_ty, temp_name, inner.mapped, operand_result_ty, ctx.locals);
    ctx.ctx.replacement.indent.* -= 1;
    try writeIndent(ctx.ctx.replacement);
    try ctx.ctx.replacement.out.appendSlice(ctx.ctx.replacement.allocator, "}\n");
    return true;
}

fn emitResultTryHoistTemp(ctx: *DirectTryHoistContext, span: ast.Span, operand: ast.Expr) anyerror!?[]const u8 {
    const operand_result_ty = ctx.ctx.result_type_for_expr(ctx.ctx.replacement.emit_ctx, operand, ctx.locals) orelse return null;
    _ = resultPayloadTypeForTag(operand_result_ty, "ok") orelse return null;
    _ = resultPayloadTypeForTag(operand_result_ty, "err") orelse return null;
    const temp_name = try nextTempName(ctx.ctx.replacement);
    try ctx.replacements.append(ctx.ctx.replacement.scratch, .{ .span = span, .temp_name = temp_name });

    try writeIndent(ctx.ctx.replacement);
    try ctx.ctx.replacement.out.print(ctx.ctx.replacement.allocator, "{s} {s} = ", .{ try ctx.ctx.replacement.c_type(ctx.ctx.replacement.emit_ctx, operand_result_ty), temp_name });
    try ctx.ctx.replacement.emit_expr(ctx.ctx.replacement.emit_ctx, operand, ctx.locals);
    try ctx.ctx.replacement.out.appendSlice(ctx.ctx.replacement.allocator, ";\n");
    return temp_name;
}

fn emitNullableTryTrapHoist(ctx_ptr: *anyopaque, expr: ast.Expr) anyerror!bool {
    const ctx: *DirectTryHoistContext = @ptrCast(@alignCast(ctx_ptr));
    const inner = switch (expr.kind) {
        .try_expr => |node| node,
        else => return false,
    };
    const inner_c_type = try ctx.ctx.nullable_inner_c_type_for_expr(ctx.ctx.replacement.emit_ctx, inner.operand.*, ctx.locals) orelse return false;
    const temp_name = try nextTempName(ctx.ctx.replacement);
    try ctx.replacements.append(ctx.ctx.replacement.scratch, .{ .span = expr.span, .temp_name = temp_name });

    try writeIndent(ctx.ctx.replacement);
    try ctx.ctx.replacement.out.print(ctx.ctx.replacement.allocator, "{s} {s} = ", .{ inner_c_type, temp_name });
    try ctx.ctx.replacement.emit_expr(ctx.ctx.replacement.emit_ctx, inner.operand.*, ctx.locals);
    try ctx.ctx.replacement.out.appendSlice(ctx.ctx.replacement.allocator, ";\n");

    try emitNullableTryTrapGuard(ctx.ctx, temp_name, inner_c_type);
    return true;
}

fn assignmentTargetType(ctx: TryReplacementEmitContext, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
    return ctx.operand_emit_type(ctx.emit_ctx, assignment.target, locals) orelse blk: {
        const target = ctx.global_assignment_target(ctx.emit_ctx, assignment.target, locals) orelse return null;
        break :blk ast_query.simpleNameType(target.info.type_name, assignment.value.span);
    };
}

fn emitAssignmentFromTemp(ctx: TryReplacementEmitContext, target: ast.Expr, locals: *std.StringHashMap(LocalInfo), temp_name: []const u8) !void {
    try writeIndent(ctx);
    if (ctx.global_assignment_target(ctx.emit_ctx, target, locals)) |global_target| {
        try appendGlobalStoreValue(ctx.allocator, ctx.out, global_target, temp_name);
    } else {
        try ctx.emit_assign_target(ctx.emit_ctx, target, locals);
        try ctx.out.print(ctx.allocator, " = {s};\n", .{temp_name});
    }
}

fn emitCheckedUnaryTryReplacement(ctx: TryReplacementEmitContext, mode: TryReplacementMode, node: anytype, locals: ?*std.StringHashMap(lower_c_model.LocalInfo), target_ty: ?ast.TypeExpr, replacements: []const lower_c_model.TryReplacement) anyerror!bool {
    if (node.op != .neg) return false;
    const target = if (target_ty) |ty| lower_c_alias.resolveAliasType(ctx.type_aliases, ty) else return error.UnsupportedCEmission;
    if (ast_query.isWrapType(target) or ast_query.isSatType(target)) return false;
    const target_name = ast_query.typeName(target) orelse return error.UnsupportedCEmission;
    const suffix = lower_c_type.signedTypeSuffix(target_name) orelse return false;

    try ctx.out.print(ctx.allocator, "mc_checked_neg_{s}(", .{suffix});
    try emitTryExprWithReplacements(ctx, mode, node.expr.*, locals, target, replacements);
    try ctx.out.appendSlice(ctx.allocator, ")");
    return true;
}

fn writeIndent(ctx: TryReplacementEmitContext) !void {
    for (0..ctx.indent.*) |_| try ctx.out.appendSlice(ctx.allocator, "    ");
}

fn nextTempName(ctx: TryReplacementEmitContext) ![]const u8 {
    const temp_name = try std.fmt.allocPrint(ctx.scratch, "mc_tmp{d}", .{ctx.temp_index.*});
    ctx.temp_index.* += 1;
    return temp_name;
}

pub fn exprContainsTry(ctx: *anyopaque, expr: ast.Expr, predicate: TryPredicateFn) bool {
    return switch (expr.kind) {
        .try_expr => |inner| predicate(ctx, inner.operand.*),
        .grouped, .address_of, .deref => |inner| exprContainsTry(ctx, inner.*, predicate),
        .unary => |node| exprContainsTry(ctx, node.expr.*, predicate),
        .binary => |node| exprContainsTry(ctx, node.left.*, predicate) or exprContainsTry(ctx, node.right.*, predicate),
        .call => |node| argsContainTry(ctx, node.args, predicate),
        .index => |node| exprContainsTry(ctx, node.base.*, predicate) or exprContainsTry(ctx, node.index.*, predicate),
        .member => |node| exprContainsTry(ctx, node.base.*, predicate),
        .cast => |node| exprContainsTry(ctx, node.value.*, predicate),
        else => false,
    };
}

pub fn argsContainTry(ctx: *anyopaque, args: []const ast.Expr, predicate: TryPredicateFn) bool {
    for (args) |arg| {
        if (exprContainsTry(ctx, arg, predicate)) return true;
    }
    return false;
}

pub fn exprContainsTryError(ctx: *anyopaque, expr: ast.Expr, predicate: TryPredicateErrorFn) anyerror!bool {
    return switch (expr.kind) {
        .try_expr => |inner| try predicate(ctx, inner.operand.*),
        .grouped, .address_of, .deref => |inner| try exprContainsTryError(ctx, inner.*, predicate),
        .unary => |node| try exprContainsTryError(ctx, node.expr.*, predicate),
        .binary => |node| (try exprContainsTryError(ctx, node.left.*, predicate)) or (try exprContainsTryError(ctx, node.right.*, predicate)),
        .call => |node| try argsContainTryError(ctx, node.args, predicate),
        .index => |node| (try exprContainsTryError(ctx, node.base.*, predicate)) or (try exprContainsTryError(ctx, node.index.*, predicate)),
        .member => |node| try exprContainsTryError(ctx, node.base.*, predicate),
        .cast => |node| try exprContainsTryError(ctx, node.value.*, predicate),
        else => false,
    };
}

pub fn argsContainTryError(ctx: *anyopaque, args: []const ast.Expr, predicate: TryPredicateErrorFn) anyerror!bool {
    for (args) |arg| {
        if (try exprContainsTryError(ctx, arg, predicate)) return true;
    }
    return false;
}

pub fn collectTryHoists(ctx: *anyopaque, expr: ast.Expr, hoist: TryHoistFn) anyerror!bool {
    switch (expr.kind) {
        .try_expr => return try hoist(ctx, expr),
        .grouped => |inner| return try collectTryHoists(ctx, inner.*, hoist),
        .call => |node| {
            var found = false;
            for (node.args) |arg| found = (try collectTryHoists(ctx, arg, hoist)) or found;
            return found;
        },
        .unary => |node| return try collectTryHoists(ctx, node.expr.*, hoist),
        .binary => |node| {
            // Evaluate both operands without short-circuiting so `a? OP b?`
            // hoists both tries, not just the left one.
            const left_found = try collectTryHoists(ctx, node.left.*, hoist);
            const right_found = try collectTryHoists(ctx, node.right.*, hoist);
            return left_found or right_found;
        },
        .index => |node| {
            const base_found = try collectTryHoists(ctx, node.base.*, hoist);
            const index_found = try collectTryHoists(ctx, node.index.*, hoist);
            return base_found or index_found;
        },
        .member => |node| return try collectTryHoists(ctx, node.base.*, hoist),
        .cast => |node| return try collectTryHoists(ctx, node.value.*, hoist),
        else => return false,
    }
}

pub fn exprContainsCall(ctx: *anyopaque, expr: ast.Expr, scan: CallScanFn) bool {
    return switch (expr.kind) {
        .call => |node| switch (scan(ctx, expr)) {
            .found => true,
            .ignored => false,
            .descend => argsContainCall(ctx, node.args, scan),
        },
        .grouped, .address_of, .deref => |inner| exprContainsCall(ctx, inner.*, scan),
        .unary => |node| exprContainsCall(ctx, node.expr.*, scan),
        .binary => |node| exprContainsCall(ctx, node.left.*, scan) or exprContainsCall(ctx, node.right.*, scan),
        .index => |node| exprContainsCall(ctx, node.base.*, scan) or exprContainsCall(ctx, node.index.*, scan),
        .member => |node| exprContainsCall(ctx, node.base.*, scan),
        .cast => |node| exprContainsCall(ctx, node.value.*, scan),
        else => false,
    };
}

pub fn argsContainCall(ctx: *anyopaque, args: []const ast.Expr, scan: CallScanFn) bool {
    for (args) |arg| {
        if (exprContainsCall(ctx, arg, scan)) return true;
    }
    return false;
}

pub fn countCalls(ctx: *anyopaque, expr: ast.Expr, scan: CallScanFn) usize {
    return switch (expr.kind) {
        .call => |node| switch (scan(ctx, expr)) {
            .found => 1,
            .ignored => 0,
            .descend => countArgs(ctx, node.args, scan),
        },
        .grouped, .address_of, .deref => |inner| countCalls(ctx, inner.*, scan),
        .unary => |node| countCalls(ctx, node.expr.*, scan),
        .binary => |node| countCalls(ctx, node.left.*, scan) + countCalls(ctx, node.right.*, scan),
        .index => |node| countCalls(ctx, node.base.*, scan) + countCalls(ctx, node.index.*, scan),
        .member => |node| countCalls(ctx, node.base.*, scan),
        .cast => |node| countCalls(ctx, node.value.*, scan),
        else => 0,
    };
}

pub fn countArgs(ctx: *anyopaque, args: []const ast.Expr, scan: CallScanFn) usize {
    var n: usize = 0;
    for (args) |arg| n += countCalls(ctx, arg, scan);
    return n;
}

pub fn collectCallHoists(ctx: *anyopaque, expr: ast.Expr, hoist: CallHoistFn, binary_guard: BinaryGuardFn) anyerror!bool {
    switch (expr.kind) {
        .call => |node| switch (try hoist(ctx, expr)) {
            .hoisted => return true,
            .ignored => return false,
            .descend => {
                var found = false;
                for (node.args) |arg| found = (try collectCallHoists(ctx, arg, hoist, binary_guard)) or found;
                return found;
            },
        },
        .grouped, .address_of, .deref => |inner| return try collectCallHoists(ctx, inner.*, hoist, binary_guard),
        .unary => |node| return try collectCallHoists(ctx, node.expr.*, hoist, binary_guard),
        .binary => |node| {
            if (try binary_guard(ctx, expr)) |handled| return handled;
            const left_found = try collectCallHoists(ctx, node.left.*, hoist, binary_guard);
            const right_found = try collectCallHoists(ctx, node.right.*, hoist, binary_guard);
            return left_found or right_found;
        },
        .index => |node| {
            const base_found = try collectCallHoists(ctx, node.base.*, hoist, binary_guard);
            const index_found = try collectCallHoists(ctx, node.index.*, hoist, binary_guard);
            return base_found or index_found;
        },
        .member => |node| return try collectCallHoists(ctx, node.base.*, hoist, binary_guard),
        .cast => |node| return try collectCallHoists(ctx, node.value.*, hoist, binary_guard),
        else => return false,
    }
}
