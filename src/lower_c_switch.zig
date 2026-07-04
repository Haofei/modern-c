//! C backend switch subject and branch classifiers.

const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const lower_c_access = @import("lower_c_access.zig");
const lower_c_const = @import("lower_c_const.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_mmio = @import("lower_c_mmio.zig");
const lower_c_type = @import("lower_c_type.zig");
const switch_lower = @import("switch_lower.zig");

const LocalInfo = lower_c_model.LocalInfo;
const MmioReadReplacement = lower_c_model.MmioReadReplacement;
const NullableSwitchBranch = lower_c_model.NullableSwitchBranch;
const NullableSwitchSubject = lower_c_model.NullableSwitchSubject;
const ResultSwitchBranch = lower_c_model.ResultSwitchBranch;
const ResultSwitchSubject = lower_c_model.ResultSwitchSubject;
const TaggedUnionSwitchBranch = lower_c_model.TaggedUnionSwitchBranch;
const TaggedUnionSwitchSubject = lower_c_model.TaggedUnionSwitchSubject;

const calleeIdentName = ast_query.calleeIdentName;
const cPayloadFieldName = lower_c_type.cPayloadFieldName;
const isDynCTypeName = lower_c_type.isDynCTypeName;
const nullableInnerTypeExpr = lower_c_type.nullableInnerTypeExpr;
const taggedUnionCase = ast_query.taggedUnionCase;

pub const EmitExprFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void;
pub const EmitReadExprWithReplacementsFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr, replacements: []const MmioReadReplacement) anyerror!void;
pub const EmitSwitchBodyFn = *const fn (ctx: *anyopaque, body: ast.SwitchBody, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void;
pub const LocalInfoFromTypeFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) anyerror!LocalInfo;
pub const CTypeFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8;
pub const CIdentFn = *const fn (ctx: *anyopaque, name: []const u8) anyerror![]const u8;
pub const ExprTypeFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr;
pub const EmitSequencedArgTempFn = *const fn (ctx: *anyopaque, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!lower_c_model.SequencedArgTemp;
pub const NullableInnerCTypeFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) anyerror!?[]const u8;

pub const EmitContext = struct {
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: *usize,
    emit_ctx: *anyopaque,
    emit_expr: EmitExprFn,
    emit_read_expr_with_replacements: EmitReadExprWithReplacementsFn,
    emit_switch_body: EmitSwitchBodyFn,
    local_info_from_type: LocalInfoFromTypeFn,
    c_type: CTypeFn,
    c_ident: CIdentFn,
    result_type_for_expr: ExprTypeFn,
    tagged_union_type_for_expr: ExprTypeFn,
    nullable_type_for_expr: ExprTypeFn,
    nullable_inner_c_type_for_type: NullableInnerCTypeFn,
    emit_sequenced_arg_temp: EmitSequencedArgTempFn,
    tagged_unions: *const std.StringHashMap(ast.UnionDecl),
};

pub const GenericSwitchSpec = struct {
    node: ast.Switch,
    locals: *std.StringHashMap(LocalInfo),
    return_ty: ?ast.TypeExpr,
    subject_enum_name: ?[]const u8,
    subject_is_bool: bool,
    subject_replacements: []const MmioReadReplacement,
};

pub const ConditionalEmitState = struct {
    emitted_any: bool = false,
};

pub const ResultEmitState = struct {
    emitted_any: bool = false,
    seen_ok: bool = false,
    seen_err: bool = false,
};

pub fn emitSwitchPatternLabel(allocator: std.mem.Allocator, out: *std.ArrayList(u8), pattern: ast.Pattern, subject_enum_name: ?[]const u8) !void {
    switch (pattern.kind) {
        .literal => |expr| if (lower_c_const.switchCaseValueSupported(expr)) {
            try out.appendSlice(allocator, "case ");
            try emitSwitchCaseValue(allocator, out, expr);
            try out.appendSlice(allocator, ":\n");
        } else if (ast_query.boolLiteralValue(expr)) |value| {
            try out.print(allocator, "case {d}:\n", .{@intFromBool(value)});
        } else {
            try out.print(allocator, "/* unsupported switch pattern: {s} */\n", .{@tagName(pattern.kind)});
            return error.UnsupportedCEmission;
        },
        .tag => |tag| {
            const enum_name = subject_enum_name orelse {
                try out.print(allocator, "/* unsupported switch tag without enum subject: {s} */\n", .{tag.text});
                return error.UnsupportedCEmission;
            };
            try out.print(allocator, "case {s}_{s}:\n", .{ enum_name, tag.text });
        },
        .wildcard => try out.appendSlice(allocator, "default:\n"),
        else => {
            try out.print(allocator, "/* unsupported switch pattern: {s} */\n", .{@tagName(pattern.kind)});
            return error.UnsupportedCEmission;
        },
    }
}

