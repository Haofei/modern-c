//! Linear `move` / borrow checker — the move-linearity analysis pass.
//!
//! Extracted verbatim from `sema.zig` (Phase 2b, pure structure, zero behavior
//! change). These were `Checker` methods; they now live here as free functions
//! taking `self: *Checker`, called from the spine as `sema_move.checkMoveLinearity(self, ...)`.
//! Phase 3 will rewrite this pass over a proper CFG; isolating it now is the point.

const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const array_len = @import("array_len.zig");
const diagnostics = @import("diagnostics.zig");
const sema_type = @import("sema_type.zig");

const sema = @import("sema.zig");
const spine = sema;
const Checker = sema.Checker;
const MoveSlot = sema.MoveSlot;
const LoopMoveFrame = sema.LoopMoveFrame;
const Context = sema.Context;
const parseArrayLen = array_len.parseArrayLen;
const resolveAliasType = sema_type.resolveAliasType;

const ArrayMoveShape = struct { len: usize, embeds: bool };

pub fn checkMoveLinearity(self: *Checker, fn_decl: ast.FnDecl, aliases: *const std.StringHashMap(ast.TypeExpr)) void {
    const body = fn_decl.body orelse return;
    var state = std.StringHashMap(MoveSlot).init(self.reporter.allocator);
    defer state.deinit();
    defer {
        for (self.move_place_keys.items) |k| self.reporter.allocator.free(k);
        self.move_place_keys.clearRetainingCapacity();
    }
    for (fn_decl.params) |param| {
        if (self.typeEmbedsMoveByValue(param.ty, aliases)) {
            state.put(param.name.text, .{ .live = true, .span = param.name.span, .place = .{ .root = param.name.text }, .ty = param.ty }) catch {
                self.oom = true;
            };
        } else if (isUsizeType(param.ty)) {
            state.put(param.name.text, .{ .live = false, .span = param.name.span, .symbolic_index = param.name.text }) catch {
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
        if (isTrackedMoveSubplace(entry.value_ptr.*, entry.key_ptr.*) and !state.contains(entry.key_ptr.*)) {
            continue;
        }
        const slot = state.get(entry.key_ptr.*) orelse entry.value_ptr.*;
        scoped.put(entry.key_ptr.*, slot) catch {
            self.oom = true;
        };
    }
    var state_it = state.iterator();
    while (state_it.next()) |entry| {
        if (before.contains(entry.key_ptr.*)) continue;
        if (!moveSubplaceRootInOuter(entry.value_ptr.*, entry.key_ptr.*, &before)) continue;
        scoped.put(entry.key_ptr.*, entry.value_ptr.*) catch {
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

pub fn reportLoopOuterResourceChanges(self: *Checker, entry_state: *std.StringHashMap(MoveSlot), iteration_state: *const std.StringHashMap(MoveSlot)) void {
    var index_fact_removals: std.ArrayListUnmanaged([]const u8) = .empty;
    defer index_fact_removals.deinit(self.reporter.allocator);

    var it = entry_state.iterator();
    while (it.next()) |entry| {
        const after = iteration_state.get(entry.key_ptr.*) orelse {
            if (isPureIndexFactSlot(entry.value_ptr.*)) {
                index_fact_removals.append(self.reporter.allocator, entry.key_ptr.*) catch {
                    self.oom = true;
                };
            }
            continue;
        };
        const before = entry.value_ptr.*;
        if (before.live != after.live or before.deferred != after.deferred or !sameMaybeKey(before.deferred_borrow, after.deferred_borrow) or !sameMaybePlace(before.deferred_borrow_place, after.deferred_borrow_place)) {
            self.errorCode(before.span, "E_MOVE_LOOP_RESOURCE", "cannot consume or reserve an outer linear `move` value inside a loop; the loop may run zero or multiple times");
            entry.value_ptr.live = false;
            entry.value_ptr.deferred = false;
            entry.value_ptr.deferred_borrow = null;
            entry.value_ptr.deferred_borrow_place = null;
        } else if (!sameAliasFact(before, after)) {
            entry.value_ptr.* = divergentAliasSlot(entry.key_ptr.*, before);
        } else if (isPureIndexFactSlot(before) and !sameIndexFact(before, after)) {
            index_fact_removals.append(self.reporter.allocator, entry.key_ptr.*) catch {
                self.oom = true;
            };
        }
    }
    for (index_fact_removals.items) |k| _ = entry_state.remove(k);

    var iter_it = iteration_state.iterator();
    while (iter_it.next()) |entry| {
        if (entry_state.contains(entry.key_ptr.*)) continue;
        const root = trackedSubplaceRoot(entry.value_ptr.*, entry.key_ptr.*) orelse continue;
        if (entry_state.getPtr(root)) |root_slot| {
            self.errorCode(entry.value_ptr.span, "E_MOVE_LOOP_RESOURCE", "cannot move an outer linear `move` place inside a loop; the loop may run zero or multiple times");
            root_slot.live = false;
            root_slot.deferred = false;
            root_slot.escaped_borrow = null;
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
            state.put(ident.text, .{ .live = true, .span = ident.span, .place = .{ .root = ident.text }, .ty = payload_ty }) catch {
                self.oom = true;
            };
            return ident.text;
        },
        .tag_bind => |node| {
            const payload_ty = spine.resultPayloadType(value_ty, node.tag.text) orelse return null;
            if (!self.typeEmbedsMoveByValue(payload_ty, aliases)) return null;
            state.put(node.binding.text, .{ .live = true, .span = node.binding.span, .place = .{ .root = node.binding.text }, .ty = payload_ty }) catch {
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
                    if (self.typeEmbedsMoveByValue(ty, aliases)) {
                        // A binding whose type embeds a `move` resource by value — a `move`
                        // struct, a `Result<…move…, …>`, or a `?move` — must be consumed.
                        state.put(decl.names[0].text, .{ .live = true, .span = decl.names[0].span, .place = .{ .root = decl.names[0].text }, .ty = ty }) catch {
                            self.oom = true;
                        };
                        bound_as_move = true;
                    }
                }
            }
            var bound_as_index_fact = false;
            if (!bound_as_move and decl.names.len > 0 and decl.init != null and isUsizeType(binding_ty)) {
                if (self.move_ctx) |mctx| {
                    if (constIndexValue(self, decl.init.?, state, mctx.*)) |index| {
                        state.put(decl.names[0].text, .{ .live = false, .span = decl.names[0].span, .const_index = index }) catch {
                            self.oom = true;
                        };
                        bound_as_index_fact = true;
                    } else if (symbolicIndexValue(self, decl.init.?, state, mctx.*)) |symbol| {
                        state.put(decl.names[0].text, .{ .live = false, .span = decl.names[0].span, .symbolic_index = symbol }) catch {
                            self.oom = true;
                        };
                        bound_as_index_fact = true;
                    }
                }
            }
            if (!bound_as_move and !bound_as_index_fact and decl.names.len > 0) {
                if (binding_ty) |ty| {
                    if (retainsAliasPlaceType(ty)) {
                        state.put(decl.names[0].text, .{ .live = false, .span = decl.names[0].span, .ty = ty, .type_only = true }) catch {
                            self.oom = true;
                        };
                    }
                }
            }
            // T1.2: `let p = &a;` where `a` is a tracked `move` binding records `p` as a
            // DERIVED alias of `a`. Reading through `p` after `a` is moved is then a stale
            // use-after-move (see moveBorrow/moveConsume). A pointer alias is a borrow, not
            // a by-value resource, so it is only registered when the binding was not already
            // classed as a move resource above.
            if (!bound_as_move and !bound_as_index_fact and decl.names.len > 0 and decl.init != null) {
                if (aliasReferentForExpr(self, decl.init.?, state, aliases)) |referent| {
                    // Gap #2: `let q = f(&t)` where `f` returns a pointer — `q` may alias a
                    // borrow of the move binding `t`, or a tracked subplace such as `t.a`,
                    // laundered through the callee's result.
                    // Register it as a derived alias so a USE of `q` after `t` is moved is a
                    // stale-alias use-after-move (and nothing fires if `q` is dead first).
                    if (aliasReferentIsTracked(referent, state)) {
                        // `live = false`: the alias is a borrow, not a linear resource, so
                        // leak/exit checks (which only fire on `live` slots) must skip it.
                        // Its referent's moved-out state is what the stale check consults.
                        state.put(decl.names[0].text, .{ .live = false, .span = decl.names[0].span, .place = .{ .root = decl.names[0].text }, .alias_of = referent.key, .alias_place = referent.place, .full_deref_alias = referent.full_deref }) catch {
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
                    registerAggregateFieldAliases(self, decl.names[0].text, .{ .root = decl.names[0].text }, decl.names[0].span, decl.init.?, state, aliases);
                } else if (decl.init.?.kind == .array_literal) {
                    registerArrayElementAliases(self, decl.names[0].text, .{ .root = decl.names[0].text }, decl.names[0].span, decl.init.?, state, aliases);
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
            if (decl.names.len > 0 and decl.init != null) {
                markBorrowEscapeCapturedCallResult(self, decl.init.?, decl.names[0].span, state, aliases);
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
                    const had_slot = state.contains(id.text);
                    const was_alias = if (state.getPtr(id.text)) |slot| slot.alias_of != null else false;
                    const target_can_store_alias = if (self.move_ctx) |mctx|
                        exprCanStoreBorrowAlias(a.target, mctx.*)
                    else
                        false;
                    if (state.getPtr(id.text)) |slot| {
                        if (slot.live and !slot.deferred) {
                            self.errorCode(a.target.span, "E_RESOURCE_OVERWRITE", "cannot overwrite a live linear `move` value; consume it first");
                        } else if (slot.deferred) {
                            self.errorCode(a.target.span, "E_USE_AFTER_MOVE", "linear `move` value is reserved by a `defer` and cannot be reassigned");
                        }
                    }
                    moveConsume(self, a.value, state, aliases);
                    markBorrowEscapeCapturedCallResult(self, a.value, a.target.span, state, aliases);
                    if (was_alias or target_can_store_alias or !had_slot) {
                        // Re-derive the alias from the RHS: `p = &t2` keeps `p` a borrow
                        // (live=false) now aliasing `t2`, so it does not leak at exit and
                        // its stale-after-move tracking follows the NEW referent. If the RHS
                        // is not an alias of a tracked move binding, drop the slot entirely
                        // (it is no longer a meaningful borrow); leaving it live would be the
                        // phantom-leak false positive this fixes.
                        if (aliasReferentForExpr(self, a.value, state, aliases)) |referent| {
                            if (aliasReferentIsTracked(referent, state)) {
                                if (state.getPtr(id.text)) |slot| {
                                    slot.alias_of = referent.key;
                                    slot.alias_place = referent.place;
                                    slot.live = false;
                                    slot.full_deref_alias = referent.full_deref;
                                } else {
                                    state.put(id.text, .{ .live = false, .span = a.target.span, .place = .{ .root = id.text }, .alias_of = referent.key, .alias_place = referent.place, .full_deref_alias = referent.full_deref }) catch {
                                        self.oom = true;
                                    };
                                }
                            } else {
                                _ = state.remove(id.text);
                            }
                        } else if (state.contains(id.text)) {
                            _ = state.remove(id.text);
                        }
                    } else if (state.getPtr(id.text)) |slot| {
                        const next_const_index = if (self.move_ctx) |mctx|
                            constIndexValue(self, a.value, state, mctx.*)
                        else
                            null;
                        if (next_const_index) |index| {
                            slot.const_index = index;
                            slot.symbolic_index = null;
                            slot.live = false;
                            slot.ty = null;
                            slot.type_only = false;
                            slot.alias_of = null;
                            slot.alias_place = null;
                            slot.escaped_borrow = null;
                            slot.full_deref_alias = false;
                        } else if (if (self.move_ctx) |mctx| symbolicIndexValue(self, a.value, state, mctx.*) else null) |symbol| {
                            slot.const_index = null;
                            slot.symbolic_index = symbol;
                            slot.live = false;
                            slot.ty = null;
                            slot.type_only = false;
                            slot.alias_of = null;
                            slot.alias_place = null;
                            slot.escaped_borrow = null;
                            slot.full_deref_alias = false;
                        } else if ((slot.const_index != null or slot.symbolic_index != null) and slot.ty == null and slot.alias_of == null) {
                            _ = state.remove(id.text);
                        } else if (slot.type_only) {
                            slot.live = false;
                            slot.symbolic_index = null;
                            slot.alias_of = null;
                            slot.alias_place = null;
                            slot.escaped_borrow = null;
                            slot.full_deref_alias = false;
                        } else {
                            slot.live = true;
                            slot.const_index = null;
                            slot.symbolic_index = null;
                        }
                    }
                },
                .member => |m| {
                    // Assigning through `p.field`: the base must be live, and overwriting a
                    // live `move` field (one not already moved out) would drop the old
                    // resource without consuming it.
                    moveBorrow(self, m.base.*, state, aliases);
                    const place_opt = moveFieldPlaceKey(self, a.target, m, state, aliases);
                    if (place_opt) |pp| {
                        if (hasMovedSubplace(pp.place, state)) {
                            self.errorCode(a.target.span, "E_USE_AFTER_MOVE", "cannot overwrite a partially moved linear `move` field; consume or discard the owner instead");
                        } else if (!stateContainsMovePlace(pp.place, state)) {
                            self.errorCode(a.target.span, "E_RESOURCE_OVERWRITE", "cannot overwrite a live linear `move` field; consume it first");
                        }
                    }
                    moveConsume(self, a.value, state, aliases);
                    markBorrowEscapeCapturedCallResult(self, a.value, a.target.span, state, aliases);
                    if (place_opt) |pp| {
                        _ = state.remove(pp.key); // the field now holds a fresh live resource
                    }
                    recordAssignedAggregateFieldAliasOrEscape(self, a.target, a.value, a.target.span, state, aliases);
                },
                .index => |ix| {
                    moveBorrow(self, ix.base.*, state, aliases);
                    moveConsume(self, ix.index.*, state, aliases);
                    if (moveIndexedPlaceKey(self, a.target, state, aliases)) |pp| {
                        if (indexedPlaceHasWildcardMove(self, a.target, state, aliases) or stateHasConflictingMovePlace(pp.place, state)) {
                            self.errorCode(a.target.span, "E_USE_AFTER_MOVE", "cannot reinitialize a concrete array element after an unknown dynamic element was moved out");
                        } else if (!stateContainsMovePlace(pp.place, state)) {
                            self.errorCode(a.target.span, "E_RESOURCE_OVERWRITE", "cannot overwrite a live linear `move` array element; consume it first");
                        }
                        moveConsume(self, a.value, state, aliases);
                        markBorrowEscapeCapturedCallResult(self, a.value, a.target.span, state, aliases);
                        _ = state.remove(pp.key);
                    } else if (wildcardMoveIndexedPlaceKey(self, a.target, state, aliases)) |pp| {
                        if (stateContainsMovePlace(pp.place, state) or stateHasConflictingMovePlace(pp.place, state)) {
                            self.errorCode(a.target.span, "E_USE_AFTER_MOVE", "cannot assign a linear `move` array element through an unknown dynamic index after an overlapping element was moved out");
                        } else {
                            self.errorCode(a.target.span, "E_RESOURCE_OVERWRITE", "cannot assign a linear `move` array element through an unknown dynamic index; the selected live element must be consumed first");
                        }
                        markBorrowEscapeCapturedCallResult(self, a.value, a.target.span, state, aliases);
                        moveConsume(self, a.value, state, aliases);
                    } else if (arrayIndexEmbedsMove(self, a.target, state, aliases)) {
                        self.errorCode(a.target.span, "E_MOVE_ARRAY_UNSUPPORTED", "cannot assign a linear `move` array element through a non-constant index; element ownership is only tracked for constant indexes");
                        markBorrowEscapeCapturedCallResult(self, a.value, a.target.span, state, aliases);
                        moveConsume(self, a.value, state, aliases);
                    } else {
                        recordAssignedAliasPlaceOrEscape(self, a.target, a.value, a.target.span, state, aliases);
                        markBorrowEscapeCapturedCallResult(self, a.value, a.target.span, state, aliases);
                        moveConsume(self, a.value, state, aliases);
                    }
                },
                else => {
                    // T1.2: `arr[0] = &t` (or any non-ident lvalue) stores a borrow of `t`
                    // into memory; mark `t` borrow-escaped. (Plain scalar `p = &t` is the
                    // `.ident` arm above — tracked precisely by the stale-alias mechanism —
                    // and is deliberately NOT routed here.)
                    markBorrowEscape(self, a.value, a.target.span, state);
                    markBorrowEscapeCapturedCallResult(self, a.value, a.target.span, state, aliases);
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
            moveBorrow(self, e, state, aliases);
            return false;
        },
        .block, .unsafe_block, .comptime_block => |b| return moveScopedBlock(self, b, state, aliases),
        .contract_block => |c| return moveScopedBlock(self, c.block, state, aliases),
        .loop => |l| {
            if (l.iterable) |iter| {
                switch (l.kind) {
                    .@"for" => moveBorrow(self, iter, state, aliases),
                    .@"while" => {
                        var condition_state = cloneMoveState(self, state);
                        defer condition_state.deinit();
                        moveConsume(self, iter, &condition_state, aliases);
                        reportLoopOuterResourceChanges(self, state, &condition_state);
                    },
                }
            }
            // Snapshot loop entry so a `break`/`continue` inside the body can tell
            // loop-body locals (which leak on an early exit) from outer resources, and
            // compare outer move/place ownership on that early-exit edge.
            var frame = LoopMoveFrame{
                .label = if (l.loop_label) |label| label.text else null,
                .entry_names = std.StringHashMap(void).init(self.reporter.allocator),
                .entry_state = cloneMoveState(self, state),
                .invalidated_const_indexes = std.StringHashMap(void).init(self.reporter.allocator),
                .invalidated_aliases = std.StringHashMap(void).init(self.reporter.allocator),
            };
            var snap_it = state.iterator();
            while (snap_it.next()) |e| {
                frame.entry_names.put(e.key_ptr.*, {}) catch {
                    self.oom = true;
                };
            }
            self.move_loop_stack.append(self.reporter.allocator, frame) catch {
                self.oom = true;
                frame.deinit();
            };
            var body_state = cloneMoveState(self, state);
            defer body_state.deinit();
            const body_diverges = moveBlock(self, l.body, &body_state, aliases);
            if (self.move_loop_stack.pop()) |popped| {
                var p = popped;
                applyLoopEarlyExitConstIndexInvalidations(state, &p);
                applyLoopEarlyExitAliasInvalidations(state, &p);
                p.deinit();
            }
            if (!body_diverges) {
                reportMoveLocalsLeavingScope(self, &body_state, state, "linear `move` value declared in a loop body is never consumed (must be moved, returned, or freed before the iteration ends)");
                reportLoopOuterResourceChanges(self, state, &body_state);
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
                                arm_state.put(id.text, .{ .live = true, .span = id.span, .place = .{ .root = id.text }, .ty = pty }) catch {
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
        .@"break" => |target| {
            checkLoopExitLeaks(self, state, target);
            return true; // the rest of the loop body is unreachable
        },
        .@"continue" => |target| {
            checkLoopExitLeaks(self, state, target);
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
        if (moveSubplaceRootInOuter(entry.value_ptr.*, entry.key_ptr.*, outer)) continue;
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
pub fn checkLoopExitLeaks(self: *Checker, state: *std.StringHashMap(MoveSlot), target: ?ast.Ident) void {
    const frame = moveLoopTargetFrame(self, target) orelse return;
    // `break`/`continue` is terminal in its block, so this is the only visit; we do
    // NOT clear the slot, which would corrupt the live state the enclosing branch
    // merges back (producing spurious branch-mismatch / use-after-move downstream).
    var it = state.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.live and !entry.value_ptr.deferred and !frame.entry_names.contains(entry.key_ptr.*)) {
            self.errorCode(entry.value_ptr.span, "E_RESOURCE_LEAK", "linear `move` value declared in a loop body is never consumed before this `break`/`continue` exits the iteration");
        }
    }
    var entry_state = cloneMoveState(self, &frame.entry_state);
    defer entry_state.deinit();
    reportLoopOuterResourceChanges(self, &entry_state, state);
    recordLoopEarlyExitConstIndexInvalidations(self, frame, state);
}

// Semantic checking already rejects a missing loop label. The move pass resolves
// the same target so ownership checks run on the actual control-flow edge rather
// than accidentally treating `break :outer` as an exit from the inner loop.
fn moveLoopTargetFrame(self: *Checker, target: ?ast.Ident) ?*LoopMoveFrame {
    if (self.move_loop_stack.items.len == 0) return null;
    if (target) |label| {
        var i = self.move_loop_stack.items.len;
        while (i > 0) {
            i -= 1;
            const frame = &self.move_loop_stack.items[i];
            if (frame.label) |name| {
                if (std.mem.eql(u8, name, label.text)) return frame;
            }
        }
        return null;
    }
    return &self.move_loop_stack.items[self.move_loop_stack.items.len - 1];
}

fn recordLoopEarlyExitConstIndexInvalidations(self: *Checker, frame: *LoopMoveFrame, state: *const std.StringHashMap(MoveSlot)) void {
    var it = frame.entry_state.iterator();
    while (it.next()) |entry| {
        const before = entry.value_ptr.*;
        if (!isPureIndexFactSlot(before) and before.alias_of == null) continue;
        const after = state.get(entry.key_ptr.*) orelse {
            if (isPureIndexFactSlot(before)) {
                frame.invalidated_const_indexes.put(entry.key_ptr.*, {}) catch {
                    self.oom = true;
                };
            } else {
                frame.invalidated_aliases.put(entry.key_ptr.*, {}) catch {
                    self.oom = true;
                };
            }
            continue;
        };
        if (isPureIndexFactSlot(before) and (!isPureIndexFactSlot(after) or !sameIndexFact(before, after))) {
            frame.invalidated_const_indexes.put(entry.key_ptr.*, {}) catch {
                self.oom = true;
            };
        } else if (before.alias_of != null and !sameAliasFact(before, after)) {
            frame.invalidated_aliases.put(entry.key_ptr.*, {}) catch {
                self.oom = true;
            };
        }
    }
}

fn applyLoopEarlyExitConstIndexInvalidations(state: *std.StringHashMap(MoveSlot), frame: *const LoopMoveFrame) void {
    var it = frame.invalidated_const_indexes.keyIterator();
    while (it.next()) |name| _ = state.remove(name.*);
}

fn applyLoopEarlyExitAliasInvalidations(state: *std.StringHashMap(MoveSlot), frame: *const LoopMoveFrame) void {
    var it = frame.invalidated_aliases.keyIterator();
    while (it.next()) |name| {
        if (state.getPtr(name.*)) |slot| {
            slot.* = divergentAliasSlot(name.*, slot.*);
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
            } else if (isTrackedMoveSubplace(entry.value_ptr.*, entry.key_ptr.*)) {
                self.errorCode(entry.value_ptr.span, "E_MOVE_BRANCH_MISMATCH", "linear `move` field has inconsistent ownership across control-flow branches");
                merged.put(entry.key_ptr.*, entry.value_ptr.*) catch {
                    self.oom = true;
                };
            }
            continue;
        };
        var slot = entry.value_ptr.*;
        if (slot.live != other.live or slot.deferred != other.deferred or !sameMaybeKey(slot.deferred_borrow, other.deferred_borrow) or !sameMaybePlace(slot.deferred_borrow_place, other.deferred_borrow_place)) {
            self.errorCode(slot.span, "E_MOVE_BRANCH_MISMATCH", "linear `move` value has inconsistent ownership across control-flow branches");
            slot.live = false;
            slot.deferred = false;
            slot.deferred_borrow = null;
            slot.deferred_borrow_place = null;
        } else if (!sameAliasFact(slot, other)) {
            slot = divergentAliasSlot(entry.key_ptr.*, slot);
        } else if (isPureIndexFactSlot(slot) and !sameIndexFact(slot, other)) {
            continue;
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
        } else if (isTrackedMoveSubplace(entry.value_ptr.*, entry.key_ptr.*)) {
            self.errorCode(entry.value_ptr.span, "E_MOVE_BRANCH_MISMATCH", "linear `move` field has inconsistent ownership across control-flow branches");
            merged.put(entry.key_ptr.*, entry.value_ptr.*) catch {
                self.oom = true;
            };
        }
    }

    replaceMoveState(self, dest, &merged);
}

fn sameAliasFact(left: MoveSlot, right: MoveSlot) bool {
    if (left.alias_of == null and right.alias_of == null) return true;
    if (left.alias_of == null or right.alias_of == null) return false;
    return std.mem.eql(u8, left.alias_of.?, right.alias_of.?) and
        sameMaybePlace(left.alias_place, right.alias_place) and
        left.full_deref_alias == right.full_deref_alias;
}

fn divergentAliasSlot(key: []const u8, source: MoveSlot) MoveSlot {
    return .{
        .live = false,
        .span = source.span,
        .alias_of = key,
        .cleanup_local = source.cleanup_local,
    };
}

fn isMoveSubplaceKey(key: []const u8) bool {
    return firstSubplaceSeparator(key) != null;
}

fn isTrackedMoveSubplace(slot: MoveSlot, key: []const u8) bool {
    return if (slot.place) |place| place.isSubplace() else isMoveSubplaceKey(key);
}

fn moveSubplaceRootInOuter(slot: MoveSlot, key: []const u8, outer: *const std.StringHashMap(MoveSlot)) bool {
    if (slot.place) |place| return outer.contains(place.root);
    const sep = firstSubplaceSeparator(key) orelse return false;
    return outer.contains(key[0..sep]);
}

fn trackedSubplaceRoot(slot: MoveSlot, key: []const u8) ?[]const u8 {
    if (slot.place) |place| return if (place.isSubplace()) place.root else null;
    const sep = firstSubplaceSeparator(key) orelse return null;
    return key[0..sep];
}

fn firstSubplaceSeparator(key: []const u8) ?usize {
    for (key, 0..) |c, i| {
        if (isSubplaceSeparator(c)) return i;
    }
    return null;
}

fn isSubplaceSeparator(c: u8) bool {
    return c == '.' or c == '[';
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

fn checkAggregateAliasArgument(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) void {
    const key = aliasPlaceKey(self, expr, state) orelse memberPlaceKey(self, expr) orelse return;
    defer self.reporter.allocator.free(key);
    const place = aliasStoragePlaceForExpr(self, expr, state);
    var it = state.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.alias_of == null) continue;
        if (place) |arg_place| {
            if (entry.value_ptr.place) |slot_place| {
                if (!slot_place.eql(arg_place) and !arg_place.isPrefixOf(slot_place)) continue;
                checkStaleAlias(self, "", entry.value_ptr.*, expr.span, state);
                continue;
            }
        }
        if (!std.mem.eql(u8, entry.key_ptr.*, key) and !isPlacePrefix(key, entry.key_ptr.*)) continue;
        checkStaleAlias(self, "", entry.value_ptr.*, expr.span, state);
    }
}

fn aliasStoragePlaceForExpr(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) ?MovePlace {
    if (placeKeyAndType(self, expr, state)) |pp| return pp.place;
    if (aliasPlaceKey(self, expr, state)) |key| {
        defer self.reporter.allocator.free(key);
        if (state.get(key)) |slot| return slot.place;
    }
    return null;
}

fn fullDerefMoveSubplace(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) ?PlaceKeyTy {
    const target = switch (expr.kind) {
        .address_of => |inner| inner.*,
        .grouped => |inner| return fullDerefMoveSubplace(self, inner.*, state, aliases),
        .call => |call| {
            if (!isAssumeNoaliasCall(call)) return null;
            return fullDerefMoveSubplace(self, call.args[0], state, aliases);
        },
        else => return null,
    };
    const pp = placeKeyAndType(self, target, state) orelse
        wildcardMoveIndexedPlaceKey(self, target, state, aliases) orelse
        return null;
    if (!pp.place.isSubplace()) return null;
    if (!self.typeEmbedsMoveByValue(pp.ty, aliases)) return null;
    return pp;
}

fn aliasPlaceForKey(key: []const u8, state: *const std.StringHashMap(MoveSlot)) ?MovePlace {
    const slot = state.get(key) orelse return null;
    if (slot.alias_of != null) return slot.alias_place;
    return slot.place;
}

const AliasReferent = struct {
    key: []const u8,
    place: ?MovePlace,
    full_deref: bool,
};

fn aliasReferentIsTracked(referent: AliasReferent, state: *const std.StringHashMap(MoveSlot)) bool {
    if (referent.place) |place| return state.contains(place.root);
    return state.contains(referent.key) or isMoveSubplaceKey(referent.key);
}

fn aliasReferentRoot(referent: AliasReferent) []const u8 {
    return referentRoot(referent.key, referent.place);
}

fn referentRoot(key: []const u8, place: ?MovePlace) []const u8 {
    if (place) |typed| return typed.root;
    return rootPlaceName(key);
}

fn aliasReferentForExpr(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) ?AliasReferent {
    if (fullDerefMoveSubplace(self, expr, state, aliases)) |pp| {
        return .{ .key = pp.key, .place = pp.place, .full_deref = true };
    }
    if (callLaunderedMoveAliasReferent(self, expr, state, aliases)) |referent| return referent;
    const key = spine.aliasReferentOf(expr, state) orelse
        return null;
    var place = aliasPlaceForKey(key, state);
    switch (expr.kind) {
        .ident => |id| if (state.get(id.text)) |slot| {
            if (slot.alias_of) |alias_of| {
                if (std.mem.eql(u8, alias_of, key) and place == null) place = slot.alias_place;
            }
        },
        .grouped => |inner| if (aliasReferentForExpr(self, inner.*, state, aliases)) |inner_ref| {
            if (std.mem.eql(u8, inner_ref.key, key) and place == null) place = inner_ref.place;
        },
        else => {},
    }
    return .{
        .key = key,
        .place = place,
        .full_deref = isDirectIdentAddressOf(expr) or inheritedFullDerefAlias(expr, state),
    };
}

fn isAssumeNoaliasCall(call: anytype) bool {
    if (call.type_args.len != 0 or call.args.len != 2) return false;
    const member = ast_query.memberCallee(call.callee.*) orelse return false;
    return ast_query.isIdentNamed(member.base.*, "compiler") and std.mem.eql(u8, member.name.text, "assume_noalias_unchecked");
}

// Consume the move bindings used by-value in `expr` (checking liveness).
pub fn moveConsume(self: *Checker, expr: ast.Expr, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) void {
    switch (expr.kind) {
        .ident => |id| {
            consumeTrackedMoveBinding(self, id.text, expr.span, state);
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
        .address_of => |inner| {
            moveBorrow(self, inner.*, state, aliases);
            if (placeKeyAndType(self, inner.*, state)) |pp| {
                if (self.typeEmbedsMoveByValue(pp.ty, aliases) and hasMovedSubplace(pp.place, state)) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "borrow of linear `move` place after one of its child places was moved out");
                }
            }
        },
        .member => |m| {
            moveBorrow(self, m.base.*, state, aliases); // the base must be live to take a field
            // (bug #3) Using a struct-field borrow alias (`h.p`) by value after its
            // referent was moved is a stale-alias use-after-move.
            if (aggregateFieldAliasSlot(self, expr, state)) |slot| {
                checkStaleAlias(self, "", slot, expr.span, state);
            }
            // Moving a `move`-typed field out of a tracked aggregate: poison the field
            // so a second move (or a borrow) of it is caught.
            if (moveFieldPlaceKey(self, expr, m, state, aliases)) |pp| {
                if (deferredBorrowConflictsWithTrackedPlace(pp.place, state)) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "linear `move` field is borrowed by a deferred expression and cannot be moved before the defer runs");
                } else if (stateContainsMovePlace(pp.place, state) or hasMovedSubplace(pp.place, state)) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "use of linear `move` field after it was moved out");
                } else {
                    state.put(pp.key, .{ .live = false, .span = expr.span, .place = pp.place }) catch {
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
            const direct_subplace = fullDerefMoveSubplace(self, inner.*, state, aliases);
            var full_alias_referent: ?AliasReferent = if (direct_subplace) |pp| .{ .key = pp.key, .place = pp.place, .full_deref = true } else immediateFullDerefMoveReferent(self, inner.*, state, aliases);
            switch (inner.*.kind) {
                .ident => |id| if (state.get(id.text)) |s| {
                    if (s.full_deref_alias) {
                        full_alias_referent = if (s.alias_of) |referent| .{ .key = referent, .place = s.alias_place, .full_deref = true } else null;
                    }
                },
                else => {},
            }
            if (full_alias_referent) |referent| {
                consumeTrackedMoveReferent(self, referent, expr.span, state);
            } else if (exprIsMoveTyped(self, expr, state, aliases)) {
                self.errorCode(expr.span, "E_USE_AFTER_MOVE", "cannot move a linear `move` value out through a pointer deref; move the owning binding directly (the pointee would be left moved-from, which the checker cannot track through the alias)");
            } else {
                moveBorrow(self, inner.*, state, aliases);
            }
        },
        .index => |ix| {
            moveBorrow(self, ix.base.*, state, aliases);
            moveConsume(self, ix.index.*, state, aliases);
            if (aliasPlaceSlot(self, expr, state)) |slot| {
                checkStaleAlias(self, "", slot, expr.span, state);
            }
            if (moveIndexedPlaceKey(self, expr, state, aliases)) |pp| {
                if (deferredBorrowConflictsWithTrackedPlace(pp.place, state)) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "linear `move` array element is borrowed by a deferred expression and cannot be moved before the defer runs");
                } else if (stateContainsMovePlace(pp.place, state) or indexedPlaceHasWildcardMove(self, expr, state, aliases) or stateHasConflictingMovePlace(pp.place, state)) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "use of linear `move` array element after it was moved out");
                } else {
                    state.put(pp.key, .{ .live = false, .span = expr.span, .place = pp.place }) catch {
                        self.oom = true;
                    };
                }
            } else if (wildcardMoveIndexedPlaceKey(self, expr, state, aliases)) |pp| {
                if (deferredBorrowConflictsWithTrackedPlace(pp.place, state)) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "linear `move` array element is borrowed by a deferred expression and cannot be moved before the defer runs");
                } else if (stateContainsMovePlace(pp.place, state) or stateHasConflictingMovePlace(pp.place, state)) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "use of linear `move` array element after it was moved out");
                } else {
                    state.put(pp.key, .{ .live = false, .span = expr.span, .place = pp.place }) catch {
                        self.oom = true;
                    };
                }
            } else if (nonNameableSingletonMoveIndex(self, expr, state, aliases)) {
                moveConsume(self, ix.base.*, state, aliases);
            } else if (arrayIndexEmbedsMove(self, expr, state, aliases)) {
                self.errorCode(expr.span, "E_MOVE_ARRAY_UNSUPPORTED", "cannot move a linear `move` array element through a non-constant index; element ownership is only tracked for constant indexes");
            }
        },
        .slice => |s| {
            moveBorrow(self, s.base.*, state, aliases);
            moveConsume(self, s.start.*, state, aliases);
            moveConsume(self, s.end.*, state, aliases);
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
                for (c.args) |arg| checkAggregateAliasArgument(self, arg, state);
                for (c.args) |arg| markBorrowEscapeCallArg(self, arg, c.callee.*.span, state);
                for (c.args) |arg| moveConsume(self, arg, state, aliases);
            }
        },
        .binary => |b| {
            moveConsume(self, b.left.*, state, aliases);
            switch (b.op) {
                .logical_and, .logical_or => moveConsumeShortCircuitRhs(self, b.right.*, state, aliases),
                else => moveConsume(self, b.right.*, state, aliases),
            }
        },
        .block => |b| _ = moveScopedBlock(self, b, state, aliases),
        .unary => |u| moveConsume(self, u.expr.*, state, aliases),
        .struct_literal => |fields| for (fields) |f| moveConsume(self, f.value, state, aliases),
        .array_literal => |items| for (items) |item| moveConsume(self, item, state, aliases),
        else => {},
    }
}

