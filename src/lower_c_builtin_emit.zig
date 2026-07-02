//! C backend builtin-call emission routing.
//!
//! This module owns the builtin dispatcher and delegates actual lowering to the
//! focused call, memory, arithmetic, access, and platform modules.

const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const lower_c_access = @import("lower_c_access.zig");
const lower_c_arith = @import("lower_c_arith.zig");
const lower_c_atomic = @import("lower_c_atomic.zig");
const lower_c_call = @import("lower_c_call.zig");
const lower_c_convert = @import("lower_c_convert.zig");
const lower_c_domain = @import("lower_c_domain.zig");
const lower_c_memory = @import("lower_c_memory.zig");
const lower_c_mmio = @import("lower_c_mmio.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_reflect = @import("lower_c_reflect.zig");

const LocalInfo = lower_c_model.LocalInfo;
const memberCallee = ast_query.memberCallee;

pub const EnumNameForValueExprFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8;
pub const EmitExprFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void;

pub const Context = struct {
    enum_ctx: *anyopaque,
    enum_name_for_value_expr: EnumNameForValueExprFn,
    emit_expr: EmitExprFn,
    enums: *const std.StringHashMap(ast.EnumDecl),
    atomic: lower_c_atomic.EmitContext,
    call: lower_c_call.Context,
    convert: lower_c_convert.Context,
    memory: lower_c_memory.Context,
    mmio: lower_c_mmio.EmitContext,
    arith: lower_c_arith.Context,
    domain: lower_c_domain.Context,
    reflect: lower_c_reflect.EmitContext,
    access: lower_c_access.EmitContext,
};

pub fn emitBuiltinCallExpr(ctx: Context, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) anyerror!bool {
    if (try emitCoreBuiltinCallExpr(ctx, node, locals)) return true;
    if (try emitMemoryBuiltinCallExpr(ctx, node, locals)) return true;
    if (try emitArithmeticBuiltinCallExpr(ctx, node, locals)) return true;
    return false;
}

fn emitCoreBuiltinCallExpr(ctx: Context, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) anyerror!bool {
    if (try lower_c_atomic.emitAtomicInitCall(ctx.atomic, node, locals)) return true;
    if (try lower_c_atomic.emitAtomicCall(ctx.atomic, node, locals)) return true;
    if (try lower_c_call.emitPhysCall(ctx.call, node, locals)) return true;
    if (try emitEnumRawCall(ctx, node, locals)) return true;
    if (try lower_c_convert.emitConversionCall(ctx.convert, node, locals)) return true;
    if (try lower_c_convert.emitBitcastCall(ctx.convert, node, locals)) return true;
    if (try lower_c_call.emitDeclassifyCall(ctx.call, node, locals)) return true;
    if (try lower_c_memory.emitDmaCall(ctx.memory, node, locals)) return true;
    if (try lower_c_mmio.emitMmioMapCall(ctx.mmio, node, locals)) return true;
    if (try lower_c_mmio.emitInlineReadCall(ctx.mmio, node, locals)) return true;
    if (try lower_c_memory.emitMaybeUninitAssumeInitCall(ctx.memory, node, locals)) return true;
    return false;
}

fn emitMemoryBuiltinCallExpr(ctx: Context, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) anyerror!bool {
    if (try lower_c_arith.emitResidueCall(ctx.arith, node, locals)) return true;
    if (try lower_c_domain.emitDomainOpCall(ctx.domain, node, locals)) return true;
    if (try lower_c_reflect.emitReflectionCall(ctx.reflect, node)) return true;
    if (try lower_c_access.emitConstGetCall(ctx.access, node, locals)) return true;
    if (try lower_c_access.emitRawManyOffsetCall(ctx.access, node, locals)) return true;
    if (try lower_c_memory.emitByteViewCall(ctx.memory, node, locals)) return true;
    if (try lower_c_call.emitAssumeNoaliasCall(ctx.call, node, locals)) return true;
    return false;
}

fn emitArithmeticBuiltinCallExpr(ctx: Context, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) anyerror!bool {
    if (try lower_c_arith.emitWrappingCall(ctx.arith, node, locals)) return true;
    if (try lower_c_arith.emitReduceSumCheckedCall(ctx.arith, node, locals)) return true;
    if (try lower_c_call.emitUncheckedCall(ctx.call, node, locals)) return true;
    return false;
}

fn emitEnumRawCall(ctx: Context, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
    if (call.type_args.len != 0) return false;
    const member = memberCallee(call.callee.*) orelse return false;
    if (!std.mem.eql(u8, member.name.text, "raw")) return false;
    if (call.args.len != 0) return error.UnsupportedCEmission;
    const enum_name = ctx.enum_name_for_value_expr(ctx.enum_ctx, member.base.*, locals) orelse return false;
    // `.raw()` is a transparent-repr read on both open and closed enums: emit the
    // enum-typed base directly (its C value already IS the representation integer).
    _ = ctx.enums.get(enum_name) orelse return false;
    try ctx.emit_expr(ctx.enum_ctx, member.base.*, locals);
    return true;
}
