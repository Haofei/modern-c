//! C backend control-flow analysis and emission helpers.

const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const lower_c_access = @import("lower_c_access.zig");
const lower_c_expr = @import("lower_c_expr.zig");
const lower_c_global = @import("lower_c_global.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_op = @import("lower_c_op.zig");
const lower_c_shape = @import("lower_c_shape.zig");
const lower_c_type = @import("lower_c_type.zig");

const GlobalAccess = lower_c_model.GlobalAccess;
const LocalInfo = lower_c_model.LocalInfo;
const LoopJumps = lower_c_model.LoopJumps;
const SequencedArgTemp = lower_c_model.SequencedArgTemp;
const binaryCOp = lower_c_op.binaryCOp;
const comparisonExpr = lower_c_expr.comparisonExpr;
const exprContainsCall = lower_c_expr.exprContainsCall;
const exprIsNumericLiteral = lower_c_expr.exprIsNumericLiteral;
const isBoolType = lower_c_type.isBoolType;
const isComparisonOp = lower_c_op.isComparisonOp;
const sameCStorageType = lower_c_type.sameCStorageType;
const sequencedConditionCandidate = lower_c_expr.sequencedConditionCandidate;
const simpleNameType = ast_query.simpleNameType;

pub const EmitExprFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void;
pub const EmitExprWithTargetFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) anyerror!void;
pub const EmitBlockItemsFn = *const fn (ctx: *anyopaque, block: ast.Block, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void;
pub const LocalInfoFromTypeFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) anyerror!LocalInfo;
pub const ArrayLenTextFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) anyerror!?[]const u8;
pub const CTypeFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8;
pub const ExprTypeFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr;
pub const EmitSequencedArgTempFn = *const fn (ctx: *anyopaque, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!SequencedArgTemp;
pub const EmitLoopFn = *const fn (ctx: *anyopaque, loop: ast.Loop, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void;
pub const ConditionOperandTypeFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?ast.TypeExpr;
pub const GlobalAssignmentTargetFn = *const fn (ctx: *anyopaque, target: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?GlobalAccess;
pub const EmitAssignTargetFn = *const fn (ctx: *anyopaque, target: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void;

pub const EmitContext = struct {
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: *usize,
    temp_index: *usize,
    next_loop_id: *u32,
    loop_ids: *std.ArrayList(u32),
    // G7: parallel to `loop_ids`; the source loop label (`outer:`) naming each
    // enclosing loop, or null for an unlabeled loop. Used to resolve a labeled
    // `break :outer` / `continue :outer` to the right loop id.
    loop_labels: *std.ArrayList(?[]const u8),
    loop_defer_marks: *std.ArrayList(usize),
    emit_ctx: *anyopaque,
    emit_expr: EmitExprFn,
    emit_expr_with_target: EmitExprWithTargetFn,
    emit_block_items: EmitBlockItemsFn,
    local_info_from_type: LocalInfoFromTypeFn,
    array_len_text: ArrayLenTextFn,
    emit_sequenced_arg_temp: EmitSequencedArgTempFn,
    emit_loop: EmitLoopFn,
    condition_operand_type: ConditionOperandTypeFn,
    operand_emit_type: ExprTypeFn,
    global_assignment_target: GlobalAssignmentTargetFn,
    emit_assign_target: EmitAssignTargetFn,
    c_type: CTypeFn,
};

pub const ForLoopHeader = struct {
    binding: ast.Ident,
    iterable: ast.Expr,
};

pub const ForLoopCore = struct {
    loop: ast.Loop,
    binding: ast.Ident,
    iterable: ast.Expr,
    locals: *std.StringHashMap(LocalInfo),
    return_ty: ?ast.TypeExpr,
    iterable_array_ty: ?ast.TypeExpr,
    element_ty: ?ast.TypeExpr,
    element_c_type: []const u8,
    index_name: []const u8,
    defer_stack_len: usize,
};

pub const ForLoopElementPlan = struct {
    iterable_array_ty: ?ast.TypeExpr,
    element_ty: ?ast.TypeExpr,
    element_c_type: []const u8,
};

// Resolve a break/continue target to an index into the loop stack. A labeled
// target (`break :outer`) searches outward for the matching loop label; a bare
// target picks the innermost loop. Returns null only when there is no loop
// (sema rejects labeled jumps to unknown labels, so a labeled target always
// resolves here when the program type-checked).
fn resolveLoopIndex(ctx: EmitContext, target: ?ast.Ident) ?usize {
    if (ctx.loop_ids.items.len == 0) return null;
    if (target) |t| {
        var i = ctx.loop_labels.items.len;
        while (i > 0) {
            i -= 1;
            if (ctx.loop_labels.items[i]) |lbl| {
                if (std.mem.eql(u8, lbl, t.text)) return i;
            }
        }
        return null;
    }
    return ctx.loop_ids.items.len - 1;
}

pub fn emitBreakStmt(ctx: EmitContext, target: ?ast.Ident) anyerror!void {
    try writeIndent(ctx);
    if (resolveLoopIndex(ctx, target)) |idx| {
        try ctx.out.print(ctx.allocator, "goto mc_break_{d};\n", .{ctx.loop_ids.items[idx]});
    } else {
        try ctx.out.appendSlice(ctx.allocator, "break;\n");
    }
}

pub fn emitContinueStmt(ctx: EmitContext, target: ?ast.Ident) anyerror!void {
    try writeIndent(ctx);
    if (resolveLoopIndex(ctx, target)) |idx| {
        try ctx.out.print(ctx.allocator, "goto mc_continue_{d};\n", .{ctx.loop_ids.items[idx]});
    } else {
        try ctx.out.appendSlice(ctx.allocator, "continue;\n");
    }
}

pub fn emitPlainWhileLoop(ctx: EmitContext, loop: ast.Loop, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, defer_stack_len: usize) anyerror!void {
    const id = ctx.next_loop_id.*;
    ctx.next_loop_id.* += 1;
    const label: ?[]const u8 = if (loop.loop_label) |l| l.text else null;
    const jumps = loopBodyJumps(loop.body, label);
    try ctx.loop_ids.append(ctx.allocator, id);
    defer _ = ctx.loop_ids.pop();
    try ctx.loop_labels.append(ctx.allocator, label);
    defer _ = ctx.loop_labels.pop();
    try ctx.loop_defer_marks.append(ctx.allocator, defer_stack_len);
    defer _ = ctx.loop_defer_marks.pop();
    try emitPlainWhileHeader(ctx, loop, locals);
    try emitPlainWhileBody(ctx, loop, locals, return_ty, id, jumps.cont);
    try emitPlainWhileFooter(ctx, id, jumps.brk);
}

pub fn forLoopHeader(ctx: EmitContext, loop: ast.Loop) !ForLoopHeader {
    const binding = loop.label orelse {
        try writeUnsupportedForLoop(ctx, "unsupported for loop without binding");
        return error.UnsupportedCEmission;
    };
    const iterable = loop.iterable orelse {
        try writeUnsupportedForLoop(ctx, "unsupported for loop without iterable");
        return error.UnsupportedCEmission;
    };
    return .{ .binding = binding, .iterable = iterable };
}

pub fn writeUnsupportedForLoop(ctx: EmitContext, message: []const u8) !void {
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "/* {s} */\n", .{message});
}

pub fn forLoopElementPlan(ctx: EmitContext, iterable_array_ty: ?ast.TypeExpr, element_ty: ast.TypeExpr) !ForLoopElementPlan {
    const element_c_type = try ctx.c_type(ctx.emit_ctx, element_ty);
    return .{
        .iterable_array_ty = iterable_array_ty,
        .element_ty = element_ty,
        .element_c_type = element_c_type,
    };
}

pub fn emitForLoopWithElementPlan(ctx: EmitContext, loop: ast.Loop, binding: ast.Ident, iterable: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, element: ForLoopElementPlan, defer_stack_len: usize) anyerror!void {
    const index_name = try std.fmt.allocPrint(ctx.scratch, "mc_i{d}", .{ctx.temp_index.*});
    ctx.temp_index.* += 1;

    try emitForLoopCore(ctx, .{
        .loop = loop,
        .binding = binding,
        .iterable = iterable,
        .locals = locals,
        .return_ty = return_ty,
        .iterable_array_ty = element.iterable_array_ty,
        .element_ty = element.element_ty,
        .element_c_type = element.element_c_type,
        .index_name = index_name,
        .defer_stack_len = defer_stack_len,
    });
}

pub fn emitForLoopSequencedIterable(ctx: EmitContext, loop: ast.Loop, iterable: ast.Expr, iterable_ty: ast.TypeExpr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
    if (!exprContainsCall(iterable)) return false;
    try emitForLoopWithMaterializedIterable(ctx, loop, iterable, locals, return_ty, iterable_ty);
    return true;
}

pub fn emitForLoopWithMaterializedIterable(ctx: EmitContext, loop: ast.Loop, iterable: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, iterable_ty: ast.TypeExpr) !void {
    const temp = try ctx.emit_sequenced_arg_temp(ctx.emit_ctx, iterable, locals, iterable_ty);

    var loop_locals = try lower_c_access.cloneLocals(ctx.allocator, locals.*);
    defer loop_locals.deinit();
    try loop_locals.put(temp.name, try ctx.local_info_from_type(ctx.emit_ctx, iterable_ty));

    var rewritten = loop;
    rewritten.iterable = ast.Expr{ .span = iterable.span, .kind = .{ .ident = .{ .span = iterable.span, .text = temp.name } } };
    try ctx.emit_loop(ctx.emit_ctx, rewritten, &loop_locals, return_ty);
}

pub fn emitSequencedConditionAssert(ctx: EmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    const condition = (try emitSequencedConditionValueTemp(ctx, expr, locals)) orelse return false;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "if (!{s}) mc_trap_Assert();\n", .{condition.name});
    return true;
}

pub fn emitSequencedConditionWhileLoop(ctx: EmitContext, loop: ast.Loop, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
    const condition = loop.iterable orelse return false;
    if (!sequencedConditionCandidate(condition)) return false;

    var nested = try lower_c_access.cloneLocals(ctx.allocator, locals.*);
    defer nested.deinit();

    try emitSequencedConditionWhileHeader(ctx);
    ctx.indent.* += 1;
    const condition_temp = (try emitSequencedConditionValueTemp(ctx, condition, &nested)) orelse {
        ctx.indent.* -= 1;
        return false;
    };
    try emitSequencedConditionWhileGuard(ctx, condition_temp.name);
    try ctx.emit_block_items(ctx.emit_ctx, loop.body, &nested, return_ty);
    ctx.indent.* -= 1;
    try emitSequencedConditionWhileFooter(ctx);
    return true;
}

pub fn emitSequencedConditionValueTemp(ctx: EmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!?SequencedArgTemp {
    const node = switch (expr.kind) {
        .grouped => |inner| return try emitSequencedConditionValueTemp(ctx, inner.*, locals),
        .binary => |node| node,
        else => return null,
    };
    if (!isComparisonOp(node.op)) return null;
    if (!exprContainsCall(node.left.*) and !exprContainsCall(node.right.*)) return null;

    const operand_types = try sequencedConditionOperandTypes(ctx, node, locals);
    return try emitSequencedComparisonTemp(ctx, expr.span, node, locals, operand_types.left, operand_types.right);
}

pub fn emitSequencedComparisonReturn(ctx: EmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
    const target_ty = return_ty orelse return false;
    if (!isBoolType(target_ty)) return false;
    const temp = (try emitSequencedConditionValueTemp(ctx, expr, locals)) orelse return false;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "return {s};\n", .{temp.name});
    return true;
}

pub fn emitSequencedComparisonLocalInit(ctx: EmitContext, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    if (!isBoolType(decl_ty)) return false;
    const temp = (try emitSequencedConditionValueTemp(ctx, initializer, locals)) orelse return false;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "bool {s} = {s};\n", .{ name, temp.name });
    return true;
}

pub fn emitBoolInferredLocalInit(ctx: EmitContext, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
    if (!comparisonExpr(initializer)) return false;
    const bool_ty = simpleNameType("bool", initializer.span);
    try locals.put(name, try ctx.local_info_from_type(ctx.emit_ctx, bool_ty));
    if (try emitSequencedComparisonLocalInit(ctx, name, bool_ty, initializer, locals)) return true;

    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "bool {s} = ", .{name});
    try ctx.emit_expr_with_target(ctx.emit_ctx, initializer, locals, bool_ty);
    try ctx.out.appendSlice(ctx.allocator, ";\n");
    return true;
}

