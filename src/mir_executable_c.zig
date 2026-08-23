//! Mechanical C rendering for a complete syntax-free MIR executable body.
//!
//! This module deliberately knows nothing about AST declarations, source
//! spelling joins, or the specialized C body plans.  All control flow comes
//! from `BlockId` terminators and all values come from typed executable-body
//! operations.  The surrounding C emitter remains responsible for the
//! function signature and braces.

const std = @import("std");
const mir = @import("mir_model.zig");

pub const RenderError = error{
    IncompleteBody,
    InvalidBlock,
    InvalidExpression,
    InvalidLocal,
    InvalidPlace,
    InvalidSymbol,
    UnsupportedOperation,
    UnsupportedType,
};

pub fn emitBody(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    indent: usize,
) (RenderError || std.mem.Allocator.Error)!void {
    return emitBodyWithSourcePath(allocator, out, body, indent, null);
}

pub fn emitBodyWithSourcePath(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    indent: usize,
    source_path: ?[]const u8,
) (RenderError || std.mem.Allocator.Error)!void {
    if (!body.isComplete() or !canEmitBody(body)) return error.IncompleteBody;
    if (body.terminators.len == 0) return error.InvalidBlock;

    // Every value is materialized once in canonical ExprId order.  C leaves
    // operand and argument evaluation order unspecified, so rendering a pure
    // expression tree here would lose the order already verified by MIR.
    for (body.expressions) |expression| {
        if (!expressionNeedsTemporary(expression)) continue;
        try writeIndent(allocator, out, indent);
        try appendCType(allocator, out, expression.result_ty);
        try out.print(allocator, " mc_exec_tmp_{d};\n", .{expression.id.raw});
    }

    for (body.terminators) |terminator| {
        try writeIndent(allocator, out, indent);
        // A C11 label must precede a statement, not a declaration.
        try out.print(allocator, "mc_bb_{d}: ;\n", .{terminator.block_id.raw});

        for (body.statements) |statement| {
            if (!statement.block_id.eql(terminator.block_id)) continue;
            try emitStatement(allocator, out, body, statement, indent + 1, source_path);
        }
        try emitTerminator(allocator, out, body, terminator, indent + 1);
    }
}

fn emitStatement(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    statement: mir.ExecutableStatement,
    indent: usize,
    source_path: ?[]const u8,
) (RenderError || std.mem.Allocator.Error)!void {
    try prepareStatementExpressions(allocator, out, body, statement, indent, source_path);
    try writeSourceLineDirective(allocator, out, source_path, statement.source);
    switch (statement.operation) {
        .local_init => |local| {
            try writeIndent(allocator, out, indent);
            try appendCType(allocator, out, local.ty);
            try out.append(allocator, ' ');
            try appendLocal(allocator, out, body, local.local);
            if (local.value) |value| {
                try out.appendSlice(allocator, " = ");
                try emitExpression(allocator, out, body, value, 0);
            }
            try out.appendSlice(allocator, ";\n");
        },
        .store => |store| {
            try writeIndent(allocator, out, indent);
            switch (store.access.kind) {
                .plain => {
                    try emitPlace(allocator, out, body, store.place);
                    try out.appendSlice(allocator, " = ");
                    try emitExpression(allocator, out, body, store.value, 0);
                    try out.appendSlice(allocator, ";\n");
                },
                .race_unordered => {
                    const scalar = scalarMemoryInfo(store.ty) orelse return error.UnsupportedType;
                    try out.print(allocator, "mc_race_store_{s}(&", .{scalar.helper_suffix});
                    try emitPlace(allocator, out, body, store.place);
                    try out.print(allocator, ", ({s})", .{scalar.c_type});
                    try emitExpression(allocator, out, body, store.value, 0);
                    try out.appendSlice(allocator, ");\n");
                },
            }
        },
        .eval => |value| {
            // `prepareStatementExpressions` evaluated the complete expression
            // graph, including a void-valued root.  Emitting it again would
            // duplicate effects.
            _ = expressionById(body, value) orelse return error.InvalidExpression;
        },
        .guard => |guard| switch (guard.kind) {
            .assert_ => {
                try writeIndent(allocator, out, indent);
                try out.appendSlice(allocator, "if (!(");
                try emitExpression(allocator, out, body, guard.condition, 0);
                try out.appendSlice(allocator, ")) mc_trap_Assert();\n");
            },
            // Branch/loop/switch guards are represented by the block
            // terminator.  The statement only preserves the source operation.
            .if_, .while_, .switch_ => {},
        },
        .return_ => |value| {
            try writeIndent(allocator, out, indent);
            if (value) |expression| {
                try out.appendSlice(allocator, "return ");
                try emitExpression(allocator, out, body, expression, 0);
                try out.appendSlice(allocator, ";\n");
            } else {
                try out.appendSlice(allocator, "return;\n");
            }
        },
        // The corresponding CFG edge is the authority for these transfers.
        .control_transfer => {},
        .defer_cleanup, .unsupported => return error.UnsupportedOperation,
    }
}

fn emitTerminator(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    terminator: mir.ExecutableTerminator,
    indent: usize,
) (RenderError || std.mem.Allocator.Error)!void {
    switch (terminator.operation) {
        .fallthrough => return error.UnsupportedOperation,
        .jump => |target| {
            if (!hasBlock(body, target)) return error.InvalidBlock;
            try writeIndent(allocator, out, indent);
            try out.print(allocator, "goto mc_bb_{d};\n", .{target.raw});
        },
        .branch => |branch| {
            if (!hasBlock(body, branch.true_block) or !hasBlock(body, branch.false_block)) return error.InvalidBlock;
            try writeIndent(allocator, out, indent);
            try out.appendSlice(allocator, "if (");
            try emitExpression(allocator, out, body, branch.condition, 0);
            try out.print(allocator, ") goto mc_bb_{d}; else goto mc_bb_{d};\n", .{ branch.true_block.raw, branch.false_block.raw });
        },
        // The value-bearing return is an executable statement.  A bare return
        // terminator only closes paths whose statement stream has no explicit
        // return operation.
        .return_ => {
            if (!blockHasReturn(body, terminator.block_id)) {
                try writeIndent(allocator, out, indent);
                try out.appendSlice(allocator, "return;\n");
            }
        },
        .trap_ => |kind| {
            const helper = trapHelper(kind) orelse return error.UnsupportedOperation;
            try writeIndent(allocator, out, indent);
            try out.print(allocator, "{s}();\n", .{helper});
        },
        .unreachable_ => {
            try writeIndent(allocator, out, indent);
            try out.appendSlice(allocator, "mc_trap_Unreachable();\n");
        },
        .switch_ => return error.UnsupportedOperation,
    }
}

fn emitExpression(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    id: mir.ExprId,
    depth: usize,
) (RenderError || std.mem.Allocator.Error)!void {
    if (depth > body.expressions.len) return error.InvalidExpression;
    const expression = expressionById(body, id) orelse return error.InvalidExpression;
    if (expressionNeedsTemporary(expression.*)) {
        try out.print(allocator, "mc_exec_tmp_{d}", .{expression.id.raw});
        return;
    }
    try emitExpressionOperation(allocator, out, body, expression, depth);
}

fn emitExpressionOperation(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    expression: *const mir.ExecutableExpression,
    depth: usize,
) (RenderError || std.mem.Allocator.Error)!void {
    switch (expression.operation) {
        .local => |local| try appendLocal(allocator, out, body, local),
        .symbol => |symbol| try appendSymbol(allocator, out, body, symbol),
        .load => |load| switch (load.access.kind) {
            .plain => try emitPlace(allocator, out, body, load.place),
            .race_unordered => {
                const scalar = scalarMemoryInfo(expression.result_ty) orelse return error.UnsupportedType;
                try out.print(allocator, "(({s})mc_race_load_{s}(&", .{ scalar.c_type, scalar.helper_suffix });
                try emitPlace(allocator, out, body, load.place);
                try out.appendSlice(allocator, "))");
            },
        },
        .literal => |literal| try emitLiteral(allocator, out, expression.result_ty, literal),
        .unary => |unary| {
            if (unary.op == .neg and integerSuffix(expression.result_ty) != null) {
                try out.print(allocator, "mc_checked_neg_{s}(", .{integerSuffix(expression.result_ty).?});
                try emitExpression(allocator, out, body, unary.operand, depth + 1);
                try out.append(allocator, ')');
            } else {
                try out.appendSlice(allocator, switch (unary.op) {
                    .neg => "(-",
                    .bit_not => "(~",
                    .logical_not => "(!",
                });
                try emitExpression(allocator, out, body, unary.operand, depth + 1);
                try out.append(allocator, ')');
            }
        },
        .binary => |binary| {
            if (checkedBinaryParts(binary.op, expression.result_ty)) |helper| {
                try out.print(allocator, "mc_checked_{s}_{s}(", .{ helper.operation, helper.suffix });
                try emitExpression(allocator, out, body, binary.left, depth + 1);
                try out.appendSlice(allocator, ", ");
                try emitExpression(allocator, out, body, binary.right, depth + 1);
                try out.append(allocator, ')');
            } else {
                try out.append(allocator, '(');
                try emitExpression(allocator, out, body, binary.left, depth + 1);
                try out.print(allocator, " {s} ", .{binaryToken(binary.op)});
                try emitExpression(allocator, out, body, binary.right, depth + 1);
                try out.append(allocator, ')');
            }
        },
        .cast => |cast| {
            try out.appendSlice(allocator, "((");
            try appendCType(allocator, out, expression.result_ty);
            try out.appendSlice(allocator, ")(");
            try emitExpression(allocator, out, body, cast.operand, depth + 1);
            try out.appendSlice(allocator, "))");
        },
        .direct_call => |call| {
            try appendSymbol(allocator, out, body, call.callee);
            try emitPreparedArguments(allocator, out, body, call.arguments[0..call.argument_count]);
        },
        .indirect_call => |call| {
            try out.append(allocator, '(');
            try emitExpression(allocator, out, body, call.callee, depth + 1);
            try out.append(allocator, ')');
            try emitPreparedArguments(allocator, out, body, call.arguments[0..call.argument_count]);
        },
        .builtin_call => |call| try emitBuiltinCall(allocator, out, body, expression.result_ty, call, depth),
        .address_of => |operand| {
            try out.appendSlice(allocator, "(&(");
            try emitExpression(allocator, out, body, operand, depth + 1);
            try out.appendSlice(allocator, "))");
        },
        .deref => |operand| {
            try out.appendSlice(allocator, "(*(");
            try emitExpression(allocator, out, body, operand, depth + 1);
            try out.appendSlice(allocator, "))");
        },
        .index => |index| {
            try emitExpression(allocator, out, body, index.base, depth + 1);
            try out.append(allocator, '[');
            try emitExpression(allocator, out, body, index.index, depth + 1);
            try out.append(allocator, ']');
        },
        .slice_length => |base| {
            try emitExpression(allocator, out, body, base, depth + 1);
            try out.appendSlice(allocator, ".len");
        },
        .range_slice, .member, .array, .struct_, .unsupported => return error.UnsupportedOperation,
    }
}

