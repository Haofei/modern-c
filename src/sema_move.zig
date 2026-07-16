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
const sema_model = @import("sema_model.zig");

const sema = @import("sema.zig");
const spine = sema;
const Checker = sema.Checker;
const MoveSlot = sema.MoveSlot;
const LoopMoveFrame = sema.LoopMoveFrame;
const LoopMoveExitKind = sema_model.LoopMoveExitKind;
const Context = sema.Context;
const parseArrayLen = array_len.parseArrayLen;
const resolveAliasType = sema_type.resolveAliasType;

const ArrayMoveShape = struct { len: usize, embeds: bool };

const MoveCfgJoinPolicy = union(enum) {
    generic,
    loop_condition,
    short_circuit: struct {
        span: diagnostics.Span,
        deferred: bool,
    },
};

// The first production consumer of the move CFG.  Unlike the small model-level
// worklist tests, this carries the real ownership state used by the checker.
// Transfer functions still retain a block-local MoveSlot map for bindings and
// compatibility metadata. Ownership subplaces are matched by MovePlace at joins,
// rather than by their formatted map keys.
const MoveStateCfgWorklist = struct {
    allocator: std.mem.Allocator,
    cfg: *const sema_model.MoveCfg,
    states: []?std.StringHashMap(MoveSlot),
    queued: []bool,
    // A deferred cleanup loop widens its zero-iteration/backedge states and
    // reports the resulting outer-resource change as E_MOVE_LOOP_RESOURCE.
    // Its internal CFG joins must still merge conservatively, but must not also
    // produce ordinary branch diagnostics for that same widening.
    report_join_diagnostics: bool = true,
    join_policy: MoveCfgJoinPolicy = .generic,
    queue: std.ArrayListUnmanaged(sema_model.MoveCfgBlockId) = .empty,

    fn init(self: *Checker, cfg: *const sema_model.MoveCfg, entry: sema_model.MoveCfgBlockId, state: *const std.StringHashMap(MoveSlot)) ?MoveStateCfgWorklist {
        const states = self.reporter.allocator.alloc(?std.StringHashMap(MoveSlot), cfg.blocks.items.len) catch {
            self.oom = true;
            return null;
        };
        errdefer self.reporter.allocator.free(states);
        for (states) |*slot| slot.* = null;
        const queued = self.reporter.allocator.alloc(bool, cfg.blocks.items.len) catch {
            self.oom = true;
            return null;
        };
        @memset(queued, false);

        var worklist = MoveStateCfgWorklist{ .allocator = self.reporter.allocator, .cfg = cfg, .states = states, .queued = queued };
        worklist.states[entry] = cloneMoveState(self, state);
        worklist.enqueue(self, entry);
        return worklist;
    }

    fn deinit(self: *MoveStateCfgWorklist) void {
        for (self.states) |*state| {
            if (state.*) |*map| map.deinit();
        }
        self.queue.deinit(self.allocator);
        self.allocator.free(self.queued);
        self.allocator.free(self.states);
    }

    fn enqueue(self: *MoveStateCfgWorklist, checker: *Checker, block: sema_model.MoveCfgBlockId) void {
        if (self.queued[block]) return;
        self.queue.append(self.allocator, block) catch {
            checker.oom = true;
            return;
        };
        self.queued[block] = true;
    }

    fn pop(self: *MoveStateCfgWorklist) ?sema_model.MoveCfgBlockId {
        if (self.queue.items.len == 0) return null;
        const block = self.queue.orderedRemove(0);
        self.queued[block] = false;
        return block;
    }

    fn statePtr(self: *MoveStateCfgWorklist, block: sema_model.MoveCfgBlockId) ?*std.StringHashMap(MoveSlot) {
        if (self.states[block]) |*state| return state;
        return null;
    }

    fn suppressJoinDiagnostics(self: *MoveStateCfgWorklist) void {
        self.report_join_diagnostics = false;
    }

    fn useShortCircuitJoinPolicy(self: *MoveStateCfgWorklist, span: diagnostics.Span, deferred: bool) void {
        self.join_policy = .{ .short_circuit = .{ .span = span, .deferred = deferred } };
    }

    fn useLoopConditionJoinPolicy(self: *MoveStateCfgWorklist) void {
        self.join_policy = .loop_condition;
    }

    // All real-state CFG joins enter here. Callers may omit a successor when an
    // AST transfer has already run for that block, but cannot reimplement the
    // ownership merge or worklist requeue policy themselves.
    fn propagateSuccessor(self: *MoveStateCfgWorklist, checker: *Checker, to: sema_model.MoveCfgBlockId, outgoing: *const std.StringHashMap(MoveSlot)) void {
        const changed = if (self.states[to]) |*joined| blk: {
            var before = cloneMoveState(checker, joined);
            defer before.deinit();
            switch (self.join_policy) {
                .generic => mergeMoveBranchesImpl(checker, joined, joined, outgoing, self.report_join_diagnostics),
                .loop_condition => reportLoopOuterResourceChanges(checker, joined, outgoing),
                .short_circuit => |policy| mergeShortCircuitMoveStates(checker, joined, outgoing, policy.span, policy.deferred),
            }
            break :blk !moveStatesEqual(joined, &before);
        } else blk: {
            self.states[to] = cloneMoveState(checker, outgoing);
            break :blk true;
        };
        if (changed) self.enqueue(checker, to);
    }

    fn propagateSuccessorsExcept(self: *MoveStateCfgWorklist, checker: *Checker, from: sema_model.MoveCfgBlockId, outgoing: *const std.StringHashMap(MoveSlot), excluded: ?sema_model.MoveCfgBlockId) void {
        for (self.cfg.edges.items) |edge| {
            if (edge.from != from or edge.to == excluded) continue;
            self.propagateSuccessor(checker, edge.to, outgoing);
        }
    }

    fn propagateSuccessors(self: *MoveStateCfgWorklist, checker: *Checker, from: sema_model.MoveCfgBlockId, outgoing: *const std.StringHashMap(MoveSlot)) void {
        self.propagateSuccessorsExcept(checker, from, outgoing, null);
    }
};

const LinearMoveCfg = struct {
    cfg: sema_model.MoveCfg,
    entry: sema_model.MoveCfgBlockId,
    body: sema_model.MoveCfgBlockId,
    exit: sema_model.MoveCfgBlockId,

    fn deinit(self: *LinearMoveCfg) void {
        self.cfg.deinit();
    }
};

fn linearMoveCfg(self: *Checker, exit_kind: sema_model.MoveCfgBlockKind) ?LinearMoveCfg {
    var cfg = sema_model.MoveCfg.init(self.reporter.allocator);
    const entry = cfg.addBlock(.entry) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    const body = cfg.addBlock(.statement) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    const exit = cfg.addBlock(exit_kind) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    cfg.addEdge(entry, body, .normal) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    cfg.addEdge(body, exit, .normal) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    return .{ .cfg = cfg, .entry = entry, .body = body, .exit = exit };
}

const ExitMoveCfg = struct {
    cfg: sema_model.MoveCfg,
    entry: sema_model.MoveCfgBlockId,
    exit: sema_model.MoveCfgBlockId,

    fn deinit(self: *ExitMoveCfg) void {
        self.cfg.deinit();
    }
};

const LoopBodyMoveCfg = struct {
    cfg: sema_model.MoveCfg,
    entry: sema_model.MoveCfgBlockId,
    loop_head: sema_model.MoveCfgBlockId,
    body: sema_model.MoveCfgBlockId,
    exit: sema_model.MoveCfgBlockId,
    break_source: sema_model.MoveCfgBlockId,
    break_exit: sema_model.MoveCfgBlockId,
    continue_source: sema_model.MoveCfgBlockId,

    fn deinit(self: *LoopBodyMoveCfg) void {
        self.cfg.deinit();
    }
};

fn loopBodyMoveCfg(self: *Checker) ?LoopBodyMoveCfg {
    var cfg = sema_model.MoveCfg.init(self.reporter.allocator);
    const entry = cfg.addBlock(.entry) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    const loop_head = cfg.addBlock(.loop_head) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    const body = cfg.addBlock(.statement) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    const exit = cfg.addBlock(.exit) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    const break_source = cfg.addBlock(.statement) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    const break_exit = cfg.addBlock(.exit) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    const continue_source = cfg.addBlock(.statement) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    cfg.addEdge(entry, loop_head, .normal) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    cfg.addEdge(loop_head, body, .branch) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    cfg.addEdge(loop_head, exit, .branch) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    cfg.addEdge(body, loop_head, .backedge) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    cfg.addEdge(break_source, break_exit, .early_exit) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    cfg.addEdge(continue_source, loop_head, .early_exit) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    return .{
        .cfg = cfg,
        .entry = entry,
        .loop_head = loop_head,
        .body = body,
        .exit = exit,
        .break_source = break_source,
        .break_exit = break_exit,
        .continue_source = continue_source,
    };
}

fn exitMoveCfg(self: *Checker) ?ExitMoveCfg {
    var cfg = sema_model.MoveCfg.init(self.reporter.allocator);
    const entry = cfg.addBlock(.entry) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    const exit = cfg.addBlock(.exit) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    cfg.addEdge(entry, exit, .normal) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    return .{ .cfg = cfg, .entry = entry, .exit = exit };
}

const ShortCircuitMoveCfg = struct {
    cfg: sema_model.MoveCfg,
    entry: sema_model.MoveCfgBlockId,
    rhs: sema_model.MoveCfgBlockId,
    join: sema_model.MoveCfgBlockId,

    fn deinit(self: *ShortCircuitMoveCfg) void {
        self.cfg.deinit();
    }
};

fn shortCircuitMoveCfg(self: *Checker) ?ShortCircuitMoveCfg {
    var cfg = sema_model.MoveCfg.init(self.reporter.allocator);
    const entry = cfg.addBlock(.entry) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    const rhs = cfg.addBlock(.statement) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    const join = cfg.addBlock(.branch_join) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    // The bypass edge is inserted first so the join state represents the path
    // where the RHS was not evaluated before the RHS path is merged into it.
    cfg.addEdge(entry, join, .branch) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    cfg.addEdge(entry, rhs, .branch) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    cfg.addEdge(rhs, join, .normal) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    return .{ .cfg = cfg, .entry = entry, .rhs = rhs, .join = join };
}

const TwoArmMoveCfg = struct {
    cfg: sema_model.MoveCfg,
    entry: sema_model.MoveCfgBlockId,
    then_block: sema_model.MoveCfgBlockId,
    else_block: sema_model.MoveCfgBlockId,
    join: sema_model.MoveCfgBlockId,

    fn deinit(self: *TwoArmMoveCfg) void {
        self.cfg.deinit();
    }
};

fn twoArmMoveCfg(self: *Checker) ?TwoArmMoveCfg {
    var cfg = sema_model.MoveCfg.init(self.reporter.allocator);
    const entry = cfg.addBlock(.entry) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    const then_block = cfg.addBlock(.statement) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    const else_block = cfg.addBlock(.statement) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    const join = cfg.addBlock(.branch_join) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    cfg.addEdge(entry, then_block, .branch) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    cfg.addEdge(entry, else_block, .branch) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    cfg.addEdge(then_block, join, .normal) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    cfg.addEdge(else_block, join, .normal) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    return .{ .cfg = cfg, .entry = entry, .then_block = then_block, .else_block = else_block, .join = join };
}

const MultiArmMoveCfg = struct {
    allocator: std.mem.Allocator,
    cfg: sema_model.MoveCfg,
    entry: sema_model.MoveCfgBlockId,
    join: sema_model.MoveCfgBlockId,
    arms: []sema_model.MoveCfgBlockId,

    fn deinit(self: *MultiArmMoveCfg) void {
        self.allocator.free(self.arms);
        self.cfg.deinit();
    }
};

fn multiArmMoveCfg(self: *Checker, arm_count: usize) ?MultiArmMoveCfg {
    var cfg = sema_model.MoveCfg.init(self.reporter.allocator);
    const entry = cfg.addBlock(.entry) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    const join = cfg.addBlock(.branch_join) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    const arms = self.reporter.allocator.alloc(sema_model.MoveCfgBlockId, arm_count) catch {
        self.oom = true;
        cfg.deinit();
        return null;
    };
    for (arms) |*block| {
        block.* = cfg.addBlock(.statement) catch {
            self.oom = true;
            self.reporter.allocator.free(arms);
            cfg.deinit();
            return null;
        };
        cfg.addEdge(entry, block.*, .branch) catch {
            self.oom = true;
            self.reporter.allocator.free(arms);
            cfg.deinit();
            return null;
        };
        cfg.addEdge(block.*, join, .normal) catch {
            self.oom = true;
            self.reporter.allocator.free(arms);
            cfg.deinit();
            return null;
        };
    }
    return .{ .allocator = self.reporter.allocator, .cfg = cfg, .entry = entry, .join = join, .arms = arms };
}

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
        } else if (self.move_ctx) |ctx| {
            if (typeCanStoreBorrowAlias(param.ty, ctx.*)) {
                state.put(param.name.text, .{ .live = false, .span = param.name.span, .place = .{ .root = param.name.text }, .ty = param.ty, .type_only = true }) catch {
                    self.oom = true;
                };
            }
        }
    }
    const fell_through = moveFunctionBodyCfg(self, body, &state, aliases);
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

fn moveFunctionBodyCfg(self: *Checker, body: ast.Block, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
    var linear = linearMoveCfg(self, .exit) orelse return false;
    defer linear.deinit();

    var worklist = MoveStateCfgWorklist.init(self, &linear.cfg, linear.entry, state) orelse return false;
    defer worklist.deinit();
    var fell_through = false;
    while (worklist.pop()) |block| {
        const block_state = worklist.statePtr(block) orelse continue;
        if (block == linear.entry) {
            worklist.propagateSuccessors(self, block, block_state);
        } else if (block == linear.body) {
            const diverges = moveBlock(self, body, block_state, aliases);
            if (!diverges) {
                fell_through = true;
                worklist.propagateSuccessors(self, block, block_state);
            }
        } else if (block == linear.exit) {
            replaceMoveState(self, state, block_state);
        }
    }
    return fell_through;
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

    var linear = linearMoveCfg(self, .branch_join) orelse return false;
    defer linear.deinit();

    var worklist = MoveStateCfgWorklist.init(self, &linear.cfg, linear.entry, state) orelse return false;
    defer worklist.deinit();
    var diverges = false;
    while (worklist.pop()) |block_id| {
        const block_state = worklist.statePtr(block_id) orelse continue;
        if (block_id == linear.entry) {
            worklist.propagateSuccessors(self, block_id, block_state);
        } else if (block_id == linear.body) {
            diverges = moveBlock(self, block, block_state, aliases);
            if (!diverges) {
                reportMoveLocalsLeavingScope(self, block_state, &before, "linear `move` value declared in this block is never consumed (must be moved, returned, or freed before the block ends)");
                worklist.propagateSuccessors(self, block_id, block_state);
            } else {
                replaceMoveState(self, state, block_state);
            }
        } else if (block_id == linear.exit) {
            replaceMoveState(self, state, block_state);
        }
    }
    preserveOuterScopedMoveState(self, state, &before);
    return diverges;
}