fn immediateFullDerefMoveReferent(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) ?AliasReferent {
    if (fullDerefMoveSubplace(self, expr, state, aliases)) |referent| return .{ .key = referent.key, .place = referent.place, .full_deref = true };
    const root = spine.borrowedMoveRoot(expr, state) orelse return null;
    return .{ .key = root, .place = aliasPlaceForKey(root, state), .full_deref = true };
}

fn consumeTrackedMoveBinding(self: *Checker, name: []const u8, span: diagnostics.Span, state: *std.StringHashMap(MoveSlot)) void {
    if (state.getPtr(name)) |slot| {
        if (slot.type_only) return;
        // T1.2: a pointer alias used by value (e.g. passed to a callee that reads
        // through it). The alias is not itself a linear resource — it is not
        // "moved" — so skip the move bookkeeping and only check it is not stale.
        if (slot.alias_of != null) {
            checkStaleAlias(self, name, slot.*, span, state);
            return;
        }
        if (isPureIndexFactSlot(slot.*)) return;
        if (!slot.live) {
            self.errorCode(span, "E_USE_AFTER_MOVE", "use of linear `move` value after it was moved");
        } else if (slot.escaped_borrow != null) {
            // T1.2 (conservative rejection): a borrow of this value (or a subfield)
            // was stored into memory we cannot prove dead (an aggregate field, an
            // array element, or a sub-place alias). Reading through that borrow after
            // the move would be a use-after-move we could not otherwise catch, so we
            // refuse the move itself.
            self.errorCode(span, "E_USE_AFTER_MOVE", "cannot move this linear `move` value: a borrow of it (or of one of its fields) has been stored into memory and may still be read; the move would leave that borrow dangling");
            slot.live = false;
        } else if (slot.deferred) {
            self.errorCode(span, "E_USE_AFTER_MOVE", "linear `move` value is reserved by a `defer` and cannot be moved");
        } else if (slot.deferred_borrow != null) {
            self.errorCode(span, "E_USE_AFTER_MOVE", "linear `move` value is borrowed by a deferred expression and cannot be moved before the defer runs");
            slot.live = false;
        } else if (slot.place != null and hasMovedSubplace(slot.place.?, state)) {
            // Moving the whole aggregate would also move the field already taken
            // out of it — a duplicate move. (`forget_unchecked` discards the husk
            // instead and goes through moveForget, which is allowed.)
            self.errorCode(span, "E_USE_AFTER_MOVE", "linear `move` value used as a whole after one of its fields was moved out");
            slot.live = false;
        } else {
            slot.live = false;
        }
    }
}