pub fn emitSequencedComparisonAssignmentStmt(ctx: EmitContext, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
    const target_ty = if (ctx.operand_emit_type(ctx.emit_ctx, assignment.target, locals)) |ty| ty else blk: {
        const target = ctx.global_assignment_target(ctx.emit_ctx, assignment.target, locals) orelse return false;
        break :blk simpleNameType(target.info.type_name, assignment.value.span);
    };
    if (!isBoolType(target_ty)) return false;
    const temp = (try emitSequencedConditionValueTemp(ctx, assignment.value, locals)) orelse return false;

    try writeIndent(ctx);
    if (ctx.global_assignment_target(ctx.emit_ctx, assignment.target, locals)) |target| {
        try lower_c_global.appendGlobalStoreValue(ctx.allocator, ctx.out, target, temp.name);
    } else {
        try ctx.emit_assign_target(ctx.emit_ctx, assignment.target, locals);
        try ctx.out.print(ctx.allocator, " = {s};\n", .{temp.name});
    }
    return true;
}

pub fn emitForLoopCore(ctx: EmitContext, spec: ForLoopCore) anyerror!void {
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "for (uintptr_t {s} = 0; {s} < ", .{ spec.index_name, spec.index_name });
    if (lower_c_access.sliceAccessForExpr(spec.iterable, spec.locals)) |slice| {
        try ctx.emit_expr(ctx.emit_ctx, spec.iterable, spec.locals);
        try ctx.out.print(ctx.allocator, ".{s}", .{slice.len_field});
    } else if (lower_c_access.arrayLenForExpr(spec.iterable, spec.locals)) |len| {
        try ctx.out.appendSlice(ctx.allocator, len);
    } else if (spec.iterable_array_ty) |array_ty| {
        const len = (try ctx.array_len_text(ctx.emit_ctx, array_ty)) orelse return error.UnsupportedCEmission;
        try ctx.out.appendSlice(ctx.allocator, len);
    } else {
        try ctx.out.appendSlice(ctx.allocator, "0");
    }
    try ctx.out.print(ctx.allocator, "; {s} += 1) {{\n", .{spec.index_name});

    const id = ctx.next_loop_id.*;
    ctx.next_loop_id.* += 1;
    const label: ?[]const u8 = if (spec.loop.loop_label) |l| l.text else null;
    const jumps = loopBodyJumps(spec.loop.body, label);
    try ctx.loop_ids.append(ctx.allocator, id);
    defer _ = ctx.loop_ids.pop();
    try ctx.loop_labels.append(ctx.allocator, label);
    defer _ = ctx.loop_labels.pop();
    try ctx.loop_defer_marks.append(ctx.allocator, spec.defer_stack_len);
    defer _ = ctx.loop_defer_marks.pop();

    var nested = try lower_c_access.cloneLocals(ctx.allocator, spec.locals.*);
    defer nested.deinit();
    if (spec.element_ty) |ty| {
        try nested.put(spec.binding.text, try ctx.local_info_from_type(ctx.emit_ctx, ty));
    } else {
        try nested.put(spec.binding.text, .{ .c_type = spec.element_c_type });
    }

    ctx.indent.* += 1;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = ", .{ spec.element_c_type, spec.binding.text });
    if (lower_c_access.sliceAccessForExpr(spec.iterable, spec.locals)) |slice| {
        try ctx.emit_expr(ctx.emit_ctx, spec.iterable, spec.locals);
        try ctx.out.print(ctx.allocator, ".{s}[{s}]", .{ slice.ptr_field, spec.index_name });
    } else {
        try ctx.emit_expr(ctx.emit_ctx, spec.iterable, spec.locals);
        if (lower_c_access.arrayElemsFieldForExpr(spec.iterable, spec.locals)) |elems_field| {
            try ctx.out.print(ctx.allocator, ".{s}[{s}]", .{ elems_field, spec.index_name });
        } else if (spec.iterable_array_ty != null) {
            try ctx.out.print(ctx.allocator, ".elems[{s}]", .{spec.index_name});
        } else {
            try ctx.out.print(ctx.allocator, "[{s}]", .{spec.index_name});
        }
    }
    try ctx.out.appendSlice(ctx.allocator, ";\n");
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "(void){s};\n", .{spec.binding.text});
    try ctx.emit_block_items(ctx.emit_ctx, spec.loop.body, &nested, spec.return_ty);
    // `continue` lands here, then the for-step (`i += 1`) runs.
    if (jumps.cont) try ctx.out.print(ctx.allocator, "    mc_continue_{d}:;\n", .{id});
    ctx.indent.* -= 1;
    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "}\n");
    if (jumps.brk) try ctx.out.print(ctx.allocator, "    mc_break_{d}:;\n", .{id});
}