fn preserveOuterScopedMoveState(self: *Checker, state: *std.StringHashMap(MoveSlot), before: *const std.StringHashMap(MoveSlot)) void {
    var scoped = std.StringHashMap(MoveSlot).init(self.reporter.allocator);
    defer scoped.deinit();
    var it = before.iterator();
    while (it.next()) |entry| {
        const current = matchingMoveStateSlot(state, entry.key_ptr.*, entry.value_ptr.*);
        if (isTrackedMoveSubplace(entry.value_ptr.*, entry.key_ptr.*) and current == null) {
            continue;
        }
        const slot = current orelse entry.value_ptr.*;
        scoped.put(entry.key_ptr.*, slot) catch {
            self.oom = true;
        };
    }
    var state_it = state.iterator();
    while (state_it.next()) |entry| {
        if (moveStateSlotMatches(before, entry.key_ptr.*, entry.value_ptr.*)) continue;
        if (!moveSubplaceRootInOuter(entry.value_ptr.*, entry.key_ptr.*, before)) continue;
        scoped.put(entry.key_ptr.*, entry.value_ptr.*) catch {
            self.oom = true;
        };
    }
    replaceMoveState(self, state, &scoped);
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

fn moveExitEdgeCfg(self: *Checker, state: *const std.StringHashMap(MoveSlot), message: []const u8) void {
    var exit_cfg = exitMoveCfg(self) orelse return;
    defer exit_cfg.deinit();

    var worklist = MoveStateCfgWorklist.init(self, &exit_cfg.cfg, exit_cfg.entry, state) orelse return;
    defer worklist.deinit();
    while (worklist.pop()) |block| {
        const block_state = worklist.statePtr(block) orelse continue;
        if (block == exit_cfg.entry) {
            worklist.propagateSuccessors(self, block, block_state);
        } else if (block == exit_cfg.exit) {
            checkMoveExitEdge(self, block_state, message);
        }
    }
}

pub fn checkMoveExit(self: *Checker, state: *const std.StringHashMap(MoveSlot)) void {
    moveExitEdgeCfg(self, state, "linear `move` value is still live on this function-exit path (must be moved, returned, or freed)");
}

pub fn reportMoveLocalsLeavingScope(self: *Checker, inner: *const std.StringHashMap(MoveSlot), outer: *const std.StringHashMap(MoveSlot), message: []const u8) void {
    var it = inner.iterator();
    while (it.next()) |entry| {
        if (moveStateSlotMatches(outer, entry.key_ptr.*, entry.value_ptr.*)) continue;
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
        const after = matchingMoveStateSlot(iteration_state, entry.key_ptr.*, entry.value_ptr.*) orelse {
            if (isPureIndexFactSlot(entry.value_ptr.*)) {
                index_fact_removals.append(self.reporter.allocator, entry.key_ptr.*) catch {
                    self.oom = true;
                };
            }
            continue;
        };
        const before = entry.value_ptr.*;
        if (before.live != after.live or before.deferred != after.deferred or !sameDeferredBorrowFact(before, after)) {
            self.errorCode(before.span, "E_MOVE_LOOP_RESOURCE", "cannot consume or reserve an outer linear `move` value inside a loop; the loop may run zero or multiple times");
            entry.value_ptr.live = false;
            entry.value_ptr.deferred = false;
            entry.value_ptr.deferred_borrow = false;
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
        if (moveStateSlotMatches(entry_state, entry.key_ptr.*, entry.value_ptr.*)) continue;
        const root = trackedSubplaceRoot(entry.value_ptr.*, entry.key_ptr.*) orelse continue;
        if (rootMoveSlotPtrForPlace(.{ .root = root }, entry_state)) |root_slot| {
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
                        state.put(decl.names[0].text, .{ .live = false, .span = decl.names[0].span, .place = .{ .root = decl.names[0].text }, .ty = ty, .type_only = true }) catch {
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
                    if (trackedAliasReferent(referent, state)) |tracked_referent| {
                        // `live = false`: the alias is a borrow, not a linear resource, so
                        // leak/exit checks (which only fire on `live` slots) must skip it.
                        // Its referent's moved-out state is what the stale check consults.
                        state.put(decl.names[0].text, .{ .live = false, .span = decl.names[0].span, .place = .{ .root = decl.names[0].text }, .alias_of = tracked_referent.key, .alias_place = tracked_referent.place, .full_deref_alias = tracked_referent.full_deref }) catch {
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
                    recordTypeOnlyPlaceRoot(self, decl.names[0], binding_ty, state, false);
                    registerAggregateFieldAliases(self, decl.names[0].text, .{ .root = decl.names[0].text }, decl.names[0].span, decl.init.?, state, aliases);
                } else if (decl.init.?.kind == .array_literal) {
                    recordTypeOnlyPlaceRoot(self, decl.names[0], binding_ty, state, false);
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
                            if (trackedAliasReferent(referent, state)) |tracked_referent| {
                                if (state.getPtr(id.text)) |slot| {
                                    slot.alias_of = tracked_referent.key;
                                    slot.alias_place = tracked_referent.place;
                                    slot.live = false;
                                    slot.full_deref_alias = tracked_referent.full_deref;
                                } else {
                                    state.put(id.text, .{ .live = false, .span = a.target.span, .place = .{ .root = id.text }, .alias_of = tracked_referent.key, .alias_place = tracked_referent.place, .full_deref_alias = tracked_referent.full_deref }) catch {
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
                        _ = removeOwnershipMovePlace(pp.place, state); // the field now holds a fresh live resource
                    }
                    recordAssignedAggregateFieldAliasOrEscape(self, a.target, a.value, a.target.span, state, aliases);
                },
                .index => |ix| {
                    moveBorrow(self, ix.base.*, state, aliases);
                    moveConsume(self, ix.index.*, state, aliases);
                    if (moveIndexedPlaceKey(self, a.target, state, aliases)) |pp| {
                        if (stateHasConflictingMovePlace(pp.place, state)) {
                            self.errorCode(a.target.span, "E_USE_AFTER_MOVE", "cannot reinitialize a concrete array element after an unknown dynamic element was moved out");
                        } else if (!stateContainsMovePlace(pp.place, state)) {
                            self.errorCode(a.target.span, "E_RESOURCE_OVERWRITE", "cannot overwrite a live linear `move` array element; consume it first");
                        }
                        moveConsume(self, a.value, state, aliases);
                        markBorrowEscapeCapturedCallResult(self, a.value, a.target.span, state, aliases);
                        _ = removeOwnershipMovePlace(pp.place, state);
                    } else if (wildcardMoveIndexedPlaceKey(self, a.target, state, aliases)) |pp| {
                        if (stateHasActivePlaceOrConflict(pp.place, state)) {
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
            return moveLoopCfg(self, l, state, aliases);
        },
        .if_let => |n| {
            return moveIfLetCfg(self, n, state, aliases);
        },
        .@"switch" => |sw| {
            return moveSwitchCfg(self, sw, state, aliases);
        },
        .@"break" => |target| {
            moveLoopExitEdgeCfg(self, state, target, .break_exit);
            return true; // the rest of the loop body is unreachable
        },
        .@"continue" => |target| {
            moveLoopExitEdgeCfg(self, state, target, .continue_exit);
            return true; // the rest of the loop body is unreachable
        },
        .asm_stmt => return false,
    }
}

fn moveLoopCfg(self: *Checker, loop: ast.Loop, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
    if (loop.iterable) |iter| {
        switch (loop.kind) {
            .@"for" => moveBorrow(self, iter, state, aliases),
            .@"while" => moveWhileConditionCfg(self, iter, state, aliases),
        }
    }
    var frame = LoopMoveFrame{
        .allocator = self.reporter.allocator,
        .label = if (loop.loop_label) |label| label.text else null,
        .entry_names = std.StringHashMap(void).init(self.reporter.allocator),
        .entry_state = cloneMoveState(self, state),
        .invalidated_const_indexes = std.StringHashMap(void).init(self.reporter.allocator),
        .invalidated_alias_places = .empty,
        .invalidated_untyped_aliases = false,
        .pending_exits = .empty,
    };
    var snap_it = state.iterator();
    while (snap_it.next()) |entry| {
        frame.entry_names.put(entry.key_ptr.*, {}) catch {
            self.oom = true;
        };
    }
    self.move_loop_stack.append(self.reporter.allocator, frame) catch {
        self.oom = true;
        frame.deinit();
    };
    var pending_outer_exits_before: usize = 0;
    if (self.move_loop_stack.items.len > 1) {
        for (self.move_loop_stack.items[0 .. self.move_loop_stack.items.len - 1]) |outer| {
            pending_outer_exits_before += outer.pending_exits.items.len;
        }
    }
    var body_state = cloneMoveState(self, state);
    defer body_state.deinit();
    const body_diverges = moveLoopBodyCfg(self, loop.body, state, &body_state, aliases);
    var body_exits_outer_loop = false;
    if (self.move_loop_stack.items.len > 1) {
        var pending_outer_exits_after: usize = 0;
        for (self.move_loop_stack.items[0 .. self.move_loop_stack.items.len - 1]) |outer| {
            pending_outer_exits_after += outer.pending_exits.items.len;
        }
        body_exits_outer_loop = pending_outer_exits_after > pending_outer_exits_before;
    }
    if (self.move_loop_stack.pop()) |popped| {
        var loop_frame = popped;
        applyLoopEarlyExitConstIndexInvalidations(state, &loop_frame);
        applyLoopEarlyExitAliasInvalidations(state, &loop_frame);
        loop_frame.deinit();
    }
    if (!body_diverges) {
        reportMoveLocalsLeavingScope(self, &body_state, state, "linear `move` value declared in a loop body is never consumed (must be moved, returned, or freed before the iteration ends)");
        reportLoopOuterResourceChanges(self, state, &body_state);
    }
    // A body that queued a labeled exit to an enclosing loop has no local
    // fallthrough edge. Propagate that fact so the enclosing CFG routes the
    // queued state through its target break/continue edge instead of joining it
    // with a spurious loop backedge.
    return body_diverges and body_exits_outer_loop;
}

// Route `if let` through explicit entry/then/else/join CFG blocks.  The scrutinee
// transfer runs in entry, arm-local bindings live only in then, and only
// non-diverging arms reach the join.  This is deliberately the first production
// CFG slice; switch and loop still use their existing specialized transfer rules.
fn moveIfLetCfg(self: *Checker, node: ast.IfLet, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
    var branch = twoArmMoveCfg(self) orelse return false;
    defer branch.deinit();

    var worklist = MoveStateCfgWorklist.init(self, &branch.cfg, branch.entry, state) orelse return false;
    defer worklist.deinit();
    var then_div = false;
    var else_div = false;
    var joined = false;

    while (worklist.pop()) |block| {
        const block_state = worklist.statePtr(block) orelse continue;
        if (block == branch.entry) {
            // The condition/scrutinee is evaluated before either branch.
            moveConsume(self, node.value, block_state, aliases);
            worklist.propagateSuccessors(self, block, block_state);
        } else if (block == branch.then_block) {
            const bound_name = addIfLetMoveBinding(self, node.pattern, node.value, block_state, aliases);
            then_div = moveBlock(self, node.then_block, block_state, aliases);
            if (bound_name) |name| {
                if (!then_div) {
                    if (block_state.getPtr(name)) |slot| {
                        if (slot.live and !slot.deferred) {
                            self.errorCode(slot.span, "E_RESOURCE_LEAK", "linear `move` value bound in an if-let branch is never consumed (must be moved, returned, or freed)");
                        }
                    }
                }
                _ = block_state.remove(name);
            }
            finalizeBranchLocals(self, block_state, state, !then_div);
            if (!then_div) worklist.propagateSuccessors(self, block, block_state);
        } else if (block == branch.else_block) {
            if (node.else_block) |else_body| else_div = moveBlock(self, else_body, block_state, aliases);
            finalizeBranchLocals(self, block_state, state, !else_div);
            if (!else_div) worklist.propagateSuccessors(self, block, block_state);
        } else if (block == branch.join) {
            replaceMoveState(self, state, block_state);
            joined = true;
        }
    }
    // Both divergent arms leave no normal join.  The caller already treats the
    // statement as terminal; preserve the incoming map only for unreachable code.
    if (!joined and !(then_div and node.else_block != null and else_div)) self.oom = true;
    return then_div and (node.else_block != null) and else_div;
}

// Route all switch arms through the same real-state CFG worklist. Each arm gets a
// cloned post-subject state; only fallthrough arms contribute an incoming state to
// the shared join block, where MoveStateCfgWorklist performs the ownership merge.
fn moveSwitchCfg(self: *Checker, node: ast.Switch, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
    if (node.arms.len == 0) {
        moveConsume(self, node.subject, state, aliases);
        return false;
    }
    var branch = multiArmMoveCfg(self, node.arms.len) orelse return false;
    defer branch.deinit();

    var worklist = MoveStateCfgWorklist.init(self, &branch.cfg, branch.entry, state) orelse return false;
    defer worklist.deinit();
    const subject_ty: ?ast.TypeExpr = if (self.move_ctx) |ctx| spine.exprResultType(node.subject, ctx.*) else null;
    var all_diverge = true;
    var joined = false;

    while (worklist.pop()) |block| {
        const block_state = worklist.statePtr(block) orelse continue;
        if (block == branch.entry) {
            moveConsume(self, node.subject, block_state, aliases);
            worklist.propagateSuccessors(self, block, block_state);
        } else if (block == branch.join) {
            replaceMoveState(self, state, block_state);
            joined = true;
        } else {
            var arm_index: ?usize = null;
            for (branch.arms, 0..) |arm_block, i| {
                if (arm_block == block) {
                    arm_index = i;
                    break;
                }
            }
            const index = arm_index orelse continue;
            const diverges = moveSwitchArm(self, node.arms[index], subject_ty, block_state, state, aliases);
            if (!diverges) {
                all_diverge = false;
                worklist.propagateSuccessors(self, block, block_state);
            }
        }
    }
    if (!joined and !all_diverge) self.oom = true;
    return all_diverge;
}

fn moveSwitchArm(self: *Checker, arm: ast.SwitchArm, subject_ty: ?ast.TypeExpr, state: *std.StringHashMap(MoveSlot), outer: *const std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
    var bound_name: ?[]const u8 = null;
    for (arm.patterns) |pattern| {
        const payload_ty: ?ast.TypeExpr = switch (pattern.kind) {
            .bind => subject_ty,
            .tag_bind => |tag| if (subject_ty) |ty| spine.resultPayloadType(ty, tag.tag.text) else null,
            else => null,
        };
        const name: ?ast.Ident = switch (pattern.kind) {
            .bind => |ident| ident,
            .tag_bind => |tag| tag.binding,
            else => null,
        };
        if (name) |ident| if (payload_ty) |ty| if (self.typeEmbedsMoveByValue(ty, aliases)) {
            state.put(ident.text, .{ .live = true, .span = ident.span, .place = .{ .root = ident.text }, .ty = ty }) catch {
                self.oom = true;
            };
            bound_name = ident.text;
        };
    }
    const diverges = switch (arm.body) {
        .block => |body| moveBlock(self, body, state, aliases),
        .expr => |expr| blk: {
            moveConsume(self, expr, state, aliases);
            checkUnusedMoveResult(self, expr, aliases);
            break :blk false;
        },
    };
    if (bound_name) |name| {
        if (!diverges) {
            if (state.getPtr(name)) |slot| if (slot.live and !slot.deferred) {
                self.errorCode(slot.span, "E_RESOURCE_LEAK", "linear `move` value bound in a switch arm is never consumed (must be moved, returned, or freed)");
            };
        }
        _ = state.remove(name);
    }
    finalizeBranchLocals(self, state, outer, !diverges);
    return diverges;
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
        if (moveStateSlotMatches(outer, entry.key_ptr.*, entry.value_ptr.*)) continue;
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
    recordLoopEarlyExitInvalidations(self, frame, state);
}

fn moveLoopExitEdgeCfg(self: *Checker, state: *const std.StringHashMap(MoveSlot), target: ?ast.Ident, kind: LoopMoveExitKind) void {
    const frame = moveLoopTargetFrame(self, target) orelse return;
    var exit_state = cloneMoveState(self, state);
    frame.pending_exits.append(self.reporter.allocator, .{
        .kind = kind,
        .state = exit_state,
    }) catch {
        exit_state.deinit();
        self.oom = true;
    };
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

fn recordLoopEarlyExitInvalidations(self: *Checker, frame: *LoopMoveFrame, state: *const std.StringHashMap(MoveSlot)) void {
    var it = frame.entry_state.iterator();
    while (it.next()) |entry| {
        const before = entry.value_ptr.*;
        if (!isPureIndexFactSlot(before) and before.alias_of == null) continue;
        if (isPureIndexFactSlot(before)) {
            const after = state.get(entry.key_ptr.*) orelse {
                frame.invalidated_const_indexes.put(entry.key_ptr.*, {}) catch {
                    self.oom = true;
                };
                continue;
            };
            if (!isPureIndexFactSlot(after) or !sameIndexFact(before, after)) {
                frame.invalidated_const_indexes.put(entry.key_ptr.*, {}) catch {
                    self.oom = true;
                };
            }
            continue;
        }

        if (before.place) |storage_place| {
            const after = aliasSlotForStoragePlace(storage_place, state);
            if (after == null or !sameAliasFact(before, after.?)) {
                recordInvalidatedAliasPlace(self, frame, storage_place);
            }
        } else {
            // Legacy aliases have no structural storage identity. An early
            // exit cannot safely decide whether a later same-spelled slot is
            // the same alias, so invalidate all such aliases conservatively.
            frame.invalidated_untyped_aliases = true;
        }
    }
}

fn recordInvalidatedAliasPlace(self: *Checker, frame: *LoopMoveFrame, place: MovePlace) void {
    for (frame.invalidated_alias_places.items) |existing| {
        if (existing.eql(place)) return;
    }
    frame.invalidated_alias_places.append(self.reporter.allocator, place) catch {
        self.oom = true;
    };
}

fn applyLoopEarlyExitConstIndexInvalidations(state: *std.StringHashMap(MoveSlot), frame: *const LoopMoveFrame) void {
    var it = frame.invalidated_const_indexes.keyIterator();
    while (it.next()) |name| _ = state.remove(name.*);
}

fn applyLoopEarlyExitAliasInvalidations(state: *std.StringHashMap(MoveSlot), frame: *const LoopMoveFrame) void {
    for (frame.invalidated_alias_places.items) |place| {
        var state_it = state.iterator();
        while (state_it.next()) |entry| {
            const slot = entry.value_ptr;
            if (slot.alias_of == null) continue;
            const storage_place = slot.place orelse continue;
            if (storage_place.eql(place)) slot.* = divergentAliasSlot(entry.key_ptr.*, slot.*);
        }
    }
    if (frame.invalidated_untyped_aliases) {
        var state_it = state.iterator();
        while (state_it.next()) |entry| {
            const slot = entry.value_ptr;
            if (slot.alias_of == null or slot.place != null) continue;
            slot.* = divergentAliasSlot(entry.key_ptr.*, slot.*);
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
    mergeMoveBranchesImpl(self, dest, left, right, true);
}

fn mergeMoveBranchesImpl(
    self: *Checker,
    dest: *std.StringHashMap(MoveSlot),
    left: *const std.StringHashMap(MoveSlot),
    right: *const std.StringHashMap(MoveSlot),
    report_diagnostics: bool,
) void {
    var merged = std.StringHashMap(MoveSlot).init(self.reporter.allocator);
    defer merged.deinit();

    var it = left.iterator();
    while (it.next()) |entry| {
        const other = matchingMoveStateSlot(right, entry.key_ptr.*, entry.value_ptr.*) orelse {
            if (entry.value_ptr.live and !entry.value_ptr.deferred) {
                if (report_diagnostics) self.errorCode(entry.value_ptr.span, "E_RESOURCE_LEAK", "linear `move` value created in only one branch is never consumed before the branch exits");
            } else if (isTrackedMoveSubplace(entry.value_ptr.*, entry.key_ptr.*)) {
                if (report_diagnostics) self.errorCode(entry.value_ptr.span, "E_MOVE_BRANCH_MISMATCH", "linear `move` field has inconsistent ownership across control-flow branches");
                merged.put(entry.key_ptr.*, entry.value_ptr.*) catch {
                    self.oom = true;
                };
            }
            continue;
        };
        var slot = entry.value_ptr.*;
        if (slot.live != other.live or slot.deferred != other.deferred or !sameDeferredBorrowFact(slot, other)) {
            if (report_diagnostics) self.errorCode(slot.span, "E_MOVE_BRANCH_MISMATCH", "linear `move` value has inconsistent ownership across control-flow branches");
            slot.live = false;
            slot.deferred = false;
            slot.deferred_borrow = false;
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
        if (moveStateSlotMatches(left, entry.key_ptr.*, entry.value_ptr.*)) continue;
        if (entry.value_ptr.live and !entry.value_ptr.deferred) {
            if (report_diagnostics) self.errorCode(entry.value_ptr.span, "E_RESOURCE_LEAK", "linear `move` value created in only one branch is never consumed before the branch exits");
        } else if (isTrackedMoveSubplace(entry.value_ptr.*, entry.key_ptr.*)) {
            if (report_diagnostics) self.errorCode(entry.value_ptr.span, "E_MOVE_BRANCH_MISMATCH", "linear `move` field has inconsistent ownership across control-flow branches");
            merged.put(entry.key_ptr.*, entry.value_ptr.*) catch {
                self.oom = true;
            };
        }
    }

    replaceMoveState(self, dest, &merged);
}

// Ownership places are structural facts, not source-level binding names. A join
// must recognize the same root, field, element, or typed alias storage even
// when a compatibility key was formatted differently along the two incoming
// paths. Untyped legacy aliases and index facts retain their separate metadata
// rules.
fn matchingMoveStateSlot(state: *const std.StringHashMap(MoveSlot), key: []const u8, slot: MoveSlot) ?MoveSlot {
    if (isOwnershipMovePlace(slot, key)) {
        const place = slot.place.?;
        var it = state.iterator();
        while (it.next()) |entry| {
            if (!isOwnershipMovePlace(entry.value_ptr.*, entry.key_ptr.*)) continue;
            const candidate = entry.value_ptr.*;
            if (candidate.place.?.eql(place)) return candidate;
        }
        return null;
    }
    if (slot.alias_of != null) {
        if (slot.place) |storage_place| {
            var it = state.iterator();
            while (it.next()) |entry| {
                const candidate = entry.value_ptr.*;
                if (candidate.alias_of == null) continue;
                const candidate_place = candidate.place orelse continue;
                if (candidate_place.eql(storage_place)) return candidate;
            }
            return null;
        }
    }
    return state.get(key);
}

fn moveStateSlotMatches(state: *const std.StringHashMap(MoveSlot), key: []const u8, slot: MoveSlot) bool {
    return matchingMoveStateSlot(state, key, slot) != null;
}

fn sameAliasFact(left: MoveSlot, right: MoveSlot) bool {
    if (left.alias_of == null and right.alias_of == null) return true;
    if (left.alias_of == null or right.alias_of == null) return false;
    if (left.alias_place) |left_place| {
        if (right.alias_place) |right_place| {
            return left_place.eql(right_place) and left.full_deref_alias == right.full_deref_alias;
        }
    }
    // A compatibility key can locate legacy metadata but cannot establish that
    // two CFG aliases denote the same resource. Without both typed referents,
    // retain the conservative divergent-join result.
    return false;
}

test "move branch joins match subplaces by typed place rather than compatibility key" {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "move-join.mc", "");
    defer reporter.deinit();
    var checker = Checker.init(&reporter);

    var left = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer left.deinit();
    var right = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer right.deinit();
    var joined = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer joined.deinit();

    const root: sema_model.MovePlace = .{ .root = "owner" };
    const place = root.project(.{ .field = "resource" }).?;
    const span: diagnostics.Span = .{ .offset = 0, .len = 0, .line = 1, .column = 1 };
    try left.put("owner.resource:left", .{ .live = false, .span = span, .place = place });
    try right.put("owner.resource:right", .{ .live = false, .span = span, .place = place });

    try std.testing.expect(moveStatesEqual(&left, &right));
    mergeMoveBranches(&checker, &joined, &left, &right);
    try std.testing.expect(!reporter.has_errors);
    try std.testing.expectEqual(@as(usize, 1), joined.count());
    try std.testing.expect(joined.contains("owner.resource:left"));

    recordOwnershipMovePlace(&checker, "owner.resource:replacement", place, .{ .live = true, .span = span, .place = place, .deferred = true }, &joined);
    try std.testing.expectEqual(@as(usize, 1), joined.count());
    try std.testing.expect(joined.get("owner.resource:left").?.deferred);
    try std.testing.expect(removeOwnershipMovePlace(place, &joined));
    try std.testing.expectEqual(@as(usize, 0), joined.count());
}

test "move branch joins match roots by typed place rather than compatibility key" {
    var left = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer left.deinit();
    var right = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer right.deinit();

    const root: MovePlace = .{ .root = "owner" };
    const span: diagnostics.Span = .{ .offset = 0, .len = 0, .line = 1, .column = 1 };
    try left.put("compat:left", .{ .live = true, .span = span, .place = root });
    try right.put("compat:right", .{ .live = true, .span = span, .place = root });

    try std.testing.expect(moveStatesEqual(&left, &right));
    try std.testing.expect(matchingMoveStateSlot(&right, "compat:left", left.get("compat:left").?) != null);
}

test "move CFG boundary state handlers match ownership subplaces by typed place" {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "move-cfg-place.mc", "");
    defer reporter.deinit();
    var checker = Checker.init(&reporter);

    const root: sema_model.MovePlace = .{ .root = "owner" };
    const place = root.project(.{ .field = "resource" }).?;
    const span: diagnostics.Span = .{ .offset = 0, .len = 0, .line = 1, .column = 1 };
    const root_slot = MoveSlot{ .live = true, .span = span, .place = root };
    const moved_slot = MoveSlot{ .live = false, .span = span, .place = place };

    var loop_entry = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer loop_entry.deinit();
    var loop_iteration = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer loop_iteration.deinit();
    try loop_entry.put("owner", root_slot);
    try loop_entry.put("owner.resource:entry", moved_slot);
    try loop_iteration.put("owner", root_slot);
    try loop_iteration.put("owner.resource:iteration", moved_slot);
    reportLoopOuterResourceChanges(&checker, &loop_entry, &loop_iteration);
    try std.testing.expect(!reporter.has_errors);
    try std.testing.expect(loop_entry.get("owner").?.live);

    var short_left = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer short_left.deinit();
    var short_right = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer short_right.deinit();
    try short_left.put("owner", root_slot);
    try short_left.put("owner.resource:left", moved_slot);
    try short_right.put("owner", root_slot);
    try short_right.put("owner.resource:right", moved_slot);
    mergeShortCircuitMoveStates(&checker, &short_left, &short_right, span, false);
    try std.testing.expect(!reporter.has_errors);
    try std.testing.expect(short_left.get("owner").?.live);

    var before_scope = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer before_scope.deinit();
    var after_scope = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer after_scope.deinit();
    try before_scope.put("owner", root_slot);
    try before_scope.put("owner.resource:before", moved_slot);
    try after_scope.put("owner", root_slot);
    try after_scope.put("owner.resource:after", moved_slot);
    preserveOuterScopedMoveState(&checker, &after_scope, &before_scope);
    try std.testing.expectEqual(@as(usize, 2), after_scope.count());
    try std.testing.expect(after_scope.contains("owner.resource:before"));
}

test "move CFG alias facts match typed referent places" {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "move-cfg-alias.mc", "");
    defer reporter.deinit();
    var checker = Checker.init(&reporter);

    const owner: sema_model.MovePlace = .{ .root = "owner" };
    const referent = owner.project(.{ .field = "resource" }).?;
    const storage: sema_model.MovePlace = .{ .root = "borrow" };
    const span: diagnostics.Span = .{ .offset = 0, .len = 0, .line = 1, .column = 1 };
    const left_slot = MoveSlot{ .live = false, .span = span, .place = storage, .alias_of = "owner.resource:left", .alias_place = referent };
    const right_slot = MoveSlot{ .live = false, .span = span, .place = storage, .alias_of = "owner.resource:right", .alias_place = referent };

    try std.testing.expect(sameAliasFact(left_slot, right_slot));
    try std.testing.expect(!sameAliasFact(
        .{ .live = false, .span = span, .alias_of = "owner.resource" },
        .{ .live = false, .span = span, .alias_of = "owner.resource" },
    ));
    var left = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer left.deinit();
    var right = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer right.deinit();
    var joined = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer joined.deinit();
    // The compatibility storage spellings diverge across CFG predecessors, but
    // both aliases occupy the same structural storage place.
    try left.put("compat:borrow:left", left_slot);
    try right.put("compat:borrow:right", right_slot);

    try std.testing.expect(moveStatesEqual(&left, &right));
    mergeMoveBranches(&checker, &joined, &left, &right);
    try std.testing.expect(!reporter.has_errors);
    try std.testing.expectEqual(@as(usize, 1), joined.count());
}

test "loop early-exit alias invalidation uses typed storage places" {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "move-loop-alias-place.mc", "");
    defer reporter.deinit();
    var checker = Checker.init(&reporter);

    const span: diagnostics.Span = .{ .offset = 0, .len = 0, .line = 1, .column = 1 };
    const owner: MovePlace = .{ .root = "owner" };
    const resource = owner.project(.{ .field = "resource" }).?;
    const replacement = owner.project(.{ .field = "replacement" }).?;
    const storage: MovePlace = .{ .root = "borrow" };

    var entry_state = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    try entry_state.put("compat:borrow:entry", .{
        .live = false,
        .span = span,
        .place = storage,
        .alias_of = "owner.resource",
        .alias_place = resource,
    });
    var frame = LoopMoveFrame{
        .allocator = std.testing.allocator,
        .entry_names = std.StringHashMap(void).init(std.testing.allocator),
        .entry_state = entry_state,
        .invalidated_const_indexes = std.StringHashMap(void).init(std.testing.allocator),
        .invalidated_alias_places = .empty,
        .invalidated_untyped_aliases = false,
        .pending_exits = .empty,
    };
    defer frame.deinit();

    var early_exit = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer early_exit.deinit();
    try early_exit.put("compat:borrow:exit", .{
        .live = false,
        .span = span,
        .place = storage,
        .alias_of = "owner.replacement",
        .alias_place = replacement,
    });
    recordLoopEarlyExitInvalidations(&checker, &frame, &early_exit);
    try std.testing.expectEqual(@as(usize, 1), frame.invalidated_alias_places.items.len);
    try std.testing.expect(!frame.invalidated_untyped_aliases);

    var post_loop = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer post_loop.deinit();
    try post_loop.put("compat:borrow:post", .{
        .live = false,
        .span = span,
        .place = storage,
        .alias_of = "owner.resource",
        .alias_place = resource,
    });
    applyLoopEarlyExitAliasInvalidations(&post_loop, &frame);
    const invalidated = post_loop.get("compat:borrow:post") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("compat:borrow:post", invalidated.alias_of.?);
    try std.testing.expect(invalidated.alias_place == null);

    // A legacy alias cannot be matched across the early-exit edge by its map
    // key. It is therefore conservatively divergent, and a later use reports
    // the same stale-alias diagnostic as any other divergent alias.
    var legacy_entry = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    try legacy_entry.put("legacy:entry", .{ .live = false, .span = span, .alias_of = "owner.resource" });
    var legacy_frame = LoopMoveFrame{
        .allocator = std.testing.allocator,
        .entry_names = std.StringHashMap(void).init(std.testing.allocator),
        .entry_state = legacy_entry,
        .invalidated_const_indexes = std.StringHashMap(void).init(std.testing.allocator),
        .invalidated_alias_places = .empty,
        .invalidated_untyped_aliases = false,
        .pending_exits = .empty,
    };
    defer legacy_frame.deinit();

    var legacy_exit = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer legacy_exit.deinit();
    recordLoopEarlyExitInvalidations(&checker, &legacy_frame, &legacy_exit);
    try std.testing.expect(legacy_frame.invalidated_untyped_aliases);

    var legacy_post = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer legacy_post.deinit();
    try legacy_post.put("different:legacy:key", .{ .live = false, .span = span, .alias_of = "owner.resource" });
    applyLoopEarlyExitAliasInvalidations(&legacy_post, &legacy_frame);
    const legacy_invalidated = legacy_post.get("different:legacy:key") orelse return error.TestUnexpectedResult;
    try std.testing.expect(legacy_invalidated.divergent_alias);
    checkStaleAlias(&checker, "different:legacy:key", legacy_invalidated, span, &legacy_post);
    try std.testing.expect(reporter.has_errors);
}

test "move CFG deferred borrows use typed places rather than compatibility keys" {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "move-cfg-defer-place.mc", "");
    defer reporter.deinit();
    var checker = Checker.init(&reporter);

    const root: MovePlace = .{ .root = "owner" };
    const borrowed = root.project(.{ .field = "resource" }).?;
    const span: diagnostics.Span = .{ .offset = 0, .len = 0, .line = 1, .column = 1 };
    const left_slot = MoveSlot{
        .live = true,
        .span = span,
        .place = root,
        .deferred_borrow = true,
        .deferred_borrow_place = borrowed,
    };
    const right_slot = MoveSlot{
        .live = true,
        .span = span,
        .place = root,
        .deferred_borrow = true,
        .deferred_borrow_place = borrowed,
    };

    var left = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer left.deinit();
    var right = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer right.deinit();
    var joined = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer joined.deinit();
    try left.put("owner", left_slot);
    try right.put("owner", right_slot);

    try std.testing.expect(moveStatesEqual(&left, &right));
    mergeMoveBranches(&checker, &joined, &left, &right);
    try std.testing.expect(!reporter.has_errors);
    try std.testing.expect(joined.get("owner").?.live);

    var loop_entry = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer loop_entry.deinit();
    var loop_iteration = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer loop_iteration.deinit();
    try loop_entry.put("owner", left_slot);
    try loop_iteration.put("owner", right_slot);
    reportLoopOuterResourceChanges(&checker, &loop_entry, &loop_iteration);
    try std.testing.expect(!reporter.has_errors);
    try std.testing.expect(loop_entry.get("owner").?.live);

    mergeShortCircuitMoveStates(&checker, &left, &right, span, true);
    try std.testing.expect(!reporter.has_errors);
    try std.testing.expect(left.get("owner").?.live);
}

test "move root ownership lookup uses typed places rather than compatibility keys" {
    const span: diagnostics.Span = .{ .offset = 0, .len = 0, .line = 1, .column = 1 };
    const root: MovePlace = .{ .root = "owner" };
    const field = root.project(.{ .field = "resource" }).?;
    var state = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer state.deinit();

    // The string key intentionally does not equal `owner`. The typed root is
    // the authority for ownership paths that begin from the field projection.
    try state.put("compat:owner", .{ .live = true, .span = span, .place = root });
    try std.testing.expect(rootMoveSlotForPlace(field, &state) != null);
    const root_slot = rootMoveSlotPtrForPlace(field, &state) orelse return error.TestUnexpectedResult;
    root_slot.live = false;
    try std.testing.expect(!state.get("compat:owner").?.live);
}

test "move place construction resolves typed roots before compatibility keys" {
    const span: diagnostics.Span = .{ .offset = 0, .len = 0, .line = 1, .column = 1 };
    const root: MovePlace = .{ .root = "owner" };
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "move-place-root.mc", "");
    defer reporter.deinit();
    var checker = Checker.init(&reporter);
    var state = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer state.deinit();
    const ty = ast_query.simpleNameType("Resource", span);
    const owner = ast.Expr{ .span = span, .kind = .{ .ident = .{ .text = "owner", .span = span } } };

    // A predecessor may retain an arbitrary compatibility key, but source
    // `owner` must still resolve the structural root recorded in the slot.
    try state.put("compat:owner", .{ .live = true, .span = span, .place = root, .ty = ty });
    const resolved = placeKeyAndType(&checker, owner, &state) orelse return error.TestUnexpectedResult;
    try std.testing.expect(resolved.place.eql(root));
    try std.testing.expect(sema_type.sameTypeSyntax(resolved.ty, ty));
}

test "move expression typing uses structural ownership roots rather than map keys" {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "move-expression-root.mc", "");
    defer reporter.deinit();
    var checker = Checker.init(&reporter);

    const span: diagnostics.Span = .{ .offset = 0, .len = 0, .line = 1, .column = 1 };
    const root: MovePlace = .{ .root = "owner" };
    const owner = ast.Expr{ .span = span, .kind = .{ .ident = .{ .text = "owner", .span = span } } };
    var state = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer state.deinit();
    var aliases = std.StringHashMap(ast.TypeExpr).init(std.testing.allocator);
    defer aliases.deinit();

    // CFG state can retain a compatibility key unrelated to source spelling.
    // The typed root still makes `owner` a linear resource for `drop` and
    // pointer-dereference diagnostics.
    try state.put("compat:owner", .{ .live = true, .span = span, .place = root });
    try std.testing.expect(exprIsMoveTyped(&checker, owner, &state, &aliases));

    state.clearRetainingCapacity();
    // Conversely, an alias stored under the source spelling must not make the
    // spelling itself a move owner merely because the compatibility key matches.
    try state.put("owner", .{ .live = false, .span = span, .place = root, .alias_of = "compat:source", .alias_place = root });
    try std.testing.expect(!exprIsMoveTyped(&checker, owner, &state, &aliases));
}

test "move subplace outer-scope classification uses typed roots rather than compatibility keys" {
    const span: diagnostics.Span = .{ .offset = 0, .len = 0, .line = 1, .column = 1 };
    const root: MovePlace = .{ .root = "owner" };
    const field = root.project(.{ .field = "resource" }).?;
    var outer = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer outer.deinit();

    try outer.put("compat:owner", .{ .live = true, .span = span, .place = root });
    try std.testing.expect(moveSubplaceRootInOuter(.{ .live = false, .span = span, .place = field }, "compat:owner.resource", &outer));
}

test "move alias producers require carried typed referent places" {
    const span: diagnostics.Span = .{ .offset = 0, .len = 0, .line = 1, .column = 1 };
    const root: MovePlace = .{ .root = "owner" };
    var state = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer state.deinit();

    try state.put("compat:owner", .{ .live = true, .span = span, .place = root });
    const tracked = trackedAliasReferent(.{ .key = "compat:owner", .place = root, .full_deref = false }, &state) orelse return error.TestUnexpectedResult;
    try std.testing.expect(tracked.place.?.eql(root));
    try std.testing.expect(aliasReferentIsTracked(.{ .key = "compat:owner", .place = root, .full_deref = false }, &state));
    try std.testing.expect(!aliasReferentIsTracked(.{ .key = "compat:owner", .place = null, .full_deref = false }, &state));

    try state.put("legacy", .{ .live = true, .span = span });
    try std.testing.expect(!aliasReferentIsTracked(.{ .key = "legacy", .place = null, .full_deref = false }, &state));
}

test "move cleanup aliases match outer roots by typed place" {
    const span: diagnostics.Span = .{ .offset = 0, .len = 0, .line = 1, .column = 1 };
    const root: MovePlace = .{ .root = "owner" };
    const field = root.project(.{ .field = "resource" }).?;
    var state = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer state.deinit();
    var outer = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer outer.deinit();

    // Neither compatibility key names the structural root. A cleanup alias of
    // this field must still be recognized as referring to the outer owner.
    try state.put("compat:cleanup-alias", .{ .live = false, .span = span, .place = field, .alias_of = "compat:source" });
    try outer.put("compat:outer-owner", .{ .live = true, .span = span, .place = root });
    try std.testing.expect(aliasReferentTargetsOuter(.{ .key = "compat:cleanup-alias", .place = field, .full_deref = false }, &outer));

    try state.put("legacy", .{ .live = false, .span = span, .alias_of = "compat:source" });
    try std.testing.expect(!aliasReferentTargetsOuter(.{ .key = "legacy", .place = null, .full_deref = false }, &outer));
}

test "move stale aliases require carried typed referent places" {
    const span: diagnostics.Span = .{ .offset = 0, .len = 0, .line = 1, .column = 1 };
    const root: MovePlace = .{ .root = "owner" };
    var state = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer state.deinit();

    try state.put("compat:owner", .{ .live = false, .span = span, .place = root });
    try std.testing.expect(aliasSlotReferentMoved(.{ .live = false, .span = span, .alias_of = "compat:owner", .alias_place = root }, &state));

    try std.testing.expect(aliasSlotReferentMoved(.{ .live = false, .span = span, .alias_of = "compat:owner" }, &state));
}

test "move pointer-return aliases require carried typed referent places" {
    const span: diagnostics.Span = .{ .offset = 0, .len = 0, .line = 1, .column = 1 };
    const root: MovePlace = .{ .root = "owner" };

    const carried = carriedAliasReferent(.{
        .live = false,
        .span = span,
        .alias_of = "compat:owner",
        .alias_place = root,
    }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("compat:owner", carried.key);
    try std.testing.expect(carried.place.?.eql(root));

    try std.testing.expect(carriedAliasReferent(.{ .live = false, .span = span, .alias_of = "compat:owner" }) == null);
}

test "move deferred aliases recover typed places from their state slots" {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "move-defer-alias-place.mc", "");
    defer reporter.deinit();
    var checker = Checker.init(&reporter);

    const span: diagnostics.Span = .{ .offset = 0, .len = 0, .line = 1, .column = 1 };
    const root: MovePlace = .{ .root = "owner" };
    const borrowed = root.project(.{ .field = "resource" }).?;
    var state = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer state.deinit();

    // The root's compatibility key cannot be reconstructed from the alias
    // spelling. The alias carries the structural place that identifies it.
    try state.put("compat:owner", .{ .live = true, .span = span, .place = root });
    try state.put("alias", .{ .live = true, .span = span, .place = borrowed, .alias_of = "owner.resource" });
    markDeferredBorrowReferent(&checker, borrowed, span, &state);

    try std.testing.expect(!reporter.has_errors);
    const owner = state.get("compat:owner") orelse return error.TestUnexpectedResult;
    try std.testing.expect(owner.deferred_borrow);
    try std.testing.expect(owner.deferred_borrow_place.?.eql(borrowed));
    try std.testing.expect(!state.get("alias").?.deferred_borrow);
}

test "move deferred alias reservations reject key-only referents" {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "move-defer-key-only.mc", "");
    defer reporter.deinit();
    var checker = Checker.init(&reporter);

    const span: diagnostics.Span = .{ .offset = 0, .len = 0, .line = 1, .column = 1 };
    const root: MovePlace = .{ .root = "owner" };
    var state = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer state.deinit();

    try state.put("compat:owner", .{ .live = true, .span = span, .place = root });
    markDeferredBorrowAliasReferent(&checker, .{ .key = "compat:owner", .place = null, .full_deref = false }, span, &state);

    try std.testing.expect(!reporter.has_errors);
    try std.testing.expect(!state.get("compat:owner").?.deferred_borrow);
}

test "move short-circuit joins use typed roots rather than compatibility keys" {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "move-short-root.mc", "");
    defer reporter.deinit();
    var checker = Checker.init(&reporter);
    const span: diagnostics.Span = .{ .offset = 0, .len = 0, .line = 1, .column = 1 };
    const root: MovePlace = .{ .root = "owner" };
    const field = root.project(.{ .field = "resource" }).?;
    var bypass = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer bypass.deinit();
    var rhs = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer rhs.deinit();

    try bypass.put("compat:owner", .{ .live = true, .span = span, .place = root });
    try rhs.put("compat:owner", .{ .live = true, .span = span, .place = root });
    try rhs.put("compat:field", .{ .live = false, .span = span, .place = field });
    mergeShortCircuitMoveStates(&checker, &bypass, &rhs, span, false);
    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(!bypass.get("compat:owner").?.live);
}

test "move escaped borrows use typed roots rather than compatibility keys" {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "move-escaped-borrow-place.mc", "");
    defer reporter.deinit();
    var checker = Checker.init(&reporter);
    const span: diagnostics.Span = .{ .offset = 0, .len = 0, .line = 1, .column = 1 };
    const root: MovePlace = .{ .root = "owner" };
    const field = root.project(.{ .field = "resource" }).?;
    var state = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer state.deinit();

    try state.put("compat:owner", .{ .live = true, .span = span, .place = root });
    markEscapedBorrowForPlace(field, span, &state);
    try std.testing.expect(state.get("compat:owner").?.escaped_borrow != null);

    var alias_target = ast.Expr{ .span = span, .kind = .{ .ident = .{ .text = "compat:alias", .span = span } } };
    const alias_borrow = ast.Expr{ .span = span, .kind = .{ .address_of = &alias_target } };
    try state.put("compat:alias", .{ .live = false, .span = span, .place = .{ .root = "compat:alias" }, .alias_of = "stale:owner", .alias_place = field });
    const recovered = borrowedMoveRootPlace(&checker, alias_borrow, &state) orelse return error.TestUnexpectedResult;
    try std.testing.expect(recovered.eql(field));

    state.getPtr("compat:alias").?.alias_place = null;
    try std.testing.expect(borrowedMoveRootPlace(&checker, alias_borrow, &state) == null);
    try std.testing.expect(hasUntypedBorrowAlias(alias_borrow, &state));
}

test "move borrowed subplaces use typed places rather than compatibility keys" {
    const span: diagnostics.Span = .{ .offset = 0, .len = 0, .line = 1, .column = 1 };
    const root: MovePlace = .{ .root = "owner" };
    const field = root.project(.{ .field = "resource" }).?;
    var state = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer state.deinit();

    // A pointer-return alias retains this place. Its ownership must not depend
    // on the temporary compatibility spelling used to store the subplace.
    try state.put("compat:owner.resource", .{ .live = true, .span = span, .place = field });
    try std.testing.expect(ownershipMoveSlotForPlace(field, &state) != null);
    try std.testing.expect(ownershipMoveSlotForPlace(field, &state).?.live);
}

test "move alias root consumption uses typed place rather than compatibility key" {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "move-alias-root-place.mc", "");
    defer reporter.deinit();
    var checker = Checker.init(&reporter);

    const span: diagnostics.Span = .{ .offset = 0, .len = 0, .line = 1, .column = 1 };
    const root: MovePlace = .{ .root = "owner" };
    var state = std.StringHashMap(MoveSlot).init(std.testing.allocator);
    defer state.deinit();

    try state.put("compat:owner", .{ .live = true, .span = span, .place = root });
    consumeTrackedMoveReferent(&checker, .{ .key = "stale:owner", .place = root, .full_deref = true }, span, &state);
    try std.testing.expect(!state.get("compat:owner").?.live);
    try std.testing.expect(!reporter.has_errors);

    // A legacy alias key may happen to name a live owner, but it cannot
    // establish ownership identity. Refuse the move rather than consuming the
    // binding selected by that text.
    try state.put("compat:owner", .{ .live = true, .span = span, .place = root });
    consumeTrackedMoveReferent(&checker, .{ .key = "compat:owner", .place = null, .full_deref = true }, span, &state);
    try std.testing.expect(state.get("compat:owner").?.live);
    try std.testing.expect(reporter.has_errors);
}

fn divergentAliasSlot(key: []const u8, source: MoveSlot) MoveSlot {
    return .{
        .live = false,
        .span = source.span,
        .place = source.place,
        .alias_of = key,
        .divergent_alias = true,
        .cleanup_local = source.cleanup_local,
    };
}

fn isTrackedMoveSubplace(slot: MoveSlot, key: []const u8) bool {
    _ = key;
    const place = slot.place orelse return false;
    return place.isSubplace();
}

fn isOwnershipMoveSubplace(slot: MoveSlot, key: []const u8) bool {
    return isOwnershipMovePlace(slot, key) and isTrackedMoveSubplace(slot, key);
}

fn isOwnershipMovePlace(slot: MoveSlot, key: []const u8) bool {
    _ = key;
    return slot.alias_of == null and !slot.type_only and !isPureIndexFactSlot(slot) and slot.place != null;
}

// `exprIsMoveTyped` is a correctness decision for `drop` and dereference
// diagnostics. Source spelling may find a compatibility-map entry, but only a
// structural, non-alias ownership root may establish that the expression owns a
// linear resource.
fn ownershipBindingMoveSlotForIdent(name: []const u8, state: *const std.StringHashMap(MoveSlot)) ?MoveSlot {
    const expected: MovePlace = .{ .root = name };
    var it = state.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr.*;
        if (!isOwnershipMovePlace(slot, entry.key_ptr.*)) continue;
        if (slot.place.?.eql(expected)) return slot;
    }
    return null;
}

fn ownershipMoveSlotPtrForPlace(place: MovePlace, state: *std.StringHashMap(MoveSlot)) ?*MoveSlot {
    var it = state.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr;
        if (isOwnershipMoveSubplace(slot.*, entry.key_ptr.*) and slot.place.?.eql(place)) return slot;
    }
    return null;
}

