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
        .index => return "unlowered_index",
        .range_slice => return "unlowered_range_slice",
        .member => return "unlowered_member",
        .array => return "unlowered_array",
        .literal => |literal| switch (literal) {
            .string, .uninit, .enum_value => return "noncanonical_literal",
            else => {},
        },
        else => {},
    };
    for (body.statements) |statement_value| switch (statement_value.operation) {
        .unsupported => return "unsupported_statement",
        .defer_cleanup => return "defer_cleanup",
        .guard => |guard| if (guard.kind == .assert_) return "assert_guard",
        else => {},
    };
    for (body.terminators) |terminator| switch (terminator.operation) {
        .switch_ => return "general_switch",
        .fallthrough => return "invalid_fallthrough",
        else => {},
    };
    if (body.trap_edges.len != function.trap_edges.len) return "trap_projection";
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

pub fn verify(function: *const mir.Function) !void {
    const body = &function.executable_body;
    if (body.complete and body.incomplete_reason != .none) return error.InvalidIncompleteReason;
    if (!body.complete and body.parameters.len == 0 and body.locals.len == 0 and body.symbols.len == 0 and
        body.expressions.len == 0 and body.places.len == 0 and body.statements.len == 0 and body.terminators.len == 0) return;

    try verifyType(function, body.return_type_id, function.return_ty, body.complete);
    for (body.aggregate_types, 0..) |aggregate, index| {
        try verifyAggregateType(function, aggregate, index);
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
        }
        for (value.projections[0..value.projection_count]) |projection| switch (projection) {
            .index => |id| try verifyExpr(body, id),
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

    if (body.complete and containsIncompleteOperation(body)) return error.InvalidCompletionClaim;
}

fn verifyExpression(function: *const mir.Function, value: mir.ExecutableExpression) !void {
    const body = &function.executable_body;
    switch (value.operation) {
        .local => |id| try verifyLocal(body, id),
        .symbol => |id| try verifySymbol(body, id),
        .load => |operation| {
            if (body.complete) {
                try verifyMemoryAccess(function, operation.place, value.result_ty, operation.access, false);
                const target = place(body, operation.place) orelse return error.InvalidPlaceReference;
                const expected_traps: usize = if (target.projection_count != 0) 1 else 0;
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
        .literal => |literal| switch (literal) {
            .float => |float| if (!mir.executableFloatMatchesType(float, value.result_ty)) return error.InvalidLiteral,
            else => {},
        },
        .unsupported => {},
        .unary => |operation| try verifyOperand(body, value, operation.operand),
        .binary => |operation| {
            try verifyOperand(body, value, operation.left);
            try verifyOperand(body, value, operation.right);
            const left = expression(body, operation.left) orelse return error.InvalidExpressionReference;
            const right = expression(body, operation.right) orelse return error.InvalidExpressionReference;
            // Incomplete bodies are descriptive migration data and may still
            // contain source-shaped operations that a legacy lowering path
            // owns.  Exact executable arithmetic invariants become mandatory
            // only when the producer claims this body is complete.
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
            if (body.complete and !mir.executableBuiltinTypesValid(call.kind, value.result_ty, operand_types[0..call.argument_count])) return error.InvalidBuiltinCall;
        },
        .indirect_call => |call| {
            try verifyOperand(body, value, call.callee);
            try verifyArguments(body, value, call.arguments, call.argument_count);
        },
        .address_of => |address| {
            const target = place(body, address.place) orelse return error.InvalidPlaceReference;
            if (body.complete) {
                if (!addressResultMatchesPlace(value.result_ty, target.ty)) return error.InvalidPlaceType;
                if (target.projection_count == 0) {
                    if (!directAddressablePlace(body, target.*) or address.representation_source != null or
                        address.representation_span_id.isValid() or ownedTrapCountAll(body, .{ .expression = value.id }) != 0)
                        return error.InvalidMemoryAccessTrap;
                } else {
                    if (!isSingleParameterDerefPlace(body, target.*, false) or !sameValueType(value.result_ty, target.root_ty)) return error.InvalidPlaceType;
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
        .array => |operation| try verifyArguments(body, value, operation.operands, operation.operand_count),
        .struct_ => |operation| {
            try verifyArguments(body, value, operation.operands, operation.operand_count);
            if (body.complete) try verifyStructConstruction(function, value, operation);
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
                    .binary => |binary| if (binary.arithmetic != .checked) return error.InvalidTrapEdge,
                    .load => |load| {
                        const target = place(body, load.place) orelse return error.InvalidTrapEdge;
                        if (!isParameterScalarAccessPlace(body, target.*, false) or edge.kind != .InvalidRepresentation or
                            edge.source != .representation_check) return error.InvalidTrapEdge;
                    },
                    .address_of => |address| {
                        const target = place(body, address.place) orelse return error.InvalidTrapEdge;
                        if (!isSingleParameterDerefPlace(body, target.*, false) or edge.kind != .InvalidRepresentation or
                            edge.source != .representation_check) return error.InvalidTrapEdge;
                    },
                    else => return error.InvalidTrapEdge,
                }
                const span_id = switch (owner.operation) {
                    .load => |load| load.representation_span_id,
                    .address_of => |address| address.representation_span_id,
                    else => owner.span_id,
                };
                break :expression_owner .{ .block_id = owner.block_id, .span_id = span_id };
            },
            .statement => |id| statement_owner: {
                const owner = statement(body, id) orelse return error.InvalidTrapEdge;
                const store = switch (owner.operation) {
                    .store => |value| value,
                    else => return error.InvalidTrapEdge,
                };
                const target = place(body, store.place) orelse return error.InvalidTrapEdge;
                if (!isParameterScalarAccessPlace(body, target.*, true) or edge.kind != .InvalidRepresentation or
                    edge.source != .representation_check) return error.InvalidTrapEdge;
                break :statement_owner .{ .block_id = owner.block_id, .span_id = store.representation_span_id };
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
        if (body.trap_edges.len != function.trap_edges.len) return error.InvalidCompletionClaim;
        for (function.trap_edges) |legacy| {
            var matches: usize = 0;
            for (body.trap_edges) |edge| {
                if (legacy.from_block == edge.from_block.index() and legacy.trap_block == edge.trap_block.index() and
                    legacy.kind == edge.kind and legacy.source == edge.source) matches += 1;
            }
            if (matches != 1) return error.InvalidCompletionClaim;
        }
    }
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
            try verifyType(function, operation.type_id, operation.ty, body.complete);
            if (body.complete) {
                try verifyMemoryAccess(function, operation.place, operation.ty, operation.access, true);
                const projected = target.projection_count != 0;
                if (projected) {
                    const source = operation.representation_source orelse return error.InvalidMemoryAccessTrap;
                    try verifySpan(function, operation.representation_span_id, source);
                    if (ownedTrapCountAll(body, .{ .statement = statement_value.id }) != 1 or
                        ownedTrapCount(body, .{ .statement = statement_value.id }, .InvalidRepresentation, .representation_check) != 1)
                        return error.InvalidMemoryAccessTrap;
                } else if (operation.representation_source != null or operation.representation_span_id.isValid() or
                    ownedTrapCountAll(body, .{ .statement = statement_value.id }) != 0)
                {
                    return error.InvalidMemoryAccessTrap;
                }
            }
            for (target.projections[0..target.projection_count]) |projection| switch (projection) {
                .index => |id| try verifyStatementExpr(body, statement_value, id),
                .field, .deref => {},
            };
            try verifyStatementExpr(body, statement_value, operation.value);
            const stored = expression(body, operation.value) orelse return error.InvalidExpressionReference;
            if (body.complete and !sameValueType(stored.result_ty, operation.ty)) return error.InvalidStoreType;
        },
        .eval => |id| try verifyStatementExpr(body, statement_value, id),
        .guard => |operation| try verifyStatementExpr(body, statement_value, operation.condition),
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
        .control_transfer, .defer_cleanup, .unsupported => {},
    }
}

fn verifyTerminator(function: *const mir.Function, terminator: mir.ExecutableTerminator) !void {
    const body = &function.executable_body;
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

fn verifyStatementExpr(body: *const mir.ExecutableBody, owner: mir.ExecutableStatement, id: mir.ExprId) !void {
    const value = expression(body, id) orelse return error.InvalidExpressionReference;
    if (!value.owner_statement.eql(owner.id) or !value.block_id.eql(owner.block_id)) return error.InvalidEvaluationOrder;
}

fn containsIncompleteOperation(body: *const mir.ExecutableBody) bool {
    for (body.expressions) |value| switch (value.operation) {
        .unsupported, .deref, .index, .range_slice, .array => return true,
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
    for (body.places) |value| if (value.projection_count != 0 and !isParameterScalarAccessPlace(body, value, false)) return true;
    for (body.statements) |value| switch (value.operation) {
        .unsupported, .defer_cleanup => return true,
        else => {},
    };
    for (body.terminators) |value| switch (value.operation) {
        .switch_ => return true,
        else => {},
    };
    return false;
}

fn verifyAggregateType(function: *const mir.Function, aggregate: mir.ExecutableAggregateType, index: usize) !void {
    const body = &function.executable_body;
    if (!aggregate.type_id.isValid() or aggregate.field_count == 0 or aggregate.field_count > mir.max_executable_operands or
        aggregate.construction != .declared_struct) return error.InvalidAggregateType;
    try verifyType(function, aggregate.type_id, aggregate.ty, body.complete);
    if (aggregate.ty != .struct_) return error.InvalidAggregateType;
    for (body.aggregate_types[0..index]) |previous| if (previous.type_id.eql(aggregate.type_id)) return error.InvalidAggregateType;
    for (aggregate.field_types[0..aggregate.field_count], aggregate.field_type_ids[0..aggregate.field_count]) |field_ty, field_type_id| {
        if (field_ty == .unknown or field_ty == .value) return error.InvalidAggregateType;
        try verifyType(function, field_type_id, field_ty, body.complete);
    }
    for (aggregate.field_spellings[aggregate.field_count..], aggregate.field_types[aggregate.field_count..], aggregate.field_type_ids[aggregate.field_count..]) |field_spelling, field_ty, field_type_id| {
        if (field_spelling.len != 0 or field_ty != .unknown or field_type_id.isValid()) return error.InvalidAggregateType;
    }
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

fn verifyStructConstruction(
    function: *const mir.Function,
    value: mir.ExecutableExpression,
    operation: @FieldType(mir.ExecutableExpression.Operation, "struct_"),
) !void {
    const body = &function.executable_body;
    const aggregate = aggregateType(body, value.type_id) orelse return error.InvalidAggregateConstruction;
    if (!sameValueType(aggregate.ty, value.result_ty) or operation.construction != aggregate.construction or
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

pub fn aggregateType(body: *const mir.ExecutableBody, type_id: mir.TypeId) ?*const mir.ExecutableAggregateType {
    if (!type_id.isValid()) return null;
    for (body.aggregate_types) |*aggregate| if (aggregate.type_id.eql(type_id)) return aggregate;
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
    if (!sameValueType(target.ty, ty)) return error.InvalidPlaceType;
    const expected_alignment = mir.ExecutableMemoryAccess.scalarAlignment(ty) orelse return error.InvalidMemoryAccessType;
    if (access.alignment != expected_alignment) return error.InvalidMemoryAccessAlignment;
    if (target.projection_count != 0) {
        if (!isParameterScalarAccessPlace(body, target.*, is_store)) return error.InvalidPlaceType;
        if (access.kind != .race_unordered) return error.InvalidMemoryAccessKind;
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
    }
}

fn verifyCompletePlace(body: *const mir.ExecutableBody, target: mir.ExecutablePlace) !void {
    if (target.projection_count == 0) return;
    if (!isParameterScalarAccessPlace(body, target, false)) return error.InvalidPlaceType;
}

fn addressResultMatchesPlace(result_ty: mir.ValueType, place_ty: mir.ValueType) bool {
    const shape = switch (result_ty) {
        .pointer => |value| value,
        else => return false,
    };
    return shape.kind == .single and std.mem.eql(u8, shape.child, place_ty.name());
}

fn directAddressablePlace(body: *const mir.ExecutableBody, target: mir.ExecutablePlace) bool {
    if (target.projection_count != 0 or !sameValueType(target.root_ty, target.ty)) return false;
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
        .symbol => return false,
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
        .symbol => return false,
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
    return aggregate.construction == .declared_struct and field_index < aggregate.field_count and
        aggregate.field_type_ids[field_index].eql(target.type_id) and
        sameValueType(aggregate.field_types[field_index], target.ty);
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
    return mir.TypeKey.eql(mir.TypeKey.fromValueType(left), mir.TypeKey.fromValueType(right));
}
