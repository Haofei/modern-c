//! Verification and lookup helpers for the executable body owned by MIR.
//!
//! `mir_model.ExecutableBody` is the only executable-body representation.
//! This module never reconstructs a second body from sparse instructions,
//! source coordinates, or textual instruction details.

const std = @import("std");
const mir = @import("mir_model.zig");
const scalar_repr = @import("scalar_repr.zig");

pub fn isComplete(function: *const mir.Function) bool {
    verify(function) catch return false;
    return function.executable_body.isComplete();
}

/// Coarse, stable reason for an incomplete canonical body.  This is migration
/// telemetry only: admission still depends on `verify` + `complete`.  Keeping
/// the classifier beside the canonical model lets the broad census rank the
/// producer gaps without teaching either backend about source syntax.
pub fn incompleteReason(function: *const mir.Function) []const u8 {
    const body = &function.executable_body;
    if (body.complete) return "complete";
    if (body.expressions.len == 0 and body.statements.len == 0 and body.terminators.len == 0) return "empty_body";
    // A producer-owned reason identifies the first operation that failed to
    // canonicalize. Prefer it over scanning otherwise valid operations: a
    // supported member/range/array may precede the actual unsupported node.
    if (body.incomplete_reason != .none) return @tagName(body.incomplete_reason);
    for (body.expressions) |expression_value| switch (expression_value.operation) {
        .unsupported => return "unsupported_expression",
        .deref => return "unlowered_deref",
        .range_slice => return "unlowered_range_slice",
        .member => return "unlowered_member",
        .array => return "unlowered_array",
        .literal => |literal| switch (literal) {
            .uninit => return "noncanonical_uninit_literal",
            .enum_value => return "noncanonical_enum_literal",
            else => {},
        },
        else => {},
    };
    for (body.statements) |statement_value| switch (statement_value.operation) {
        .unsupported => return "unsupported_statement",
        .defer_register, .cleanup_run => {},
        .guard => |guard| if (guard.kind == .assert_ and
            !assertGuardHasExactTrapEdge(body, statement_value, guard)) return "assert_guard",
        else => {},
    };
    for (body.places) |place_value| {
        if (place_value.storage == .atomic) {
            if (!atomicPlaceSupported(body, place_value)) return "incomplete_atomic_place";
        } else if (place_value.projection_count != 0 and !isScalarAccessPlace(body, place_value, false) and
            !mir.executableGuardedLocalAggregateDerefPlace(body, place_value, false) and
            !mir.executableParameterProjectedPlace(body, place_value, false) and
            mir.executableFixedArrayIndexPlace(body, place_value) == null and
            mir.executableSliceIndexPlace(body, place_value) == null) return "incomplete_place";
    }
    for (body.terminators) |terminator| switch (terminator.operation) {
        .switch_ => return "general_switch",
        .fallthrough => return "invalid_fallthrough",
        else => {},
    };
    // When every operation has a canonical shape but the producer declined to
    // mark the body complete, ask the verifier which invariant would fail if it
    // did. This keeps migration telemetry actionable without duplicating the
    // verifier's rules in the producer or either backend.
    var claimed_function = function.*;
    claimed_function.executable_body = body.*;
    claimed_function.executable_body.complete = true;
    claimed_function.executable_body.incomplete_reason = .none;
    verify(&claimed_function) catch |err| return @errorName(err);
    return "producer_invariant";
}

pub fn expression(body: *const mir.ExecutableBody, id: mir.ExprId) ?*const mir.ExecutableExpression {
    if (!id.isValid() or id.index() >= body.expressions.len) return null;
    const value = &body.expressions[id.index()];
    return if (value.id.eql(id)) value else null;
}

pub fn statement(body: *const mir.ExecutableBody, id: mir.InstId) ?*const mir.ExecutableStatement {
    if (!id.isValid() or id.index() >= body.statements.len) return null;
    const value = &body.statements[id.index()];
    return if (value.id.eql(id)) value else null;
}

pub fn place(body: *const mir.ExecutableBody, id: mir.PlaceId) ?*const mir.ExecutablePlace {
    if (!id.isValid() or id.index() >= body.places.len) return null;
    const value = &body.places[id.index()];
    return if (value.id.eql(id)) value else null;
}

pub fn local(body: *const mir.ExecutableBody, id: mir.LocalId) ?mir.ExecutableLocalIdentity {
    if (!id.isValid() or id.index() >= body.locals.len) return null;
    const value = body.locals[id.index()];
    return if (value.id.eql(id)) value else null;
}

pub fn symbol(body: *const mir.ExecutableBody, id: mir.SymbolId) ?mir.SymbolIdentity {
    if (!id.isValid() or id.index() >= body.symbols.len) return null;
    const value = body.symbols[id.index()];
    return if (value.id.eql(id)) value else null;
}

/// Transitional admission guard for backends whose canonical renderer still
/// materializes every declared local. The specialized path already removes
/// locals that are only initialized or assigned and never read; keep those
/// bodies there until executable-MIR owns a shared dead-local elimination pass.
pub fn verify(function: *const mir.Function) !void {
    const body = &function.executable_body;
    if (function.param_types.len != function.param_count) return error.InvalidFunctionSignature;
    if (!function.is_extern) {
        if (body.parameters.len != function.param_count or body.is_variadic != function.is_variadic)
            return error.InvalidFunctionSignature;
        if (body.is_variadic) {
            if (body.parameters.len == 0 or
                !body.last_named_parameter.eql(body.parameters[body.parameters.len - 1].local))
                return error.InvalidFunctionSignature;
        } else if (body.last_named_parameter.isValid()) return error.InvalidFunctionSignature;
    }
    if (body.parameters.len == function.param_types.len) {
        for (body.parameters, function.param_types) |parameter, parameter_ty| {
            if (!sameValueType(parameter.ty, parameter_ty)) return error.InvalidFunctionSignature;
        }
    }
    if (body.complete and body.incomplete_reason != .none) return error.InvalidIncompleteReason;
    if (!body.complete and body.parameters.len == 0 and body.locals.len == 0 and body.symbols.len == 0 and
        body.aggregate_types.len == 0 and body.enum_types.len == 0 and body.result_types.len == 0 and body.tagged_union_types.len == 0 and
        body.expressions.len == 0 and body.places.len == 0 and body.statements.len == 0 and body.terminators.len == 0) return;

    try verifyType(function, body.return_type_id, function.return_ty, body.complete);
    if (body.return_dyn_trait_symbol_id.isValid()) {
        if (function.return_ty != .value or function.return_callable_signature != null) return error.InvalidFunctionSignature;
        const trait = symbol(body, body.return_dyn_trait_symbol_id) orelse return error.InvalidSymbolReference;
        if (body.complete and trait.kind != .trait) return error.InvalidCalleeSymbol;
    }
    if (function.return_callable_signature) |signature| {
        if (function.return_ty != .value) return error.InvalidFunctionSignature;
        try verifyCallableSignature(function, signature, body.complete);
    }
    for (body.aggregate_types, 0..) |aggregate, index| {
        try verifyAggregateType(function, aggregate, index);
    }
    for (body.enum_types, 0..) |enum_ty, index| {
        try verifyEnumType(function, enum_ty, index);
    }
    for (body.result_types, 0..) |result_ty, index| {
        try verifyResultType(function, result_ty, index);
    }
    for (body.tagged_union_types, 0..) |tagged_union_ty, index| {
        try verifyTaggedUnionType(function, tagged_union_ty, index);
    }
    for (body.locals, 0..) |identity, index| {
        if (!identity.id.isValid() or identity.id.index() != index) return error.InvalidLocalIdentity;
        if (identity.is_va_list and identity.dyn_trait_symbol_id.isValid()) return error.InvalidLocalIdentity;
        if (identity.dyn_trait_symbol_id.isValid()) {
            const trait = symbol(body, identity.dyn_trait_symbol_id) orelse return error.InvalidSymbolReference;
            if (body.complete and trait.kind != .trait) return error.InvalidCalleeSymbol;
        }
    }
    for (body.symbols, 0..) |identity, index| {
        if (!identity.id.isValid() or identity.id.index() != index) return error.InvalidSymbolIdentity;
        if (identity.callable_signature) |signature| {
            if (identity.kind != .function) return error.InvalidSymbolIdentity;
            try verifyCallableSignature(function, signature, body.complete);
        }
        if (identity.return_dyn_trait_symbol_id.isValid()) {
            if (identity.kind != .function or identity.callable_signature != null) return error.InvalidSymbolIdentity;
            const trait = symbol(body, identity.return_dyn_trait_symbol_id) orelse return error.InvalidSymbolReference;
            if (body.complete and trait.kind != .trait) return error.InvalidCalleeSymbol;
        }
    }
    for (body.parameters) |parameter| {
        try verifyLocal(body, parameter.local);
        try verifySpan(function, parameter.span_id, parameter.source);
        try verifyType(function, parameter.type_id, parameter.ty, body.complete);
        if (parameter.callable_signature) |signature| {
            if (parameter.ty != .value or parameter.dyn_trait_symbol_id.isValid() or parameter.atomic_payload_type_id.isValid()) return error.InvalidFunctionSignature;
            try verifyCallableSignature(function, signature, body.complete);
        } else if (parameter.dyn_trait_symbol_id.isValid()) {
            if (parameter.ty != .value or parameter.atomic_payload_type_id.isValid()) return error.InvalidFunctionSignature;
            const trait = symbol(body, parameter.dyn_trait_symbol_id) orelse return error.InvalidSymbolReference;
            if (body.complete and trait.kind != .trait) return error.InvalidCalleeSymbol;
        } else if (parameter.atomic_payload_type_id.isValid()) {
            const atomic_container = parameter.ty == .value or switch (parameter.ty) {
                .pointer => |shape| shape.kind == .single,
                else => false,
            };
            if (!atomic_container or parameter.atomic_payload_ty == .unknown or parameter.atomic_payload_ty == .value)
                return error.InvalidFunctionSignature;
            try verifyType(function, parameter.atomic_payload_type_id, parameter.atomic_payload_ty, body.complete);
        } else if (body.complete and parameter.ty == .value) return error.InvalidFunctionSignature;
    }

    for (body.expressions, 0..) |value, index| {
        if (!value.id.isValid() or value.id.index() != index) return error.InvalidExpressionIdentity;
        if (!blockExists(function, value.block_id)) return error.InvalidBlockReference;
        if (!value.owner_statement.isValid() or value.owner_statement.index() >= body.statements.len) return error.InvalidStatementReference;
        const owner = body.statements[value.owner_statement.index()];
        if (!owner.id.eql(value.owner_statement) or !owner.block_id.eql(value.block_id)) return error.InvalidStatementReference;
        try verifySpan(function, value.span_id, value.source);
        try verifyType(function, value.type_id, value.result_ty, body.complete);
        try verifyExpression(function, value);
    }
    for (body.cleanup_actions, 0..) |action, index| {
        if (!action.id.isValid() or action.id.index() != index or
            !action.registration.isValid() or action.registration.index() >= body.statements.len or
            !blockExists(function, action.block_id)) return error.InvalidCleanupActionIdentity;
        try verifySpan(function, action.span_id, action.source);
        const registration = body.statements[action.registration.index()];
        if (!registration.id.eql(action.registration) or !registration.block_id.eql(action.block_id))
            return error.InvalidCleanupRegistration;
        switch (registration.operation) {
            .defer_register => |id| if (!id.eql(action.id)) return error.InvalidCleanupRegistration,
            else => return error.InvalidCleanupRegistration,
        }
        if (body.complete and action.roots.len == 0) return error.InvalidCleanupExpression;
        for (action.roots) |root| {
            const value = expression(body, root) orelse return error.InvalidExpressionReference;
            if (!value.owner_statement.eql(action.registration) or !value.block_id.eql(action.block_id))
                return error.InvalidCleanupExpression;
            if (body.complete and (value.result_ty != .void or value.operation != .direct_call))
                return error.InvalidCleanupExpression;
        }
    }
    try verifyTrapEdges(function);

    for (body.places, 0..) |value, index| {
        if (!value.id.isValid() or value.id.index() != index or value.projection_count > mir.max_executable_projections) return error.InvalidPlaceIdentity;
        try verifySpan(function, value.span_id, value.source);
        try verifyType(function, value.root_type_id, value.root_ty, body.complete);
        try verifyType(function, value.type_id, value.ty, body.complete);
        switch (value.root) {
            .local => |id| try verifyLocal(body, id),
            .symbol => |id| try verifySymbol(body, id),
            .value => |id| try verifyExpr(body, id),
        }
        for (value.projections[0..value.projection_count]) |projection| switch (projection) {
            .index => |projection_index| {
                try verifyExpr(body, projection_index.value);
                try verifySpanId(function, projection_index.span_id);
            },
            .field, .deref => {},
        };
        if (body.complete) try verifyCompletePlace(body, value);
    }

    for (body.statements, 0..) |statement_value, index| {
        if (!statement_value.id.isValid() or statement_value.id.index() != index or !blockExists(function, statement_value.block_id)) return error.InvalidStatementIdentity;
        try verifySpan(function, statement_value.span_id, statement_value.source);
        try verifyStatement(function, statement_value);
    }

    if (body.terminators.len != function.blocks.len) return error.InvalidTerminatorIdentity;
    for (body.terminators, 0..) |terminator, index| {
        if (!terminator.block_id.eql(function.blocks[index].typed_id)) return error.InvalidTerminatorIdentity;
        try verifyTerminator(function, terminator);
    }

    if (body.complete) try verifyExecutableCleanupCfg(function);

    if (body.complete and containsIncompleteOperation(body)) return error.InvalidCompletionClaim;
}

fn cleanupAction(body: *const mir.ExecutableBody, id: mir.CleanupActionId) ?mir.ExecutableCleanupAction {
    if (!id.isValid() or id.index() >= body.cleanup_actions.len) return null;
    const action = body.cleanup_actions[id.index()];
    return if (action.id.eql(id)) action else null;
}

fn cleanupListPops(stack: []mir.CleanupActionId, depth: *usize, actions: []const mir.CleanupActionId) bool {
    if (actions.len > depth.*) return false;
    for (actions, 0..) |action, index| {
        if (!stack[depth.* - 1 - index].eql(action)) return false;
    }
    depth.* -= actions.len;
    return true;
}

fn cleanupStackEql(left: []const mir.CleanupActionId, right: []const mir.CleanupActionId) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (!a.eql(b)) return false;
    return true;
}

fn terminatorByBlock(body: *const mir.ExecutableBody, id: mir.BlockId) ?*const mir.ExecutableTerminator {
    if (!id.isValid() or id.index() >= body.terminators.len) return null;
    const terminator = &body.terminators[id.index()];
    return if (terminator.block_id.eql(id)) terminator else null;
}

fn verifyCleanupSuccessor(body: *const mir.ExecutableBody, target: mir.BlockId, stack: []const mir.CleanupActionId) !void {
    const successor = terminatorByBlock(body, target) orelse return error.InvalidBlockReference;
    if (!cleanupStackEql(stack, successor.entry_cleanup_stack)) return error.InvalidCleanupSuccessorState;
}

fn verifyExecutableCleanupCfg(function: *const mir.Function) !void {
    const body = &function.executable_body;
    if (body.terminators.len == 0) return;
    if (body.terminators[0].entry_cleanup_stack.len != 0) return error.InvalidCleanupSuccessorState;
    const stack = try std.heap.page_allocator.alloc(mir.CleanupActionId, body.cleanup_actions.len);
    defer std.heap.page_allocator.free(stack);
    for (body.terminators) |terminator| {
        var depth = terminator.entry_cleanup_stack.len;
        if (depth > stack.len) return error.InvalidCleanupOrder;
        @memcpy(stack[0..depth], terminator.entry_cleanup_stack);
        for (body.statements) |statement_value| {
            if (!statement_value.block_id.eql(terminator.block_id)) continue;
            for (body.expressions) |value| {
                if (!value.owner_statement.eql(statement_value.id)) continue;
                const actions = switch (value.operation) {
                    .try_propagate => |operation| operation.error_cleanup_actions,
                    .try_map_error => |operation| operation.error_cleanup_actions,
                    else => continue,
                };
                var failure_depth = depth;
                if (!cleanupListPops(stack, &failure_depth, actions) or failure_depth != 0)
                    return error.InvalidCleanupOrder;
            }
            switch (statement_value.operation) {
                .defer_register => |id| {
                    const action = cleanupAction(body, id) orelse return error.InvalidCleanupActionIdentity;
                    if (!action.registration.eql(statement_value.id) or depth >= stack.len)
                        return error.InvalidCleanupRegistration;
                    stack[depth] = id;
                    depth += 1;
                },
                .cleanup_run => |actions| if (!cleanupListPops(stack, &depth, actions))
                    return error.InvalidCleanupOrder,
                else => {},
            }
        }
        if (!cleanupListPops(stack, &depth, terminator.exit_cleanup_actions)) return error.InvalidCleanupOrder;
        const remaining = stack[0..depth];
        switch (terminator.operation) {
            .return_ => if (depth != 0) return error.InvalidCleanupOrder,
            .jump => |target| try verifyCleanupSuccessor(body, target, remaining),
            .branch => |branch| {
                try verifyCleanupSuccessor(body, branch.true_block, remaining);
                try verifyCleanupSuccessor(body, branch.false_block, remaining);
            },
            .for_each => |loop| {
                try verifyCleanupSuccessor(body, loop.body_block, remaining);
                try verifyCleanupSuccessor(body, loop.after_block, remaining);
            },
            .for_step => |step| try verifyCleanupSuccessor(body, step.header_block, remaining),
            .switch_ => |switch_| {
                try verifyCleanupSuccessor(body, switch_.default_block, remaining);
                for (switch_.cases[0..switch_.case_count]) |case| try verifyCleanupSuccessor(body, case.target, remaining);
            },
            .trap_, .unreachable_ => {},
            .fallthrough => return error.InvalidBlockReference,
        }
    }
}