pub fn emitConditionalBranchOpen(allocator: std.mem.Allocator, out: *std.ArrayList(u8), condition: ?[]const u8, state: *ConditionalEmitState) !void {
    if (!state.emitted_any) {
        if (condition) |cond| {
            try out.print(allocator, "if ({s}) {{\n", .{cond});
        } else {
            try out.appendSlice(allocator, "{\n");
        }
    } else if (condition) |cond| {
        try out.print(allocator, "else if ({s}) {{\n", .{cond});
    } else {
        try out.appendSlice(allocator, "else {\n");
    }
    state.emitted_any = true;
}

pub fn emitResultBranchOpen(allocator: std.mem.Allocator, out: *std.ArrayList(u8), branch: ResultSwitchBranch, state: *ResultEmitState) !void {
    if (!state.emitted_any) {
        if (branch.condition) |condition| {
            try out.print(allocator, "if ({s}) {{\n", .{condition});
        } else {
            try out.appendSlice(allocator, "{\n");
        }
    } else if (branch.condition) |condition| {
        const complement = if (branch.tag) |tag|
            (std.mem.eql(u8, tag, "ok") and state.seen_err) or (std.mem.eql(u8, tag, "err") and state.seen_ok)
        else
            false;
        if (complement) {
            try out.appendSlice(allocator, "else {\n");
        } else {
            try out.print(allocator, "else if ({s}) {{\n", .{condition});
        }
    } else {
        try out.appendSlice(allocator, "else {\n");
    }

    state.emitted_any = true;
    if (branch.tag) |tag| {
        if (std.mem.eql(u8, tag, "ok")) state.seen_ok = true;
        if (std.mem.eql(u8, tag, "err")) state.seen_err = true;
    }
}

pub fn emitGenericSwitch(ctx: EmitContext, spec: GenericSwitchSpec) anyerror!void {
    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "switch (");
    try emitGenericSwitchSubject(ctx, spec.node.subject, spec.locals, spec.subject_is_bool, spec.subject_replacements);
    try ctx.out.appendSlice(ctx.allocator, ") {\n");

    ctx.indent.* += 1;
    const has_wildcard = try emitGenericSwitchArms(ctx, spec.node.arms, spec.locals, spec.return_ty, spec.subject_enum_name);
    try emitGenericSwitchDefaultTrap(ctx, spec.subject_enum_name, spec.subject_is_bool, has_wildcard);
    ctx.indent.* -= 1;

    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "}\n");
}

pub fn emitGenericSwitchWithMmioSubjectHoists(ctx: EmitContext, mmio_ctx: lower_c_mmio.EmitContext, spec: GenericSwitchSpec) anyerror!void {
    var replacements: std.ArrayList(MmioReadReplacement) = .empty;
    defer replacements.deinit(mmio_ctx.scratch);
    if (try lower_c_mmio.collectReadHoistsForExpr(mmio_ctx, spec.node.subject, spec.locals, &replacements)) {
        var switch_locals = try lower_c_mmio.emitReadReplacementFrame(mmio_ctx.context, spec.locals.*, replacements.items);
        defer switch_locals.deinit();

        var hoisted_spec = spec;
        hoisted_spec.locals = &switch_locals;
        hoisted_spec.subject_replacements = replacements.items;
        return try emitGenericSwitch(ctx, hoisted_spec);
    }

    var plain_spec = spec;
    plain_spec.subject_replacements = &[_]MmioReadReplacement{};
    try emitGenericSwitch(ctx, plain_spec);
}

