//! C backend MMIO emission helpers.
//!
//! These helpers spell MMIO-specific C read/barrier forms and the hoisting
//! shapes needed to preserve read ordering.

const std = @import("std");

const ast_bridge = @import("ast_bridge.zig");
const syntax_bridge = @import("syntax_bridge.zig");
const lower_c_access = @import("lower_c_access.zig");
const lower_c_arith = @import("lower_c_arith.zig");
const lower_c_atomic = @import("lower_c_atomic.zig");
const lower_c_call = @import("lower_c_call.zig");
const lower_c_global = @import("lower_c_global.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_op = @import("lower_c_op.zig");
const lower_c_shape = @import("lower_c_shape.zig");
const lower_c_try = @import("lower_c_try.zig");
const lower_c_type = @import("lower_c_type.zig");
const mir = @import("mir.zig");
const type_bridge = @import("type_bridge.zig");

const LocalInfo = lower_c_model.LocalInfo;
const FnInfo = lower_c_model.FnInfo;
const GlobalAccess = lower_c_model.GlobalAccess;
const MmioAccess = lower_c_model.MmioAccess;
const MmioReadReplacement = lower_c_model.MmioReadReplacement;
const PackedBitsInfo = lower_c_model.PackedBitsInfo;
const SequencedArgTemp = lower_c_model.SequencedArgTemp;
const appendGlobalStoreValue = lower_c_global.appendGlobalStoreValue;
const appendGlobalStorePrefix = lower_c_global.appendGlobalStorePrefix;
const appendGlobalStoreSuffix = lower_c_global.appendGlobalStoreSuffix;
const calleeIdentName = syntax_bridge.calleeIdentName;
const memberExpr = syntax_bridge.memberExpr;
const mmioFieldFromType = lower_c_shape.mmioFieldFromType;
const mmioFieldWidthBytes = lower_c_type.mmioFieldWidthBytes;
const orderingArg = lower_c_atomic.orderingArg;
const primitiveCTypeName = lower_c_type.primitiveCTypeName;

pub const Context = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: *usize,
};

