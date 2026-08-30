//! Mechanical C rendering for a complete syntax-free MIR executable body.
//!
//! This module deliberately knows nothing about AST declarations, source
//! spelling joins, or the specialized C body plans.  All control flow comes
//! from `BlockId` terminators and all values come from typed executable-body
//! operations.  The surrounding C emitter remains responsible for the
//! function signature and braces.

const std = @import("std");
const c_identifier = @import("c_identifier.zig");
const mir = @import("mir_model.zig");
const scalar_repr = @import("scalar_repr.zig");

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

    try writeIndent(allocator, out, indent);
    try out.appendSlice(allocator, "/* canonical executable MIR */\n");

    // Every value is materialized once in canonical ExprId order.  C leaves
    // operand and argument evaluation order unspecified, so rendering a pure
    // expression tree here would lose the order already verified by MIR.
    for (body.expressions) |expression| {
        if (!expressionNeedsTemporary(expression)) continue;
        // MC slices use a declaration-owned typedef whose spelling is not a
        // MIR semantic identity. Infer the exact C type at the single
        // materialization point instead of reconstructing syntax here.
        if (isSliceType(expression.result_ty) or expression.result_ty == .value) continue;
        try writeIndent(allocator, out, indent);
        if (expression.operation == .optional_none) try out.appendSlice(allocator, "MC_UNUSED ");
        try appendCType(allocator, out, body, expression.result_ty);
        try out.print(allocator, " mc_exec_tmp_{d};\n", .{expression.id.raw});
    }

    for (body.terminators) |terminator| {
        if (blockNeedsLabel(body, terminator.block_id)) {
            try writeIndent(allocator, out, indent);
            // A C11 label must precede a statement, not a declaration.
            try out.print(allocator, "mc_bb_{d}: ;\n", .{terminator.block_id.raw});
        }

        for (body.statements) |statement| {
            if (!statement.block_id.eql(terminator.block_id)) continue;
            try emitStatement(allocator, out, body, statement, indent + 1, source_path);
        }
        try emitTerminator(allocator, out, body, terminator, indent + 1, source_path);
    }
}

fn blockNeedsLabel(body: *const mir.ExecutableBody, block_id: mir.BlockId) bool {
    // Most MIR trap edges are rendered inline by checked helper calls. Only
    // assert guards emit a C `goto` to their trap block, so those are the only
    // trap edges that make a label live in the generated C control flow.
    for (body.statements) |statement| switch (statement.operation) {
        .guard => |guard| if (guard.kind == .assert_) {
            const edge = assertGuardTrapEdge(body, statement, guard) orelse continue;
            if (edge.trap_block.eql(block_id)) return true;
        },
        else => {},
    };
    for (body.terminators) |terminator| switch (terminator.operation) {
        .jump => |target| if (target.eql(block_id)) return true,
        .branch => |branch| if (branch.true_block.eql(block_id) or branch.false_block.eql(block_id)) return true,
        .switch_ => |switch_| {
            if (switch_.default_block.eql(block_id)) return true;
            for (switch_.cases[0..switch_.case_count]) |case| if (case.target.eql(block_id)) return true;
        },
        else => {},
    };
    return false;
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
    if (statementRepresentationGuard(statement)) |guard| {
        try writeSourceLineDirective(allocator, out, source_path, guard.source);
        try emitRepresentationGuard(allocator, out, body, guard, indent);
    }
    try writeSourceLineDirective(allocator, out, source_path, statement.source);
    switch (statement.operation) {
        .local_init => |local| {
            try writeIndent(allocator, out, indent);
            const identity = localById(body, local.local) orelse return error.InvalidLocal;
            if (std.mem.startsWith(u8, identity.spelling, "_")) try out.appendSlice(allocator, "MC_UNUSED ");
            if (isSliceType(local.ty) or local.ty == .value) {
                if (local.value == null) return error.UnsupportedType;
                try out.appendSlice(allocator, "__auto_type ");
            } else {
                try appendCType(allocator, out, body, local.ty);
                try out.append(allocator, ' ');
            }
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
                    if ((store.ty == .value and mir.executableCallableAggregateField(body.aggregate_types, (placeById(body, store.place) orelse return error.InvalidPlace).*) != null) or
                        store.ty == .closed_enum or store.ty == .open_enum)
                    {
                        try out.appendSlice(allocator, "__atomic_store_n(");
                        try emitPlaceAddress(allocator, out, body, store.place);
                        try out.appendSlice(allocator, ", ");
                        try emitExpression(allocator, out, body, store.value, 0);
                        try out.appendSlice(allocator, ", __ATOMIC_RELAXED);\n");
                    } else {
                        const scalar = scalarMemoryInfo(store.ty) orelse return error.UnsupportedType;
                        try out.print(allocator, "mc_race_store_{s}(", .{scalar.helper_suffix});
                        try emitPlaceAddress(allocator, out, body, store.place);
                        try out.print(allocator, ", ({s})", .{scalar.c_type});
                        try emitExpression(allocator, out, body, store.value, 0);
                        try out.appendSlice(allocator, ");\n");
                    }
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
                const edge = assertGuardTrapEdge(body, statement, guard) orelse return error.InvalidBlock;
                try writeIndent(allocator, out, indent);
                try out.appendSlice(allocator, "if (!(");
                try emitExpression(allocator, out, body, guard.condition, 0);
                try out.print(allocator, ")) goto mc_bb_{d};\n", .{edge.trap_block.raw});
            },
            // Branch/loop/switch guards are represented by the block
            // terminator.  The statement only preserves the source operation.
            .if_, .while_, .switch_ => {},
        },
        .contract_marker => |marker| {
            try writeIndent(allocator, out, indent);
            switch (marker.kind) {
                .begin => try out.print(allocator, "/* MC_CONTRACT_BEGIN {s} */\n", .{marker.name}),
                .end => try out.print(allocator, "/* MC_CONTRACT_END {s} */\n", .{marker.name}),
            }
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
    source_path: ?[]const u8,
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
            try writeSourceLineDirective(allocator, out, source_path, terminator.source);
            try writeIndent(allocator, out, indent);
            try out.print(allocator, "{s}();\n", .{helper});
        },
        .unreachable_ => {
            try writeSourceLineDirective(allocator, out, source_path, terminator.source);
            try writeIndent(allocator, out, indent);
            try out.appendSlice(allocator, "mc_trap_Unreachable();\n");
        },
        .switch_ => |switch_| {
            if (!switchTerminatorSupported(body, switch_)) return error.InvalidBlock;
            try writeIndent(allocator, out, indent);
            try out.appendSlice(allocator, "switch (");
            try emitExpression(allocator, out, body, switch_.subject, 0);
            try out.appendSlice(allocator, ") {\n");
            for (switch_.cases[0..switch_.case_count]) |case| {
                try writeIndent(allocator, out, indent + 1);
                try out.appendSlice(allocator, "case ");
                switch (case.value) {
                    .unsigned => |value| try out.print(allocator, "{d}", .{value}),
                    .signed => |value| try out.print(allocator, "{d}", .{value}),
                }
                try out.print(allocator, ": goto mc_bb_{d};\n", .{case.target.raw});
            }
            try writeIndent(allocator, out, indent + 1);
            try out.print(allocator, "default: goto mc_bb_{d};\n", .{switch_.default_block.raw});
            try writeIndent(allocator, out, indent);
            try out.appendSlice(allocator, "}\n");
        },
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
                if ((expression.result_ty == .value and mir.executableCallableAggregateField(body.aggregate_types, (placeById(body, load.place) orelse return error.InvalidPlace).*) != null) or
                    expression.result_ty == .closed_enum or expression.result_ty == .open_enum)
                {
                    try out.appendSlice(allocator, "__atomic_load_n(");
                    try emitPlaceAddress(allocator, out, body, load.place);
                    try out.appendSlice(allocator, ", __ATOMIC_RELAXED)");
                    return;
                }
                if (expression.result_ty == .nullable_pointer) {
                    try out.appendSlice(allocator, "__atomic_load_n(");
                    try emitPlaceAddress(allocator, out, body, load.place);
                    try out.appendSlice(allocator, ", __ATOMIC_RELAXED)");
                    return;
                }
                const scalar = scalarMemoryInfo(expression.result_ty) orelse return error.UnsupportedType;
                try out.print(allocator, "(({s})mc_race_load_{s}(", .{ scalar.c_type, scalar.helper_suffix });
                try emitPlaceAddress(allocator, out, body, load.place);
                try out.appendSlice(allocator, "))");
            },
        },
        .atomic_load => |load| {
            const scalar = scalarMemoryInfo(expression.result_ty) orelse return error.UnsupportedType;
            try out.print(allocator, "(({s})__atomic_load_n(", .{scalar.c_type});
            try emitAtomicPlaceAddress(allocator, out, body, load.place);
            try out.print(allocator, ", {s}))", .{cAtomicOrdering(load.ordering)});
        },
        .atomic_init => |operand| try emitExpression(allocator, out, body, operand, depth + 1),
        .atomic_update => |update| {
            const scalar = scalarMemoryInfo((placeById(body, update.place) orelse return error.InvalidPlace).ty) orelse
                return error.UnsupportedType;
            try out.appendSlice(allocator, switch (update.kind) {
                .store => "__atomic_store_n(",
                .fetch_add => "__atomic_fetch_add(",
                .fetch_sub => "__atomic_fetch_sub(",
            });
            try emitAtomicPlaceAddress(allocator, out, body, update.place);
            try out.print(allocator, ", (({s})", .{scalar.c_type});
            try emitExpression(allocator, out, body, update.value, depth + 1);
            try out.print(allocator, "), {s})", .{cAtomicOrdering(update.ordering)});
        },
        .mmio_read => |read| {
            const scalar = scalarMemoryInfo(read.storage_ty) orelse return error.UnsupportedType;
            try out.print(allocator, "(({s})mc_mmio_read_{s}(", .{ scalar.c_type, scalar.helper_suffix });
            try emitMmioPointer(allocator, out, body, read.base, read.byte_offset, read.storage_ty, false);
            try out.appendSlice(allocator, "))");
        },
        .mmio_write => |write| {
            const scalar = scalarMemoryInfo(write.storage_ty) orelse return error.UnsupportedType;
            try out.print(allocator, "mc_mmio_write_{s}(", .{scalar.helper_suffix});
            try emitMmioPointer(allocator, out, body, write.base, write.byte_offset, write.storage_ty, true);
            try out.print(allocator, ", (({s})", .{scalar.c_type});
            try emitExpression(allocator, out, body, write.value, depth + 1);
            try out.appendSlice(allocator, "))");
        },
        .literal => |literal| try emitLiteral(allocator, out, literal),
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
            if (optionalNullComparison(body, expression.*, binary)) {
                const left = expressionById(body, binary.left) orelse return error.InvalidExpression;
                const value = if (left.operation == .optional_none) binary.right else binary.left;
                if (binary.op == .eq) try out.appendSlice(allocator, "(!") else try out.append(allocator, '(');
                try emitExpression(allocator, out, body, value, depth + 1);
                try out.appendSlice(allocator, ".present)");
            } else if (binary.arithmetic == .checked) {
                const helper = checkedBinaryParts(binary.op, expression.result_ty) orelse return error.InvalidExpression;
                try out.print(allocator, "mc_checked_{s}_{s}(", .{ helper.operation, helper.suffix });
                try emitExpression(allocator, out, body, binary.left, depth + 1);
                try out.appendSlice(allocator, ", ");
                try emitExpression(allocator, out, body, binary.right, depth + 1);
                try out.append(allocator, ')');
            } else if (binary.arithmetic == .saturating) {
                const domain = domainInteger(expression.result_ty, .sat) orelse return error.InvalidExpression;
                const operation: []const u8 = switch (binary.op) {
                    .add => "add",
                    .sub => "sub",
                    .mul => "mul",
                    else => return error.InvalidExpression,
                };
                try out.print(allocator, "mc_sat_{s}_{s}(", .{ operation, domain.child });
                try emitExpression(allocator, out, body, binary.left, depth + 1);
                try out.appendSlice(allocator, ", ");
                try emitExpression(allocator, out, body, binary.right, depth + 1);
                try out.append(allocator, ')');
            } else if (binary.arithmetic == .wrapping and (binary.op == .shl or binary.op == .shr)) {
                const domain = domainInteger(expression.result_ty, .wrap) orelse return error.InvalidExpression;
                try out.print(allocator, "mc_wrap_{s}_{s}(", .{ if (binary.op == .shl) "shl" else "shr", domain.child });
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
            try appendCType(allocator, out, body, expression.result_ty);
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
        .representation_check => |check| try emitExpression(allocator, out, body, check.operand, depth + 1),
        .address_of => |address| try emitPlaceAddress(allocator, out, body, address.place),
        .deref => |operand| {
            try out.appendSlice(allocator, "(*(");
            try emitExpression(allocator, out, body, operand, depth + 1);
            try out.appendSlice(allocator, "))");
        },
        .index => |index| {
            if (!indexSupported(body, expression.*, index)) return error.InvalidExpression;
            try out.append(allocator, '(');
            try emitExpression(allocator, out, body, index.base, depth + 1);
            try out.appendSlice(allocator, switch (index.kind) {
                .fixed_array => ").elems[",
                .slice => ").ptr[",
            });
            if (index.checked) try out.appendSlice(allocator, "mc_check_index_usize(");
            try emitExpression(allocator, out, body, index.index, depth + 1);
            if (index.checked) {
                try out.appendSlice(allocator, ", ");
                switch (index.kind) {
                    .fixed_array => try out.print(allocator, "{d}", .{index.bound.?}),
                    .slice => {
                        try out.append(allocator, '(');
                        try emitExpression(allocator, out, body, index.base, depth + 1);
                        try out.appendSlice(allocator, ").len");
                    },
                }
                try out.append(allocator, ')');
            }
            try out.append(allocator, ']');
        },
        .slice_length => |base| {
            try emitExpression(allocator, out, body, base, depth + 1);
            try out.appendSlice(allocator, ".len");
        },
        .optional_some => |operand| {
            try out.append(allocator, '(');
            try appendCType(allocator, out, body, expression.result_ty);
            try out.appendSlice(allocator, "){ .present = true, .value = ");
            try emitExpression(allocator, out, body, operand, depth + 1);
            try out.appendSlice(allocator, " }");
        },
        .optional_none => {
            try out.append(allocator, '(');
            try appendCType(allocator, out, body, expression.result_ty);
            try out.appendSlice(allocator, "){ .present = false }");
        },
        .variant_test => |operation| {
            try out.append(allocator, '(');
            if (operation.kind == .result_err) try out.append(allocator, '!');
            try emitExpression(allocator, out, body, operation.operand, depth + 1);
            try out.appendSlice(allocator, switch (operation.kind) {
                .optional_present => switch ((expressionById(body, operation.operand) orelse return error.InvalidExpression).result_ty) {
                    .nullable_pointer => " != NULL)",
                    .nullable_value => ".present)",
                    else => return error.InvalidExpression,
                },
                .result_ok, .result_err => ".is_ok)",
            });
        },
        .variant_payload => |operation| {
            try out.append(allocator, '(');
            try emitExpression(allocator, out, body, operation.operand, depth + 1);
            switch (operation.kind) {
                .optional_present => switch ((expressionById(body, operation.operand) orelse return error.InvalidExpression).result_ty) {
                    .nullable_pointer => {},
                    .nullable_value => try out.appendSlice(allocator, ".value"),
                    else => return error.InvalidExpression,
                },
                .result_ok => try out.appendSlice(allocator, ".payload.ok"),
                .result_err => try out.appendSlice(allocator, ".payload.err"),
            }
            try out.append(allocator, ')');
        },
        .try_unwrap => |operand| try emitExpression(allocator, out, body, operand, depth + 1),
        .result => |result| {
            const shape = resultType(body, expression.type_id) orelse return error.InvalidExpression;
            if (!resultConstructionSupported(body, expression.*, result)) return error.InvalidExpression;
            try out.appendSlice(allocator, "((");
            try appendCType(allocator, out, body, shape.ty);
            try out.appendSlice(allocator, "){ .is_ok = ");
            try out.appendSlice(allocator, if (result.is_ok) "true, .payload.ok = " else "false, .payload.err = ");
            try emitExpression(allocator, out, body, result.payload, depth + 1);
            try out.appendSlice(allocator, " })");
        },
        .array => |aggregate| {
            const shape = aggregateType(body, expression.type_id) orelse return error.InvalidExpression;
            if (!arrayConstructionSupported(body, expression.*, aggregate)) return error.InvalidExpression;
            try out.append(allocator, '(');
            try appendCType(allocator, out, body, shape.ty);
            try out.appendSlice(allocator, "){ .elems = { ");
            for (aggregate.operands[0..aggregate.operand_count], 0..) |operand, index| {
                if (index != 0) try out.appendSlice(allocator, ", ");
                try emitExpression(allocator, out, body, operand, depth + 1);
            }
            try out.appendSlice(allocator, " } }");
        },
        .struct_ => |aggregate| {
            const shape = aggregateType(body, expression.type_id) orelse return error.InvalidExpression;
            if (!structConstructionSupported(body, expression.*, aggregate)) return error.InvalidExpression;
            if (shape.construction == .packed_bits) {
                try out.appendSlice(allocator, "((");
                try appendCType(allocator, out, body, shape.ty);
                try out.appendSlice(allocator, ")(0");
                for (aggregate.operands[0..aggregate.operand_count], aggregate.field_indices[0..aggregate.operand_count]) |operand, field_index| {
                    try out.appendSlice(allocator, " | ((");
                    try emitExpression(allocator, out, body, operand, depth + 1);
                    try out.appendSlice(allocator, ") ? (((");
                    try appendCType(allocator, out, body, shape.storage_ty);
                    try out.print(allocator, ")1) << {d}) : 0)", .{field_index});
                }
                try out.appendSlice(allocator, "))");
                return;
            }
            try out.append(allocator, '(');
            try appendCType(allocator, out, body, shape.ty);
            try out.appendSlice(allocator, "){ ");
            for (0..shape.field_count) |field_index| {
                if (field_index != 0) try out.appendSlice(allocator, ", ");
                var operand: ?mir.ExprId = null;
                for (aggregate.field_indices[0..aggregate.operand_count], aggregate.operands[0..aggregate.operand_count]) |candidate_index, candidate| {
                    if (candidate_index == field_index) {
                        operand = candidate;
                        break;
                    }
                }
                try emitExpression(allocator, out, body, operand orelse return error.InvalidExpression, depth + 1);
            }
            try out.appendSlice(allocator, " }");
        },
        .member => |member| {
            const base = expressionById(body, member.base) orelse return error.InvalidExpression;
            const shape = aggregateType(body, base.type_id) orelse return error.InvalidExpression;
            if (!memberSupported(body, expression.*, member)) return error.InvalidExpression;
            if (shape.construction == .packed_bits) {
                try out.appendSlice(allocator, "((");
                try emitExpression(allocator, out, body, member.base, depth + 1);
                try out.appendSlice(allocator, " & (((");
                try appendCType(allocator, out, body, shape.storage_ty);
                try out.print(allocator, ")1) << {d})) != 0)", .{member.field_index});
                return;
            }
            try out.append(allocator, '(');
            try emitExpression(allocator, out, body, member.base, depth + 1);
            try out.appendSlice(allocator, ").");
            try appendIdent(allocator, out, shape.field_spellings[member.field_index]);
        },
        .range_slice, .unsupported => return error.UnsupportedOperation,
    }
}

