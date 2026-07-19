//! C backend local aggregate access and replacement helpers.

const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const lower_c_expr = @import("lower_c_expr.zig");
const lower_c_global = @import("lower_c_global.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_shape = @import("lower_c_shape.zig");
const mir = @import("mir.zig");

const callExpr = ast_query.callExpr;
const calleeIdentName = ast_query.calleeIdentName;
const exprContainsCall = lower_c_expr.exprContainsCall;
const indexExpr = ast_query.indexExpr;
const ConstGetCallInfo = lower_c_model.ConstGetCallInfo;
const GlobalArrayElementAccess = lower_c_model.GlobalArrayElementAccess;
const GlobalAccess = lower_c_model.GlobalAccess;
const LocalInfo = lower_c_model.LocalInfo;
const MmioReadReplacement = lower_c_model.MmioReadReplacement;
const PackedBitsInfo = lower_c_model.PackedBitsInfo;
const RawManyOffsetInfo = lower_c_model.RawManyOffsetInfo;
const SliceAccess = lower_c_model.SliceAccess;
const SequencedArgTemp = lower_c_model.SequencedArgTemp;
const TryReplacement = lower_c_model.TryReplacement;
const arrayElementType = lower_c_shape.arrayElementType;
const memberCallee = ast_query.memberCallee;
const simpleNameType = ast_query.simpleNameType;
const sliceElementType = lower_c_shape.sliceElementType;
const appendGlobalStoreValue = lower_c_global.appendGlobalStoreValue;

pub const EmitExprFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void;
pub const EmitSequencedArgTempFn = *const fn (ctx: *anyopaque, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!SequencedArgTemp;
pub const SliceReturnTypeForCallFn = *const fn (ctx: *anyopaque, call: ast_query.CallExpr) ?ast.TypeExpr;
pub const ArrayReturnTypeForExprFn = *const fn (ctx: *anyopaque, expr: ast.Expr) ?ast.TypeExpr;
pub const ArrayLenTextFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) anyerror!?[]const u8;
pub const CTypeFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8;
pub const EmitDeclaratorFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr, name: []const u8) anyerror!void;
pub const LocalInfoFromTypeFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) anyerror!LocalInfo;
pub const OperandEmitTypeFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr;
pub const GlobalAssignmentTargetFn = *const fn (ctx: *anyopaque, target: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?GlobalAccess;
pub const EmitAssignTargetFn = *const fn (ctx: *anyopaque, target: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void;
pub const EmitRaceLoadTempFn = *const fn (ctx: *anyopaque, ptr_name: []const u8, target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp;
pub const MirCallTargetKindFn = *const fn (ctx: *anyopaque, span: ast.Span) ?mir.CallTargetKind;
pub const MirTargetTypeFn = *const fn (ctx: *anyopaque, kind: mir.TargetTypeKind, span: ast.Span) ?ast.TypeExpr;
pub const MirOwnedTargetTypeFn = *const fn (ctx: *anyopaque, kind: mir.TargetTypeKind, span: ast.Span, target_owner: []const u8, target_index: ?usize) ?ast.TypeExpr;
pub const MirConstGetIndexFn = *const fn (ctx: *anyopaque, span: ast.Span) ?usize;

pub const DirectCallIndexTemps = struct {
    base: SequencedArgTemp,
    index: SequencedArgTemp,
};

pub const EmitContext = struct {
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: *usize,
    temp_index: *usize,
    emit_ctx: *anyopaque,
    emit_expr: EmitExprFn,
    emit_sequenced_arg_temp: EmitSequencedArgTempFn,
    c_type: CTypeFn,
    emit_declarator: EmitDeclaratorFn,
    local_info_from_type: LocalInfoFromTypeFn,
    operand_emit_type: OperandEmitTypeFn,
    global_assignment_target: GlobalAssignmentTargetFn,
    emit_assign_target: EmitAssignTargetFn,
    emit_race_load_temp: EmitRaceLoadTempFn,
    slice_return_type_for_call: SliceReturnTypeForCallFn,
    array_return_type_for_expr: ArrayReturnTypeForExprFn,
    array_len_text: ArrayLenTextFn,
    mir_call_target_kind: MirCallTargetKindFn,
    mir_target_type: MirTargetTypeFn,
    mir_owned_target_type: MirOwnedTargetTypeFn,
    mir_const_get_index: MirConstGetIndexFn,
};

pub fn cloneLocals(allocator: std.mem.Allocator, locals: std.StringHashMap(LocalInfo)) !std.StringHashMap(LocalInfo) {
    var cloned = std.StringHashMap(LocalInfo).init(allocator);
    errdefer cloned.deinit();
    var it = locals.iterator();
    while (it.next()) |entry| try cloned.put(entry.key_ptr.*, entry.value_ptr.*);
    return cloned;
}

pub fn addMmioReadReplacementLocals(locals: *std.StringHashMap(LocalInfo), replacements: []const MmioReadReplacement) !void {
    for (replacements) |replacement| {
        try locals.put(replacement.temp_name, .{
            .c_type = replacement.c_type,
            .source_type_name = replacement.source_type_name,
        });
    }
}

pub fn arrayLenForExpr(expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
    const local_set = locals orelse return null;
    return switch (expr.kind) {
        .ident => |ident| if (local_set.get(ident.text)) |info| info.array_len else null,
        .grouped => |inner| arrayLenForExpr(inner.*, locals),
        else => null,
    };
}

pub fn arrayElemsFieldForExpr(expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
    const local_set = locals orelse return null;
    return switch (expr.kind) {
        .ident => |ident| if (local_set.get(ident.text)) |info| info.array_elems_field else null,
        .grouped => |inner| arrayElemsFieldForExpr(inner.*, locals),
        else => null,
    };
}

pub fn constGetCallInfo(ctx: EmitContext, call: anytype) ?ConstGetCallInfo {
    if (ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) != .const_get) return null;
    if (call.args.len != 0 or call.type_args.len != 1) return null;
    const member = memberCallee(call.callee.*) orelse return null;
    if (!std.mem.eql(u8, member.name.text, "const_get")) return null;
    _ = ctx.mir_target_type(ctx.emit_ctx, .const_get_base, call.callee.*.span) orelse return null;
    _ = ctx.mir_target_type(ctx.emit_ctx, .const_get_result, call.callee.*.span) orelse return null;
    const index = ctx.mir_const_get_index(ctx.emit_ctx, call.callee.*.span) orelse return null;
    return .{ .base = member.base, .index = index };
}

pub fn emitConstGetCall(ctx: EmitContext, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
    const info = constGetCallInfo(ctx, call) orelse return false;
    try ctx.emit_expr(ctx.emit_ctx, info.base.*, locals);
    if (arrayElemsFieldForExpr(info.base.*, locals)) |elems_field| {
        try ctx.out.print(ctx.allocator, ".{s}", .{elems_field});
    }
    try ctx.out.print(ctx.allocator, "[{d}]", .{info.index});
    return true;
}

pub fn emitRawManyOffsetCall(ctx: EmitContext, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
    const info = rawManyOffsetCallInfo(ctx, call, locals) orelse return false;

    try ctx.out.appendSlice(ctx.allocator, "(");
    try ctx.emit_expr(ctx.emit_ctx, info.base, locals);
    try ctx.out.appendSlice(ctx.allocator, " + ");
    try ctx.emit_expr(ctx.emit_ctx, call.args[0], locals);
    try ctx.out.appendSlice(ctx.allocator, ")");
    return true;
}

pub fn rawManyOffsetCallInfo(ctx: EmitContext, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) ?RawManyOffsetInfo {
    _ = locals;
    if (call.type_args.len != 0 or call.args.len != 1) return null;
    const member = memberCallee(call.callee.*) orelse return null;
    if (!std.mem.eql(u8, member.name.text, "offset")) return null;
    if (ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) != .raw_many_offset) return null;
    _ = ctx.mir_target_type(ctx.emit_ctx, .raw_many_offset_base, call.callee.*.span) orelse return null;
    const element_ty = ctx.mir_target_type(ctx.emit_ctx, .raw_many_offset_element, call.callee.*.span) orelse return null;
    const result_ty = ctx.mir_target_type(ctx.emit_ctx, .raw_many_offset_result, call.callee.*.span) orelse return null;
    return .{ .base = member.base.*, .ty = result_ty, .element_ty = element_ty };
}

pub fn emitRawManyOffsetValueTemp(ctx: EmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
    return switch (expr.kind) {
        .grouped => |inner| try emitRawManyOffsetValueTemp(ctx, inner.*, locals, target_ty),
        .call => |call| try emitRawManyOffsetValueTempFromCallForce(ctx, call, locals, target_ty, false),
        else => null,
    };
}

pub fn emitRawManyOffsetValueTempFromCall(ctx: EmitContext, call: anytype, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
    return try emitRawManyOffsetValueTempFromCallForce(ctx, call, locals, target_ty, false);
}

pub fn emitRawManyOffsetValueTempFromCallForce(ctx: EmitContext, call: anytype, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, force: bool) anyerror!?SequencedArgTemp {
    const info = rawManyOffsetCallInfo(ctx, call, locals) orelse return null;
    if (!force and !exprContainsCall(info.base) and !exprContainsCall(call.args[0])) return null;

    const base_temp = try ctx.emit_sequenced_arg_temp(ctx.emit_ctx, info.base, locals, info.ty);
    const index_temp = try ctx.emit_sequenced_arg_temp(ctx.emit_ctx, call.args[0], locals, simpleNameType("usize", call.args[0].span));
    const result_temp = try nextTempName(ctx);

    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = ({s} + {s});\n", .{ try ctx.c_type(ctx.emit_ctx, target_ty), result_temp, base_temp.name, index_temp.name });
    return .{ .name = result_temp, .ty = target_ty };
}

pub fn emitRawManyOffsetDerefAddressValueTemp(ctx: EmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
    if (expr.kind == .grouped) return try emitRawManyOffsetDerefAddressValueTemp(ctx, expr.kind.grouped.*, locals, target_ty);
    const call = rawManyOffsetAddressCall(expr) orelse return null;
    const ptr_ty = rawManyOffsetCallInfo(ctx, call, locals) orelse return null;
    const ptr_temp = (try emitRawManyOffsetValueTempFromCallForce(ctx, call, locals, ptr_ty.ty, true)) orelse return null;
    return try emitRawManyOffsetAddressCastTemp(ctx, target_ty, ptr_temp.name);
}

fn rawManyOffsetAddressCall(expr: ast.Expr) ?@TypeOf(callExpr(expr).?) {
    const deref_expr = switch (expr.kind) {
        .address_of => |inner| inner.*,
        else => return null,
    };
    const offset_expr = switch (deref_expr.kind) {
        .grouped => |grouped| switch (grouped.kind) {
            .deref => |inner| inner.*,
            else => return null,
        },
        .deref => |inner| inner.*,
        else => return null,
    };
    return callExpr(offset_expr);
}

fn emitRawManyOffsetAddressCastTemp(ctx: EmitContext, target_ty: ast.TypeExpr, ptr_temp_name: []const u8) !SequencedArgTemp {
    const result_temp = try nextTempName(ctx);
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = {s};\n", .{ try ctx.c_type(ctx.emit_ctx, target_ty), result_temp, ptr_temp_name });
    return .{ .name = result_temp, .ty = target_ty };
}

pub fn emitRawManyOffsetDerefValueTemp(ctx: EmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
    const inner = switch (expr.kind) {
        .grouped => |grouped| return try emitRawManyOffsetDerefValueTemp(ctx, grouped.*, locals, target_ty),
        .deref => |inner| inner.*,
        else => return null,
    };
    const ptr_ty = rawManyOffsetTypeForExpr(ctx, inner, locals) orelse return null;
    const ptr_temp = (try emitRawManyOffsetValueTemp(ctx, inner, locals, ptr_ty)) orelse return null;
    if (try ctx.emit_race_load_temp(ctx.emit_ctx, ptr_temp.name, target_ty)) |temp| return temp;
    const value_temp = try nextTempName(ctx);

    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = *{s};\n", .{ try ctx.c_type(ctx.emit_ctx, target_ty), value_temp, ptr_temp.name });
    return .{ .name = value_temp, .ty = target_ty };
}

pub fn emitRawManyOffsetDerefAddressReturn(ctx: EmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
    const target_ty = return_ty orelse return false;
    const temp = (try emitRawManyOffsetDerefAddressValueTemp(ctx, expr, locals, target_ty)) orelse return false;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "return {s};\n", .{temp.name});
    return true;
}