/// Backend capability admission layered on top of the producer's semantic
/// completeness bit.  This is deliberately structural and typed: it never
/// consults source text, spans, or declaration ASTs.
pub fn canEmitBody(body: *const mir.ExecutableBody) bool {
    if (!body.isComplete() or body.terminators.len == 0) return false;
    for (body.parameters) |parameter| if (!supportsType(parameter.ty) or localById(body, parameter.local) == null) return false;
    for (body.expressions) |expression| {
        if (!supportsExpression(body, expression)) return false;
    }
    // Every exceptional edge must be owned by the one checked arithmetic
    // operation this renderer understands. This prevents a newly added edge
    // kind from being silently ignored while still emitting ordinary C.
    for (body.trap_edges) |edge| {
        const owner = expressionById(body, edge.owner) orelse return false;
        if (!checkedIntegerBinaryHasExactTrapEdges(body, owner.*)) return false;
    }
    for (body.places) |place| {
        if (place.projection_count != 0) return false;
        switch (place.root) {
            .local => |local| if (localById(body, local) == null) return false,
            .symbol => |symbol| {
                const identity = symbolById(body, symbol) orelse return false;
                if (identity.kind != .global) return false;
            },
        }
    }
    for (body.statements) |statement| {
        if (!hasBlock(body, statement.block_id)) return false;
        switch (statement.operation) {
            .local_init => |local| {
                if (!supportsType(local.ty) or localById(body, local.local) == null) return false;
                if (local.value) |value| if (expressionById(body, value) == null) return false;
            },
            .store => |store| if (!memoryStoreSupported(body, store)) return false,
            .eval => |value| if (expressionById(body, value) == null) return false,
            .guard => |guard| if (expressionById(body, guard.condition) == null) return false,
            .return_ => |value| if (value) |expression| if (expressionById(body, expression) == null) return false,
            .control_transfer => {},
            .defer_cleanup, .unsupported => return false,
        }
    }
    for (body.terminators) |terminator| switch (terminator.operation) {
        // Block slice order is storage order, not a verified CFG edge.
        .fallthrough => return false,
        .return_, .unreachable_ => {},
        .trap_ => |kind| if (trapHelper(kind) == null) return false,
        .jump => |target| if (!hasBlock(body, target)) return false,
        .branch => |branch| if (expressionById(body, branch.condition) == null or !hasBlock(body, branch.true_block) or !hasBlock(body, branch.false_block)) return false,
        .switch_ => return false,
    };
    return true;
}

fn supportsExpression(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    if (!supportsType(expression.result_ty)) return false;
    return switch (expression.operation) {
        .local => |local| localById(body, local) != null,
        // A bare symbol does not state ordinary/atomic/volatile/MMIO access.
        // Direct calls carry their SymbolId separately; global value reads
        // remain closed until MIR owns an explicit access mode.
        .symbol => false,
        .load => |load| memoryLoadSupported(body, expression, load),
        .literal => |literal| switch (literal) {
            .float => |value| mir.executableFloatMatchesType(value, expression.result_ty),
            // Raw source string/character spelling is not a canonical byte
            // payload and must not cross the syntax-free boundary.
            .string, .character, .enum_value => false,
            else => true,
        },
        .unary => |unary| expressionById(body, unary.operand) != null,
        .binary => |binary| binarySupported(body, expression, binary),
        .cast => |cast| castSupported(body, expression, cast),
        .direct_call => |call| call.argument_count <= call.arguments.len and symbolById(body, call.callee) != null and allExpressionsExist(body, call.arguments[0..call.argument_count]),
        .indirect_call => |call| call.argument_count <= call.arguments.len and expressionById(body, call.callee) != null and allExpressionsExist(body, call.arguments[0..call.argument_count]),
        .slice_length => |base| expressionById(body, base) != null,
        .builtin_call => |call| builtinCallSupported(body, expression, call),
        .address_of, .deref, .index, .range_slice, .member, .array, .struct_, .unsupported => false,
    };
}

fn builtinCallSupported(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    call: @FieldType(mir.ExecutableExpression.Operation, "builtin_call"),
) bool {
    switch (call.kind) {
        .phys, .wrapping_add, .conversion_from => {},
        else => return false,
    }
    if (call.argument_count > mir.max_executable_operands) return false;
    var operand_types: [mir.max_executable_operands]mir.ValueType = undefined;
    for (call.arguments[0..call.argument_count], 0..) |argument, index| {
        const operand = expressionById(body, argument) orelse return false;
        operand_types[index] = operand.result_ty;
    }
    return mir.executableBuiltinTypesValid(call.kind, expression.result_ty, operand_types[0..call.argument_count]);
}

fn emitBuiltinCall(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    result_ty: mir.ValueType,
    call: @FieldType(mir.ExecutableExpression.Operation, "builtin_call"),
    depth: usize,
) (RenderError || std.mem.Allocator.Error)!void {
    switch (call.kind) {
        .phys => {
            try out.appendSlice(allocator, "((uintptr_t)(");
            try emitExpression(allocator, out, body, call.arguments[0], depth + 1);
            try out.appendSlice(allocator, "))");
        },
        .conversion_from => {
            try out.appendSlice(allocator, "((");
            try appendCType(allocator, out, result_ty);
            try out.appendSlice(allocator, ")(");
            try emitExpression(allocator, out, body, call.arguments[0], depth + 1);
            try out.appendSlice(allocator, "))");
        },
        .wrapping_add => {
            try out.appendSlice(allocator, "((");
            try appendCType(allocator, out, result_ty);
            try out.appendSlice(allocator, ")((");
            try appendCType(allocator, out, result_ty);
            try out.appendSlice(allocator, ")(");
            try emitExpression(allocator, out, body, call.arguments[0], depth + 1);
            try out.appendSlice(allocator, ") + (");
            try appendCType(allocator, out, result_ty);
            try out.appendSlice(allocator, ")(");
            try emitExpression(allocator, out, body, call.arguments[1], depth + 1);
            try out.appendSlice(allocator, ")))");
        },
        else => return error.UnsupportedOperation,
    }
}

fn castSupported(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    cast: @FieldType(mir.ExecutableExpression.Operation, "cast"),
) bool {
    const operand = expressionById(body, cast.operand) orelse return false;
    const expected = mir.ExecutableCastKind.classify(operand.result_ty, expression.result_ty) orelse return false;
    return cast.kind == expected;
}

fn memoryLoadSupported(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    load: @FieldType(mir.ExecutableExpression.Operation, "load"),
) bool {
    const scalar = scalarMemoryInfo(expression.result_ty) orelse return false;
    if (load.access.alignment != scalar.alignment) return false;
    const place = placeById(body, load.place) orelse return false;
    if (place.projection_count != 0) return false;
    const symbol = switch (place.root) {
        .symbol => |id| symbolById(body, id) orelse return false,
        .local => return false,
    };
    if (symbol.kind != .global) return false;
    const expected_kind: mir.ExecutableMemoryAccessKind = if (symbol.mutable) .race_unordered else .plain;
    return load.access.kind == expected_kind;
}

fn memoryStoreSupported(
    body: *const mir.ExecutableBody,
    store: @FieldType(mir.ExecutableStatement.Operation, "store"),
) bool {
    const scalar = scalarMemoryInfo(store.ty) orelse return false;
    if (store.access.alignment != scalar.alignment) return false;
    const value = expressionById(body, store.value) orelse return false;
    if (!mir.TypeKey.eql(mir.TypeKey.fromValueType(store.ty), mir.TypeKey.fromValueType(value.result_ty))) return false;
    const place = placeById(body, store.place) orelse return false;
    if (place.projection_count != 0) return false;
    return switch (place.root) {
        .local => |local| localById(body, local) != null and store.access.kind == .plain,
        .symbol => |id| if (symbolById(body, id)) |symbol|
            symbol.kind == .global and symbol.mutable and store.access.kind == .race_unordered
        else
            false,
    };
}

fn binarySupported(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    binary: @FieldType(mir.ExecutableExpression.Operation, "binary"),
) bool {
    if (binary.op == .logical_and or binary.op == .logical_or) return false;
    if (expressionById(body, binary.left) == null or expressionById(body, binary.right) == null) return false;
    return switch (binary.arithmetic) {
        .ordinary => ownedTrapEdgeCount(body, expression.id) == 0,
        .checked => checkedIntegerBinaryHasExactTrapEdges(body, expression),
    };
}

fn checkedIntegerBinaryHasExactTrapEdges(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    const binary = switch (expression.operation) {
        .binary => |value| value,
        else => return false,
    };
    if (binary.arithmetic != .checked) return false;
    if (integerSuffix(expression.result_ty) == null) return false;
    const left = expressionById(body, binary.left) orelse return false;
    const right = expressionById(body, binary.right) orelse return false;
    const result_key = mir.TypeKey.fromValueType(expression.result_ty);
    if (!mir.TypeKey.eql(result_key, mir.TypeKey.fromValueType(left.result_ty)) or
        !mir.TypeKey.eql(result_key, mir.TypeKey.fromValueType(right.result_ty))) return false;
    const requirements = mir.executableCheckedBinaryTrapRequirements(binary.op, expression.result_ty) orelse return false;
    var total: usize = 0;
    for (body.trap_edges) |edge| {
        if (!edge.owner.eql(expression.id)) continue;
        total += 1;
        if (!edge.from_block.eql(expression.block_id)) return false;
    }
    if (total != requirements.count) return false;
    for (requirements.items[0..requirements.count]) |requirement| {
        var matching: usize = 0;
        for (body.trap_edges) |edge| {
            if (!edge.owner.eql(expression.id) or edge.kind != requirement.kind or edge.source != requirement.source) continue;
            const trap_terminator = terminatorByBlock(body, edge.trap_block) orelse return false;
            switch (trap_terminator.operation) {
                .trap_ => |kind| {
                    if (kind == requirement.kind) matching += 1;
                },
                else => return false,
            }
        }
        if (matching != 1) return false;
    }
    return true;
}