pub fn emitResultSwitch(ctx: EmitContext, node: ast.Switch, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, subject: ResultSwitchSubject) anyerror!bool {
    var branch_state: ResultEmitState = .{};
    for (node.arms) |arm| {
        const branch = (try resultSwitchBranch(ctx.scratch, arm.patterns, subject)) orelse {
            try writeIndent(ctx);
            try ctx.out.appendSlice(ctx.allocator, "/* unsupported result switch pattern */\n");
            return error.UnsupportedCEmission;
        };

        try writeIndent(ctx);
        try emitResultBranchOpen(ctx.allocator, ctx.out, branch, &branch_state);
        try emitResultSwitchBranchBody(ctx, arm.body, locals, return_ty, subject, branch);
    }
    return branch_state.emitted_any;
}

pub fn emitNullableSwitch(ctx: EmitContext, node: ast.Switch, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, subject: NullableSwitchSubject) anyerror!bool {
    var branch_state: ConditionalEmitState = .{};
    for (node.arms) |arm| {
        if (arm.patterns.len != 1) return false;
        const branch = (try nullableSwitchBranch(ctx.scratch, arm.patterns[0], subject)) orelse return false;

        try writeIndent(ctx);
        try emitConditionalBranchOpen(ctx.allocator, ctx.out, branch.condition, &branch_state);
        try emitNullableSwitchBranchBody(ctx, arm.body, locals, return_ty, subject, branch);
    }
    return branch_state.emitted_any;
}

pub fn emitTaggedUnionSwitch(ctx: EmitContext, node: ast.Switch, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, subject: TaggedUnionSwitchSubject) anyerror!bool {
    var branch_state: ConditionalEmitState = .{};
    var has_wildcard = false;
    for (node.arms) |arm| {
        const branch = (try taggedUnionSwitchBranch(ctx.scratch, arm.patterns, subject)) orelse {
            try writeIndent(ctx);
            try ctx.out.appendSlice(ctx.allocator, "/* unsupported tagged union switch pattern */\n");
            return error.UnsupportedCEmission;
        };
        if (branch.is_wildcard) has_wildcard = true;

        try writeIndent(ctx);
        try emitConditionalBranchOpen(ctx.allocator, ctx.out, branch.condition, &branch_state);
        try emitTaggedUnionSwitchBranchBody(ctx, arm.body, locals, return_ty, subject, branch);
    }
    try emitTaggedUnionSwitchDefaultTrap(ctx, has_wildcard);
    return branch_state.emitted_any;
}

pub fn emitTaggedUnionSwitchDefaultTrap(ctx: EmitContext, has_wildcard: bool) !void {
    if (has_wildcard) return;
    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "else {\n");
    ctx.indent.* += 1;
    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "mc_trap_InvalidRepresentation();\n");
    ctx.indent.* -= 1;
    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "}\n");
}

pub fn emitNullableIfLet(ctx: EmitContext, node: ast.IfLet, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, subject: NullableSwitchSubject) anyerror!void {
    const binding = switch (node.pattern.kind) {
        .bind => |ident| ident,
        else => {
            try writeIndent(ctx);
            try ctx.out.print(ctx.allocator, "/* unsupported if-let pattern: {s} */\n", .{@tagName(node.pattern.kind)});
            return error.UnsupportedCEmission;
        },
    };

    try emitNullableIfLetThen(ctx, node, locals, return_ty, subject, binding);
    try emitIfLetElse(ctx, node.else_block, locals, return_ty);
    try ctx.out.appendSlice(ctx.allocator, "\n");
}

pub fn emitResultIfLet(ctx: EmitContext, node: ast.IfLet, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, subject: ResultSwitchSubject) anyerror!void {
    const tag_bind = switch (node.pattern.kind) {
        .tag_bind => |tag_bind| tag_bind,
        else => unreachable,
    };
    const is_ok = try resultIfLetTagIsOk(ctx, tag_bind.tag);
    const bind_ty = if (is_ok) subject.ok_c_type else subject.err_c_type;
    const payload_field = if (is_ok) "ok" else "err";

    try emitResultIfLetThen(ctx, node, locals, return_ty, subject, tag_bind.binding, is_ok, bind_ty, payload_field);
    try emitIfLetElse(ctx, node.else_block, locals, return_ty);
    try ctx.out.appendSlice(ctx.allocator, "\n");
}

