//! C backend scalar/domain conversion call emission.
//!
//! Keeps the checked conversion lowering out of the main emitter while leaving
//! backend-specific type inference and expression emission behind callbacks.

const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const lower_c_alias = @import("lower_c_alias.zig");
const lower_c_expr = @import("lower_c_expr.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_type = @import("lower_c_type.zig");

const LocalInfo = lower_c_model.LocalInfo;
const intTypeRange = lower_c_type.intTypeRange;
const isNumericStorageType = lower_c_type.isNumericStorageType;
const isBitcastCall = lower_c_expr.isBitcastCall;
const memberCallee = ast_query.memberCallee;
const primitiveCTypeName = lower_c_type.primitiveCTypeName;
const simpleNameType = ast_query.simpleNameType;
const typeName = ast_query.typeName;

pub const EmitExprFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void;
pub const ExprSourceTypeFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr;
pub const CTypeFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8;
pub const NumericExprTypeFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr;
pub const UnderlyingIntTypeNameFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) ?[]const u8;
pub const ResultTypeNameFn = *const fn (ctx: *anyopaque, ok_ty: ast.TypeExpr, err_ty: ast.TypeExpr) anyerror![]const u8;

pub const Context = struct {
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    out: *std.ArrayList(u8),
    temp_index: *usize,
    type_aliases: *const std.StringHashMap(ast.TypeExpr),
    emit_ctx: *anyopaque,
    emit_expr: EmitExprFn,
    c_type: CTypeFn,
    expr_source_type: ExprSourceTypeFn,
    numeric_expr_type: NumericExprTypeFn,
    underlying_int_type_name: UnderlyingIntTypeNameFn,
    result_type_name: ResultTypeNameFn,
};

pub fn emitConversionCall(ctx: Context, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
    if (call.type_args.len != 0) return false;
    const member = memberCallee(call.callee.*) orelse return false;
    const op = member.name.text;
    const is_cast = std.mem.eql(u8, op, "from") or std.mem.eql(u8, op, "wrap_from") or std.mem.eql(u8, op, "from_mod");
    const is_checked = std.mem.eql(u8, op, "trap_from") or std.mem.eql(u8, op, "sat_from") or std.mem.eql(u8, op, "try_from");
    if (!is_cast and !is_checked) return false;
    const ident = switch (member.base.kind) {
        .ident => |id| id,
        else => return false,
    };
    if (locals) |ls| {
        if (ls.contains(ident.text)) return false;
    }
    const resolved = lower_c_alias.resolveAliasType(ctx.type_aliases, simpleNameType(ident.text, ident.span));
    const target_name = typeName(resolved);
    const numeric_target = isNumericStorageType(resolved) or (target_name != null and primitiveCTypeName(target_name.?) != null);
    if (!numeric_target) return false;
    if (call.args.len != 1) return error.UnsupportedCEmission;
    const cty = try ctx.c_type(ctx.emit_ctx, resolved);

    if (is_checked) {
        const dst_name = ctx.underlying_int_type_name(ctx.emit_ctx, resolved) orelse return error.UnsupportedCEmission;
        const dst_range = intTypeRange(dst_name) orelse return error.UnsupportedCEmission;
        const src_ty = ctx.numeric_expr_type(ctx.emit_ctx, call.args[0], locals) orelse return error.UnsupportedCEmission;
        const src_name = ctx.underlying_int_type_name(ctx.emit_ctx, src_ty) orelse return error.UnsupportedCEmission;
        const src_range = intTypeRange(src_name) orelse return error.UnsupportedCEmission;
        const need_lower = src_range.min < dst_range.min;
        const need_upper = src_range.max > dst_range.max;

        if (!need_lower and !need_upper) {
            if (std.mem.eql(u8, op, "try_from")) {
                const struct_name = try ctx.result_type_name(ctx.emit_ctx, resolved, simpleNameType("ConversionError", member.name.span));
                try ctx.out.print(ctx.allocator, "(({s}){{ .is_ok = true, .payload.ok = ({s})(", .{ struct_name, cty });
                try ctx.emit_expr(ctx.emit_ctx, call.args[0], locals);
                try ctx.out.appendSlice(ctx.allocator, ") })");
            } else {
                try ctx.out.print(ctx.allocator, "(({s})(", .{cty});
                try ctx.emit_expr(ctx.emit_ctx, call.args[0], locals);
                try ctx.out.appendSlice(ctx.allocator, "))");
            }
            return true;
        }

        const src_cty = primitiveCTypeName(src_name) orelse return error.UnsupportedCEmission;
        const tmp = try std.fmt.allocPrint(ctx.scratch, "mc_tmp{d}", .{ctx.temp_index.*});
        ctx.temp_index.* += 1;
        try ctx.out.print(ctx.allocator, "({{ {s} {s} = (", .{ src_cty, tmp });
        try ctx.emit_expr(ctx.emit_ctx, call.args[0], locals);
        try ctx.out.appendSlice(ctx.allocator, "); ");

        if (std.mem.eql(u8, op, "try_from")) {
            const struct_name = try ctx.result_type_name(ctx.emit_ctx, resolved, simpleNameType("ConversionError", member.name.span));
            try ctx.out.appendSlice(ctx.allocator, "(");
            try emitConversionBoundTemp(ctx, tmp, dst_range, need_lower, need_upper);
            try ctx.out.print(ctx.allocator, " ? (({s}){{ .is_ok = false, .payload.err = 0 }}) : (({s}){{ .is_ok = true, .payload.ok = ({s})({s}) }}))", .{ struct_name, struct_name, cty, tmp });
        } else if (std.mem.eql(u8, op, "trap_from")) {
            try ctx.out.appendSlice(ctx.allocator, "(");
            try emitConversionBoundTemp(ctx, tmp, dst_range, need_lower, need_upper);
            try ctx.out.print(ctx.allocator, " ? (mc_trap_IntegerOverflow(), ({s})0) : ({s})({s}))", .{ cty, cty, tmp });
        } else {
            try ctx.out.print(ctx.allocator, "(({s})(", .{cty});
            if (need_lower) {
                try ctx.out.print(ctx.allocator, "(__int128)({s}) < (__int128)({s}) ? ({s}) : (", .{ tmp, dst_range.c_min, dst_range.c_min });
            }
            if (need_upper) {
                try ctx.out.print(ctx.allocator, "(__int128)({s}) > (__int128)({s}) ? ({s}) : (", .{ tmp, dst_range.c_max, dst_range.c_max });
            }
            try ctx.out.appendSlice(ctx.allocator, tmp);
            if (need_upper) try ctx.out.appendSlice(ctx.allocator, ")");
            if (need_lower) try ctx.out.appendSlice(ctx.allocator, ")");
            try ctx.out.appendSlice(ctx.allocator, "))");
        }
        try ctx.out.appendSlice(ctx.allocator, "; })");
        return true;
    }

    try ctx.out.print(ctx.allocator, "(({s})(", .{cty});
    try ctx.emit_expr(ctx.emit_ctx, call.args[0], locals);
    try ctx.out.appendSlice(ctx.allocator, "))");
    return true;
}