fn verifyExpression(function: *const mir.Function, value: mir.ExecutableExpression) !void {
    const body = &function.executable_body;
    switch (value.operation) {
        .local => |id| try verifyLocal(body, id),
        .symbol => |id| try verifySymbol(body, id),
        .load => |operation| {
            const target = place(body, operation.place) orelse return error.InvalidPlaceReference;
            if (target.storage != .ordinary) return error.InvalidMemoryAccessType;
            if (target.root == .value) try verifyOperand(body, value, target.root.value);
            if (body.complete) {
                try verifyMemoryAccess(function, operation.place, value.result_ty, operation.access, false);
                if (mir.executableFixedArrayIndexPlace(body, target.*) != null) {
                    const indexed = mir.executableFixedArrayIndexPlace(body, target.*).?;
                    const representation_count: usize = @intFromBool(indexed.parameter_pointee);
                    if (indexed.parameter_pointee) {
                        const source = operation.representation_source orelse return error.InvalidMemoryAccessTrap;
                        try verifySpan(function, operation.representation_span_id, source);
                        if (ownedTrapCount(body, .{ .expression = value.id }, .InvalidRepresentation, .representation_check) != 1)
                            return error.InvalidMemoryAccessTrap;
                    } else if (operation.representation_source != null or operation.representation_span_id.isValid()) {
                        return error.InvalidMemoryAccessTrap;
                    }
                    if (!indexedBoundsEdgesExact(body, .{ .expression = value.id }, value.block_id, target.*, representation_count))
                        return error.InvalidMemoryAccessTrap;
                    return;
                }
                const expected_traps: usize = if (placeNeedsRepresentationGuard(body, target.*)) 1 else 0;
                if (expected_traps == 1) {
                    const source = operation.representation_source orelse return error.InvalidMemoryAccessTrap;
                    try verifySpan(function, operation.representation_span_id, source);
                } else if (operation.representation_source != null or operation.representation_span_id.isValid()) {
                    return error.InvalidMemoryAccessTrap;
                }
                if (ownedTrapCountAll(body, .{ .expression = value.id }) != expected_traps or
                    (expected_traps == 1 and ownedTrapCount(body, .{ .expression = value.id }, .InvalidRepresentation, .representation_check) != 1))
                    return error.InvalidMemoryAccessTrap;
            } else if (place(body, operation.place) == null) return error.InvalidPlaceReference;
        },
        .atomic_load => |operation| {
            const target = place(body, operation.place) orelse return error.InvalidPlaceReference;
            if (target.root == .value) try verifyOperand(body, value, target.root.value);
            if (body.complete) {
                if (!operation.ordering.validForLoad() or !atomicPlaceSupported(body, target.*) or
                    !sameValueType(target.ty, value.result_ty) or !target.type_id.eql(value.type_id))
                    return error.InvalidAtomicLoad;
                const guarded = placeNeedsRepresentationGuard(body, target.*);
                if (guarded) {
                    const source = operation.representation_source orelse return error.InvalidAtomicLoad;
                    try verifySpan(function, operation.representation_span_id, source);
                    if (ownedTrapCountAll(body, .{ .expression = value.id }) != 1 or
                        ownedTrapCount(body, .{ .expression = value.id }, .InvalidRepresentation, .representation_check) != 1)
                        return error.InvalidAtomicLoad;
                } else if (operation.representation_source != null or operation.representation_span_id.isValid() or
                    ownedTrapCountAll(body, .{ .expression = value.id }) != 0)
                {
                    return error.InvalidAtomicLoad;
                }
            }
        },
        .atomic_init => |operand_id| {
            try verifyOperand(body, value, operand_id);
            const operand = expression(body, operand_id) orelse return error.InvalidExpressionReference;
            if (body.complete and (!atomicPayloadSupported(value.result_ty) or
                !sameValueType(operand.result_ty, value.result_ty) or !operand.type_id.eql(value.type_id) or
                ownedTrapCountAll(body, .{ .expression = value.id }) != 0)) return error.InvalidAtomicLoad;
        },
        .atomic_update => |operation| {
            const target = place(body, operation.place) orelse return error.InvalidPlaceReference;
            if (target.root == .value) try verifyOperand(body, value, target.root.value);
            try verifyOperand(body, value, operation.value);
            if (body.complete) {
                const operand = expression(body, operation.value) orelse return error.InvalidExpressionReference;
                const ordering_valid = switch (operation.kind) {
                    .store => operation.ordering.validForStore(),
                    .fetch_add, .fetch_sub => operation.ordering.validForRmw(),
                };
                if (!ordering_valid or !atomicPlaceSupported(body, target.*) or
                    !sameValueType(target.ty, operand.result_ty) or !target.type_id.eql(operand.type_id) or
                    (operation.kind == .store and value.result_ty != .void) or
                    (operation.kind != .store and (!sameValueType(target.ty, value.result_ty) or !target.type_id.eql(value.type_id))))
                    return error.InvalidAtomicLoad;
                const guarded = placeNeedsRepresentationGuard(body, target.*);
                if (guarded) {
                    const source = operation.representation_source orelse return error.InvalidAtomicLoad;
                    try verifySpan(function, operation.representation_span_id, source);
                    if (ownedTrapCountAll(body, .{ .expression = value.id }) != 1 or
                        ownedTrapCount(body, .{ .expression = value.id }, .InvalidRepresentation, .representation_check) != 1)
                        return error.InvalidAtomicLoad;
                } else if (operation.representation_source != null or operation.representation_span_id.isValid() or
                    ownedTrapCountAll(body, .{ .expression = value.id }) != 0)
                {
                    return error.InvalidAtomicLoad;
                }
            }
        },
        .mmio_read => |operation| {
            try verifyLocal(body, operation.base);
            try verifyType(function, operation.storage_type_id, operation.storage_ty, body.complete);
            if (body.complete and (!operation.ordering.validForRead() or
                !mmioBaseSupported(body, operation.base) or
                !mmioStorageSupported(operation.storage_ty) or
                !mmioReadResultSupported(body, value, operation.storage_ty, operation.storage_type_id) or
                ownedTrapCountAll(body, .{ .expression = value.id }) != 0))
                return error.InvalidMmioAccess;
        },
        .mmio_write => |operation| {
            try verifyLocal(body, operation.base);
            try verifyOperand(body, value, operation.value);
            try verifyType(function, operation.storage_type_id, operation.storage_ty, body.complete);
            const operand = expression(body, operation.value) orelse return error.InvalidExpressionReference;
            if (body.complete and (!operation.ordering.validForWrite() or
                !mmioBaseSupported(body, operation.base) or
                !mmioStorageSupported(operation.storage_ty) or
                value.result_ty != .void or
                !sameValueType(operand.result_ty, operation.storage_ty) or
                !operand.type_id.eql(operation.storage_type_id) or
                ownedTrapCountAll(body, .{ .expression = value.id }) != 0))
                return error.InvalidMmioAccess;
        },
        .mmio_map_checked => |operation| {
            try verifyOperand(body, value, operation.address);
            const address = expression(body, operation.address) orelse return error.InvalidExpressionReference;
            if (body.complete and (!operation.unsafe_authorized or
                !sameValueType(address.result_ty, .{ .address = .paddr }) or
                !sameValueType(value.result_ty, .{ .address = .mmio_ptr }) or
                ownedTrapCountAll(body, .{ .expression = value.id }) != 1 or
                ownedTrapCount(body, .{ .expression = value.id }, .Unwrap, .unwrap) != 1))
                return error.InvalidBuiltinCall;
        },
        .literal => |literal| switch (literal) {
            .float => |float| if (!mir.executableFloatMatchesType(float, value.result_ty)) return error.InvalidLiteral,
            .signed_integer => switch (value.result_ty) {
                .closed_enum, .open_enum, .integer => {},
                else => return error.InvalidLiteral,
            },
            .string => if (!stringLiteralType(value.result_ty)) return error.InvalidLiteral,
            .uninit => if (body.complete and !mir.executableUninitLocalInitializer(body, value) and
                !mir.executableUninitAggregateOperand(body, value)) return error.InvalidLiteral,
            else => {},
        },
        .unsupported => {},
        .unary => |operation| {
            try verifyOperand(body, value, operation.operand);
            if (body.complete) {
                const operand = expression(body, operation.operand) orelse return error.InvalidExpressionReference;
                if (!sameValueType(value.result_ty, operand.result_ty)) return error.InvalidUnaryOperation;
                if (mir.executableCheckedUnaryTrapRequirements(operation.op, value.result_ty)) |requirements| {
                    if (ownedTrapCountAll(body, .{ .expression = value.id }) != requirements.count)
                        return error.InvalidUnaryOperation;
                    for (requirements.items[0..requirements.count]) |requirement| {
                        if (ownedTrapCount(body, .{ .expression = value.id }, requirement.kind, requirement.source) != 1)
                            return error.InvalidUnaryOperation;
                    }
                } else if (ownedTrapCountAll(body, .{ .expression = value.id }) != 0) {
                    return error.InvalidUnaryOperation;
                }
            }
        },
        .binary => |operation| {
            try verifyOperand(body, value, operation.left);
            try verifyOperand(body, value, operation.right);
            const left = expression(body, operation.left) orelse return error.InvalidExpressionReference;
            const right = expression(body, operation.right) orelse return error.InvalidExpressionReference;
            // Incomplete bodies are descriptive migration data and may still
            // contain source-shaped operations that a legacy lowering path
            // owns.  Exact executable arithmetic invariants become mandatory
            // only when the producer claims this body is complete.
            if (body.complete) {
                if (operation.arithmetic != .unchecked and operation.contract_region_id != null)
                    return error.InvalidUncheckedArithmetic;
                const logical = operation.op == .logical_and or operation.op == .logical_or;
                if (logical) {
                    if (value.result_ty != .bool or left.result_ty != .bool or right.result_ty != .bool or
                        (operation.eager_safe and
                            (!mir.executableEagerSafeBoolTree(body.expressions, body.trap_edges, left.id) or
                                !mir.executableEagerSafeBoolTree(body.expressions, body.trap_edges, right.id))) or
                        ownedTrapCountAll(body, .{ .expression = value.id }) != 0)
                        return error.InvalidLogicalOperation;
                } else if (operation.eager_safe) {
                    return error.InvalidLogicalOperation;
                }
            }
            if (body.complete) switch (operation.arithmetic) {
                .checked => {
                    if (!sameValueType(value.result_ty, left.result_ty) or !sameValueType(left.result_ty, right.result_ty) or
                        std.meta.activeTag(value.result_ty) != .integer) return error.InvalidCheckedArithmetic;
                    const requirements = mir.executableCheckedBinaryTrapRequirements(operation.op, value.result_ty) orelse return error.InvalidCheckedArithmetic;
                    if (ownedTrapCountAll(body, .{ .expression = value.id }) != requirements.count) return error.InvalidCheckedArithmetic;
                    for (requirements.items[0..requirements.count]) |requirement| {
                        if (ownedTrapCount(body, .{ .expression = value.id }, requirement.kind, requirement.source) != 1) return error.InvalidCheckedArithmetic;
                    }
                },
                .wrapping, .saturating => {
                    if (!sameValueType(value.result_ty, left.result_ty) or !sameValueType(left.result_ty, right.result_ty) or
                        ownedTrapCountAll(body, .{ .expression = value.id }) != 0) return error.InvalidDomainArithmetic;
                    const shape = switch (value.result_ty) {
                        .domain_integer => |domain| domain,
                        else => return error.InvalidDomainArithmetic,
                    };
                    if ((operation.arithmetic == .wrapping and shape.kind != .wrap) or
                        (operation.arithmetic == .saturating and shape.kind != .sat)) return error.InvalidDomainArithmetic;
                    const supported = switch (operation.arithmetic) {
                        .wrapping => switch (operation.op) {
                            .add, .sub, .mul, .bit_or, .bit_xor, .bit_and, .shl, .shr => true,
                            else => false,
                        },
                        .saturating => switch (operation.op) {
                            .add, .sub, .mul => true,
                            else => false,
                        },
                        else => unreachable,
                    };
                    if (!supported) return error.InvalidDomainArithmetic;
                },
                .unchecked => {
                    if (!uncheckedBinaryHasExactProof(function, body, value, operation, left.*, right.*))
                        return error.InvalidUncheckedArithmetic;
                },
                .ordinary => if (left.result_ty == .domain_integer) {
                    const comparison = operation.op == .eq or operation.op == .ne or operation.op == .lt or
                        operation.op == .le or operation.op == .gt or operation.op == .ge;
                    if (!comparison or !sameValueType(left.result_ty, right.result_ty) or value.result_ty != .bool or
                        ownedTrapCountAll(body, .{ .expression = value.id }) != 0) return error.InvalidDomainArithmetic;
                } else if (right.result_ty == .domain_integer or value.result_ty == .domain_integer) {
                    return error.InvalidDomainArithmetic;
                },
            };
        },
        .cast => |operation| {
            try verifyOperand(body, value, operation.operand);
            const operand = expression(body, operation.operand) orelse return error.InvalidExpressionReference;
            const expected = mir.ExecutableCastKind.classify(operand.result_ty, value.result_ty) orelse return error.InvalidCast;
            if (operation.kind != expected) return error.InvalidCast;
            if (operation.kind == .integer_to_open_enum or operation.kind == .enum_to_integer) {
                var exact = false;
                for (body.enum_types) |enum_ty| {
                    const enum_value: *const mir.ExecutableExpression = if (operation.kind == .integer_to_open_enum) &value else operand;
                    if (!sameValueType(enum_ty.ty, enum_value.result_ty)) continue;
                    exact = enum_ty.type_id.eql(enum_value.type_id) and
                        mir.ExecutableCastKind.integerInfo(enum_ty.repr_ty) != null;
                    break;
                }
                if (!exact) return error.InvalidCast;
            }
        },
        .representation_check => |operation| {
            try verifyOperand(body, value, operation.operand);
            const operand = expression(body, operation.operand) orelse return error.InvalidExpressionReference;
            if (body.complete and
                (!mir.ExecutableRepresentationCheckKind.typesValid(operation.kind, value.result_ty, operand.result_ty) or
                    !value.type_id.eql(operand.type_id) or
                    (operation.kind == .valid_closed_enum and !closedEnumCheckMetadataValid(body, value)) or
                    ownedTrapCountAll(body, .{ .expression = value.id }) != 1 or
                    ownedTrapCount(body, .{ .expression = value.id }, .InvalidRepresentation, .representation_check) != 1))
                return error.InvalidMemoryAccessTrap;
        },
        .direct_call => |call| {
            try verifySymbol(body, call.callee);
            if (body.complete and body.symbols[call.callee.index()].kind != .function) return error.InvalidCalleeSymbol;
            try verifySpan(function, call.callee_span_id, call.callee_source);
            try verifyArguments(body, value, call.arguments, call.argument_count);
        },
        .closure_bind => |bind| {
            try verifyOperand(body, value, bind.capture);
            try verifySymbol(body, bind.target);
            try verifySymbol(body, bind.code);
            try verifyCallableSignature(function, bind.signature, body.complete);
            if (body.complete) {
                const target = symbol(body, bind.target) orelse return error.InvalidSymbolReference;
                const code = symbol(body, bind.code) orelse return error.InvalidSymbolReference;
                const capture = expression(body, bind.capture) orelse return error.InvalidExpressionReference;
                if (value.result_ty != .value or !bind.signature.has_environment or target.kind != .function or
                    code.kind != .function or !closureBindTargetSignatureValid(target, capture.*, bind.signature) or
                    !closureCaptureEncodingValid(capture.result_ty, bind.capture_encoding) or
                    (switch (bind.capture_encoding) {
                        .pointer => !bind.code.eql(bind.target),
                        .integer => bind.code.eql(bind.target) or code.callable_signature != null,
                    }) or
                    ownedTrapCountAll(body, .{ .expression = value.id }) != 0)
                    return error.InvalidFunctionSignature;
            }
        },
        .builtin_call => |call| {
            try verifySpan(function, call.callee_span_id, call.callee_source);
            if (mir.executableBuiltinRequiresUnsafe(call.kind) != call.unsafe_authorized) return error.InvalidUnsafeAuthorization;
            try verifyArguments(body, value, call.arguments, call.argument_count);
            var operand_types: [mir.max_executable_operands]mir.ValueType = undefined;
            for (call.arguments[0..call.argument_count], 0..) |argument, index| {
                operand_types[index] = (expression(body, argument) orelse return error.InvalidExpressionReference).result_ty;
            }
            if (body.complete) {
                if (!mir.executableBuiltinTypesValid(call.kind, value.result_ty, operand_types[0..call.argument_count])) return error.InvalidBuiltinCall;
                switch (call.kind) {
                    .va_start => {
                        if (call.vararg_cursor.isValid() or !body.is_variadic or
                            mir.executableVaStartLocal(body, value.id) == null)
                            return error.InvalidBuiltinCall;
                    },
                    .va_arg, .va_end => if (!mir.executableVaListLocal(body, call.vararg_cursor))
                        return error.InvalidBuiltinCall,
                    else => if (call.vararg_cursor.isValid()) return error.InvalidBuiltinCall,
                }
                if (call.kind == .const_get) {
                    const index = call.const_index orelse return error.InvalidBuiltinCall;
                    const array = switch (operand_types[0]) {
                        .array => |shape| shape,
                        else => return error.InvalidBuiltinCall,
                    };
                    if (array.length == null or index >= array.length.?) return error.InvalidBuiltinCall;
                } else if (call.const_index != null) {
                    return error.InvalidBuiltinCall;
                }
                if (call.kind == .raw_ptr) {
                    const source = call.representation_source orelse return error.InvalidMemoryAccessTrap;
                    try verifySpan(function, call.representation_span_id, source);
                    if (!sameSource(source, value.source) or !call.representation_span_id.eql(value.span_id))
                        return error.InvalidMemoryAccessTrap;
                    if (ownedTrapCountAll(body, .{ .expression = value.id }) != 1 or
                        ownedTrapCount(body, .{ .expression = value.id }, .InvalidRepresentation, .representation_check) != 1)
                        return error.InvalidMemoryAccessTrap;
                } else if (call.kind == .conversion_trap_from) {
                    if (call.representation_source != null or call.representation_span_id.isValid() or
                        !builtinTrapConversionHasExactEdge(body, value))
                        return error.InvalidBuiltinCall;
                } else if (call.representation_source != null or call.representation_span_id.isValid() or
                    ownedTrapCountAll(body, .{ .expression = value.id }) != 0)
                {
                    return error.InvalidMemoryAccessTrap;
                }
            }
        },
        .indirect_call => |call| {
            try verifyOperand(body, value, call.callee);
            try verifyArguments(body, value, call.arguments, call.argument_count);
            try verifyCallSignature(function, body, value, call);
        },
        .dyn_call => |call| {
            const receiver = place(body, call.receiver) orelse return error.InvalidPlaceReference;
            try verifySymbol(body, call.trait_symbol);
            try verifyArguments(body, value, call.arguments, call.argument_count);
            try verifyCallableSignature(function, call.signature, body.complete);
            if (body.complete) {
                const trait = symbol(body, call.trait_symbol) orelse return error.InvalidSymbolReference;
                const receiver_trait = mir.executableDynTraitPlace(body, receiver.*) orelse return error.InvalidPlaceType;
                if (trait.kind != .trait or !receiver_trait.eql(call.trait_symbol) or
                    call.method_spelling.len == 0 or call.method_index >= mir.max_executable_operands or
                    call.signature.has_environment or call.signature.parameter_count != call.argument_count or
                    !sameValueType(call.signature.return_ty, value.result_ty) or
                    !call.signature.return_type_id.eql(value.type_id)) return error.InvalidFunctionSignature;
                for (call.arguments[0..call.argument_count], 0..) |argument_id, index| {
                    const argument = expression(body, argument_id) orelse return error.InvalidExpressionReference;
                    if (!sameValueType(argument.result_ty, call.signature.parameter_types[index]) or
                        !argument.type_id.eql(call.signature.parameter_type_ids[index]))
                        return error.InvalidFunctionSignature;
                }
                const guarded = placeNeedsRepresentationGuard(body, receiver.*);
                if (guarded) {
                    const source = call.representation_source orelse return error.InvalidMemoryAccessTrap;
                    try verifySpan(function, call.representation_span_id, source);
                    if (ownedTrapCountAll(body, .{ .expression = value.id }) != 1 or
                        ownedTrapCount(body, .{ .expression = value.id }, .InvalidRepresentation, .representation_check) != 1)
                        return error.InvalidMemoryAccessTrap;
                } else if (call.representation_source != null or call.representation_span_id.isValid() or
                    ownedTrapCountAll(body, .{ .expression = value.id }) != 0)
                {
                    return error.InvalidMemoryAccessTrap;
                }
            }
        },
        .dyn_bind => |bind| {
            try verifyOperand(body, value, bind.source);
            const source = expression(body, bind.source) orelse return error.InvalidExpressionReference;
            const trait = symbol(body, bind.trait_symbol) orelse return error.InvalidSymbolReference;
            const concrete = symbol(body, bind.concrete_type_symbol) orelse return error.InvalidSymbolReference;
            if (body.complete) {
                const pointer = switch (source.result_ty) {
                    .pointer => |shape| shape,
                    else => return error.InvalidPlaceType,
                };
                if (value.result_ty != .value or trait.kind != .trait or concrete.kind != .type_ or
                    pointer.kind != .single or !std.mem.eql(u8, pointer.child, concrete.spelling) or
                    ownedTrapCountAll(body, .{ .expression = value.id }) != 0)
                    return error.InvalidPlaceType;
            }
        },
        .address_of => |address| {
            const target = place(body, address.place) orelse return error.InvalidPlaceReference;
            if (target.storage != .ordinary) return error.InvalidPlaceType;
            if (target.root == .value) try verifyOperand(body, value, target.root.value);
            if (body.complete) {
                if (!addressResultMatchesPlace(value.result_ty, target.ty)) return error.InvalidPlaceType;
                if (mir.executableSliceIndexPlace(body, target.*) != null) {
                    if (address.representation_source != null or address.representation_span_id.isValid() or
                        !indexedBoundsEdgesExact(body, .{ .expression = value.id }, value.block_id, target.*, 0))
                        return error.InvalidMemoryAccessTrap;
                } else if (mir.executableFixedArrayIndexPlace(body, target.*) != null) {
                    const indexed = mir.executableFixedArrayIndexPlace(body, target.*).?;
                    if (!fixedArrayAddressableRoot(body, target.*)) return error.InvalidMemoryAccessTrap;
                    const representation_count: usize = @intFromBool(indexed.parameter_pointee);
                    if (indexed.parameter_pointee) {
                        const source = address.representation_source orelse return error.InvalidMemoryAccessTrap;
                        try verifySpan(function, address.representation_span_id, source);
                        if (ownedTrapCount(body, .{ .expression = value.id }, .InvalidRepresentation, .representation_check) != 1)
                            return error.InvalidMemoryAccessTrap;
                    } else if (address.representation_source != null or address.representation_span_id.isValid()) {
                        return error.InvalidMemoryAccessTrap;
                    }
                    if (!indexedBoundsEdgesExact(body, .{ .expression = value.id }, value.block_id, target.*, representation_count))
                        return error.InvalidMemoryAccessTrap;
                } else if (mir.executableAggregateFieldPlace(
                    body.locals,
                    body.statements,
                    body.aggregate_types,
                    target.*,
                    false,
                )) {
                    if (address.representation_source != null or address.representation_span_id.isValid() or
                        ownedTrapCountAll(body, .{ .expression = value.id }) != 0)
                        return error.InvalidMemoryAccessTrap;
                } else if (target.projection_count == 0) {
                    if (!directAddressablePlace(body, target.*) or address.representation_source != null or
                        address.representation_span_id.isValid() or ownedTrapCountAll(body, .{ .expression = value.id }) != 0)
                        return error.InvalidMemoryAccessTrap;
                } else if (isComputedRawManyDerefPlace(body, target.*, false)) {
                    if (address.representation_source != null or address.representation_span_id.isValid() or
                        ownedTrapCountAll(body, .{ .expression = value.id }) != 0)
                        return error.InvalidMemoryAccessTrap;
                } else if (mir.executableParameterProjectedPlace(body, target.*, false)) {
                    const source = address.representation_source orelse return error.InvalidMemoryAccessTrap;
                    try verifySpan(function, address.representation_span_id, source);
                    if (ownedTrapCountAll(body, .{ .expression = value.id }) != 1 or
                        ownedTrapCount(body, .{ .expression = value.id }, .InvalidRepresentation, .representation_check) != 1)
                        return error.InvalidMemoryAccessTrap;
                } else {
                    if (!(isSingleParameterDerefPlace(body, target.*, false) or mir.executableLocalAddressDerefPlace(body, target.*, false)) or
                        !sameValueType(value.result_ty, target.root_ty)) return error.InvalidPlaceType;
                    const source = address.representation_source orelse return error.InvalidMemoryAccessTrap;
                    try verifySpan(function, address.representation_span_id, source);
                    if (ownedTrapCountAll(body, .{ .expression = value.id }) != 1 or
                        ownedTrapCount(body, .{ .expression = value.id }, .InvalidRepresentation, .representation_check) != 1) return error.InvalidMemoryAccessTrap;
                }
            }
        },
        .deref, .slice_length => |id| try verifyOperand(body, value, id),
        .index => |operation| {
            try verifyOperand(body, value, operation.base);
            try verifyOperand(body, value, operation.index);
            if (body.complete) try verifyIndexProjection(function, value, operation);
        },
        .range_slice => |operation| {
            try verifyOperand(body, value, operation.base);
            try verifyOperand(body, value, operation.start);
            try verifyOperand(body, value, operation.end);
            if (body.complete) try verifyRangeSlice(function, value, operation);
        },
        .member => |operation| {
            try verifyOperand(body, value, operation.base);
            if (body.complete) try verifyMemberProjection(function, value, operation);
        },
        .optional_some => |operand_id| {
            try verifyOperand(body, value, operand_id);
            if (body.complete) {
                const aggregate = aggregateType(body, value.type_id) orelse return error.InvalidAggregateConstruction;
                const operand = expression(body, operand_id) orelse return error.InvalidExpressionReference;
                if (value.result_ty != .nullable_value or aggregate.construction != .declared_struct or
                    aggregate.field_count != 2 or !sameValueType(aggregate.ty, value.result_ty) or
                    !sameValueType(aggregate.field_types[0], .bool) or
                    !sameValueType(aggregate.field_types[1], operand.result_ty) or
                    !aggregate.field_type_ids[1].eql(operand.type_id)) return error.InvalidAggregateConstruction;
            }
        },
        .optional_none => if (body.complete) {
            const aggregate = aggregateType(body, value.type_id) orelse return error.InvalidAggregateConstruction;
            if (value.result_ty != .nullable_value or aggregate.construction != .declared_struct or
                aggregate.field_count != 2 or !sameValueType(aggregate.ty, value.result_ty) or
                !sameValueType(aggregate.field_types[0], .bool)) return error.InvalidAggregateConstruction;
        },
        .variant_test => |operation| {
            try verifyOperand(body, value, operation.operand);
            if (body.complete) try verifyVariantOperation(body, value, operation.operand, operation.kind, false);
        },
        .variant_payload => |operation| {
            try verifyOperand(body, value, operation.operand);
            if (body.complete) try verifyVariantOperation(body, value, operation.operand, operation.kind, true);
        },
        .tagged_union_construct => |operation| {
            if (operation.payload) |payload| try verifyOperand(body, value, payload);
            if (body.complete) try verifyTaggedUnionConstruction(body, value, operation);
        },
        .tagged_union_tag => |operand| {
            try verifyOperand(body, value, operand);
            if (body.complete) try verifyTaggedUnionTag(body, value, operand);
        },
        .tagged_union_payload => |operation| {
            try verifyOperand(body, value, operation.operand);
            if (body.complete) try verifyTaggedUnionPayload(function, value, operation);
        },
        .try_unwrap => |operand_id| {
            try verifyOperand(body, value, operand_id);
            const operand = expression(body, operand_id) orelse return error.InvalidExpressionReference;
            if (body.complete) {
                if (!tryUnwrapPayloadValid(body, &value, operand) or
                    ownedTrapCountAll(body, .{ .expression = value.id }) != 1 or
                    ownedTrapCount(body, .{ .expression = value.id }, .Unwrap, .unwrap) != 1)
                    return error.InvalidAggregateConstruction;
            }
        },
        .try_propagate => |operation| {
            try verifyOperand(body, value, operation.operand);
            const operand = expression(body, operation.operand) orelse return error.InvalidExpressionReference;
            if (body.complete and (!tryPropagatePayloadValid(body, &value, operand) or
                ownedTrapCountAll(body, .{ .expression = value.id }) != 0))
                return error.InvalidAggregateConstruction;
        },
        .try_map_error => |operation| {
            try verifyOperand(body, value, operation.operand);
            if (operation.mapper == .literal) try verifyOperand(body, value, operation.mapper.literal);
            if (operation.mapper == .conversion) {
                const signature = operation.mapper.conversion.signature;
                if (signature.parameter_count == 1) try verifyType(
                    function,
                    signature.parameter_type_ids[0],
                    signature.parameter_types[0],
                    body.complete,
                );
                try verifyType(function, signature.return_type_id, signature.return_ty, body.complete);
            }
            const operand = expression(body, operation.operand) orelse return error.InvalidExpressionReference;
            if (body.complete and (!tryMapErrorPayloadValid(body, &value, operand, operation.mapper) or
                ownedTrapCountAll(body, .{ .expression = value.id }) != 0))
                return error.InvalidAggregateConstruction;
        },
        .result => |operation| {
            try verifyOperand(body, value, operation.payload);
            if (body.complete) {
                const shape = resultType(body, value.type_id) orelse return error.InvalidAggregateConstruction;
                const payload = expression(body, operation.payload) orelse return error.InvalidExpressionReference;
                if (!sameValueType(shape.ty, value.result_ty)) return error.InvalidAggregateConstruction;
                if (operation.is_ok) {
                    if (!sameValueType(payload.result_ty, shape.ok_ty) or !payload.type_id.eql(shape.ok_type_id))
                        return error.InvalidAggregateConstruction;
                } else if (!sameValueType(payload.result_ty, shape.err_ty) or !payload.type_id.eql(shape.err_type_id)) {
                    return error.InvalidAggregateConstruction;
                }
            }
        },
        .array => |operation| {
            for (operation.operands) |operand| try verifyOperand(body, value, operand);
            if (body.complete) try verifyArrayConstruction(function, value, operation);
        },
        .struct_ => |operation| {
            try verifyArguments(body, value, operation.operands, operation.operand_count);
            if (body.complete) try verifyStructConstruction(function, value, operation);
        },
    }
}

