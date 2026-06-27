//! C backend serial/counter domain operation call emission.
//!
//! `serial<T>` and `counter<T>` lower to their unsigned inner integer
//! representation; this module owns the C spellings for their modular
//! differences and result-returning helpers.

const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const lower_c_alias = @import("lower_c_alias.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_type = @import("lower_c_type.zig");

const LocalInfo = lower_c_model.LocalInfo;
const memberCallee = ast_query.memberCallee;
const primitiveCTypeName = lower_c_type.primitiveCTypeName;
const signedCTypeForInner = lower_c_type.signedCTypeForInner;
const signedMinMacroForInner = lower_c_type.signedMinMacroForInner;
const simpleNameType = ast_query.simpleNameType;
const typeName = ast_query.typeName;

pub const EmitExprFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void;
pub const ResultTypeNameFn = *const fn (ctx: *anyopaque, ok_ty: ast.TypeExpr, err_ty: ast.TypeExpr) anyerror![]const u8;

pub const Context = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    type_aliases: *const std.StringHashMap(ast.TypeExpr),
    emit_ctx: *anyopaque,
    emit_expr: EmitExprFn,
    result_type_name: ResultTypeNameFn,
};

// Serial/counter domain operations. `serial<T>`/`counter<T>` lower to their
// unsigned inner integer, so the modular difference is plain wrapping
// subtraction; serial ordering reinterprets that difference as signed.
pub fn emitDomainOpCall(ctx: Context, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
    if (call.type_args.len != 0) return false;
    const member = memberCallee(call.callee.*) orelse return false;
    const op = member.name.text;
    const is_serial_op = std.mem.eql(u8, op, "before") or std.mem.eql(u8, op, "after") or
        std.mem.eql(u8, op, "distance") or std.mem.eql(u8, op, "compare");
    const is_counter_op = std.mem.eql(u8, op, "delta_mod") or
        std.mem.eql(u8, op, "elapsed_assume_within") or std.mem.eql(u8, op, "elapsed_bounded");
    if (!is_serial_op and !is_counter_op) return false;
    const ident = switch (member.base.kind) {
        .ident => |id| id,
        else => return false,
    };
    if (locals) |ls| {
        if (ls.contains(ident.text)) return false;
    }
    const resolved = lower_c_alias.resolveAliasType(ctx.type_aliases, simpleNameType(ident.text, ident.span));
    const node = switch (resolved.kind) {
        .generic => |n| n,
        else => return false,
    };
    const is_serial = std.mem.eql(u8, node.base.text, "serial");
    const is_counter = std.mem.eql(u8, node.base.text, "counter");
    if ((!is_serial and !is_counter) or node.args.len != 1) return false;
    if (is_serial_op and !is_serial) return false;
    if (is_counter_op and !is_counter) return false;
    if (call.args.len < 2) return error.UnsupportedCEmission;
    const inner_name = typeName(node.args[0]) orelse return error.UnsupportedCEmission;
    const unsigned_c = primitiveCTypeName(inner_name) orelse return error.UnsupportedCEmission;

    // serial.compare -> Result<Order, AmbiguousSerialOrder> (section 5.4).
    // Ambiguous exactly when the signed modular difference is the half-window
    // boundary (the wrapped INT_MIN), otherwise a three-way Order (-1/0/+1).
    if (std.mem.eql(u8, op, "compare")) {
        const signed_c = signedCTypeForInner(inner_name) orelse return error.UnsupportedCEmission;
        const min_macro = signedMinMacroForInner(inner_name) orelse return error.UnsupportedCEmission;
        const struct_name = try ctx.result_type_name(ctx.emit_ctx, simpleNameType("Order", member.name.span), simpleNameType("AmbiguousSerialOrder", member.name.span));
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
        if (call.args.len != 3) return error.UnsupportedCEmission;
        const duration_ty: ast.TypeExpr = .{ .span = member.name.span, .kind = .{ .generic = .{ .base = .{ .text = "Duration", .span = member.name.span }, .args = node.args } } };
        const struct_name = try ctx.result_type_name(ctx.emit_ctx, duration_ty, simpleNameType("AmbiguousCounterInterval", member.name.span));
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