fn consumeTrackedMoveReferent(self: *Checker, referent: AliasReferent, span: diagnostics.Span, state: *std.StringHashMap(MoveSlot)) void {
    if (referent.place orelse aliasPlaceForKey(referent.key, state)) |place| {
        if (place.isSubplace()) {
            consumeTrackedMovePlace(self, referent.key, place, span, state);
        } else {
            consumeTrackedMoveBinding(self, referent.key, span, state);
        }
        return;
    }
    if (isMoveSubplaceKey(referent.key)) {
        consumeTrackedMoveSubplace(self, referent.key, span, state);
    } else {
        consumeTrackedMoveBinding(self, referent.key, span, state);
    }
}

fn consumeTrackedMoveSubplace(self: *Checker, key: []const u8, span: diagnostics.Span, state: *std.StringHashMap(MoveSlot)) void {
    const sep = firstSubplaceSeparator(key) orelse return;
    const root = key[0..sep];
    if (state.get(root)) |slot| {
        if (!slot.live) {
            self.errorCode(span, "E_USE_AFTER_MOVE", "use of linear `move` field after its owner was moved");
            return;
        }
        if (slot.deferred_borrow != null and deferredBorrowConflictsWithPlace(key, slot.deferred_borrow.?)) {
            self.errorCode(span, "E_USE_AFTER_MOVE", "linear `move` field is borrowed by a deferred expression and cannot be moved before the defer runs");
            return;
        }
    }
    if (state.contains(key)) {
        self.errorCode(span, "E_USE_AFTER_MOVE", "use of linear `move` field after it was moved out");
    } else {
        state.put(key, .{ .live = false, .span = span }) catch {
            self.oom = true;
        };
    }
}

fn consumeTrackedMovePlace(self: *Checker, key: []const u8, place: MovePlace, span: diagnostics.Span, state: *std.StringHashMap(MoveSlot)) void {
    const root = state.get(place.root) orelse return;
    if (!root.live) {
        self.errorCode(span, "E_USE_AFTER_MOVE", "use of linear `move` field after its owner was moved");
        return;
    }
    if (deferredBorrowConflictsWithTrackedPlace(place, state)) {
        self.errorCode(span, "E_USE_AFTER_MOVE", "linear `move` field is borrowed by a deferred expression and cannot be moved before the defer runs");
        return;
    }
    if (stateContainsMovePlace(place, state) or stateHasConflictingMovePlace(place, state)) {
        self.errorCode(span, "E_USE_AFTER_MOVE", "use of linear `move` field after it was moved out");
        return;
    }
    state.put(key, .{ .live = false, .span = span, .place = place }) catch {
        self.oom = true;
    };
}

fn moveConsumeShortCircuitRhs(self: *Checker, rhs: ast.Expr, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) void {
    var rhs_state = cloneMoveState(self, state);
    defer rhs_state.deinit();
    moveConsume(self, rhs, &rhs_state, aliases);

    var index_fact_removals: std.ArrayListUnmanaged([]const u8) = .empty;
    defer index_fact_removals.deinit(self.reporter.allocator);

    var it = state.iterator();
    while (it.next()) |entry| {
        const after = rhs_state.get(entry.key_ptr.*) orelse {
            if (isPureIndexFactSlot(entry.value_ptr.*)) {
                index_fact_removals.append(self.reporter.allocator, entry.key_ptr.*) catch {
                    self.oom = true;
                };
            }
            continue;
        };
        const before = entry.value_ptr.*;
        if (before.live != after.live or before.deferred != after.deferred or !sameMaybeSpan(before.escaped_borrow, after.escaped_borrow) or !sameMaybeKey(before.deferred_borrow, after.deferred_borrow) or !sameMaybePlace(before.deferred_borrow_place, after.deferred_borrow_place)) {
            self.errorCode(rhs.span, "E_MOVE_BRANCH_MISMATCH", "cannot consume, reserve, or escape an outer linear `move` value only on one side of a short-circuit expression");
            entry.value_ptr.live = false;
            entry.value_ptr.deferred = false;
            entry.value_ptr.escaped_borrow = null;
            entry.value_ptr.deferred_borrow = null;
            entry.value_ptr.deferred_borrow_place = null;
        } else if (!sameAliasFact(before, after)) {
            entry.value_ptr.* = divergentAliasSlot(entry.key_ptr.*, before);
        } else if (isPureIndexFactSlot(before) and !sameIndexFact(before, after)) {
            index_fact_removals.append(self.reporter.allocator, entry.key_ptr.*) catch {
                self.oom = true;
            };
        }
    }
    for (index_fact_removals.items) |k| _ = state.remove(k);

    var rhs_it = rhs_state.iterator();
    while (rhs_it.next()) |entry| {
        if (state.contains(entry.key_ptr.*)) continue;
        const root = trackedSubplaceRoot(entry.value_ptr.*, entry.key_ptr.*) orelse continue;
        if (state.getPtr(root)) |root_slot| {
            self.errorCode(rhs.span, "E_MOVE_BRANCH_MISMATCH", "cannot move a linear `move` place only on one side of a short-circuit expression");
            root_slot.live = false;
            root_slot.deferred = false;
            root_slot.escaped_borrow = null;
        }
    }
}

fn moveDeferShortCircuitRhs(self: *Checker, rhs: ast.Expr, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) void {
    var rhs_state = cloneMoveState(self, state);
    defer rhs_state.deinit();
    moveDefer(self, rhs, &rhs_state, aliases);

    var index_fact_removals: std.ArrayListUnmanaged([]const u8) = .empty;
    defer index_fact_removals.deinit(self.reporter.allocator);

    var it = state.iterator();
    while (it.next()) |entry| {
        const after = rhs_state.get(entry.key_ptr.*) orelse {
            if (isPureIndexFactSlot(entry.value_ptr.*)) {
                index_fact_removals.append(self.reporter.allocator, entry.key_ptr.*) catch {
                    self.oom = true;
                };
            }
            continue;
        };
        const before = entry.value_ptr.*;
        if (before.live != after.live or before.deferred != after.deferred or !sameMaybeSpan(before.escaped_borrow, after.escaped_borrow) or !sameMaybeKey(before.deferred_borrow, after.deferred_borrow) or !sameMaybePlace(before.deferred_borrow_place, after.deferred_borrow_place)) {
            self.errorCode(rhs.span, "E_MOVE_BRANCH_MISMATCH", "cannot consume, reserve, or defer-borrow an outer linear `move` value only on one side of a short-circuit expression");
            entry.value_ptr.live = false;
            entry.value_ptr.deferred = false;
            entry.value_ptr.escaped_borrow = null;
            entry.value_ptr.deferred_borrow = null;
            entry.value_ptr.deferred_borrow_place = null;
        } else if (!sameAliasFact(before, after)) {
            entry.value_ptr.* = divergentAliasSlot(entry.key_ptr.*, before);
        } else if (isPureIndexFactSlot(before) and !sameIndexFact(before, after)) {
            index_fact_removals.append(self.reporter.allocator, entry.key_ptr.*) catch {
                self.oom = true;
            };
        }
    }
    for (index_fact_removals.items) |k| _ = state.remove(k);

    var rhs_it = rhs_state.iterator();
    while (rhs_it.next()) |entry| {
        if (state.contains(entry.key_ptr.*)) continue;
        const root = trackedSubplaceRoot(entry.value_ptr.*, entry.key_ptr.*) orelse continue;
        if (state.getPtr(root)) |root_slot| {
            self.errorCode(rhs.span, "E_MOVE_BRANCH_MISMATCH", "cannot defer-consume a linear `move` place only on one side of a short-circuit expression");
            root_slot.live = false;
            root_slot.deferred = false;
            root_slot.escaped_borrow = null;
            root_slot.deferred_borrow = null;
            root_slot.deferred_borrow_place = null;
        }
    }
}

fn sameMaybeSpan(left: ?diagnostics.Span, right: ?diagnostics.Span) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    const l = left.?;
    const r = right.?;
    return l.offset == r.offset and l.len == r.len and l.line == r.line and l.column == r.column;
}

fn sameMaybeKey(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    return std.mem.eql(u8, left.?, right.?);
}

fn sameMaybePlace(left: ?MovePlace, right: ?MovePlace) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    return left.?.eql(right.?);
}

fn deferredAliasBorrowPlace(place: ?MovePlace) ?MovePlace {
    var result = place orelse return null;
    for (result.projections[0..result.projection_count]) |*projection| {
        if (projection.* == .symbolic_index) projection.* = .wildcard_index;
    }
    return result;
}

fn placeHasWildcardProjection(place: MovePlace) bool {
    for (place.projections[0..place.projection_count]) |projection| {
        if (projection == .wildcard_index) return true;
    }
    return false;
}

fn isPureIndexFactSlot(slot: MoveSlot) bool {
    return !slot.live and
        !slot.deferred and
        slot.deferred_borrow == null and
        slot.ty == null and
        (slot.const_index != null or slot.symbolic_index != null) and
        slot.alias_of == null and
        slot.escaped_borrow == null and
        !slot.cleanup_local and
        !slot.full_deref_alias;
}

fn sameIndexFact(left: MoveSlot, right: MoveSlot) bool {
    if (!isPureIndexFactSlot(left) or !isPureIndexFactSlot(right)) return false;
    if (left.const_index != null or right.const_index != null) {
        return left.const_index != null and right.const_index != null and left.const_index.? == right.const_index.?;
    }
    if (left.symbolic_index == null or right.symbolic_index == null) return false;
    return std.mem.eql(u8, left.symbolic_index.?, right.symbolic_index.?);
}

// ----- place sensitivity: track a `move` field moved out of its aggregate -----
//
// The state is keyed by binding name; a one-level field move is recorded with a
// synthetic key `binding.field` whose presence means "this field has been moved out".
// This lets the checker reject a duplicate field move, a borrow of a moved-out field,
// and a whole-aggregate move after a field was taken (which would duplicate it).

// Move-place construction is now structured. The state map still uses `key` as a
// compatibility adapter while the checker is migrated, but field/index identity is
// no longer discovered by reparsing that string at the construction boundary.
pub const MovePlace = sema.MovePlace;
const MoveProjection = sema.MovePlaceProjection;

pub const PlaceKeyTy = struct {
    key: []const u8,
    place: MovePlace,
    ty: ast.TypeExpr,
};

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
            return .{ .key = id.text, .place = .{ .root = id.text }, .ty = ty };
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
            const place = base.place.project(.{ .field = m.name.text }) orelse return null;
            return .{ .key = key, .place = place, .ty = field_ty };
        },
        .index => |ix| {
            const base = placeKeyAndType(self, ix.base.*, state) orelse return null;
            const ctx = self.move_ctx orelse return null;
            const base_ty = resolveAliasType(base.ty, ctx.*);
            const array = switch (base_ty.kind) {
                .array => |node| node,
                else => return null,
            };
            const child_ty = array.child.*;
            const len = parseArrayLen(array.len, ctx.const_fns, ctx.const_globals) orelse return null;
            const k = constIndexValue(self, ix.index.*, state, ctx.*) orelse blk: {
                if (symbolicIndexValue(self, ix.index.*, state, ctx.*)) |symbol| {
                    const key = std.fmt.allocPrint(self.reporter.allocator, "{s}[${s}]", .{ base.key, symbol }) catch {
                        self.oom = true;
                        return null;
                    };
                    self.move_place_keys.append(self.reporter.allocator, key) catch {
                        self.oom = true;
                        self.reporter.allocator.free(key);
                        return null;
                    };
                    const place = base.place.project(.{ .symbolic_index = symbol }) orelse return null;
                    return .{ .key = key, .place = place, .ty = child_ty };
                }
                if (len != 1) return null;
                break :blk 0;
            };
            if (k >= len) return null;
            const key = std.fmt.allocPrint(self.reporter.allocator, "{s}[{d}]", .{ base.key, k }) catch {
                self.oom = true;
                return null;
            };
            self.move_place_keys.append(self.reporter.allocator, key) catch {
                self.oom = true;
            };
            const place = base.place.project(.{ .constant_index = k }) orelse return null;
            return .{ .key = key, .place = place, .ty = child_ty };
        },
        else => return null,
    }
}

fn constIndexValue(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot), ctx: Context) ?usize {
    if (parseArrayLen(expr, ctx.const_fns, ctx.const_globals)) |k| return k;
    switch (expr.kind) {
        .grouped => |inner| return constIndexValue(self, inner.*, state, ctx),
        .ident => |id| return if (state.get(id.text)) |slot| slot.const_index else null,
        .binary => |node| {
            switch (node.op) {
                .mul => {
                    if (constIndexValue(self, node.left.*, state, ctx)) |left| if (left == 0) return 0;
                    if (constIndexValue(self, node.right.*, state, ctx)) |right| if (right == 0) return 0;
                },
                .mod => {
                    if (constIndexValue(self, node.right.*, state, ctx)) |right| {
                        if (right == 1) return 0;
                        if (right != 0) {
                            if (symbolicIndexValue(self, node.left.*, state, ctx)) |symbol| {
                                if (symbolicIndexModuloIsZero(symbol, right)) return 0;
                            }
                        }
                    }
                },
                .sub => {
                    if (sameIndexIdent(node.left.*, node.right.*)) return 0;
                    if (sameSymbolicIndex(symbolicIndexValue(self, node.left.*, state, ctx), symbolicIndexValue(self, node.right.*, state, ctx))) return 0;
                },
                .bit_and => {
                    if (constIndexValue(self, node.left.*, state, ctx)) |left| if (left == 0) return 0;
                    if (constIndexValue(self, node.right.*, state, ctx)) |right| if (right == 0) return 0;
                },
                .bit_xor => {
                    if (sameIndexIdent(node.left.*, node.right.*)) return 0;
                    if (sameSymbolicIndex(symbolicIndexValue(self, node.left.*, state, ctx), symbolicIndexValue(self, node.right.*, state, ctx))) return 0;
                },
                else => {},
            }
            const left = constIndexValue(self, node.left.*, state, ctx) orelse return null;
            const right = constIndexValue(self, node.right.*, state, ctx) orelse return null;
            return switch (node.op) {
                .add => std.math.add(usize, left, right) catch null,
                .sub => std.math.sub(usize, left, right) catch null,
                .mul => std.math.mul(usize, left, right) catch null,
                .div => if (right == 0) null else @divTrunc(left, right),
                .mod => if (right == 0) null else @mod(left, right),
                .bit_or => left | right,
                .bit_xor => left ^ right,
                .bit_and => left & right,
                .shl => if (right >= @bitSizeOf(usize)) null else std.math.shl(usize, left, right),
                .shr => if (right >= @bitSizeOf(usize)) null else left >> @intCast(right),
                else => null,
            };
        },
        else => return null,
    }
}

