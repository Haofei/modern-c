//! C backend registry collection helpers.

const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const lower_c_alias = @import("lower_c_alias.zig");
const lower_c_builtin = @import("lower_c_builtin.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_shape = @import("lower_c_shape.zig");
const mir = @import("mir.zig");

const ArrayInfo = lower_c_model.ArrayInfo;
const BindThunk = lower_c_model.BindThunk;
const FnInfo = lower_c_model.FnInfo;
const MmioStruct = lower_c_model.MmioStruct;
const PackedBitsField = lower_c_model.PackedBitsField;
const PackedBitsInfo = lower_c_model.PackedBitsInfo;
const ResultInfo = lower_c_model.ResultInfo;
const SliceInfo = lower_c_model.SliceInfo;
const byteViewCallReturnTypeForCall = lower_c_builtin.byteViewCallReturnTypeForCall;
const calleeIdentName = ast_query.calleeIdentName;
const memberCallee = ast_query.memberCallee;
const mmioFieldFromType = lower_c_shape.mmioFieldFromType;
const typeName = ast_query.typeName;

pub const TypeArtifactFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) anyerror!void;
pub const MirTargetTypeFn = *const fn (ctx: *anyopaque, kind: mir.TargetTypeKind, span: ast.Span) ?ast.TypeExpr;
pub const TypeNameFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8;
pub const ArrayTypeNameFn = *const fn (ctx: *anyopaque, child: ast.TypeExpr, len_expr: ast.Expr) anyerror![]const u8;
pub const ExprTextFn = *const fn (ctx: *anyopaque, expr: ast.Expr) anyerror![]const u8;
pub const ResultTypeNameFn = *const fn (ctx: *anyopaque, ok_ty: ast.TypeExpr, err_ty: ast.TypeExpr) anyerror![]const u8;
pub const SliceTypeNameFn = *const fn (ctx: *anyopaque, child: ast.TypeExpr, mutability: ast.Mutability) anyerror![]const u8;

pub const TypeArtifactContext = struct {
    emit_ctx: *anyopaque,
    collect_type_artifacts: TypeArtifactFn,
    mir_target_type: MirTargetTypeFn,
};

pub const FnPtrArtifactContext = struct {
    emit_ctx: *anyopaque,
    fn_ptr_type_name: TypeNameFn,
    closure_type_name: TypeNameFn,
    fn_ptr_types: *std.StringHashMap(ast.TypeExpr),
    closure_types: *std.StringHashMap(ast.TypeExpr),
};

pub const ArrayArtifactContext = struct {
    emit_ctx: *anyopaque,
    collect_type_artifacts: TypeArtifactFn,
    array_type_name: ArrayTypeNameFn,
    array_len_text_for_expr: ExprTextFn,
    c_type_for_typedef: TypeNameFn,
    array_types: *std.StringHashMap(ArrayInfo),
};

pub const ResultArtifactContext = struct {
    emit_ctx: *anyopaque,
    collect_type_artifacts: TypeArtifactFn,
    result_type_name: ResultTypeNameFn,
    result_types: *std.StringHashMap(ResultInfo),
};

pub const SliceArtifactContext = struct {
    emit_ctx: *anyopaque,
    slice_type_name: SliceTypeNameFn,
    pointer_type_for_slice_element: SliceTypeNameFn,
    slice_types: *std.StringHashMap(SliceInfo),
};

pub const BindThunkContext = struct {
    name_allocator: std.mem.Allocator,
    type_aliases: *const std.StringHashMap(ast.TypeExpr),
    functions: *const std.StringHashMap(FnInfo),
    bind_thunks: *std.StringHashMap(BindThunk),
    mir_function: *const mir.Function,
};

