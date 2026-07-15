//! C backend leaf call emitters.
//!
//! These helpers cover small built-in call forms that only need C expression
//! emission and type spelling callbacks. Larger calls with backend state stay
//! in `lower_c_emitter.zig`.

const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const lower_c_alias = @import("lower_c_alias.zig");
const lower_c_expr = @import("lower_c_expr.zig");
const lower_c_global = @import("lower_c_global.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_type = @import("lower_c_type.zig");
const mir = @import("mir.zig");

const calleeIdentName = ast_query.calleeIdentName;
const callExpr = ast_query.callExpr;
const rawScalarSuffix = lower_c_type.rawScalarSuffix;
const isNonNullPointerType = lower_c_type.isNonNullPointerType;
const isPAddrType = lower_c_type.isPAddrType;
const isPointerLikeAddressType = lower_c_type.isPointerLikeAddressType;
const isVaListType = lower_c_type.isVaListType;
const isVoidType = lower_c_type.isVoidType;
const uncheckedNoOverflowOperator = lower_c_expr.uncheckedNoOverflowOperator;
const typeName = ast_query.typeName;
const LocalInfo = lower_c_model.LocalInfo;
const FnInfo = lower_c_model.FnInfo;
const GlobalAccess = lower_c_model.GlobalAccess;
const SequencedArgTemp = lower_c_model.SequencedArgTemp;

pub const EmitExprFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void;
pub const EmitExprWithTargetFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) anyerror!void;
pub const ExprSourceTypeFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr;
pub const EmitSequencedArgTempFn = *const fn (ctx: *anyopaque, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!SequencedArgTemp;
pub const EmitOptionalSequencedArgTempFn = *const fn (ctx: *anyopaque, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp;
pub const CTypeFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8;
pub const EmitDeclaratorFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr, name: []const u8) anyerror!void;
pub const CIdentFn = *const fn (ctx: *anyopaque, name: []const u8) anyerror![]const u8;
pub const LocalInfoFromTypeFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) anyerror!LocalInfo;
pub const GlobalAssignmentTargetFn = *const fn (ctx: *anyopaque, target: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?GlobalAccess;
pub const EmitAssignTargetFn = *const fn (ctx: *anyopaque, target: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void;
pub const MirCallTargetKindFn = *const fn (ctx: *anyopaque, span: ast.Span) ?mir.CallTargetKind;
pub const MirTargetTypeFn = *const fn (ctx: *anyopaque, kind: mir.TargetTypeKind, span: ast.Span) ?ast.TypeExpr;
pub const MirOwnedTargetTypeFn = *const fn (ctx: *anyopaque, kind: mir.TargetTypeKind, span: ast.Span, target_owner: []const u8, target_index: ?usize) ?ast.TypeExpr;

pub const Context = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    emit_ctx: *anyopaque,
    emit_expr: EmitExprFn,
    emit_expr_with_target: EmitExprWithTargetFn,
    c_type: CTypeFn,
    mir_call_target_kind: MirCallTargetKindFn,
    mir_target_type: MirTargetTypeFn,
};

const UncheckedCallInfo = struct {
    op: []const u8,
    left_ty: ast.TypeExpr,
    right_ty: ast.TypeExpr,
};

fn uncheckedCallInfo(ctx: Context, call: anytype) ?UncheckedCallInfo {
    if (call.type_args.len != 0 or call.args.len != 2) return null;
    const kind = ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) orelse return null;
    const op = mir.uncheckedCallFactInfo(kind) orelse return null;
    const left_ty = ctx.mir_target_type(ctx.emit_ctx, .unchecked_left, call.args[0].span) orelse return null;
    const right_ty = ctx.mir_target_type(ctx.emit_ctx, .unchecked_right, call.args[1].span) orelse return null;
    _ = ctx.mir_target_type(ctx.emit_ctx, .unchecked_result, call.callee.*.span) orelse return null;
    return .{ .op = op, .left_ty = left_ty, .right_ty = right_ty };
}

pub const TempContext = struct {
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: *usize,
    temp_index: *usize,
    type_aliases: *const std.StringHashMap(ast.TypeExpr),
    emit_ctx: *anyopaque,
    emit_expr: EmitExprFn,
    emit_expr_with_target: EmitExprWithTargetFn,
    emit_arg_temp: EmitSequencedArgTempFn,
    c_type: CTypeFn,
    c_ident: CIdentFn,
    expr_source_type: ExprSourceTypeFn,
    local_info_from_type: LocalInfoFromTypeFn,
    global_assignment_target: GlobalAssignmentTargetFn,
    emit_assign_target: EmitAssignTargetFn,
    mir_call_target_kind: MirCallTargetKindFn,
    mir_target_type: MirTargetTypeFn,
    mir_owned_target_type: MirOwnedTargetTypeFn,
};

