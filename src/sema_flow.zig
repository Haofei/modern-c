const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const sema_builtin = @import("sema_builtin.zig");
const sema_model = @import("sema_model.zig");

const EnumInfo = sema_model.EnumInfo;
const UnionInfo = sema_model.UnionInfo;
const boolLiteralValue = ast_query.boolLiteralValue;
const exprIsIdentNamed = ast_query.exprIsIdentNamed;
const resultIfLetHandlesLocal = ast_query.resultIfLetHandlesLocal;
const resultSwitchHandlesLocal = ast_query.resultSwitchHandlesLocal;

pub fn blockContainsTry(block: ast.Block) bool {
    for (block.items) |stmt| {
        if (stmtContainsTry(stmt)) return true;
    }
    return false;
}

pub fn stmtContainsTry(stmt: ast.Stmt) bool {
    return switch (stmt.kind) {
        .let_decl, .var_decl => |local| if (local.init) |expr| exprContainsTry(expr) else false,
        .loop => |node| (if (node.iterable) |iterable| exprContainsTry(iterable) else false) or blockContainsTry(node.body),
        .if_let => |node| exprContainsTry(node.value) or blockContainsTry(node.then_block) or
            (if (node.else_block) |else_block| blockContainsTry(else_block) else false),
        .@"switch" => |node| switchContainsTry(node),
        .unsafe_block, .comptime_block, .block => |block| blockContainsTry(block),
        .contract_block => |contract| blockContainsTry(contract.block),
        .@"return" => |maybe| if (maybe) |expr| exprContainsTry(expr) else false,
        .@"break", .@"continue" => false,
        .@"defer", .expr, .assert => |expr| exprContainsTry(expr),
        .assignment => |node| exprContainsTry(node.target) or exprContainsTry(node.value),
        .asm_stmt => false,
    };
}

pub fn switchContainsTry(node: ast.Switch) bool {
    if (exprContainsTry(node.subject)) return true;
    for (node.arms) |arm| {
        const body_contains_try = switch (arm.body) {
            .block => |block| blockContainsTry(block),
            .expr => |expr| exprContainsTry(expr),
        };
        if (body_contains_try) return true;
    }
    return false;
}

pub fn exprContainsTry(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .try_expr => true,
        .grouped, .address_of, .deref => |inner| exprContainsTry(inner.*),
        .block => |block| blockContainsTry(block),
        .unary => |node| exprContainsTry(node.expr.*),
        .binary => |node| exprContainsTry(node.left.*) or exprContainsTry(node.right.*),
        .cast => |node| exprContainsTry(node.value.*),
        .call => |node| callContainsTry(node),
        .index => |node| exprContainsTry(node.base.*) or exprContainsTry(node.index.*),
        .member => |node| exprContainsTry(node.base.*),
        else => false,
    };
}

pub fn callContainsTry(node: anytype) bool {
    if (exprContainsTry(node.callee.*)) return true;
    for (node.args) |arg| {
        if (exprContainsTry(arg)) return true;
    }
    return false;
}

pub fn stmtTerminatesNormally(stmt: ast.Stmt) bool {
    return switch (stmt.kind) {
        .@"return", .@"break", .@"continue", .asm_stmt => true,
        .expr => |expr| exprTerminatesNormally(expr),
        .block, .unsafe_block, .comptime_block => |block| blockTerminatesNormally(block),
        .contract_block => |contract| blockTerminatesNormally(contract.block),
        .if_let => |node| node.else_block != null and
            blockTerminatesNormally(node.then_block) and
            blockTerminatesNormally(node.else_block.?),
        .@"switch" => |node| switchTerminatesNormally(node),
        else => false,
    };
}

pub fn blockTerminatesNormally(block: ast.Block) bool {
    for (block.items) |stmt| {
        if (stmtTerminatesNormally(stmt)) return true;
    }
    return false;
}

pub fn switchTerminatesNormally(node: ast.Switch) bool {
    var has_wildcard = false;
    for (node.arms) |arm| {
        for (arm.patterns) |pattern| {
            if (pattern.kind == .wildcard) has_wildcard = true;
        }
        const body_terminates = switch (arm.body) {
            .block => |block| blockTerminatesNormally(block),
            .expr => |expr| exprTerminatesNormally(expr),
        };
        if (!body_terminates) return false;
    }
    return has_wildcard;
}

pub fn exprTerminatesNormally(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .unreachable_expr => true,
        .grouped => |inner| exprTerminatesNormally(inner.*),
        .call => |node| sema_builtin.isTrapCall(node.callee.*),
        .block => |block| blockTerminatesNormally(block),
        else => false,
    };
}