pub fn emitRawManyOffsetDerefAddressLocalInit(ctx: EmitContext, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const temp = (try emitRawManyOffsetDerefAddressValueTemp(ctx, initializer, locals, decl_ty)) orelse return false;
    try writeIndent(ctx);
    try ctx.emit_declarator(ctx.emit_ctx, decl_ty, name);
    try ctx.out.print(ctx.allocator, " = {s};\n", .{temp.name});
    return true;
}

pub fn emitRawManyOffsetDerefAddressAssignmentStmt(ctx: EmitContext, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
    const target_ty = assignmentTargetType(ctx, assignment, locals) orelse return false;
    const temp = (try emitRawManyOffsetDerefAddressValueTemp(ctx, assignment.value, locals, target_ty)) orelse return false;
    try emitAssignmentFromTemp(ctx, assignment.target, locals, temp.name);
    return true;
}

pub fn emitRawManyOffsetDerefReturn(ctx: EmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
    const target_ty = return_ty orelse return false;
    const temp = (try emitRawManyOffsetDerefValueTemp(ctx, expr, locals, target_ty)) orelse return false;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "return {s};\n", .{temp.name});
    return true;
}

pub fn emitRawManyOffsetDerefLocalInit(ctx: EmitContext, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const temp = (try emitRawManyOffsetDerefValueTemp(ctx, initializer, locals, decl_ty)) orelse return false;
    try writeIndent(ctx);
    try ctx.emit_declarator(ctx.emit_ctx, decl_ty, name);
    try ctx.out.print(ctx.allocator, " = {s};\n", .{temp.name});
    return true;
}