pub const EmitExprFn = *const fn (ctx: *anyopaque, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void;
pub const EmitExprWithTargetFn = *const fn (ctx: *anyopaque, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast_bridge.TypeExpr) anyerror!void;
pub const CTypeFn = *const fn (ctx: *anyopaque, ty: ast_bridge.TypeExpr) anyerror![]const u8;
pub const EmitDeclaratorFn = *const fn (ctx: *anyopaque, ty: ast_bridge.TypeExpr, name: []const u8) anyerror!void;
pub const OperandEmitTypeFn = *const fn (ctx: *anyopaque, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr;
pub const GlobalAssignmentTargetFn = *const fn (ctx: *anyopaque, target: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) ?GlobalAccess;
pub const EmitAssignTargetFn = *const fn (ctx: *anyopaque, target: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void;
pub const EmitReadSequencedBinaryValueTempFn = *const fn (ctx: *anyopaque, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!?SequencedArgTemp;
pub const EmitSequencedArgTempFn = *const fn (ctx: *anyopaque, arg: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!SequencedArgTemp;
pub const MmioAccessFn = *const fn (ctx: *anyopaque, callee: ast_bridge.Expr, args: []const ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) ?MmioAccess;
pub const ValueCTypeFn = *const fn (ctx: *anyopaque, value_type: []const u8) []const u8;
pub const CIdentFn = *const fn (ctx: *anyopaque, name: []const u8) anyerror![]const u8;
pub const MirCallTargetKindFn = *const fn (ctx: *anyopaque, span: ast_bridge.Span) ?mir.CallTargetKind;
pub const MirTargetTypeFn = *const fn (ctx: *anyopaque, kind: mir.TargetTypeKind, span: ast_bridge.Span) ?ast_bridge.TypeExpr;
pub const MirOwnedTargetTypeFn = lower_c_call.MirOwnedTargetTypeFn;
pub const MirOwnedTargetValueTypeFn = lower_c_call.MirOwnedTargetValueTypeFn;
pub const EmitBlockItemsFn = *const fn (ctx: *anyopaque, block: ast_bridge.Block, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) anyerror!void;

pub const AccessContext = struct {
    packed_bits: *const std.StringHashMap(PackedBitsInfo),
    emit_ctx: *anyopaque,
    c_ident: CIdentFn,
    mir_call_target_kind: MirCallTargetKindFn,
    mir_target_type: MirTargetTypeFn,
};

pub const StructEmitContext = struct {
    context: Context,
    emit_ctx: *anyopaque,
    c_ident: CIdentFn,
};

pub const EmitContext = struct {
    context: Context,
    scratch: std.mem.Allocator,
    temp_index: *usize,
    emit_ctx: *anyopaque,
    emit_expr: EmitExprFn,
    emit_expr_with_target: EmitExprWithTargetFn,
    c_type: CTypeFn,
    c_ident: CIdentFn,
    mmio_access: MmioAccessFn,
    value_c_type: ValueCTypeFn,
    emit_sequenced_arg_temp: EmitSequencedArgTempFn,
    mir_call_target_kind: MirCallTargetKindFn,
    mir_target_type: MirTargetTypeFn,
    mir_owned_target_type: MirOwnedTargetTypeFn,
};

pub const ReplacementEmitContext = struct {
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    out: *std.ArrayList(u8),
    temp_index: *usize,
    type_aliases: *const std.StringHashMap(ast_bridge.TypeExpr),
    functions: *const std.StringHashMap(FnInfo),
    packed_bits: *const std.StringHashMap(PackedBitsInfo),
    emit_ctx: *anyopaque,
    emit_expr: EmitExprFn,
    emit_expr_with_target: EmitExprWithTargetFn,
    c_type: CTypeFn,
    emit_declarator: EmitDeclaratorFn,
    operand_emit_type: OperandEmitTypeFn,
    global_assignment_target: GlobalAssignmentTargetFn,
    emit_assign_target: EmitAssignTargetFn,
    emit_read_sequenced_binary_value_temp: EmitReadSequencedBinaryValueTempFn,
    mir_owned_target_type: MirOwnedTargetTypeFn,
    mir_owned_target_value_type: MirOwnedTargetValueTypeFn,
};

pub const CallEmitContext = struct {
    emit: EmitContext,
    replacement: ReplacementEmitContext,
    call_ctx: lower_c_call.TempContext,
    arith: lower_c_arith.Context,
};

pub const WhileEmitContext = struct {
    emit: EmitContext,
    replacement: ReplacementEmitContext,
    emit_ctx: *anyopaque,
    emit_block_items: EmitBlockItemsFn,
};

const ReadScanContext = struct {
    ctx: EmitContext,
    locals: *std.StringHashMap(LocalInfo),
};

const ReadHoistContext = struct {
    ctx: EmitContext,
    locals: *std.StringHashMap(LocalInfo),
    replacements: *std.ArrayList(MmioReadReplacement),
};

pub const DirectReadAccess = struct {
    access: MmioAccess,
    value_c_type: []const u8,
};

pub fn emitReadExprWithReplacements(
    ctx: ReplacementEmitContext,
    expr: ast_bridge.Expr,
    locals: ?*std.StringHashMap(LocalInfo),
    target_ty: ?ast_bridge.TypeExpr,
    replacements: []const MmioReadReplacement,
) anyerror!void {
    if (!lower_c_access.exprHasMmioReadReplacement(expr, replacements)) return ctx.emit_expr_with_target(ctx.emit_ctx, expr, locals, target_ty);
    if (lower_c_access.mmioReadReplacementForSpan(expr.span, replacements)) |replacement| {
        try ctx.out.appendSlice(ctx.allocator, replacement.temp_name);
        return;
    }

    switch (expr.kind) {
        .grouped => |inner| {
            try ctx.out.appendSlice(ctx.allocator, "(");
            try emitReadExprWithReplacements(ctx, inner.*, locals, target_ty, replacements);
            try ctx.out.appendSlice(ctx.allocator, ")");
        },
        .call => |node| {
            const fn_name = calleeIdentName(node.callee.*);
            const fn_info = if (fn_name) |name| ctx.functions.get(name) else null;
            try ctx.emit_expr(ctx.emit_ctx, node.callee.*, locals);
            try ctx.out.appendSlice(ctx.allocator, "(");
            for (node.args, 0..) |arg, i| {
                if (i != 0) try ctx.out.appendSlice(ctx.allocator, ", ");
                const arg_target_ty = if (fn_info) |info|
                    if (i < info.params.len) blk: {
                        const owner = fn_name orelse return error.UnsupportedCEmission;
                        const expected_ty = ctx.mir_owned_target_type(ctx.emit_ctx, .direct_call_argument, arg.span, owner, i) orelse return error.UnsupportedCEmission;
                        const target_value_ty = ctx.mir_owned_target_value_type(ctx.emit_ctx, .direct_call_argument, arg.span, owner, i) orelse return error.UnsupportedCEmission;
                        if (!mir.ValueType.eql(target_value_ty, info.params[i].value_ty)) return error.UnsupportedCEmission;
                        break :blk expected_ty;
                    } else if (!info.is_variadic)
                        return error.UnsupportedCEmission
                    else
                        null
                else
                    null;
                try emitReadExprWithReplacements(ctx, arg, locals, arg_target_ty, replacements);
            }
            try ctx.out.appendSlice(ctx.allocator, ")");
        },
        .unary => |node| {
            if (try emitCheckedUnaryReadReplacement(ctx, node, locals, target_ty, replacements)) return;
            try ctx.out.appendSlice(ctx.allocator, lower_c_op.unaryCOp(node.op));
            try ctx.out.appendSlice(ctx.allocator, "(");
            try emitReadExprWithReplacements(ctx, node.expr.*, locals, null, replacements);
            try ctx.out.appendSlice(ctx.allocator, ")");
        },
        .binary => |node| {
            if (lower_c_op.isCheckedBinaryOp(node.op)) {
                const target = target_ty orelse return error.UnsupportedCEmission;
                const target_name = type_bridge.typeName(target) orelse return error.UnsupportedCEmission;
                const helper = lower_c_op.checkedHelperParts(node.op, target_name) orelse return error.UnsupportedCEmission;
                try ctx.out.print(ctx.allocator, "{s}{s}(", .{ helper.prefix, helper.suffix });
                try emitReadExprWithReplacements(ctx, node.left.*, locals, target, replacements);
                try ctx.out.appendSlice(ctx.allocator, ", ");
                try emitReadExprWithReplacements(ctx, node.right.*, locals, target, replacements);
                try ctx.out.appendSlice(ctx.allocator, ")");
            } else {
                try ctx.out.appendSlice(ctx.allocator, "(");
                try emitReadExprWithReplacements(ctx, node.left.*, locals, null, replacements);
                try ctx.out.print(ctx.allocator, " {s} ", .{lower_c_op.binaryCOp(node.op)});
                try emitReadExprWithReplacements(ctx, node.right.*, locals, null, replacements);
                try ctx.out.appendSlice(ctx.allocator, ")");
            }
        },
        .index => |node| {
            try emitReadExprWithReplacements(ctx, node.base.*, locals, null, replacements);
            try ctx.out.appendSlice(ctx.allocator, "[");
            try emitReadExprWithReplacements(ctx, node.index.*, locals, null, replacements);
            try ctx.out.appendSlice(ctx.allocator, "]");
        },
        .member => |node| {
            if (lower_c_access.mmioReadReplacementValueTypeForExpr(node.base.*, replacements)) |base_ty| {
                if (ctx.packed_bits.get(base_ty)) |info| {
                    if (info.fields.get(node.name.text)) |field| {
                        try emitPackedBitsMaskTestWithReplacements(ctx, node.base.*, locals, info, field.bit_index, replacements);
                        return;
                    }
                }
            }
            try emitReadExprWithReplacements(ctx, node.base.*, locals, null, replacements);
            try ctx.out.print(ctx.allocator, ".{s}", .{node.name.text});
        },
        .cast => |node| {
            try ctx.out.print(ctx.allocator, "(({s})", .{try ctx.c_type(ctx.emit_ctx, node.ty.*)});
            try emitReadExprWithReplacements(ctx, node.value.*, locals, null, replacements);
            try ctx.out.appendSlice(ctx.allocator, ")");
        },
        else => try ctx.emit_expr_with_target(ctx.emit_ctx, expr, locals, target_ty),
    }
}

pub fn classifyAccess(ctx: AccessContext, callee: ast_bridge.Expr, args: []const ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) ?MmioAccess {
    _ = locals;
    const member = memberExpr(callee) orelse return null;
    const kind = accessKind(member.name.text) orelse return null;
    const expected: mir.CallTargetKind = if (std.mem.eql(u8, kind, "read")) .mmio_read else .mmio_write;
    if (ctx.mir_call_target_kind(ctx.emit_ctx, callee.span) != expected) return null;
    const reg_member = memberExpr(member.base.*) orelse return null;
    const param = calleeIdentName(reg_member.base.*) orelse return null;
    const struct_ty = ctx.mir_target_type(ctx.emit_ctx, .mmio_struct, callee.span) orelse return null;
    const storage_ty = ctx.mir_target_type(ctx.emit_ctx, .mmio_storage, callee.span) orelse return null;
    const value_ty = ctx.mir_target_type(ctx.emit_ctx, .mmio_value, callee.span) orelse return null;
    _ = ctx.mir_target_type(ctx.emit_ctx, .mmio_result, callee.span) orelse return null;
    const struct_name = type_bridge.typeName(struct_ty) orelse return null;
    const width = type_bridge.typeName(storage_ty) orelse return null;
    const value_type = type_bridge.typeName(value_ty) orelse return null;
    return .{
        .kind = kind,
        .param = param,
        .struct_name = struct_name,
        .field = ctx.c_ident(ctx.emit_ctx, reg_member.name.text) catch reg_member.name.text,
        .value_type = value_type,
        .width = width,
        .ordering = orderingArg(args),
    };
}

pub fn valueCType(ctx: AccessContext, value_type: []const u8) []const u8 {
    if (ctx.packed_bits.contains(value_type)) return value_type;
    return primitiveCTypeName(value_type) orelse "uint8_t";
}

pub fn emitStruct(ctx: StructEmitContext, struct_decl: ast_bridge.StructDecl) !void {
    try ctx.context.out.print(ctx.context.allocator, "typedef struct {s} {{\n", .{struct_decl.name.text});
    ctx.context.indent.* += 1;
    var running: u64 = 0;
    var pad_n: usize = 0;
    for (struct_decl.fields) |field| {
        try emitStructField(ctx, field, &running, &pad_n);
    }
    ctx.context.indent.* -= 1;
    try ctx.context.out.print(ctx.context.allocator, "}} {s};\n\n", .{struct_decl.name.text});
}

fn accessKind(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "read")) return "read";
    if (std.mem.eql(u8, name, "write")) return "write";
    return null;
}

fn emitStructField(ctx: StructEmitContext, field: ast_bridge.Field, running: *u64, pad_n: *usize) !void {
    const info = mmioFieldFromType(field.ty) orelse {
        try writeIndent(ctx.context);
        try ctx.context.out.print(ctx.context.allocator, "/* unsupported MMIO field: {s} */\n", .{field.name.text});
        return error.UnsupportedCEmission;
    };
    try emitFieldPadding(ctx.context, field, running, pad_n);
    try writeIndent(ctx.context);
    try ctx.context.out.print(ctx.context.allocator, "{s} volatile {s};\n", .{ primitiveCTypeName(info.width) orelse "void *", try ctx.c_ident(ctx.emit_ctx, field.name.text) });
    running.* += mmioFieldWidthBytes(info.width);
}

fn emitFieldPadding(ctx: Context, field: ast_bridge.Field, running: *u64, pad_n: *usize) !void {
    const offset = field.offset orelse return;
    if (offset < running.*) return error.UnsupportedCEmission;
    if (offset == running.*) return;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "uint8_t _pad{d}[{d}];\n", .{ pad_n.*, offset - running.* });
    pad_n.* += 1;
    running.* = offset;
}

fn emitCheckedUnaryReadReplacement(ctx: ReplacementEmitContext, node: anytype, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast_bridge.TypeExpr, replacements: []const MmioReadReplacement) anyerror!bool {
    if (node.op != .neg) return false;
    const target = if (target_ty) |ty| type_bridge.resolveAliasType(ctx.type_aliases, ty) else return error.UnsupportedCEmission;
    if (type_bridge.isWrapType(target) or type_bridge.isSatType(target)) return false;
    const target_name = type_bridge.typeName(target) orelse return error.UnsupportedCEmission;
    const suffix = lower_c_type.signedTypeSuffix(target_name) orelse return false;

    try ctx.out.print(ctx.allocator, "mc_checked_neg_{s}(", .{suffix});
    try emitReadExprWithReplacements(ctx, node.expr.*, locals, target, replacements);
    try ctx.out.appendSlice(ctx.allocator, ")");
    return true;
}

fn emitPackedBitsMaskTestWithReplacements(ctx: ReplacementEmitContext, base: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), info: PackedBitsInfo, bit_index: usize, replacements: []const MmioReadReplacement) !void {
    try ctx.out.appendSlice(ctx.allocator, "((");
    try emitReadExprWithReplacements(ctx, base, locals, null, replacements);
    try ctx.out.print(ctx.allocator, " & {s}) != 0)", .{try lower_c_access.packedBitsMaskLiteral(ctx.scratch, info, bit_index)});
}

pub fn emitMmioMapCall(ctx: EmitContext, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
    if (ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) != .mmio_map) return false;
    if (call.type_args.len != 1 or call.args.len != 1) return error.UnsupportedCEmission;
    const source_ty = ctx.mir_target_type(ctx.emit_ctx, .mmio_map_source, call.callee.*.span) orelse return error.UnsupportedCEmission;
    const payload_ty = ctx.mir_target_type(ctx.emit_ctx, .mmio_map_payload, call.callee.*.span) orelse return error.UnsupportedCEmission;
    _ = ctx.mir_target_type(ctx.emit_ctx, .mmio_map_result, call.callee.*.span) orelse return error.UnsupportedCEmission;
    try ctx.context.out.print(ctx.context.allocator, "(({s})", .{try ctx.c_type(ctx.emit_ctx, payload_ty)});
    try ctx.emit_expr_with_target(ctx.emit_ctx, call.args[0], locals, source_ty);
    try ctx.context.out.appendSlice(ctx.context.allocator, ")");
    return true;
}