fn stableIndexPlaceKnown(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot), ctx: Context) bool {
    return constIndexValue(self, expr, state, ctx) != null or symbolicIndexValue(self, expr, state, ctx) != null;
}

fn sameIndexIdent(left: ast.Expr, right: ast.Expr) bool {
    const left_name = indexIdentName(left) orelse return false;
    const right_name = indexIdentName(right) orelse return false;
    return std.mem.eql(u8, left_name, right_name);
}

fn indexIdentName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .grouped => |inner| indexIdentName(inner.*),
        .ident => |id| id.text,
        else => null,
    };
}

fn symbolicIndexValue(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot), ctx: Context) ?[]const u8 {
    return switch (expr.kind) {
        .grouped => |inner| symbolicIndexValue(self, inner.*, state, ctx),
        .ident => |id| if (state.get(id.text)) |slot| slot.symbolic_index else null,
        .binary => |node| symbolicIndexBinaryValue(self, node, state, ctx),
        else => null,
    };
}

fn symbolicIndexBinaryValue(self: *Checker, node: anytype, state: *const std.StringHashMap(MoveSlot), ctx: Context) ?[]const u8 {
    const left_symbol = symbolicIndexValue(self, node.left.*, state, ctx);
    const right_symbol = symbolicIndexValue(self, node.right.*, state, ctx);
    const left_const = parseArrayLen(node.left.*, ctx.const_fns, ctx.const_globals);
    const right_const = parseArrayLen(node.right.*, ctx.const_fns, ctx.const_globals);
    return switch (node.op) {
        .add => if (left_symbol != null and right_symbol != null)
            symbolicIndexAddSymbol(self, left_symbol.?, right_symbol.?)
        else if (left_symbol != null and right_const != null)
            symbolicIndexWithOffset(self, left_symbol.?, right_const.?)
        else if (right_symbol != null and left_const != null)
            symbolicIndexWithOffset(self, right_symbol.?, left_const.?)
        else
            null,
        .sub => if (left_symbol != null and right_symbol != null)
            symbolicIndexSubtractSymbol(self, left_symbol.?, right_symbol.?)
        else if (left_symbol != null and right_const != null)
            symbolicIndexMinusOffset(self, left_symbol.?, right_const.?)
        else
            null,
        .mul => if (left_symbol != null and right_const != null)
            symbolicIndexScale(self, left_symbol.?, right_const.?)
        else if (right_symbol != null and left_const != null)
            symbolicIndexScale(self, right_symbol.?, left_const.?)
        else
            null,
        .div => if (left_symbol != null and right_const != null)
            symbolicIndexDivideExact(self, left_symbol.?, right_const.?)
        else
            null,
        .shl => if (left_symbol != null and right_const != null)
            symbolicIndexShiftLeft(self, left_symbol.?, right_const.?)
        else
            null,
        .shr => if (left_symbol != null and right_const != null)
            symbolicIndexShiftRightExact(self, left_symbol.?, right_const.?)
        else
            null,
        .bit_or => if (left_symbol != null and right_const != null and right_const.? == 0)
            left_symbol.?
        else if (right_symbol != null and left_const != null and left_const.? == 0)
            right_symbol.?
        else if (sameSymbolicIndex(left_symbol, right_symbol))
            left_symbol.?
        else
            null,
        .bit_xor => if (left_symbol != null and right_const != null and right_const.? == 0)
            left_symbol.?
        else if (right_symbol != null and left_const != null and left_const.? == 0)
            right_symbol.?
        else
            null,
        .bit_and => if (sameSymbolicIndex(left_symbol, right_symbol))
            left_symbol.?
        else
            null,
        else => null,
    };
}

fn sameSymbolicIndex(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return false;
    return std.mem.eql(u8, left.?, right.?);
}

fn symbolicIndexWithOffset(self: *Checker, symbol: []const u8, offset: usize) ?[]const u8 {
    const delta = std.math.cast(isize, offset) orelse return null;
    return symbolicIndexAddSignedOffset(self, symbol, delta);
}

fn symbolicIndexMinusOffset(self: *Checker, symbol: []const u8, offset: usize) ?[]const u8 {
    const delta = std.math.cast(isize, offset) orelse return null;
    return symbolicIndexAddSignedOffset(self, symbol, -delta);
}

fn symbolicIndexAddSymbol(self: *Checker, left: []const u8, right: []const u8) ?[]const u8 {
    return symbolicIndexCombine(self, left, right, 1);
}

fn symbolicIndexSubtractSymbol(self: *Checker, left: []const u8, right: []const u8) ?[]const u8 {
    return symbolicIndexCombine(self, left, right, -1);
}

fn symbolicIndexAddSignedOffset(self: *Checker, symbol: []const u8, delta: isize) ?[]const u8 {
    var parsed = parseSymbolicLinearIndex(symbol) orelse return null;
    parsed.offset = std.math.add(isize, parsed.offset, delta) catch return null;
    return formatSymbolicLinearIndex(self, parsed);
}

fn symbolicIndexCombine(self: *Checker, left: []const u8, right: []const u8, right_sign: isize) ?[]const u8 {
    var combined = parseSymbolicLinearIndex(left) orelse return null;
    const parsed_right = parseSymbolicLinearIndex(right) orelse return null;
    combined.offset = std.math.add(isize, combined.offset, parsed_right.offset * right_sign) catch return null;
    var idx: usize = 0;
    while (idx < parsed_right.len) : (idx += 1) {
        const term = parsed_right.terms[idx];
        addSymbolicLinearTerm(&combined, term.name, term.sign * right_sign) orelse return null;
    }
    sortSymbolicLinearTerms(&combined);
    return formatSymbolicLinearIndex(self, combined);
}

fn symbolicIndexScale(self: *Checker, symbol: []const u8, factor: usize) ?[]const u8 {
    if (factor == 0) return null;
    var scaled = SymbolicLinearIndex{ .offset = 0 };
    const parsed = parseSymbolicLinearIndex(symbol) orelse return null;
    const signed_factor = std.math.cast(isize, factor) orelse return null;
    scaled.offset = std.math.mul(isize, parsed.offset, signed_factor) catch return null;
    var repeat: usize = 0;
    while (repeat < factor) : (repeat += 1) {
        var idx: usize = 0;
        while (idx < parsed.len) : (idx += 1) {
            const term = parsed.terms[idx];
            addSymbolicLinearTerm(&scaled, term.name, term.sign) orelse return null;
        }
    }
    sortSymbolicLinearTerms(&scaled);
    return formatSymbolicLinearIndex(self, scaled);
}

fn symbolicIndexShiftLeft(self: *Checker, symbol: []const u8, shift: usize) ?[]const u8 {
    if (shift >= @bitSizeOf(usize)) return null;
    const factor = std.math.shl(usize, 1, shift);
    return symbolicIndexScale(self, symbol, factor);
}

fn symbolicIndexShiftRightExact(self: *Checker, symbol: []const u8, shift: usize) ?[]const u8 {
    if (shift >= @bitSizeOf(usize)) return null;
    if (shift == 0) return symbol;
    const divisor = std.math.shl(usize, 1, shift);
    return symbolicIndexDivideExact(self, symbol, divisor);
}

fn symbolicIndexDivideExact(self: *Checker, symbol: []const u8, divisor: usize) ?[]const u8 {
    if (divisor == 0) return null;
    if (divisor == 1) return symbol;
    const signed_divisor = std.math.cast(isize, divisor) orelse return null;
    var parsed = parseSymbolicLinearIndex(symbol) orelse return null;
    if (@mod(parsed.offset, signed_divisor) != 0) return null;

    sortSymbolicTermsByNameAndSign(&parsed);

    var divided = SymbolicLinearIndex{ .offset = @divTrunc(parsed.offset, signed_divisor) };
    var idx: usize = 0;
    while (idx < parsed.len) {
        const term = parsed.terms[idx];
        var count: usize = 1;
        while (idx + count < parsed.len and
            term.sign == parsed.terms[idx + count].sign and
            std.mem.eql(u8, term.name, parsed.terms[idx + count].name)) : (count += 1)
        {}
        if (@mod(count, divisor) != 0) return null;
        var repeat: usize = 0;
        while (repeat < count / divisor) : (repeat += 1) {
            addSymbolicLinearTerm(&divided, term.name, term.sign) orelse return null;
        }
        idx += count;
    }

    sortSymbolicLinearTerms(&divided);
    return formatSymbolicLinearIndex(self, divided);
}

fn symbolicIndexModuloIsZero(symbol: []const u8, divisor: usize) bool {
    if (divisor == 0) return false;
    if (divisor == 1) return true;
    const signed_divisor = std.math.cast(isize, divisor) orelse return false;
    var parsed = parseSymbolicLinearIndex(symbol) orelse return false;
    if (@mod(parsed.offset, signed_divisor) != 0) return false;
    sortSymbolicTermsByNameAndSign(&parsed);

    var idx: usize = 0;
    while (idx < parsed.len) {
        const name = parsed.terms[idx].name;
        var coefficient: isize = 0;
        while (idx < parsed.len and std.mem.eql(u8, name, parsed.terms[idx].name)) : (idx += 1) {
            coefficient += parsed.terms[idx].sign;
        }
        if (@mod(coefficient, signed_divisor) != 0) return false;
    }
    return true;
}

const max_symbolic_index_terms = 4;

const SymbolicLinearTerm = struct {
    name: []const u8,
    sign: isize,
};

const SymbolicLinearIndex = struct {
    terms: [max_symbolic_index_terms]SymbolicLinearTerm = undefined,
    len: usize = 0,
    offset: isize,
};

fn parseSymbolicLinearIndex(symbol: []const u8) ?SymbolicLinearIndex {
    if (symbol.len == 0) return null;
    var parsed = SymbolicLinearIndex{ .offset = 0 };
    var start: usize = 0;
    var sign: isize = 1;
    if (symbol[0] == '-') {
        sign = -1;
        start = 1;
    } else if (symbol[0] == '+') {
        start = 1;
    }
    var pos = start;
    while (pos <= symbol.len) : (pos += 1) {
        if (pos < symbol.len and symbol[pos] != '+' and symbol[pos] != '-') continue;
        if (pos == start) return null;
        const token = symbol[start..pos];
        if (std.fmt.parseInt(isize, token, 10)) |value| {
            parsed.offset = std.math.add(isize, parsed.offset, value * sign) catch return null;
        } else |_| {
            addSymbolicLinearTerm(&parsed, token, sign) orelse return null;
        }
        if (pos < symbol.len) {
            sign = if (symbol[pos] == '+') 1 else -1;
            start = pos + 1;
        }
    }
    if (parsed.len == 0) return null;
    sortSymbolicLinearTerms(&parsed);
    return parsed;
}

fn addSymbolicLinearTerm(index: *SymbolicLinearIndex, name: []const u8, sign: isize) ?void {
    if (sign != 1 and sign != -1) return null;
    if (name.len == 0) return null;
    var existing_index: usize = 0;
    while (existing_index < index.len) : (existing_index += 1) {
        if (!std.mem.eql(u8, index.terms[existing_index].name, name)) continue;
        if (index.terms[existing_index].sign == -sign) {
            var shift = existing_index;
            while (shift + 1 < index.len) : (shift += 1) {
                index.terms[shift] = index.terms[shift + 1];
            }
            index.len -= 1;
            return;
        }
    }
    if (index.len >= max_symbolic_index_terms) return null;
    index.terms[index.len] = .{ .name = name, .sign = sign };
    index.len += 1;
}

fn sortSymbolicLinearTerms(index: *SymbolicLinearIndex) void {
    var i: usize = 1;
    while (i < index.len) : (i += 1) {
        const current = index.terms[i];
        var j = i;
        while (j > 0 and symbolicLinearTermLess(current, index.terms[j - 1])) : (j -= 1) {
            index.terms[j] = index.terms[j - 1];
        }
        index.terms[j] = current;
    }
}

fn sortSymbolicTermsByNameAndSign(index: *SymbolicLinearIndex) void {
    var i: usize = 1;
    while (i < index.len) : (i += 1) {
        const current = index.terms[i];
        var j = i;
        while (j > 0 and symbolicLinearTermNameSignLess(current, index.terms[j - 1])) : (j -= 1) {
            index.terms[j] = index.terms[j - 1];
        }
        index.terms[j] = current;
    }
}

fn symbolicLinearTermLess(left: SymbolicLinearTerm, right: SymbolicLinearTerm) bool {
    if (left.sign != right.sign) return left.sign > right.sign;
    return std.mem.lessThan(u8, left.name, right.name);
}

fn symbolicLinearTermNameSignLess(left: SymbolicLinearTerm, right: SymbolicLinearTerm) bool {
    if (!std.mem.eql(u8, left.name, right.name)) return std.mem.lessThan(u8, left.name, right.name);
    return left.sign > right.sign;
}

fn formatSymbolicLinearIndex(self: *Checker, index: SymbolicLinearIndex) ?[]const u8 {
    if (index.len == 0) return null;
    var out: std.ArrayList(u8) = .empty;

    var idx: usize = 0;
    while (idx < index.len) : (idx += 1) {
        const term = index.terms[idx];
        if (idx == 0) {
            if (term.sign < 0) out.append(self.reporter.allocator, '-') catch {
                self.oom = true;
                return null;
            };
        } else {
            out.append(self.reporter.allocator, if (term.sign > 0) '+' else '-') catch {
                self.oom = true;
                return null;
            };
        }
        out.appendSlice(self.reporter.allocator, term.name) catch {
            self.oom = true;
            return null;
        };
    }

    if (index.offset != 0) {
        if (index.offset > 0) {
            const suffix = std.fmt.allocPrint(self.reporter.allocator, "+{d}", .{index.offset}) catch {
                self.oom = true;
                return null;
            };
            defer self.reporter.allocator.free(suffix);
            out.appendSlice(self.reporter.allocator, suffix) catch {
                self.oom = true;
                return null;
            };
        } else {
            const suffix = std.fmt.allocPrint(self.reporter.allocator, "-{d}", .{-index.offset}) catch {
                self.oom = true;
                return null;
            };
            defer self.reporter.allocator.free(suffix);
            out.appendSlice(self.reporter.allocator, suffix) catch {
                self.oom = true;
                return null;
            };
        }
    }

    const key = out.toOwnedSlice(self.reporter.allocator) catch {
        self.oom = true;
        return null;
    };
    self.move_place_keys.append(self.reporter.allocator, key) catch {
        self.oom = true;
        self.reporter.allocator.free(key);
        return null;
    };
    return key;
}

fn isUsizeType(maybe_ty: ?ast.TypeExpr) bool {
    const ty = maybe_ty orelse return false;
    const name = ast_query.typeName(ty) orelse return false;
    return std.mem.eql(u8, name, "usize");
}

fn retainsAliasPlaceType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .array => true,
        .qualified => |node| retainsAliasPlaceType(node.child.*),
        else => false,
    };
}

fn exprCanStoreBorrowAlias(expr: ast.Expr, ctx: Context) bool {
    const ty = spine.exprResultType(expr, ctx) orelse return false;
    return typeCanStoreBorrowAlias(ty, ctx);
}

fn typeCanStoreBorrowAlias(ty: ast.TypeExpr, ctx: Context) bool {
    return switch (resolveAliasType(ty, ctx).kind) {
        .pointer, .raw_many_pointer, .slice => true,
        .qualified => |node| typeCanStoreBorrowAlias(node.child.*, ctx),
        else => false,
    };
}

// The place key for a `move`-typed field access (at any nesting depth), or null if the
// accessed place is not a tracked move field.
pub fn moveFieldPlaceKey(self: *Checker, expr: ast.Expr, m: anytype, state: *const std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) ?PlaceKeyTy {
    _ = m;
    const pp = placeKeyAndType(self, expr, state) orelse return null;
    // A field is a move place if its type *embeds* a move resource by value — not only a
    // direct move type name, but also a `?move` / `Result<…move…,…>` field. Otherwise moving
    // such a wrapper field out of an aggregate would not poison the place, and a second
    // move of the same field (a double free) would go undetected. (Move-typed array fields
    // are rejected at declaration, so a place leaf is never an untrackable array.)
    if (!self.typeEmbedsMoveByValue(pp.ty, aliases)) return null;
    return pp;
}