fn emitPlainWhileHeader(ctx: EmitContext, loop: ast.Loop, locals: *std.StringHashMap(LocalInfo)) anyerror!void {
    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "while (");
    if (loop.iterable) |condition| {
        try ctx.emit_expr(ctx.emit_ctx, condition, locals);
    } else {
        try ctx.out.appendSlice(ctx.allocator, "true");
    }
    try ctx.out.appendSlice(ctx.allocator, ") {\n");
}

fn emitSequencedConditionWhileHeader(ctx: EmitContext) !void {
    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "while (true) {\n");
}

fn emitSequencedConditionWhileGuard(ctx: EmitContext, condition_temp: []const u8) !void {
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "if (!{s}) break;\n", .{condition_temp});
}

fn emitSequencedConditionWhileFooter(ctx: EmitContext) !void {
    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "}\n");
}

fn sequencedConditionOperandTypes(ctx: EmitContext, node: anytype, locals: *std.StringHashMap(LocalInfo)) !struct { left: ast.TypeExpr, right: ast.TypeExpr } {
    var left_ty = ctx.condition_operand_type(ctx.emit_ctx, node.left.*, locals);
    var right_ty = ctx.condition_operand_type(ctx.emit_ctx, node.right.*, locals);
    // A bare numeric literal adopts the other operand's storage type, so
    // `call() != 0` compares at the call's width rather than the literal's
    // default `u32` (e.g. `(pte & PTE_V) != 0` over a `u64`).
    if (exprIsNumericLiteral(node.left.*) and right_ty != null) left_ty = right_ty;
    if (exprIsNumericLiteral(node.right.*) and left_ty != null) right_ty = left_ty;
    const lt = left_ty orelse return error.UnsupportedCEmission;
    const rt = right_ty orelse return error.UnsupportedCEmission;
    if (!sameCStorageType(lt, rt)) return error.UnsupportedCEmission;
    return .{ .left = lt, .right = rt };
}

