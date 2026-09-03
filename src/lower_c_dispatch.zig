//! C backend closure-dispatch helpers.

const std = @import("std");

const ast_bridge = @import("ast_bridge.zig");
const lower_c_model = @import("lower_c_model.zig");

const BindThunk = lower_c_model.BindThunk;
const FnInfo = lower_c_model.FnInfo;

pub const CTypeFn = *const fn (ctx: *anyopaque, ty: ast_bridge.TypeExpr) anyerror![]const u8;
pub const EmitExprFn = *const fn (ctx: *anyopaque, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void;
pub const IsVoidTypeFn = *const fn (ctx: *anyopaque, ty: ast_bridge.TypeExpr) bool;

const LocalInfo = lower_c_model.LocalInfo;

pub const Context = struct {
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    out: *std.ArrayList(u8),
    temp_index: *usize,
    emit_ctx: *anyopaque,
    c_type: CTypeFn,
    emit_expr: EmitExprFn,
    is_void_type: IsVoidTypeFn,
};

pub const BindEmitPlan = struct {
    fname: []const u8,
    info: FnInfo,
    ret_ty: ast_bridge.TypeExpr,
    cname: []const u8,
};

// Emit each collected scalar-env thunk: `static RET mc_envthunk_f(void *env, P...){
// return f((T)(uintptr_t)env, P...); }`. The first param is genuinely `void *`,
// matching the closure's code-pointer signature exactly.
pub fn emitBindThunks(ctx: Context, bind_thunks: *std.StringHashMap(BindThunk)) !void {
    var it = bind_thunks.iterator();
    while (it.next()) |entry| {
        try emitBindThunk(ctx, entry.key_ptr.*, entry.value_ptr.*);
    }
}

fn emitBindThunk(ctx: Context, thunk_name: []const u8, thunk: BindThunk) !void {
    const info = thunk.info;
    const returns_void = if (info.return_type) |rt| ctx.is_void_type(ctx.emit_ctx, rt) else true;
    try emitBindThunkSignature(ctx, thunk_name, info);
    try emitBindThunkBody(ctx, thunk.fname, info, returns_void);
}

fn emitBindThunkSignature(ctx: Context, thunk_name: []const u8, info: FnInfo) !void {
    try ctx.out.appendSlice(ctx.allocator, "static MC_UNUSED ");
    if (info.return_type) |rt| {
        try ctx.out.appendSlice(ctx.allocator, try ctx.c_type(ctx.emit_ctx, rt));
    } else {
        try ctx.out.appendSlice(ctx.allocator, "void");
    }
    try ctx.out.print(ctx.allocator, " {s}(void *mc_env", .{thunk_name});
    for (info.params[1..], 0..) |param, i| {
        try ctx.out.print(ctx.allocator, ", {s} mc_a{d}", .{ try ctx.c_type(ctx.emit_ctx, param.ty), i });
    }
    try ctx.out.appendSlice(ctx.allocator, ") {\n    ");
}

fn emitBindThunkBody(ctx: Context, fn_name: []const u8, info: FnInfo, returns_void: bool) !void {
    if (!returns_void) try ctx.out.appendSlice(ctx.allocator, "return ");
    try ctx.out.print(ctx.allocator, "{s}((", .{fn_name});
    try ctx.out.appendSlice(ctx.allocator, try ctx.c_type(ctx.emit_ctx, info.params[0].ty));
    try ctx.out.appendSlice(ctx.allocator, ")(uintptr_t)mc_env");
    for (info.params[1..], 0..) |_, i| {
        try ctx.out.print(ctx.allocator, ", mc_a{d}", .{i});
    }
    try ctx.out.appendSlice(ctx.allocator, ");\n}\n\n");
}

pub fn emitScalarEnvBind(ctx: Context, node: anytype, locals: ?*std.StringHashMap(LocalInfo), plan: BindEmitPlan) !void {
    const thunk = try std.fmt.allocPrint(ctx.scratch, "mc_envthunk_{s}", .{plan.fname});
    try ctx.out.print(ctx.allocator, "({s}){{ .code = {s}, .env = (void *)(uintptr_t)(", .{ plan.cname, thunk });
    try ctx.emit_expr(ctx.emit_ctx, node.args[0], locals);
    try ctx.out.appendSlice(ctx.allocator, ") }");
}

pub fn emitPointerEnvBind(ctx: Context, node: anytype, locals: ?*std.StringHashMap(LocalInfo), plan: BindEmitPlan) !void {
    try ctx.out.print(ctx.allocator, "({s}){{ .code = (", .{plan.cname});
    try ctx.out.appendSlice(ctx.allocator, try ctx.c_type(ctx.emit_ctx, plan.ret_ty));
    try ctx.out.appendSlice(ctx.allocator, " (*)(void *");
    for (plan.info.params[1..]) |param| {
        try ctx.out.appendSlice(ctx.allocator, ", ");
        try ctx.out.appendSlice(ctx.allocator, try ctx.c_type(ctx.emit_ctx, param.ty));
    }
    try ctx.out.print(ctx.allocator, ")){s}, .env = (void *)(", .{plan.fname});
    try ctx.emit_expr(ctx.emit_ctx, node.args[0], locals);
    try ctx.out.appendSlice(ctx.allocator, ") }");
}

pub fn emitClosureCall(ctx: Context, node: anytype, clos: ast_bridge.TypeExpr, locals: ?*std.StringHashMap(LocalInfo)) !void {
    const temp_name = try std.fmt.allocPrint(ctx.scratch, "mc_tmp{d}", .{ctx.temp_index.*});
    ctx.temp_index.* += 1;
    try ctx.out.print(ctx.allocator, "({{ {s} {s} = ", .{ try ctx.c_type(ctx.emit_ctx, clos), temp_name });
    try ctx.emit_expr(ctx.emit_ctx, node.callee.*, locals);
    try ctx.out.print(ctx.allocator, "; {s}.code({s}.env", .{ temp_name, temp_name });
    for (node.args) |arg| {
        try ctx.out.appendSlice(ctx.allocator, ", ");
        try ctx.emit_expr(ctx.emit_ctx, arg, locals);
    }
    try ctx.out.appendSlice(ctx.allocator, "); })");
}
