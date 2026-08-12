//! C backend arithmetic library-call emission.
//!
//! Covers explicit wrapping addition and reduction helpers whose lowering is
//! expression-local but depends on backend type inference and result naming.

const std = @import("std");

const ast_bridge = @import("ast_bridge.zig");
const syntax_bridge = @import("syntax_bridge.zig");
const lower_c_const = @import("lower_c_const.zig");
const lower_c_expr = @import("lower_c_expr.zig");
const lower_c_global = @import("lower_c_global.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_op = @import("lower_c_op.zig");
const lower_c_shape = @import("lower_c_shape.zig");
const lower_c_target = @import("lower_c_target.zig");
const lower_c_type = @import("lower_c_type.zig");
const mir = @import("mir.zig");
const type_bridge = @import("type_bridge.zig");

const appendCIntLiteral = lower_c_const.appendCIntLiteral;
const appendCFloatLiteral = lower_c_const.appendCFloatLiteral;
const assignmentRangeTargetName = lower_c_target.assignmentRangeTargetName;
const binaryCOp = lower_c_op.binaryCOp;
const checkedHelperParts = lower_c_op.checkedHelperParts;
const constBinaryProvenNoOverflow = lower_c_const.constBinaryProvenNoOverflow;
const GlobalAccess = lower_c_model.GlobalAccess;
const LocalInfo = lower_c_model.LocalInfo;
const SequencedArgTemp = lower_c_model.SequencedArgTemp;
const SequencedBinaryPlan = lower_c_model.SequencedBinaryPlan;
const floatCTypeName = lower_c_type.floatCTypeName;
const genericChildType = lower_c_shape.genericChildType;
const intTypeRange = lower_c_type.intTypeRange;
const isCheckedBinaryOp = lower_c_op.isCheckedBinaryOp;
const isNoTrapBitwiseInfixOp = lower_c_op.isNoTrapBitwiseInfixOp;
const isIdentNamed = syntax_bridge.isIdentNamed;
const isSatType = type_bridge.isSatType;
const isWrapType = type_bridge.isWrapType;
const memberCallee = syntax_bridge.memberCallee;
const primitiveCTypeName = lower_c_type.primitiveCTypeName;
const satHelperParts = lower_c_op.satHelperParts;
const signedTypeSuffix = lower_c_type.signedTypeSuffix;
const simpleNameType = type_bridge.simpleNameType;
const sameCStorageType = lower_c_type.sameCStorageType;
const typeName = type_bridge.typeName;
const unsignedTypeSuffix = lower_c_type.unsignedTypeSuffix;
const uncheckedNoOverflowOperator = lower_c_expr.uncheckedNoOverflowOperator;

pub const EmitExprFn = *const fn (ctx: *anyopaque, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void;
pub const EmitExprWithTargetFn = *const fn (ctx: *anyopaque, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast_bridge.TypeExpr) anyerror!void;
pub const EmitSequencedArgTempFn = *const fn (ctx: *anyopaque, arg: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!SequencedArgTemp;
pub const CTypeFn = *const fn (ctx: *anyopaque, ty: ast_bridge.TypeExpr) anyerror![]const u8;
pub const CIdentFn = *const fn (ctx: *anyopaque, name: []const u8) anyerror![]const u8;
pub const UnderlyingIntTypeNameFn = *const fn (ctx: *anyopaque, ty: ast_bridge.TypeExpr) ?[]const u8;
pub const ResultTypeNameFn = *const fn (ctx: *anyopaque, ok_ty: ast_bridge.TypeExpr, err_ty: ast_bridge.TypeExpr) anyerror![]const u8;
pub const MirCheckElidedFn = *const fn (ctx: *anyopaque, span: ast_bridge.Span) bool;
pub const MirNoOverflowRangeFactFn = *const fn (ctx: *anyopaque, target: []const u8, op: []const u8, span: ast_bridge.Span) bool;
pub const MirCallTargetKindFn = *const fn (ctx: *anyopaque, span: ast_bridge.Span) ?mir.CallTargetKind;
pub const MirTargetTypeFn = *const fn (ctx: *anyopaque, kind: mir.TargetTypeKind, span: ast_bridge.Span) ?ast_bridge.TypeExpr;
pub const LocalInfoFromTypeFn = *const fn (ctx: *anyopaque, ty: ast_bridge.TypeExpr) anyerror!LocalInfo;
pub const OperandEmitTypeFn = *const fn (ctx: *anyopaque, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast_bridge.TypeExpr;
pub const GlobalAssignmentTargetFn = *const fn (ctx: *anyopaque, target: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) ?GlobalAccess;
pub const EmitAssignTargetFn = *const fn (ctx: *anyopaque, target: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void;
pub const ExprNeedsSequencedBinaryFn = *const fn (ctx: *anyopaque, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!bool;
pub const EmitSequencedBinaryOperandTempFn = *const fn (ctx: *anyopaque, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!SequencedArgTemp;

pub const Context = struct {
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: *usize,
    temp_index: *usize,
    type_aliases: *const std.StringHashMap(ast_bridge.TypeExpr),
    emit_ctx: *anyopaque,
    emit_expr: EmitExprFn,
    emit_expr_with_target: EmitExprWithTargetFn,
    emit_sequenced_arg_temp: EmitSequencedArgTempFn,
    c_type: CTypeFn,
    c_ident: CIdentFn,
    underlying_int_type_name: UnderlyingIntTypeNameFn,
    result_type_name: ResultTypeNameFn,
    mir_check_elided: MirCheckElidedFn,
    has_mir_no_overflow_range_fact: MirNoOverflowRangeFactFn,
    mir_call_target_kind: MirCallTargetKindFn,
    mir_target_type: MirTargetTypeFn,
    local_info_from_type: LocalInfoFromTypeFn,
    operand_emit_type: OperandEmitTypeFn,
    global_assignment_target: GlobalAssignmentTargetFn,
    emit_assign_target: EmitAssignTargetFn,
};

pub const SequencedBinaryContext = struct {
    arith: Context,
    emit_ctx: *anyopaque,
    expr_needs_sequenced_binary: ExprNeedsSequencedBinaryFn,
    emit_operand_temp: EmitSequencedBinaryOperandTempFn,
};

pub const UncheckedCallInfo = struct {
    op: []const u8,
    left_ty: ast_bridge.TypeExpr,
    right_ty: ast_bridge.TypeExpr,
    result_ty: ast_bridge.TypeExpr,
};

const ReduceTypes = struct {
    source: ast_bridge.TypeExpr,
    element: ast_bridge.TypeExpr,
};

const DomainTypes = struct {
    domain: ast_bridge.TypeExpr,
    payload: ast_bridge.TypeExpr,
    result: ast_bridge.TypeExpr,
};

const ArithmeticCallTypes = struct {
    left: ast_bridge.TypeExpr,
    right: ast_bridge.TypeExpr,
    result: ast_bridge.TypeExpr,
};

pub fn uncheckedCallInfo(ctx: Context, call: anytype) ?UncheckedCallInfo {
    if (call.type_args.len != 0 or call.args.len != 2) return null;
    const kind = ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) orelse return null;
    const op = mir.uncheckedCallFactInfo(kind) orelse return null;
    const types = uncheckedTypesForEmission(ctx, call) orelse return null;
    return .{ .op = op, .left_ty = types.left, .right_ty = types.right, .result_ty = types.result };
}

const WrappingCallInfo = struct {
    left_ty: ast_bridge.TypeExpr,
    right_ty: ast_bridge.TypeExpr,
    result_ty: ast_bridge.TypeExpr,
};

fn wrappingCallInfo(ctx: Context, call: anytype) ?WrappingCallInfo {
    if (call.type_args.len != 0 or call.args.len != 2) return null;
    const kind = ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) orelse return null;
    _ = mir.wrappingCallFactInfo(kind) orelse return null;
    const types = wrappingTypesForEmission(ctx, call) orelse return null;
    return .{ .left_ty = types.left, .right_ty = types.right, .result_ty = types.result };
}

fn uncheckedTypesForEmission(ctx: Context, call: anytype) ?ArithmeticCallTypes {
    return arithmeticCallTypesForEmission(ctx, call, .unchecked_left, .unchecked_right, .unchecked_result);
}

fn wrappingTypesForEmission(ctx: Context, call: anytype) ?ArithmeticCallTypes {
    return arithmeticCallTypesForEmission(ctx, call, .wrapping_left, .wrapping_right, .wrapping_result);
}

fn arithmeticCallTypesForEmission(ctx: Context, call: anytype, left_kind: mir.TargetTypeKind, right_kind: mir.TargetTypeKind, result_kind: mir.TargetTypeKind) ?ArithmeticCallTypes {
    return .{
        .left = ctx.mir_target_type(ctx.emit_ctx, left_kind, call.args[0].span) orelse return null,
        .right = ctx.mir_target_type(ctx.emit_ctx, right_kind, call.args[1].span) orelse return null,
        .result = ctx.mir_target_type(ctx.emit_ctx, result_kind, call.callee.*.span) orelse return null,
    };
}

pub fn exprNeedsDefaultSequencedBinary(ctx: *anyopaque, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!bool {
    const node = switch (expr.kind) {
        .grouped => |inner| return exprNeedsDefaultSequencedBinary(ctx, inner.*, locals),
        .binary => |node| node,
        else => return false,
    };
    return !(isNoTrapBitwiseInfixOp(node.op) and !lower_c_expr.exprContainsCall(node.left.*) and !lower_c_expr.exprContainsCall(node.right.*));
}

// `wrapping.add(a, b)` is explicit modular addition (no trap edge). On unsigned
// operands a plain C `+` already wraps; signed wrapping add is computed in the
// unsigned domain of the same width to avoid signed-overflow UB.
pub fn emitWrappingCall(ctx: Context, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
    const info = wrappingCallInfo(ctx, call) orelse return false;

    if (ctx.underlying_int_type_name(ctx.emit_ctx, info.result_ty)) |name| {
        if (name.len > 0 and name[0] == 'i') {
            const s_cty = primitiveCTypeName(name) orelse return emitWrappingPlusAdd(ctx, call, locals, info);
            const u_name = try std.fmt.allocPrint(ctx.scratch, "u{s}", .{name[1..]});
            const u_cty = primitiveCTypeName(u_name) orelse return emitWrappingPlusAdd(ctx, call, locals, info);
            try ctx.out.print(ctx.allocator, "(({s})(({s})(", .{ s_cty, u_cty });
            try ctx.emit_expr_with_target(ctx.emit_ctx, call.args[0], locals, info.left_ty);
            try ctx.out.print(ctx.allocator, ") + ({s})(", .{u_cty});
            try ctx.emit_expr_with_target(ctx.emit_ctx, call.args[1], locals, info.right_ty);
            try ctx.out.appendSlice(ctx.allocator, ")))");
            return true;
        }
    }
    return emitWrappingPlusAdd(ctx, call, locals, info);
}

// Unsigned / unknown operands: a plain `+` already wraps (well-defined).
fn emitWrappingPlusAdd(ctx: Context, call: anytype, locals: ?*std.StringHashMap(LocalInfo), info: WrappingCallInfo) !bool {
    try ctx.out.appendSlice(ctx.allocator, "(");
    try ctx.emit_expr_with_target(ctx.emit_ctx, call.args[0], locals, info.left_ty);
    try ctx.out.appendSlice(ctx.allocator, " + ");
    try ctx.emit_expr_with_target(ctx.emit_ctx, call.args[1], locals, info.right_ty);
    try ctx.out.appendSlice(ctx.allocator, ")");
    return true;
}

// `wrap<T>.residue()` exposes the raw representative; `wrap<T>` already lowers
// to its inner integer type, so this is the identity on the C value.
pub fn emitResidueCall(ctx: Context, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
    if (call.type_args.len != 0) return false;
    const member = memberCallee(call.callee.*) orelse return false;
    if (!std.mem.eql(u8, member.name.text, "residue")) return false;
    if (ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) != .wrap_residue) return false;
    _ = try residueTypesForEmission(ctx, call);
    if (call.args.len != 0) return error.UnsupportedCEmission;
    try ctx.emit_expr(ctx.emit_ctx, member.base.*, locals);
    return true;
}

// Reductions are lowered as GCC/Clang statement-expressions so each slice
// operand is evaluated once. `sum_checked` uses a wide integer accumulator and
// result path; floating reductions use an explicit typed loop.
pub fn emitReduceSumCheckedCall(ctx: Context, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
    const kind = ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) orelse return false;
    if (kind != .reduce_sum_checked and kind != .reduce_sum_left and kind != .reduce_sum_fast) return false;
    const member = memberCallee(call.callee.*) orelse return false;
    if (call.type_args.len != 1 or call.args.len != 1) return error.UnsupportedCEmission;
    const types = try reduceTypesForEmission(ctx, call);
    const source_ty = types.source;
    const element_ty = types.element;

    if (kind == .reduce_sum_left or kind == .reduce_sum_fast) {
        return try emitFloatReduceCall(ctx, call, locals, source_ty, element_ty, kind == .reduce_sum_fast);
    }

    const t_cty = try ctx.c_type(ctx.emit_ctx, element_ty);
    const int_name = ctx.underlying_int_type_name(ctx.emit_ctx, element_ty) orelse return error.UnsupportedCEmission;
    const range = intTypeRange(int_name) orelse return error.UnsupportedCEmission;
    const struct_name = try ctx.result_type_name(ctx.emit_ctx, element_ty, simpleNameType("Overflow", member.name.span));

    const n = ctx.temp_index.*;
    ctx.temp_index.* += 1;
    try ctx.out.print(ctx.allocator, "({{ __auto_type mc_xs{d} = (", .{n});
    try ctx.emit_expr_with_target(ctx.emit_ctx, call.args[0], locals, source_ty);
    try ctx.out.print(ctx.allocator, "); __int128 mc_acc{d} = 0; for (uintptr_t mc_i{d} = 0; mc_i{d} < mc_xs{d}.len; mc_i{d}++) mc_acc{d} += (__int128)mc_xs{d}.ptr[mc_i{d}]; ", .{ n, n, n, n, n, n, n, n });
    try ctx.out.print(ctx.allocator, "(mc_acc{d} < (__int128)({s}) || mc_acc{d} > (__int128)({s})) ? (({s}){{ .is_ok = false, .payload.err = 0 }}) : (({s}){{ .is_ok = true, .payload.ok = ({s})mc_acc{d} }}); }})", .{ n, range.c_min, n, range.c_max, struct_name, struct_name, t_cty, n });
    return true;
}

fn reduceTypesForEmission(ctx: Context, call: anytype) !ReduceTypes {
    return .{
        .source = ctx.mir_target_type(ctx.emit_ctx, .reduce_source, call.args[0].span) orelse return error.UnsupportedCEmission,
        .element = ctx.mir_target_type(ctx.emit_ctx, .reduce_element, call.callee.*.span) orelse return error.UnsupportedCEmission,
    };
}

fn residueTypesForEmission(ctx: Context, call: anytype) !DomainTypes {
    const span = call.callee.*.span;
    return .{
        .domain = ctx.mir_target_type(ctx.emit_ctx, .domain_type, span) orelse return error.UnsupportedCEmission,
        .payload = ctx.mir_target_type(ctx.emit_ctx, .domain_payload, span) orelse return error.UnsupportedCEmission,
        .result = ctx.mir_target_type(ctx.emit_ctx, .domain_result, span) orelse return error.UnsupportedCEmission,
    };
}

pub fn sequencedBinaryPlan(ctx: Context, node: anytype, target_ty: ast_bridge.TypeExpr, locals: ?*std.StringHashMap(LocalInfo)) !?SequencedBinaryPlan {
    const op = node.op;
    const resolved_target_ty = type_bridge.resolveAliasType(ctx.type_aliases, target_ty);
    if (genericChildType(resolved_target_ty, "wrap")) |inner| {
        return try wrapSequencedBinaryPlan(ctx, op, inner);
    }
    if (genericChildType(resolved_target_ty, "sat")) |inner| {
        return try satSequencedBinaryPlan(op, inner);
    }

    const target_name = typeName(resolved_target_ty) orelse return error.UnsupportedCEmission;
    return checkedSequencedBinaryPlan(ctx, node, op, target_name, locals);
}

pub fn emitSequencedBinaryPlanResultTemp(ctx: Context, plan: SequencedBinaryPlan, target_ty: ast_bridge.TypeExpr, left_name: []const u8, right_name: []const u8) anyerror!SequencedArgTemp {
    const result_temp = try std.fmt.allocPrint(ctx.scratch, "mc_tmp{d}", .{ctx.temp_index.*});
    ctx.temp_index.* += 1;

    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = ", .{ try ctx.c_type(ctx.emit_ctx, target_ty), result_temp });
    switch (plan) {
        .infix => |op_text| try ctx.out.print(ctx.allocator, "({s} {s} {s})", .{ left_name, op_text, right_name }),
        // Narrow (u8/u16) wrap arithmetic computed in `unsigned int` to avoid C's signed-int
        // promotion (where e.g. a u16 `*` overflows `int` before truncating).
        .unsigned_infix => |op_text| try ctx.out.print(ctx.allocator, "((unsigned int)({s}) {s} (unsigned int)({s}))", .{ left_name, op_text, right_name }),
        .helper => |helper| try ctx.out.print(ctx.allocator, "{s}{s}({s}, {s})", .{ helper.prefix, helper.suffix, left_name, right_name }),
    }
    try ctx.out.appendSlice(ctx.allocator, ";\n");
    return .{ .name = result_temp, .ty = target_ty };
}

pub fn emitSequencedBinaryValueTemp(ctx: SequencedBinaryContext, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!?SequencedArgTemp {
    if (!try ctx.expr_needs_sequenced_binary(ctx.emit_ctx, expr, locals)) return null;
    const node = switch (expr.kind) {
        .grouped => |inner| return try emitSequencedBinaryValueTemp(ctx, inner.*, locals, target_ty),
        .binary => |node| node,
        else => return null,
    };
    const plan = try sequencedBinaryPlan(ctx.arith, node, target_ty, locals) orelse return null;

    const left_temp = try ctx.emit_operand_temp(ctx.emit_ctx, node.left.*, locals, target_ty);
    const right_temp = try ctx.emit_operand_temp(ctx.emit_ctx, node.right.*, locals, target_ty);
    return try emitSequencedBinaryPlanResultTemp(ctx.arith, plan, target_ty, left_temp.name, right_temp.name);
}

pub fn emitSequencedCheckedBinaryReturn(ctx: SequencedBinaryContext, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) !bool {
    const target_ty = return_ty orelse return false;
    const temp = (try emitSequencedBinaryValueTemp(ctx, expr, locals, target_ty)) orelse return false;
    try writeIndent(ctx.arith);
    try ctx.arith.out.print(ctx.arith.allocator, "return {s};\n", .{temp.name});
    return true;
}

pub fn emitSequencedCheckedBinaryLocalInit(ctx: SequencedBinaryContext, name: []const u8, decl_ty: ast_bridge.TypeExpr, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const temp = (try emitSequencedBinaryValueTemp(ctx, initializer, locals, decl_ty)) orelse return false;
    try writeIndent(ctx.arith);
    try ctx.arith.out.print(ctx.arith.allocator, "{s} {s} = {s};\n", .{ try ctx.arith.c_type(ctx.arith.emit_ctx, decl_ty), try ctx.arith.c_ident(ctx.arith.emit_ctx, name), temp.name });
    return true;
}

pub fn emitSequencedCheckedBinaryAssignmentStmt(ctx: SequencedBinaryContext, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
    const target_ty = if (ctx.arith.operand_emit_type(ctx.arith.emit_ctx, assignment.target, locals)) |ty| ty else blk: {
        const target = ctx.arith.global_assignment_target(ctx.arith.emit_ctx, assignment.target, locals) orelse return false;
        break :blk simpleNameType(target.info.type_name, assignment.value.span);
    };
    const temp = (try emitSequencedBinaryValueTemp(ctx, assignment.value, locals, target_ty)) orelse return false;

    try writeIndent(ctx.arith);
    if (ctx.arith.global_assignment_target(ctx.arith.emit_ctx, assignment.target, locals)) |target| {
        try lower_c_global.appendGlobalStoreValue(ctx.arith.allocator, ctx.arith.out, target, temp.name);
    } else {
        try ctx.arith.emit_assign_target(ctx.arith.emit_ctx, assignment.target, locals);
        try ctx.arith.out.print(ctx.arith.allocator, " = {s};\n", .{temp.name});
    }
    return true;
}

pub fn emitUncheckedAddValueTemp(ctx: Context, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr, range_target: []const u8) anyerror!?SequencedArgTemp {
    return switch (expr.kind) {
        .grouped => |inner| try emitUncheckedAddValueTemp(ctx, inner.*, locals, target_ty, range_target),
        .cast => |node| try emitUncheckedCastValueTemp(ctx, node, locals, target_ty, range_target),
        .call => |call| try emitUncheckedAddValueTempFromCall(ctx, call, expr.span, locals, target_ty, range_target),
        else => null,
    };
}

fn emitUncheckedCastValueTemp(ctx: Context, node: anytype, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr, range_target: []const u8) anyerror!?SequencedArgTemp {
    const cast_ty = node.ty.*;
    if (!sameCStorageType(cast_ty, target_ty)) return null;
    const source_ty = (try uncheckedInferredLocalType(ctx, node.value.*, locals, range_target)) orelse return null;
    const source_temp = (try emitUncheckedAddValueTemp(ctx, node.value.*, locals, source_ty, range_target)) orelse return null;
    if (sameCStorageType(source_ty, cast_ty)) return source_temp;

    const result_temp = try std.fmt.allocPrint(ctx.scratch, "mc_tmp{d}", .{ctx.temp_index.*});
    ctx.temp_index.* += 1;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = ({s}){s};\n", .{
        try ctx.c_type(ctx.emit_ctx, cast_ty),
        result_temp,
        try ctx.c_type(ctx.emit_ctx, cast_ty),
        source_temp.name,
    });
    return .{ .name = result_temp, .ty = cast_ty };
}

pub fn emitUncheckedAddValueTempFromCall(ctx: Context, call: anytype, call_span: ast_bridge.Span, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr, range_target: []const u8) anyerror!?SequencedArgTemp {
    const info = uncheckedCallInfo(ctx, call) orelse return null;
    if (!ctx.has_mir_no_overflow_range_fact(ctx.emit_ctx, range_target, info.op, call_span)) return null;

    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "/* MC_MIR_RANGE no_overflow target={s} op={s} */\n", .{ range_target, info.op });

    const left_temp = try emitUncheckedOperandTemp(ctx, call.args[0], locals, info.left_ty);
    const right_temp = try emitUncheckedOperandTemp(ctx, call.args[1], locals, info.right_ty);
    const result_temp = try std.fmt.allocPrint(ctx.scratch, "mc_tmp{d}", .{ctx.temp_index.*});
    ctx.temp_index.* += 1;

    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = ({s} {s} {s});\n", .{ try ctx.c_type(ctx.emit_ctx, info.result_ty), result_temp, left_temp.name, uncheckedNoOverflowOperator(info.op), right_temp.name });
    if (!sameCStorageType(info.result_ty, target_ty)) return error.UnsupportedCEmission;
    return .{ .name = result_temp, .ty = info.result_ty };
}

fn emitUncheckedOperandTemp(ctx: Context, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast_bridge.TypeExpr) anyerror!SequencedArgTemp {
    switch (expr.kind) {
        .grouped => |inner| return emitUncheckedOperandTemp(ctx, inner.*, locals, target_ty),
        .cast => |node| return emitUncheckedOperandTemp(ctx, node.value.*, locals, node.ty.*),
        .call => |call| {
            if (uncheckedCallInfo(ctx, call)) |info| {
                const temp = try emitUncheckedOperandCallTemp(ctx, call, locals, info);
                return temp;
            }
        },
        else => {},
    }
    return ctx.emit_sequenced_arg_temp(ctx.emit_ctx, expr, locals, target_ty);
}

fn emitUncheckedOperandCallTemp(ctx: Context, call: anytype, locals: *std.StringHashMap(LocalInfo), info: UncheckedCallInfo) anyerror!SequencedArgTemp {
    const left_temp = try emitUncheckedOperandTemp(ctx, call.args[0], locals, info.left_ty);
    const right_temp = try emitUncheckedOperandTemp(ctx, call.args[1], locals, info.right_ty);
    const result_temp = try std.fmt.allocPrint(ctx.scratch, "mc_tmp{d}", .{ctx.temp_index.*});
    ctx.temp_index.* += 1;

    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = ({s} {s} {s});\n", .{ try ctx.c_type(ctx.emit_ctx, info.result_ty), result_temp, left_temp.name, uncheckedNoOverflowOperator(info.op), right_temp.name });
    return .{ .name = result_temp, .ty = info.result_ty };
}

pub fn emitUncheckedAddReturn(ctx: Context, expr: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast_bridge.TypeExpr) !bool {
    const target_ty = return_ty orelse return false;
    const temp = (try emitUncheckedAddValueTemp(ctx, expr, locals, target_ty, "value")) orelse return false;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "return {s};\n", .{temp.name});
    return true;
}

pub fn emitUncheckedAddLocalInit(ctx: Context, name: []const u8, decl_ty: ast_bridge.TypeExpr, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const temp = (try emitUncheckedAddValueTemp(ctx, initializer, locals, decl_ty, name)) orelse return false;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = {s};\n", .{ try ctx.c_type(ctx.emit_ctx, decl_ty), try ctx.c_ident(ctx.emit_ctx, name), temp.name });
    return true;
}

pub fn emitUncheckedAddInferredLocalInit(ctx: Context, name: []const u8, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const inferred_ty = (try uncheckedInferredLocalType(ctx, initializer, locals, name)) orelse return false;
    const temp = (try emitUncheckedAddValueTemp(ctx, initializer, locals, inferred_ty, name)) orelse return false;
    try locals.put(name, try ctx.local_info_from_type(ctx.emit_ctx, inferred_ty));
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = {s};\n", .{ try ctx.c_type(ctx.emit_ctx, inferred_ty), try ctx.c_ident(ctx.emit_ctx, name), temp.name });
    return true;
}

fn uncheckedInferredLocalType(ctx: Context, initializer: ast_bridge.Expr, locals: *std.StringHashMap(LocalInfo), range_target: []const u8) !?ast_bridge.TypeExpr {
    return switch (initializer.kind) {
        .grouped => |inner| try uncheckedInferredLocalType(ctx, inner.*, locals, range_target),
        .call => |call| try uncheckedCallResultType(ctx, call, initializer.span, locals, range_target),
        else => sourceExpressionResultType(ctx, initializer),
    };
}

fn sourceExpressionResultType(ctx: Context, initializer: ast_bridge.Expr) ?ast_bridge.TypeExpr {
    return ctx.mir_target_type(ctx.emit_ctx, .expression_result, initializer.span);
}

fn uncheckedCallResultType(ctx: Context, call: anytype, call_span: ast_bridge.Span, locals: *std.StringHashMap(LocalInfo), range_target: []const u8) !?ast_bridge.TypeExpr {
    _ = locals;
    const info = uncheckedCallInfo(ctx, call) orelse return null;
    if (!ctx.has_mir_no_overflow_range_fact(ctx.emit_ctx, range_target, info.op, call_span)) return null;
    return info.result_ty;
}

pub fn emitUncheckedAddAssignmentStmt(ctx: Context, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
    const target_ty = if (ctx.operand_emit_type(ctx.emit_ctx, assignment.target, locals)) |ty| ty else blk: {
        const target = ctx.global_assignment_target(ctx.emit_ctx, assignment.target, locals) orelse return false;
        break :blk simpleNameType(target.info.type_name, assignment.value.span);
    };
    const range_target = assignmentRangeTargetName(assignment.target) orelse return false;
    const temp = (try emitUncheckedAddValueTemp(ctx, assignment.value, locals, target_ty, range_target)) orelse return false;

    try writeIndent(ctx);
    if (ctx.global_assignment_target(ctx.emit_ctx, assignment.target, locals)) |target| {
        try lower_c_global.appendGlobalStoreValue(ctx.allocator, ctx.out, target, temp.name);
    } else {
        try ctx.emit_assign_target(ctx.emit_ctx, assignment.target, locals);
        try ctx.out.print(ctx.allocator, " = {s};\n", .{temp.name});
    }
    return true;
}

fn wrapSequencedBinaryPlan(ctx: Context, op: ast_bridge.BinaryOp, inner: ast_bridge.TypeExpr) !?SequencedBinaryPlan {
    const inner_name = typeName(inner) orelse return error.UnsupportedCEmission;
    if (unsignedTypeSuffix(inner_name) == null) return error.UnsupportedCEmission;
    const narrow = std.mem.eql(u8, inner_name, "u8") or std.mem.eql(u8, inner_name, "u16");
    return switch (op) {
        .add, .sub, .mul => if (narrow) .{ .unsigned_infix = binaryCOp(op) } else .{ .infix = binaryCOp(op) },
        .bit_and, .bit_or, .bit_xor => .{ .infix = binaryCOp(op) },
        .shl, .shr => .{ .helper = .{
            .prefix = try std.fmt.allocPrint(ctx.scratch, "mc_wrap_{s}_", .{if (op == .shl) "shl" else "shr"}),
            .suffix = unsignedTypeSuffix(inner_name).?,
        } },
        .div, .mod => .{ .helper = checkedHelperParts(op, inner_name) orelse return error.UnsupportedCEmission },
        else => null,
    };
}

fn satSequencedBinaryPlan(op: ast_bridge.BinaryOp, inner: ast_bridge.TypeExpr) !?SequencedBinaryPlan {
    const inner_name = typeName(inner) orelse return error.UnsupportedCEmission;
    return if (satHelperParts(op, inner_name)) |helper| .{ .helper = helper } else null;
}

fn checkedSequencedBinaryPlan(ctx: Context, node: anytype, op: ast_bridge.BinaryOp, target_name: []const u8, locals: ?*std.StringHashMap(LocalInfo)) !?SequencedBinaryPlan {
    if (isNoTrapBitwiseInfixOp(op)) {
        if (unsignedTypeSuffix(target_name) == null) return error.UnsupportedCEmission;
        return .{ .infix = binaryCOp(op) };
    }
    if (!isCheckedBinaryOp(op)) return null;
    if (constBinaryProvenNoOverflow(node, target_name, locals)) return .{ .infix = binaryCOp(op) };
    if ((op == .div or op == .mod) and ctx.mir_check_elided(ctx.emit_ctx, node.right.span)) return .{ .infix = binaryCOp(op) };
    return if (checkedHelperParts(op, target_name)) |helper| .{ .helper = helper } else null;
}

fn emitFloatReduceCall(ctx: Context, call: anytype, locals: ?*std.StringHashMap(LocalInfo), source_ty: ast_bridge.TypeExpr, element_ty: ast_bridge.TypeExpr, fast: bool) !bool {
    const t_cty = floatCTypeName(element_ty) orelse return error.UnsupportedCEmission;
    const n = ctx.temp_index.*;
    ctx.temp_index.* += 1;

    try ctx.out.print(ctx.allocator, "({{ __auto_type mc_xs{d} = (", .{n});
    try ctx.emit_expr_with_target(ctx.emit_ctx, call.args[0], locals, source_ty);
    try ctx.out.print(ctx.allocator, "); {s} mc_acc{d} = ({s})0; ", .{ t_cty, n, t_cty });
    if (fast) {
        try ctx.out.print(ctx.allocator,
            \\/* MC_SUM_FAST: reassociation/vectorization opt-in */
            \\#if defined(__clang__)
            \\{{
            \\#pragma clang fp reassociate(on)
            \\#pragma clang loop vectorize(enable) interleave(enable)
            \\for (uintptr_t mc_i{0d} = 0; mc_i{0d} < mc_xs{0d}.len; mc_i{0d}++) mc_acc{0d} = ({1s})(mc_acc{0d} + mc_xs{0d}.ptr[mc_i{0d}]);
            \\}}
            \\#else
            \\for (uintptr_t mc_i{0d} = 0; mc_i{0d} < mc_xs{0d}.len; mc_i{0d}++) mc_acc{0d} = ({1s})(mc_acc{0d} + mc_xs{0d}.ptr[mc_i{0d}]);
            \\#endif
            \\ mc_acc{0d}; }})
        , .{ n, t_cty });
    } else {
        try ctx.out.print(ctx.allocator, "for (uintptr_t mc_i{d} = 0; mc_i{d} < mc_xs{d}.len; mc_i{d}++) mc_acc{d} = ({s})(mc_acc{d} + mc_xs{d}.ptr[mc_i{d}]); mc_acc{d}; }})", .{ n, n, n, n, n, t_cty, n, n, n, n });
    }
    return true;
}