pub fn emitRawManyOffsetDerefAssignmentStmt(ctx: EmitContext, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
    const target_ty = assignmentTargetType(ctx, assignment, locals) orelse return false;
    const temp = (try emitRawManyOffsetDerefValueTemp(ctx, assignment.value, locals, target_ty)) orelse return false;
    try emitAssignmentFromTemp(ctx, assignment.target, locals, temp.name);
    return true;
}

pub fn emitRawManyOffsetDerefInferredLocalInit(ctx: EmitContext, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const element_ty = rawManyOffsetDerefTypeForExpr(ctx, initializer, locals) orelse return false;
    const inferred_ty = ctx.mir_owned_target_type(ctx.emit_ctx, .inferred_local, initializer.span, name, null) orelse return error.UnsupportedCEmission;
    if (!std.meta.eql(inferred_ty, element_ty)) return error.UnsupportedCEmission;
    try locals.put(name, try ctx.local_info_from_type(ctx.emit_ctx, inferred_ty));
    if (try emitRawManyOffsetDerefLocalInit(ctx, name, inferred_ty, initializer, locals)) return true;

    try writeIndent(ctx);
    try ctx.emit_declarator(ctx.emit_ctx, inferred_ty, name);
    try ctx.out.appendSlice(ctx.allocator, " = ");
    try ctx.emit_expr(ctx.emit_ctx, initializer, locals);
    try ctx.out.appendSlice(ctx.allocator, ";\n");
    return true;
}

pub fn emitRawManyOffsetDerefTargetAssignmentStmt(ctx: EmitContext, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
    const inner = switch (assignment.target.kind) {
        .grouped => |grouped| return try emitRawManyOffsetDerefTargetAssignmentStmt(ctx, .{ .target = grouped.*, .value = assignment.value }, locals),
        .deref => |inner| inner.*,
        else => return false,
    };
    const call = callExpr(inner) orelse return false;
    const info = rawManyOffsetCallInfo(ctx, call, locals) orelse return false;
    const ptr_ty = info.ty;
    const element_ty = info.element_ty;
    const should_sequence = exprContainsCall(inner) or exprContainsCall(assignment.value);
    if (!should_sequence) return false;

    const value_temp = try ctx.emit_sequenced_arg_temp(ctx.emit_ctx, assignment.value, locals, element_ty);
    const ptr_temp = (try emitRawManyOffsetValueTempFromCallForce(ctx, call, locals, ptr_ty, true)) orelse return false;

    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "*{s} = {s};\n", .{ ptr_temp.name, value_temp.name });
    return true;
}

pub fn emitRawManyOffsetReturn(ctx: EmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
    const target_ty = return_ty orelse return false;
    const temp = (try emitRawManyOffsetValueTemp(ctx, expr, locals, target_ty)) orelse return false;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "return {s};\n", .{temp.name});
    return true;
}