pub fn emitResultSwitchBranchBody(ctx: EmitContext, body: ast.SwitchBody, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, subject: ResultSwitchSubject, branch: ResultSwitchBranch) anyerror!void {
    var nested = try lower_c_access.cloneLocals(ctx.allocator, locals.*);
    defer nested.deinit();
    ctx.indent.* += 1;
    if (branch.binding_name) |binding_name| {
        try emitResultSwitchBinding(ctx, &nested, subject, branch, binding_name);
    }
    try ctx.emit_switch_body(ctx.emit_ctx, body, &nested, return_ty);
    ctx.indent.* -= 1;
    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "}\n");
}

pub fn emitNullableSwitchBranchBody(ctx: EmitContext, body: ast.SwitchBody, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, subject: NullableSwitchSubject, branch: NullableSwitchBranch) anyerror!void {
    var nested = try lower_c_access.cloneLocals(ctx.allocator, locals.*);
    defer nested.deinit();
    ctx.indent.* += 1;
    if (branch.binding_name) |binding_name| {
        try emitNullableSwitchBinding(ctx, &nested, subject, binding_name);
    }
    try ctx.emit_switch_body(ctx.emit_ctx, body, &nested, return_ty);
    ctx.indent.* -= 1;
    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "}\n");
}

pub fn emitTaggedUnionSwitchBranchBody(ctx: EmitContext, body: ast.SwitchBody, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, subject: TaggedUnionSwitchSubject, branch: TaggedUnionSwitchBranch) anyerror!void {
    var nested = try lower_c_access.cloneLocals(ctx.allocator, locals.*);
    defer nested.deinit();
    ctx.indent.* += 1;
    if (branch.binding_name) |binding_name| {
        try emitTaggedUnionSwitchBinding(ctx, &nested, subject, branch, binding_name);
    }
    try ctx.emit_switch_body(ctx.emit_ctx, body, &nested, return_ty);
    ctx.indent.* -= 1;
    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "}\n");
}

fn emitNullableIfLetThen(ctx: EmitContext, node: ast.IfLet, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, subject: NullableSwitchSubject, binding: ast.Ident) anyerror!void {
    try writeIndent(ctx);
    var cond_buf: [256]u8 = undefined;
    try ctx.out.print(ctx.allocator, "if ({s}) {{\n", .{subject.someCond(&cond_buf)});
    var then_locals = try lower_c_access.cloneLocals(ctx.allocator, locals.*);
    defer then_locals.deinit();
    const binding_info: LocalInfo = if (subject.inner_ty) |it| try ctx.local_info_from_type(ctx.emit_ctx, it) else .{ .c_type = subject.inner_c_type };
    try then_locals.put(binding.text, binding_info);
    ctx.indent.* += 1;
    try writeIndent(ctx);
    var val_buf: [256]u8 = undefined;
    try ctx.out.print(ctx.allocator, "MC_UNUSED {s} {s} = {s};\n", .{ subject.inner_c_type, try ctx.c_ident(ctx.emit_ctx, binding.text), subject.valueExpr(&val_buf) });
    try ctx.emit_switch_body(ctx.emit_ctx, .{ .block = node.then_block }, &then_locals, return_ty);
    ctx.indent.* -= 1;
    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "}");
}

fn emitResultIfLetThen(
    ctx: EmitContext,
    node: ast.IfLet,
    locals: *std.StringHashMap(LocalInfo),
    return_ty: ?ast.TypeExpr,
    subject: ResultSwitchSubject,
    binding: ast.Ident,
    is_ok: bool,
    bind_ty: []const u8,
    payload_field: []const u8,
) anyerror!void {
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "if ({s}{s}.is_ok) {{\n", .{ if (is_ok) "" else "!", subject.name });
    var then_locals = try lower_c_access.cloneLocals(ctx.allocator, locals.*);
    defer then_locals.deinit();
    ctx.indent.* += 1;
    try emitResultIfLetBinding(ctx, &then_locals, binding.text, bind_ty, subject.name, payload_field);
    try ctx.emit_switch_body(ctx.emit_ctx, .{ .block = node.then_block }, &then_locals, return_ty);
    ctx.indent.* -= 1;
    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "}");
}

