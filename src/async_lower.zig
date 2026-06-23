// src/async_lower.zig — the `async fn` / `await` stackless state-machine transform
// (async/await roadmap Phase D, build-order step 3: straight-line awaits).
//
// Runs POST-parse, PRE-monomorphize/sema, on the whole `ast.Module`. For every `is_async`
// fn it GENERATES ordinary MC AST matching the hand-lowered acceptance target in
// `tests/c_emit/fuzz_async_lowering.mc`:
//
//   async fn f(params) -> T { let x0 = await e0; ...; <straight-line>; return expr; }
//
// lowers to:
//
//   struct f__Fut { state: u8, <one child-future field per await>, <captured locals>, result: T }
//   fn f(params) -> f__Fut { ...construct ONLY child0 + state=0 + result=0... }   // constructor
//   impl Future for f__Fut { fn poll(self: *mut f__Fut) -> bool { <switch-on-state machine> } }
//   fn f__Fut_take_result(self: *mut f__Fut) -> T { return self.result; }
//   fn f__Fut_cancel(self: *mut f__Fut) -> void { ...walk the active child, mark DONE... }
//
// `await g(args)`: the child future for step 0 is constructed up-front in the constructor; each
// LATER child (`__c{i+1}`) is constructed LAZILY at the transition that ends step i — AFTER its
// take-result has stored the prior binding — so a later awaited call MAY reference an earlier
// `await` result (`let t = await login(); let d = await fetch(t);`). The poll state machine polls
// the active child (`FutT__poll(&self.__cN)`), returns `false` (suspend) while pending, reads its
// typed result via `FutT_take_result(&self.__cN)`, builds the next child, then advances `state`.
// The generated poll NEVER calls a blocking await — it only polls children.
//
// v0 scope (enforced): STRAIGHT-LINE only — a sequence of `let xN = await eN;` (each `eN` a plain
// call `g(args)`), followed by branch-free straight-line statements, then `return expr;`. No
// branches/loops across an await. Capture analysis is CONSERVATIVE: every local binding becomes a
// struct field (correctness over minimality).
//
// CANCEL (drop): a generated free fn `f__Fut_cancel(self: *mut f__Fut)` reclaims the in-flight
// broker slot held by a still-pending future. Because of lazy construction, at most ONE child is
// live at a time (state i ⇒ only `__ci` exists), so cancel walks just the current state's child
// via `<childFutType>_cancel(&self.__ci)`, then sets `state = done_state` (idempotent: a later poll
// early-returns true; no double-free). This establishes the LEAF Future ABI as `__poll` +
// `_take_result` + `_cancel` — every awaited leaf must provide all three.
//
// CHILD-FUTURE ABI (uniform across generated futures and hand-written leaves), resolved WITHOUT
// sema by scanning the module's fn decls for the awaited callee's return type:
//   - `await g(args)` ⇒ child future struct type `FutT` = return type of fn `g`
//     (for an async `g`, the transform rewrites `g` to return `g__Fut`, so `FutT == g__Fut`);
//   - construct by value:  `self.__cN = g(args);` (child0 in the constructor; later children at
//                          the transition that ends the prior step, so they may read prior results);
//   - poll:                `FutT__poll(&self.__cN)`  (the `impl Future for FutT` method);
//   - typed result:        `FutT_take_result(&self.__cN)`  (a free fn; generated for async `g`,
//                          author-provided for a leaf — valid once, after poll()==true);
//   - cancel:              `FutT_cancel(&self.__cN)`  (a free fn; generated for async `g`,
//                          author-provided for a leaf — releases the in-flight slot on drop).

const std = @import("std");
const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");

const zspan = diagnostics.Span{ .offset = 0, .len = 0, .line = 0, .column = 0 };

fn id(text: []const u8) ast.Ident {
    return .{ .text = text, .span = zspan };
}

fn ptr(arena: std.mem.Allocator, comptime T: type, value: T) !*T {
    const p = try arena.create(T);
    p.* = value;
    return p;
}

fn nameType(arena: std.mem.Allocator, text: []const u8) !ast.TypeExpr {
    _ = arena;
    return .{ .span = zspan, .kind = .{ .name = id(text) } };
}

fn mutPtrType(arena: std.mem.Allocator, child: ast.TypeExpr) !ast.TypeExpr {
    return .{ .span = zspan, .kind = .{ .pointer = .{ .mutability = .mut, .child = try ptr(arena, ast.TypeExpr, child) } } };
}

fn identExpr(text: []const u8) ast.Expr {
    return .{ .span = zspan, .kind = .{ .ident = id(text) } };
}

fn intExpr(text: []const u8) ast.Expr {
    return .{ .span = zspan, .kind = .{ .int_literal = text } };
}

fn memberExpr(arena: std.mem.Allocator, base: ast.Expr, field: []const u8) !ast.Expr {
    return .{ .span = zspan, .kind = .{ .member = .{ .base = try ptr(arena, ast.Expr, base), .name = id(field) } } };
}

fn addrOf(arena: std.mem.Allocator, inner: ast.Expr) !ast.Expr {
    return .{ .span = zspan, .kind = .{ .address_of = try ptr(arena, ast.Expr, inner) } };
}

fn selfMember(arena: std.mem.Allocator, field: []const u8) !ast.Expr {
    return memberExpr(arena, identExpr("self"), field);
}

fn callExpr(arena: std.mem.Allocator, callee: []const u8, args: []ast.Expr) !ast.Expr {
    return .{ .span = zspan, .kind = .{ .call = .{
        .callee = try ptr(arena, ast.Expr, identExpr(callee)),
        .type_args = &.{},
        .args = args,
    } } };
}

const Error = std.mem.Allocator.Error || error{AsyncLowerFailed};

// The ABI of an async fn, recorded so awaits of it resolve to its generated future type.
const AsyncInfo = struct {
    fut_type: []const u8, // `f__Fut`
    take_result: []const u8, // `f__Fut_take_result`
    cancel: []const u8, // `f__Fut_cancel`
    result_type: ast.TypeExpr,
};

const Lowerer = struct {
    arena: std.mem.Allocator,
    reporter: ?*diagnostics.Reporter,
    // callee name -> declared return-type name (a struct type) for EVERY fn in the module,
    // so an `await g(args)` can resolve `g`'s future struct type without sema.
    fn_ret_type: std.StringHashMap([]const u8),
    // async fn name -> its generated future ABI.
    async_info: std.StringHashMap(AsyncInfo),
    failed: bool = false,

    fn fail(self: *Lowerer, span: diagnostics.Span, comptime fmt: []const u8, args: anytype) Error {
        self.failed = true;
        if (self.reporter) |r| r.err(span, fmt, args);
        return error.AsyncLowerFailed;
    }
};

// A single `let binding = await call(args);` step extracted from a straight-line async body.
const AwaitStep = struct {
    binding: ?[]const u8, // the `let x =` name (null if `await e;` is a bare statement)
    binding_type: ?ast.TypeExpr, // the `: T` annotation on the binding, if present
    child_field: []const u8, // `__cN`
    fut_type: []const u8, // child future struct type
    take_result: []const u8, // child `FutT_take_result`
    cancel: []const u8, // child `FutT_cancel`
    call: ast.Expr, // the awaited `g(args)` call (used to construct the child)
    result_type: ast.TypeExpr, // the child's result type (binding_type, or async fn's return type)
};

// A `while cond { body }` whose body CONTAINS awaits, split into the body's leading await-run +
// straight-line tail. The loop needs a BACK-EDGE: the entire poll body is wrapped in `while true`
// and the last body state sets `state` back to the loop-head state (0). (v0: exactly one such loop,
// optional no-await pre-loop straight-line, a straight-line tail ending in `return expr;`.)
const WhileLoop = struct {
    cond: ast.Expr, // the loop condition (re-checked at the head each iteration)
    steps: std.ArrayList(AwaitStep) = .empty, // the body's leading await-run
    tail: std.ArrayList(ast.Stmt) = .empty, // the body's straight-line tail (no return/break/continue)
};

// A bool-`if`/`else` (parser-desugared to a 2-arm bool `switch`) that CONTAINS awaits, split into
// each arm's leading await-run + straight-line tail. The shared continuation runs the body tail.
const Branch = struct {
    cond: ast.Expr, // the `if` condition (switch subject)
    then_steps: std.ArrayList(AwaitStep) = .empty, // then-arm leading awaits
    then_tail: std.ArrayList(ast.Stmt) = .empty, // then-arm straight-line stmts (no return)
    else_steps: std.ArrayList(AwaitStep) = .empty, // else-arm leading awaits
    else_tail: std.ArrayList(ast.Stmt) = .empty, // else-arm straight-line stmts (no return)
};

// Is this stmt the parser's bool-`if`/`else` desugar: a 2-arm `switch` whose arms are `true`/`false`
// literal patterns over block bodies? (See parser.desugarBoolIf.) Returns the cond + both blocks.
const BoolIf = struct { cond: ast.Expr, then_blk: ast.Block, else_blk: ast.Block };
fn asBoolIf(stmt: ast.Stmt) ?BoolIf {
    const sw = switch (stmt.kind) {
        .@"switch" => |s| s,
        else => return null,
    };
    if (sw.arms.len != 2) return null;
    const t = boolPatternValue(sw.arms[0]) orelse return null;
    const f = boolPatternValue(sw.arms[1]) orelse return null;
    if (!(t == true and f == false)) return null;
    const then_blk = switch (sw.arms[0].body) {
        .block => |b| b,
        else => return null,
    };
    const else_blk = switch (sw.arms[1].body) {
        .block => |b| b,
        else => return null,
    };
    return .{ .cond = sw.subject, .then_blk = then_blk, .else_blk = else_blk };
}

// A switch arm whose single pattern is a bool literal -> that bool's value, else null.
fn boolPatternValue(arm: ast.SwitchArm) ?bool {
    if (arm.patterns.len != 1) return null;
    return switch (arm.patterns[0].kind) {
        .literal => |e| switch (e.kind) {
            .bool_literal => |b| b,
            else => null,
        },
        else => null,
    };
}

// Returns the type-name a `*TypeExpr` denotes if it is a bare nominal name, else null.
fn typeName(t: ast.TypeExpr) ?[]const u8 {
    return switch (t.kind) {
        .name => |n| n.text,
        else => null,
    };
}

