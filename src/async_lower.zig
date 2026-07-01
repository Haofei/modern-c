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
// PHASE E, step E2: `await e` for an ARBITRARY future-valued expression, not only a plain named
// call. The awaited future is MATERIALIZED into the child slot by VALUE (`self.__cN = <e>`) at the
// transition that begins that await — exactly where the call used to be built — so the lazy
// at-most-one-child-live property (the E1 cancel walk depends on it) and the borrow-across-await
// rule are preserved unchanged. Supported `e` forms (future type resolved SYNTACTICALLY, no sema):
//   - call `g(args)` / `Owner.method(args)` (the parser pre-mangles UFCS to a plain ident call);
//   - parenthesized such expr `(g(args))`, `(ctx.fut)`;
//   - struct-FIELD future `base.fut` where `base` resolves to a known struct type (a param, or a
//     chain of struct fields) — the field's declared type IS the concrete future struct;
//   - array element `arr[i]` where `arr` is a param/field of `[N]ElemFut` (element type = `ElemFut`).
// DEFERRED (Phase E later): `*dyn Future` await (the vtable lacks `take_result`, so the typed result
// is unreachable through dispatch) and any `e` whose future type is not syntactically resolvable
// (e.g. a block expr, a method/UFCS call returning a future via an inherent-impl, an arbitrary local).
//
// CHILD-FUTURE ABI (uniform across generated futures and hand-written leaves), resolved WITHOUT
// sema by scanning the module's fn decls + struct-field types for the awaited future's struct type:
//   - `await e` ⇒ child future struct type `FutT` = the syntactic type of `e` (call return type,
//     awaited field's declared type, or array element type; for an async `g`, the transform rewrites
//     `g` to return `g__Fut`, so a call `g(...)` gives `FutT == g__Fut`);
//   - construct by value:  `self.__cN = <e>;` (child0 in the constructor; later children at
//                          the transition that ends the prior step, so they may read prior results);
//   - poll:                `FutT__poll(&self.__cN)`  (the `impl Future for FutT` method);
//   - typed result:        `FutT_take_result(&self.__cN)`  (a free fn; generated for async `g`,
//                          author-provided for a leaf — valid once, after poll()==true);
//   - cancel:              `FutT_cancel(&self.__cN)`  (a free fn; generated for async `g`,
//                          author-provided for a leaf — releases the in-flight slot on drop).

const std = @import("std");
const ast = @import("ast.zig");
const async_ast = @import("async_ast.zig");
const async_query = @import("async_query.zig");
const diagnostics = @import("diagnostics.zig");

const addrOf = async_ast.addrOf;
const arrayElemTypeName = async_ast.arrayElemTypeName;
const assignStmt = async_ast.assignStmt;
const awaitStepCall = async_query.awaitStepCall;
const blockContainsAwait = async_query.blockContainsAwait;
const boolPattern = async_ast.boolPattern;
const callExpr = async_ast.callExpr;
const dupIdents = async_ast.dupIdents;
const id = async_ast.id;
const identExpr = async_ast.identExpr;
const ifElseBlock = async_ast.ifElseBlock;
const ifNotReturnFalse = async_ast.ifNotReturnFalse;
const ifStateEq = async_ast.ifStateEq;
const intExpr = async_ast.intExpr;
const memberExpr = async_ast.memberExpr;
const isScalarIntName = async_ast.isScalarIntName;
const mutPtrType = async_ast.mutPtrType;
const nameType = async_ast.nameType;
const paramCarrierTypeName = async_ast.paramCarrierTypeName;
const ptr = async_ast.ptr;
const selfMember = async_ast.selfMember;
const stmtContainsAwait = async_query.stmtContainsAwait;
const typeName = async_ast.typeName;
const unwrapToAwaitCall = async_query.unwrapToAwaitCall;
const whileTrueBlock = async_ast.whileTrueBlock;
const zspan = async_ast.zspan;

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
    // E2: struct type name -> (field name -> field type name). Lets `await base.fut` resolve the
    // awaited field's CONCRETE future type syntactically (no sema), when `base` resolves to a known
    // struct type. Array fields are recorded under the synthetic field key "[]" (element type) so
    // `await arr[i]` (arr a field/param of `[N]ElemFut`) resolves to `ElemFut`.
    struct_fields: std.StringHashMap(std.StringHashMap([]const u8)),
    // E2: the CURRENT async fn's param name -> declared type name (reset per fn). The entry point
    // for resolving a field/index await's base type without sema.
    param_types: std.StringHashMap([]const u8),
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
    is_try: bool = false, // `let x = (await c)?;` — the awaited value is a Result; `?` propagates err
    try_mapped: ?ast.Expr = null, // `(await c)? else MAPPED` — the remapped error to propagate
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

// FINDING #3: scan a block (recursing through nested regions) for explicitly-typed `let`/`var`
// decls and record `name -> carrier type name` into `param_types`, so a future-carrier LOCAL
// resolves in `structTypeOf(.ident)` exactly like a param. Untyped decls (and awaited bindings,
// whose type is the awaited future's RESULT, not a carrier) contribute nothing. Re-keying after the
// general path's alpha-rename is handled by a second call on the renamed body.
//
// FINDING #2 (fail-closed regression): the map is FLAT and function-wide while `structTypeOf` has no
// scope model, so a naive `put` lets an inner `let ctx: Other` CLOBBER a param `ctx: Ctx` for the
// whole fn — breaking an earlier/outer `await ctx.fut` (param) that lexically PRECEDES the shadow.
// Fix: FIRST-WRITER-WINS — never overwrite an existing entry. Params are recorded before this scan
// (lowerAsyncFn), so a local can never clobber a param; and the lexically-EARLIER carrier (the one an
// earlier await depends on) is recorded before a later same-named shadow, so that await still
// resolves correctly. (In the general path the body is alpha-renamed before this runs, so every local
// is unique and first-vs-last is moot; the protection matters only for the non-renamed fast paths.)
// A genuinely ambiguous later shadow with a DIFFERENT carrier type that is itself awaited after its
// decl would, in the fast paths, mis-route — but such a shape (an await on a shadowing typed-carrier
// local) takes the general path, where alpha-rename makes it unambiguous; so no SILENT mis-resolution
// remains. Worst case is a clean fail-closed E_ASYNC_AWAIT_UNRESOLVED, never wrong codegen.
fn recordLocalCarrierTypes(low: *Lowerer, b: ast.Block) Error!void {
    for (b.items) |s| switch (s.kind) {
        .let_decl, .var_decl => |ld| {
            if (ld.ty) |ty| {
                if (paramCarrierTypeName(ty)) |tn| {
                    for (ld.names) |nm| {
                        if (!low.param_types.contains(nm.text)) try low.param_types.put(nm.text, tn);
                    }
                }
            }
        },
        .loop => |l| try recordLocalCarrierTypes(low, l.body),
        .block, .unsafe_block, .comptime_block => |bl| try recordLocalCarrierTypes(low, bl),
        .@"switch" => |sw| for (sw.arms) |arm| switch (arm.body) {
            .block => |bl| try recordLocalCarrierTypes(low, bl),
            .expr => {},
        },
        .if_let => |il| {
            try recordLocalCarrierTypes(low, il.then_block);
            if (il.else_block) |eb| try recordLocalCarrierTypes(low, eb);
        },
        else => {},
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
        .struct_fields = std.StringHashMap(std.StringHashMap([]const u8)).init(arena),
        .param_types = std.StringHashMap([]const u8).init(arena),
    };

    // E2 pass 0: record each struct's field -> field-type-name map (and array fields' element type
    // under key "[]"), so a field/index await can resolve its CONCRETE future type without sema.
    for (module.decls) |d| {
        if (d.kind != .struct_decl) continue;
        const sd = d.kind.struct_decl;
        var fm = std.StringHashMap([]const u8).init(arena);
        for (sd.fields) |f| {
            if (typeName(f.ty)) |tn| {
                try fm.put(f.name.text, tn);
            } else if (arrayElemTypeName(f.ty)) |en| {
                try fm.put(f.name.text, en);
            }
        }
        try low.struct_fields.put(sd.name.text, fm);
    }

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
                if (std.mem.eql(u8, o, k.*)) {
                    present = true;
                    break;
                }
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
        .let_decl, .var_decl => |l| {
            if (l.init) |e| patchUfcsExpr(arena, e, futs);
        },
        .assignment => |a| {
            patchUfcsExpr(arena, a.target, futs);
            patchUfcsExpr(arena, a.value, futs);
        },
        .expr => |e| patchUfcsExpr(arena, e, futs),
        .@"return" => |e| {
            if (e) |x| patchUfcsExpr(arena, x, futs);
        },
        .assert => |e| patchUfcsExpr(arena, e, futs),
        .@"defer" => |e| patchUfcsExpr(arena, e, futs),
        .block, .unsafe_block, .comptime_block => |b| {
            for (b.items) |it| patchUfcsStmt(arena, it, futs);
        },
        .loop => |lp| {
            if (lp.iterable) |it| patchUfcsExpr(arena, it, futs);
            for (lp.body.items) |it| patchUfcsStmt(arena, it, futs);
        },
        .if_let => |il| {
            patchUfcsExpr(arena, il.value, futs);
            for (il.then_block.items) |it| patchUfcsStmt(arena, it, futs);
            if (il.else_block) |eb| for (eb.items) |it| patchUfcsStmt(arena, it, futs);
        },
        .@"switch" => |sw| {
            patchUfcsExpr(arena, sw.subject, futs);
            for (sw.arms) |arm| switch (arm.body) {
                .block => |b| {
                    for (b.items) |it| patchUfcsStmt(arena, it, futs);
                },
                .expr => |e| patchUfcsExpr(arena, e, futs),
            };
        },
        .contract_block => |cb| {
            for (cb.block.items) |it| patchUfcsStmt(arena, it, futs);
        },
        else => {},
    }
}