fn emitResultIfLetBinding(ctx: EmitContext, locals: *std.StringHashMap(LocalInfo), binding: []const u8, bind_ty: []const u8, subject_name: []const u8, payload_field: []const u8) !void {
    try locals.put(binding, .{ .c_type = bind_ty });
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "MC_UNUSED {s} {s} = {s}.payload.{s};\n", .{ bind_ty, binding, subject_name, payload_field });
}

fn emitIfLetElse(ctx: EmitContext, maybe_else: ?ast.Block, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
    if (maybe_else) |else_block| {
        try ctx.out.appendSlice(ctx.allocator, " else {\n");
        var else_locals = try lower_c_access.cloneLocals(ctx.allocator, locals.*);
        defer else_locals.deinit();
        ctx.indent.* += 1;
        try ctx.emit_switch_body(ctx.emit_ctx, .{ .block = else_block }, &else_locals, return_ty);
        ctx.indent.* -= 1;
        try writeIndent(ctx);
        try ctx.out.appendSlice(ctx.allocator, "}");
    }
}

fn resultIfLetTagIsOk(ctx: EmitContext, tag: ast.Ident) !bool {
    if (std.mem.eql(u8, tag.text, "ok")) return true;
    if (std.mem.eql(u8, tag.text, "err")) return false;
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "/* unsupported result if-let tag: {s} */\n", .{tag.text});
    return error.UnsupportedCEmission;
}

fn emitResultSwitchBinding(ctx: EmitContext, locals: *std.StringHashMap(LocalInfo), subject: ResultSwitchSubject, branch: ResultSwitchBranch, binding_name: []const u8) anyerror!void {
    const payload_src = if (std.mem.eql(u8, branch.payload_field.?, "err")) subject.err_source_ty else subject.ok_source_ty;
    var binding_info: LocalInfo = .{ .c_type = branch.binding_type.? };
    if (payload_src) |src| binding_info = try ctx.local_info_from_type(ctx.emit_ctx, src);
    try locals.put(binding_name, binding_info);
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "MC_UNUSED {s} {s} = {s}.payload.{s};\n", .{ branch.binding_type.?, binding_name, subject.name, branch.payload_field.? });
}

fn emitNullableSwitchBinding(ctx: EmitContext, locals: *std.StringHashMap(LocalInfo), subject: NullableSwitchSubject, binding_name: []const u8) anyerror!void {
    const binding_info: LocalInfo = if (subject.inner_ty) |it| try ctx.local_info_from_type(ctx.emit_ctx, it) else .{ .c_type = subject.inner_c_type };
    try locals.put(binding_name, binding_info);
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "MC_UNUSED {s} {s} = {s};\n", .{ subject.inner_c_type, binding_name, subject.name });
}

fn emitTaggedUnionSwitchBinding(ctx: EmitContext, locals: *std.StringHashMap(LocalInfo), subject: TaggedUnionSwitchSubject, branch: TaggedUnionSwitchBranch, binding_name: []const u8) anyerror!void {
    const binding_type = try ctx.c_type(ctx.emit_ctx, branch.binding_source_ty.?);
    try locals.put(binding_name, .{ .c_type = binding_type, .source_ty = branch.binding_source_ty });
    try writeIndent(ctx);
    try ctx.out.print(ctx.allocator, "{s} {s} = {s}.payload.{s};\n", .{
        binding_type,
        binding_name,
        subject.name,
        try cPayloadFieldName(ctx.scratch, branch.payload_field.?),
    });
}

fn emitGenericSwitchSubject(ctx: EmitContext, subject: ast.Expr, locals: *std.StringHashMap(LocalInfo), subject_is_bool: bool, subject_replacements: []const MmioReadReplacement) anyerror!void {
    if (subject_is_bool) try ctx.out.appendSlice(ctx.allocator, "(int)(");
    if (subject_replacements.len > 0) {
        try ctx.emit_read_expr_with_replacements(ctx.emit_ctx, subject, locals, null, subject_replacements);
    } else {
        try ctx.emit_expr(ctx.emit_ctx, subject, locals);
    }
    if (subject_is_bool) try ctx.out.appendSlice(ctx.allocator, ")");
}