pub fn transform(arena: std.mem.Allocator, module: ast.Module, reporter: ?*diagnostics.Reporter) Error!ast.Module {
    // `await` is ONLY valid inside an `async fn` — the transform rewrites those away. Any `await`
    // surviving in a non-async fn would reach sema as an unhandled `await_expr` (a compiler crash),
    // so reject it here with a diagnostic. This runs UNCONDITIONALLY (even with no async fns).
    for (module.decls) |d| {
        if (d.kind != .fn_decl) continue;
        const fd = d.kind.fn_decl;
        if (fd.is_async) continue; // an async fn's own awaits are handled by the transform
        const b = fd.body orelse continue;
        if (blockContainsAwait(b)) {
            if (reporter) |r| r.err(fd.name.span, "E_AWAIT_OUTSIDE_ASYNC: `await` is only valid inside an `async fn` (in '{s}')", .{fd.name.text});
            return error.AsyncLowerFailed;
        }
    }

    // Quick pass: does any async fn exist? If not, pass through untouched.
    var has_async = false;
    for (module.decls) |d| {
        if (d.kind == .fn_decl and d.kind.fn_decl.is_async) has_async = true;
    }
    if (!has_async) return module;

    var low = Lowerer{
        .arena = arena,
        .reporter = reporter,
        .fn_ret_type = std.StringHashMap([]const u8).init(arena),
        .async_info = std.StringHashMap(AsyncInfo).init(arena),
    };

    // Pass 1: record every fn's return-type name, and each async fn's generated future ABI.
    for (module.decls) |d| {
        switch (d.kind) {
            .fn_decl, .extern_fn => |fd| {
                if (fd.return_type) |rt| {
                    if (typeName(rt)) |tn| try low.fn_ret_type.put(fd.name.text, tn);
                }
                if (d.kind == .fn_decl and fd.is_async) {
                    const fut_type = try std.fmt.allocPrint(arena, "{s}__Fut", .{fd.name.text});
                    const take = try std.fmt.allocPrint(arena, "{s}_take_result", .{fut_type});
                    const cancel = try std.fmt.allocPrint(arena, "{s}_cancel", .{fut_type});
                    const rt = fd.return_type orelse return low.fail(fd.name.span, "async fn '{s}' must declare a return type", .{fd.name.text});
                    try low.async_info.put(fd.name.text, .{ .fut_type = fut_type, .take_result = take, .cancel = cancel, .result_type = rt });
                    // After lowering, calling `g(args)` yields a `g__Fut`, so record that as g's
                    // "return type" for nested awaits (`await g(...)`).
                    try low.fn_ret_type.put(fd.name.text, fut_type);
                }
            },
            else => {},
        }
    }

    // Pass 2: rewrite. Non-async decls pass through; each async fn expands to several decls.
    var out: std.ArrayList(ast.Decl) = .empty;
    for (module.decls) |d| {
        if (d.kind == .fn_decl and d.kind.fn_decl.is_async) {
            try lowerAsyncFn(&low, &out, d);
        } else {
            try out.append(arena, d);
        }
    }

    // Pass 3: UFCS on GENERATED futures. The parser rewrites `Owner.method(args)` to the mangled
    // `Owner__method` at PARSE time, but a generated future type (`f__Fut`) does not exist then, so
    // a caller's `f__Fut.poll(&x)` is left as an unresolved member expr. Patch those in place now:
    // for each generated future `G`, rewrite a `member{ base: ident(G), name: "poll" }` to the free
    // ident `G__poll` (the impl method's mangled name the transform already emits). `take_result`
    // and `cancel` are plain free fns (single-underscore `G_take_result`), not trait methods, so
    // only `.poll` is UFCS-eligible. This also registers G as a qualified owner (shadow safety).
    if (low.async_info.count() > 0) {
        var futs = std.StringHashMap(void).init(arena);
        var it = low.async_info.valueIterator();
        while (it.next()) |ai| try futs.put(ai.fut_type, {});
        for (out.items) |d| {
            if (d.kind == .fn_decl) {
                if (d.kind.fn_decl.body) |b| for (b.items) |s| patchUfcsStmt(arena, s, &futs);
            }
        }
        // Extend qualified_owners with the generated future names (dedup against existing).
        var owners: std.ArrayList([]const u8) = .empty;
        try owners.appendSlice(arena, module.qualified_owners);
        var fit = futs.keyIterator();
        while (fit.next()) |k| {
            var present = false;
            for (module.qualified_owners) |o| {
                if (std.mem.eql(u8, o, k.*)) { present = true; break; }
            }
            if (!present) try owners.append(arena, k.*);
        }
        return .{ .decls = try out.toOwnedSlice(arena), .qualified_owners = try owners.toOwnedSlice(arena) };
    }

    return .{ .decls = try out.toOwnedSlice(arena), .qualified_owners = module.qualified_owners };
}

// ---- Pass-3 UFCS patcher: rewrite `G.poll` member exprs (G a generated future) to `ident(G__poll)`
// IN PLACE. Recurses through statement/expression child pointers, patching `expr.*` at each match.
// Coverage spans the ordinary stmt/expr shapes a driver uses (calls, control flow, decls). ----
fn patchUfcsStmt(arena: std.mem.Allocator, s: ast.Stmt, futs: *std.StringHashMap(void)) void {
    switch (s.kind) {
        .let_decl, .var_decl => |l| { if (l.init) |e| patchUfcsExpr(arena, e, futs); },
        .assignment => |a| { patchUfcsExpr(arena, a.target, futs); patchUfcsExpr(arena, a.value, futs); },
        .expr => |e| patchUfcsExpr(arena, e, futs),
        .@"return" => |e| { if (e) |x| patchUfcsExpr(arena, x, futs); },
        .assert => |e| patchUfcsExpr(arena, e, futs),
        .@"defer" => |e| patchUfcsExpr(arena, e, futs),
        .block, .unsafe_block, .comptime_block => |b| { for (b.items) |it| patchUfcsStmt(arena, it, futs); },
        .loop => |lp| { if (lp.iterable) |it| patchUfcsExpr(arena, it, futs); for (lp.body.items) |it| patchUfcsStmt(arena, it, futs); },
        .if_let => |il| {
            patchUfcsExpr(arena, il.value, futs);
            for (il.then_block.items) |it| patchUfcsStmt(arena, it, futs);
            if (il.else_block) |eb| for (eb.items) |it| patchUfcsStmt(arena, it, futs);
        },
        .@"switch" => |sw| {
            patchUfcsExpr(arena, sw.subject, futs);
            for (sw.arms) |arm| switch (arm.body) {
                .block => |b| { for (b.items) |it| patchUfcsStmt(arena, it, futs); },
                .expr => |e| patchUfcsExpr(arena, e, futs),
            };
        },
        .contract_block => |cb| { for (cb.block.items) |it| patchUfcsStmt(arena, it, futs); },
        else => {},
    }
}

// Recurse into an expression's child pointers and, when a child points at a `member{ ident(G),
// "poll" }`, overwrite it with `ident(G__poll)`.
fn patchUfcsExpr(arena: std.mem.Allocator, e: ast.Expr, futs: *std.StringHashMap(void)) void {
    switch (e.kind) {
        .grouped, .address_of, .deref => |inner| { patchUfcsOne(arena, inner, futs); },
        .unary => |u| patchUfcsOne(arena, u.expr, futs),
        .binary => |b| { patchUfcsOne(arena, b.left, futs); patchUfcsOne(arena, b.right, futs); },
        .cast => |c| patchUfcsOne(arena, c.value, futs),
        .call => |c| { patchUfcsOne(arena, c.callee, futs); for (c.args) |*a| patchUfcsOne(arena, a, futs); },
        .index => |ix| { patchUfcsOne(arena, ix.base, futs); patchUfcsOne(arena, ix.index, futs); },
        .member => |m| patchUfcsOne(arena, m.base, futs),
        .try_expr => |t| patchUfcsOne(arena, t.operand, futs),
        else => {},
    }
}

// Check-and-patch a single child pointer, then recurse into it.
fn patchUfcsOne(arena: std.mem.Allocator, p: *ast.Expr, futs: *std.StringHashMap(void)) void {
    if (p.kind == .member) {
        const m = p.kind.member;
        if (m.base.kind == .ident and std.mem.eql(u8, m.name.text, "poll") and futs.contains(m.base.kind.ident.text)) {
            // `G.poll` -> `G__poll` (the generated impl method's mangled free name).
            const mangled = std.fmt.allocPrint(arena, "{s}__poll", .{m.base.kind.ident.text}) catch return;
            p.* = .{ .span = p.span, .kind = .{ .ident = .{ .text = mangled, .span = p.span } } };
            return; // patched leaf; nothing to recurse into
        }
    }
    patchUfcsExpr(arena, p.*, futs);
}