/// Backend capability admission layered on top of the producer's semantic
/// completeness bit.  This is deliberately structural and typed: it never
/// consults source text, spans, or declaration ASTs.
pub fn canEmitBody(body: *const mir.ExecutableBody) bool {
    if (!body.isComplete() or body.terminators.len == 0) return false;
    for (body.parameters) |parameter| if (!(supportsType(body, parameter.ty) or
        (parameter.ty == .value and callableParameter(body, parameter.local))) or
        localById(body, parameter.local) == null) return false;
    for (body.expressions) |expression| if (!supportsExpression(body, expression)) return false;
    // Every exceptional edge must be owned by an operation whose complete
    // trap set this renderer understands. This prevents a newly added edge
    // kind from being silently ignored while still emitting ordinary C.
    for (body.trap_edges) |edge| {
        switch (edge.owner) {
            .expression => |owner_id| {
                const owner = expressionById(body, owner_id) orelse return false;
                if (!expressionHasExactTrapEdges(body, owner.*)) return false;
            },
            .statement => |owner_id| {
                const owner = statementById(body, owner_id) orelse return false;
                switch (owner.operation) {
                    .store => |store| if (!memoryStoreSupported(body, owner.*, store)) return false,
                    .guard => |guard| if (!assertGuardHasExactTrapEdge(body, owner.*, guard)) return false,
                    else => return false,
                }
            },
        }
    }
    for (body.places) |place| {
        if (place.storage == .atomic) {
            if (!atomicPlaceSupported(body, place)) return false;
        } else if (place.projection_count != 0 and !scalarAccessPlaceSupported(body, place) and
            mir.executableFixedArrayIndexPlace(body, place) == null) return false;
        switch (place.root) {
            .local => |local| if (localById(body, local) == null) return false,
            .symbol => |symbol| {
                const identity = symbolById(body, symbol) orelse return false;
                if (identity.kind != .global) return false;
            },
            .value => |value| if (expressionById(body, value) == null) return false,
        }
    }
    for (body.statements) |statement| {
        if (!hasBlock(body, statement.block_id)) return false;
        switch (statement.operation) {
            .local_init => |local| {
                if (!(supportsType(body, local.ty) or
                    (local.ty == .value and callableLocalUsedAsIndirectCallee(body, local.local))) or
                    localById(body, local.local) == null) return false;
                if (local.value) |value| {
                    const expression = expressionById(body, value) orelse return false;
                    if (!sameValueType(local.ty, expression.result_ty)) return false;
                    if (local.ty == .value and !callableValueExpressionSupported(body, expression.*)) return false;
                } else if (isSliceType(local.ty) or local.ty == .value) return false;
            },
            .store => |store| if (!memoryStoreSupported(body, statement, store)) return false,
            .eval => |value| if (expressionById(body, value) == null) return false,
            .guard => |guard| {
                const condition = expressionById(body, guard.condition) orelse return false;
                if (guard.kind == .assert_) {
                    if (!sameValueType(condition.result_ty, .bool) or
                        !condition.owner_statement.eql(statement.id) or
                        !condition.block_id.eql(statement.block_id) or
                        !assertGuardHasExactTrapEdge(body, statement, guard)) return false;
                }
            },
            .return_ => |value| if (value) |expression| if (expressionById(body, expression) == null) return false,
            .contract_marker => |marker| if (marker.name.len == 0) return false,
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
        .switch_ => |switch_| if (!switchTerminatorSupported(body, switch_)) return false,
    };
    return true;
}

fn switchTerminatorSupported(body: *const mir.ExecutableBody, switch_: mir.ExecutableSwitchTerminator) bool {
    if (switch_.case_count == 0 or switch_.case_count > switch_.cases.len or !hasBlock(body, switch_.default_block)) return false;
    const subject = expressionById(body, switch_.subject) orelse return false;
    switch (subject.result_ty) {
        .integer, .domain_integer, .closed_enum, .open_enum => {},
        else => return false,
    }
    for (switch_.cases[0..switch_.case_count]) |case| if (!hasBlock(body, case.target)) return false;
    return true;
}

fn supportsExpression(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    if (functionSymbolExpressionSupported(body, expression)) return true;
    if (expression.result_ty == .value) return callableValueExpressionSupported(body, expression);
    if (!supportsType(body, expression.result_ty)) return false;
    return switch (expression.operation) {
        .local => |local| localById(body, local) != null,
        // A global aggregate symbol is only an addressable base for one typed
        // fixed-array index. The index operation owns the actual read and its
        // bounds edge; every other bare global value remains fail-closed.
        .symbol => globalAggregateIndexBaseSupported(body, expression),
        .load => |load| memoryLoadSupported(body, expression, load),
        .atomic_load => |load| atomicLoadSupported(body, expression, load),
        .atomic_init => |operand| atomicInitSupported(body, expression, operand),
        .atomic_update => |update| atomicUpdateSupported(body, expression, update),
        .mmio_read => |read| mmioReadSupported(body, expression, read),
        .mmio_write => |write| mmioWriteSupported(body, expression, write),
        .literal => |literal| switch (literal) {
            .float => |value| mir.executableFloatMatchesType(value, expression.result_ty),
            // Raw source string spelling is not a canonical byte payload and
            // must not cross the syntax-free boundary. Character literals
            // have already become canonical integer magnitudes in MIR.
            .string, .enum_value => false,
            else => true,
        },
        .unary => |unary| expressionById(body, unary.operand) != null and
            if (mir.executableCheckedUnaryTrapRequirements(unary.op, expression.result_ty) != null)
                checkedIntegerUnaryHasExactTrapEdges(body, expression)
            else
                ownedTrapEdgeCount(body, expression.id) == 0,
        .binary => |binary| binarySupported(body, expression, binary),
        .cast => |cast| castSupported(body, expression, cast),
        .representation_check => |check| representationCheckSupported(body, expression, check),
        .direct_call => |call| call.argument_count <= call.arguments.len and symbolById(body, call.callee) != null and allExpressionsExist(body, call.arguments[0..call.argument_count]),
        .indirect_call => |call| indirectCallSupported(body, expression, call),
        .slice_length => |base| expressionById(body, base) != null,
        .builtin_call => |call| builtinCallSupported(body, expression, call),
        .address_of => |address| addressOfSupported(body, expression, address),
        .array => |aggregate| arrayConstructionSupported(body, expression, aggregate),
        .struct_ => |aggregate| structConstructionSupported(body, expression, aggregate),
        .member => |member| memberSupported(body, expression, member),
        .optional_some => |operand| optionalConstructionSupported(body, expression, operand),
        .optional_none => optionalConstructionSupported(body, expression, null),
        .variant_test => |operation| variantOperationSupported(body, expression, operation.operand, operation.kind, false),
        .variant_payload => |operation| variantOperationSupported(body, expression, operation.operand, operation.kind, true),
        .try_unwrap => |operand| tryUnwrapSupported(body, expression, operand),
        .result => |result| resultConstructionSupported(body, expression, result),
        .index => |index| indexSupported(body, expression, index),
        .deref, .range_slice, .unsupported => false,
    };
}

fn variantOperationSupported(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    operand_id: mir.ExprId,
    kind: mir.ExecutableVariantKind,
    payload: bool,
) bool {
    const operand = expressionById(body, operand_id) orelse return false;
    if (!payload) return expression.result_ty == .bool and switch (kind) {
        .optional_present => operand.result_ty == .nullable_pointer or operand.result_ty == .nullable_value,
        .result_ok, .result_err => operand.result_ty == .result,
    };
    return switch (kind) {
        .optional_present => switch (operand.result_ty) {
            .nullable_pointer => |shape| sameValueType(expression.result_ty, .{ .pointer = shape }),
            .nullable_value => optional: {
                const aggregate = aggregateType(body, operand.type_id) orelse break :optional false;
                break :optional aggregate.field_count == 2 and
                    sameValueType(expression.result_ty, aggregate.field_types[1]) and
                    expression.type_id.eql(aggregate.field_type_ids[1]);
            },
            else => false,
        },
        .result_ok, .result_err => result: {
            const shape = resultType(body, operand.type_id) orelse break :result false;
            break :result if (kind == .result_ok)
                sameValueType(expression.result_ty, shape.ok_ty) and expression.type_id.eql(shape.ok_type_id)
            else
                sameValueType(expression.result_ty, shape.err_ty) and expression.type_id.eql(shape.err_type_id);
        },
    };
}

fn tryUnwrapSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, operand_id: mir.ExprId) bool {
    const operand = expressionById(body, operand_id) orelse return false;
    const shape = switch (operand.result_ty) {
        .nullable_pointer => |pointer| pointer,
        else => return false,
    };
    return sameValueType(expression.result_ty, .{ .pointer = shape }) and
        tryUnwrapTrapEdge(body, expression) != null;
}

fn callableValueExpressionSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    if (expression.result_ty != .value) return false;
    return switch (expression.operation) {
        .local => |local| localById(body, local) != null and
            (callableParameter(body, local) or callableLocalUsedAsIndirectCallee(body, local)),
        .symbol => functionSymbolExpressionSupported(body, expression),
        .direct_call => |call| call.argument_count <= call.arguments.len and
            symbolById(body, call.callee) != null and allExpressionsExist(body, call.arguments[0..call.argument_count]) and
            callableProducerInitializesUsedLocal(body, expression.id),
        else => false,
    };
}

fn callableParameter(body: *const mir.ExecutableBody, local: mir.LocalId) bool {
    for (body.parameters) |parameter| if (parameter.local.eql(local))
        return parameter.ty == .value and parameter.callable_signature != null;
    return false;
}

fn callableLocalUsedAsIndirectCallee(body: *const mir.ExecutableBody, local: mir.LocalId) bool {
    for (body.expressions) |expression| switch (expression.operation) {
        .indirect_call => |call| {
            const callee = expressionById(body, call.callee) orelse continue;
            switch (callee.operation) {
                .local => |candidate| if (candidate.eql(local) and call.signature.parameter_count == call.argument_count)
                    return true,
                else => {},
            }
        },
        else => {},
    };
    return false;
}

fn callableProducerInitializesUsedLocal(body: *const mir.ExecutableBody, producer: mir.ExprId) bool {
    for (body.statements) |statement| switch (statement.operation) {
        .local_init => |local| if (local.value != null and local.value.?.eql(producer) and
            callableLocalUsedAsIndirectCallee(body, local.local)) return true,
        else => {},
    };
    return false;
}

fn indirectCallSupported(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    call: @FieldType(mir.ExecutableExpression.Operation, "indirect_call"),
) bool {
    if (call.argument_count > call.arguments.len or call.signature.parameter_count != call.argument_count or
        !sameValueType(call.signature.return_ty, expression.result_ty) or
        !call.signature.return_type_id.eql(expression.type_id)) return false;
    const callee = expressionById(body, call.callee) orelse return false;
    if (!callableValueExpressionSupported(body, callee.*)) return false;
    for (call.arguments[0..call.argument_count], 0..) |argument_id, index| {
        const argument = expressionById(body, argument_id) orelse return false;
        if (!sameValueType(argument.result_ty, call.signature.parameter_types[index]) or
            !argument.type_id.eql(call.signature.parameter_type_ids[index])) return false;
    }
    return true;
}

fn functionSymbolExpressionSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    if (expression.result_ty != .value) return false;
    const id = switch (expression.operation) {
        .symbol => |id| id,
        else => return false,
    };
    const identity = symbolById(body, id) orelse return false;
    return identity.kind == .function;
}

fn representationCheckSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, check: anytype) bool {
    const operand = expressionById(body, check.operand) orelse return false;
    return check.operand.index() < expression.id.index() and operand.block_id.eql(expression.block_id) and
        operand.owner_statement.eql(expression.owner_statement) and expression.type_id.eql(operand.type_id) and
        mir.ExecutableRepresentationCheckKind.typesValid(check.kind, expression.result_ty, operand.result_ty) and
        (check.kind != .valid_closed_enum or executableEnumType(body, expression.type_id) != null) and
        representationOperationHasExactTrapEdge(body, expression);
}

fn memberSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, operation: anytype) bool {
    const base = expressionById(body, operation.base) orelse return false;
    const shape = aggregateType(body, base.type_id) orelse return false;
    const construction_supported = shape.construction == .declared_struct or
        (shape.construction == .packed_bits and expression.result_ty == .bool and
            mir.ExecutableCastKind.integerInfo(shape.storage_ty) != null);
    return construction_supported and operation.field_index < shape.field_count and
        isSafeIdentifier(shape.field_spellings[operation.field_index]) and
        sameValueType(base.result_ty, shape.ty) and
        sameValueType(expression.result_ty, shape.field_types[operation.field_index]) and
        expression.type_id.eql(shape.field_type_ids[operation.field_index]);
}

fn indexSupported(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    operation: @FieldType(mir.ExecutableExpression.Operation, "index"),
) bool {
    const global_base = globalAggregateIndexBase(body, operation.base);
    if (global_base) {
        if (operation.kind != .fixed_array or !indexFeedsDirectAggregateLocalStore(body, expression)) return false;
    } else if (!directImmutableLocalArrayIndexReturn(body, expression, operation) and
        (!projectionRootIsDirectCall(body, operation.base) or !indexIsDirectReturn(body, expression) or
            (operation.kind == .slice and !projectionPathHasMember(body, operation.base)))) return false;
    const base = expressionById(body, operation.base) orelse return false;
    const index = expressionById(body, operation.index) orelse return false;
    if (!base.block_id.eql(expression.block_id) or !index.block_id.eql(expression.block_id) or
        !base.owner_statement.eql(expression.owner_statement) or !index.owner_statement.eql(expression.owner_statement) or
        !sameValueType(index.result_ty, .{ .integer = "usize" }) or !supportsType(body, expression.result_ty))
        return false;
    switch (operation.kind) {
        .fixed_array => {
            const bound = operation.bound orelse return false;
            const array = switch (base.result_ty) {
                .array => |shape| shape,
                else => return false,
            };
            const aggregate = aggregateType(body, base.type_id) orelse return false;
            if (array.length == null or array.length.? != bound or bound == 0 or
                !sameValueType(aggregate.ty, base.result_ty) or aggregate.array_length == null or
                aggregate.array_length.? != bound or aggregate.field_count == 0 or
                !sameValueType(expression.result_ty, aggregate.field_types[0]) or
                !expression.type_id.eql(aggregate.field_type_ids[0]))
                return false;
        },
        .slice => {
            if (operation.bound != null) return false;
            const child = switch (base.result_ty) {
                .pointer => |shape| if (shape.kind == .slice) shape.child else return false,
                .slice => |name| name,
                else => return false,
            };
            if (!std.mem.eql(u8, child, expression.result_ty.name())) return false;
        },
    }
    if (operation.checked) return indexTrapEdge(body, expression) != null;
    if (ownedTrapEdgeCount(body, expression.id) != 0 or operation.kind != .fixed_array) return false;
    const bound = operation.bound orelse return false;
    return switch (index.operation) {
        .literal => |literal| switch (literal) {
            .integer => |value| value < bound,
            else => false,
        },
        else => false,
    };
}

fn directImmutableLocalArrayIndexReturn(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    operation: @FieldType(mir.ExecutableExpression.Operation, "index"),
) bool {
    if (operation.kind != .fixed_array or !indexIsDirectReturn(body, expression)) return false;
    const base = expressionById(body, operation.base) orelse return false;
    const local_id = switch (base.operation) {
        .local => |id| id,
        else => return false,
    };
    var initialized = false;
    for (body.statements) |statement| switch (statement.operation) {
        .local_init => |local| if (local.local.eql(local_id)) {
            if (local.mutable or local.value == null or !sameValueType(local.ty, base.result_ty)) return false;
            initialized = true;
        },
        .store => |store| {
            const place = placeById(body, store.place) orelse return false;
            if (place.root == .local and place.root.local.eql(local_id)) return false;
        },
        else => {},
    };
    return initialized;
}

fn globalAggregateIndexBase(body: *const mir.ExecutableBody, id: mir.ExprId) bool {
    const expression = expressionById(body, id) orelse return false;
    const symbol_id = switch (expression.operation) {
        .symbol => |symbol| symbol,
        else => return false,
    };
    const identity = symbolById(body, symbol_id) orelse return false;
    return identity.kind == .global and expression.result_ty == .array and supportsType(body, expression.result_ty);
}

fn globalAggregateIndexBaseSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    if (!globalAggregateIndexBase(body, expression.id)) return false;
    for (body.expressions) |candidate| switch (candidate.operation) {
        .index => |index| if (index.base.eql(expression.id) and index.kind == .fixed_array and
            indexFeedsDirectAggregateLocalStore(body, candidate)) return true,
        else => {},
    };
    return false;
}