fn stringLiteralType(ty: mir.ValueType) bool {
    return switch (ty) {
        .cstr => true,
        .pointer => |shape| std.mem.eql(u8, shape.child, "u8"),
        .slice => |child| std.mem.eql(u8, child, "u8"),
        else => false,
    };
}

fn fixedArrayAddressableRoot(body: *const mir.ExecutableBody, target: mir.ExecutablePlace) bool {
    const indexed = mir.executableFixedArrayIndexPlace(body, target) orelse return false;
    if (indexed.parameter_pointee) return true;
    return switch (target.root) {
        .local => |id| local: {
            for (body.parameters) |parameter| if (parameter.local.eql(id)) break :local false;
            for (body.statements) |entry| switch (entry.operation) {
                .local_init => |value| if (value.local.eql(id)) break :local true,
                else => {},
            };
            break :local false;
        },
        .symbol => |id| if (id.isValid() and id.index() < body.symbols.len)
            body.symbols[id.index()].id.eql(id) and body.symbols[id.index()].kind == .global
        else
            false,
        .value => mir.executableFixedArrayCallResultRoot(body, target),
    };
}

fn uncheckedBinaryHasExactProof(
    function: *const mir.Function,
    body: *const mir.ExecutableBody,
    value: mir.ExecutableExpression,
    operation: @FieldType(mir.ExecutableExpression.Operation, "binary"),
    left: mir.ExecutableExpression,
    right: mir.ExecutableExpression,
) bool {
    if (operation.eager_safe or
        !sameValueType(value.result_ty, left.result_ty) or
        !sameValueType(left.result_ty, right.result_ty) or
        mir.ExecutableCastKind.integerInfo(value.result_ty) == null or
        ownedTrapCountAll(body, .{ .expression = value.id }) != 0) return false;
    const op: []const u8 = switch (operation.op) {
        .add => "add",
        .sub => "sub",
        .mul => "mul",
        else => return false,
    };
    const region_id = operation.contract_region_id orelse return false;
    const region_valid = for (function.contract_regions) |region| {
        if (region.id == region_id) break std.mem.eql(u8, region.kind, "no_overflow");
    } else false;
    if (!region_valid) return false;
    for (function.range_facts) |fact| {
        if (fact.region_id == region_id and fact.typed_span_id.eql(value.span_id) and
            std.mem.eql(u8, fact.op, op) and sameValueType(fact.result_ty, value.result_ty)) return true;
    }
    return false;
}

fn verifyVariantOperation(
    body: *const mir.ExecutableBody,
    value: mir.ExecutableExpression,
    operand_id: mir.ExprId,
    kind: mir.ExecutableVariantKind,
    payload: bool,
) !void {
    const operand = expression(body, operand_id) orelse return error.InvalidExpressionReference;
    if (ownedTrapCountAll(body, .{ .expression = value.id }) != 0) return error.InvalidAggregateConstruction;
    if (!payload) {
        if (value.result_ty != .bool) return error.InvalidAggregateConstruction;
        switch (kind) {
            .optional_present => switch (operand.result_ty) {
                .nullable_pointer, .nullable_value => {},
                else => return error.InvalidAggregateConstruction,
            },
            .result_ok, .result_err => if (operand.result_ty != .result) return error.InvalidAggregateConstruction,
        }
        return;
    }
    switch (kind) {
        .optional_present => switch (operand.result_ty) {
            .nullable_pointer => |shape| if (!sameValueType(value.result_ty, .{ .pointer = shape }))
                return error.InvalidAggregateConstruction,
            .nullable_value => {
                const aggregate = aggregateType(body, operand.type_id) orelse return error.InvalidAggregateConstruction;
                if (aggregate.field_count != 2 or !sameValueType(value.result_ty, aggregate.field_types[1]) or
                    !value.type_id.eql(aggregate.field_type_ids[1])) return error.InvalidAggregateConstruction;
            },
            else => return error.InvalidAggregateConstruction,
        },
        .result_ok, .result_err => {
            const shape = resultType(body, operand.type_id) orelse return error.InvalidAggregateConstruction;
            if (kind == .result_ok) {
                if (!sameValueType(value.result_ty, shape.ok_ty) or !value.type_id.eql(shape.ok_type_id))
                    return error.InvalidAggregateConstruction;
            } else if (!sameValueType(value.result_ty, shape.err_ty) or !value.type_id.eql(shape.err_type_id)) {
                return error.InvalidAggregateConstruction;
            }
        },
    }
}