pub fn collectPackedBits(
    allocator: std.mem.Allocator,
    packed_bits_map: *std.StringHashMap(PackedBitsInfo),
    packed_bits: ast.PackedBitsDecl,
    repr_c_type: []const u8,
) !void {
    var fields = std.StringHashMap(PackedBitsField).init(allocator);
    errdefer fields.deinit();
    for (packed_bits.fields, 0..) |field, bit_index| {
        try fields.put(field.name.text, .{ .bit_index = bit_index });
    }
    try packed_bits_map.put(packed_bits.name.text, .{
        .repr_name = typeName(packed_bits.repr) orelse "unknown",
        .repr_c_type = repr_c_type,
        .fields = fields,
    });
}

pub fn collectMmioStruct(
    allocator: std.mem.Allocator,
    mmio_structs: *std.StringHashMap(MmioStruct),
    struct_decl: ast.StructDecl,
) !void {
    var fields = std.StringHashMap(lower_c_model.MmioField).init(allocator);
    errdefer fields.deinit();
    for (struct_decl.fields) |field| {
        if (mmioFieldFromType(field.ty)) |info| try fields.put(field.name.text, info);
    }
    try mmio_structs.put(struct_decl.name.text, .{ .fields = fields });
}

pub fn collectFunctionTypeArtifacts(ctx: TypeArtifactContext, fn_decl: ast.FnDecl) anyerror!void {
    for (fn_decl.params) |param| try ctx.collect_type_artifacts(ctx.emit_ctx, param.ty);
    if (fn_decl.return_type) |ret| try ctx.collect_type_artifacts(ctx.emit_ctx, ret);
    if (fn_decl.body) |body| try collectBlockTypeArtifacts(ctx, body);
}

pub fn collectBlockTypeArtifacts(ctx: TypeArtifactContext, block: ast.Block) anyerror!void {
    for (block.items) |stmt| switch (stmt.kind) {
        .let_decl, .var_decl => |local| {
            if (local.ty) |ty| try ctx.collect_type_artifacts(ctx.emit_ctx, ty);
            if (local.init) |initializer| try collectExprTypeArtifacts(ctx, initializer);
        },
        .loop => |node| {
            if (node.iterable) |expr| try collectExprTypeArtifacts(ctx, expr);
            try collectBlockTypeArtifacts(ctx, node.body);
        },
        .if_let => |node| {
            try collectExprTypeArtifacts(ctx, node.value);
            try collectBlockTypeArtifacts(ctx, node.then_block);
            if (node.else_block) |else_block| try collectBlockTypeArtifacts(ctx, else_block);
        },
        .@"switch" => |node| for (node.arms) |arm| switch (arm.body) {
            .block => |arm_block| try collectBlockTypeArtifacts(ctx, arm_block),
            .expr => |expr| try collectExprTypeArtifacts(ctx, expr),
        },
        .unsafe_block, .comptime_block, .block => |nested| try collectBlockTypeArtifacts(ctx, nested),
        .contract_block => |contract| try collectBlockTypeArtifacts(ctx, contract.block),
        .@"return" => |maybe| if (maybe) |expr| try collectExprTypeArtifacts(ctx, expr),
        .@"defer", .expr, .assert => |expr| try collectExprTypeArtifacts(ctx, expr),
        .assignment => |node| {
            try collectExprTypeArtifacts(ctx, node.target);
            try collectExprTypeArtifacts(ctx, node.value);
        },
        else => {},
    };
}