pub fn moveIndexedPlaceKey(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) ?PlaceKeyTy {
    const pp = placeKeyAndType(self, expr, state) orelse return null;
    if (!self.typeEmbedsMoveByValue(pp.ty, aliases)) return null;
    return pp;
}

fn wildcardMoveIndexedPlaceKey(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) ?PlaceKeyTy {
    if (nestedWildcardIndexedPlaceKeyAndType(self, expr, state, aliases)) |pp| {
        if (!self.typeEmbedsMoveByValue(pp.ty, aliases)) return null;
        return pp;
    }
    switch (expr.kind) {
        .grouped => |inner| return wildcardMoveIndexedPlaceKey(self, inner.*, state, aliases),
        .index => |ix| {
            const base = placeKeyAndType(self, ix.base.*, state) orelse return null;
            const ctx = self.move_ctx orelse return null;
            const base_ty = resolveAliasType(base.ty, ctx.*);
            const array = switch (base_ty.kind) {
                .array => |node| node,
                else => return null,
            };
            const len = parseArrayLen(array.len, ctx.const_fns, ctx.const_globals) orelse return null;
            if (len <= 1) return null;
            if (stableIndexPlaceKnown(self, ix.index.*, state, ctx.*)) return null;
            if (!self.typeEmbedsMoveByValue(array.child.*, aliases)) return null;
            const key = std.fmt.allocPrint(self.reporter.allocator, "{s}[*]", .{base.key}) catch {
                self.oom = true;
                return null;
            };
            self.move_place_keys.append(self.reporter.allocator, key) catch {
                self.oom = true;
                self.reporter.allocator.free(key);
                return null;
            };
            const place = base.place.project(.wildcard_index) orelse return null;
            return .{ .key = key, .place = place, .ty = array.child.* };
        },
        else => return null,
    }
}

fn nestedWildcardIndexedPlaceKeyAndType(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) ?PlaceKeyTy {
    switch (expr.kind) {
        .grouped => |inner| return nestedWildcardIndexedPlaceKeyAndType(self, inner.*, state, aliases),
        .index => |ix| {
            const ctx = self.move_ctx orelse return null;
            const base = nestedWildcardIndexedPlaceKeyAndType(self, ix.base.*, state, aliases) orelse {
                const direct_base = placeKeyAndType(self, ix.base.*, state) orelse return null;
                const direct_base_ty = resolveAliasType(direct_base.ty, ctx.*);
                const direct_array = switch (direct_base_ty.kind) {
                    .array => |node| node,
                    else => return null,
                };
                const direct_len = parseArrayLen(direct_array.len, ctx.const_fns, ctx.const_globals) orelse return null;
                if (direct_len <= 1) return null;
                if (stableIndexPlaceKnown(self, ix.index.*, state, ctx.*)) return null;
                if (!self.typeEmbedsMoveByValue(direct_array.child.*, aliases)) return null;
                const key = std.fmt.allocPrint(self.reporter.allocator, "{s}[*]", .{direct_base.key}) catch {
                    self.oom = true;
                    return null;
                };
                self.move_place_keys.append(self.reporter.allocator, key) catch {
                    self.oom = true;
                    self.reporter.allocator.free(key);
                    return null;
                };
                const place = direct_base.place.project(.wildcard_index) orelse return null;
                return .{ .key = key, .place = place, .ty = direct_array.child.* };
            };
            const base_ty = resolveAliasType(base.ty, ctx.*);
            const array = switch (base_ty.kind) {
                .array => |node| node,
                else => return null,
            };
            const len = parseArrayLen(array.len, ctx.const_fns, ctx.const_globals) orelse return null;
            const child_ty = array.child.*;
            const key = if (constIndexValue(self, ix.index.*, state, ctx.*)) |index| blk: {
                if (index >= len) return null;
                break :blk std.fmt.allocPrint(self.reporter.allocator, "{s}[{d}]", .{ base.key, index }) catch {
                    self.oom = true;
                    return null;
                };
            } else if (len == 1) blk: {
                break :blk std.fmt.allocPrint(self.reporter.allocator, "{s}[0]", .{base.key}) catch {
                    self.oom = true;
                    return null;
                };
            } else blk: {
                if (!self.typeEmbedsMoveByValue(child_ty, aliases)) return null;
                break :blk std.fmt.allocPrint(self.reporter.allocator, "{s}[*]", .{base.key}) catch {
                    self.oom = true;
                    return null;
                };
            };
            self.move_place_keys.append(self.reporter.allocator, key) catch {
                self.oom = true;
                self.reporter.allocator.free(key);
                return null;
            };
            const index_value = constIndexValue(self, ix.index.*, state, ctx.*);
            const projection: MoveProjection = if (index_value) |index|
                .{ .constant_index = index }
            else if (len == 1)
                .{ .constant_index = 0 }
            else
                .wildcard_index;
            const place = base.place.project(projection) orelse return null;
            return .{ .key = key, .place = place, .ty = child_ty };
        },
        else => return null,
    }
}

fn indexedPlaceWildcardConflictKey(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) ?[]const u8 {
    switch (expr.kind) {
        .grouped => |inner| return indexedPlaceWildcardConflictKey(self, inner.*, state, aliases),
        .index => |ix| {
            const base = placeKeyAndType(self, ix.base.*, state) orelse return null;
            const ctx = self.move_ctx orelse return null;
            const base_ty = resolveAliasType(base.ty, ctx.*);
            const array = switch (base_ty.kind) {
                .array => |node| node,
                else => return null,
            };
            const len = parseArrayLen(array.len, ctx.const_fns, ctx.const_globals) orelse return null;
            if (len <= 1) return null;
            if (!self.typeEmbedsMoveByValue(array.child.*, aliases)) return null;
            return std.fmt.allocPrint(self.reporter.allocator, "{s}[*]", .{base.key}) catch {
                self.oom = true;
                return null;
            };
        },
        else => return null,
    }
}

fn indexedPlaceHasWildcardMove(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
    const key = indexedPlaceWildcardConflictKey(self, expr, state, aliases) orelse return false;
    defer self.reporter.allocator.free(key);
    return state.contains(key);
}

fn arrayLiteralElementEmbedsMove(self: *Checker, expr: ast.Expr, ctx: Context, aliases: *const std.StringHashMap(ast.TypeExpr)) ?bool {
    switch (expr.kind) {
        .grouped => |inner| return arrayLiteralElementEmbedsMove(self, inner.*, ctx, aliases),
        .array_literal => |items| {
            for (items) |item| {
                if (arrayLiteralElementEmbedsMove(self, item, ctx, aliases)) |embeds| {
                    if (embeds) return true;
                    continue;
                }
                if (spine.exprResultType(item, ctx)) |item_ty| {
                    if (self.typeEmbedsMoveByValue(item_ty, aliases)) return true;
                }
            }
            return false;
        },
        else => return null,
    }
}

fn arrayIndexEmbedsMove(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
    switch (expr.kind) {
        .grouped => |inner| return arrayIndexEmbedsMove(self, inner.*, state, aliases),
        .index => |ix| {
            const ctx = self.move_ctx orelse return false;
            const base_ty_expr = if (placeKeyAndType(self, ix.base.*, state)) |base|
                base.ty
            else
                spine.exprResultType(ix.base.*, ctx.*) orelse {
                    if (arrayIndexEmbedsMove(self, ix.base.*, state, aliases)) return true;
                    return arrayLiteralElementEmbedsMove(self, ix.base.*, ctx.*, aliases) orelse false;
                };
            const base_ty = resolveAliasType(base_ty_expr, ctx.*);
            const child_ty = switch (base_ty.kind) {
                .array => |node| node.child.*,
                else => return false,
            };
            return self.typeEmbedsMoveByValue(child_ty, aliases);
        },
        else => return false,
    }
}

fn arrayLiteralLenAndElementEmbedsMove(self: *Checker, expr: ast.Expr, ctx: Context, aliases: *const std.StringHashMap(ast.TypeExpr)) ?ArrayMoveShape {
    switch (expr.kind) {
        .grouped => |inner| return arrayLiteralLenAndElementEmbedsMove(self, inner.*, ctx, aliases),
        .array_literal => |items| {
            var embeds = false;
            for (items) |item| {
                if (arrayLiteralElementEmbedsMove(self, item, ctx, aliases)) |item_embeds| {
                    embeds = embeds or item_embeds;
                    continue;
                }
                if (spine.exprResultType(item, ctx)) |item_ty| {
                    embeds = embeds or self.typeEmbedsMoveByValue(item_ty, aliases);
                }
            }
            return .{ .len = items.len, .embeds = embeds };
        },
        else => return null,
    }
}

fn nonNameableSingletonIndexResultType(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) ?ast.TypeExpr {
    switch (expr.kind) {
        .grouped => |inner| return nonNameableSingletonIndexResultType(self, inner.*, state),
        .index => |ix| {
            if (placeKeyAndType(self, ix.base.*, state) != null) return null;
            const ctx = self.move_ctx orelse return null;
            const base_ty_expr = spine.exprResultType(ix.base.*, ctx.*) orelse nonNameableSingletonIndexResultType(self, ix.base.*, state) orelse return null;
            const base_ty = resolveAliasType(base_ty_expr, ctx.*);
            const array = switch (base_ty.kind) {
                .array => |node| node,
                else => return null,
            };
            const len = parseArrayLen(array.len, ctx.const_fns, ctx.const_globals) orelse return null;
            if (len != 1) return null;
            return array.child.*;
        },
        else => return null,
    }
}

fn selectedArrayLiteralItemLenAndElementEmbedsMove(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot), ctx: Context, aliases: *const std.StringHashMap(ast.TypeExpr)) ?ArrayMoveShape {
    switch (expr.kind) {
        .grouped => |inner| return selectedArrayLiteralItemLenAndElementEmbedsMove(self, inner.*, state, ctx, aliases),
        .index => |ix| {
            const items = switch (ix.base.*.kind) {
                .grouped => |inner| switch (inner.*.kind) {
                    .array_literal => |items| items,
                    else => return null,
                },
                .array_literal => |items| items,
                else => return null,
            };
            const selected = if (constIndexValue(self, ix.index.*, state, ctx)) |index| blk: {
                if (index >= items.len) return null;
                break :blk index;
            } else blk: {
                if (items.len != 1) return null;
                break :blk 0;
            };
            return arrayLiteralLenAndElementEmbedsMove(self, items[selected], ctx, aliases);
        },
        else => return null,
    }
}

fn nonNameableArrayExprLenAndElementEmbedsMove(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot), ctx: Context, aliases: *const std.StringHashMap(ast.TypeExpr)) ?ArrayMoveShape {
    if (arrayLiteralLenAndElementEmbedsMove(self, expr, ctx, aliases)) |literal| return literal;
    if (selectedArrayLiteralItemLenAndElementEmbedsMove(self, expr, state, ctx, aliases)) |literal| return literal;
    const ty_expr = nonNameableSingletonIndexResultType(self, expr, state) orelse spine.exprResultType(expr, ctx) orelse return null;
    const ty = resolveAliasType(ty_expr, ctx);
    const array = switch (ty.kind) {
        .array => |node| node,
        else => return null,
    };
    const len = parseArrayLen(array.len, ctx.const_fns, ctx.const_globals) orelse return null;
    return .{ .len = len, .embeds = self.typeEmbedsMoveByValue(array.child.*, aliases) };
}

fn nonNameableSingletonMoveIndex(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
    switch (expr.kind) {
        .grouped => |inner| return nonNameableSingletonMoveIndex(self, inner.*, state, aliases),
        .index => |ix| {
            if (placeKeyAndType(self, ix.base.*, state) != null) return false;
            const ctx = self.move_ctx orelse return false;
            const array = nonNameableArrayExprLenAndElementEmbedsMove(self, ix.base.*, state, ctx.*, aliases) orelse return false;
            return array.len == 1 and array.embeds;
        },
        else => return false,
    }
}

// Whether the place denoted by `expr` (a possibly-nested field access) is recorded as
// moved out.
pub fn placeExprIsMoved(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) bool {
    const pp = placeKeyAndType(self, expr, state) orelse return false;
    return stateHasMovedPlace(pp.place, state) or stateHasMovedConflictingPlace(pp.place, state);
}

fn concretePlaceHasWildcardMove(key: []const u8, state: *const std.StringHashMap(MoveSlot)) bool {
    var it = state.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, key)) continue;
        if (entry.value_ptr.alias_of != null or entry.value_ptr.type_only or isPureIndexFactSlot(entry.value_ptr.*)) continue;
        if (wildcardMoveKeyMatchesConcrete(entry.key_ptr.*, key)) return true;
    }
    return false;
}

fn wildcardMoveConflictsWithConcreteSubplace(wildcard_key: []const u8, state: *const std.StringHashMap(MoveSlot)) bool {
    var it = state.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, wildcard_key)) continue;
        if (entry.value_ptr.alias_of != null or entry.value_ptr.type_only or isPureIndexFactSlot(entry.value_ptr.*)) continue;
        if (wildcardMoveKeyMatchesConcrete(wildcard_key, entry.key_ptr.*)) return true;
    }
    return false;
}

fn wildcardMoveKeyMatchesConcrete(wildcard_key: []const u8, concrete_key: []const u8) bool {
    const marker = std.mem.indexOf(u8, wildcard_key, "[*]") orelse std.mem.indexOf(u8, wildcard_key, "[$") orelse return false;
    const prefix = wildcard_key[0..marker];
    if (!std.mem.startsWith(u8, concrete_key, prefix)) return false;
    if (concrete_key.len <= prefix.len or concrete_key[prefix.len] != '[') return false;
    const close_rel = std.mem.indexOfScalar(u8, concrete_key[prefix.len..], ']') orelse return false;
    const concrete_suffix = concrete_key[prefix.len + close_rel + 1 ..];
    const wildcard_close_rel = std.mem.indexOfScalar(u8, wildcard_key[marker..], ']') orelse return false;
    const wildcard_suffix = wildcard_key[marker + wildcard_close_rel + 1 ..];
    return std.mem.eql(u8, concrete_suffix, wildcard_suffix);
}

fn stateContainsMovePlace(place: MovePlace, state: *const std.StringHashMap(MoveSlot)) bool {
    var it = state.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr.*;
        if (slot.alias_of != null or slot.type_only or isPureIndexFactSlot(slot)) continue;
        if (slot.place) |tracked| if (tracked.eql(place)) return true;
    }
    return false;
}

fn stateHasConflictingMovePlace(place: MovePlace, state: *const std.StringHashMap(MoveSlot)) bool {
    var it = state.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr.*;
        if (slot.alias_of != null or slot.type_only or isPureIndexFactSlot(slot)) continue;
        if (slot.place) |tracked| {
            if (!tracked.eql(place) and tracked.conflicts(place)) return true;
        }
    }
    return false;
}

fn stateHasMovedPlace(place: MovePlace, state: *const std.StringHashMap(MoveSlot)) bool {
    var it = state.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr.*;
        if (slot.live or slot.alias_of != null or slot.type_only or isPureIndexFactSlot(slot)) continue;
        if (slot.place) |tracked| if (tracked.eql(place)) return true;
    }
    return false;
}

fn stateHasMovedConflictingPlace(place: MovePlace, state: *const std.StringHashMap(MoveSlot)) bool {
    var it = state.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr.*;
        if (slot.live or slot.alias_of != null or slot.type_only or isPureIndexFactSlot(slot)) continue;
        if (slot.place) |tracked| {
            if (!tracked.eql(place) and tracked.conflicts(place)) return true;
        }
    }
    return false;
}

fn stateHasMovedChildPlace(place: MovePlace, state: *const std.StringHashMap(MoveSlot)) bool {
    var it = state.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr.*;
        if (slot.live or slot.alias_of != null or slot.type_only or isPureIndexFactSlot(slot)) continue;
        if (slot.place) |tracked| if (place.isPrefixOf(tracked)) return true;
    }
    return false;
}

fn deferredBorrowConflictsWithTrackedPlace(place: MovePlace, state: *const std.StringHashMap(MoveSlot)) bool {
    const root_slot = state.get(place.root) orelse return false;
    const borrowed = root_slot.deferred_borrow_place orelse return false;
    return borrowed.eql(place) or borrowed.isPrefixOf(place) or place.isPrefixOf(borrowed) or borrowed.conflicts(place);
}

// Compatibility for aliases whose referent predates the structured state entry.
// Direct move/defer paths use `deferredBorrowConflictsWithTrackedPlace` above.
fn deferredBorrowConflictsWithPlace(move_key: []const u8, borrow_key: []const u8) bool {
    if (std.mem.eql(u8, move_key, borrow_key)) return true;
    if (isPlacePrefix(move_key, borrow_key) or isPlacePrefix(borrow_key, move_key)) return true;
    if (wildcardMoveKeyMatchesConcrete(move_key, borrow_key)) return true;
    return wildcardMoveKeyMatchesConcrete(borrow_key, move_key);
}

fn rootPlaceName(key: []const u8) []const u8 {
    const sep = firstSubplaceSeparator(key) orelse return key;
    return key[0..sep];
}

fn isPlacePrefix(prefix: []const u8, key: []const u8) bool {
    if (key.len <= prefix.len) return false;
    return std.mem.startsWith(u8, key, prefix) and isSubplaceSeparator(key[prefix.len]);
}