// Recurse into an expression's child pointers and, when a child points at a `member{ ident(G),
// "poll" }`, overwrite it with `ident(G__poll)`.
fn patchUfcsExpr(arena: std.mem.Allocator, e: ast.Expr, futs: *std.StringHashMap(void)) void {
    switch (e.kind) {
        .grouped, .address_of, .deref => |inner| {
            patchUfcsOne(arena, inner, futs);
        },
        .unary => |u| patchUfcsOne(arena, u.expr, futs),
        .binary => |b| {
            patchUfcsOne(arena, b.left, futs);
            patchUfcsOne(arena, b.right, futs);
        },
        .cast => |c| patchUfcsOne(arena, c.value, futs),
        .call => |c| {
            patchUfcsOne(arena, c.callee, futs);
            for (c.args) |*a| patchUfcsOne(arena, a, futs);
        },
        .index => |ix| {
            patchUfcsOne(arena, ix.base, futs);
            patchUfcsOne(arena, ix.index, futs);
        },
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

    // E2: record this fn's param name -> declared type name, so a field/index await (`await p.fut`,
    // `await arr[i]`) can resolve the awaited future's CONCRETE type via the struct-field map.
    low.param_types.clearRetainingCapacity();
    for (fd.params) |p| {
        // Peel pointer/qualifier wrappers and map an array param to its element type, so both a
        // struct/future behind a pointer (`await p.fut`) and a (pointer-to-)array param element
        // (`await p[i]`) resolve — matching the E_ASYNC_AWAIT_UNRESOLVED message's promise.
        if (paramCarrierTypeName(p.ty)) |tn| try low.param_types.put(p.name.text, tn);
    }
    // FINDING #3: ALSO record explicitly-typed LOCAL carrier types (`let ctx: Ctx = ...;` /
    // `var ctx: Ctx = ...;`) so `await ctx.fut` (a local future-carrier) resolves the same way a
    // param carrier does. Without this, `structTypeOf(.ident)` only knew params and a typed-local
    // field await was rejected (E_ASYNC_AWAIT_UNRESOLVED) though `await param.fut` worked. We scan
    // the body (top-level + nested) for typed `let`/`var` decls; untyped locals are left unresolved
    // (the carrier type is unknown pre-sema). The general path records the POST-rename names below.
    if (fd.body) |b0| try recordLocalCarrierTypes(low, b0);

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

    // FINDING (HIGH): the general path alpha-renames every local to a unique name PRE-sema, so two
    // `let`/`var` of the SAME name in the SAME lexical scope — which ordinary MC rejects with
    // E_DUPLICATE_LOCAL — would be silently renamed apart and never seen by sema. The fast paths mask
    // it too (the body lowers with the source names untouched). Run a scope-aware duplicate-local
    // validation over EVERY async body BEFORE routing/renaming, failing with the SAME diagnostic
    // (code + message) sema's `addLocalBinding` raises — so an async fn accepts exactly the set of
    // locally-valid programs a non-async fn does. Legitimate shadowing across DISJOINT scopes (and a
    // nested binding that does not collide with a still-live enclosing one) stays accepted, matching
    // sema's `copyScope` discipline (params + the fn's top-level body share one scope; each block/
    // loop/arm inherits its enclosing bindings, so re-binding any still-live name is the error).
    try validateNoDuplicateLocals(low, fd.params, body);

    // ---- E3c: a body whose control flow is BEYOND the two pattern-matched fast paths — an `await`
    // nested inside inner control flow (an `if`/`switch`/`loop` within a loop body or an if/else arm),
    // or MORE THAN ONE await-bearing top-level construct — takes the GENERAL structured-CFG path
    // (`lowerAsyncGeneralFn`): the whole body becomes one `while true { switch state }` dispatch with a
    // per-suspend-point state numbering and build-on-the-entry-edge. The two fast paths below are left
    // untouched for the exact shapes they already handle (zero regression), so only the previously-
    // REJECTED shapes route here. ----
    //
    // ROOT-CAUSE ROUTING (finding: fast-path capture keys fields by ORIGINAL binding name, so it
    // cannot represent lexical shadowing). The fast paths build the future-struct's captured fields by
    // ORIGINAL name from: params + pre-region (pre-branch/pre-loop) top-level locals + awaited
    // bindings. If any two of those sources share a name, the struct gets a duplicate field
    // (E_DUPLICATE_STRUCT_FIELD) and/or the carrier-type map mis-resolves an `await x.fut` to the
    // FIRST writer's type (E_RETURN_TYPE_MISMATCH) — both are broken-generated-struct errors on VALID
    // shadowing source. The general path alpha-renames every local to a globally-unique name BEFORE
    // lowering, so neither a capture-field collision nor a carrier mis-resolution is possible there.
    // Therefore: route any fast-path-breaking capture-name collision to the general path. (We detect
    // ONLY the captured-name sources, so a non-captured arm/loop-body/tail local that shadows a param —
    // already handled correctly by the fast-path rewriters' shadow-removal — keeps the fast path.)
    if (fastPathCaptureCollision(fd.params, body)) {
        return lowerAsyncGeneralFn(low, out, decl, info, fut_type, result_type, body);
    }
    if (needsGeneralLowering(body)) {
        return lowerAsyncGeneralFn(low, out, decl, info, fut_type, result_type, body);
    }

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
    // One child-future ARM per await, across pre-run + both arms (only the taken arm's children are
    // ever built — lazy — and only one is live at a time), overlaid in a single addressable union.
    var child_arms: std.ArrayList(ast.Field) = .empty;
    for (steps.items) |s| {
        try child_arms.append(arena, .{ .name = id(s.child_field), .ty = try nameType(arena, s.fut_type) });
    }
    if (branch) |b| {
        for (b.then_steps.items) |s| try child_arms.append(arena, .{ .name = id(s.child_field), .ty = try nameType(arena, s.fut_type) });
        for (b.else_steps.items) |s| try child_arms.append(arena, .{ .name = id(s.child_field), .ty = try nameType(arena, s.fut_type) });
    }
    try appendChildUnionField(arena, out, &fields, fut_type, child_arms.items);
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
        try cbody.append(arena, assignStmt(try selfChild(arena, s0.child_field), rewritten));
    }
    // Zero the captured binding fields + result (definite-init for the move/borrow checker). This
    // covers pre-await bindings, pre-branch locals, and BOTH arms' awaited bindings — every scalar
    // field the poll machine may read. (The real pre-branch local init is replayed at the dispatch.)
    for (steps.items) |s| {
        if (s.binding) |b| try appendZeroInit(low, &cbody, b, s.result_type);
    }
    if (branch) |b| {
        for (pre_branch.items) |stmt| switch (stmt.kind) {
            .let_decl, .var_decl => |ld| try appendZeroInit(low, &cbody, ld.names[0].text, ld.ty.?),
            else => {},
        };
        for (b.then_steps.items) |s| if (s.binding) |nm| try appendZeroInit(low, &cbody, nm, s.result_type);
        for (b.else_steps.items) |s| if (s.binding) |nm| try appendZeroInit(low, &cbody, nm, s.result_type);
    }
    try appendZeroInit(low, &cbody, "result", result_type);
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
            // zero-await then arm: run its straight-line stmts now, then go to the continuation. The
            // arm may END in a `return expr;` (an early exit that doesn't fall through to the common
            // tail) — route through rewriteRegionBlock so that `return` becomes the DONE transition
            // (`self.result = expr; self.state = DONE; return true;`), NOT a bare `return <expr>;`
            // emitted into the bool-returning `poll` (that was E_RETURN_TYPE_MISMATCH on valid source).
            // The trailing `setState(cont_state)` is then dead-but-harmless after an unconditional
            // return, and is the correct fall-through edge when the arm does NOT return.
            const rtb = try rewriteRegionBlock(low, .{ .span = zspan, .items = b.then_tail.items }, bind_names, done_str);
            for (rtb.items) |st| try tb.append(arena, st);
            try setState(low, &tb, cont_state);
        }
        // else-branch body
        var eb: std.ArrayList(ast.Stmt) = .empty;
        if (n_else > 0) {
            try emitBuildChild(low, &eb, b.else_steps.items[0], bind_names);
            try setState(low, &eb, else_entry);
        } else {
            const reb = try rewriteRegionBlock(low, .{ .span = zspan, .items = b.else_tail.items }, bind_names, done_str);
            for (reb.items) |st| try eb.append(arena, st);
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
        try emitPollAndTake(low, &blk, s, done_str);
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
        try emitArm(low, &pbody, b.then_steps.items, b.then_tail.items, arm_base, cont_state, done_str, bind_names);
        try emitArm(low, &pbody, b.else_steps.items, b.else_tail.items, arm_base + n_then, cont_state, done_str, bind_names);
    }

    // The continuation / tail. `return expr;` -> result-store + advance to DONE + `return true`. Other
    // tail stmts emit as-is with captured-name reads rewritten to self.*. Guarding it at cont_state
    // (plus the DONE early-return) keeps poll idempotent.
    var tail_body: std.ArrayList(ast.Stmt) = .empty;
    // Route through rewriteRegionBlock for block-scoped `let`/`var` shadow handling (a region-local
    // shadowing a captured name reads the local, not `self.<name>`). E3a: a `return` (top-level or
    // nested in non-await control flow) becomes the DONE transition.
    const rtail = try rewriteRegionBlock(low, .{ .span = zspan, .items = tail.items }, bind_names, done_str);
    for (rtail.items) |stmt| try tail_body.append(arena, stmt);
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
    // conformance check passes) — mirrors how parseImplBlock appends an `impl_trait` Decl. E1: the
    // `Future` trait now REQUIRES `cancel` too, so the record carries BOTH methods. `poll` resolves
    // to the impl method `f__Fut__poll`; `cancel` resolves to the generated free fn `f__Fut_cancel`
    // emitted below (a vtable slot may name any existing fn symbol — same as `poll`'s mangled name).
    var conf_methods = try arena.alloc(ast.ImplTraitMethod, 2);
    conf_methods[0] = .{
        .name = id("poll"),
        .mangled = poll_method_name,
        .self_mode = .by_mut_ptr,
        .params = poll_params,
        .return_type = try nameType(arena, "bool"),
    };
    conf_methods[1] = try cancelConfMethod(low, info, fut_type);
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
    // active child, so they fall through to the DONE store. E1: this free fn is ALSO wired into the
    // `impl Future` record above (as the `cancel` vtable slot), so a generated future satisfies the
    // `Future` trait that now requires `cancel` — see `cancelConfMethod`. ----
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
    var child_arms: std.ArrayList(ast.Field) = .empty;
    for (loopw.steps.items) |s| try child_arms.append(arena, .{ .name = id(s.child_field), .ty = try nameType(arena, s.fut_type) });
    try appendChildUnionField(arena, out, &fields, fut_type, child_arms.items);
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
    for (loopw.steps.items) |s| if (s.binding) |b| try appendZeroInit(low, &cbody, b, s.result_type);
    try appendZeroInit(low, &cbody, "result", result_type);
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
        try emitPollAndTake(low, &blk, s, done_str);
        if (j + 1 < B) {
            try emitBuildChild(low, &blk, loopw.steps.items[j + 1], bind_names);
            try setState(low, &blk, j + 2); // states are 1-based: step j is state j+1
        } else {
            // LAST body await: run the body straight-line tail (E3a: a `return` inside the body
            // becomes the DONE transition; E3b: a `break`/`continue` becomes the loop-exit/head
            // transition), then BACK-EDGE to the loop head. If the body ends in an unconditional
            // break/continue/return, the `state=0` below is dead but harmless.
            // Route the tail through rewriteLoopBodyBlock so block-scoped `let`/`var` shadowing of a
            // captured name is honored (a region-local must read the local, not the captured field).
            const rtail = try rewriteLoopBodyBlock(low, .{ .span = zspan, .items = loopw.tail.items }, bind_names, done_str, cont_state, false);
            for (rtail.items) |st| try blk.append(arena, st);
            try setState(low, &blk, 0);
        }
        try inner.append(arena, try ifStateEq(arena, j + 1, try blk.toOwnedSlice(arena)));
    }
    // state cont = CONTINUATION/TAIL.
    {
        var tail_body: std.ArrayList(ast.Stmt) = .empty;
        // The post-loop tail is straight-line (no break/continue): a `return` becomes the DONE
        // transition (E3a-consistent; nested returns handled too).
        const rtail2 = try rewriteRegionBlock(low, .{ .span = zspan, .items = tail.items }, bind_names, done_str);
        for (rtail2.items) |stmt| try tail_body.append(arena, stmt);
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

    // `impl Future for f__Fut` conformance record (E1: carries both `poll` and `cancel`).
    var conf_methods = try arena.alloc(ast.ImplTraitMethod, 2);
    conf_methods[0] = .{
        .name = id("poll"),
        .mangled = poll_method_name,
        .self_mode = .by_mut_ptr,
        .params = poll_params,
        .return_type = try nameType(arena, "bool"),
    };
    conf_methods[1] = try cancelConfMethod(low, info, fut_type);
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

// ===== E3c: GENERAL structured-CFG lowering =====================================================
// The two fast paths (`lowerAsyncFn` linear/branch, `lowerAsyncLoopFn`) pattern-match a single
// await-bearing construct with a flat contiguous state range. E3c generalizes to ARBITRARY nesting
// and SEQUENCING of await-bearing constructs by lowering the whole body as a structured CFG into ONE
// `while true { if state==DONE return true; <state blocks> } return false;` dispatch, with a
// per-suspend-point state numbering. The crux invariants — at-most-one-child-live and
// build-once-per-entry — hold BY CONSTRUCTION:
//   * Every `await` is its OWN poll-state. That state ONLY polls `&self.__cN`, suspends while pending
//     (`return false`), then takes the result into the binding field. It NEVER builds a child.
//   * A child is materialized (`self.__cN = <expr>;`) on the ENTRY EDGE — the predecessor block,
//     immediately before `self.state = pollState; continue;`. Re-polling re-enters the poll-state via
//     the while-true dispatch (NOT via the edge), so it never rebuilds (build-once-per-entry). A loop
//     back-edge re-runs the loop head, which routes through the body-entry edge that rebuilds the loop
//     child exactly once per iteration.
//   * Because the build sits on the edge and the take happens inside the poll-state before control
//     leaves it, at any suspend exactly the current poll-state's child is live; no edge builds two
//     children, and the next await's child is built only after the prior poll-state took its result and
//     left (at-most-one-child-live).
// `return`/`break`/`continue` lower to state-edges that run AFTER the region's await took its result
// (no live child at the edge); cancel walks `if state==N { __cN_cancel }` per await poll-state then
// marks DONE (cancel-on-every-exit + idempotent). The constructor builds NO child (every child is
// edge-built in `poll`), so `checkNoSelfBorrow` over the constructor stays sound+complete unchanged.

// Does the body need the general path (i.e. is it BEYOND both fast paths)? True iff there is more than
// one top-level await-bearing construct, OR an `await` nested inside inner control flow within a loop
// body / if-arm (which the flat per-construct allocator cannot number). Shapes the fast paths accept
// (a single leading await-run + at most one await-bearing if/else, OR a single await-bearing while with
// a leading-await-run body) return false here and keep their byte-for-byte lowering — zero regression.
// ROOT-CAUSE collision detector for the fast paths. The branch/loop fast paths emit the future
// struct's CAPTURED fields BY ORIGINAL binding name from exactly three sources, and rely on each
// captured name being unique (one struct field, one carrier-type entry):
//   (1) params                                  (async_lower.zig branch ~620 / loop ~976)
//   (2) pre-REGION top-level `let`/`var` locals  (pre-branch ~635 / pre-loop ~983)
//   (3) awaited bindings `let x = await E;`      (pre-run ~624, both arms ~642/643, loop body ~987)
// A name appearing in TWO of these sources yields a duplicate field (E_DUPLICATE_STRUCT_FIELD) and/or
// a carrier mis-resolution (the first-writer-wins `param_types` map binds the awaited `x.fut` to the
// WRONG carrier → E_RETURN_TYPE_MISMATCH). Both are broken-generated-struct errors on valid shadowing
// source. This predicate returns true iff the fast paths WOULD build such a colliding capture set, so
// the caller can route the fn to the alpha-renaming general path instead. It is intentionally a tight
// over-approximation: it counts every name a fast path could capture as a field. NON-captured locals
// (arm-body / loop-body / post-region tail decls) are excluded — the fast-path rewriters already honor
// their shadowing via shadow-removal, so those keep the fast path (no needless rerouting).
//
// `in_region` = "we are at/after the first await-bearing top-level branch/loop". Top-level locals
// BEFORE it are captured (source 2); AFTER it they are tail-only (not captured) and ignored. Awaited
// bindings are gathered structurally from the leading await-runs the fast paths actually capture.
fn fastPathCaptureCollision(params: []const ast.Param, body: ast.Block) bool {
    var seen = std.StringHashMap(void).init(std.heap.page_allocator);
    defer seen.deinit();
    // A name collides if we try to add it twice. `add` returns true on the SECOND insertion.
    const add = struct {
        fn f(s: *std.StringHashMap(void), name: []const u8) bool {
            if (s.contains(name)) return true;
            s.put(name, {}) catch return true; // OOM: fail safe → route to general
            return false;
        }
    }.f;

    for (params) |p| if (add(&seen, p.name.text)) return true;

    var in_region = false;
    for (body.items) |stmt| {
        // An await-bearing top-level branch or loop is the fast-path REGION. Its leading await-runs
        // are captured; we count their bindings, then mark in_region so later top-level locals (tail)
        // are NOT counted as captured fields.
        if (asBoolIf(stmt)) |bi| {
            if (blockContainsAwait(bi.then_blk) or blockContainsAwait(bi.else_blk)) {
                if (collectLeadingAwaitBindings(&seen, bi.then_blk)) return true;
                if (collectLeadingAwaitBindings(&seen, bi.else_blk)) return true;
                in_region = true;
                continue;
            }
        }
        if (stmt.kind == .loop and blockContainsAwait(stmt.kind.loop.body)) {
            if (collectLeadingAwaitBindings(&seen, stmt.kind.loop.body)) return true;
            in_region = true;
            continue;
        }
        // Top-level straight-line stmt. A pre-region `let`/`var` is captured (source 2); a pre-region
        // top-level awaited-let is captured (source 3). Post-region top-level decls are tail-only.
        switch (stmt.kind) {
            .let_decl, .var_decl => |ld| {
                if (!in_region) for (ld.names) |nm| {
                    if (add(&seen, nm.text)) return true;
                };
            },
            else => {},
        }
    }
    return false;
}

// Add the binding names of a block's LEADING run of `let x = await E;` (the run the fast paths
// capture). Stops at the first non-await-let stmt (the arm/loop "tail" begins there, matching
// collectArm/collectLoopBody). Returns true on the first duplicate.
fn collectLeadingAwaitBindings(seen: *std.StringHashMap(void), b: ast.Block) bool {
    for (b.items) |s| {
        if (awaitStepCall(s) == null) break; // leading await-run ended
        const ld = switch (s.kind) {
            .let_decl, .var_decl => |l| l,
            else => break,
        };
        for (ld.names) |nm| {
            if (seen.contains(nm.text)) return true;
            seen.put(nm.text, {}) catch return true;
        }
    }
    return false;
}

fn needsGeneralLowering(body: ast.Block) bool {
    var top_await_ifs: usize = 0;
    var top_await_loops: usize = 0;
    for (body.items) |stmt| {
        if (asBoolIf(stmt)) |bi| {
            if (blockContainsAwait(bi.then_blk) or blockContainsAwait(bi.else_blk)) {
                top_await_ifs += 1;
                // An await nested in inner control flow within either arm needs the general path.
                if (blockHasNestedAwait(bi.then_blk) or blockHasNestedAwait(bi.else_blk)) return true;
            }
            continue;
        }
        if (stmt.kind == .loop and blockContainsAwait(stmt.kind.loop.body)) {
            top_await_loops += 1;
            if (blockHasNestedAwait(stmt.kind.loop.body)) return true;
        }
    }
    // More than one top-level await-bearing construct (e.g. await-if THEN await-while), or an
    // await-while mixed with an await-if, is multi-construct — general.
    return (top_await_ifs + top_await_loops) > 1;
}

// Does this block (a loop body or if-arm) contain an `await` NESTED inside inner control flow — i.e.
// inside an `if`/`switch`/`loop`/inner block — as opposed to a top-level leading `let x = await e;`?
// The fast paths only support a LEADING run of top-level await-lets in a region; anything deeper is
// E3c. (A top-level await-let in the block is NOT "nested"; an await inside a top-level if/loop IS.)
fn blockHasNestedAwait(b: ast.Block) bool {
    for (b.items) |s| {
        switch (s.kind) {
            // A top-level await-let is fine (fast-path leading run). Any OTHER top-level stmt that
            // contains an await has that await nested in inner control flow.
            .let_decl, .var_decl => {},
            else => if (stmtContainsAwait(s)) return true,
        }
    }
    return false;
}

// ===== general-path alpha-rename (findings #1 + #2) =====
//
// PROBLEM. The general path captures every local that is live across a suspend as a `self.*` field,
// and rewrites references to that local by NAME (`rewriteParamRefs` maps any ident whose text is a
// captured name to `self.<name>`). That is sound ONLY when every textual occurrence of a name refers
// to ONE declaration. Two failures arise otherwise:
//   #1 a local declared INSIDE a nested region (an `if`/`while` block) and read AFTER a later await
//      was NOT captured (the capture set was params + awaited bindings + TOP-LEVEL let/var only), so
//      it was emitted as a plain local in one poll-state and referenced in a later one -> sema's
//      E_UNKNOWN_IDENTIFIER on the user's variable.
//   #2 the SAME name declared in two disjoint scopes produced two struct fields of that name ->
//      E_DUPLICATE_STRUCT_FIELD at 0:0 (no source location).
//
// FIX. Run a lexically-scoped alpha-rename over the async-fn body BEFORE lowering: give every `let`/
// `var` binding a globally UNIQUE fresh name and rewrite its in-scope references to that fresh name,
// honoring shadowing (an inner decl shadows an outer same-named one only within its block). After
// this pass NO two declarations share a name, so (a) every local — including nested ones — can be
// captured as a uniquely-named field with the existing name-keyed rewrite, and (b) #2's duplicate
// field is impossible. Params are NEVER renamed (they are not locals and the awaited-expr resolver +
// the ctor's param copies key on the original param names). The pass is pure source-to-source AST
// rewriting that runs before any state-machine construction, so it is backend-agnostic by definition.

// Scope-aware duplicate-local validation, mirroring sema's `addLocalBinding` (src/sema.zig): a
// `let`/`var` whose name already exists in the CURRENT scope OR any still-live enclosing scope is
// E_DUPLICATE_LOCAL (sema seeds the fn's top scope with params, then `checkBlock` reuses that scope,
// and each nested region copies its parent's bindings in via `copyScope`, so re-binding ANY live name
// is the error — exactly what a frame-stack `lookup` over all open frames detects). Runs for ALL async
// fns BEFORE routing/renaming, so the diagnostic is identical regardless of which lowering path the
// body takes; without it the renamer/fast-paths would silently accept invalid source.
const DupScope = struct {
    low: *Lowerer,
    // Innermost-last stack of name→span maps; a name is a duplicate if it is in ANY currently-open frame.
    frames: std.ArrayList(std.StringHashMap(diagnostics.Span)) = .empty,

    fn arena(self: *DupScope) std.mem.Allocator {
        return self.low.arena;
    }
    fn push(self: *DupScope) Error!void {
        try self.frames.append(self.arena(), std.StringHashMap(diagnostics.Span).init(self.arena()));
    }
    fn pop(self: *DupScope) void {
        _ = self.frames.pop();
    }
    fn liveInAnyFrame(self: *DupScope, name: []const u8) bool {
        var i: usize = self.frames.items.len;
        while (i > 0) {
            i -= 1;
            if (self.frames.items[i].contains(name)) return true;
        }
        return false;
    }
    // Bind `name` into the current (innermost) frame, failing E_DUPLICATE_LOCAL if it collides with a
    // still-live binding in this or any enclosing frame.
    fn bind(self: *DupScope, name: ast.Ident) Error!void {
        if (self.liveInAnyFrame(name.text)) {
            return self.low.fail(name.span, "E_DUPLICATE_LOCAL: local bindings must have unique names in the current scope", .{});
        }
        try self.frames.items[self.frames.items.len - 1].put(name.text, name.span);
    }
};

// Validate a whole async fn body: params + top-level body live in ONE scope (matching sema's
// `checkFn`), each nested block/loop/arm pushes a child frame that inherits its parent's bindings.
fn validateNoDuplicateLocals(low: *Lowerer, params: []const ast.Param, body: ast.Block) Error!void {
    var ds = DupScope{ .low = low };
    try ds.push(); // the fn's top scope: params + the body's top-level locals share it
    defer ds.pop();
    // Param-vs-param collisions are E_DUPLICATE_PARAMETER in sema (`checkFn`), NOT E_DUPLICATE_LOCAL.
    // Detect them SEPARATELY before seeding the scope so the diagnostic matches non-async exactly; a
    // body local later shadowing a (now known-unique) param still reports E_DUPLICATE_LOCAL via `bind`.
    {
        var seen = std.StringHashMap(void).init(low.arena);
        for (params) |p| {
            if (seen.contains(p.name.text)) {
                return low.fail(p.name.span, "E_DUPLICATE_PARAMETER: function parameter names must be unique", .{});
            }
            try seen.put(p.name.text, {});
        }
    }
    for (params) |p| try ds.bind(p.name);
    try dupCheckBlockItems(&ds, body);
}

// Walk a block's items WITHOUT pushing a frame (the caller owns the frame), so a loop's condition and
// body — and the fn's params and top-level body — share one scope, exactly as sema does.
fn dupCheckBlockItems(ds: *DupScope, b: ast.Block) Error!void {
    for (b.items) |st| try dupCheckStmt(ds, st);
}

// Walk a nested block in its OWN child frame (it inherits the enclosing bindings via `liveInAnyFrame`).
fn dupCheckBlock(ds: *DupScope, b: ast.Block) Error!void {
    try ds.push();
    defer ds.pop();
    try dupCheckBlockItems(ds, b);
}

fn dupCheckStmt(ds: *DupScope, s: ast.Stmt) Error!void {
    switch (s.kind) {
        .let_decl, .var_decl => |ld| {
            for (ld.names) |nm| try ds.bind(nm);
        },
        .block => |b| try dupCheckBlock(ds, b),
        .unsafe_block => |b| try dupCheckBlock(ds, b),
        .comptime_block => |b| try dupCheckBlock(ds, b),
        .contract_block => |c| try dupCheckBlock(ds, c.block),
        .loop => |l| {
            // The condition/iterable and the body share one (child) frame, matching the renamer and
            // sema (a `for` binds its element in the body scope; a `while` cond + body in one scope).
            try ds.push();
            defer ds.pop();
            // A `for x in xs` binds its element `x` into the body scope (sema's `checkForBody`/
            // `addForBinding`), so re-using a still-live name there is E_DUPLICATE_LOCAL. A `while`
            // loop's `label` is a loop LABEL, not a value binding — only bind for `.@"for"`.
            if (l.kind == .@"for") {
                if (l.label) |lbl| try ds.bind(lbl);
            }
            try dupCheckBlockItems(ds, l.body);
        },
        .if_let => |node| {
            // `if`/`if let`: the then-block is a child scope; a `.bind`/`.tag_bind` pattern introduces
            // an arm-local into it (sema binds the pattern then checks the then-block in that scope).
            try ds.push();
            try dupCheckPattern(ds, node.pattern);
            try dupCheckBlockItems(ds, node.then_block);
            ds.pop();
            if (node.else_block) |eb| try dupCheckBlock(ds, eb);
        },
        .@"switch" => |sw| {
            // Switch arm binding-ness splits into a type-INDEPENDENT case and a type-DEPENDENT one.
            //
            // A SINGLE-pattern `.tag_bind` (`ok(x)`) is a union-payload destructure that ALWAYS binds,
            // independent of the subject type. The general path alpha-renames outer locals BEFORE sema,
            // hiding a payload shadowing a still-live outer (E_DUPLICATE_LOCAL in non-async) AND silently
            // miscompiling its body read to the outer carrier. So we dup-check it HERE, pre-rename —
            // `ds.bind` fails on a live-outer collision, mirroring sema exactly.
            //
            // A bare `.bind` (`x`) is TYPE-DEPENDENT: sema binds it ONLY for a NULLABLE subject (the
            // unwrap); a non-nullable `switch n { x => ... }` is a catch-all binding nothing (body reads
            // the outer). We CANNOT decide that here, pre-sema, for an arbitrary subject (a call/member/
            // alias needs real type resolution) — and the general path renames the colliding outer into a
            // `self.*` field, so sema can no longer SEE the source collision. So: detect the COLLISION
            // (type-independent — `liveInAnyFrame`) and FLAG the arm; sema, which has the resolved subject
            // type, fires E_DUPLICATE_LOCAL iff it actually binds (nullable). This recovers exact parity
            // for EVERY subject shape without re-deriving the type here (closing the leaf-by-leaf chase of
            // syntactic nullability). MULTI-pattern arms defer wholesale (a binding there is
            // E_SWITCH_MULTI_BINDING_ARM; flagging/pre-binding would mask it). We still recurse each arm
            // body in its own child frame so a genuine NESTED `let` is dup-checked.
            for (sw.arms, 0..) |arm, i| {
                try ds.push();
                if (arm.patterns.len == 1) {
                    switch (arm.patterns[0].kind) {
                        .tag_bind => |tb| try ds.bind(tb.binding),
                        .bind => |nm| if (ds.liveInAnyFrame(nm.text)) {
                            sw.arms[i].dup_local_if_binds = true;
                        },
                        else => {},
                    }
                }
                switch (arm.body) {
                    .block => |b| try dupCheckBlockItems(ds, b),
                    .expr => {},
                }
                ds.pop();
            }
        },
        // No locals introduced into the enclosing scope.
        else => {},
    }
}

// `dupCheckPattern` handles patterns that ALWAYS bind unconditionally (an `if let` narrowing). Switch
// patterns are NOT routed here — their binding-ness is type-dependent (see `.@"switch"` above), so
// sema validates them.
fn dupCheckPattern(ds: *DupScope, p: ast.Pattern) Error!void {
    switch (p.kind) {
        .bind => |b| try ds.bind(b),
        .tag_bind => |tb| try ds.bind(tb.binding),
        else => {},
    }
}

const RenameScope = struct {
    low: *Lowerer,
    // Innermost-last stack of (original-name -> fresh-name) maps; lookup walks outermost-from-inner.
    frames: std.ArrayList(std.StringHashMap([]const u8)) = .empty,
    counter: *usize,

    fn arena(self: *RenameScope) std.mem.Allocator {
        return self.low.arena;
    }
    fn push(self: *RenameScope) Error!void {
        try self.frames.append(self.arena(), std.StringHashMap([]const u8).init(self.arena()));
    }
    fn pop(self: *RenameScope) void {
        _ = self.frames.pop();
    }
    // Bind `orig` in the CURRENT (innermost) frame to a fresh unique name and return it.
    fn bind(self: *RenameScope, orig: []const u8) Error![]const u8 {
        const fresh = try std.fmt.allocPrint(self.arena(), "{s}__a{d}", .{ orig, self.counter.* });
        self.counter.* += 1;
        try self.frames.items[self.frames.items.len - 1].put(orig, fresh);
        return fresh;
    }
    // Resolve `name` to its fresh binding if any enclosing scope declared it; else null (a param /
    // global / fn / type — left untouched).
    fn lookup(self: *RenameScope, name: []const u8) ?[]const u8 {
        var i: usize = self.frames.items.len;
        while (i > 0) {
            i -= 1;
            if (self.frames.items[i].get(name)) |fresh| return fresh;
        }
        return null;
    }
};

// Alpha-rename a block in its own lexical scope (a new frame pushed/popped around its items).
fn renameBlock(rs: *RenameScope, b: ast.Block) Error!ast.Block {
    try rs.push();
    defer rs.pop();
    return renameBlockItems(rs, b);
}

// Rename a block's items WITHOUT pushing a frame (used for the fn body / a region whose frame the
// caller manages, e.g. so a loop's condition and body share the body decls' visibility correctly).
fn renameBlockItems(rs: *RenameScope, b: ast.Block) Error!ast.Block {
    var items: std.ArrayList(ast.Stmt) = .empty;
    for (b.items) |st| try items.append(rs.arena(), try renameStmt(rs, st));
    return .{ .span = b.span, .items = try items.toOwnedSlice(rs.arena()) };
}

fn renameStmt(rs: *RenameScope, s: ast.Stmt) Error!ast.Stmt {
    const arena = rs.arena();
    switch (s.kind) {
        .let_decl, .var_decl => |ld| {
            // The init is evaluated in the OUTER scope (the binding is not yet visible), so rename it
            // BEFORE binding the new name. Then bind each name to a fresh unique symbol.
            const new_init = if (ld.init) |e| try renameExpr(rs, e) else null;
            var new_names = try arena.alloc(ast.Ident, ld.names.len);
            for (ld.names, 0..) |nm, i| new_names[i] = .{ .text = try rs.bind(nm.text), .span = nm.span };
            const nl: ast.LocalDecl = .{ .names = new_names, .ty = ld.ty, .init = new_init };
            return .{ .span = s.span, .kind = if (s.kind == .let_decl) .{ .let_decl = nl } else .{ .var_decl = nl } };
        },
        .assignment => |a| return .{ .span = s.span, .kind = .{ .assignment = .{ .target = try renameExpr(rs, a.target), .value = try renameExpr(rs, a.value) } } },
        .expr => |e| return .{ .span = s.span, .kind = .{ .expr = try renameExpr(rs, e) } },
        .@"return" => |e| return .{ .span = s.span, .kind = .{ .@"return" = if (e) |x| try renameExpr(rs, x) else null } },
        .assert => |e| return .{ .span = s.span, .kind = .{ .assert = try renameExpr(rs, e) } },
        .@"defer" => |e| return .{ .span = s.span, .kind = .{ .@"defer" = try renameExpr(rs, e) } },
        .block => |b| return .{ .span = s.span, .kind = .{ .block = try renameBlock(rs, b) } },
        .unsafe_block => |b| return .{ .span = s.span, .kind = .{ .unsafe_block = try renameBlock(rs, b) } },
        .comptime_block => |b| return .{ .span = s.span, .kind = .{ .comptime_block = try renameBlock(rs, b) } },
        .loop => |l| {
            // `for`/`while`: the condition/iterable is evaluated in the loop's scope; the body shares
            // that scope (so the iterable can refer to nothing the body binds, but a `while` cond and
            // body live in one frame). Push one frame for the whole loop.
            try rs.push();
            defer rs.pop();
            const new_iter = if (l.iterable) |it| try renameExpr(rs, it) else null;
            const new_body = try renameBlockItems(rs, l.body);
            var nl = l;
            nl.iterable = new_iter;
            nl.body = new_body;
            return .{ .span = s.span, .kind = .{ .loop = nl } };
        },
        .@"switch" => |sw| {
            const rsubj = try renameExpr(rs, sw.subject);
            var new_arms = try arena.alloc(ast.SwitchArm, sw.arms.len);
            for (sw.arms, 0..) |arm, i| {
                // A switch arm's `.bind`/`.tag_bind` introduces an arm-local whose binding-ness is
                // TYPE-DEPENDENT (see the dup-check `.@"switch"` note): sema validates it. We do NOT
                // alpha-rename the pattern NAME — we leave it ORIGINAL and do NOT bind it in the arm
                // frame. Rationale (the earlier rename "fixed" a silent miscompile that ONLY arose on
                // INVALID shadowing input — a payload name colliding with a still-live captured/awaited
                // name — which MC's no-shadow rule now makes sema REJECT outright, so it never reaches
                // here): on VALID (non-shadowing) input the arm body's references resolve correctly
                // WITHOUT renaming. A payload `z` is in NO rename frame (the only same-named outer
                // binding lives in a DISJOINT, already-popped scope), so `renameExpr` leaves the read
                // bare `z` — reading the payload; an outer captured name referenced in the arm still
                // renames via its still-live frame entry; and the identifier rewriters' `shadowRemove`
                // (keyed on the original pattern name via `armBoundNames`) keeps the bare payload read
                // from being rewritten to `self.<field>`. We STILL rename a `.literal` pattern's expr
                // (it may reference an outer renamed binding). The frame is pushed for any arm-body
                // NESTED `let` to rename within.
                try rs.push();
                const new_pats = try renamePatterns(rs, arm.patterns);
                const new_body: ast.SwitchBody = switch (arm.body) {
                    .block => |b| .{ .block = try renameBlockItems(rs, b) },
                    .expr => |e| .{ .expr = try renameExpr(rs, e) },
                };
                rs.pop();
                new_arms[i] = .{ .patterns = new_pats, .body = new_body, .dup_local_if_binds = arm.dup_local_if_binds };
            }
            return .{ .span = s.span, .kind = .{ .@"switch" = .{ .subject = rsubj, .arms = new_arms } } };
        },
        // No identifiers to rebind / no locals introduced into the enclosing scope.
        .@"break", .@"continue" => return s,
        // Constructs the general path rejects when they bear an await; for await-free pass-through we
        // do not introduce bindings into the enclosing scope, so leaving them as-is is sound (their
        // own sub-scopes, if any, contain no captured-across-suspend locals).
        else => return s,
    }
}

// Rename a switch arm's patterns. A `.bind`/`.tag_bind` binding is LEFT ORIGINAL and NOT bound in the
// arm frame: on valid input the arm body's payload reads stay bare and resolve to the payload without
// renaming (a disjoint, already-popped same-named binding `lookup` misses; the identifier rewriters'
// `shadowRemove`, keyed on the ORIGINAL pattern name, keeps the bare read off `self.*`). We must NOT
// alias the pattern to a renamed outer here: that would push the renamed name into `armBoundNames`, so
// `shadowRemove` would then (wrongly) stop the body's renamed read from being rewritten to its
// `self.<field>` — turning a valid non-nullable catch-all's outer read into an E_UNKNOWN_IDENTIFIER.
// A STILL-LIVE outer collision is instead rejected PRE-RENAME by `validateNoDuplicateLocals` (it
// dup-checks a single-pattern `.tag_bind` payload — always binds — and a single-pattern `.bind` when the
// subject is a nullable param OR typed local — binds the unwrap), so the only miscompiling shapes never
// reach here. The one residual it cannot reach (a `.bind` over a nullable subject whose type isn't
// syntactically resolvable — an untyped/inferred local or a member/index/call expr — shadowing a live
// outer) stays masked — a bounded, type-info-only gap. `.literal` patterns hold an expr that may reference an
// outer renamed binding — rename it. `.wildcard`/`.tag` bind nothing.
fn renamePatterns(rs: *RenameScope, pats: []const ast.Pattern) Error![]ast.Pattern {
    const arena = rs.arena();
    var out = try arena.alloc(ast.Pattern, pats.len);
    for (pats, 0..) |p, i| {
        out[i] = switch (p.kind) {
            .bind, .tag_bind => p,
            .literal => |e| .{ .span = p.span, .kind = .{ .literal = try renameExpr(rs, e) } },
            else => p,
        };
    }
    return out;
}

fn renameExpr(rs: *RenameScope, e: ast.Expr) Error!ast.Expr {
    const arena = rs.arena();
    return switch (e.kind) {
        .ident => |i| if (rs.lookup(i.text)) |fresh| .{ .span = e.span, .kind = .{ .ident = .{ .text = fresh, .span = i.span } } } else e,
        .grouped => |inner| .{ .span = e.span, .kind = .{ .grouped = try ptr(arena, ast.Expr, try renameExpr(rs, inner.*)) } },
        .address_of => |inner| .{ .span = e.span, .kind = .{ .address_of = try ptr(arena, ast.Expr, try renameExpr(rs, inner.*)) } },
        .deref => |inner| .{ .span = e.span, .kind = .{ .deref = try ptr(arena, ast.Expr, try renameExpr(rs, inner.*)) } },
        .await_expr => |inner| .{ .span = e.span, .kind = .{ .await_expr = try ptr(arena, ast.Expr, try renameExpr(rs, inner.*)) } },
        .unary => |u| .{ .span = e.span, .kind = .{ .unary = .{ .op = u.op, .expr = try ptr(arena, ast.Expr, try renameExpr(rs, u.expr.*)) } } },
        .binary => |b| .{ .span = e.span, .kind = .{ .binary = .{ .op = b.op, .left = try ptr(arena, ast.Expr, try renameExpr(rs, b.left.*)), .right = try ptr(arena, ast.Expr, try renameExpr(rs, b.right.*)) } } },
        .cast => |c| .{ .span = e.span, .kind = .{ .cast = .{ .value = try ptr(arena, ast.Expr, try renameExpr(rs, c.value.*)), .ty = c.ty } } },
        .call => |c| blk: {
            var new_args = try arena.alloc(ast.Expr, c.args.len);
            for (c.args, 0..) |a, i| new_args[i] = try renameExpr(rs, a);
            // FINDING #2: a captured fn-pointer LOCAL used as a callee (`op(x,y)`) must be renamed too;
            // a direct/global function name (or an already-mangled `Owner.method`) is not in any rename
            // frame, so `renameExpr` on the ident leaves it unchanged — only a bound local is rewritten.
            const new_callee = try ptr(arena, ast.Expr, try renameExpr(rs, c.callee.*));
            break :blk .{ .span = e.span, .kind = .{ .call = .{ .callee = new_callee, .type_args = c.type_args, .args = new_args } } };
        },
        .index => |ix| .{ .span = e.span, .kind = .{ .index = .{ .base = try ptr(arena, ast.Expr, try renameExpr(rs, ix.base.*)), .index = try ptr(arena, ast.Expr, try renameExpr(rs, ix.index.*)) } } },
        .slice => |sl| .{ .span = e.span, .kind = .{ .slice = .{ .base = try ptr(arena, ast.Expr, try renameExpr(rs, sl.base.*)), .start = try ptr(arena, ast.Expr, try renameExpr(rs, sl.start.*)), .end = try ptr(arena, ast.Expr, try renameExpr(rs, sl.end.*)) } } },
        .member => |m| .{ .span = e.span, .kind = .{ .member = .{ .base = try ptr(arena, ast.Expr, try renameExpr(rs, m.base.*)), .name = m.name } } },
        .try_expr => |t| .{ .span = e.span, .kind = .{ .try_expr = .{ .operand = try ptr(arena, ast.Expr, try renameExpr(rs, t.operand.*)), .mapped = if (t.mapped) |mp| try ptr(arena, ast.Expr, try renameExpr(rs, mp.*)) else null } } },
        .array_literal => |els| blk: {
            var new_els = try arena.alloc(ast.Expr, els.len);
            for (els, 0..) |x, i| new_els[i] = try renameExpr(rs, x);
            break :blk .{ .span = e.span, .kind = .{ .array_literal = new_els } };
        },
        .struct_literal => |flds| blk: {
            var new_flds = try arena.alloc(ast.StructLiteralField, flds.len);
            for (flds, 0..) |f, i| new_flds[i] = .{ .name = f.name, .value = try renameExpr(rs, f.value) };
            break :blk .{ .span = e.span, .kind = .{ .struct_literal = new_flds } };
        },
        // Literals, enum literals, void/null/uninit/unreachable, nested `block`/`if_let` exprs the
        // general path does not admit with awaits — no captured-local identifier to rebind here.
        else => e,
    };
}

// Collect EVERY local declaration (name + type) declared ANYWHERE in `b` (top-level or nested), in
// source order, into `out`. After the alpha-rename every name is unique, so each becomes its own
// captured field. A decl without an explicit type is reported (the field needs a type); the caller
// turns a missing type into a precise diagnostic. Awaited bindings (`let x = await e;`) are EXCLUDED
// here — they are captured from the await steps (their type is the awaited future's result type).
const LocalCapture = struct { name: ast.Ident, ty: ?ast.TypeExpr, span: diagnostics.Span };
fn collectAllLocalDecls(low: *Lowerer, b: ast.Block, out: *std.ArrayList(LocalCapture)) Error!void {
    const arena = low.arena;
    for (b.items) |s| {
        switch (s.kind) {
            .let_decl, .var_decl => |ld| {
                if (awaitStepCall(s) != null) continue; // awaited binding: captured from its step
                // A multi-name decl (`let a, b = ...`) is not lifted to a field store soundly by the
                // single-name decl->store path; reject it here with a precise span (rare; the prior
                // top-level-only path rejected it too).
                if (ld.names.len != 1) return low.fail(s.span, "E_ASYNC_GENERAL_UNSUPPORTED: a `let`/`var` live across the await regions must bind exactly one name in async E3c", .{});
                try out.append(arena, .{ .name = ld.names[0], .ty = ld.ty, .span = s.span });
            },
            .loop => |l| try collectAllLocalDecls(low, l.body, out),
            .block, .unsafe_block, .comptime_block => |bl| try collectAllLocalDecls(low, bl, out),
            .@"switch" => |sw| for (sw.arms) |arm| switch (arm.body) {
                .block => |bl| try collectAllLocalDecls(low, bl, out),
                .expr => {},
            },
            else => {},
        }
    }
}

// The general lowering context: a growing single `while true` dispatch built as a list of finalized
// state blocks plus the "current" block being accumulated. `newState`/`gotoState`/`finishCur`/
// `startState` are the basic-block-builder primitives; `emitAwaitState` records each await poll-state
// for the struct fields + cancel guards.
const GenCtx = struct {
    low: *Lowerer,
    names: *std.StringHashMap(void),
    done_str: []const u8,
    states: std.ArrayList(GenState) = .empty, // finalized state blocks
    cur: std.ArrayList(ast.Stmt) = .empty, // the block being accumulated
    cur_state: usize = 0,
    counter: usize = 1, // 0 is the entry state; next fresh state is 1
    awaits: std.ArrayList(GenAwait) = .empty, // (state, step) for fields + cancel

    const GenState = struct { num: usize, items: []ast.Stmt };
    const GenAwait = struct { state: usize, step: AwaitStep };

    fn arena(self: *GenCtx) std.mem.Allocator {
        return self.low.arena;
    }
    fn newState(self: *GenCtx) usize {
        const n = self.counter;
        self.counter += 1;
        return n;
    }
    // Append `self.state = n; continue;` (the edge terminator) to the current block.
    fn gotoState(self: *GenCtx, n: usize) Error!void {
        try setState(self.low, &self.cur, n);
        try self.cur.append(self.arena(), .{ .span = zspan, .kind = .@"continue" });
    }
    // Finalize the current block under its state number.
    fn finishCur(self: *GenCtx) Error!void {
        try self.states.append(self.arena(), .{ .num = self.cur_state, .items = try self.cur.toOwnedSlice(self.arena()) });
        self.cur = .empty;
    }
    fn startState(self: *GenCtx, n: usize) void {
        self.cur_state = n;
        self.cur = .empty;
    }
};

fn lowerAsyncGeneralFn(
    low: *Lowerer,
    out: *std.ArrayList(ast.Decl),
    decl: ast.Decl,
    info: AsyncInfo,
    fut_type: []const u8,
    result_type: ast.TypeExpr,
    body_in: ast.Block,
) Error!void {
    const arena = low.arena;
    const fd = decl.kind.fn_decl;

    // Findings #1+#2: alpha-rename every local in the body to a globally-unique name FIRST. This makes
    // it sound to capture EVERY local — including ones declared inside nested regions (`if`/`while`
    // blocks) and ones whose source name is reused across disjoint scopes — as a uniquely-named
    // `self.*` field, with the existing name-keyed rewrite. Params are not renamed.
    var rename_counter: usize = 0;
    var rs = RenameScope{ .low = low, .counter = &rename_counter };
    try rs.push(); // the fn body's top scope (params live one level up, conceptually — not renamed)
    const body = try renameBlockItems(&rs, body_in);
    rs.pop();

    // FINDING #3: the alpha-rename changed local names, so re-record typed-local carriers under their
    // POST-rename names (the pre-rename scan in lowerAsyncFn keyed the original names). This lets
    // `await ctx.fut` resolve when `ctx` is a typed local that the general path renamed.
    try recordLocalCarrierTypes(low, body);

    // Captured names: params + every awaited binding (anywhere) + every (now-unique) local declared
    // ANYWHERE (top-level OR nested — the index/accumulators AND nested temporaries live across the
    // regions). They become `self.*` fields; reads rewrite to self.*.
    var field_names = std.StringHashMap(void).init(arena);
    for (fd.params) |p| try field_names.put(p.name.text, {});
    try collectAwaitBindingNames(body, &field_names);
    var local_caps: std.ArrayList(LocalCapture) = .empty;
    try collectAllLocalDecls(low, body, &local_caps);
    for (local_caps.items) |lc| try field_names.put(lc.name.text, {});
    const names = &field_names;

    var ctx = GenCtx{ .low = low, .names = names, .done_str = "" };

    // DONE is a FIXED state allocated FIRST (so `return`/fall-off can reference it during lowering);
    // the body's states are allocated after it. State 0 is the entry. The numeric value of DONE thus
    // does not depend on body size — it is always state 1 — which keeps every `return`/fall-off edge
    // well-formed in a single lowering pass.
    const done_state = ctx.newState(); // == 1
    const done_str = try std.fmt.allocPrint(arena, "{d}", .{done_state});
    ctx.done_str = done_str;

    // Lower the whole body in one pass. The body's final fall-off (if reachable) jumps to DONE; a fn
    // that never returns is rejected by the return checker later (an async fn must `return`). brk/cont
    // are null at the top level (a break/continue outside any loop is a parse/sema error upstream).
    ctx.startState(0);
    try lowerStmtsGen(&ctx, body.items, done_state, null, null);
    try ctx.finishCur(); // finalize the last open block (its terminator is its own goto/return)

    // ---- Build the future struct: state + one __cN per await (in state order) + params + top-level
    // locals + awaited bindings + result. ----
    var fields: std.ArrayList(ast.Field) = .empty;
    try fields.append(arena, .{ .name = id("state"), .ty = try nameType(arena, "u8") });
    var child_arms: std.ArrayList(ast.Field) = .empty;
    for (ctx.awaits.items) |ga| {
        try child_arms.append(arena, .{ .name = id(ga.step.child_field), .ty = try nameType(arena, ga.step.fut_type) });
    }
    try appendChildUnionField(arena, out, &fields, fut_type, child_arms.items);
    for (fd.params) |p| try fields.append(arena, .{ .name = p.name, .ty = p.ty });
    // EVERY local (top-level OR nested, now uniquely renamed) -> a captured field; each lives across
    // the regions as a `self.*` field (its source-level scope is enforced by where its init store and
    // reads are emitted, not by the field's existence). Require an explicit type annotation (same
    // contract as the pre-loop/pre-branch locals in the fast paths) — the field needs a type pre-sema.
    for (local_caps.items) |lc| {
        const lty = lc.ty orelse return low.fail(lc.span, "E_ASYNC_GENERAL_UNSUPPORTED: a `let`/`var` live across the await regions needs an explicit type annotation in async E3c", .{});
        try fields.append(arena, .{ .name = lc.name, .ty = lty });
    }
    // Awaited-binding fields (in state/await order; each unique).
    for (ctx.awaits.items) |ga| if (ga.step.binding) |nm| try fields.append(arena, .{ .name = id(nm), .ty = ga.step.result_type });
    try fields.append(arena, .{ .name = id("result"), .ty = result_type });
    try out.append(arena, .{ .span = zspan, .attrs = &.{}, .kind = .{ .struct_decl = .{
        .name = id(fut_type),
        .abi = null,
        .fields = try fields.toOwnedSlice(arena),
    } } });

    // ---- Constructor: zero state, copy params, replay top-level straight-line decls as stores, zero
    // scalar fields. Build NO child eagerly (every child is built on its entry edge in `poll`). ----
    var cbody: std.ArrayList(ast.Stmt) = .empty;
    try cbody.append(arena, .{ .span = zspan, .kind = .{ .var_decl = .{
        .names = try dupIdents(arena, &.{"self"}),
        .ty = try nameType(arena, fut_type),
        .init = .{ .span = zspan, .kind = .uninit_literal },
    } } });
    try cbody.append(arena, assignStmt(try selfMember(arena, "state"), intExpr("0")));
    for (fd.params) |p| try cbody.append(arena, assignStmt(try selfMember(arena, p.name.text), identExpr(p.name.text)));
    // Zero every scalar local field for definite-init (the move/borrow checker needs every field
    // initialized before `return self`). Each local's REAL init (`self.x = init;`) runs in the
    // poll-state where its declaration executes — which always runs before any state that reads it
    // (a local is read only after its own declaration) — emitted by `genRewriteStraight` converting
    // the decl to a store. So the zero-init is a sound definite-init placeholder, never observed.
    for (local_caps.items) |lc| {
        if (lc.ty) |lty| try appendZeroInit(low, &cbody, lc.name.text, lty);
    }
    // Zero the scalar awaited-binding fields + result (definite-init).
    for (ctx.awaits.items) |ga| if (ga.step.binding) |b| try appendZeroInit(low, &cbody, b, ga.step.result_type);
    try appendZeroInit(low, &cbody, "result", result_type);
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

    // ---- The poll method: `while true { if state==DONE return true; <state blocks, sorted> } return
    // false;`. State blocks are emitted in numeric order; each is `if self.state==N { ... }`. ----
    var inner: std.ArrayList(ast.Stmt) = .empty;
    {
        var dbody = try arena.alloc(ast.Stmt, 1);
        dbody[0] = .{ .span = zspan, .kind = .{ .@"return" = .{ .span = zspan, .kind = .{ .bool_literal = true } } } };
        try inner.append(arena, try ifStateEq(arena, done_state, dbody));
    }
    // Emit states in ascending numeric order (deterministic output, stable across backends).
    std.mem.sort(GenCtx.GenState, ctx.states.items, {}, struct {
        fn lt(_: void, a: GenCtx.GenState, b: GenCtx.GenState) bool {
            return a.num < b.num;
        }
    }.lt);
    for (ctx.states.items) |st| {
        try inner.append(arena, try ifStateEq(arena, st.num, st.items));
    }
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

    // `impl Future for f__Fut` (poll + cancel).
    var conf_methods = try arena.alloc(ast.ImplTraitMethod, 2);
    conf_methods[0] = .{
        .name = id("poll"),
        .mangled = poll_method_name,
        .self_mode = .by_mut_ptr,
        .params = poll_params,
        .return_type = try nameType(arena, "bool"),
    };
    conf_methods[1] = try cancelConfMethod(low, info, fut_type);
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

    // `fn f__Fut_cancel(self) -> void`: one guard per await poll-state (each holds its own __cN while
    // pending; at-most-one is live), then mark DONE (idempotent).
    var cn_params = try arena.alloc(ast.Param, 1);
    cn_params[0] = .{ .name = id("self"), .ty = try mutPtrType(arena, try nameType(arena, fut_type)) };
    var cn_body: std.ArrayList(ast.Stmt) = .empty;
    for (ctx.awaits.items) |ga| try emitCancelGuard(low, &cn_body, ga.step, ga.state);
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

// Collect every awaited binding name (`let x = await e;`) anywhere in `b` (top-level or nested) into
// `set` — they all become captured `self.*` fields (live across their suspend).
fn collectAwaitBindingNames(b: ast.Block, set: *std.StringHashMap(void)) Error!void {
    for (b.items) |s| {
        if (awaitStepCall(s) != null) {
            const ld = s.kind.let_decl;
            try set.put(ld.names[0].text, {});
        }
        switch (s.kind) {
            .loop => |l| try collectAwaitBindingNames(l.body, set),
            .@"switch" => |sw| for (sw.arms) |arm| switch (arm.body) {
                .block => |bl| try collectAwaitBindingNames(bl, set),
                .expr => {},
            },
            .block, .unsafe_block, .comptime_block => |bl| try collectAwaitBindingNames(bl, set),
            else => {},
        }
    }
}

// Lower a statement sequence into `ctx`, such that control falls off the end to `succ` (or, if `succ`
// is null, the body's final fall-off — only the top-level uses non-null `succ`). `brk`/`cont` are the
// enclosing async-loop's exit/head state numbers (null outside a loop). Each await/await-bearing
// construct CUTS the current block into new states; straight-line code accumulates into `ctx.cur`.
fn lowerStmtsGen(ctx: *GenCtx, items: []const ast.Stmt, succ: ?usize, brk: ?usize, cont: ?usize) Error!void {
    const low = ctx.low;
    const arena = ctx.arena();
    for (items) |s| {
        if (!stmtContainsAwait(s)) {
            // Straight-line (possibly with await-free inner control flow). Rewrite return->DONE,
            // break/continue->edges; recurse through inner await-free control flow.
            const rs = try genRewriteStraight(ctx, s, brk, cont);
            try ctx.cur.append(arena, rs);
            if (isUnconditionalTerminator(s)) return; // dead code after a terminator
            continue;
        }
        // `s` contains an await.
        if (awaitStepCall(s)) |acall| {
            // `let x = await E;` — build the child on the current edge, jump to a fresh poll-state.
            const step = try buildAwaitStep(low, s, acall, ctx.awaits.items.len);
            const a = ctx.newState();
            try emitBuildChild(low, &ctx.cur, step, ctx.names);
            try ctx.gotoState(a);
            try ctx.finishCur();
            try ctx.awaits.append(arena, .{ .state = a, .step = step });
            ctx.startState(a);
            try emitPollAndTake(low, &ctx.cur, step, ctx.done_str);
            continue; // subsequent items accumulate into state `a`
        }
        if (asBoolIf(s)) |bi| {
            // An await-bearing bool-if: dispatch in the current state to each arm's entry trampoline,
            // both converging on a fresh JOIN state. (A bool-if with no awaits was handled above as
            // straight-line.)
            const join = ctx.newState();
            const t_entry = ctx.newState();
            const f_entry = ctx.newState();
            const rcond = try rewriteParamRefs(low, bi.cond, ctx.names);
            var tb: std.ArrayList(ast.Stmt) = .empty;
            try setState(low, &tb, t_entry);
            try tb.append(arena, .{ .span = zspan, .kind = .@"continue" });
            var eb: std.ArrayList(ast.Stmt) = .empty;
            try setState(low, &eb, f_entry);
            try eb.append(arena, .{ .span = zspan, .kind = .@"continue" });
            try ctx.cur.append(arena, try ifElseBlock(arena, rcond, try tb.toOwnedSlice(arena), try eb.toOwnedSlice(arena)));
            try ctx.finishCur();
            // then arm
            ctx.startState(t_entry);
            try lowerStmtsGen(ctx, bi.then_blk.items, join, brk, cont);
            try ctx.gotoState(join);
            try ctx.finishCur();
            // else arm
            ctx.startState(f_entry);
            try lowerStmtsGen(ctx, bi.else_blk.items, join, brk, cont);
            try ctx.gotoState(join);
            try ctx.finishCur();
            // continue the outer sequence in the join state
            ctx.startState(join);
            continue;
        }
        if (s.kind == .loop and s.kind.loop.kind == .@"while") {
            const loop = s.kind.loop;
            const lcond = loop.iterable orelse return low.fail(s.span, "E_ASYNC_GENERAL_UNSUPPORTED: a `while` loop must have a condition in async E3c", .{});
            const head = ctx.newState();
            const body_entry = ctx.newState();
            const exit = ctx.newState();
            // edge into the head
            try ctx.gotoState(head);
            try ctx.finishCur();
            // head: if cond { goto body_entry } else { goto exit }
            ctx.startState(head);
            {
                const rcond = try rewriteParamRefs(low, lcond, ctx.names);
                var tb: std.ArrayList(ast.Stmt) = .empty;
                try setState(low, &tb, body_entry);
                try tb.append(arena, .{ .span = zspan, .kind = .@"continue" });
                var eb: std.ArrayList(ast.Stmt) = .empty;
                try setState(low, &eb, exit);
                try eb.append(arena, .{ .span = zspan, .kind = .@"continue" });
                try ctx.cur.append(arena, try ifElseBlock(arena, rcond, try tb.toOwnedSlice(arena), try eb.toOwnedSlice(arena)));
                try ctx.finishCur();
            }
            // body: lower with succ=head (back-edge), brk=exit, cont=head.
            ctx.startState(body_entry);
            try lowerStmtsGen(ctx, loop.body.items, head, exit, head);
            try ctx.gotoState(head); // fall off the body -> back-edge to head
            try ctx.finishCur();
            // continue the outer sequence at the exit state
            ctx.startState(exit);
            continue;
        }
        // Any other await-bearing construct (await in `if_let`, `for`, `contract_block`, …) is beyond
        // E3c — reject with a clear code rather than mislower.
        return low.fail(s.span, "E_ASYNC_GENERAL_UNSUPPORTED: this await-bearing construct is unsupported in async E3c (supported: `let x = await e;`, bool `if`/`else`, and `while` loops, arbitrarily nested/sequenced)", .{});
    }
    // Fell off the end of the sequence: jump to the successor (or DONE for the top-level body).
    if (succ) |sx| {
        try ctx.gotoState(sx);
    }
}

// Is this stmt an UNCONDITIONAL terminator (return/break/continue at the top level of a block)? Code
// after it is dead, so we stop accumulating the current block (it already ends in a goto/return).
fn isUnconditionalTerminator(s: ast.Stmt) bool {
    return switch (s.kind) {
        .@"return", .@"break", .@"continue" => true,
        else => false,
    };
}

// Rewrite a STRAIGHT-LINE (await-free) statement for emission into a poll-state, mapping the async
// fn's control edges to state transitions:
//   `return v`  -> `self.result = v; self.state = DONE; return true;`
//   `break`     -> `self.state = brk; continue;`   (the enclosing async loop's exit state)
//   `continue`  -> `self.state = cont; continue;`  (the enclosing async loop's head state)
// recursing THROUGH await-free inner control flow (a plain `if`/`switch`/`block`), and leaving an
// INNER await-free loop's own break/continue to that loop. Captured-name reads rewrite to `self.*`.
fn genRewriteStraight(ctx: *GenCtx, s: ast.Stmt, brk: ?usize, cont: ?usize) Error!ast.Stmt {
    const low = ctx.low;
    const arena = ctx.arena();
    switch (s.kind) {
        // A `let/var x = init;` that binds a CAPTURED field (a top-level accumulator/index) is NOT a
        // poll-machine local — `x` is `self.x`. Lift it to a store `self.x = init;` (so the emitted C
        // has no unused local and the field — not a fresh local — carries the value across states). A
        // decl whose name is NOT captured (a region-local not live across a suspend) stays a local.
        .let_decl, .var_decl => |ld| {
            if (ld.names.len == 1 and ctx.names.contains(ld.names[0].text)) {
                return rewriteDeclToStore(low, s, ctx.names);
            }
            return rewriteStmtParamRefs(low, s, ctx.names);
        },
        .@"return" => return rewriteRegionStmt(low, s, ctx.names, ctx.done_str),
        .@"break" => {
            const b = brk orelse return low.fail(s.span, "E_ASYNC_GENERAL_UNSUPPORTED: `break` outside an await-bearing loop in async E3c", .{});
            var bb: std.ArrayList(ast.Stmt) = .empty;
            try setState(low, &bb, b);
            try bb.append(arena, .{ .span = s.span, .kind = .@"continue" });
            return .{ .span = s.span, .kind = .{ .block = .{ .span = s.span, .items = try bb.toOwnedSlice(arena) } } };
        },
        .@"continue" => {
            const c = cont orelse return low.fail(s.span, "E_ASYNC_GENERAL_UNSUPPORTED: `continue` outside an await-bearing loop in async E3c", .{});
            var cb: std.ArrayList(ast.Stmt) = .empty;
            try setState(low, &cb, c);
            try cb.append(arena, .{ .span = s.span, .kind = .@"continue" });
            return .{ .span = s.span, .kind = .{ .block = .{ .span = s.span, .items = try cb.toOwnedSlice(arena) } } };
        },
        .block => |b| return .{ .span = s.span, .kind = .{ .block = try genRewriteStraightBlock(ctx, b, brk, cont) } },
        .unsafe_block => |b| return .{ .span = s.span, .kind = .{ .unsafe_block = try genRewriteStraightBlock(ctx, b, brk, cont) } },
        .loop => |l| {
            // An INNER await-free loop: its own break/continue belong to IT, not the async loop, so
            // pass `brk`/`cont` as null inside. A `return` inside still exits the whole fn (-> DONE).
            const new_iter = if (l.iterable) |it| try rewriteParamRefs(low, it, ctx.names) else null;
            const new_body = try genRewriteStraightBlock(ctx, l.body, null, null);
            var nl = l;
            nl.iterable = new_iter;
            nl.body = new_body;
            return .{ .span = s.span, .kind = .{ .loop = nl } };
        },
        .@"switch" => |sw| {
            const rsubj = try rewriteParamRefs(low, sw.subject, ctx.names);
            var new_arms = try arena.alloc(ast.SwitchArm, sw.arms.len);
            for (sw.arms, 0..) |arm, i| {
                // FINDING #1: shadow the arm's pattern-bound names so their uses inside the arm are
                // NOT rewritten to `self.*` (they read the arm-local payload, not a captured field).
                const bound = try armBoundNames(arena, arm);
                var removed: std.ArrayList([]const u8) = .empty;
                try shadowRemove(ctx.names, bound, &removed, arena);
                const new_body: ast.SwitchBody = switch (arm.body) {
                    .block => |b| .{ .block = try genRewriteStraightBlock(ctx, b, brk, cont) },
                    .expr => |e| .{ .expr = try rewriteParamRefs(low, e, ctx.names) },
                };
                try shadowRestore(ctx.names, removed.items);
                new_arms[i] = .{ .patterns = arm.patterns, .body = new_body, .dup_local_if_binds = arm.dup_local_if_binds };
            }
            return .{ .span = s.span, .kind = .{ .@"switch" = .{ .subject = rsubj, .arms = new_arms } } };
        },
        else => return rewriteStmtParamRefs(low, s, ctx.names),
    }
}

fn genRewriteStraightBlock(ctx: *GenCtx, b: ast.Block, brk: ?usize, cont: ?usize) Error!ast.Block {
    var items: std.ArrayList(ast.Stmt) = .empty;
    for (b.items) |st| try items.append(ctx.arena(), try genRewriteStraight(ctx, st, brk, cont));
    return .{ .span = b.span, .items = try items.toOwnedSlice(ctx.arena()) };
}

// E1: build the `cancel` entry of a generated future's `impl Future` record. It points the vtable
// `cancel` slot at the generated free fn `f__Fut_cancel` (`info.cancel`), emitted separately by the
// straight-line / loop lowering. Signature mirrors that free fn: `fn cancel(self: *mut f__Fut) ->
// void`. A vtable slot may name any existing fn symbol (the `poll` slot already names the mangled
// `f__Fut__poll`), so the generated future satisfies the `Future` trait without a second fn body.
fn cancelConfMethod(low: *Lowerer, info: AsyncInfo, fut_type: []const u8) Error!ast.ImplTraitMethod {
    const arena = low.arena;
    var cancel_params = try arena.alloc(ast.Param, 1);
    cancel_params[0] = .{ .name = id("self"), .ty = try mutPtrType(arena, try nameType(arena, fut_type)) };
    return .{
        .name = id("cancel"),
        .mangled = info.cancel,
        .self_mode = .by_mut_ptr,
        .params = cancel_params,
        .return_type = try nameType(arena, "void"),
    };
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
        // E3a/E3b: `return` / `break` / `continue` inside an await-bearing loop body ARE now
        // supported — lowered by rewriteLoopBodyStmt to a DONE / loop-exit / loop-head transition
        // (a `break`/`continue` is typically written nested in an `if`, which already flows through
        // here as a switch and is rewritten recursively). Still reject any await beyond the leading
        // run (E3c: awaits nested in inner control flow).
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

// E2: the bare type name a future-valued expression denotes, resolved SYNTACTICALLY (no sema), or
// null if not resolvable. Handles the await-expr forms E2 supports:
//   - `g(args)` (ident callee) / `Owner.method(args)` (parser already mangled to an ident call):
//       the callee's declared return-type name (a future struct).
//   - `(e)` grouped / nested parens: the inner expr's future type.
//   - `base.field`: `base`'s struct type's `field` type — a CONCRETE future struct.
//   - `base[i]`: `base`'s array-element type (recorded as the field's type in the struct-field map).
// A field/index `base` must itself resolve to a struct type (a param, or a chain of fields).
fn futureTypeOf(low: *Lowerer, e: ast.Expr) ?[]const u8 {
    return switch (e.kind) {
        .call => |c| switch (c.callee.*.kind) {
            .ident => |i| low.fn_ret_type.get(i.text),
            else => null,
        },
        .grouped => |inner| futureTypeOf(low, inner.*),
        .member => |m| blk: {
            const base_ty = structTypeOf(low, m.base.*) orelse break :blk null;
            const fm = low.struct_fields.get(base_ty) orelse break :blk null;
            break :blk fm.get(m.name.text);
        },
        .index => |ix| structTypeOf(low, ix.base.*), // base array's element type (stored as the field type)
        else => null,
    };
}

// E2: the bare STRUCT type name an lvalue-ish expr denotes (for resolving a field/index await's
// base), or null. A bare param uses `param_types`; a nested `base.field` / `base[i]` looks the
// field/element type up in the struct-field map (must itself be a struct/array carrier).
fn structTypeOf(low: *Lowerer, e: ast.Expr) ?[]const u8 {
    return switch (e.kind) {
        .ident => |i| low.param_types.get(i.text),
        .grouped => |inner| structTypeOf(low, inner.*),
        .member => |m| blk: {
            const base_ty = structTypeOf(low, m.base.*) orelse break :blk null;
            const fm = low.struct_fields.get(base_ty) orelse break :blk null;
            break :blk fm.get(m.name.text);
        },
        .index => |ix| structTypeOf(low, ix.base.*),
        else => null,
    };
}

// Resolve `await e` (E2: `e` is any future-valued expression) to its child future type +
// take_result accessor + cancel + result type, using only syntactic maps (no sema). For an async
// callee, use its generated ABI (which carries the result type); for any other concrete future
// type the result type is unknown here and the caller falls back to the binding's `: T` annotation.
fn resolveAwait(low: *Lowerer, span: diagnostics.Span, e: ast.Expr) Error!ResolvedChild {
    // A plain async-fn call carries its result type directly from the generated ABI.
    if (e.kind == .call) {
        if (e.kind.call.callee.*.kind == .ident) {
            const cname = e.kind.call.callee.*.kind.ident.text;
            if (low.async_info.get(cname)) |ai| {
                return .{ .fut_type = ai.fut_type, .take_result = ai.take_result, .cancel = ai.cancel, .result_type = ai.result_type };
            }
        }
    }
    const fut_type = futureTypeOf(low, e) orelse return low.fail(span, "E_ASYNC_AWAIT_UNRESOLVED: `await e` requires `e`'s future type be resolvable without sema — a call `g(args)`/`Owner.m(args)`, a parenthesized such expr, a struct-FIELD future `base.fut`, or an array element `arr[i]` (base a param/field of a known struct/array-of-future type); `*dyn Future` await and other expression shapes are deferred (Phase E)", .{});
    const take = try std.fmt.allocPrint(low.arena, "{s}_take_result", .{fut_type});
    const cancel = try std.fmt.allocPrint(low.arena, "{s}_cancel", .{fut_type});
    // The result type is unknown here; callers fall back to the binding's `: T` annotation.
    // Use a placeholder; an await without a `: T` annotation is rejected at the call site.
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
    // `let x = (await c)?;` — the awaited value is a `Result`; `?` propagates its `err` up the async
    // fn (which must itself return a `Result`) and binds the `ok` value to `x` (of type `res_ty`).
    var is_try = false;
    var try_mapped: ?ast.Expr = null;
    if (ld.init) |ie| {
        if (ie.kind == .try_expr and unwrapToAwaitCall(ie.kind.try_expr.operand.*) != null) {
            is_try = true;
            if (ie.kind.try_expr.mapped) |m| try_mapped = m.*;
        }
    }
    return .{
        .binding = ld.names[0].text,
        .binding_type = ld.ty,
        .child_field = field,
        .fut_type = child.fut_type,
        .take_result = child.take_result,
        .cancel = child.cancel,
        .call = acall,
        .result_type = res_ty,
        .is_try = is_try,
        .try_mapped = try_mapped,
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
        // E3a: a `return` inside an await-bearing arm IS now supported (lowered to the DONE
        // transition by rewriteRegionStmt). Still reject any await beyond the leading run.
        if (stmtContainsAwait(stmt))
            return low.fail(stmt.span, "E_ASYNC_BRANCH_UNSUPPORTED: in async v0 an if/else arm may contain only a LEADING run of `let x = await call;` then straight-line code (no awaits nested in loops, switches, or deeper control flow)", .{});
        try tail.append(arena, stmt);
    }
}

// `self.__u.__cN` — access the active child future through the addressable child-union.
// The N child futures share ONE union slot (only the current `state`'s child is live), so the
// Future struct is sized to the LARGEST child instead of their sum (§3.5). Union member access is
// alias-safe on both backends (real C `union` / offset-0 storage; see ast.StructDecl.is_c_union),
// and `&self.__u.__cN` is a stable, in-place pointer — exactly what poll/take/cancel need across
// suspensions.
fn selfChild(arena: std.mem.Allocator, child_field: []const u8) Error!ast.Expr {
    return memberExpr(arena, try selfMember(arena, "__u"), child_field);
}

// Build the `#[c_union]` child-storage struct `<FutName>__U` (one arm per await child) and append
// ONE `__u` field of it to the Future's `fields`, in place of N separate `__cN` fields. The union
// decl is emitted into `out`. No-op when there are no children (a pure async fn with no awaits).
fn appendChildUnionField(
    arena: std.mem.Allocator,
    out: *std.ArrayList(ast.Decl),
    fields: *std.ArrayList(ast.Field),
    fut_type: []const u8,
    arms: []const ast.Field,
) Error!void {
    if (arms.len == 0) return;
    const union_name = try std.fmt.allocPrint(arena, "{s}__U", .{fut_type});
    try out.append(arena, .{ .span = zspan, .attrs = &.{}, .kind = .{ .struct_decl = .{
        .name = id(union_name),
        .abi = null,
        .fields = try arena.dupe(ast.Field, arms),
        .is_c_union = true,
    } } });
    try fields.append(arena, .{ .name = id("__u"), .ty = try nameType(arena, union_name) });
}

// Emit the suspend-or-take prologue of an await step into `blk`:
//   let r: bool = FutT__poll(&self.__cN);  if !r { return false; }
//   self.<binding> = FutT_take_result(&self.__cN);   (or drop the result if no binding)
// For a TRY step (`let x = (await c)?;`) the awaited value is a `Result`; instead of a plain
// assignment, match it: `ok(v)` binds `v` to the binding, `err(e)` propagates by completing the
// future with that error (`self.result = err(e); self.state = done; return true;`). `done_str` is
// the DONE-state index; the enclosing async fn must itself return a `Result` (sema enforces it).
fn emitPollAndTake(low: *Lowerer, blk: *std.ArrayList(ast.Stmt), s: AwaitStep, done_str: []const u8) Error!void {
    const arena = low.arena;
    const poll_fn = try std.fmt.allocPrint(arena, "{s}__poll", .{s.fut_type});
    var poll_args = try arena.alloc(ast.Expr, 1);
    poll_args[0] = try addrOf(arena, try selfChild(arena, s.child_field));
    try blk.append(arena, .{ .span = zspan, .kind = .{ .let_decl = .{
        .names = try dupIdents(arena, &.{"r"}),
        .ty = try nameType(arena, "bool"),
        .init = try callExpr(arena, poll_fn, poll_args),
    } } });
    try blk.append(arena, try ifNotReturnFalse(arena));
    var take_args = try arena.alloc(ast.Expr, 1);
    take_args[0] = try addrOf(arena, try selfChild(arena, s.child_field));
    const take_call = try callExpr(arena, s.take_result, take_args);

    if (s.is_try) {
        if (s.try_mapped != null) return low.fail(zspan, "async v0: `(await e)? else MAPPED` (error remap) is not supported in try-await; use plain `?`", .{});
        // let __try = FutT_take_result(&self.__cN);   (a Result<U, E>; type inferred)
        try blk.append(arena, .{ .span = zspan, .kind = .{ .let_decl = .{
            .names = try dupIdents(arena, &.{"__try"}),
            .ty = null,
            .init = take_call,
        } } });
        // ok(__v) => { self.<binding> = __v; }
        var ok_body: std.ArrayList(ast.Stmt) = .empty;
        if (s.binding) |b| try ok_body.append(arena, assignStmt(try selfMember(arena, b), identExpr("__v")));
        var ok_pats = try arena.alloc(ast.Pattern, 1);
        ok_pats[0] = .{ .span = zspan, .kind = .{ .tag_bind = .{ .tag = id("ok"), .binding = id("__v") } } };
        // err(__e) => { self.result = err(__e); self.state = done; return true; }
        var err_body: std.ArrayList(ast.Stmt) = .empty;
        var err_args = try arena.alloc(ast.Expr, 1);
        err_args[0] = identExpr("__e");
        try err_body.append(arena, assignStmt(try selfMember(arena, "result"), try callExpr(arena, "err", err_args)));
        try err_body.append(arena, assignStmt(try selfMember(arena, "state"), intExpr(done_str)));
        try err_body.append(arena, .{ .span = zspan, .kind = .{ .@"return" = .{ .span = zspan, .kind = .{ .bool_literal = true } } } });
        var err_pats = try arena.alloc(ast.Pattern, 1);
        err_pats[0] = .{ .span = zspan, .kind = .{ .tag_bind = .{ .tag = id("err"), .binding = id("__e") } } };
        var arms = try arena.alloc(ast.SwitchArm, 2);
        arms[0] = .{ .patterns = ok_pats, .body = .{ .block = .{ .span = zspan, .items = try ok_body.toOwnedSlice(arena) } } };
        arms[1] = .{ .patterns = err_pats, .body = .{ .block = .{ .span = zspan, .items = try err_body.toOwnedSlice(arena) } } };
        try blk.append(arena, .{ .span = zspan, .kind = .{ .@"switch" = .{ .subject = identExpr("__try"), .arms = arms } } });
        return;
    }

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
    try blk.append(low.arena, assignStmt(try selfChild(low.arena, s.child_field), rewritten));
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
fn emitArm(low: *Lowerer, pbody: *std.ArrayList(ast.Stmt), arm_steps: []const AwaitStep, arm_tail: []const ast.Stmt, entry: usize, cont_state: usize, done_str: []const u8, names: *std.StringHashMap(void)) Error!void {
    const arena = low.arena;
    for (arm_steps, 0..) |s, i| {
        var blk: std.ArrayList(ast.Stmt) = .empty;
        try emitPollAndTake(low, &blk, s, done_str);
        if (i + 1 < arm_steps.len) {
            try emitBuildChild(low, &blk, arm_steps[i + 1], names);
            try setState(low, &blk, entry + i + 1);
        } else {
            // last await of the arm: run the arm's straight-line stmts (E3a: a `return` inside the
            // arm becomes the DONE transition), then go to the continuation. If the arm's last stmt
            // is an unconditional `return`, the `state=cont_state` below is dead but harmless.
            // Route through rewriteRegionBlock for block-scoped `let`/`var` shadow handling.
            const rtail = try rewriteRegionBlock(low, .{ .span = zspan, .items = @constCast(arm_tail) }, names, done_str);
            for (rtail.items) |st| try blk.append(arena, st);
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
    cargs[0] = try addrOf(arena, try selfChild(arena, s.child_field));
    var cblk = try arena.alloc(ast.Stmt, 1);
    cblk[0] = .{ .span = zspan, .kind = .{ .expr = try callExpr(arena, s.cancel, cargs) } };
    try cn_body.append(arena, try ifStateEq(arena, state, cblk));
}

// ---- Interior-borrow check (move/borrow soundness across `await`) ----------------------------
// The soundness discriminator is WHERE an interior `&self.<field>` is formed (E4, v0.5):
//
//   * CONSTRUCTOR (REJECT — this check). The constructor builds `self` as a LOCAL and returns it BY
//     VALUE, so the caller's copy lives at a NEW address. Any `&self.<field>` the constructor forms
//     points into the constructor's transient `self` and DANGLES after that move — a self-referential
//     future needing pinning (unsupported in v0). The transform itself can place such a borrow in the
//     constructor in two ways: a first-await arg `await g(&x)` (built as `self.__c0 = g(&self.x)`),
//     or — in the LOOP lowering only — a PRE-LOOP straight-line `let p = &x;` (replayed as
//     `self.p = &self.x` in the constructor). Both are unsound and stay rejected (fail-closed).
//
//   * POLL MACHINE (ACCEPT — not scanned here, and proven sound). The DRIVER owns the future by
//     `*mut` (run_to_completion/drive_irq poll it IN PLACE; it never moves between polls), so when a
//     poll state forms `&self.<field>` it is taken at the future's STABLE address. Such a borrow stays
//     valid across ANY number of subsequent suspends — including the loop back-edge — because every
//     re-poll re-enters through the same `*mut self`. This is exactly the relaxation E4 pins: a
//     captured-local borrow formed in the loop body (used across the back-edge) and a PRE-BRANCH
//     borrow (the branch lowering replays the pre-branch straight-line into the poll dispatch, at the
//     stable `*mut self`, NOT the constructor). Positive gate: fuzz_async_borrow_captured.mc.
//
// This check is PRECISE and COMPLETE for the v0 lowering shapes: it scans ONLY the constructor body,
// which is exactly the set of `&self.<field>` taken at the transient (about-to-move) address — no
// false positives (poll-formed borrows are never in `ctor_body`), no false negatives (the constructor
// never legitimately forms `&self.<field>`: it builds children BY VALUE; only `poll` takes
// `&self.__cN`). The relaxation is therefore achieved WITHOUT weakening the check — we did NOT stop it
// firing; the safe poll-formed case simply never appears in the constructor body it scans.
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

// A definite-init zero for a captured SCALAR field, or null for a non-scalar (a `Result`, struct,
// pointer, …). The constructor zero-inits scalar fields only; non-scalar fields are left unwritten,
// which is sound because (a) sema def-init tracks only scalar `uninit` vars, not aggregate fields,
// and (b) the poll state machine overwrites a captured field before it is read. This lets an
// `async fn` return a `Result<T, E>` (try-await): `self.result = 0` would be a type error, so it is
// simply not emitted.
fn zeroFor(low: *Lowerer, ty: ast.TypeExpr) Error!?ast.Expr {
    _ = low;
    const tn = typeName(ty) orelse return null; // non-nominal (Result, pointer, slice, …) -> skip
    if (std.mem.eql(u8, tn, "bool")) return .{ .span = zspan, .kind = .{ .bool_literal = false } };
    if (isScalarIntName(tn)) return intExpr("0");
    return null; // a struct/aggregate nominal -> not def-init-tracked, skip
}

// Append `self.<field> = <zero>;` only when the field type has a scalar zero (see zeroFor).
fn appendZeroInit(low: *Lowerer, body: *std.ArrayList(ast.Stmt), field: []const u8, ty: ast.TypeExpr) Error!void {
    if (try zeroFor(low, ty)) |z| try body.append(low.arena, assignStmt(try selfMember(low.arena, field), z));
}

// FINDING #1 (silent miscompile): a switch-arm pattern `number(x) => ...` / `ident(s) => ...` / a
// bare `bind` pattern introduces a REAL local in the arm scope (the backend desugars `tag_bind`/
// `bind` into a local `let x = subject.payload...;`). That local SHADOWS any captured outer
// param/awaited-binding/renamed-local of the same name. The capture-keyed rewriters
// (`rewriteParamRefs` & friends) must therefore NOT rewrite a reference to a pattern-bound name to
// `self.<name>` inside that arm. We model the shadowing by temporarily REMOVING the pattern's bound
// names from the `names` capture-set for the duration of the arm body, then restoring them.
//
// `armBoundNames` lists the names a switch arm's patterns bind: `.bind` (the whole ident) and
// `.tag_bind` (the binding ident); `.wildcard`/`.tag`/`.literal` bind nothing.
fn armBoundNames(arena: std.mem.Allocator, arm: ast.SwitchArm) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (arm.patterns) |p| switch (p.kind) {
        .bind => |b| try out.append(arena, b.text),
        .tag_bind => |tb| try out.append(arena, tb.binding.text),
        else => {},
    };
    return out.toOwnedSlice(arena);
}

// Remove every name in `bound` from `names`, appending to `removed` exactly the subset that was
// actually present (so the caller restores precisely those — a name the arm shadowed but that was
// never captured must NOT be re-inserted). Makes a switch-arm pattern binding shadow a captured
// outer name within the arm.
fn shadowRemove(names: *std.StringHashMap(void), bound: []const []const u8, removed: *std.ArrayList([]const u8), alloc: std.mem.Allocator) Error!void {
    for (bound) |nm| {
        if (names.remove(nm)) try removed.append(alloc, nm);
    }
}

fn shadowRestore(names: *std.StringHashMap(void), restored: []const []const u8) Error!void {
    for (restored) |nm| try names.put(nm, {});
}

// A `let`/`var` decl introduces region-locals. In the fast paths (which, unlike the general path,
// do NOT alpha-rename), such a local may share its name with a CAPTURED outer name (a param,
// pre-loop/pre-branch local, or awaited binding). For the REST of the enclosing block the captured
// name is shadowed by this local, so reads of it must stay bare (read the local) — NOT rewrite to
// `self.<name>`. `declShadowNames` lists the decl's bound names; the block walker shadow-removes them
// AFTER rewriting the decl (whose init is evaluated in the OUTER scope) and restores at block end
// (lexical scope). A captured TOP-LEVEL pre-loop/pre-branch local never reaches a region/loop body
// rewriter (it lives in `pre_loop`/`pre_branch`); only genuine region-locals do, so removing the name
// is always the correct shadow — without this, a nested `let p` shadowing param `p` silently read
// `self->p` (the param) instead of the local. (The general path is immune: alpha-rename made every
// such local a globally-unique name, so no capture-set collision can occur there.)
fn declShadowNames(arena: std.mem.Allocator, ld: ast.LocalDecl) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (ld.names) |nm| try out.append(arena, nm.text);
    return out.toOwnedSlice(arena);
}

// The name(s) an `if let <pat> = v` binds into its then-block (mirrors armBoundNames for switch arms):
// a `.bind`/`.tag_bind` pattern names a then-block-local that shadows a captured outer name there.
fn ifLetBoundNames(arena: std.mem.Allocator, pat: ast.Pattern) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    switch (pat.kind) {
        .bind => |b| try out.append(arena, b.text),
        .tag_bind => |tb| try out.append(arena, tb.binding.text),
        else => {},
    }
    return out.toOwnedSlice(arena);
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
            // FINDING #2: a captured fn-pointer param/local used as a callee (`op(x,y)`) must be
            // rewritten to `self.op(...)`. A direct/global function name (or an already-mangled
            // `Owner.method`) is not a captured name, so the ident lookup leaves it unchanged.
            const new_callee = try ptr(arena, ast.Expr, try rewriteParamRefs(low, c.callee.*, names));
            break :blk .{ .span = e.span, .kind = .{ .call = .{ .callee = new_callee, .type_args = c.type_args, .args = new_args } } };
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

// E3a: rewrite a REGION (loop-body / arm) straight-line statement for emission into a poll state,
// turning any `return v;` — top-level OR nested inside NON-await control flow (a plain `if`/`switch`,
// inner block, inner loop) — into the terminal DONE transition `self.result = v; self.state = DONE;
// return true;`. All other stmts get the ordinary captured-name -> `self.*` rewrite. This recurses
// THROUGH inner control flow so a conditional early `return` (e.g. `if acc >= cap { return acc; }`)
// lowers correctly; the region's awaits were already split off into states by collectArm/
// collectLoopBody (they may not contain awaits), so this rewrite only ever wraps await-free code.
//
// Soundness: a `return` in a region's straight-line code runs AFTER the region's awaits took their
// results, so NO child is live at the return — jumping to DONE is a clean exit (a later cancel finds
// DONE, no active child, no double-free). The transition replaces the `return`'s control flow
// exactly: `return true` out of `poll` means "future complete", and DONE makes it idempotent.
fn rewriteRegionStmt(low: *Lowerer, s: ast.Stmt, names: *std.StringHashMap(void), done_str: []const u8) Error!ast.Stmt {
    const arena = low.arena;
    switch (s.kind) {
        .@"return" => |maybe_expr| {
            const rexpr = maybe_expr orelse return low.fail(s.span, "async v0: `return` must return a value", .{});
            const rewritten = try rewriteParamRefs(low, rexpr, names);
            var rb: std.ArrayList(ast.Stmt) = .empty;
            try rb.append(arena, assignStmt(try selfMember(arena, "result"), rewritten));
            try rb.append(arena, assignStmt(try selfMember(arena, "state"), intExpr(done_str)));
            try rb.append(arena, .{ .span = s.span, .kind = .{ .@"return" = .{ .span = s.span, .kind = .{ .bool_literal = true } } } });
            // A `return` is multiple stmts now; wrap them in a block so the caller sees one stmt.
            return .{ .span = s.span, .kind = .{ .block = .{ .span = s.span, .items = try rb.toOwnedSlice(arena) } } };
        },
        .block => |b| return .{ .span = s.span, .kind = .{ .block = try rewriteRegionBlock(low, b, names, done_str) } },
        .unsafe_block => |b| return .{ .span = s.span, .kind = .{ .unsafe_block = try rewriteRegionBlock(low, b, names, done_str) } },
        .loop => |l| {
            // An INNER (await-free) loop: rewrite its condition refs + body; a `return` inside it
            // still jumps to DONE (the enclosing async fn's return), which is correct.
            const new_iter = if (l.iterable) |it| try rewriteParamRefs(low, it, names) else null;
            const new_body = try rewriteRegionBlock(low, l.body, names, done_str);
            var nl = l;
            nl.iterable = new_iter;
            nl.body = new_body;
            return .{ .span = s.span, .kind = .{ .loop = nl } };
        },
        .@"switch" => |sw| {
            // A plain `if`/`switch` (the parser desugars bool-`if` to a 2-arm switch). Rewrite the
            // subject + each arm body. Arms may be block- or expr-bodied; an expr arm cannot hold a
            // `return`, so only block arms need the region rewrite.
            const rsubj = try rewriteParamRefs(low, sw.subject, names);
            var new_arms = try arena.alloc(ast.SwitchArm, sw.arms.len);
            for (sw.arms, 0..) |arm, i| {
                // FINDING #1: a pattern binding (`number(x)`/`ident(s)`/bare `bind`) introduces an
                // arm-local that shadows a captured outer name — DON'T rewrite its uses to `self.*`
                // inside this arm. Remove the bound names from the capture-set for the arm body.
                const bound = try armBoundNames(arena, arm);
                var removed: std.ArrayList([]const u8) = .empty;
                try shadowRemove(names, bound, &removed, arena);
                const new_body: ast.SwitchBody = switch (arm.body) {
                    .block => |b| .{ .block = try rewriteRegionBlock(low, b, names, done_str) },
                    .expr => |e| .{ .expr = try rewriteParamRefs(low, e, names) },
                };
                try shadowRestore(names, removed.items);
                new_arms[i] = .{ .patterns = arm.patterns, .body = new_body, .dup_local_if_binds = arm.dup_local_if_binds };
            }
            return .{ .span = s.span, .kind = .{ .@"switch" = .{ .subject = rsubj, .arms = new_arms } } };
        },
        .if_let => |il| {
            // `if let <pat> = v { then } else { else }`: the matched value is read in the OUTER scope
            // (rewrite with the full capture set), the pattern binds a then-block-local that shadows a
            // captured name (shadow-remove for the then-block, like a switch arm), the else-block sees
            // the full set. Previously this fell to `else => rewriteStmtParamRefs` (an `else => s`
            // no-op), leaving captured-name reads inside the then/else arms unrewritten -> a
            // fail-closed E_UNKNOWN_IDENTIFIER; now they are rewritten with correct shadowing.
            const rvalue = try rewriteParamRefs(low, il.value, names);
            const bound = try ifLetBoundNames(arena, il.pattern);
            var removed: std.ArrayList([]const u8) = .empty;
            try shadowRemove(names, bound, &removed, arena);
            const rthen = try rewriteRegionBlock(low, il.then_block, names, done_str);
            try shadowRestore(names, removed.items);
            const relse = if (il.else_block) |eb| try rewriteRegionBlock(low, eb, names, done_str) else null;
            return .{ .span = s.span, .kind = .{ .if_let = .{ .pattern = il.pattern, .value = rvalue, .then_block = rthen, .else_block = relse } } };
        },
        else => return rewriteStmtParamRefs(low, s, names),
    }
}

fn rewriteRegionBlock(low: *Lowerer, b: ast.Block, names: *std.StringHashMap(void), done_str: []const u8) Error!ast.Block {
    const arena = low.arena;
    var items: std.ArrayList(ast.Stmt) = .empty;
    // Block-scoped shadowing: a `let`/`var` in this block shadows a captured outer name from its decl
    // to the block end. Accumulate removals and restore them all when the block closes (lexical scope).
    var block_removed: std.ArrayList([]const u8) = .empty;
    for (b.items) |st| {
        try items.append(arena, try rewriteRegionStmt(low, st, names, done_str));
        switch (st.kind) {
            .let_decl, .var_decl => |ld| try shadowRemove(names, try declShadowNames(arena, ld), &block_removed, arena),
            else => {},
        }
    }
    try shadowRestore(names, block_removed.items);
    return .{ .span = b.span, .items = try items.toOwnedSlice(arena) };
}

// E3b: rewrite a loop-BODY straight-line statement. Like `rewriteRegionStmt` (returns -> DONE) but
// ALSO maps the async loop's own `break`/`continue` to a state jump that re-enters the `while true`
// poll wrapper:
//   `break`    -> `self.state = cont_state; continue;`  (exit the loop -> continuation/tail state)
//   `continue` -> `self.state = 0; continue;`           (loop-head state: re-check the condition)
// The emitted `continue;` re-enters the while-true, which checks DONE then dispatches on the NEW
// state — precisely modelling the source edge while skipping the rest of the body block + the
// back-edge. `in_inner_loop` guards against rewriting an INNER (await-free) loop's own break/continue
// as the OUTER async loop's exit: inside such a loop those keywords belong to it and pass through
// unchanged; a `return` inside it still exits the whole async fn (-> DONE), which is correct.
//
// Soundness (at-most-one-child-live): a break/continue lives in the body's straight-line code, which
// runs AFTER the body await took its result, so no child is live. `continue` re-enters at state 0,
// where the loop head rebuilds __c0 exactly once per entry; `break` builds no child. So no leak and
// no double-build across the back-edge/exit edge.
fn rewriteLoopBodyStmt(low: *Lowerer, s: ast.Stmt, names: *std.StringHashMap(void), done_str: []const u8, cont_state: usize) Error!ast.Stmt {
    return rewriteLoopBodyStmtIn(low, s, names, done_str, cont_state, false);
}

fn rewriteLoopBodyStmtIn(low: *Lowerer, s: ast.Stmt, names: *std.StringHashMap(void), done_str: []const u8, cont_state: usize, in_inner_loop: bool) Error!ast.Stmt {
    const arena = low.arena;
    switch (s.kind) {
        .@"return" => return rewriteRegionStmt(low, s, names, done_str),
        .@"break" => {
            if (in_inner_loop) return s; // belongs to the inner loop
            var bb: std.ArrayList(ast.Stmt) = .empty;
            try setState(low, &bb, cont_state);
            try bb.append(arena, .{ .span = s.span, .kind = .@"continue" });
            return .{ .span = s.span, .kind = .{ .block = .{ .span = s.span, .items = try bb.toOwnedSlice(arena) } } };
        },
        .@"continue" => {
            if (in_inner_loop) return s; // belongs to the inner loop
            var cb: std.ArrayList(ast.Stmt) = .empty;
            try setState(low, &cb, 0);
            try cb.append(arena, .{ .span = s.span, .kind = .@"continue" });
            return .{ .span = s.span, .kind = .{ .block = .{ .span = s.span, .items = try cb.toOwnedSlice(arena) } } };
        },
        .block => |b| return .{ .span = s.span, .kind = .{ .block = try rewriteLoopBodyBlock(low, b, names, done_str, cont_state, in_inner_loop) } },
        .unsafe_block => |b| return .{ .span = s.span, .kind = .{ .unsafe_block = try rewriteLoopBodyBlock(low, b, names, done_str, cont_state, in_inner_loop) } },
        .loop => |l| {
            const new_iter = if (l.iterable) |it| try rewriteParamRefs(low, it, names) else null;
            const new_body = try rewriteLoopBodyBlock(low, l.body, names, done_str, cont_state, true);
            var nl = l;
            nl.iterable = new_iter;
            nl.body = new_body;
            return .{ .span = s.span, .kind = .{ .loop = nl } };
        },
        .@"switch" => |sw| {
            const rsubj = try rewriteParamRefs(low, sw.subject, names);
            var new_arms = try arena.alloc(ast.SwitchArm, sw.arms.len);
            for (sw.arms, 0..) |arm, i| {
                // FINDING #1 (silent miscompile): a switch-arm pattern binding (`number(x)` / bare
                // `bind`) introduces an arm-local that shadows a captured outer name. Remove the bound
                // names from the capture-set for the arm body so their reads stay bare (read the
                // payload), NOT `self.<name>` — mirroring rewriteRegionStmt / genRewriteStraight. This
                // path (the loop-body rewriter) previously skipped the shadow and read the captured
                // field instead of the payload.
                const bound = try armBoundNames(arena, arm);
                var removed: std.ArrayList([]const u8) = .empty;
                try shadowRemove(names, bound, &removed, arena);
                const new_body: ast.SwitchBody = switch (arm.body) {
                    .block => |b| .{ .block = try rewriteLoopBodyBlock(low, b, names, done_str, cont_state, in_inner_loop) },
                    .expr => |e| .{ .expr = try rewriteParamRefs(low, e, names) },
                };
                try shadowRestore(names, removed.items);
                new_arms[i] = .{ .patterns = arm.patterns, .body = new_body, .dup_local_if_binds = arm.dup_local_if_binds };
            }
            return .{ .span = s.span, .kind = .{ .@"switch" = .{ .subject = rsubj, .arms = new_arms } } };
        },
        .if_let => |il| {
            // See rewriteRegionStmt's `.if_let`: rewrite the matched value in the outer scope, shadow
            // the pattern binding for the then-block, full set for the else-block. The arms are
            // await-free (an await here routes to the general path), so a `return` inside still becomes
            // the DONE transition via rewriteLoopBodyBlock; no break/continue ambiguity arises.
            const rvalue = try rewriteParamRefs(low, il.value, names);
            const bound = try ifLetBoundNames(arena, il.pattern);
            var removed: std.ArrayList([]const u8) = .empty;
            try shadowRemove(names, bound, &removed, arena);
            const rthen = try rewriteLoopBodyBlock(low, il.then_block, names, done_str, cont_state, in_inner_loop);
            try shadowRestore(names, removed.items);
            const relse = if (il.else_block) |eb| try rewriteLoopBodyBlock(low, eb, names, done_str, cont_state, in_inner_loop) else null;
            return .{ .span = s.span, .kind = .{ .if_let = .{ .pattern = il.pattern, .value = rvalue, .then_block = rthen, .else_block = relse } } };
        },
        else => return rewriteStmtParamRefs(low, s, names),
    }
}

fn rewriteLoopBodyBlock(low: *Lowerer, b: ast.Block, names: *std.StringHashMap(void), done_str: []const u8, cont_state: usize, in_inner_loop: bool) Error!ast.Block {
    const arena = low.arena;
    var items: std.ArrayList(ast.Stmt) = .empty;
    // Block-scoped shadowing (see rewriteRegionBlock): a `let`/`var` shadows a captured outer name for
    // the rest of the block; restore at block close.
    var block_removed: std.ArrayList([]const u8) = .empty;
    for (b.items) |st| {
        try items.append(arena, try rewriteLoopBodyStmtIn(low, st, names, done_str, cont_state, in_inner_loop));
        switch (st.kind) {
            .let_decl, .var_decl => |ld| try shadowRemove(names, try declShadowNames(arena, ld), &block_removed, arena),
            else => {},
        }
    }
    try shadowRestore(names, block_removed.items);
    return .{ .span = b.span, .items = try items.toOwnedSlice(low.arena) };
}
