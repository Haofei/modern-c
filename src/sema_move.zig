//! Linear `move` / borrow checker — the move-linearity analysis pass.
//!
//! Extracted verbatim from `sema.zig` (Phase 2b, pure structure, zero behavior
//! change). These were `Checker` methods; they now live here as free functions
//! taking `self: *Checker`, called from the spine as `sema_move.checkMoveLinearity(self, ...)`.
//! Phase 3 will rewrite this pass over a proper CFG; isolating it now is the point.

const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");

const sema = @import("sema.zig");
const spine = sema;
const Checker = sema.Checker;
const MoveSlot = sema.MoveSlot;
const Context = sema.Context;

pub fn checkMoveLinearity(self: *Checker, fn_decl: ast.FnDecl, aliases: *const std.StringHashMap(ast.TypeExpr)) void {
    const body = fn_decl.body orelse return;
    var state = std.StringHashMap(MoveSlot).init(self.reporter.allocator);
    defer state.deinit();
    defer {
        for (self.move_place_keys.items) |k| self.reporter.allocator.free(k);
        self.move_place_keys.clearRetainingCapacity();
    }
    for (fn_decl.params) |param| {
        if (self.typeIsMoveArray(param.ty, aliases)) {
            self.errorCode(param.name.span, "E_MOVE_ARRAY_UNSUPPORTED", "an array of a linear `move` type is not yet trackable (element moves need place analysis); pass the resources behind pointers or in a `move` container instead");
        } else if (self.typeEmbedsMoveByValue(param.ty, aliases)) {
            state.put(param.name.text, .{ .live = true, .span = param.name.span, .ty = param.ty }) catch {
                self.oom = true;
            };
        }
    }
    const fell_through = !moveBlock(self, body, &state, aliases);
    // Implicit fall-through exit at the end of the body (a `void` return): only a
    // real exit edge if control can actually reach it. If the body diverges on every
    // path (e.g. ends in `return`), each such exit edge was already leak-checked.
    if (fell_through) {
        var it = state.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.live and !entry.value_ptr.deferred) {
                self.errorCode(entry.value_ptr.span, "E_RESOURCE_LEAK", "linear `move` value is never consumed (must be moved, returned, or freed)");
            }
        }
    }
}

// Analyze the statements of a block in order. Returns `true` if the block diverges
// (every path through it ends in `return`/`break`/`continue`), in which case the
// join after the block is unreachable. Statements after a diverging statement are
// dead code and are not analyzed.
pub fn moveBlock(self: *Checker, block: ast.Block, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
    for (block.items) |stmt| {
        if (moveStmt(self, stmt, state, aliases)) return true;
    }
    return false;
}

// A lexical `{ ... }` sub-scope. Returns whether the block diverges. Block-local
// `move` bindings are dropped from `state` on the way out; if the block falls through
// (does not diverge) any still-live local is a leak at the scope's normal exit edge.
pub fn moveScopedBlock(self: *Checker, block: ast.Block, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
    var before = cloneMoveState(self, state);
    defer before.deinit();
    const diverges = moveBlock(self, block, state, aliases);
    if (!diverges) {
        reportMoveLocalsLeavingScope(self, state, &before, "linear `move` value declared in this block is never consumed (must be moved, returned, or freed before the block ends)");
    }

    var scoped = std.StringHashMap(MoveSlot).init(self.reporter.allocator);
    defer scoped.deinit();
    var it = before.iterator();
    while (it.next()) |entry| {
        const slot = state.get(entry.key_ptr.*) orelse entry.value_ptr.*;
        scoped.put(entry.key_ptr.*, slot) catch {
            self.oom = true;
        };
    }
    replaceMoveState(self, state, &scoped);
    return diverges;
}

// Leak-check every `move` binding live at an exit edge. Used both at an explicit
// `return` (the whole function exits) and at a `?` operator (the function exits on
// the error branch). A `deferred` binding is scheduled for lexical cleanup that runs
// on the exit edge, so it is not a leak.
pub fn checkMoveExitEdge(self: *Checker, state: *const std.StringHashMap(MoveSlot), message: []const u8) void {
    var it = state.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.live and !entry.value_ptr.deferred) {
            self.errorCode(entry.value_ptr.span, "E_RESOURCE_LEAK", message);
        }
    }
}

pub fn checkMoveExit(self: *Checker, state: *const std.StringHashMap(MoveSlot)) void {
    checkMoveExitEdge(self, state, "linear `move` value is still live on this function-exit path (must be moved, returned, or freed)");
}

pub fn reportMoveLocalsLeavingScope(self: *Checker, inner: *const std.StringHashMap(MoveSlot), outer: *const std.StringHashMap(MoveSlot), message: []const u8) void {
    var it = inner.iterator();
    while (it.next()) |entry| {
        if (outer.contains(entry.key_ptr.*)) continue;
        if (entry.value_ptr.live and !entry.value_ptr.deferred) {
            self.errorCode(entry.value_ptr.span, "E_RESOURCE_LEAK", message);
        }
    }
}

pub fn addIfLetMoveBinding(self: *Checker, pattern: ast.Pattern, value: ast.Expr, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) ?[]const u8 {
    const ctx = self.move_ctx orelse return null;
    const value_ty = spine.exprResultType(value, ctx.*) orelse return null;
    switch (pattern.kind) {
        .bind => |ident| {
            const payload_ty = spine.nullableInnerType(value_ty) orelse return null;
            if (!self.typeEmbedsMoveByValue(payload_ty, aliases)) return null;
            state.put(ident.text, .{ .live = true, .span = ident.span, .ty = payload_ty }) catch {
                self.oom = true;
            };
            return ident.text;
        },
        .tag_bind => |node| {
            const payload_ty = spine.resultPayloadType(value_ty, node.tag.text) orelse return null;
            if (!self.typeEmbedsMoveByValue(payload_ty, aliases)) return null;
            state.put(node.binding.text, .{ .live = true, .span = node.binding.span, .ty = payload_ty }) catch {
                self.oom = true;
            };
            return node.binding.text;
        },
        .wildcard, .tag, .literal => return null,
    }
}

// An expression used only for its side effects (a bare expression statement, or a switch /
// if-let arm whose body is an expression) discards its result. If that result embeds a
// linear `move` resource by value — a `move` struct, a `Result<…move…,…>`, or a `?move` —
// the resource leaks: it was never bound, returned, or passed to a consuming function.
// (A direct call's return type and a `?` operand's ok payload are resolved here; a generic
// call with explicit type args is not, but its by-value storage is still caught at
// monomorphization by E_MOVE_FIELD_IN_NONMOVE.)
pub fn checkUnusedMoveResult(self: *Checker, e: ast.Expr, aliases: *const std.StringHashMap(ast.TypeExpr)) void {
    const mctx = self.move_ctx orelse return;
    const rty = spine.exprResultType(e, mctx.*) orelse return;
    if (self.typeEmbedsMoveByValue(rty, aliases)) {
        self.errorCode(e.span, "E_UNUSED_MOVE_RESULT", "the linear `move` result of this expression is discarded; bind it with `let`, return it, or pass it to a consuming function");
    }
}