fn verifyTrapEdges(function: *const mir.Function) !void {
    const body = &function.executable_body;
    for (body.trap_edges, 0..) |edge, edge_index| {
        try verifySpanId(function, edge.span_id);
        const OwnerInfo = struct { block_id: mir.BlockId, span_id: mir.SpanId };
        const owner_info: OwnerInfo = switch (edge.owner) {
            .expression => |id| expression_owner: {
                const owner = expression(body, id) orelse return error.InvalidTrapEdge;
                switch (owner.operation) {
                    .unary => |unary| if (mir.executableCheckedUnaryTrapRequirements(unary.op, owner.result_ty) == null)
                        return error.InvalidTrapEdge,
                    .binary => |binary| if (binary.arithmetic != .checked) return error.InvalidTrapEdge,
                    .load => |load| {
                        const target = place(body, load.place) orelse return error.InvalidTrapEdge;
                        if (edge.kind == .Bounds and edge.source == .bounds_check) {
                            _ = indexedProjectionForSpan(body, target.*, edge.span_id) orelse return error.InvalidTrapEdge;
                        } else if (target.storage != .ordinary or
                            !(isParameterScalarAccessPlace(body, target.*, false) or
                                mir.executableParameterProjectedPlace(body, target.*, false) or
                                mir.executableLocalAddressDerefPlace(body, target.*, false) or
                                mir.executableGuardedLocalScalarDerefPlace(body, target.*, false) or
                                mir.executableGuardedLocalAggregateDerefPlace(body, target.*, false) or
                                mir.executableGlobalPointerDerefPlace(body, target.*, false) or
                                mir.executableAggregatePointerFieldDerefPlace(body, target.*, false) != null or
                                mir.executableFixedArrayParameterPointeePlace(body, target.*, false)) or
                            edge.kind != .InvalidRepresentation or
                            edge.source != .representation_check) return error.InvalidTrapEdge;
                    },
                    .atomic_load => |load| {
                        const target = place(body, load.place) orelse return error.InvalidTrapEdge;
                        if (!atomicPlaceSupported(body, target.*) or !placeNeedsRepresentationGuard(body, target.*) or
                            edge.kind != .InvalidRepresentation or edge.source != .representation_check)
                            return error.InvalidTrapEdge;
                    },
                    .atomic_update => |update| {
                        const target = place(body, update.place) orelse return error.InvalidTrapEdge;
                        if (!atomicPlaceSupported(body, target.*) or !placeNeedsRepresentationGuard(body, target.*) or
                            edge.kind != .InvalidRepresentation or edge.source != .representation_check)
                            return error.InvalidTrapEdge;
                    },
                    .address_of => |address| {
                        const target = place(body, address.place) orelse return error.InvalidTrapEdge;
                        const indexed = mir.executableFixedArrayIndexPlace(body, target.*);
                        if (edge.kind == .Bounds and edge.source == .bounds_check) {
                            _ = indexedProjectionForSpan(body, target.*, edge.span_id) orelse return error.InvalidTrapEdge;
                            if (indexed != null and !fixedArrayAddressableRoot(body, target.*)) return error.InvalidTrapEdge;
                        } else if (!(isSingleParameterDerefPlace(body, target.*, false) or
                            mir.executableLocalAddressDerefPlace(body, target.*, false) or
                            mir.executableParameterProjectedPlace(body, target.*, false) or
                            (indexed != null and indexed.?.parameter_pointee)) or
                            edge.kind != .InvalidRepresentation or
                            edge.source != .representation_check) return error.InvalidTrapEdge;
                    },
                    .builtin_call => |call| {
                        if (call.kind == .raw_ptr) {
                            if (call.representation_source == null or !call.representation_span_id.isValid() or
                                edge.kind != .InvalidRepresentation or edge.source != .representation_check)
                                return error.InvalidTrapEdge;
                        } else if (call.kind == .conversion_trap_from) {
                            if (call.representation_source != null or call.representation_span_id.isValid() or
                                edge.kind != .IntegerOverflow or edge.source != .checked_arithmetic)
                                return error.InvalidTrapEdge;
                        } else return error.InvalidTrapEdge;
                    },
                    .dyn_call => |call| {
                        const receiver = place(body, call.receiver) orelse return error.InvalidTrapEdge;
                        if (mir.executableDynTraitPlace(body, receiver.*) == null or
                            !placeNeedsRepresentationGuard(body, receiver.*) or
                            call.representation_source == null or !call.representation_span_id.isValid() or
                            edge.kind != .InvalidRepresentation or edge.source != .representation_check)
                            return error.InvalidTrapEdge;
                    },
                    .representation_check => |check| {
                        const operand = expression(body, check.operand) orelse return error.InvalidTrapEdge;
                        if (!mir.ExecutableRepresentationCheckKind.typesValid(check.kind, owner.result_ty, operand.result_ty) or
                            !owner.type_id.eql(operand.type_id) or edge.kind != .InvalidRepresentation or
                            edge.source != .representation_check) return error.InvalidTrapEdge;
                    },
                    .try_unwrap => |operand_id| {
                        const operand = expression(body, operand_id) orelse return error.InvalidTrapEdge;
                        if (!tryUnwrapPayloadValid(body, owner, operand) or
                            edge.kind != .Unwrap or edge.source != .unwrap)
                            return error.InvalidTrapEdge;
                    },
                    .mmio_map_checked => |operation| {
                        const address = expression(body, operation.address) orelse return error.InvalidTrapEdge;
                        if (!operation.unsafe_authorized or
                            !sameValueType(address.result_ty, .{ .address = .paddr }) or
                            !sameValueType(owner.result_ty, .{ .address = .mmio_ptr }) or
                            edge.kind != .Unwrap or edge.source != .unwrap)
                            return error.InvalidTrapEdge;
                    },
                    .index => |operation| {
                        if (!operation.checked or edge.kind != .Bounds or edge.source != .bounds_check)
                            return error.InvalidTrapEdge;
                    },
                    .range_slice => |operation| {
                        if (!operation.checked or edge.kind != .Bounds or edge.source != .bounds_check)
                            return error.InvalidTrapEdge;
                    },
                    else => return error.InvalidTrapEdge,
                }
                const span_id = switch (owner.operation) {
                    .load => |load| if (edge.kind == .Bounds and edge.source == .bounds_check) bounds: {
                        const target = place(body, load.place) orelse return error.InvalidTrapEdge;
                        const projection = indexedProjectionForSpan(body, target.*, edge.span_id) orelse return error.InvalidTrapEdge;
                        break :bounds projection.span_id;
                    } else load.representation_span_id,
                    .atomic_load => |load| load.representation_span_id,
                    .atomic_update => |update| update.representation_span_id,
                    .address_of => |address| if (edge.kind == .Bounds and edge.source == .bounds_check) bounds: {
                        const target = place(body, address.place) orelse return error.InvalidTrapEdge;
                        const projection = indexedProjectionForSpan(body, target.*, edge.span_id) orelse return error.InvalidTrapEdge;
                        break :bounds projection.span_id;
                    } else address.representation_span_id,
                    .builtin_call => |call| if (call.kind == .raw_ptr) call.representation_span_id else owner.span_id,
                    .dyn_call => |call| call.representation_span_id,
                    else => owner.span_id,
                };
                break :expression_owner .{ .block_id = owner.block_id, .span_id = span_id };
            },
            .statement => |id| statement_owner: {
                const owner = statement(body, id) orelse return error.InvalidTrapEdge;
                switch (owner.operation) {
                    .store => |store| {
                        const target = place(body, store.place) orelse return error.InvalidTrapEdge;
                        if (edge.kind == .Bounds and edge.source == .bounds_check) {
                            const projection = indexedProjectionForSpan(body, target.*, edge.span_id) orelse return error.InvalidTrapEdge;
                            break :statement_owner .{ .block_id = owner.block_id, .span_id = projection.span_id };
                        }
                        if (!(isParameterScalarAccessPlace(body, target.*, true) or
                            mir.executableLocalAddressDerefPlace(body, target.*, true) or
                            mir.executableGuardedLocalScalarDerefPlace(body, target.*, true) or
                            mir.executableGuardedLocalAggregateDerefPlace(body, target.*, true) or
                            mir.executableGlobalPointerDerefPlace(body, target.*, true) or
                            mir.executableAggregatePointerFieldDerefPlace(body, target.*, true) != null or
                            mir.executableFixedArrayParameterPointeePlace(body, target.*, true) or
                            mir.executableParameterProjectedPlace(body, target.*, true)) or
                            edge.kind != .InvalidRepresentation or edge.source != .representation_check)
                            return error.InvalidTrapEdge;
                        break :statement_owner .{ .block_id = owner.block_id, .span_id = store.representation_span_id };
                    },
                    .guard => |guard| {
                        const condition = expression(body, guard.condition) orelse return error.InvalidTrapEdge;
                        if (guard.kind != .assert_ or !sameValueType(condition.result_ty, .bool) or
                            !condition.owner_statement.eql(owner.id) or !condition.block_id.eql(owner.block_id) or
                            edge.kind != .Assert or edge.source != .assert_stmt) return error.InvalidTrapEdge;
                        const executable_trap = executableTerminator(body, edge.trap_block) orelse return error.InvalidTrapEdge;
                        switch (executable_trap.operation) {
                            .trap_ => |kind| if (kind != .Assert) return error.InvalidTrapEdge,
                            else => return error.InvalidTrapEdge,
                        }
                        break :statement_owner .{ .block_id = owner.block_id, .span_id = owner.span_id };
                    },
                    else => return error.InvalidTrapEdge,
                }
            },
        };
        if (!owner_info.block_id.eql(edge.from_block) or !owner_info.span_id.eql(edge.span_id)) return error.InvalidTrapEdge;
        const source_block = blockById(function, edge.from_block) orelse return error.InvalidTrapEdge;
        var has_successor = false;
        for (source_block.typed_successors) |successor| if (successor.eql(edge.trap_block)) {
            has_successor = true;
            break;
        };
        if (!has_successor) return error.InvalidTrapEdge;
        const trap_block = blockById(function, edge.trap_block) orelse return error.InvalidTrapEdge;
        switch (trap_block.terminator) {
            .trap_ => |kind| if (kind != edge.kind) return error.InvalidTrapEdge,
            else => return error.InvalidTrapEdge,
        }
        var legacy_matches: usize = 0;
        for (function.trap_edges) |legacy| {
            if (legacy.from_block == edge.from_block.index() and legacy.trap_block == edge.trap_block.index() and
                legacy.kind == edge.kind and legacy.source == edge.source and legacy.typed_span_id.eql(owner_info.span_id)) legacy_matches += 1;
        }
        if (legacy_matches != 1) return error.InvalidTrapEdge;
        for (body.trap_edges[0..edge_index]) |previous| {
            if (previous.owner.eql(edge.owner) and previous.trap_block.eql(edge.trap_block) and
                previous.kind == edge.kind and previous.source == edge.source and previous.span_id.eql(edge.span_id)) return error.InvalidTrapEdge;
        }
    }
    if (body.complete) {
        var terminal_projections: usize = 0;
        for (function.trap_edges) |legacy| {
            var matches: usize = 0;
            for (body.trap_edges) |edge| {
                if (legacy.from_block == edge.from_block.index() and legacy.trap_block == edge.trap_block.index() and
                    legacy.kind == edge.kind and legacy.source == edge.source and legacy.typed_span_id.eql(edge.span_id)) matches += 1;
            }
            if (matches == 0 and (tryPropagationProjectionMatches(function, legacy) or
                terminalTrapProjectionMatches(function, legacy)))
            {
                terminal_projections += 1;
                continue;
            }
            if (matches != 1) return error.InvalidCompletionClaim;
        }
        if (body.trap_edges.len + terminal_projections != function.trap_edges.len) return error.InvalidCompletionClaim;
    }
}

fn tryPropagationProjectionMatches(function: *const mir.Function, legacy: mir.TrapEdge) bool {
    if (legacy.kind != .Unwrap or legacy.source != .unwrap) return false;
    const body = &function.executable_body;
    var match: ?*const mir.ExecutableExpression = null;
    for (body.expressions) |*value| {
        if (!value.block_id.eql(mir.BlockId.fromIndex(legacy.from_block)) or
            !value.span_id.eql(legacy.typed_span_id) or
            (value.operation != .try_propagate and value.operation != .try_map_error))
            continue;
        if (match != null) return false;
        match = value;
    }
    const value = match orelse return false;
    const operand_id = switch (value.operation) {
        .try_propagate => |operation| operation.operand,
        .try_map_error => |operation| operation.operand,
        else => return false,
    };
    const operand = expression(body, operand_id) orelse return false;
    return switch (value.operation) {
        .try_propagate => tryPropagatePayloadValid(body, value, operand),
        .try_map_error => |operation| tryMapErrorPayloadValid(body, value, operand, operation.mapper),
        else => false,
    };
}

fn terminalTrapProjectionMatches(function: *const mir.Function, legacy: mir.TrapEdge) bool {
    const body = &function.executable_body;
    const source = executableTerminator(body, mir.BlockId.fromIndex(legacy.from_block)) orelse return false;
    const target = executableTerminator(body, mir.BlockId.fromIndex(legacy.trap_block)) orelse return false;
    const trap_block = mir.BlockId.fromIndex(legacy.trap_block);
    const reaches_trap = switch (source.operation) {
        .jump => |block| block.eql(trap_block),
        .switch_ => |switch_| reaches: {
            if (switch_.default_block.eql(trap_block)) break :reaches true;
            for (switch_.cases[0..switch_.case_count]) |case| if (case.target.eql(trap_block)) break :reaches true;
            break :reaches false;
        },
        else => false,
    };
    if (!reaches_trap) return false;
    const kind = switch (target.operation) {
        .trap_ => |value| value,
        else => return false,
    };
    return switch (legacy.source) {
        .unreachable_expr => legacy.kind == .Unreachable and kind == .Unreachable,
        .explicit_trap => explicit: {
            if (legacy.kind != .ExplicitTrap) break :explicit false;
            var matches: usize = 0;
            for (function.call_target_facts) |fact| {
                if (!fact.typed_span_id.eql(legacy.typed_span_id)) continue;
                if (mir.explicitTrapKindForTarget(fact.kind)) |expected| {
                    if (expected == kind) matches += 1;
                }
            }
            break :explicit matches == 1;
        },
        .representation_check => source.operation == .switch_ and
            legacy.kind == .InvalidRepresentation and kind == .InvalidRepresentation,
        else => false,
    };
}

fn ownedTrapCount(body: *const mir.ExecutableBody, owner: mir.ExecutableTrapOwner, kind: mir.TrapKind, source: mir.TrapSource) usize {
    var count: usize = 0;
    for (body.trap_edges) |edge| if (edge.owner.eql(owner) and edge.kind == kind and edge.source == source) {
        count += 1;
    };
    return count;
}

fn indexedProjectionForSpan(
    body: *const mir.ExecutableBody,
    target: mir.ExecutablePlace,
    span_id: mir.SpanId,
) ?@FieldType(mir.ExecutablePlace.Projection, "index") {
    if (mir.executableFixedArrayProjectionForSpan(body, target, span_id)) |projection| return projection;
    const projection = mir.executableSliceIndexPlace(body, target) orelse return null;
    return if (projection.span_id.eql(span_id)) projection else null;
}

fn indexedBoundsEdgesExact(
    body: *const mir.ExecutableBody,
    owner: mir.ExecutableTrapOwner,
    block_id: mir.BlockId,
    target: mir.ExecutablePlace,
    additional_traps: usize,
) bool {
    if (mir.executableFixedArrayIndexPlace(body, target) == null and
        mir.executableSliceIndexPlace(body, target) == null) return false;
    const expected = mir.executableCheckedIndexProjectionCount(target);
    if (ownedTrapCountAll(body, owner) != expected + additional_traps or
        ownedTrapCount(body, owner, .Bounds, .bounds_check) != expected) return false;
    for (target.projections[0..target.projection_count]) |projection| switch (projection) {
        .index => |index| if (index.checked) {
            var matches: usize = 0;
            for (body.trap_edges) |edge| {
                if (!edge.owner.eql(owner) or !edge.span_id.eql(index.span_id)) continue;
                if (!edge.from_block.eql(block_id) or edge.kind != .Bounds or edge.source != .bounds_check) return false;
                const trap = executableTerminator(body, edge.trap_block) orelse return false;
                switch (trap.operation) {
                    .trap_ => |kind| if (kind != .Bounds) return false,
                    else => return false,
                }
                matches += 1;
            }
            if (matches != 1) return false;
        },
        .field, .deref => {},
    };
    return true;
}