fn ownedTrapEdgeCount(body: *const mir.ExecutableBody, owner: mir.ExprId) usize {
    var count: usize = 0;
    for (body.trap_edges) |edge| if (edge.owner.eql(owner)) {
        count += 1;
    };
    return count;
}

fn allExpressionsExist(body: *const mir.ExecutableBody, expressions: []const mir.ExprId) bool {
    for (expressions) |expression| if (expressionById(body, expression) == null) return false;
    return true;
}

fn supportsType(ty: mir.ValueType) bool {
    return switch (ty) {
        .void, .never, .bool, .cstr, .address => true,
        .integer, .float => |name| primitiveType(name) != null,
        .pointer, .nullable_pointer => |shape| primitiveType(shape.child) != null or isSafeIdentifier(shape.child),
        .closed_enum, .open_enum, .struct_ => |name| isSafeIdentifier(name),
        else => false,
    };
}

fn prepareStatementExpressions(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    statement: mir.ExecutableStatement,
    indent: usize,
    source_path: ?[]const u8,
) (RenderError || std.mem.Allocator.Error)!void {
    // ExprIds are emitted by the producer in source evaluation order and the
    // verified body requires operands to precede their consumer under one
    // owner statement.  Materialize every value, including reads, so a later
    // call or store cannot change what an earlier operand observes.
    for (body.expressions) |expression| {
        if (!expression.owner_statement.eql(statement.id)) continue;
        try writeSourceLineDirective(allocator, out, source_path, expression.source);
        try writeIndent(allocator, out, indent);
        if (expressionNeedsTemporary(expression)) try out.print(allocator, "mc_exec_tmp_{d} = ", .{expression.id.raw});
        try emitExpressionOperation(allocator, out, body, &expression, 0);
        try out.appendSlice(allocator, ";\n");
    }
}

fn writeSourceLineDirective(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    source_path: ?[]const u8,
    source: mir.SourcePoint,
) std.mem.Allocator.Error!void {
    const path = source_path orelse return;
    if (source.line == 0) return;
    try out.print(allocator, "#line {d} \"", .{source.line});
    for (path) |ch| switch (ch) {
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '"' => try out.appendSlice(allocator, "\\\""),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        else => try out.append(allocator, ch),
    };
    try out.appendSlice(allocator, "\"\n");
}

fn emitPreparedArguments(allocator: std.mem.Allocator, out: *std.ArrayList(u8), body: *const mir.ExecutableBody, arguments: []const mir.ExprId) (RenderError || std.mem.Allocator.Error)!void {
    try out.append(allocator, '(');
    for (arguments, 0..) |argument, index| {
        if (index != 0) try out.appendSlice(allocator, ", ");
        try emitExpression(allocator, out, body, argument, 0);
    }
    try out.append(allocator, ')');
}

fn expressionNeedsTemporary(expression: mir.ExecutableExpression) bool {
    if (expression.result_ty == .void or expression.result_ty == .never) return false;
    return true;
}

fn trapHelper(kind: mir.TrapKind) ?[]const u8 {
    return switch (kind) {
        .IntegerOverflow => "mc_trap_IntegerOverflow",
        .DivideByZero => "mc_trap_DivideByZero",
        .InvalidShift => "mc_trap_InvalidShift",
        .Bounds => "mc_trap_Bounds",
        .Assert => "mc_trap_Assert",
        .Unreachable => "mc_trap_Unreachable",
        .Unwrap => "mc_trap_NullUnwrap",
        .InvalidRepresentation => "mc_trap_InvalidRepresentation",
        .ExplicitTrap, .CallMayTrap, .Unknown => null,
    };
}

fn emitPlace(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    id: mir.PlaceId,
) (RenderError || std.mem.Allocator.Error)!void {
    const place = placeById(body, id) orelse return error.InvalidPlace;
    switch (place.root) {
        .local => |local| try appendLocal(allocator, out, body, local),
        .symbol => |symbol| try appendSymbol(allocator, out, body, symbol),
    }
    for (place.projections[0..place.projection_count]) |projection| switch (projection) {
        .index => |index| {
            try out.append(allocator, '[');
            try emitExpression(allocator, out, body, index, 0);
            try out.append(allocator, ']');
        },
        .deref => {
            // Prefixing an already-emitted root would require retaining and
            // re-parenthesizing it.  Completion currently excludes deref
            // places; fail closed if an invalid producer admits one.
            return error.UnsupportedOperation;
        },
        .field => return error.UnsupportedOperation,
    };
}

fn emitArguments(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    arguments: []const mir.ExprId,
    depth: usize,
) (RenderError || std.mem.Allocator.Error)!void {
    try out.append(allocator, '(');
    for (arguments, 0..) |argument, index| {
        if (index != 0) try out.appendSlice(allocator, ", ");
        try emitExpression(allocator, out, body, argument, depth + 1);
    }
    try out.append(allocator, ')');
}

fn emitLiteral(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    result_ty: mir.ValueType,
    literal: mir.ExecutableLiteral,
) (RenderError || std.mem.Allocator.Error)!void {
    switch (literal) {
        .integer => |magnitude| try out.print(allocator, "{d}", .{magnitude}),
        .float => |value| switch (value) {
            .f32_bits => |bits| try out.print(allocator, "__builtin_bit_cast(float, ((uint32_t)0x{X:0>8}U))", .{bits}),
            .f64_bits => |bits| try out.print(allocator, "__builtin_bit_cast(double, ((uint64_t)0x{X:0>16}ULL))", .{bits}),
        },
        .string, .character => |spelling| try out.appendSlice(allocator, spelling),
        .boolean => |value| try out.appendSlice(allocator, if (value) "true" else "false"),
        .null => try out.appendSlice(allocator, "NULL"),
        .void => try out.appendSlice(allocator, "((void)0)"),
        .uninit => {
            try out.appendSlice(allocator, "((");
            try appendCType(allocator, out, result_ty);
            try out.appendSlice(allocator, "){0})");
        },
        .enum_value => return error.UnsupportedOperation,
    }
}

fn appendCType(allocator: std.mem.Allocator, out: *std.ArrayList(u8), ty: mir.ValueType) (RenderError || std.mem.Allocator.Error)!void {
    switch (ty) {
        .void, .never => try out.appendSlice(allocator, "void"),
        .bool => try out.appendSlice(allocator, "bool"),
        .integer, .float => |name| try out.appendSlice(allocator, primitiveType(name) orelse return error.UnsupportedType),
        .cstr => try out.appendSlice(allocator, "char const *"),
        .pointer, .nullable_pointer => |shape| {
            const child = primitiveType(shape.child) orelse shape.child;
            try out.appendSlice(allocator, child);
            try out.appendSlice(allocator, if (shape.mutability == .mut) " *" else " const *");
        },
        .address => try out.appendSlice(allocator, "uintptr_t"),
        .closed_enum, .open_enum, .struct_ => |name| try appendIdent(allocator, out, name),
        else => return error.UnsupportedType,
    }
}

fn appendLocal(allocator: std.mem.Allocator, out: *std.ArrayList(u8), body: *const mir.ExecutableBody, id: mir.LocalId) (RenderError || std.mem.Allocator.Error)!void {
    const local = localById(body, id) orelse return error.InvalidLocal;
    return appendIdent(allocator, out, local.spelling);
}

fn appendSymbol(allocator: std.mem.Allocator, out: *std.ArrayList(u8), body: *const mir.ExecutableBody, id: mir.SymbolId) (RenderError || std.mem.Allocator.Error)!void {
    const symbol = symbolById(body, id) orelse return error.InvalidSymbol;
    return appendIdent(allocator, out, symbol.spelling);
}

fn localById(body: *const mir.ExecutableBody, id: mir.LocalId) ?*const mir.ExecutableLocalIdentity {
    if (!id.isValid()) return null;
    for (body.locals) |*local| if (local.id.eql(id)) return local;
    return null;
}

fn symbolById(body: *const mir.ExecutableBody, id: mir.SymbolId) ?*const mir.SymbolIdentity {
    if (!id.isValid()) return null;
    for (body.symbols) |*symbol| if (symbol.id.eql(id)) return symbol;
    return null;
}

fn appendIdent(allocator: std.mem.Allocator, out: *std.ArrayList(u8), spelling: []const u8) std.mem.Allocator.Error!void {
    try out.appendSlice(allocator, spelling);
    if (isCKeyword(spelling)) try out.append(allocator, '_');
}

fn expressionById(body: *const mir.ExecutableBody, id: mir.ExprId) ?*const mir.ExecutableExpression {
    if (!id.isValid()) return null;
    for (body.expressions) |*expression| if (expression.id.eql(id)) return expression;
    return null;
}

fn placeById(body: *const mir.ExecutableBody, id: mir.PlaceId) ?*const mir.ExecutablePlace {
    if (!id.isValid()) return null;
    for (body.places) |*place| if (place.id.eql(id)) return place;
    return null;
}

fn hasBlock(body: *const mir.ExecutableBody, id: mir.BlockId) bool {
    for (body.terminators) |terminator| if (terminator.block_id.eql(id)) return true;
    return false;
}

fn terminatorByBlock(body: *const mir.ExecutableBody, id: mir.BlockId) ?*const mir.ExecutableTerminator {
    if (!id.isValid()) return null;
    for (body.terminators) |*terminator| if (terminator.block_id.eql(id)) return terminator;
    return null;
}

fn blockHasReturn(body: *const mir.ExecutableBody, id: mir.BlockId) bool {
    for (body.statements) |statement| {
        if (statement.block_id.eql(id) and statement.operation == .return_) return true;
    }
    return false;
}