pub fn emitInlineReadCall(ctx: EmitContext, call: anytype, locals_opt: ?*std.StringHashMap(LocalInfo)) !bool {
    const locals = locals_opt orelse return false;
    const read = (try directReadAccess(ctx, call, locals)) orelse return false;
    try appendInlineReadExpr(ctx.context, read.value_c_type, read.access);
    return true;
}

pub fn emitWriteStmt(ctx: EmitContext, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const call = syntax_bridge.callExpr(expr) orelse return false;
    return emitWriteCall(ctx, call.callee.*, call.args, locals);
}

pub fn emitWriteCall(ctx: EmitContext, callee: ast_bridge.Expr, args: []const ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const access = ctx.mmio_access(ctx.emit_ctx, callee, args, locals) orelse return false;
    if (!std.mem.eql(u8, access.kind, "write")) return false;
    if (primitiveCTypeName(access.width) == null) return error.UnsupportedCEmission;
    if (args.len == 0) return error.UnsupportedCEmission;

    const value_ty = type_bridge.simpleNameType(access.value_type, args[0].span);
    const value_temp = try ctx.emit_sequenced_arg_temp(ctx.emit_ctx, args[0], locals, value_ty);
    if (std.mem.eql(u8, access.ordering, "release")) {
        try writeIndent(ctx.context);
        try ctx.context.out.appendSlice(ctx.context.allocator, "mc_barrier_release_before();\n");
    }
    try writeIndent(ctx.context);
    try ctx.context.out.print(ctx.context.allocator, "mc_mmio_write_{s}(&{s}->{s}, {s});\n", .{ access.width, access.param, access.field, value_temp.name });
    return true;
}