fn indexFeedsDirectAggregateLocalStore(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    const owner = statementById(body, expression.owner_statement) orelse return false;
    const store = switch (owner.operation) {
        .store => |value| value,
        else => return false,
    };
    if (!store.value.eql(expression.id) or store.access.kind != .plain) return false;
    const place = placeById(body, store.place) orelse return false;
    return place.projection_count == 0 and place.root == .local and
        (expression.result_ty == .array or expression.result_ty == .struct_) and
        sameValueType(place.ty, expression.result_ty);
}

fn indexIsDirectReturn(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    const owner = statementById(body, expression.owner_statement) orelse return false;
    return switch (owner.operation) {
        .return_ => |value| if (value) |id| id.eql(expression.id) else false,
        else => false,
    };
}

fn projectionRootIsDirectCall(body: *const mir.ExecutableBody, start: mir.ExprId) bool {
    var current = start;
    var depth: usize = 0;
    while (depth <= mir.max_executable_operands) : (depth += 1) {
        const expression = expressionById(body, current) orelse return false;
        current = switch (expression.operation) {
            .direct_call => return true,
            .member => |member| member.base,
            .representation_check => |check| check.operand,
            else => return false,
        };
    }
    return false;
}

fn projectionPathHasMember(body: *const mir.ExecutableBody, start: mir.ExprId) bool {
    var current = start;
    var depth: usize = 0;
    while (depth <= mir.max_executable_operands) : (depth += 1) {
        const expression = expressionById(body, current) orelse return false;
        current = switch (expression.operation) {
            .member => return true,
            .representation_check => |check| check.operand,
            else => return false,
        };
    }
    return false;
}

fn structConstructionSupported(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    operation: @FieldType(mir.ExecutableExpression.Operation, "struct_"),
) bool {
    const shape = aggregateType(body, expression.type_id) orelse return false;
    if ((shape.construction != .declared_struct and shape.construction != .packed_bits) or
        operation.construction != shape.construction or
        shape.field_count == 0 or shape.field_count != operation.operand_count or !sameValueType(shape.ty, expression.result_ty)) return false;
    var seen = [_]bool{false} ** mir.max_executable_operands;
    for (operation.operands[0..operation.operand_count], operation.field_indices[0..operation.operand_count]) |operand_id, field_index| {
        if (field_index >= shape.field_count or seen[field_index]) return false;
        seen[field_index] = true;
        const operand = expressionById(body, operand_id) orelse return false;
        if (!sameValueType(operand.result_ty, shape.field_types[field_index]) or
            !operand.type_id.eql(shape.field_type_ids[field_index]) or !supportsType(body, operand.result_ty)) return false;
    }
    for (seen[0..shape.field_count]) |present| if (!present) return false;
    return true;
}

fn arrayConstructionSupported(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    operation: @FieldType(mir.ExecutableExpression.Operation, "array"),
) bool {
    const shape = aggregateType(body, expression.type_id) orelse return false;
    if (shape.construction != .declared_struct or shape.ty != .array or shape.field_count == 0 or
        shape.array_length == null or shape.array_length.? != operation.operand_count or
        shape.field_count != operation.operand_count or !sameValueType(shape.ty, expression.result_ty)) return false;
    if (!arrayElementTypeSupported(body, shape.field_types[0], 0)) return false;
    for (operation.operands[0..operation.operand_count], 0..) |operand_id, index| {
        const operand = expressionById(body, operand_id) orelse return false;
        if (!sameValueType(operand.result_ty, shape.field_types[index]) or
            !operand.type_id.eql(shape.field_type_ids[index]) or !supportsType(body, operand.result_ty)) return false;
    }
    return true;
}

fn aggregateType(body: *const mir.ExecutableBody, type_id: mir.TypeId) ?*const mir.ExecutableAggregateType {
    if (!type_id.isValid()) return null;
    for (body.aggregate_types) |*aggregate| if (aggregate.type_id.eql(type_id)) return aggregate;
    return null;
}

fn aggregateTypeForValueType(body: *const mir.ExecutableBody, ty: mir.ValueType) ?*const mir.ExecutableAggregateType {
    for (body.aggregate_types) |*aggregate| if (sameValueType(aggregate.ty, ty)) return aggregate;
    return null;
}

fn executableEnumType(body: *const mir.ExecutableBody, type_id: mir.TypeId) ?*const mir.ExecutableEnumType {
    if (!type_id.isValid()) return null;
    for (body.enum_types) |*enum_ty| if (enum_ty.type_id.eql(type_id) and
        enum_ty.ty == .closed_enum and enum_ty.valid_value_count != 0) return enum_ty;
    return null;
}

fn enumTypeForValueType(body: *const mir.ExecutableBody, ty: mir.ValueType) ?*const mir.ExecutableEnumType {
    for (body.enum_types) |*enum_ty| if (sameValueType(enum_ty.ty, ty)) return enum_ty;
    return null;
}

fn resultType(body: *const mir.ExecutableBody, type_id: mir.TypeId) ?*const mir.ExecutableResultType {
    if (!type_id.isValid()) return null;
    for (body.result_types) |*shape| if (shape.type_id.eql(type_id)) return shape;
    return null;
}

fn resultTypeForValueType(body: *const mir.ExecutableBody, ty: mir.ValueType) ?*const mir.ExecutableResultType {
    for (body.result_types) |*shape| if (sameValueType(shape.ty, ty)) return shape;
    return null;
}

fn resultConstructionSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, operation: anytype) bool {
    const shape = resultType(body, expression.type_id) orelse return false;
    const payload = expressionById(body, operation.payload) orelse return false;
    if (!sameValueType(shape.ty, expression.result_ty)) return false;
    return if (operation.is_ok)
        sameValueType(payload.result_ty, shape.ok_ty) and payload.type_id.eql(shape.ok_type_id)
    else
        sameValueType(payload.result_ty, shape.err_ty) and payload.type_id.eql(shape.err_type_id);
}

fn optionalConstructionSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, operand_id: ?mir.ExprId) bool {
    if (expression.result_ty != .nullable_value) return false;
    const shape = aggregateType(body, expression.type_id) orelse return false;
    if (shape.construction != .declared_struct or shape.ty != .nullable_value or shape.field_count != 2 or
        !sameValueType(shape.field_types[0], .bool)) return false;
    const id = operand_id orelse return true;
    const operand = expressionById(body, id) orelse return false;
    return sameValueType(operand.result_ty, shape.field_types[1]) and
        operand.type_id.eql(shape.field_type_ids[1]);
}

fn builtinCallSupported(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    call: @FieldType(mir.ExecutableExpression.Operation, "builtin_call"),
) bool {
    if (mir.executableBuiltinRequiresUnsafe(call.kind) != call.unsafe_authorized) return false;
    switch (call.kind) {
        .phys, .wrapping_add, .wrap_residue, .serial_before, .serial_after, .serial_distance, .serial_compare, .counter_delta_mod, .counter_elapsed_bounded, .enum_raw, .conversion_from, .conversion_try_from, .conversion_trap_from, .conversion_wrap_from, .conversion_sat_from, .conversion_from_mod, .bitcast, .raw_many_offset, .raw_load, .raw_ptr, .raw_store, .forget_unchecked, .cpu_pause, .fence_full, .fence_release, .fence_acquire => {},
        else => return false,
    }
    if (call.argument_count > mir.max_executable_operands) return false;
    var operand_types: [mir.max_executable_operands]mir.ValueType = undefined;
    for (call.arguments[0..call.argument_count], 0..) |argument, index| {
        const operand = expressionById(body, argument) orelse return false;
        operand_types[index] = operand.result_ty;
    }
    if (!mir.executableBuiltinTypesValid(call.kind, expression.result_ty, operand_types[0..call.argument_count])) return false;
    if (call.kind == .enum_raw and !enumRawSupported(body, expression, call)) return false;
    if (call.kind == .conversion_try_from and !conversionTryResultSupported(body, expression)) return false;
    if (call.kind == .serial_compare and !serialCompareResultSupported(body, expression)) return false;
    if (call.kind == .counter_elapsed_bounded and !counterElapsedResultSupported(body, expression)) return false;
    return if (call.kind == .raw_ptr)
        call.representation_source != null and call.representation_span_id.isValid() and
            representationOperationHasExactTrapEdge(body, expression)
    else if (call.kind == .conversion_trap_from)
        call.representation_source == null and !call.representation_span_id.isValid() and
            builtinTrapConversionHasExactEdge(body, expression)
    else
        call.representation_source == null and !call.representation_span_id.isValid() and
            ownedTrapEdgeCount(body, expression.id) == 0;
}

fn conversionTryResultSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    const shape = resultType(body, expression.type_id) orelse return false;
    return sameValueType(shape.ty, expression.result_ty) and shape.ok_ty == .integer and
        sameValueType(shape.err_ty, .{ .integer = "u8" });
}

fn serialCompareResultSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    const shape = resultType(body, expression.type_id) orelse return false;
    const identity = switch (expression.result_ty) {
        .result => |value| value,
        else => return false,
    };
    return sameValueType(shape.ty, expression.result_ty) and
        std.mem.eql(u8, identity.ok, "Order") and std.mem.eql(u8, identity.err, "AmbiguousSerialOrder") and
        sameValueType(shape.ok_ty, .{ .integer = "i8" }) and sameValueType(shape.err_ty, .{ .integer = "u8" });
}

fn counterElapsedResultSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    const shape = resultType(body, expression.type_id) orelse return false;
    const identity = switch (expression.result_ty) {
        .result => |value| value,
        else => return false,
    };
    const duration = domainInteger(shape.ok_ty, .duration) orelse return false;
    return sameValueType(shape.ty, expression.result_ty) and durationTypeSpellingMatches(identity.ok, duration.child) and
        std.mem.eql(u8, identity.err, "AmbiguousCounterInterval") and sameValueType(shape.err_ty, .{ .integer = "u8" });
}

fn enumRawSupported(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    call: @FieldType(mir.ExecutableExpression.Operation, "builtin_call"),
) bool {
    if (call.argument_count != 1) return false;
    const operand = expressionById(body, call.arguments[0]) orelse return false;
    for (body.enum_types) |enum_ty| {
        if (!enum_ty.type_id.eql(operand.type_id)) continue;
        return enum_ty.repr_type_id.eql(expression.type_id) and
            sameValueType(enum_ty.ty, operand.result_ty) and
            sameValueType(enum_ty.repr_ty, expression.result_ty);
    }
    return false;
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
        .conversion_from, .conversion_wrap_from, .conversion_from_mod => {
            try out.appendSlice(allocator, "((");
            try appendCType(allocator, out, body, result_ty);
            try out.appendSlice(allocator, ")(");
            try emitExpression(allocator, out, body, call.arguments[0], depth + 1);
            try out.appendSlice(allocator, "))");
        },
        .conversion_try_from => {
            const operand = expressionById(body, call.arguments[0]) orelse return error.InvalidExpression;
            const shape = resultTypeForValueType(body, result_ty) orelse return error.UnsupportedType;
            const conversion = mir.executableTrapConversion(operand.result_ty, shape.ok_ty) orelse return error.UnsupportedType;
            const has_bounds = conversion.need_lower or conversion.need_upper;
            try out.append(allocator, '(');
            if (has_bounds) {
                try out.append(allocator, '(');
                try emitConversionOutOfRange(allocator, out, body, call.arguments[0], conversion, depth + 1);
                try out.appendSlice(allocator, ") ? (");
                try appendCType(allocator, out, body, result_ty);
                try out.appendSlice(allocator, "){ .is_ok = false, .payload.err = (");
                try appendCType(allocator, out, body, shape.err_ty);
                try out.appendSlice(allocator, ")0 } : ");
            }
            try out.append(allocator, '(');
            try appendCType(allocator, out, body, result_ty);
            try out.appendSlice(allocator, "){ .is_ok = true, .payload.ok = (");
            try appendCType(allocator, out, body, shape.ok_ty);
            try out.appendSlice(allocator, ")(");
            try emitExpression(allocator, out, body, call.arguments[0], depth + 1);
            try out.appendSlice(allocator, ") }");
            try out.append(allocator, ')');
        },
        .serial_compare => {
            const left = expressionById(body, call.arguments[0]) orelse return error.InvalidExpression;
            const domain = domainInteger(left.result_ty, .serial) orelse return error.UnsupportedType;
            const storage = mir.ExecutableCastKind.integerInfo(.{ .integer = domain.child }) orelse return error.UnsupportedType;
            if (storage.signed or storage.bits > 64) return error.UnsupportedType;
            const unsigned_c = primitiveType(domain.child) orelse return error.UnsupportedType;
            const signed_c = signedPrimitiveType(domain.child) orelse return error.UnsupportedType;
            const shape = resultTypeForValueType(body, result_ty) orelse return error.UnsupportedType;
            const half_window = @as(u128, 1) << @intCast(storage.bits - 1);

            try out.append(allocator, '(');
            try emitSerialUnsignedDiff(allocator, out, body, call.arguments[0], call.arguments[1], unsigned_c, depth + 1);
            try out.print(allocator, " == ({s}){d} ? (", .{ unsigned_c, half_window });
            try appendCType(allocator, out, body, result_ty);
            try out.appendSlice(allocator, "){ .is_ok = false, .payload.err = (");
            try appendCType(allocator, out, body, shape.err_ty);
            try out.appendSlice(allocator, ")0 } : (");
            try appendCType(allocator, out, body, result_ty);
            try out.appendSlice(allocator, "){ .is_ok = true, .payload.ok = (");
            try appendCType(allocator, out, body, shape.ok_ty);
            try out.appendSlice(allocator, ")(");
            try emitSerialSignedDiff(allocator, out, body, call.arguments[0], call.arguments[1], unsigned_c, signed_c, depth + 1);
            try out.appendSlice(allocator, " < 0 ? -1 : (");
            try emitSerialSignedDiff(allocator, out, body, call.arguments[0], call.arguments[1], unsigned_c, signed_c, depth + 1);
            try out.appendSlice(allocator, " > 0 ? 1 : 0)) })");
        },
        .counter_elapsed_bounded => {
            const counter = expressionById(body, call.arguments[0]) orelse return error.InvalidExpression;
            const counter_shape = domainInteger(counter.result_ty, .counter) orelse return error.UnsupportedType;
            const shape = resultTypeForValueType(body, result_ty) orelse return error.UnsupportedType;
            const duration = domainInteger(shape.ok_ty, .duration) orelse return error.UnsupportedType;
            if (!std.mem.eql(u8, counter_shape.child, duration.child)) return error.UnsupportedType;
            const unsigned_c = primitiveType(counter_shape.child) orelse return error.UnsupportedType;
            try out.append(allocator, '(');
            try emitSerialUnsignedDiff(allocator, out, body, call.arguments[0], call.arguments[1], unsigned_c, depth + 1);
            try out.appendSlice(allocator, " <= ");
            try emitExpression(allocator, out, body, call.arguments[2], depth + 1);
            try out.appendSlice(allocator, " ? (");
            try appendCType(allocator, out, body, result_ty);
            try out.appendSlice(allocator, "){ .is_ok = true, .payload.ok = (");
            try appendCType(allocator, out, body, shape.ok_ty);
            try out.appendSlice(allocator, ")");
            try emitSerialUnsignedDiff(allocator, out, body, call.arguments[0], call.arguments[1], unsigned_c, depth + 1);
            try out.appendSlice(allocator, " } : (");
            try appendCType(allocator, out, body, result_ty);
            try out.appendSlice(allocator, "){ .is_ok = false, .payload.err = (");
            try appendCType(allocator, out, body, shape.err_ty);
            try out.appendSlice(allocator, ")0 })");
        },
        .conversion_sat_from => {
            const operand = expressionById(body, call.arguments[0]) orelse return error.InvalidExpression;
            const conversion = mir.executableTrapConversion(operand.result_ty, result_ty) orelse return error.UnsupportedType;
            try out.appendSlice(allocator, "((");
            try appendCType(allocator, out, body, result_ty);
            try out.appendSlice(allocator, ")(");
            if (conversion.need_lower) {
                try out.appendSlice(allocator, "((__int128)(");
                try emitExpression(allocator, out, body, call.arguments[0], depth + 1);
                try out.print(allocator, ") < (__int128){d}) ? {d} : ", .{
                    if (conversion.target.signed) signedMinimum(conversion.target.bits) else @as(i128, 0),
                    if (conversion.target.signed) signedMinimum(conversion.target.bits) else @as(i128, 0),
                });
            }
            if (conversion.need_upper) {
                try out.appendSlice(allocator, if (conversion.source.signed) "((__int128)(" else "((unsigned __int128)(");
                try emitExpression(allocator, out, body, call.arguments[0], depth + 1);
                if (conversion.target.signed)
                    try out.print(allocator, ") > (__int128){d}) ? {d} : ", .{ signedMaximum(conversion.target.bits), signedMaximum(conversion.target.bits) })
                else
                    try out.print(allocator, ") > (unsigned __int128){d}) ? {d} : ", .{ unsignedMaximum(conversion.target.bits), unsignedMaximum(conversion.target.bits) });
            }
            try emitExpression(allocator, out, body, call.arguments[0], depth + 1);
            try out.appendSlice(allocator, "))");
        },
        .conversion_trap_from => {
            const operand = expressionById(body, call.arguments[0]) orelse return error.InvalidExpression;
            const conversion = mir.executableTrapConversion(operand.result_ty, result_ty) orelse return error.UnsupportedType;
            try out.appendSlice(allocator, "((");
            try appendCType(allocator, out, body, result_ty);
            try out.appendSlice(allocator, ")(");
            if (conversion.need_lower or conversion.need_upper) {
                try out.append(allocator, '(');
                if (conversion.need_lower) {
                    try out.appendSlice(allocator, "((__int128)(");
                    try emitExpression(allocator, out, body, call.arguments[0], depth + 1);
                    try out.print(allocator, ") < (__int128){d})", .{if (conversion.target.signed) signedMinimum(conversion.target.bits) else @as(i128, 0)});
                }
                if (conversion.need_lower and conversion.need_upper) try out.appendSlice(allocator, " || ");
                if (conversion.need_upper) {
                    try out.appendSlice(allocator, if (conversion.source.signed) "((__int128)(" else "((unsigned __int128)(");
                    try emitExpression(allocator, out, body, call.arguments[0], depth + 1);
                    if (conversion.target.signed)
                        try out.print(allocator, ") > (__int128){d})", .{signedMaximum(conversion.target.bits)})
                    else
                        try out.print(allocator, ") > (unsigned __int128){d})", .{unsignedMaximum(conversion.target.bits)});
                }
                try out.appendSlice(allocator, ") ? (mc_trap_IntegerOverflow(), 0) : (");
                try emitExpression(allocator, out, body, call.arguments[0], depth + 1);
                try out.appendSlice(allocator, ")");
            } else {
                try emitExpression(allocator, out, body, call.arguments[0], depth + 1);
            }
            try out.appendSlice(allocator, "))");
        },
        .wrapping_add => {
            try out.appendSlice(allocator, "((");
            try appendCType(allocator, out, body, result_ty);
            try out.appendSlice(allocator, ")((");
            try appendCType(allocator, out, body, result_ty);
            try out.appendSlice(allocator, ")(");
            try emitExpression(allocator, out, body, call.arguments[0], depth + 1);
            try out.appendSlice(allocator, ") + (");
            try appendCType(allocator, out, body, result_ty);
            try out.appendSlice(allocator, ")(");
            try emitExpression(allocator, out, body, call.arguments[1], depth + 1);
            try out.appendSlice(allocator, ")))");
        },
        .wrap_residue, .enum_raw => {
            try out.appendSlice(allocator, "((");
            try appendCType(allocator, out, body, result_ty);
            try out.appendSlice(allocator, ")(");
            try emitExpression(allocator, out, body, call.arguments[0], depth + 1);
            try out.appendSlice(allocator, "))");
        },
        .serial_before, .serial_after => {
            const operand = expressionById(body, call.arguments[0]) orelse return error.InvalidExpression;
            const shape = domainInteger(operand.result_ty, .serial) orelse return error.UnsupportedType;
            const signed_ty = signedPrimitiveType(shape.child) orelse return error.UnsupportedType;
            try out.print(allocator, "((({s})((", .{signed_ty});
            try emitExpression(allocator, out, body, call.arguments[0], depth + 1);
            try out.appendSlice(allocator, ") - (");
            try emitExpression(allocator, out, body, call.arguments[1], depth + 1);
            try out.print(allocator, "))) {s} 0)", .{if (call.kind == .serial_before) "<" else ">"});
        },
        .serial_distance, .counter_delta_mod => {
            try out.appendSlice(allocator, "((");
            try appendCType(allocator, out, body, result_ty);
            try out.appendSlice(allocator, ")((");
            try emitExpression(allocator, out, body, call.arguments[0], depth + 1);
            try out.appendSlice(allocator, ") - (");
            try emitExpression(allocator, out, body, call.arguments[1], depth + 1);
            try out.appendSlice(allocator, ")))");
        },
        .bitcast => {
            // `__builtin_bit_cast` copies the object representation. A C
            // numerical cast would change values for integer/float pairs and
            // pointer-punning would violate strict aliasing.
            try out.appendSlice(allocator, "__builtin_bit_cast(");
            try appendCType(allocator, out, body, result_ty);
            try out.appendSlice(allocator, ", ");
            try emitExpression(allocator, out, body, call.arguments[0], depth + 1);
            try out.append(allocator, ')');
        },
        .raw_many_offset => {
            try out.append(allocator, '(');
            try emitExpression(allocator, out, body, call.arguments[0], depth + 1);
            try out.appendSlice(allocator, " + ");
            try emitExpression(allocator, out, body, call.arguments[1], depth + 1);
            try out.append(allocator, ')');
        },
        .raw_load => {
            const scalar = scalarMemoryInfo(result_ty) orelse return error.UnsupportedType;
            try out.print(allocator, "mc_raw_load_{s}(", .{scalar.helper_suffix});
            try emitExpression(allocator, out, body, call.arguments[0], depth + 1);
            try out.append(allocator, ')');
        },
        .raw_ptr => {
            try out.appendSlice(allocator, "((");
            try appendCType(allocator, out, body, result_ty);
            try out.appendSlice(allocator, ")((uintptr_t)(");
            try emitExpression(allocator, out, body, call.arguments[0], depth + 1);
            try out.appendSlice(allocator, ")))");
        },
        .raw_store => {
            const value = expressionById(body, call.arguments[1]) orelse return error.InvalidExpression;
            const scalar = scalarMemoryInfo(value.result_ty) orelse return error.UnsupportedType;
            try out.print(allocator, "mc_raw_store_{s}(", .{scalar.helper_suffix});
            try emitExpression(allocator, out, body, call.arguments[0], depth + 1);
            try out.appendSlice(allocator, ", ");
            try emitExpression(allocator, out, body, call.arguments[1], depth + 1);
            try out.append(allocator, ')');
        },
        .forget_unchecked => {
            // Operand expressions are materialized in source order before the
            // owning statement is emitted.  Referencing the materialized value
            // here preserves exactly-once evaluation while intentionally
            // emitting no release operation.
            try out.appendSlice(allocator, "((void)(");
            try emitExpression(allocator, out, body, call.arguments[0], depth + 1);
            try out.appendSlice(allocator, "))");
        },
        .cpu_pause => try out.appendSlice(allocator, "mc_cpu_pause()"),
        .fence_full, .fence_release, .fence_acquire => try out.appendSlice(allocator, switch (call.kind) {
            .fence_full => "mc_barrier_full()",
            .fence_release => "mc_barrier_release_before()",
            .fence_acquire => "mc_barrier_acquire_after()",
            else => unreachable,
        }),
        else => return error.UnsupportedOperation,
    }
}