fn emitSequencedComparisonTemp(ctx: EmitContext, span: ast.Span, node: anytype, locals: *std.StringHashMap(LocalInfo), left_ty: ast.TypeExpr, right_ty: ast.TypeExpr) anyerror!SequencedArgTemp {
    const left_temp = try ctx.emit_sequenced_arg_temp(ctx.emit_ctx, node.left.*, locals, left_ty);
    const right_temp = try ctx.emit_sequenced_arg_temp(ctx.emit_ctx, node.right.*, locals, right_ty);
    const bool_ty = simpleNameType("bool", span);
    const condition_temp = try std.fmt.allocPrint(ctx.scratch, "mc_tmp{d}", .{ctx.temp_index.*});
    ctx.temp_index.* += 1;

    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "bool {s} = ({s} {s} {s});\n", .{ condition_temp, left_temp.name, binaryCOp(node.op), right_temp.name });
    return .{ .name = condition_temp, .ty = bool_ty };
}

fn emitPlainWhileBody(ctx: EmitContext, loop: ast.Loop, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, id: u32, has_continue: bool) anyerror!void {
    var nested = try lower_c_access.cloneLocals(ctx.allocator, locals.*);
    defer nested.deinit();
    ctx.indent.* += 1;
    try ctx.emit_block_items(ctx.emit_ctx, loop.body, &nested, return_ty);
    if (has_continue) try ctx.out.print(ctx.allocator, "    mc_continue_{d}:;\n", .{id});
    ctx.indent.* -= 1;
}

