//! Cross-domain C lowering dispatch helpers.
//!
//! These helpers own ordering between independently factored lowering domains
//! where the order is semantically meaningful.

const std = @import("std");

const ast = @import("ast.zig");
const lower_c_mmio = @import("lower_c_mmio.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_try = @import("lower_c_try.zig");

const LocalInfo = lower_c_model.LocalInfo;

pub const TryMmioContext = struct {
    try_stmt: lower_c_try.TryStmtEmitContext,
    try_direct: lower_c_try.TryDirectEmitContext,
    try_replacement: lower_c_try.TryReplacementEmitContext,
    try_call: lower_c_try.TryCallEmitContext,
    mmio_emit: lower_c_mmio.EmitContext,
    mmio_replacement: lower_c_mmio.ReplacementEmitContext,
    mmio_call: lower_c_mmio.CallEmitContext,
};

pub fn emitTypedLocalInit(
    ctx: TryMmioContext,
    name: []const u8,
    decl_ty: ast.TypeExpr,
    initializer: ast.Expr,
    locals: *std.StringHashMap(LocalInfo),
    return_ty: ?ast.TypeExpr,
) anyerror!bool {
    if (try lower_c_try.emitResultTryExprLocalInit(ctx.try_stmt, name, decl_ty, initializer, locals, return_ty)) return true;
    if (try lower_c_try.emitNullableTryExprLocalInit(ctx.try_stmt, name, decl_ty, initializer, locals)) return true;
    if (try lower_c_try.emitResultTryLocalInit(ctx.try_direct, name, decl_ty, initializer, locals, return_ty)) return true;
    if (try lower_c_mmio.emitDirectReadLocalInitExpr(ctx.mmio_emit, name, decl_ty, initializer, locals)) return true;
    if (try lower_c_mmio.emitReadExprLocalInit(ctx.mmio_call, name, decl_ty, initializer, locals)) return true;
    return false;
}

pub fn emitAssignmentStmt(ctx: TryMmioContext, assignment: anytype, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!bool {
    if (try lower_c_try.emitResultTryAssignmentStmt(ctx.try_stmt, assignment, locals, return_ty)) return true;
    if (try lower_c_try.emitNullableTryAssignmentStmt(ctx.try_stmt, assignment, locals)) return true;
    if (try lower_c_mmio.emitDirectReadAssignment(ctx.mmio_emit, ctx.mmio_replacement, assignment, locals)) return true;
    if (try lower_c_mmio.emitReadExprAssignment(ctx.mmio_call, assignment, locals)) return true;
    return false;
}

pub fn emitReturn(ctx: TryMmioContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!bool {
    if (try lower_c_try.emitResultTryCallReturn(ctx.try_call, expr, locals)) return true;
    if (try lower_c_try.emitResultTryConstructorReturn(ctx.try_call, expr, locals, return_ty)) return true;
    if (try lower_c_try.emitNullableTryCallReturn(ctx.try_call, expr, locals)) return true;
    if (try lower_c_try.emitResultTryReturn(ctx.try_direct, expr, locals, return_ty)) return true;
    if (try lower_c_try.emitNullableTryReturn(ctx.try_direct, expr, locals)) return true;
    if (try lower_c_try.emitResultTrySequencedBinaryReturn(ctx.try_replacement, expr, locals, return_ty)) return true;
    if (try lower_c_try.emitNullableTrySequencedBinaryReturn(ctx.try_replacement, expr, locals, return_ty)) return true;
    if (try lower_c_mmio.emitReadCallReturn(ctx.mmio_call, expr, locals)) return true;
    if (try lower_c_mmio.emitReadExprReturn(ctx.mmio_call, expr, locals, return_ty)) return true;
    return false;
}