fn collectExprTypeArtifacts(ctx: TypeArtifactContext, expr: ast.Expr) anyerror!void {
    switch (expr.kind) {
        .call => |node| {
            if (byteViewCallReturnTypeForCall(node)) |ty| try ctx.collect_type_artifacts(ctx.emit_ctx, ty);
            if (reduceCallElementType(ctx, node)) |element_ty| {
                var child_ty = element_ty;
                const slice_ty: ast.TypeExpr = .{ .span = node.args[0].span, .kind = .{ .slice = .{ .mutability = .@"const", .child = &child_ty } } };
                try ctx.collect_type_artifacts(ctx.emit_ctx, slice_ty);
            }
            for (node.type_args) |ty| try ctx.collect_type_artifacts(ctx.emit_ctx, ty);
            try collectExprTypeArtifacts(ctx, node.callee.*);
            for (node.args) |arg| try collectExprTypeArtifacts(ctx, arg);
        },
        .grouped, .address_of, .deref => |inner| try collectExprTypeArtifacts(ctx, inner.*),
        .try_expr => |inner| try collectExprTypeArtifacts(ctx, inner.operand.*),
        .unary => |node| try collectExprTypeArtifacts(ctx, node.expr.*),
        .binary => |node| {
            try collectExprTypeArtifacts(ctx, node.left.*);
            try collectExprTypeArtifacts(ctx, node.right.*);
        },
        .index => |node| {
            try collectExprTypeArtifacts(ctx, node.base.*);
            try collectExprTypeArtifacts(ctx, node.index.*);
        },
        .member => |node| try collectExprTypeArtifacts(ctx, node.base.*),
        .cast => |node| {
            try ctx.collect_type_artifacts(ctx.emit_ctx, node.ty.*);
            try collectExprTypeArtifacts(ctx, node.value.*);
        },
        .array_literal => |items| for (items) |item| try collectExprTypeArtifacts(ctx, item),
        .struct_literal => |fields| for (fields) |field| try collectExprTypeArtifacts(ctx, field.value),
        else => {},
    }
}

fn reduceCallElementType(ctx: TypeArtifactContext, call: anytype) ?ast.TypeExpr {
    if (call.type_args.len != 1 or call.args.len != 1) return null;
    return ctx.mir_target_type(ctx.emit_ctx, .reduce_element, call.callee.*.span);
}

pub fn collectFnPtrType(ctx: FnPtrArtifactContext, ty: ast.TypeExpr) anyerror!void {
    switch (ty.kind) {
        .fn_pointer => |node| {
            try collectFnPtrType(ctx, node.ret.*);
            for (node.params) |param| try collectFnPtrType(ctx, param);
            const name = try ctx.fn_ptr_type_name(ctx.emit_ctx, ty);
            if (!ctx.fn_ptr_types.contains(name)) try ctx.fn_ptr_types.put(name, ty);
        },
        .closure_type => |node| {
            try collectFnPtrType(ctx, node.ret.*);
            for (node.params) |param| try collectFnPtrType(ctx, param);
            const name = try ctx.closure_type_name(ctx.emit_ctx, ty);
            if (!ctx.closure_types.contains(name)) try ctx.closure_types.put(name, ty);
        },
        .pointer => |node| try collectFnPtrType(ctx, node.child.*),
        .raw_many_pointer => |node| try collectFnPtrType(ctx, node.child.*),
        .nullable => |child| try collectFnPtrType(ctx, child.*),
        .qualified => |node| try collectFnPtrType(ctx, node.child.*),
        .array => |node| try collectFnPtrType(ctx, node.child.*),
        .slice => |node| try collectFnPtrType(ctx, node.child.*),
        .generic => |node| for (node.args) |arg| try collectFnPtrType(ctx, arg),
        .member => |node| try collectFnPtrType(ctx, node.base.*),
        else => {},
    }
}

pub fn collectArrayType(ctx: ArrayArtifactContext, ty: ast.TypeExpr) anyerror!void {
    switch (ty.kind) {
        .array => |node| {
            try collectArrayType(ctx, node.child.*);
            try ctx.collect_type_artifacts(ctx.emit_ctx, node.child.*);
            const name = try ctx.array_type_name(ctx.emit_ctx, node.child.*, node.len);
            if (!ctx.array_types.contains(name)) {
                const len = try ctx.array_len_text_for_expr(ctx.emit_ctx, node.len);
                try ctx.array_types.put(name, .{
                    .name = name,
                    .element_ty = node.child.*,
                    .element_c_type = try ctx.c_type_for_typedef(ctx.emit_ctx, node.child.*),
                    .len = len,
                });
            }
        },
        .pointer => |node| try collectArrayType(ctx, node.child.*),
        .raw_many_pointer => |node| try collectArrayType(ctx, node.child.*),
        .slice => |node| try collectArrayType(ctx, node.child.*),
        .nullable => |child| try collectArrayType(ctx, child.*),
        .qualified => |node| try collectArrayType(ctx, node.child.*),
        .generic => |node| for (node.args) |arg| try collectArrayType(ctx, arg),
        .member => |node| try collectArrayType(ctx, node.base.*),
        else => {},
    }
}