pub const LocalInitContext = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: *usize,
    current_variadic_last: ?[]const u8,
    emit_ctx: *anyopaque,
    emit_declarator: EmitDeclaratorFn,
    c_ident: CIdentFn,
    mir_call_target_kind: MirCallTargetKindFn,
    mir_target_type: MirTargetTypeFn,
};

pub const SpecialTempContext = struct {
    emit_ctx: *anyopaque,
    address: EmitOptionalSequencedArgTempFn,
    index: EmitOptionalSequencedArgTempFn,
    binary: EmitOptionalSequencedArgTempFn,
    deref: EmitOptionalSequencedArgTempFn,
    aggregate: EmitOptionalSequencedArgTempFn,
    cast: EmitOptionalSequencedArgTempFn,
    call: EmitOptionalSequencedArgTempFn,
};

pub fn collectSequencedArgTemps(
    ctx: TempContext,
    call: anytype,
    locals: *std.StringHashMap(LocalInfo),
    fn_info: FnInfo,
) anyerror!std.ArrayList(SequencedArgTemp) {
    var temps: std.ArrayList(SequencedArgTemp) = .empty;
    errdefer temps.deinit(ctx.scratch);

    const target_owner = calleeIdentName(call.callee.*) orelse return error.UnsupportedCEmission;
    for (call.args, 0..) |arg, i| {
        if (i >= fn_info.params.len) return error.UnsupportedCEmission;
        const target_ty = ctx.mir_owned_target_type(ctx.emit_ctx, .direct_call_argument, arg.span, target_owner, i) orelse return error.UnsupportedCEmission;
        if (!std.meta.eql(target_ty, fn_info.params[i].ty)) return error.UnsupportedCEmission;
        try temps.append(ctx.scratch, try ctx.emit_arg_temp(ctx.emit_ctx, arg, locals, target_ty));
    }

    return temps;
}

pub fn emitSequencedArgList(allocator: std.mem.Allocator, out: *std.ArrayList(u8), temps: []const SequencedArgTemp) !void {
    try out.appendSlice(allocator, "(");
    for (temps, 0..) |temp, i| {
        if (i != 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, temp.name);
    }
    try out.appendSlice(allocator, ")");
}

pub fn emitSequencedCallLocalInit(ctx: TempContext, functions: *const std.StringHashMap(FnInfo), name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const call = callExpr(initializer) orelse return false;
    if (call.args.len == 0) return false;

    const fn_info = sequencedCallFnInfo(functions, call) orelse return false;
    if (fn_info.params.len < call.args.len) return false;

    var temps = try collectSequencedArgTemps(ctx, call, locals, fn_info);
    defer temps.deinit(ctx.scratch);

    try emitSequencedCallLocalValue(ctx, name, decl_ty, call, locals, temps.items, true);
    return true;
}

pub fn emitSequencedCallExprStmt(ctx: TempContext, functions: *const std.StringHashMap(FnInfo), expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const call = callExpr(expr) orelse return false;
    if (call.args.len == 0) return false;

    const fn_info = sequencedCallFnInfo(functions, call) orelse return false;
    if (fn_info.params.len < call.args.len) return false;

    var temps = try collectSequencedArgTemps(ctx, call, locals, fn_info);
    defer temps.deinit(ctx.scratch);

    try emitSequencedCallExprStmtValue(ctx, call, locals, temps.items);
    return true;
}

pub fn emitSequencedCallReturn(ctx: TempContext, functions: *const std.StringHashMap(FnInfo), expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const call = callExpr(expr) orelse return false;
    if (call.args.len == 0) return false;

    const fn_info = sequencedCallFnInfo(functions, call) orelse return false;
    if (fn_info.params.len < call.args.len) return false;

    var temps = try collectSequencedArgTemps(ctx, call, locals, fn_info);
    defer temps.deinit(ctx.scratch);

    try emitSequencedCallReturnValue(ctx, call, locals, temps.items);
    return true;
}