fn lowerAsyncFn(low: *Lowerer, out: *std.ArrayList(ast.Decl), decl: ast.Decl) Error!void {
    const arena = low.arena;
    const fd = decl.kind.fn_decl;
    const fname = fd.name.text;

    // An `async fn` suspends (returns `pending` up the poll chain) and is driven through `*dyn`
    // dispatch — both forbidden in an IRQ/atomic/bounded context. Reject it before lowering, since
    // the generated decls carry no attrs and sema would otherwise never see the conflict.
    for (decl.attrs) |a| {
        if (a.kind == .named) {
            const an = a.kind.named.text;
            // `atomic_context` is a sema synonym for `irq_context` (see sema.hasIrqContext).
            if (std.mem.eql(u8, an, "irq_context") or std.mem.eql(u8, an, "atomic_context") or std.mem.eql(u8, an, "bounded")) {
                return low.fail(a.span, "E_ASYNC_FORBIDDEN_CONTEXT: `async fn` is forbidden in a #[{s}] context (it suspends and uses indirect dispatch)", .{an});
            }
        }
    }
    const info = low.async_info.get(fname).?;
    const fut_type = info.fut_type;
    const result_type = info.result_type;

    const body = fd.body orelse return low.fail(fd.name.span, "async fn '{s}' must have a body", .{fname});

    // ---- An await-bearing `while` loop takes a DEDICATED lowering path (back-edge + while-true poll
    // wrapper). Detect it first; it may not be mixed with an await-bearing if/else in v0. ----
    {
        var loop_count: usize = 0;
        for (body.items) |stmt| {
            if (stmt.kind == .loop and blockContainsAwait(stmt.kind.loop.body)) loop_count += 1;
        }
        if (loop_count > 0) {
            return lowerAsyncLoopFn(low, out, decl, info, fut_type, result_type, body);
        }
    }

    // ---- Walk the body in this v0 shape: a LEADING run of `let x = await call;` steps, then AT MOST
    // ONE bool-`if`/`else` that CONTAINS awaits (each arm: its own leading await-run + straight-line
    // tail, NO return), then a straight-line tail ending in `return expr;`. A body with no
    // await-bearing branch keeps the original linear path (`branch == null`). ----
    var steps: std.ArrayList(AwaitStep) = .empty; // pre-branch await run
    var branch: ?Branch = null; // the single await-bearing if/else, if any
    var pre_branch: std.ArrayList(ast.Stmt) = .empty; // straight-line stmts between pre-await & branch
    var tail: std.ArrayList(ast.Stmt) = .empty; // post-branch straight-line stmts (incl the return)

    var in_await_run = true; // still consuming the leading `let x = await ...;` run
    var in_tail = false; // past the branch (or no branch): accumulating the final straight-line tail
    for (body.items) |stmt| {
        const await_call = awaitStepCall(stmt);
        // (1) The leading await-run.
        if (await_call != null and in_await_run) {
            const step = try buildAwaitStep(low, stmt, await_call.?, steps.items.len);
            try steps.append(arena, step);
            continue;
        }
        in_await_run = false;
        // (2) The single await-bearing bool-`if`/`else` (at most one, before the tail). A branch with
        // no awaits is NOT the branch — it falls through to the straight-line tail unchanged.
        if (!in_tail and branch == null) {
            if (asBoolIf(stmt)) |bi| {
                if (blockContainsAwait(bi.then_blk) or blockContainsAwait(bi.else_blk)) {
                    var b = Branch{ .cond = bi.cond };
                    // then-awaits are __c{P..}, else-awaits continue the GLOBAL numbering after them.
                    try collectArm(low, bi.then_blk, steps.items.len, &b.then_steps, &b.then_tail);
                    try collectArm(low, bi.else_blk, steps.items.len + b.then_steps.items.len, &b.else_steps, &b.else_tail);
                    branch = b;
                    continue;
                }
            }
            // (3) Straight-line stmt between the pre-await run and the branch. Reject an await here
            // (an await outside the leading run / not a plain `let x = await`).
            if (stmtContainsAwait(stmt)) return low.fail(stmt.span, "E_ASYNC_BRANCH_UNSUPPORTED: async v0 supports a leading await-run, at most one await-bearing if/else, then a straight-line tail ending in `return expr;` (no awaits in the tail, in loops, or nested deeper than one if-level)", .{});
            try pre_branch.append(arena, stmt);
            continue;
        }
        // (4) The straight-line tail (after the branch, or the whole body if there is no branch). A
        // second await-bearing branch, or any await beyond the leading run, is rejected here.
        in_tail = true;
        if (asBoolIf(stmt)) |bi| {
            if (blockContainsAwait(bi.then_blk) or blockContainsAwait(bi.else_blk))
                return low.fail(stmt.span, "E_ASYNC_BRANCH_UNSUPPORTED: async v0 supports at most ONE await-bearing if/else (then a straight-line tail); a second await-bearing branch is unsupported", .{});
        }
        if (stmtContainsAwait(stmt)) return low.fail(stmt.span, "E_ASYNC_BRANCH_UNSUPPORTED: async v0 supports a leading await-run, at most one await-bearing if/else, then a straight-line tail ending in `return expr;` (no awaits in the tail, in loops, or nested deeper than one if-level)", .{});
        try tail.append(arena, stmt);
    }

    // If there is no branch, fold the pre-branch straight-line stmts back into the tail (they ARE the
    // tail in the linear case), preserving the original single-tail-state lowering exactly.
    if (branch == null) {
        var merged: std.ArrayList(ast.Stmt) = .empty;
        try merged.appendSlice(arena, pre_branch.items);
        try merged.appendSlice(arena, tail.items);
        tail = merged;
        pre_branch = .empty;
    }

    // Total await count across pre-run + both arms; used for child-field allocation and cancel.
    const n_then: usize = if (branch) |b| b.then_steps.items.len else 0;
    const n_else: usize = if (branch) |b| b.else_steps.items.len else 0;

    // ---- Build the future struct: state + child fields + captured-binding fields + result. ----
    var fields: std.ArrayList(ast.Field) = .empty;
    try fields.append(arena, .{ .name = id("state"), .ty = try nameType(arena, "u8") });
    // One child-future field per await, across pre-run + both arms (only the taken arm's children are
    // ever built — lazy — but all fields exist).
    for (steps.items) |s| {
        try fields.append(arena, .{ .name = id(s.child_field), .ty = try nameType(arena, s.fut_type) });
    }
    if (branch) |b| {
        for (b.then_steps.items) |s| try fields.append(arena, .{ .name = id(s.child_field), .ty = try nameType(arena, s.fut_type) });
        for (b.else_steps.items) |s| try fields.append(arena, .{ .name = id(s.child_field), .ty = try nameType(arena, s.fut_type) });
    }
    // Conservative capture: every awaited binding becomes a field (it may be live across a later
    // await or used in the tail). Params are also captured so the tail/await args can read them. Arm
    // bindings (pre + then + else) AND any local declared in an arm/tail straight-line block become
    // fields too. (Arm-local `let`s in the straight-line tail are lowered in place; declaring them as
    // struct fields would double-declare, so we DON'T add tail/arm-straight-line locals as fields —
    // only awaited bindings. Straight-line `let`/`var` keep their local scope, rewritten to self.* for
    // reads of captured names but their own name stays a local.)
    for (fd.params) |p| {
        try fields.append(arena, .{ .name = p.name, .ty = p.ty });
    }
    for (steps.items) |s| {
        if (s.binding) |b| try fields.append(arena, .{ .name = id(b), .ty = s.result_type });
    }
    // Locals declared in the pre-branch straight-line (e.g. `var out: i32 = 0;`) are live across the
    // branch's states, so they become captured fields too (only in the branch lowering). Their init
    // is replayed (as an assignment) at the dispatch; reads/writes in the arms rewrite to self.*.
    if (branch != null) {
        for (pre_branch.items) |stmt| {
            switch (stmt.kind) {
                .let_decl, .var_decl => |ld| {
                    if (ld.names.len != 1) return low.fail(stmt.span, "E_ASYNC_BRANCH_UNSUPPORTED: a pre-branch `let`/`var` must bind exactly one name in async v0", .{});
                    const lty = ld.ty orelse return low.fail(stmt.span, "E_ASYNC_BRANCH_UNSUPPORTED: a pre-branch `let`/`var` live across an await-bearing if/else needs an explicit type annotation in async v0", .{});
                    try fields.append(arena, .{ .name = ld.names[0], .ty = lty });
                },
                else => {},
            }
        }
    }
    if (branch) |b| {
        for (b.then_steps.items) |s| if (s.binding) |nm| try fields.append(arena, .{ .name = id(nm), .ty = s.result_type });
        for (b.else_steps.items) |s| if (s.binding) |nm| try fields.append(arena, .{ .name = id(nm), .ty = s.result_type });
    }
    try fields.append(arena, .{ .name = id("result"), .ty = result_type });

    try out.append(arena, .{ .span = zspan, .attrs = &.{}, .kind = .{ .struct_decl = .{
        .name = id(fut_type),
        .abi = null,
        .fields = try fields.toOwnedSlice(arena),
    } } });

    // The set of names that are now `self.*` fields: every param plus every awaited binding. An
    // awaited call's args (built lazily at a transition) may reference a param OR any PRIOR binding,
    // and a later binding name never appears before it is bound, so one combined set is correct.
    var field_names = std.StringHashMap(void).init(arena);
    for (fd.params) |p| try field_names.put(p.name.text, {});
    for (steps.items) |s| {
        if (s.binding) |b| try field_names.put(b, {});
    }
    // Branch-captured names: pre-branch declared locals + both arms' awaited bindings. Within an arm
    // a reference to one of these reads/writes the corresponding `self.*` field.
    if (branch) |b| {
        for (pre_branch.items) |stmt| switch (stmt.kind) {
            .let_decl, .var_decl => |ld| try field_names.put(ld.names[0].text, {}),
            else => {},
        };
        for (b.then_steps.items) |s| if (s.binding) |nm| try field_names.put(nm, {});
        for (b.else_steps.items) |s| if (s.binding) |nm| try field_names.put(nm, {});
    }

    // ---- The constructor `fn f(params) -> f__Fut { var self: f__Fut = uninit; ...; return self; }`
    // It zeroes state, copies params into their fields, and constructs ONLY child0 (step 0's child)
    // from the params. Later children are built LAZILY in `poll` at their step's entry transition,
    // so an awaited call may read an earlier `await` result. Leaving the later `__cN` fields
    // unwritten is sound: sema def-init tracks only SCALAR `uninit` vars, and each `__cN` is written
    // (at the transition) before its first poll. ----
    var cbody: std.ArrayList(ast.Stmt) = .empty;
    try cbody.append(arena, .{ .span = zspan, .kind = .{ .var_decl = .{
        .names = try dupIdents(arena, &.{"self"}),
        .ty = try nameType(arena, fut_type),
        .init = .{ .span = zspan, .kind = .uninit_literal },
    } } });
    try cbody.append(arena, assignStmt(try selfMember(arena, "state"), intExpr("0")));
    for (fd.params) |p| {
        try cbody.append(arena, assignStmt(try selfMember(arena, p.name.text), identExpr(p.name.text)));
    }
    // child0 is constructed by value: `self.__c0 = g(args);` — the call's args may reference params,
    // which are now `self.<param>` fields. Rewrite ident args that name a captured field.
    if (steps.items.len > 0) {
        const s0 = steps.items[0];
        const rewritten = try rewriteParamRefs(low, s0.call, &field_names);
        try cbody.append(arena, assignStmt(try selfMember(arena, s0.child_field), rewritten));
    }
    // Zero the captured binding fields + result (definite-init for the move/borrow checker). This
    // covers pre-await bindings, pre-branch locals, and BOTH arms' awaited bindings — every scalar
    // field the poll machine may read. (The real pre-branch local init is replayed at the dispatch.)
    for (steps.items) |s| {
        if (s.binding) |b| try cbody.append(arena, assignStmt(try selfMember(arena, b), try zeroFor(low, s.result_type)));
    }
    if (branch) |b| {
        for (pre_branch.items) |stmt| switch (stmt.kind) {
            .let_decl, .var_decl => |ld| try cbody.append(arena, assignStmt(try selfMember(arena, ld.names[0].text), try zeroFor(low, ld.ty.?))),
            else => {},
        };
        for (b.then_steps.items) |s| if (s.binding) |nm| try cbody.append(arena, assignStmt(try selfMember(arena, nm), try zeroFor(low, s.result_type)));
        for (b.else_steps.items) |s| if (s.binding) |nm| try cbody.append(arena, assignStmt(try selfMember(arena, nm), try zeroFor(low, s.result_type)));
    }
    try cbody.append(arena, assignStmt(try selfMember(arena, "result"), try zeroFor(low, result_type)));
    try cbody.append(arena, .{ .span = zspan, .kind = .{ .@"return" = identExpr("self") } });

    try checkNoSelfBorrow(low, fd, cbody.items);

    try out.append(arena, .{ .span = zspan, .attrs = &.{}, .kind = .{ .fn_decl = .{
        .name = id(fname),
        .abi = null,
        .params = fd.params,
        .return_type = try nameType(arena, fut_type),
        .body = .{ .span = zspan, .items = try cbody.toOwnedSlice(arena) },
        .is_const = false,
        .exported = fd.exported,
    } } });

    // ---- The poll method: a switch-on-state machine. Each await is one `if self.state == N { ... }`
    // block that polls the child, suspends (`return false`) while pending, takes the typed result
    // into the binding field, then advances `state`. After the last await, run the straight-line
    // tail (with `return expr;` rewritten to `self.result = expr; self.state = LAST; return true;`).
    var pbody: std.ArrayList(ast.Stmt) = .empty;
    const bind_names = &field_names;
    const P = steps.items.len;
    // State layout. LINEAR (no branch): pre states 0..P-1, tail at state P, DONE at P+1 — UNCHANGED.
    // BRANCH: pre states 0..P-1; then-arm states [arm_base .. arm_base+T-1]; else-arm states
    // [arm_base+T .. arm_base+T+E-1]; continuation (tail) at `cont_state`; DONE at `cont_state+1`.
    // When P==0 the dispatch occupies state 0 on its own, so arms start at 1 (arm_base==1); when P>0
    // the dispatch rides on pre-state P-1's completion block and arms start at P (arm_base==P).
    const arm_base: usize = if (branch == null) P else (if (P == 0) 1 else P);
    const cont_state: usize = arm_base + n_then + n_else;
    const done_state: usize = cont_state + 1;
    const done_str = try std.fmt.allocPrint(arena, "{d}", .{done_state});

    // Idempotence: check DONE FIRST and return true WITHOUT re-running the tail / its side effects.
    {
        var dbody = try arena.alloc(ast.Stmt, 1);
        dbody[0] = .{ .span = zspan, .kind = .{ .@"return" = .{ .span = zspan, .kind = .{ .bool_literal = true } } } };
        try pbody.append(arena, try ifStateEq(arena, done_state, dbody));
    }

    // Build the DISPATCH stmt (only used when there is a branch): rewrite the cond to self.*, then in
    // each arm lazily build the arm's FIRST child (if it has awaits) and jump to the arm-entry state,
    // OR (zero-await arm) run the arm's straight-line stmts synchronously and jump to the continuation.
    const dispatch: ?ast.Stmt = if (branch) |b| blk: {
        const then_entry = arm_base; // first then state
        const else_entry = arm_base + n_then; // first else state
        // then-branch body
        var tb: std.ArrayList(ast.Stmt) = .empty;
        if (n_then > 0) {
            try emitBuildChild(low, &tb, b.then_steps.items[0], bind_names);
            try setState(low, &tb, then_entry);
        } else {
            // zero-await then arm: run its straight-line stmts now, then go to the continuation.
            for (b.then_tail.items) |st| try tb.append(arena, try rewriteStmtParamRefs(low, st, bind_names));
            try setState(low, &tb, cont_state);
        }
        // else-branch body
        var eb: std.ArrayList(ast.Stmt) = .empty;
        if (n_else > 0) {
            try emitBuildChild(low, &eb, b.else_steps.items[0], bind_names);
            try setState(low, &eb, else_entry);
        } else {
            for (b.else_tail.items) |st| try eb.append(arena, try rewriteStmtParamRefs(low, st, bind_names));
            try setState(low, &eb, cont_state);
        }
        // `if <cond> { tb } else { eb }` as a 2-arm bool switch (same desugar the parser produces).
        const rcond = try rewriteParamRefs(low, b.cond, bind_names);
        var arms = try arena.alloc(ast.SwitchArm, 2);
        var tpat = try arena.alloc(ast.Pattern, 1);
        tpat[0] = boolPattern(true);
        var fpat = try arena.alloc(ast.Pattern, 1);
        fpat[0] = boolPattern(false);
        arms[0] = .{ .patterns = tpat, .body = .{ .block = .{ .span = zspan, .items = try tb.toOwnedSlice(arena) } } };
        arms[1] = .{ .patterns = fpat, .body = .{ .block = .{ .span = zspan, .items = try eb.toOwnedSlice(arena) } } };
        break :blk .{ .span = zspan, .kind = .{ .@"switch" = .{ .subject = rcond, .arms = arms } } };
    } else null;

    // Pre-await states 0..P-1. Each polls its child, takes its result, then advances. The LAST
    // pre-state's completion either (linear) advances to the tail state, or (branch, P>0) runs the
    // pre-branch straight-line + dispatch.
    for (steps.items, 0..) |s, i| {
        var blk: std.ArrayList(ast.Stmt) = .empty;
        try emitPollAndTake(low, &blk, s);
        if (i + 1 < P) {
            // LAZY: build the next pre-child now (it may reference an earlier await result).
            try emitBuildChild(low, &blk, steps.items[i + 1], bind_names);
            try setState(low, &blk, i + 1);
        } else if (branch != null) {
            // Last pre-await done -> replay pre-branch straight-line (lifting decls to self.* stores),
            // then DISPATCH.
            for (pre_branch.items) |st| try blk.append(arena, try rewriteDeclToStore(low, st, bind_names));
            try blk.append(arena, dispatch.?);
        } else {
            try setState(low, &blk, i + 1); // -> linear tail state (== P)
        }
        try pbody.append(arena, try ifStateEq(arena, i, try blk.toOwnedSlice(arena)));
    }

    // When P==0 and there is a branch, the dispatch is a standalone `if self.state == 0` block (it
    // polls no child): run the pre-branch straight-line then dispatch.
    if (branch != null and P == 0) {
        var blk: std.ArrayList(ast.Stmt) = .empty;
        for (pre_branch.items) |st| try blk.append(arena, try rewriteDeclToStore(low, st, bind_names));
        try blk.append(arena, dispatch.?);
        try pbody.append(arena, try ifStateEq(arena, 0, try blk.toOwnedSlice(arena)));
    }

    // Arm states: each arm's await-run, contiguous. After an arm's LAST await takes its result, run
    // the arm's straight-line stmts then jump to the continuation. Both arms converge on cont_state,
    // which lies BEYOND both arm ranges, so the sequential `if self.state==N` fall-through is sound:
    // the untaken arm's guards never match.
    if (branch) |b| {
        try emitArm(low, &pbody, b.then_steps.items, b.then_tail.items, arm_base, cont_state, bind_names);
        try emitArm(low, &pbody, b.else_steps.items, b.else_tail.items, arm_base + n_then, cont_state, bind_names);
    }

    // The continuation / tail. `return expr;` -> result-store + advance to DONE + `return true`. Other
    // tail stmts emit as-is with captured-name reads rewritten to self.*. Guarding it at cont_state
    // (plus the DONE early-return) keeps poll idempotent.
    var tail_body: std.ArrayList(ast.Stmt) = .empty;
    for (tail.items) |stmt| {
        switch (stmt.kind) {
            .@"return" => |maybe_expr| {
                const rexpr = maybe_expr orelse return low.fail(stmt.span, "async v0: `return` must return a value", .{});
                const rewritten = try rewriteParamRefs(low, rexpr, bind_names);
                try tail_body.append(arena, assignStmt(try selfMember(arena, "result"), rewritten));
                try tail_body.append(arena, assignStmt(try selfMember(arena, "state"), intExpr(done_str)));
                try tail_body.append(arena, .{ .span = zspan, .kind = .{ .@"return" = .{ .span = zspan, .kind = .{ .bool_literal = true } } } });
            },
            else => {
                const rewritten = try rewriteStmtParamRefs(low, stmt, bind_names);
                try tail_body.append(arena, rewritten);
            },
        }
    }
    try pbody.append(arena, try ifStateEq(arena, cont_state, try tail_body.toOwnedSlice(arena)));
    // Conservative definite-return fallback (unreachable at runtime: state is always DONE or a guarded
    // state above). `false` (not-complete) is the safe choice.
    try pbody.append(arena, .{ .span = zspan, .kind = .{ .@"return" = .{ .span = zspan, .kind = .{ .bool_literal = false } } } });

    const poll_method_name = try std.fmt.allocPrint(arena, "{s}__poll", .{fut_type});
    var poll_params = try arena.alloc(ast.Param, 1);
    poll_params[0] = .{ .name = id("self"), .ty = try mutPtrType(arena, try nameType(arena, fut_type)) };
    try out.append(arena, .{ .span = zspan, .attrs = &.{}, .kind = .{ .fn_decl = .{
        .name = id(poll_method_name),
        .abi = null,
        .params = poll_params,
        .return_type = try nameType(arena, "bool"),
        .body = .{ .span = zspan, .items = try pbody.toOwnedSlice(arena) },
        .is_const = false,
    } } });

    // The `impl Future for f__Fut` conformance record (so vtable emission picks it up, and sema's
    // conformance check passes) — mirrors how parseImplBlock appends an `impl_trait` Decl.
    var conf_methods = try arena.alloc(ast.ImplTraitMethod, 1);
    conf_methods[0] = .{
        .name = id("poll"),
        .mangled = poll_method_name,
        .self_mode = .by_mut_ptr,
        .params = poll_params,
        .return_type = try nameType(arena, "bool"),
    };
    try out.append(arena, .{ .span = zspan, .attrs = &.{}, .kind = .{ .impl_trait = .{
        .trait_name = id("Future"),
        .type_name = id(fut_type),
        .methods = conf_methods,
    } } });

    // The once-only typed-result accessor `fn f__Fut_take_result(self: *mut f__Fut) -> T`.
    var tr_params = try arena.alloc(ast.Param, 1);
    tr_params[0] = .{ .name = id("self"), .ty = try mutPtrType(arena, try nameType(arena, fut_type)) };
    var tr_body: std.ArrayList(ast.Stmt) = .empty;
    try tr_body.append(arena, .{ .span = zspan, .kind = .{ .@"return" = try selfMember(arena, "result") } });
    try out.append(arena, .{ .span = zspan, .attrs = &.{}, .kind = .{ .fn_decl = .{
        .name = id(info.take_result),
        .abi = null,
        .params = tr_params,
        .return_type = result_type,
        .body = .{ .span = zspan, .items = try tr_body.toOwnedSlice(arena) },
        .is_const = false,
        .exported = fd.exported,
    } } });

    // ---- The generated drop/cancel `fn f__Fut_cancel(self: *mut f__Fut) -> void`. It reclaims the
    // in-flight broker slot a still-pending future holds. With LAZY construction at most ONE child
    // is live at a time (state i ⇒ only `__ci` exists; states < i are done & consumed, states > i
    // not yet built), so cancel walks just the CURRENT state's child via `<childFutType>_cancel`,
    // then marks DONE (state = done_state). DONE makes it idempotent: a later poll early-returns
    // true and a later cancel finds no active child — no double-free. States >= tail_state hold no
    // active child, so they fall through to the DONE store. This is a PLAIN free fn (not a trait
    // method) — it is NOT added to the `impl Future` record. ----
    var cn_params = try arena.alloc(ast.Param, 1);
    cn_params[0] = .{ .name = id("self"), .ty = try mutPtrType(arena, try nameType(arena, fut_type)) };
    var cn_body: std.ArrayList(ast.Stmt) = .empty;
    // Pre-await children: state i holds child i.
    for (steps.items, 0..) |s, i| try emitCancelGuard(low, &cn_body, s, i);
    // Arm children: only the TAKEN arm's children are ever built, and at most one is live (the active
    // state's), so a guard per arm-await at its own state index is correct.
    if (branch) |b| {
        for (b.then_steps.items, 0..) |s, j| try emitCancelGuard(low, &cn_body, s, arm_base + j);
        for (b.else_steps.items, 0..) |s, k| try emitCancelGuard(low, &cn_body, s, arm_base + n_then + k);
    }
    // self.state = done_state;  (idempotent: subsequent poll/cancel are no-ops)
    try cn_body.append(arena, assignStmt(try selfMember(arena, "state"), intExpr(done_str)));
    try out.append(arena, .{ .span = zspan, .attrs = &.{}, .kind = .{ .fn_decl = .{
        .name = id(info.cancel),
        .abi = null,
        .params = cn_params,
        .return_type = try nameType(arena, "void"),
        .body = .{ .span = zspan, .items = try cn_body.toOwnedSlice(arena) },
        .is_const = false,
        .exported = fd.exported,
    } } });
}