fn writeIndent(ctx: Context) !void {
    for (0..ctx.indent.*) |_| try ctx.out.appendSlice(ctx.allocator, "    ");
}

pub fn emitWrapBinaryWithTarget(ctx: Context, node: anytype, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast_bridge.TypeExpr) !bool {
    const target = if (target_ty) |ty| type_bridge.resolveAliasType(ctx.type_aliases, ty) else return false;
    const inner = genericChildType(target, "wrap") orelse return false;
    const inner_name = typeName(inner) orelse return error.UnsupportedCEmission;
    if (unsignedTypeSuffix(inner_name) == null) return error.UnsupportedCEmission;

    switch (node.op) {
        .add, .sub, .mul => {
            // C integer promotion takes a sub-`int` unsigned operand (u8/u16)
            // to signed `int`, so compute narrow wrap arithmetic in unsigned
            // int and truncate back to the wrap type.
            const narrow = std.mem.eql(u8, inner_name, "u8") or std.mem.eql(u8, inner_name, "u16");
            if (narrow) {
                const c_inner = try ctx.c_type(ctx.emit_ctx, inner);
                try ctx.out.print(ctx.allocator, "({s})((unsigned int)(", .{c_inner});
                try ctx.emit_expr_with_target(ctx.emit_ctx, node.left.*, locals, target);
                try ctx.out.print(ctx.allocator, ") {s} (unsigned int)(", .{binaryCOp(node.op)});
                try ctx.emit_expr_with_target(ctx.emit_ctx, node.right.*, locals, target);
                try ctx.out.appendSlice(ctx.allocator, ")))");
                return true;
            }
            try emitTargetBinaryInfix(ctx, node, locals, target, binaryCOp(node.op));
            return true;
        },
        .bit_and, .bit_or, .bit_xor => {
            try emitTargetBinaryInfix(ctx, node, locals, target, binaryCOp(node.op));
            return true;
        },
        .shl, .shr => {
            const suffix = unsignedTypeSuffix(inner_name) orelse return error.UnsupportedCEmission;
            try ctx.out.print(ctx.allocator, "mc_wrap_{s}_{s}(", .{ if (node.op == .shl) "shl" else "shr", suffix });
            try ctx.emit_expr_with_target(ctx.emit_ctx, node.left.*, locals, target);
            try ctx.out.appendSlice(ctx.allocator, ", ");
            try ctx.emit_expr_with_target(ctx.emit_ctx, node.right.*, locals, target);
            try ctx.out.appendSlice(ctx.allocator, ")");
            return true;
        },
        .div, .mod => {
            if (ctx.mir_check_elided(ctx.emit_ctx, node.right.span)) {
                try emitTargetBinaryInfix(ctx, node, locals, target, if (node.op == .div) "/" else "%");
                return true;
            }
            const helper = checkedHelperParts(node.op, inner_name) orelse return error.UnsupportedCEmission;
            try emitTargetBinaryHelper(ctx, node, locals, target, helper);
            return true;
        },
        else => return false,
    }
}