pub fn emitSequencedCallAssignmentResultTemp(ctx: TempContext, functions: *const std.StringHashMap(FnInfo), value: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !?[]const u8 {
    const call = callExpr(value) orelse return null;
    if (call.args.len == 0) return null;

    const fn_info = sequencedCallFnInfo(functions, call) orelse return null;
    const target_owner = calleeIdentName(call.callee.*) orelse return error.UnsupportedCEmission;
    const return_ty = ctx.mir_owned_target_type(ctx.emit_ctx, .direct_call_result, call.callee.*.span, target_owner, null) orelse return error.UnsupportedCEmission;
    if (fn_info.return_type == null or !std.meta.eql(return_ty, fn_info.return_type.?)) return error.UnsupportedCEmission;
    if (isVoidType(return_ty) or fn_info.params.len < call.args.len) return null;

    var temps = try collectSequencedArgTemps(ctx, call, locals, fn_info);
    defer temps.deinit(ctx.scratch);

    return try emitSequencedCallResultTemp(ctx, call, return_ty, locals, temps.items);
}

pub fn emitSequencedCallAssignmentStmt(ctx: TempContext, functions: *const std.StringHashMap(FnInfo), assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
    const result_temp = (try emitSequencedCallAssignmentResultTemp(ctx, functions, assignment.value, locals)) orelse return false;

    try writeIndent(ctx);
    if (ctx.global_assignment_target(ctx.emit_ctx, assignment.target, locals)) |target| {
        try lower_c_global.appendGlobalStoreValue(ctx.allocator, ctx.out, target, result_temp);
    } else {
        try ctx.emit_assign_target(ctx.emit_ctx, assignment.target, locals);
        try ctx.out.print(ctx.allocator, " = {s};\n", .{result_temp});
    }
    return true;
}

pub fn emitBitcastValueTemp(ctx: TempContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!?SequencedArgTemp {
    const call = callExpr(expr) orelse return null;
    return try emitBitcastValueTempFromCall(ctx, call, locals);
}

pub fn emitBitcastValueTempFromCall(ctx: TempContext, call: anytype, locals: *std.StringHashMap(LocalInfo)) anyerror!?SequencedArgTemp {
    const target = bitcastTargetType(ctx, call) orelse return null;
    const target_ty = lower_c_alias.resolveAliasType(ctx.type_aliases, target);
    const source_ty = ctx.mir_target_type(ctx.emit_ctx, .bitcast_source, call.callee.*.span) orelse return error.UnsupportedCEmission;
    const source_temp = try ctx.emit_arg_temp(ctx.emit_ctx, call.args[0], locals, source_ty);
    const result_temp = try std.fmt.allocPrint(ctx.scratch, "mc_tmp{d}", .{ctx.temp_index.*});
    ctx.temp_index.* += 1;

    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s};\n", .{ try ctx.c_type(ctx.emit_ctx, target_ty), result_temp });
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "__builtin_memcpy(&{s}, &{s}, sizeof({s}));\n", .{ result_temp, source_temp.name, result_temp });
    return .{ .name = result_temp, .ty = target_ty };
}

pub fn emitBitcastLocalInit(ctx: TempContext, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const call = callExpr(initializer) orelse return false;
    if (bitcastTargetType(ctx, call) == null) return false;
    const source_ty = ctx.mir_target_type(ctx.emit_ctx, .bitcast_source, call.callee.*.span) orelse return error.UnsupportedCEmission;
    const source_temp = try ctx.emit_arg_temp(ctx.emit_ctx, call.args[0], locals, source_ty);

    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s};\n", .{ try ctx.c_type(ctx.emit_ctx, decl_ty), try ctx.c_ident(ctx.emit_ctx, name) });
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "__builtin_memcpy(&{s}, &{s}, sizeof({s}));\n", .{ name, source_temp.name, name });
    return true;
}

pub fn emitBitcastInferredLocalInit(ctx: TempContext, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const call = callExpr(initializer) orelse return false;
    const target_ty = bitcastTargetType(ctx, call) orelse return false;
    const inferred_ty = ctx.mir_owned_target_type(ctx.emit_ctx, .inferred_local, initializer.span, name, null) orelse return error.UnsupportedCEmission;
    if (!std.meta.eql(inferred_ty, target_ty)) return error.UnsupportedCEmission;
    try locals.put(name, try ctx.local_info_from_type(ctx.emit_ctx, inferred_ty));
    return try emitBitcastLocalInit(ctx, name, inferred_ty, initializer, locals);
}