pub fn emitReadCallStmt(ctx: EmitContext, callee: ast_bridge.Expr, args: []const ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const access = ctx.mmio_access(ctx.emit_ctx, callee, args, locals) orelse return false;
    if (!std.mem.eql(u8, access.kind, "read")) return false;
    if (primitiveCTypeName(access.width) == null) return error.UnsupportedCEmission;
    if (args.len != 1) return error.UnsupportedCEmission;

    try writeIndent(ctx.context);
    try appendReadExpr(ctx.context, ctx.value_c_type(ctx.emit_ctx, access.value_type), access);
    try ctx.context.out.appendSlice(ctx.context.allocator, ";\n");
    try emitAcquireBarrierIfNeeded(ctx.context, access);
    return true;
}

pub fn emitDirectReadReturn(ctx: EmitContext, call: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
    const read = (try directReadAccess(ctx, call, locals)) orelse return false;

    if (std.mem.eql(u8, read.access.ordering, "acquire")) {
        const temp_name = try std.fmt.allocPrint(ctx.scratch, "mc_tmp{d}", .{ctx.temp_index.*});
        ctx.temp_index.* += 1;
        try emitReadDecl(ctx.context, read.value_c_type, temp_name, read.access);
        try emitAcquireBarrierIfNeeded(ctx.context, read.access);
        try writeIndent(ctx.context);
        try ctx.context.out.print(ctx.context.allocator, "return {s};\n", .{temp_name});
    } else {
        try emitReadReturn(ctx.context, read.value_c_type, read.access);
    }
    return true;
}

pub fn emitDirectReadReturnExpr(ctx: EmitContext, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const call = syntax_bridge.callExpr(expr) orelse return false;
    return emitDirectReadReturn(ctx, call, locals);
}

pub fn emitDirectReadLocalInit(ctx: EmitContext, name: []const u8, decl_ty: ast_bridge.TypeExpr, call: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
    const read = (try directReadAccess(ctx, call, locals)) orelse return false;

    try writeIndent(ctx.context);
    try ctx.context.out.print(ctx.context.allocator, "{s} {s} = ", .{ try ctx.c_type(ctx.emit_ctx, decl_ty), try ctx.c_ident(ctx.emit_ctx, name) });
    try appendReadExpr(ctx.context, try ctx.c_type(ctx.emit_ctx, decl_ty), read.access);
    try ctx.context.out.appendSlice(ctx.context.allocator, ";\n");
    try emitAcquireBarrierIfNeeded(ctx.context, read.access);
    return true;
}

pub fn emitDirectReadLocalInitExpr(ctx: EmitContext, name: []const u8, decl_ty: ast_bridge.TypeExpr, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const call = syntax_bridge.callExpr(initializer) orelse return false;
    return emitDirectReadLocalInit(ctx, name, decl_ty, call, locals);
}

pub fn emitDirectReadAssignment(ctx: EmitContext, replacement_ctx: ReplacementEmitContext, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
    const call = syntax_bridge.callExpr(assignment.value) orelse return false;
    const read = (try directReadAccess(ctx, call, locals)) orelse return false;

    const temp_name = try std.fmt.allocPrint(ctx.scratch, "mc_tmp{d}", .{ctx.temp_index.*});
    ctx.temp_index.* += 1;
    try emitReadDecl(ctx.context, read.value_c_type, temp_name, read.access);
    try emitAcquireBarrierIfNeeded(ctx.context, read.access);
    try emitAssignmentFromTemp(ctx.context, replacement_ctx, assignment.target, locals, temp_name);
    return true;
}

pub fn emitDirectReadInferredLocalInit(ctx: EmitContext, name: []const u8, initializer_span: ast_bridge.Span, call: anytype, locals: *std.StringHashMap(LocalInfo)) !?LocalInfo {
    const read = (try directReadAccess(ctx, call, locals)) orelse return null;
    const inferred_ty = ctx.mir_owned_target_type(ctx.emit_ctx, .inferred_local, initializer_span, name, null) orelse return error.UnsupportedCEmission;
    const inferred_c_type = try ctx.c_type(ctx.emit_ctx, inferred_ty);
    if (!std.mem.eql(u8, inferred_c_type, read.value_c_type)) return error.UnsupportedCEmission;
    const source_type_name = type_bridge.typeName(inferred_ty) orelse return error.UnsupportedCEmission;

    try emitReadDecl(ctx.context, inferred_c_type, name, read.access);
    try emitAcquireBarrierIfNeeded(ctx.context, read.access);
    return .{
        .c_type = inferred_c_type,
        .source_type_name = source_type_name,
    };
}

pub fn emitDirectReadInferredLocalInitExpr(ctx: EmitContext, name: []const u8, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const call = syntax_bridge.callExpr(initializer) orelse return false;
    const info = (try emitDirectReadInferredLocalInit(ctx, name, initializer.span, call, locals)) orelse return false;
    try locals.put(name, info);
    return true;
}

pub fn directReadAccess(ctx: EmitContext, call: anytype, locals: *std.StringHashMap(LocalInfo)) !?DirectReadAccess {
    const access = ctx.mmio_access(ctx.emit_ctx, call.callee.*, call.args, locals) orelse return null;
    if (!std.mem.eql(u8, access.kind, "read")) return null;
    if (primitiveCTypeName(access.width) == null) return error.UnsupportedCEmission;
    return .{
        .access = access,
        .value_c_type = ctx.value_c_type(ctx.emit_ctx, access.value_type),
    };
}

pub fn exprContainsRead(ctx: EmitContext, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) bool {
    var scan_ctx = ReadScanContext{ .ctx = ctx, .locals = locals };
    return lower_c_try.exprContainsCall(&scan_ctx, expr, scanReadCall);
}

pub fn argsContainRead(ctx: EmitContext, args: []const ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) bool {
    var scan_ctx = ReadScanContext{ .ctx = ctx, .locals = locals };
    return lower_c_try.argsContainCall(&scan_ctx, args, scanReadCall);
}

pub fn countReads(ctx: EmitContext, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) usize {
    var scan_ctx = ReadScanContext{ .ctx = ctx, .locals = locals };
    return lower_c_try.countCalls(&scan_ctx, expr, scanReadCall);
}