pub fn emitSatBinaryWithTarget(ctx: Context, node: anytype, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast_bridge.TypeExpr) !bool {
    const target = if (target_ty) |ty| type_bridge.resolveAliasType(ctx.type_aliases, ty) else return false;
    const inner = genericChildType(target, "sat") orelse return false;
    const inner_name = typeName(inner) orelse return error.UnsupportedCEmission;
    const helper = satHelperParts(node.op, inner_name) orelse return false;

    try emitTargetBinaryHelper(ctx, node, locals, target, helper);
    return true;
}

pub fn emitCheckedBinaryWithTarget(ctx: Context, node: anytype, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast_bridge.TypeExpr) !bool {
    if (!isCheckedBinaryOp(node.op)) return false;
    const target = if (target_ty) |ty| type_bridge.resolveAliasType(ctx.type_aliases, ty) else return false;
    if (isWrapType(target) or isSatType(target)) return false;
    const target_name = typeName(target) orelse return error.UnsupportedCEmission;

    if (constBinaryProvenNoOverflow(node, target_name, locals)) {
        const cty = try ctx.c_type(ctx.emit_ctx, target);
        try ctx.out.print(ctx.allocator, "(({s})(", .{cty});
        try ctx.emit_expr_with_target(ctx.emit_ctx, node.left.*, locals, target);
        try ctx.out.print(ctx.allocator, " {s} ", .{binaryCOp(node.op)});
        try ctx.emit_expr_with_target(ctx.emit_ctx, node.right.*, locals, target);
        try ctx.out.appendSlice(ctx.allocator, "))");
        return true;
    }

    const helper = checkedHelperParts(node.op, target_name) orelse return false;

    if ((node.op == .div or node.op == .mod) and ctx.mir_check_elided(ctx.emit_ctx, node.right.span)) {
        try emitTargetBinaryInfix(ctx, node, locals, target, if (node.op == .div) "/" else "%");
        return true;
    }

    try emitTargetBinaryHelper(ctx, node, locals, target, helper);
    return true;
}