// Analyze one statement. Returns `true` if it diverges — transfers control out of the
// enclosing block on every path (`return`, `break`, `continue`, or a branch all of
// whose arms diverge) — so the statements that follow are unreachable and the join
// after it has no predecessor here.
pub fn moveStmt(self: *Checker, stmt: ast.Stmt, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
    switch (stmt.kind) {
        .let_decl, .var_decl => |decl| {
            if (decl.init) |init_expr| moveConsume(self, init_expr, state, aliases);
            // The binding's type: an explicit annotation, else inferred from the
            // initializer. An inferred `let b = alloc()` over a `move` type must still be
            // tracked as a live resource, or it leaks undetected.
            var binding_ty: ?ast.TypeExpr = decl.ty;
            if (binding_ty == null) {
                if (decl.init) |init_expr| {
                    if (self.move_ctx) |mctx| binding_ty = spine.exprResultType(init_expr, mctx.*);
                }
            }
            var bound_as_move = false;
            if (binding_ty) |ty| {
                if (decl.names.len > 0) {
                    if (self.typeIsMoveArray(ty, aliases)) {
                        self.errorCode(decl.names[0].span, "E_MOVE_ARRAY_UNSUPPORTED", "an array of a linear `move` type is not yet trackable (element moves need place analysis); hold the resources behind pointers or in a `move` container instead");
                    } else if (self.typeEmbedsMoveByValue(ty, aliases)) {
                        // A binding whose type embeds a `move` resource by value — a `move`
                        // struct, a `Result<…move…, …>`, or a `?move` — must be consumed.
                        state.put(decl.names[0].text, .{ .live = true, .span = decl.names[0].span, .ty = ty }) catch {
                            self.oom = true;
                        };
                        bound_as_move = true;
                    }
                }
            }
            // T1.2: `let p = &a;` where `a` is a tracked `move` binding records `p` as a
            // DERIVED alias of `a`. Reading through `p` after `a` is moved is then a stale
            // use-after-move (see moveBorrow/moveConsume). A pointer alias is a borrow, not
            // a by-value resource, so it is only registered when the binding was not already
            // classed as a move resource above.
            if (!bound_as_move and decl.names.len > 0 and decl.init != null) {
                if (callLaunderedMoveRoot(self, decl.init.?, state)) |referent| {
                    // Gap #2: `let q = f(&t)` where `f` returns a pointer — `q` may alias a
                    // borrow of the move binding `t` laundered through the callee's result.
                    // Register it as a derived alias so a USE of `q` after `t` is moved is a
                    // stale-alias use-after-move (and nothing fires if `q` is dead first).
                    state.put(decl.names[0].text, .{ .live = false, .span = decl.names[0].span, .alias_of = referent }) catch {
                        self.oom = true;
                    };
                } else if (spine.aliasReferentOf(decl.init.?, state)) |referent| {
                    if (state.contains(referent)) {
                        // Is `*<this alias>` the whole move binding? True when the initializer
                        // is `&<ident>` directly (`let p = &o` ⇒ `*p` IS `o`), or when copying
                        // an existing full alias (`let q = p`). A `&o.field`/`&o[i]` initializer
                        // is NOT a full alias (its referent resolves to `o` for stale-tracking,
                        // but `*p` is the field, not `o`).
                        const full = isDirectIdentAddressOf(decl.init.?) or
                            inheritedFullDerefAlias(decl.init.?, state);
                        // `live = false`: the alias is a borrow, not a linear resource, so
                        // leak/exit checks (which only fire on `live` slots) must skip it.
                        // Its referent's moved-out state is what the stale check consults.
                        state.put(decl.names[0].text, .{ .live = false, .span = decl.names[0].span, .alias_of = referent, .full_deref_alias = full }) catch {
                            self.oom = true;
                        };
                    }
                } else if (decl.init.?.kind == .struct_literal) {
                    // (bug #3 / T1.3) `let h = .{ .p = &t };` launders a borrow of the move
                    // binding `t` through the struct FIELD `h.p`. Register a field-place alias
                    // `h.p -> t` so reading `h.p` after `t` is moved is caught as a stale alias.
                    // The scan recurses through nested struct literals (`o.h.p`) for precise
                    // tracking, and conservatively marks the move root escaped where the borrow
                    // is buried in a non-nameable place (a nested array literal).
                    registerAggregateFieldAliases(self, decl.names[0].text, decl.names[0].span, decl.init.?, state);
                } else {
                    // T1.2: `let p = &t.inner;` borrows a SUBFIELD/element of the move binding
                    // `t`. The whole-binding stale-alias machinery keys on the bare referent
                    // and does not poison such a sub-place alias, so we cannot prove the later
                    // use safe. Mark `t` borrow-escaped so moving `t` as a whole is refused
                    // while `p` is in scope. (A direct `&t` is the alias case above and is NOT
                    // routed here; only sub-place borrows reach this.)
                    markBorrowEscape(self, decl.init.?, decl.names[0].span, state);
                }
            }
            return false;
        },
        .@"return" => |maybe| {
            if (maybe) |v| moveConsume(self, v, state, aliases);
            checkMoveExit(self, state);
            return true; // the rest of the block is unreachable
        },
        .expr => |e| {
            moveConsume(self, e, state, aliases);
            checkUnusedMoveResult(self, e, aliases);
            // An expression statement that unconditionally aborts or is unreachable
            // (`unreachable`, `trap(...)`, or a call to a `-> never` function) ends
            // this control-flow path. Unlike `return`/`?` it performs no normal exit
            // and reaches no successor, so live resources here do not leak — the
            // program halts or the path is impossible. This is the `Unreachable`
            // lattice state: diverge with no exit-edge leak check, so the post-branch
            // join drops this path instead of merging a stale live set (which would
            // otherwise raise a spurious E_MOVE_BRANCH_MISMATCH / E_RESOURCE_LEAK).
            // (The `-> never` call is recognized here for the move join even though
            // the function-level return-path checker still requires an explicit
            // `return`/`trap`/`unreachable` terminator — both backends need one.)
            if (self.move_ctx) |mctx| {
                if (!spine.exprMayFallThrough(e, mctx.*) or spine.exprIsNeverCall(e, mctx.*)) return true;
            }
            return false;
        },
        .assignment => |a| {
            switch (a.target.kind) {
                .ident => |id| {
                    // (bug #2) Whether the EXISTING slot is a borrow alias (registered
                    // `live=false, alias_of=...`). Overwrite/defer-reserve checks below
                    // only concern linear resources, not aliases (an alias is never `live`
                    // or `deferred`), and re-binding an alias must NOT flip it live.
                    const was_alias = if (state.getPtr(id.text)) |slot| slot.alias_of != null else false;
                    if (state.getPtr(id.text)) |slot| {
                        if (slot.live and !slot.deferred) {
                            self.errorCode(a.target.span, "E_RESOURCE_OVERWRITE", "cannot overwrite a live linear `move` value; consume it first");
                        } else if (slot.deferred) {
                            self.errorCode(a.target.span, "E_USE_AFTER_MOVE", "linear `move` value is reserved by a `defer` and cannot be reassigned");
                        }
                    }
                    moveConsume(self, a.value, state, aliases);
                    if (was_alias) {
                        // Re-derive the alias from the RHS: `p = &t2` keeps `p` a borrow
                        // (live=false) now aliasing `t2`, so it does not leak at exit and
                        // its stale-after-move tracking follows the NEW referent. If the RHS
                        // is not an alias of a tracked move binding, drop the slot entirely
                        // (it is no longer a meaningful borrow); leaving it live would be the
                        // phantom-leak false positive this fixes.
                        const new_ref = spine.aliasReferentOf(a.value, state);
                        if (state.getPtr(id.text)) |slot| {
                            if (new_ref) |referent| {
                                if (state.contains(referent)) {
                                    slot.alias_of = referent;
                                    slot.live = false;
                                } else {
                                    _ = state.remove(id.text);
                                }
                            } else {
                                _ = state.remove(id.text);
                            }
                        }
                    } else if (state.getPtr(id.text)) |slot| {
                        slot.live = true;
                    }
                },
                .member => |m| {
                    // Assigning through `p.field`: the base must be live, and overwriting a
                    // live `move` field (one not already moved out) would drop the old
                    // resource without consuming it.
                    moveBorrow(self, m.base.*, state);
                    const key_opt = moveFieldPlaceKey(self, a.target, m, state, aliases);
                    if (key_opt) |key| {
                        if (!state.contains(key)) {
                            self.errorCode(a.target.span, "E_RESOURCE_OVERWRITE", "cannot overwrite a live linear `move` field; consume it first");
                        }
                    }
                    moveConsume(self, a.value, state, aliases);
                    if (key_opt) |key| {
                        _ = state.remove(key); // the field now holds a fresh live resource
                    }
                    // T1.2: `h.p = &t` launders a borrow of `t` into the struct field `h.p`
                    // (memory we cannot track for deadness). Mark `t` borrow-escaped so a
                    // later move of `t` is refused.
                    markBorrowEscape(self, a.value, a.target.span, state);
                },
                else => {
                    // T1.2: `arr[0] = &t` (or any non-ident lvalue) stores a borrow of `t`
                    // into memory; mark `t` borrow-escaped. (Plain scalar `p = &t` is the
                    // `.ident` arm above — tracked precisely by the stale-alias mechanism —
                    // and is deliberately NOT routed here.)
                    markBorrowEscape(self, a.value, a.target.span, state);
                    moveConsume(self, a.value, state, aliases);
                },
            }
            return false;
        },
        // `defer <expr>` runs at scope end: it reserves (does not immediately
        // move) the values it will consume, so they neither leak nor remain
        // movable.
        .@"defer" => |e| {
            moveDefer(self, e, state, aliases);
            return false;
        },
        .assert => |e| {
            moveBorrow(self, e, state);
            return false;
        },
        .block, .unsafe_block, .comptime_block => |b| return moveScopedBlock(self, b, state, aliases),
        .contract_block => |c| return moveScopedBlock(self, c.block, state, aliases),
        .loop => |l| {
            if (l.iterable) |iter| moveBorrow(self, iter, state);
            // Snapshot the names live at loop entry so a `break`/`continue` inside
            // the body can tell loop-body locals (which leak on an early exit) from
            // outer resources (handled by the E_MOVE_LOOP_RESOURCE check below).
            var entry_names = std.StringHashMap(void).init(self.reporter.allocator);
            var snap_it = state.iterator();
            while (snap_it.next()) |e| {
                entry_names.put(e.key_ptr.*, {}) catch {
                    self.oom = true;
                };
            }
            self.move_loop_stack.append(self.reporter.allocator, entry_names) catch {
                self.oom = true;
            };
            var body_state = cloneMoveState(self, state);
            defer body_state.deinit();
            _ = moveBlock(self, l.body, &body_state, aliases);
            if (self.move_loop_stack.pop()) |popped| {
                var p = popped;
                p.deinit();
            }
            reportMoveLocalsLeavingScope(self, &body_state, state, "linear `move` value declared in a loop body is never consumed (must be moved, returned, or freed before the iteration ends)");
            var it = state.iterator();
            while (it.next()) |entry| {
                const after = body_state.get(entry.key_ptr.*) orelse continue;
                const before = entry.value_ptr.*;
                if (before.live != after.live or before.deferred != after.deferred) {
                    self.errorCode(before.span, "E_MOVE_LOOP_RESOURCE", "cannot consume or reserve an outer linear `move` value inside a loop; the loop may run zero or multiple times");
                    entry.value_ptr.live = false;
                    entry.value_ptr.deferred = false;
                }
            }
            // A loop may run zero times, so control can always fall through past it.
            return false;
        },
        .if_let => |n| {
            // The condition/scrutinee is evaluated, so by-value `move` operands in
            // it are consumed (borrow operands `&x` stay borrows inside moveConsume).
            moveConsume(self, n.value, state, aliases);
            var then_state = cloneMoveState(self, state);
            defer then_state.deinit();
            var else_state = cloneMoveState(self, state);
            defer else_state.deinit();
            const bound_name = addIfLetMoveBinding(self, n.pattern, n.value, &then_state, aliases);
            const then_div = moveBlock(self, n.then_block, &then_state, aliases);
            if (bound_name) |bn| {
                // A diverging arm already leak-checked the binding at its exit edge.
                if (!then_div) {
                    if (then_state.getPtr(bn)) |slot| {
                        if (slot.live and !slot.deferred) {
                            self.errorCode(slot.span, "E_RESOURCE_LEAK", "linear `move` value bound in an if-let branch is never consumed (must be moved, returned, or freed)");
                        }
                    }
                }
                _ = then_state.remove(bn);
            }
            var else_div = false;
            if (n.else_block) |eb| {
                else_div = moveBlock(self, eb, &else_state, aliases);
            }
            finalizeBranchLocals(self, &then_state, state, !then_div);
            finalizeBranchLocals(self, &else_state, state, !else_div);
            joinMoveBranches(self, state, &then_state, then_div, &else_state, else_div);
            // Diverges only when an `else` exists and both arms diverge; a missing
            // `else` arm falls through.
            return then_div and (n.else_block != null) and else_div;
        },
        .@"switch" => |sw| {
            // The subject is evaluated, so by-value `move` operands in it are
            // consumed (a plain `if cond` desugars to a switch on `cond`; borrow
            // operands `&x` and non-move subjects stay no-ops in moveConsume).
            moveConsume(self, sw.subject, state, aliases);
            var joined: ?std.StringHashMap(MoveSlot) = null;
            defer if (joined) |*m| m.deinit();
            // Infer the subject's type so a pattern binding (`ok(p)`) that names a `move`
            // value is tracked inside the arm — otherwise use-after-move / a leak through a
            // switch arm goes undetected.
            const subject_ty: ?ast.TypeExpr = if (self.move_ctx) |ctx| spine.exprResultType(sw.subject, ctx.*) else null;
            var any_arm = false;
            var all_diverge = true;
            for (sw.arms) |arm| {
                any_arm = true;
                var arm_state = cloneMoveState(self, state);
                defer arm_state.deinit();
                var bound_name: ?[]const u8 = null;
                for (arm.patterns) |pat| {
                    const payload_ty: ?ast.TypeExpr = switch (pat.kind) {
                        .bind => subject_ty, // binds the whole value
                        .tag_bind => |tb| if (subject_ty) |sty| spine.resultPayloadType(sty, tb.tag.text) else null,
                        else => null,
                    };
                    const name: ?ast.Ident = switch (pat.kind) {
                        .bind => |id| id,
                        .tag_bind => |tb| tb.binding,
                        else => null,
                    };
                    if (name) |id| {
                        if (payload_ty) |pty| {
                            // Recursive predicate: a payload that is itself a `?move` or
                            // `Result<…move…,…>` embeds a linear resource and must be tracked
                            // inside the arm too, not only a payload that is a move type name.
                            if (self.typeEmbedsMoveByValue(pty, aliases)) {
                                arm_state.put(id.text, .{ .live = true, .span = id.span, .ty = pty }) catch {
                                    self.oom = true;
                                };
                                bound_name = id.text;
                            }
                        }
                    }
                }
                const arm_div = switch (arm.body) {
                    .block => |b| moveBlock(self, b, &arm_state, aliases),
                    .expr => |e| blk: {
                        moveConsume(self, e, &arm_state, aliases);
                        checkUnusedMoveResult(self, e, aliases); // arm body is used for effect; its move result must not be discarded
                        break :blk false;
                    },
                };
                // A `move` value bound by this arm must be consumed within it; then it leaves
                // scope (remove it so a later arm's same-named binding starts fresh). A
                // diverging arm already leak-checked it at its exit edge.
                if (bound_name) |bn| {
                    if (!arm_div) {
                        if (arm_state.getPtr(bn)) |slot| {
                            if (slot.live and !slot.deferred) {
                                self.errorCode(slot.span, "E_RESOURCE_LEAK", "linear `move` value bound in a switch arm is never consumed (must be moved, returned, or freed)");
                            }
                        }
                    }
                    _ = arm_state.remove(bn);
                }
                finalizeBranchLocals(self, &arm_state, state, !arm_div);
                // Only an arm that falls through reaches the join after the switch.
                if (!arm_div) {
                    all_diverge = false;
                    if (joined) |*m| {
                        mergeMoveBranches(self, m, m, &arm_state);
                    } else {
                        joined = cloneMoveState(self, &arm_state);
                    }
                }
            }
            if (joined) |*m| replaceMoveState(self, state, m);
            // The switch diverges only if it has arms and every arm diverges.
            return any_arm and all_diverge;
        },
        .@"break", .@"continue" => {
            checkLoopExitLeaks(self, state);
            return true; // the rest of the loop body is unreachable
        },
        .asm_stmt => return false,
    }
}

