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

    return .{ .decls = try out.toOwnedSlice(arena), .qualified_owners = module.qualified_owners };
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

    // ---- Walk the straight-line body: leading `let x = await call;` steps, then a tail of
    // ordinary statements ending in `return expr;`. Reject anything outside this v0 shape. ----
    var steps: std.ArrayList(AwaitStep) = .empty;
    var tail: std.ArrayList(ast.Stmt) = .empty; // post-await straight-line stmts (incl the return)

    var in_tail = false;
    for (body.items) |stmt| {
        // An await step is `let NAME = await CALL;` (or `var`), seen before any non-await stmt.
        const await_call = awaitStepCall(stmt);
        if (await_call != null and !in_tail) {
            const ld = stmt.kind.let_decl; // (let or var; both carry LocalDecl)
            if (ld.names.len != 1) return low.fail(stmt.span, "async v0: an awaited binding must bind exactly one name", .{});
            const acall = await_call.?;
            // LAZY construction: child0 is built in the constructor; each LATER child is built at the
            // transition ending the prior step, so an awaited call MAY reference an earlier `await`
            // result (the prior binding is a struct field by then). No depends-on-prior rejection.
            // Resolve the child future type from the awaited call's callee.
            const child = try resolveAwait(low, stmt.span, acall);
            const field = try std.fmt.allocPrint(arena, "__c{d}", .{steps.items.len});
            // The binding's result type: an async-fn child carries its own return type; a leaf
            // child's result type is only known from the binding's `: T` annotation (v0 requires
            // one). `__async_infer` is the leaf placeholder — reject if no annotation overrides it.
            if (ld.ty == null and typeName(child.result_type) != null and std.mem.eql(u8, typeName(child.result_type).?, "__async_infer")) {
                return low.fail(stmt.span, "async v0: `let {s} = await <leaf>;` needs an explicit result type annotation `let {s}: T = await ...;`", .{ ld.names[0].text, ld.names[0].text });
            }
            const res_ty = ld.ty orelse child.result_type;
            try steps.append(arena, .{
                .binding = ld.names[0].text,
                .binding_type = ld.ty,
                .child_field = field,
                .fut_type = child.fut_type,
                .take_result = child.take_result,
                .cancel = child.cancel,
                .call = acall,
                .result_type = res_ty,
            });
            continue;
        }
        // First non-await statement begins the tail. Reject a stray await beyond the leading run
        // (v0 forbids awaits interleaved with / nested in straight-line code or control flow).
        in_tail = true;
        if (stmtContainsAwait(stmt)) return low.fail(stmt.span, "async v0: only a leading run of `let x = await call;` statements is supported (no awaits in the straight-line tail, branches, or loops)", .{});
        try tail.append(arena, stmt);
    }

    // ---- Build the future struct: state + child fields + captured-binding fields + result. ----
    var fields: std.ArrayList(ast.Field) = .empty;
    try fields.append(arena, .{ .name = id("state"), .ty = try nameType(arena, "u8") });
    for (steps.items) |s| {
        try fields.append(arena, .{ .name = id(s.child_field), .ty = try nameType(arena, s.fut_type) });
    }
    // Conservative capture: every awaited binding becomes a field (it may be live across a later
    // await or used in the tail). Params are also captured so the tail/await args can read them.
    for (fd.params) |p| {
        try fields.append(arena, .{ .name = p.name, .ty = p.ty });
    }
    for (steps.items) |s| {
        if (s.binding) |b| try fields.append(arena, .{ .name = id(b), .ty = s.result_type });
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
    // Zero the captured binding fields + result (definite-init for the move/borrow checker).
    for (steps.items) |s| {
        if (s.binding) |b| try cbody.append(arena, assignStmt(try selfMember(arena, b), try zeroFor(low, s.result_type)));
    }
    try cbody.append(arena, assignStmt(try selfMember(arena, "result"), try zeroFor(low, result_type)));
    try cbody.append(arena, .{ .span = zspan, .kind = .{ .@"return" = identExpr("self") } });

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
    const tail_state = steps.items.len; // state reached after the last await; the tail runs here
    const done_state = steps.items.len + 1; // distinct DONE state: complete, nothing left to run
    // Idempotence (std/task.mc: poll must keep returning true after completion): check DONE FIRST
    // and return true WITHOUT re-running the tail statements or their side effects.
    {
        var dbody = try arena.alloc(ast.Stmt, 1);
        dbody[0] = .{ .span = zspan, .kind = .{ .@"return" = .{ .span = zspan, .kind = .{ .bool_literal = true } } } };
        try pbody.append(arena, try ifStateEq(arena, done_state, dbody));
    }
    for (steps.items, 0..) |s, i| {
        var blk: std.ArrayList(ast.Stmt) = .empty;
        // let r: bool = FutT__poll(&self.__cN);
        const poll_fn = try std.fmt.allocPrint(arena, "{s}__poll", .{s.fut_type});
        var poll_args = try arena.alloc(ast.Expr, 1);
        poll_args[0] = try addrOf(arena, try selfMember(arena, s.child_field));
        try blk.append(arena, .{ .span = zspan, .kind = .{ .let_decl = .{
            .names = try dupIdents(arena, &.{"r"}),
            .ty = try nameType(arena, "bool"),
            .init = try callExpr(arena, poll_fn, poll_args),
        } } });
        // if !r { return false; }
        try blk.append(arena, try ifNotReturnFalse(arena));
        // self.<binding> = FutT_take_result(&self.__cN);   (or drop the result if no binding)
        var take_args = try arena.alloc(ast.Expr, 1);
        take_args[0] = try addrOf(arena, try selfMember(arena, s.child_field));
        const take_call = try callExpr(arena, s.take_result, take_args);
        if (s.binding) |b| {
            try blk.append(arena, assignStmt(try selfMember(arena, b), take_call));
        } else {
            try blk.append(arena, .{ .span = zspan, .kind = .{ .expr = take_call } });
        }
        // LAZY: build the NEXT child future now, AFTER the prior result is stored in its field, so
        // its call may reference an earlier `await` result (and params) — all `self.*` fields.
        if (i + 1 < steps.items.len) {
            const next = steps.items[i + 1];
            const rewritten = try rewriteParamRefs(low, next.call, &field_names);
            try blk.append(arena, assignStmt(try selfMember(arena, next.child_field), rewritten));
        }
        // self.state = N+1;
        const next_state = try std.fmt.allocPrint(arena, "{d}", .{i + 1});
        try blk.append(arena, assignStmt(try selfMember(arena, "state"), intExpr(next_state)));

        // if self.state == N { <blk> }
        try pbody.append(arena, try ifStateEq(arena, i, try blk.toOwnedSlice(arena)));
    }

    // The straight-line tail. `return expr;` becomes result-store + final-state + `return true`.
    // Other tail statements are emitted as-is, but local idents that name a param or an awaited
    // binding must read from `self.*` (they are fields now); the `return expr` is rewritten too.
    // `field_names` (params ∪ all bindings) is exactly the captured-field set the tail needs.
    const bind_names = &field_names;
    // The tail runs in ONE guarded state (`if self.state == tail_state`), reached after the last
    // await advances `state` to tail_state. `return expr;` becomes result-store + advance to DONE +
    // `return true`. Guarding it (plus the DONE early-return above) makes poll idempotent: once
    // complete, state == done_state, so the tail never re-runs.
    const done_str = try std.fmt.allocPrint(arena, "{d}", .{done_state});
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
                // A straight-line tail stmt: rewrite ident reads of params/bindings to self.* .
                const rewritten = try rewriteStmtParamRefs(low, stmt, bind_names);
                try tail_body.append(arena, rewritten);
            },
        }
    }
    try pbody.append(arena, try ifStateEq(arena, tail_state, try tail_body.toOwnedSlice(arena)));
    // Unreachable fallback: at runtime `state` is always DONE or one of 0..tail_state, so one guard
    // above always returns. But every path is now inside a state guard, so the definite-return
    // check needs an explicit trailing return. `false` (not-complete) is the conservative choice.
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
    for (steps.items, 0..) |s, i| {
        // if self.state == i { ChildI_cancel(&self.__ci); }
        var cargs = try arena.alloc(ast.Expr, 1);
        cargs[0] = try addrOf(arena, try selfMember(arena, s.child_field));
        var cblk = try arena.alloc(ast.Stmt, 1);
        cblk[0] = .{ .span = zspan, .kind = .{ .expr = try callExpr(arena, s.cancel, cargs) } };
        try cn_body.append(arena, try ifStateEq(arena, i, cblk));
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
