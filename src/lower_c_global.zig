//! C backend global load/store text helpers.

const std = @import("std");

const ast = @import("ast.zig");
const lower_c_const = @import("lower_c_const.zig");
const lower_c_model = @import("lower_c_model.zig");

const GlobalAccess = lower_c_model.GlobalAccess;
const GlobalArrayElementAccess = lower_c_model.GlobalArrayElementAccess;
const GlobalElementInfo = lower_c_model.GlobalElementInfo;
const GlobalInfo = lower_c_model.GlobalInfo;
const FnInfo = lower_c_model.FnInfo;
const LocalInfo = lower_c_model.LocalInfo;

const emitStaticCInitializer = lower_c_const.emitStaticCInitializer;
const isArrayLiteralExpr = lower_c_const.isArrayLiteralExpr;
const isStructLiteralExpr = lower_c_const.isStructLiteralExpr;
const staticCInitializer = lower_c_const.staticCInitializer;

pub const WriteLineDirectiveFn = *const fn (ctx: *anyopaque, span: ast.Span) anyerror!void;
pub const EmitDeclaratorFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr, name: []const u8) anyerror!void;
pub const ConstGlobalCValueFn = *const fn (ctx: *anyopaque, expr: ast.Expr) anyerror!?[]const u8;
pub const EmitExprFn = *const fn (ctx: *anyopaque, expr: ast.Expr) anyerror!void;
pub const EmitExprWithTargetFn = *const fn (ctx: *anyopaque, expr: ast.Expr, target_ty: ast.TypeExpr) anyerror!void;
pub const EmitExprWithLocalsFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void;
pub const EmitConstGlobalInitializerFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr, expr: ast.Expr) anyerror!bool;
pub const IsAggregateGlobalTypeFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) bool;
pub const GlobalInfoFromTypeFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) anyerror!GlobalInfo;

pub const EmitContext = struct {
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    out: *std.ArrayList(u8),
    static_initializers: *std.StringHashMap(ast.Expr),
    functions: *std.StringHashMap(FnInfo),
    emit_ctx: *anyopaque,
    write_line_directive: WriteLineDirectiveFn,
    emit_declarator: EmitDeclaratorFn,
    const_global_c_value: ConstGlobalCValueFn,
    emit_expr: EmitExprFn,
    emit_expr_with_target: EmitExprWithTargetFn,
    emit_const_global_initializer: EmitConstGlobalInitializerFn,
    is_aggregate_global_type: IsAggregateGlobalTypeFn,
};

pub const ArrayAccessEmitContext = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    emit_ctx: *anyopaque,
    emit_expr: EmitExprWithLocalsFn,
};

pub const AccessContext = struct {
    scratch: std.mem.Allocator,
    globals: *const std.StringHashMap(GlobalInfo),
    structs: *const std.StringHashMap(ast.StructDecl),
    emit_ctx: *anyopaque,
    global_info_from_type: GlobalInfoFromTypeFn,
};