pub fn emitRawManyOffsetLocalInit(ctx: EmitContext, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const temp = (try emitRawManyOffsetValueTemp(ctx, initializer, locals, decl_ty)) orelse return false;
    try writeIndent(ctx);
    try ctx.emit_declarator(ctx.emit_ctx, decl_ty, name);
    try ctx.out.print(ctx.allocator, " = {s};\n", .{temp.name});
    return true;
}

pub fn emitRawManyOffsetAssignmentStmt(ctx: EmitContext, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
    const target_ty = assignmentTargetType(ctx, assignment, locals) orelse return false;
    const temp = (try emitRawManyOffsetValueTemp(ctx, assignment.value, locals, target_ty)) orelse return false;
    try emitAssignmentFromTemp(ctx, assignment.target, locals, temp.name);
    return true;
}

pub fn emitRawManyOffsetInferredLocalInit(ctx: EmitContext, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const raw_ty = rawManyOffsetTypeForExpr(ctx, initializer, locals) orelse return false;
    const inferred_ty = ctx.mir_owned_target_type(ctx.emit_ctx, .inferred_local, initializer.span, name, null) orelse return error.UnsupportedCEmission;
    if (!std.meta.eql(inferred_ty, raw_ty)) return error.UnsupportedCEmission;
    try locals.put(name, try ctx.local_info_from_type(ctx.emit_ctx, inferred_ty));
    if (try emitRawManyOffsetLocalInit(ctx, name, inferred_ty, initializer, locals)) return true;

    try writeIndent(ctx);
    try ctx.emit_declarator(ctx.emit_ctx, inferred_ty, name);
    try ctx.out.appendSlice(ctx.allocator, " = ");
    try ctx.emit_expr(ctx.emit_ctx, initializer, locals);
    try ctx.out.appendSlice(ctx.allocator, ";\n");
    return true;
}

fn assignmentTargetType(ctx: EmitContext, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
    return ctx.operand_emit_type(ctx.emit_ctx, assignment.target, locals) orelse blk: {
        const target = ctx.global_assignment_target(ctx.emit_ctx, assignment.target, locals) orelse return null;
        break :blk simpleNameType(target.info.type_name, assignment.value.span);
    };
}

fn emitAssignmentFromTemp(ctx: EmitContext, target_expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), temp_name: []const u8) !void {
    try writeIndent(ctx);
    if (ctx.global_assignment_target(ctx.emit_ctx, target_expr, locals)) |target| {
        try appendGlobalStoreValue(ctx.allocator, ctx.out, target, temp_name);
    } else {
        try ctx.emit_assign_target(ctx.emit_ctx, target_expr, locals);
        try ctx.out.print(ctx.allocator, " = {s};\n", .{temp_name});
    }
}

pub fn rawManyOffsetTypeForExpr(ctx: EmitContext, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
    return switch (expr.kind) {
        .call => |call| if (rawManyOffsetCallInfo(ctx, call, locals)) |info| info.ty else null,
        .grouped => |inner| rawManyOffsetTypeForExpr(ctx, inner.*, locals),
        else => null,
    };
}

pub fn rawManyOffsetDerefTypeForExpr(ctx: EmitContext, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
    const inner = switch (expr.kind) {
        .grouped => |grouped| return rawManyOffsetDerefTypeForExpr(ctx, grouped.*, locals),
        .deref => |inner| inner.*,
        else => return null,
    };
    const call = callExpr(inner) orelse return null;
    return (rawManyOffsetCallInfo(ctx, call, locals) orelse return null).element_ty;
}

pub fn sliceAccessForExpr(expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?SliceAccess {
    const local_set = locals orelse return null;
    return switch (expr.kind) {
        .ident => |ident| if (local_set.get(ident.text)) |info|
            if (info.slice_ptr_field) |ptr_field|
                if (info.slice_len_field) |len_field| .{ .ptr_field = ptr_field, .len_field = len_field } else null
            else
                null
        else
            null,
        .grouped => |inner| sliceAccessForExpr(inner.*, locals),
        else => null,
    };
}

pub fn overlayUnionNameForExpr(expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?[]const u8 {
    return switch (expr.kind) {
        .ident => |ident| if (locals.get(ident.text)) |info| info.source_type_name else null,
        .grouped => |inner| overlayUnionNameForExpr(inner.*, locals),
        else => null,
    };
}

pub fn packedBitsNameForExpr(expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), globals: anytype) ?[]const u8 {
    return switch (expr.kind) {
        .ident => |ident| if (locals) |local_set| blk: {
            if (local_set.get(ident.text)) |info| break :blk info.source_type_name;
            if (globals.get(ident.text)) |global| break :blk global.type_name;
            break :blk null;
        } else null,
        .grouped => |inner| packedBitsNameForExpr(inner.*, locals, globals),
        else => null,
    };
}

pub fn packedBitsGlobalBase(expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), globals: anytype, base_ty: []const u8) ?[]const u8 {
    return switch (expr.kind) {
        .ident => |ident| {
            if (locals.contains(ident.text)) return null;
            const global = globals.get(ident.text) orelse return null;
            return if (std.mem.eql(u8, global.type_name, base_ty)) ident.text else null;
        },
        .grouped => |inner| packedBitsGlobalBase(inner.*, locals, globals, base_ty),
        else => null,
    };
}

pub fn packedBitsMaskLiteral(allocator: std.mem.Allocator, info: PackedBitsInfo, bit_index: usize) ![]const u8 {
    const value = @as(u64, 1) << @intCast(bit_index);
    if (std.mem.eql(u8, info.repr_name, "u8")) return std.fmt.allocPrint(allocator, "UINT8_C({d})", .{value});
    if (std.mem.eql(u8, info.repr_name, "u16")) return std.fmt.allocPrint(allocator, "UINT16_C({d})", .{value});
    if (std.mem.eql(u8, info.repr_name, "u32")) return std.fmt.allocPrint(allocator, "UINT32_C({d})", .{value});
    if (std.mem.eql(u8, info.repr_name, "u64")) return std.fmt.allocPrint(allocator, "UINT64_C({d})", .{value});
    return std.fmt.allocPrint(allocator, "{d}", .{value});
}