fn ownedTrapCountAll(body: *const mir.ExecutableBody, owner: mir.ExecutableTrapOwner) usize {
    var count: usize = 0;
    for (body.trap_edges) |edge| {
        if (edge.owner.eql(owner)) count += 1;
    }
    return count;
}

fn executableTerminator(body: *const mir.ExecutableBody, block_id: mir.BlockId) ?mir.ExecutableTerminator {
    for (body.terminators) |terminator| if (terminator.block_id.eql(block_id)) return terminator;
    return null;
}

fn assertGuardHasExactTrapEdge(
    body: *const mir.ExecutableBody,
    statement_value: mir.ExecutableStatement,
    guard: @FieldType(mir.ExecutableStatement.Operation, "guard"),
) bool {
    if (guard.kind != .assert_) return false;
    const condition = expression(body, guard.condition) orelse return false;
    if (!sameValueType(condition.result_ty, .bool) or
        !condition.owner_statement.eql(statement_value.id) or
        !condition.block_id.eql(statement_value.block_id) or
        ownedTrapCountAll(body, .{ .statement = statement_value.id }) != 1 or
        ownedTrapCount(body, .{ .statement = statement_value.id }, .Assert, .assert_stmt) != 1) return false;
    for (body.trap_edges) |edge| {
        if (!edge.owner.eql(.{ .statement = statement_value.id })) continue;
        if (!edge.from_block.eql(statement_value.block_id)) return false;
        const trap = executableTerminator(body, edge.trap_block) orelse return false;
        return switch (trap.operation) {
            .trap_ => |kind| kind == .Assert,
            else => false,
        };
    }
    return false;
}

fn builtinTrapConversionHasExactEdge(body: *const mir.ExecutableBody, value: mir.ExecutableExpression) bool {
    const call = switch (value.operation) {
        .builtin_call => |operation| operation,
        else => return false,
    };
    if (call.kind != .conversion_trap_from or
        ownedTrapCountAll(body, .{ .expression = value.id }) != 1 or
        ownedTrapCount(body, .{ .expression = value.id }, .IntegerOverflow, .checked_arithmetic) != 1)
        return false;
    for (body.trap_edges) |edge| {
        if (!edge.owner.eql(.{ .expression = value.id })) continue;
        if (!edge.from_block.eql(value.block_id)) return false;
        const trap = executableTerminator(body, edge.trap_block) orelse return false;
        return switch (trap.operation) {
            .trap_ => |kind| kind == .IntegerOverflow,
            else => false,
        };
    }
    return false;
}

fn verifyStatement(function: *const mir.Function, statement_value: mir.ExecutableStatement) !void {
    const body = &function.executable_body;
    switch (statement_value.operation) {
        .local_init => |operation| {
            try verifyLocal(body, operation.local);
            try verifyType(function, operation.type_id, operation.ty, body.complete);
            if (operation.value) |id| try verifyStatementExpr(body, statement_value, id);
        },
        .store => |operation| {
            const target = place(body, operation.place) orelse return error.InvalidPlaceReference;
            if (target.root == .value) {
                try verifyStatementExpr(body, statement_value, target.root.value);
                // Assignment evaluates its RHS before computing a value-rooted
                // destination (for example `raw.offset(i).* = value`).
                if (target.root.value.index() <= operation.value.index()) return error.InvalidEvaluationOrder;
            }
            try verifyType(function, operation.type_id, operation.ty, body.complete);
            if (body.complete) {
                try verifyMemoryAccess(function, operation.place, operation.ty, operation.access, true);
                const guarded = placeNeedsRepresentationGuard(body, target.*);
                const indexed = mir.executableFixedArrayIndexPlace(body, target.*) != null or
                    mir.executableSliceIndexPlace(body, target.*) != null;
                const checked_indices = if (indexed) mir.executableCheckedIndexProjectionCount(target.*) else 0;
                const expected_traps = @as(usize, @intFromBool(guarded)) + checked_indices;
                if (guarded) {
                    const source = operation.representation_source orelse return error.InvalidMemoryAccessTrap;
                    try verifySpan(function, operation.representation_span_id, source);
                    if (ownedTrapCount(body, .{ .statement = statement_value.id }, .InvalidRepresentation, .representation_check) != 1)
                        return error.InvalidMemoryAccessTrap;
                } else if (operation.representation_source != null or operation.representation_span_id.isValid()) {
                    return error.InvalidMemoryAccessTrap;
                }
                if (indexed and !indexedBoundsEdgesExact(
                    body,
                    .{ .statement = statement_value.id },
                    statement_value.block_id,
                    target.*,
                    @intFromBool(guarded),
                )) {
                    return error.InvalidMemoryAccessTrap;
                }
                if (ownedTrapCountAll(body, .{ .statement = statement_value.id }) != expected_traps) {
                    return error.InvalidMemoryAccessTrap;
                }
            }
            for (target.projections[0..target.projection_count]) |projection| switch (projection) {
                .index => |index| try verifyStatementExpr(body, statement_value, index.value),
                .field, .deref => {},
            };
            try verifyStatementExpr(body, statement_value, operation.value);
            const stored = expression(body, operation.value) orelse return error.InvalidExpressionReference;
            if (body.complete and !sameValueType(stored.result_ty, operation.ty)) return error.InvalidStoreType;
            if (body.complete) if (mir.executableCallablePlace(body.aggregate_types, target.*)) |target_signature| {
                const stored_signature = switch (stored.operation) {
                    .symbol => |id| (symbol(body, id) orelse return error.InvalidSymbolReference).callable_signature orelse
                        return error.InvalidFunctionSignature,
                    .local => |id| parameter: {
                        for (body.parameters) |parameter| if (parameter.local.eql(id))
                            break :parameter parameter.callable_signature orelse return error.InvalidFunctionSignature;
                        return error.InvalidFunctionSignature;
                    },
                    .closure_bind => |bind| bind.signature,
                    else => return error.InvalidFunctionSignature,
                };
                if (!target_signature.eql(stored_signature)) return error.InvalidFunctionSignature;
            };
            if (body.complete) if (mir.executableDynTraitPlace(body, target.*)) |target_trait| {
                const stored_trait = switch (stored.operation) {
                    .local => |id| parameter: {
                        for (body.parameters) |parameter| if (parameter.local.eql(id))
                            break :parameter parameter.dyn_trait_symbol_id;
                        return error.InvalidFunctionSignature;
                    },
                    else => return error.InvalidFunctionSignature,
                };
                if (!stored_trait.isValid() or !stored_trait.eql(target_trait)) return error.InvalidFunctionSignature;
            };
        },
        .packed_field_store => |operation| {
            const target = place(body, operation.place) orelse return error.InvalidPlaceReference;
            if (target.storage != .ordinary or target.projection_count != 0 or
                !sameValueType(target.root_ty, target.ty) or !target.root_type_id.eql(target.type_id))
                return error.InvalidPlaceType;
            const aggregate = aggregateType(body, target.type_id) orelse return error.InvalidAggregateType;
            if (aggregate.construction != .packed_bits or !sameValueType(aggregate.ty, target.ty) or
                operation.field_index >= aggregate.field_count or
                aggregate.field_types[operation.field_index] != .bool)
                return error.InvalidAggregateType;
            const expected_alignment = mir.executableMemoryAlignment(body.enum_types, aggregate.storage_ty) orelse
                return error.InvalidMemoryAccessType;
            if (operation.access.alignment != expected_alignment) return error.InvalidMemoryAccessAlignment;
            switch (target.root) {
                .local => if (operation.access.kind != .plain) return error.InvalidMemoryAccessKind,
                .symbol => |id| {
                    const identity = symbol(body, id) orelse return error.InvalidSymbolReference;
                    if (identity.kind != .global or !identity.mutable) return error.ImmutableGlobalStore;
                    if (operation.access.kind != .race_unordered) return error.InvalidMemoryAccessKind;
                },
                .value => return error.InvalidPlaceType,
            }
            try verifyStatementExpr(body, statement_value, operation.value);
            const stored = expression(body, operation.value) orelse return error.InvalidExpressionReference;
            if (stored.result_ty != .bool or !stored.type_id.eql(aggregate.field_type_ids[operation.field_index]))
                return error.InvalidStoreType;
            if (ownedTrapCountAll(body, .{ .statement = statement_value.id }) != 0)
                return error.InvalidMemoryAccessTrap;
        },
        .eval => |id| try verifyStatementExpr(body, statement_value, id),
        .guard => |operation| {
            try verifyStatementExpr(body, statement_value, operation.condition);
            if (body.complete) {
                const expected_traps: usize = if (operation.kind == .assert_) 1 else 0;
                if (operation.kind == .assert_) {
                    if (!assertGuardHasExactTrapEdge(body, statement_value, operation)) return error.InvalidTrapEdge;
                } else if (ownedTrapCountAll(body, .{ .statement = statement_value.id }) != expected_traps) return error.InvalidTrapEdge;
            }
        },
        .return_ => |maybe_id| {
            if (body.complete) {
                const block = blockById(function, statement_value.block_id) orelse return error.InvalidBlockReference;
                switch (block.terminator) {
                    .return_ => {},
                    else => return error.InvalidReturnStatement,
                }
                for (body.statements[statement_value.id.index() + 1 ..]) |later| {
                    if (later.block_id.eql(statement_value.block_id)) return error.InvalidReturnStatement;
                }
            }
            if (maybe_id) |id| {
                if (function.return_ty == .void) return error.InvalidReturnStatement;
                try verifyStatementExpr(body, statement_value, id);
                const result = expression(body, id) orelse return error.InvalidExpressionReference;
                if (body.complete and !sameValueType(result.result_ty, function.return_ty)) return error.InvalidReturnStatement;
            } else if (body.complete and function.return_ty != .void) return error.InvalidReturnStatement;
        },
        .opaque_asm => |asm_value| {
            if (asm_value.template_count > mir.max_executable_operands or
                asm_value.clobber_count > mir.max_executable_operands or
                ownedTrapCountAll(body, .{ .statement = statement_value.id }) != 0)
                return error.InvalidStatementIdentity;
        },
        .precise_asm => |asm_value| {
            if (asm_value.template_count > mir.max_executable_operands or
                asm_value.clobber_count > mir.max_executable_operands or
                asm_value.output_count > mir.max_executable_operands or
                asm_value.input_count > mir.max_executable_operands or
                ownedTrapCountAll(body, .{ .statement = statement_value.id }) != 0)
                return error.InvalidStatementIdentity;
            for (asm_value.outputs[0..asm_value.output_count]) |output| {
                try verifyLocal(body, output.local);
                try verifyType(function, output.type_id, output.ty, body.complete);
                const declared = mutableLocalDeclaration(body, output.local) orelse return error.InvalidLocalIdentity;
                if (!sameValueType(declared.ty, output.ty) or !declared.type_id.eql(output.type_id))
                    return error.InvalidStatementIdentity;
            }
            for (asm_value.inputs[0..asm_value.input_count]) |input| {
                try verifyType(function, input.type_id, input.ty, body.complete);
                try verifyStatementExpr(body, statement_value, input.value);
                const value = expression(body, input.value) orelse return error.InvalidExpressionReference;
                if (!sameValueType(value.result_ty, input.ty) or !value.type_id.eql(input.type_id))
                    return error.InvalidStatementIdentity;
            }
        },
        .control_transfer, .defer_register, .cleanup_run, .unsupported => {},
    }
}

fn mutableLocalDeclaration(
    body: *const mir.ExecutableBody,
    local_id: mir.LocalId,
) ?@FieldType(mir.ExecutableStatement.Operation, "local_init") {
    var found: ?@FieldType(mir.ExecutableStatement.Operation, "local_init") = null;
    for (body.statements) |statement_value| switch (statement_value.operation) {
        .local_init => |declaration| if (declaration.local.eql(local_id)) {
            if (!declaration.mutable or found != null) return null;
            found = declaration;
        },
        else => {},
    };
    return found;
}

fn verifyTerminator(function: *const mir.Function, terminator: mir.ExecutableTerminator) !void {
    const body = &function.executable_body;
    if (terminator.span_id.isValid()) try verifySpan(function, terminator.span_id, terminator.source);
    switch (terminator.operation) {
        .fallthrough, .trap_, .unreachable_ => {},
        .return_ => {
            var return_count: usize = 0;
            for (body.statements) |statement_value| {
                if (!statement_value.block_id.eql(terminator.block_id)) continue;
                switch (statement_value.operation) {
                    .return_ => return_count += 1,
                    else => {},
                }
            }
            if (body.complete and (return_count > 1 or (function.return_ty != .void and return_count != 1))) return error.InvalidReturnStatement;
        },
        .jump => |target| if (!blockExists(function, target)) return error.InvalidBlockReference,
        .for_each => |loop| {
            if (!blockExists(function, loop.body_block) or !blockExists(function, loop.after_block) or
                local(body, loop.iterable_local) == null or local(body, loop.index_local) == null or
                local(body, loop.binding_local) == null or !loop.iterable_type_id.isValid() or
                !loop.index_type_id.isValid() or !loop.element_type_id.isValid())
                return error.InvalidBlockReference;
            const child = switch (loop.iterable_ty) {
                .array => |shape| blk: {
                    if (loop.kind != .fixed_array or loop.bound == null or shape.length == null or
                        loop.bound.? != shape.length.?) return error.InvalidTerminatorCondition;
                    break :blk shape.child;
                },
                .pointer => |shape| blk: {
                    if (loop.kind != .slice or loop.bound != null or shape.kind != .slice) return error.InvalidTerminatorCondition;
                    break :blk shape.child;
                },
                .slice => |child| blk: {
                    if (loop.kind != .slice or loop.bound != null) return error.InvalidTerminatorCondition;
                    break :blk child;
                },
                else => return error.InvalidTerminatorCondition,
            };
            if (!std.mem.eql(u8, child, loop.element_ty.name())) return error.InvalidTerminatorCondition;
        },
        .for_step => |step| {
            if (!blockExists(function, step.header_block) or local(body, step.index_local) == null or
                !step.index_type_id.isValid()) return error.InvalidBlockReference;
        },
        .branch => |branch| {
            const condition = expression(body, branch.condition) orelse return error.InvalidExpressionReference;
            if (!condition.block_id.eql(terminator.block_id) or !blockExists(function, branch.true_block) or !blockExists(function, branch.false_block)) return error.InvalidBlockReference;
            const owner = body.statements[condition.owner_statement.index()];
            switch (owner.operation) {
                .guard => |guard| if (!guard.condition.eql(branch.condition) or guard.kind == .assert_) return error.InvalidTerminatorCondition,
                else => return error.InvalidTerminatorCondition,
            }
        },
        .switch_ => |operation| {
            const subject = expression(body, operation.subject) orelse return error.InvalidExpressionReference;
            if (!subject.block_id.eql(terminator.block_id)) return error.InvalidTerminatorCondition;
            // Incomplete bodies retain a structurally valid switch subject as
            // migration telemetry even when a typed case table could not yet
            // be formed. Complete bodies must carry the whole dispatch table.
            if (!body.complete and operation.case_count == 0 and !operation.default_block.isValid()) return;
            if (operation.case_count == 0 or operation.case_count > operation.cases.len or
                !blockExists(function, operation.default_block)) return error.InvalidTerminatorCondition;
            switch (subject.result_ty) {
                .integer, .domain_integer, .closed_enum, .open_enum => {},
                else => return error.InvalidTerminatorCondition,
            }
            for (operation.cases[0..operation.case_count], 0..) |case, index| {
                if (!blockExists(function, case.target)) return error.InvalidBlockReference;
                if (!switchValueFitsType(body, subject.result_ty, case.value)) return error.InvalidTerminatorCondition;
                for (operation.cases[0..index]) |previous| {
                    if (previous.value.eql(case.value)) return error.InvalidTerminatorCondition;
                }
            }
        },
    }
}

fn verifyOperand(body: *const mir.ExecutableBody, consumer: mir.ExecutableExpression, id: mir.ExprId) !void {
    const operand = expression(body, id) orelse return error.InvalidExpressionReference;
    if (operand.id.index() >= consumer.id.index() or !operand.block_id.eql(consumer.block_id) or
        !operand.owner_statement.eql(consumer.owner_statement)) return error.InvalidEvaluationOrder;
}

fn verifyArguments(body: *const mir.ExecutableBody, consumer: mir.ExecutableExpression, arguments: [mir.max_executable_operands]mir.ExprId, count: usize) !void {
    if (count > mir.max_executable_operands) return error.InvalidArgumentCount;
    for (arguments[0..count]) |argument| try verifyOperand(body, consumer, argument);
    for (arguments[count..]) |argument| if (argument.isValid()) return error.InvalidArgumentCount;
}