pub fn collectReadHoistsForExpr(ctx: EmitContext, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), replacements: *std.ArrayList(MmioReadReplacement)) !bool {
    var hoist_ctx = ReadHoistContext{ .ctx = ctx, .locals = locals, .replacements = replacements };
    return lower_c_try.collectCallHoists(&hoist_ctx, expr, collectReadCall, guardLogicalBinary);
}

fn scanReadCall(ctx_ptr: *anyopaque, expr: ast_bridge.Expr) lower_c_try.CallScanResult {
    const ctx: *ReadScanContext = @ptrCast(@alignCast(ctx_ptr));
    const node = switch (expr.kind) {
        .call => |call| call,
        else => return .ignored,
    };
    const access = ctx.ctx.mmio_access(ctx.ctx.emit_ctx, node.callee.*, node.args, ctx.locals) orelse return .descend;
    return if (std.mem.eql(u8, access.kind, "read")) .found else .ignored;
}

fn collectReadCall(ctx_ptr: *anyopaque, expr: ast_bridge.Expr) anyerror!lower_c_try.CallHoistResult {
    const ctx: *ReadHoistContext = @ptrCast(@alignCast(ctx_ptr));
    const node = switch (expr.kind) {
        .call => |call| call,
        else => return .ignored,
    };
    const access = ctx.ctx.mmio_access(ctx.ctx.emit_ctx, node.callee.*, node.args, ctx.locals) orelse return .descend;
    if (!std.mem.eql(u8, access.kind, "read")) return .ignored;
    if (primitiveCTypeName(access.width) == null) return error.UnsupportedCEmission;

    try appendReadReplacement(ctx, .{ .line = expr.span.line, .column = expr.span.column, .offset = expr.span.offset, .len = expr.span.len }, access);
    return .hoisted;
}

fn appendReadReplacement(ctx: *ReadHoistContext, source: mir.SourcePoint, access: MmioAccess) !void {
    const temp_name = try std.fmt.allocPrint(ctx.ctx.scratch, "mc_tmp{d}", .{ctx.ctx.temp_index.*});
    ctx.ctx.temp_index.* += 1;
    try ctx.replacements.append(ctx.ctx.scratch, .{
        .source = source,
        .temp_name = temp_name,
        .source_type_name = access.value_type,
        .c_type = ctx.ctx.value_c_type(ctx.ctx.emit_ctx, access.value_type),
        .access = access,
    });
}

fn guardLogicalBinary(ctx_ptr: *anyopaque, expr: ast_bridge.Expr) anyerror!?bool {
    const ctx: *ReadHoistContext = @ptrCast(@alignCast(ctx_ptr));
    const node = switch (expr.kind) {
        .binary => |binary| binary,
        else => return null,
    };
    if (isLogicalBinaryOp(node.op)) {
        if (logicalOperandHasSequencingHazard(ctx.ctx, node, ctx.locals)) return error.UnsupportedCEmission;
        return false;
    }
    return null;
}

fn isLogicalBinaryOp(op: ast_bridge.BinaryOp) bool {
    return op == .logical_and or op == .logical_or;
}

fn logicalOperandHasSequencingHazard(ctx: EmitContext, node: anytype, locals: *std.StringHashMap(LocalInfo)) bool {
    return countReads(ctx, node.left.*, locals) > 1 or countReads(ctx, node.right.*, locals) > 1;
}

pub fn emitReadDecl(ctx: Context, c_type: []const u8, name: []const u8, access: MmioAccess) !void {
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = ", .{ c_type, name });
    try appendReadExpr(ctx, c_type, access);
    try ctx.out.appendSlice(ctx.allocator, ";\n");
}

pub fn emitReadReplacement(ctx: Context, replacement: MmioReadReplacement) !void {
    try emitReadDecl(ctx, replacement.c_type, replacement.temp_name, replacement.access);
    try emitAcquireBarrierIfNeeded(ctx, replacement.access);
}

pub fn emitReadReplacements(ctx: Context, replacements: []const MmioReadReplacement) !void {
    for (replacements) |replacement| {
        try emitReadReplacement(ctx, replacement);
    }
}

pub fn readReplacementNestedLocals(allocator: std.mem.Allocator, locals: std.StringHashMap(LocalInfo), replacements: []const MmioReadReplacement) !std.StringHashMap(LocalInfo) {
    var nested = try lower_c_access.cloneLocals(allocator, locals);
    errdefer nested.deinit();
    try lower_c_access.addMmioReadReplacementLocals(&nested, replacements);
    return nested;
}

pub fn emitReadReplacementFrame(ctx: Context, locals: std.StringHashMap(LocalInfo), replacements: []const MmioReadReplacement) !std.StringHashMap(LocalInfo) {
    try emitReadReplacements(ctx, replacements);
    return try readReplacementNestedLocals(ctx.allocator, locals, replacements);
}

pub fn emitReadAssertWithReplacements(ctx: Context, replacement_ctx: ReplacementEmitContext, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), replacements: []const MmioReadReplacement) !void {
    var nested = try emitReadReplacementFrame(ctx, locals.*, replacements);
    defer nested.deinit();

    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "if (!(");
    try emitReadExprWithReplacements(replacement_ctx, expr, &nested, null, replacements);
    try ctx.out.appendSlice(ctx.allocator, ")) mc_trap_Assert();\n");
}

pub fn emitReadAssert(ctx: CallEmitContext, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    var replacements: std.ArrayList(MmioReadReplacement) = .empty;
    defer replacements.deinit(ctx.emit.scratch);
    if (!try collectReadHoistsForExpr(ctx.emit, expr, locals, &replacements)) return false;

    try emitReadAssertWithReplacements(ctx.emit.context, ctx.replacement, expr, locals, replacements.items);
    return true;
}

pub fn emitReadWhileLoop(ctx: WhileEmitContext, loop: ast_bridge.Loop, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) !bool {
    const condition = loop.iterable orelse return false;
    var replacements: std.ArrayList(MmioReadReplacement) = .empty;
    defer replacements.deinit(ctx.emit.scratch);
    if (!try collectReadHoistsForExpr(ctx.emit, condition, locals, &replacements)) return false;

    try writeIndent(ctx.emit.context);
    try ctx.emit.context.out.appendSlice(ctx.emit.context.allocator, "while (true) {\n");
    ctx.emit.context.indent.* += 1;
    var nested = try emitReadReplacementFrame(ctx.emit.context, locals.*, replacements.items);
    defer nested.deinit();
    try emitReadWhileGuard(ctx.emit.context, ctx.replacement, condition, &nested, replacements.items);
    try ctx.emit_block_items(ctx.emit_ctx, loop.body, &nested, return_ty);
    ctx.emit.context.indent.* -= 1;
    try writeIndent(ctx.emit.context);
    try ctx.emit.context.out.appendSlice(ctx.emit.context.allocator, "}\n");
    return true;
}