fn bitcastTargetType(ctx: TempContext, call: anytype) ?ast.TypeExpr {
    if (ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) != .bitcast) return null;
    if (call.type_args.len != 1 or call.args.len != 1) return null;
    return ctx.mir_target_type(ctx.emit_ctx, .bitcast_target, call.callee.*.span);
}

pub fn emitBitcastReturn(ctx: TempContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
    _ = return_ty;
    const temp = (try emitBitcastValueTemp(ctx, expr, locals)) orelse return false;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "return {s};\n", .{temp.name});
    return true;
}

pub fn emitBitcastAssignmentStmt(ctx: TempContext, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
    const temp = (try emitBitcastValueTemp(ctx, assignment.value, locals)) orelse return false;
    try writeIndent(ctx);
    if (ctx.global_assignment_target(ctx.emit_ctx, assignment.target, locals)) |target| {
        try lower_c_global.appendGlobalStoreValue(ctx.allocator, ctx.out, target, temp.name);
    } else {
        try ctx.emit_assign_target(ctx.emit_ctx, assignment.target, locals);
        try ctx.out.print(ctx.allocator, " = {s};\n", .{temp.name});
    }
    return true;
}

pub fn externNonNullReturnInfo(functions: *const std.StringHashMap(FnInfo), call: anytype) ?FnInfo {
    const callee_name = calleeIdentName(call.callee.*) orelse return null;
    const fn_info = functions.get(callee_name) orelse return null;
    const return_ty = fn_info.return_type orelse return null;
    if (!fn_info.is_extern or !isNonNullPointerType(return_ty) or fn_info.params.len < call.args.len) return null;
    return fn_info;
}

pub fn emitExternNonNullCallValueTemp(ctx: TempContext, functions: *const std.StringHashMap(FnInfo), expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!?SequencedArgTemp {
    const call = callExpr(expr) orelse return null;
    const fn_info = externNonNullReturnInfo(functions, call) orelse return null;
    const target_owner = calleeIdentName(call.callee.*) orelse return error.UnsupportedCEmission;
    const return_ty = ctx.mir_owned_target_type(ctx.emit_ctx, .direct_call_result, call.callee.*.span, target_owner, null) orelse return error.UnsupportedCEmission;
    if (!std.meta.eql(return_ty, fn_info.return_type.?)) return error.UnsupportedCEmission;

    var temps = try collectSequencedArgTemps(ctx, call, locals, fn_info);
    defer temps.deinit(ctx.scratch);

    const temp_name = try std.fmt.allocPrint(ctx.scratch, "mc_tmp{d}", .{ctx.temp_index.*});
    ctx.temp_index.* += 1;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = ", .{ try ctx.c_type(ctx.emit_ctx, return_ty), temp_name });
    try ctx.emit_expr(ctx.emit_ctx, call.callee.*, locals);
    try emitSequencedArgList(ctx.allocator, ctx.out, temps.items);
    try ctx.out.appendSlice(ctx.allocator, ";\n");
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "if ({s} == NULL) mc_trap_InvalidRepresentation();\n", .{temp_name});
    return .{ .name = temp_name, .ty = return_ty };
}

pub fn emitExternNonNullCallLocalInit(ctx: TempContext, functions: *const std.StringHashMap(FnInfo), name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const temp = (try emitExternNonNullCallValueTemp(ctx, functions, initializer, locals)) orelse return false;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = {s};\n", .{ try ctx.c_type(ctx.emit_ctx, decl_ty), try ctx.c_ident(ctx.emit_ctx, name), temp.name });
    return true;
}

pub fn emitExternNonNullCallInferredLocalInit(ctx: TempContext, functions: *const std.StringHashMap(FnInfo), name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const temp = (try emitExternNonNullCallValueTemp(ctx, functions, initializer, locals)) orelse return false;
    try locals.put(name, try ctx.local_info_from_type(ctx.emit_ctx, temp.ty));
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = {s};\n", .{ try ctx.c_type(ctx.emit_ctx, temp.ty), try ctx.c_ident(ctx.emit_ctx, name), temp.name });
    return true;
}

pub fn emitExternNonNullCallReturn(ctx: TempContext, functions: *const std.StringHashMap(FnInfo), expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const temp = (try emitExternNonNullCallValueTemp(ctx, functions, expr, locals)) orelse return false;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "return {s};\n", .{temp.name});
    return true;
}