// Drop branch-local `move` bindings (names not present in `outer`) from `branch` on
// the way out of an if/switch arm. If the arm falls through (`report`), any still-live
// local is a leak at the arm's normal exit; a diverging arm already leak-checked its
// locals at the exit edge. Afterwards `branch` holds only outer names, so two arms can
// be merged by comparing the same keys.
pub fn finalizeBranchLocals(self: *Checker, branch: *std.StringHashMap(MoveSlot), outer: *const std.StringHashMap(MoveSlot), report: bool) void {
    var removals: std.ArrayListUnmanaged([]const u8) = .empty;
    defer removals.deinit(self.reporter.allocator);
    var it = branch.iterator();
    while (it.next()) |entry| {
        if (outer.contains(entry.key_ptr.*)) continue;
        if (report and entry.value_ptr.live and !entry.value_ptr.deferred) {
            self.errorCode(entry.value_ptr.span, "E_RESOURCE_LEAK", "linear `move` value declared in this branch is never consumed before the branch exits");
        }
        removals.append(self.reporter.allocator, entry.key_ptr.*) catch {
            self.oom = true;
        };
    }
    for (removals.items) |k| _ = branch.remove(k);
}

// Join two control-flow arms into `dest`. A diverging arm does not reach the join, so
// it contributes nothing: the join is the surviving arm's state (or unreachable if
// both diverge). Only when both arms fall through are they merged — and a `move` value
// must then have consistent ownership across them (else E_MOVE_BRANCH_MISMATCH).
pub fn joinMoveBranches(
    self: *Checker,
    dest: *std.StringHashMap(MoveSlot),
    left: *const std.StringHashMap(MoveSlot),
    left_div: bool,
    right: *const std.StringHashMap(MoveSlot),
    right_div: bool,
) void {
    if (left_div and right_div) return; // join is unreachable; leave `dest` as-is
    if (left_div) {
        replaceMoveState(self, dest, right);
        return;
    }
    if (right_div) {
        replaceMoveState(self, dest, left);
        return;
    }
    mergeMoveBranches(self, dest, left, right);
}

