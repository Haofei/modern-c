//! C backend atomic helpers.
//!
//! Classifies atomic memory orderings, maps them to C `__ATOMIC_*` constants,
//! validates atomic payload types, resolves `fence.*` helpers, and emits the
//! small atomic builtin call forms through a narrow emitter callback context.

const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const lower_c_model = @import("lower_c_model.zig");
const mir = @import("mir.zig");

const isIdentNamed = ast_query.isIdentNamed;
const memberCallee = ast_query.memberCallee;
const typeName = ast_query.typeName;
const LocalInfo = lower_c_model.LocalInfo;

pub const EmitExprFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void;
pub const EmitExprWithTargetFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) anyerror!void;
pub const ExprIsPointerFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool;
pub const MirCallTargetKindFn = *const fn (ctx: *anyopaque, span: ast.Span) ?mir.CallTargetKind;
pub const MirTargetTypeFn = *const fn (ctx: *anyopaque, kind: mir.TargetTypeKind, span: ast.Span) ?ast.TypeExpr;

pub const EmitContext = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    emit_ctx: *anyopaque,
    emit_expr: EmitExprFn,
    emit_expr_with_target: EmitExprWithTargetFn,
    expr_is_pointer: ExprIsPointerFn,
    mir_call_target_kind: MirCallTargetKindFn,
    mir_target_type: MirTargetTypeFn,
};

pub fn orderingArg(args: []ast.Expr) []const u8 {
    for (args) |arg| {
        if (arg.kind == .enum_literal) return arg.kind.enum_literal.text;
    }
    return "none";
}

pub fn atomicOrderingArg(args: []const ast.Expr, index: usize) []const u8 {
    if (index >= args.len) return "none";
    return switch (args[index].kind) {
        .enum_literal => |literal| literal.text,
        else => "none",
    };
}

pub fn asmHasMemoryClobber(asm_stmt: ast.AsmStmt) bool {
    if (asm_stmt.clobbers.len == 0) return true;
    for (asm_stmt.clobbers) |clobber| {
        if (std.mem.indexOf(u8, clobber, "memory") != null) return true;
    }
    return false;
}

pub fn atomicOrderCConstant(ordering: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, ordering, "relaxed")) return "__ATOMIC_RELAXED";
    if (std.mem.eql(u8, ordering, "acquire")) return "__ATOMIC_ACQUIRE";
    if (std.mem.eql(u8, ordering, "release")) return "__ATOMIC_RELEASE";
    if (std.mem.eql(u8, ordering, "acq_rel")) return "__ATOMIC_ACQ_REL";
    if (std.mem.eql(u8, ordering, "seq_cst")) return "__ATOMIC_SEQ_CST";
    return null;
}

pub fn atomicOrderSynchronizes(ordering: []const u8) bool {
    return !std.mem.eql(u8, ordering, "relaxed") and atomicOrderCConstant(ordering) != null;
}

pub fn isAtomicLoadOrdering(ordering: []const u8) bool {
    return std.mem.eql(u8, ordering, "relaxed") or
        std.mem.eql(u8, ordering, "acquire") or
        std.mem.eql(u8, ordering, "seq_cst");
}

pub fn isAtomicStoreOrdering(ordering: []const u8) bool {
    return std.mem.eql(u8, ordering, "relaxed") or
        std.mem.eql(u8, ordering, "release") or
        std.mem.eql(u8, ordering, "seq_cst");
}

pub fn isAtomicIntegerPayload(name: []const u8) bool {
    return std.mem.eql(u8, name, "u8") or
        std.mem.eql(u8, name, "u16") or
        std.mem.eql(u8, name, "u32") or
        std.mem.eql(u8, name, "u64") or
        std.mem.eql(u8, name, "usize") or
        std.mem.eql(u8, name, "i8") or
        std.mem.eql(u8, name, "i16") or
        std.mem.eql(u8, name, "i32") or
        std.mem.eql(u8, name, "i64") or
        std.mem.eql(u8, name, "isize");
}

pub fn emitAtomicInitCall(ctx: EmitContext, call: anytype, locals: ?*std.StringHashMap(LocalInfo), payload_ty: ast.TypeExpr) !bool {
    if (call.type_args.len != 0 or call.args.len != 1) return false;
    try ctx.emit_expr_with_target(ctx.emit_ctx, call.args[0], locals, payload_ty);
    return true;
}