pub fn emitExternNonNullCallAssignmentStmt(ctx: TempContext, functions: *const std.StringHashMap(FnInfo), assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
    const temp = (try emitExternNonNullCallValueTemp(ctx, functions, assignment.value, locals)) orelse return false;
    try writeIndent(ctx);
    if (ctx.global_assignment_target(ctx.emit_ctx, assignment.target, locals)) |target| {
        try lower_c_global.appendGlobalStoreValue(ctx.allocator, ctx.out, target, temp.name);
    } else {
        try ctx.emit_assign_target(ctx.emit_ctx, assignment.target, locals);
        try ctx.out.print(ctx.allocator, " = {s};\n", .{temp.name});
    }
    return true;
}

pub fn emitSequencedCallReturnValue(ctx: TempContext, call: anytype, locals: *std.StringHashMap(LocalInfo), temps: []const SequencedArgTemp) !void {
    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "return ");
    try ctx.emit_expr(ctx.emit_ctx, call.callee.*, locals);
    try emitSequencedArgList(ctx.allocator, ctx.out, temps);
    try ctx.out.appendSlice(ctx.allocator, ";\n");
}

pub fn emitSequencedCallResultTemp(ctx: TempContext, call: anytype, return_ty: ast.TypeExpr, locals: *std.StringHashMap(LocalInfo), temps: []const SequencedArgTemp) ![]const u8 {
    const result_temp = try std.fmt.allocPrint(ctx.scratch, "mc_tmp{d}", .{ctx.temp_index.*});
    ctx.temp_index.* += 1;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = ", .{ try ctx.c_type(ctx.emit_ctx, return_ty), result_temp });
    try ctx.emit_expr(ctx.emit_ctx, call.callee.*, locals);
    try emitSequencedArgList(ctx.allocator, ctx.out, temps);
    try ctx.out.appendSlice(ctx.allocator, ";\n");
    return result_temp;
}

pub fn emitSequencedCallLocalValue(ctx: TempContext, name: []const u8, decl_ty: ast.TypeExpr, call: anytype, locals: *std.StringHashMap(LocalInfo), temps: []const SequencedArgTemp, emit_ignored_prefix: bool) !void {
    try writeIndent(ctx);
    if (emit_ignored_prefix) try emitIgnoredLocalPrefix(ctx, name);
    try ctx.out.print(ctx.allocator, "{s} {s} = ", .{ try ctx.c_type(ctx.emit_ctx, decl_ty), try ctx.c_ident(ctx.emit_ctx, name) });
    try ctx.emit_expr(ctx.emit_ctx, call.callee.*, locals);
    try emitSequencedArgList(ctx.allocator, ctx.out, temps);
    try ctx.out.appendSlice(ctx.allocator, ";\n");
}

pub fn emitSequencedCallExprStmtValue(ctx: TempContext, call: anytype, locals: *std.StringHashMap(LocalInfo), temps: []const SequencedArgTemp) !void {
    try writeIndent(ctx);
    try ctx.emit_expr(ctx.emit_ctx, call.callee.*, locals);
    try emitSequencedArgList(ctx.allocator, ctx.out, temps);
    try ctx.out.appendSlice(ctx.allocator, ";\n");
}