// At a `break`/`continue`, the current iteration ends. Any loop-body-local `move`
// value still live (a name not present at loop entry, and not reserved by a defer)
// leaks on that edge — the iteration exits without consuming it. Mirrors
// `checkMoveExit` for `return`, but bounded to the innermost loop's body locals.
pub fn checkLoopExitLeaks(self: *Checker, state: *std.StringHashMap(MoveSlot)) void {
    if (self.move_loop_stack.items.len == 0) return; // a stray break/continue (parser rejects)
    const entry_names = &self.move_loop_stack.items[self.move_loop_stack.items.len - 1];
    // `break`/`continue` is terminal in its block, so this is the only visit; we do
    // NOT clear the slot, which would corrupt the live state the enclosing branch
    // merges back (producing spurious branch-mismatch / use-after-move downstream).
    var it = state.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.live and !entry.value_ptr.deferred and !entry_names.contains(entry.key_ptr.*)) {
            self.errorCode(entry.value_ptr.span, "E_RESOURCE_LEAK", "linear `move` value declared in a loop body is never consumed before this `break`/`continue` exits the iteration");
        }
    }
}

pub fn cloneMoveState(self: *Checker, state: *const std.StringHashMap(MoveSlot)) std.StringHashMap(MoveSlot) {
    var clone = std.StringHashMap(MoveSlot).init(self.reporter.allocator);
    var it = state.iterator();
    while (it.next()) |entry| {
        clone.put(entry.key_ptr.*, entry.value_ptr.*) catch {
            self.oom = true;
        };
    }
    return clone;
}

pub fn replaceMoveState(self: *Checker, dest: *std.StringHashMap(MoveSlot), src: *const std.StringHashMap(MoveSlot)) void {
    dest.clearRetainingCapacity();
    var it = src.iterator();
    while (it.next()) |entry| {
        dest.put(entry.key_ptr.*, entry.value_ptr.*) catch {
            self.oom = true;
        };
    }
}

pub fn mergeMoveBranches(
    self: *Checker,
    dest: *std.StringHashMap(MoveSlot),
    left: *const std.StringHashMap(MoveSlot),
    right: *const std.StringHashMap(MoveSlot),
) void {
    var merged = std.StringHashMap(MoveSlot).init(self.reporter.allocator);
    defer merged.deinit();

    var it = left.iterator();
    while (it.next()) |entry| {
        const other = right.get(entry.key_ptr.*) orelse {
            if (entry.value_ptr.live and !entry.value_ptr.deferred) {
                self.errorCode(entry.value_ptr.span, "E_RESOURCE_LEAK", "linear `move` value created in only one branch is never consumed before the branch exits");
            }
            continue;
        };
        var slot = entry.value_ptr.*;
        if (slot.live != other.live or slot.deferred != other.deferred) {
            self.errorCode(slot.span, "E_MOVE_BRANCH_MISMATCH", "linear `move` value has inconsistent ownership across control-flow branches");
            slot.live = false;
            slot.deferred = false;
        }
        merged.put(entry.key_ptr.*, slot) catch {
            self.oom = true;
        };
    }

    var right_it = right.iterator();
    while (right_it.next()) |entry| {
        if (left.contains(entry.key_ptr.*)) continue;
        if (entry.value_ptr.live and !entry.value_ptr.deferred) {
            self.errorCode(entry.value_ptr.span, "E_RESOURCE_LEAK", "linear `move` value created in only one branch is never consumed before the branch exits");
        }
    }

    replaceMoveState(self, dest, &merged);
}

// `&<ident>` (peeling `grouped`): the address of a binding ITSELF, so `*result` is that
// binding. `&t.field`, `&t[i]`, and call results are NOT direct ident address-of.
fn isDirectIdentAddressOf(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .grouped => |inner| isDirectIdentAddressOf(inner.*),
        .address_of => |inner| switch (inner.*.kind) {
            .ident => true,
            .grouped => |g| g.*.kind == .ident,
            else => false,
        },
        else => false,
    };
}

// `let q = p` copying an existing full-deref alias `p`: `q` is also one (`*q` == `*p`).
fn inheritedFullDerefAlias(expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) bool {
    switch (expr.kind) {
        .ident => |id| if (state.get(id.text)) |s| return s.full_deref_alias,
        .grouped => |inner| return inheritedFullDerefAlias(inner.*, state),
        else => {},
    }
    return false;
}