pub fn collectResultType(ctx: ResultArtifactContext, ty: ast.TypeExpr) anyerror!void {
    switch (ty.kind) {
        .pointer => |node| try collectResultType(ctx, node.child.*),
        .raw_many_pointer => |node| try collectResultType(ctx, node.child.*),
        .slice => |node| try collectResultType(ctx, node.child.*),
        .array => |node| try collectResultType(ctx, node.child.*),
        .nullable => |child| try collectResultType(ctx, child.*),
        .qualified => |node| try collectResultType(ctx, node.child.*),
        .member => |node| try collectResultType(ctx, node.base.*),
        .generic => |node| {
            for (node.args) |arg| try ctx.collect_type_artifacts(ctx.emit_ctx, arg);
            if (std.mem.eql(u8, node.base.text, "Result") and node.args.len == 2) {
                const name = try ctx.result_type_name(ctx.emit_ctx, node.args[0], node.args[1]);
                if (!ctx.result_types.contains(name)) {
                    try ctx.result_types.put(name, .{ .name = name, .ok_ty = node.args[0], .err_ty = node.args[1] });
                }
            }
        },
        else => {},
    }
}

pub fn collectSliceType(ctx: SliceArtifactContext, ty: ast.TypeExpr) anyerror!void {
    switch (ty.kind) {
        .slice => |node| {
            try collectSliceType(ctx, node.child.*);
            try putSliceType(ctx, node.child.*, node.mutability);
            // A source `[]mut T` can appear implicitly even when the declared
            // surface type is only `[]const T`, e.g. `let s: []const T = a[0..n]`.
            // The emitter const-narrows that mutable slice value through a
            // temporary, so the mutable companion typedef must exist.
            if (node.mutability == .@"const") try putSliceType(ctx, node.child.*, .mut);
        },
        .pointer => |node| try collectSliceType(ctx, node.child.*),
        .raw_many_pointer => |node| try collectSliceType(ctx, node.child.*),
        .nullable => |child| try collectSliceType(ctx, child.*),
        .qualified => |node| try collectSliceType(ctx, node.child.*),
        .array => |node| try collectSliceType(ctx, node.child.*),
        .generic => |node| {
            if (std.mem.eql(u8, node.base.text, "DmaBuf") and node.args.len == 2) {
                try putSliceType(ctx, node.args[0], .mut);
            }
            for (node.args) |arg| try collectSliceType(ctx, arg);
        },
        .member => |node| try collectSliceType(ctx, node.base.*),
        else => {},
    }
}

fn putSliceType(ctx: SliceArtifactContext, child: ast.TypeExpr, mutability: ast.Mutability) !void {
    const name = try ctx.slice_type_name(ctx.emit_ctx, child, mutability);
    if (!ctx.slice_types.contains(name)) {
        const ptr_type = try ctx.pointer_type_for_slice_element(ctx.emit_ctx, child, mutability);
        try ctx.slice_types.put(name, .{ .name = name, .ptr_type = ptr_type });
    }
}

pub fn bindEnvIsPointerLike(type_aliases: *const std.StringHashMap(ast.TypeExpr), ty: ast.TypeExpr) bool {
    return switch (lower_c_alias.resolveAliasType(type_aliases, ty).kind) {
        .pointer, .raw_many_pointer, .fn_pointer, .slice => true,
        .nullable => |child| bindEnvIsPointerLike(type_aliases, child.*),
        .qualified => |node| bindEnvIsPointerLike(type_aliases, node.child.*),
        else => false,
    };
}