// ---- LOOP lowering: an async body of `<pre-loop straight-line>; while cond { <leading await-run>
// <body straight-line> } <tail: return expr;>`. A loop needs a BACK-EDGE (re-check the condition
// after each iteration), which the flat `if self.state==N` fall-through cannot express within a
// single poll — so the WHOLE poll body is wrapped in `while true { <DONE early-return>; <state
// blocks> }` and the last body state sets `state` BACKWARD to the loop head (state 0).
//
// State layout (B = body await steps):
//   state 0       LOOP HEAD: `if <cond> { build __c0; state=1 } else { state=cont }`.
//   states 1..B   LOOP BODY awaits: poll __c{j-1}; on the LAST (j==B) run the body straight-line
//                 tail then `state=0` (BACK-EDGE); otherwise build __c{j} and advance.
//   state cont    (=B+1) CONTINUATION/TAIL: `return expr` -> result-store + state=done + return true.
//   state done    (=B+2) DONE: checked FIRST inside the while-true.
fn lowerAsyncLoopFn(
    low: *Lowerer,
    out: *std.ArrayList(ast.Decl),
    decl: ast.Decl,
    info: AsyncInfo,
    fut_type: []const u8,
    result_type: ast.TypeExpr,
    body: ast.Block,
) Error!void {
    const arena = low.arena;
    const fd = decl.kind.fn_decl;

    // ---- Split the body: optional PRE-LOOP straight-line (no await), exactly ONE await-bearing
    // `while`, then a straight-line TAIL ending in `return expr;`. ----
    var pre_loop: std.ArrayList(ast.Stmt) = .empty; // pre-loop straight-line decls/stmts (no await)
    var tail: std.ArrayList(ast.Stmt) = .empty; // post-loop straight-line tail (incl the return)
    var wl: ?WhileLoop = null;
    var seen_loop = false;
    for (body.items) |stmt| {
        if (stmt.kind == .loop and blockContainsAwait(stmt.kind.loop.body)) {
            if (seen_loop) return low.fail(stmt.span, "E_ASYNC_LOOP_UNSUPPORTED: async v0 supports at most ONE await-bearing loop", .{});
            const loop = stmt.kind.loop;
            if (loop.kind != .@"while") return low.fail(stmt.span, "E_ASYNC_LOOP_UNSUPPORTED: async v0 supports an `await` only inside a `while` loop (a `for` loop with awaits is unsupported)", .{});
            const cond = loop.iterable orelse return low.fail(stmt.span, "E_ASYNC_LOOP_UNSUPPORTED: a `while` loop must have a condition in async v0", .{});
            var w = WhileLoop{ .cond = cond };
            try collectLoopBody(low, loop.body, &w.steps, &w.tail);
            if (w.steps.items.len == 0) return low.fail(stmt.span, "E_ASYNC_LOOP_UNSUPPORTED: an await-bearing `while` body must begin with a `let x = await call;` run in async v0", .{});
            wl = w;
            seen_loop = true;
            continue;
        }
        if (stmtContainsAwait(stmt)) return low.fail(stmt.span, "E_ASYNC_LOOP_UNSUPPORTED: an await-bearing async fn with a loop may not have awaits in its pre-loop or tail (only inside the one `while` loop) in async v0", .{});
        if (!seen_loop) {
            try pre_loop.append(arena, stmt);
        } else {
            try tail.append(arena, stmt);
        }
    }
    const loopw = wl.?;
    const B = loopw.steps.items.len;

    // ---- Build the future struct: state + one __cN per body await + params + pre-loop locals +
    // body-awaited bindings + result. ----
    var fields: std.ArrayList(ast.Field) = .empty;
    try fields.append(arena, .{ .name = id("state"), .ty = try nameType(arena, "u8") });
    for (loopw.steps.items) |s| try fields.append(arena, .{ .name = id(s.child_field), .ty = try nameType(arena, s.fut_type) });
    for (fd.params) |p| try fields.append(arena, .{ .name = p.name, .ty = p.ty });
    // Pre-loop locals are live across the loop (the index/accumulator) -> captured fields; require an
    // explicit type annotation like the pre-branch locals.
    for (pre_loop.items) |stmt| switch (stmt.kind) {
        .let_decl, .var_decl => |ld| {
            if (ld.names.len != 1) return low.fail(stmt.span, "E_ASYNC_LOOP_UNSUPPORTED: a pre-loop `let`/`var` must bind exactly one name in async v0", .{});
            const lty = ld.ty orelse return low.fail(stmt.span, "E_ASYNC_LOOP_UNSUPPORTED: a pre-loop `let`/`var` live across the loop needs an explicit type annotation in async v0", .{});
            try fields.append(arena, .{ .name = ld.names[0], .ty = lty });
        },
        else => {},
    };
    for (loopw.steps.items) |s| if (s.binding) |nm| try fields.append(arena, .{ .name = id(nm), .ty = s.result_type });
    try fields.append(arena, .{ .name = id("result"), .ty = result_type });
    try out.append(arena, .{ .span = zspan, .attrs = &.{}, .kind = .{ .struct_decl = .{
        .name = id(fut_type),
        .abi = null,
        .fields = try fields.toOwnedSlice(arena),
    } } });

    // Captured names now read as `self.*`: params + pre-loop locals + body-awaited bindings.
    var field_names = std.StringHashMap(void).init(arena);
    for (fd.params) |p| try field_names.put(p.name.text, {});
    for (pre_loop.items) |stmt| switch (stmt.kind) {
        .let_decl, .var_decl => |ld| try field_names.put(ld.names[0].text, {}),
        else => {},
    };
    for (loopw.steps.items) |s| if (s.binding) |nm| try field_names.put(nm, {});
    const bind_names = &field_names;

    // ---- State indices. ----
    const cont_state: usize = B + 1;
    const done_state: usize = B + 2;
    const done_str = try std.fmt.allocPrint(arena, "{d}", .{done_state});

    // ---- Constructor: build NO child eagerly (the first child is built at the loop head); copy
    // params; REPLAY pre-loop straight-line decls as `self.x = init` stores; zero scalar fields. ----
    var cbody: std.ArrayList(ast.Stmt) = .empty;
    try cbody.append(arena, .{ .span = zspan, .kind = .{ .var_decl = .{
        .names = try dupIdents(arena, &.{"self"}),
        .ty = try nameType(arena, fut_type),
        .init = .{ .span = zspan, .kind = .uninit_literal },
    } } });
    try cbody.append(arena, assignStmt(try selfMember(arena, "state"), intExpr("0")));
    for (fd.params) |p| try cbody.append(arena, assignStmt(try selfMember(arena, p.name.text), identExpr(p.name.text)));
    // Replay the pre-loop straight-line, lifting `let/var x = init` to `self.x = init` and rewriting
    // captured reads to self.*.
    for (pre_loop.items) |stmt| try cbody.append(arena, try rewriteDeclToStore(low, stmt, bind_names));
    // Zero the body-awaited binding fields + result (definite-init for the move/borrow checker).
    for (loopw.steps.items) |s| if (s.binding) |b| try cbody.append(arena, assignStmt(try selfMember(arena, b), try zeroFor(low, s.result_type)));
    try cbody.append(arena, assignStmt(try selfMember(arena, "result"), try zeroFor(low, result_type)));
    try cbody.append(arena, .{ .span = zspan, .kind = .{ .@"return" = identExpr("self") } });
    try checkNoSelfBorrow(low, fd, cbody.items);
    try out.append(arena, .{ .span = zspan, .attrs = &.{}, .kind = .{ .fn_decl = .{
        .name = id(fd.name.text),
        .abi = null,
        .params = fd.params,
        .return_type = try nameType(arena, fut_type),
        .body = .{ .span = zspan, .items = try cbody.toOwnedSlice(arena) },
        .is_const = false,
        .exported = fd.exported,
    } } });

    // ---- The poll method: `while true { <state blocks> } return false;`. ----
    var inner: std.ArrayList(ast.Stmt) = .empty;
    // DONE early-return, checked FIRST.
    {
        var dbody = try arena.alloc(ast.Stmt, 1);
        dbody[0] = .{ .span = zspan, .kind = .{ .@"return" = .{ .span = zspan, .kind = .{ .bool_literal = true } } } };
        try inner.append(arena, try ifStateEq(arena, done_state, dbody));
    }
    // state 0 = LOOP HEAD: `if <cond> { build __c0; state=1 } else { state=cont }`.
    {
        var hbody: std.ArrayList(ast.Stmt) = .empty;
        var tb: std.ArrayList(ast.Stmt) = .empty;
        try emitBuildChild(low, &tb, loopw.steps.items[0], bind_names);
        try setState(low, &tb, 1);
        var ebl: std.ArrayList(ast.Stmt) = .empty;
        try setState(low, &ebl, cont_state);
        const rcond = try rewriteParamRefs(low, loopw.cond, bind_names);
        try hbody.append(arena, try ifElseBlock(arena, rcond, try tb.toOwnedSlice(arena), try ebl.toOwnedSlice(arena)));
        try inner.append(arena, try ifStateEq(arena, 0, try hbody.toOwnedSlice(arena)));
    }
    // states 1..B = LOOP BODY awaits.
    for (loopw.steps.items, 0..) |s, j| {
        var blk: std.ArrayList(ast.Stmt) = .empty;
        try emitPollAndTake(low, &blk, s);
        if (j + 1 < B) {
            try emitBuildChild(low, &blk, loopw.steps.items[j + 1], bind_names);
            try setState(low, &blk, j + 2); // states are 1-based: step j is state j+1
        } else {
            // LAST body await: run the body straight-line tail, then BACK-EDGE to the loop head.
            for (loopw.tail.items) |st| try blk.append(arena, try rewriteStmtParamRefs(low, st, bind_names));
            try setState(low, &blk, 0);
        }
        try inner.append(arena, try ifStateEq(arena, j + 1, try blk.toOwnedSlice(arena)));
    }
    // state cont = CONTINUATION/TAIL.
    {
        var tail_body: std.ArrayList(ast.Stmt) = .empty;
        for (tail.items) |stmt| switch (stmt.kind) {
            .@"return" => |maybe_expr| {
                const rexpr = maybe_expr orelse return low.fail(stmt.span, "async v0: `return` must return a value", .{});
                const rewritten = try rewriteParamRefs(low, rexpr, bind_names);
                try tail_body.append(arena, assignStmt(try selfMember(arena, "result"), rewritten));
                try tail_body.append(arena, assignStmt(try selfMember(arena, "state"), intExpr(done_str)));
                try tail_body.append(arena, .{ .span = zspan, .kind = .{ .@"return" = .{ .span = zspan, .kind = .{ .bool_literal = true } } } });
            },
            else => try tail_body.append(arena, try rewriteStmtParamRefs(low, stmt, bind_names)),
        };
        try inner.append(arena, try ifStateEq(arena, cont_state, try tail_body.toOwnedSlice(arena)));
    }
    // Wrap the state chain in `while true { ... }`, then a trailing `return false;` (the return
    // checker does not special-case `while true`, so this is REQUIRED to avoid E_RETURN_MISSING).
    var pbody: std.ArrayList(ast.Stmt) = .empty;
    try pbody.append(arena, try whileTrueBlock(try inner.toOwnedSlice(arena)));
    try pbody.append(arena, .{ .span = zspan, .kind = .{ .@"return" = .{ .span = zspan, .kind = .{ .bool_literal = false } } } });

    const poll_method_name = try std.fmt.allocPrint(arena, "{s}__poll", .{fut_type});
    var poll_params = try arena.alloc(ast.Param, 1);
    poll_params[0] = .{ .name = id("self"), .ty = try mutPtrType(arena, try nameType(arena, fut_type)) };
    try out.append(arena, .{ .span = zspan, .attrs = &.{}, .kind = .{ .fn_decl = .{
        .name = id(poll_method_name),
        .abi = null,
        .params = poll_params,
        .return_type = try nameType(arena, "bool"),
        .body = .{ .span = zspan, .items = try pbody.toOwnedSlice(arena) },
        .is_const = false,
    } } });

    // `impl Future for f__Fut` conformance record.
    var conf_methods = try arena.alloc(ast.ImplTraitMethod, 1);
    conf_methods[0] = .{
        .name = id("poll"),
        .mangled = poll_method_name,
        .self_mode = .by_mut_ptr,
        .params = poll_params,
        .return_type = try nameType(arena, "bool"),
    };
    try out.append(arena, .{ .span = zspan, .attrs = &.{}, .kind = .{ .impl_trait = .{
        .trait_name = id("Future"),
        .type_name = id(fut_type),
        .methods = conf_methods,
    } } });

    // `fn f__Fut_take_result(self) -> T { return self.result; }`.
    var tr_params = try arena.alloc(ast.Param, 1);
    tr_params[0] = .{ .name = id("self"), .ty = try mutPtrType(arena, try nameType(arena, fut_type)) };
    var tr_body: std.ArrayList(ast.Stmt) = .empty;
    try tr_body.append(arena, .{ .span = zspan, .kind = .{ .@"return" = try selfMember(arena, "result") } });
    try out.append(arena, .{ .span = zspan, .attrs = &.{}, .kind = .{ .fn_decl = .{
        .name = id(info.take_result),
        .abi = null,
        .params = tr_params,
        .return_type = result_type,
        .body = .{ .span = zspan, .items = try tr_body.toOwnedSlice(arena) },
        .is_const = false,
        .exported = fd.exported,
    } } });

    // `fn f__Fut_cancel(self) -> void`: one guard per body-await state (1..B), then mark DONE.
    var cn_params = try arena.alloc(ast.Param, 1);
    cn_params[0] = .{ .name = id("self"), .ty = try mutPtrType(arena, try nameType(arena, fut_type)) };
    var cn_body: std.ArrayList(ast.Stmt) = .empty;
    for (loopw.steps.items, 0..) |s, j| try emitCancelGuard(low, &cn_body, s, j + 1);
    try cn_body.append(arena, assignStmt(try selfMember(arena, "state"), intExpr(done_str)));
    try out.append(arena, .{ .span = zspan, .attrs = &.{}, .kind = .{ .fn_decl = .{
        .name = id(info.cancel),
        .abi = null,
        .params = cn_params,
        .return_type = try nameType(arena, "void"),
        .body = .{ .span = zspan, .items = try cn_body.toOwnedSlice(arena) },
        .is_const = false,
        .exported = fd.exported,
    } } });
}

