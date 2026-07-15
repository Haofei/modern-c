//! C backend memory-view and DMA call emission.

const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const lower_c_model = @import("lower_c_model.zig");
const mir = @import("mir.zig");

const LocalInfo = lower_c_model.LocalInfo;
const byteViewAddressTarget = ast_query.byteViewAddressTarget;
const isIdentNamed = ast_query.isIdentNamed;
const memberCallee = ast_query.memberCallee;

pub const EmitExprFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void;
pub const EmitExprWithTargetFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!void;
pub const CTypeFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8;
pub const SliceTypeNameFn = *const fn (ctx: *anyopaque, child: ast.TypeExpr, mutability: ast.Mutability) anyerror![]const u8;
pub const MirCallTargetKindFn = *const fn (ctx: *anyopaque, span: ast.Span) ?mir.CallTargetKind;
pub const MirTargetTypeFn = *const fn (ctx: *anyopaque, kind: mir.TargetTypeKind, span: ast.Span) ?ast.TypeExpr;

pub const Context = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: *usize,
    temp_index: *usize,
    type_aliases: *const std.StringHashMap(ast.TypeExpr),
    emit_ctx: *anyopaque,
    emit_expr: EmitExprFn,
    emit_expr_with_target: EmitExprWithTargetFn,
    c_type: CTypeFn,
    slice_type_name: SliceTypeNameFn,
    mir_call_target_kind: MirCallTargetKindFn,
    mir_target_type: MirTargetTypeFn,
};

pub fn emitByteViewCall(ctx: Context, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
    const kind = ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) orelse return false;
    if (kind != .byte_view_as_bytes and kind != .byte_view_equal) return false;
    const source_ty = ctx.mir_target_type(ctx.emit_ctx, .byte_view_source, call.callee.*.span) orelse return error.UnsupportedCEmission;
    const result_ty = ctx.mir_target_type(ctx.emit_ctx, .byte_view_result, call.callee.*.span) orelse return error.UnsupportedCEmission;
    if (call.type_args.len != 0) return error.UnsupportedCEmission;
    switch (kind) {
        .byte_view_as_bytes => {
            if (call.args.len != 1) return error.UnsupportedCEmission;
            _ = byteViewAddressTarget(call.args[0]) orelse return error.UnsupportedCEmission;
            try ctx.out.print(ctx.allocator, "(({s}){{ .ptr = (uint8_t const *)(void *)(", .{try ctx.c_type(ctx.emit_ctx, result_ty)});
            try ctx.emit_expr(ctx.emit_ctx, call.args[0], locals);
            try ctx.out.print(ctx.allocator, "), .len = (uintptr_t)sizeof({s}) }})", .{try ctx.c_type(ctx.emit_ctx, source_ty)});
            return true;
        },
        .byte_view_equal => {
            if (call.args.len != 2) return error.UnsupportedCEmission;
            const n = ctx.temp_index.*;
            ctx.temp_index.* += 1;
            try ctx.out.print(ctx.allocator, "({{ __auto_type mc_a{d} = (", .{n});
            try ctx.emit_expr_with_target(ctx.emit_ctx, call.args[0], locals, source_ty);
            try ctx.out.print(ctx.allocator, "); __auto_type mc_b{d} = (", .{n});
            try ctx.emit_expr_with_target(ctx.emit_ctx, call.args[1], locals, source_ty);
            try ctx.out.print(ctx.allocator, "); (mc_a{d}.len == mc_b{d}.len) && (__builtin_memcmp(mc_a{d}.ptr, mc_b{d}.ptr, mc_a{d}.len) == 0); }})", .{ n, n, n, n, n });
            return true;
        },
        else => unreachable,
    }
}