fn emitGenericSwitchArms(ctx: EmitContext, arms: []const ast.SwitchArm, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, subject_enum_name: ?[]const u8) anyerror!bool {
    var has_wildcard = false;
    for (arms) |arm| {
        for (arm.patterns) |pattern| {
            if (pattern.kind == .wildcard) has_wildcard = true;
            try writeIndent(ctx);
            try emitSwitchPatternLabel(ctx.allocator, ctx.out, pattern, subject_enum_name);
        }
        try emitGenericSwitchArmBody(ctx, arm.body, locals, return_ty);
    }
    return has_wildcard;
}

fn emitGenericSwitchArmBody(ctx: EmitContext, body: ast.SwitchBody, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "{\n");
    var nested = try lower_c_access.cloneLocals(ctx.allocator, locals.*);
    defer nested.deinit();
    ctx.indent.* += 1;
    try ctx.emit_switch_body(ctx.emit_ctx, body, &nested, return_ty);
    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "break;\n");
    ctx.indent.* -= 1;
    try writeIndent(ctx);
    try ctx.out.appendSlice(ctx.allocator, "}\n");
}

fn emitGenericSwitchDefaultTrap(ctx: EmitContext, subject_enum_name: ?[]const u8, subject_is_bool: bool, has_wildcard: bool) !void {
    if ((subject_enum_name != null or subject_is_bool) and !has_wildcard) {
        try writeIndent(ctx);
        try ctx.out.appendSlice(ctx.allocator, "default:\n");
        ctx.indent.* += 1;
        try writeIndent(ctx);
        try ctx.out.appendSlice(ctx.allocator, "mc_trap_InvalidRepresentation();\n");
        ctx.indent.* -= 1;
    }
}

fn emitSwitchCaseValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), expr: ast.Expr) !void {
    switch (expr.kind) {
        .int_literal => |literal| try lower_c_const.appendCIntLiteral(allocator, out, literal),
        .char_literal => |literal| try out.appendSlice(allocator, literal),
        .grouped => |inner| try emitSwitchCaseValue(allocator, out, inner.*),
        .unary => |node| {
            try out.appendSlice(allocator, "-");
            try emitSwitchCaseValue(allocator, out, node.expr.*);
        },
        else => unreachable,
    }
}

fn writeIndent(ctx: EmitContext) !void {
    for (0..ctx.indent.*) |_| try ctx.out.appendSlice(ctx.allocator, "    ");
}

pub fn nullableSwitchBranch(allocator: std.mem.Allocator, pattern: ast.Pattern, subject: NullableSwitchSubject) !?NullableSwitchBranch {
    var cond_buf: [256]u8 = undefined;
    return switch (pattern.kind) {
        .bind => |binding| NullableSwitchBranch{
            .condition = try std.fmt.allocPrint(allocator, "{s}", .{subject.someCond(&cond_buf)}),
            .binding_name = binding.text,
        },
        .wildcard => NullableSwitchBranch{ .condition = null },
        else => null,
    };
}