fn emitConversionOutOfRange(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    operand: mir.ExprId,
    conversion: mir.ExecutableTrapConversion,
    depth: usize,
) (RenderError || std.mem.Allocator.Error)!void {
    if (conversion.need_lower) {
        try out.appendSlice(allocator, "((__int128)(");
        try emitExpression(allocator, out, body, operand, depth + 1);
        try out.print(allocator, ") < (__int128){d})", .{if (conversion.target.signed) signedMinimum(conversion.target.bits) else @as(i128, 0)});
    }
    if (conversion.need_lower and conversion.need_upper) try out.appendSlice(allocator, " || ");
    if (conversion.need_upper) {
        try out.appendSlice(allocator, if (conversion.source.signed) "((__int128)(" else "((unsigned __int128)(");
        try emitExpression(allocator, out, body, operand, depth + 1);
        if (conversion.target.signed)
            try out.print(allocator, ") > (__int128){d})", .{signedMaximum(conversion.target.bits)})
        else
            try out.print(allocator, ") > (unsigned __int128){d})", .{unsignedMaximum(conversion.target.bits)});
    }
}

fn emitSerialUnsignedDiff(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    left: mir.ExprId,
    right: mir.ExprId,
    unsigned_c: []const u8,
    depth: usize,
) (RenderError || std.mem.Allocator.Error)!void {
    try out.print(allocator, "(({s})(", .{unsigned_c});
    try emitExpression(allocator, out, body, left, depth + 1);
    try out.appendSlice(allocator, " - ");
    try emitExpression(allocator, out, body, right, depth + 1);
    try out.appendSlice(allocator, "))");
}

fn emitSerialSignedDiff(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    left: mir.ExprId,
    right: mir.ExprId,
    unsigned_c: []const u8,
    signed_c: []const u8,
    depth: usize,
) (RenderError || std.mem.Allocator.Error)!void {
    try out.print(allocator, "(({s})", .{signed_c});
    try emitSerialUnsignedDiff(allocator, out, body, left, right, unsigned_c, depth + 1);
    try out.append(allocator, ')');
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
    if (expression.result_ty == .nullable_pointer) {
        if (load.access.kind != .race_unordered or load.representation_source != null or
            load.representation_span_id.isValid() or ownedTrapEdgeCount(body, expression.id) != 0)
            return false;
        const place = placeById(body, load.place) orelse return false;
        if (place.storage != .ordinary or place.projection_count != 0 or
            load.access.alignment != mir.ExecutableMemoryAccess.scalarAlignment(expression.result_ty)) return false;
        return switch (place.root) {
            .symbol => |id| if (symbolById(body, id)) |symbol|
                symbol.kind == .global and symbol.mutable and sameValueType(place.ty, expression.result_ty)
            else
                false,
            .local, .value => false,
        };
    }
    if (scalarMemoryInfo(expression.result_ty) == null and enumTypeForValueType(body, expression.result_ty) == null) return false;
    if (load.access.alignment != mir.executableStorageAlignment(body.enum_types, expression.result_ty)) return false;
    const place = placeById(body, load.place) orelse return false;
    if (place.storage != .ordinary) return false;
    if (place.projection_count != 0) {
        if (mir.executableFixedArrayIndexPlace(body, place.*)) |index| {
            const expected_kind: mir.ExecutableMemoryAccessKind = switch (place.root) {
                .local => .plain,
                .symbol => |id| if (symbolById(body, id)) |symbol|
                    if (symbol.kind == .global)
                        if (symbol.mutable) .race_unordered else .plain
                    else
                        return false
                else
                    return false,
                .value => return false,
            };
            return load.access.kind == expected_kind and
                load.representation_source == null and !load.representation_span_id.isValid() and
                if (index.checked)
                    fixedArrayLoadBoundsTrapEdge(body, expression) != null and ownedTrapEdgeCount(body, expression.id) == 1
                else
                    ownedTrapEdgeCount(body, expression.id) == 0;
        }
        if (mir.executableDirectAggregateFieldPlace(
            body.locals,
            body.statements,
            body.aggregate_types,
            place.*,
            false,
        ) != null) return load.access.kind == .plain and
            load.representation_source == null and !load.representation_span_id.isValid() and
            ownedTrapEdgeCount(body, expression.id) == 0;
        if (!scalarAccessPlaceSupported(body, place.*)) return false;
        const local_alias = mir.executableLocalAddressDerefPlace(body, place.*, false);
        const expected_kind: mir.ExecutableMemoryAccessKind = if (local_alias) .plain else .race_unordered;
        if (load.access.kind != expected_kind) return false;
        if (computedRawManyDerefPlaceSupported(body, place.*, false)) {
            return load.representation_source == null and !load.representation_span_id.isValid() and
                ownedTrapEdgeCount(body, expression.id) == 0;
        }
        return representationOperationHasExactTrapEdge(body, expression);
    }
    const symbol = switch (place.root) {
        .symbol => |id| symbolById(body, id) orelse return false,
        .local, .value => return false,
    };
    if (symbol.kind != .global) return false;
    const expected_kind: mir.ExecutableMemoryAccessKind = if (symbol.mutable) .race_unordered else .plain;
    return load.access.kind == expected_kind;
}

fn atomicLoadSupported(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    load: @FieldType(mir.ExecutableExpression.Operation, "atomic_load"),
) bool {
    if (!load.ordering.validForLoad()) return false;
    const target = placeById(body, load.place) orelse return false;
    if (!atomicPlaceSupported(body, target.*) or !sameValueType(target.ty, expression.result_ty) or
        !target.type_id.eql(expression.type_id)) return false;
    if (placeNeedsRepresentationGuard(target.*)) return representationOperationHasExactTrapEdge(body, expression);
    return load.representation_source == null and !load.representation_span_id.isValid() and
        ownedTrapEdgeCount(body, expression.id) == 0;
}

fn atomicInitSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, operand_id: mir.ExprId) bool {
    const operand = expressionById(body, operand_id) orelse return false;
    return scalarMemoryInfo(expression.result_ty) != null and sameValueType(operand.result_ty, expression.result_ty) and
        operand.type_id.eql(expression.type_id) and ownedTrapEdgeCount(body, expression.id) == 0;
}

fn atomicUpdateSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, update: anytype) bool {
    const target = placeById(body, update.place) orelse return false;
    const operand = expressionById(body, update.value) orelse return false;
    const ordering_valid = switch (update.kind) {
        .store => update.ordering.validForStore(),
        .fetch_add, .fetch_sub => update.ordering.validForRmw(),
    };
    if (!ordering_valid or !atomicPlaceSupported(body, target.*) or
        !sameValueType(target.ty, operand.result_ty) or !target.type_id.eql(operand.type_id)) return false;
    if (update.kind == .store) {
        if (expression.result_ty != .void) return false;
    } else if (!sameValueType(expression.result_ty, target.ty) or !expression.type_id.eql(target.type_id)) return false;
    if (placeNeedsRepresentationGuard(target.*)) return representationOperationHasExactTrapEdge(body, expression);
    return update.representation_source == null and !update.representation_span_id.isValid() and
        ownedTrapEdgeCount(body, expression.id) == 0;
}

fn mmioReadSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, read: anytype) bool {
    return read.ordering.validForRead() and mmioBaseSupported(body, read.base) and
        mmioStorageSupported(read.storage_ty) and sameValueType(expression.result_ty, read.storage_ty) and
        expression.type_id.eql(read.storage_type_id) and ownedTrapEdgeCount(body, expression.id) == 0;
}

fn mmioWriteSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, write: anytype) bool {
    const operand = expressionById(body, write.value) orelse return false;
    return write.ordering.validForWrite() and mmioBaseSupported(body, write.base) and
        mmioStorageSupported(write.storage_ty) and expression.result_ty == .void and
        sameValueType(operand.result_ty, write.storage_ty) and operand.type_id.eql(write.storage_type_id) and
        ownedTrapEdgeCount(body, expression.id) == 0;
}

fn mmioBaseSupported(body: *const mir.ExecutableBody, id: mir.LocalId) bool {
    for (body.parameters) |parameter| {
        if (!parameter.local.eql(id)) continue;
        return switch (parameter.ty) {
            .address => |class| class == .mmio_ptr,
            else => false,
        };
    }
    return false;
}

fn mmioStorageSupported(ty: mir.ValueType) bool {
    return switch (ty) {
        .integer => |name| std.mem.eql(u8, name, "u8") or std.mem.eql(u8, name, "u16") or
            std.mem.eql(u8, name, "u32") or std.mem.eql(u8, name, "u64"),
        else => false,
    };
}

fn atomicPlaceSupported(body: *const mir.ExecutableBody, place: mir.ExecutablePlace) bool {
    if (place.storage != .atomic or !place.root_type_id.isValid() or !place.type_id.isValid() or
        scalarMemoryInfo(place.ty) == null) return false;
    switch (place.ty) {
        .bool, .integer => {},
        else => return false,
    }
    if (place.projection_count == 0) return switch (place.root) {
        .local => |id| local_storage: {
            for (body.statements) |statement| switch (statement.operation) {
                .local_init => |init| if (init.local.eql(id)) {
                    break :local_storage sameValueType(init.ty, place.ty) and init.type_id.eql(place.type_id);
                },
                else => {},
            };
            break :local_storage false;
        },
        .symbol => |id| if (symbolById(body, id)) |identity|
            identity.kind == .global and identity.atomic_payload_type_id.eql(place.type_id)
        else
            false,
        .value => false,
    };
    if (place.projection_count == 2) {
        var ordinary = place;
        ordinary.storage = .ordinary;
        return parameterScalarAccessPlaceSupported(body, ordinary);
    }
    if (place.projection_count != 1 or place.projections[0] != .deref) return false;
    const local = switch (place.root) {
        .local => |id| id,
        .symbol, .value => return false,
    };
    var parameter: ?mir.ExecutableParameter = null;
    for (body.parameters) |candidate| if (candidate.local.eql(local)) {
        parameter = candidate;
        break;
    };
    const root = parameter orelse return false;
    if (!root.type_id.eql(place.root_type_id) or !root.atomic_payload_type_id.eql(place.type_id) or
        !sameValueType(root.ty, place.root_ty)) return false;
    const pointer = switch (root.ty) {
        .pointer => |shape| shape,
        else => return false,
    };
    return pointer.kind == .single;
}

fn placeNeedsRepresentationGuard(place: mir.ExecutablePlace) bool {
    if (place.projection_count == 0) return false;
    return switch (place.root_ty) {
        .pointer => |shape| shape.kind == .single,
        .nullable_pointer => true,
        else => false,
    };
}

fn cAtomicOrdering(ordering: mir.ExecutableAtomicOrdering) []const u8 {
    return switch (ordering) {
        .relaxed => "__ATOMIC_RELAXED",
        .acquire => "__ATOMIC_ACQUIRE",
        .seq_cst => "__ATOMIC_SEQ_CST",
        .release => "__ATOMIC_RELEASE",
        .acq_rel => "__ATOMIC_ACQ_REL",
    };
}

fn emitMmioPointer(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    base: mir.LocalId,
    byte_offset: u64,
    storage_ty: mir.ValueType,
    mutable: bool,
) (RenderError || std.mem.Allocator.Error)!void {
    const scalar = scalarMemoryInfo(storage_ty) orelse return error.UnsupportedType;
    try out.print(allocator, "(({s} volatile{s} *)((uintptr_t)", .{
        scalar.c_type,
        if (mutable) "" else " const",
    });
    try appendLocal(allocator, out, body, base);
    if (byte_offset != 0) try out.print(allocator, " + UINT64_C({d})", .{byte_offset});
    try out.appendSlice(allocator, "))");
}

fn addressOfSupported(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    address: @FieldType(mir.ExecutableExpression.Operation, "address_of"),
) bool {
    const place = placeById(body, address.place) orelse return false;
    if (place.storage != .ordinary) return false;
    if (!addressResultMatchesPlace(expression.result_ty, place.ty)) return false;
    if (place.projection_count == 0) {
        return directAddressablePlaceSupported(body, place.*) and address.representation_source == null and
            !address.representation_span_id.isValid() and ownedTrapEdgeCount(body, expression.id) == 0;
    }
    if (computedRawManyDerefPlaceSupported(body, place.*, false)) {
        return address.representation_source == null and !address.representation_span_id.isValid() and
            ownedTrapEdgeCount(body, expression.id) == 0;
    }
    return (singleParameterScalarDerefPlaceSupported(body, place.*) or
        mir.executableLocalAddressDerefPlace(body, place.*, false)) and
        sameValueType(expression.result_ty, place.root_ty) and
        representationOperationHasExactTrapEdge(body, expression);
}