pub fn globalArrayElementAccess(index: anytype, locals: ?*std.StringHashMap(LocalInfo), globals: anytype) ?GlobalArrayElementAccess {
    const base_name = calleeIdentName(index.base.*) orelse return null;
    if (locals) |local_set| if (local_set.contains(base_name)) return null;
    const global = globals.get(base_name) orelse return null;
    const element_info = global.array_element_info orelse return null;
    const len = global.array_len orelse return null;
    return .{
        .base_name = base_name,
        .index = index.index.*,
        .len = len,
        .element_info = element_info,
    };
}

pub fn localIndexElementType(expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
    return switch (expr.kind) {
        .ident => |ident| {
            const info = locals.get(ident.text) orelse return null;
            const source_ty = info.source_ty orelse return null;
            return arrayElementType(source_ty) orelse sliceElementType(source_ty);
        },
        .grouped => |inner| localIndexElementType(inner.*, locals),
        else => null,
    };
}

pub fn emitLocalSliceIndexValueTemp(ctx: EmitContext, index: anytype, locals: *std.StringHashMap(LocalInfo), element_ty: ast.TypeExpr, slice: SliceAccess, index_temp: []const u8) anyerror!SequencedArgTemp {
    const value_temp = try nextTempName(ctx);
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = ", .{ try ctx.c_type(ctx.emit_ctx, element_ty), value_temp });
    try ctx.emit_expr(ctx.emit_ctx, index.base.*, locals);
    try ctx.out.print(ctx.allocator, ".{s}[mc_check_index_usize({s}, ", .{ slice.ptr_field, index_temp });
    try ctx.emit_expr(ctx.emit_ctx, index.base.*, locals);
    try ctx.out.print(ctx.allocator, ".{s})];\n", .{slice.len_field});
    return .{ .name = value_temp, .ty = element_ty };
}

pub fn emitLocalArrayIndexValueTemp(ctx: EmitContext, index: anytype, locals: *std.StringHashMap(LocalInfo), element_ty: ast.TypeExpr, len: []const u8, index_temp: []const u8) anyerror!SequencedArgTemp {
    const value_temp = try nextTempName(ctx);
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = ", .{ try ctx.c_type(ctx.emit_ctx, element_ty), value_temp });
    try ctx.emit_expr(ctx.emit_ctx, index.base.*, locals);
    if (arrayElemsFieldForExpr(index.base.*, locals)) |elems_field| {
        try ctx.out.print(ctx.allocator, ".{s}", .{elems_field});
    }
    try ctx.out.print(ctx.allocator, "[mc_check_index_usize({s}, {s})];\n", .{ index_temp, len });
    return .{ .name = value_temp, .ty = element_ty };
}

pub fn emitLocalSliceIndexAddressValueTemp(ctx: EmitContext, index: anytype, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, slice: SliceAccess, index_temp: []const u8) anyerror!SequencedArgTemp {
    const value_temp = try nextTempName(ctx);
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = &", .{ try ctx.c_type(ctx.emit_ctx, target_ty), value_temp });
    try ctx.emit_expr(ctx.emit_ctx, index.base.*, locals);
    try ctx.out.print(ctx.allocator, ".{s}[mc_check_index_usize({s}, ", .{ slice.ptr_field, index_temp });
    try ctx.emit_expr(ctx.emit_ctx, index.base.*, locals);
    try ctx.out.print(ctx.allocator, ".{s})];\n", .{slice.len_field});
    return .{ .name = value_temp, .ty = target_ty };
}

pub fn emitLocalArrayIndexAddressValueTemp(ctx: EmitContext, index: anytype, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, len: []const u8, index_temp: []const u8) anyerror!SequencedArgTemp {
    const value_temp = try nextTempName(ctx);
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = &", .{ try ctx.c_type(ctx.emit_ctx, target_ty), value_temp });
    try ctx.emit_expr(ctx.emit_ctx, index.base.*, locals);
    if (arrayElemsFieldForExpr(index.base.*, locals)) |elems_field| {
        try ctx.out.print(ctx.allocator, ".{s}", .{elems_field});
    }
    try ctx.out.print(ctx.allocator, "[mc_check_index_usize({s}, {s})];\n", .{ index_temp, len });
    return .{ .name = value_temp, .ty = target_ty };
}

pub fn emitLocalSliceIndexStore(ctx: EmitContext, index: anytype, locals: *std.StringHashMap(LocalInfo), slice: SliceAccess, index_temp: []const u8, value_temp: []const u8) !void {
    try ctx.emit_expr(ctx.emit_ctx, index.base.*, locals);
    try ctx.out.print(ctx.allocator, ".{s}[mc_check_index_usize({s}, ", .{ slice.ptr_field, index_temp });
    try ctx.emit_expr(ctx.emit_ctx, index.base.*, locals);
    try ctx.out.print(ctx.allocator, ".{s})] = {s};\n", .{ slice.len_field, value_temp });
}

pub fn emitLocalArrayIndexStore(ctx: EmitContext, index: anytype, locals: *std.StringHashMap(LocalInfo), len: []const u8, index_temp: []const u8, value_temp: []const u8) !void {
    try ctx.emit_expr(ctx.emit_ctx, index.base.*, locals);
    if (arrayElemsFieldForExpr(index.base.*, locals)) |elems_field| {
        try ctx.out.print(ctx.allocator, ".{s}", .{elems_field});
    }
    try ctx.out.print(ctx.allocator, "[mc_check_index_usize({s}, {s})] = {s};\n", .{ index_temp, len, value_temp });
}