pub fn emitPlainSequencedArgTemp(ctx: TempContext, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!SequencedArgTemp {
    // A va_list argument materialized into a temp must be COPIED with __builtin_va_copy, not
    // `=`: on x86-64 SysV __builtin_va_list is an array type, so `T t = arg;` is ill-formed.
    // This fires for e.g. vfprintf forwarding its `ap` to vprintf. __builtin_va_copy is also
    // correct where va_list is a scalar pointer (riscv/aarch64).
    if (isVaListType(target_ty)) {
        const va_temp = try std.fmt.allocPrint(ctx.scratch, "mc_tmp{d}", .{ctx.temp_index.*});
        ctx.temp_index.* += 1;
        try writeIndent(ctx);
        try ctx.out.print(ctx.allocator, "{s} {s};\n", .{ try ctx.c_type(ctx.emit_ctx, target_ty), va_temp });
        try writeIndent(ctx);
        try ctx.out.appendSlice(ctx.allocator, "__builtin_va_copy(");
        try ctx.out.appendSlice(ctx.allocator, va_temp);
        try ctx.out.appendSlice(ctx.allocator, ", ");
        try ctx.emit_expr(ctx.emit_ctx, arg, locals);
        try ctx.out.appendSlice(ctx.allocator, ");\n");
        return .{ .name = va_temp, .ty = target_ty };
    }

    const temp_name = try std.fmt.allocPrint(ctx.scratch, "mc_tmp{d}", .{ctx.temp_index.*});
    ctx.temp_index.* += 1;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = ", .{ try ctx.c_type(ctx.emit_ctx, target_ty), temp_name });
    const cast_pointer_to_paddr = isPAddrType(target_ty) and blk: {
        const source_ty = ctx.expr_source_type(ctx.emit_ctx, arg, locals) orelse break :blk false;
        break :blk isPointerLikeAddressType(source_ty);
    };
    if (cast_pointer_to_paddr) {
        try ctx.out.appendSlice(ctx.allocator, "((uintptr_t)(");
        try ctx.emit_expr(ctx.emit_ctx, arg, locals);
        try ctx.out.appendSlice(ctx.allocator, "))");
    } else {
        try ctx.emit_expr_with_target(ctx.emit_ctx, arg, locals, target_ty);
    }
    try ctx.out.appendSlice(ctx.allocator, ";\n");
    return .{ .name = temp_name, .ty = target_ty };
}

pub fn emitVaStartLocalInit(ctx: LocalInitContext, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr) !bool {
    const node = switch (initializer.kind) {
        .call => |call| call,
        else => return false,
    };
    const kind = ctx.mir_call_target_kind(ctx.emit_ctx, node.callee.*.span) orelse return false;
    if (kind != .va_start) return false;
    if (node.type_args.len != 0 or node.args.len != 0) return error.UnsupportedCEmission;
    _ = ctx.mir_target_type(ctx.emit_ctx, .va_result, node.callee.*.span) orelse return error.UnsupportedCEmission;
    const last = ctx.current_variadic_last orelse return error.UnsupportedCEmission;
    try writeLocalIndent(ctx);
    try ctx.emit_declarator(ctx.emit_ctx, decl_ty, name);
    try ctx.out.appendSlice(ctx.allocator, ";\n");
    try writeLocalIndent(ctx);
    try ctx.out.print(ctx.allocator, "__builtin_va_start({s}, {s});\n", .{ try ctx.c_ident(ctx.emit_ctx, name), try ctx.c_ident(ctx.emit_ctx, last) });
    return true;
}

pub fn emitVaListCopyLocalInit(ctx: LocalInitContext, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr) !bool {
    if (!isVaListType(decl_ty)) return false;
    const src_ident = switch (initializer.kind) {
        .ident => |ident| ident,
        else => return false,
    };
    try writeLocalIndent(ctx);
    try ctx.emit_declarator(ctx.emit_ctx, decl_ty, name);
    try ctx.out.appendSlice(ctx.allocator, ";\n");
    try writeLocalIndent(ctx);
    try ctx.out.print(ctx.allocator, "__builtin_va_copy({s}, {s});\n", .{ try ctx.c_ident(ctx.emit_ctx, name), try ctx.c_ident(ctx.emit_ctx, src_ident.text) });
    return true;
}

pub fn emitSpecialSequencedArgTemp(ctx: SpecialTempContext, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
    switch (arg.kind) {
        .address_of => if (try ctx.address(ctx.emit_ctx, arg, locals, target_ty)) |temp| return temp,
        .index => if (try ctx.index(ctx.emit_ctx, arg, locals, target_ty)) |temp| return temp,
        .binary => if (try ctx.binary(ctx.emit_ctx, arg, locals, target_ty)) |temp| return temp,
        .deref => if (try ctx.deref(ctx.emit_ctx, arg, locals, target_ty)) |temp| return temp,
        .array_literal, .struct_literal => if (try ctx.aggregate(ctx.emit_ctx, arg, locals, target_ty)) |temp| return temp,
        .cast => if (try ctx.cast(ctx.emit_ctx, arg, locals, target_ty)) |temp| return temp,
        .call => if (try ctx.call(ctx.emit_ctx, arg, locals, target_ty)) |temp| return temp,
        else => {},
    }

    return null;
}

pub fn emitTrapCall(ctx: Context, call: anytype) !bool {
    const kind = ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) orelse return false;
    const helper = mir.explicitTrapHelperForTarget(kind) orelse return false;
    if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedCEmission;
    try ctx.out.print(ctx.allocator, "{s}()", .{helper});
    return true;
}