fn writeIndent(allocator: std.mem.Allocator, out: *std.ArrayList(u8), level: usize) std.mem.Allocator.Error!void {
    for (0..level) |_| try out.appendSlice(allocator, "    ");
}

const CheckedBinaryParts = struct { operation: []const u8, suffix: []const u8 };

fn checkedBinaryParts(op: mir.ExecutableBinaryOp, ty: mir.ValueType) ?CheckedBinaryParts {
    const suffix = integerSuffix(ty) orelse return null;
    const opname = switch (op) {
        .add => "add",
        .sub => "sub",
        .mul => "mul",
        .div => "div",
        .mod => "mod",
        .shl => "shl",
        .shr => "shr",
        else => return null,
    };
    return .{ .operation = opname, .suffix = suffix };
}

fn integerSuffix(ty: mir.ValueType) ?[]const u8 {
    return switch (ty) {
        .integer => |name| if (primitiveType(name) != null) name else null,
        else => null,
    };
}

fn binaryToken(op: mir.ExecutableBinaryOp) []const u8 {
    return switch (op) {
        .logical_or => "||",
        .logical_and => "&&",
        .eq => "==",
        .ne => "!=",
        .lt => "<",
        .le => "<=",
        .gt => ">",
        .ge => ">=",
        .bit_or => "|",
        .bit_xor => "^",
        .bit_and => "&",
        .shl => "<<",
        .shr => ">>",
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .mod => "%",
    };
}

fn primitiveType(name: []const u8) ?[]const u8 {
    const Entry = struct { mc: []const u8, c: []const u8 };
    const entries = [_]Entry{
        .{ .mc = "u8", .c = "uint8_t" },      .{ .mc = "u16", .c = "uint16_t" },   .{ .mc = "u32", .c = "uint32_t" }, .{ .mc = "u64", .c = "uint64_t" }, .{ .mc = "u128", .c = "unsigned __int128" },
        .{ .mc = "i8", .c = "int8_t" },       .{ .mc = "i16", .c = "int16_t" },    .{ .mc = "i32", .c = "int32_t" },  .{ .mc = "i64", .c = "int64_t" },  .{ .mc = "i128", .c = "__int128" },
        .{ .mc = "usize", .c = "uintptr_t" }, .{ .mc = "isize", .c = "intptr_t" }, .{ .mc = "f32", .c = "float" },    .{ .mc = "f64", .c = "double" },   .{ .mc = "bool", .c = "bool" },
    };
    for (entries) |entry| if (std.mem.eql(u8, name, entry.mc)) return entry.c;
    return null;
}

const ScalarMemoryInfo = struct {
    helper_suffix: []const u8,
    c_type: []const u8,
    alignment: u16,
};

fn scalarMemoryInfo(ty: mir.ValueType) ?ScalarMemoryInfo {
    const suffix = switch (ty) {
        .bool => "bool",
        .integer, .float => |name| name,
        else => return null,
    };
    return .{
        .helper_suffix = suffix,
        .c_type = primitiveType(suffix) orelse return null,
        .alignment = mir.ExecutableMemoryAccess.scalarAlignment(ty) orelse return null,
    };
}