pub fn collectBlockBindThunks(ctx: BindThunkContext, block: ast.Block) anyerror!void {
    for (block.items) |stmt| switch (stmt.kind) {
        .let_decl, .var_decl => |local| {
            if (local.init) |initializer| try collectExprBindThunks(ctx, initializer);
        },
        .loop => |node| {
            if (node.iterable) |expr| try collectExprBindThunks(ctx, expr);
            try collectBlockBindThunks(ctx, node.body);
        },
        .if_let => |node| {
            try collectExprBindThunks(ctx, node.value);
            try collectBlockBindThunks(ctx, node.then_block);
            if (node.else_block) |else_block| try collectBlockBindThunks(ctx, else_block);
        },
        .@"switch" => |node| {
            try collectExprBindThunks(ctx, node.subject);
            for (node.arms) |arm| switch (arm.body) {
                .block => |arm_block| try collectBlockBindThunks(ctx, arm_block),
                .expr => |expr| try collectExprBindThunks(ctx, expr),
            };
        },
        .unsafe_block, .comptime_block, .block => |nested| try collectBlockBindThunks(ctx, nested),
        .contract_block => |contract| try collectBlockBindThunks(ctx, contract.block),
        .@"return" => |maybe| if (maybe) |expr| try collectExprBindThunks(ctx, expr),
        .@"defer", .expr, .assert => |expr| try collectExprBindThunks(ctx, expr),
        .assignment => |node| {
            try collectExprBindThunks(ctx, node.target);
            try collectExprBindThunks(ctx, node.value);
        },
        else => {},
    };
}

fn collectExprBindThunks(ctx: BindThunkContext, expr: ast.Expr) anyerror!void {
    switch (expr.kind) {
        .call => |node| {
            if (hasCallTargetFact(ctx.mir_function.*, .bind, expr.span)) try collectBindThunk(ctx, node);
            try collectExprBindThunks(ctx, node.callee.*);
            for (node.args) |arg| try collectExprBindThunks(ctx, arg);
        },
        .grouped, .address_of, .deref => |inner| try collectExprBindThunks(ctx, inner.*),
        .try_expr => |inner| try collectExprBindThunks(ctx, inner.operand.*),
        .unary => |node| try collectExprBindThunks(ctx, node.expr.*),
        .binary => |node| {
            try collectExprBindThunks(ctx, node.left.*);
            try collectExprBindThunks(ctx, node.right.*);
        },
        .index => |node| {
            try collectExprBindThunks(ctx, node.base.*);
            try collectExprBindThunks(ctx, node.index.*);
        },
        .member => |node| try collectExprBindThunks(ctx, node.base.*),
        .cast => |node| try collectExprBindThunks(ctx, node.value.*),
        .array_literal => |items| for (items) |item| try collectExprBindThunks(ctx, item),
        .struct_literal => |fields| for (fields) |field| try collectExprBindThunks(ctx, field.value),
        .block => |block| try collectBlockBindThunks(ctx, block),
        else => {},
    }
}

fn collectBindThunk(ctx: BindThunkContext, node: anytype) !void {
    if (node.type_args.len != 0 or node.args.len != 2) return error.UnsupportedCEmission;
    const fname = calleeIdentName(node.args[1]) orelse return;
    const info = ctx.functions.get(fname) orelse return;
    if (info.params.len == 0 or info.is_extern) return;
    if (bindEnvIsPointerLike(ctx.type_aliases, info.params[0].ty)) return;
    const name = try std.fmt.allocPrint(ctx.name_allocator, "mc_envthunk_{s}", .{fname});
    if (!ctx.bind_thunks.contains(name)) try ctx.bind_thunks.put(name, .{ .fname = fname, .info = info });
}

fn hasCallTargetFact(function: mir.Function, kind: mir.CallTargetKind, span: ast.Span) bool {
    for (function.call_target_facts) |fact| {
        if (fact.kind == kind and fact.source.line == span.line and fact.source.column == span.column) return true;
    }
    return false;
}