fn emitPlainWhileFooter(ctx: EmitContext, id: u32, has_break: bool) !void {
    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "}\n");
    if (has_break) try ctx.out.print(ctx.allocator, "    mc_break_{d}:;\n", .{id});
}

pub fn loopBodyHasOwnBreakContinue(block: ast.Block) LoopJumps {
    return loopBodyJumps(block, null);
}

// Whether a loop needs `mc_break_N` / `mc_continue_N` labels. `label` is the
// loop's own source label (or null). A jump counts toward this loop when it is
// a bare jump at this loop's own level (innermost target) OR a labeled jump
// naming `label`, wherever it appears — including inside nested loops, since a
// `break :outer` deep inside still targets this loop.
pub fn loopBodyJumps(block: ast.Block, label: ?[]const u8) LoopJumps {
    var out = LoopJumps{};
    for (block.items) |stmt| {
        const j = stmtJumps(stmt, label, true);
        out.brk = out.brk or j.brk;
        out.cont = out.cont or j.cont;
    }
    return out;
}

fn writeIndent(ctx: EmitContext) !void {
    for (0..ctx.indent.*) |_| try ctx.out.appendSlice(ctx.allocator, "    ");
}

fn labelHits(target: ?ast.Ident, label: ?[]const u8) bool {
    const t = target orelse return false;
    const l = label orelse return false;
    return std.mem.eql(u8, t.text, l);
}