fn emitReadWhileGuard(ctx: Context, replacement_ctx: ReplacementEmitContext, condition: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), replacements: []const MmioReadReplacement) !void {
    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "if (!(");
    try emitReadExprWithReplacements(replacement_ctx, condition, locals, null, replacements);
    try ctx.out.appendSlice(ctx.allocator, ")) break;\n");
}

pub fn emitReadExprStmtWithReplacements(ctx: Context, replacement_ctx: ReplacementEmitContext, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), replacements: []const MmioReadReplacement) !void {
    var nested = try emitReadReplacementFrame(ctx, locals.*, replacements);
    defer nested.deinit();

    try writeIndent(ctx);
    if (lower_c_access.mmioReadReplacementForSpan(expr.span, replacements)) |replacement| {
        try ctx.out.print(ctx.allocator, "(void){s};\n", .{replacement.temp_name});
    } else {
        try emitReadExprWithReplacements(replacement_ctx, expr, &nested, null, replacements);
        try ctx.out.appendSlice(ctx.allocator, ";\n");
    }
}

pub fn emitReadExprStmt(ctx: CallEmitContext, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    if (try emitReadCallExprStmt(ctx, expr, locals)) return true;

    var replacements: std.ArrayList(MmioReadReplacement) = .empty;
    defer replacements.deinit(ctx.emit.scratch);
    if (!try collectReadHoistsForExpr(ctx.emit, expr, locals, &replacements)) return false;

    try emitReadExprStmtWithReplacements(ctx.emit.context, ctx.replacement, expr, locals, replacements.items);
    return true;
}

pub fn emitReadReturnWithReplacements(ctx: Context, replacement_ctx: ReplacementEmitContext, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr, replacements: []const MmioReadReplacement) !void {
    var nested = try emitReadReplacementFrame(ctx, locals.*, replacements);
    defer nested.deinit();

    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "return ");
    try emitReadExprWithReplacements(replacement_ctx, expr, &nested, return_ty, replacements);
    try ctx.out.appendSlice(ctx.allocator, ";\n");
}

pub fn emitReadExprReturn(ctx: CallEmitContext, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) !bool {
    if (return_ty) |target_ty| {
        if (try emitReadSequencedBinaryReturn(ctx.emit.context, ctx.replacement, expr, locals, target_ty)) return true;
    }

    var replacements: std.ArrayList(MmioReadReplacement) = .empty;
    defer replacements.deinit(ctx.emit.scratch);
    if (!try collectReadHoistsForExpr(ctx.emit, expr, locals, &replacements)) return false;

    try emitReadReturnWithReplacements(ctx.emit.context, ctx.replacement, expr, locals, return_ty, replacements.items);
    return true;
}

pub fn emitReadCallReturn(ctx: CallEmitContext, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const call = syntax_bridge.callExpr(expr) orelse return false;
    if (call.args.len == 0) return false;
    if (!argsContainRead(ctx.emit, call.args, locals)) return false;

    const fn_info = if (calleeIdentName(call.callee.*)) |name| ctx.replacement.functions.get(name) orelse return false else return false;
    if (!fn_info.acceptsArgCount(call.args.len)) return false;

    var temps = try emitReadCallArgTemps(ctx, call, locals, fn_info);
    defer temps.deinit(ctx.emit.scratch);

    try lower_c_call.emitSequencedCallReturnValue(ctx.call_ctx, call, locals, temps.items);
    return true;
}

pub fn emitReadLocalInitWithReplacements(ctx: Context, replacement_ctx: ReplacementEmitContext, name: []const u8, decl_ty: ast_bridge.TypeExpr, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), replacements: []const MmioReadReplacement) !void {
    var nested = try emitReadReplacementFrame(ctx, locals.*, replacements);
    defer nested.deinit();

    try writeIndent(ctx);
    try replacement_ctx.emit_declarator(replacement_ctx.emit_ctx, decl_ty, name);
    try ctx.out.appendSlice(ctx.allocator, " = ");
    try emitReadExprWithReplacements(replacement_ctx, initializer, &nested, decl_ty, replacements);
    try ctx.out.appendSlice(ctx.allocator, ";\n");
}

pub fn emitReadExprLocalInit(ctx: CallEmitContext, name: []const u8, decl_ty: ast_bridge.TypeExpr, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    if (try emitReadSequencedBinaryLocalInit(ctx.emit.context, ctx.replacement, name, decl_ty, initializer, locals)) return true;
    if (try emitReadCallLocalInit(ctx, name, decl_ty, initializer, locals)) return true;

    var replacements: std.ArrayList(MmioReadReplacement) = .empty;
    defer replacements.deinit(ctx.emit.scratch);
    if (!try collectReadHoistsForExpr(ctx.emit, initializer, locals, &replacements)) return false;

    try emitReadLocalInitWithReplacements(ctx.emit.context, ctx.replacement, name, decl_ty, initializer, locals, replacements.items);
    return true;
}

pub fn emitReadCallLocalInit(ctx: CallEmitContext, name: []const u8, decl_ty: ast_bridge.TypeExpr, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const call = syntax_bridge.callExpr(initializer) orelse return false;
    if (!argsContainRead(ctx.emit, call.args, locals)) return false;
    const fn_info = if (calleeIdentName(call.callee.*)) |callee_name| ctx.replacement.functions.get(callee_name) orelse return false else return false;
    if (!fn_info.acceptsArgCount(call.args.len)) return false;

    var temps = try emitReadCallArgTemps(ctx, call, locals, fn_info);
    defer temps.deinit(ctx.emit.scratch);

    try lower_c_call.emitSequencedCallLocalValue(ctx.call_ctx, name, decl_ty, call, locals, temps.items, true);
    return true;
}

pub fn emitReadCallAssignment(ctx: CallEmitContext, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
    const call = syntax_bridge.callExpr(assignment.value) orelse return false;
    if (!argsContainRead(ctx.emit, call.args, locals)) return false;
    const fn_info = if (calleeIdentName(call.callee.*)) |callee_name| ctx.replacement.functions.get(callee_name) orelse return false else return false;
    const owner = calleeIdentName(call.callee.*) orelse return false;
    const call_return_ty = ctx.call_ctx.mir_owned_target_type(ctx.call_ctx.emit_ctx, .direct_call_result, call.callee.*.span, owner, null) orelse return false;
    const call_return_value_ty = ctx.call_ctx.mir_owned_target_value_type(ctx.call_ctx.emit_ctx, .direct_call_result, call.callee.*.span, owner, null) orelse return false;
    if (!mir.ValueType.eql(call_return_value_ty, fn_info.return_ty) or lower_c_type.isVoidType(call_return_ty) or !fn_info.acceptsArgCount(call.args.len)) return false;

    var temps = try emitReadCallArgTemps(ctx, call, locals, fn_info);
    defer temps.deinit(ctx.emit.scratch);

    const result_temp = try lower_c_call.emitSequencedCallResultTemp(ctx.call_ctx, call, call_return_ty, locals, temps.items);
    try emitAssignmentFromTemp(ctx.emit.context, ctx.replacement, assignment.target, locals, result_temp);
    return true;
}

