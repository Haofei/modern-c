//! C backend serial/counter domain operation call emission.
//!
//! `serial<T>` and `counter<T>` lower to their unsigned inner integer
//! representation; this module owns the C spellings for their modular
//! differences and result-returning helpers.

const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_type = @import("lower_c_type.zig");
const mir = @import("mir.zig");

const LocalInfo = lower_c_model.LocalInfo;
const memberCallee = ast_query.memberCallee;
const signedCTypeForInner = lower_c_type.signedCTypeForInner;
const signedMinMacroForInner = lower_c_type.signedMinMacroForInner;

pub const EmitExprFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void;
pub const CTypeFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8;
pub const UnderlyingIntTypeNameFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) ?[]const u8;
pub const MirCallTargetKindFn = *const fn (ctx: *anyopaque, span: ast.Span) ?mir.CallTargetKind;
pub const MirTargetTypeFn = *const fn (ctx: *anyopaque, kind: mir.TargetTypeKind, span: ast.Span) ?ast.TypeExpr;

pub const Context = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    emit_ctx: *anyopaque,
    emit_expr: EmitExprFn,
    c_type: CTypeFn,
    underlying_int_type_name: UnderlyingIntTypeNameFn,
    mir_call_target_kind: MirCallTargetKindFn,
    mir_target_type: MirTargetTypeFn,
};

