//! C backend overlay-union read/write emission.

const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const lower_c_access = @import("lower_c_access.zig");
const lower_c_model = @import("lower_c_model.zig");

const LocalInfo = lower_c_model.LocalInfo;
const OverlayFieldAccess = lower_c_model.OverlayFieldAccess;
const OverlayUnionInfo = lower_c_model.OverlayUnionInfo;

const memberExpr = ast_query.memberExpr;
const overlayArrayElementType = ast_query.overlayArrayElementType;
const overlayByteArrayElementType = ast_query.overlayByteArrayElementType;
const overlayMemberFromIndexBase = ast_query.overlayMemberFromIndexBase;
const overlayUnionNameForExpr = lower_c_access.overlayUnionNameForExpr;

pub const WriteIndentFn = *const fn (ctx: *anyopaque) anyerror!void;
pub const CTypeFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8;
pub const EmitExprFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void;
pub const EmitExprWithTargetFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!void;
pub const OverlayFieldLayoutSizeFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) usize;

pub const EmitContext = struct {
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    out: *std.ArrayList(u8),
    temp_index: *usize,
    overlay_unions: *const std.StringHashMap(OverlayUnionInfo),
    emit_ctx: *anyopaque,
    write_indent: WriteIndentFn,
    c_type: CTypeFn,
    emit_expr: EmitExprFn,
    emit_expr_with_target: EmitExprWithTargetFn,
    overlay_field_layout_size: OverlayFieldLayoutSizeFn,
};

pub fn emitOverlayFieldReadReturn(ctx: EmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
    switch (expr.kind) {
        .grouped => |inner| return try emitOverlayFieldReadReturn(ctx, inner.*, locals, return_ty),
        .member => |node| {
            const access = overlayFieldAccess(ctx, node, locals) orelse return false;
            if (access.field.byte_array_len != null) return false;
            const temp_ty = if (return_ty) |ty| ty else access.field.ty;
            const temp_name = try nextTempName(ctx, "mc_tmp");

            try ctx.write_indent(ctx.emit_ctx);
            try ctx.out.print(ctx.allocator, "{s} {s};\n", .{ try ctx.c_type(ctx.emit_ctx, temp_ty), temp_name });
            try ctx.write_indent(ctx.emit_ctx);
            try ctx.out.print(ctx.allocator, "__builtin_memcpy(&{s}, ", .{temp_name});
            try ctx.emit_expr(ctx.emit_ctx, access.base, locals);
            try ctx.out.print(ctx.allocator, ".storage, {d});\n", .{access.field.layout.size});
            try ctx.write_indent(ctx.emit_ctx);
            try ctx.out.print(ctx.allocator, "return {s};\n", .{temp_name});
            return true;
        },
        .index => |node| {
            const member = memberExpr(node.base.*) orelse return false;
            const access = overlayFieldAccess(ctx, member, locals) orelse return false;
            const len = access.field.byte_array_len orelse return false;

            try ctx.write_indent(ctx.emit_ctx);
            try ctx.out.appendSlice(ctx.allocator, "return ");
            try ctx.emit_expr(ctx.emit_ctx, access.base, locals);
            try ctx.out.appendSlice(ctx.allocator, ".storage[mc_check_index_usize(");
            try ctx.emit_expr(ctx.emit_ctx, node.index.*, locals);
            try ctx.out.print(ctx.allocator, ", {s})];\n", .{len});
            return true;
        },
        else => return false,
    }
}

pub fn emitOverlayFieldWriteStmt(ctx: EmitContext, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
    switch (assignment.target.kind) {
        .grouped => |inner| return try emitOverlayFieldWriteStmt(ctx, .{ .target = inner.*, .value = assignment.value }, locals),
        .member => |node| {
            const access = overlayFieldAccess(ctx, node, locals) orelse return false;
            if (access.field.byte_array_len != null) return false;
            const temp_name = try nextTempName(ctx, "mc_tmp");

            try ctx.write_indent(ctx.emit_ctx);
            try ctx.out.print(ctx.allocator, "{s} {s} = ", .{ try ctx.c_type(ctx.emit_ctx, access.field.ty), temp_name });
            try ctx.emit_expr_with_target(ctx.emit_ctx, assignment.value, locals, access.field.ty);
            try ctx.out.appendSlice(ctx.allocator, ";\n");

            try ctx.write_indent(ctx.emit_ctx);
            try ctx.out.print(ctx.allocator, "__builtin_memcpy(", .{});
            try ctx.emit_expr(ctx.emit_ctx, access.base, locals);
            try ctx.out.print(ctx.allocator, ".storage, &{s}, {d});\n", .{ temp_name, access.field.layout.size });
            return true;
        },
        .index => |node| {
            const member = overlayMemberFromIndexBase(node.base.*) orelse return false;
            const access = overlayFieldAccess(ctx, member, locals) orelse return false;

            if (access.field.byte_array_len) |len| {
                // Byte view: storage byte == view element.
                try ctx.write_indent(ctx.emit_ctx);
                try ctx.emit_expr(ctx.emit_ctx, access.base, locals);
                try ctx.out.appendSlice(ctx.allocator, ".storage[mc_check_index_usize(");
                try ctx.emit_expr(ctx.emit_ctx, node.index.*, locals);
                try ctx.out.print(ctx.allocator, ", {s})] = ", .{len});
                const byte_ty = overlayByteArrayElementType(access.field.ty) orelse return false;
                try ctx.emit_expr_with_target(ctx.emit_ctx, assignment.value, locals, byte_ty);
                try ctx.out.appendSlice(ctx.allocator, ";\n");
                return true;
            }

            // Non-byte view (`[N]uW`): write one element at its byte offset in storage
            // via the same memcpy-reinterpret idiom the read path uses.
            const element_ty = overlayArrayElementType(access.field.ty) orelse return false;
            const elem_count = access.field.layout.size / ctx.overlay_field_layout_size(ctx.emit_ctx, element_ty);
            const element_c = try ctx.c_type(ctx.emit_ctx, element_ty);
            const val_name = try nextTempName(ctx, "mc_ov");
            const idx_name = try nextTempName(ctx, "mc_ovi");

            try ctx.write_indent(ctx.emit_ctx);
            try ctx.out.print(ctx.allocator, "{s} {s} = ", .{ element_c, val_name });
            try ctx.emit_expr_with_target(ctx.emit_ctx, assignment.value, locals, element_ty);
            try ctx.out.appendSlice(ctx.allocator, ";\n");
            try ctx.write_indent(ctx.emit_ctx);
            try ctx.out.print(ctx.allocator, "size_t {s} = mc_check_index_usize(", .{idx_name});
            try ctx.emit_expr(ctx.emit_ctx, node.index.*, locals);
            try ctx.out.print(ctx.allocator, ", {d});\n", .{elem_count});
            try ctx.write_indent(ctx.emit_ctx);
            try ctx.out.appendSlice(ctx.allocator, "__builtin_memcpy(&");
            try ctx.emit_expr(ctx.emit_ctx, access.base, locals);
            try ctx.out.print(ctx.allocator, ".storage[{s} * sizeof({s})], &{s}, sizeof({s}));\n", .{ idx_name, element_c, val_name, element_c });
            return true;
        },
        else => return false,
    }
}