fn verifyCallSignature(
    function: *const mir.Function,
    body: *const mir.ExecutableBody,
    consumer: mir.ExecutableExpression,
    call: @FieldType(mir.ExecutableExpression.Operation, "indirect_call"),
) !void {
    const callee = expression(body, call.callee) orelse return error.InvalidExpressionReference;
    if (callee.result_ty != .value or call.signature.parameter_count != call.argument_count or
        call.signature.parameter_count > mir.max_executable_operands) return error.InvalidFunctionSignature;
    // Incomplete bodies are migration telemetry, not a codegen authority.
    // Their partial indirect-call nodes still need structurally valid
    // references, but exact signature/type identity is required only before a
    // body can cross the verified executable boundary.
    if (!body.complete) return;
    switch (callee.operation) {
        .local => |local_id| for (body.parameters) |parameter| {
            if (!parameter.local.eql(local_id)) continue;
            const declared = parameter.callable_signature orelse return error.InvalidFunctionSignature;
            if (!declared.eql(call.signature)) return error.InvalidFunctionSignature;
            break;
        },
        else => {},
    }
    if (!sameValueType(call.signature.return_ty, consumer.result_ty) or
        !call.signature.return_type_id.eql(consumer.type_id)) return error.InvalidFunctionSignature;
    try verifyType(function, call.signature.return_type_id, call.signature.return_ty, body.complete);
    for (call.arguments[0..call.argument_count], 0..) |argument_id, index| {
        const argument = expression(body, argument_id) orelse return error.InvalidExpressionReference;
        if (!sameValueType(argument.result_ty, call.signature.parameter_types[index]) or
            !argument.type_id.eql(call.signature.parameter_type_ids[index])) return error.InvalidFunctionSignature;
        try verifyType(function, call.signature.parameter_type_ids[index], call.signature.parameter_types[index], body.complete);
    }
    for (call.signature.parameter_types[call.signature.parameter_count..]) |ty| if (ty != .unknown)
        return error.InvalidFunctionSignature;
    for (call.signature.parameter_type_ids[call.signature.parameter_count..]) |id| if (id.isValid())
        return error.InvalidFunctionSignature;
}

fn verifyCallableSignature(function: *const mir.Function, signature: mir.ExecutableCallSignature, complete: bool) !void {
    if (signature.parameter_count > mir.max_executable_operands) return error.InvalidFunctionSignature;
    if (!complete) return;
    if (signature.return_ty == .unknown or signature.return_ty == .value) return error.InvalidFunctionSignature;
    try verifyType(function, signature.return_type_id, signature.return_ty, true);
    for (signature.parameter_types[0..signature.parameter_count], signature.parameter_type_ids[0..signature.parameter_count]) |ty, id| {
        if (ty == .unknown or ty == .value) return error.InvalidFunctionSignature;
        try verifyType(function, id, ty, true);
    }
    for (signature.parameter_types[signature.parameter_count..]) |ty| if (ty != .unknown)
        return error.InvalidFunctionSignature;
    for (signature.parameter_type_ids[signature.parameter_count..]) |id| if (id.isValid())
        return error.InvalidFunctionSignature;
}

fn closureCaptureEncodingValid(ty: mir.ValueType, encoding: mir.ExecutableClosureCaptureEncoding) bool {
    return switch (encoding) {
        .pointer => switch (ty) {
            .pointer => |shape| shape.kind != .slice,
            else => false,
        },
        .integer => switch (ty) {
            .integer => |name| (scalar_repr.integer(name) orelse return false).bits <= 64,
            .domain_integer => |shape| (scalar_repr.integer(shape.child) orelse return false).bits <= 64,
            else => false,
        },
    };
}

fn closureBindTargetSignatureValid(
    target: mir.SymbolIdentity,
    capture: mir.ExecutableExpression,
    closure: mir.ExecutableCallSignature,
) bool {
    const signature = target.callable_signature orelse return false;
    if (signature.has_environment or signature.parameter_count != closure.parameter_count + 1 or
        !sameValueType(signature.return_ty, closure.return_ty) or
        !signature.return_type_id.eql(closure.return_type_id) or
        !sameValueType(signature.parameter_types[0], capture.result_ty) or
        !signature.parameter_type_ids[0].eql(capture.type_id)) return false;
    for (
        signature.parameter_types[1..signature.parameter_count],
        signature.parameter_type_ids[1..signature.parameter_count],
        closure.parameter_types[0..closure.parameter_count],
        closure.parameter_type_ids[0..closure.parameter_count],
    ) |target_ty, target_id, closure_ty, closure_id| {
        if (!sameValueType(target_ty, closure_ty) or !target_id.eql(closure_id)) return false;
    }
    return true;
}

fn verifyStatementExpr(body: *const mir.ExecutableBody, owner: mir.ExecutableStatement, id: mir.ExprId) !void {
    const value = expression(body, id) orelse return error.InvalidExpressionReference;
    if (!value.owner_statement.eql(owner.id) or !value.block_id.eql(owner.block_id)) return error.InvalidEvaluationOrder;
}

fn containsIncompleteOperation(body: *const mir.ExecutableBody) bool {
    for (body.expressions) |value| switch (value.operation) {
        .unsupported, .deref => return true,
        .range_slice => {},
        .builtin_call => |call| {
            if (mir.executableBuiltinRequiresUnsafe(call.kind) != call.unsafe_authorized) return true;
            if (call.argument_count > mir.max_executable_operands) return true;
            var operand_types: [mir.max_executable_operands]mir.ValueType = undefined;
            for (call.arguments[0..call.argument_count], 0..) |argument, index| {
                const operand = expression(body, argument) orelse return true;
                operand_types[index] = operand.result_ty;
            }
            if (!mir.executableBuiltinTypesValid(call.kind, value.result_ty, operand_types[0..call.argument_count])) return true;
        },
        .literal => |literal| switch (literal) {
            .uninit => if (!mir.executableUninitLocalInitializer(body, value) and
                !mir.executableUninitAggregateOperand(body, value)) return true,
            .enum_value => return true,
            else => {},
        },
        else => {},
    };
    for (body.places) |value| {
        if (value.storage == .atomic) {
            if (!atomicPlaceSupported(body, value)) return true;
        } else if (value.projection_count != 0 and !isScalarAccessPlace(body, value, false) and
            !mir.executableGuardedLocalAggregateDerefPlace(body, value, false) and
            !mir.executableParameterProjectedPlace(body, value, false) and
            mir.executableFixedArrayIndexPlace(body, value) == null and
            mir.executableSliceIndexPlace(body, value) == null) return true;
    }
    for (body.statements) |value| switch (value.operation) {
        .unsupported => return true,
        .defer_register, .cleanup_run => {},
        else => {},
    };
    for (body.terminators) |value| switch (value.operation) {
        .switch_ => |operation| if (operation.case_count == 0 or !operation.default_block.isValid()) return true,
        else => {},
    };
    return false;
}

fn switchValueFitsType(body: *const mir.ExecutableBody, subject_ty: mir.ValueType, value: mir.ExecutableSwitchValue) bool {
    const storage_ty: mir.ValueType = switch (subject_ty) {
        .integer, .domain_integer => subject_ty,
        .closed_enum, .open_enum => enum_storage: {
            for (body.enum_types) |enum_ty| if (mir.ValueType.eql(enum_ty.ty, subject_ty)) break :enum_storage enum_ty.repr_ty;
            return false;
        },
        else => return false,
    };
    const info = mir.ExecutableCastKind.integerInfo(storage_ty) orelse return false;
    return switch (value) {
        .unsigned => |magnitude| if (info.signed)
            magnitude <= (@as(u128, 1) << @intCast(info.bits - 1)) - 1
        else if (info.bits == 128)
            true
        else
            magnitude <= (@as(u128, 1) << @intCast(info.bits)) - 1,
        .signed => |signed| if (!info.signed)
            signed >= 0 and @as(u128, @intCast(signed)) <= (if (info.bits == 128)
                std.math.maxInt(u128)
            else
                (@as(u128, 1) << @intCast(info.bits)) - 1)
        else if (signed >= 0)
            @as(u128, @intCast(signed)) <= (@as(u128, 1) << @intCast(info.bits - 1)) - 1
        else
            @as(u128, @intCast(-(signed + 1))) + 1 <= (@as(u128, 1) << @intCast(info.bits - 1)),
    };
}

fn verifyAggregateType(function: *const mir.Function, aggregate: mir.ExecutableAggregateType, index: usize) !void {
    const body = &function.executable_body;
    if (!aggregate.type_id.isValid() or aggregate.field_count == 0 or aggregate.field_count > mir.max_executable_operands or
        (aggregate.construction != .declared_struct and aggregate.construction != .c_union and aggregate.construction != .packed_bits)) return error.InvalidAggregateType;
    try verifyType(function, aggregate.type_id, aggregate.ty, body.complete);
    if (aggregate.ty != .array and aggregate.ty != .struct_ and aggregate.ty != .nullable_value) return error.InvalidAggregateType;
    if (aggregate.construction == .packed_bits) {
        const storage = mir.ExecutableCastKind.integerInfo(aggregate.storage_ty) orelse return error.InvalidAggregateType;
        if (aggregate.ty != .struct_ or !aggregate.storage_type_id.isValid() or aggregate.field_count > storage.bits)
            return error.InvalidAggregateType;
        try verifyType(function, aggregate.storage_type_id, aggregate.storage_ty, body.complete);
        for (aggregate.field_types[0..aggregate.field_count]) |field_ty| if (field_ty != .bool) return error.InvalidAggregateType;
        if (aggregate.storage_size != 0 or aggregate.storage_alignment != 0 or aggregate.storage_unit_size != 0 or aggregate.is_overlay_union)
            return error.InvalidAggregateType;
    } else {
        if (aggregate.storage_ty != .unknown or aggregate.storage_type_id.isValid()) return error.InvalidAggregateType;
        if (aggregate.construction == .c_union) {
            if (aggregate.storage_size == 0 or aggregate.storage_alignment == 0 or aggregate.storage_unit_size == 0 or
                aggregate.storage_size % aggregate.storage_unit_size != 0 or
                aggregate.storage_unit_size > aggregate.storage_alignment or
                (aggregate.storage_unit_size != 1 and aggregate.storage_unit_size != 2 and aggregate.storage_unit_size != 4 and
                    aggregate.storage_unit_size != 8 and aggregate.storage_unit_size != 16))
                return error.InvalidAggregateType;
        } else if (aggregate.storage_size != 0 or aggregate.storage_alignment != 0 or aggregate.storage_unit_size != 0 or aggregate.is_overlay_union) {
            return error.InvalidAggregateType;
        }
    }
    if (aggregate.ty == .array and aggregate.construction != .declared_struct) return error.InvalidAggregateType;
    if (aggregate.ty == .nullable_value and (aggregate.construction != .declared_struct or aggregate.field_count != 2 or
        !sameValueType(aggregate.field_types[0], .bool))) return error.InvalidAggregateType;
    for (body.aggregate_types[0..index]) |previous| if (previous.type_id.eql(aggregate.type_id)) return error.InvalidAggregateType;
    for (aggregate.field_types[0..aggregate.field_count], aggregate.field_type_ids[0..aggregate.field_count], aggregate.field_callable_signatures[0..aggregate.field_count], aggregate.field_dyn_trait_symbols[0..aggregate.field_count]) |field_ty, field_type_id, callable_signature, dyn_trait_symbol| {
        const dyn_trait = dyn_trait_symbol.isValid();
        if (field_ty == .unknown or (field_ty == .value) != ((callable_signature != null) != dyn_trait)) return error.InvalidAggregateType;
        try verifyType(function, field_type_id, field_ty, body.complete);
        if (callable_signature) |signature| try verifyCallableSignature(function, signature, body.complete);
        if (dyn_trait) {
            const trait = symbol(body, dyn_trait_symbol) orelse return error.InvalidSymbolReference;
            if (body.complete and trait.kind != .trait) return error.InvalidAggregateType;
        }
    }
    if (aggregate.ty == .array) {
        const length = aggregate.array_length orelse return error.InvalidAggregateType;
        // The element spelling is presentation data and is not reversible
        // from every ValueType (pointer name(), for example, returns only its
        // child). Structural identity is already checked by type_id and by
        // the repeated field type/type-id checks below.
        if (aggregate.ty.array.length == null or aggregate.ty.array.length.? != length)
            return error.InvalidAggregateType;
        const stored_field_count = if (length > mir.max_executable_operands) 1 else length;
        if (length == 0 or aggregate.field_count != stored_field_count)
            return error.InvalidAggregateType;
        for (aggregate.field_spellings[0..aggregate.field_count], aggregate.field_types[0..aggregate.field_count], aggregate.field_type_ids[0..aggregate.field_count]) |field_spelling, field_ty, field_type_id| {
            if (field_spelling.len != 0 or !sameValueType(field_ty, aggregate.field_types[0]) or
                !field_type_id.eql(aggregate.field_type_ids[0])) return error.InvalidAggregateType;
        }
    }
    for (aggregate.field_types[0..aggregate.field_count], aggregate.field_type_ids[0..aggregate.field_count], aggregate.field_layout_complete[0..aggregate.field_count]) |field_ty, field_type_id, layout_complete| {
        if (field_ty != .array or !layout_complete) continue;
        var found = false;
        for (body.aggregate_types) |nested| {
            if (nested.type_id.eql(field_type_id) and sameValueType(nested.ty, field_ty)) {
                found = true;
                break;
            }
        }
        if (!found) return error.InvalidAggregateType;
    }
    for (aggregate.field_spellings[aggregate.field_count..], aggregate.field_types[aggregate.field_count..], aggregate.field_type_ids[aggregate.field_count..], aggregate.field_callable_signatures[aggregate.field_count..], aggregate.field_dyn_trait_symbols[aggregate.field_count..]) |field_spelling, field_ty, field_type_id, callable_signature, dyn_trait_symbol| {
        if (field_spelling.len != 0 or field_ty != .unknown or field_type_id.isValid() or callable_signature != null or dyn_trait_symbol.isValid())
            return error.InvalidAggregateType;
    }
}

fn verifyEnumType(function: *const mir.Function, enum_ty: mir.ExecutableEnumType, index: usize) !void {
    const body = &function.executable_body;
    if (!enum_ty.type_id.isValid() or !enum_ty.repr_type_id.isValid()) return error.InvalidEnumType;
    switch (enum_ty.ty) {
        .closed_enum, .open_enum => {},
        else => return error.InvalidEnumType,
    }
    if (enum_ty.repr_ty != .integer) return error.InvalidEnumType;
    try verifyType(function, enum_ty.type_id, enum_ty.ty, body.complete);
    try verifyType(function, enum_ty.repr_type_id, enum_ty.repr_ty, body.complete);
    if (enum_ty.ty == .closed_enum) {
        if (enum_ty.valid_value_count == 0 or enum_ty.valid_value_count > mir.max_executable_operands)
            return error.InvalidEnumType;
        for (enum_ty.valid_values[0..enum_ty.valid_value_count], 0..) |value, value_index| {
            for (enum_ty.valid_values[0..value_index]) |previous| if (previous == value) return error.InvalidEnumType;
        }
    } else if (enum_ty.valid_value_count != 0) return error.InvalidEnumType;
    for (body.enum_types[0..index]) |previous| {
        if (previous.type_id.eql(enum_ty.type_id) or sameValueType(previous.ty, enum_ty.ty)) return error.InvalidEnumType;
    }
}

fn closedEnumCheckMetadataValid(body: *const mir.ExecutableBody, value: mir.ExecutableExpression) bool {
    for (body.enum_types) |enum_ty| if (enum_ty.type_id.eql(value.type_id)) {
        return sameValueType(enum_ty.ty, value.result_ty) and enum_ty.ty == .closed_enum and
            enum_ty.valid_value_count != 0 and enum_ty.valid_value_count <= mir.max_executable_operands;
    };
    return false;
}

fn verifyResultType(function: *const mir.Function, result_ty: mir.ExecutableResultType, index: usize) !void {
    const body = &function.executable_body;
    if (!result_ty.type_id.isValid() or !result_ty.ok_type_id.isValid() or !result_ty.err_type_id.isValid() or
        result_ty.ty != .result or result_ty.ok_ty == .unknown or result_ty.ok_ty == .value or
        result_ty.err_ty == .unknown or result_ty.err_ty == .value) return error.InvalidAggregateType;
    try verifyType(function, result_ty.type_id, result_ty.ty, body.complete);
    try verifyType(function, result_ty.ok_type_id, result_ty.ok_ty, body.complete);
    try verifyType(function, result_ty.err_type_id, result_ty.err_ty, body.complete);
    for (body.result_types[0..index]) |previous| if (previous.type_id.eql(result_ty.type_id) or
        sameValueType(previous.ty, result_ty.ty)) return error.InvalidAggregateType;
}

fn taggedUnionType(body: *const mir.ExecutableBody, type_id: mir.TypeId) ?*const mir.ExecutableTaggedUnionType {
    for (body.tagged_union_types) |*candidate| if (candidate.type_id.eql(type_id)) return candidate;
    return null;
}