// Serial/counter domain operations. `serial<T>`/`counter<T>` lower to their
// unsigned inner integer, so the modular difference is plain wrapping
// subtraction; serial ordering reinterprets that difference as signed.
pub fn emitDomainOpCall(ctx: Context, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
    if (call.type_args.len != 0) return false;
    const member = memberCallee(call.callee.*) orelse return false;
    const kind = ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) orelse return false;
    const fact_info = mir.domainCallFactInfo(kind) orelse return false;
    if (kind == .wrap_residue or !std.mem.eql(u8, member.name.text, fact_info.op)) return false;
    const expected_args: usize = if (fact_info.has_interval) 3 else 2;
    if (call.args.len != expected_args) return error.UnsupportedCEmission;
    _ = ctx.mir_target_type(ctx.emit_ctx, .domain_type, call.callee.*.span) orelse return error.UnsupportedCEmission;
    const payload_ty = ctx.mir_target_type(ctx.emit_ctx, .domain_payload, call.callee.*.span) orelse return error.UnsupportedCEmission;
    const result_ty = ctx.mir_target_type(ctx.emit_ctx, .domain_result, call.callee.*.span) orelse return error.UnsupportedCEmission;
    if (fact_info.has_interval) _ = ctx.mir_target_type(ctx.emit_ctx, .domain_interval, call.callee.*.span) orelse return error.UnsupportedCEmission;
    const inner_name = ctx.underlying_int_type_name(ctx.emit_ctx, payload_ty) orelse return error.UnsupportedCEmission;
    const unsigned_c = try ctx.c_type(ctx.emit_ctx, payload_ty);
    const op = fact_info.op;

    // serial.compare -> Result<Order, AmbiguousSerialOrder> (section 5.4).
    // Ambiguous exactly when the signed modular difference is the half-window
    // boundary (the wrapped INT_MIN), otherwise a three-way Order (-1/0/+1).
    if (std.mem.eql(u8, op, "compare")) {
        const signed_c = signedCTypeForInner(inner_name) orelse return error.UnsupportedCEmission;
        const min_macro = signedMinMacroForInner(inner_name) orelse return error.UnsupportedCEmission;
        const struct_name = try ctx.c_type(ctx.emit_ctx, result_ty);
        try ctx.out.appendSlice(ctx.allocator, "(");
        try emitSignedSerialDiff(ctx, call.args[0], call.args[1], locals, signed_c, unsigned_c);
        try ctx.out.print(ctx.allocator, " == {s} ? (({s}){{ .is_ok = false, .payload.err = 0 }}) : (({s}){{ .is_ok = true, .payload.ok = (", .{ min_macro, struct_name, struct_name });
        try emitSignedSerialDiff(ctx, call.args[0], call.args[1], locals, signed_c, unsigned_c);
        try ctx.out.appendSlice(ctx.allocator, " < 0 ? -1 : (");
        try emitSignedSerialDiff(ctx, call.args[0], call.args[1], locals, signed_c, unsigned_c);
        try ctx.out.appendSlice(ctx.allocator, " > 0 ? 1 : 0)) }))");
        return true;
    }

    // counter.elapsed_bounded -> Result<Duration<T>, AmbiguousCounterInterval>
    // (section 5.5). Ok when the modular delta does not exceed the supplied
    // maximum interval, otherwise the interval is ambiguous.
    if (std.mem.eql(u8, op, "elapsed_bounded")) {
        const struct_name = try ctx.c_type(ctx.emit_ctx, result_ty);
        try ctx.out.print(ctx.allocator, "((({s})(", .{unsigned_c});
        try ctx.emit_expr(ctx.emit_ctx, call.args[0], locals);
        try ctx.out.appendSlice(ctx.allocator, " - ");
        try ctx.emit_expr(ctx.emit_ctx, call.args[1], locals);
        try ctx.out.appendSlice(ctx.allocator, ")) <= (");
        try ctx.emit_expr(ctx.emit_ctx, call.args[2], locals);
        try ctx.out.print(ctx.allocator, ") ? (({s}){{ .is_ok = true, .payload.ok = ({s})(", .{ struct_name, unsigned_c });
        try ctx.emit_expr(ctx.emit_ctx, call.args[0], locals);
        try ctx.out.appendSlice(ctx.allocator, " - ");
        try ctx.emit_expr(ctx.emit_ctx, call.args[1], locals);
        try ctx.out.print(ctx.allocator, ") }}) : (({s}){{ .is_ok = false, .payload.err = 0 }}))", .{struct_name});
        return true;
    }

    // `elapsed_assume_within` is a pure modular delta at runtime: the temporal
    // assumption grants the optimizer no extra license (section 5.5).
    if (std.mem.eql(u8, op, "distance") or std.mem.eql(u8, op, "delta_mod") or std.mem.eql(u8, op, "elapsed_assume_within")) {
        try ctx.out.print(ctx.allocator, "(({s})(", .{unsigned_c});
        try ctx.emit_expr(ctx.emit_ctx, call.args[0], locals);
        try ctx.out.appendSlice(ctx.allocator, " - ");
        try ctx.emit_expr(ctx.emit_ctx, call.args[1], locals);
        try ctx.out.appendSlice(ctx.allocator, "))");
        return true;
    }

    const signed_c = signedCTypeForInner(inner_name) orelse return error.UnsupportedCEmission;
    const cmp: []const u8 = if (std.mem.eql(u8, op, "before")) "<" else ">";
    try ctx.out.print(ctx.allocator, "(({s})(({s})(", .{ signed_c, unsigned_c });
    try ctx.emit_expr(ctx.emit_ctx, call.args[0], locals);
    try ctx.out.appendSlice(ctx.allocator, " - ");
    try ctx.emit_expr(ctx.emit_ctx, call.args[1], locals);
    try ctx.out.print(ctx.allocator, ")) {s} 0)", .{cmp});
    return true;
}

fn emitSignedSerialDiff(ctx: Context, a: ast.Expr, b: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), signed_c: []const u8, unsigned_c: []const u8) !void {
    try ctx.out.print(ctx.allocator, "({s})({s})(", .{ signed_c, unsigned_c });
    try ctx.emit_expr(ctx.emit_ctx, a, locals);
    try ctx.out.appendSlice(ctx.allocator, " - ");
    try ctx.emit_expr(ctx.emit_ctx, b, locals);
    try ctx.out.appendSlice(ctx.allocator, ")");
}