pub fn emitGlobal(ctx: EmitContext, global: ast.GlobalDecl) !void {
    try ctx.write_line_directive(ctx.emit_ctx, global.name.span);
    // `extern global NAME: T;` — a declaration only (storage lives in another unit).
    if (global.is_extern) {
        try ctx.out.print(ctx.allocator, "#undef {s}\n", .{global.name.text});
        try ctx.out.appendSlice(ctx.allocator, "extern ");
        if (global.ty) |global_ty| {
            try ctx.emit_declarator(ctx.emit_ctx, global_ty, global.name.text);
        } else {
            try ctx.out.print(ctx.allocator, "uint32_t {s}", .{global.name.text});
        }
        try ctx.out.appendSlice(ctx.allocator, ";\n\n");
        return;
    }
    // A user global is a real definition and must win over any same-named macro a
    // system header leaked on hosted builds (e.g. ARG_MAX / PATH_MAX / NAME_MAX from
    // <limits.h>) — otherwise its declaration and every read expand the macro and
    // fail to compile. `#undef` of a non-macro is a legal no-op, so this is safe for
    // the common (non-colliding) case.
    try ctx.out.print(ctx.allocator, "#undef {s}\n", .{global.name.text});
    // `export global` gets EXTERNAL linkage (no `static`) so other compilation units —
    // e.g. a vendored C engine linking against `stdout`/`stderr` data symbols this
    // runtime provides — resolve it by name. Plain `global` stays file-local `static`.
    try ctx.out.appendSlice(ctx.allocator, if (global.exported) "MC_UNUSED " else "static MC_UNUSED ");
    if (global.ty) |global_ty| {
        try ctx.emit_declarator(ctx.emit_ctx, global_ty, global.name.text);
    } else {
        try ctx.out.print(ctx.allocator, "uint32_t {s}", .{global.name.text});
    }
    if (global.init) |initializer| {
        // A `const` global (section 22) emits its folded compile-time value,
        // so initializers like `MAX * 2` that reference earlier const
        // globals lower to a plain C constant.
        if (global.is_const) {
            if (try ctx.const_global_c_value(ctx.emit_ctx, initializer)) |text| {
                try ctx.out.print(ctx.allocator, " = {s};\n\n", .{text});
                return;
            }
        }
        if (staticCInitializer(initializer, ctx.static_initializers, ctx.functions, ctx.scratch)) |static_initializer| {
            try ctx.out.appendSlice(ctx.allocator, " = ");
            if (try emitStaticCInitializer(ctx.allocator, ctx.out, static_initializer)) {
                // Emitted directly.
            } else if (global.ty) |global_ty| {
                try ctx.emit_expr_with_target(ctx.emit_ctx, static_initializer, global_ty);
            } else {
                try ctx.emit_expr(ctx.emit_ctx, static_initializer);
            }
            try ctx.static_initializers.put(global.name.text, static_initializer);
        } else if (global.ty != null and isArrayLiteralExpr(initializer)) {
            try ctx.out.appendSlice(ctx.allocator, " = ");
            try ctx.emit_expr_with_target(ctx.emit_ctx, initializer, global.ty.?);
            try ctx.static_initializers.put(global.name.text, initializer);
        } else if (global.ty != null and isStructLiteralExpr(initializer)) {
            try ctx.out.appendSlice(ctx.allocator, " = ");
            try ctx.emit_expr_with_target(ctx.emit_ctx, initializer, global.ty.?);
            try ctx.static_initializers.put(global.name.text, initializer);
        } else if (global.ty) |global_ty| {
            if (try ctx.emit_const_global_initializer(ctx.emit_ctx, global_ty, initializer)) {
                try ctx.out.appendSlice(ctx.allocator, ";\n\n");
                return;
            }
            if (global_ty.kind == .array) {
                try ctx.out.appendSlice(ctx.allocator, "/* unsupported non-static global array initializer */");
                return error.UnsupportedCEmission;
            }
            try ctx.out.appendSlice(ctx.allocator, "/* unsupported non-static global initializer */");
            return error.UnsupportedCEmission;
        } else {
            try ctx.out.appendSlice(ctx.allocator, "/* unsupported non-static global initializer */");
            return error.UnsupportedCEmission;
        }
    } else if (global.ty != null and ctx.is_aggregate_global_type(ctx.emit_ctx, global.ty.?)) {
        try ctx.out.appendSlice(ctx.allocator, " = {0}");
    } else {
        try ctx.out.appendSlice(ctx.allocator, " = 0");
    }
    try ctx.out.appendSlice(ctx.allocator, ";\n\n");
}

pub fn appendGlobalLoadExpr(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, global: GlobalInfo) !void {
    if (global.aggregate) {
        try out.print(allocator, "({s})", .{name});
    } else if (global.pointer_like) {
        try out.print(allocator, "(({s})__atomic_load_n(&{s}, __ATOMIC_RELAXED))", .{ global.c_type, name });
    } else {
        try out.print(allocator, "(({s})mc_race_load_{s}(&{s}))", .{ global.c_type, global.race_type_name, name });
    }
}

pub fn appendGlobalStorePrefix(allocator: std.mem.Allocator, out: *std.ArrayList(u8), target: GlobalAccess) !void {
    if (target.info.aggregate) {
        try out.print(allocator, "{s} = ({s})(", .{ target.name, target.info.c_type });
    } else if (target.info.pointer_like) {
        try out.print(allocator, "__atomic_store_n(&{s}, ({s})", .{ target.name, target.info.c_type });
    } else {
        try out.print(allocator, "mc_race_store_{s}(&{s}, ({s})", .{ target.info.race_type_name, target.name, target.info.race_c_type });
    }
}

pub fn appendGlobalStoreSuffix(allocator: std.mem.Allocator, out: *std.ArrayList(u8), target: GlobalAccess) !void {
    if (target.info.pointer_like) {
        try out.appendSlice(allocator, ", __ATOMIC_RELAXED);\n");
    } else {
        try out.appendSlice(allocator, ");\n");
    }
}