pub fn resultSubjectForExpr(expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?ResultSwitchSubject {
    const name = calleeIdentName(expr) orelse return null;
    const info = locals.get(name) orelse return null;
    const ok_ty = info.result_ok_c_type orelse return null;
    const err_ty = info.result_err_c_type orelse return null;
    var ok_src: ?ast.TypeExpr = null;
    var err_src: ?ast.TypeExpr = null;
    if (info.result_ty) |rty| switch (rty.kind) {
        .generic => |g| if (g.args.len == 2) {
            ok_src = g.args[0];
            err_src = g.args[1];
        },
        else => {},
    };
    return .{ .name = name, .ok_c_type = ok_ty, .err_c_type = err_ty, .ok_source_ty = ok_src, .err_source_ty = err_src };
}

pub fn resultSubjectForValueExpr(ctx: EmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !?ResultSwitchSubject {
    if (resultSubjectForExpr(expr, locals)) |subject| return subject;
    const result_ty = ctx.result_type_for_expr(ctx.emit_ctx, expr, locals) orelse return null;
    const temp = try ctx.emit_sequenced_arg_temp(ctx.emit_ctx, expr, locals, result_ty);
    try locals.put(temp.name, try ctx.local_info_from_type(ctx.emit_ctx, result_ty));
    return resultSubjectForExpr(.{ .kind = .{ .ident = .{ .text = temp.name, .span = expr.span } }, .span = expr.span }, locals);
}

pub fn resultSwitchBranch(allocator: std.mem.Allocator, patterns: []const ast.Pattern, subject: ResultSwitchSubject) !?ResultSwitchBranch {
    if (patterns.len == 0) return null;
    if (patterns.len == 1) {
        if (patterns[0].kind == .wildcard) return .{ .condition = null };
        const arm = switch_lower.resultArmPattern(patterns[0]) orelse return null;
        const is_ok = std.mem.eql(u8, arm.tag, "ok");
        if (!is_ok and !std.mem.eql(u8, arm.tag, "err")) return null;
        const condition = if (is_ok)
            try std.fmt.allocPrint(allocator, "{s}.is_ok", .{subject.name})
        else
            try std.fmt.allocPrint(allocator, "!{s}.is_ok", .{subject.name});
        if (arm.binding) |binding| {
            return .{
                .condition = condition,
                .tag = if (is_ok) "ok" else "err",
                .binding_name = binding.text,
                .binding_type = if (is_ok) subject.ok_c_type else subject.err_c_type,
                .payload_field = if (is_ok) "ok" else "err",
            };
        }
        return .{ .condition = condition, .tag = if (is_ok) "ok" else "err" };
    }

    var condition: std.ArrayList(u8) = .empty;
    for (patterns, 0..) |pattern, index| {
        const tag = switch (pattern.kind) {
            .tag => |tag| tag,
            else => return null,
        };
        const tag_condition = if (std.mem.eql(u8, tag.text, "ok"))
            try std.fmt.allocPrint(allocator, "{s}.is_ok", .{subject.name})
        else if (std.mem.eql(u8, tag.text, "err"))
            try std.fmt.allocPrint(allocator, "!{s}.is_ok", .{subject.name})
        else
            return null;
        if (index > 0) try condition.appendSlice(allocator, " || ");
        try condition.appendSlice(allocator, tag_condition);
    }
    return .{ .condition = try condition.toOwnedSlice(allocator) };
}

pub fn taggedUnionSubjectForExpr(expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), tagged_unions: anytype) ?TaggedUnionSwitchSubject {
    const name = calleeIdentName(expr) orelse return null;
    const info = locals.get(name) orelse return null;
    const type_name = info.source_type_name orelse return null;
    const union_decl = tagged_unions.get(type_name) orelse return null;
    return .{ .name = name, .type_name = type_name, .decl = union_decl };
}

pub fn taggedUnionSubjectForValueExpr(ctx: EmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !?TaggedUnionSwitchSubject {
    if (taggedUnionSubjectForExpr(expr, locals, ctx.tagged_unions)) |subject| return subject;
    const union_ty = ctx.tagged_union_type_for_expr(ctx.emit_ctx, expr, locals) orelse return null;
    const temp = try ctx.emit_sequenced_arg_temp(ctx.emit_ctx, expr, locals, union_ty);
    try locals.put(temp.name, try ctx.local_info_from_type(ctx.emit_ctx, union_ty));
    return taggedUnionSubjectForExpr(.{ .kind = .{ .ident = .{ .text = temp.name, .span = expr.span } }, .span = expr.span }, locals, ctx.tagged_unions);
}

pub fn nullableSubjectForExpr(ctx: EmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !?NullableSwitchSubject {
    if (nullableSourceName(expr)) |name| {
        if (nullableSubjectForLocalName(name, locals)) |subject| return subject;
        if (locals.contains(name)) return null;
    }
    return try materializeNullableSubject(ctx, expr, locals);
}

fn nullableSourceName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .ident => |ident| ident.text,
        .grouped => |inner| nullableSourceName(inner.*),
        else => null,
    };
}

fn nullableSubjectForLocalName(name: []const u8, locals: *std.StringHashMap(LocalInfo)) ?NullableSwitchSubject {
    const info = locals.get(name) orelse return null;
    const inner_c_type = info.nullable_inner_c_type orelse return null;
    const inner_ty = if (info.source_ty) |st| nullableInnerTypeExpr(st) else null;
    return .{
        .name = name,
        .inner_c_type = inner_c_type,
        .is_dyn = isDynCTypeName(inner_c_type),
        .inner_ty = inner_ty,
        .is_value_opt = nullablePayloadIsValueOptional(info.source_ty),
    };
}

// True when a `?T` (given as the whole optional TypeExpr) uses the tagged value repr —
// i.e. its payload T is a named value type (scalar/struct/enum/address), not a pointer,
// slice, fn-pointer, or `*dyn`. Mirrors lower_c_type.nullablePayloadIsValueType.
fn nullablePayloadIsValueOptional(opt_ty: ?ast.TypeExpr) bool {
    const ty = opt_ty orelse return false;
    const child = nullableInnerTypeExpr(ty) orelse return false;
    return payloadKindIsValue(child);
}

fn payloadKindIsValue(child: ast.TypeExpr) bool {
    return switch (child.kind) {
        .name => |n| !std.mem.eql(u8, n.text, "c_void"),
        .qualified => |node| payloadKindIsValue(node.child.*),
        else => false,
    };
}

fn materializeNullableSubject(ctx: EmitContext, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !?NullableSwitchSubject {
    const nullable_ty = ctx.nullable_type_for_expr(ctx.emit_ctx, expr, locals) orelse return null;
    const inner_c_type = try ctx.nullable_inner_c_type_for_type(ctx.emit_ctx, nullable_ty) orelse return null;
    const temp = try ctx.emit_sequenced_arg_temp(ctx.emit_ctx, expr, locals, nullable_ty);
    const temp_info = try ctx.local_info_from_type(ctx.emit_ctx, nullable_ty);
    try locals.put(temp.name, temp_info);
    return .{
        .name = temp.name,
        .inner_c_type = inner_c_type,
        .is_dyn = isDynCTypeName(inner_c_type),
        .inner_ty = if (temp_info.source_ty) |st| nullableInnerTypeExpr(st) else nullableInnerTypeExpr(nullable_ty),
        .is_value_opt = nullablePayloadIsValueOptional(temp_info.source_ty orelse nullable_ty),
    };
}

pub fn taggedUnionSwitchBranch(allocator: std.mem.Allocator, patterns: []const ast.Pattern, subject: TaggedUnionSwitchSubject) !?TaggedUnionSwitchBranch {
    if (patterns.len == 0) return null;
    if (patterns.len == 1) {
        if (patterns[0].kind == .wildcard) return .{ .condition = null, .is_wildcard = true };
        const case_name = switch_lower.taggedUnionPatternName(patterns[0]) orelse return null;
        const condition = try std.fmt.allocPrint(allocator, "{s}.tag == {s}Tag_{s}", .{ subject.name, subject.type_name, case_name });
        if (patterns[0].kind == .tag_bind) {
            const tag_bind = patterns[0].kind.tag_bind;
            const case = taggedUnionCase(subject.decl, tag_bind.tag.text) orelse return null;
            const payload_ty = case.ty orelse return null;
            return .{
                .condition = condition,
                .binding_name = tag_bind.binding.text,
                .binding_source_ty = payload_ty,
                .payload_field = tag_bind.tag.text,
            };
        }
        return .{ .condition = condition };
    }

    var condition: std.ArrayList(u8) = .empty;
    for (patterns, 0..) |pattern, index| {
        const tag = switch (pattern.kind) {
            .tag => |tag| tag,
            else => return null,
        };
        if (index > 0) try condition.appendSlice(allocator, " || ");
        try condition.appendSlice(
            allocator,
            try std.fmt.allocPrint(allocator, "{s}.tag == {s}Tag_{s}", .{ subject.name, subject.type_name, tag.text }),
        );
    }
    return .{ .condition = try condition.toOwnedSlice(allocator) };
}