pub fn emitLocalIndexReturn(ctx: EmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
    const value_temp = (try emitLocalIndexValueTemp(ctx, expr, locals, return_ty)) orelse return false;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "return {s};\n", .{value_temp.name});
    return true;
}

pub fn emitLocalIndexLocalInit(ctx: EmitContext, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const value_temp = (try emitLocalIndexValueTemp(ctx, initializer, locals, decl_ty)) orelse return false;
    try writeIndent(ctx);
    try ctx.emit_declarator(ctx.emit_ctx, decl_ty, name);
    try ctx.out.print(ctx.allocator, " = {s};\n", .{value_temp.name});
    return true;
}

pub fn emitLocalIndexAssignmentStmt(ctx: EmitContext, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
    const global_target = ctx.global_assignment_target(ctx.emit_ctx, assignment.target, locals);
    const target_ty = ctx.operand_emit_type(ctx.emit_ctx, assignment.target, locals) orelse blk: {
        const target = global_target orelse return false;
        break :blk simpleNameType(target.info.type_name, assignment.value.span);
    };
    const value_temp = (try emitLocalIndexValueTemp(ctx, assignment.value, locals, target_ty)) orelse return false;

    try writeIndent(ctx);
    if (global_target) |target| {
        try appendGlobalStoreValue(ctx.allocator, ctx.out, target, value_temp.name);
    } else {
        try ctx.emit_assign_target(ctx.emit_ctx, assignment.target, locals);
        try ctx.out.print(ctx.allocator, " = {s};\n", .{value_temp.name});
    }
    return true;
}

pub fn emitLocalIndexTargetAssignmentStmt(ctx: EmitContext, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
    const index = indexExpr(assignment.target) orelse return false;
    if (!exprContainsCall(index.index.*) and !exprContainsCall(assignment.value)) return false;
    const element_ty = localIndexElementType(index.base.*, locals) orelse return false;

    const usize_ty = simpleNameType("usize", index.index.span);
    const value_temp = try ctx.emit_sequenced_arg_temp(ctx.emit_ctx, assignment.value, locals, element_ty);
    const index_temp = try ctx.emit_sequenced_arg_temp(ctx.emit_ctx, index.index.*, locals, usize_ty);

    try writeIndent(ctx);
    if (sliceAccessForExpr(index.base.*, locals)) |slice| {
        try emitLocalSliceIndexStore(ctx, index, locals, slice, index_temp.name, value_temp.name);
        return true;
    }

    if (arrayLenForExpr(index.base.*, locals)) |len| {
        try emitLocalArrayIndexStore(ctx, index, locals, len, index_temp.name, value_temp.name);
        return true;
    }

    return false;
}

pub fn emitLocalBaseIndexAddressValueTemp(ctx: EmitContext, index: anytype, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
    if (!exprContainsCall(index.index.*)) return null;
    if (localIndexElementType(index.base.*, locals) == null) return null;

    const usize_ty = simpleNameType("usize", index.index.span);
    const index_temp = try ctx.emit_sequenced_arg_temp(ctx.emit_ctx, index.index.*, locals, usize_ty);
    if (sliceAccessForExpr(index.base.*, locals)) |slice| {
        return try emitLocalSliceIndexAddressValueTemp(ctx, index, locals, target_ty, slice, index_temp.name);
    }

    if (arrayLenForExpr(index.base.*, locals)) |len| {
        return try emitLocalArrayIndexAddressValueTemp(ctx, index, locals, target_ty, len, index_temp.name);
    }

    return null;
}

pub fn emitLocalIndexValueTemp(ctx: EmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) anyerror!?SequencedArgTemp {
    const index = indexExpr(expr) orelse return null;
    if (!exprContainsCall(index.index.*)) return null;

    const element_ty = target_ty orelse localIndexElementType(index.base.*, locals) orelse return error.UnsupportedCEmission;
    const usize_ty = simpleNameType("usize", index.index.span);
    const index_temp = try ctx.emit_sequenced_arg_temp(ctx.emit_ctx, index.index.*, locals, usize_ty);

    if (sliceAccessForExpr(index.base.*, locals)) |slice| {
        return try emitLocalSliceIndexValueTemp(ctx, index, locals, element_ty, slice, index_temp.name);
    }

    if (arrayLenForExpr(index.base.*, locals)) |len| {
        return try emitLocalArrayIndexValueTemp(ctx, index, locals, element_ty, len, index_temp.name);
    }

    return null;
}

pub fn emitDirectCallSliceIndexReturn(ctx: EmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const value_temp = (try emitDirectCallSliceIndexExprValueTemp(ctx, expr, locals, null)) orelse return false;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "return {s};\n", .{value_temp.name});
    return true;
}

pub fn emitDirectCallSliceIndexLocalInit(ctx: EmitContext, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const value_temp = (try emitDirectCallSliceIndexExprValueTemp(ctx, initializer, locals, decl_ty)) orelse return false;
    try writeIndent(ctx);
    try ctx.emit_declarator(ctx.emit_ctx, decl_ty, name);
    try ctx.out.print(ctx.allocator, " = {s};\n", .{value_temp.name});
    return true;
}

pub fn emitDirectCallSliceIndexAssignmentStmt(ctx: EmitContext, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
    const target_ty = assignmentTargetType(ctx, assignment, locals) orelse return false;
    const value_temp = (try emitDirectCallSliceIndexExprValueTemp(ctx, assignment.value, locals, target_ty)) orelse return false;
    try emitAssignmentFromTemp(ctx, assignment.target, locals, value_temp.name);
    return true;
}

