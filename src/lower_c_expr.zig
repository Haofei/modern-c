const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const lower_c_alias = @import("lower_c_alias.zig");
const lower_c_const = @import("lower_c_const.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_op = @import("lower_c_op.zig");

const calleeIdentName = ast_query.calleeIdentName;
const isIdentNamed = ast_query.isIdentNamed;
const memberCallee = ast_query.memberCallee;
const binaryCOp = lower_c_op.binaryCOp;
const isCheckedBinaryOp = lower_c_op.isCheckedBinaryOp;
const isComparisonOp = lower_c_op.isComparisonOp;
const unaryCOp = lower_c_op.unaryCOp;

const LocalInfo = lower_c_model.LocalInfo;

pub const EmitExprFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void;
pub const EmitExprWithTargetFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) anyerror!void;
pub const EmitCheckedExprFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) anyerror!bool;
pub const CountExprFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) usize;
pub const ExprTypeFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr;
pub const ExprPredicateFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool;

pub const EmitContext = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    type_aliases: *const std.StringHashMap(ast.TypeExpr),
    emit_ctx: *anyopaque,
    emit_expr: EmitExprFn,
    emit_expr_with_target: EmitExprWithTargetFn,
    emit_checked_unary: EmitCheckedExprFn,
    emit_checked_binary: EmitCheckedExprFn,
    count_mmio_reads: CountExprFn,
    numeric_expr_type: ExprTypeFn,
    operand_emit_type: ExprTypeFn,
    expr_resolves_to_float: ExprPredicateFn,
};

pub fn emitUnaryExpr(ctx: EmitContext, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
    const node = switch (expr.kind) {
        .unary => |node| node,
        else => unreachable,
    };
    if (node.op == .neg and lower_c_const.negatedLiteralIsI64Min(node.expr.*)) {
        // The most-negative i64 (INT64_MIN). Emitting `-(9223372036854775808)` is
        // wrong in C: the magnitude 2^63 exceeds LLONG_MAX, so the bare decimal
        // constant is unsigned, and negating it stays unsigned.
        try ctx.out.appendSlice(ctx.allocator, "(-9223372036854775807LL - 1)");
        return;
    }
    if (node.op == .neg and !ctx.expr_resolves_to_float(ctx.emit_ctx, node.expr.*, locals)) {
        if (ctx.numeric_expr_type(ctx.emit_ctx, node.expr.*, locals)) |inferred| {
            const resolved = lower_c_alias.resolveAliasType(ctx.type_aliases, inferred);
            if (!ast_query.isWrapType(resolved) and !ast_query.isSatType(resolved)) {
                if (try ctx.emit_checked_unary(ctx.emit_ctx, expr, locals, inferred)) return;
            }
        }
    }
    try ctx.out.appendSlice(ctx.allocator, unaryCOp(node.op));
    try ctx.out.appendSlice(ctx.allocator, "(");
    try ctx.emit_expr(ctx.emit_ctx, node.expr.*, locals);
    try ctx.out.appendSlice(ctx.allocator, ")");
}

pub fn emitBinaryExpr(ctx: EmitContext, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
    const node = switch (expr.kind) {
        .binary => |node| node,
        else => unreachable,
    };
    if ((node.op == .logical_and or node.op == .logical_or)) {
        if (locals) |local_set| {
            if (ctx.count_mmio_reads(ctx.emit_ctx, node.left.*, local_set) > 1 or ctx.count_mmio_reads(ctx.emit_ctx, node.right.*, local_set) > 1) {
                return error.UnsupportedCEmission;
            }
        }
    }
    if (isCheckedBinaryOp(node.op) and !binaryResolvesToFloat(ctx, node, locals)) {
        if (ctx.numeric_expr_type(ctx.emit_ctx, expr, locals)) |inferred| {
            const inferred_dom = lower_c_alias.resolveAliasType(ctx.type_aliases, inferred);
            if (ast_query.isWrapType(inferred_dom) or ast_query.isSatType(inferred_dom)) {
                try ctx.emit_expr_with_target(ctx.emit_ctx, expr, locals, inferred);
                return;
            }
            if (try ctx.emit_checked_binary(ctx.emit_ctx, expr, locals, inferred)) return;
        }
        return error.UnsupportedCEmission;
    }
    if (isComparisonOp(node.op)) {
        const left_enum = node.left.*.kind == .enum_literal;
        const right_enum = node.right.*.kind == .enum_literal;
        if (left_enum or right_enum) {
            const enum_ty = if (left_enum)
                ctx.operand_emit_type(ctx.emit_ctx, node.right.*, locals)
            else
                ctx.operand_emit_type(ctx.emit_ctx, node.left.*, locals);
            if (enum_ty) |ety| {
                try ctx.out.appendSlice(ctx.allocator, "(");
                try ctx.emit_expr_with_target(ctx.emit_ctx, node.left.*, locals, ety);
                try ctx.out.print(ctx.allocator, " {s} ", .{binaryCOp(node.op)});
                try ctx.emit_expr_with_target(ctx.emit_ctx, node.right.*, locals, ety);
                try ctx.out.appendSlice(ctx.allocator, ")");
                return;
            }
        }
    }
    try ctx.out.appendSlice(ctx.allocator, "(");
    try ctx.emit_expr(ctx.emit_ctx, node.left.*, locals);
    try ctx.out.print(ctx.allocator, " {s} ", .{binaryCOp(node.op)});
    try ctx.emit_expr(ctx.emit_ctx, node.right.*, locals);
    try ctx.out.appendSlice(ctx.allocator, ")");
}