fn addressResultMatchesPlace(result_ty: mir.ValueType, place_ty: mir.ValueType) bool {
    const shape = switch (result_ty) {
        .pointer => |value| value,
        else => return false,
    };
    return shape.kind == .single and std.mem.eql(u8, shape.child, place_ty.name());
}

fn directAddressablePlaceSupported(body: *const mir.ExecutableBody, place: mir.ExecutablePlace) bool {
    if (place.storage != .ordinary or place.projection_count != 0 or !sameValueType(place.root_ty, place.ty)) return false;
    return switch (place.root) {
        .local => |id| local: {
            for (body.parameters) |parameter| if (parameter.local.eql(id)) break :local false;
            for (body.statements) |statement| switch (statement.operation) {
                .local_init => |value| if (value.local.eql(id)) break :local true,
                else => {},
            };
            break :local false;
        },
        .symbol => |id| if (symbolById(body, id)) |identity| identity.kind == .global else false,
        .value => false,
    };
}

fn singleParameterScalarDerefPlaceSupported(body: *const mir.ExecutableBody, place: mir.ExecutablePlace) bool {
    if (place.storage != .ordinary or place.projection_count != 1 or place.projections[0] != .deref or scalarMemoryInfo(place.ty) == null) return false;
    const local = switch (place.root) {
        .local => |id| id,
        .symbol, .value => return false,
    };
    var parameter_ty: ?mir.ValueType = null;
    for (body.parameters) |parameter| if (parameter.local.eql(local)) {
        parameter_ty = parameter.ty;
        break;
    };
    const root_ty = parameter_ty orelse return false;
    if (!mir.ValueType.eql(root_ty, place.root_ty)) return false;
    const shape = switch (root_ty) {
        .pointer => |value| value,
        else => return false,
    };
    return shape.kind == .single and std.mem.eql(u8, shape.child, place.ty.name());
}

fn parameterScalarAccessPlaceSupported(body: *const mir.ExecutableBody, place: mir.ExecutablePlace) bool {
    if (place.storage != .ordinary) return false;
    if (place.projection_count == 1) return singleParameterScalarDerefPlaceSupported(body, place);
    if (place.projection_count != 2 or place.projections[0] != .deref or mir.executableStorageAlignment(body.enum_types, place.ty) == null or
        !place.root_type_id.isValid() or !place.type_id.isValid()) return false;
    const field_index = switch (place.projections[1]) {
        .field => |index| index,
        .deref, .index => return false,
    };
    const local = switch (place.root) {
        .local => |id| id,
        .symbol, .value => return false,
    };
    var parameter: ?mir.ExecutableParameter = null;
    for (body.parameters) |candidate| if (candidate.local.eql(local)) {
        parameter = candidate;
        break;
    };
    const root = parameter orelse return false;
    if (!root.type_id.eql(place.root_type_id) or !mir.ValueType.eql(root.ty, place.root_ty)) return false;
    const pointer = switch (place.root_ty) {
        .pointer => |shape| shape,
        else => return false,
    };
    if (pointer.kind != .single) return false;
    var aggregate: ?*const mir.ExecutableAggregateType = null;
    for (body.aggregate_types) |*candidate| if (mir.ValueType.eql(candidate.ty, .{ .struct_ = pointer.child })) {
        aggregate = candidate;
        break;
    };
    const shape = aggregate orelse return false;
    return (shape.construction == .declared_struct or shape.construction == .c_union) and field_index < shape.field_count and
        isSafeIdentifier(shape.field_spellings[field_index]) and
        shape.field_type_ids[field_index].eql(place.type_id) and
        mir.ValueType.eql(shape.field_types[field_index], place.ty);
}

fn computedRawManyDerefPlaceSupported(body: *const mir.ExecutableBody, place: mir.ExecutablePlace, require_mutable: bool) bool {
    if (place.storage != .ordinary or place.projection_count != 1 or place.projections[0] != .deref or
        !place.root_type_id.isValid() or !place.type_id.isValid() or scalarMemoryInfo(place.ty) == null) return false;
    const root_id = switch (place.root) {
        .value => |id| id,
        .local, .symbol => return false,
    };
    const root = expressionById(body, root_id) orelse return false;
    if (!root.type_id.eql(place.root_type_id) or
        !sameValueType(root.result_ty, place.root_ty)) return false;
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
        std.mem.eql(u8, pointer.child, place.ty.name());
}

fn scalarAccessPlaceSupported(body: *const mir.ExecutableBody, place: mir.ExecutablePlace) bool {
    return mir.executableDirectAggregateFieldPlace(
        body.locals,
        body.statements,
        body.aggregate_types,
        place,
        false,
    ) != null or parameterScalarAccessPlaceSupported(body, place) or
        mir.executableLocalAddressDerefPlace(body, place, false) or
        computedRawManyDerefPlaceSupported(body, place, false);
}

fn memoryStoreSupported(
    body: *const mir.ExecutableBody,
    statement: mir.ExecutableStatement,
    store: @FieldType(mir.ExecutableStatement.Operation, "store"),
) bool {
    const value = expressionById(body, store.value) orelse return false;
    if (!mir.ValueType.eql(store.ty, value.result_ty)) return false;
    const place = placeById(body, store.place) orelse return false;
    if (place.storage != .ordinary) return false;
    const alignment = mir.executableStorageAlignment(body.enum_types, store.ty) orelse aggregate_local: {
        if (place.projection_count != 0 or store.access.kind != .plain) return false;
        switch (place.root) {
            .local => {},
            .symbol, .value => return false,
        }
        switch (store.ty) {
            .array, .struct_, .nullable_value => break :aggregate_local 1,
            else => return false,
        }
    };
    if (store.access.alignment != alignment) return false;
    if (place.projection_count != 0) {
        if (scalarMemoryInfo(store.ty) == null and enumTypeForValueType(body, store.ty) == null and
            mir.executableCallableAggregateField(body.aggregate_types, place.*) == null) return false;
        if (mir.executableFixedArrayIndexPlace(body, place.*)) |index| {
            const access_ok = switch (place.root) {
                .local => store.access.kind == .plain,
                .symbol => |id| if (symbolById(body, id)) |symbol|
                    symbol.kind == .global and symbol.mutable and store.access.kind == .race_unordered
                else
                    false,
                .value => false,
            };
            return access_ok and store.representation_source == null and !store.representation_span_id.isValid() and
                if (index.checked)
                    statementBoundsTrapEdge(body, statement) != null and ownedStatementTrapEdgeCount(body, statement.id) == 1
                else
                    ownedStatementTrapEdgeCount(body, statement.id) == 0;
        }
        if (mir.executableDirectAggregateFieldPlace(
            body.locals,
            body.statements,
            body.aggregate_types,
            place.*,
            true,
        ) != null) return store.access.kind == .plain and
            store.representation_source == null and !store.representation_span_id.isValid() and
            ownedStatementTrapEdgeCount(body, statement.id) == 0;
        const shape = switch (place.root_ty) {
            .pointer => |pointer| pointer,
            else => return false,
        };
        const local_alias = mir.executableLocalAddressDerefPlace(body, place.*, false);
        const expected_kind: mir.ExecutableMemoryAccessKind = if (local_alias) .plain else .race_unordered;
        if (shape.mutability != .mut or store.access.kind != expected_kind) return false;
        if (computedRawManyDerefPlaceSupported(body, place.*, true)) {
            return store.representation_source == null and !store.representation_span_id.isValid() and
                ownedStatementTrapEdgeCount(body, statement.id) == 0;
        }
        return (parameterScalarAccessPlaceSupported(body, place.*) or local_alias) and
            statementRepresentationOperationHasExactTrapEdge(body, statement, store);
    }
    return switch (place.root) {
        .local => |local| localById(body, local) != null and store.access.kind == .plain,
        .symbol => |id| if (symbolById(body, id)) |symbol|
            symbol.kind == .global and symbol.mutable and store.access.kind == .race_unordered and scalarMemoryInfo(store.ty) != null
        else
            false,
        .value => false,
    };
}

fn binarySupported(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    binary: @FieldType(mir.ExecutableExpression.Operation, "binary"),
) bool {
    const left = expressionById(body, binary.left) orelse return false;
    const right = expressionById(body, binary.right) orelse return false;
    if (binary.op == .logical_and or binary.op == .logical_or) {
        return binary.eager_safe and binary.arithmetic == .ordinary and expression.result_ty == .bool and
            mir.executableEagerSafeBoolTree(body.expressions, body.trap_edges, left.id) and
            mir.executableEagerSafeBoolTree(body.expressions, body.trap_edges, right.id) and ownedTrapEdgeCount(body, expression.id) == 0;
    }
    if (binary.eager_safe) return false;
    if (!sameValueType(left.result_ty, right.result_ty)) return false;
    if (optionalNullComparison(body, expression, binary)) return ownedTrapEdgeCount(body, expression.id) == 0;
    // The nullable-value representation is an aggregate. C cannot compare it
    // directly, so keep payload equality closed until MIR models it explicitly.
    if (left.result_ty == .nullable_value) return false;
    if (left.result_ty == .domain_integer) {
        const shape = left.result_ty.domain_integer;
        if (binary.op == .eq or binary.op == .ne or binary.op == .lt or binary.op == .le or binary.op == .gt or binary.op == .ge) {
            return binary.arithmetic == .ordinary and expression.result_ty == .bool and ownedTrapEdgeCount(body, expression.id) == 0;
        }
        if (!sameValueType(expression.result_ty, left.result_ty) or ownedTrapEdgeCount(body, expression.id) != 0) return false;
        return switch (shape.kind) {
            .wrap => binary.arithmetic == .wrapping and switch (binary.op) {
                .add, .sub, .mul, .bit_or, .bit_xor, .bit_and, .shl, .shr => true,
                else => false,
            },
            .sat => binary.arithmetic == .saturating and switch (binary.op) {
                .add, .sub, .mul => true,
                else => false,
            },
            .serial, .counter, .duration => false,
        };
    }
    return switch (binary.arithmetic) {
        .ordinary => ownedTrapEdgeCount(body, expression.id) == 0,
        .checked => checkedIntegerBinaryHasExactTrapEdges(body, expression),
        .wrapping, .saturating => false,
    };
}