// Whether any field of `base` has been moved out (a partial move of the aggregate).
pub fn hasMovedSubplace(base: MovePlace, state: *const std.StringHashMap(MoveSlot)) bool {
    var it = state.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr.*;
        if (slot.alias_of != null or slot.type_only or isPureIndexFactSlot(slot)) continue;
        if (slot.place) |tracked| if (base.isPrefixOf(tracked)) return true;
    }
    return false;
}

// Remove every child place when the whole aggregate leaves play (consumed or
// forgotten), so a later same-named binding starts clean. Typed slots use
// projection ancestry; legacy alias-only slots retain the display-key fallback
// until the state-map migration is complete.
pub fn clearSubplaces(base: MovePlace, state: *std.StringHashMap(MoveSlot)) void {
    // A HashMap iterator is invalidated by a removal, so rescan from the top
    // after each one. The number of tracked places per function is tiny.
    var removed_any = true;
    while (removed_any) {
        removed_any = false;
        var it = state.iterator();
        while (it.next()) |entry| {
            const k = entry.key_ptr.*;
            const slot = entry.value_ptr.*;
            const is_child = if (slot.place) |place|
                base.isPrefixOf(place)
            else
                k.len > base.root.len + 1 and std.mem.startsWith(u8, k, base.root) and isSubplaceSeparator(k[base.root.len]);
            if (is_child) {
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
            var root_place = MovePlace{ .root = id.text };
            if (state.getPtr(id.text)) |slot| {
                if (slot.place) |place| root_place = place;
                if (!slot.live) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "use of linear `move` value after it was moved");
                } else if (slot.deferred) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "linear `move` value is reserved by a `defer` and cannot be moved");
                } else if (slot.deferred_borrow != null) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "linear `move` value is borrowed by a deferred expression and cannot be forgotten before the defer runs");
                    slot.live = false;
                } else {
                    slot.live = false;
                }
            }
            clearSubplaces(root_place, state);
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
    if (aliasSlotReferentMoved(slot, state)) {
        self.errorCode(span, "E_USE_AFTER_MOVE", "use of an alias derived from a linear `move` value after that value was moved (the alias is now stale)");
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
// is covered precisely by the pointer-returning-call laundering check (callLaunderedMoveReferent).
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

// T1.3 residual: `let h = mkHolder(&t)` stores a direct call's returned aggregate locally.
// If the return type can contain pointer-like storage, the callee may have copied an argument
// borrow into that returned value. Unlike a pointer return (`let q = id(&t)`), there is no
// scalar alias local to track precisely, so conservatively mark the borrowed move root escaped.
pub fn markBorrowEscapeCapturedCallResult(self: *Checker, value: ast.Expr, escape_span: diagnostics.Span, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) void {
    const ctx = self.move_ctx orelse return;
    const call = switch (value.kind) {
        .call => |c| c,
        .grouped => |inner| return markBorrowEscapeCapturedCallResult(self, inner.*, escape_span, state, aliases),
        .cast => |c| return markBorrowEscapeCapturedCallResult(self, c.value.*, escape_span, state, aliases),
        else => return,
    };
    if (spine.isDropCall(call.callee.*) or spine.isForgetUncheckedCall(call.callee.*)) return;
    const ret_ty = spine.directCallReturnType(call.callee.*, ctx.*) orelse return;
    if (spine.isPointerLike(spine.classifyTypeCtx(ret_ty, ctx.*))) return;
    if (!typeCanCarryBorrowInStoredValue(ret_ty, ctx.*, aliases, 0)) return;

    for (call.args) |arg| markBorrowEscapeCapturedCallArg(arg, escape_span, state);
}

fn markBorrowEscapeCapturedCallArg(arg: ast.Expr, escape_span: diagnostics.Span, state: *std.StringHashMap(MoveSlot)) void {
    switch (arg.kind) {
        .grouped => |inner| return markBorrowEscapeCapturedCallArg(inner.*, escape_span, state),
        .struct_literal => |fields| {
            for (fields) |field| markBorrowEscapeCapturedCallArg(field.value, escape_span, state);
            return;
        },
        .array_literal => |items| {
            for (items) |item| markBorrowEscapeCapturedCallArg(item, escape_span, state);
            return;
        },
        else => {},
    }

    const root = spine.borrowedMoveRoot(arg, state) orelse blk: {
        if (spine.aliasReferentOf(arg, state)) |referent| {
            if (state.contains(referent)) break :blk referent;
        }
        return;
    };
    if (state.getPtr(root)) |slot| {
        if (slot.live and slot.alias_of == null and slot.escaped_borrow == null) {
            slot.escaped_borrow = escape_span;
        }
    }
}

fn typeCanCarryBorrowInStoredValue(ty: ast.TypeExpr, ctx: Context, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) bool {
    if (depth > 64) return false;
    switch (ty.kind) {
        .name => |name| {
            if (aliases.get(name.text)) |target| {
                if (ast_query.typeName(target)) |target_name| {
                    if (!std.mem.eql(u8, target_name, name.text)) {
                        if (typeCanCarryBorrowInStoredValue(target, ctx, aliases, depth + 1)) return true;
                    }
                } else if (typeCanCarryBorrowInStoredValue(target, ctx, aliases, depth + 1)) return true;
            }
            if (ctx.structs) |structs| {
                if (structs.get(name.text)) |info| return layoutFieldsCanCarryBorrow(info.fields, ctx, aliases, depth + 1);
            }
            if (ctx.packed_bits) |packed_bits| {
                if (packed_bits.get(name.text)) |info| return layoutFieldsCanCarryBorrow(info.fields, ctx, aliases, depth + 1);
            }
            if (ctx.overlay_unions) |overlay_unions| {
                if (overlay_unions.get(name.text)) |info| return layoutFieldsCanCarryBorrow(info.fields, ctx, aliases, depth + 1);
            }
            if (ctx.tagged_unions) |tagged_unions| {
                if (tagged_unions.get(name.text)) |info| {
                    var it = info.cases.valueIterator();
                    while (it.next()) |case_ty| {
                        if (case_ty.*) |payload_ty| {
                            if (typeCanCarryBorrowInStoredValue(payload_ty, ctx, aliases, depth + 1)) return true;
                        }
                    }
                }
            }
            return false;
        },
        .pointer, .raw_many_pointer, .slice, .closure_type, .dyn_trait => return true,
        .array => |node| return typeCanCarryBorrowInStoredValue(node.child.*, ctx, aliases, depth + 1),
        .nullable => |child| return typeCanCarryBorrowInStoredValue(child.*, ctx, aliases, depth + 1),
        .qualified => |node| return typeCanCarryBorrowInStoredValue(node.child.*, ctx, aliases, depth + 1),
        .generic => |node| {
            if (!std.mem.eql(u8, node.base.text, "Result") and
                !std.mem.eql(u8, node.base.text, "MaybeUninit") and
                !std.mem.eql(u8, node.base.text, "atomic"))
            {
                return false;
            }
            for (node.args) |arg| {
                if (typeCanCarryBorrowInStoredValue(arg, ctx, aliases, depth + 1)) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn layoutFieldsCanCarryBorrow(fields: std.StringHashMap(ast.TypeExpr), ctx: Context, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) bool {
    var it = fields.valueIterator();
    while (it.next()) |field_ty| {
        if (typeCanCarryBorrowInStoredValue(field_ty.*, ctx, aliases, depth + 1)) return true;
    }
    return false;
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
// For `f(&t.field)` / `f(&arr[0])`, return the exact tracked subplace key when the subplace
// embeds a move resource. That lets a later use of `q` observe `t.field`'s moved-out state
// instead of only checking whether the root `t` is live.
//
// Returns the move-root or move-subplace referent that a pointer-returning call's args borrow,
// or null. Narrowed to KNOWN pointer-returning direct calls so a non-pointer result
// (`pk(&t) -> u32`) — which cannot retain the borrow — does not register an alias and the
// legit case still accepts.
pub fn callLaunderedMoveReferent(self: *Checker, init_expr: ast.Expr, state: *const std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) ?[]const u8 {
    if (callLaunderedMoveAliasReferent(self, init_expr, state, aliases)) |referent| return referent.key;
    return null;
}

fn callLaunderedMoveAliasReferent(self: *Checker, init_expr: ast.Expr, state: *const std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) ?AliasReferent {
    const ctx = self.move_ctx orelse return null;
    const call = switch (init_expr.kind) {
        .call => |c| c,
        .grouped => |inner| return callLaunderedMoveAliasReferent(self, inner.*, state, aliases),
        .cast => |c| return callLaunderedMoveAliasReferent(self, c.value.*, state, aliases),
        else => return null,
    };
    // `drop`/`forget_unchecked` are not borrow-laundering pointer factories.
    if (spine.isDropCall(call.callee.*) or spine.isForgetUncheckedCall(call.callee.*)) return null;
    const ret_ty = spine.directCallReturnType(call.callee.*, ctx.*) orelse return null;
    if (!spine.isPointerLike(spine.classifyTypeCtx(ret_ty, ctx.*))) return null;
    for (call.args) |arg| {
        if (fullDerefMoveSubplace(self, arg, state, aliases)) |referent| {
            if (state.get(referent.key)) |slot| {
                if (!slot.live) continue;
            }
            return .{ .key = referent.key, .place = referent.place, .full_deref = false };
        }
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
            if (slot.live and slot.alias_of == null) return .{ .key = root, .place = slot.place, .full_deref = false };
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
pub fn registerAggregateFieldAliases(
    self: *Checker,
    base: []const u8,
    base_place: ?MovePlace,
    escape_span: diagnostics.Span,
    init_expr: ast.Expr,
    state: *std.StringHashMap(MoveSlot),
    aliases: *const std.StringHashMap(ast.TypeExpr),
) void {
    const fields = switch (init_expr.kind) {
        .struct_literal => |f| f,
        .grouped => |inner| return registerAggregateFieldAliases(self, base, base_place, escape_span, inner.*, state, aliases),
        else => return,
    };
    for (fields) |field| {
        const field_place = if (base_place) |place| place.project(.{ .field = field.name.text }) else null;
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
            registerAggregateFieldAliases(self, key, field_place, escape_span, field.value, state, aliases);
            continue;
        }
        if (fieldExprIsArrayLiteral(field.value)) {
            const key = std.fmt.allocPrint(self.reporter.allocator, "{s}.{s}", .{ base, field.name.text }) catch {
                self.oom = true;
                continue;
            };
            registerArrayElementAliases(self, key, field_place, escape_span, field.value, state, aliases);
            self.reporter.allocator.free(key);
            continue;
        }
        // A field whose value is NOT a directly-trackable scalar borrow (`&t`/an alias of it)
        // and is not a nested aggregate shape with place identity falls back to the
        // CONSERVATIVE escape: mark the move root escaped (reject-at-move). This composes
        // the precise and conservative scans in one traversal so no nested borrow is lost.
        // (A plain non-borrow field value `.v = 5` has no move root, so this is a no-op there.)
        const referent = aliasReferentForExpr(self, field.value, state, aliases) orelse {
            markBorrowEscape(self, field.value, escape_span, state);
            continue;
        };
        if (!aliasReferentIsTracked(referent, state)) continue;
        const key = std.fmt.allocPrint(self.reporter.allocator, "{s}.{s}", .{ base, field.name.text }) catch {
            self.oom = true;
            continue;
        };
        self.move_place_keys.append(self.reporter.allocator, key) catch {
            self.oom = true;
            self.reporter.allocator.free(key);
            continue;
        };
        state.put(key, .{ .live = false, .span = field.value.span, .place = field_place, .alias_of = referent.key, .alias_place = referent.place }) catch {
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
    if (aliasStoragePlaceForExpr(self, expr, state)) |place| {
        if (aliasSlotForStoragePlace(place, state)) |slot| return slot;
        if (staleAliasWildcardSlotForConcretePlace(place, state)) |slot| return slot;
    }
    if (aliasPlaceKey(self, expr, state)) |key| {
        defer self.reporter.allocator.free(key);
        if (state.get(key)) |slot| {
            if (slot.alias_of != null) return slot;
        }
        if (wildcardAliasSlotForConcrete(key, state)) |slot| return slot;
    }
    if (aliasWildcardPlaceKey(self, expr, state)) |key| {
        defer self.reporter.allocator.free(key);
        if (state.get(key)) |slot| {
            if (slot.alias_of != null) return slot;
        }
    }
    if (allConcreteAliasSlotForWildcardExpr(self, expr, state)) |slot| return slot;
    const key = memberPlaceKey(self, expr) orelse return null;
    defer self.reporter.allocator.free(key);
    if (state.get(key)) |slot| {
        if (slot.alias_of != null) return slot;
    }
    return null;
}

pub fn recordAssignedAggregateFieldAliasOrEscape(
    self: *Checker,
    target: ast.Expr,
    value: ast.Expr,
    escape_span: diagnostics.Span,
    state: *std.StringHashMap(MoveSlot),
    aliases: *const std.StringHashMap(ast.TypeExpr),
) void {
    const key = aliasPlaceKey(self, target, state) orelse
        aliasWildcardPlaceKey(self, target, state) orelse
        memberPlaceKey(self, target) orelse {
        markBorrowEscape(self, value, escape_span, state);
        return;
    };
    const key_place = aliasStoragePlaceForExpr(self, target, state);

    const referent = aliasReferentForExpr(self, value, state, aliases) orelse {
        _ = state.remove(key);
        self.reporter.allocator.free(key);
        markBorrowEscape(self, value, escape_span, state);
        return;
    };
    if (!aliasReferentIsTracked(referent, state)) {
        _ = state.remove(key);
        self.reporter.allocator.free(key);
        return;
    }

    if (state.getPtr(key)) |slot| {
        slot.* = .{ .live = false, .span = value.span, .place = key_place, .alias_of = referent.key, .alias_place = referent.place };
        self.reporter.allocator.free(key);
        return;
    }

    self.move_place_keys.append(self.reporter.allocator, key) catch {
        self.oom = true;
        self.reporter.allocator.free(key);
        return;
    };
    state.put(key, .{ .live = false, .span = value.span, .place = key_place, .alias_of = referent.key, .alias_place = referent.place }) catch {
        self.oom = true;
    };
}

pub fn registerArrayElementAliases(
    self: *Checker,
    base: []const u8,
    base_place: ?MovePlace,
    escape_span: diagnostics.Span,
    init_expr: ast.Expr,
    state: *std.StringHashMap(MoveSlot),
    aliases: *const std.StringHashMap(ast.TypeExpr),
) void {
    const items = switch (init_expr.kind) {
        .array_literal => |array_items| array_items,
        .grouped => |inner| return registerArrayElementAliases(self, base, base_place, escape_span, inner.*, state, aliases),
        else => return,
    };
    for (items, 0..) |item, index| {
        const element_place = if (base_place) |place| place.project(.{ .constant_index = index }) else null;
        const key = std.fmt.allocPrint(self.reporter.allocator, "{s}[{d}]", .{ base, index }) catch {
            self.oom = true;
            continue;
        };
        if (fieldExprIsStructLiteral(item)) {
            self.move_place_keys.append(self.reporter.allocator, key) catch {
                self.oom = true;
                self.reporter.allocator.free(key);
                continue;
            };
            registerAggregateFieldAliases(self, key, element_place, escape_span, item, state, aliases);
            continue;
        }
        if (fieldExprIsArrayLiteral(item)) {
            registerArrayElementAliases(self, key, element_place, escape_span, item, state, aliases);
            self.reporter.allocator.free(key);
            continue;
        }
        recordAliasPlaceOrEscapeWithKey(self, key, element_place, item, escape_span, state, aliases);
    }
}

pub fn fieldExprIsArrayLiteral(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .array_literal => true,
        .grouped => |inner| fieldExprIsArrayLiteral(inner.*),
        else => false,
    };
}

pub fn recordAssignedAliasPlaceOrEscape(
    self: *Checker,
    target: ast.Expr,
    value: ast.Expr,
    escape_span: diagnostics.Span,
    state: *std.StringHashMap(MoveSlot),
    aliases: *const std.StringHashMap(ast.TypeExpr),
) void {
    const key = aliasPlaceKey(self, target, state) orelse
        aliasWildcardPlaceKey(self, target, state) orelse {
        markBorrowEscape(self, value, escape_span, state);
        return;
    };
    const key_place = aliasStoragePlaceForExpr(self, target, state);
    recordAliasPlaceOrEscapeWithKey(self, key, key_place, value, escape_span, state, aliases);
}

fn recordAliasPlaceOrEscapeWithKey(
    self: *Checker,
    key: []const u8,
    key_place: ?MovePlace,
    value: ast.Expr,
    escape_span: diagnostics.Span,
    state: *std.StringHashMap(MoveSlot),
    aliases: *const std.StringHashMap(ast.TypeExpr),
) void {
    const referent = aliasReferentForExpr(self, value, state, aliases) orelse {
        _ = state.remove(key);
        self.reporter.allocator.free(key);
        markBorrowEscape(self, value, escape_span, state);
        return;
    };
    if (!aliasReferentIsTracked(referent, state)) {
        _ = state.remove(key);
        self.reporter.allocator.free(key);
        return;
    }

    if (state.getPtr(key)) |slot| {
        slot.* = .{ .live = false, .span = value.span, .place = key_place, .alias_of = referent.key, .alias_place = referent.place };
        self.reporter.allocator.free(key);
        return;
    }

    self.move_place_keys.append(self.reporter.allocator, key) catch {
        self.oom = true;
        self.reporter.allocator.free(key);
        return;
    };
    state.put(key, .{ .live = false, .span = value.span, .place = key_place, .alias_of = referent.key, .alias_place = referent.place }) catch {
        self.oom = true;
    };
}

pub fn aliasPlaceSlot(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) ?MoveSlot {
    if (aliasStoragePlaceForExpr(self, expr, state)) |place| {
        if (aliasSlotForStoragePlace(place, state)) |slot| return slot;
        if (staleAliasWildcardSlotForConcretePlace(place, state)) |slot| return slot;
    }
    if (aliasPlaceKey(self, expr, state)) |key| {
        defer self.reporter.allocator.free(key);
        if (state.get(key)) |slot| {
            if (slot.alias_of != null) return slot;
        }
        if (wildcardAliasSlotForConcrete(key, state)) |slot| return slot;
    }
    if (aliasWildcardPlaceKey(self, expr, state)) |key| {
        defer self.reporter.allocator.free(key);
        if (state.get(key)) |slot| {
            if (slot.alias_of != null) return slot;
        }
    }
    if (allConcreteAliasSlotForWildcardExpr(self, expr, state)) |slot| return slot;
    return null;
}

fn aliasSlotForStoragePlace(place: MovePlace, state: *const std.StringHashMap(MoveSlot)) ?MoveSlot {
    var it = state.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr.*;
        if (slot.alias_of == null) continue;
        if (slot.place) |stored| {
            if (stored.eql(place)) return slot;
        }
    }
    return null;
}

fn staleAliasWildcardSlotForConcretePlace(place: MovePlace, state: *const std.StringHashMap(MoveSlot)) ?MoveSlot {
    var it = state.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr.*;
        if (slot.alias_of == null) continue;
        if (slot.place) |stored| {
            if (!stored.eql(place) and stored.conflicts(place) and aliasSlotReferentMoved(slot, state)) return slot;
        }
    }
    return null;
}

fn wildcardAliasSlotForConcrete(concrete_key: []const u8, state: *const std.StringHashMap(MoveSlot)) ?MoveSlot {
    var it = state.iterator();
    while (it.next()) |entry| {
        if (!wildcardMoveKeyMatchesConcrete(entry.key_ptr.*, concrete_key)) continue;
        if (entry.value_ptr.alias_of != null) return entry.value_ptr.*;
    }
    return null;
}

fn allConcreteAliasSlotForWildcardExpr(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) ?MoveSlot {
    const pattern = aliasWildcardPatternKeyAndLen(self, expr, state) orelse return null;
    const wildcard_key = pattern.key;
    defer self.reporter.allocator.free(wildcard_key);
    if (pattern.len_count == 0) return null;

    var acc = ConcreteAliasScan{};
    if (scanConcreteAliasPattern(self, wildcard_key, pattern.lens[0..pattern.len_count], state, &acc)) |stale| return stale;
    if (acc.all_present and acc.all_same) return acc.first_slot;
    return null;
}

const AliasWildcardPattern = struct {
    key: []const u8,
    lens: [4]usize = undefined,
    len_count: usize = 0,
};

const ConcreteAliasScan = struct {
    first_slot: ?MoveSlot = null,
    first_referent: ?[]const u8 = null,
    first_place: ?MovePlace = null,
    all_present: bool = true,
    all_same: bool = true,
};

fn scanConcreteAliasPattern(
    self: *Checker,
    key: []const u8,
    lens: []const usize,
    state: *const std.StringHashMap(MoveSlot),
    acc: *ConcreteAliasScan,
) ?MoveSlot {
    if (lens.len == 0) {
        const slot = state.get(key) orelse {
            acc.all_present = false;
            return null;
        };
        const referent = slot.alias_of orelse {
            acc.all_present = false;
            return null;
        };
        if (aliasSlotReferentMoved(slot, state)) return slot;
        if (acc.first_referent) |seen| {
            if (!std.mem.eql(u8, seen, referent)) acc.all_same = false;
            if (!sameMaybePlace(acc.first_place, slot.alias_place)) acc.all_same = false;
        } else {
            acc.first_referent = referent;
            acc.first_place = slot.alias_place;
            acc.first_slot = slot;
        }
        return null;
    }

    const marker = std.mem.indexOf(u8, key, "[*]") orelse {
        acc.all_present = false;
        return null;
    };
    const prefix = key[0..marker];
    const suffix = key[marker + 3 ..];
    for (0..lens[0]) |index| {
        const concrete_key = std.fmt.allocPrint(self.reporter.allocator, "{s}[{d}]{s}", .{ prefix, index, suffix }) catch {
            self.oom = true;
            return null;
        };
        defer self.reporter.allocator.free(concrete_key);
        if (scanConcreteAliasPattern(self, concrete_key, lens[1..], state, acc)) |stale| return stale;
    }
    return null;
}

fn aliasWildcardPatternKeyAndLen(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) ?AliasWildcardPattern {
    switch (expr.kind) {
        .grouped => |inner| return aliasWildcardPatternKeyAndLen(self, inner.*, state),
        .member => |m| {
            const base = aliasWildcardPatternKeyAndLen(self, m.base.*, state) orelse return null;
            errdefer self.reporter.allocator.free(base.key);
            const key = std.fmt.allocPrint(self.reporter.allocator, "{s}.{s}", .{ base.key, m.name.text }) catch {
                self.oom = true;
                self.reporter.allocator.free(base.key);
                return null;
            };
            self.reporter.allocator.free(base.key);
            return .{ .key = key, .lens = base.lens, .len_count = base.len_count };
        },
        .index => |ix| {
            if (aliasWildcardPatternKeyAndLen(self, ix.base.*, state)) |base| {
                errdefer self.reporter.allocator.free(base.key);
                if (aliasPatternConstIndex(self, ix, state)) |index| {
                    const key = std.fmt.allocPrint(self.reporter.allocator, "{s}[{d}]", .{ base.key, index }) catch {
                        self.oom = true;
                        self.reporter.allocator.free(base.key);
                        return null;
                    };
                    self.reporter.allocator.free(base.key);
                    return .{ .key = key, .lens = base.lens, .len_count = base.len_count };
                }
                if (base.len_count >= 4) {
                    self.reporter.allocator.free(base.key);
                    return null;
                }
                const len = dynamicAliasIndexLen(self, ix, state) orelse {
                    self.reporter.allocator.free(base.key);
                    return null;
                };
                const key = std.fmt.allocPrint(self.reporter.allocator, "{s}[*]", .{base.key}) catch {
                    self.oom = true;
                    self.reporter.allocator.free(base.key);
                    return null;
                };
                var lens = base.lens;
                lens[base.len_count] = len;
                self.reporter.allocator.free(base.key);
                return .{ .key = key, .lens = lens, .len_count = base.len_count + 1 };
            }
            const ctx = self.move_ctx orelse return null;
            const base = aliasPlaceKey(self, ix.base.*, state) orelse return null;
            errdefer self.reporter.allocator.free(base);
            const base_ty = resolveAliasType(aliasPlaceBaseType(ix.base.*, state) orelse
                spine.exprResultType(ix.base.*, ctx.*) orelse {
                self.reporter.allocator.free(base);
                return null;
            }, ctx.*);
            const array = switch (base_ty.kind) {
                .array => |node| node,
                else => {
                    self.reporter.allocator.free(base);
                    return null;
                },
            };
            const len = parseArrayLen(array.len, ctx.const_fns, ctx.const_globals) orelse {
                self.reporter.allocator.free(base);
                return null;
            };
            if (len <= 1 or aliasPlaceIndex(self, ix, state) != null) {
                self.reporter.allocator.free(base);
                return null;
            }
            const key = std.fmt.allocPrint(self.reporter.allocator, "{s}[*]", .{base}) catch {
                self.oom = true;
                self.reporter.allocator.free(base);
                return null;
            };
            self.reporter.allocator.free(base);
            var lens: [4]usize = undefined;
            lens[0] = len;
            return .{ .key = key, .lens = lens, .len_count = 1 };
        },
        else => return null,
    }
}

fn dynamicAliasIndexLen(self: *Checker, ix: anytype, state: *const std.StringHashMap(MoveSlot)) ?usize {
    const ctx = self.move_ctx orelse return null;
    if (aliasPlaceIndex(self, ix, state) != null) return null;
    const base_ty = resolveAliasType(aliasIndexExprType(self, ix.base.*, state, ctx.*) orelse
        aliasPlaceBaseType(ix.base.*, state) orelse
        spine.exprResultType(ix.base.*, ctx.*) orelse
        return null, ctx.*);
    const array = switch (base_ty.kind) {
        .array => |node| node,
        else => return null,
    };
    const len = parseArrayLen(array.len, ctx.const_fns, ctx.const_globals) orelse return null;
    if (len <= 1) return null;
    return len;
}

fn aliasIndexExprType(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot), ctx: Context) ?ast.TypeExpr {
    switch (expr.kind) {
        .grouped => |inner| return aliasIndexExprType(self, inner.*, state, ctx),
        .ident => |id| {
            const slot = state.get(id.text) orelse return spine.exprResultType(expr, ctx);
            return slot.ty orelse spine.exprResultType(expr, ctx);
        },
        .member => |m| {
            const base_ty = aliasIndexExprType(self, m.base.*, state, ctx) orelse
                spine.exprResultType(m.base.*, ctx) orelse
                return spine.exprResultType(expr, ctx);
            return spine.structFieldType(base_ty, m.name.text, ctx) orelse spine.exprResultType(expr, ctx);
        },
        .index => |ix| {
            const base_ty = resolveAliasType(aliasIndexExprType(self, ix.base.*, state, ctx) orelse
                spine.exprResultType(ix.base.*, ctx) orelse
                return spine.exprResultType(expr, ctx), ctx);
            const array = switch (base_ty.kind) {
                .array => |node| node,
                else => return spine.exprResultType(expr, ctx),
            };
            return array.child.*;
        },
        else => return spine.exprResultType(expr, ctx),
    }
}

fn aliasSlotReferentMoved(slot: MoveSlot, state: *const std.StringHashMap(MoveSlot)) bool {
    const referent = slot.alias_of orelse return false;
    if (referentPlaceMoved(referent, slot.alias_place, state)) return true;
    if (slot.alias_place != null) return false;
    if (state.get(referent)) |r| {
        if (!r.live) return true;
    }
    return false;
}

fn referentPlaceMoved(referent: []const u8, place: ?MovePlace, state: *const std.StringHashMap(MoveSlot)) bool {
    if (place) |typed| {
        if (state.get(typed.root)) |root| {
            if (!root.live) return true;
        }
        return stateHasMovedPlace(typed, state) or stateHasMovedChildPlace(typed, state) or stateHasMovedConflictingPlace(typed, state);
    }
    return legacySubplaceReferentMoved(referent, state);
}

fn legacySubplaceReferentMoved(referent: []const u8, state: *const std.StringHashMap(MoveSlot)) bool {
    return isMoveSubplaceKey(referent) and
        (state.contains(referent) or concretePlaceHasWildcardMove(referent, state) or wildcardMoveConflictsWithConcreteSubplace(referent, state));
}

pub fn aliasPlaceKey(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) ?[]const u8 {
    switch (expr.kind) {
        .grouped => |inner| return aliasPlaceKey(self, inner.*, state),
        .ident => |id| return self.reporter.allocator.dupe(u8, id.text) catch {
            self.oom = true;
            return null;
        },
        .member => |m| {
            const base = aliasPlaceKey(self, m.base.*, state) orelse return null;
            defer self.reporter.allocator.free(base);
            return std.fmt.allocPrint(self.reporter.allocator, "{s}.{s}", .{ base, m.name.text }) catch {
                self.oom = true;
                return null;
            };
        },
        .index => |ix| {
            const base = aliasPlaceKey(self, ix.base.*, state) orelse return null;
            defer self.reporter.allocator.free(base);
            const index = aliasPlaceIndex(self, ix, state) orelse return null;
            return std.fmt.allocPrint(self.reporter.allocator, "{s}[{d}]", .{ base, index }) catch {
                self.oom = true;
                return null;
            };
        },
        else => return null,
    }
}

fn aliasPlaceIndex(self: *Checker, ix: anytype, state: *const std.StringHashMap(MoveSlot)) ?usize {
    const ctx = self.move_ctx orelse return null;
    if (constIndexValue(self, ix.index.*, state, ctx.*)) |index| return index;

    const base_ty = resolveAliasType(aliasPlaceBaseType(ix.base.*, state) orelse
        spine.exprResultType(ix.base.*, ctx.*) orelse
        return null, ctx.*);
    const array = switch (base_ty.kind) {
        .array => |node| node,
        else => return null,
    };
    const len = parseArrayLen(array.len, ctx.const_fns, ctx.const_globals) orelse return null;
    if (len != 1) return null;
    return 0;
}

fn aliasPatternConstIndex(self: *Checker, ix: anytype, state: *const std.StringHashMap(MoveSlot)) ?usize {
    const ctx = self.move_ctx orelse return null;
    if (constIndexValue(self, ix.index.*, state, ctx.*)) |index| return index;
    const base_ty = resolveAliasType(spine.exprResultType(ix.base.*, ctx.*) orelse return null, ctx.*);
    const array = switch (base_ty.kind) {
        .array => |node| node,
        else => return null,
    };
    const len = parseArrayLen(array.len, ctx.const_fns, ctx.const_globals) orelse return null;
    if (len != 1) return null;
    return 0;
}

fn aliasWildcardPlaceKey(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) ?[]const u8 {
    switch (expr.kind) {
        .grouped => |inner| return aliasWildcardPlaceKey(self, inner.*, state),
        .member => |m| {
            const base = aliasWildcardPlaceKey(self, m.base.*, state) orelse return null;
            defer self.reporter.allocator.free(base);
            return std.fmt.allocPrint(self.reporter.allocator, "{s}.{s}", .{ base, m.name.text }) catch {
                self.oom = true;
                return null;
            };
        },
        .index => |ix| {
            const ctx = self.move_ctx orelse return null;
            const base = aliasPlaceKey(self, ix.base.*, state) orelse return null;
            errdefer self.reporter.allocator.free(base);
            const base_ty = resolveAliasType(aliasPlaceBaseType(ix.base.*, state) orelse
                spine.exprResultType(ix.base.*, ctx.*) orelse {
                self.reporter.allocator.free(base);
                return null;
            }, ctx.*);
            const array = switch (base_ty.kind) {
                .array => |node| node,
                else => {
                    self.reporter.allocator.free(base);
                    return null;
                },
            };
            const len = parseArrayLen(array.len, ctx.const_fns, ctx.const_globals) orelse {
                self.reporter.allocator.free(base);
                return null;
            };
            if (len <= 1) {
                self.reporter.allocator.free(base);
                return null;
            }
            const key = std.fmt.allocPrint(self.reporter.allocator, "{s}[*]", .{base}) catch {
                self.reporter.allocator.free(base);
                self.oom = true;
                return null;
            };
            self.reporter.allocator.free(base);
            return key;
        },
        else => return null,
    }
}

fn aliasPlaceBaseType(expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) ?ast.TypeExpr {
    switch (expr.kind) {
        .grouped => |inner| return aliasPlaceBaseType(inner.*, state),
        .ident => |id| {
            const slot = state.get(id.text) orelse return null;
            if (!slot.type_only) return null;
            return slot.ty;
        },
        else => return null,
    }
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
pub fn moveBorrow(self: *Checker, expr: ast.Expr, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) void {
    switch (expr.kind) {
        .ident => |id| {
            if (state.getPtr(id.text)) |slot| {
                if (slot.type_only) {
                    return;
                } else if (slot.alias_of != null) {
                    checkStaleAlias(self, id.text, slot.*, expr.span, state);
                } else if (!slot.live) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "borrow of linear `move` value after it was moved");
                }
            }
        },
        .grouped, .deref => |inner| moveBorrow(self, inner.*, state, aliases),
        .address_of => |inner| {
            moveBorrow(self, inner.*, state, aliases);
            if (placeKeyAndType(self, inner.*, state)) |pp| {
                if (self.typeEmbedsMoveByValue(pp.ty, aliases) and hasMovedSubplace(pp.place, state)) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "borrow of linear `move` place after one of its child places was moved out");
                }
            }
        },
        .try_expr => |inner| {
            // `?` is an exit edge even in a borrow position: on error it returns, so any
            // other live `move` value would leak unless registered with `defer`.
            moveBorrow(self, inner.operand.*, state, aliases);
            checkMoveExitEdge(self, state, "linear `move` value is still live where `?` may return on error (consume it before `?`, or register it with `defer`)");
        },
        .member => |m| {
            moveBorrow(self, m.base.*, state, aliases);
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
        .index => |ix| {
            moveBorrow(self, ix.base.*, state, aliases);
            if (placeExprIsMoved(self, expr, state)) {
                self.errorCode(expr.span, "E_USE_AFTER_MOVE", "borrow of linear `move` array element after it was moved out");
            }
            if (aliasPlaceSlot(self, expr, state)) |slot| {
                checkStaleAlias(self, "", slot, expr.span, state);
            }
        },
        .slice => |s| {
            moveBorrow(self, s.base.*, state, aliases);
            moveBorrow(self, s.start.*, state, aliases);
            moveBorrow(self, s.end.*, state, aliases);
        },
        .cast => |c| moveBorrow(self, c.value.*, state, aliases),
        .unary => |u| moveBorrow(self, u.expr.*, state, aliases),
        .binary => |b| {
            moveBorrow(self, b.left.*, state, aliases);
            moveBorrow(self, b.right.*, state, aliases);
        },
        .block => |b| _ = moveScopedBlock(self, b, state, aliases),
        .call => |c| for (c.args) |arg| {
            checkAggregateAliasArgument(self, arg, state);
            moveBorrow(self, arg, state, aliases);
        },
        else => {},
    }
}

fn deferredBorrowPlaceKey(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) ?PlaceKeyTy {
    switch (expr.kind) {
        .grouped => |inner| return deferredBorrowPlaceKey(self, inner.*, state, aliases),
        else => {},
    }
    const pp = placeKeyAndType(self, expr, state) orelse {
        return wildcardMoveIndexedPlaceKey(self, expr, state, aliases);
    };
    if (!self.typeEmbedsMoveByValue(pp.ty, aliases)) return null;
    return pp;
}

fn markDeferredBorrowReferent(self: *Checker, referent: []const u8, place: ?MovePlace, span: diagnostics.Span, state: *std.StringHashMap(MoveSlot)) void {
    const root = referentRoot(referent, place);
    const root_slot = state.getPtr(root) orelse return;
    if (root_slot.cleanup_local) {
        checkStaleAlias(self, "", .{ .live = false, .span = span, .alias_of = referent, .alias_place = place }, span, state);
        return;
    }
    if (!root_slot.live) {
        self.errorCode(span, "E_USE_AFTER_MOVE", "defer borrows a linear `move` value after it was moved");
        return;
    }
    if (place) |borrowed| {
        if (borrowed.isSubplace()) {
            if (stateHasMovedPlace(borrowed, state) or stateHasMovedChildPlace(borrowed, state) or stateHasMovedConflictingPlace(borrowed, state)) {
                self.errorCode(span, "E_USE_AFTER_MOVE", "defer borrows a linear `move` field or array element after it was moved out");
                return;
            }
        } else if (hasMovedSubplace(borrowed, state)) {
            self.errorCode(span, "E_USE_AFTER_MOVE", "defer borrows a linear `move` value after one of its fields or elements was moved out");
            return;
        }
    } else if (referentPlaceMoved(referent, null, state)) {
        self.errorCode(span, "E_USE_AFTER_MOVE", "defer borrows a linear `move` field or array element after it was moved out");
        return;
    } else if (state.get(referent)) |referent_slot| {
        if (referent_slot.place != null and hasMovedSubplace(referent_slot.place.?, state)) {
            self.errorCode(span, "E_USE_AFTER_MOVE", "defer borrows a linear `move` value after one of its fields or elements was moved out");
            return;
        }
    }
    if (root_slot.deferred_borrow) |existing| {
        if (std.mem.eql(u8, existing, referent)) {
            if (place) |new_place| {
                if (root_slot.deferred_borrow_place == null or placeHasWildcardProjection(new_place)) {
                    root_slot.deferred_borrow_place = new_place;
                }
            } else if (root_slot.deferred_borrow_place == null) {
                root_slot.deferred_borrow_place = place orelse
                    (if (state.get(referent)) |referent_slot| referent_slot.place else null);
            }
            return;
        }
        root_slot.deferred_borrow = root;
        root_slot.deferred_borrow_place = root_slot.place;
        return;
    }
    root_slot.deferred_borrow = referent;
    root_slot.deferred_borrow_place = place orelse
        (if (state.get(referent)) |referent_slot| referent_slot.place else null) orelse
        root_slot.place;
}

fn moveDeferSliceBase(self: *Checker, expr: ast.Expr, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) void {
    switch (expr.kind) {
        .grouped => |inner| moveDeferSliceBase(self, inner.*, state, aliases),
        .struct_literal => |fields| for (fields) |field| moveDefer(self, field.value, state, aliases),
        .array_literal => |items| for (items) |item| moveDefer(self, item, state, aliases),
        else => moveBorrow(self, expr, state, aliases),
    }
}

// `defer <expr>`: reserve the move bindings the deferred expr will consume.
pub fn moveDefer(self: *Checker, expr: ast.Expr, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) void {
    switch (expr.kind) {
        .ident => |id| {
            if (state.getPtr(id.text)) |slot| {
                if (slot.alias_of) |referent| {
                    markDeferredBorrowReferent(self, referent, deferredAliasBorrowPlace(slot.alias_place), expr.span, state);
                } else if (slot.cleanup_local) {
                    consumeTrackedMoveBinding(self, id.text, expr.span, state);
                } else if (!slot.live) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "defer consumes a linear `move` value already moved");
                } else {
                    slot.deferred = true;
                }
            }
        },
        .grouped => |inner| moveDefer(self, inner.*, state, aliases),
        .cast => |c| moveDefer(self, c.value.*, state, aliases),
        .unary => |u| moveDefer(self, u.expr.*, state, aliases),
        .address_of => |inner| {
            if (deferredBorrowPlaceKey(self, inner.*, state, aliases)) |pp| {
                const root = pp.place.root;
                if (state.get(root)) |slot| {
                    if (slot.cleanup_local) {
                        moveBorrow(self, inner.*, state, aliases);
                    } else {
                        markDeferredBorrowReferent(self, pp.key, pp.place, expr.span, state);
                    }
                } else {
                    markDeferredBorrowReferent(self, pp.key, pp.place, expr.span, state);
                }
            } else {
                moveBorrow(self, inner.*, state, aliases);
            }
        },
        .call => |c| for (c.args) |arg| {
            checkAggregateAliasArgument(self, arg, state);
            if (callLaunderedMoveAliasReferent(self, arg, state, aliases)) |referent| {
                markDeferredBorrowReferent(self, referent.key, deferredAliasBorrowPlace(referent.place), arg.span, state);
                continue;
            }
            moveDefer(self, arg, state, aliases);
        },
        .member => |m| {
            moveBorrow(self, m.base.*, state, aliases);
            if (aggregateFieldAliasSlot(self, expr, state)) |slot| {
                if (slot.alias_of) |referent| markDeferredBorrowReferent(self, referent, deferredAliasBorrowPlace(slot.alias_place), expr.span, state);
                return;
            }
            // `defer free(p.field)`: reserve the move field for lexical cleanup so it is
            // neither leaked at exit nor moved out before the defer runs.
            if (moveFieldPlaceKey(self, expr, m, state, aliases)) |pp| {
                if (deferredBorrowConflictsWithTrackedPlace(pp.place, state)) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "defer cannot consume a linear `move` field already borrowed by a deferred expression");
                } else if (stateContainsMovePlace(pp.place, state) or hasMovedSubplace(pp.place, state)) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "defer reserves a linear `move` field already moved out");
                } else {
                    state.put(pp.key, .{ .live = true, .span = expr.span, .place = pp.place, .deferred = true }) catch {
                        self.oom = true;
                    };
                }
            }
        },
        .index => |ix| {
            moveBorrow(self, ix.base.*, state, aliases);
            moveConsume(self, ix.index.*, state, aliases);
            if (aliasPlaceSlot(self, expr, state)) |slot| {
                if (slot.alias_of) |referent| markDeferredBorrowReferent(self, referent, deferredAliasBorrowPlace(slot.alias_place), expr.span, state);
                return;
            }
            // `defer free(arr[0])`: reserve a tracked constant-index element place for
            // lexical cleanup, matching field-place defer behavior.
            if (moveIndexedPlaceKey(self, expr, state, aliases)) |pp| {
                if (deferredBorrowConflictsWithTrackedPlace(pp.place, state)) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "defer cannot consume a linear `move` array element already borrowed by a deferred expression");
                } else if (stateContainsMovePlace(pp.place, state) or indexedPlaceHasWildcardMove(self, expr, state, aliases) or stateHasConflictingMovePlace(pp.place, state)) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "defer reserves a linear `move` array element already moved out");
                } else {
                    state.put(pp.key, .{ .live = true, .span = expr.span, .place = pp.place, .deferred = true }) catch {
                        self.oom = true;
                    };
                }
            } else if (wildcardMoveIndexedPlaceKey(self, expr, state, aliases)) |pp| {
                if (deferredBorrowConflictsWithTrackedPlace(pp.place, state)) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "defer cannot consume a linear `move` array element already borrowed by a deferred expression");
                } else if (stateContainsMovePlace(pp.place, state) or stateHasConflictingMovePlace(pp.place, state)) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "defer reserves a linear `move` array element already moved out");
                } else {
                    state.put(pp.key, .{ .live = true, .span = expr.span, .place = pp.place, .deferred = true }) catch {
                        self.oom = true;
                    };
                }
            } else if (nonNameableSingletonMoveIndex(self, expr, state, aliases)) {
                moveDefer(self, ix.base.*, state, aliases);
            } else if (arrayIndexEmbedsMove(self, expr, state, aliases)) {
                self.errorCode(expr.span, "E_MOVE_ARRAY_UNSUPPORTED", "cannot defer a linear `move` array element through a non-constant index; element ownership is only tracked for constant indexes");
            }
        },
        .slice => |s| {
            moveDeferSliceBase(self, s.base.*, state, aliases);
            moveDefer(self, s.start.*, state, aliases);
            moveDefer(self, s.end.*, state, aliases);
        },
        .binary => |b| {
            moveDefer(self, b.left.*, state, aliases);
            switch (b.op) {
                .logical_and, .logical_or => moveDeferShortCircuitRhs(self, b.right.*, state, aliases),
                else => moveDefer(self, b.right.*, state, aliases),
            }
        },
        .struct_literal => |fields| for (fields) |field| moveDefer(self, field.value, state, aliases),
        .array_literal => |items| for (items) |item| moveDefer(self, item, state, aliases),
        .block => |b| moveDeferBlock(self, b, state, aliases),
        else => {},
    }
}