// `own` is true while walking statements that live directly in the target
// loop's body (bare jumps target it). Descending into a nested loop clears
// `own`, so bare jumps there belong to the nested loop and only labeled jumps
// matching `label` still count.
fn stmtJumps(stmt: ast.Stmt, label: ?[]const u8, own: bool) LoopJumps {
    return switch (stmt.kind) {
        .@"break" => |target| .{ .brk = (own and target == null) or labelHits(target, label) },
        .@"continue" => |target| .{ .cont = (own and target == null) or labelHits(target, label) },
        .block, .unsafe_block, .comptime_block => |b| blockJumps(b, label, own),
        .contract_block => |n| blockJumps(n.block, label, own),
        .if_let => |n| blk: {
            var j = blockJumps(n.then_block, label, own);
            if (n.else_block) |e| {
                const ej = blockJumps(e, label, own);
                j.brk = j.brk or ej.brk;
                j.cont = j.cont or ej.cont;
            }
            break :blk j;
        },
        .@"switch" => |n| blk: {
            var j = LoopJumps{};
            for (n.arms) |arm| {
                switch (arm.body) {
                    .block => |b| {
                        const aj = blockJumps(b, label, own);
                        j.brk = j.brk or aj.brk;
                        j.cont = j.cont or aj.cont;
                    },
                    .expr => {},
                }
            }
            break :blk j;
        },
        // A nested loop captures its own bare break/continue; only labeled jumps
        // naming an outer loop still propagate, so recurse with `own = false`.
        .loop => |nested| blockJumps(nested.body, label, false),
        else => .{},
    };
}

fn blockJumps(block: ast.Block, label: ?[]const u8, own: bool) LoopJumps {
    var out = LoopJumps{};
    for (block.items) |stmt| {
        const j = stmtJumps(stmt, label, own);
        out.brk = out.brk or j.brk;
        out.cont = out.cont or j.cont;
    }
    return out;
}