pub fn emitCheckedUnaryWithTarget(ctx: Context, node: anytype, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast_bridge.TypeExpr) !bool {
    if (node.op != .neg) return false;
    const target = if (target_ty) |ty| type_bridge.resolveAliasType(ctx.type_aliases, ty) else return false;
    if (isWrapType(target) or isSatType(target)) return false;
    const target_name = typeName(target) orelse return error.UnsupportedCEmission;
    const suffix = signedTypeSuffix(target_name) orelse return false;

    if (node.expr.kind == .int_literal) {
        try ctx.out.print(ctx.allocator, "(({s})", .{try ctx.c_type(ctx.emit_ctx, target)});
        try lower_c_const.appendCNegatedIntLiteral(ctx.allocator, ctx.out, node.expr.kind.int_literal);
        try ctx.out.appendSlice(ctx.allocator, ")");
        return true;
    }

    try ctx.out.print(ctx.allocator, "mc_checked_neg_{s}(", .{suffix});
    try ctx.emit_expr_with_target(ctx.emit_ctx, node.expr.*, locals, target);
    try ctx.out.appendSlice(ctx.allocator, ")");
    return true;
}

// Emit a float expression whose target type is f32: every float literal gets an
// `f` suffix and arithmetic recurses with the same f32 target, so the whole
// computation runs in `float`. Non-float-shaped leaves fall back to normal
// expression emission.
pub fn emitF32Expr(ctx: Context, expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
    switch (expr.kind) {
        .float_literal => |lit| try appendCFloatLiteral(ctx.allocator, ctx.out, lit, true),
        .grouped => |inner| {
            try ctx.out.appendSlice(ctx.allocator, "(");
            try emitF32Expr(ctx, inner.*, locals);
            try ctx.out.appendSlice(ctx.allocator, ")");
        },
        .binary => |node| {
            try ctx.out.appendSlice(ctx.allocator, "(");
            try emitF32Expr(ctx, node.left.*, locals);
            try ctx.out.print(ctx.allocator, " {s} ", .{binaryCOp(node.op)});
            try emitF32Expr(ctx, node.right.*, locals);
            try ctx.out.appendSlice(ctx.allocator, ")");
        },
        .unary => |node| {
            if (node.op == .neg) {
                try ctx.out.appendSlice(ctx.allocator, "(-");
                try emitF32Expr(ctx, node.expr.*, locals);
                try ctx.out.appendSlice(ctx.allocator, ")");
            } else try ctx.emit_expr(ctx.emit_ctx, expr, locals);
        },
        else => try ctx.emit_expr(ctx.emit_ctx, expr, locals),
    }
}

fn emitTargetBinaryInfix(ctx: Context, node: anytype, locals: ?*std.StringHashMap(LocalInfo), target: ast_bridge.TypeExpr, op: []const u8) !void {
    try ctx.out.appendSlice(ctx.allocator, "(");
    try ctx.emit_expr_with_target(ctx.emit_ctx, node.left.*, locals, target);
    try ctx.out.print(ctx.allocator, " {s} ", .{op});
    try ctx.emit_expr_with_target(ctx.emit_ctx, node.right.*, locals, target);
    try ctx.out.appendSlice(ctx.allocator, ")");
}

fn emitTargetBinaryHelper(ctx: Context, node: anytype, locals: ?*std.StringHashMap(LocalInfo), target: ast_bridge.TypeExpr, helper: lower_c_op.CheckedHelperParts) !void {
    try ctx.out.print(ctx.allocator, "{s}{s}(", .{ helper.prefix, helper.suffix });
    try ctx.emit_expr_with_target(ctx.emit_ctx, node.left.*, locals, target);
    try ctx.out.appendSlice(ctx.allocator, ", ");
    try ctx.emit_expr_with_target(ctx.emit_ctx, node.right.*, locals, target);
    try ctx.out.appendSlice(ctx.allocator, ")");
}