fn writeIndent(ctx: TempContext) !void {
    for (0..ctx.indent.*) |_| try ctx.out.appendSlice(ctx.allocator, "    ");
}

fn emitIgnoredLocalPrefix(ctx: TempContext, name: []const u8) !void {
    if (name.len > 0 and name[0] == '_') {
        try ctx.out.appendSlice(ctx.allocator, "MC_UNUSED ");
    }
}

fn sequencedCallFnInfo(functions: *const std.StringHashMap(FnInfo), call: anytype) ?FnInfo {
    const name = calleeIdentName(call.callee.*) orelse return null;
    return functions.get(name);
}

fn writeLocalIndent(ctx: LocalInitContext) !void {
    for (0..ctx.indent.*) |_| try ctx.out.appendSlice(ctx.allocator, "    ");
}

pub fn emitNamedDiscardCall(ctx: Context, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
    const kind = ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) orelse return false;
    if (kind != .drop and kind != .forget_unchecked) return false;
    if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedCEmission;
    const argument_ty = ctx.mir_target_type(ctx.emit_ctx, .discard_argument, call.args[0].span) orelse return error.UnsupportedCEmission;
    try ctx.out.appendSlice(ctx.allocator, "(void)(");
    try ctx.emit_expr_with_target(ctx.emit_ctx, call.args[0], locals, argument_ty);
    try ctx.out.appendSlice(ctx.allocator, ")");
    return true;
}

pub fn emitRawAddressCall(ctx: Context, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
    const kind = ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span);
    if (kind == .raw_load) {
        if (!ast_query.isRawLoadCall(call.callee.*) or call.type_args.len != 1 or call.args.len != 1) return error.UnsupportedCEmission;
        const address_ty = ctx.mir_target_type(ctx.emit_ctx, .raw_address, call.callee.*.span) orelse return error.UnsupportedCEmission;
        const payload_ty = ctx.mir_target_type(ctx.emit_ctx, .raw_payload, call.callee.*.span) orelse return error.UnsupportedCEmission;
        const result_ty = ctx.mir_target_type(ctx.emit_ctx, .raw_result, call.callee.*.span) orelse return error.UnsupportedCEmission;
        if (typeName(payload_ty)) |name| {
            if (rawScalarSuffix(name)) |suffix| {
                try ctx.out.print(ctx.allocator, "mc_raw_load_{s}(", .{suffix});
                try ctx.emit_expr_with_target(ctx.emit_ctx, call.args[0], locals, address_ty);
                try ctx.out.appendSlice(ctx.allocator, ")");
                return true;
            }
        }
        // Aggregate (non-scalar) T: whole-object typed load, mirroring how
        // `raw.ptr<T>(addr)` + deref already lowers a struct. `(*(T *)(addr))`
        // is a struct-typed lvalue read.
        try ctx.out.appendSlice(ctx.allocator, "(*(");
        try ctx.out.appendSlice(ctx.allocator, try ctx.c_type(ctx.emit_ctx, result_ty));
        try ctx.out.appendSlice(ctx.allocator, " *)(");
        try ctx.emit_expr_with_target(ctx.emit_ctx, call.args[0], locals, address_ty);
        try ctx.out.appendSlice(ctx.allocator, "))");
        return true;
    }
    if (kind == .raw_ptr) {
        if (!ast_query.isRawPtrCall(call.callee.*) or call.type_args.len != 1 or call.args.len != 1) return error.UnsupportedCEmission;
        const address_ty = ctx.mir_target_type(ctx.emit_ctx, .raw_address, call.callee.*.span) orelse return error.UnsupportedCEmission;
        _ = ctx.mir_target_type(ctx.emit_ctx, .raw_payload, call.callee.*.span) orelse return error.UnsupportedCEmission;
        const result_ty = ctx.mir_target_type(ctx.emit_ctx, .raw_result, call.callee.*.span) orelse return error.UnsupportedCEmission;
        try ctx.out.appendSlice(ctx.allocator, "(");
        try ctx.out.appendSlice(ctx.allocator, try ctx.c_type(ctx.emit_ctx, result_ty));
        try ctx.out.appendSlice(ctx.allocator, ")(");
        try ctx.emit_expr_with_target(ctx.emit_ctx, call.args[0], locals, address_ty);
        try ctx.out.appendSlice(ctx.allocator, ")");
        return true;
    }
    return false;
}