fn verifyTaggedUnionType(function: *const mir.Function, tagged: mir.ExecutableTaggedUnionType, index: usize) !void {
    const body = &function.executable_body;
    if (!tagged.type_id.isValid() or !tagged.tag_type_id.isValid() or tagged.ty != .tagged_union or
        tagged.case_count == 0 or tagged.case_count > mir.max_executable_switch_cases or
        tagged.size == 0 or tagged.alignment == 0 or tagged.payload_size == 0 or tagged.payload_alignment == 0 or
        tagged.storage_count == 0 or tagged.payload_field_index == 0)
        return error.InvalidAggregateType;
    if (tagged.payload_alignment != 1 and tagged.payload_alignment != 2 and
        tagged.payload_alignment != 4 and tagged.payload_alignment != 8)
        return error.InvalidAggregateType;
    const expected_alignment = @max(@as(u64, 4), tagged.payload_alignment);
    const expected_padding = ((tagged.payload_alignment - (4 % tagged.payload_alignment)) % tagged.payload_alignment);
    const payload_rounding = tagged.payload_alignment - 1;
    const payload_with_rounding = std.math.add(u64, tagged.payload_size, payload_rounding) catch
        return error.InvalidAggregateType;
    const aligned_payload_size = payload_with_rounding & ~payload_rounding;
    const expected_storage_count = @max(@as(u64, 1), aligned_payload_size / tagged.payload_alignment);
    const payload_storage_size = std.math.mul(u64, expected_storage_count, tagged.payload_alignment) catch
        return error.InvalidAggregateType;
    const payload_offset = std.math.add(u64, 4, expected_padding) catch return error.InvalidAggregateType;
    const payload_end = std.math.add(u64, payload_offset, payload_storage_size) catch return error.InvalidAggregateType;
    const total_with_rounding = std.math.add(u64, payload_end, expected_alignment - 1) catch
        return error.InvalidAggregateType;
    const expected_size = total_with_rounding & ~(expected_alignment - 1);
    if (tagged.alignment != expected_alignment or tagged.padding_size != expected_padding or
        tagged.storage_count != expected_storage_count or tagged.size != expected_size or
        tagged.payload_field_index != @as(u8, if (expected_padding == 0) 1 else 2))
        return error.InvalidAggregateType;
    try verifyType(function, tagged.type_id, tagged.ty, body.complete);
    try verifyType(function, tagged.tag_type_id, .{ .integer = "u32" }, body.complete);
    for (body.tagged_union_types[0..index]) |previous| if (previous.type_id.eql(tagged.type_id) or
        sameValueType(previous.ty, tagged.ty)) return error.InvalidAggregateType;
    for (tagged.cases[0..tagged.case_count], 0..) |case, case_index| {
        if (case.spelling.len == 0) return error.InvalidAggregateType;
        for (tagged.cases[0..case_index]) |previous| if (std.mem.eql(u8, previous.spelling, case.spelling))
            return error.InvalidAggregateType;
        if (case.has_payload) {
            if (!case.payload_type_id.isValid() or case.payload_ty == .unknown or case.payload_ty == .value or
                case.payload_ty == .void or case.payload_ty == .never) return error.InvalidAggregateType;
            try verifyType(function, case.payload_type_id, case.payload_ty, body.complete);
        } else if (case.payload_type_id.isValid() or case.payload_ty != .void) return error.InvalidAggregateType;
    }
    for (tagged.cases[tagged.case_count..]) |case| if (case.spelling.len != 0 or case.has_payload or
        case.payload_type_id.isValid() or case.payload_ty != .void) return error.InvalidAggregateType;
}

fn verifyTaggedUnionConstruction(body: *const mir.ExecutableBody, value: mir.ExecutableExpression, operation: @FieldType(mir.ExecutableExpression.Operation, "tagged_union_construct")) !void {
    const tagged = taggedUnionType(body, value.type_id) orelse return error.InvalidAggregateConstruction;
    if (!sameValueType(tagged.ty, value.result_ty) or operation.case_index >= tagged.case_count)
        return error.InvalidAggregateConstruction;
    const case = tagged.cases[operation.case_index];
    if (case.has_payload) {
        const payload_id = operation.payload orelse return error.InvalidAggregateConstruction;
        const payload = expression(body, payload_id) orelse return error.InvalidExpressionReference;
        if (!sameValueType(payload.result_ty, case.payload_ty) or !payload.type_id.eql(case.payload_type_id))
            return error.InvalidAggregateConstruction;
    } else if (operation.payload != null) return error.InvalidAggregateConstruction;
}

fn verifyTaggedUnionTag(body: *const mir.ExecutableBody, value: mir.ExecutableExpression, operand_id: mir.ExprId) !void {
    const operand = expression(body, operand_id) orelse return error.InvalidExpressionReference;
    const tagged = taggedUnionType(body, operand.type_id) orelse return error.InvalidAggregateConstruction;
    if (!sameValueType(operand.result_ty, tagged.ty) or !sameValueType(value.result_ty, .{ .integer = "u32" }) or
        !value.type_id.eql(tagged.tag_type_id)) return error.InvalidAggregateConstruction;
}

fn expressionLocal(body: *const mir.ExecutableBody, id: mir.ExprId) ?mir.LocalId {
    const value = expression(body, id) orelse return null;
    return switch (value.operation) {
        .local => |local_id| local_id,
        else => null,
    };
}

fn taggedUnionPayloadHasCaseEdge(function: *const mir.Function, value: mir.ExecutableExpression, operand_id: mir.ExprId, case_index: u32) bool {
    const body = &function.executable_body;
    const payload_local = expressionLocal(body, operand_id) orelse return false;
    for (body.expressions) |tag_value| switch (tag_value.operation) {
        .tagged_union_tag => |tag_operand| {
            const tag_local = expressionLocal(body, tag_operand) orelse continue;
            if (!tag_local.eql(payload_local)) continue;
            const terminator = executableTerminator(body, tag_value.block_id) orelse continue;
            switch (terminator.operation) {
                .switch_ => |switch_| {
                    if (!switch_.subject.eql(tag_value.id)) continue;
                    for (switch_.cases[0..switch_.case_count]) |case| {
                        if (case.value == .unsigned and case.value.unsigned == case_index and case.target.eql(value.block_id)) return true;
                    }
                },
                else => {},
            }
        },
        else => {},
    };
    return false;
}

fn verifyTaggedUnionPayload(function: *const mir.Function, value: mir.ExecutableExpression, operation: @FieldType(mir.ExecutableExpression.Operation, "tagged_union_payload")) !void {
    const body = &function.executable_body;
    const operand = expression(body, operation.operand) orelse return error.InvalidExpressionReference;
    const tagged = taggedUnionType(body, operand.type_id) orelse return error.InvalidAggregateConstruction;
    if (!sameValueType(operand.result_ty, tagged.ty) or operation.case_index >= tagged.case_count)
        return error.InvalidAggregateConstruction;
    const case = tagged.cases[operation.case_index];
    if (!case.has_payload or !sameValueType(value.result_ty, case.payload_ty) or !value.type_id.eql(case.payload_type_id) or
        !taggedUnionPayloadHasCaseEdge(function, value, operation.operand, operation.case_index))
        return error.InvalidAggregateConstruction;
}

fn verifyMemberProjection(
    function: *const mir.Function,
    value: mir.ExecutableExpression,
    operation: @FieldType(mir.ExecutableExpression.Operation, "member"),
) !void {
    const body = &function.executable_body;
    const base = expression(body, operation.base) orelse return error.InvalidExpressionReference;
    const aggregate = aggregateType(body, base.type_id) orelse return error.InvalidAggregateType;
    if (operation.field_index >= aggregate.field_count or aggregate.field_spellings[operation.field_index].len == 0 or
        !sameValueType(base.result_ty, aggregate.ty) or
        !sameValueType(value.result_ty, aggregate.field_types[operation.field_index]) or
        !value.type_id.eql(aggregate.field_type_ids[operation.field_index])) return error.InvalidAggregateType;
}

fn verifyIndexProjection(
    function: *const mir.Function,
    value: mir.ExecutableExpression,
    operation: @FieldType(mir.ExecutableExpression.Operation, "index"),
) !void {
    const body = &function.executable_body;
    const base = expression(body, operation.base) orelse return error.InvalidExpressionReference;
    const index = expression(body, operation.index) orelse return error.InvalidExpressionReference;
    if (!base.block_id.eql(value.block_id) or !index.block_id.eql(value.block_id) or
        !base.owner_statement.eql(value.owner_statement) or !index.owner_statement.eql(value.owner_statement) or
        !sameValueType(index.result_ty, .{ .integer = "usize" }))
        return error.InvalidAggregateType;

    switch (operation.kind) {
        .fixed_array => {
            const bound = operation.bound orelse return error.InvalidAggregateType;
            const array = switch (base.result_ty) {
                .array => |shape| shape,
                else => return error.InvalidAggregateType,
            };
            const aggregate = aggregateType(body, base.type_id) orelse return error.InvalidAggregateType;
            if (array.length == null or array.length.? != bound or bound == 0 or
                !sameValueType(aggregate.ty, base.result_ty) or aggregate.array_length == null or
                aggregate.array_length.? != bound or aggregate.field_count == 0 or
                !sameValueType(value.result_ty, aggregate.field_types[0]) or
                !value.type_id.eql(aggregate.field_type_ids[0]))
                return error.InvalidAggregateType;
        },
        .slice => {
            if (operation.bound != null) return error.InvalidAggregateType;
            const child = switch (base.result_ty) {
                .pointer => |shape| if (shape.kind == .slice) shape.child else return error.InvalidAggregateType,
                .slice => |name| name,
                else => return error.InvalidAggregateType,
            };
            if (!std.mem.eql(u8, child, value.result_ty.name())) return error.InvalidAggregateType;
        },
    }

    const owner: mir.ExecutableTrapOwner = .{ .expression = value.id };
    if (operation.checked) {
        if (ownedTrapCountAll(body, owner) != 1 or
            ownedTrapCount(body, owner, .Bounds, .bounds_check) != 1)
            return error.InvalidMemoryAccessTrap;
        return;
    }
    if (ownedTrapCountAll(body, owner) != 0 or operation.kind != .fixed_array)
        return error.InvalidMemoryAccessTrap;
    const bound = operation.bound orelse return error.InvalidAggregateType;
    switch (index.operation) {
        .literal => |literal| switch (literal) {
            .integer => |magnitude| if (magnitude >= bound) return error.InvalidMemoryAccessTrap,
            else => return error.InvalidMemoryAccessTrap,
        },
        else => return error.InvalidMemoryAccessTrap,
    }
}

fn verifyRangeSlice(
    function: *const mir.Function,
    value: mir.ExecutableExpression,
    operation: @FieldType(mir.ExecutableExpression.Operation, "range_slice"),
) !void {
    const body = &function.executable_body;
    const base = expression(body, operation.base) orelse return error.InvalidExpressionReference;
    const start = expression(body, operation.start) orelse return error.InvalidExpressionReference;
    const end = expression(body, operation.end) orelse return error.InvalidExpressionReference;
    if (!base.block_id.eql(value.block_id) or !start.block_id.eql(value.block_id) or !end.block_id.eql(value.block_id) or
        !base.owner_statement.eql(value.owner_statement) or !start.owner_statement.eql(value.owner_statement) or
        !end.owner_statement.eql(value.owner_statement) or
        !sameValueType(start.result_ty, .{ .integer = "usize" }) or
        !sameValueType(end.result_ty, .{ .integer = "usize" }))
        return error.InvalidAggregateType;

    const result_shape = switch (value.result_ty) {
        .pointer => |shape| if (shape.kind == .slice) shape else return error.InvalidAggregateType,
        else => return error.InvalidAggregateType,
    };
    const bound: ?usize = switch (base.result_ty) {
        .array => |shape| array: {
            const length = shape.length orelse return error.InvalidAggregateType;
            const aggregate = aggregateType(body, base.type_id) orelse return error.InvalidAggregateType;
            if (aggregate.array_length == null or aggregate.array_length.? != length or aggregate.field_count == 0 or
                !sameValueType(aggregate.ty, base.result_ty) or
                !std.mem.eql(u8, result_shape.child, aggregate.field_types[0].name()))
                return error.InvalidAggregateType;
            break :array length;
        },
        .pointer => |shape| if (shape.kind == .slice and std.mem.eql(u8, shape.child, result_shape.child)) null else return error.InvalidAggregateType,
        .slice => |child| if (std.mem.eql(u8, child, result_shape.child)) null else return error.InvalidAggregateType,
        else => return error.InvalidAggregateType,
    };

    const owner: mir.ExecutableTrapOwner = .{ .expression = value.id };
    if (operation.checked) {
        if (ownedTrapCountAll(body, owner) != 1 or ownedTrapCount(body, owner, .Bounds, .bounds_check) != 1)
            return error.InvalidMemoryAccessTrap;
        return;
    }
    if (ownedTrapCountAll(body, owner) != 0 or bound == null) return error.InvalidMemoryAccessTrap;
    const start_value = switch (start.operation) {
        .literal => |literal| switch (literal) {
            .integer => |magnitude| magnitude,
            else => return error.InvalidMemoryAccessTrap,
        },
        else => return error.InvalidMemoryAccessTrap,
    };
    const end_value = switch (end.operation) {
        .literal => |literal| switch (literal) {
            .integer => |magnitude| magnitude,
            else => return error.InvalidMemoryAccessTrap,
        },
        else => return error.InvalidMemoryAccessTrap,
    };
    if (start_value > end_value or end_value > bound.?) return error.InvalidMemoryAccessTrap;
}

fn verifyStructConstruction(
    function: *const mir.Function,
    value: mir.ExecutableExpression,
    operation: @FieldType(mir.ExecutableExpression.Operation, "struct_"),
) !void {
    const body = &function.executable_body;
    const aggregate = aggregateType(body, value.type_id) orelse return error.InvalidAggregateConstruction;
    if ((aggregate.construction != .declared_struct and aggregate.construction != .c_union and aggregate.construction != .packed_bits) or
        operation.construction != aggregate.construction or
        !sameValueType(aggregate.ty, value.result_ty) or
        (aggregate.construction == .c_union and operation.operand_count != 1) or
        (aggregate.construction != .c_union and operation.operand_count != aggregate.field_count))
        return error.InvalidAggregateConstruction;
    var seen = [_]bool{false} ** mir.max_executable_operands;
    for (operation.operands[0..operation.operand_count], operation.field_indices[0..operation.operand_count]) |operand_id, field_index| {
        if (field_index >= aggregate.field_count or seen[field_index]) return error.InvalidAggregateConstruction;
        seen[field_index] = true;
        const operand = expression(body, operand_id) orelse return error.InvalidExpressionReference;
        if (!sameValueType(operand.result_ty, aggregate.field_types[field_index]) or !operand.type_id.eql(aggregate.field_type_ids[field_index]))
            return error.InvalidAggregateConstruction;
    }
    if (aggregate.construction != .c_union)
        for (seen[0..aggregate.field_count]) |present| if (!present) return error.InvalidAggregateConstruction;
    for (operation.field_indices[operation.operand_count..]) |field_index| if (field_index != std.math.maxInt(usize))
        return error.InvalidAggregateConstruction;
}

fn verifyArrayConstruction(
    function: *const mir.Function,
    value: mir.ExecutableExpression,
    operation: @FieldType(mir.ExecutableExpression.Operation, "array"),
) !void {
    const body = &function.executable_body;
    const aggregate = aggregateType(body, value.type_id) orelse return error.InvalidAggregateConstruction;
    if (aggregate.construction != .declared_struct or aggregate.ty != .array or !sameValueType(aggregate.ty, value.result_ty) or
        operation.operands.len == 0 or aggregate.array_length == null or
        operation.operands.len != aggregate.array_length.? or
        (aggregate.field_count != 1 and operation.operands.len != aggregate.field_count))
        return error.InvalidAggregateConstruction;
    for (operation.operands, 0..) |operand_id, index| {
        const operand = expression(body, operand_id) orelse return error.InvalidExpressionReference;
        const field_index = if (aggregate.field_count == 1) 0 else index;
        if (!sameValueType(operand.result_ty, aggregate.field_types[field_index]) or
            !operand.type_id.eql(aggregate.field_type_ids[field_index])) return error.InvalidAggregateConstruction;
    }
}

pub fn aggregateType(body: *const mir.ExecutableBody, type_id: mir.TypeId) ?*const mir.ExecutableAggregateType {
    if (!type_id.isValid()) return null;
    for (body.aggregate_types) |*aggregate| if (aggregate.type_id.eql(type_id)) return aggregate;
    return null;
}

fn resultType(body: *const mir.ExecutableBody, type_id: mir.TypeId) ?*const mir.ExecutableResultType {
    if (!type_id.isValid()) return null;
    for (body.result_types) |*shape| if (shape.type_id.eql(type_id)) return shape;
    return null;
}

fn tryUnwrapPayloadValid(
    body: *const mir.ExecutableBody,
    value: *const mir.ExecutableExpression,
    operand: *const mir.ExecutableExpression,
) bool {
    return switch (operand.result_ty) {
        .nullable_pointer => |shape| sameValueType(value.result_ty, .{ .pointer = shape }),
        .nullable_value => optional: {
            const aggregate = aggregateType(body, operand.type_id) orelse break :optional false;
            break :optional aggregate.construction == .declared_struct and
                aggregate.ty == .nullable_value and aggregate.field_count == 2 and
                sameValueType(value.result_ty, aggregate.field_types[1]) and
                value.type_id.eql(aggregate.field_type_ids[1]);
        },
        .result => result: {
            const shape = resultType(body, operand.type_id) orelse break :result false;
            break :result sameValueType(value.result_ty, shape.ok_ty) and
                value.type_id.eql(shape.ok_type_id);
        },
        else => false,
    };
}

fn tryPropagatePayloadValid(
    body: *const mir.ExecutableBody,
    value: *const mir.ExecutableExpression,
    operand: *const mir.ExecutableExpression,
) bool {
    if (operand.result_ty != .result or !operand.type_id.eql(body.return_type_id)) return false;
    const shape = resultType(body, operand.type_id) orelse return false;
    return sameValueType(shape.ty, operand.result_ty) and
        sameValueType(value.result_ty, shape.ok_ty) and value.type_id.eql(shape.ok_type_id);
}

