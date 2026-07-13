//! C backend memory-view and DMA call emission.

const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const lower_c_model = @import("lower_c_model.zig");
const mir = @import("mir.zig");

const LocalInfo = lower_c_model.LocalInfo;
const byteViewAddressTarget = ast_query.byteViewAddressTarget;
const byteViewCallKind = ast_query.byteViewCallKind;
const dmaBufInfo = ast_query.dmaBufInfo;
const isIdentNamed = ast_query.isIdentNamed;
const memberCallee = ast_query.memberCallee;
const simpleNameType = ast_query.simpleNameType;

pub const EmitExprFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void;
pub const EmitExprWithTargetFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!void;
pub const CTypeFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8;
pub const SliceTypeNameFn = *const fn (ctx: *anyopaque, child: ast.TypeExpr, mutability: ast.Mutability) anyerror![]const u8;
pub const CIdentFn = *const fn (ctx: *anyopaque, name: []const u8) anyerror![]const u8;
pub const ExprTypeFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr;
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
    c_ident: CIdentFn,
    operand_emit_type: ExprTypeFn,
    expr_source_type: ExprTypeFn,
    mir_call_target_kind: MirCallTargetKindFn,
    mir_target_type: MirTargetTypeFn,
};

pub fn emitByteViewCall(ctx: Context, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
    const kind = byteViewCallKind(call.callee.*) orelse return false;
    const expected_fact = mir.byteViewCallTargetKind(call) orelse return error.UnsupportedCEmission;
    if (ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) != expected_fact) return error.UnsupportedCEmission;
    _ = ctx.mir_target_type(ctx.emit_ctx, .byte_view_result, call.callee.*.span) orelse return error.UnsupportedCEmission;
    if (call.type_args.len != 0) return error.UnsupportedCEmission;
    switch (kind) {
        .as_bytes => {
            if (call.args.len != 1) return error.UnsupportedCEmission;
            const target = byteViewAddressTarget(call.args[0]) orelse return error.UnsupportedCEmission;
            const source_ty = ctx.operand_emit_type(ctx.emit_ctx, target, locals) orelse
                ctx.expr_source_type(ctx.emit_ctx, target, locals) orelse
                return error.UnsupportedCEmission;
            const slice_name = try ctx.slice_type_name(ctx.emit_ctx, simpleNameType("u8", call.callee.*.span), .@"const");
            try ctx.out.print(ctx.allocator, "(({s}){{ .ptr = (uint8_t const *)(void *)(", .{slice_name});
            try ctx.emit_expr(ctx.emit_ctx, call.args[0], locals);
            try ctx.out.print(ctx.allocator, "), .len = (uintptr_t)sizeof({s}) }})", .{try ctx.c_type(ctx.emit_ctx, source_ty)});
            return true;
        },
        .bytes_equal => {
            if (call.args.len != 2) return error.UnsupportedCEmission;
            const n = ctx.temp_index.*;
            ctx.temp_index.* += 1;
            try ctx.out.print(ctx.allocator, "({{ __auto_type mc_a{d} = (", .{n});
            try ctx.emit_expr(ctx.emit_ctx, call.args[0], locals);
            try ctx.out.print(ctx.allocator, "); __auto_type mc_b{d} = (", .{n});
            try ctx.emit_expr(ctx.emit_ctx, call.args[1], locals);
            try ctx.out.print(ctx.allocator, "); (mc_a{d}.len == mc_b{d}.len) && (__builtin_memcmp(mc_a{d}.ptr, mc_b{d}.ptr, mc_a{d}.len) == 0); }})", .{ n, n, n, n, n });
            return true;
        },
    }
}

pub fn emitDmaCall(ctx: Context, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
    const member = memberCallee(call.callee.*) orelse return false;

    if (isIdentNamed(member.base.*, "cache")) {
        if (!std.mem.eql(u8, member.name.text, "clean") and !std.mem.eql(u8, member.name.text, "invalidate")) return false;
        if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedCEmission;
        try ctx.out.appendSlice(ctx.allocator, if (std.mem.eql(u8, member.name.text, "clean")) "mc_barrier_release_before()" else "mc_barrier_acquire_after()");
        return true;
    }

    const local_set = locals orelse return false;
    const base_name = switch (member.base.kind) {
        .ident => |ident| ident.text,
        else => return false,
    };
    const info = local_set.get(base_name) orelse return false;
    const dma = dmaBufInfo(info.source_ty orelse return false) orelse return false;

    if (std.mem.eql(u8, member.name.text, "dma_addr")) {
        if (call.type_args.len != 0 or call.args.len != 0) return error.UnsupportedCEmission;
        try ctx.out.print(ctx.allocator, "((uintptr_t){s})", .{try ctx.c_ident(ctx.emit_ctx, base_name)});
        return true;
    }
    if (std.mem.eql(u8, member.name.text, "as_slice")) {
        if (call.type_args.len != 0 or call.args.len != 0) return error.UnsupportedCEmission;
        const slice_name = try ctx.slice_type_name(ctx.emit_ctx, dma.payload, .mut);
        try ctx.out.print(ctx.allocator, "(({s}){{ .ptr = {s}, .len = 1 }})", .{ slice_name, try ctx.c_ident(ctx.emit_ctx, base_name) });
        return true;
    }
    return false;
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