pub fn emitVaCall(ctx: Context, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
    const kind = ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) orelse return false;
    switch (kind) {
        .va_arg => {
            if (call.type_args.len != 1 or call.args.len != 1) return error.UnsupportedCEmission;
            const cursor_ty = ctx.mir_target_type(ctx.emit_ctx, .va_cursor, call.callee.*.span) orelse return error.UnsupportedCEmission;
            const payload_ty = ctx.mir_target_type(ctx.emit_ctx, .va_payload, call.callee.*.span) orelse return error.UnsupportedCEmission;
            _ = ctx.mir_target_type(ctx.emit_ctx, .va_result, call.callee.*.span) orelse return error.UnsupportedCEmission;
            try ctx.out.print(ctx.allocator, "__builtin_va_arg(*(", .{});
            try ctx.emit_expr_with_target(ctx.emit_ctx, call.args[0], locals, cursor_ty);
            try ctx.out.appendSlice(ctx.allocator, "), ");
            try ctx.out.appendSlice(ctx.allocator, try ctx.c_type(ctx.emit_ctx, payload_ty));
            try ctx.out.appendSlice(ctx.allocator, ")");
            return true;
        },
        .va_end => {
            if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedCEmission;
            const cursor_ty = ctx.mir_target_type(ctx.emit_ctx, .va_cursor, call.callee.*.span) orelse return error.UnsupportedCEmission;
            _ = ctx.mir_target_type(ctx.emit_ctx, .va_result, call.callee.*.span) orelse return error.UnsupportedCEmission;
            try ctx.out.appendSlice(ctx.allocator, "__builtin_va_end(*(");
            try ctx.emit_expr_with_target(ctx.emit_ctx, call.args[0], locals, cursor_ty);
            try ctx.out.appendSlice(ctx.allocator, "))");
            return true;
        },
        .va_start => return error.UnsupportedCEmission,
        else => return false,
    }
}

pub fn emitPhysCall(ctx: Context, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
    if (ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) != .phys) return false;
    if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedCEmission;
    _ = ctx.mir_target_type(ctx.emit_ctx, .phys_result, call.callee.*.span) orelse return error.UnsupportedCEmission;
    try ctx.out.appendSlice(ctx.allocator, "((uintptr_t)(");
    try ctx.emit_expr(ctx.emit_ctx, call.args[0], locals);
    try ctx.out.appendSlice(ctx.allocator, "))");
    return true;
}

pub fn emitDeclassifyCall(ctx: Context, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
    if (ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) != .declassify) return false;
    if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedCEmission;
    _ = ctx.mir_target_type(ctx.emit_ctx, .declassify_source, call.callee.*.span) orelse return error.UnsupportedCEmission;
    _ = ctx.mir_target_type(ctx.emit_ctx, .declassify_result, call.callee.*.span) orelse return error.UnsupportedCEmission;
    try ctx.emit_expr(ctx.emit_ctx, call.args[0], locals);
    return true;
}

pub fn emitAssumeNoaliasCall(ctx: Context, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
    if (ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) != .assume_noalias) return false;
    if (call.type_args.len != 0 or call.args.len != 2) return error.UnsupportedCEmission;
    _ = ctx.mir_target_type(ctx.emit_ctx, .assume_noalias_source, call.callee.*.span) orelse return error.UnsupportedCEmission;
    _ = ctx.mir_target_type(ctx.emit_ctx, .assume_noalias_result, call.callee.*.span) orelse return error.UnsupportedCEmission;
    try ctx.out.appendSlice(ctx.allocator, "((void)(");
    try ctx.emit_expr(ctx.emit_ctx, call.args[1], locals);
    try ctx.out.appendSlice(ctx.allocator, "), ");
    try ctx.emit_expr(ctx.emit_ctx, call.args[0], locals);
    try ctx.out.appendSlice(ctx.allocator, ")");
    return true;
}

pub fn emitUncheckedCall(ctx: Context, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
    const info = uncheckedCallInfo(ctx, call) orelse return false;
    try ctx.out.appendSlice(ctx.allocator, "(");
    try ctx.emit_expr_with_target(ctx.emit_ctx, call.args[0], locals, info.left_ty);
    try ctx.out.print(ctx.allocator, " {s} ", .{uncheckedNoOverflowOperator(info.op)});
    try ctx.emit_expr_with_target(ctx.emit_ctx, call.args[1], locals, info.right_ty);
    try ctx.out.appendSlice(ctx.allocator, ")");
    return true;
}