fn isCKeyword(name: []const u8) bool {
    const keywords = [_][]const u8{ "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "_Alignas", "_Alignof", "_Atomic", "_Bool", "_Complex", "_Generic", "_Imaginary", "_Noreturn", "_Static_assert", "_Thread_local" };
    for (keywords) |keyword| if (std.mem.eql(u8, name, keyword)) return true;
    return false;
}

fn isSafeIdentifier(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    return true;
}

test "executable C renderer emits typed CFG labels and branches" {
    const local_flag = mir.LocalId.fromIndex(0);
    const local_x = mir.LocalId.fromIndex(1);
    const expr_flag = mir.ExprId.fromIndex(0);
    const expr_one = mir.ExprId.fromIndex(1);
    const expr_two = mir.ExprId.fromIndex(2);
    const expr_x = mir.ExprId.fromIndex(3);
    const block_entry = mir.BlockId.fromIndex(0);
    const block_true = mir.BlockId.fromIndex(1);
    const block_false = mir.BlockId.fromIndex(2);
    const statement_guard = mir.InstId.fromIndex(0);
    const statement_true_local = mir.InstId.fromIndex(1);
    const statement_true_return = mir.InstId.fromIndex(2);
    const statement_false_return = mir.InstId.fromIndex(3);
    var locals = [_]mir.ExecutableLocalIdentity{ .{ .id = local_flag, .spelling = "flag" }, .{ .id = local_x, .spelling = "x" } };
    var expressions = [_]mir.ExecutableExpression{
        .{ .id = expr_flag, .block_id = block_entry, .owner_statement = statement_guard, .source = .{ .line = 1, .column = 1 }, .result_ty = .bool, .operation = .{ .local = local_flag } },
        .{ .id = expr_one, .block_id = block_true, .owner_statement = statement_true_local, .source = .{ .line = 2, .column = 1 }, .result_ty = .{ .integer = "u32" }, .operation = .{ .literal = .{ .integer = 1 } } },
        .{ .id = expr_two, .block_id = block_false, .owner_statement = statement_false_return, .source = .{ .line = 3, .column = 1 }, .result_ty = .{ .integer = "u32" }, .operation = .{ .literal = .{ .integer = 2 } } },
        .{ .id = expr_x, .block_id = block_true, .owner_statement = statement_true_return, .source = .{ .line = 4, .column = 1 }, .result_ty = .{ .integer = "u32" }, .operation = .{ .local = local_x } },
    };
    var statements = [_]mir.ExecutableStatement{
        .{ .id = statement_guard, .block_id = block_entry, .source = .{ .line = 1, .column = 1 }, .operation = .{ .guard = .{ .kind = .if_, .condition = expr_flag } } },
        .{ .id = statement_true_local, .block_id = block_true, .source = .{ .line = 2, .column = 1 }, .operation = .{ .local_init = .{ .local = local_x, .ty = .{ .integer = "u32" }, .value = expr_one, .mutable = true } } },
        .{ .id = statement_true_return, .block_id = block_true, .source = .{ .line = 2, .column = 2 }, .operation = .{ .return_ = expr_x } },
        .{ .id = statement_false_return, .block_id = block_false, .source = .{ .line = 3, .column = 1 }, .operation = .{ .return_ = expr_two } },
    };
    var terminators = [_]mir.ExecutableTerminator{
        .{ .block_id = block_entry, .operation = .{ .branch = .{ .condition = expr_flag, .true_block = block_true, .false_block = block_false } } },
        .{ .block_id = block_true, .operation = .return_ },
        .{ .block_id = block_false, .operation = .return_ },
    };
    const body: mir.ExecutableBody = .{
        .locals = &locals,
        .expressions = &expressions,
        .statements = &statements,
        .terminators = &terminators,
    };
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try emitBody(std.testing.allocator, &output, &body, 0);
    try std.testing.expectEqualStrings(
        \\bool mc_exec_tmp_0;
        \\uint32_t mc_exec_tmp_1;
        \\uint32_t mc_exec_tmp_2;
        \\uint32_t mc_exec_tmp_3;
        \\mc_bb_0: ;
        \\    mc_exec_tmp_0 = flag;
        \\    if (mc_exec_tmp_0) goto mc_bb_1; else goto mc_bb_2;
        \\mc_bb_1: ;
        \\    mc_exec_tmp_1 = 1;
        \\    uint32_t x = mc_exec_tmp_1;
        \\    mc_exec_tmp_3 = x;
        \\    return mc_exec_tmp_3;
        \\mc_bb_2: ;
        \\    mc_exec_tmp_2 = 2;
        \\    return mc_exec_tmp_2;
        \\
    , output.items);
}

test "executable C renderer stages call arguments left to right" {
    const next_symbol = mir.SymbolId.fromIndex(0);
    const combine_symbol = mir.SymbolId.fromIndex(1);
    const first = mir.ExprId.fromIndex(0);
    const second = mir.ExprId.fromIndex(1);
    const combined = mir.ExprId.fromIndex(2);
    const entry = mir.BlockId.fromIndex(0);
    const return_statement = mir.InstId.fromIndex(0);
    const source_first: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const source_second: mir.SourcePoint = .{ .line = 1, .column = 2 };
    const source_combined: mir.SourcePoint = .{ .line = 1, .column = 3 };
    var symbols = [_]mir.SymbolIdentity{
        .{ .id = next_symbol, .spelling = "next" },
        .{ .id = combine_symbol, .spelling = "combine" },
    };
    const first_call: @FieldType(mir.ExecutableExpression.Operation, "direct_call") = .{ .callee = next_symbol, .callee_source = source_first };
    const second_call: @FieldType(mir.ExecutableExpression.Operation, "direct_call") = .{ .callee = next_symbol, .callee_source = source_second };
    var combine_call: @FieldType(mir.ExecutableExpression.Operation, "direct_call") = .{ .callee = combine_symbol, .callee_source = source_combined, .argument_count = 2 };
    combine_call.arguments[0] = first;
    combine_call.arguments[1] = second;
    var expressions = [_]mir.ExecutableExpression{
        .{ .id = first, .block_id = entry, .owner_statement = return_statement, .source = source_first, .result_ty = .{ .integer = "u32" }, .operation = .{ .direct_call = first_call } },
        .{ .id = second, .block_id = entry, .owner_statement = return_statement, .source = source_second, .result_ty = .{ .integer = "u32" }, .operation = .{ .direct_call = second_call } },
        .{ .id = combined, .block_id = entry, .owner_statement = return_statement, .source = source_combined, .result_ty = .{ .integer = "u32" }, .operation = .{ .direct_call = combine_call } },
    };
    var statements = [_]mir.ExecutableStatement{
        .{ .id = return_statement, .block_id = entry, .source = source_first, .operation = .{ .return_ = combined } },
    };
    var terminators = [_]mir.ExecutableTerminator{.{ .block_id = entry, .operation = .return_ }};
    const body: mir.ExecutableBody = .{
        .symbols = &symbols,
        .expressions = &expressions,
        .statements = &statements,
        .terminators = &terminators,
    };
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try emitBody(std.testing.allocator, &output, &body, 0);

    const first_pos = std.mem.indexOf(u8, output.items, "mc_exec_tmp_0 = next();") orelse return error.TestUnexpectedResult;
    const second_pos = std.mem.indexOf(u8, output.items, "mc_exec_tmp_1 = next();") orelse return error.TestUnexpectedResult;
    const combine_pos = std.mem.indexOf(u8, output.items, "mc_exec_tmp_2 = combine(mc_exec_tmp_0, mc_exec_tmp_1);") orelse return error.TestUnexpectedResult;
    try std.testing.expect(first_pos < second_pos and second_pos < combine_pos);
}

test "executable C renderer snapshots reads before a later effect" {
    const local_x = mir.LocalId.fromIndex(0);
    const mutate_symbol = mir.SymbolId.fromIndex(0);
    const combine_symbol = mir.SymbolId.fromIndex(1);
    const read_x = mir.ExprId.fromIndex(0);
    const mutate = mir.ExprId.fromIndex(1);
    const combined = mir.ExprId.fromIndex(2);
    const entry = mir.BlockId.fromIndex(0);
    const return_statement = mir.InstId.fromIndex(0);
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    var locals = [_]mir.ExecutableLocalIdentity{.{ .id = local_x, .spelling = "x" }};
    var symbols = [_]mir.SymbolIdentity{
        .{ .id = mutate_symbol, .spelling = "mutate_x" },
        .{ .id = combine_symbol, .spelling = "combine" },
    };
    const mutate_call: @FieldType(mir.ExecutableExpression.Operation, "direct_call") = .{ .callee = mutate_symbol, .callee_source = source };
    var combine_call: @FieldType(mir.ExecutableExpression.Operation, "direct_call") = .{ .callee = combine_symbol, .callee_source = source, .argument_count = 2 };
    combine_call.arguments[0] = read_x;
    combine_call.arguments[1] = mutate;
    var expressions = [_]mir.ExecutableExpression{
        .{ .id = read_x, .block_id = entry, .owner_statement = return_statement, .source = source, .result_ty = .{ .integer = "u32" }, .operation = .{ .local = local_x } },
        .{ .id = mutate, .block_id = entry, .owner_statement = return_statement, .source = source, .result_ty = .{ .integer = "u32" }, .operation = .{ .direct_call = mutate_call } },
        .{ .id = combined, .block_id = entry, .owner_statement = return_statement, .source = source, .result_ty = .{ .integer = "u32" }, .operation = .{ .direct_call = combine_call } },
    };
    var statements = [_]mir.ExecutableStatement{.{ .id = return_statement, .block_id = entry, .source = source, .operation = .{ .return_ = combined } }};
    var terminators = [_]mir.ExecutableTerminator{.{ .block_id = entry, .operation = .return_ }};
    const body: mir.ExecutableBody = .{ .locals = &locals, .symbols = &symbols, .expressions = &expressions, .statements = &statements, .terminators = &terminators };
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try emitBody(std.testing.allocator, &output, &body, 0);
    const read_pos = std.mem.indexOf(u8, output.items, "mc_exec_tmp_0 = x;") orelse return error.TestUnexpectedResult;
    const mutate_pos = std.mem.indexOf(u8, output.items, "mc_exec_tmp_1 = mutate_x();") orelse return error.TestUnexpectedResult;
    const combine_pos = std.mem.indexOf(u8, output.items, "mc_exec_tmp_2 = combine(mc_exec_tmp_0, mc_exec_tmp_1);") orelse return error.TestUnexpectedResult;
    try std.testing.expect(read_pos < mutate_pos and mutate_pos < combine_pos);
}

test "executable C renderer rejects implicit CFG and short circuit effects" {
    const entry = mir.BlockId.fromIndex(0);
    const other = mir.BlockId.fromIndex(1);
    var fallthrough_terminators = [_]mir.ExecutableTerminator{
        .{ .block_id = entry, .operation = .fallthrough },
        .{ .block_id = other, .operation = .return_ },
    };
    const fallthrough_body: mir.ExecutableBody = .{ .terminators = &fallthrough_terminators };
    try std.testing.expect(!canEmitBody(&fallthrough_body));

    const statement = mir.InstId.fromIndex(0);
    const lhs = mir.ExprId.fromIndex(0);
    const rhs = mir.ExprId.fromIndex(1);
    const result = mir.ExprId.fromIndex(2);
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    var expressions = [_]mir.ExecutableExpression{
        .{ .id = lhs, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = .bool, .operation = .{ .literal = .{ .boolean = false } } },
        .{ .id = rhs, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = .bool, .operation = .{ .literal = .{ .boolean = true } } },
        .{ .id = result, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = .bool, .operation = .{ .binary = .{ .op = .logical_and, .left = lhs, .right = rhs } } },
    };
    var statements = [_]mir.ExecutableStatement{.{ .id = statement, .block_id = entry, .source = source, .operation = .{ .return_ = result } }};
    var terminators = [_]mir.ExecutableTerminator{.{ .block_id = entry, .operation = .return_ }};
    const logical_body: mir.ExecutableBody = .{ .expressions = &expressions, .statements = &statements, .terminators = &terminators };
    try std.testing.expect(!canEmitBody(&logical_body));
}

test "executable C renderer maps only closed trap helpers" {
    const entry = mir.BlockId.fromIndex(0);
    var unwrap_terminators = [_]mir.ExecutableTerminator{.{ .block_id = entry, .operation = .{ .trap_ = .Unwrap } }};
    const unwrap_body: mir.ExecutableBody = .{ .terminators = &unwrap_terminators };
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try emitBody(std.testing.allocator, &output, &unwrap_body, 0);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_NullUnwrap();") != null);

    var unknown_terminators = [_]mir.ExecutableTerminator{.{ .block_id = entry, .operation = .{ .trap_ = .Unknown } }};
    const unknown_body: mir.ExecutableBody = .{ .terminators = &unknown_terminators };
    try std.testing.expect(!canEmitBody(&unknown_body));
}

test "executable C renderer admits checked arithmetic with exact overflow edges" {
    const entry = mir.BlockId.fromIndex(0);
    const add_trap = mir.BlockId.fromIndex(1);
    const sub_trap = mir.BlockId.fromIndex(2);
    const mul_trap = mir.BlockId.fromIndex(3);
    const statement = mir.InstId.fromIndex(0);
    const one = mir.ExprId.fromIndex(0);
    const two = mir.ExprId.fromIndex(1);
    const add = mir.ExprId.fromIndex(2);
    const sub = mir.ExprId.fromIndex(3);
    const mul = mir.ExprId.fromIndex(4);
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const u32_ty: mir.ValueType = .{ .integer = "u32" };
    var expressions = [_]mir.ExecutableExpression{
        .{ .id = one, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = u32_ty, .operation = .{ .literal = .{ .integer = 1 } } },
        .{ .id = two, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = u32_ty, .operation = .{ .literal = .{ .integer = 2 } } },
        .{ .id = add, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = u32_ty, .operation = .{ .binary = .{ .op = .add, .left = one, .right = two, .arithmetic = .checked } } },
        .{ .id = sub, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = u32_ty, .operation = .{ .binary = .{ .op = .sub, .left = add, .right = one, .arithmetic = .checked } } },
        .{ .id = mul, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = u32_ty, .operation = .{ .binary = .{ .op = .mul, .left = sub, .right = two, .arithmetic = .checked } } },
    };
    var edges = [_]mir.ExecutableTrapEdge{
        .{ .owner = add, .from_block = entry, .trap_block = add_trap, .kind = .IntegerOverflow, .source = .checked_arithmetic },
        .{ .owner = sub, .from_block = entry, .trap_block = sub_trap, .kind = .IntegerOverflow, .source = .checked_arithmetic },
        .{ .owner = mul, .from_block = entry, .trap_block = mul_trap, .kind = .IntegerOverflow, .source = .checked_arithmetic },
    };
    var statements = [_]mir.ExecutableStatement{.{ .id = statement, .block_id = entry, .source = source, .operation = .{ .return_ = mul } }};
    var terminators = [_]mir.ExecutableTerminator{
        .{ .block_id = entry, .operation = .return_ },
        .{ .block_id = add_trap, .operation = .{ .trap_ = .IntegerOverflow } },
        .{ .block_id = sub_trap, .operation = .{ .trap_ = .IntegerOverflow } },
        .{ .block_id = mul_trap, .operation = .{ .trap_ = .IntegerOverflow } },
    };
    const body: mir.ExecutableBody = .{
        .complete = true,
        .expressions = &expressions,
        .trap_edges = &edges,
        .statements = &statements,
        .terminators = &terminators,
    };
    try std.testing.expect(canEmitBody(&body));
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try emitBody(std.testing.allocator, &output, &body, 0);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_u32(mc_exec_tmp_0, mc_exec_tmp_1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_sub_u32(mc_exec_tmp_2, mc_exec_tmp_0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_mul_u32(mc_exec_tmp_3, mc_exec_tmp_1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_bb_1: ;\n    mc_trap_IntegerOverflow();") != null);
}

test "executable C renderer rejects checked arithmetic edge drift" {
    const entry = mir.BlockId.fromIndex(0);
    const trap = mir.BlockId.fromIndex(1);
    const statement = mir.InstId.fromIndex(0);
    const left = mir.ExprId.fromIndex(0);
    const right = mir.ExprId.fromIndex(1);
    const result = mir.ExprId.fromIndex(2);
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const u32_ty: mir.ValueType = .{ .integer = "u32" };
    var expressions = [_]mir.ExecutableExpression{
        .{ .id = left, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = u32_ty, .operation = .{ .literal = .{ .integer = 1 } } },
        .{ .id = right, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = u32_ty, .operation = .{ .literal = .{ .integer = 2 } } },
        .{ .id = result, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = u32_ty, .operation = .{ .binary = .{ .op = .add, .left = left, .right = right, .arithmetic = .checked } } },
    };
    var edge = [_]mir.ExecutableTrapEdge{.{ .owner = result, .from_block = entry, .trap_block = trap, .kind = .IntegerOverflow, .source = .checked_arithmetic }};
    var statements = [_]mir.ExecutableStatement{.{ .id = statement, .block_id = entry, .source = source, .operation = .{ .return_ = result } }};
    var terminators = [_]mir.ExecutableTerminator{
        .{ .block_id = entry, .operation = .return_ },
        .{ .block_id = trap, .operation = .{ .trap_ = .IntegerOverflow } },
    };
    var body: mir.ExecutableBody = .{ .complete = true, .expressions = &expressions, .trap_edges = &edge, .statements = &statements, .terminators = &terminators };
    try std.testing.expect(canEmitBody(&body));

    body.trap_edges = &.{};
    try std.testing.expect(!canEmitBody(&body));
    body.trap_edges = &edge;

    edge[0].kind = .DivideByZero;
    try std.testing.expect(!canEmitBody(&body));
    edge[0].kind = .IntegerOverflow;

    terminators[1].operation = .{ .trap_ = .DivideByZero };
    try std.testing.expect(!canEmitBody(&body));
    terminators[1].operation = .{ .trap_ = .IntegerOverflow };

    expressions[2].operation.binary.arithmetic = .ordinary;
    try std.testing.expect(!canEmitBody(&body));
    expressions[2].operation.binary.arithmetic = .checked;

    var duplicate_edges = [_]mir.ExecutableTrapEdge{ edge[0], edge[0] };
    body.trap_edges = &duplicate_edges;
    try std.testing.expect(!canEmitBody(&body));
}

test "executable C renderer emits plain global load and preserves plain local store" {
    const input_local = mir.LocalId.fromIndex(0);
    const target_local = mir.LocalId.fromIndex(1);
    const global_symbol = mir.SymbolId.fromIndex(0);
    const global_place = mir.PlaceId.fromIndex(0);
    const local_place = mir.PlaceId.fromIndex(1);
    const entry = mir.BlockId.fromIndex(0);
    const value = mir.ExprId.fromIndex(0);
    const loaded = mir.ExprId.fromIndex(1);
    const store_statement = mir.InstId.fromIndex(0);
    const return_statement = mir.InstId.fromIndex(1);
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const u32_ty: mir.ValueType = .{ .integer = "u32" };
    var parameters = [_]mir.ExecutableParameter{.{ .local = input_local, .ty = u32_ty, .source = source }};
    var locals = [_]mir.ExecutableLocalIdentity{
        .{ .id = input_local, .spelling = "input" },
        .{ .id = target_local, .spelling = "target" },
    };
    var symbols = [_]mir.SymbolIdentity{.{ .id = global_symbol, .spelling = "global_count", .kind = .global, .mutable = false }};
    var places = [_]mir.ExecutablePlace{
        .{ .id = global_place, .source = source, .root = .{ .symbol = global_symbol } },
        .{ .id = local_place, .source = source, .root = .{ .local = target_local } },
    };
    var expressions = [_]mir.ExecutableExpression{
        .{ .id = value, .block_id = entry, .owner_statement = store_statement, .source = source, .result_ty = u32_ty, .operation = .{ .local = input_local } },
        .{ .id = loaded, .block_id = entry, .owner_statement = return_statement, .source = source, .result_ty = u32_ty, .operation = .{ .load = .{ .place = global_place, .access = .{ .kind = .plain, .alignment = 4 } } } },
    };
    var statements = [_]mir.ExecutableStatement{
        .{ .id = store_statement, .block_id = entry, .source = source, .operation = .{ .store = .{ .place = local_place, .value = value, .ty = u32_ty, .access = .{ .kind = .plain, .alignment = 4 } } } },
        .{ .id = return_statement, .block_id = entry, .source = source, .operation = .{ .return_ = loaded } },
    };
    var terminators = [_]mir.ExecutableTerminator{.{ .block_id = entry, .operation = .return_ }};
    const body: mir.ExecutableBody = .{
        .parameters = &parameters,
        .locals = &locals,
        .symbols = &symbols,
        .expressions = &expressions,
        .places = &places,
        .statements = &statements,
        .terminators = &terminators,
    };
    try std.testing.expect(canEmitBody(&body));
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try emitBody(std.testing.allocator, &output, &body, 0);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "target = mc_exec_tmp_0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_exec_tmp_1 = global_count;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_race_") == null);
}

test "executable C renderer emits exact race-unordered scalar helpers" {
    const input_local = mir.LocalId.fromIndex(0);
    const global_symbol = mir.SymbolId.fromIndex(0);
    const global_place = mir.PlaceId.fromIndex(0);
    const entry = mir.BlockId.fromIndex(0);
    const value = mir.ExprId.fromIndex(0);
    const loaded = mir.ExprId.fromIndex(1);
    const store_statement = mir.InstId.fromIndex(0);
    const return_statement = mir.InstId.fromIndex(1);
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const f64_ty: mir.ValueType = .{ .float = "f64" };
    var locals = [_]mir.ExecutableLocalIdentity{.{ .id = input_local, .spelling = "input" }};
    var parameters = [_]mir.ExecutableParameter{.{ .local = input_local, .ty = f64_ty, .source = source }};
    var symbols = [_]mir.SymbolIdentity{.{ .id = global_symbol, .spelling = "shared_value", .kind = .global, .mutable = true }};
    var places = [_]mir.ExecutablePlace{.{ .id = global_place, .source = source, .root = .{ .symbol = global_symbol } }};
    var expressions = [_]mir.ExecutableExpression{
        .{ .id = value, .block_id = entry, .owner_statement = store_statement, .source = source, .result_ty = f64_ty, .operation = .{ .local = input_local } },
        .{ .id = loaded, .block_id = entry, .owner_statement = return_statement, .source = source, .result_ty = f64_ty, .operation = .{ .load = .{ .place = global_place, .access = .{ .kind = .race_unordered, .alignment = 8 } } } },
    };
    var statements = [_]mir.ExecutableStatement{
        .{ .id = store_statement, .block_id = entry, .source = source, .operation = .{ .store = .{ .place = global_place, .value = value, .ty = f64_ty, .access = .{ .kind = .race_unordered, .alignment = 8 } } } },
        .{ .id = return_statement, .block_id = entry, .source = source, .operation = .{ .return_ = loaded } },
    };
    var terminators = [_]mir.ExecutableTerminator{.{ .block_id = entry, .operation = .return_ }};
    var body: mir.ExecutableBody = .{
        .parameters = &parameters,
        .locals = &locals,
        .symbols = &symbols,
        .expressions = &expressions,
        .places = &places,
        .statements = &statements,
        .terminators = &terminators,
    };
    try std.testing.expect(canEmitBody(&body));
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try emitBody(std.testing.allocator, &output, &body, 0);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_race_store_f64(&shared_value, (double)mc_exec_tmp_0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_exec_tmp_1 = ((double)mc_race_load_f64(&shared_value));") != null);

    expressions[1].operation.load.access.alignment = 4;
    try std.testing.expect(!canEmitBody(&body));
    expressions[1].operation.load.access.alignment = 8;
    expressions[1].operation.load.access.kind = .plain;
    try std.testing.expect(!canEmitBody(&body));
    expressions[1].operation.load.access.kind = .race_unordered;
    statements[0].operation.store.access.alignment = 4;
    try std.testing.expect(!canEmitBody(&body));
    statements[0].operation.store.access.alignment = 8;
    statements[0].operation.store.access.kind = .plain;
    try std.testing.expect(!canEmitBody(&body));
    statements[0].operation.store.access.kind = .race_unordered;
    statements[0].operation.store.ty = .{ .float = "f32" };
    try std.testing.expect(!canEmitBody(&body));
    statements[0].operation.store.ty = f64_ty;

    symbols[0].mutable = false;
    expressions[1].operation.load.access.kind = .plain;
    statements[0].operation.store.access.kind = .plain;
    try std.testing.expect(!canEmitBody(&body));
    symbols[0].mutable = true;
    expressions[1].operation.load.access.kind = .race_unordered;
    statements[0].operation.store.access.kind = .race_unordered;
    symbols[0].kind = .function;
    try std.testing.expect(!canEmitBody(&body));
}

test "executable C renderer emits classified restricted casts in value order" {
    const identity_local = mir.LocalId.fromIndex(0);
    const unsigned_local = mir.LocalId.fromIndex(1);
    const signed_local = mir.LocalId.fromIndex(2);
    const identity_value = mir.ExprId.fromIndex(0);
    const identity_cast = mir.ExprId.fromIndex(1);
    const unsigned_value = mir.ExprId.fromIndex(2);
    const unsigned_cast = mir.ExprId.fromIndex(3);
    const signed_value = mir.ExprId.fromIndex(4);
    const signed_cast = mir.ExprId.fromIndex(5);
    const statement = mir.InstId.fromIndex(0);
    const entry = mir.BlockId.fromIndex(0);
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const u8_ty: mir.ValueType = .{ .integer = "u8" };
    const u32_ty: mir.ValueType = .{ .integer = "u32" };
    const i8_ty: mir.ValueType = .{ .integer = "i8" };
    const i64_ty: mir.ValueType = .{ .integer = "i64" };
    var parameters = [_]mir.ExecutableParameter{
        .{ .local = identity_local, .ty = u32_ty, .source = source },
        .{ .local = unsigned_local, .ty = u8_ty, .source = source },
        .{ .local = signed_local, .ty = i8_ty, .source = source },
    };
    var locals = [_]mir.ExecutableLocalIdentity{
        .{ .id = identity_local, .spelling = "same" },
        .{ .id = unsigned_local, .spelling = "small_unsigned" },
        .{ .id = signed_local, .spelling = "small_signed" },
    };
    var expressions = [_]mir.ExecutableExpression{
        .{ .id = identity_value, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = u32_ty, .operation = .{ .local = identity_local } },
        .{ .id = identity_cast, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = u32_ty, .operation = .{ .cast = .{ .operand = identity_value, .kind = .identity } } },
        .{ .id = unsigned_value, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = u8_ty, .operation = .{ .local = unsigned_local } },
        .{ .id = unsigned_cast, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = u32_ty, .operation = .{ .cast = .{ .operand = unsigned_value, .kind = .unsigned_resize } } },
        .{ .id = signed_value, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = i8_ty, .operation = .{ .local = signed_local } },
        .{ .id = signed_cast, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = i64_ty, .operation = .{ .cast = .{ .operand = signed_value, .kind = .signed_widen } } },
    };
    var statements = [_]mir.ExecutableStatement{.{ .id = statement, .block_id = entry, .source = source, .operation = .{ .return_ = signed_cast } }};
    var terminators = [_]mir.ExecutableTerminator{.{ .block_id = entry, .operation = .return_ }};
    const body: mir.ExecutableBody = .{
        .parameters = &parameters,
        .locals = &locals,
        .expressions = &expressions,
        .statements = &statements,
        .terminators = &terminators,
    };
    try std.testing.expect(canEmitBody(&body));
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try emitBody(std.testing.allocator, &output, &body, 0);
    const identity_value_pos = std.mem.indexOf(u8, output.items, "mc_exec_tmp_0 = same;") orelse return error.TestUnexpectedResult;
    const identity_cast_pos = std.mem.indexOf(u8, output.items, "mc_exec_tmp_1 = ((uint32_t)(mc_exec_tmp_0));") orelse return error.TestUnexpectedResult;
    const unsigned_value_pos = std.mem.indexOf(u8, output.items, "mc_exec_tmp_2 = small_unsigned;") orelse return error.TestUnexpectedResult;
    const unsigned_cast_pos = std.mem.indexOf(u8, output.items, "mc_exec_tmp_3 = ((uint32_t)(mc_exec_tmp_2));") orelse return error.TestUnexpectedResult;
    const signed_value_pos = std.mem.indexOf(u8, output.items, "mc_exec_tmp_4 = small_signed;") orelse return error.TestUnexpectedResult;
    const signed_cast_pos = std.mem.indexOf(u8, output.items, "mc_exec_tmp_5 = ((int64_t)(mc_exec_tmp_4));") orelse return error.TestUnexpectedResult;
    try std.testing.expect(identity_value_pos < identity_cast_pos and identity_cast_pos < unsigned_value_pos);
    try std.testing.expect(unsigned_value_pos < unsigned_cast_pos and unsigned_cast_pos < signed_value_pos);
    try std.testing.expect(signed_value_pos < signed_cast_pos);
}

test "executable C renderer rejects restricted cast fact drift" {
    const local = mir.LocalId.fromIndex(0);
    const operand = mir.ExprId.fromIndex(0);
    const result = mir.ExprId.fromIndex(1);
    const statement = mir.InstId.fromIndex(0);
    const entry = mir.BlockId.fromIndex(0);
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const u8_ty: mir.ValueType = .{ .integer = "u8" };
    const u32_ty: mir.ValueType = .{ .integer = "u32" };
    var parameters = [_]mir.ExecutableParameter{.{ .local = local, .ty = u8_ty, .source = source }};
    var locals = [_]mir.ExecutableLocalIdentity{.{ .id = local, .spelling = "value" }};
    var expressions = [_]mir.ExecutableExpression{
        .{ .id = operand, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = u8_ty, .operation = .{ .local = local } },
        .{ .id = result, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = u32_ty, .operation = .{ .cast = .{ .operand = operand, .kind = .unsigned_resize } } },
    };
    var statements = [_]mir.ExecutableStatement{.{ .id = statement, .block_id = entry, .source = source, .operation = .{ .return_ = result } }};
    var terminators = [_]mir.ExecutableTerminator{.{ .block_id = entry, .operation = .return_ }};
    const body: mir.ExecutableBody = .{
        .parameters = &parameters,
        .locals = &locals,
        .expressions = &expressions,
        .statements = &statements,
        .terminators = &terminators,
    };
    try std.testing.expect(canEmitBody(&body));

    expressions[1].operation.cast.kind = .signed_widen;
    try std.testing.expect(!canEmitBody(&body));
    expressions[1].operation.cast.kind = .unsigned_resize;

    expressions[1].result_ty = .{ .integer = "i8" };
    try std.testing.expect(!canEmitBody(&body));
    expressions[1].result_ty = u32_ty;

    expressions[1].operation.cast.operand = mir.ExprId.invalid;
    try std.testing.expect(!canEmitBody(&body));
}

test "executable C renderer emits selected typed builtins in operand order" {
    const phys_local = mir.LocalId.fromIndex(0);
    const wrap_left_local = mir.LocalId.fromIndex(1);
    const wrap_right_local = mir.LocalId.fromIndex(2);
    const conversion_local = mir.LocalId.fromIndex(3);
    const phys_operand = mir.ExprId.fromIndex(0);
    const phys_result = mir.ExprId.fromIndex(1);
    const wrap_left = mir.ExprId.fromIndex(2);
    const wrap_right = mir.ExprId.fromIndex(3);
    const wrap_result = mir.ExprId.fromIndex(4);
    const conversion_operand = mir.ExprId.fromIndex(5);
    const conversion_result = mir.ExprId.fromIndex(6);
    const statement = mir.InstId.fromIndex(0);
    const entry = mir.BlockId.fromIndex(0);
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const u8_ty: mir.ValueType = .{ .integer = "u8" };
    const u32_ty: mir.ValueType = .{ .integer = "u32" };
    const u64_ty: mir.ValueType = .{ .integer = "u64" };
    const paddr_ty: mir.ValueType = .{ .address = .paddr };
    var parameters = [_]mir.ExecutableParameter{
        .{ .local = phys_local, .ty = u64_ty, .source = source },
        .{ .local = wrap_left_local, .ty = u32_ty, .source = source },
        .{ .local = wrap_right_local, .ty = u32_ty, .source = source },
        .{ .local = conversion_local, .ty = u8_ty, .source = source },
    };
    var locals = [_]mir.ExecutableLocalIdentity{
        .{ .id = phys_local, .spelling = "physical_bits" },
        .{ .id = wrap_left_local, .spelling = "wrap_left" },
        .{ .id = wrap_right_local, .spelling = "wrap_right" },
        .{ .id = conversion_local, .spelling = "small" },
    };
    var phys_call: @FieldType(mir.ExecutableExpression.Operation, "builtin_call") = .{ .kind = .phys, .callee_source = source, .argument_count = 1 };
    phys_call.arguments[0] = phys_operand;
    var wrapping_call: @FieldType(mir.ExecutableExpression.Operation, "builtin_call") = .{ .kind = .wrapping_add, .callee_source = source, .argument_count = 2 };
    wrapping_call.arguments[0] = wrap_left;
    wrapping_call.arguments[1] = wrap_right;
    var conversion_call: @FieldType(mir.ExecutableExpression.Operation, "builtin_call") = .{ .kind = .conversion_from, .callee_source = source, .argument_count = 1 };
    conversion_call.arguments[0] = conversion_operand;
    var expressions = [_]mir.ExecutableExpression{
        .{ .id = phys_operand, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = u64_ty, .operation = .{ .local = phys_local } },
        .{ .id = phys_result, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = paddr_ty, .operation = .{ .builtin_call = phys_call } },
        .{ .id = wrap_left, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = u32_ty, .operation = .{ .local = wrap_left_local } },
        .{ .id = wrap_right, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = u32_ty, .operation = .{ .local = wrap_right_local } },
        .{ .id = wrap_result, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = u32_ty, .operation = .{ .builtin_call = wrapping_call } },
        .{ .id = conversion_operand, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = u8_ty, .operation = .{ .local = conversion_local } },
        .{ .id = conversion_result, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = u32_ty, .operation = .{ .builtin_call = conversion_call } },
    };
    var statements = [_]mir.ExecutableStatement{.{ .id = statement, .block_id = entry, .source = source, .operation = .{ .return_ = conversion_result } }};
    var terminators = [_]mir.ExecutableTerminator{.{ .block_id = entry, .operation = .return_ }};
    const body: mir.ExecutableBody = .{
        .parameters = &parameters,
        .locals = &locals,
        .expressions = &expressions,
        .statements = &statements,
        .terminators = &terminators,
    };
    try std.testing.expect(canEmitBody(&body));
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try emitBody(std.testing.allocator, &output, &body, 0);
    const phys_operand_pos = std.mem.indexOf(u8, output.items, "mc_exec_tmp_0 = physical_bits;") orelse return error.TestUnexpectedResult;
    const phys_pos = std.mem.indexOf(u8, output.items, "mc_exec_tmp_1 = ((uintptr_t)(mc_exec_tmp_0));") orelse return error.TestUnexpectedResult;
    const wrap_left_pos = std.mem.indexOf(u8, output.items, "mc_exec_tmp_2 = wrap_left;") orelse return error.TestUnexpectedResult;
    const wrap_right_pos = std.mem.indexOf(u8, output.items, "mc_exec_tmp_3 = wrap_right;") orelse return error.TestUnexpectedResult;
    const wrap_pos = std.mem.indexOf(u8, output.items, "mc_exec_tmp_4 = ((uint32_t)((uint32_t)(mc_exec_tmp_2) + (uint32_t)(mc_exec_tmp_3)));") orelse return error.TestUnexpectedResult;
    const conversion_operand_pos = std.mem.indexOf(u8, output.items, "mc_exec_tmp_5 = small;") orelse return error.TestUnexpectedResult;
    const conversion_pos = std.mem.indexOf(u8, output.items, "mc_exec_tmp_6 = ((uint32_t)(mc_exec_tmp_5));") orelse return error.TestUnexpectedResult;
    try std.testing.expect(phys_operand_pos < phys_pos and phys_pos < wrap_left_pos);
    try std.testing.expect(wrap_left_pos < wrap_right_pos and wrap_right_pos < wrap_pos);
    try std.testing.expect(wrap_pos < conversion_operand_pos and conversion_operand_pos < conversion_pos);
}

test "executable C renderer rejects selected builtin fact mutations" {
    const local = mir.LocalId.fromIndex(0);
    const operand = mir.ExprId.fromIndex(0);
    const result = mir.ExprId.fromIndex(1);
    const statement = mir.InstId.fromIndex(0);
    const entry = mir.BlockId.fromIndex(0);
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const u8_ty: mir.ValueType = .{ .integer = "u8" };
    const u32_ty: mir.ValueType = .{ .integer = "u32" };
    var parameters = [_]mir.ExecutableParameter{.{ .local = local, .ty = u8_ty, .source = source }};
    var locals = [_]mir.ExecutableLocalIdentity{.{ .id = local, .spelling = "value" }};
    var call: @FieldType(mir.ExecutableExpression.Operation, "builtin_call") = .{ .kind = .conversion_from, .callee_source = source, .argument_count = 1 };
    call.arguments[0] = operand;
    var expressions = [_]mir.ExecutableExpression{
        .{ .id = operand, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = u8_ty, .operation = .{ .local = local } },
        .{ .id = result, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = u32_ty, .operation = .{ .builtin_call = call } },
    };
    var statements = [_]mir.ExecutableStatement{.{ .id = statement, .block_id = entry, .source = source, .operation = .{ .return_ = result } }};
    var terminators = [_]mir.ExecutableTerminator{.{ .block_id = entry, .operation = .return_ }};
    const body: mir.ExecutableBody = .{
        .parameters = &parameters,
        .locals = &locals,
        .expressions = &expressions,
        .statements = &statements,
        .terminators = &terminators,
    };
    try std.testing.expect(canEmitBody(&body));

    expressions[1].operation.builtin_call.kind = .phys;
    try std.testing.expect(!canEmitBody(&body));
    expressions[1].result_ty = .{ .address = .paddr };
    try std.testing.expect(!canEmitBody(&body));
    expressions[1].result_ty = u32_ty;
    expressions[1].operation.builtin_call.kind = .conversion_from;

    expressions[1].operation.builtin_call.argument_count = 0;
    try std.testing.expect(!canEmitBody(&body));
    expressions[1].operation.builtin_call.argument_count = 1;

    expressions[1].result_ty = .{ .integer = "i32" };
    try std.testing.expect(!canEmitBody(&body));
    expressions[1].result_ty = u32_ty;

    expressions[1].operation.builtin_call.kind = .wrapping_add;
    expressions[1].operation.builtin_call.argument_count = 2;
    expressions[1].operation.builtin_call.arguments[1] = operand;
    expressions[1].result_ty = u8_ty;
    try std.testing.expect(canEmitBody(&body));
    expressions[1].result_ty = u32_ty;
    try std.testing.expect(!canEmitBody(&body));

    expressions[1].operation.builtin_call.kind = .conversion_from_mod;
    try std.testing.expect(!canEmitBody(&body));
}

test "executable C renderer emits canonical float payloads bit exactly" {
    const negative_zero = mir.ExprId.fromIndex(0);
    const nan32 = mir.ExprId.fromIndex(1);
    const nan64 = mir.ExprId.fromIndex(2);
    const statement = mir.InstId.fromIndex(0);
    const entry = mir.BlockId.fromIndex(0);
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const f32_ty: mir.ValueType = .{ .float = "f32" };
    const f64_ty: mir.ValueType = .{ .float = "f64" };
    var expressions = [_]mir.ExecutableExpression{
        .{ .id = negative_zero, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = f32_ty, .operation = .{ .literal = .{ .float = .{ .f32_bits = 0x80000000 } } } },
        .{ .id = nan32, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = f32_ty, .operation = .{ .literal = .{ .float = .{ .f32_bits = 0x7FC01234 } } } },
        .{ .id = nan64, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = f64_ty, .operation = .{ .literal = .{ .float = .{ .f64_bits = 0xFFF8000000001234 } } } },
    };
    var statements = [_]mir.ExecutableStatement{.{ .id = statement, .block_id = entry, .source = source, .operation = .{ .return_ = nan64 } }};
    var terminators = [_]mir.ExecutableTerminator{.{ .block_id = entry, .operation = .return_ }};
    const body: mir.ExecutableBody = .{
        .expressions = &expressions,
        .statements = &statements,
        .terminators = &terminators,
    };
    try std.testing.expect(canEmitBody(&body));
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try emitBody(std.testing.allocator, &output, &body, 0);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_exec_tmp_0 = __builtin_bit_cast(float, ((uint32_t)0x80000000U));") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_exec_tmp_1 = __builtin_bit_cast(float, ((uint32_t)0x7FC01234U));") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_exec_tmp_2 = __builtin_bit_cast(double, ((uint64_t)0xFFF8000000001234ULL));") != null);
}

test "executable C renderer rejects canonical float type tag drift" {
    const value = mir.ExprId.fromIndex(0);
    const statement = mir.InstId.fromIndex(0);
    const entry = mir.BlockId.fromIndex(0);
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    var expressions = [_]mir.ExecutableExpression{.{
        .id = value,
        .block_id = entry,
        .owner_statement = statement,
        .source = source,
        .result_ty = .{ .float = "f32" },
        .operation = .{ .literal = .{ .float = .{ .f32_bits = 0x3FC00000 } } },
    }};
    var statements = [_]mir.ExecutableStatement{.{ .id = statement, .block_id = entry, .source = source, .operation = .{ .return_ = value } }};
    var terminators = [_]mir.ExecutableTerminator{.{ .block_id = entry, .operation = .return_ }};
    const body: mir.ExecutableBody = .{
        .expressions = &expressions,
        .statements = &statements,
        .terminators = &terminators,
    };
    try std.testing.expect(canEmitBody(&body));

    expressions[0].result_ty = .{ .float = "f64" };
    try std.testing.expect(!canEmitBody(&body));
    expressions[0].result_ty = .{ .integer = "u32" };
    try std.testing.expect(!canEmitBody(&body));

    expressions[0].result_ty = .{ .float = "f32" };
    expressions[0].operation.literal.float = .{ .f64_bits = 0x3FF8000000000000 };
    try std.testing.expect(!canEmitBody(&body));
}

const CheckedTrapTestSpec = struct {
    kind: mir.TrapKind,
    source: mir.TrapSource,
};

fn expectCheckedIntegerBinaryTrapSet(
    op: mir.ExecutableBinaryOp,
    type_name: []const u8,
    specs: []const CheckedTrapTestSpec,
) !void {
    const entry = mir.BlockId.fromIndex(0);
    const statement = mir.InstId.fromIndex(0);
    const left = mir.ExprId.fromIndex(0);
    const right = mir.ExprId.fromIndex(1);
    const result = mir.ExprId.fromIndex(2);
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const ty: mir.ValueType = .{ .integer = type_name };
    var expressions = [_]mir.ExecutableExpression{
        .{ .id = left, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = ty, .operation = .{ .literal = .{ .integer = 8 } } },
        .{ .id = right, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = ty, .operation = .{ .literal = .{ .integer = 2 } } },
        .{ .id = result, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = ty, .operation = .{ .binary = .{ .op = op, .left = left, .right = right, .arithmetic = .checked } } },
    };
    var edges: [3]mir.ExecutableTrapEdge = undefined;
    var terminators: [3]mir.ExecutableTerminator = undefined;
    terminators[0] = .{ .block_id = entry, .operation = .return_ };
    for (specs, 0..) |spec, index| {
        const trap_block = mir.BlockId.fromIndex(index + 1);
        edges[index] = .{
            .owner = result,
            .from_block = entry,
            .trap_block = trap_block,
            .kind = spec.kind,
            .source = spec.source,
        };
        terminators[index + 1] = .{ .block_id = trap_block, .operation = .{ .trap_ = spec.kind } };
    }
    var statements = [_]mir.ExecutableStatement{.{ .id = statement, .block_id = entry, .source = source, .operation = .{ .return_ = result } }};
    var body: mir.ExecutableBody = .{
        .complete = true,
        .expressions = &expressions,
        .trap_edges = edges[0..specs.len],
        .statements = &statements,
        .terminators = terminators[0 .. specs.len + 1],
    };
    try std.testing.expect(canEmitBody(&body));

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try emitBody(std.testing.allocator, &output, &body, 0);
    const helper = try std.fmt.allocPrint(std.testing.allocator, "mc_checked_{s}_{s}", .{ @tagName(op), type_name });
    defer std.testing.allocator.free(helper);
    try std.testing.expect(std.mem.indexOf(u8, output.items, helper) != null);

    body.trap_edges = edges[0 .. specs.len - 1];
    try std.testing.expect(!canEmitBody(&body));
    body.trap_edges = edges[0..specs.len];

    edges[specs.len] = edges[0];
    body.trap_edges = edges[0 .. specs.len + 1];
    try std.testing.expect(!canEmitBody(&body));
    body.trap_edges = edges[0..specs.len];

    const original_kind = edges[0].kind;
    edges[0].kind = if (original_kind == .Bounds) .Assert else .Bounds;
    try std.testing.expect(!canEmitBody(&body));
    edges[0].kind = original_kind;

    const original_source = edges[0].source;
    edges[0].source = if (original_source == .checked_shift) .checked_arithmetic else .checked_shift;
    try std.testing.expect(!canEmitBody(&body));
}

test "executable C renderer enforces exact checked div mod and shift trap sets" {
    const unsigned_div_mod = [_]CheckedTrapTestSpec{
        .{ .kind = .DivideByZero, .source = .checked_arithmetic },
    };
    const signed_div_mod = [_]CheckedTrapTestSpec{
        .{ .kind = .DivideByZero, .source = .checked_arithmetic },
        .{ .kind = .IntegerOverflow, .source = .checked_arithmetic },
    };
    const checked_shl = [_]CheckedTrapTestSpec{
        .{ .kind = .InvalidShift, .source = .checked_shift },
        .{ .kind = .IntegerOverflow, .source = .checked_arithmetic },
    };
    const checked_shr = [_]CheckedTrapTestSpec{
        .{ .kind = .InvalidShift, .source = .checked_shift },
    };

    try expectCheckedIntegerBinaryTrapSet(.div, "u32", &unsigned_div_mod);
    try expectCheckedIntegerBinaryTrapSet(.div, "i32", &signed_div_mod);
    try expectCheckedIntegerBinaryTrapSet(.mod, "u32", &unsigned_div_mod);
    try expectCheckedIntegerBinaryTrapSet(.mod, "i32", &signed_div_mod);
    try expectCheckedIntegerBinaryTrapSet(.shl, "u32", &checked_shl);
    try expectCheckedIntegerBinaryTrapSet(.shl, "i32", &checked_shl);
    try expectCheckedIntegerBinaryTrapSet(.shr, "u32", &checked_shr);
    try expectCheckedIntegerBinaryTrapSet(.shr, "i32", &checked_shr);
}