// Consume the move bindings used by-value in `expr` (checking liveness).
pub fn moveConsume(self: *Checker, expr: ast.Expr, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) void {
    switch (expr.kind) {
        .ident => |id| {
            if (state.getPtr(id.text)) |slot| {
                // T1.2: a pointer alias used by value (e.g. passed to a callee that reads
                // through it). The alias is not itself a linear resource — it is not
                // "moved" — so skip the move bookkeeping and only check it is not stale.
                if (slot.alias_of != null) {
                    checkStaleAlias(self, id.text, slot.*, expr.span, state);
                    return;
                }
                if (!slot.live) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "use of linear `move` value after it was moved");
                } else if (slot.escaped_borrow != null) {
                    // T1.2 (conservative rejection): a borrow of this value (or a subfield)
                    // was stored into memory we cannot prove dead (an aggregate field, an
                    // array element, or a sub-place alias). Reading through that borrow after
                    // the move would be a use-after-move we could not otherwise catch, so we
                    // refuse the move itself.
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "cannot move this linear `move` value: a borrow of it (or of one of its fields) has been stored into memory and may still be read; the move would leave that borrow dangling");
                    slot.live = false;
                } else if (slot.deferred) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "linear `move` value is reserved by a `defer` and cannot be moved");
                } else if (hasMovedSubplace(id.text, state)) {
                    // Moving the whole aggregate would also move the field already taken
                    // out of it — a duplicate move. (`forget_unchecked` discards the husk
                    // instead and goes through moveForget, which is allowed.)
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "linear `move` value used as a whole after one of its fields was moved out");
                    slot.live = false;
                } else {
                    slot.live = false;
                }
            }
        },
        .grouped => |inner| moveConsume(self, inner.*, state, aliases),
        .try_expr => |inner| {
            // `?` is an exit edge: on error it returns from the function. The operand's
            // `ok` payload is consumed and flows on; every *other* live `move` value
            // would leak on the error return unless it is registered with `defer`.
            moveConsume(self, inner.operand.*, state, aliases);
            checkMoveExitEdge(self, state, "linear `move` value is still live where `?` may return on error (consume it before `?`, or register it with `defer`)");
        },
        .cast => |c| moveConsume(self, c.value.*, state, aliases),
        .address_of => |inner| moveBorrow(self, inner.*, state),
        .member => |m| {
            moveBorrow(self, m.base.*, state); // the base must be live to take a field
            // (bug #3) Using a struct-field borrow alias (`h.p`) by value after its
            // referent was moved is a stale-alias use-after-move.
            if (aggregateFieldAliasSlot(self, expr, state)) |slot| {
                checkStaleAlias(self, "", slot, expr.span, state);
            }
            // Moving a `move`-typed field out of a tracked aggregate: poison the field
            // so a second move (or a borrow) of it is caught.
            if (moveFieldPlaceKey(self, expr, m, state, aliases)) |key| {
                if (state.contains(key)) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "use of linear `move` field after it was moved out");
                } else {
                    state.put(key, .{ .live = false, .span = expr.span }) catch {
                        self.oom = true;
                    };
                }
            }
        },
        .deref => |inner| {
            // Moving a linear `move` value out THROUGH a pointer deref (`own_free(T, *p)`)
            // is unsound: the checker tracks the owning *binding*, not the pointee, so it
            // can neither prevent a later free of that binding (a double-free) nor a use of
            // the now moved-from pointee. (Modeling it as a plain borrow — the old behavior —
            // let `own_free(T, *p); own_free(T, o)` compile into a double-free.) Reject the
            // move out of the alias; the owner must be moved directly. A non-move deref
            // (`f(*p)` for a scalar) is an ordinary borrow and still flows through.
            // Detect a move-out THROUGH an alias of a tracked move binding (`*p` where
            // `p = &o`): `aliasReferentOf` resolves `p` back to `o`, and only move
            // bindings/aliases live in `state`, so a scalar `*u32` deref never matches
            // (it stays a borrow). The type-based check is a fallback for derefs whose
            // result type the move Context can resolve (it cannot for local pointer vars).
            // A `full_deref_alias` (`p = &o`) makes `*p` the move binding itself, so consuming
            // it moves the resource out THROUGH the alias — reject (the type-based check below
            // cannot see this: the move Context does not carry local pointer-var types). A
            // derived alias (`p = f(&o)`, `p = &o.field`) is NOT flagged, so reading its
            // non-move pointee (`p.* + 1` on a `*mut u32`) stays an ordinary borrow.
            var full_alias = false;
            switch (inner.*.kind) {
                .ident => |id| if (state.get(id.text)) |s| {
                    full_alias = s.full_deref_alias;
                },
                else => {},
            }
            const moves_out = full_alias or exprIsMoveTyped(self, expr, state, aliases);
            if (moves_out) {
                self.errorCode(expr.span, "E_USE_AFTER_MOVE", "cannot move a linear `move` value out through a pointer deref; move the owning binding directly (the pointee would be left moved-from, which the checker cannot track through the alias)");
            } else {
                moveBorrow(self, inner.*, state);
            }
        },
        .index => |ix| {
            moveBorrow(self, ix.base.*, state);
            moveConsume(self, ix.index.*, state, aliases);
        },
        .call => |c| {
            // `drop(x)` is a safe discard for plain values, but on a linear `move`
            // value it consumes the binding while freeing nothing — a leak the
            // checker would otherwise bless. Reject it and point at the real options:
            // a release function, or `forget_unchecked` when the contents were already
            // transferred. (The argument is still consumed below so a single mistake
            // does not cascade into use-after-move noise.)
            if (spine.isDropCall(c.callee.*)) {
                for (c.args) |arg| {
                    // `#[trivial_drop]` move types may be safely `drop`ped (the author has
                    // asserted completion needs no release); every other linear resource
                    // must be released by its free function or `forget_unchecked` in unsafe.
                    if (exprIsMoveTyped(self, arg, state, aliases) and !exprIsTrivialDrop(self, arg, state, aliases)) {
                        self.errorCode(arg.span, "E_DROP_LINEAR_RESOURCE", "a linear `move` value cannot be `drop`ped (it frees nothing); release it with its free function, `forget_unchecked` it in an unsafe block once its contents have been transferred, or mark the type `#[trivial_drop]` if completing it needs no release");
                    }
                }
                for (c.args) |arg| moveConsume(self, arg, state, aliases);
            } else if (spine.isForgetUncheckedCall(c.callee.*)) {
                // Discard the husk wholesale — moved-out fields and all — so a partial
                // move is fine here (the aggregate is being thrown away, not reused).
                for (c.args) |arg| moveForget(self, arg, state, aliases);
            } else {
                // T1.3 (borrow-escape through a CALL argument). A struct/array literal argument
                // carrying `&<live-move-binding>` (`sink(.{ .p = &t })`, at any nesting depth)
                // launders the borrow into the callee — memory we cannot prove dead. The escape
                // scan, previously run only on decl/assignment initializers, runs here too: it
                // recurses through nested aggregate literals and marks the move root escaped, so
                // a later by-value move of the root is refused (E_USE_AFTER_MOVE). A direct
                // scalar `&t` arg (the legit transient borrow `pk(&t)`) takes NO move root from
                // markBorrowEscape unless it is *inside* an aggregate that escapes — only an
                // address-of laundered into memory marks the root, so `pk(&t); cn(t)` (borrow
                // dead at the call) still accepts.
                for (c.args) |arg| markBorrowEscapeCallArg(self, arg, c.callee.*.span, state);
                for (c.args) |arg| moveConsume(self, arg, state, aliases);
            }
        },
        .binary => |b| {
            moveConsume(self, b.left.*, state, aliases);
            moveConsume(self, b.right.*, state, aliases);
        },
        .unary => |u| moveConsume(self, u.expr.*, state, aliases),
        .struct_literal => |fields| for (fields) |f| moveConsume(self, f.value, state, aliases),
        .array_literal => |items| for (items) |item| moveConsume(self, item, state, aliases),
        else => {},
    }
}

// ----- place sensitivity: track a `move` field moved out of its aggregate -----
//
// The state is keyed by binding name; a one-level field move is recorded with a
// synthetic key `binding.field` whose presence means "this field has been moved out".
// This lets the checker reject a duplicate field move, a borrow of a moved-out field,
// and a whole-aggregate move after a field was taken (which would duplicate it).

// If `expr` is `<binding>.<field>` where the field is a `move` type and the base is a
// tracked move binding, return the place key `binding.field` (allocated once, owned by
// `move_place_keys`); otherwise null.
pub const PlaceKeyTy = struct { key: []const u8, ty: ast.TypeExpr };