fn moveDeferBlock(self: *Checker, block: ast.Block, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) void {
    var before = cloneMoveState(self, state);
    defer before.deinit();
    for (block.items) |stmt| moveDeferStmt(self, stmt, state, &before, aliases);
    reportMoveLocalsLeavingScope(self, state, &before, "linear `move` value declared in this deferred cleanup block is never consumed before cleanup ends");

    var scoped = std.StringHashMap(MoveSlot).init(self.reporter.allocator);
    defer scoped.deinit();
    var it = before.iterator();
    while (it.next()) |entry| {
        if (isTrackedMoveSubplace(entry.value_ptr.*, entry.key_ptr.*) and !state.contains(entry.key_ptr.*)) {
            continue;
        }
        const slot = state.get(entry.key_ptr.*) orelse entry.value_ptr.*;
        scoped.put(entry.key_ptr.*, slot) catch {
            self.oom = true;
        };
    }
    var state_it = state.iterator();
    while (state_it.next()) |entry| {
        if (before.contains(entry.key_ptr.*)) continue;
        if (!moveSubplaceRootInOuter(entry.value_ptr.*, entry.key_ptr.*, &before)) continue;
        scoped.put(entry.key_ptr.*, entry.value_ptr.*) catch {
            self.oom = true;
        };
    }
    replaceMoveState(self, state, &scoped);
}