pub fn emitDmaCall(ctx: Context, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
    const member = memberCallee(call.callee.*) orelse return false;
    const kind = ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) orelse {
        if ((isIdentNamed(member.base.*, "cache") and
            (std.mem.eql(u8, member.name.text, "clean") or std.mem.eql(u8, member.name.text, "invalidate"))) or
            std.mem.eql(u8, member.name.text, "dma_addr") or
            std.mem.eql(u8, member.name.text, "as_slice")) return error.UnsupportedCEmission;
        return false;
    };
    const fact_info = mir.dmaCallFactInfo(kind) orelse return false;
    const buffer_ty = ctx.mir_target_type(ctx.emit_ctx, .dma_buffer, call.callee.*.span) orelse return error.UnsupportedCEmission;
    const payload_ty = ctx.mir_target_type(ctx.emit_ctx, .dma_payload, call.callee.*.span) orelse return error.UnsupportedCEmission;
    _ = ctx.mir_target_type(ctx.emit_ctx, .dma_result, call.callee.*.span) orelse return error.UnsupportedCEmission;

    if (fact_info.cache) {
        if (!isIdentNamed(member.base.*, "cache") or !std.mem.eql(u8, member.name.text, fact_info.op)) return error.UnsupportedCEmission;
        if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedCEmission;
        try ctx.out.appendSlice(ctx.allocator, "((void)(");
        try ctx.emit_expr_with_target(ctx.emit_ctx, call.args[0], locals, buffer_ty);
        try ctx.out.appendSlice(ctx.allocator, if (kind == .dma_cache_clean) "), mc_barrier_release_before())" else "), mc_barrier_acquire_after())");
        return true;
    }

    if (!std.mem.eql(u8, member.name.text, fact_info.op)) return error.UnsupportedCEmission;
    if (kind == .dma_addr) {
        if (call.type_args.len != 0 or call.args.len != 0) return error.UnsupportedCEmission;
        try ctx.out.appendSlice(ctx.allocator, "((uintptr_t)(");
        try ctx.emit_expr_with_target(ctx.emit_ctx, member.base.*, locals, buffer_ty);
        try ctx.out.appendSlice(ctx.allocator, "))");
        return true;
    }
    if (kind == .dma_as_slice) {
        if (call.type_args.len != 0 or call.args.len != 0) return error.UnsupportedCEmission;
        const slice_name = try ctx.slice_type_name(ctx.emit_ctx, payload_ty, .mut);
        try ctx.out.print(ctx.allocator, "(({s}){{ .ptr = ", .{slice_name});
        try ctx.emit_expr_with_target(ctx.emit_ctx, member.base.*, locals, buffer_ty);
        try ctx.out.appendSlice(ctx.allocator, ", .len = 1 }})");
        return true;
    }
    return error.UnsupportedCEmission;
}

pub fn emitMaybeUninitAssumeInitCall(ctx: Context, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
    if (call.type_args.len != 0 or call.args.len != 0) return false;
    const member = memberCallee(call.callee.*) orelse return false;
    if (ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) != .maybe_uninit_assume_init) return false;
    _ = ctx.mir_target_type(ctx.emit_ctx, .maybe_uninit_payload, call.callee.*.span) orelse return error.UnsupportedCEmission;
    try ctx.emit_expr(ctx.emit_ctx, member.base.*, locals);
    return true;
}

pub fn emitMaybeUninitWriteStmt(ctx: Context, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const call = switch (expr.kind) {
        .call => |call| call,
        else => return false,
    };
    if (call.type_args.len != 0 or call.args.len != 1) return false;
    const member = memberCallee(call.callee.*) orelse return false;
    if (ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) != .maybe_uninit_write) return false;
    const payload_ty = ctx.mir_target_type(ctx.emit_ctx, .maybe_uninit_payload, call.callee.*.span) orelse return error.UnsupportedCEmission;
    try writeIndent(ctx);
    try ctx.emit_expr(ctx.emit_ctx, member.base.*, locals);
    try ctx.out.appendSlice(ctx.allocator, " = ");
    try ctx.emit_expr_with_target(ctx.emit_ctx, call.args[0], locals, payload_ty);
    try ctx.out.appendSlice(ctx.allocator, ";\n");
    return true;
}

fn writeIndent(ctx: Context) !void {
    for (0..ctx.indent.*) |_| try ctx.out.appendSlice(ctx.allocator, "    ");
}
