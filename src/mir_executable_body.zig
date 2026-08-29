//! Verification and lookup helpers for the executable body owned by MIR.
//!
//! `mir_model.ExecutableBody` is the only executable-body representation.
//! This module never reconstructs a second body from sparse instructions,
//! source coordinates, or textual instruction details.

const std = @import("std");
const mir = @import("mir_model.zig");

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
    for (body.expressions) |expression_value| switch (expression_value.operation) {
        .unsupported => return if (body.incomplete_reason == .none) "unsupported_expression" else @tagName(body.incomplete_reason),
        .deref => return "unlowered_deref",
        .range_slice => return "unlowered_range_slice",
        .member => return "unlowered_member",
        .array => return "unlowered_array",
        .literal => |literal| switch (literal) {
            .string => return "noncanonical_string_literal",
            .uninit => return "noncanonical_uninit_literal",
            .enum_value => return "noncanonical_enum_literal",
            else => {},
        },
        else => {},
    };
    for (body.statements) |statement_value| switch (statement_value.operation) {
        .unsupported => return "unsupported_statement",
        .defer_cleanup => return "defer_cleanup",
        .guard => |guard| if (guard.kind == .assert_ and
            !assertGuardHasExactTrapEdge(body, statement_value, guard)) return "assert_guard",
        else => {},
    };
    for (body.terminators) |terminator| switch (terminator.operation) {
        .switch_ => return "general_switch",
        .fallthrough => return "invalid_fallthrough",
        else => {},
    };
    if (body.trap_edges.len != function.trap_edges.len) return "trap_projection";
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
    if (!function.is_extern and body.parameters.len != function.param_count) return error.InvalidFunctionSignature;
    if (body.parameters.len == function.param_types.len) {
        for (body.parameters, function.param_types) |parameter, parameter_ty| {
            if (!sameValueType(parameter.ty, parameter_ty)) return error.InvalidFunctionSignature;
        }
    }
    if (body.complete and body.incomplete_reason != .none) return error.InvalidIncompleteReason;
    if (!body.complete and body.parameters.len == 0 and body.locals.len == 0 and body.symbols.len == 0 and
        body.aggregate_types.len == 0 and body.enum_types.len == 0 and body.result_types.len == 0 and
        body.expressions.len == 0 and body.places.len == 0 and body.statements.len == 0 and body.terminators.len == 0) return;

    try verifyType(function, body.return_type_id, function.return_ty, body.complete);
    for (body.aggregate_types, 0..) |aggregate, index| {
        try verifyAggregateType(function, aggregate, index);
    }
    for (body.enum_types, 0..) |enum_ty, index| {
        try verifyEnumType(function, enum_ty, index);
    }
    for (body.result_types, 0..) |result_ty, index| {
        try verifyResultType(function, result_ty, index);
    }
    for (body.locals, 0..) |identity, index| {
        if (!identity.id.isValid() or identity.id.index() != index) return error.InvalidLocalIdentity;
    }
    for (body.symbols, 0..) |identity, index| {
        if (!identity.id.isValid() or identity.id.index() != index) return error.InvalidSymbolIdentity;
    }
    for (body.parameters) |parameter| {
        try verifyLocal(body, parameter.local);
        try verifySpan(function, parameter.span_id, parameter.source);
        try verifyType(function, parameter.type_id, parameter.ty, body.complete);
        if (parameter.callable_signature) |signature| {
            if (parameter.ty != .value) return error.InvalidFunctionSignature;
            try verifyCallableSignature(function, signature, body.complete);
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
    if (body.complete) try verifyContractMarkers(body);

    if (body.terminators.len != function.blocks.len) return error.InvalidTerminatorIdentity;
    for (body.terminators, 0..) |terminator, index| {
        if (!terminator.block_id.eql(function.blocks[index].typed_id)) return error.InvalidTerminatorIdentity;
        try verifyTerminator(function, terminator);
    }

    if (body.complete and containsIncompleteOperation(body)) return error.InvalidCompletionClaim;
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
                if (mir.executableFixedArrayIndexPlace(body, target.*)) |projection| {
                    if (operation.representation_source != null or operation.representation_span_id.isValid())
                        return error.InvalidMemoryAccessTrap;
                    const expected_traps: usize = @intFromBool(projection.checked);
                    if (ownedTrapCountAll(body, .{ .expression = value.id }) != expected_traps or
                        (projection.checked and ownedTrapCount(body, .{ .expression = value.id }, .Bounds, .bounds_check) != 1))
                        return error.InvalidMemoryAccessTrap;
                    return;
                }
                const expected_traps: usize = if (placeNeedsRepresentationGuard(target.*)) 1 else 0;
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
                const guarded = placeNeedsRepresentationGuard(target.*);
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
                const guarded = placeNeedsRepresentationGuard(target.*);
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
                !sameValueType(value.result_ty, operation.storage_ty) or
                !value.type_id.eql(operation.storage_type_id) or
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
        .literal => |literal| switch (literal) {
            .float => |float| if (!mir.executableFloatMatchesType(float, value.result_ty)) return error.InvalidLiteral,
            .signed_integer => switch (value.result_ty) {
                .closed_enum, .open_enum, .integer => {},
                else => return error.InvalidLiteral,
            },
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
                const logical = operation.op == .logical_and or operation.op == .logical_or;
                if (logical) {
                    if (!operation.eager_safe or value.result_ty != .bool or
                        !mir.executableEagerSafeBoolTree(body.expressions, body.trap_edges, left.id) or
                        !mir.executableEagerSafeBoolTree(body.expressions, body.trap_edges, right.id) or
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
            if (operation.kind == .integer_to_open_enum) {
                var exact = false;
                for (body.enum_types) |enum_ty| {
                    if (!sameValueType(enum_ty.ty, value.result_ty)) continue;
                    exact = enum_ty.type_id.eql(value.type_id) and
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
        .address_of => |address| {
            const target = place(body, address.place) orelse return error.InvalidPlaceReference;
            if (target.storage != .ordinary) return error.InvalidPlaceType;
            if (target.root == .value) try verifyOperand(body, value, target.root.value);
            if (body.complete) {
                if (!addressResultMatchesPlace(value.result_ty, target.ty)) return error.InvalidPlaceType;
                if (target.projection_count == 0) {
                    if (!directAddressablePlace(body, target.*) or address.representation_source != null or
                        address.representation_span_id.isValid() or ownedTrapCountAll(body, .{ .expression = value.id }) != 0)
                        return error.InvalidMemoryAccessTrap;
                } else if (isComputedRawManyDerefPlace(body, target.*, false)) {
                    if (address.representation_source != null or address.representation_span_id.isValid() or
                        ownedTrapCountAll(body, .{ .expression = value.id }) != 0)
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
        .try_unwrap => |operand_id| {
            try verifyOperand(body, value, operand_id);
            const operand = expression(body, operand_id) orelse return error.InvalidExpressionReference;
            if (body.complete) {
                const shape = switch (operand.result_ty) {
                    .nullable_pointer => |pointer| pointer,
                    else => return error.InvalidAggregateConstruction,
                };
                if (!sameValueType(value.result_ty, .{ .pointer = shape }) or
                    ownedTrapCountAll(body, .{ .expression = value.id }) != 1 or
                    ownedTrapCount(body, .{ .expression = value.id }, .Unwrap, .unwrap) != 1)
                    return error.InvalidAggregateConstruction;
            }
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
            try verifyArguments(body, value, operation.operands, operation.operand_count);
            if (body.complete) try verifyArrayConstruction(function, value, operation);
        },
        .struct_ => |operation| {
            try verifyArguments(body, value, operation.operands, operation.operand_count);
            if (body.complete) try verifyStructConstruction(function, value, operation);
        },
    }
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
                            const projection = mir.executableFixedArrayIndexPlace(body, target.*) orelse return error.InvalidTrapEdge;
                            if (!projection.checked) return error.InvalidTrapEdge;
                        } else if (target.storage != .ordinary or
                            !(isParameterScalarAccessPlace(body, target.*, false) or mir.executableLocalAddressDerefPlace(body, target.*, false)) or
                            edge.kind != .InvalidRepresentation or
                            edge.source != .representation_check) return error.InvalidTrapEdge;
                    },
                    .atomic_load => |load| {
                        const target = place(body, load.place) orelse return error.InvalidTrapEdge;
                        if (!atomicPlaceSupported(body, target.*) or !placeNeedsRepresentationGuard(target.*) or
                            edge.kind != .InvalidRepresentation or edge.source != .representation_check)
                            return error.InvalidTrapEdge;
                    },
                    .atomic_update => |update| {
                        const target = place(body, update.place) orelse return error.InvalidTrapEdge;
                        if (!atomicPlaceSupported(body, target.*) or !placeNeedsRepresentationGuard(target.*) or
                            edge.kind != .InvalidRepresentation or edge.source != .representation_check)
                            return error.InvalidTrapEdge;
                    },
                    .address_of => |address| {
                        const target = place(body, address.place) orelse return error.InvalidTrapEdge;
                        if (!(isSingleParameterDerefPlace(body, target.*, false) or mir.executableLocalAddressDerefPlace(body, target.*, false)) or
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
                    .representation_check => |check| {
                        const operand = expression(body, check.operand) orelse return error.InvalidTrapEdge;
                        if (!mir.ExecutableRepresentationCheckKind.typesValid(check.kind, owner.result_ty, operand.result_ty) or
                            !owner.type_id.eql(operand.type_id) or edge.kind != .InvalidRepresentation or
                            edge.source != .representation_check) return error.InvalidTrapEdge;
                    },
                    .try_unwrap => |operand_id| {
                        const operand = expression(body, operand_id) orelse return error.InvalidTrapEdge;
                        if (operand.result_ty != .nullable_pointer or edge.kind != .Unwrap or edge.source != .unwrap)
                            return error.InvalidTrapEdge;
                    },
                    .index => |operation| {
                        if (!operation.checked or edge.kind != .Bounds or edge.source != .bounds_check)
                            return error.InvalidTrapEdge;
                    },
                    else => return error.InvalidTrapEdge,
                }
                const span_id = switch (owner.operation) {
                    .load => |load| if (edge.kind == .Bounds and edge.source == .bounds_check) bounds: {
                        const target = place(body, load.place) orelse return error.InvalidTrapEdge;
                        const projection = mir.executableFixedArrayIndexPlace(body, target.*) orelse return error.InvalidTrapEdge;
                        if (!projection.checked) return error.InvalidTrapEdge;
                        break :bounds projection.span_id;
                    } else load.representation_span_id,
                    .atomic_load => |load| load.representation_span_id,
                    .atomic_update => |update| update.representation_span_id,
                    .address_of => |address| address.representation_span_id,
                    .builtin_call => |call| if (call.kind == .raw_ptr) call.representation_span_id else owner.span_id,
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
                            const projection = mir.executableFixedArrayIndexPlace(body, target.*) orelse return error.InvalidTrapEdge;
                            if (!projection.checked) return error.InvalidTrapEdge;
                            break :statement_owner .{ .block_id = owner.block_id, .span_id = projection.span_id };
                        }
                        if (!(isParameterScalarAccessPlace(body, target.*, true) or mir.executableLocalAddressDerefPlace(body, target.*, true)) or
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
        if (!owner_info.block_id.eql(edge.from_block)) return error.InvalidTrapEdge;
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
                previous.kind == edge.kind and previous.source == edge.source) return error.InvalidTrapEdge;
        }
    }
    if (body.complete) {
        var terminal_projections: usize = 0;
        for (function.trap_edges) |legacy| {
            var matches: usize = 0;
            for (body.trap_edges) |edge| {
                if (legacy.from_block == edge.from_block.index() and legacy.trap_block == edge.trap_block.index() and
                    legacy.kind == edge.kind and legacy.source == edge.source) matches += 1;
            }
            if (matches == 0 and terminalTrapProjectionMatches(function, legacy)) {
                terminal_projections += 1;
                continue;
            }
            if (matches != 1) return error.InvalidCompletionClaim;
        }
        if (body.trap_edges.len + terminal_projections != function.trap_edges.len) return error.InvalidCompletionClaim;
    }
}

fn terminalTrapProjectionMatches(function: *const mir.Function, legacy: mir.TrapEdge) bool {
    const body = &function.executable_body;
    const source = executableTerminator(body, mir.BlockId.fromIndex(legacy.from_block)) orelse return false;
    const target = executableTerminator(body, mir.BlockId.fromIndex(legacy.trap_block)) orelse return false;
    const destination = switch (source.operation) {
        .jump => |block| block,
        .switch_ => |switch_| switch_.default_block,
        else => return false,
    };
    if (!destination.eql(mir.BlockId.fromIndex(legacy.trap_block))) return false;
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
                if (target.root.value.index() >= operation.value.index()) return error.InvalidEvaluationOrder;
            }
            try verifyType(function, operation.type_id, operation.ty, body.complete);
            if (body.complete) {
                try verifyMemoryAccess(function, operation.place, operation.ty, operation.access, true);
                const guarded = placeNeedsRepresentationGuard(target.*);
                const indexed = mir.executableFixedArrayIndexPlace(body, target.*);
                const checked_index = indexed != null and indexed.?.checked;
                const expected_traps = @as(usize, @intFromBool(guarded)) + @as(usize, @intFromBool(checked_index));
                if (guarded) {
                    const source = operation.representation_source orelse return error.InvalidMemoryAccessTrap;
                    try verifySpan(function, operation.representation_span_id, source);
                    if (ownedTrapCount(body, .{ .statement = statement_value.id }, .InvalidRepresentation, .representation_check) != 1)
                        return error.InvalidMemoryAccessTrap;
                } else if (operation.representation_source != null or operation.representation_span_id.isValid()) {
                    return error.InvalidMemoryAccessTrap;
                }
                if (checked_index and ownedTrapCount(body, .{ .statement = statement_value.id }, .Bounds, .bounds_check) != 1)
                    return error.InvalidMemoryAccessTrap;
                if (ownedTrapCountAll(body, .{ .statement = statement_value.id }) != expected_traps)
                    return error.InvalidMemoryAccessTrap;
            }
            for (target.projections[0..target.projection_count]) |projection| switch (projection) {
                .index => |index| try verifyStatementExpr(body, statement_value, index.value),
                .field, .deref => {},
            };
            try verifyStatementExpr(body, statement_value, operation.value);
            const stored = expression(body, operation.value) orelse return error.InvalidExpressionReference;
            if (body.complete and !sameValueType(stored.result_ty, operation.ty)) return error.InvalidStoreType;
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
        .contract_marker => |marker| if (marker.name.len == 0) return error.InvalidContractMarker,
        .control_transfer, .defer_cleanup, .unsupported => {},
    }
}

fn verifyContractMarkers(body: *const mir.ExecutableBody) !void {
    var names: [64][]const u8 = undefined;
    var blocks: [64]mir.BlockId = undefined;
    var depth: usize = 0;
    for (body.statements) |statement_value| switch (statement_value.operation) {
        .contract_marker => |marker| switch (marker.kind) {
            .begin => {
                if (marker.name.len == 0 or depth == names.len) return error.InvalidContractMarker;
                names[depth] = marker.name;
                blocks[depth] = statement_value.block_id;
                depth += 1;
            },
            .end => {
                if (depth == 0) return error.InvalidContractMarker;
                depth -= 1;
                if (!blocks[depth].eql(statement_value.block_id) or !std.mem.eql(u8, names[depth], marker.name))
                    return error.InvalidContractMarker;
            },
        },
        else => {},
    };
    // A lexical contract whose body terminates has no reachable point at
    // which to emit an end marker. Its CFG terminator closes the remaining
    // marker stack for that block.
    while (depth != 0) {
        depth -= 1;
        const terminator = executableTerminator(body, blocks[depth]) orelse return error.InvalidContractMarker;
        switch (terminator.operation) {
            .return_, .trap_, .unreachable_ => {},
            else => return error.InvalidContractMarker,
        }
    }
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
            if (!callableSignaturesEqual(declared, call.signature)) return error.InvalidFunctionSignature;
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

fn callableSignaturesEqual(a: mir.ExecutableCallSignature, b: mir.ExecutableCallSignature) bool {
    if (a.parameter_count != b.parameter_count or
        !sameValueType(a.return_ty, b.return_ty) or
        !a.return_type_id.eql(b.return_type_id)) return false;
    for (a.parameter_types[0..a.parameter_count], b.parameter_types[0..b.parameter_count]) |a_ty, b_ty|
        if (!sameValueType(a_ty, b_ty)) return false;
    for (a.parameter_type_ids[0..a.parameter_count], b.parameter_type_ids[0..b.parameter_count]) |a_id, b_id|
        if (!a_id.eql(b_id)) return false;
    return true;
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

fn verifyStatementExpr(body: *const mir.ExecutableBody, owner: mir.ExecutableStatement, id: mir.ExprId) !void {
    const value = expression(body, id) orelse return error.InvalidExpressionReference;
    if (!value.owner_statement.eql(owner.id) or !value.block_id.eql(owner.block_id)) return error.InvalidEvaluationOrder;
}

fn containsIncompleteOperation(body: *const mir.ExecutableBody) bool {
    for (body.expressions) |value| switch (value.operation) {
        .unsupported, .deref, .range_slice => return true,
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
            .uninit, .enum_value => return true,
            else => {},
        },
        else => {},
    };
    for (body.places) |value| {
        if (value.storage == .atomic) {
            if (!atomicPlaceSupported(body, value)) return true;
        } else if (value.projection_count != 0 and !isScalarAccessPlace(body, value, false) and
            mir.executableFixedArrayIndexPlace(body, value) == null) return true;
    }
    for (body.statements) |value| switch (value.operation) {
        .unsupported, .defer_cleanup => return true,
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
        (aggregate.construction != .declared_struct and aggregate.construction != .c_union)) return error.InvalidAggregateType;
    try verifyType(function, aggregate.type_id, aggregate.ty, body.complete);
    if (aggregate.ty != .array and aggregate.ty != .struct_ and aggregate.ty != .nullable_value) return error.InvalidAggregateType;
    if (aggregate.ty == .array and aggregate.construction != .declared_struct) return error.InvalidAggregateType;
    if (aggregate.ty == .nullable_value and (aggregate.construction != .declared_struct or aggregate.field_count != 2 or
        !sameValueType(aggregate.field_types[0], .bool))) return error.InvalidAggregateType;
    for (body.aggregate_types[0..index]) |previous| if (previous.type_id.eql(aggregate.type_id)) return error.InvalidAggregateType;
    for (aggregate.field_types[0..aggregate.field_count], aggregate.field_type_ids[0..aggregate.field_count], aggregate.field_callable_signatures[0..aggregate.field_count]) |field_ty, field_type_id, callable_signature| {
        if (field_ty == .unknown or (field_ty == .value) != (callable_signature != null)) return error.InvalidAggregateType;
        try verifyType(function, field_type_id, field_ty, body.complete);
        if (callable_signature) |signature| try verifyCallableSignature(function, signature, body.complete);
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
    for (aggregate.field_spellings[aggregate.field_count..], aggregate.field_types[aggregate.field_count..], aggregate.field_type_ids[aggregate.field_count..], aggregate.field_callable_signatures[aggregate.field_count..]) |field_spelling, field_ty, field_type_id, callable_signature| {
        if (field_spelling.len != 0 or field_ty != .unknown or field_type_id.isValid() or callable_signature != null)
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
    for (body.enum_types[0..index]) |previous| {
        if (previous.type_id.eql(enum_ty.type_id) or sameValueType(previous.ty, enum_ty.ty)) return error.InvalidEnumType;
    }
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

fn verifyStructConstruction(
    function: *const mir.Function,
    value: mir.ExecutableExpression,
    operation: @FieldType(mir.ExecutableExpression.Operation, "struct_"),
) !void {
    const body = &function.executable_body;
    const aggregate = aggregateType(body, value.type_id) orelse return error.InvalidAggregateConstruction;
    if (aggregate.construction != .declared_struct or operation.construction != .declared_struct or
        !sameValueType(aggregate.ty, value.result_ty) or
        operation.operand_count != aggregate.field_count) return error.InvalidAggregateConstruction;
    var seen = [_]bool{false} ** mir.max_executable_operands;
    for (operation.operands[0..operation.operand_count], operation.field_indices[0..operation.operand_count]) |operand_id, field_index| {
        if (field_index >= aggregate.field_count or seen[field_index]) return error.InvalidAggregateConstruction;
        seen[field_index] = true;
        const operand = expression(body, operand_id) orelse return error.InvalidExpressionReference;
        if (!sameValueType(operand.result_ty, aggregate.field_types[field_index]) or !operand.type_id.eql(aggregate.field_type_ids[field_index]))
            return error.InvalidAggregateConstruction;
    }
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
        operation.operand_count == 0 or aggregate.array_length == null or
        operation.operand_count != aggregate.array_length.? or operation.operand_count != aggregate.field_count)
        return error.InvalidAggregateConstruction;
    for (operation.operands[0..operation.operand_count], 0..) |operand_id, index| {
        const operand = expression(body, operand_id) orelse return error.InvalidExpressionReference;
        if (!sameValueType(operand.result_ty, aggregate.field_types[index]) or
            !operand.type_id.eql(aggregate.field_type_ids[index])) return error.InvalidAggregateConstruction;
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
    const expected_alignment = mir.ExecutableMemoryAccess.scalarAlignment(ty) orelse aggregate_local: {
        if (target.projection_count != 0 or access.kind != .plain) return error.InvalidMemoryAccessType;
        switch (target.root) {
            .local => {},
            .symbol, .value => return error.InvalidMemoryAccessType,
        }
        switch (ty) {
            .array, .struct_, .nullable_value => break :aggregate_local 1,
            else => return error.InvalidMemoryAccessType,
        }
    };
    if (access.alignment != expected_alignment) return error.InvalidMemoryAccessAlignment;
    if (target.projection_count != 0) {
        if (mir.executableFixedArrayIndexPlace(body, target.*) != null) {
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
        if (mir.executableDirectAggregateFieldPlace(
            body.locals,
            body.statements,
            body.aggregate_types,
            target.*,
            is_store,
        ) != null) {
            if (access.kind != .plain) return error.InvalidMemoryAccessKind;
            return;
        }
        if (!isScalarAccessPlace(body, target.*, is_store)) return error.InvalidPlaceType;
        const expected_kind: mir.ExecutableMemoryAccessKind =
            if (mir.executableLocalAddressDerefPlace(body, target.*, false)) .plain else .race_unordered;
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
            const expected_kind: mir.ExecutableMemoryAccessKind = if (identity.mutable) .race_unordered else .plain;
            if (access.kind != expected_kind) return error.InvalidMemoryAccessKind;
        },
        .value => return error.InvalidPlaceType,
    }
}

fn verifyCompletePlace(body: *const mir.ExecutableBody, target: mir.ExecutablePlace) !void {
    if (target.storage == .atomic) {
        if (!atomicPlaceSupported(body, target)) return error.InvalidAtomicLoad;
        return;
    }
    if (target.projection_count == 0) return;
    if (mir.executableFixedArrayIndexPlace(body, target) != null) return;
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
            for (body.parameters) |parameter| if (parameter.local.eql(id)) break :local false;
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
        mir.ExecutableMemoryAccess.scalarAlignment(target.ty) == null) return false;
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
    return mir.executableDirectAggregateFieldPlace(
        body.locals,
        body.statements,
        body.aggregate_types,
        target,
        require_mutable,
    ) != null or isParameterScalarAccessPlace(body, target, require_mutable) or
        mir.executableLocalAddressDerefPlace(body, target, require_mutable) or
        isComputedRawManyDerefPlace(body, target, require_mutable);
}

fn placeNeedsRepresentationGuard(target: mir.ExecutablePlace) bool {
    if (target.projection_count == 0) return false;
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
    if (!sameValueType(root_ty, target.root_ty) or mir.ExecutableMemoryAccess.scalarAlignment(target.ty) == null) return false;
    const shape = switch (root_ty) {
        .pointer => |value| value,
        else => return false,
    };
    if (shape.kind != .single or (require_mutable and shape.mutability != .mut)) return false;
    return std.mem.eql(u8, shape.child, target.ty.name());
}

fn isParameterScalarAccessPlace(body: *const mir.ExecutableBody, target: mir.ExecutablePlace, require_mutable: bool) bool {
    if (target.storage != .ordinary) return false;
    if (target.projection_count == 1) return isSingleParameterDerefPlace(body, target, require_mutable);
    if (target.projection_count != 2 or !target.root_type_id.isValid() or !target.type_id.isValid()) return false;
    switch (target.projections[0]) {
        .deref => {},
        .field, .index => return false,
    }
    const field_index = switch (target.projections[1]) {
        .field => |index| index,
        .deref, .index => return false,
    };
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
    if (!root.type_id.eql(target.root_type_id) or !sameValueType(root.ty, target.root_ty) or
        mir.ExecutableMemoryAccess.scalarAlignment(target.ty) == null) return false;
    const pointer = switch (target.root_ty) {
        .pointer => |shape| shape,
        else => return false,
    };
    if (pointer.kind != .single or (require_mutable and pointer.mutability != .mut)) return false;
    var pointee: ?*const mir.ExecutableAggregateType = null;
    for (body.aggregate_types) |*aggregate| if (sameValueType(aggregate.ty, .{ .struct_ = pointer.child })) {
        pointee = aggregate;
        break;
    };
    const aggregate = pointee orelse return false;
    return (aggregate.construction == .declared_struct or aggregate.construction == .c_union) and field_index < aggregate.field_count and
        aggregate.field_type_ids[field_index].eql(target.type_id) and
        sameValueType(aggregate.field_types[field_index], target.ty);
}

fn atomicPlaceSupported(body: *const mir.ExecutableBody, target: mir.ExecutablePlace) bool {
    if (target.storage != .atomic or !target.root_type_id.isValid() or !target.type_id.isValid() or
        !atomicPayloadSupported(target.ty)) return false;
    if (target.projection_count == 0) return switch (target.root) {
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
    if (target.projection_count != 1 or target.projections[0] != .deref)
        return false;
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

fn mmioBaseSupported(body: *const mir.ExecutableBody, local_id: mir.LocalId) bool {
    for (body.parameters) |parameter| {
        if (!parameter.local.eql(local_id)) continue;
        return switch (parameter.ty) {
            .address => |class| class == .mmio_ptr and parameter.type_id.isValid(),
            else => false,
        };
    }
    return false;
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