/// General-position READ of a scalar overlay member (`w.u`). Overlay unions are
/// lowered to a storage-only C struct (`unsigned char storage[N]`), so the named
/// member does not exist on the C type; it must be reconstituted from storage.
pub fn emitOverlayMemberReadExpr(ctx: EmitContext, node: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
    const access = overlayFieldAccess(ctx, node, locals) orelse return false;
    // Array views are read element-wise via `emitOverlayIndexReadExpr`; a bare
    // member read of an array view is not a supported scalar load.
    if (access.field.byte_array_len != null) return false;
    if (overlayArrayElementType(access.field.ty) != null) return false;

    const temp_name = try nextTempName(ctx, "mc_ov");

    try ctx.out.appendSlice(ctx.allocator, "({ ");
    try ctx.out.print(ctx.allocator, "{s} {s}; __builtin_memcpy(&{s}, ", .{ try ctx.c_type(ctx.emit_ctx, access.field.ty), temp_name, temp_name });
    try ctx.emit_expr(ctx.emit_ctx, access.base, locals);
    try ctx.out.print(ctx.allocator, ".storage, {d}); {s}; }})", .{ access.field.layout.size, temp_name });
    return true;
}

/// General-position READ of an overlay array-view element (`w.bytes[i]`,
/// `w.halves[i]`). Byte views index storage directly; non-byte views copy one
/// element from its byte offset in storage.
pub fn emitOverlayIndexReadExpr(ctx: EmitContext, node: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
    const member = overlayMemberFromIndexBase(node.base.*) orelse return false;
    const access = overlayFieldAccess(ctx, member, locals) orelse return false;

    if (access.field.byte_array_len) |len| {
        // Byte view: storage byte == view element.
        try ctx.emit_expr(ctx.emit_ctx, access.base, locals);
        try ctx.out.appendSlice(ctx.allocator, ".storage[mc_check_index_usize(");
        try ctx.emit_expr(ctx.emit_ctx, node.index.*, locals);
        try ctx.out.print(ctx.allocator, ", {s})]", .{len});
        return true;
    }

    const element_ty = overlayArrayElementType(access.field.ty) orelse return false;
    const elem_count = access.field.layout.size / ctx.overlay_field_layout_size(ctx.emit_ctx, element_ty);
    const element_c = try ctx.c_type(ctx.emit_ctx, element_ty);
    const idx_name = try nextTempName(ctx, "mc_ovi");
    const temp_name = try nextTempName(ctx, "mc_ov");

    // Non-byte view: copy one element from its byte offset within storage.
    try ctx.out.appendSlice(ctx.allocator, "({ size_t ");
    try ctx.out.print(ctx.allocator, "{s} = mc_check_index_usize(", .{idx_name});
    try ctx.emit_expr(ctx.emit_ctx, node.index.*, locals);
    try ctx.out.print(ctx.allocator, ", {d}); {s} {s}; __builtin_memcpy(&{s}, &", .{ elem_count, element_c, temp_name, temp_name });
    try ctx.emit_expr(ctx.emit_ctx, access.base, locals);
    try ctx.out.print(ctx.allocator, ".storage[{s} * sizeof({s})], sizeof({s})); {s}; }})", .{ idx_name, element_c, element_c, temp_name });
    return true;
}

fn nextTempName(ctx: EmitContext, prefix: []const u8) ![]const u8 {
    const name = try std.fmt.allocPrint(ctx.scratch, "{s}{d}", .{ prefix, ctx.temp_index.* });
    ctx.temp_index.* += 1;
    return name;
}

fn overlayFieldAccess(ctx: EmitContext, member: anytype, locals: *std.StringHashMap(LocalInfo)) ?OverlayFieldAccess {
    const name = overlayUnionNameForExpr(member.base.*, locals) orelse return null;
    const info = ctx.overlay_unions.get(name) orelse return null;
    const field = info.fields.get(member.name.text) orelse return null;
    return .{ .base = member.base.*, .field = field };
}