pub fn emitBitcastCall(ctx: Context, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
    if (!isBitcastCall(call) or call.type_args.len != 1 or call.args.len != 1) return false;
    const target_ty = lower_c_alias.resolveAliasType(ctx.type_aliases, call.type_args[0]);
    const source_ty = ctx.expr_source_type(ctx.emit_ctx, call.args[0], locals) orelse return error.UnsupportedCEmission;
    const source_name = try std.fmt.allocPrint(ctx.scratch, "mc_bc_src{d}", .{ctx.temp_index.*});
    ctx.temp_index.* += 1;
    const target_name = try std.fmt.allocPrint(ctx.scratch, "mc_bc_dst{d}", .{ctx.temp_index.*});
    ctx.temp_index.* += 1;

    try ctx.out.appendSlice(ctx.allocator, "({ ");
    try ctx.out.print(ctx.allocator, "{s} {s} = ", .{ try ctx.c_type(ctx.emit_ctx, source_ty), source_name });
    try ctx.emit_expr(ctx.emit_ctx, call.args[0], locals);
    try ctx.out.appendSlice(ctx.allocator, "; ");
    try ctx.out.print(ctx.allocator, "{s} {s}; ", .{ try ctx.c_type(ctx.emit_ctx, target_ty), target_name });
    try ctx.out.print(ctx.allocator, "__builtin_memcpy(&{s}, &{s}, sizeof({s})); {s}; }})", .{ target_name, source_name, target_name, target_name });
    return true;
}

fn emitConversionBoundTemp(ctx: Context, tmp: []const u8, range: lower_c_type.IntTypeRange, need_lower: bool, need_upper: bool) !void {
    if (need_lower) {
        try ctx.out.print(ctx.allocator, "(__int128)({s}) < (__int128)({s})", .{ tmp, range.c_min });
    }
    if (need_lower and need_upper) try ctx.out.appendSlice(ctx.allocator, " || ");
    if (need_upper) {
        try ctx.out.print(ctx.allocator, "(__int128)({s}) > (__int128)({s})", .{ tmp, range.c_max });
    }
}