// Split a `while` loop body into a leading await-run (-> `steps`) and a straight-line tail
// (-> `tail`). v0 rejects: `return`/`break`/`continue` inside the body; any await beyond the
// leading run (nested in straight-line code / control flow).
fn collectLoopBody(low: *Lowerer, blk: ast.Block, steps: *std.ArrayList(AwaitStep), tail: *std.ArrayList(ast.Stmt)) Error!void {
    const arena = low.arena;
    var in_tail = false;
    for (blk.items) |stmt| {
        const await_call = awaitStepCall(stmt);
        if (await_call != null and !in_tail) {
            const step = try buildAwaitStep(low, stmt, await_call.?, steps.items.len);
            try steps.append(arena, step);
            continue;
        }
        in_tail = true;
        switch (stmt.kind) {
            .@"return" => return low.fail(stmt.span, "E_ASYNC_LOOP_UNSUPPORTED: a `return` inside an await-bearing loop body is not supported in async v0", .{}),
            .@"break" => return low.fail(stmt.span, "E_ASYNC_LOOP_UNSUPPORTED: a `break` inside an await-bearing loop body is not supported in async v0", .{}),
            .@"continue" => return low.fail(stmt.span, "E_ASYNC_LOOP_UNSUPPORTED: a `continue` inside an await-bearing loop body is not supported in async v0", .{}),
            else => {},
        }
        if (stmtContainsAwait(stmt))
            return low.fail(stmt.span, "E_ASYNC_LOOP_UNSUPPORTED: an await-bearing loop body may contain only a LEADING run of `let x = await call;` then straight-line code (no awaits nested in inner loops, switches, or deeper control flow) in async v0", .{});
        try tail.append(arena, stmt);
    }
}