// Build the dotted place key and leaf type for a place expression (`x`, `x.f`, `x.f.g`)
// whose root is a tracked move binding — so nested fields, not just one level, are
// distinct places. The key is allocated and owned by `move_place_keys`. Returns null if
// the root is not a tracked move binding or a field type cannot be resolved.
pub fn placeKeyAndType(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) ?PlaceKeyTy {
    switch (expr.kind) {
        .grouped => |inner| return placeKeyAndType(self, inner.*, state),
        .ident => |id| {
            const slot = state.get(id.text) orelse return null;
            const ty = slot.ty orelse return null;
            return .{ .key = id.text, .ty = ty }; // root key = binding name (AST-owned)
        },
        .member => |m| {
            const base = placeKeyAndType(self, m.base.*, state) orelse return null;
            const ctx = self.move_ctx orelse return null;
            const field_ty = spine.structFieldType(base.ty, m.name.text, ctx.*) orelse return null;
            const key = std.fmt.allocPrint(self.reporter.allocator, "{s}.{s}", .{ base.key, m.name.text }) catch {
                self.oom = true;
                return null;
            };
            self.move_place_keys.append(self.reporter.allocator, key) catch {
                self.oom = true;
            };
            return .{ .key = key, .ty = field_ty };
        },
        else => return null,
    }
}

// The place key for a `move`-typed field access (at any nesting depth), or null if the
// accessed place is not a tracked move field.
pub fn moveFieldPlaceKey(self: *Checker, expr: ast.Expr, m: anytype, state: *const std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) ?[]const u8 {
    _ = m;
    const pp = placeKeyAndType(self, expr, state) orelse return null;
    // A field is a move place if its type *embeds* a move resource by value — not only a
    // direct move type name, but also a `?move` / `Result<…move…,…>` field. Otherwise moving
    // such a wrapper field out of an aggregate would not poison the place, and a second
    // move of the same field (a double free) would go undetected. (Move-typed array fields
    // are rejected at declaration, so a place leaf is never an untrackable array.)
    if (!self.typeEmbedsMoveByValue(pp.ty, aliases)) return null;
    return pp.key;
}

// Whether the place denoted by `expr` (a possibly-nested field access) is recorded as
// moved out.
pub fn placeExprIsMoved(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) bool {
    const pp = placeKeyAndType(self, expr, state) orelse return false;
    return state.contains(pp.key);
}

// Whether any field of `base` has been moved out (a partial move of the aggregate).
pub fn hasMovedSubplace(base: []const u8, state: *const std.StringHashMap(MoveSlot)) bool {
    var it = state.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        if (k.len > base.len + 1 and std.mem.startsWith(u8, k, base) and k[base.len] == '.') return true;
    }
    return false;
}

// Remove every `base.field` place key when the whole aggregate leaves play (consumed or
// forgotten), so a later same-named binding starts clean.
pub fn clearSubplaces(base: []const u8, state: *std.StringHashMap(MoveSlot)) void {
    // Remove every `base.field…` subplace. A HashMap iterator is invalidated by a removal,
    // so rescan from the top after each one until none remain — rather than collecting into
    // a fixed-size batch, which would silently leave stale subplace state behind once an
    // aggregate had more moved-out fields than the batch could hold. The number of tracked
    // subplaces per function is tiny, so the repeated scan is cheap.
    var removed_any = true;
    while (removed_any) {
        removed_any = false;
        var it = state.iterator();
        while (it.next()) |entry| {
            const k = entry.key_ptr.*;
            if (k.len > base.len + 1 and std.mem.startsWith(u8, k, base) and k[base.len] == '.') {
                _ = state.remove(k);
                removed_any = true;
                break; // the iterator is now invalid; rescan with a fresh one
            }
        }
    }
}

// `forget_unchecked(x)` discards the whole aggregate husk: consume the binding and drop
// its field-move records (the husk is being thrown away, moved-out fields and all), so a
// partial move is fine here — unlike a real whole-aggregate move.
pub fn moveForget(self: *Checker, expr: ast.Expr, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) void {
    switch (expr.kind) {
        .ident => |id| {
            if (state.getPtr(id.text)) |slot| {
                if (!slot.live) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "use of linear `move` value after it was moved");
                } else if (slot.deferred) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "linear `move` value is reserved by a `defer` and cannot be moved");
                } else {
                    slot.live = false;
                }
            }
            clearSubplaces(id.text, state);
        },
        .grouped => |inner| moveForget(self, inner.*, state, aliases),
        else => moveConsume(self, expr, state, aliases),
    }
}

// Whether `expr` denotes a linear `move` value — a tracked move binding by name, or
// any expression whose inferred type is a move type. Used to reject `drop` of a
// resource.
pub fn exprIsMoveTyped(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
    switch (expr.kind) {
        .ident => |id| if (state.contains(id.text)) return true,
        .grouped => |inner| return exprIsMoveTyped(self, inner.*, state, aliases),
        else => {},
    }
    if (self.move_ctx) |mctx| {
        if (spine.exprResultType(expr, mctx.*)) |ty| {
            // Use the recursive predicate, not isMoveTypeName: a `?move`, `Result<…move…,…>`,
            // or array-of-move result also denotes a linear resource (so `drop` of it frees
            // nothing and leaks), even though the wrapper itself is not a move type *name*.
            if (self.typeEmbedsMoveByValue(ty, aliases)) return true;
        }
    }
    return false;
}

// Whether `drop(expr)` is a SAFE final use: expr's `move` type is `#[trivial_drop]`,
// so the author has asserted completing it needs no release. Looks the type up via the
// binding's recorded type (or the expression's inferred type).
pub fn exprIsTrivialDrop(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
    const set = self.trivial_drop_types orelse return false;
    const name = exprMoveTypeName(self, expr, state, aliases) orelse return false;
    return set.contains(name);
}

pub fn exprMoveTypeName(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) ?[]const u8 {
    switch (expr.kind) {
        .ident => |id| if (state.get(id.text)) |slot| {
            if (slot.ty) |t| return self.moveTypeNameOf(t, aliases);
        },
        .grouped => |inner| return exprMoveTypeName(self, inner.*, state, aliases),
        else => {},
    }
    if (self.move_ctx) |mctx| {
        if (spine.exprResultType(expr, mctx.*)) |ty| return self.moveTypeNameOf(ty, aliases);
    }
    return null;
}

// T1.2: if `name`'s slot is a pointer alias DERIVED from a tracked `move` binding (`let
// p = &a`), reading through it after the referent `a` was moved out is a stale-alias
// use-after-move. The alias slot itself stays live (a pointer copy is fine); it is the
// referent's moved-out state that poisons reads through the alias.
pub fn checkStaleAlias(self: *Checker, name: []const u8, slot: MoveSlot, span: diagnostics.Span, state: *const std.StringHashMap(MoveSlot)) void {
    _ = name;
    const referent = slot.alias_of orelse return;
    if (state.get(referent)) |r| {
        if (!r.live) {
            self.errorCode(span, "E_USE_AFTER_MOVE", "use of an alias derived from a linear `move` value after that value was moved (the alias is now stale)");
        }
    }
}