pub fn emitReadCallExprStmt(ctx: CallEmitContext, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const call = syntax_bridge.callExpr(expr) orelse return false;
    if (!argsContainRead(ctx.emit, call.args, locals)) return false;
    const fn_info = if (calleeIdentName(call.callee.*)) |callee_name| ctx.replacement.functions.get(callee_name) orelse return false else return false;
    if (!fn_info.acceptsArgCount(call.args.len)) return false;

    var temps = try emitReadCallArgTemps(ctx, call, locals, fn_info);
    defer temps.deinit(ctx.emit.scratch);

    try lower_c_call.emitSequencedCallExprStmtValue(ctx.call_ctx, call, locals, temps.items);
    return true;
}

pub fn emitReadAssignmentWithReplacements(ctx: Context, replacement_ctx: ReplacementEmitContext, assignment: anytype, locals: *std.StringHashMap(LocalInfo), replacements: []const MmioReadReplacement) !void {
    var nested = try emitReadReplacementFrame(ctx, locals.*, replacements);
    defer nested.deinit();

    try writeIndent(ctx);
    try emitReadReplacementAssignment(ctx, replacement_ctx, assignment.target, locals, &nested, assignment.value, replacements);
}

pub fn emitReadExprAssignment(ctx: CallEmitContext, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
    if (try emitReadSequencedBinaryAssignment(ctx.emit.context, ctx.replacement, assignment, locals)) return true;
    if (try emitReadCallAssignment(ctx, assignment, locals)) return true;

    var replacements: std.ArrayList(MmioReadReplacement) = .empty;
    defer replacements.deinit(ctx.emit.scratch);
    if (!try collectReadHoistsForExpr(ctx.emit, assignment.value, locals, &replacements)) return false;

    try emitReadAssignmentWithReplacements(ctx.emit.context, ctx.replacement, assignment, locals, replacements.items);
    return true;
}

pub fn emitReadSequencedBinaryReturn(ctx: Context, replacement_ctx: ReplacementEmitContext, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) !bool {
    const temp = (try replacement_ctx.emit_read_sequenced_binary_value_temp(replacement_ctx.emit_ctx, expr, locals, target_ty)) orelse return false;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "return {s};\n", .{temp.name});
    return true;
}

pub fn emitReadSequencedBinaryLocalInit(ctx: Context, replacement_ctx: ReplacementEmitContext, name: []const u8, decl_ty: ast_bridge.TypeExpr, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const temp = (try replacement_ctx.emit_read_sequenced_binary_value_temp(replacement_ctx.emit_ctx, initializer, locals, decl_ty)) orelse return false;
    try writeIndent(ctx);
    try replacement_ctx.emit_declarator(replacement_ctx.emit_ctx, decl_ty, name);
    try ctx.out.print(ctx.allocator, " = {s};\n", .{temp.name});
    return true;
}

pub fn emitReadSequencedBinaryAssignment(ctx: Context, replacement_ctx: ReplacementEmitContext, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
    const target_ty = assignmentTargetType(replacement_ctx, assignment, locals) orelse return false;
    const temp = (try replacement_ctx.emit_read_sequenced_binary_value_temp(replacement_ctx.emit_ctx, assignment.value, locals, target_ty)) orelse return false;
    try emitAssignmentFromTemp(ctx, replacement_ctx, assignment.target, locals, temp.name);
    return true;
}

pub fn emitReadOperandTempWithReplacements(ctx: EmitContext, replacement_ctx: ReplacementEmitContext, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr, replacements: []const MmioReadReplacement) !SequencedArgTemp {
    var nested = try emitReadReplacementFrame(ctx.context, locals.*, replacements);
    defer nested.deinit();

    const temp_name = try std.fmt.allocPrint(ctx.scratch, "mc_tmp{d}", .{ctx.temp_index.*});
    ctx.temp_index.* += 1;
    try writeIndent(ctx.context);
    try ctx.context.out.print(ctx.context.allocator, "{s} {s} = ", .{ try ctx.c_type(ctx.emit_ctx, target_ty), temp_name });
    try emitReadExprWithReplacements(replacement_ctx, expr, &nested, target_ty, replacements);
    try ctx.context.out.appendSlice(ctx.context.allocator, ";\n");
    return .{ .name = temp_name, .ty = target_ty };
}

pub fn emitReadOperandTemp(ctx: CallEmitContext, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) !SequencedArgTemp {
    var replacements: std.ArrayList(MmioReadReplacement) = .empty;
    defer replacements.deinit(ctx.emit.scratch);
    _ = try collectReadHoistsForExpr(ctx.emit, expr, locals, &replacements);

    return emitReadOperandTempWithReplacements(ctx.emit, ctx.replacement, expr, locals, target_ty, replacements.items);
}