pub fn emitDirectCallSliceIndexExprValueTemp(ctx: EmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) anyerror!?SequencedArgTemp {
    const index = indexExpr(expr) orelse return null;
    const call = callExpr(index.base.*) orelse return null;
    const slice_ty = ctx.slice_return_type_for_call(ctx.emit_ctx, call) orelse return null;
    const temps = try emitDirectCallIndexTemps(ctx, index, locals, slice_ty);
    const value_ty = target_ty orelse sliceElementType(slice_ty) orelse return error.UnsupportedCEmission;
    return try emitDirectCallSliceIndexValueTemp(ctx, value_ty, temps.base.name, temps.index.name);
}

pub fn emitDirectCallArrayIndexReturn(ctx: EmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const value_temp = (try emitDirectCallArrayIndexExprValueTemp(ctx, expr, locals, null)) orelse return false;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "return {s};\n", .{value_temp.name});
    return true;
}

pub fn emitDirectCallArrayIndexLocalInit(ctx: EmitContext, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const value_temp = (try emitDirectCallArrayIndexExprValueTemp(ctx, initializer, locals, decl_ty)) orelse return false;
    try writeIndent(ctx);
    try ctx.emit_declarator(ctx.emit_ctx, decl_ty, name);
    try ctx.out.print(ctx.allocator, " = {s};\n", .{value_temp.name});
    return true;
}

pub fn emitDirectCallArrayIndexAssignmentStmt(ctx: EmitContext, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
    const target_ty = assignmentTargetType(ctx, assignment, locals) orelse return false;
    const value_temp = (try emitDirectCallArrayIndexExprValueTemp(ctx, assignment.value, locals, target_ty)) orelse return false;
    try emitAssignmentFromTemp(ctx, assignment.target, locals, value_temp.name);
    return true;
}

pub fn emitDirectCallArrayIndexExprValueTemp(ctx: EmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) anyerror!?SequencedArgTemp {
    const index = indexExpr(expr) orelse return null;
    const array_ty = ctx.array_return_type_for_expr(ctx.emit_ctx, index.base.*) orelse return null;
    const element_ty = target_ty orelse arrayElementType(array_ty) orelse return error.UnsupportedCEmission;
    const len = (try ctx.array_len_text(ctx.emit_ctx, array_ty)) orelse return error.UnsupportedCEmission;
    const temps = try emitDirectCallIndexTemps(ctx, index, locals, array_ty);
    return try emitDirectCallArrayIndexValueTemp(ctx, element_ty, len, temps.base.name, temps.index.name);
}

pub fn emitLocalIndexAddressReturn(ctx: EmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
    const target_ty = return_ty orelse return false;
    const value_temp = (try emitLocalIndexAddressValueTemp(ctx, expr, locals, target_ty)) orelse return false;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "return {s};\n", .{value_temp.name});
    return true;
}

pub fn emitLocalIndexAddressLocalInit(ctx: EmitContext, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const value_temp = (try emitLocalIndexAddressValueTemp(ctx, initializer, locals, decl_ty)) orelse return false;
    try writeIndent(ctx);
    try ctx.emit_declarator(ctx.emit_ctx, decl_ty, name);
    try ctx.out.print(ctx.allocator, " = {s};\n", .{value_temp.name});
    return true;
}

pub fn emitLocalIndexAddressAssignmentStmt(ctx: EmitContext, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
    const target_ty = assignmentTargetType(ctx, assignment, locals) orelse return false;
    const value_temp = (try emitLocalIndexAddressValueTemp(ctx, assignment.value, locals, target_ty)) orelse return false;
    try emitAssignmentFromTemp(ctx, assignment.target, locals, value_temp.name);
    return true;
}

pub fn emitLocalIndexAddressValueTemp(ctx: EmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
    const operand = switch (expr.kind) {
        .address_of => |inner| inner.*,
        .grouped => |inner| return try emitLocalIndexAddressValueTemp(ctx, inner.*, locals, target_ty),
        else => return null,
    };
    const index = indexExpr(operand) orelse return null;
    if (try emitDirectCallIndexAddressValueTemp(ctx, index, locals, target_ty)) |temp| return temp;
    return emitLocalBaseIndexAddressValueTemp(ctx, index, locals, target_ty);
}

pub fn emitDirectCallIndexAddressValueTemp(ctx: EmitContext, index: anytype, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
    if (callExpr(index.base.*)) |call| {
        if (ctx.slice_return_type_for_call(ctx.emit_ctx, call)) |slice_ty| {
            const temps = try emitDirectCallIndexTemps(ctx, index, locals, slice_ty);
            return try emitDirectCallSliceIndexAddressValueTemp(ctx, target_ty, temps.base.name, temps.index.name);
        }
    }

    if (ctx.array_return_type_for_expr(ctx.emit_ctx, index.base.*)) |array_ty| {
        const len = (try ctx.array_len_text(ctx.emit_ctx, array_ty)) orelse return error.UnsupportedCEmission;
        const temps = try emitDirectCallIndexTemps(ctx, index, locals, array_ty);
        return try emitDirectCallArrayIndexAddressValueTemp(ctx, target_ty, len, temps.base.name, temps.index.name);
    }

    return null;
}

pub fn emitDirectCallSliceIndexValueTemp(ctx: EmitContext, value_ty: ast.TypeExpr, base_temp: []const u8, index_temp: []const u8) anyerror!SequencedArgTemp {
    const ptr_expr = try std.fmt.allocPrint(ctx.scratch, "&{s}.ptr[mc_check_index_usize({s}, {s}.len)]", .{ base_temp, index_temp, base_temp });
    if (try ctx.emit_race_load_temp(ctx.emit_ctx, ptr_expr, value_ty)) |temp| return temp;

    const value_temp = try nextTempName(ctx);
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = {s}.ptr[mc_check_index_usize({s}, {s}.len)];\n", .{
        try ctx.c_type(ctx.emit_ctx, value_ty),
        value_temp,
        base_temp,
        index_temp,
        base_temp,
    });
    return .{ .name = value_temp, .ty = value_ty };
}