// ---- helpers ----

const ResolvedChild = struct {
    fut_type: []const u8,
    take_result: []const u8,
    cancel: []const u8,
    result_type: ast.TypeExpr,
};

// Resolve `await g(args)` to its child future type + take_result accessor + result type, using
// only the module's fn-return-type map (no sema). For an async callee, use its generated ABI;
// for a leaf, the callee's declared return type IS the future struct, and `<FutT>_take_result`
// is the (author-provided) accessor.
fn resolveAwait(low: *Lowerer, span: diagnostics.Span, call: ast.Expr) Error!ResolvedChild {
    const callee = switch (call.kind) {
        .call => |c| c.callee.*,
        else => return low.fail(span, "async v0: `await` must be applied to a call `g(args)`", .{}),
    };
    const cname = switch (callee.kind) {
        .ident => |i| i.text,
        else => return low.fail(span, "async v0: `await` must call a plain named function", .{}),
    };
    if (low.async_info.get(cname)) |ai| {
        return .{ .fut_type = ai.fut_type, .take_result = ai.take_result, .cancel = ai.cancel, .result_type = ai.result_type };
    }
    const fut_type = low.fn_ret_type.get(cname) orelse
        return low.fail(span, "async v0: awaited callee '{s}' must be an async fn or a future-returning function (with a declared struct return type)", .{cname});
    const take = try std.fmt.allocPrint(low.arena, "{s}_take_result", .{fut_type});
    const cancel = try std.fmt.allocPrint(low.arena, "{s}_cancel", .{fut_type});
    // The leaf's result type is unknown here; callers fall back to the binding's `: T` annotation.
    // Use a placeholder; a leaf await without a `: T` annotation is rejected at the call site.
    return .{ .fut_type = fut_type, .take_result = take, .cancel = cancel, .result_type = .{ .span = zspan, .kind = .{ .name = id("__async_infer") } } };
}

// Build an AwaitStep from a `let NAME = await CALL;` stmt, using `field_index` for its `__cN` field
// name. Shared by the pre-await run and both branch arms so field numbering is GLOBAL (unique).
fn buildAwaitStep(low: *Lowerer, stmt: ast.Stmt, acall: ast.Expr, field_index: usize) Error!AwaitStep {
    const arena = low.arena;
    const ld = stmt.kind.let_decl; // (let or var; both carry LocalDecl)
    if (ld.names.len != 1) return low.fail(stmt.span, "async v0: an awaited binding must bind exactly one name", .{});
    const child = try resolveAwait(low, stmt.span, acall);
    const field = try std.fmt.allocPrint(arena, "__c{d}", .{field_index});
    if (ld.ty == null and typeName(child.result_type) != null and std.mem.eql(u8, typeName(child.result_type).?, "__async_infer")) {
        return low.fail(stmt.span, "async v0: `let {s} = await <leaf>;` needs an explicit result type annotation `let {s}: T = await ...;`", .{ ld.names[0].text, ld.names[0].text });
    }
    const res_ty = ld.ty orelse child.result_type;
    return .{
        .binding = ld.names[0].text,
        .binding_type = ld.ty,
        .child_field = field,
        .fut_type = child.fut_type,
        .take_result = child.take_result,
        .cancel = child.cancel,
        .call = acall,
        .result_type = res_ty,
    };
}