fn cleanupLocalAliasReferent(self: *Checker, init: ast.Expr, state: *const std.StringHashMap(MoveSlot), outer: *const std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) ?AliasReferent {
    switch (init.kind) {
        .grouped => |inner| return cleanupLocalAliasReferent(self, inner.*, state, outer, aliases),
        else => {},
    }
    const referent = aliasReferentForExpr(self, init, state, aliases) orelse return null;
    if (outer.contains(aliasReferentRoot(referent))) return null;
    if (!aliasReferentIsTracked(referent, state)) return null;
    return referent;
}

fn recordDeferredIdentAssignmentAlias(self: *Checker, name: ast.Ident, value: ast.Expr, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) void {
    if (aliasReferentForExpr(self, value, state, aliases)) |referent| {
        if (aliasReferentIsTracked(referent, state)) {
            if (state.getPtr(name.text)) |slot| {
                slot.alias_of = referent.key;
                slot.alias_place = referent.place;
                slot.live = false;
                slot.full_deref_alias = referent.full_deref;
            } else {
                state.put(name.text, .{ .live = false, .span = name.span, .place = .{ .root = name.text }, .alias_of = referent.key, .alias_place = referent.place, .cleanup_local = true, .full_deref_alias = referent.full_deref }) catch {
                    self.oom = true;
                };
            }
            return;
        }
    }
    if (state.getPtr(name.text)) |slot| {
        if (slot.alias_of != null) {
            _ = state.remove(name.text);
        }
    }
}

fn moveDeferStmt(self: *Checker, stmt: ast.Stmt, state: *std.StringHashMap(MoveSlot), outer: *const std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) void {
    switch (stmt.kind) {
        .let_decl, .var_decl => |decl| {
            if (decl.init) |init| {
                if (cleanupLocalAliasReferent(self, init, state, outer, aliases) != null) {
                    moveBorrow(self, init, state, aliases);
                } else {
                    moveDefer(self, init, state, aliases);
                }
            }
            trackDeferredCleanupLocal(self, decl, state, aliases);
        },
        .@"return" => |maybe| {
            if (maybe) |expr| moveDefer(self, expr, state, aliases);
        },
        .expr, .assert, .@"defer" => |expr| moveDefer(self, expr, state, aliases),
        .assignment => |a| {
            moveBorrow(self, a.target, state, aliases);
            moveDefer(self, a.value, state, aliases);
            switch (a.target.kind) {
                .ident => |id| recordDeferredIdentAssignmentAlias(self, id, a.value, state, aliases),
                .member => recordAssignedAggregateFieldAliasOrEscape(self, a.target, a.value, a.target.span, state, aliases),
                .index => recordAssignedAliasPlaceOrEscape(self, a.target, a.value, a.target.span, state, aliases),
                else => {},
            }
            markBorrowEscapeCapturedCallResult(self, a.value, a.target.span, state, aliases);
        },
        .block, .unsafe_block, .comptime_block => |b| moveDeferBlock(self, b, state, aliases),
        .contract_block => |c| moveDeferBlock(self, c.block, state, aliases),
        .if_let => |n| {
            moveDefer(self, n.value, state, aliases);
            var then_state = cloneMoveState(self, state);
            defer then_state.deinit();
            var else_state = cloneMoveState(self, state);
            defer else_state.deinit();
            moveDeferBlock(self, n.then_block, &then_state, aliases);
            if (n.else_block) |else_block| moveDeferBlock(self, else_block, &else_state, aliases);
            joinMoveBranches(self, state, &then_state, false, &else_state, false);
        },
        .@"switch" => |sw| {
            moveDefer(self, sw.subject, state, aliases);
            var joined: ?std.StringHashMap(MoveSlot) = null;
            defer if (joined) |*m| m.deinit();
            for (sw.arms) |arm| {
                var arm_state = cloneMoveState(self, state);
                defer arm_state.deinit();
                switch (arm.body) {
                    .block => |b| moveDeferBlock(self, b, &arm_state, aliases),
                    .expr => |expr| moveDefer(self, expr, &arm_state, aliases),
                }
                if (joined) |*m| {
                    mergeMoveBranches(self, m, m, &arm_state);
                } else {
                    joined = cloneMoveState(self, &arm_state);
                }
            }
            if (joined) |*m| replaceMoveState(self, state, m);
        },
        .loop => |l| {
            if (l.iterable) |iter| {
                var condition_state = cloneMoveState(self, state);
                defer condition_state.deinit();
                moveDefer(self, iter, &condition_state, aliases);
                reportLoopOuterResourceChanges(self, state, &condition_state);
            }
            var body_state = cloneMoveState(self, state);
            defer body_state.deinit();
            moveDeferBlock(self, l.body, &body_state, aliases);
            reportLoopOuterResourceChanges(self, state, &body_state);
        },
        else => {},
    }
}

fn trackDeferredCleanupLocal(self: *Checker, decl: ast.LocalDecl, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) void {
    if (decl.names.len == 0) return;
    var binding_ty: ?ast.TypeExpr = decl.ty;
    if (binding_ty == null) {
        if (decl.init) |init_expr| {
            if (self.move_ctx) |mctx| binding_ty = spine.exprResultType(init_expr, mctx.*);
        }
    }
    if (binding_ty) |ty| {
        if (self.typeEmbedsMoveByValue(ty, aliases)) {
            state.put(decl.names[0].text, .{ .live = true, .span = decl.names[0].span, .place = .{ .root = decl.names[0].text }, .ty = ty, .cleanup_local = true }) catch {
                self.oom = true;
            };
            return;
        }
    }
    if (decl.init) |init| {
        if (aliasReferentForExpr(self, init, state, aliases)) |referent| {
            if (aliasReferentIsTracked(referent, state)) {
                state.put(decl.names[0].text, .{ .live = false, .span = decl.names[0].span, .place = .{ .root = decl.names[0].text }, .alias_of = referent.key, .alias_place = referent.place, .cleanup_local = true, .full_deref_alias = referent.full_deref }) catch {
                    self.oom = true;
                };
            }
        } else if (init.kind == .struct_literal) {
            registerAggregateFieldAliases(self, decl.names[0].text, .{ .root = decl.names[0].text }, decl.names[0].span, init, state, aliases);
        } else if (init.kind == .array_literal) {
            registerArrayElementAliases(self, decl.names[0].text, .{ .root = decl.names[0].text }, decl.names[0].span, init, state, aliases);
        }
        markBorrowEscapeCapturedCallResult(self, init, decl.names[0].span, state, aliases);
    }
}