pub fn emitAtomicCall(ctx: EmitContext, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
    const member = memberCallee(call.callee.*) orelse return false;
    const kind = ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) orelse return false;
    const op = switch (kind) {
        .atomic_load => "load",
        .atomic_store => "store",
        .atomic_fetch_add => "fetch_add",
        .atomic_fetch_sub => "fetch_sub",
        else => return false,
    };
    const payload_ty = ctx.mir_target_type(ctx.emit_ctx, .atomic_payload, call.callee.*.span) orelse return error.UnsupportedCEmission;
    const payload = typeName(payload_ty) orelse return error.UnsupportedCEmission;
    if (std.mem.eql(u8, op, "load")) {
        const ordering = atomicOrderingArg(call.args, 0);
        if (!isAtomicLoadOrdering(ordering)) return false;
        const order_c = atomicOrderCConstant(ordering) orelse return false;
        try ctx.out.appendSlice(ctx.allocator, "__atomic_load_n(");
        try emitAtomicAddr(ctx, member.base.*, locals);
        try ctx.out.print(ctx.allocator, ", {s})", .{order_c});
        return true;
    }
    if (std.mem.eql(u8, op, "store")) {
        if (call.args.len < 1) return false;
        const ordering = atomicOrderingArg(call.args, 1);
        if (!isAtomicStoreOrdering(ordering)) return false;
        const order_c = atomicOrderCConstant(ordering) orelse return false;
        try ctx.out.appendSlice(ctx.allocator, "__atomic_store_n(");
        try emitAtomicAddr(ctx, member.base.*, locals);
        try ctx.out.appendSlice(ctx.allocator, ", ");
        try ctx.emit_expr(ctx.emit_ctx, call.args[0], locals);
        try ctx.out.print(ctx.allocator, ", {s})", .{order_c});
        return true;
    }
    if (std.mem.eql(u8, op, "fetch_add") or std.mem.eql(u8, op, "fetch_sub")) {
        if (call.args.len < 1) return false;
        if (!isAtomicIntegerPayload(payload)) return false;
        const ordering = atomicOrderingArg(call.args, 1);
        const order_c = atomicOrderCConstant(ordering) orelse return false;
        const builtin = if (std.mem.eql(u8, op, "fetch_sub")) "__atomic_fetch_sub(" else "__atomic_fetch_add(";
        try ctx.out.appendSlice(ctx.allocator, builtin);
        try emitAtomicAddr(ctx, member.base.*, locals);
        try ctx.out.appendSlice(ctx.allocator, ", ");
        try ctx.emit_expr(ctx.emit_ctx, call.args[0], locals);
        try ctx.out.print(ctx.allocator, ", {s})", .{order_c});
        return true;
    }
    return false;
}

pub fn atomicResultPayload(ctx: EmitContext, call: anytype) ?ast.TypeExpr {
    const kind = ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) orelse return null;
    const op = switch (kind) {
        .atomic_load => "load",
        .atomic_fetch_add => "fetch_add",
        .atomic_fetch_sub => "fetch_sub",
        else => return null,
    };
    if (!std.mem.eql(u8, op, "load") and
        !std.mem.eql(u8, op, "fetch_add") and
        !std.mem.eql(u8, op, "fetch_sub"))
    {
        return null;
    }

    const payload_ty = ctx.mir_target_type(ctx.emit_ctx, .atomic_payload, call.callee.*.span) orelse return null;
    if (!std.mem.eql(u8, op, "load") and !isAtomicIntegerPayload(typeName(payload_ty) orelse return null)) return null;
    return payload_ty;
}

fn emitAtomicAddr(ctx: EmitContext, base: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) !void {
    if (ctx.expr_is_pointer(ctx.emit_ctx, base, locals)) {
        try ctx.emit_expr(ctx.emit_ctx, base, locals);
    } else {
        try ctx.out.append(ctx.allocator, '&');
        try emitAtomicBaseAddr(ctx, base, locals);
    }
}

fn emitAtomicBaseAddr(ctx: EmitContext, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
    switch (expr.kind) {
        .ident => |ident| try ctx.out.appendSlice(ctx.allocator, ident.text),
        .grouped => |inner| try emitAtomicBaseAddr(ctx, inner.*, locals),
        .member => |m| {
            try emitAtomicBaseAddr(ctx, m.base.*, locals);
            try ctx.out.appendSlice(ctx.allocator, if (ctx.expr_is_pointer(ctx.emit_ctx, m.base.*, locals)) "->" else ".");
            try ctx.out.appendSlice(ctx.allocator, m.name.text);
        },
        else => return error.UnsupportedCEmission,
    }
}

pub fn fenceHelperForCall(callee: ast.Expr) ?[]const u8 {
    return switch (callee.kind) {
        .member => |node| blk: {
            if (!isIdentNamed(node.base.*, "fence")) break :blk null;
            if (std.mem.eql(u8, node.name.text, "full")) break :blk "mc_barrier_full";
            if (std.mem.eql(u8, node.name.text, "release")) break :blk "mc_barrier_release_before";
            if (std.mem.eql(u8, node.name.text, "acquire")) break :blk "mc_barrier_acquire_after";
            break :blk null;
        },
        .grouped => |inner| fenceHelperForCall(inner.*),
        else => null,
    };
}