// T1.2 (conservative rejection): if `value` takes the address of a place rooted at a
// tracked move binding (`&t`, `&t.inner`, `&t[i]`, possibly via an alias), mark that
// binding's slot as having an escaped, reachable borrow stored at `escape_span`. A later
// by-value move of the binding is then refused (moveConsume), because the borrow lives in
// memory we cannot prove dead. The DIRECT scalar pointer-local case (`let p = &t`, which
// the stale-alias mechanism already tracks precisely) is handled by the caller NOT routing
// here — only stores into aggregate/array memory or subfield aliases reach this.
pub fn markBorrowEscape(self: *Checker, value: ast.Expr, escape_span: diagnostics.Span, state: *std.StringHashMap(MoveSlot)) void {
    // T1.2: an ARRAY-LITERAL initializer (`let arr: [1]*T = .{ &t }`) launders a borrow of a
    // move binding into array memory we cannot prove dead — symmetric with the `arr[0] = &t`
    // element-ASSIGNMENT path (which reaches this same hook) and the struct-literal field path.
    // Recurse into each element so the borrowed root is marked escaped and a later by-value
    // move of the root is refused. (Grouped wrappers are peeled here too.)
    switch (value.kind) {
        .array_literal => |items| {
            for (items) |item| markBorrowEscape(self, item, escape_span, state);
            return;
        },
        // T1.3: descend into a NESTED struct literal (`.{ .{ .p = &t } }`) too — a borrow
        // laundered into a struct that is itself an element/field of an outer aggregate
        // escapes into the same untrackable memory. The escape scan was previously flat
        // (it saw `&t` only at the TOP level of an array/struct literal); recursing through
        // nested aggregate/array literals closes the nested-aggregate channel, symmetric
        // with the one-level case. (Grouped wrappers are peeled below.)
        .struct_literal => |fields| {
            for (fields) |field| markBorrowEscape(self, field.value, escape_span, state);
            return;
        },
        // T1.3 ptr-to-int round-trip: taking the address of a linear `move` value and casting
        // it to an INTEGER (`&<move-value> as usize`) launders a borrow through an integer,
        // dropping the provenance the borrow tracker follows. We cannot track the integer (or
        // any pointer reconstituted from it), so the cast IS a borrow ESCAPE: mark the move
        // root escaped here so the later by-value move is refused (E_USE_AFTER_MOVE). NARROW
        // trigger — fires ONLY when an `&`/move-place is cast to an integer type. General
        // `usize as *T`, `&<non-move-local> as usize`, address arithmetic, and MMIO/DMA
        // address construction are unaffected (no `&<move-binding>` feeds the integer cast).
        //
        // Two parse shapes carry this (Pratt precedence makes `&` bind looser than `as`):
        //   * `&t as usize`   parses as `&(t as usize)` — an `address_of` of a cast of `t`.
        //   * `(&t) as usize` parses as `(&t) as usize` — a `cast` of an `address_of`.
        // The `.cast` arm handles the explicit-paren form; the `.address_of` arm (below) the
        // natural-precedence form.
        .cast => |c| {
            if (self.move_ctx) |mctx| {
                if (spine.isIntegerLike(spine.classifyTypeCtx(c.ty.*, mctx.*))) {
                    // `(&<move>) as int`: the cast operand is itself the `&<move>` borrow.
                    if (spine.borrowedMoveRoot(c.value.*, state)) |root| {
                        if (state.getPtr(root)) |slot| {
                            if (slot.escaped_borrow == null) slot.escaped_borrow = escape_span;
                        }
                        return;
                    }
                }
            }
            // Not a `&<move> as int` round-trip — a plain `<non-move> as T` cast (including the
            // pervasive `usize as *T` / integer-address-to-pointer direction) is NOT an escape.
            return;
        },
        .address_of => |inner| {
            // `&(<move-place> as int)`: address of a value cast from a move place into an
            // integer — the natural-precedence parse of `&t as usize`. The borrow's
            // provenance was already stripped by the integer cast, so the move root escapes.
            // Only THIS shape is handled here; any other `&…` (e.g. a sub-place borrow
            // `&t.v`) falls through to the default `borrowedMoveRoot` escape below.
            if (spine.castToIntegerMoveRoot(self, inner.*, state)) |root| {
                if (state.getPtr(root)) |slot| {
                    if (slot.escaped_borrow == null) slot.escaped_borrow = escape_span;
                }
                return;
            }
        },
        .grouped => |inner| return markBorrowEscape(self, inner.*, escape_span, state),
        else => {},
    }
    const root = spine.borrowedMoveRoot(value, state) orelse return;
    if (state.getPtr(root)) |slot| {
        if (slot.escaped_borrow == null) slot.escaped_borrow = escape_span;
    }
}

// T1.3 (borrow-escape through a CALL argument). Scan a call argument for a borrow of a live
// move binding that escapes into the callee. The escape rule for a call arg differs from the
// decl/assignment store: a BARE top-level `&t` argument is a transient borrow for the duration
// of the call (the legit `pk(&t); cn(t)` pattern), so it does NOT escape here — that direction
// is covered precisely by the pointer-returning-call laundering check (callLaunderedMoveRoot).
// What DOES escape is a borrow buried INSIDE an aggregate literal passed by value: the callee
// receives a copy of the struct/array containing `&t`, so the borrow reaches memory we cannot
// prove dead. We therefore descend into struct/array literal arguments (peeling `grouped`) and
// run the full recursive escape scan on the aggregate's contents — at any nesting depth.
pub fn markBorrowEscapeCallArg(self: *Checker, arg: ast.Expr, escape_span: diagnostics.Span, state: *std.StringHashMap(MoveSlot)) void {
    switch (arg.kind) {
        .grouped => |inner| return markBorrowEscapeCallArg(self, inner.*, escape_span, state),
        // An aggregate literal argument is copied into the callee — scan its contents (which
        // recurses through any further nested aggregate literals) for an escaping borrow.
        .struct_literal, .array_literal => return markBorrowEscape(self, arg, escape_span, state),
        // A bare `&t` / `&t.v` / `n = &t as usize` etc. as a top-level argument is a transient
        // borrow (or the ptr-to-int round-trip already handled at its decl); not escaped here.
        else => {},
    }
}

// Gap #2 [interprocedural borrow laundering] — conservative rejection, precise variant.
// `let q = f(&t)` (or `f(p)` where `p` aliases `t`) where `f` RETURNS A POINTER may launder
// a borrow of the `move` binding `t` out through its result `q` (the callee can `return`
// the argument). We cannot see what the callee does, so we conservatively treat `q` as a
// DERIVED ALIAS of `t` — registered into the same stale-alias machinery as `let p = &t`.
// A later move of `t` followed by a USE of `q` is then a stale-alias use-after-move
// (E_USE_AFTER_MOVE). Registering an alias (rather than eagerly marking `t` escaped) is what
// keeps the legitimate "borrow through a call, use it, THEN move once the result is dead"
// pattern compiling: if `q` is never read after the move, nothing fires.
//
// Returns the move-root `t` that a pointer-returning call's args borrow, or null. Narrowed
// to KNOWN pointer-returning direct calls so a non-pointer result (`pk(&t) -> u32`) — which
// cannot retain the borrow — does not register an alias and the legit case still accepts.
pub fn callLaunderedMoveRoot(self: *Checker, init_expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) ?[]const u8 {
    const ctx = self.move_ctx orelse return null;
    const call = switch (init_expr.kind) {
        .call => |c| c,
        .grouped => |inner| return callLaunderedMoveRoot(self, inner.*, state),
        .cast => |c| return callLaunderedMoveRoot(self, c.value.*, state),
        else => return null,
    };
    // `drop`/`forget_unchecked` are not borrow-laundering pointer factories.
    if (spine.isDropCall(call.callee.*) or spine.isForgetUncheckedCall(call.callee.*)) return null;
    const ret_ty = spine.directCallReturnType(call.callee.*, ctx.*) orelse return null;
    if (!spine.isPointerLike(spine.classifyTypeCtx(ret_ty, ctx.*))) return null;
    for (call.args) |arg| {
        const root = spine.borrowedMoveRoot(arg, state) orelse blk: {
            // an alias local `p` passed by value (→ its referent `t`)
            if (spine.aliasReferentOf(arg, state)) |referent| {
                if (state.contains(referent)) break :blk referent;
            }
            continue;
        };
        // Only register the laundered alias while the root is still LIVE. If it was already
        // moved, the borrow of it (the `&t` arg) is itself the use-after-move and is reported
        // by moveBorrow at the call — registering an alias here would double-report on the
        // later `q.*` use.
        if (state.getPtr(root)) |slot| {
            if (slot.live and slot.alias_of == null) return root;
        }
    }
    return null;
}