fn binaryResolvesToFloat(ctx: EmitContext, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) bool {
    return ctx.expr_resolves_to_float(ctx.emit_ctx, node.left.*, locals) or ctx.expr_resolves_to_float(ctx.emit_ctx, node.right.*, locals);
}

pub fn exprIsNumericLiteral(expr: ast.Expr) bool {
    return switch (expr.kind) {
        // A char literal is a byte value; in arithmetic it adopts its sibling
        // operand's integer storage type (e.g. `c - '0'` over a `u8`).
        .int_literal, .float_literal, .char_literal => true,
        .grouped => |inner| exprIsNumericLiteral(inner.*),
        .unary => |node| node.op == .neg and exprIsNumericLiteral(node.expr.*),
        else => false,
    };
}

pub fn isNumericValueBinaryOp(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul, .div, .mod, .shl, .shr, .bit_and, .bit_or, .bit_xor => true,
        else => false,
    };
}

pub fn uncheckedNoOverflowCallOp(call: anytype) ?[]const u8 {
    if (call.type_args.len != 0 or call.args.len != 2) return null;
    const member = memberCallee(call.callee.*) orelse return null;
    if (!isIdentNamed(member.base.*, "unchecked")) return null;
    if (std.mem.eql(u8, member.name.text, "add")) return "add";
    if (std.mem.eql(u8, member.name.text, "sub")) return "sub";
    if (std.mem.eql(u8, member.name.text, "mul")) return "mul";
    return null;
}

pub fn uncheckedNoOverflowOperator(op: []const u8) []const u8 {
    if (std.mem.eql(u8, op, "add")) return "+";
    if (std.mem.eql(u8, op, "sub")) return "-";
    if (std.mem.eql(u8, op, "mul")) return "*";
    return "+";
}

pub fn isBitcastCall(call: anytype) bool {
    const name = calleeIdentName(call.callee.*) orelse return false;
    return std.mem.eql(u8, name, "bitcast");
}

pub fn bitcastReturnTypeForCall(call: anytype) ?ast.TypeExpr {
    if (!isBitcastCall(call) or call.type_args.len != 1) return null;
    return call.type_args[0];
}

pub fn intLiteralText(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .int_literal => |literal| literal,
        .grouped => |inner| intLiteralText(inner.*),
        else => null,
    };
}

pub fn isDeclassifyCall(call: anytype) bool {
    const name = calleeIdentName(call.callee.*) orelse return false;
    return std.mem.eql(u8, name, "declassify") or std.mem.eql(u8, name, "reveal");
}

pub fn sequencedConditionCandidate(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .grouped => |inner| sequencedConditionCandidate(inner.*),
        .binary => |node| isComparisonOp(node.op) and (exprContainsCall(node.left.*) or exprContainsCall(node.right.*)),
        else => false,
    };
}

pub fn exprContainsCall(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .call => true,
        .grouped, .address_of, .deref => |inner| exprContainsCall(inner.*),
        .try_expr => |inner| exprContainsCall(inner.operand.*),
        .unary => |node| exprContainsCall(node.expr.*),
        .binary => |node| exprContainsCall(node.left.*) or exprContainsCall(node.right.*),
        .index => |node| exprContainsCall(node.base.*) or exprContainsCall(node.index.*),
        .member => |node| exprContainsCall(node.base.*),
        .cast => |node| exprContainsCall(node.value.*),
        else => false,
    };
}

pub fn comparisonExpr(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .binary => |node| isComparisonOp(node.op),
        .grouped => |inner| comparisonExpr(inner.*),
        else => false,
    };
}