pub fn emitDirectCallArrayIndexValueTemp(ctx: EmitContext, element_ty: ast.TypeExpr, len: []const u8, base_temp: []const u8, index_temp: []const u8) anyerror!SequencedArgTemp {
    const value_temp = try nextTempName(ctx);
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = {s}.elems[mc_check_index_usize({s}, {s})];\n", .{
        try ctx.c_type(ctx.emit_ctx, element_ty),
        value_temp,
        base_temp,
        index_temp,
        len,
    });
    return .{ .name = value_temp, .ty = element_ty };
}

pub fn emitDirectCallSliceIndexAddressValueTemp(ctx: EmitContext, target_ty: ast.TypeExpr, base_temp: []const u8, index_temp: []const u8) anyerror!SequencedArgTemp {
    const value_temp = try nextTempName(ctx);
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = &{s}.ptr[mc_check_index_usize({s}, {s}.len)];\n", .{
        try ctx.c_type(ctx.emit_ctx, target_ty),
        value_temp,
        base_temp,
        index_temp,
        base_temp,
    });
    return .{ .name = value_temp, .ty = target_ty };
}

pub fn emitDirectCallArrayIndexAddressValueTemp(ctx: EmitContext, target_ty: ast.TypeExpr, len: []const u8, base_temp: []const u8, index_temp: []const u8) anyerror!SequencedArgTemp {
    const value_temp = try nextTempName(ctx);
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = &{s}.elems[mc_check_index_usize({s}, {s})];\n", .{
        try ctx.c_type(ctx.emit_ctx, target_ty),
        value_temp,
        base_temp,
        index_temp,
        len,
    });
    return .{ .name = value_temp, .ty = target_ty };
}

pub fn emitDirectCallIndexTemps(ctx: EmitContext, index: anytype, locals: *std.StringHashMap(LocalInfo), base_ty: ast.TypeExpr) anyerror!DirectCallIndexTemps {
    const usize_ty = simpleNameType("usize", index.index.span);
    return .{
        .base = try ctx.emit_sequenced_arg_temp(ctx.emit_ctx, index.base.*, locals, base_ty),
        .index = try ctx.emit_sequenced_arg_temp(ctx.emit_ctx, index.index.*, locals, usize_ty),
    };
}

pub fn resultTryOperand(expr: ast.Expr) ?ast.Expr {
    return switch (expr.kind) {
        .try_expr => |inner| inner.operand.*,
        .grouped => |inner| resultTryOperand(inner.*),
        else => null,
    };
}

pub fn exprHasTryReplacement(expr: ast.Expr, replacements: []const TryReplacement) bool {
    return exprHasReplacement(TryReplacement, expr, replacements);
}

pub fn exprHasMmioReadReplacement(expr: ast.Expr, replacements: []const MmioReadReplacement) bool {
    return exprHasReplacement(MmioReadReplacement, expr, replacements);
}

fn exprHasReplacement(comptime Replacement: type, expr: ast.Expr, replacements: []const Replacement) bool {
    if (replacementForSpan(Replacement, expr.span, replacements) != null) return true;
    return switch (expr.kind) {
        .grouped, .address_of, .deref => |inner| exprHasReplacement(Replacement, inner.*, replacements),
        .unary => |node| exprHasReplacement(Replacement, node.expr.*, replacements),
        .try_expr => |inner| exprHasReplacement(Replacement, inner.operand.*, replacements),
        .binary => |node| exprHasReplacement(Replacement, node.left.*, replacements) or exprHasReplacement(Replacement, node.right.*, replacements),
        .call => |node| {
            for (node.args) |arg| if (exprHasReplacement(Replacement, arg, replacements)) return true;
            return false;
        },
        .index => |node| exprHasReplacement(Replacement, node.base.*, replacements) or exprHasReplacement(Replacement, node.index.*, replacements),
        .member => |node| exprHasReplacement(Replacement, node.base.*, replacements),
        .cast => |node| exprHasReplacement(Replacement, node.value.*, replacements),
        else => false,
    };
}

pub fn tryReplacementForSpan(span: ast.Span, replacements: []const TryReplacement) ?[]const u8 {
    return if (replacementForSpan(TryReplacement, span, replacements)) |replacement| replacement.temp_name else null;
}

pub fn mmioReadReplacementForSpan(span: ast.Span, replacements: []const MmioReadReplacement) ?MmioReadReplacement {
    return replacementForSpan(MmioReadReplacement, span, replacements);
}

fn replacementForSpan(comptime Replacement: type, span: ast.Span, replacements: []const Replacement) ?Replacement {
    for (replacements) |replacement| {
        if (sameSpan(span, replacement.span)) return replacement;
    }
    return null;
}

pub fn mmioReadReplacementValueTypeForExpr(expr: ast.Expr, replacements: []const MmioReadReplacement) ?[]const u8 {
    return switch (expr.kind) {
        .grouped => |inner| mmioReadReplacementValueTypeForExpr(inner.*, replacements),
        else => if (mmioReadReplacementForSpan(expr.span, replacements)) |replacement| replacement.source_type_name else null,
    };
}

fn nextTempName(ctx: EmitContext) ![]const u8 {
    const temp_name = try std.fmt.allocPrint(ctx.scratch, "mc_tmp{d}", .{ctx.temp_index.*});
    ctx.temp_index.* += 1;
    return temp_name;
}

fn writeIndent(ctx: EmitContext) !void {
    for (0..ctx.indent.*) |_| try ctx.out.appendSlice(ctx.allocator, "    ");
}

fn sameSpan(left: ast.Span, right: ast.Span) bool {
    return left.offset == right.offset and left.len == right.len and left.line == right.line and left.column == right.column;
}