// Split an arm's block into a leading await-run (-> `steps`) and a straight-line tail (-> `tail`).
// `field_base` is the GLOBAL `__cN` index for this arm's first await. v0 rejects: a `return` inside
// the arm, any await beyond the leading run (nested in straight-line code / control flow).
fn collectArm(low: *Lowerer, blk: ast.Block, field_base: usize, steps: *std.ArrayList(AwaitStep), tail: *std.ArrayList(ast.Stmt)) Error!void {
    const arena = low.arena;
    var in_tail = false;
    for (blk.items) |stmt| {
        const await_call = awaitStepCall(stmt);
        if (await_call != null and !in_tail) {
            const step = try buildAwaitStep(low, stmt, await_call.?, field_base + steps.items.len);
            try steps.append(arena, step);
            continue;
        }
        in_tail = true;
        if (stmt.kind == .@"return")
            return low.fail(stmt.span, "E_ASYNC_BRANCH_UNSUPPORTED: a `return` inside an await-bearing if/else arm is not supported in async v0 (the arm must fall through to the shared continuation)", .{});
        if (stmtContainsAwait(stmt))
            return low.fail(stmt.span, "E_ASYNC_BRANCH_UNSUPPORTED: in async v0 an if/else arm may contain only a LEADING run of `let x = await call;` then straight-line code (no awaits nested in loops, switches, or deeper control flow)", .{});
        try tail.append(arena, stmt);
    }
}

// `let x = await CALL;` (or `var`) — return the inner CALL expr if this stmt is exactly that.
fn awaitStepCall(stmt: ast.Stmt) ?ast.Expr {
    const ld = switch (stmt.kind) {
        .let_decl, .var_decl => |l| l,
        else => return null,
    };
    const init_expr = ld.init orelse return null;
    return switch (init_expr.kind) {
        .await_expr => |inner| inner.*,
        else => null,
    };
}

// Does the statement contain an `await` anywhere (used to reject awaits outside the leading run)?
fn stmtContainsAwait(stmt: ast.Stmt) bool {
    return switch (stmt.kind) {
        .let_decl, .var_decl => |l| if (l.init) |e| exprContainsAwait(e) else false,
        .@"return" => |e| if (e) |x| exprContainsAwait(x) else false,
        .expr => |e| exprContainsAwait(e),
        .assignment => |a| exprContainsAwait(a.target) or exprContainsAwait(a.value),
        .assert => |e| exprContainsAwait(e),
        .@"defer" => |e| exprContainsAwait(e),
        // Any control-flow construct in v0 conservatively "contains await" only if it actually
        // does; but v0 forbids awaits inside them, so a true here yields a clear diagnostic.
        else => stmtControlContainsAwait(stmt),
    };
}

