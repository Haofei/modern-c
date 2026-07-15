//! C backend dynamic-dispatch support artifacts.
//!
//! This module owns generated vtable instances. Expression lowering still owns
//! dynamic call emission and dyn value construction.

const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_shape = @import("lower_c_shape.zig");

const BindThunk = lower_c_model.BindThunk;
const FnInfo = lower_c_model.FnInfo;
const cTraitIsObjectSafe = lower_c_shape.cTraitIsObjectSafe;
const implMethodMangled = lower_c_shape.implMethodMangled;
const memberCallee = ast_query.memberCallee;

pub const CTypeFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8;
pub const DynTypeNameFn = *const fn (ctx: *anyopaque, trait_name: []const u8) anyerror![]const u8;
pub const EmitExprFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void;
pub const IsVoidTypeFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) bool;
pub const RequireDynDispatchArgumentFn = *const fn (ctx: *anyopaque, span: ast.Span, trait_name: []const u8, method_index: usize, argument_index: usize) anyerror!void;

const LocalInfo = lower_c_model.LocalInfo;

pub const Context = struct {
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    out: *std.ArrayList(u8),
    temp_index: *usize,
    emit_ctx: *anyopaque,
    c_type: CTypeFn,
    dyn_type_name: DynTypeNameFn,
    emit_expr: EmitExprFn,
    is_void_type: IsVoidTypeFn,
    require_dyn_dispatch_argument: RequireDynDispatchArgumentFn,
};

pub const BindEmitPlan = struct {
    fname: []const u8,
    info: FnInfo,
    ret_ty: ast.TypeExpr,
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

pub fn emitDynDispatch(ctx: Context, node: anytype, trait_name: []const u8, method_index: usize, locals: ?*std.StringHashMap(LocalInfo)) !void {
    const member = memberCallee(node.callee.*) orelse return error.UnsupportedCEmission;
    const temp_name = try std.fmt.allocPrint(ctx.scratch, "mc_tmp{d}", .{ctx.temp_index.*});
    ctx.temp_index.* += 1;
    try ctx.out.print(ctx.allocator, "({{ {s} {s} = ", .{ try ctx.dyn_type_name(ctx.emit_ctx, trait_name), temp_name });
    try ctx.emit_expr(ctx.emit_ctx, member.base.*, locals);
    try ctx.out.print(ctx.allocator, "; {s}.vtable->{s}({s}.data", .{ temp_name, member.name.text, temp_name });
    for (node.args, 0..) |arg, index| {
        try ctx.require_dyn_dispatch_argument(ctx.emit_ctx, arg.span, trait_name, method_index, index);
        try ctx.out.appendSlice(ctx.allocator, ", ");
        try ctx.emit_expr(ctx.emit_ctx, arg, locals);
    }
    try ctx.out.appendSlice(ctx.allocator, "); })");
}

pub fn emitClosureCall(ctx: Context, node: anytype, clos: ast.TypeExpr, locals: ?*std.StringHashMap(LocalInfo)) !void {
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

// One rodata vtable per `impl Trait for Type` of an object-safe trait:
//   static const VT_Trait __vt_Type_Trait = { &Type__m1, &Type__m2, ... };
// The function pointers are listed in trait-method order. Each is cast to the
// void*-self slot type (the thunk-free erasure is compiler-privileged: the
// concrete `*Type` self and the erased `void*` slot are ABI-identical).
pub fn emitVtables(
    ctx: Context,
    impl_methods: *std.StringHashMap([]const ast.ImplTraitMethod),
    trait_decls: *std.StringHashMap(ast.TraitDecl),
) !void {
    var it = impl_methods.iterator();
    while (it.next()) |entry| {
        try emitVtable(ctx, entry.key_ptr.*, entry.value_ptr.*, trait_decls);
    }
    try ctx.out.appendSlice(ctx.allocator, "\n");
}

fn emitVtable(
    ctx: Context,
    key: []const u8,
    methods: []const ast.ImplTraitMethod,
    trait_decls: *std.StringHashMap(ast.TraitDecl),
) !void {
    const sep = std.mem.indexOfScalar(u8, key, 0) orelse return;
    const trait_name = key[0..sep];
    const type_name = key[sep + 1 ..];
    const trait = trait_decls.get(trait_name) orelse return;
    if (!cTraitIsObjectSafe(trait)) return;
    try ctx.out.print(ctx.allocator, "static MC_UNUSED VT_{s} const __vt_{s}_{s} = {{ ", .{ trait_name, type_name, trait_name });
    try emitVtableSlots(ctx, trait, methods);
    try ctx.out.appendSlice(ctx.allocator, " };\n");
}

fn emitVtableSlots(ctx: Context, trait: ast.TraitDecl, methods: []const ast.ImplTraitMethod) !void {
    for (trait.methods, 0..) |method, i| {
        if (i != 0) try ctx.out.appendSlice(ctx.allocator, ", ");
        const mangled = implMethodMangled(methods, method.name.text) orelse return error.UnsupportedCEmission;
        try ctx.out.appendSlice(ctx.allocator, "(");
        try appendVtableSlotCastType(ctx, trait, method);
        try ctx.out.print(ctx.allocator, "){s}", .{mangled});
    }
}

// The cast type for a vtable slot: `RET (*)(void *, P...)`.
fn appendVtableSlotCastType(ctx: Context, trait: ast.TraitDecl, method: ast.TraitMethodSig) !void {
    const ret_ty: ast.TypeExpr = method.return_type orelse ast.TypeExpr{ .span = trait.name.span, .kind = .{ .name = .{ .text = "void", .span = trait.name.span } } };
    try ctx.out.appendSlice(ctx.allocator, try ctx.c_type(ctx.emit_ctx, ret_ty));
    try ctx.out.appendSlice(ctx.allocator, " (*)(void *");
    for (method.params[1..]) |param| {
        try ctx.out.appendSlice(ctx.allocator, ", ");
        try ctx.out.appendSlice(ctx.allocator, try ctx.c_type(ctx.emit_ctx, param.ty));
    }
    try ctx.out.appendSlice(ctx.allocator, ")");
}
