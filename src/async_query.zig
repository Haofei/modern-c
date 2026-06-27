const ast = @import("ast.zig");

// `let x = await E;` (or `var`) — return the awaited expression `E` if this stmt is exactly that.
pub fn awaitStepCall(stmt: ast.Stmt) ?ast.Expr {
    const ld = switch (stmt.kind) {
        .let_decl, .var_decl => |l| l,
        else => return null,
    };
    const init_expr = ld.init orelse return null;
    return switch (init_expr.kind) {
        .await_expr => |inner| inner.*,
        .try_expr => |t| unwrapToAwaitCall(t.operand.*),
        else => null,
    };
}

pub fn unwrapToAwaitCall(e: ast.Expr) ?ast.Expr {
    return switch (e.kind) {
        .await_expr => |inner| inner.*,
        .grouped => |inner| unwrapToAwaitCall(inner.*),
        else => null,
    };
}

pub fn stmtContainsAwait(stmt: ast.Stmt) bool {
    return switch (stmt.kind) {
        .let_decl, .var_decl => |l| if (l.init) |e| exprContainsAwait(e) else false,
        .@"return" => |e| if (e) |x| exprContainsAwait(x) else false,
        .expr => |e| exprContainsAwait(e),
        .assignment => |a| exprContainsAwait(a.target) or exprContainsAwait(a.value),
        .assert => |e| exprContainsAwait(e),
        .@"defer" => |e| exprContainsAwait(e),
        else => stmtControlContainsAwait(stmt),
    };
}

pub fn stmtControlContainsAwait(stmt: ast.Stmt) bool {
    return switch (stmt.kind) {
        .block, .unsafe_block, .comptime_block => |b| blockContainsAwait(b),
        .loop => |l| blockContainsAwait(l.body) or (if (l.iterable) |it| exprContainsAwait(it) else false),
        .if_let => |il| exprContainsAwait(il.value) or blockContainsAwait(il.then_block) or (if (il.else_block) |eb| blockContainsAwait(eb) else false),
        .@"switch" => |sw| blk: {
            if (exprContainsAwait(sw.subject)) break :blk true;
            for (sw.arms) |arm| {
                const has = switch (arm.body) {
                    .block => |b| blockContainsAwait(b),
                    .expr => |e| exprContainsAwait(e),
                };
                if (has) break :blk true;
            }
            break :blk false;
        },
        .contract_block => |cb| blockContainsAwait(cb.block),
        else => false,
    };
}

pub fn blockContainsAwait(b: ast.Block) bool {
    for (b.items) |s| if (stmtContainsAwait(s)) return true;
    return false;
}

pub fn exprContainsAwait(e: ast.Expr) bool {
    return switch (e.kind) {
        .await_expr => true,
        .grouped, .address_of, .deref => |inner| exprContainsAwait(inner.*),
        .unary => |u| exprContainsAwait(u.expr.*),
        .binary => |b| exprContainsAwait(b.left.*) or exprContainsAwait(b.right.*),
        .cast => |c| exprContainsAwait(c.value.*),
        .call => |c| blk: {
            for (c.args) |a| if (exprContainsAwait(a)) break :blk true;
            break :blk exprContainsAwait(c.callee.*);
        },
        .index => |ix| exprContainsAwait(ix.base.*) or exprContainsAwait(ix.index.*),
        .member => |m| exprContainsAwait(m.base.*),
        .try_expr => |t| exprContainsAwait(t.operand.*),
        else => false,
    };
}
