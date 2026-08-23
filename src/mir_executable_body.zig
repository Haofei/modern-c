//! Verification and lookup helpers for the executable body owned by MIR.
//!
//! `mir_model.ExecutableBody` is the only executable-body representation.
//! This module never reconstructs a second body from sparse instructions,
//! source coordinates, or textual instruction details.

const std = @import("std");
const mir = @import("mir_model.zig");

pub fn isComplete(function: *const mir.Function) bool {
    verify(function) catch return false;
    return function.executable_body.complete;
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
        .literal, .unsupported => {},
        .unary => |operation| try verifyOperand(body, value, operation.operand),
        .binary => |operation| {
            try verifyOperand(body, value, operation.left);
            try verifyOperand(body, value, operation.right);
        },
        .cast => |operation| try verifyOperand(body, value, operation.operand),
        .direct_call => |call| {
            try verifySymbol(body, call.callee);
            try verifySpan(function, call.callee_span_id, call.callee_source);
            try verifyArguments(body, value, call.arguments, call.argument_count);
        },
        .builtin_call => |call| {
            try verifySpan(function, call.callee_span_id, call.callee_source);
            try verifyArguments(body, value, call.arguments, call.argument_count);
        },
        .indirect_call => |call| {
            try verifyOperand(body, value, call.callee);
            try verifyArguments(body, value, call.arguments, call.argument_count);
        },
        .address_of, .deref, .slice_length => |id| try verifyOperand(body, value, id),
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
            for (target.projections[0..target.projection_count]) |projection| switch (projection) {
                .index => |id| try verifyStatementExpr(body, statement_value, id),
                .field, .deref => {},
            };
            try verifyStatementExpr(body, statement_value, operation.value);
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
        .unsupported, .builtin_call, .cast, .address_of, .deref, .index, .range_slice, .member, .array, .struct_ => return true,
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
    if (!identity.id.eql(id) or !std.mem.eql(u8, identity.spelling, ty.name())) return error.InvalidTypeReference;
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
    return std.meta.activeTag(left) == std.meta.activeTag(right) and std.mem.eql(u8, left.name(), right.name());
}
