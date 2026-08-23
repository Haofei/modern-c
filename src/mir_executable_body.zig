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

pub fn expression(body: *const mir.ExecutableBody, id: mir.ExprId) ?*const mir.ExecutableExpression {
    if (!id.isValid() or id.index() >= body.expressions.len) return null;
    const value = &body.expressions[id.index()];
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
    if (!body.complete and body.parameters.len == 0 and body.locals.len == 0 and body.symbols.len == 0 and
        body.expressions.len == 0 and body.places.len == 0 and body.statements.len == 0 and body.terminators.len == 0) return;

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
        switch (value.root) {
            .local => |id| try verifyLocal(body, id),
            .symbol => |id| try verifySymbol(body, id),
        }
        for (value.projections[0..value.projection_count]) |projection| switch (projection) {
            .index => |id| try verifyExpr(body, id),
            .field, .deref => {},
        };
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
            } else if (place(body, operation.place) == null) return error.InvalidPlaceReference;
        },
        .literal, .unsupported => {},
        .unary => |operation| try verifyOperand(body, value, operation.operand),
        .binary => |operation| {
            try verifyOperand(body, value, operation.left);
            try verifyOperand(body, value, operation.right);
            const left = expression(body, operation.left) orelse return error.InvalidExpressionReference;
            const right = expression(body, operation.right) orelse return error.InvalidExpressionReference;
            if (operation.arithmetic == .checked) {
                if (operation.op != .add and operation.op != .sub and operation.op != .mul) return error.InvalidCheckedArithmetic;
                if (!sameValueType(value.result_ty, left.result_ty) or !sameValueType(left.result_ty, right.result_ty) or
                    std.meta.activeTag(value.result_ty) != .integer) return error.InvalidCheckedArithmetic;
                if (ownedTrapCount(body, value.id, .IntegerOverflow, .checked_arithmetic) != 1 or ownedTrapCountAll(body, value.id) != 1)
                    return error.InvalidCheckedArithmetic;
            }
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
        .address_of => |id| if (place(body, id) == null) return error.InvalidPlaceReference,
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
        .member => |operation| try verifyOperand(body, value, operation.base),
        .array => |operation| try verifyArguments(body, value, operation.operands, operation.operand_count),
        .struct_ => |operation| try verifyArguments(body, value, operation.operands, operation.operand_count),
    }
}

fn verifyTrapEdges(function: *const mir.Function) !void {
    const body = &function.executable_body;
    for (body.trap_edges, 0..) |edge, edge_index| {
        const owner = expression(body, edge.owner) orelse return error.InvalidTrapEdge;
        if (!owner.block_id.eql(edge.from_block)) return error.InvalidTrapEdge;
        switch (owner.operation) {
            .binary => |binary| if (binary.arithmetic != .checked) return error.InvalidTrapEdge,
            else => return error.InvalidTrapEdge,
        }
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
                legacy.kind == edge.kind and legacy.source == edge.source and legacy.typed_span_id.eql(owner.span_id)) legacy_matches += 1;
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

fn ownedTrapCount(body: *const mir.ExecutableBody, owner: mir.ExprId, kind: mir.TrapKind, source: mir.TrapSource) usize {
    var count: usize = 0;
    for (body.trap_edges) |edge| if (edge.owner.eql(owner) and edge.kind == kind and edge.source == source) {
        count += 1;
    };
    return count;
}

fn ownedTrapCountAll(body: *const mir.ExecutableBody, owner: mir.ExprId) usize {
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
            if (body.complete) try verifyMemoryAccess(function, operation.place, operation.ty, operation.access, true);
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
        .unsupported, .address_of, .deref, .index, .range_slice, .member, .array, .struct_ => return true,
        .builtin_call => |call| {
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
    for (body.places) |value| if (value.projection_count != 0) return true;
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

fn verifyMemoryAccess(
    function: *const mir.Function,
    place_id: mir.PlaceId,
    ty: mir.ValueType,
    access: mir.ExecutableMemoryAccess,
    is_store: bool,
) !void {
    const body = &function.executable_body;
    const target = place(body, place_id) orelse return error.InvalidPlaceReference;
    const expected_alignment = mir.ExecutableMemoryAccess.scalarAlignment(ty) orelse return error.InvalidMemoryAccessType;
    if (access.alignment != expected_alignment) return error.InvalidMemoryAccessAlignment;
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