fn tryMapErrorPayloadValid(
    body: *const mir.ExecutableBody,
    value: *const mir.ExecutableExpression,
    operand: *const mir.ExecutableExpression,
    mapper: mir.ExecutableTryErrorMapper,
) bool {
    if (operand.result_ty != .result) return false;
    const source = resultType(body, operand.type_id) orelse return false;
    const target = resultType(body, body.return_type_id) orelse return false;
    if (!sameValueType(source.ok_ty, target.ok_ty) or
        !sameValueType(value.result_ty, source.ok_ty) or !value.type_id.eql(source.ok_type_id)) return false;
    return switch (mapper) {
        .conversion => |conversion| conversion_valid: {
            const callee = symbol(body, conversion.callee) orelse break :conversion_valid false;
            const signature = conversion.signature;
            break :conversion_valid callee.kind == .function and signature.parameter_count == 1 and
                !signature.has_environment and sameValueType(signature.parameter_types[0], source.err_ty) and
                signature.parameter_type_ids[0].eql(source.err_type_id) and
                sameValueType(signature.return_ty, target.err_ty) and signature.return_type_id.eql(target.err_type_id);
        },
        .literal => |literal_id| literal_valid: {
            const literal = expression(body, literal_id) orelse break :literal_valid false;
            if (!sameValueType(literal.result_ty, target.err_ty) or !literal.type_id.eql(target.err_type_id))
                break :literal_valid false;
            break :literal_valid switch (literal.operation) {
                .literal => |payload| switch (payload) {
                    .integer, .signed_integer => true,
                    else => false,
                },
                else => false,
            };
        },
    };
}

fn verifyMemoryAccess(
    function: *const mir.Function,
    place_id: mir.PlaceId,
    ty: mir.ValueType,
    access: mir.ExecutableMemoryAccess,
    is_store: bool,
) !void {
    const body = &function.executable_body;
    const target = place(body, place_id) orelse return error.InvalidPlaceReference;
    if (target.storage != .ordinary) return error.InvalidMemoryAccessType;
    if (!sameValueType(target.ty, ty)) return error.InvalidPlaceType;
    const aggregate_copy = mir.executableAggregateCopyAlignment(ty) != null;
    const expected_alignment = mir.executableMemoryAlignment(body.enum_types, ty) orelse return error.InvalidMemoryAccessType;
    if (access.alignment != expected_alignment) return error.InvalidMemoryAccessAlignment;
    if (aggregate_copy and access.kind == .race_unordered and
        !mir.executableRaceAggregateTypeSupported(body, target.type_id, target.ty)) return error.InvalidMemoryAccessType;
    if (target.projection_count != 0) {
        if (mir.executableFixedArrayIndexPlace(body, target.*) != null) {
            if (mir.executableFixedArrayParameterPointeePlace(body, target.*, is_store)) {
                if (access.kind != .race_unordered) return error.InvalidMemoryAccessKind;
                return;
            }
            switch (target.root) {
                .local => if (access.kind != .plain) return error.InvalidMemoryAccessKind,
                .symbol => |id| {
                    const identity = symbol(body, id) orelse return error.InvalidSymbolReference;
                    if (identity.kind != .global or (is_store and !identity.mutable)) return error.InvalidMemoryAccessType;
                    const expected_kind: mir.ExecutableMemoryAccessKind = if (identity.mutable) .race_unordered else .plain;
                    if (access.kind != expected_kind) return error.InvalidMemoryAccessKind;
                },
                .value => return error.InvalidPlaceType,
            }
            return;
        }
        if (mir.executableSliceIndexPlace(body, target.*) != null) {
            const root_valid = switch (target.root) {
                .local => |local_id| local: {
                    for (body.parameters) |parameter| if (parameter.local.eql(local_id)) {
                        break :local sameValueType(parameter.ty, target.root_ty) and
                            parameter.type_id.eql(target.root_type_id);
                    };
                    break :local false;
                },
                .value => mir.executableCheckedSliceValueRoot(body, target.*),
                .symbol => false,
            };
            if (!root_valid) return error.InvalidPlaceType;
            if (access.kind != .race_unordered) return error.InvalidMemoryAccessKind;
            return;
        }
        if (mir.executableAggregateFieldPlace(
            body.locals,
            body.statements,
            body.aggregate_types,
            target.*,
            is_store,
        )) {
            const expected_kind: mir.ExecutableMemoryAccessKind = switch (target.root) {
                .local => .plain,
                .symbol => |id| global: {
                    const identity = symbol(body, id) orelse return error.InvalidSymbolReference;
                    if (identity.kind != .global or (is_store and !identity.mutable)) return error.InvalidMemoryAccessType;
                    break :global if (identity.mutable) .race_unordered else .plain;
                },
                .value => return error.InvalidPlaceType,
            };
            if (access.kind != expected_kind) return error.InvalidMemoryAccessKind;
            return;
        }
        if (!isScalarAccessPlace(body, target.*, is_store) and
            !(aggregate_copy and (mir.executableGuardedLocalAggregateDerefPlace(body, target.*, is_store) or
                mir.executableParameterProjectedPlace(body, target.*, is_store))))
            return error.InvalidPlaceType;
        const expected_kind = mir.executablePointerDerefAccessKind(body, target.*) orelse return error.InvalidPlaceType;
        if (access.kind != expected_kind) return error.InvalidMemoryAccessKind;
        return;
    }
    switch (target.root) {
        .local => {
            if (access.kind != .plain) return error.InvalidMemoryAccessKind;
        },
        .symbol => |id| {
            const identity = symbol(body, id) orelse return error.InvalidSymbolReference;
            if (identity.kind != .global) return error.InvalidGlobalSymbol;
            if (is_store and !identity.mutable) return error.ImmutableGlobalStore;
            const expected_kind: mir.ExecutableMemoryAccessKind = if (mir.executableAggregateRequiresPlainAccess(
                body,
                target.type_id,
                target.ty,
            )) .plain else if (identity.mutable) .race_unordered else .plain;
            if (access.kind != expected_kind) return error.InvalidMemoryAccessKind;
        },
        .value => return error.InvalidPlaceType,
    }
}

fn verifyCompletePlace(body: *const mir.ExecutableBody, target: mir.ExecutablePlace) !void {
    if (target.root_nonnull_proven) {
        if (target.root != .local or target.projection_count == 0 or target.projections[0] != .deref or
            !mir.executableLocalInitializedByOptionalPresentPayload(body, target.root.local))
            return error.InvalidPlaceType;
        switch (target.root_ty) {
            .pointer => |shape| if (shape.kind != .single) return error.InvalidPlaceType,
            else => return error.InvalidPlaceType,
        }
    }
    if (target.pointer_provenance != .unknown) {
        if (target.root != .local or target.projection_count == 0 or target.projections[0] != .deref)
            return error.InvalidPlaceType;
        switch (target.root_ty) {
            .pointer => {},
            else => return error.InvalidPlaceType,
        }
    }
    if (target.storage == .atomic) {
        if (!atomicPlaceSupported(body, target)) return error.InvalidAtomicLoad;
        return;
    }
    if (target.projection_count == 0 or mir.executableAggregateCopyAlignment(target.ty) != null) return;
    if (mir.executableFixedArrayIndexPlace(body, target) != null) return;
    if (mir.executableSliceIndexPlace(body, target) != null) return;
    if (!isScalarAccessPlace(body, target, false)) return error.InvalidPlaceType;
}

fn addressResultMatchesPlace(result_ty: mir.ValueType, place_ty: mir.ValueType) bool {
    const shape = switch (result_ty) {
        .pointer => |value| value,
        else => return false,
    };
    return shape.kind == .single and std.mem.eql(u8, shape.child, place_ty.name());
}

fn directAddressablePlace(body: *const mir.ExecutableBody, target: mir.ExecutablePlace) bool {
    if (target.storage != .ordinary or target.projection_count != 0 or !sameValueType(target.root_ty, target.ty)) return false;
    return switch (target.root) {
        .local => |id| local: {
            for (body.parameters) |parameter| if (parameter.local.eql(id)) break :local true;
            for (body.statements) |current_statement| switch (current_statement.operation) {
                .local_init => |value| if (value.local.eql(id)) break :local true,
                else => {},
            };
            break :local false;
        },
        .symbol => |id| if (symbol(body, id)) |identity| identity.kind == .global else false,
        .value => false,
    };
}

fn isComputedRawManyDerefPlace(body: *const mir.ExecutableBody, target: mir.ExecutablePlace, require_mutable: bool) bool {
    if (target.storage != .ordinary or target.projection_count != 1 or target.projections[0] != .deref or
        !target.root_type_id.isValid() or !target.type_id.isValid() or
        mir.executableStorageAlignment(body.enum_types, target.ty) == null) return false;
    const root_id = switch (target.root) {
        .value => |id| id,
        .local, .symbol => return false,
    };
    const root = expression(body, root_id) orelse return false;
    if (!root.type_id.eql(target.root_type_id) or !sameValueType(root.result_ty, target.root_ty)) return false;
    const call = switch (root.operation) {
        .builtin_call => |value| value,
        else => return false,
    };
    if (call.kind != .raw_many_offset) return false;
    const pointer = switch (root.result_ty) {
        .pointer => |shape| shape,
        else => return false,
    };
    return pointer.kind == .raw_many and (!require_mutable or pointer.mutability == .mut) and
        std.mem.eql(u8, pointer.child, target.ty.name());
}

fn isScalarAccessPlace(body: *const mir.ExecutableBody, target: mir.ExecutablePlace, require_mutable: bool) bool {
    return mir.executableAggregateFieldPlace(
        body.locals,
        body.statements,
        body.aggregate_types,
        target,
        require_mutable,
    ) or mir.executableAggregatePointerFieldDerefPlace(body, target, require_mutable) != null or
        isParameterScalarAccessPlace(body, target, require_mutable) or
        mir.executableLocalAddressDerefPlace(body, target, require_mutable) or
        mir.executableGuardedLocalScalarDerefPlace(body, target, require_mutable) or
        mir.executableGlobalPointerDerefPlace(body, target, require_mutable) or
        isComputedRawManyDerefPlace(body, target, require_mutable);
}

fn placeNeedsRepresentationGuard(body: *const mir.ExecutableBody, target: mir.ExecutablePlace) bool {
    if (target.projection_count == 0) return false;
    if (target.root_nonnull_proven) return false;
    if (mir.executableAggregatePointerFieldDerefPlace(body, target, false) != null) return true;
    return switch (target.root_ty) {
        .pointer => |shape| shape.kind == .single,
        .nullable_pointer => true,
        else => false,
    };
}

fn isSingleParameterDerefPlace(body: *const mir.ExecutableBody, target: mir.ExecutablePlace, require_mutable: bool) bool {
    if (target.projection_count != 1) return false;
    switch (target.projections[0]) {
        .deref => {},
        else => return false,
    }
    const local_id = switch (target.root) {
        .local => |id| id,
        .symbol, .value => return false,
    };
    var parameter_ty: ?mir.ValueType = null;
    for (body.parameters) |parameter| if (parameter.local.eql(local_id)) {
        parameter_ty = parameter.ty;
        break;
    };
    const root_ty = parameter_ty orelse return false;
    if (!sameValueType(root_ty, target.root_ty) or mir.executableMemoryAlignment(body.enum_types, target.ty) == null) return false;
    const shape = switch (root_ty) {
        .pointer => |value| value,
        else => return false,
    };
    if (shape.kind != .single or (require_mutable and shape.mutability != .mut)) return false;
    return mir.executableAggregateCopyAlignment(target.ty) != null or
        std.mem.eql(u8, shape.child, target.ty.name());
}

fn isParameterScalarAccessPlace(body: *const mir.ExecutableBody, target: mir.ExecutablePlace, require_mutable: bool) bool {
    if (target.storage != .ordinary) return false;
    if (target.projection_count == 1) return isSingleParameterDerefPlace(body, target, require_mutable);
    return mir.executableStorageAlignment(body.enum_types, target.ty) != null and
        mir.executableParameterProjectedPlace(body, target, require_mutable);
}

fn atomicPlaceSupported(body: *const mir.ExecutableBody, target: mir.ExecutablePlace) bool {
    if (target.storage != .atomic or !target.root_type_id.isValid() or !target.type_id.isValid() or
        !atomicPayloadSupported(target.ty)) return false;
    if (target.projection_count == 0) return mir.executableDirectAtomicParameterPlace(body.parameters, target) or switch (target.root) {
        .local => |id| local_storage: {
            for (body.statements) |statement_value| switch (statement_value.operation) {
                .local_init => |init| if (init.local.eql(id)) {
                    break :local_storage sameValueType(init.ty, target.ty) and init.type_id.eql(target.type_id);
                },
                else => {},
            };
            break :local_storage false;
        },
        .symbol => |id| if (symbol(body, id)) |identity|
            identity.kind == .global and identity.atomic_payload_type_id.eql(target.type_id)
        else
            false,
        .value => false,
    };
    if (target.projection_count != 0) {
        var ordinary = target;
        ordinary.storage = .ordinary;
        if (isScalarAccessPlace(body, ordinary, false)) return true;
    }
    if (target.projection_count != 1 or target.projections[0] != .deref) return false;
    const local_id = switch (target.root) {
        .local => |id| id,
        .symbol, .value => return false,
    };
    var parameter: ?mir.ExecutableParameter = null;
    for (body.parameters) |candidate| if (candidate.local.eql(local_id)) {
        parameter = candidate;
        break;
    };
    const root = parameter orelse return false;
    if (!root.type_id.eql(target.root_type_id) or !root.atomic_payload_type_id.eql(target.type_id) or
        !sameValueType(root.ty, target.root_ty)) return false;
    const pointer = switch (root.ty) {
        .pointer => |shape| shape,
        else => return false,
    };
    if (pointer.kind != .single) return false;
    return true;
}

fn atomicPayloadSupported(ty: mir.ValueType) bool {
    return switch (ty) {
        .bool => true,
        .integer => mir.ExecutableMemoryAccess.scalarAlignment(ty) != null,
        else => false,
    };
}

fn mmioStorageSupported(ty: mir.ValueType) bool {
    return switch (ty) {
        .integer => |name| std.mem.eql(u8, name, "u8") or std.mem.eql(u8, name, "u16") or
            std.mem.eql(u8, name, "u32") or std.mem.eql(u8, name, "u64"),
        else => false,
    };
}

fn mmioReadResultSupported(
    body: *const mir.ExecutableBody,
    value: mir.ExecutableExpression,
    storage_ty: mir.ValueType,
    storage_type_id: mir.TypeId,
) bool {
    if (sameValueType(value.result_ty, storage_ty) and value.type_id.eql(storage_type_id)) return true;
    const aggregate = aggregateType(body, value.type_id) orelse return false;
    return aggregate.construction == .packed_bits and sameValueType(aggregate.ty, value.result_ty) and
        sameValueType(aggregate.storage_ty, storage_ty) and aggregate.storage_type_id.eql(storage_type_id);
}

fn mmioBaseSupported(body: *const mir.ExecutableBody, local_id: mir.LocalId) bool {
    return mir.executableMmioBase(body, local_id);
}

fn verifyExpr(body: *const mir.ExecutableBody, id: mir.ExprId) !void {
    if (expression(body, id) == null) return error.InvalidExpressionReference;
}

fn verifyLocal(body: *const mir.ExecutableBody, id: mir.LocalId) !void {
    if (local(body, id) == null) return error.InvalidLocalReference;
}

fn verifySymbol(body: *const mir.ExecutableBody, id: mir.SymbolId) !void {
    if (symbol(body, id) == null) return error.InvalidSymbolReference;
}

fn verifySpan(function: *const mir.Function, id: mir.SpanId, source: mir.SourcePoint) !void {
    if (!id.isValid() or id.index() >= function.span_identities.len) return error.InvalidSpanReference;
    const identity = function.span_identities[id.index()];
    if (!identity.id.eql(id) or !sameSource(identity.source, source)) return error.InvalidSpanReference;
}

fn verifySpanId(function: *const mir.Function, id: mir.SpanId) !void {
    if (!id.isValid() or id.index() >= function.span_identities.len) return error.InvalidSpanReference;
    if (!function.span_identities[id.index()].id.eql(id)) return error.InvalidSpanReference;
}

fn verifyType(function: *const mir.Function, id: mir.TypeId, ty: mir.ValueType, required: bool) !void {
    if (!id.isValid()) {
        if (required) return error.InvalidTypeReference;
        return;
    }
    if (id.index() >= function.type_identities.len) return error.InvalidTypeReference;
    const identity = function.type_identities[id.index()];
    if (!identity.id.eql(id) or !identity.matches(ty)) return error.InvalidTypeReference;
}

fn blockExists(function: *const mir.Function, id: mir.BlockId) bool {
    if (!id.isValid()) return false;
    for (function.blocks) |block| if (block.typed_id.eql(id)) return true;
    return false;
}

fn blockById(function: *const mir.Function, id: mir.BlockId) ?*const mir.Block {
    if (!id.isValid()) return null;
    for (function.blocks) |*block| if (block.typed_id.eql(id)) return block;
    return null;
}

fn sameSource(left: mir.SourcePoint, right: mir.SourcePoint) bool {
    return left.file_id == right.file_id and left.line == right.line and left.column == right.column and
        left.offset == right.offset and left.len == right.len;
}

fn sameValueType(left: mir.ValueType, right: mir.ValueType) bool {
    return mir.ValueType.eql(left, right);
}