pub fn emitReadSequencedBinaryValueTemp(ctx: CallEmitContext, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!?SequencedArgTemp {
    var seq_ctx = ctx;
    return lower_c_arith.emitSequencedBinaryValueTemp(.{
        .arith = ctx.arith,
        .emit_ctx = &seq_ctx,
        .expr_needs_sequenced_binary = readExprNeedsSequencedBinary,
        .emit_operand_temp = emitReadSequencedBinaryOperandTemp,
    }, expr, locals, target_ty);
}

fn readExprNeedsSequencedBinary(ctx_ptr: *anyopaque, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!bool {
    const ctx: *CallEmitContext = @ptrCast(@alignCast(ctx_ptr));
    return exprContainsRead(ctx.emit, expr, locals);
}

fn emitReadSequencedBinaryOperandTemp(ctx_ptr: *anyopaque, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!SequencedArgTemp {
    const ctx: *CallEmitContext = @ptrCast(@alignCast(ctx_ptr));
    return emitReadOperandTemp(ctx.*, expr, locals, target_ty);
}

fn assignmentTargetType(ctx: ReplacementEmitContext, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr {
    return ctx.operand_emit_type(ctx.emit_ctx, assignment.target, locals) orelse blk: {
        const target = ctx.global_assignment_target(ctx.emit_ctx, assignment.target, locals) orelse return null;
        break :blk type_bridge.simpleNameType(target.info.type_name, assignment.value.span);
    };
}

fn emitReadCallArgTemp(ctx: CallEmitContext, arg: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!SequencedArgTemp {
    if (!exprContainsRead(ctx.emit, arg, locals)) {
        return try ctx.emit.emit_sequenced_arg_temp(ctx.emit.emit_ctx, arg, locals, target_ty);
    }

    return try emitReadOperandTemp(ctx, arg, locals, target_ty);
}

fn emitReadCallArgTemps(ctx: CallEmitContext, call: anytype, locals: *std.StringHashMap(LocalInfo), fn_info: FnInfo) anyerror!std.ArrayList(SequencedArgTemp) {
    var temps: std.ArrayList(SequencedArgTemp) = .empty;
    errdefer temps.deinit(ctx.emit.scratch);
    const target_owner = calleeIdentName(call.callee.*) orelse return error.UnsupportedCEmission;
    for (call.args, 0..) |arg, i| {
        const target_ty = ctx.call_ctx.mir_owned_target_type(ctx.call_ctx.emit_ctx, .direct_call_argument, arg.span, target_owner, i) orelse return error.UnsupportedCEmission;
        if (i < fn_info.params.len) {
            const value_ty = ctx.call_ctx.mir_owned_target_value_type(ctx.call_ctx.emit_ctx, .direct_call_argument, arg.span, target_owner, i) orelse return error.UnsupportedCEmission;
            if (!mir.ValueType.eql(value_ty, fn_info.params[i].value_ty)) return error.UnsupportedCEmission;
        } else if (!fn_info.is_variadic) return error.UnsupportedCEmission;
        try temps.append(ctx.emit.scratch, try emitReadCallArgTemp(ctx, arg, locals, target_ty));
    }
    return temps;
}

fn emitAssignmentFromTemp(ctx: Context, replacement_ctx: ReplacementEmitContext, target: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), temp_name: []const u8) !void {
    try writeIndent(ctx);
    if (replacement_ctx.global_assignment_target(replacement_ctx.emit_ctx, target, locals)) |global_target| {
        try appendGlobalStoreValue(ctx.allocator, ctx.out, global_target, temp_name);
    } else {
        try replacement_ctx.emit_assign_target(replacement_ctx.emit_ctx, target, locals);
        try ctx.out.print(ctx.allocator, " = {s};\n", .{temp_name});
    }
}

fn emitInlineReadAssignment(ctx: Context, replacement_ctx: ReplacementEmitContext, target: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), value_c_type: []const u8, access: MmioAccess) !void {
    try writeIndent(ctx);
    try replacement_ctx.emit_assign_target(replacement_ctx.emit_ctx, target, locals);
    try ctx.out.appendSlice(ctx.allocator, " = ");
    try appendReadExpr(ctx, value_c_type, access);
    try ctx.out.appendSlice(ctx.allocator, ";\n");
}

fn emitReadReplacementAssignment(ctx: Context, replacement_ctx: ReplacementEmitContext, target_expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), nested: *std.StringHashMap(LocalInfo), value: ast_bridge.Expr, replacements: []const MmioReadReplacement) !void {
    const target_ty = assignmentTargetType(replacement_ctx, .{ .target = target_expr, .value = value }, locals) orelse return error.UnsupportedCEmission;
    const temp_name = try std.fmt.allocPrint(replacement_ctx.scratch, "mc_tmp{d}", .{replacement_ctx.temp_index.*});
    replacement_ctx.temp_index.* += 1;
    try replacement_ctx.emit_declarator(replacement_ctx.emit_ctx, target_ty, temp_name);
    try ctx.out.appendSlice(ctx.allocator, " = ");
    try emitReadExprWithReplacements(replacement_ctx, value, nested, target_ty, replacements);
    try ctx.out.appendSlice(ctx.allocator, ";\n");
    try emitAssignmentFromTemp(ctx, replacement_ctx, target_expr, locals, temp_name);
}

pub fn emitReadInferredLocalInitWithReplacements(ctx: Context, replacement_ctx: ReplacementEmitContext, name: []const u8, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), replacements: []const MmioReadReplacement) !void {
    var nested = try emitReadReplacementFrame(ctx, locals.*, replacements);
    defer nested.deinit();

    const source_ty = type_bridge.simpleNameType("u32", initializer.span);
    try locals.put(name, .{
        .source_ty = source_ty,
        .c_type = "uint32_t",
        .source_type_name = "u32",
    });
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "uint32_t {s} = ", .{name});
    try emitReadExprWithReplacements(replacement_ctx, initializer, &nested, source_ty, replacements);
    try ctx.out.appendSlice(ctx.allocator, ";\n");
}

pub fn emitReadExprInferredLocalInit(ctx: CallEmitContext, name: []const u8, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    var replacements: std.ArrayList(MmioReadReplacement) = .empty;
    defer replacements.deinit(ctx.emit.scratch);
    if (!try collectReadHoistsForExpr(ctx.emit, initializer, locals, &replacements)) return false;

    try emitReadInferredLocalInitWithReplacements(ctx.emit.context, ctx.replacement, name, initializer, locals, replacements.items);
    return true;
}

pub fn emitReadReturn(ctx: Context, c_type: []const u8, access: MmioAccess) !void {
    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "return ");
    try appendReadExpr(ctx, c_type, access);
    try ctx.out.appendSlice(ctx.allocator, ";\n");
}

pub fn appendReadExpr(ctx: Context, c_type: []const u8, access: MmioAccess) !void {
    try ctx.out.print(ctx.allocator, "({s})mc_mmio_read_{s}(&{s}->{s})", .{ c_type, access.width, access.param, access.field });
}

pub fn emitAcquireBarrierIfNeeded(ctx: Context, access: MmioAccess) !void {
    if (!std.mem.eql(u8, access.ordering, "acquire")) return;
    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "mc_barrier_acquire_after();\n");
}

pub fn appendInlineReadExpr(ctx: Context, c_type: []const u8, access: MmioAccess) !void {
    if (std.mem.eql(u8, access.ordering, "acquire")) {
        try ctx.out.print(
            ctx.allocator,
            "({{ {s} mc_mr = ",
            .{c_type},
        );
        try appendReadExpr(ctx, c_type, access);
        try ctx.out.appendSlice(ctx.allocator, "; mc_barrier_acquire_after(); mc_mr; })");
        return;
    }
    try ctx.out.appendSlice(ctx.allocator, "(");
    try appendReadExpr(ctx, c_type, access);
    try ctx.out.appendSlice(ctx.allocator, ")");
}

fn writeIndent(ctx: Context) !void {
    for (0..ctx.indent.*) |_| try ctx.out.appendSlice(ctx.allocator, "    ");
}