fn ownershipMoveSlotForPlace(place: MovePlace, state: *const std.StringHashMap(MoveSlot)) ?MoveSlot {
    var it = state.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr.*;
        if (isOwnershipMoveSubplace(slot, entry.key_ptr.*) and slot.place.?.eql(place)) return slot;
    }
    return null;
}

// Binding names remain the map index while the checker carries compatibility
// metadata, but ownership checks must not recover a root by formatting or
// looking up a string key. A root place is matched structurally so a renamed
// compatibility entry cannot change move semantics.
fn rootMoveSlotForPlace(place: MovePlace, state: *const std.StringHashMap(MoveSlot)) ?MoveSlot {
    var it = state.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr.*;
        if (slot.alias_of != null or isPureIndexFactSlot(slot)) continue;
        const tracked = slot.place orelse continue;
        if (tracked.isSubplace()) continue;
        if (std.mem.eql(u8, tracked.root, place.root)) return slot;
    }
    return null;
}

fn rootMoveSlotPtrForPlace(place: MovePlace, state: *std.StringHashMap(MoveSlot)) ?*MoveSlot {
    var it = state.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr;
        if (slot.alias_of != null or isPureIndexFactSlot(slot.*)) continue;
        const tracked = slot.place orelse continue;
        if (tracked.isSubplace()) continue;
        if (std.mem.eql(u8, tracked.root, place.root)) return slot;
    }
    return null;
}

