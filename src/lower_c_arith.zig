//! C backend arithmetic library-call emission.
//!
//! Covers explicit wrapping addition and reduction helpers whose lowering is
//! expression-local but depends on backend type inference and result naming.

const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const lower_c_alias = @import("lower_c_alias.zig");
const lower_c_const = @import("lower_c_const.zig");
const lower_c_expr = @import("lower_c_expr.zig");
const lower_c_global = @import("lower_c_global.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_op = @import("lower_c_op.zig");
const lower_c_shape = @import("lower_c_shape.zig");
const lower_c_target = @import("lower_c_target.zig");
const lower_c_type = @import("lower_c_type.zig");

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
const isIdentNamed = ast_query.isIdentNamed;
const isSatType = ast_query.isSatType;
const isWrapType = ast_query.isWrapType;
const memberCallee = ast_query.memberCallee;
const primitiveCTypeName = lower_c_type.primitiveCTypeName;
const satHelperParts = lower_c_op.satHelperParts;
const signedTypeSuffix = lower_c_type.signedTypeSuffix;
const simpleNameType = ast_query.simpleNameType;
const typeName = ast_query.typeName;
const unsignedTypeSuffix = lower_c_type.unsignedTypeSuffix;
const uncheckedNoOverflowCallOp = lower_c_expr.uncheckedNoOverflowCallOp;
const uncheckedNoOverflowOperator = lower_c_expr.uncheckedNoOverflowOperator;

pub const EmitExprFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void;
pub const EmitExprWithTargetFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) anyerror!void;
pub const EmitSequencedArgTempFn = *const fn (ctx: *anyopaque, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!SequencedArgTemp;
pub const CTypeFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8;
pub const CIdentFn = *const fn (ctx: *anyopaque, name: []const u8) anyerror![]const u8;
pub const NumericExprTypeFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr;
pub const UnderlyingIntTypeNameFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) ?[]const u8;
pub const ResultTypeNameFn = *const fn (ctx: *anyopaque, ok_ty: ast.TypeExpr, err_ty: ast.TypeExpr) anyerror![]const u8;
pub const MirCheckElidedFn = *const fn (ctx: *anyopaque, span: ast.Span) bool;
pub const MirNoOverflowRangeFactFn = *const fn (ctx: *anyopaque, target: []const u8, op: []const u8, span: ast.Span) bool;
pub const LocalInfoFromTypeFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) anyerror!LocalInfo;
pub const OperandEmitTypeFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr;
pub const GlobalAssignmentTargetFn = *const fn (ctx: *anyopaque, target: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?GlobalAccess;
pub const EmitAssignTargetFn = *const fn (ctx: *anyopaque, target: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void;
pub const ExprNeedsSequencedBinaryFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!bool;
pub const EmitSequencedBinaryOperandTempFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!SequencedArgTemp;

pub const Context = struct {
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: *usize,
    temp_index: *usize,
    type_aliases: *const std.StringHashMap(ast.TypeExpr),
    emit_ctx: *anyopaque,
    emit_expr: EmitExprFn,
    emit_expr_with_target: EmitExprWithTargetFn,
    emit_sequenced_arg_temp: EmitSequencedArgTempFn,
    c_type: CTypeFn,
    c_ident: CIdentFn,
    numeric_expr_type: NumericExprTypeFn,
    underlying_int_type_name: UnderlyingIntTypeNameFn,
    result_type_name: ResultTypeNameFn,
    mir_check_elided: MirCheckElidedFn,
    has_mir_no_overflow_range_fact: MirNoOverflowRangeFactFn,
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

pub fn exprNeedsDefaultSequencedBinary(ctx: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!bool {
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
    const member = memberCallee(call.callee.*) orelse return false;
    if (!isIdentNamed(member.base.*, "wrapping")) return false;
    if (!std.mem.eql(u8, member.name.text, "add")) return error.UnsupportedCEmission;
    if (call.args.len != 2) return error.UnsupportedCEmission;

    if (locals) |ls| {
        if (ctx.numeric_expr_type(ctx.emit_ctx, call.args[0], ls)) |ty| {
            if (ctx.underlying_int_type_name(ctx.emit_ctx, ty)) |name| {
                if (name.len > 0 and name[0] == 'i') {
                    const s_cty = primitiveCTypeName(name) orelse return emitWrappingPlusAdd(ctx, call, locals);
                    const u_name = try std.fmt.allocPrint(ctx.scratch, "u{s}", .{name[1..]});
                    const u_cty = primitiveCTypeName(u_name) orelse return emitWrappingPlusAdd(ctx, call, locals);
                    try ctx.out.print(ctx.allocator, "(({s})(({s})(", .{ s_cty, u_cty });
                    try ctx.emit_expr(ctx.emit_ctx, call.args[0], locals);
                    try ctx.out.print(ctx.allocator, ") + ({s})(", .{u_cty});
                    try ctx.emit_expr(ctx.emit_ctx, call.args[1], locals);
                    try ctx.out.appendSlice(ctx.allocator, ")))");
                    return true;
                }
            }
        }
    }
    return emitWrappingPlusAdd(ctx, call, locals);
}

// Unsigned / unknown operands: a plain `+` already wraps (well-defined).
fn emitWrappingPlusAdd(ctx: Context, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
    try ctx.out.appendSlice(ctx.allocator, "(");
    try ctx.emit_expr(ctx.emit_ctx, call.args[0], locals);
    try ctx.out.appendSlice(ctx.allocator, " + ");
    try ctx.emit_expr(ctx.emit_ctx, call.args[1], locals);
    try ctx.out.appendSlice(ctx.allocator, ")");
    return true;
}

// `wrap<T>.residue()` exposes the raw representative; `wrap<T>` already lowers
// to its inner integer type, so this is the identity on the C value.
pub fn emitResidueCall(ctx: Context, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
    if (call.type_args.len != 0) return false;
    const member = memberCallee(call.callee.*) orelse return false;
    if (!std.mem.eql(u8, member.name.text, "residue")) return false;
    _ = ctx.numeric_expr_type(ctx.emit_ctx, member.base.*, locals) orelse return false;
    if (call.args.len != 0) return error.UnsupportedCEmission;
    try ctx.emit_expr(ctx.emit_ctx, member.base.*, locals);
    return true;
}

// Reductions are lowered as GCC/Clang statement-expressions so each slice
// operand is evaluated once. `sum_checked` uses a wide integer accumulator and
// result path; floating reductions use an explicit typed loop.
pub fn emitReduceSumCheckedCall(ctx: Context, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
    const member = memberCallee(call.callee.*) orelse return false;
    if (!isIdentNamed(member.base.*, "reduce")) return false;
    if (call.type_args.len != 1 or call.args.len != 1) return error.UnsupportedCEmission;

    if (std.mem.eql(u8, member.name.text, "sum_left") or std.mem.eql(u8, member.name.text, "sum_fast")) {
        return try emitFloatReduceCall(ctx, call, locals, std.mem.eql(u8, member.name.text, "sum_fast"));
    }
    if (!std.mem.eql(u8, member.name.text, "sum_checked")) return error.UnsupportedCEmission;

    const t_ty = call.type_args[0];
    const t_cty = try ctx.c_type(ctx.emit_ctx, t_ty);
    const int_name = ctx.underlying_int_type_name(ctx.emit_ctx, t_ty) orelse return error.UnsupportedCEmission;
    const range = intTypeRange(int_name) orelse return error.UnsupportedCEmission;
    const struct_name = try ctx.result_type_name(ctx.emit_ctx, t_ty, simpleNameType("Overflow", member.name.span));

    const n = ctx.temp_index.*;
    ctx.temp_index.* += 1;

    try ctx.out.print(ctx.allocator, "({{ __auto_type mc_xs{d} = (", .{n});
    try ctx.emit_expr(ctx.emit_ctx, call.args[0], locals);
    try ctx.out.print(ctx.allocator, "); __int128 mc_acc{d} = 0; for (uintptr_t mc_i{d} = 0; mc_i{d} < mc_xs{d}.len; mc_i{d}++) mc_acc{d} += (__int128)mc_xs{d}.ptr[mc_i{d}]; ", .{ n, n, n, n, n, n, n, n });
    try ctx.out.print(ctx.allocator, "(mc_acc{d} < (__int128)({s}) || mc_acc{d} > (__int128)({s})) ? (({s}){{ .is_ok = false, .payload.err = 0 }}) : (({s}){{ .is_ok = true, .payload.ok = ({s})mc_acc{d} }}); }})", .{ n, range.c_min, n, range.c_max, struct_name, struct_name, t_cty, n });
    return true;
}

pub fn sequencedBinaryPlan(ctx: Context, node: anytype, target_ty: ast.TypeExpr, locals: ?*std.StringHashMap(LocalInfo)) !?SequencedBinaryPlan {
    const op = node.op;
    const resolved_target_ty = lower_c_alias.resolveAliasType(ctx.type_aliases, target_ty);
    if (genericChildType(resolved_target_ty, "wrap")) |inner| {
        return try wrapSequencedBinaryPlan(ctx, op, inner);
    }
    if (genericChildType(resolved_target_ty, "sat")) |inner| {
        return try satSequencedBinaryPlan(op, inner);
    }

    const target_name = typeName(resolved_target_ty) orelse return error.UnsupportedCEmission;
    return checkedSequencedBinaryPlan(ctx, node, op, target_name, locals);
}

pub fn emitSequencedBinaryPlanResultTemp(ctx: Context, plan: SequencedBinaryPlan, target_ty: ast.TypeExpr, left_name: []const u8, right_name: []const u8) anyerror!SequencedArgTemp {
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

pub fn emitSequencedBinaryValueTemp(ctx: SequencedBinaryContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
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

pub fn emitSequencedCheckedBinaryReturn(ctx: SequencedBinaryContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
    const target_ty = return_ty orelse return false;
    const temp = (try emitSequencedBinaryValueTemp(ctx, expr, locals, target_ty)) orelse return false;
    try writeIndent(ctx.arith);
    try ctx.arith.out.print(ctx.arith.allocator, "return {s};\n", .{temp.name});
    return true;
}

pub fn emitSequencedCheckedBinaryLocalInit(ctx: SequencedBinaryContext, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
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

pub fn emitUncheckedAddValueTemp(ctx: Context, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, range_target: []const u8) anyerror!?SequencedArgTemp {
    return switch (expr.kind) {
        .grouped => |inner| try emitUncheckedAddValueTemp(ctx, inner.*, locals, target_ty, range_target),
        .cast => |node| try emitUncheckedAddValueTemp(ctx, node.value.*, locals, node.ty.*, range_target),
        .call => |call| try emitUncheckedAddValueTempFromCall(ctx, call, expr.span, locals, target_ty, range_target),
        else => null,
    };
}

pub fn emitUncheckedAddValueTempFromCall(ctx: Context, call: anytype, call_span: ast.Span, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, range_target: []const u8) anyerror!?SequencedArgTemp {
    const op = uncheckedNoOverflowCallOp(call) orelse return null;
    if (!ctx.has_mir_no_overflow_range_fact(ctx.emit_ctx, range_target, op, call_span)) return null;

    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "/* MC_MIR_RANGE no_overflow target={s} op={s} */\n", .{ range_target, op });

    const left_temp = try ctx.emit_sequenced_arg_temp(ctx.emit_ctx, call.args[0], locals, target_ty);
    const right_temp = try ctx.emit_sequenced_arg_temp(ctx.emit_ctx, call.args[1], locals, target_ty);
    const result_temp = try std.fmt.allocPrint(ctx.scratch, "mc_tmp{d}", .{ctx.temp_index.*});
    ctx.temp_index.* += 1;

    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = ({s} {s} {s});\n", .{ try ctx.c_type(ctx.emit_ctx, target_ty), result_temp, left_temp.name, uncheckedNoOverflowOperator(op), right_temp.name });
    return .{ .name = result_temp, .ty = target_ty };
}

pub fn emitUncheckedAddReturn(ctx: Context, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
    const target_ty = return_ty orelse return false;
    const temp = (try emitUncheckedAddValueTemp(ctx, expr, locals, target_ty, "value")) orelse return false;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "return {s};\n", .{temp.name});
    return true;
}

pub fn emitUncheckedAddLocalInit(ctx: Context, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const temp = (try emitUncheckedAddValueTemp(ctx, initializer, locals, decl_ty, name)) orelse return false;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = {s};\n", .{ try ctx.c_type(ctx.emit_ctx, decl_ty), try ctx.c_ident(ctx.emit_ctx, name), temp.name });
    return true;
}

pub fn emitUncheckedAddInferredLocalInit(ctx: Context, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const inferred_ty = simpleNameType("u32", initializer.span);
    const temp = (try emitUncheckedAddValueTemp(ctx, initializer, locals, inferred_ty, name)) orelse return false;
    try locals.put(name, try ctx.local_info_from_type(ctx.emit_ctx, inferred_ty));
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "uint32_t {s} = {s};\n", .{ try ctx.c_ident(ctx.emit_ctx, name), temp.name });
    return true;
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

fn wrapSequencedBinaryPlan(ctx: Context, op: ast.BinaryOp, inner: ast.TypeExpr) !?SequencedBinaryPlan {
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

fn satSequencedBinaryPlan(op: ast.BinaryOp, inner: ast.TypeExpr) !?SequencedBinaryPlan {
    const inner_name = typeName(inner) orelse return error.UnsupportedCEmission;
    return if (satHelperParts(op, inner_name)) |helper| .{ .helper = helper } else null;
}

fn checkedSequencedBinaryPlan(ctx: Context, node: anytype, op: ast.BinaryOp, target_name: []const u8, locals: ?*std.StringHashMap(LocalInfo)) !?SequencedBinaryPlan {
    if (isNoTrapBitwiseInfixOp(op)) {
        if (unsignedTypeSuffix(target_name) == null) return error.UnsupportedCEmission;
        return .{ .infix = binaryCOp(op) };
    }
    if (!isCheckedBinaryOp(op)) return null;
    if (constBinaryProvenNoOverflow(node, target_name, locals)) return .{ .infix = binaryCOp(op) };
    if ((op == .div or op == .mod) and ctx.mir_check_elided(ctx.emit_ctx, node.right.span)) return .{ .infix = binaryCOp(op) };
    return if (checkedHelperParts(op, target_name)) |helper| .{ .helper = helper } else null;
}

fn emitFloatReduceCall(ctx: Context, call: anytype, locals: ?*std.StringHashMap(LocalInfo), fast: bool) !bool {
    const t_ty = call.type_args[0];
    const t_cty = floatCTypeName(t_ty) orelse return error.UnsupportedCEmission;
    const n = ctx.temp_index.*;
    ctx.temp_index.* += 1;

    try ctx.out.print(ctx.allocator, "({{ __auto_type mc_xs{d} = (", .{n});
    try ctx.emit_expr(ctx.emit_ctx, call.args[0], locals);
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

pub fn emitWrapBinaryWithTarget(ctx: Context, node: anytype, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) !bool {
    const target = if (target_ty) |ty| lower_c_alias.resolveAliasType(ctx.type_aliases, ty) else return false;
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

pub fn emitSatBinaryWithTarget(ctx: Context, node: anytype, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) !bool {
    const target = if (target_ty) |ty| lower_c_alias.resolveAliasType(ctx.type_aliases, ty) else return false;
    const inner = genericChildType(target, "sat") orelse return false;
    const inner_name = typeName(inner) orelse return error.UnsupportedCEmission;
    const helper = satHelperParts(node.op, inner_name) orelse return false;

    try emitTargetBinaryHelper(ctx, node, locals, target, helper);
    return true;
}

pub fn emitCheckedBinaryWithTarget(ctx: Context, node: anytype, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) !bool {
    if (!isCheckedBinaryOp(node.op)) return false;
    const target = if (target_ty) |ty| lower_c_alias.resolveAliasType(ctx.type_aliases, ty) else return false;
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

pub fn emitCheckedUnaryWithTarget(ctx: Context, node: anytype, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) !bool {
    if (node.op != .neg) return false;
    const target = if (target_ty) |ty| lower_c_alias.resolveAliasType(ctx.type_aliases, ty) else return false;
    if (isWrapType(target) or isSatType(target)) return false;
    const target_name = typeName(target) orelse return error.UnsupportedCEmission;
    const suffix = signedTypeSuffix(target_name) orelse return false;

    if (node.expr.kind == .int_literal) {
        try ctx.out.print(ctx.allocator, "(({s})-", .{try ctx.c_type(ctx.emit_ctx, target)});
        try appendCIntLiteral(ctx.allocator, ctx.out, node.expr.kind.int_literal);
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
pub fn emitF32Expr(ctx: Context, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
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

fn emitTargetBinaryInfix(ctx: Context, node: anytype, locals: ?*std.StringHashMap(LocalInfo), target: ast.TypeExpr, op: []const u8) !void {
    try ctx.out.appendSlice(ctx.allocator, "(");
    try ctx.emit_expr_with_target(ctx.emit_ctx, node.left.*, locals, target);
    try ctx.out.print(ctx.allocator, " {s} ", .{op});
    try ctx.emit_expr_with_target(ctx.emit_ctx, node.right.*, locals, target);
    try ctx.out.appendSlice(ctx.allocator, ")");
}

fn emitTargetBinaryHelper(ctx: Context, node: anytype, locals: ?*std.StringHashMap(LocalInfo), target: ast.TypeExpr, helper: lower_c_op.CheckedHelperParts) !void {
    try ctx.out.print(ctx.allocator, "{s}{s}(", .{ helper.prefix, helper.suffix });
    try ctx.emit_expr_with_target(ctx.emit_ctx, node.left.*, locals, target);
    try ctx.out.appendSlice(ctx.allocator, ", ");
    try ctx.emit_expr_with_target(ctx.emit_ctx, node.right.*, locals, target);
    try ctx.out.appendSlice(ctx.allocator, ")");
}