pub fn resultLocalHandledLater(name: []const u8, stmts: []const ast.Stmt) bool {
    for (stmts) |stmt| {
        if (stmtHandlesResultLocal(name, stmt)) return true;
    }
    return false;
}

pub fn stmtHandlesResultLocal(name: []const u8, stmt: ast.Stmt) bool {
    return switch (stmt.kind) {
        .let_decl, .var_decl => |local| if (local.init) |expr| exprHandlesResultLocal(name, expr) else false,
        .loop => |node| if (node.iterable) |iterable| exprHandlesResultLocal(name, iterable) else false,
        .if_let => |node| resultIfLetHandlesLocal(name, node) or exprHandlesResultLocal(name, node.value),
        .@"switch" => |node| resultSwitchHandlesLocal(name, node) or exprHandlesResultLocal(name, node.subject),
        .unsafe_block, .comptime_block, .block => |block| blockHandlesResultLocal(name, block),
        .contract_block => |contract| blockHandlesResultLocal(name, contract.block),
        .@"return" => |maybe| if (maybe) |expr| exprHandlesResultLocal(name, expr) else false,
        .@"break", .@"continue", .asm_stmt => false,
        .@"defer", .expr, .assert => |expr| exprHandlesResultLocal(name, expr),
        .assignment => |node| exprHandlesResultLocal(name, node.target) or exprHandlesResultLocal(name, node.value),
    };
}

pub fn blockHandlesResultLocal(name: []const u8, block: ast.Block) bool {
    for (block.items) |stmt| {
        if (stmtHandlesResultLocal(name, stmt)) return true;
    }
    return false;
}

pub fn exprHandlesResultLocal(name: []const u8, expr: ast.Expr) bool {
    return switch (expr.kind) {
        .try_expr => |inner| exprIsIdentNamed(inner.operand.*, name) or exprHandlesResultLocal(name, inner.operand.*),
        .grouped, .address_of, .deref => |inner| exprHandlesResultLocal(name, inner.*),
        .block => |block| blockHandlesResultLocal(name, block),
        .unary => |node| exprHandlesResultLocal(name, node.expr.*),
        .binary => |node| exprHandlesResultLocal(name, node.left.*) or exprHandlesResultLocal(name, node.right.*),
        .cast => |node| exprHandlesResultLocal(name, node.value.*),
        .call => |node| callHandlesResultLocal(name, node),
        .index => |node| exprHandlesResultLocal(name, node.base.*) or exprHandlesResultLocal(name, node.index.*),
        .member => |node| exprHandlesResultLocal(name, node.base.*),
        else => false,
    };
}

pub fn callHandlesResultLocal(name: []const u8, node: anytype) bool {
    if (exprHandlesResultLocal(name, node.callee.*)) return true;
    for (node.args) |arg| {
        if (exprHandlesResultLocal(name, arg)) return true;
    }
    return false;
}

pub fn switchBoolLiteralValue(pattern: ast.Pattern) ?bool {
    return switch (pattern.kind) {
        .literal => |expr| boolLiteralValue(expr),
        else => null,
    };
}

pub fn switchCoversAllEnumCases(node: ast.Switch, enum_info: EnumInfo) bool {
    var cases = enum_info.cases.keyIterator();
    while (cases.next()) |case_name| {
        if (!switchCoversEnumCase(node, case_name.*)) return false;
    }
    return true;
}

fn switchCoversEnumCase(node: ast.Switch, case_name: []const u8) bool {
    for (node.arms) |arm| {
        for (arm.patterns) |pattern| {
            switch (pattern.kind) {
                .tag => |tag| if (std.mem.eql(u8, tag.text, case_name)) return true,
                .wildcard => return true,
                .tag_bind, .literal, .bind => {},
            }
        }
    }
    return false;
}

pub fn switchCoversAllUnionCases(node: ast.Switch, union_info: UnionInfo) bool {
    var cases = union_info.cases.keyIterator();
    while (cases.next()) |case_name| {
        if (!switchCoversUnionCase(node, case_name.*)) return false;
    }
    return true;
}

fn switchCoversUnionCase(switch_node: ast.Switch, case_name: []const u8) bool {
    for (switch_node.arms) |arm| {
        for (arm.patterns) |pattern| {
            switch (pattern.kind) {
                .tag => |tag| if (std.mem.eql(u8, tag.text, case_name)) return true,
                .tag_bind => |tag_bind| if (std.mem.eql(u8, tag_bind.tag.text, case_name)) return true,
                .wildcard => return true,
                .literal, .bind => {},
            }
        }
    }
    return false;
}