// A direct `&place` has a typed storage place before it crosses an aggregate or
// call boundary. Escape tracking only needs to poison the owning root, but it
// must find that owner through the typed place while that information exists.
fn borrowedMoveRootPlace(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) ?MovePlace {
    const target = switch (expr.kind) {
        .address_of => |inner| inner.*,
        .cast => |node| return borrowedMoveRootPlace(self, node.value.*, state),
        .grouped => |inner| return borrowedMoveRootPlace(self, inner.*, state),
        else => return null,
    };
    switch (target.kind) {
        .ident => |id| if (state.get(id.text)) |slot| {
            if (slot.alias_of != null) {
                const place = slot.alias_place orelse return null;
                if (rootMoveSlotForPlace(place, state) == null) return null;
                return place;
            }
        },
        else => {},
    }
    const place = (placeKeyAndType(self, target, state) orelse return null).place;
    if (rootMoveSlotForPlace(place, state) == null) return null;
    return .{ .root = place.root };
}

// `&t as usize` parses as `&(t as usize)`. Preserve `t`'s structural place
// before the integer cast drops pointer provenance, rather than recovering the
// root from the cast syntax's compatibility key.
fn integerCastBorrowedMoveRootPlace(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) ?MovePlace {
    const cast = switch (expr.kind) {
        .cast => |node| node,
        .grouped => |inner| return integerCastBorrowedMoveRootPlace(self, inner.*, state),
        else => return null,
    };
    const ctx = self.move_ctx orelse return null;
    if (!spine.isIntegerLike(spine.classifyTypeCtx(cast.ty.*, ctx.*))) return null;
    const place = (placeKeyAndType(self, cast.value.*, state) orelse return null).place;
    if (rootMoveSlotForPlace(place, state) == null) return null;
    return .{ .root = place.root };
}