fn optionalNullComparison(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    binary: @FieldType(mir.ExecutableExpression.Operation, "binary"),
) bool {
    if (binary.arithmetic != .ordinary or expression.result_ty != .bool or
        (binary.op != .eq and binary.op != .ne)) return false;
    const left = expressionById(body, binary.left) orelse return false;
    const right = expressionById(body, binary.right) orelse return false;
    if (left.result_ty != .nullable_value or !sameValueType(left.result_ty, right.result_ty)) return false;
    const left_none = left.operation == .optional_none;
    const right_none = right.operation == .optional_none;
    return left_none != right_none;
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
    const result_ty = expression.result_ty;
    if (!mir.ValueType.eql(result_ty, left.result_ty) or
        !mir.ValueType.eql(result_ty, right.result_ty)) return false;
    const requirements = mir.executableCheckedBinaryTrapRequirements(binary.op, expression.result_ty) orelse return false;
    var total: usize = 0;
    for (body.trap_edges) |edge| {
        if (!edgeOwnedByExpression(edge, expression.id)) continue;
        total += 1;
        if (!edge.from_block.eql(expression.block_id)) return false;
    }
    if (total != requirements.count) return false;
    for (requirements.items[0..requirements.count]) |requirement| {
        var matching: usize = 0;
        for (body.trap_edges) |edge| {
            if (!edgeOwnedByExpression(edge, expression.id) or edge.kind != requirement.kind or edge.source != requirement.source) continue;
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

fn checkedIntegerUnaryHasExactTrapEdges(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    const unary = switch (expression.operation) {
        .unary => |value| value,
        else => return false,
    };
    const operand = expressionById(body, unary.operand) orelse return false;
    if (!mir.ValueType.eql(expression.result_ty, operand.result_ty)) return false;
    const requirements = mir.executableCheckedUnaryTrapRequirements(unary.op, expression.result_ty) orelse return false;
    var total: usize = 0;
    for (body.trap_edges) |edge| {
        if (!edgeOwnedByExpression(edge, expression.id)) continue;
        total += 1;
        if (!edge.from_block.eql(expression.block_id)) return false;
    }
    if (total != requirements.count) return false;
    for (requirements.items[0..requirements.count]) |requirement| {
        var matching: usize = 0;
        for (body.trap_edges) |edge| {
            if (!edgeOwnedByExpression(edge, expression.id) or edge.kind != requirement.kind or edge.source != requirement.source) continue;
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

fn expressionHasExactTrapEdges(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    return switch (expression.operation) {
        .unary => checkedIntegerUnaryHasExactTrapEdges(body, expression),
        .binary => checkedIntegerBinaryHasExactTrapEdges(body, expression),
        .load => |load| if (placeById(body, load.place)) |place|
            if (mir.executableFixedArrayIndexPlace(body, place.*) != null)
                fixedArrayLoadBoundsTrapEdge(body, expression) != null
            else
                representationOperationHasExactTrapEdge(body, expression)
        else
            false,
        .atomic_load, .atomic_update, .address_of, .representation_check => representationOperationHasExactTrapEdge(body, expression),
        .builtin_call => |call| if (call.kind == .conversion_trap_from)
            builtinTrapConversionHasExactEdge(body, expression)
        else
            representationOperationHasExactTrapEdge(body, expression),
        .try_unwrap => tryUnwrapTrapEdge(body, expression) != null,
        .index => |operation| operation.checked and indexTrapEdge(body, expression) != null,
        else => false,
    };
}

fn indexTrapEdge(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) ?mir.ExecutableTrapEdge {
    if (expression.operation != .index or !expression.operation.index.checked or
        ownedTrapEdgeCount(body, expression.id) != 1) return null;
    for (body.trap_edges) |edge| {
        if (!edgeOwnedByExpression(edge, expression.id)) continue;
        if (!edge.from_block.eql(expression.block_id) or edge.kind != .Bounds or edge.source != .bounds_check) return null;
        const trap = terminatorByBlock(body, edge.trap_block) orelse return null;
        return switch (trap.operation) {
            .trap_ => |kind| if (kind == .Bounds) edge else null,
            else => null,
        };
    }
    return null;
}

fn fixedArrayLoadBoundsTrapEdge(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) ?mir.ExecutableTrapEdge {
    const load = switch (expression.operation) {
        .load => |value| value,
        else => return null,
    };
    const place = placeById(body, load.place) orelse return null;
    const projection = mir.executableFixedArrayIndexPlace(body, place.*) orelse return null;
    if (!projection.checked or ownedTrapEdgeCount(body, expression.id) != 1) return null;
    for (body.trap_edges) |edge| {
        if (!edgeOwnedByExpression(edge, expression.id)) continue;
        if (!edge.from_block.eql(expression.block_id) or edge.kind != .Bounds or edge.source != .bounds_check) return null;
        const trap = terminatorByBlock(body, edge.trap_block) orelse return null;
        return switch (trap.operation) {
            .trap_ => |kind| if (kind == .Bounds) edge else null,
            else => null,
        };
    }
    return null;
}

fn tryUnwrapTrapEdge(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) ?mir.ExecutableTrapEdge {
    if (expression.operation != .try_unwrap or ownedTrapEdgeCount(body, expression.id) != 1) return null;
    for (body.trap_edges) |edge| {
        if (!edgeOwnedByExpression(edge, expression.id)) continue;
        if (!edge.from_block.eql(expression.block_id) or edge.kind != .Unwrap or edge.source != .unwrap) return null;
        const trap = terminatorByBlock(body, edge.trap_block) orelse return null;
        return switch (trap.operation) {
            .trap_ => |kind| if (kind == .Unwrap) edge else null,
            else => null,
        };
    }
    return null;
}

fn builtinTrapConversionHasExactEdge(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    const call = switch (expression.operation) {
        .builtin_call => |value| value,
        else => return false,
    };
    if (call.kind != .conversion_trap_from or ownedTrapEdgeCount(body, expression.id) != 1) return false;
    for (body.trap_edges) |edge| {
        if (!edgeOwnedByExpression(edge, expression.id)) continue;
        if (!edge.from_block.eql(expression.block_id) or edge.kind != .IntegerOverflow or edge.source != .checked_arithmetic) return false;
        const trap = terminatorByBlock(body, edge.trap_block) orelse return false;
        return switch (trap.operation) {
            .trap_ => |kind| kind == .IntegerOverflow,
            else => false,
        };
    }
    return false;
}

const RepresentationMetadata = struct {
    source: ?mir.SourcePoint,
    span_id: mir.SpanId,
};

fn representationOperationHasExactTrapEdge(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    const metadata: RepresentationMetadata = switch (expression.operation) {
        .load => |load| blk: {
            const place = placeById(body, load.place) orelse return false;
            if (!(parameterScalarAccessPlaceSupported(body, place.*) or
                mir.executableLocalAddressDerefPlace(body, place.*, false))) return false;
            break :blk .{ .source = load.representation_source, .span_id = load.representation_span_id };
        },
        .atomic_load => |load| blk: {
            const place = placeById(body, load.place) orelse return false;
            if (!atomicPlaceSupported(body, place.*) or !placeNeedsRepresentationGuard(place.*)) return false;
            break :blk .{ .source = load.representation_source, .span_id = load.representation_span_id };
        },
        .atomic_update => |update| blk: {
            const place = placeById(body, update.place) orelse return false;
            if (!atomicPlaceSupported(body, place.*) or !placeNeedsRepresentationGuard(place.*)) return false;
            break :blk .{ .source = update.representation_source, .span_id = update.representation_span_id };
        },
        .address_of => |address| blk: {
            const place = placeById(body, address.place) orelse return false;
            if (!(singleParameterScalarDerefPlaceSupported(body, place.*) or
                mir.executableLocalAddressDerefPlace(body, place.*, false))) return false;
            break :blk .{ .source = address.representation_source, .span_id = address.representation_span_id };
        },
        .builtin_call => |call| blk: {
            if (call.kind != .raw_ptr) return false;
            break :blk .{ .source = call.representation_source, .span_id = call.representation_span_id };
        },
        .representation_check => .{ .source = expression.source, .span_id = expression.span_id },
        else => return false,
    };
    if (metadata.source == null or !metadata.span_id.isValid() or ownedTrapEdgeCount(body, expression.id) != 1) return false;
    for (body.trap_edges) |edge| {
        if (!edgeOwnedByExpression(edge, expression.id)) continue;
        if (!edge.from_block.eql(expression.block_id) or edge.kind != .InvalidRepresentation or edge.source != .representation_check) return false;
        const trap = terminatorByBlock(body, edge.trap_block) orelse return false;
        return switch (trap.operation) {
            .trap_ => |kind| kind == .InvalidRepresentation,
            else => false,
        };
    }
    return false;
}

fn statementRepresentationOperationHasExactTrapEdge(
    body: *const mir.ExecutableBody,
    statement: mir.ExecutableStatement,
    store: @FieldType(mir.ExecutableStatement.Operation, "store"),
) bool {
    const place = placeById(body, store.place) orelse return false;
    if (!(parameterScalarAccessPlaceSupported(body, place.*) or
        mir.executableLocalAddressDerefPlace(body, place.*, false)) or
        store.representation_source == null or !store.representation_span_id.isValid() or
        ownedStatementTrapEdgeCount(body, statement.id) != 1) return false;
    for (body.trap_edges) |edge| {
        if (!edgeOwnedByStatement(edge, statement.id)) continue;
        if (!edge.from_block.eql(statement.block_id) or edge.kind != .InvalidRepresentation or edge.source != .representation_check) return false;
        const trap = terminatorByBlock(body, edge.trap_block) orelse return false;
        return switch (trap.operation) {
            .trap_ => |kind| kind == .InvalidRepresentation,
            else => false,
        };
    }
    return false;
}

fn statementBoundsTrapEdge(body: *const mir.ExecutableBody, statement: mir.ExecutableStatement) ?mir.ExecutableTrapEdge {
    var found: ?mir.ExecutableTrapEdge = null;
    for (body.trap_edges) |edge| {
        if (!edgeOwnedByStatement(edge, statement.id)) continue;
        if (found != null or !edge.from_block.eql(statement.block_id) or
            edge.kind != .Bounds or edge.source != .bounds_check) return null;
        const trap = terminatorByBlock(body, edge.trap_block) orelse return null;
        switch (trap.operation) {
            .trap_ => |kind| if (kind != .Bounds) return null,
            else => return null,
        }
        found = edge;
    }
    return found;
}

fn assertGuardHasExactTrapEdge(
    body: *const mir.ExecutableBody,
    statement: mir.ExecutableStatement,
    guard: @FieldType(mir.ExecutableStatement.Operation, "guard"),
) bool {
    return assertGuardTrapEdge(body, statement, guard) != null;
}

fn assertGuardTrapEdge(
    body: *const mir.ExecutableBody,
    statement: mir.ExecutableStatement,
    guard: @FieldType(mir.ExecutableStatement.Operation, "guard"),
) ?mir.ExecutableTrapEdge {
    if (guard.kind != .assert_ or ownedStatementTrapEdgeCount(body, statement.id) != 1) return null;
    const condition = expressionById(body, guard.condition) orelse return null;
    if (!sameValueType(condition.result_ty, .bool) or
        !condition.owner_statement.eql(statement.id) or
        !condition.block_id.eql(statement.block_id)) return null;
    for (body.trap_edges) |edge| {
        if (!edgeOwnedByStatement(edge, statement.id)) continue;
        if (!edge.from_block.eql(statement.block_id) or edge.kind != .Assert or edge.source != .assert_stmt) return null;
        const trap = terminatorByBlock(body, edge.trap_block) orelse return null;
        switch (trap.operation) {
            .trap_ => |kind| if (kind != .Assert) return null,
            else => return null,
        }
        return edge;
    }
    return null;
}

fn edgeOwnedByExpression(edge: mir.ExecutableTrapEdge, owner: mir.ExprId) bool {
    return switch (edge.owner) {
        .expression => |id| id.eql(owner),
        .statement => false,
    };
}

fn edgeOwnedByStatement(edge: mir.ExecutableTrapEdge, owner: mir.InstId) bool {
    return switch (edge.owner) {
        .expression => false,
        .statement => |id| id.eql(owner),
    };
}

fn ownedStatementTrapEdgeCount(body: *const mir.ExecutableBody, owner: mir.InstId) usize {
    var count: usize = 0;
    for (body.trap_edges) |edge| if (edgeOwnedByStatement(edge, owner)) {
        count += 1;
    };
    return count;
}

fn ownedTrapEdgeCount(body: *const mir.ExecutableBody, owner: mir.ExprId) usize {
    var count: usize = 0;
    for (body.trap_edges) |edge| if (edgeOwnedByExpression(edge, owner)) {
        count += 1;
    };
    return count;
}

fn allExpressionsExist(body: *const mir.ExecutableBody, expressions: []const mir.ExprId) bool {
    for (expressions) |expression| if (expressionById(body, expression) == null) return false;
    return true;
}

fn sameValueType(left: mir.ValueType, right: mir.ValueType) bool {
    return mir.ValueType.eql(left, right);
}

fn signedMinimum(bits: u16) i128 {
    return -(@as(i128, 1) << @intCast(bits - 1));
}

fn signedMaximum(bits: u16) i128 {
    return (@as(i128, 1) << @intCast(bits - 1)) - 1;
}

fn unsignedMaximum(bits: u16) u128 {
    return (@as(u128, 1) << @intCast(bits)) - 1;
}

fn supportsType(body: *const mir.ExecutableBody, ty: mir.ValueType) bool {
    return switch (ty) {
        .void, .never, .bool, .cstr, .address => true,
        .integer, .float => |name| primitiveType(name) != null,
        .domain_integer => |shape| primitiveType(shape.child) != null,
        .pointer => |shape| primitiveType(shape.child) != null or isSafeIdentifier(shape.child),
        .nullable_pointer => |shape| shape.kind != .slice and (primitiveType(shape.child) != null or isSafeIdentifier(shape.child)),
        .closed_enum, .open_enum, .struct_ => |name| isSafeIdentifier(name),
        .array => if (aggregateTypeForValueType(body, ty)) |shape|
            shape.array_length != null and shape.array_length.? != 0 and
                shape.field_count != 0 and arrayElementTypeSupported(body, shape.field_types[0], 0)
        else
            false,
        .nullable_value => aggregateTypeForValueType(body, ty) != null,
        .result => resultTypeForValueType(body, ty) != null,
        else => false,
    };
}

fn isSliceType(ty: mir.ValueType) bool {
    return switch (ty) {
        .pointer => |shape| shape.kind == .slice,
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
        // A function identity is a pure leaf and is emitted directly at its
        // use site. Emitting it here as a discarded expression would add no
        // ordering guarantee and would produce an avoidable C warning.
        if (functionSymbolExpressionSupported(body, expression) or
            globalAggregateIndexBaseSupported(body, expression)) continue;
        if (representationGuard(expression)) |guard| {
            try writeSourceLineDirective(allocator, out, source_path, guard.source);
            try emitRepresentationGuard(allocator, out, body, guard, indent);
        }
        if (tryUnwrapTrapEdge(body, expression) != null) {
            const operand = switch (expression.operation) {
                .try_unwrap => |value| value,
                else => return error.InvalidExpression,
            };
            try writeSourceLineDirective(allocator, out, source_path, expression.source);
            try writeIndent(allocator, out, indent);
            try out.appendSlice(allocator, "if (");
            try emitExpression(allocator, out, body, operand, 0);
            try out.appendSlice(allocator, " == NULL) mc_trap_NullUnwrap();\n");
        }
        switch (expression.operation) {
            .mmio_write => |write| if (write.ordering == .release) {
                try writeSourceLineDirective(allocator, out, source_path, expression.source);
                try writeIndent(allocator, out, indent);
                try out.appendSlice(allocator, "mc_barrier_release_before();\n");
            },
            else => {},
        }
        try writeSourceLineDirective(allocator, out, source_path, expression.source);
        try writeIndent(allocator, out, indent);
        if (expressionNeedsTemporary(expression)) {
            if (isSliceType(expression.result_ty) or expression.result_ty == .value) {
                try out.print(allocator, "__auto_type mc_exec_tmp_{d} = ", .{expression.id.raw});
            } else {
                try out.print(allocator, "mc_exec_tmp_{d} = ", .{expression.id.raw});
            }
        }
        try emitExpressionOperation(allocator, out, body, &expression, 0);
        try out.appendSlice(allocator, ";\n");
        switch (expression.operation) {
            .mmio_read => |read| if (read.ordering == .acquire) {
                try writeIndent(allocator, out, indent);
                try out.appendSlice(allocator, "mc_barrier_acquire_after();\n");
            },
            else => {},
        }
        if (resultRepresentationGuard(expression)) |guard| {
            try writeSourceLineDirective(allocator, out, source_path, guard.source);
            try writeIndent(allocator, out, indent);
            switch (guard.kind) {
                .nonnull_pointer => try out.print(allocator, "if (mc_exec_tmp_{d} == NULL) mc_trap_InvalidRepresentation();\n", .{expression.id.raw}),
                .valid_slice => try out.print(allocator, "if (mc_exec_tmp_{d}.ptr == NULL && mc_exec_tmp_{d}.len != 0) mc_trap_InvalidRepresentation();\n", .{ expression.id.raw, expression.id.raw }),
                .valid_closed_enum => {
                    const enum_ty = executableEnumType(body, expression.type_id) orelse return error.InvalidExpression;
                    try out.appendSlice(allocator, "if (");
                    for (enum_ty.valid_values[0..enum_ty.valid_value_count], 0..) |value, index| {
                        if (index != 0) try out.appendSlice(allocator, " && ");
                        try out.print(allocator, "mc_exec_tmp_{d} != {d}", .{ expression.id.raw, value });
                    }
                    try out.appendSlice(allocator, ") mc_trap_InvalidRepresentation();\n");
                },
            }
        }
    }
}

const RepresentationGuard = struct {
    place: mir.PlaceId,
    source: mir.SourcePoint,
};

fn representationGuard(expression: mir.ExecutableExpression) ?RepresentationGuard {
    return switch (expression.operation) {
        .load => |load| if (load.representation_source) |source| .{ .place = load.place, .source = source } else null,
        .atomic_load => |load| if (load.representation_source) |source| .{ .place = load.place, .source = source } else null,
        .atomic_update => |update| if (update.representation_source) |source| .{ .place = update.place, .source = source } else null,
        .address_of => |address| if (address.representation_source) |source| .{ .place = address.place, .source = source } else null,
        else => null,
    };
}

const ResultRepresentationGuard = struct {
    source: mir.SourcePoint,
    kind: mir.ExecutableRepresentationCheckKind,
};

fn resultRepresentationGuard(expression: mir.ExecutableExpression) ?ResultRepresentationGuard {
    return switch (expression.operation) {
        .builtin_call => |call| if (call.kind == .raw_ptr and call.representation_source != null)
            .{ .source = call.representation_source.?, .kind = .nonnull_pointer }
        else
            null,
        .representation_check => |check| .{ .source = expression.source, .kind = check.kind },
        else => null,
    };
}

fn statementRepresentationGuard(statement: mir.ExecutableStatement) ?RepresentationGuard {
    return switch (statement.operation) {
        .store => |store| if (store.representation_source) |source| .{ .place = store.place, .source = source } else null,
        else => null,
    };
}

fn emitRepresentationGuard(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    guard: RepresentationGuard,
    indent: usize,
) (RenderError || std.mem.Allocator.Error)!void {
    try writeIndent(allocator, out, indent);
    try out.appendSlice(allocator, "if (");
    try emitPlaceRoot(allocator, out, body, guard.place);
    try out.appendSlice(allocator, " == NULL) mc_trap_InvalidRepresentation();\n");
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
    // Function identities are already C expressions. Canonical admission is
    // deliberately limited to SymbolIdentity.kind=function, so this cannot
    // turn an untyped global read into a direct expression.
    if (expression.operation == .symbol) return false;
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
    if (place.storage != .ordinary) return error.UnsupportedOperation;
    if (mir.executableFixedArrayIndexPlace(body, place.*)) |index| {
        try out.append(allocator, '(');
        try emitPlaceRootValue(allocator, out, body, place.*);
        try out.appendSlice(allocator, ").elems[");
        if (index.checked) try out.appendSlice(allocator, "mc_check_index_usize(");
        try emitExpression(allocator, out, body, index.value, 0);
        if (index.checked) try out.print(allocator, ", {d})", .{index.bound.?});
        try out.append(allocator, ']');
        return;
    }
    if (mir.executableDirectAggregateFieldPlace(
        body.locals,
        body.statements,
        body.aggregate_types,
        place.*,
        false,
    )) |field_index| {
        const aggregate = aggregateType(body, place.root_type_id) orelse return error.InvalidPlace;
        try out.append(allocator, '(');
        try emitPlaceRootValue(allocator, out, body, place.*);
        try out.appendSlice(allocator, ").");
        try appendIdent(allocator, out, aggregate.field_spellings[field_index]);
        return;
    }
    if (place.projection_count == 1 and mir.executableLocalAddressDerefPlace(body, place.*, false)) {
        try out.appendSlice(allocator, "(*(");
        try emitPlaceRootValue(allocator, out, body, place.*);
        try out.appendSlice(allocator, "))");
        return;
    }
    if (place.projection_count != 0) return error.UnsupportedOperation;
    try emitPlaceRootValue(allocator, out, body, place.*);
}

fn emitPlaceAddress(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    id: mir.PlaceId,
) (RenderError || std.mem.Allocator.Error)!void {
    const place = placeById(body, id) orelse return error.InvalidPlace;
    if (place.storage != .ordinary) return error.UnsupportedOperation;
    if (mir.executableFixedArrayIndexPlace(body, place.*) != null) {
        try out.appendSlice(allocator, "&(");
        try emitPlace(allocator, out, body, id);
        try out.append(allocator, ')');
        return;
    }
    if (mir.executableDirectAggregateFieldPlace(
        body.locals,
        body.statements,
        body.aggregate_types,
        place.*,
        false,
    ) != null) {
        try out.appendSlice(allocator, "&(");
        try emitPlace(allocator, out, body, id);
        try out.append(allocator, ')');
        return;
    }
    if (place.projection_count == 0) {
        try out.append(allocator, '&');
        try emitPlaceRootValue(allocator, out, body, place.*);
        return;
    }
    if (!scalarAccessPlaceSupported(body, place.*)) return error.UnsupportedOperation;
    if (place.projection_count == 2) {
        const field_index = switch (place.projections[1]) {
            .field => |index| index,
            .deref, .index => return error.UnsupportedOperation,
        };
        const pointer = switch (place.root_ty) {
            .pointer => |shape| shape,
            else => return error.UnsupportedOperation,
        };
        var aggregate: ?*const mir.ExecutableAggregateType = null;
        for (body.aggregate_types) |*candidate| if (mir.ValueType.eql(candidate.ty, .{ .struct_ = pointer.child })) {
            aggregate = candidate;
            break;
        };
        const shape = aggregate orelse return error.UnsupportedOperation;
        try out.appendSlice(allocator, "&(");
        try emitPlaceRootValue(allocator, out, body, place.*);
        try out.appendSlice(allocator, "->");
        try appendIdent(allocator, out, shape.field_spellings[field_index]);
        try out.append(allocator, ')');
        return;
    }
    // `&p.*` is the original pointer value. Keeping this identity also avoids
    // creating a second C dereference after the explicit representation guard.
    try emitPlaceRootValue(allocator, out, body, place.*);
}

fn emitAtomicPlaceAddress(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    id: mir.PlaceId,
) (RenderError || std.mem.Allocator.Error)!void {
    const place = placeById(body, id) orelse return error.InvalidPlace;
    if (!atomicPlaceSupported(body, place.*)) return error.UnsupportedOperation;
    if (place.projection_count == 0) {
        try out.append(allocator, '&');
        try emitPlaceRootValue(allocator, out, body, place.*);
        return;
    }
    if (place.projection_count == 2) {
        const field_index = switch (place.projections[1]) {
            .field => |index| index,
            .deref, .index => return error.UnsupportedOperation,
        };
        const pointer = switch (place.root_ty) {
            .pointer => |shape| shape,
            else => return error.UnsupportedOperation,
        };
        const aggregate = aggregateTypeForValueType(body, .{ .struct_ = pointer.child }) orelse return error.UnsupportedOperation;
        if (field_index >= aggregate.field_count) return error.UnsupportedOperation;
        try out.appendSlice(allocator, "&(");
        try emitPlaceRootValue(allocator, out, body, place.*);
        try out.appendSlice(allocator, "->");
        try appendIdent(allocator, out, aggregate.field_spellings[field_index]);
        try out.append(allocator, ')');
        return;
    }
    // The value of a direct `*atomic<T>` parameter is the storage address;
    // taking its address here would load from the parameter slot instead.
    try emitPlaceRootValue(allocator, out, body, place.*);
}

fn emitPlaceRoot(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    id: mir.PlaceId,
) (RenderError || std.mem.Allocator.Error)!void {
    const place = placeById(body, id) orelse return error.InvalidPlace;
    try emitPlaceRootValue(allocator, out, body, place.*);
}

fn emitPlaceRootValue(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    place: mir.ExecutablePlace,
) (RenderError || std.mem.Allocator.Error)!void {
    switch (place.root) {
        .local => |local| try appendLocal(allocator, out, body, local),
        .symbol => |symbol| try appendSymbol(allocator, out, body, symbol),
        .value => |value| try emitExpression(allocator, out, body, value, 0),
    }
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
    literal: mir.ExecutableLiteral,
) (RenderError || std.mem.Allocator.Error)!void {
    switch (literal) {
        .integer => |magnitude| try out.print(allocator, "{d}", .{magnitude}),
        .signed_integer => |value| try out.print(allocator, "{d}", .{value}),
        .float => |value| switch (value) {
            .f32_bits => |bits| try out.print(allocator, "__builtin_bit_cast(float, ((uint32_t)0x{X:0>8}U))", .{bits}),
            .f64_bits => |bits| try out.print(allocator, "__builtin_bit_cast(double, ((uint64_t)0x{X:0>16}ULL))", .{bits}),
        },
        .string => |spelling| try out.appendSlice(allocator, spelling),
        .boolean => |value| try out.appendSlice(allocator, if (value) "true" else "false"),
        .null => try out.appendSlice(allocator, "NULL"),
        .void => try out.appendSlice(allocator, "((void)0)"),
        .uninit => return error.UnsupportedOperation,
        .enum_value => return error.UnsupportedOperation,
    }
}

fn appendCType(allocator: std.mem.Allocator, out: *std.ArrayList(u8), body: *const mir.ExecutableBody, ty: mir.ValueType) (RenderError || std.mem.Allocator.Error)!void {
    switch (ty) {
        .void, .never => try out.appendSlice(allocator, "void"),
        .bool => try out.appendSlice(allocator, "bool"),
        .integer, .float => |name| try out.appendSlice(allocator, primitiveType(name) orelse return error.UnsupportedType),
        .domain_integer => |shape| try out.appendSlice(allocator, primitiveType(shape.child) orelse return error.UnsupportedType),
        .cstr => try out.appendSlice(allocator, "char const *"),
        .pointer, .nullable_pointer => |shape| {
            if (shape.kind == .slice) return error.UnsupportedType;
            const child = if (std.mem.eql(u8, shape.child, "c_void")) "void" else primitiveType(shape.child) orelse shape.child;
            try out.appendSlice(allocator, child);
            try out.appendSlice(allocator, if (shape.mutability == .mut) " *" else " const *");
        },
        .address => try out.appendSlice(allocator, "uintptr_t"),
        .array => {
            const shape = aggregateTypeForValueType(body, ty) orelse return error.UnsupportedType;
            if (shape.construction != .declared_struct or shape.ty != .array or shape.field_count == 0 or shape.array_length == null) return error.UnsupportedType;
            try out.appendSlice(allocator, "mc_array_");
            try appendArrayElementTypeSuffix(allocator, out, body, shape.field_types[0], 0);
            try out.print(allocator, "_{d}", .{shape.array_length.?});
        },
        .closed_enum, .open_enum, .struct_ => |name| try appendIdent(allocator, out, name),
        .nullable_value => {
            const shape = aggregateTypeForValueType(body, ty) orelse return error.UnsupportedType;
            if (shape.construction != .declared_struct or shape.ty != .nullable_value or shape.field_count != 2) return error.UnsupportedType;
            try out.appendSlice(allocator, "mc_opt_");
            try appendCTypeSuffix(allocator, out, shape.field_types[1]);
        },
        .result => |identity| {
            const shape = resultTypeForValueType(body, ty) orelse return error.UnsupportedType;
            try out.appendSlice(allocator, "mc_result_");
            try appendResultCTypeSuffix(allocator, out, identity.ok, shape.ok_ty);
            try out.append(allocator, '_');
            try appendResultCTypeSuffix(allocator, out, identity.err, shape.err_ty);
        },
        else => return error.UnsupportedType,
    }
}

fn appendResultCTypeSuffix(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    identity: []const u8,
    storage_ty: mir.ValueType,
) (RenderError || std.mem.Allocator.Error)!void {
    switch (storage_ty) {
        .domain_integer => |domain| if (domain.kind == .duration)
            return out.print(allocator, "mc_type_generic_8_Duration_1_{d}_{s}", .{ domain.child.len, domain.child }),
        else => {},
    }
    if (isSafeIdentifier(identity)) return out.appendSlice(allocator, identity);
    if (try appendUnaryGenericCTypeSuffix(allocator, out, identity)) return;
    return appendCTypeSuffix(allocator, out, storage_ty);
}

fn appendUnaryGenericCTypeSuffix(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    identity: []const u8,
) std.mem.Allocator.Error!bool {
    const open = std.mem.indexOfScalar(u8, identity, '<') orelse return false;
    if (open == 0 or identity.len <= open + 2 or identity[identity.len - 1] != '>' or
        std.mem.indexOfScalarPos(u8, identity, open + 1, '<') != null)
        return false;
    const base = identity[0..open];
    const argument = identity[open + 1 .. identity.len - 1];
    if (!isSafeIdentifier(base) or !isSafeIdentifier(argument)) return false;
    try out.print(allocator, "mc_type_generic_{d}_{s}_1_{d}_{s}", .{ base.len, base, argument.len, argument });
    return true;
}

fn appendCTypeSuffix(allocator: std.mem.Allocator, out: *std.ArrayList(u8), ty: mir.ValueType) (RenderError || std.mem.Allocator.Error)!void {
    switch (ty) {
        .bool => try out.appendSlice(allocator, "bool"),
        .integer, .float => |name| try out.appendSlice(allocator, name),
        .address => try out.appendSlice(allocator, ty.name()),
        .struct_ => |name| try out.print(allocator, "mc_type_struct_{d}_{s}", .{ name.len, name }),
        // Enum declarations are emitted as nominal C typedefs, so Result
        // helper names use the same public suffix as the declaration path.
        // Encoding them as a generic source type name here produces a helper
        // that was never declared (for example mc_result_u32_mc_type_name_5_Error).
        .closed_enum, .open_enum => |name| try appendIdent(allocator, out, name),
        else => return error.UnsupportedType,
    }
}

fn appendArrayElementTypeSuffix(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    ty: mir.ValueType,
    depth: usize,
) (RenderError || std.mem.Allocator.Error)!void {
    if (depth >= mir.max_executable_operands) return error.UnsupportedType;
    if (ty != .array) return appendCTypeSuffix(allocator, out, ty);
    const shape = aggregateTypeForValueType(body, ty) orelse return error.UnsupportedType;
    if (shape.array_length == null or shape.array_length.? == 0 or shape.field_count == 0) return error.UnsupportedType;
    var child: std.ArrayList(u8) = .empty;
    defer child.deinit(allocator);
    try appendArrayElementTypeSuffix(allocator, &child, body, shape.field_types[0], depth + 1);
    const length = try std.fmt.allocPrint(allocator, "{d}", .{shape.array_length.?});
    defer allocator.free(length);
    try out.print(allocator, "mc_type_array_{d}_{s}_{d}_{s}", .{ child.items.len, child.items, length.len, length });
}

fn arrayElementTypeSupported(body: *const mir.ExecutableBody, ty: mir.ValueType, depth: usize) bool {
    if (depth >= mir.max_executable_operands) return false;
    return switch (ty) {
        .bool, .address => true,
        .integer, .float => |name| primitiveType(name) != null,
        .struct_, .closed_enum, .open_enum => |name| isSafeIdentifier(name),
        .array => if (aggregateTypeForValueType(body, ty)) |shape|
            shape.array_length != null and shape.array_length.? != 0 and shape.field_count != 0 and
                arrayElementTypeSupported(body, shape.field_types[0], depth + 1)
        else
            false,
        else => false,
    };
}

fn appendLocal(allocator: std.mem.Allocator, out: *std.ArrayList(u8), body: *const mir.ExecutableBody, id: mir.LocalId) (RenderError || std.mem.Allocator.Error)!void {
    const local = localById(body, id) orelse return error.InvalidLocal;
    if (std.mem.eql(u8, local.spelling, "__mc_iflet_subject"))
        return out.print(allocator, "__mc_iflet_subject_{d}", .{id.raw});
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
    if (c_identifier.isReservedWord(spelling)) try out.append(allocator, '_');
}

fn expressionById(body: *const mir.ExecutableBody, id: mir.ExprId) ?*const mir.ExecutableExpression {
    if (!id.isValid()) return null;
    for (body.expressions) |*expression| if (expression.id.eql(id)) return expression;
    return null;
}

fn statementById(body: *const mir.ExecutableBody, id: mir.InstId) ?*const mir.ExecutableStatement {
    if (!id.isValid()) return null;
    for (body.statements) |*statement| if (statement.id.eql(id)) return statement;
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

fn domainInteger(ty: mir.ValueType, expected: mir.IntegerDomainKind) ?mir.DomainIntegerShape {
    const shape = switch (ty) {
        .domain_integer => |value| value,
        else => return null,
    };
    return if (shape.kind == expected and primitiveType(shape.child) != null) shape else null;
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
    if (std.mem.eql(u8, name, "IrqOff")) return (scalar_repr.integer(name) orelse return null).c_type;
    const Entry = struct { mc: []const u8, c: []const u8 };
    const entries = [_]Entry{
        .{ .mc = "u8", .c = "uint8_t" },      .{ .mc = "u16", .c = "uint16_t" },   .{ .mc = "u32", .c = "uint32_t" }, .{ .mc = "u64", .c = "uint64_t" }, .{ .mc = "u128", .c = "unsigned __int128" },
        .{ .mc = "i8", .c = "int8_t" },       .{ .mc = "i16", .c = "int16_t" },    .{ .mc = "i32", .c = "int32_t" },  .{ .mc = "i64", .c = "int64_t" },  .{ .mc = "i128", .c = "__int128" },
        .{ .mc = "usize", .c = "uintptr_t" }, .{ .mc = "isize", .c = "intptr_t" }, .{ .mc = "f32", .c = "float" },    .{ .mc = "f64", .c = "double" },   .{ .mc = "bool", .c = "bool" },
    };
    for (entries) |entry| if (std.mem.eql(u8, name, entry.mc)) return entry.c;
    return null;
}

fn signedPrimitiveType(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "u8") or std.mem.eql(u8, name, "i8")) return "int8_t";
    if (std.mem.eql(u8, name, "u16") or std.mem.eql(u8, name, "i16")) return "int16_t";
    if (std.mem.eql(u8, name, "u32") or std.mem.eql(u8, name, "i32")) return "int32_t";
    if (std.mem.eql(u8, name, "u64") or std.mem.eql(u8, name, "i64")) return "int64_t";
    if (std.mem.eql(u8, name, "u128") or std.mem.eql(u8, name, "i128")) return "__int128";
    if (std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "isize")) return "intptr_t";
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
        .domain_integer => |shape| shape.child,
        .address => "usize",
        else => return null,
    };
    return .{
        .helper_suffix = suffix,
        .c_type = primitiveType(suffix) orelse return null,
        .alignment = mir.ExecutableMemoryAccess.scalarAlignment(ty) orelse return null,
    };
}

fn isSafeIdentifier(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    return true;
}

fn durationTypeSpellingMatches(spelling: []const u8, child: []const u8) bool {
    if (std.mem.eql(u8, spelling, "Duration")) return true;
    const prefix = "Duration<";
    return spelling.len == prefix.len + child.len + 1 and
        std.mem.startsWith(u8, spelling, prefix) and spelling[spelling.len - 1] == '>' and
        std.mem.eql(u8, spelling[prefix.len .. spelling.len - 1], child);
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
        \\/* canonical executable MIR */
        \\bool mc_exec_tmp_0;
        \\uint32_t mc_exec_tmp_1;
        \\uint32_t mc_exec_tmp_2;
        \\uint32_t mc_exec_tmp_3;
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

test "executable C renderer admits assert only with its exact statement trap edge" {
    const entry = mir.BlockId.fromIndex(0);
    const trap = mir.BlockId.fromIndex(1);
    const statement = mir.InstId.fromIndex(0);
    const condition = mir.ExprId.fromIndex(0);
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    var expressions = [_]mir.ExecutableExpression{.{
        .id = condition,
        .block_id = entry,
        .owner_statement = statement,
        .source = source,
        .result_ty = .bool,
        .operation = .{ .literal = .{ .boolean = false } },
    }};
    var statements = [_]mir.ExecutableStatement{.{
        .id = statement,
        .block_id = entry,
        .source = source,
        .operation = .{ .guard = .{ .kind = .assert_, .condition = condition } },
    }};
    var edges = [_]mir.ExecutableTrapEdge{.{
        .owner = .{ .statement = statement },
        .from_block = entry,
        .trap_block = trap,
        .kind = .Assert,
        .source = .assert_stmt,
    }};
    var terminators = [_]mir.ExecutableTerminator{
        .{ .block_id = entry, .operation = .return_ },
        .{ .block_id = trap, .operation = .{ .trap_ = .Assert } },
    };
    var body: mir.ExecutableBody = .{
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
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_exec_tmp_0 = false;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!(mc_exec_tmp_0)) goto mc_bb_1;") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.items, "mc_trap_Assert();"));

    body.trap_edges = &.{};
    try std.testing.expect(!canEmitBody(&body));
    body.trap_edges = &edges;

    edges[0].source = .checked_arithmetic;
    try std.testing.expect(!canEmitBody(&body));
    edges[0].source = .assert_stmt;

    edges[0].kind = .IntegerOverflow;
    try std.testing.expect(!canEmitBody(&body));
    edges[0].kind = .Assert;

    terminators[1].operation = .{ .trap_ = .IntegerOverflow };
    try std.testing.expect(!canEmitBody(&body));
    terminators[1].operation = .{ .trap_ = .Assert };

    var duplicate_edges = [_]mir.ExecutableTrapEdge{ edges[0], edges[0] };
    body.trap_edges = &duplicate_edges;
    try std.testing.expect(!canEmitBody(&body));
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
        .{ .owner = .{ .expression = add }, .from_block = entry, .trap_block = add_trap, .kind = .IntegerOverflow, .source = .checked_arithmetic },
        .{ .owner = .{ .expression = sub }, .from_block = entry, .trap_block = sub_trap, .kind = .IntegerOverflow, .source = .checked_arithmetic },
        .{ .owner = .{ .expression = mul }, .from_block = entry, .trap_block = mul_trap, .kind = .IntegerOverflow, .source = .checked_arithmetic },
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
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_IntegerOverflow();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_bb_1: ;") == null);
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
    var edge = [_]mir.ExecutableTrapEdge{.{ .owner = .{ .expression = result }, .from_block = entry, .trap_block = trap, .kind = .IntegerOverflow, .source = .checked_arithmetic }};
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

test "executable C renderer emits scalar bitcast as a bit preserving builtin" {
    const local = mir.LocalId.fromIndex(0);
    const operand = mir.ExprId.fromIndex(0);
    const result = mir.ExprId.fromIndex(1);
    const statement = mir.InstId.fromIndex(0);
    const entry = mir.BlockId.fromIndex(0);
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const f32_ty: mir.ValueType = .{ .float = "f32" };
    const u32_ty: mir.ValueType = .{ .integer = "u32" };
    var parameters = [_]mir.ExecutableParameter{.{ .local = local, .ty = f32_ty, .source = source }};
    var locals = [_]mir.ExecutableLocalIdentity{.{ .id = local, .spelling = "value" }};
    var call: @FieldType(mir.ExecutableExpression.Operation, "builtin_call") = .{ .kind = .bitcast, .callee_source = source, .argument_count = 1 };
    call.arguments[0] = operand;
    var expressions = [_]mir.ExecutableExpression{
        .{ .id = operand, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = f32_ty, .operation = .{ .local = local } },
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

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try emitBody(std.testing.allocator, &output, &body, 0);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_exec_tmp_0 = value;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_exec_tmp_1 = __builtin_bit_cast(uint32_t, mc_exec_tmp_0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_exec_tmp_1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "((uint32_t)(mc_exec_tmp_0))") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "memcpy") == null);
}

test "executable C renderer rejects scalar bitcast fact mutations" {
    const local = mir.LocalId.fromIndex(0);
    const operand = mir.ExprId.fromIndex(0);
    const result = mir.ExprId.fromIndex(1);
    const statement = mir.InstId.fromIndex(0);
    const entry = mir.BlockId.fromIndex(0);
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const f32_ty: mir.ValueType = .{ .float = "f32" };
    const f64_ty: mir.ValueType = .{ .float = "f64" };
    const u32_ty: mir.ValueType = .{ .integer = "u32" };
    const u64_ty: mir.ValueType = .{ .integer = "u64" };
    var parameters = [_]mir.ExecutableParameter{.{ .local = local, .ty = f32_ty, .source = source }};
    var locals = [_]mir.ExecutableLocalIdentity{.{ .id = local, .spelling = "value" }};
    var call: @FieldType(mir.ExecutableExpression.Operation, "builtin_call") = .{ .kind = .bitcast, .callee_source = source, .argument_count = 1 };
    call.arguments[0] = operand;
    var expressions = [_]mir.ExecutableExpression{
        .{ .id = operand, .block_id = entry, .owner_statement = statement, .source = source, .result_ty = f32_ty, .operation = .{ .local = local } },
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

    expressions[1].operation.builtin_call.argument_count = 0;
    try std.testing.expect(!canEmitBody(&body));
    expressions[1].operation.builtin_call.argument_count = 2;
    expressions[1].operation.builtin_call.arguments[1] = operand;
    try std.testing.expect(!canEmitBody(&body));
    expressions[1].operation.builtin_call.argument_count = 1;

    expressions[1].result_ty = u64_ty;
    try std.testing.expect(!canEmitBody(&body));
    expressions[1].result_ty = u32_ty;
    expressions[0].result_ty = f64_ty;
    try std.testing.expect(!canEmitBody(&body));
    expressions[0].result_ty = f32_ty;

    expressions[1].operation.builtin_call.arguments[0] = .invalid;
    try std.testing.expect(!canEmitBody(&body));
    expressions[1].operation.builtin_call.arguments[0] = operand;
    try std.testing.expect(canEmitBody(&body));
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
            .owner = .{ .expression = result },
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

test "executable C renderer guards single parameter scalar deref with exact representation edge" {
    const pointer_local = mir.LocalId.fromIndex(0);
    const place_id = mir.PlaceId.fromIndex(0);
    const value_id = mir.ExprId.fromIndex(0);
    const return_statement = mir.InstId.fromIndex(0);
    const entry = mir.BlockId.fromIndex(0);
    const trap = mir.BlockId.fromIndex(1);
    const source: mir.SourcePoint = .{ .line = 1, .column = 39, .offset = 38, .len = 7 };
    const pointer_source: mir.SourcePoint = .{ .line = 1, .column = 39, .offset = 38, .len = 1 };
    const u32_ty: mir.ValueType = .{ .integer = "u32" };
    const pointer_ty: mir.ValueType = .{ .pointer = .{ .kind = .single, .mutability = .@"const", .child = "u32" } };
    var parameters = [_]mir.ExecutableParameter{.{ .local = pointer_local, .ty = pointer_ty, .source = pointer_source }};
    var locals = [_]mir.ExecutableLocalIdentity{.{ .id = pointer_local, .spelling = "pointer" }};
    var places = [_]mir.ExecutablePlace{.{
        .id = place_id,
        .source = source,
        .root = .{ .local = pointer_local },
        .root_ty = pointer_ty,
        .ty = u32_ty,
        .projections = blk: {
            var projections = [_]mir.ExecutablePlace.Projection{.deref} ** mir.max_executable_projections;
            projections[0] = .deref;
            break :blk projections;
        },
        .projection_count = 1,
    }};
    var expressions = [_]mir.ExecutableExpression{.{
        .id = value_id,
        .block_id = entry,
        .owner_statement = return_statement,
        .source = source,
        .result_ty = u32_ty,
        .operation = .{ .load = .{
            .place = place_id,
            .access = .{ .kind = .race_unordered, .alignment = 4 },
            .representation_source = pointer_source,
            .representation_span_id = mir.SpanId.fromIndex(0),
        } },
    }};
    var edges = [_]mir.ExecutableTrapEdge{
        .{ .owner = .{ .expression = value_id }, .from_block = entry, .trap_block = trap, .kind = .InvalidRepresentation, .source = .representation_check },
        .{ .owner = .{ .expression = value_id }, .from_block = entry, .trap_block = trap, .kind = .InvalidRepresentation, .source = .representation_check },
    };
    var statements = [_]mir.ExecutableStatement{.{ .id = return_statement, .block_id = entry, .source = source, .operation = .{ .return_ = value_id } }};
    var terminators = [_]mir.ExecutableTerminator{
        .{ .block_id = entry, .operation = .return_ },
        .{ .block_id = trap, .operation = .{ .trap_ = .InvalidRepresentation } },
    };
    var body: mir.ExecutableBody = .{
        .parameters = &parameters,
        .locals = &locals,
        .expressions = &expressions,
        .trap_edges = edges[0..1],
        .places = &places,
        .statements = &statements,
        .terminators = &terminators,
    };
    try std.testing.expect(canEmitBody(&body));

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try emitBody(std.testing.allocator, &output, &body, 0);
    const guard_pos = std.mem.indexOf(u8, output.items, "if (pointer == NULL) mc_trap_InvalidRepresentation();") orelse return error.TestUnexpectedResult;
    const load_pos = std.mem.indexOf(u8, output.items, "mc_exec_tmp_0 = ((uint32_t)mc_race_load_u32(pointer));") orelse return error.TestUnexpectedResult;
    try std.testing.expect(guard_pos < load_pos);

    body.trap_edges = &.{};
    try std.testing.expect(!canEmitBody(&body));
    body.trap_edges = edges[0..2];
    try std.testing.expect(!canEmitBody(&body));
    body.trap_edges = edges[0..1];

    edges[0].kind = .Bounds;
    try std.testing.expect(!canEmitBody(&body));
    edges[0].kind = .InvalidRepresentation;
    edges[0].source = .checked_arithmetic;
    try std.testing.expect(!canEmitBody(&body));
    edges[0].source = .representation_check;
    edges[0].from_block = trap;
    try std.testing.expect(!canEmitBody(&body));
    edges[0].from_block = entry;
    terminators[1].operation = .{ .trap_ = .Bounds };
    try std.testing.expect(!canEmitBody(&body));
    terminators[1].operation = .{ .trap_ = .InvalidRepresentation };

    expressions[0].operation.load.access.kind = .plain;
    try std.testing.expect(!canEmitBody(&body));
    expressions[0].operation.load.access.kind = .race_unordered;
    expressions[0].operation.load.representation_span_id = .invalid;
    try std.testing.expect(!canEmitBody(&body));
    expressions[0].operation.load.representation_span_id = mir.SpanId.fromIndex(0);

    places[0].projections[0] = .{ .field = 0 };
    try std.testing.expect(!canEmitBody(&body));
    places[0].projections[0] = .deref;
    places[0].root_ty = .{ .nullable_pointer = .{ .kind = .single, .mutability = .@"const", .child = "u32" } };
    parameters[0].ty = places[0].root_ty;
    try std.testing.expect(!canEmitBody(&body));
}

test "executable C renderer guards address of parameter deref and returns original pointer" {
    const pointer_local = mir.LocalId.fromIndex(0);
    const place_id = mir.PlaceId.fromIndex(0);
    const value_id = mir.ExprId.fromIndex(0);
    const return_statement = mir.InstId.fromIndex(0);
    const entry = mir.BlockId.fromIndex(0);
    const trap = mir.BlockId.fromIndex(1);
    const source: mir.SourcePoint = .{ .line = 1, .column = 48, .offset = 47, .len = 7 };
    const pointer_source: mir.SourcePoint = .{ .line = 1, .column = 49, .offset = 48, .len = 1 };
    const pointer_ty: mir.ValueType = .{ .pointer = .{ .kind = .single, .mutability = .mut, .child = "u32" } };
    var parameters = [_]mir.ExecutableParameter{.{ .local = pointer_local, .ty = pointer_ty, .source = pointer_source }};
    var locals = [_]mir.ExecutableLocalIdentity{.{ .id = pointer_local, .spelling = "pointer" }};
    var places = [_]mir.ExecutablePlace{.{
        .id = place_id,
        .source = source,
        .root = .{ .local = pointer_local },
        .root_ty = pointer_ty,
        .ty = .{ .integer = "u32" },
        .projections = blk: {
            var projections = [_]mir.ExecutablePlace.Projection{.deref} ** mir.max_executable_projections;
            projections[0] = .deref;
            break :blk projections;
        },
        .projection_count = 1,
    }};
    var expressions = [_]mir.ExecutableExpression{.{
        .id = value_id,
        .block_id = entry,
        .owner_statement = return_statement,
        .source = source,
        .result_ty = pointer_ty,
        .operation = .{ .address_of = .{
            .place = place_id,
            .representation_source = pointer_source,
            .representation_span_id = mir.SpanId.fromIndex(0),
        } },
    }};
    var edges = [_]mir.ExecutableTrapEdge{.{ .owner = .{ .expression = value_id }, .from_block = entry, .trap_block = trap, .kind = .InvalidRepresentation, .source = .representation_check }};
    var statements = [_]mir.ExecutableStatement{.{ .id = return_statement, .block_id = entry, .source = source, .operation = .{ .return_ = value_id } }};
    var terminators = [_]mir.ExecutableTerminator{
        .{ .block_id = entry, .operation = .return_ },
        .{ .block_id = trap, .operation = .{ .trap_ = .InvalidRepresentation } },
    };
    var body: mir.ExecutableBody = .{
        .parameters = &parameters,
        .locals = &locals,
        .expressions = &expressions,
        .trap_edges = &edges,
        .places = &places,
        .statements = &statements,
        .terminators = &terminators,
    };
    try std.testing.expect(canEmitBody(&body));

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try emitBody(std.testing.allocator, &output, &body, 0);
    const guard_pos = std.mem.indexOf(u8, output.items, "if (pointer == NULL) mc_trap_InvalidRepresentation();") orelse return error.TestUnexpectedResult;
    const identity_pos = std.mem.indexOf(u8, output.items, "mc_exec_tmp_0 = pointer;") orelse return error.TestUnexpectedResult;
    try std.testing.expect(guard_pos < identity_pos);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "&(*") == null);

    expressions[0].result_ty = .{ .pointer = .{ .kind = .single, .mutability = .@"const", .child = "u32" } };
    try std.testing.expect(!canEmitBody(&body));
}

test "executable C renderer guards statement-owned parameter scalar store with exact representation edge" {
    const pointer_local = mir.LocalId.fromIndex(0);
    const value_local = mir.LocalId.fromIndex(1);
    const place_id = mir.PlaceId.fromIndex(0);
    const value_id = mir.ExprId.fromIndex(0);
    const store_statement = mir.InstId.fromIndex(0);
    const entry = mir.BlockId.fromIndex(0);
    const trap = mir.BlockId.fromIndex(1);
    const source: mir.SourcePoint = .{ .line = 1, .column = 51, .offset = 50, .len = 17 };
    const pointer_source: mir.SourcePoint = .{ .line = 1, .column = 51, .offset = 50, .len = 7 };
    const u32_ty: mir.ValueType = .{ .integer = "u32" };
    const pointer_ty: mir.ValueType = .{ .pointer = .{ .kind = .single, .mutability = .mut, .child = "u32" } };
    var parameters = [_]mir.ExecutableParameter{
        .{ .local = pointer_local, .ty = pointer_ty, .source = pointer_source },
        .{ .local = value_local, .ty = u32_ty, .source = source },
    };
    var locals = [_]mir.ExecutableLocalIdentity{
        .{ .id = pointer_local, .spelling = "pointer" },
        .{ .id = value_local, .spelling = "value" },
    };
    var places = [_]mir.ExecutablePlace{.{
        .id = place_id,
        .source = source,
        .root = .{ .local = pointer_local },
        .root_ty = pointer_ty,
        .ty = u32_ty,
        .projections = blk: {
            var projections = [_]mir.ExecutablePlace.Projection{.deref} ** mir.max_executable_projections;
            projections[0] = .deref;
            break :blk projections;
        },
        .projection_count = 1,
    }};
    var expressions = [_]mir.ExecutableExpression{.{
        .id = value_id,
        .block_id = entry,
        .owner_statement = store_statement,
        .source = source,
        .result_ty = u32_ty,
        .operation = .{ .local = value_local },
    }};
    var statements = [_]mir.ExecutableStatement{.{
        .id = store_statement,
        .block_id = entry,
        .source = source,
        .operation = .{ .store = .{
            .place = place_id,
            .value = value_id,
            .ty = u32_ty,
            .access = .{ .kind = .race_unordered, .alignment = 4 },
            .representation_source = pointer_source,
            .representation_span_id = mir.SpanId.fromIndex(0),
        } },
    }};
    var edges = [_]mir.ExecutableTrapEdge{
        .{ .owner = .{ .statement = store_statement }, .from_block = entry, .trap_block = trap, .kind = .InvalidRepresentation, .source = .representation_check },
        .{ .owner = .{ .statement = store_statement }, .from_block = entry, .trap_block = trap, .kind = .InvalidRepresentation, .source = .representation_check },
    };
    var terminators = [_]mir.ExecutableTerminator{
        .{ .block_id = entry, .operation = .return_ },
        .{ .block_id = trap, .operation = .{ .trap_ = .InvalidRepresentation } },
    };
    var body: mir.ExecutableBody = .{
        .parameters = &parameters,
        .locals = &locals,
        .expressions = &expressions,
        .trap_edges = edges[0..1],
        .places = &places,
        .statements = &statements,
        .terminators = &terminators,
    };
    try std.testing.expect(canEmitBody(&body));

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try emitBody(std.testing.allocator, &output, &body, 0);
    const value_pos = std.mem.indexOf(u8, output.items, "mc_exec_tmp_0 = value;") orelse return error.TestUnexpectedResult;
    const guard_pos = std.mem.indexOf(u8, output.items, "if (pointer == NULL) mc_trap_InvalidRepresentation();") orelse return error.TestUnexpectedResult;
    const store_pos = std.mem.indexOf(u8, output.items, "mc_race_store_u32(pointer, (uint32_t)mc_exec_tmp_0);") orelse return error.TestUnexpectedResult;
    try std.testing.expect(value_pos < guard_pos and guard_pos < store_pos);

    body.trap_edges = &.{};
    try std.testing.expect(!canEmitBody(&body));
    body.trap_edges = edges[0..2];
    try std.testing.expect(!canEmitBody(&body));
    body.trap_edges = edges[0..1];

    edges[0].owner = .{ .expression = value_id };
    try std.testing.expect(!canEmitBody(&body));
    edges[0].owner = .{ .statement = store_statement };
    edges[0].kind = .Bounds;
    try std.testing.expect(!canEmitBody(&body));
    edges[0].kind = .InvalidRepresentation;
    edges[0].source = .checked_arithmetic;
    try std.testing.expect(!canEmitBody(&body));
    edges[0].source = .representation_check;
    terminators[1].operation = .{ .trap_ = .Bounds };
    try std.testing.expect(!canEmitBody(&body));
    terminators[1].operation = .{ .trap_ = .InvalidRepresentation };

    statements[0].operation.store.access.kind = .plain;
    try std.testing.expect(!canEmitBody(&body));
    statements[0].operation.store.access.kind = .race_unordered;
    statements[0].operation.store.representation_span_id = .invalid;
    try std.testing.expect(!canEmitBody(&body));
    statements[0].operation.store.representation_span_id = mir.SpanId.fromIndex(0);

    places[0].root_ty.pointer.mutability = .@"const";
    parameters[0].ty = places[0].root_ty;
    try std.testing.expect(!canEmitBody(&body));
    places[0].root_ty = pointer_ty;
    parameters[0].ty = pointer_ty;
    places[0].root_ty.pointer.kind = .raw_many;
    parameters[0].ty = places[0].root_ty;
    try std.testing.expect(!canEmitBody(&body));
    places[0].root_ty = pointer_ty;
    parameters[0].ty = pointer_ty;
    places[0].projections[0] = .{ .field = 0 };
    try std.testing.expect(!canEmitBody(&body));
    places[0].projections[0] = .{ .index = .{
        .value = value_id,
        .kind = .fixed_array,
        .bound = 1,
        .span_id = mir.SpanId.fromIndex(0),
    } };
    try std.testing.expect(!canEmitBody(&body));
}

test "executable C renderer validates a slice once with an exact representation edge" {
    const slice_ty: mir.ValueType = .{ .pointer = .{ .kind = .slice, .mutability = .@"const", .child = "u32" } };
    const source: mir.SourcePoint = .{ .line = 1, .column = 35, .offset = 34, .len = 2 };
    const entry = mir.BlockId.fromIndex(0);
    const trap = mir.BlockId.fromIndex(1);
    const return_statement = mir.InstId.fromIndex(0);
    var locals = [_]mir.ExecutableLocalIdentity{.{ .id = mir.LocalId.fromIndex(0), .spelling = "items" }};
    var parameters = [_]mir.ExecutableParameter{.{
        .local = mir.LocalId.fromIndex(0),
        .ty = slice_ty,
        .type_id = mir.TypeId.fromIndex(0),
        .source = source,
        .span_id = mir.SpanId.fromIndex(0),
    }};
    var expressions = [_]mir.ExecutableExpression{
        .{
            .id = mir.ExprId.fromIndex(0),
            .block_id = entry,
            .owner_statement = return_statement,
            .source = source,
            .span_id = mir.SpanId.fromIndex(0),
            .result_ty = slice_ty,
            .type_id = mir.TypeId.fromIndex(0),
            .operation = .{ .local = mir.LocalId.fromIndex(0) },
        },
        .{
            .id = mir.ExprId.fromIndex(1),
            .block_id = entry,
            .owner_statement = return_statement,
            .source = source,
            .span_id = mir.SpanId.fromIndex(0),
            .result_ty = slice_ty,
            .type_id = mir.TypeId.fromIndex(0),
            .operation = .{ .representation_check = .{ .operand = mir.ExprId.fromIndex(0), .kind = .valid_slice } },
        },
    };
    var edges = [_]mir.ExecutableTrapEdge{
        .{ .owner = .{ .expression = mir.ExprId.fromIndex(1) }, .from_block = entry, .trap_block = trap, .kind = .InvalidRepresentation, .source = .representation_check },
        .{ .owner = .{ .expression = mir.ExprId.fromIndex(1) }, .from_block = entry, .trap_block = trap, .kind = .InvalidRepresentation, .source = .representation_check },
    };
    var statements = [_]mir.ExecutableStatement{.{ .id = return_statement, .block_id = entry, .source = source, .span_id = mir.SpanId.fromIndex(0), .operation = .{ .return_ = mir.ExprId.fromIndex(1) } }};
    var terminators = [_]mir.ExecutableTerminator{
        .{ .block_id = entry, .operation = .return_ },
        .{ .block_id = trap, .operation = .{ .trap_ = .InvalidRepresentation } },
    };
    var body: mir.ExecutableBody = .{
        .parameters = &parameters,
        .locals = &locals,
        .expressions = &expressions,
        .trap_edges = edges[0..1],
        .statements = &statements,
        .terminators = &terminators,
    };

    try std.testing.expect(canEmitBody(&body));
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try emitBody(std.testing.allocator, &output, &body, 0);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.items, "__auto_type mc_exec_tmp_0 = items;"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.items, "mc_exec_tmp_1.ptr == NULL && mc_exec_tmp_1.len != 0"));
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_exec_tmp_1;") != null);

    body.trap_edges = &.{};
    try std.testing.expect(!canEmitBody(&body));
    body.trap_edges = edges[0..2];
    try std.testing.expect(!canEmitBody(&body));
    body.trap_edges = edges[0..1];
    edges[0].kind = .Bounds;
    try std.testing.expect(!canEmitBody(&body));
    edges[0].kind = .InvalidRepresentation;
    edges[0].source = .bounds_check;
    try std.testing.expect(!canEmitBody(&body));
    edges[0].source = .representation_check;
    edges[0].from_block = trap;
    try std.testing.expect(!canEmitBody(&body));
    edges[0].from_block = entry;

    const rejected_types = [_]mir.ValueType{
        .{ .nullable_pointer = .{ .kind = .slice, .mutability = .@"const", .child = "u32" } },
        .{ .pointer = .{ .kind = .raw_many, .mutability = .@"const", .child = "u32" } },
        .{ .pointer = .{ .kind = .single, .mutability = .@"const", .child = "u32" } },
        .{ .array = .{ .child = "u32", .length = 4 } },
        .cstr,
        .{ .closed_enum = "State" },
    };
    for (rejected_types) |rejected| {
        expressions[0].result_ty = rejected;
        expressions[1].result_ty = rejected;
        try std.testing.expect(!canEmitBody(&body));
    }
}