fn stmtControlContainsAwait(stmt: ast.Stmt) bool {
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

fn blockContainsAwait(b: ast.Block) bool {
    for (b.items) |s| if (stmtContainsAwait(s)) return true;
    return false;
}

fn exprContainsAwait(e: ast.Expr) bool {
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

// Emit the suspend-or-take prologue of an await step into `blk`:
//   let r: bool = FutT__poll(&self.__cN);  if !r { return false; }
//   self.<binding> = FutT_take_result(&self.__cN);   (or drop the result if no binding)
fn emitPollAndTake(low: *Lowerer, blk: *std.ArrayList(ast.Stmt), s: AwaitStep) Error!void {
    const arena = low.arena;
    const poll_fn = try std.fmt.allocPrint(arena, "{s}__poll", .{s.fut_type});
    var poll_args = try arena.alloc(ast.Expr, 1);
    poll_args[0] = try addrOf(arena, try selfMember(arena, s.child_field));
    try blk.append(arena, .{ .span = zspan, .kind = .{ .let_decl = .{
        .names = try dupIdents(arena, &.{"r"}),
        .ty = try nameType(arena, "bool"),
        .init = try callExpr(arena, poll_fn, poll_args),
    } } });
    try blk.append(arena, try ifNotReturnFalse(arena));
    var take_args = try arena.alloc(ast.Expr, 1);
    take_args[0] = try addrOf(arena, try selfMember(arena, s.child_field));
    const take_call = try callExpr(arena, s.take_result, take_args);
    if (s.binding) |b| {
        try blk.append(arena, assignStmt(try selfMember(arena, b), take_call));
    } else {
        try blk.append(arena, .{ .span = zspan, .kind = .{ .expr = take_call } });
    }
}

// `self.__cN = g(args);` with the awaited call's ident args rewritten to read captured `self.*`
// fields (params + prior await results). Used to LAZILY construct an arm/pre child at a transition.
fn emitBuildChild(low: *Lowerer, blk: *std.ArrayList(ast.Stmt), s: AwaitStep, names: *std.StringHashMap(void)) Error!void {
    const rewritten = try rewriteParamRefs(low, s.call, names);
    try blk.append(low.arena, assignStmt(try selfMember(low.arena, s.child_field), rewritten));
}

// `self.state = N;`
fn setState(low: *Lowerer, blk: *std.ArrayList(ast.Stmt), n: usize) Error!void {
    const n_str = try std.fmt.allocPrint(low.arena, "{d}", .{n});
    try blk.append(low.arena, assignStmt(try selfMember(low.arena, "state"), intExpr(n_str)));
}

// Emit one `if self.state == N { ... }` poll block per await in an arm, at states `entry .. entry+T-1`.
// Each block polls its child, suspends while pending, takes the result; the next child is built
// lazily at the prior transition. After the LAST await, the arm's straight-line stmts run and state
// advances to `cont_state`. (T==0 arms produce no blocks here — handled synchronously at dispatch.)
fn emitArm(low: *Lowerer, pbody: *std.ArrayList(ast.Stmt), arm_steps: []const AwaitStep, arm_tail: []const ast.Stmt, entry: usize, cont_state: usize, names: *std.StringHashMap(void)) Error!void {
    const arena = low.arena;
    for (arm_steps, 0..) |s, i| {
        var blk: std.ArrayList(ast.Stmt) = .empty;
        try emitPollAndTake(low, &blk, s);
        if (i + 1 < arm_steps.len) {
            try emitBuildChild(low, &blk, arm_steps[i + 1], names);
            try setState(low, &blk, entry + i + 1);
        } else {
            // last await of the arm: run the arm's straight-line stmts, then go to the continuation.
            for (arm_tail) |st| try blk.append(arena, try rewriteStmtParamRefs(low, st, names));
            try setState(low, &blk, cont_state);
        }
        try pbody.append(arena, try ifStateEq(arena, entry + i, try blk.toOwnedSlice(arena)));
    }
}

// A pre-branch straight-line stmt, lifted into the poll machine: a `let/var x = init;` becomes
// `self.x = init;` (x is a captured field); reads of captured names rewrite to self.*. Anything else
// (assignment / expr) is rewritten in place.
fn rewriteDeclToStore(low: *Lowerer, s: ast.Stmt, names: *std.StringHashMap(void)) Error!ast.Stmt {
    switch (s.kind) {
        .let_decl, .var_decl => |ld| {
            const init_expr = ld.init orelse return low.fail(s.span, "E_ASYNC_BRANCH_UNSUPPORTED: a pre-branch `let`/`var` live across an await-bearing if/else must have an initializer in async v0", .{});
            const rinit = try rewriteParamRefs(low, init_expr, names);
            return assignStmt(try selfMember(low.arena, ld.names[0].text), rinit);
        },
        else => return rewriteStmtParamRefs(low, s, names),
    }
}

// `if self.state == N { <childType>_cancel(&self.__cN); }` — release the active state's in-flight child.
fn emitCancelGuard(low: *Lowerer, cn_body: *std.ArrayList(ast.Stmt), s: AwaitStep, state: usize) Error!void {
    const arena = low.arena;
    var cargs = try arena.alloc(ast.Expr, 1);
    cargs[0] = try addrOf(arena, try selfMember(arena, s.child_field));
    var cblk = try arena.alloc(ast.Stmt, 1);
    cblk[0] = .{ .span = zspan, .kind = .{ .expr = try callExpr(arena, s.cancel, cargs) } };
    try cn_body.append(arena, try ifStateEq(arena, state, cblk));
}

// ---- Interior-borrow check (move/borrow soundness across `await`) ----------------------------
// A future is built in its constructor as a local `self` and RETURNED BY VALUE, so the caller's
// copy lives at a new address. Any pointer the constructor forms INTO `self` (`&self.<field>`)
// therefore dangles after that move — a self-referential future, which needs pinning (not in v0).
//
// This is PRECISE and COMPLETE for the v0 lowering shapes: the only borrow of a captured
// local/param that can live across an `await` suspend is one the transform places in the
// CONSTRUCTOR — a pre-branch/pre-loop straight-line `let p = &x;` (replayed as `self.p = &self.x`)
// or a first-await arg `await g(&x)` (built as `self.__c0 = g(&self.x)`). A borrow formed in a
// poll state cannot span a suspend, because each region's straight-line runs AFTER that region's
// awaits. And the constructor never legitimately forms `&self.<field>` (it builds children by
// value; only `poll` takes `&self.__cN`). So `&self.<anything>` in the constructor is exactly the
// unsound set — no false positives, no false negatives.
fn checkNoSelfBorrow(low: *Lowerer, fd: ast.FnDecl, ctor_body: []const ast.Stmt) Error!void {
    for (ctor_body) |s| {
        if (stmtFormsSelfBorrow(s)) {
            return low.fail(fd.name.span, "E_ASYNC_BORROW_ACROSS_AWAIT: in async fn '{s}', a reference to a local or parameter (`&x`) is captured across an `await` — the future is returned by value, so an interior pointer dangles after the move (self-referential futures need pinning, unsupported in async v0). Restructure so no borrow of a captured value crosses the await.", .{fd.name.text});
        }
    }
}

// Is `e` rooted at the identifier `self` (a member/index/deref chain bottoming out at `self`)?
fn rootIsSelf(e: ast.Expr) bool {
    return switch (e.kind) {
        .ident => |i| std.mem.eql(u8, i.text, "self"),
        .member => |m| rootIsSelf(m.base.*),
        .index => |ix| rootIsSelf(ix.base.*),
        .deref => |inner| rootIsSelf(inner.*),
        .grouped => |inner| rootIsSelf(inner.*),
        else => false,
    };
}

// Does `e` form the address of `self.*` anywhere within it (`&self.x`, `g(&self.x)`, …)?
fn exprFormsSelfBorrow(e: ast.Expr) bool {
    return switch (e.kind) {
        .address_of => |inner| rootIsSelf(inner.*) or exprFormsSelfBorrow(inner.*),
        .grouped, .deref => |inner| exprFormsSelfBorrow(inner.*),
        .unary => |u| exprFormsSelfBorrow(u.expr.*),
        .binary => |b| exprFormsSelfBorrow(b.left.*) or exprFormsSelfBorrow(b.right.*),
        .cast => |c| exprFormsSelfBorrow(c.value.*),
        .call => |c| blk: {
            if (exprFormsSelfBorrow(c.callee.*)) break :blk true;
            for (c.args) |a| if (exprFormsSelfBorrow(a)) break :blk true;
            break :blk false;
        },
        .index => |ix| exprFormsSelfBorrow(ix.base.*) or exprFormsSelfBorrow(ix.index.*),
        .member => |m| exprFormsSelfBorrow(m.base.*),
        .try_expr => |t| exprFormsSelfBorrow(t.operand.*),
        else => false,
    };
}

fn stmtFormsSelfBorrow(s: ast.Stmt) bool {
    return switch (s.kind) {
        .let_decl, .var_decl => |l| if (l.init) |e| exprFormsSelfBorrow(e) else false,
        .assignment => |a| exprFormsSelfBorrow(a.target) or exprFormsSelfBorrow(a.value),
        .expr => |e| exprFormsSelfBorrow(e),
        .@"return" => |e| if (e) |x| exprFormsSelfBorrow(x) else false,
        else => false,
    };
}

fn assignStmt(target: ast.Expr, value: ast.Expr) ast.Stmt {
    return .{ .span = zspan, .kind = .{ .assignment = .{ .target = target, .value = value } } };
}

fn boolPattern(value: bool) ast.Pattern {
    return .{ .span = zspan, .kind = .{ .literal = .{ .span = zspan, .kind = .{ .bool_literal = value } } } };
}

// Build a boolean `if cond { body }` exactly as the parser desugars it: a `switch` on the bool
// with a `true => { body }` arm and an empty `false => {}` arm. This keeps generated control flow
// on the same lowering path the backends already exercise (no new construct).
fn ifCondBlock(arena: std.mem.Allocator, cond: ast.Expr, body: []ast.Stmt) Error!ast.Stmt {
    var arms = try arena.alloc(ast.SwitchArm, 2);
    var true_pats = try arena.alloc(ast.Pattern, 1);
    true_pats[0] = boolPattern(true);
    var false_pats = try arena.alloc(ast.Pattern, 1);
    false_pats[0] = boolPattern(false);
    arms[0] = .{ .patterns = true_pats, .body = .{ .block = .{ .span = zspan, .items = body } } };
    arms[1] = .{ .patterns = false_pats, .body = .{ .block = .{ .span = zspan, .items = &.{} } } };
    return .{ .span = zspan, .kind = .{ .@"switch" = .{ .subject = cond, .arms = arms } } };
}

// `while true { <body> }` — the back-edge wrapper for a loop-bearing poll. A body state sets
// `self.state` BACKWARD (to the loop head) and the while re-runs the if-state chain from the top.
fn whileTrueBlock(body: []ast.Stmt) Error!ast.Stmt {
    return .{ .span = zspan, .kind = .{ .loop = .{
        .kind = .@"while",
        .label = null,
        .iterable = .{ .span = zspan, .kind = .{ .bool_literal = true } },
        .body = .{ .span = zspan, .items = body },
    } } };
}

// `if cond { then } else { els }` as the parser's 2-arm bool `switch` desugar.
fn ifElseBlock(arena: std.mem.Allocator, cond: ast.Expr, then_body: []ast.Stmt, else_body: []ast.Stmt) Error!ast.Stmt {
    var arms = try arena.alloc(ast.SwitchArm, 2);
    var true_pats = try arena.alloc(ast.Pattern, 1);
    true_pats[0] = boolPattern(true);
    var false_pats = try arena.alloc(ast.Pattern, 1);
    false_pats[0] = boolPattern(false);
    arms[0] = .{ .patterns = true_pats, .body = .{ .block = .{ .span = zspan, .items = then_body } } };
    arms[1] = .{ .patterns = false_pats, .body = .{ .block = .{ .span = zspan, .items = else_body } } };
    return .{ .span = zspan, .kind = .{ .@"switch" = .{ .subject = cond, .arms = arms } } };
}

// `if !r { return false; }`
fn ifNotReturnFalse(arena: std.mem.Allocator) Error!ast.Stmt {
    const not_r: ast.Expr = .{ .span = zspan, .kind = .{ .unary = .{ .op = .logical_not, .expr = try ptr(arena, ast.Expr, identExpr("r")) } } };
    var body = try arena.alloc(ast.Stmt, 1);
    body[0] = .{ .span = zspan, .kind = .{ .@"return" = .{ .span = zspan, .kind = .{ .bool_literal = false } } } };
    return ifCondBlock(arena, not_r, body);
}

// `if self.state == N { <body> }`
fn ifStateEq(arena: std.mem.Allocator, n: usize, body: []ast.Stmt) Error!ast.Stmt {
    const n_str = try std.fmt.allocPrint(arena, "{d}", .{n});
    const cond: ast.Expr = .{ .span = zspan, .kind = .{ .binary = .{
        .op = .eq,
        .left = try ptr(arena, ast.Expr, try selfMember(arena, "state")),
        .right = try ptr(arena, ast.Expr, intExpr(n_str)),
    } } };
    return ifCondBlock(arena, cond, body);
}

fn dupIdents(arena: std.mem.Allocator, names: []const []const u8) Error![]ast.Ident {
    var out = try arena.alloc(ast.Ident, names.len);
    for (names, 0..) |n, i| out[i] = id(n);
    return out;
}

// A definite-init zero for a captured field. v0 uses `0` for scalars; the move/borrow checker
// only needs the field written before `return self`, and these fields are overwritten by the
// poll state machine before they are read. Scalars cover the v0 fixture's `i32`/`u64`/`bool`.
fn zeroFor(low: *Lowerer, ty: ast.TypeExpr) Error!ast.Expr {
    _ = low;
    if (typeName(ty)) |tn| {
        if (std.mem.eql(u8, tn, "bool")) return .{ .span = zspan, .kind = .{ .bool_literal = false } };
    }
    return intExpr("0");
}

// Rewrite bare-ident reads that name a captured field (param or awaited binding) to `self.<name>`.
// Inside the constructor and poll method the original locals are FIELDS, so a reference to `a`
// must become `self.a`. Recurses structurally over the expression.
fn rewriteParamRefs(low: *Lowerer, e: ast.Expr, names: *std.StringHashMap(void)) Error!ast.Expr {
    const arena = low.arena;
    return switch (e.kind) {
        .ident => |i| if (names.contains(i.text)) try selfMember(arena, i.text) else e,
        .grouped => |inner| .{ .span = e.span, .kind = .{ .grouped = try ptr(arena, ast.Expr, try rewriteParamRefs(low, inner.*, names)) } },
        .address_of => |inner| .{ .span = e.span, .kind = .{ .address_of = try ptr(arena, ast.Expr, try rewriteParamRefs(low, inner.*, names)) } },
        .deref => |inner| .{ .span = e.span, .kind = .{ .deref = try ptr(arena, ast.Expr, try rewriteParamRefs(low, inner.*, names)) } },
        .unary => |u| .{ .span = e.span, .kind = .{ .unary = .{ .op = u.op, .expr = try ptr(arena, ast.Expr, try rewriteParamRefs(low, u.expr.*, names)) } } },
        .binary => |b| .{ .span = e.span, .kind = .{ .binary = .{ .op = b.op, .left = try ptr(arena, ast.Expr, try rewriteParamRefs(low, b.left.*, names)), .right = try ptr(arena, ast.Expr, try rewriteParamRefs(low, b.right.*, names)) } } },
        .cast => |c| .{ .span = e.span, .kind = .{ .cast = .{ .value = try ptr(arena, ast.Expr, try rewriteParamRefs(low, c.value.*, names)), .ty = c.ty } } },
        .call => |c| blk: {
            var new_args = try arena.alloc(ast.Expr, c.args.len);
            for (c.args, 0..) |a, i| new_args[i] = try rewriteParamRefs(low, a, names);
            // The callee is a function name, not a captured local — leave it as-is.
            break :blk .{ .span = e.span, .kind = .{ .call = .{ .callee = c.callee, .type_args = c.type_args, .args = new_args } } };
        },
        .index => |ix| .{ .span = e.span, .kind = .{ .index = .{ .base = try ptr(arena, ast.Expr, try rewriteParamRefs(low, ix.base.*, names)), .index = try ptr(arena, ast.Expr, try rewriteParamRefs(low, ix.index.*, names)) } } },
        .member => |m| .{ .span = e.span, .kind = .{ .member = .{ .base = try ptr(arena, ast.Expr, try rewriteParamRefs(low, m.base.*, names)), .name = m.name } } },
        else => e,
    };
}

fn rewriteStmtParamRefs(low: *Lowerer, s: ast.Stmt, names: *std.StringHashMap(void)) Error!ast.Stmt {
    return switch (s.kind) {
        .let_decl, .var_decl => |l| blk: {
            const new_init = if (l.init) |e| try rewriteParamRefs(low, e, names) else null;
            const nl: ast.LocalDecl = .{ .names = l.names, .ty = l.ty, .init = new_init };
            break :blk .{ .span = s.span, .kind = if (s.kind == .let_decl) .{ .let_decl = nl } else .{ .var_decl = nl } };
        },
        .assignment => |a| .{ .span = s.span, .kind = .{ .assignment = .{ .target = try rewriteParamRefs(low, a.target, names), .value = try rewriteParamRefs(low, a.value, names) } } },
        .expr => |e| .{ .span = s.span, .kind = .{ .expr = try rewriteParamRefs(low, e, names) } },
        .@"return" => |e| .{ .span = s.span, .kind = .{ .@"return" = if (e) |x| try rewriteParamRefs(low, x, names) else null } },
        else => s,
    };
}