fn markEscapedBorrowForPlace(place: MovePlace, escape_span: diagnostics.Span, state: *std.StringHashMap(MoveSlot)) void {
    if (rootMoveSlotPtrForPlace(place, state)) |slot| {
        if (slot.escaped_borrow == null) slot.escaped_borrow = escape_span;
    }
}

// A key-only escape candidate must never recover its owner by formatted text.
// Its producer lost the typed place required for ownership tracking, so reject
// the store/call boundary instead of accepting a potentially dangling borrow.
fn rejectUntypedBorrowEscape(self: *Checker, escape_span: diagnostics.Span) void {
    self.errorCode(escape_span, "E_USE_AFTER_MOVE", "cannot store or return a borrow of a linear `move` value without typed place metadata");
}

fn hasUntypedBorrowAlias(expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) bool {
    const target = switch (expr.kind) {
        .address_of => |inner| inner.*,
        .cast => |node| return hasUntypedBorrowAlias(node.value.*, state),
        .grouped => |inner| return hasUntypedBorrowAlias(inner.*, state),
        else => return false,
    };
    const id = switch (target.kind) {
        .ident => |value| value,
        else => return false,
    };
    const slot = state.get(id.text) orelse return false;
    return slot.alias_of != null and slot.alias_place == null;
}

// A named alias reaches this escape path with the source place it carried at
// registration. Keep that place through the recursive aggregate/call scan;
// `alias_of` must not be used to reconstruct ownership identity here.
fn markEscapedBorrowForCarriedAlias(value: ast.Expr, escape_span: diagnostics.Span, state: *std.StringHashMap(MoveSlot)) bool {
    const referent = carriedAliasReferentForExpr(value, state) orelse return false;
    const place = typedAliasReferentPlace(referent) orelse return true;
    const root = rootMoveSlotForPlace(place, state) orelse return true;
    if (root.live and root.alias_of == null) markEscapedBorrowForPlace(place, escape_span, state);
    return true;
}

// Map keys remain compatibility indexes, but ownership updates are addressed by
// the structured place. A repeated producer for the same place updates its
// existing slot rather than adding another formatted-key entry.
fn recordOwnershipMovePlace(self: *Checker, key: []const u8, place: MovePlace, slot: MoveSlot, state: *std.StringHashMap(MoveSlot)) void {
    if (ownershipMoveSlotPtrForPlace(place, state)) |existing| {
        existing.* = slot;
        return;
    }
    state.put(key, slot) catch {
        self.oom = true;
    };
}

fn removeOwnershipMovePlace(place: MovePlace, state: *std.StringHashMap(MoveSlot)) bool {
    var it = state.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr.*;
        if (isOwnershipMoveSubplace(slot, entry.key_ptr.*) and slot.place.?.eql(place)) {
            return state.remove(entry.key_ptr.*);
        }
    }
    return false;
}

fn moveSubplaceRootInOuter(slot: MoveSlot, key: []const u8, outer: *const std.StringHashMap(MoveSlot)) bool {
    _ = key;
    const place = slot.place orelse return false;
    return rootMoveSlotForPlace(place, outer) != null;
}

fn trackedSubplaceRoot(slot: MoveSlot, key: []const u8) ?[]const u8 {
    _ = key;
    const place = slot.place orelse return null;
    return if (place.isSubplace()) place.root else null;
}

fn checkAggregateAliasArgument(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) void {
    const place = aliasStoragePlaceForExpr(self, expr, state);
    var it = state.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.alias_of == null) continue;
        if (place) |arg_place| {
            if (entry.value_ptr.place) |slot_place| {
                if (!slot_place.eql(arg_place) and !arg_place.isPrefixOf(slot_place) and !storagePlaceMayBeWithinArgument(arg_place, slot_place)) continue;
                checkStaleAlias(self, "", entry.value_ptr.*, expr.span, state);
                continue;
            }
        }
    }
}

fn storagePlaceMayBeWithinArgument(argument: MovePlace, stored: MovePlace) bool {
    if (!std.mem.eql(u8, argument.root, stored.root) or argument.projection_count > stored.projection_count) return false;
    for (argument.projections[0..argument.projection_count], stored.projections[0..argument.projection_count]) |arg_projection, stored_projection| {
        if (!moveProjectionsMayOverlap(arg_projection, stored_projection)) return false;
    }
    return true;
}

fn moveProjectionsMayOverlap(left: MoveProjection, right: MoveProjection) bool {
    return switch (left) {
        .field => |left_name| switch (right) {
            .field => |right_name| std.mem.eql(u8, left_name, right_name),
            else => false,
        },
        .constant_index => |left_index| switch (right) {
            .constant_index => |right_index| left_index == right_index,
            .symbolic_index, .wildcard_index => true,
            else => false,
        },
        .symbolic_index => switch (right) {
            .constant_index, .symbolic_index, .wildcard_index => true,
            else => false,
        },
        .wildcard_index => switch (right) {
            .constant_index, .symbolic_index, .wildcard_index => true,
            else => false,
        },
    };
}

fn aliasStoragePlaceForExpr(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) ?MovePlace {
    if (placeKeyAndType(self, expr, state)) |pp| return pp.place;
    switch (expr.kind) {
        .grouped => |inner| return aliasStoragePlaceForExpr(self, inner.*, state),
        .ident => |id| {
            const slot = state.get(id.text) orelse return null;
            return slot.place;
        },
        else => {},
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

const AliasReferent = struct {
    key: []const u8,
    place: ?MovePlace,
    full_deref: bool,
};

fn aliasReferentIsTracked(referent: AliasReferent, state: *const std.StringHashMap(MoveSlot)) bool {
    return trackedAliasReferent(referent, state) != null;
}

// Every newly registered alias must carry its typed referent. A compatibility
// key indexes alias storage only; it cannot recover ownership identity.
fn trackedAliasReferent(referent: AliasReferent, state: *const std.StringHashMap(MoveSlot)) ?AliasReferent {
    const place = typedAliasReferentPlace(referent) orelse return null;
    if (rootMoveSlotForPlace(place, state) == null) return null;
    return .{ .key = referent.key, .place = place, .full_deref = referent.full_deref };
}

// A stored pointer alias carries its source place at registration time. Consumers
// must preserve that identity rather than recover it through `alias_of`, whose
// text is only a compatibility index and can differ after CFG joins or rewrites.
fn carriedAliasReferent(slot: MoveSlot) ?AliasReferent {
    const key = slot.alias_of orelse return null;
    const place = slot.alias_place orelse return null;
    return .{ .key = key, .place = place, .full_deref = slot.full_deref_alias };
}

fn carriedAliasReferentForExpr(expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) ?AliasReferent {
    return switch (expr.kind) {
        .ident => |id| blk: {
            const slot = state.get(id.text) orelse break :blk null;
            break :blk carriedAliasReferent(slot);
        },
        .grouped => |inner| carriedAliasReferentForExpr(inner.*, state),
        else => null,
    };
}

fn typedAliasReferentPlace(referent: AliasReferent) ?MovePlace {
    return referent.place;
}

fn aliasReferentTargetsOuter(referent: AliasReferent, outer: *const std.StringHashMap(MoveSlot)) bool {
    const place = typedAliasReferentPlace(referent) orelse return false;
    return rootMoveSlotForPlace(place, outer) != null;
}

fn aliasReferentForExpr(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) ?AliasReferent {
    if (fullDerefMoveSubplace(self, expr, state, aliases)) |pp| {
        return .{ .key = pp.key, .place = pp.place, .full_deref = true };
    }
    if (callLaunderedMoveAliasReferent(self, expr, state, aliases)) |referent| return referent;
    // A direct `&binding` is already a typed root place. Preserve that identity
    // before the legacy name-only alias helper is consulted; field/index address
    // expressions retain their conservative escape boundary below.
    if (directAliasReferentPlace(self, expr, state)) |pp| {
        return .{ .key = pp.key, .place = pp.place, .full_deref = true };
    }
    // A stored alias already carries both its compatibility metadata and its
    // semantic referent place. Do not re-parse a root key from the expression:
    // key-only aliases are intentionally not registered as tracked aliases.
    return carriedAliasReferentForExpr(expr, state);
}

fn directAliasReferentPlace(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) ?PlaceKeyTy {
    const target = switch (expr.kind) {
        .address_of => |inner| inner.*,
        .grouped => |inner| return directAliasReferentPlace(self, inner.*, state),
        else => return null,
    };
    return switch (target.kind) {
        .ident, .grouped => placeKeyAndType(self, target, state),
        else => null,
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
            moveExitEdgeCfg(self, state, "linear `move` value is still live where `?` may return on error (consume it before `?`, or register it with `defer`)");
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
                } else if (stateHasMovedPlaceOrChild(pp.place, state)) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "use of linear `move` field after it was moved out");
                } else {
                    recordOwnershipMovePlace(self, pp.key, pp.place, .{ .live = false, .span = expr.span, .place = pp.place }, state);
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
            // `p = &o`) from the alias's carried typed referent. Scalar `*u32` derefs
            // carry no move alias fact and remain ordinary borrows. The type-based check
            // is a fallback for derefs whose result type the move Context can resolve
            // (it cannot for local pointer vars).
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
            } else if (arrayIndexEmbedsMove(self, inner.*, state, aliases)) {
                self.errorCode(expr.span, "E_MOVE_ARRAY_UNSUPPORTED", "cannot move a linear `move` array element through a non-constant index; element ownership is only tracked for constant indexes");
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
                } else if (stateHasActivePlaceOrConflict(pp.place, state)) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "use of linear `move` array element after it was moved out");
                } else {
                    recordOwnershipMovePlace(self, pp.key, pp.place, .{ .live = false, .span = expr.span, .place = pp.place }, state);
                }
            } else if (wildcardMoveIndexedPlaceKey(self, expr, state, aliases)) |pp| {
                if (deferredBorrowConflictsWithTrackedPlace(pp.place, state)) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "linear `move` array element is borrowed by a deferred expression and cannot be moved before the defer runs");
                } else if (stateHasActivePlaceOrConflict(pp.place, state)) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "use of linear `move` array element after it was moved out");
                } else {
                    recordOwnershipMovePlace(self, pp.key, pp.place, .{ .live = false, .span = expr.span, .place = pp.place }, state);
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
    if (directAliasReferentPlace(self, expr, state)) |referent| {
        return .{ .key = referent.key, .place = referent.place, .full_deref = true };
    }
    var referent = carriedAliasReferentForExpr(expr, state) orelse return null;
    referent.full_deref = true;
    return referent;
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
        } else if (slot.deferred_borrow) {
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
    const place = typedAliasReferentPlace(referent) orelse {
        self.errorCode(span, "E_USE_AFTER_MOVE", "cannot move a linear `move` value through an alias without a typed referent place");
        return;
    };
    if (place.isSubplace()) {
        consumeTrackedMovePlace(self, referent.key, place, span, state);
    } else {
        consumeTrackedMoveRootPlace(self, place, span, state);
    }
}

