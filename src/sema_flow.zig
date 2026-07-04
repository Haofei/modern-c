const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const sema_model = @import("sema_model.zig");

const EnumInfo = sema_model.EnumInfo;
const UnionInfo = sema_model.UnionInfo;
const boolLiteralValue = ast_query.boolLiteralValue;
const exprIsIdentNamed = ast_query.exprIsIdentNamed;
const resultIfLetHandlesLocal = ast_query.resultIfLetHandlesLocal;
const resultSwitchHandlesLocal = ast_query.resultSwitchHandlesLocal;

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