// (bug #3 / T1.3) Register field-place borrow aliases for a struct-literal initializer bound
// to `base`: for each field `.f = &t` whose `t` is a tracked move binding, record a slot keyed
// `base.f` with `alias_of = t` (a non-live borrow). Reading `base.f` after `t` is moved is
// then a stale-alias use-after-move (see moveBorrow `.member`).
//
// The scan RECURSES through nested struct literals: `.{ .h = .{ .p = &t } }` bound to `o`
// registers the dotted place `o.h.p -> t` (precise, reject-at-use), closing the
// struct-of-struct decl channel that one-level-deep tracking was leaving open. A field whose
// value is NOT a directly-trackable borrow or a nested struct literal (e.g. an ARRAY literal,
// where the place would be `o.f[i]` — not expressible as a dotted member key) is handled by
// the conservative escape scan the caller also runs (markBorrowEscape), so the borrow is never
// lost: precise where a dotted place exists, conservative (reject-at-move) otherwise.
pub fn registerAggregateFieldAliases(self: *Checker, base: []const u8, escape_span: diagnostics.Span, init_expr: ast.Expr, state: *std.StringHashMap(MoveSlot)) void {
    const fields = switch (init_expr.kind) {
        .struct_literal => |f| f,
        .grouped => |inner| return registerAggregateFieldAliases(self, base, escape_span, inner.*, state),
        else => return,
    };
    for (fields) |field| {
        // A nested struct literal: descend so a borrow buried at `base.f.g…` is tracked at its
        // dotted place. The dotted `key` is owned by `move_place_keys` (so the recursive call
        // can borrow it as the new base, and it is freed at function end).
        if (fieldExprIsStructLiteral(field.value)) {
            const key = std.fmt.allocPrint(self.reporter.allocator, "{s}.{s}", .{ base, field.name.text }) catch {
                self.oom = true;
                continue;
            };
            self.move_place_keys.append(self.reporter.allocator, key) catch {
                self.oom = true;
                self.reporter.allocator.free(key);
                continue;
            };
            registerAggregateFieldAliases(self, key, escape_span, field.value, state);
            continue;
        }
        // A field whose value is NOT a directly-trackable scalar borrow (`&t`/an alias of it)
        // — e.g. an array literal `.{ .arr = .{ &t } }`, where the place would be `arr[i]`, not
        // nameable as a dotted member key. We cannot prove such a place dead, so fall back to
        // the CONSERVATIVE escape: mark the move root escaped (reject-at-move). This composes
        // the precise and conservative scans in one traversal so no nested borrow is lost.
        // (A plain non-borrow field value `.v = 5` has no move root, so this is a no-op there.)
        const referent = spine.aliasReferentOf(field.value, state) orelse {
            markBorrowEscape(self, field.value, escape_span, state);
            continue;
        };
        if (!state.contains(referent)) continue;
        const key = std.fmt.allocPrint(self.reporter.allocator, "{s}.{s}", .{ base, field.name.text }) catch {
            self.oom = true;
            continue;
        };
        self.move_place_keys.append(self.reporter.allocator, key) catch {
            self.oom = true;
            self.reporter.allocator.free(key);
            continue;
        };
        state.put(key, .{ .live = false, .span = field.value.span, .alias_of = referent }) catch {
            self.oom = true;
        };
    }
}

// Whether a struct-literal field value is itself a (possibly grouped) struct literal — the
// recursion gate for registerAggregateFieldAliases' nested-place descent.
pub fn fieldExprIsStructLiteral(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .struct_literal => true,
        .grouped => |inner| fieldExprIsStructLiteral(inner.*),
        else => false,
    };
}

// (bug #3) If `expr` is a member access `base.f…` whose place-key names a registered
// field-place borrow alias, return its slot — for the stale-alias check on member reads.
pub fn aggregateFieldAliasSlot(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) ?MoveSlot {
    const key = memberPlaceKey(self, expr) orelse return null;
    defer self.reporter.allocator.free(key);
    if (state.get(key)) |slot| {
        if (slot.alias_of != null) return slot;
    }
    return null;
}

// The dotted place key for a member access over a bare-ident root (`base.f.g`), allocated
// for the caller to free. Null if the root is not a bare ident.
pub fn memberPlaceKey(self: *Checker, expr: ast.Expr) ?[]const u8 {
    switch (expr.kind) {
        .grouped => |inner| return memberPlaceKey(self, inner.*),
        .ident => |id| return self.reporter.allocator.dupe(u8, id.text) catch {
            self.oom = true;
            return null;
        },
        .member => |m| {
            const base = memberPlaceKey(self, m.base.*) orelse return null;
            defer self.reporter.allocator.free(base);
            return std.fmt.allocPrint(self.reporter.allocator, "{s}.{s}", .{ base, m.name.text }) catch {
                self.oom = true;
                return null;
            };
        },
        else => return null,
    }
}

// Borrow: check the move bindings referenced are live, without consuming.
pub fn moveBorrow(self: *Checker, expr: ast.Expr, state: *std.StringHashMap(MoveSlot)) void {
    switch (expr.kind) {
        .ident => |id| {
            if (state.getPtr(id.text)) |slot| {
                if (slot.alias_of != null) {
                    checkStaleAlias(self, id.text, slot.*, expr.span, state);
                } else if (!slot.live) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "borrow of linear `move` value after it was moved");
                }
            }
        },
        .grouped, .address_of, .deref => |inner| moveBorrow(self, inner.*, state),
        .try_expr => |inner| {
            // `?` is an exit edge even in a borrow position: on error it returns, so any
            // other live `move` value would leak unless registered with `defer`.
            moveBorrow(self, inner.operand.*, state);
            checkMoveExitEdge(self, state, "linear `move` value is still live where `?` may return on error (consume it before `?`, or register it with `defer`)");
        },
        .member => |m| {
            moveBorrow(self, m.base.*, state);
            // (bug #3) Reading a struct-field borrow alias (`h.p` from `let h=.{.p=&t}`)
            // after its referent `t` was moved is a stale-alias use-after-move.
            if (aggregateFieldAliasSlot(self, expr, state)) |slot| {
                checkStaleAlias(self, "", slot, expr.span, state);
            }
            // Borrowing a field (at any nesting depth) that was already moved out is a
            // use-after-move.
            if (placeExprIsMoved(self, expr, state)) {
                self.errorCode(expr.span, "E_USE_AFTER_MOVE", "borrow of linear `move` field after it was moved out");
            }
        },
        .index => |ix| moveBorrow(self, ix.base.*, state),
        .cast => |c| moveBorrow(self, c.value.*, state),
        .call => |c| for (c.args) |arg| moveBorrow(self, arg, state),
        else => {},
    }
}

// `defer <expr>`: reserve the move bindings the deferred expr will consume.
pub fn moveDefer(self: *Checker, expr: ast.Expr, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) void {
    switch (expr.kind) {
        .ident => |id| {
            if (state.getPtr(id.text)) |slot| {
                if (!slot.live) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "defer consumes a linear `move` value already moved");
                } else {
                    slot.deferred = true;
                }
            }
        },
        .grouped => |inner| moveDefer(self, inner.*, state, aliases),
        .call => |c| for (c.args) |arg| moveDefer(self, arg, state, aliases),
        .member => |m| {
            moveBorrow(self, m.base.*, state);
            // `defer free(p.field)`: reserve the move field for lexical cleanup so it is
            // neither leaked at exit nor moved out before the defer runs.
            if (moveFieldPlaceKey(self, expr, m, state, aliases)) |key| {
                if (state.contains(key)) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "defer reserves a linear `move` field already moved out");
                } else {
                    state.put(key, .{ .live = true, .span = expr.span, .deferred = true }) catch {
                        self.oom = true;
                    };
                }
            }
        },
        else => {},
    }
}