// An alias can retain a typed root place while its compatibility lookup key was
// rewritten by an assignment or CFG merge. Root consumption must follow that
// place, not the compatibility spelling, or the owner can be left live.
fn consumeTrackedMoveRootPlace(self: *Checker, place: MovePlace, span: diagnostics.Span, state: *std.StringHashMap(MoveSlot)) void {
    const slot = rootMoveSlotPtrForPlace(place, state) orelse return;
    if (slot.type_only) return;
    if (!slot.live) {
        self.errorCode(span, "E_USE_AFTER_MOVE", "use of linear `move` value after it was moved");
    } else if (slot.escaped_borrow != null) {
        self.errorCode(span, "E_USE_AFTER_MOVE", "cannot move this linear `move` value: a borrow of it (or of one of its fields) has been stored into memory and may still be read; the move would leave that borrow dangling");
        slot.live = false;
    } else if (slot.deferred) {
        self.errorCode(span, "E_USE_AFTER_MOVE", "linear `move` value is reserved by a `defer` and cannot be moved");
    } else if (slot.deferred_borrow) {
        self.errorCode(span, "E_USE_AFTER_MOVE", "linear `move` value is borrowed by a deferred expression and cannot be moved before the defer runs");
        slot.live = false;
    } else if (hasMovedSubplace(place, state)) {
        self.errorCode(span, "E_USE_AFTER_MOVE", "linear `move` value used as a whole after one of its fields was moved out");
        slot.live = false;
    } else {
        slot.live = false;
    }
}

fn consumeTrackedMovePlace(self: *Checker, key: []const u8, place: MovePlace, span: diagnostics.Span, state: *std.StringHashMap(MoveSlot)) void {
    const root = rootMoveSlotForPlace(place, state) orelse return;
    if (!root.live) {
        self.errorCode(span, "E_USE_AFTER_MOVE", "use of linear `move` field after its owner was moved");
        return;
    }
    if (deferredBorrowConflictsWithTrackedPlace(place, state)) {
        self.errorCode(span, "E_USE_AFTER_MOVE", "linear `move` field is borrowed by a deferred expression and cannot be moved before the defer runs");
        return;
    }
    if (stateHasActivePlaceOrConflict(place, state)) {
        self.errorCode(span, "E_USE_AFTER_MOVE", "use of linear `move` field after it was moved out");
        return;
    }
    recordOwnershipMovePlace(self, key, place, .{ .live = false, .span = span, .place = place }, state);
}

// A while condition has a zero-iteration bypass and an evaluated-condition path.
// The worklist owns transport between those blocks; loop widening remains the
// existing dedicated rule so condition-only moves retain E_MOVE_LOOP_RESOURCE.
fn moveWhileConditionCfg(self: *Checker, condition: ast.Expr, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) void {
    var short = shortCircuitMoveCfg(self) orelse return;
    defer short.deinit();

    var worklist = MoveStateCfgWorklist.init(self, &short.cfg, short.entry, state) orelse return;
    defer worklist.deinit();
    worklist.useLoopConditionJoinPolicy();
    while (worklist.pop()) |block| {
        const block_state = worklist.statePtr(block) orelse continue;
        if (block == short.entry) {
            worklist.propagateSuccessors(self, block, block_state);
        } else if (block == short.rhs) {
            moveConsume(self, condition, block_state, aliases);
            worklist.propagateSuccessors(self, block, block_state);
        } else if (block == short.join) {
            replaceMoveState(self, state, block_state);
        }
    }
}

// The loop body now runs through an explicit loop-head CFG. The body is
// evaluated once for diagnostics, then its outgoing state travels over the
// backedge and joins the zero-iteration path at the head. The existing loop
// widening below remains the authority for rejecting outer-resource changes.
fn runLoopBodyCfgWorklist(self: *Checker, loop_cfg: *const LoopBodyMoveCfg, worklist: *MoveStateCfgWorklist, body: ast.Block, result_state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr), body_diverges: *bool, body_visited: *bool) void {
    while (worklist.pop()) |block| {
        const block_state = worklist.statePtr(block) orelse continue;
        if (block == loop_cfg.entry) {
            worklist.propagateSuccessors(self, block, block_state);
        } else if (block == loop_cfg.loop_head) {
            worklist.propagateSuccessorsExcept(self, block, block_state, if (body_visited.*) loop_cfg.body else null);
        } else if (block == loop_cfg.body) {
            body_visited.* = true;
            body_diverges.* = moveBlock(self, body, block_state, aliases);
            if (!body_diverges.*) worklist.propagateSuccessors(self, block, block_state);
        } else if (block == loop_cfg.break_source or block == loop_cfg.continue_source) {
            // The queued state belongs to this loop frame, so the active frame
            // is the same target that a labeled exit resolved during AST walk.
            checkLoopExitLeaks(self, block_state, null);
            worklist.propagateSuccessors(self, block, block_state);
        } else if (block == loop_cfg.break_exit) {
            // A queued labeled break targets this loop's terminal CFG block.
            // Preserve that edge's ownership state for the enclosing loop's
            // scope and exit checks instead of dropping it after validation.
            replaceMoveState(self, result_state, block_state);
        } else if (block == loop_cfg.exit) {
            replaceMoveState(self, result_state, block_state);
        }
    }
}

fn enqueuePendingLoopExitStates(self: *Checker, loop_cfg: *const LoopBodyMoveCfg, worklist: *MoveStateCfgWorklist) void {
    const frame = moveLoopTargetFrame(self, null) orelse return;
    while (frame.pending_exits.items.len > 0) {
        var pending = frame.pending_exits.pop().?;
        defer pending.state.deinit();
        const source = switch (pending.kind) {
            .break_exit => loop_cfg.break_source,
            .continue_exit => loop_cfg.continue_source,
        };
        worklist.propagateSuccessor(self, source, &pending.state);
    }
}

fn moveLoopBodyCfg(self: *Checker, body: ast.Block, entry_state: *const std.StringHashMap(MoveSlot), result_state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
    var loop_cfg = loopBodyMoveCfg(self) orelse return false;
    defer loop_cfg.deinit();

    var worklist = MoveStateCfgWorklist.init(self, &loop_cfg.cfg, loop_cfg.entry, entry_state) orelse return false;
    defer worklist.deinit();
    // Loop-head widening has its own E_MOVE_LOOP_RESOURCE policy. Merge the
    // zero-iteration and backedge states conservatively here, then let that
    // policy report outer ownership changes once rather than also issuing the
    // generic branch-join diagnostic.
    worklist.suppressJoinDiagnostics();
    var body_diverges = false;
    var body_visited = false;
    runLoopBodyCfgWorklist(self, &loop_cfg, &worklist, body, result_state, aliases, &body_diverges, &body_visited);
    enqueuePendingLoopExitStates(self, &loop_cfg, &worklist);
    runLoopBodyCfgWorklist(self, &loop_cfg, &worklist, body, result_state, aliases, &body_diverges, &body_visited);
    return body_diverges;
}

fn moveConsumeShortCircuitRhs(self: *Checker, rhs: ast.Expr, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) void {
    var short = shortCircuitMoveCfg(self) orelse return;
    defer short.deinit();

    var worklist = MoveStateCfgWorklist.init(self, &short.cfg, short.entry, state) orelse return;
    defer worklist.deinit();
    worklist.useShortCircuitJoinPolicy(rhs.span, false);
    while (worklist.pop()) |block| {
        const block_state = worklist.statePtr(block) orelse continue;
        if (block == short.entry) {
            worklist.propagateSuccessors(self, block, block_state);
        } else if (block == short.rhs) {
            moveConsume(self, rhs, block_state, aliases);
            worklist.propagateSuccessors(self, block, block_state);
        } else if (block == short.join) {
            replaceMoveState(self, state, block_state);
        }
    }
}