pub fn appendGlobalStoreValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), target: GlobalAccess, value: []const u8) !void {
    try appendGlobalStorePrefix(allocator, out, target);
    try out.appendSlice(allocator, value);
    try appendGlobalStoreSuffix(allocator, out, target);
}

pub fn globalAssignmentTarget(ctx: AccessContext, target: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?GlobalAccess {
    return switch (target.kind) {
        .ident => |ident| if (!locals.contains(ident.text))
            if (ctx.globals.get(ident.text)) |global| .{ .name = ident.text, .info = global } else null
        else
            null,
        .member => |member| globalMemberAccess(ctx, member, locals),
        .grouped => |inner| globalAssignmentTarget(ctx, inner.*, locals),
        else => null,
    };
}

pub fn globalMemberAccess(ctx: AccessContext, member: anytype, locals: ?*std.StringHashMap(LocalInfo)) ?GlobalAccess {
    const base_ident = switch (member.base.kind) {
        .ident => |ident| ident,
        .grouped => |inner| switch (inner.kind) {
            .ident => |ident| ident,
            else => return null,
        },
        else => return null,
    };
    if (locals) |local_set| if (local_set.contains(base_ident.text)) return null;
    const global = ctx.globals.get(base_ident.text) orelse return null;
    const struct_decl = ctx.structs.get(global.type_name) orelse return null;
    for (struct_decl.fields) |field| {
        if (!std.mem.eql(u8, field.name.text, member.name.text)) continue;
        const info = ctx.global_info_from_type(ctx.emit_ctx, field.ty) catch return null;
        return .{
            .name = std.fmt.allocPrint(ctx.scratch, "{s}.{s}", .{ base_ident.text, member.name.text }) catch return null,
            .info = info,
        };
    }
    return null;
}

pub fn emitGlobalArrayElementLoadExpr(ctx: ArrayAccessEmitContext, access: GlobalArrayElementAccess, locals: ?*std.StringHashMap(LocalInfo)) !void {
    if (access.element_info.aggregate) {
        try ctx.out.print(ctx.allocator, "({s}.elems[mc_check_index_usize(", .{access.base_name});
        try ctx.emit_expr(ctx.emit_ctx, access.index, locals);
        try ctx.out.print(ctx.allocator, ", {s})])", .{access.len});
        return;
    }
    if (access.element_info.pointer_like) {
        try ctx.out.print(ctx.allocator, "(({s})__atomic_load_n(&{s}.elems[mc_check_index_usize(", .{ access.element_info.c_type, access.base_name });
        try ctx.emit_expr(ctx.emit_ctx, access.index, locals);
        try ctx.out.print(ctx.allocator, ", {s})], __ATOMIC_RELAXED))", .{access.len});
        return;
    }
    try ctx.out.print(ctx.allocator, "(({s})mc_race_load_{s}(&{s}.elems[mc_check_index_usize(", .{ access.element_info.c_type, access.element_info.race_type_name, access.base_name });
    try ctx.emit_expr(ctx.emit_ctx, access.index, locals);
    try ctx.out.print(ctx.allocator, ", {s})]))", .{access.len});
}

pub fn emitGlobalArrayElementMemberLoadExpr(ctx: ArrayAccessEmitContext, access: GlobalArrayElementAccess, locals: ?*std.StringHashMap(LocalInfo), field_info: GlobalElementInfo, field_name: []const u8) !void {
    if (field_info.aggregate) {
        try ctx.out.print(ctx.allocator, "({s}.elems[mc_check_index_usize(", .{access.base_name});
        try ctx.emit_expr(ctx.emit_ctx, access.index, locals);
        try ctx.out.print(ctx.allocator, ", {s})].{s})", .{ access.len, field_name });
        return;
    }
    if (field_info.pointer_like) {
        try ctx.out.print(ctx.allocator, "(({s})__atomic_load_n(&{s}.elems[mc_check_index_usize(", .{ field_info.c_type, access.base_name });
        try ctx.emit_expr(ctx.emit_ctx, access.index, locals);
        try ctx.out.print(ctx.allocator, ", {s})].{s}, __ATOMIC_RELAXED))", .{ access.len, field_name });
        return;
    }
    try ctx.out.print(ctx.allocator, "(({s})mc_race_load_{s}(&{s}.elems[mc_check_index_usize(", .{ field_info.c_type, field_info.race_type_name, access.base_name });
    try ctx.emit_expr(ctx.emit_ctx, access.index, locals);
    try ctx.out.print(ctx.allocator, ", {s})].{s}))", .{ access.len, field_name });
}

pub fn appendGlobalArrayElementStore(allocator: std.mem.Allocator, out: *std.ArrayList(u8), access: GlobalArrayElementAccess, index_temp: []const u8, value_temp: []const u8) !void {
    if (access.element_info.aggregate) {
        try appendGlobalArrayAggregateStore(allocator, out, access, index_temp, value_temp);
        return;
    }
    if (access.element_info.pointer_like) {
        try appendGlobalArrayPointerStore(allocator, out, access, index_temp, value_temp);
        return;
    }
    try appendGlobalArrayRaceStore(allocator, out, access, index_temp, value_temp);
}

fn appendGlobalArrayAggregateStore(allocator: std.mem.Allocator, out: *std.ArrayList(u8), access: GlobalArrayElementAccess, index_temp: []const u8, value_temp: []const u8) !void {
    try out.print(
        allocator,
        "{s}.elems[mc_check_index_usize({s}, {s})] = ({s}){s};\n",
        .{ access.base_name, index_temp, access.len, access.element_info.c_type, value_temp },
    );
}

fn appendGlobalArrayPointerStore(allocator: std.mem.Allocator, out: *std.ArrayList(u8), access: GlobalArrayElementAccess, index_temp: []const u8, value_temp: []const u8) !void {
    try out.print(
        allocator,
        "__atomic_store_n(&{s}.elems[mc_check_index_usize({s}, {s})], ({s}){s}, __ATOMIC_RELAXED);\n",
        .{ access.base_name, index_temp, access.len, access.element_info.c_type, value_temp },
    );
}

fn appendGlobalArrayRaceStore(allocator: std.mem.Allocator, out: *std.ArrayList(u8), access: GlobalArrayElementAccess, index_temp: []const u8, value_temp: []const u8) !void {
    try out.print(
        allocator,
        "mc_race_store_{s}(&{s}.elems[mc_check_index_usize({s}, {s})], ({s}){s});\n",
        .{ access.element_info.race_type_name, access.base_name, index_temp, access.len, access.element_info.race_c_type, value_temp },
    );
}

pub fn appendGlobalArrayElementMemberStore(allocator: std.mem.Allocator, out: *std.ArrayList(u8), access: GlobalArrayElementAccess, field_info: GlobalElementInfo, field_name: []const u8, index_temp: []const u8, value_temp: []const u8) !void {
    if (field_info.aggregate) {
        try appendGlobalArrayMemberAggregateStore(allocator, out, access, field_info, field_name, index_temp, value_temp);
        return;
    }
    if (field_info.pointer_like) {
        try appendGlobalArrayMemberPointerStore(allocator, out, access, field_info, field_name, index_temp, value_temp);
        return;
    }
    try appendGlobalArrayMemberRaceStore(allocator, out, access, field_info, field_name, index_temp, value_temp);
}

fn appendGlobalArrayMemberAggregateStore(allocator: std.mem.Allocator, out: *std.ArrayList(u8), access: GlobalArrayElementAccess, field_info: GlobalElementInfo, field_name: []const u8, index_temp: []const u8, value_temp: []const u8) !void {
    try out.print(
        allocator,
        "{s}.elems[mc_check_index_usize({s}, {s})].{s} = ({s}){s};\n",
        .{ access.base_name, index_temp, access.len, field_name, field_info.c_type, value_temp },
    );
}

fn appendGlobalArrayMemberPointerStore(allocator: std.mem.Allocator, out: *std.ArrayList(u8), access: GlobalArrayElementAccess, field_info: GlobalElementInfo, field_name: []const u8, index_temp: []const u8, value_temp: []const u8) !void {
    try out.print(
        allocator,
        "__atomic_store_n(&{s}.elems[mc_check_index_usize({s}, {s})].{s}, ({s}){s}, __ATOMIC_RELAXED);\n",
        .{ access.base_name, index_temp, access.len, field_name, field_info.c_type, value_temp },
    );
}

fn appendGlobalArrayMemberRaceStore(allocator: std.mem.Allocator, out: *std.ArrayList(u8), access: GlobalArrayElementAccess, field_info: GlobalElementInfo, field_name: []const u8, index_temp: []const u8, value_temp: []const u8) !void {
    try out.print(
        allocator,
        "mc_race_store_{s}(&{s}.elems[mc_check_index_usize({s}, {s})].{s}, ({s}){s});\n",
        .{ field_info.race_type_name, access.base_name, index_temp, access.len, field_name, field_info.race_c_type, value_temp },
    );
}