fn mergeShortCircuitMoveStates(self: *Checker, state: *std.StringHashMap(MoveSlot), rhs_state: *const std.StringHashMap(MoveSlot), span: diagnostics.Span, deferred: bool) void {
    var index_fact_removals: std.ArrayListUnmanaged([]const u8) = .empty;
    defer index_fact_removals.deinit(self.reporter.allocator);

    var it = state.iterator();
    while (it.next()) |entry| {
        const after = matchingMoveStateSlot(rhs_state, entry.key_ptr.*, entry.value_ptr.*) orelse {
            if (isPureIndexFactSlot(entry.value_ptr.*)) {
                index_fact_removals.append(self.reporter.allocator, entry.key_ptr.*) catch {
                    self.oom = true;
                };
            }
            continue;
        };
        const before = entry.value_ptr.*;
        if (before.live != after.live or before.deferred != after.deferred or !sameMaybeSpan(before.escaped_borrow, after.escaped_borrow) or !sameDeferredBorrowFact(before, after)) {
            self.errorCode(span, "E_MOVE_BRANCH_MISMATCH", if (deferred) "cannot consume, reserve, or defer-borrow an outer linear `move` value only on one side of a short-circuit expression" else "cannot consume, reserve, or escape an outer linear `move` value only on one side of a short-circuit expression");
            entry.value_ptr.live = false;
            entry.value_ptr.deferred = false;
            entry.value_ptr.escaped_borrow = null;
            entry.value_ptr.deferred_borrow = false;
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
        if (moveStateSlotMatches(state, entry.key_ptr.*, entry.value_ptr.*)) continue;
        const root = trackedSubplaceRoot(entry.value_ptr.*, entry.key_ptr.*) orelse continue;
        if (rootMoveSlotPtrForPlace(.{ .root = root }, state)) |root_slot| {
            self.errorCode(span, "E_MOVE_BRANCH_MISMATCH", if (deferred) "cannot defer-consume a linear `move` place only on one side of a short-circuit expression" else "cannot move a linear `move` place only on one side of a short-circuit expression");
            root_slot.live = false;
            root_slot.deferred = false;
            root_slot.escaped_borrow = null;
        }
    }
}

fn moveDeferShortCircuitRhs(self: *Checker, rhs: ast.Expr, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) void {
    var short = shortCircuitMoveCfg(self) orelse return;
    defer short.deinit();

    var worklist = MoveStateCfgWorklist.init(self, &short.cfg, short.entry, state) orelse return;
    defer worklist.deinit();
    worklist.useShortCircuitJoinPolicy(rhs.span, true);
    while (worklist.pop()) |block| {
        const block_state = worklist.statePtr(block) orelse continue;
        if (block == short.entry) {
            worklist.propagateSuccessors(self, block, block_state);
        } else if (block == short.rhs) {
            moveDefer(self, rhs, block_state, aliases);
            worklist.propagateSuccessors(self, block, block_state);
        } else if (block == short.join) {
            replaceMoveState(self, state, block_state);
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

// Typed deferred-borrow places are the semantic identity. A legacy key-only
// reservation cannot prove that two CFG states borrowed the same resource.
fn sameDeferredBorrowFact(left: MoveSlot, right: MoveSlot) bool {
    if (left.deferred_borrow_place) |left_place| {
        if (right.deferred_borrow_place) |right_place| return left_place.eql(right_place);
        return false;
    }
    if (right.deferred_borrow_place != null) return false;
    return !left.deferred_borrow and !right.deferred_borrow;
}

fn moveStatesEqual(left: *const std.StringHashMap(MoveSlot), right: *const std.StringHashMap(MoveSlot)) bool {
    if (left.count() != right.count()) return false;
    var it = left.iterator();
    while (it.next()) |entry| {
        const other = matchingMoveStateSlot(right, entry.key_ptr.*, entry.value_ptr.*) orelse return false;
        if (!moveSlotStateEqual(entry.value_ptr.*, other)) return false;
    }
    return true;
}

fn moveSlotStateEqual(left: MoveSlot, right: MoveSlot) bool {
    return left.live == right.live and
        sameMaybePlace(left.place, right.place) and
        left.deferred == right.deferred and
        sameDeferredBorrowFact(left, right) and
        std.meta.eql(left.ty, right.ty) and
        left.type_only == right.type_only and
        left.const_index == right.const_index and
        sameMaybeKey(left.symbolic_index, right.symbolic_index) and
        sameAliasFact(left, right) and
        sameMaybeSpan(left.escaped_borrow, right.escaped_borrow) and
        left.cleanup_local == right.cleanup_local;
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
        !slot.deferred_borrow and
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

const AliasPlaceInfo = struct {
    key: []const u8,
    place: MovePlace,
};

// Build the dotted place key and leaf type for a place expression (`x`, `x.f`, `x.f.g`)
// whose root is a tracked move binding — so nested fields, not just one level, are
// distinct places. The key is allocated and owned by `move_place_keys`. Returns null if
// the root is not a tracked move binding or a field type cannot be resolved.
pub fn placeKeyAndType(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) ?PlaceKeyTy {
    switch (expr.kind) {
        .grouped => |inner| return placeKeyAndType(self, inner.*, state),
        .ident => |id| {
            const slot = bindingMoveSlotForIdent(id.text, state) orelse return null;
            const ty = slot.ty orelse return null;
            const place: MovePlace = slot.place orelse .{ .root = id.text };
            return .{ .key = id.text, .place = place, .ty = ty };
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

// Source identifier spelling is a map index only. A typed root slot can retain
// a different compatibility key after CFG joins, so resolve the exact root
// place before falling back to key-only metadata such as index facts.
fn bindingMoveSlotForIdent(name: []const u8, state: *const std.StringHashMap(MoveSlot)) ?MoveSlot {
    const expected: MovePlace = .{ .root = name };
    if (state.get(name)) |slot| {
        if (slot.place) |place| {
            if (place.eql(expected)) return slot;
        } else return slot;
    }
    var it = state.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr.*;
        const place = slot.place orelse continue;
        if (place.eql(expected)) return slot;
    }
    return null;
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

fn storageElementType(ty: ast.TypeExpr, ctx: Context) ?ast.TypeExpr {
    return switch (resolveAliasType(ty, ctx).kind) {
        .pointer => |node| node.child.*,
        .raw_many_pointer => |node| node.child.*,
        .slice => |node| node.child.*,
        .array => |node| node.child.*,
        .qualified => |node| storageElementType(node.child.*, ctx),
        else => null,
    };
}

fn derefPlaceElementType(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot), ctx: Context) ?ast.TypeExpr {
    const inner = switch (expr.kind) {
        .deref => |node| node.*,
        else => return null,
    };
    const base = placeKeyAndType(self, inner, state) orelse return null;
    return storageElementType(base.ty, ctx);
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
            else if (derefPlaceElementType(self, ix.base.*, state, ctx.*)) |ty|
                ty
            else
                spine.exprResultType(ix.base.*, ctx.*) orelse {
                    if (arrayIndexEmbedsMove(self, ix.base.*, state, aliases)) return true;
                    return arrayLiteralElementEmbedsMove(self, ix.base.*, ctx.*, aliases) orelse false;
                };
            const resolved_base_ty = resolveAliasType(base_ty_expr, ctx.*);
            const array_ty = switch (resolved_base_ty.kind) {
                .array => resolved_base_ty,
                else => storageElementType(base_ty_expr, ctx.*) orelse return false,
            };
            const resolved_array_ty = resolveAliasType(array_ty, ctx.*);
            const child_ty = switch (array_ty.kind) {
                .array => |node| node.child.*,
                else => switch (resolved_array_ty.kind) {
                    .array => |node| node.child.*,
                    else => return false,
                },
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
    return stateHasMovedPlaceOrConflict(pp.place, state);
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

fn stateHasActivePlaceOrConflict(place: MovePlace, state: *const std.StringHashMap(MoveSlot)) bool {
    return stateContainsMovePlace(place, state) or stateHasConflictingMovePlace(place, state);
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

fn stateHasMovedPlaceOrConflict(place: MovePlace, state: *const std.StringHashMap(MoveSlot)) bool {
    return stateHasMovedPlace(place, state) or stateHasMovedConflictingPlace(place, state);
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

fn stateHasMovedPlaceChildOrConflict(place: MovePlace, state: *const std.StringHashMap(MoveSlot)) bool {
    return stateHasMovedPlaceOrConflict(place, state) or stateHasMovedChildPlace(place, state);
}

fn stateHasMovedPlaceOrChild(place: MovePlace, state: *const std.StringHashMap(MoveSlot)) bool {
    return stateContainsMovePlace(place, state) or hasMovedSubplace(place, state);
}

fn deferredBorrowConflictsWithTrackedPlace(place: MovePlace, state: *const std.StringHashMap(MoveSlot)) bool {
    const root_slot = rootMoveSlotForPlace(place, state) orelse return false;
    const borrowed = root_slot.deferred_borrow_place orelse return false;
    return borrowed.eql(place) or borrowed.isPrefixOf(place) or place.isPrefixOf(borrowed) or borrowed.conflicts(place);
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

// Remove every typed child place when the whole aggregate leaves play (consumed
// or forgotten), so a later same-named binding starts clean.
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
            if (slot.place) |place| if (base.isPrefixOf(place)) {
                _ = state.remove(k);
                removed_any = true;
                break; // the iterator is now invalid; rescan with a fresh one
            };
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
                } else if (slot.deferred_borrow) {
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
        .ident => |id| if (ownershipBindingMoveSlotForIdent(id.text, state) != null) return true,
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
                    if (borrowedMoveRootPlace(self, c.value.*, state)) |place| {
                        markEscapedBorrowForPlace(place, escape_span, state);
                        return;
                    }
                    if (hasUntypedBorrowAlias(c.value.*, state)) {
                        rejectUntypedBorrowEscape(self, escape_span);
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
            if (integerCastBorrowedMoveRootPlace(self, inner.*, state)) |place| {
                markEscapedBorrowForPlace(place, escape_span, state);
                return;
            }
            if (hasUntypedBorrowAlias(inner.*, state)) {
                rejectUntypedBorrowEscape(self, escape_span);
                return;
            }
        },
        .grouped => |inner| return markBorrowEscape(self, inner.*, escape_span, state),
        else => {},
    }
    if (borrowedMoveRootPlace(self, value, state)) |place| {
        markEscapedBorrowForPlace(place, escape_span, state);
        return;
    }
    if (markEscapedBorrowForCarriedAlias(value, escape_span, state)) return;
    if (hasUntypedBorrowAlias(value, state)) rejectUntypedBorrowEscape(self, escape_span);
}

// T1.3 (borrow-escape through a CALL argument). Scan a call argument for a borrow of a live
// move binding that escapes into the callee. The escape rule for a call arg differs from the
// decl/assignment store: a BARE top-level `&t` argument is a transient borrow for the duration
// of the call (the legit `pk(&t); cn(t)` pattern), so it does NOT escape here — that direction
// is covered precisely by the pointer-returning-call laundering check
// (`callLaunderedMoveAliasReferent`).
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

    for (call.args) |arg| markBorrowEscapeCapturedCallArg(self, arg, escape_span, state);
}

fn markBorrowEscapeCapturedCallArg(self: *Checker, arg: ast.Expr, escape_span: diagnostics.Span, state: *std.StringHashMap(MoveSlot)) void {
    switch (arg.kind) {
        .grouped => |inner| return markBorrowEscapeCapturedCallArg(self, inner.*, escape_span, state),
        .struct_literal => |fields| {
            for (fields) |field| markBorrowEscapeCapturedCallArg(self, field.value, escape_span, state);
            return;
        },
        .array_literal => |items| {
            for (items) |item| markBorrowEscapeCapturedCallArg(self, item, escape_span, state);
            return;
        },
        else => {},
    }

    // This helper does not need type information for the aggregate walk, but a
    // direct address expression can still be typed through the move checker.
    // Reuse that path before the legacy root-name fallback below.
    if (borrowedMoveRootPlace(self, arg, state)) |place| {
        if (rootMoveSlotPtrForPlace(place, state)) |slot| {
            if (slot.live and slot.alias_of == null and slot.escaped_borrow == null) slot.escaped_borrow = escape_span;
        }
        return;
    }
    if (markEscapedBorrowForCarriedAlias(arg, escape_span, state)) return;
    if (hasUntypedBorrowAlias(arg, state)) {
        rejectUntypedBorrowEscape(self, escape_span);
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
            if (ownershipMoveSlotForPlace(referent.place, state)) |slot| {
                if (!slot.live) continue;
            }
            return .{ .key = referent.key, .place = referent.place, .full_deref = false };
        }
        if (borrowedMoveRootPlace(self, arg, state)) |place| {
            if (rootMoveSlotForPlace(place, state)) |slot| {
                if (slot.live and slot.alias_of == null) return .{ .key = place.root, .place = place, .full_deref = false };
            }
            continue;
        }
        const carried = carriedAliasReferentForExpr(arg, state) orelse continue;
        const place = typedAliasReferentPlace(carried) orelse continue;
        // Only register the laundered alias while the root is still LIVE. If it was already
        // moved, the borrow of it (the `&t` arg) is itself the use-after-move and is reported
        // by moveBorrow at the call — registering an alias here would double-report on the
        // later `q.*` use.
        if (rootMoveSlotForPlace(place, state)) |root| {
            if (root.live and root.alias_of == null) {
                return .{ .key = carried.key, .place = place, .full_deref = false };
            }
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
        const tracked_referent = trackedAliasReferent(referent, state) orelse continue;
        const key = std.fmt.allocPrint(self.reporter.allocator, "{s}.{s}", .{ base, field.name.text }) catch {
            self.oom = true;
            continue;
        };
        self.move_place_keys.append(self.reporter.allocator, key) catch {
            self.oom = true;
            self.reporter.allocator.free(key);
            continue;
        };
        state.put(key, .{ .live = false, .span = field.value.span, .place = field_place, .alias_of = tracked_referent.key, .alias_place = tracked_referent.place }) catch {
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
    const storage_place = aliasStoragePlaceForExpr(self, expr, state);
    if (storage_place) |place| {
        if (aliasSlotForStoragePlace(place, state)) |slot| return slot;
        if (staleAliasWildcardSlotForConcretePlace(place, state)) |slot| return slot;
        if (aliasConflictingSlotForStoragePlace(place, state)) |slot| return slot;
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
    const target_info = aliasPlaceInfo(self, target, state) orelse
        aliasWildcardPlaceInfo(self, target, state) orelse {
        markBorrowEscape(self, value, escape_span, state);
        return;
    };

    const referent = aliasReferentForExpr(self, value, state, aliases) orelse {
        _ = removeAliasSlotForStoragePlace(target_info.place, state);
        self.reporter.allocator.free(target_info.key);
        markBorrowEscape(self, value, escape_span, state);
        return;
    };
    const tracked_referent = trackedAliasReferent(referent, state) orelse {
        _ = removeAliasSlotForStoragePlace(target_info.place, state);
        self.reporter.allocator.free(target_info.key);
        return;
    };

    if (aliasSlotPtrForStoragePlace(target_info.place, state)) |slot| {
        slot.* = .{ .live = false, .span = value.span, .place = target_info.place, .alias_of = tracked_referent.key, .alias_place = tracked_referent.place };
        self.reporter.allocator.free(target_info.key);
        return;
    }

    self.move_place_keys.append(self.reporter.allocator, target_info.key) catch {
        self.oom = true;
        self.reporter.allocator.free(target_info.key);
        return;
    };
    state.put(target_info.key, .{ .live = false, .span = value.span, .place = target_info.place, .alias_of = tracked_referent.key, .alias_place = tracked_referent.place }) catch {
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
        const concrete_element_place = element_place orelse {
            self.reporter.allocator.free(key);
            markBorrowEscape(self, item, escape_span, state);
            continue;
        };
        recordAliasPlaceOrEscapeWithKey(self, key, concrete_element_place, item, escape_span, state, aliases);
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
    const target_info = aliasPlaceInfo(self, target, state) orelse
        aliasWildcardPlaceInfo(self, target, state) orelse {
        markBorrowEscape(self, value, escape_span, state);
        return;
    };
    recordAliasPlaceOrEscapeWithKey(self, target_info.key, target_info.place, value, escape_span, state, aliases);
}

fn recordAliasPlaceOrEscapeWithKey(
    self: *Checker,
    key: []const u8,
    key_place: MovePlace,
    value: ast.Expr,
    escape_span: diagnostics.Span,
    state: *std.StringHashMap(MoveSlot),
    aliases: *const std.StringHashMap(ast.TypeExpr),
) void {
    const referent = aliasReferentForExpr(self, value, state, aliases) orelse {
        _ = removeAliasSlotForStoragePlace(key_place, state);
        self.reporter.allocator.free(key);
        markBorrowEscape(self, value, escape_span, state);
        return;
    };
    const tracked_referent = trackedAliasReferent(referent, state) orelse {
        _ = removeAliasSlotForStoragePlace(key_place, state);
        self.reporter.allocator.free(key);
        return;
    };

    if (aliasSlotPtrForStoragePlace(key_place, state)) |slot| {
        slot.* = .{ .live = false, .span = value.span, .place = key_place, .alias_of = tracked_referent.key, .alias_place = tracked_referent.place };
        self.reporter.allocator.free(key);
        return;
    }

    self.move_place_keys.append(self.reporter.allocator, key) catch {
        self.oom = true;
        self.reporter.allocator.free(key);
        return;
    };
    state.put(key, .{ .live = false, .span = value.span, .place = key_place, .alias_of = tracked_referent.key, .alias_place = tracked_referent.place }) catch {
        self.oom = true;
    };
}

pub fn aliasPlaceSlot(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) ?MoveSlot {
    const storage_place = aliasStoragePlaceForExpr(self, expr, state);
    if (storage_place) |place| {
        if (aliasSlotForStoragePlace(place, state)) |slot| return slot;
        if (staleAliasWildcardSlotForConcretePlace(place, state)) |slot| return slot;
        if (aliasConflictingSlotForStoragePlace(place, state)) |slot| return slot;
    }
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

fn aliasSlotPtrForStoragePlace(place: MovePlace, state: *std.StringHashMap(MoveSlot)) ?*MoveSlot {
    var it = state.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr;
        if (slot.alias_of == null) continue;
        if (slot.place) |stored| {
            if (stored.eql(place)) return slot;
        }
    }
    return null;
}

fn removeAliasSlotForStoragePlace(place: MovePlace, state: *std.StringHashMap(MoveSlot)) bool {
    var it = state.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr.*;
        if (slot.alias_of == null) continue;
        if (slot.place) |stored| {
            if (stored.eql(place)) {
                return state.remove(entry.key_ptr.*);
            }
        }
    }
    return false;
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

fn aliasConflictingSlotForStoragePlace(place: MovePlace, state: *const std.StringHashMap(MoveSlot)) ?MoveSlot {
    var it = state.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr.*;
        if (slot.alias_of == null) continue;
        if (slot.place) |stored| {
            if (!stored.eql(place) and stored.conflicts(place)) return slot;
        }
    }
    return null;
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
    if (slot.divergent_alias) return true;
    _ = slot.alias_of orelse return false;
    if (slot.alias_place) |typed| return referentPlaceMoved(typed, state);
    return true;
}

fn referentPlaceMoved(place: MovePlace, state: *const std.StringHashMap(MoveSlot)) bool {
    if (rootMoveSlotForPlace(place, state)) |root| {
        if (!root.live) return true;
    }
    return stateHasMovedPlaceChildOrConflict(place, state);
}

fn aliasPlaceInfo(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) ?AliasPlaceInfo {
    const pp = placeKeyAndType(self, expr, state) orelse return null;
    const key = self.reporter.allocator.dupe(u8, pp.key) catch {
        self.oom = true;
        return null;
    };
    return .{ .key = key, .place = pp.place };
}

fn aliasWildcardPlaceInfo(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) ?AliasPlaceInfo {
    switch (expr.kind) {
        .grouped => |inner| return aliasWildcardPlaceInfo(self, inner.*, state),
        .member => |m| {
            const base = aliasWildcardPlaceInfo(self, m.base.*, state) orelse return null;
            defer self.reporter.allocator.free(base.key);
            const key = std.fmt.allocPrint(self.reporter.allocator, "{s}.{s}", .{ base.key, m.name.text }) catch {
                self.oom = true;
                return null;
            };
            const place = base.place.project(.{ .field = m.name.text }) orelse {
                self.reporter.allocator.free(key);
                return null;
            };
            return .{ .key = key, .place = place };
        },
        .index => |ix| {
            const ctx = self.move_ctx orelse return null;
            const base = placeKeyAndType(self, ix.base.*, state) orelse return null;
            const base_ty = resolveAliasType(aliasPlaceBaseType(ix.base.*, state) orelse
                spine.exprResultType(ix.base.*, ctx.*) orelse
                base.ty, ctx.*);
            const array = switch (base_ty.kind) {
                .array => |node| node,
                else => return null,
            };
            const len = parseArrayLen(array.len, ctx.const_fns, ctx.const_globals) orelse return null;
            if (len <= 1) return null;
            const place = base.place.project(.wildcard_index) orelse return null;
            const key = std.fmt.allocPrint(self.reporter.allocator, "{s}[*]", .{base.key}) catch {
                self.oom = true;
                return null;
            };
            return .{ .key = key, .place = place };
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
            moveExitEdgeCfg(self, state, "linear `move` value is still live where `?` may return on error (consume it before `?`, or register it with `defer`)");
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

fn markDeferredBorrowReferent(self: *Checker, borrowed_place: MovePlace, span: diagnostics.Span, state: *std.StringHashMap(MoveSlot)) void {
    const root_slot = rootMoveSlotPtrForPlace(borrowed_place, state) orelse return;
    if (root_slot.cleanup_local) {
        checkStaleAlias(self, "", .{ .live = false, .span = span, .alias_of = borrowed_place.root, .alias_place = borrowed_place }, span, state);
        return;
    }
    if (!root_slot.live) {
        self.errorCode(span, "E_USE_AFTER_MOVE", "defer borrows a linear `move` value after it was moved");
        return;
    }
    if (borrowed_place.isSubplace()) {
        if (stateHasMovedPlaceChildOrConflict(borrowed_place, state)) {
            self.errorCode(span, "E_USE_AFTER_MOVE", "defer borrows a linear `move` field or array element after it was moved out");
            return;
        }
    } else if (hasMovedSubplace(borrowed_place, state)) {
        self.errorCode(span, "E_USE_AFTER_MOVE", "defer borrows a linear `move` value after one of its fields or elements was moved out");
        return;
    }
    if (root_slot.deferred_borrow) {
        if (root_slot.deferred_borrow_place) |existing_place| {
            if (existing_place.eql(borrowed_place)) return;
        }
        if (root_slot.deferred_borrow_place == null) {
            root_slot.deferred_borrow_place = borrowed_place;
            return;
        }
        root_slot.deferred_borrow = true;
        root_slot.deferred_borrow_place = root_slot.place;
        return;
    }
    root_slot.deferred_borrow = true;
    root_slot.deferred_borrow_place = borrowed_place;
}

fn markDeferredBorrowAliasReferent(self: *Checker, referent: AliasReferent, span: diagnostics.Span, state: *std.StringHashMap(MoveSlot)) void {
    const borrowed_place = deferredAliasBorrowPlace(referent.place) orelse return;
    markDeferredBorrowReferent(self, borrowed_place, span, state);
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
                    markDeferredBorrowAliasReferent(self, .{ .key = referent, .place = slot.alias_place, .full_deref = slot.full_deref_alias }, expr.span, state);
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
                if (rootMoveSlotForPlace(pp.place, state)) |slot| {
                    if (slot.cleanup_local) {
                        moveBorrow(self, inner.*, state, aliases);
                    } else {
                        markDeferredBorrowReferent(self, pp.place, expr.span, state);
                    }
                } else {
                    markDeferredBorrowReferent(self, pp.place, expr.span, state);
                }
            } else {
                moveBorrow(self, inner.*, state, aliases);
            }
        },
        .call => |c| for (c.args) |arg| {
            checkAggregateAliasArgument(self, arg, state);
            if (callLaunderedMoveAliasReferent(self, arg, state, aliases)) |referent| {
                markDeferredBorrowAliasReferent(self, referent, arg.span, state);
                continue;
            }
            moveDefer(self, arg, state, aliases);
        },
        .member => |m| {
            moveBorrow(self, m.base.*, state, aliases);
            if (aggregateFieldAliasSlot(self, expr, state)) |slot| {
                if (slot.alias_of) |referent| markDeferredBorrowAliasReferent(self, .{ .key = referent, .place = slot.alias_place, .full_deref = slot.full_deref_alias }, expr.span, state);
                return;
            }
            // `defer free(p.field)`: reserve the move field for lexical cleanup so it is
            // neither leaked at exit nor moved out before the defer runs.
            if (moveFieldPlaceKey(self, expr, m, state, aliases)) |pp| {
                if (deferredBorrowConflictsWithTrackedPlace(pp.place, state)) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "defer cannot consume a linear `move` field already borrowed by a deferred expression");
                } else if (stateHasMovedPlaceOrChild(pp.place, state)) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "defer reserves a linear `move` field already moved out");
                } else {
                    recordOwnershipMovePlace(self, pp.key, pp.place, .{ .live = true, .span = expr.span, .place = pp.place, .deferred = true }, state);
                }
            }
        },
        .index => |ix| {
            moveBorrow(self, ix.base.*, state, aliases);
            moveConsume(self, ix.index.*, state, aliases);
            if (aliasPlaceSlot(self, expr, state)) |slot| {
                if (slot.alias_of) |referent| markDeferredBorrowAliasReferent(self, .{ .key = referent, .place = slot.alias_place, .full_deref = slot.full_deref_alias }, expr.span, state);
                return;
            }
            // `defer free(arr[0])`: reserve a tracked constant-index element place for
            // lexical cleanup, matching field-place defer behavior.
            if (moveIndexedPlaceKey(self, expr, state, aliases)) |pp| {
                if (deferredBorrowConflictsWithTrackedPlace(pp.place, state)) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "defer cannot consume a linear `move` array element already borrowed by a deferred expression");
                } else if (stateHasActivePlaceOrConflict(pp.place, state)) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "defer reserves a linear `move` array element already moved out");
                } else {
                    recordOwnershipMovePlace(self, pp.key, pp.place, .{ .live = true, .span = expr.span, .place = pp.place, .deferred = true }, state);
                }
            } else if (wildcardMoveIndexedPlaceKey(self, expr, state, aliases)) |pp| {
                if (deferredBorrowConflictsWithTrackedPlace(pp.place, state)) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "defer cannot consume a linear `move` array element already borrowed by a deferred expression");
                } else if (stateHasActivePlaceOrConflict(pp.place, state)) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "defer reserves a linear `move` array element already moved out");
                } else {
                    recordOwnershipMovePlace(self, pp.key, pp.place, .{ .live = true, .span = expr.span, .place = pp.place, .deferred = true }, state);
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

    var linear = linearMoveCfg(self, .branch_join) orelse return;
    defer linear.deinit();

    var worklist = MoveStateCfgWorklist.init(self, &linear.cfg, linear.entry, state) orelse return;
    defer worklist.deinit();
    while (worklist.pop()) |block_id| {
        const block_state = worklist.statePtr(block_id) orelse continue;
        if (block_id == linear.entry) {
            worklist.propagateSuccessors(self, block_id, block_state);
        } else if (block_id == linear.body) {
            for (block.items) |stmt| moveDeferStmt(self, stmt, block_state, &before, aliases);
            reportMoveLocalsLeavingScope(self, block_state, &before, "linear `move` value declared in this deferred cleanup block is never consumed before cleanup ends");
            worklist.propagateSuccessors(self, block_id, block_state);
        } else if (block_id == linear.exit) {
            replaceMoveState(self, state, block_state);
        }
    }
    preserveOuterScopedMoveState(self, state, &before);
}

fn cleanupLocalAliasReferent(self: *Checker, init: ast.Expr, state: *const std.StringHashMap(MoveSlot), outer: *const std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) ?AliasReferent {
    switch (init.kind) {
        .grouped => |inner| return cleanupLocalAliasReferent(self, inner.*, state, outer, aliases),
        else => {},
    }
    const referent = aliasReferentForExpr(self, init, state, aliases) orelse return null;
    const place = typedAliasReferentPlace(referent) orelse return null;
    if (aliasReferentTargetsOuter(referent, outer)) return null;
    if (rootMoveSlotForPlace(place, state) == null) return null;
    return .{ .key = referent.key, .place = place, .full_deref = referent.full_deref };
}

fn recordDeferredIdentAssignmentAlias(self: *Checker, name: ast.Ident, value: ast.Expr, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) void {
    if (aliasReferentForExpr(self, value, state, aliases)) |referent| {
        if (trackedAliasReferent(referent, state)) |tracked_referent| {
            if (state.getPtr(name.text)) |slot| {
                slot.alias_of = tracked_referent.key;
                slot.alias_place = tracked_referent.place;
                slot.live = false;
                slot.full_deref_alias = tracked_referent.full_deref;
            } else {
                state.put(name.text, .{ .live = false, .span = name.span, .place = .{ .root = name.text }, .alias_of = tracked_referent.key, .alias_place = tracked_referent.place, .cleanup_local = true, .full_deref_alias = tracked_referent.full_deref }) catch {
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
        .if_let => |n| moveDeferIfLetCfg(self, n, state, aliases),
        .@"switch" => |sw| moveDeferSwitchCfg(self, sw, state, aliases),
        .loop => |l| moveDeferLoopCfg(self, l, state, aliases),
        else => {},
    }
}

fn moveDeferLoopCfg(self: *Checker, loop: ast.Loop, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) void {
    // Deferred cleanup loops still have zero-or-many iteration semantics. Analyze
    // their source condition/body once, then let the same loop-head worklist used
    // by ordinary loops merge the zero-iteration and backedge states. `break` and
    // `continue` in a defer remain a semantic E_DEFER_CONTROL_FLOW boundary, so
    // this CFG deliberately models only supported cleanup-loop fallthrough.
    var loop_cfg = loopBodyMoveCfg(self) orelse return;
    defer loop_cfg.deinit();

    var worklist = MoveStateCfgWorklist.init(self, &loop_cfg.cfg, loop_cfg.entry, state) orelse return;
    defer worklist.deinit();
    worklist.suppressJoinDiagnostics();
    var condition_visited = false;
    var body_visited = false;
    while (worklist.pop()) |block| {
        const block_state = worklist.statePtr(block) orelse continue;
        if (block == loop_cfg.entry) {
            worklist.propagateSuccessors(self, block, block_state);
        } else if (block == loop_cfg.loop_head) {
            if (!condition_visited) {
                condition_visited = true;
                if (loop.iterable) |iter| moveDefer(self, iter, block_state, aliases);
            }
            worklist.propagateSuccessorsExcept(self, block, block_state, if (body_visited) loop_cfg.body else null);
        } else if (block == loop_cfg.body) {
            body_visited = true;
            moveDeferBlock(self, loop.body, block_state, aliases);
            worklist.propagateSuccessors(self, block, block_state);
        }
    }
    if (worklist.statePtr(loop_cfg.exit)) |exit_state| {
        var entry_state = cloneMoveState(self, state);
        defer entry_state.deinit();
        reportLoopOuterResourceChanges(self, &entry_state, exit_state);
        // The loop widener is the authority for outer resources changed by a
        // deferred cleanup loop. Keep its conservative result for later source
        // statements; otherwise a borrow reserved on a zero-or-many iteration
        // path is forgotten as soon as this helper returns.
        replaceMoveState(self, state, &entry_state);
    }
}

fn moveDeferSwitchCfg(self: *Checker, node: ast.Switch, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) void {
    if (node.arms.len == 0) {
        moveDefer(self, node.subject, state, aliases);
        return;
    }
    var branch = multiArmMoveCfg(self, node.arms.len) orelse return;
    defer branch.deinit();

    var worklist = MoveStateCfgWorklist.init(self, &branch.cfg, branch.entry, state) orelse return;
    defer worklist.deinit();
    while (worklist.pop()) |block| {
        const block_state = worklist.statePtr(block) orelse continue;
        if (block == branch.entry) {
            moveDefer(self, node.subject, block_state, aliases);
            worklist.propagateSuccessors(self, block, block_state);
        } else if (block == branch.join) {
            replaceMoveState(self, state, block_state);
        } else {
            var arm_index: ?usize = null;
            for (branch.arms, 0..) |arm_block, i| {
                if (arm_block == block) {
                    arm_index = i;
                    break;
                }
            }
            const index = arm_index orelse continue;
            switch (node.arms[index].body) {
                .block => |b| moveDeferBlock(self, b, block_state, aliases),
                .expr => |expr| moveDefer(self, expr, block_state, aliases),
            }
            worklist.propagateSuccessors(self, block, block_state);
        }
    }
}

fn moveDeferIfLetCfg(self: *Checker, node: ast.IfLet, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) void {
    var branch = twoArmMoveCfg(self) orelse return;
    defer branch.deinit();

    var worklist = MoveStateCfgWorklist.init(self, &branch.cfg, branch.entry, state) orelse return;
    defer worklist.deinit();
    while (worklist.pop()) |block| {
        const block_state = worklist.statePtr(block) orelse continue;
        if (block == branch.entry) {
            moveDefer(self, node.value, block_state, aliases);
            worklist.propagateSuccessors(self, block, block_state);
        } else if (block == branch.then_block) {
            moveDeferBlock(self, node.then_block, block_state, aliases);
            worklist.propagateSuccessors(self, block, block_state);
        } else if (block == branch.else_block) {
            if (node.else_block) |else_block| moveDeferBlock(self, else_block, block_state, aliases);
            worklist.propagateSuccessors(self, block, block_state);
        } else if (block == branch.join) {
            replaceMoveState(self, state, block_state);
        }
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
        } else if (retainsAliasPlaceType(ty)) {
            state.put(decl.names[0].text, .{ .live = false, .span = decl.names[0].span, .place = .{ .root = decl.names[0].text }, .ty = ty, .type_only = true, .cleanup_local = true }) catch {
                self.oom = true;
            };
        }
    }
    if (decl.init) |init| {
        if (aliasReferentForExpr(self, init, state, aliases)) |referent| {
            if (trackedAliasReferent(referent, state)) |tracked_referent| {
                state.put(decl.names[0].text, .{ .live = false, .span = decl.names[0].span, .place = .{ .root = decl.names[0].text }, .alias_of = tracked_referent.key, .alias_place = tracked_referent.place, .cleanup_local = true, .full_deref_alias = tracked_referent.full_deref }) catch {
                    self.oom = true;
                };
            }
        } else if (init.kind == .struct_literal) {
            recordTypeOnlyPlaceRoot(self, decl.names[0], binding_ty, state, true);
            registerAggregateFieldAliases(self, decl.names[0].text, .{ .root = decl.names[0].text }, decl.names[0].span, init, state, aliases);
        } else if (init.kind == .array_literal) {
            recordTypeOnlyPlaceRoot(self, decl.names[0], binding_ty, state, true);
            registerArrayElementAliases(self, decl.names[0].text, .{ .root = decl.names[0].text }, decl.names[0].span, init, state, aliases);
        }
        markBorrowEscapeCapturedCallResult(self, init, decl.names[0].span, state, aliases);
    }
}

fn recordTypeOnlyPlaceRoot(self: *Checker, name: ast.Ident, maybe_ty: ?ast.TypeExpr, state: *std.StringHashMap(MoveSlot), cleanup_local: bool) void {
    const ty = maybe_ty orelse return;
    if (state.get(name.text)) |slot| {
        if (slot.alias_of != null or isPureIndexFactSlot(slot) or (slot.live and !slot.type_only)) return;
    }
    state.put(name.text, .{ .live = false, .span = name.span, .place = .{ .root = name.text }, .ty = ty, .type_only = true, .cleanup_local = cleanup_local }) catch {
        self.oom = true;
    };
}
