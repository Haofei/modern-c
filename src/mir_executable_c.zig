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

pub const EmitOptions = struct {
    source_path: ?[]const u8 = null,
    stub_asm: bool = false,
};

pub fn emitBody(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    indent: usize,
) (RenderError || std.mem.Allocator.Error)!void {
    return emitBodyWithOptions(allocator, out, body, indent, .{});
}

pub fn emitBodyWithSourcePath(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    indent: usize,
    source_path: ?[]const u8,
) (RenderError || std.mem.Allocator.Error)!void {
    return emitBodyWithOptions(allocator, out, body, indent, .{ .source_path = source_path });
}

pub fn emitBodyWithOptions(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    indent: usize,
    options: EmitOptions,
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
        switch (expression.operation) {
            .address_of => |address| {
                const place = placeById(body, address.place) orelse return error.InvalidPlace;
                const pointer = switch (expression.result_ty) {
                    .pointer => |shape| shape,
                    else => return error.InvalidExpression,
                };
                try appendCType(allocator, out, body, place.ty);
                try out.appendSlice(allocator, if (pointer.mutability == .@"const") " const *" else " *");
            },
            else => try appendCType(allocator, out, body, expression.result_ty),
        }
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
            try emitStatement(allocator, out, body, statement, indent + 1, options);
        }
        try emitTerminator(allocator, out, body, terminator, indent + 1, options.source_path);
    }
}

pub fn canEmitNakedBody(body: *const mir.ExecutableBody) bool {
    if (!body.isComplete() or body.expressions.len != 0 or body.trap_edges.len != 0 or
        body.places.len != 0 or body.statements.len != 1 or body.terminators.len != 1 or
        body.terminators[0].operation != .unreachable_) return false;
    return switch (body.statements[0].operation) {
        .opaque_asm => |asm_value| asm_value.clobber_count == 0 and
            asm_value.template_count <= mir.max_executable_operands,
        else => false,
    };
}

pub fn emitNakedBody(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    indent: usize,
) (RenderError || std.mem.Allocator.Error)!void {
    if (!canEmitNakedBody(body)) return error.IncompleteBody;
    const asm_value = body.statements[0].operation.opaque_asm;
    try writeIndent(allocator, out, indent);
    try out.appendSlice(allocator, "#if defined(__GNUC__) || defined(__clang__)\n");
    try writeIndent(allocator, out, indent);
    try out.appendSlice(allocator, "__asm__(");
    if (asm_value.template_count == 0) {
        try appendQuotedCBytes(allocator, out, "");
    } else for (asm_value.templates[0..asm_value.template_count], 0..) |template, index| {
        if (index != 0) try out.appendSlice(allocator, " \"\\n\\t\" ");
        try appendQuotedCBytes(allocator, out, template);
    }
    try out.appendSlice(allocator, ");\n");
    try writeIndent(allocator, out, indent);
    try out.appendSlice(allocator, "#else\n");
    try writeIndent(allocator, out, indent);
    try out.appendSlice(allocator, "#error \"#[naked] requires GCC/Clang inline-asm support\"\n");
    try writeIndent(allocator, out, indent);
    try out.appendSlice(allocator, "#endif\n");
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
        .for_each => |loop| if (loop.body_block.eql(block_id) or loop.after_block.eql(block_id)) return true,
        .for_step => |step| if (step.header_block.eql(block_id)) return true,
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
    options: EmitOptions,
) (RenderError || std.mem.Allocator.Error)!void {
    switch (statement.operation) {
        .defer_register => return,
        .cleanup_run => |actions| {
            try emitExecutableCleanupActions(allocator, out, body, actions, indent, options.source_path);
            return;
        },
        else => {},
    }
    try prepareStatementExpressions(allocator, out, body, statement, indent, options.source_path);
    if (statementRepresentationGuard(statement)) |guard| {
        try writeSourceLineDirective(allocator, out, options.source_path, guard.source);
        try emitRepresentationGuard(allocator, out, body, guard, indent);
    }
    try writeSourceLineDirective(allocator, out, options.source_path, statement.source);
    switch (statement.operation) {
        .local_init => |local| {
            try writeIndent(allocator, out, indent);
            const identity = localById(body, local.local) orelse return error.InvalidLocal;
            // Canonical MIR intentionally does not reconstruct source-level liveness in the
            // renderer.  Mark every generated local as potentially unused so pattern bindings
            // and other control-flow-local values remain valid under the toolchain's -Werror
            // policy without adding a second liveness authority to codegen.
            try out.appendSlice(allocator, "MC_UNUSED ");
            if (identity.is_va_list) {
                const value = local.value orelse return error.InvalidExpression;
                if (mir.executableVaStartLocal(body, value) == null) return error.InvalidExpression;
                try out.appendSlice(allocator, "__builtin_va_list ");
                try appendLocal(allocator, out, body, local.local);
                try out.appendSlice(allocator, ";\n");
                try writeIndent(allocator, out, indent);
                try out.appendSlice(allocator, "__builtin_va_start(");
                try appendLocal(allocator, out, body, local.local);
                try out.appendSlice(allocator, ", ");
                try appendLocal(allocator, out, body, body.last_named_parameter);
                try out.appendSlice(allocator, ");\n");
                return;
            }
            if (isSliceType(local.ty) or local.ty == .value) {
                if (local.value == null) return error.UnsupportedType;
                try out.appendSlice(allocator, "__auto_type ");
            } else {
                try appendCType(allocator, out, body, local.ty);
                try out.append(allocator, ' ');
            }
            try appendLocal(allocator, out, body, local.local);
            if (local.value) |value| if (!mir.executableUninitLocalInitializer(body, (expressionById(body, value) orelse return error.InvalidExpression).*)) {
                try out.appendSlice(allocator, " = ");
                try emitExpression(allocator, out, body, value, 0);
            };
            try out.appendSlice(allocator, ";\n");
        },
        .store => |store| {
            try writeIndent(allocator, out, indent);
            switch (store.access.kind) {
                .plain => {
                    if (overlayUnionAccessPlace(body, store.place)) |overlay| {
                        if (overlay.index) |index| {
                            try out.print(allocator, "uintptr_t mc_overlay_index_{d} = mc_check_index_usize(", .{statement.id.raw});
                            try emitExpression(allocator, out, body, index.value, 0);
                            try out.print(allocator, ", {d});\n", .{index.bound.?});
                            try writeIndent(allocator, out, indent);
                        }
                        try out.appendSlice(allocator, "__builtin_memcpy(&(");
                        try emitPlaceRootValue(allocator, out, body, overlay.place);
                        try out.appendSlice(allocator, ").storage[");
                        if (overlay.index != null)
                            try out.print(allocator, "mc_overlay_index_{d} * sizeof(", .{statement.id.raw})
                        else
                            try out.appendSlice(allocator, "0 * sizeof(");
                        try appendCType(allocator, out, body, store.ty);
                        try out.appendSlice(allocator, ")], &(");
                        try emitExpression(allocator, out, body, store.value, 0);
                        try out.appendSlice(allocator, "), sizeof(");
                        try appendCType(allocator, out, body, store.ty);
                        try out.appendSlice(allocator, "));\n");
                        return;
                    }
                    try emitPlace(allocator, out, body, store.place);
                    try out.appendSlice(allocator, " = ");
                    try emitExpression(allocator, out, body, store.value, 0);
                    try out.appendSlice(allocator, ";\n");
                },
                .race_unordered => {
                    if (dynStoreTargetSupported(body, (placeById(body, store.place) orelse return error.InvalidPlace).*, (expressionById(body, store.value) orelse return error.InvalidExpression).*)) {
                        try out.appendSlice(allocator, "__atomic_store_n(&(");
                        try emitPlace(allocator, out, body, store.place);
                        try out.appendSlice(allocator, ".data), (");
                        try emitExpression(allocator, out, body, store.value, 0);
                        try out.appendSlice(allocator, ").data, __ATOMIC_RELAXED);\n");
                        try writeIndent(allocator, out, indent);
                        try out.appendSlice(allocator, "__atomic_store_n(&(");
                        try emitPlace(allocator, out, body, store.place);
                        try out.appendSlice(allocator, ".vtable), (");
                        try emitExpression(allocator, out, body, store.value, 0);
                        try out.appendSlice(allocator, ").vtable, __ATOMIC_RELAXED);\n");
                        return;
                    }
                    if (isSliceType(store.ty)) {
                        try out.print(allocator, "__auto_type mc_store_tmp_{d} = ", .{statement.id.raw});
                        try emitExpression(allocator, out, body, store.value, 0);
                        try out.appendSlice(allocator, ";\n");
                        try writeIndent(allocator, out, indent);
                        try out.appendSlice(allocator, "__atomic_store_n(&(");
                        try emitPlace(allocator, out, body, store.place);
                        try out.print(allocator, ".ptr), mc_store_tmp_{d}.ptr, __ATOMIC_RELAXED);\n", .{statement.id.raw});
                        try writeIndent(allocator, out, indent);
                        try out.appendSlice(allocator, "mc_race_store_usize(&(");
                        try emitPlace(allocator, out, body, store.place);
                        try out.print(allocator, ".len), (uintptr_t)mc_store_tmp_{d}.len);\n", .{statement.id.raw});
                        return;
                    }
                    if (mir.executableAggregateCopyAlignment(store.ty) != null) {
                        var projections: [mir.max_executable_projections]CLeafProjection = undefined;
                        var first = true;
                        const target = placeById(body, store.place) orelse return error.InvalidPlace;
                        try emitRaceAggregateStore(allocator, out, body, store.place, store.ty, target.type_id, store.value, &projections, 0, indent, &first);
                        return;
                    }
                    if ((store.ty == .value and mir.executableCallablePlace(body.aggregate_types, (placeById(body, store.place) orelse return error.InvalidPlace).*) != null) or
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
        .packed_field_store => |store| try emitPackedFieldStore(allocator, out, body, store, indent),
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
        .opaque_asm => |asm_value| try emitOpaqueAsm(allocator, out, asm_value, indent, options.stub_asm),
        .precise_asm => |asm_value| try emitPreciseAsm(allocator, out, body, asm_value, indent, options.stub_asm),
        .return_ => |value| {
            if (blockHasExitCleanup(body, statement.block_id)) {
                if (value) |expression| {
                    try writeIndent(allocator, out, indent);
                    try out.print(allocator, "__auto_type mc_exec_return_{d} = ", .{statement.id.raw});
                    try emitExpression(allocator, out, body, expression, 0);
                    try out.appendSlice(allocator, ";\n");
                }
            } else {
                try writeIndent(allocator, out, indent);
                if (value) |expression| {
                    try out.appendSlice(allocator, "return ");
                    try emitExpression(allocator, out, body, expression, 0);
                    try out.appendSlice(allocator, ";\n");
                } else {
                    try out.appendSlice(allocator, "return;\n");
                }
            }
        },
        // The corresponding CFG edge is the authority for these transfers.
        .control_transfer => {},
        .defer_register, .cleanup_run => unreachable,
        .unsupported => return error.UnsupportedOperation,
    }
}

fn cleanupActionById(body: *const mir.ExecutableBody, id: mir.CleanupActionId) ?*const mir.ExecutableCleanupAction {
    if (!id.isValid() or id.index() >= body.cleanup_actions.len) return null;
    const action = &body.cleanup_actions[id.index()];
    return if (action.id.eql(id)) action else null;
}

fn emitExecutableCleanupActions(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    actions: []const mir.CleanupActionId,
    indent: usize,
    source_path: ?[]const u8,
) (RenderError || std.mem.Allocator.Error)!void {
    for (actions) |id| {
        const action = cleanupActionById(body, id) orelse return error.InvalidBlock;
        const registration = statementById(body, action.registration) orelse return error.InvalidBlock;
        // The same action can appear on several CFG exits. Give each emitted
        // occurrence a C scope so `__auto_type` temporaries owned by the
        // deferred expression never collide across those exits.
        try writeIndent(allocator, out, indent);
        try out.appendSlice(allocator, "{\n");
        // A block-form defer has its own source span in addition to the spans
        // of the expressions inside it. Preserve that registration origin in
        // the generated map even though registration has no runtime work.
        try writeSourceLineDirective(allocator, out, source_path, action.source);
        try writeIndent(allocator, out, indent + 1);
        try out.appendSlice(allocator, "/* canonical defer cleanup */\n");
        for (action.roots) |root| {
            try prepareExpressionSet(allocator, out, body, registration.*, root, indent + 1, source_path);
        }
        try writeIndent(allocator, out, indent);
        try out.appendSlice(allocator, "}\n");
    }
}

fn emitOpaqueAsm(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    asm_value: mir.ExecutableOpaqueAsm,
    indent: usize,
    stub_asm: bool,
) std.mem.Allocator.Error!void {
    try writeIndent(allocator, out, indent);
    if (stub_asm) {
        try out.appendSlice(allocator, "__asm__ __volatile__(\"\" ::: \"memory\");\n");
        return;
    }
    try out.appendSlice(allocator, "#if defined(__GNUC__) || defined(__clang__)\n");
    try writeIndent(allocator, out, indent);
    try out.appendSlice(allocator, if (asm_value.is_volatile) "__asm__ __volatile__(" else "__asm__(");
    if (asm_value.template_count == 0) {
        try appendQuotedCBytes(allocator, out, "");
    } else for (asm_value.templates[0..asm_value.template_count], 0..) |template, index| {
        if (index != 0) try out.appendSlice(allocator, " \"\\n\\t\" ");
        try appendQuotedCBytes(allocator, out, template);
    }
    try out.appendSlice(allocator, " ::: ");
    if (asm_value.clobber_count == 0) {
        try out.appendSlice(allocator, "\"memory\"");
    } else for (asm_value.clobbers[0..asm_value.clobber_count], 0..) |clobber, index| {
        if (index != 0) try out.appendSlice(allocator, ", ");
        try appendQuotedCBytes(allocator, out, clobber);
    }
    try out.appendSlice(allocator, ");\n");
    try writeIndent(allocator, out, indent);
    try out.appendSlice(allocator, "#else\n");
    try writeIndent(allocator, out, indent);
    try out.appendSlice(allocator, "#error \"inline asm emission requires compiler support\"\n");
    try writeIndent(allocator, out, indent);
    try out.appendSlice(allocator, "#endif\n");
}

fn appendQuotedCBytes(allocator: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8) std.mem.Allocator.Error!void {
    try out.append(allocator, '"');
    for (bytes) |byte| switch (byte) {
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '"' => try out.appendSlice(allocator, "\\\""),
        '\'' => try out.appendSlice(allocator, "\\'"),
        '?' => try out.appendSlice(allocator, "\\?"),
        0 => try out.appendSlice(allocator, "\\000"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        32...33, 35...38, 40...62, 64...91, 93...126 => try out.append(allocator, byte),
        else => {
            try out.append(allocator, '\\');
            try out.append(allocator, '0' + ((byte >> 6) & 0x07));
            try out.append(allocator, '0' + ((byte >> 3) & 0x07));
            try out.append(allocator, '0' + (byte & 0x07));
        },
    };
    try out.append(allocator, '"');
}

fn emitPreciseAsm(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    asm_value: mir.ExecutablePreciseAsm,
    indent: usize,
    stub_asm: bool,
) (RenderError || std.mem.Allocator.Error)!void {
    if (stub_asm) {
        for (asm_value.inputs[0..asm_value.input_count]) |input| {
            try writeIndent(allocator, out, indent);
            try out.appendSlice(allocator, "(void)(");
            try emitExpression(allocator, out, body, input.value, 0);
            try out.appendSlice(allocator, ");\n");
        }
        for (asm_value.outputs[0..asm_value.output_count]) |output| {
            try writeIndent(allocator, out, indent);
            try appendLocal(allocator, out, body, output.local);
            try out.appendSlice(allocator, " = 0;\n");
        }
        return;
    }
    try writeIndent(allocator, out, indent);
    try out.appendSlice(allocator, "#if defined(__GNUC__) || defined(__clang__)\n");
    if (asm_value.output_count != 0 or asm_value.input_count != 0) {
        try writeIndent(allocator, out, indent);
        try out.appendSlice(allocator, "/* MC_PRECISE_ASM");
        for (asm_value.outputs[0..asm_value.output_count]) |output| {
            try out.appendSlice(allocator, " out(\"");
            try out.appendSlice(allocator, output.constraint);
            try out.appendSlice(allocator, "\")->");
            try appendLocal(allocator, out, body, output.local);
        }
        for (asm_value.inputs[0..asm_value.input_count]) |input| {
            try out.appendSlice(allocator, " in(\"");
            try out.appendSlice(allocator, input.constraint);
            try out.appendSlice(allocator, "\")");
        }
        try out.appendSlice(allocator, " */\n");
    }
    try writeIndent(allocator, out, indent);
    try out.appendSlice(allocator, if (asm_value.is_volatile) "__asm__ __volatile__(" else "__asm__(");
    if (asm_value.template_count == 0) {
        try appendQuotedCBytes(allocator, out, "");
    } else for (asm_value.templates[0..asm_value.template_count], 0..) |template, index| {
        if (index != 0) try out.appendSlice(allocator, " \"\\n\\t\" ");
        try appendQuotedCBytes(allocator, out, template);
    }
    try out.appendSlice(allocator, " : ");
    for (asm_value.outputs[0..asm_value.output_count], 0..) |output, index| {
        if (index != 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, "\"=r\"(");
        try appendLocal(allocator, out, body, output.local);
        try out.append(allocator, ')');
    }
    try out.appendSlice(allocator, " : ");
    for (asm_value.inputs[0..asm_value.input_count], 0..) |input, index| {
        if (index != 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, "\"r\"(");
        try emitExpression(allocator, out, body, input.value, 0);
        try out.append(allocator, ')');
    }
    if (asm_value.clobber_count != 0) {
        try out.appendSlice(allocator, " : ");
        for (asm_value.clobbers[0..asm_value.clobber_count], 0..) |clobber, index| {
            if (index != 0) try out.appendSlice(allocator, ", ");
            try appendQuotedCBytes(allocator, out, clobber);
        }
    }
    try out.appendSlice(allocator, ");\n");
    try writeIndent(allocator, out, indent);
    try out.appendSlice(allocator, "#else\n");
    try writeIndent(allocator, out, indent);
    try out.appendSlice(allocator, "#error \"inline asm emission requires compiler support\"\n");
    try writeIndent(allocator, out, indent);
    try out.appendSlice(allocator, "#endif\n");
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
            try emitExecutableCleanupActions(allocator, out, body, terminator.exit_cleanup_actions, indent, source_path);
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
        .for_each => |loop| {
            if (!forEachSupported(body, loop)) return error.InvalidBlock;
            try writeIndent(allocator, out, indent);
            try out.appendSlice(allocator, "if (");
            try appendLocal(allocator, out, body, loop.index_local);
            try out.appendSlice(allocator, " < ");
            switch (loop.kind) {
                .fixed_array => try out.print(allocator, "{d}", .{loop.bound.?}),
                .slice => {
                    try appendLocal(allocator, out, body, loop.iterable_local);
                    try out.appendSlice(allocator, ".len");
                },
            }
            try out.appendSlice(allocator, ") { ");
            try appendLocal(allocator, out, body, loop.binding_local);
            try out.appendSlice(allocator, " = ");
            try appendLocal(allocator, out, body, loop.iterable_local);
            try out.appendSlice(allocator, switch (loop.kind) {
                .fixed_array => ".elems[",
                .slice => ".ptr[",
            });
            try appendLocal(allocator, out, body, loop.index_local);
            try out.print(allocator, "]; goto mc_bb_{d}; }} else goto mc_bb_{d};\n", .{ loop.body_block.raw, loop.after_block.raw });
        },
        .for_step => |step| {
            if (!forStepSupported(body, step)) return error.InvalidBlock;
            try writeIndent(allocator, out, indent);
            try appendLocal(allocator, out, body, step.index_local);
            try out.appendSlice(allocator, " += 1;\n");
            try writeIndent(allocator, out, indent);
            try out.print(allocator, "goto mc_bb_{d};\n", .{step.header_block.raw});
        },
        // The value-bearing return is an executable statement.  A bare return
        // terminator only closes paths whose statement stream has no explicit
        // return operation.
        .return_ => {
            try emitExecutableCleanupActions(allocator, out, body, terminator.exit_cleanup_actions, indent, source_path);
            if (terminator.exit_cleanup_actions.len != 0) {
                if (returnStatementForBlock(body, terminator.block_id)) |statement| {
                    if (statement.operation.return_ != null) {
                        try writeIndent(allocator, out, indent);
                        try out.print(allocator, "return mc_exec_return_{d};\n", .{statement.id.raw});
                    } else {
                        try writeIndent(allocator, out, indent);
                        try out.appendSlice(allocator, "return;\n");
                    }
                } else {
                    try writeIndent(allocator, out, indent);
                    try out.appendSlice(allocator, "return;\n");
                }
            } else if (!blockHasReturn(body, terminator.block_id)) {
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

fn returnStatementForBlock(body: *const mir.ExecutableBody, block_id: mir.BlockId) ?*const mir.ExecutableStatement {
    for (body.statements) |*statement| {
        if (!statement.block_id.eql(block_id)) continue;
        if (statement.operation == .return_) return statement;
    }
    return null;
}

fn blockHasExitCleanup(body: *const mir.ExecutableBody, block_id: mir.BlockId) bool {
    for (body.terminators) |terminator| {
        if (terminator.block_id.eql(block_id)) return terminator.exit_cleanup_actions.len != 0;
    }
    return false;
}

const CLeafProjection = union(enum) { field: usize, index: usize };

fn emitCLeafSuffix(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    root_type_id: mir.TypeId,
    projections: []const CLeafProjection,
) (RenderError || std.mem.Allocator.Error)!void {
    var type_id = root_type_id;
    for (projections) |projection| {
        const aggregate = aggregateType(body, type_id) orelse return error.InvalidPlace;
        switch (projection) {
            .field => |field_index| {
                if (field_index >= aggregate.field_count) return error.InvalidPlace;
                try out.append(allocator, '.');
                try appendIdent(allocator, out, aggregate.field_spellings[field_index]);
                type_id = aggregate.field_type_ids[field_index];
            },
            .index => |element_index| {
                if (aggregate.array_length == null or element_index >= aggregate.array_length.? or aggregate.field_count == 0)
                    return error.InvalidPlace;
                try out.print(allocator, ".elems[{d}]", .{element_index});
                type_id = aggregate.field_type_ids[0];
            },
        }
    }
}

fn emitRaceAggregateLoad(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    place_id: mir.PlaceId,
    ty: mir.ValueType,
    type_id: mir.TypeId,
    projections: *[mir.max_executable_projections]CLeafProjection,
    projection_count: usize,
) (RenderError || std.mem.Allocator.Error)!void {
    if (mir.executableAggregateCopyAlignment(ty) == null) {
        if (scalarMemoryInfo(ty)) |scalar| {
            try out.print(allocator, "(({s})mc_race_load_{s}(&(", .{ scalar.c_type, scalar.helper_suffix });
            try emitPlace(allocator, out, body, place_id);
            try emitCLeafSuffix(allocator, out, body, (placeById(body, place_id) orelse return error.InvalidPlace).type_id, projections[0..projection_count]);
            try out.appendSlice(allocator, ")))");
        } else {
            try out.appendSlice(allocator, "__atomic_load_n(&(");
            try emitPlace(allocator, out, body, place_id);
            try emitCLeafSuffix(allocator, out, body, (placeById(body, place_id) orelse return error.InvalidPlace).type_id, projections[0..projection_count]);
            try out.appendSlice(allocator, "), __ATOMIC_RELAXED)");
        }
        return;
    }
    if (projection_count >= projections.len) return error.UnsupportedType;
    const shape = aggregateType(body, type_id) orelse return error.UnsupportedType;
    if (shape.construction != .declared_struct or !mir.ValueType.eql(shape.ty, ty)) return error.UnsupportedType;
    try out.appendSlice(allocator, "((");
    try appendCType(allocator, out, body, ty);
    try out.appendSlice(allocator, if (shape.array_length != null) "){ .elems = { " else "){ ");
    const count = shape.array_length orelse shape.field_count;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        if (index != 0) try out.appendSlice(allocator, ", ");
        const metadata_index: usize = if (shape.array_length != null) 0 else index;
        if (metadata_index >= shape.field_count) return error.UnsupportedType;
        if (shape.array_length != null) {
            try out.print(allocator, "[{d}] = ", .{index});
            projections[projection_count] = .{ .index = index };
        } else {
            try out.append(allocator, '.');
            try appendIdent(allocator, out, shape.field_spellings[index]);
            try out.appendSlice(allocator, " = ");
            projections[projection_count] = .{ .field = index };
        }
        try emitRaceAggregateLoad(allocator, out, body, place_id, shape.field_types[metadata_index], shape.field_type_ids[metadata_index], projections, projection_count + 1);
    }
    try out.appendSlice(allocator, if (shape.array_length != null) " } })" else " })");
}

fn emitRaceAggregateStore(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    place_id: mir.PlaceId,
    ty: mir.ValueType,
    type_id: mir.TypeId,
    value_id: mir.ExprId,
    projections: *[mir.max_executable_projections]CLeafProjection,
    projection_count: usize,
    indent: usize,
    first: *bool,
) (RenderError || std.mem.Allocator.Error)!void {
    if (mir.executableAggregateCopyAlignment(ty) == null) {
        if (!first.*) try writeIndent(allocator, out, indent);
        first.* = false;
        if (scalarMemoryInfo(ty)) |scalar| {
            try out.print(allocator, "mc_race_store_{s}(&(", .{scalar.helper_suffix});
            try emitPlace(allocator, out, body, place_id);
            try emitCLeafSuffix(allocator, out, body, (placeById(body, place_id) orelse return error.InvalidPlace).type_id, projections[0..projection_count]);
            try out.print(allocator, "), ({s})(", .{scalar.c_type});
            try emitExpression(allocator, out, body, value_id, 0);
            try out.append(allocator, ')');
            try emitCLeafSuffix(allocator, out, body, (expressionById(body, value_id) orelse return error.InvalidExpression).type_id, projections[0..projection_count]);
            try out.appendSlice(allocator, ");\n");
        } else {
            try out.appendSlice(allocator, "__atomic_store_n(&(");
            try emitPlace(allocator, out, body, place_id);
            try emitCLeafSuffix(allocator, out, body, (placeById(body, place_id) orelse return error.InvalidPlace).type_id, projections[0..projection_count]);
            try out.appendSlice(allocator, "), (");
            try emitExpression(allocator, out, body, value_id, 0);
            try out.append(allocator, ')');
            try emitCLeafSuffix(allocator, out, body, (expressionById(body, value_id) orelse return error.InvalidExpression).type_id, projections[0..projection_count]);
            try out.appendSlice(allocator, ", __ATOMIC_RELAXED);\n");
        }
        return;
    }
    if (projection_count >= projections.len) return error.UnsupportedType;
    const shape = aggregateType(body, type_id) orelse return error.UnsupportedType;
    if (shape.construction != .declared_struct or !mir.ValueType.eql(shape.ty, ty)) return error.UnsupportedType;
    const count = shape.array_length orelse shape.field_count;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const metadata_index: usize = if (shape.array_length != null) 0 else index;
        if (metadata_index >= shape.field_count) return error.UnsupportedType;
        projections[projection_count] = if (shape.array_length != null) .{ .index = index } else .{ .field = index };
        try emitRaceAggregateStore(allocator, out, body, place_id, shape.field_types[metadata_index], shape.field_type_ids[metadata_index], value_id, projections, projection_count + 1, indent, first);
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

fn emitRacePairLoad(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    place: mir.PlaceId,
    id: mir.ExprId,
    kind: enum { dyn_value, slice },
) (RenderError || std.mem.Allocator.Error)!void {
    try out.print(allocator, "({{ __auto_type mc_pair_ptr_{d} = ", .{id.raw});
    try emitPlaceAddress(allocator, out, body, place);
    switch (kind) {
        .dyn_value => try out.print(
            allocator,
            "; (__typeof__(*mc_pair_ptr_{0d})){{ .data = __atomic_load_n(&(mc_pair_ptr_{0d}->data), __ATOMIC_RELAXED), .vtable = __atomic_load_n(&(mc_pair_ptr_{0d}->vtable), __ATOMIC_RELAXED) }}; }})",
            .{id.raw},
        ),
        .slice => try out.print(
            allocator,
            "; (__typeof__(*mc_pair_ptr_{0d})){{ .ptr = __atomic_load_n(&(mc_pair_ptr_{0d}->ptr), __ATOMIC_RELAXED), .len = (size_t)mc_race_load_usize(&(mc_pair_ptr_{0d}->len)) }}; }})",
            .{id.raw},
        ),
    }
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
            .plain => if (overlayUnionAccessPlace(body, load.place)) |overlay|
                try emitOverlayUnionLoad(allocator, out, body, expression.*, overlay, depth)
            else
                try emitPlace(allocator, out, body, load.place),
            .race_unordered => {
                if (mir.executableAggregateCopyAlignment(expression.result_ty) != null) {
                    var projections: [mir.max_executable_projections]CLeafProjection = undefined;
                    try emitRaceAggregateLoad(allocator, out, body, load.place, expression.result_ty, expression.type_id, &projections, 0);
                    return;
                }
                if (dynLoadTargetSupported(body, expression.*, load)) {
                    try emitRacePairLoad(allocator, out, body, load.place, expression.id, .dyn_value);
                    return;
                }
                if (sliceLoadTargetSupported(body, expression.*, load)) {
                    try emitRacePairLoad(allocator, out, body, load.place, expression.id, .slice);
                    return;
                }
                if (expression.result_ty == .value and callableLoadTargetSupported(body, expression.*, load) and
                    expressionUsedAsClosureIndirectCallee(body, expression.id))
                {
                    try out.print(allocator, "({{ __auto_type mc_closure_ptr_{d} = ", .{expression.id.raw});
                    try emitPlaceAddress(allocator, out, body, load.place);
                    try out.print(allocator, "; __typeof__(*mc_closure_ptr_{d}) mc_closure_tmp_{d}; __atomic_load(mc_closure_ptr_{d}, &mc_closure_tmp_{d}, __ATOMIC_RELAXED); mc_closure_tmp_{d}; }})", .{ expression.id.raw, expression.id.raw, expression.id.raw, expression.id.raw, expression.id.raw });
                    return;
                }
                if (expression.result_ty == .value and callableLoadTargetSupported(body, expression.*, load)) {
                    try out.appendSlice(allocator, "__atomic_load_n(");
                    try emitPlaceAddress(allocator, out, body, load.place);
                    try out.appendSlice(allocator, ", __ATOMIC_RELAXED)");
                    return;
                }
                if (expression.result_ty == .closed_enum or expression.result_ty == .open_enum) {
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
                if (expression.result_ty == .pointer) {
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
        .maybe_uninit_write => |operation| {
            try out.append(allocator, '(');
            try appendLocal(allocator, out, body, operation.local);
            try out.appendSlice(allocator, " = ");
            try emitExpression(allocator, out, body, operation.value, depth + 1);
            try out.appendSlice(allocator, ", (void)0)");
        },
        .maybe_uninit_assume_init => |operation| try appendLocal(allocator, out, body, operation.local),
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
            try out.appendSlice(allocator, "((");
            try appendCType(allocator, out, body, expression.result_ty);
            try out.print(allocator, ")mc_mmio_read_{s}(", .{scalar.helper_suffix});
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
        .literal => |literal| try emitLiteral(allocator, out, body, expression.result_ty, literal),
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
        .closure_bind => |bind| try emitClosureBind(allocator, out, body, bind, depth),
        .indirect_call => |call| {
            if (call.signature.has_environment) {
                try out.append(allocator, '(');
                try emitExpression(allocator, out, body, call.callee, depth + 1);
                try out.appendSlice(allocator, ").code((");
                try emitExpression(allocator, out, body, call.callee, depth + 1);
                try out.appendSlice(allocator, ").env");
                for (call.arguments[0..call.argument_count]) |argument| {
                    try out.appendSlice(allocator, ", ");
                    try emitExpression(allocator, out, body, argument, 0);
                }
                try out.append(allocator, ')');
            } else {
                try out.append(allocator, '(');
                try emitExpression(allocator, out, body, call.callee, depth + 1);
                try out.append(allocator, ')');
                try emitPreparedArguments(allocator, out, body, call.arguments[0..call.argument_count]);
            }
        },
        .dyn_call => |call| {
            const trait = symbolById(body, call.trait_symbol) orelse return error.InvalidExpression;
            try out.print(allocator, "({{ mc_dyn_{s} mc_dyn_tmp_{d} = ", .{ trait.spelling, expression.id.raw });
            try emitPlace(allocator, out, body, call.receiver);
            try out.print(allocator, "; mc_dyn_tmp_{d}.vtable->{s}(mc_dyn_tmp_{d}.data", .{
                expression.id.raw,
                call.method_spelling,
                expression.id.raw,
            });
            for (call.arguments[0..call.argument_count]) |argument| {
                try out.appendSlice(allocator, ", ");
                try emitExpression(allocator, out, body, argument, 0);
            }
            try out.appendSlice(allocator, "); })");
        },
        .dyn_bind => |bind| {
            const trait = symbolById(body, bind.trait_symbol) orelse return error.InvalidExpression;
            const concrete = symbolById(body, bind.concrete_type_symbol) orelse return error.InvalidExpression;
            try out.print(allocator, "((mc_dyn_{s}){{ .data = (void *)", .{trait.spelling});
            try emitExpression(allocator, out, body, bind.source, depth + 1);
            try out.print(allocator, ", .vtable = &__vt_{s}_{s} }})", .{ concrete.spelling, trait.spelling });
        },
        .builtin_call => |call| try emitBuiltinCall(allocator, out, body, expression, call, depth),
        .representation_check => |check| try emitExpression(allocator, out, body, check.operand, depth + 1),
        .address_of => |address| try emitPlaceAddress(allocator, out, body, address.place),
        .deref => |operand| {
            try out.appendSlice(allocator, "(*(");
            try emitExpression(allocator, out, body, operand, depth + 1);
            try out.appendSlice(allocator, "))");
        },
        .index => |index| {
            if (!indexSupported(body, expression.*, index)) return error.InvalidExpression;
            const slice_scalar = if (index.kind == .slice) scalarMemoryInfo(expression.result_ty) else null;
            const slice_aggregate = if (index.kind == .slice and slice_scalar == null)
                raceAggregateLoadShape(body, expression.*) orelse return error.UnsupportedType
            else
                null;
            if (slice_aggregate) |shape| {
                try out.appendSlice(allocator, "((");
                try appendCType(allocator, out, body, expression.result_ty);
                try out.appendSlice(allocator, "){ ");
                for (shape.field_types[0..shape.field_count], shape.field_spellings[0..shape.field_count], 0..) |field_ty, field_name, field_index| {
                    if (field_index != 0) try out.appendSlice(allocator, ", ");
                    const scalar = scalarMemoryInfo(field_ty) orelse return error.UnsupportedType;
                    try out.print(allocator, ".{s} = (({s})mc_race_load_{s}(&(", .{ field_name, scalar.c_type, scalar.helper_suffix });
                    try out.append(allocator, '(');
                    try emitExpression(allocator, out, body, index.base, depth + 1);
                    try out.appendSlice(allocator, ").ptr[");
                    if (index.checked) try out.appendSlice(allocator, "mc_check_index_usize(");
                    try emitExpression(allocator, out, body, index.index, depth + 1);
                    if (index.checked) {
                        try out.appendSlice(allocator, ", (");
                        try emitExpression(allocator, out, body, index.base, depth + 1);
                        try out.appendSlice(allocator, ").len)");
                    }
                    try out.print(allocator, "].{s})))", .{field_name});
                }
                try out.appendSlice(allocator, " })");
                return;
            }
            if (slice_scalar) |scalar| try out.print(allocator, "(({s})mc_race_load_{s}(&(", .{ scalar.c_type, scalar.helper_suffix });
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
            if (slice_scalar != null) try out.appendSlice(allocator, ")))");
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
        .tagged_union_construct => |operation| {
            const shape = taggedUnionType(body, expression.type_id) orelse return error.InvalidExpression;
            if (operation.case_index >= shape.case_count) return error.InvalidExpression;
            const case = shape.cases[operation.case_index];
            try out.appendSlice(allocator, "((");
            try appendCType(allocator, out, body, shape.ty);
            try out.appendSlice(allocator, "){ .tag = ");
            try appendIdent(allocator, out, shape.ty.tagged_union);
            try out.appendSlice(allocator, "Tag_");
            try appendIdent(allocator, out, case.spelling);
            if (case.has_payload) {
                const payload = operation.payload orelse return error.InvalidExpression;
                try out.appendSlice(allocator, ", .payload.");
                try appendIdent(allocator, out, case.spelling);
                try out.appendSlice(allocator, " = ");
                try emitExpression(allocator, out, body, payload, depth + 1);
            } else if (operation.payload != null) return error.InvalidExpression;
            try out.appendSlice(allocator, " })");
        },
        .tagged_union_tag => |operand| {
            try out.append(allocator, '(');
            try emitExpression(allocator, out, body, operand, depth + 1);
            try out.appendSlice(allocator, ").tag");
        },
        .tagged_union_payload => |operation| {
            const operand = expressionById(body, operation.operand) orelse return error.InvalidExpression;
            const shape = taggedUnionType(body, operand.type_id) orelse return error.InvalidExpression;
            if (operation.case_index >= shape.case_count or !shape.cases[operation.case_index].has_payload)
                return error.InvalidExpression;
            try out.append(allocator, '(');
            try emitExpression(allocator, out, body, operation.operand, depth + 1);
            try out.appendSlice(allocator, ").payload.");
            try appendIdent(allocator, out, shape.cases[operation.case_index].spelling);
        },
        .try_unwrap => |operand_id| {
            try out.append(allocator, '(');
            try emitExpression(allocator, out, body, operand_id, depth + 1);
            switch ((expressionById(body, operand_id) orelse return error.InvalidExpression).result_ty) {
                .nullable_pointer => {},
                .nullable_value => try out.appendSlice(allocator, ".value"),
                .result => try out.appendSlice(allocator, ".payload.ok"),
                else => return error.InvalidExpression,
            }
            try out.append(allocator, ')');
        },
        .try_propagate => |operation| {
            try out.append(allocator, '(');
            try emitExpression(allocator, out, body, operation.operand, depth + 1);
            try out.appendSlice(allocator, ".payload.ok)");
        },
        .try_map_error => |operation| {
            try out.append(allocator, '(');
            try emitExpression(allocator, out, body, operation.operand, depth + 1);
            try out.appendSlice(allocator, ".payload.ok)");
        },
        .mmio_map_checked => |operation| {
            try out.appendSlice(allocator, "((void volatile *)((uintptr_t)");
            try emitExpression(allocator, out, body, operation.address, depth + 1);
            try out.appendSlice(allocator, "))");
        },
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
            for (aggregate.operands, 0..) |operand, index| {
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
            if (shape.construction == .c_union) {
                const field_index = aggregate.field_indices[0];
                if (shape.is_overlay_union) {
                    try out.appendSlice(allocator, "({ ");
                    try appendCType(allocator, out, body, shape.ty);
                    try out.print(allocator, " mc_union_{d} = {{0}}; ", .{expression.id.raw});
                    try appendCType(allocator, out, body, shape.field_types[field_index]);
                    try out.print(allocator, " mc_union_field_{d} = ", .{expression.id.raw});
                    try emitExpression(allocator, out, body, aggregate.operands[0], depth + 1);
                    try out.print(allocator, "; __builtin_memcpy(mc_union_{d}.storage, &mc_union_field_{d}, sizeof(mc_union_field_{d})); mc_union_{d}; }})", .{
                        expression.id.raw,
                        expression.id.raw,
                        expression.id.raw,
                        expression.id.raw,
                    });
                    return;
                }
                try out.append(allocator, '(');
                try appendCType(allocator, out, body, shape.ty);
                try out.appendSlice(allocator, "){ .");
                try appendIdent(allocator, out, shape.field_spellings[field_index]);
                try out.appendSlice(allocator, " = ");
                try emitExpression(allocator, out, body, aggregate.operands[0], depth + 1);
                try out.appendSlice(allocator, " }");
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
            if (shape.construction == .c_union and shape.is_overlay_union) {
                try out.appendSlice(allocator, "({ ");
                try appendCType(allocator, out, body, expression.result_ty);
                try out.print(allocator, " mc_overlay_read_{d}; __builtin_memcpy(&mc_overlay_read_{d}, (", .{ expression.id.raw, expression.id.raw });
                try emitExpression(allocator, out, body, member.base, depth + 1);
                try out.print(allocator, ").storage, sizeof(mc_overlay_read_{d})); mc_overlay_read_{d}; }})", .{ expression.id.raw, expression.id.raw });
                return;
            }
            try out.append(allocator, '(');
            try emitExpression(allocator, out, body, member.base, depth + 1);
            try out.appendSlice(allocator, ").");
            try appendIdent(allocator, out, shape.field_spellings[member.field_index]);
        },
        .range_slice => |range| try emitRangeSlice(allocator, out, body, expression.*, range, depth),
        .unsupported => return error.UnsupportedOperation,
    }
}

/// Backend capability admission layered on top of the producer's semantic
/// completeness bit.  This is deliberately structural and typed: it never
/// consults source text, spans, or declaration ASTs.
pub fn canEmitBody(body: *const mir.ExecutableBody) bool {
    if (!body.isComplete() or body.terminators.len == 0) return false;
    for (body.parameters) |parameter| if (!supportsParameter(body, parameter) or
        localById(body, parameter.local) == null)
        return false;
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
            !mir.executableGuardedLocalAggregateDerefPlace(body, place, false) and
            !mir.executableParameterProjectedPlace(body, place, false) and
            mir.executableFixedArrayIndexPlace(body, place) == null and
            mir.executableSliceIndexPlace(body, place) == null)
            return false;
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
                if (localById(body, local.local) == null) return false;
                if (local.value) |value| {
                    const expression = expressionById(body, value) orelse return false;
                    if (!localInitializerTypeCompatible(local.ty, expression.result_ty)) return false;
                    if (!(supportsType(body, local.ty) or callableValueExpressionSupported(body, expression.*) or
                        dynBindSupported(body, expression.*) or opaqueValueExpressionSupported(body, expression.*) or
                        (mir.executableVaListLocal(body, local.local) and mir.executableVaStartLocal(body, value) != null) or
                        (local.ty == .value and dynLocal(body, local.local)))) return false;
                } else if (isSliceType(local.ty) or local.ty == .value) return false;
            },
            .store => |store| if (!memoryStoreSupported(body, statement, store)) return false,
            .packed_field_store => |store| if (!packedFieldStoreSupported(body, statement, store)) return false,
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
            .opaque_asm => |asm_value| if (asm_value.template_count > mir.max_executable_operands or
                asm_value.clobber_count > mir.max_executable_operands) return false,
            .precise_asm => |asm_value| if (!preciseAsmSupported(body, asm_value)) return false,
            .control_transfer => {},
            .defer_register, .cleanup_run => {},
            .unsupported => return false,
        }
    }
    for (body.terminators) |terminator| switch (terminator.operation) {
        // Block slice order is storage order, not a verified CFG edge.
        .fallthrough => return false,
        .return_, .unreachable_ => {},
        .trap_ => |kind| if (trapHelper(kind) == null) return false,
        .jump => |target| if (!hasBlock(body, target)) return false,
        .branch => |branch| if (expressionById(body, branch.condition) == null or !hasBlock(body, branch.true_block) or !hasBlock(body, branch.false_block)) return false,
        .for_each => |loop| if (!forEachSupported(body, loop)) return false,
        .for_step => |step| if (!forStepSupported(body, step)) return false,
        .switch_ => |switch_| if (!switchTerminatorSupported(body, switch_)) return false,
    };
    return true;
}

fn preciseAsmSupported(body: *const mir.ExecutableBody, asm_value: mir.ExecutablePreciseAsm) bool {
    if (asm_value.template_count > mir.max_executable_operands or asm_value.clobber_count > mir.max_executable_operands or
        asm_value.output_count > mir.max_executable_operands or asm_value.input_count > mir.max_executable_operands) return false;
    for (asm_value.outputs[0..asm_value.output_count]) |output| {
        const declaration = localInit(body, output.local) orelse return false;
        if (!declaration.mutable or !sameValueType(declaration.ty, output.ty) or
            !declaration.type_id.eql(output.type_id) or !supportsType(body, output.ty)) return false;
    }
    for (asm_value.inputs[0..asm_value.input_count]) |input| {
        const value = expressionById(body, input.value) orelse return false;
        if (!sameValueType(value.result_ty, input.ty) or !value.type_id.eql(input.type_id) or
            !supportsType(body, input.ty)) return false;
    }
    return true;
}

fn packedFieldStoreSupported(
    body: *const mir.ExecutableBody,
    statement: mir.ExecutableStatement,
    store: @FieldType(mir.ExecutableStatement.Operation, "packed_field_store"),
) bool {
    const place = placeById(body, store.place) orelse return false;
    const value = expressionById(body, store.value) orelse return false;
    const aggregate = aggregateType(body, place.type_id) orelse return false;
    if (place.storage != .ordinary or place.projection_count != 0 or
        !sameValueType(place.root_ty, place.ty) or !place.root_type_id.eql(place.type_id) or
        aggregate.construction != .packed_bits or !sameValueType(aggregate.ty, place.ty) or
        store.field_index >= aggregate.field_count or aggregate.field_types[store.field_index] != .bool or
        value.result_ty != .bool or !value.type_id.eql(aggregate.field_type_ids[store.field_index]) or
        scalarMemoryInfo(aggregate.storage_ty) == null or
        store.access.alignment != mir.executableMemoryAlignment(body.enum_types, aggregate.storage_ty) or
        ownedStatementTrapEdgeCount(body, statement.id) != 0) return false;
    return switch (place.root) {
        .local => |local| localById(body, local) != null and store.access.kind == .plain,
        .symbol => |symbol| if (symbolById(body, symbol)) |identity|
            identity.kind == .global and identity.mutable and store.access.kind == .race_unordered
        else
            false,
        .value => false,
    };
}

fn emitPackedFieldStore(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    store: @FieldType(mir.ExecutableStatement.Operation, "packed_field_store"),
    indent: usize,
) (RenderError || std.mem.Allocator.Error)!void {
    const place = placeById(body, store.place) orelse return error.InvalidPlace;
    const aggregate = aggregateType(body, place.type_id) orelse return error.InvalidPlace;
    const scalar = scalarMemoryInfo(aggregate.storage_ty) orelse return error.UnsupportedType;
    if (store.field_index >= 128) return error.UnsupportedOperation;
    const mask = @as(u128, 1) << @intCast(store.field_index);

    try writeIndent(allocator, out, indent);
    if (store.access.kind == .race_unordered) {
        try out.print(allocator, "mc_race_store_{s}(", .{scalar.helper_suffix});
        try emitPlaceAddress(allocator, out, body, store.place);
        try out.print(allocator, ", ({s})((mc_race_load_{s}(", .{ scalar.c_type, scalar.helper_suffix });
        try emitPlaceAddress(allocator, out, body, store.place);
        try out.print(allocator, ") & ({s})~(({s}){d})) | (", .{ scalar.c_type, scalar.c_type, mask });
        try emitExpression(allocator, out, body, store.value, 0);
        try out.print(allocator, " ? ({s}){d} : ({s})0)));\n", .{ scalar.c_type, mask, scalar.c_type });
        return;
    }
    try emitPlace(allocator, out, body, store.place);
    try out.appendSlice(allocator, " = (");
    try appendCType(allocator, out, body, place.ty);
    try out.appendSlice(allocator, ")((");
    try emitPlace(allocator, out, body, store.place);
    try out.print(allocator, " & ({s})~(({s}){d})) | (", .{ scalar.c_type, scalar.c_type, mask });
    try emitExpression(allocator, out, body, store.value, 0);
    try out.print(allocator, " ? ({s}){d} : ({s})0));\n", .{ scalar.c_type, mask, scalar.c_type });
}

fn localInit(body: *const mir.ExecutableBody, id: mir.LocalId) ?@FieldType(mir.ExecutableStatement.Operation, "local_init") {
    var found: ?@FieldType(mir.ExecutableStatement.Operation, "local_init") = null;
    for (body.statements) |statement| switch (statement.operation) {
        .local_init => |init| if (init.local.eql(id)) {
            if (found != null) return null;
            found = init;
        },
        else => {},
    };
    return found;
}

fn forEachSupported(body: *const mir.ExecutableBody, loop: mir.ExecutableForEachTerminator) bool {
    if (!hasBlock(body, loop.body_block) or !hasBlock(body, loop.after_block)) return false;
    const iterable = localInit(body, loop.iterable_local) orelse return false;
    const index = localInit(body, loop.index_local) orelse return false;
    const binding = localInit(body, loop.binding_local) orelse return false;
    if (!mir.ValueType.eql(iterable.ty, loop.iterable_ty) or !iterable.type_id.eql(loop.iterable_type_id) or
        !mir.ValueType.eql(index.ty, .{ .integer = "usize" }) or !index.type_id.eql(loop.index_type_id) or
        !mir.ValueType.eql(binding.ty, loop.element_ty) or !binding.type_id.eql(loop.element_type_id) or
        binding.value != null) return false;
    return switch (loop.kind) {
        .fixed_array => loop.bound != null and switch (loop.iterable_ty) {
            .array => |shape| shape.length != null and shape.length.? == loop.bound.? and std.mem.eql(u8, shape.child, loop.element_ty.name()),
            else => false,
        },
        .slice => loop.bound == null and switch (loop.iterable_ty) {
            .pointer => |shape| shape.kind == .slice and std.mem.eql(u8, shape.child, loop.element_ty.name()),
            .slice => |child| std.mem.eql(u8, child, loop.element_ty.name()),
            else => false,
        },
    };
}

fn forStepSupported(body: *const mir.ExecutableBody, step: mir.ExecutableForStepTerminator) bool {
    if (!hasBlock(body, step.header_block)) return false;
    const index = localInit(body, step.index_local) orelse return false;
    return mir.ValueType.eql(index.ty, .{ .integer = "usize" }) and index.type_id.eql(step.index_type_id) and index.mutable;
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
    if (expression.result_ty == .value and mir.executableVaStartLocal(body, expression.id) == null) return callableValueExpressionSupported(body, expression) or
        dynBindSupported(body, expression) or opaqueValueExpressionSupported(body, expression) or
        switch (expression.operation) {
            .index => |index| indexSupported(body, expression, index),
            else => false,
        };
    if (!supportsType(body, expression.result_ty) and
        mir.executableVaStartLocal(body, expression.id) == null) return false;
    return switch (expression.operation) {
        .local => |local| localById(body, local) != null,
        // A global aggregate symbol is only an addressable base for one typed
        // fixed-array index. The index operation owns the actual read and its
        // bounds edge; every other bare global value remains fail-closed.
        .symbol => globalAggregateIndexBaseSupported(body, expression),
        .load => |load| memoryLoadSupported(body, expression, load),
        .atomic_load => |load| atomicLoadSupported(body, expression, load),
        .atomic_init => |operand| atomicInitSupported(body, expression, operand),
        .maybe_uninit_write => |operation| maybeUninitWriteSupported(body, expression, operation),
        .maybe_uninit_assume_init => |operation| maybeUninitAssumeInitSupported(body, expression, operation),
        .atomic_update => |update| atomicUpdateSupported(body, expression, update),
        .mmio_read => |read| mmioReadSupported(body, expression, read),
        .mmio_write => |write| mmioWriteSupported(body, expression, write),
        .literal => |literal| switch (literal) {
            .float => |value| mir.executableFloatMatchesType(value, expression.result_ty),
            .uninit => mir.executableUninitLocalInitializer(body, expression) or
                mir.executableUninitAggregateOperand(body, expression),
            .string => stringLiteralTypeSupported(expression.result_ty),
            .enum_value => false,
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
        .closure_bind => |bind| closureBindSupported(body, expression, bind),
        .indirect_call => |call| indirectCallSupported(body, expression, call),
        .dyn_call => |call| dynCallSupported(body, expression, call),
        .dyn_bind => |bind| dynBindSupported(body, expression) and expressionById(body, bind.source) != null,
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
        .tagged_union_construct => |operation| taggedUnionConstructionSupported(body, expression, operation),
        .tagged_union_tag => |operand| taggedUnionTagSupported(body, expression, operand),
        .tagged_union_payload => |operation| taggedUnionPayloadSupported(body, expression, operation),
        .try_unwrap => |operand| tryUnwrapSupported(body, expression, operand),
        .try_propagate => |operation| tryPropagateSupported(body, expression, operation.operand),
        .try_map_error => |operation| tryMapErrorSupported(body, expression, operation),
        .mmio_map_checked => |operation| mmioMapCheckedSupported(body, expression, operation),
        .result => |result| resultConstructionSupported(body, expression, result),
        .index => |index| indexSupported(body, expression, index),
        .range_slice => |range| rangeSliceSupported(body, expression, range),
        .deref, .unsupported => false,
    };
}

fn dynBindSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    const bind = switch (expression.operation) {
        .dyn_bind => |value| value,
        else => return false,
    };
    if (expression.result_ty != .value or !expression.type_id.isValid()) return false;
    const source = expressionById(body, bind.source) orelse return false;
    const pointer = switch (source.result_ty) {
        .pointer => |shape| shape,
        else => return false,
    };
    const trait = symbolById(body, bind.trait_symbol) orelse return false;
    const concrete = symbolById(body, bind.concrete_type_symbol) orelse return false;
    return pointer.kind == .single and trait.kind == .trait and concrete.kind == .type_ and
        std.mem.eql(u8, pointer.child, concrete.spelling);
}

fn opaqueValueExpressionSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    if (expression.result_ty != .value or !expression.type_id.isValid()) return false;
    if (dynTraitExpression(body, expression)) |_| return true;
    return switch (expression.operation) {
        .direct_call => |call| call.argument_count <= call.arguments.len and
            symbolById(body, call.callee) != null and allExpressionsExist(body, call.arguments[0..call.argument_count]),
        else => false,
    };
}

/// Return the exact trait-object identity carried by a canonical expression.
/// `.value` deliberately covers several unrelated representations, so callers
/// must compare this SymbolId instead of accepting an opaque value by shape.
fn dynTraitExpression(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) ?mir.SymbolId {
    if (expression.result_ty != .value or !expression.type_id.isValid()) return null;
    return switch (expression.operation) {
        .dyn_bind => |bind| if (dynBindSupported(body, expression)) bind.trait_symbol else null,
        .local => |local| local_dyn: {
            if (localById(body, local)) |identity| if (identity.dyn_trait_symbol_id.isValid())
                break :local_dyn identity.dyn_trait_symbol_id;
            for (body.parameters) |parameter| if (parameter.local.eql(local) and
                parameter.dyn_trait_symbol_id.isValid()) break :local_dyn parameter.dyn_trait_symbol_id;
            break :local_dyn null;
        },
        .load => |load| load_dyn: {
            if (!dynLoadTargetSupported(body, expression, load) or !memoryLoadSupported(body, expression, load))
                break :load_dyn null;
            const place = placeById(body, load.place) orelse break :load_dyn null;
            break :load_dyn mir.executableDynTraitPlace(body, place.*);
        },
        .member => |member| member_dyn: {
            if (!memberSupported(body, expression, member)) break :member_dyn null;
            const base = expressionById(body, member.base) orelse break :member_dyn null;
            const shape = aggregateType(body, base.type_id) orelse break :member_dyn null;
            const trait = shape.field_dyn_trait_symbols[member.field_index];
            break :member_dyn if (trait.isValid()) trait else null;
        },
        .direct_call => |call| call_dyn: {
            if (call.argument_count > call.arguments.len or !allExpressionsExist(body, call.arguments[0..call.argument_count]))
                break :call_dyn null;
            const callee = symbolById(body, call.callee) orelse break :call_dyn null;
            break :call_dyn if (callee.kind == .function and callee.return_dyn_trait_symbol_id.isValid())
                callee.return_dyn_trait_symbol_id
            else
                null;
        },
        else => null,
    };
}

fn expressionMatchesDynTrait(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, expected: mir.SymbolId) bool {
    if (!expected.isValid()) return false;
    const actual = dynTraitExpression(body, expression) orelse return false;
    return actual.eql(expected);
}

fn dynLocal(body: *const mir.ExecutableBody, local: mir.LocalId) bool {
    const identity = localById(body, local) orelse return false;
    return identity.dyn_trait_symbol_id.isValid();
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
    const payload_valid = switch (operand.result_ty) {
        .nullable_pointer => |shape| sameValueType(expression.result_ty, .{ .pointer = shape }),
        .nullable_value => optional: {
            const aggregate = aggregateType(body, operand.type_id) orelse break :optional false;
            break :optional aggregate.construction == .declared_struct and
                aggregate.ty == .nullable_value and aggregate.field_count == 2 and
                sameValueType(expression.result_ty, aggregate.field_types[1]) and
                expression.type_id.eql(aggregate.field_type_ids[1]);
        },
        .result => result: {
            const shape = resultType(body, operand.type_id) orelse break :result false;
            break :result sameValueType(expression.result_ty, shape.ok_ty) and
                expression.type_id.eql(shape.ok_type_id);
        },
        else => false,
    };
    return payload_valid and tryUnwrapTrapEdge(body, expression) != null;
}

fn tryPropagateSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, operand_id: mir.ExprId) bool {
    const operand = expressionById(body, operand_id) orelse return false;
    if (operand.result_ty != .result or !operand.type_id.eql(body.return_type_id) or
        ownedTrapEdgeCount(body, expression.id) != 0) return false;
    const shape = resultType(body, operand.type_id) orelse return false;
    return sameValueType(shape.ty, operand.result_ty) and
        sameValueType(expression.result_ty, shape.ok_ty) and expression.type_id.eql(shape.ok_type_id);
}

fn tryMapErrorSupported(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    operation: @FieldType(mir.ExecutableExpression.Operation, "try_map_error"),
) bool {
    const operand = expressionById(body, operation.operand) orelse return false;
    if (operand.result_ty != .result or ownedTrapEdgeCount(body, expression.id) != 0) return false;
    const source = resultType(body, operand.type_id) orelse return false;
    const target = resultType(body, body.return_type_id) orelse return false;
    if (!sameValueType(source.ok_ty, target.ok_ty) or
        !sameValueType(expression.result_ty, source.ok_ty) or !expression.type_id.eql(source.ok_type_id)) return false;
    return switch (operation.mapper) {
        .conversion => |conversion| conversion_valid: {
            const callee = symbolById(body, conversion.callee) orelse break :conversion_valid false;
            const signature = conversion.signature;
            break :conversion_valid callee.kind == .function and signature.parameter_count == 1 and
                !signature.has_environment and sameValueType(signature.parameter_types[0], source.err_ty) and
                signature.parameter_type_ids[0].eql(source.err_type_id) and
                sameValueType(signature.return_ty, target.err_ty) and signature.return_type_id.eql(target.err_type_id);
        },
        .literal => |literal_id| literal_valid: {
            const literal = expressionById(body, literal_id) orelse break :literal_valid false;
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

fn mmioMapCheckedSupported(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    operation: @FieldType(mir.ExecutableExpression.Operation, "mmio_map_checked"),
) bool {
    const address = expressionById(body, operation.address) orelse return false;
    return operation.unsafe_authorized and
        sameValueType(address.result_ty, .{ .address = .paddr }) and
        sameValueType(expression.result_ty, .{ .address = .mmio_ptr }) and
        mmioMapTrapEdge(body, expression) != null;
}

fn callableValueExpressionSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    if (expression.result_ty != .value) return false;
    return switch (expression.operation) {
        .local => |local| localById(body, local) != null and
            (callableParameter(body, local) or callableLocalUsedAsIndirectCallee(body, local) or
                callableClosureLocalPassedToDirectCall(body, local)),
        .symbol => functionSymbolExpressionSupported(body, expression),
        .load => |load| (expressionUsedAsIndirectCallee(body, expression.id) or expressionReturned(body, expression.id) or
            callableProducerInitializesUsedLocal(body, expression.id)) and memoryLoadSupported(body, expression, load),
        .direct_call => |call| call.argument_count <= call.arguments.len and
            symbolById(body, call.callee) != null and allExpressionsExist(body, call.arguments[0..call.argument_count]) and
            callableProducerInitializesUsedLocal(body, expression.id),
        .closure_bind => |bind| closureBindSupported(body, expression, bind),
        else => false,
    };
}

/// A closure stored in an immutable local keeps the exact callable signature
/// of its canonical `closure_bind` initializer. Direct calls already carry a
/// checked argument contract; admitting this local avoids treating the
/// source-level binding name as a second callable-type authority.
fn callableClosureLocalPassedToDirectCall(body: *const mir.ExecutableBody, local: mir.LocalId) bool {
    const init = localInit(body, local) orelse return false;
    if (init.mutable or init.ty != .value) return false;
    const initializer_id = init.value orelse return false;
    const initializer = expressionById(body, initializer_id) orelse return false;
    const bind = switch (initializer.operation) {
        .closure_bind => |value| value,
        else => return false,
    };
    if (!closureBindSupported(body, initializer.*, bind)) return false;
    for (body.expressions) |candidate| switch (candidate.operation) {
        .direct_call => |call| for (call.arguments[0..call.argument_count]) |argument_id| {
            const argument = expressionById(body, argument_id) orelse continue;
            switch (argument.operation) {
                .local => |argument_local| if (argument_local.eql(local)) return true,
                else => {},
            }
        },
        else => {},
    };
    return false;
}

fn expressionUsedAsIndirectCallee(body: *const mir.ExecutableBody, id: mir.ExprId) bool {
    for (body.expressions) |candidate| switch (candidate.operation) {
        .indirect_call => |call| if (call.callee.eql(id)) return true,
        else => {},
    };
    return false;
}

fn expressionReturned(body: *const mir.ExecutableBody, id: mir.ExprId) bool {
    for (body.statements) |statement| switch (statement.operation) {
        .return_ => |value| if (value != null and value.?.eql(id)) return true,
        else => {},
    };
    return false;
}

fn expressionUsedAsClosureIndirectCallee(body: *const mir.ExecutableBody, id: mir.ExprId) bool {
    for (body.expressions) |candidate| switch (candidate.operation) {
        .indirect_call => |call| if (call.callee.eql(id)) return call.signature.has_environment,
        else => {},
    };
    return false;
}

fn callableLoadTargetSupported(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    load: @FieldType(mir.ExecutableExpression.Operation, "load"),
) bool {
    if (expression.result_ty != .value or
        (!expressionUsedAsIndirectCallee(body, expression.id) and !expressionReturned(body, expression.id) and
            !callableProducerInitializesUsedLocal(body, expression.id))) return false;
    const place = placeById(body, load.place) orelse return false;
    if (place.storage != .ordinary or !sameValueType(place.ty, .value)) return false;
    if (mir.executableCallablePlace(body.aggregate_types, place.*) != null) return true;
    if (place.projection_count != 0) return false;
    return switch (place.root) {
        .symbol => |id| if (symbolById(body, id)) |symbol| symbol.kind == .global else false,
        .local, .value => false,
    };
}

fn dynLoadTargetSupported(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    load: @FieldType(mir.ExecutableExpression.Operation, "load"),
) bool {
    if (expression.result_ty != .value) return false;
    const place = placeById(body, load.place) orelse return false;
    return mir.executableDynTraitPlace(body, place.*) != null;
}

fn sliceLoadTargetSupported(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    load: @FieldType(mir.ExecutableExpression.Operation, "load"),
) bool {
    if (!isSliceType(expression.result_ty)) return false;
    const place = placeById(body, load.place) orelse return false;
    return sameValueType(place.ty, expression.result_ty);
}

fn callableParameter(body: *const mir.ExecutableBody, local: mir.LocalId) bool {
    for (body.parameters) |parameter| if (parameter.local.eql(local))
        return parameter.ty == .value and parameter.callable_signature != null;
    return false;
}

fn dynTraitParameter(body: *const mir.ExecutableBody, local: mir.LocalId) bool {
    for (body.parameters) |parameter| if (parameter.local.eql(local))
        return parameter.ty == .value and parameter.dyn_trait_symbol_id.isValid();
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

fn closureBindSupported(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    bind: @FieldType(mir.ExecutableExpression.Operation, "closure_bind"),
) bool {
    if (expression.result_ty != .value or !bind.signature.has_environment or
        bind.signature.parameter_count > mir.max_executable_operands) return false;
    const target = symbolById(body, bind.target) orelse return false;
    const code = symbolById(body, bind.code) orelse return false;
    const capture = expressionById(body, bind.capture) orelse return false;
    if (target.kind != .function or code.kind != .function or
        !closureCaptureEncodingSupported(capture.result_ty, bind.capture_encoding) or
        (switch (bind.capture_encoding) {
            .pointer => !bind.code.eql(bind.target),
            .integer => bind.code.eql(bind.target),
        }) or
        !supportsType(body, bind.signature.return_ty)) return false;
    for (bind.signature.parameter_types[0..bind.signature.parameter_count]) |ty| if (!supportsType(body, ty)) return false;
    return true;
}

fn closureCaptureEncodingSupported(ty: mir.ValueType, encoding: mir.ExecutableClosureCaptureEncoding) bool {
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

fn callableExpressionMatches(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    expected: mir.ExecutableCallSignature,
) bool {
    const actual = switch (expression.operation) {
        .symbol => |id| (symbolById(body, id) orelse return false).callable_signature orelse return false,
        .local => |id| for (body.parameters) |parameter| {
            if (parameter.local.eql(id)) break parameter.callable_signature orelse return false;
        } else return false,
        .closure_bind => |bind| bind.signature,
        .load => |load| blk: {
            const place = placeById(body, load.place) orelse return false;
            break :blk mir.executableCallablePlace(body.aggregate_types, place.*) orelse return false;
        },
        else => return false,
    };
    return actual.eql(expected);
}

fn appendClosureCodePointerType(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    signature: mir.ExecutableCallSignature,
) (RenderError || std.mem.Allocator.Error)!void {
    try appendCType(allocator, out, body, signature.return_ty);
    try out.appendSlice(allocator, " (*)(void *");
    for (signature.parameter_types[0..signature.parameter_count]) |ty| {
        try out.appendSlice(allocator, ", ");
        try appendCType(allocator, out, body, ty);
    }
    try out.append(allocator, ')');
}

fn emitClosureBind(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    bind: @FieldType(mir.ExecutableExpression.Operation, "closure_bind"),
    depth: usize,
) (RenderError || std.mem.Allocator.Error)!void {
    if (closureTypeNameSupported(bind.signature)) {
        try out.appendSlice(allocator, "((");
        try appendClosureTypeName(allocator, out, bind.signature);
        try out.appendSlice(allocator, "){ .code = (");
    } else {
        try out.appendSlice(allocator, "((struct { ");
        try appendCType(allocator, out, body, bind.signature.return_ty);
        try out.appendSlice(allocator, " (*code)(void *");
        for (bind.signature.parameter_types[0..bind.signature.parameter_count]) |ty| {
            try out.appendSlice(allocator, ", ");
            try appendCType(allocator, out, body, ty);
        }
        try out.appendSlice(allocator, "); void *env; }){ .code = (");
    }
    try appendClosureCodePointerType(allocator, out, body, bind.signature);
    try out.append(allocator, ')');
    try appendSymbol(allocator, out, body, bind.code);
    try out.appendSlice(allocator, ", .env = (void *)");
    if (bind.capture_encoding == .integer) try out.appendSlice(allocator, "(uintptr_t)");
    try emitExpression(allocator, out, body, bind.capture, depth + 1);
    try out.appendSlice(allocator, " })");
}

fn closureTypeNameSupported(signature: mir.ExecutableCallSignature) bool {
    if (!cTypeSuffixSupported(signature.return_ty)) return false;
    for (signature.parameter_types[0..signature.parameter_count]) |ty|
        if (!cTypeSuffixSupported(ty)) return false;
    return true;
}

fn cTypeSuffixSupported(ty: mir.ValueType) bool {
    return switch (ty) {
        .bool, .integer, .float, .address, .struct_, .closed_enum, .open_enum => true,
        else => false,
    };
}

fn appendClosureTypeName(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    signature: mir.ExecutableCallSignature,
) (RenderError || std.mem.Allocator.Error)!void {
    try out.appendSlice(allocator, "mc_closure");
    var suffix: std.ArrayList(u8) = .empty;
    defer suffix.deinit(allocator);
    try appendCTypeSuffix(allocator, &suffix, signature.return_ty);
    try out.print(allocator, "_{d}_{s}", .{ suffix.items.len, suffix.items });
    for (signature.parameter_types[0..signature.parameter_count]) |ty| {
        suffix.clearRetainingCapacity();
        try appendCTypeSuffix(allocator, &suffix, ty);
        try out.print(allocator, "_{d}_{s}", .{ suffix.items.len, suffix.items });
    }
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

fn dynCallSupported(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    call: @FieldType(mir.ExecutableExpression.Operation, "dyn_call"),
) bool {
    const receiver = placeById(body, call.receiver) orelse return false;
    const trait = symbolById(body, call.trait_symbol) orelse return false;
    const receiver_trait = mir.executableDynTraitPlace(body, receiver.*) orelse return false;
    if (trait.kind != .trait or !receiver_trait.eql(call.trait_symbol) or
        !isSafeIdentifier(trait.spelling) or !isSafeIdentifier(call.method_spelling) or
        call.argument_count > call.arguments.len or call.signature.parameter_count != call.argument_count or
        call.signature.has_environment or !sameValueType(call.signature.return_ty, expression.result_ty) or
        !call.signature.return_type_id.eql(expression.type_id)) return false;
    for (call.arguments[0..call.argument_count], 0..) |argument_id, index| {
        const argument = expressionById(body, argument_id) orelse return false;
        if (!sameValueType(argument.result_ty, call.signature.parameter_types[index]) or
            !argument.type_id.eql(call.signature.parameter_type_ids[index])) return false;
    }
    const guarded = placeNeedsRepresentationGuard(receiver.*);
    if (guarded != (call.representation_source != null and call.representation_span_id.isValid())) return false;
    return if (guarded) representationOperationHasExactTrapEdge(body, expression) else ownedTrapEdgeCount(body, expression.id) == 0;
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
    const construction_supported = shape.construction == .declared_struct or shape.construction == .c_union or
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
    if (operation.kind == .fixed_array) {
        if (global_base) {
            if (!indexFeedsDirectAggregateLocalStore(body, expression)) return false;
        } else if (!localArrayIndexBase(body, operation.base) and
            !loadedLocalArrayIndexBase(body, operation.base) and
            !memberArrayIndexBase(body, operation.base) and
            !projectionRootIsLocalArray(body, operation.base) and
            !parameterArrayIndexBase(body, operation.base) and
            !projectionRootIsDirectCall(body, operation.base)) return false;
    }
    const base = expressionById(body, operation.base) orelse return false;
    const index = expressionById(body, operation.index) orelse return false;
    const dyn_array_element = if (operation.kind == .fixed_array)
        if (aggregateType(body, base.type_id)) |shape| shape.field_count != 0 and shape.field_dyn_trait_symbols[0].isValid() else false
    else
        false;
    if (!base.block_id.eql(expression.block_id) or !index.block_id.eql(expression.block_id) or
        !base.owner_statement.eql(expression.owner_statement) or !index.owner_statement.eql(expression.owner_statement) or
        !sameValueType(index.result_ty, .{ .integer = "usize" }) or
        !(supportsType(body, expression.result_ty) or (expression.result_ty == .value and dyn_array_element)))
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
            // Slice reads preserve the race-tolerant access contract. Scalars
            // use one helper load; declared structs are rebuilt from verified
            // scalar fields instead of performing a racy aggregate copy.
            if (scalarMemoryInfo(expression.result_ty) == null and raceAggregateLoadShape(body, expression) == null) return false;
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

fn raceAggregateLoadShape(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) ?*const mir.ExecutableAggregateType {
    const shape = aggregateType(body, expression.type_id) orelse return null;
    if (shape.construction != .declared_struct or shape.field_count == 0 or
        !sameValueType(shape.ty, expression.result_ty)) return null;
    for (shape.field_types[0..shape.field_count], shape.field_spellings[0..shape.field_count]) |field_ty, field_name| {
        if (scalarMemoryInfo(field_ty) == null or !isSafeIdentifier(field_name)) return null;
    }
    return shape;
}

fn parameterArrayIndexBase(body: *const mir.ExecutableBody, id: mir.ExprId) bool {
    const expression = expressionById(body, id) orelse return false;
    const local_id = switch (expression.operation) {
        .local => |local| local,
        else => return false,
    };
    if (expression.result_ty != .array) return false;
    for (body.parameters) |parameter| if (parameter.local.eql(local_id))
        return sameValueType(parameter.ty, expression.result_ty) and parameter.type_id.eql(expression.type_id);
    return false;
}

fn memberArrayIndexBase(body: *const mir.ExecutableBody, id: mir.ExprId) bool {
    const expression = expressionById(body, id) orelse return false;
    const array_ty = switch (expression.result_ty) {
        .array => |shape| shape,
        else => return false,
    };
    const member = switch (expression.operation) {
        .member => |value| value,
        else => return false,
    };
    const base = expressionById(body, member.base) orelse return false;
    const local_id = switch (base.operation) {
        .local => |local| local,
        else => return false,
    };
    if (localById(body, local_id) == null) return false;
    var exact_root = false;
    for (body.parameters) |parameter| if (parameter.local.eql(local_id)) {
        if (exact_root or !sameValueType(parameter.ty, base.result_ty) or !parameter.type_id.eql(base.type_id)) return false;
        exact_root = true;
    };
    for (body.statements) |statement| switch (statement.operation) {
        .local_init => |local| if (local.local.eql(local_id)) {
            if (exact_root or !sameValueType(local.ty, base.result_ty) or !local.type_id.eql(base.type_id)) return false;
            exact_root = true;
        },
        else => {},
    };
    if (!exact_root) return false;
    const owner = aggregateType(body, base.type_id) orelse return false;
    if ((owner.construction != .declared_struct and owner.construction != .c_union) or
        !sameValueType(owner.ty, base.result_ty) or
        member.field_index >= owner.field_count or
        !sameValueType(owner.field_types[member.field_index], expression.result_ty) or
        !owner.field_type_ids[member.field_index].eql(expression.type_id)) return false;
    const array = aggregateType(body, expression.type_id) orelse return false;
    return array.construction == .declared_struct and array.ty == .array and array.array_length != null and
        array.array_length.? != 0 and array.array_length == array_ty.length and array.field_count != 0 and
        sameValueType(array.ty, expression.result_ty);
}

fn rangeSliceSupported(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    operation: @FieldType(mir.ExecutableExpression.Operation, "range_slice"),
) bool {
    const base = expressionById(body, operation.base) orelse return false;
    const start = expressionById(body, operation.start) orelse return false;
    const end = expressionById(body, operation.end) orelse return false;
    if (!rangeSliceBaseStorageSupported(body, operation.base) or
        !base.block_id.eql(expression.block_id) or !start.block_id.eql(expression.block_id) or
        !end.block_id.eql(expression.block_id) or
        !base.owner_statement.eql(expression.owner_statement) or
        !start.owner_statement.eql(expression.owner_statement) or
        !end.owner_statement.eql(expression.owner_statement) or
        !sameValueType(start.result_ty, .{ .integer = "usize" }) or
        !sameValueType(end.result_ty, .{ .integer = "usize" }) or
        !supportsType(body, expression.result_ty)) return false;
    const result = switch (expression.result_ty) {
        .pointer => |shape| if (shape.kind == .slice) shape else return false,
        else => return false,
    };
    const bound: ?usize = switch (base.result_ty) {
        .array => |array| array_shape: {
            const length = array.length orelse return false;
            const aggregate = aggregateType(body, base.type_id) orelse return false;
            if (aggregate.array_length == null or aggregate.array_length.? != length or aggregate.field_count == 0 or
                !sameValueType(aggregate.ty, base.result_ty) or
                !std.mem.eql(u8, aggregate.field_types[0].name(), result.child)) return false;
            break :array_shape length;
        },
        .pointer => |shape| if (shape.kind == .slice and std.mem.eql(u8, shape.child, result.child)) null else return false,
        .slice => |child| if (std.mem.eql(u8, child, result.child)) null else return false,
        else => return false,
    };
    if (operation.checked) return rangeSliceTrapEdge(body, expression) != null;
    if (ownedTrapEdgeCount(body, expression.id) != 0 or bound == null) return false;
    const start_value = integerLiteralValue(start.*) orelse return false;
    const end_value = integerLiteralValue(end.*) orelse return false;
    return start_value <= end_value and end_value <= bound.?;
}

fn rangeSliceBaseStorageSupported(body: *const mir.ExecutableBody, id: mir.ExprId) bool {
    const expression = expressionById(body, id) orelse return false;
    return switch (expression.operation) {
        .local => |local| localById(body, local) != null,
        .symbol => globalAggregateIndexBase(body, id),
        .representation_check => |check| rangeSliceBaseStorageSupported(body, check.operand),
        else => false,
    };
}

fn integerLiteralValue(expression: mir.ExecutableExpression) ?u128 {
    return switch (expression.operation) {
        .literal => |literal| switch (literal) {
            .integer => |value| value,
            else => null,
        },
        else => null,
    };
}

fn emitRangeSlice(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    operation: @FieldType(mir.ExecutableExpression.Operation, "range_slice"),
    depth: usize,
) (RenderError || std.mem.Allocator.Error)!void {
    if (!rangeSliceSupported(body, expression, operation)) return error.InvalidExpression;
    const base = expressionById(body, operation.base) orelse return error.InvalidExpression;
    const id = expression.id.raw;
    try out.print(allocator, "({{ uintptr_t mc_range_start_{d} = ", .{id});
    try emitExpression(allocator, out, body, operation.start, depth + 1);
    try out.print(allocator, "; uintptr_t mc_range_end_{d} = ", .{id});
    try emitExpression(allocator, out, body, operation.end, depth + 1);
    try out.print(allocator, "; uintptr_t mc_range_len_{d} = ", .{id});
    switch (base.result_ty) {
        .array => |array| try out.print(allocator, "{d}", .{array.length.?}),
        .pointer, .slice => {
            try emitExpression(allocator, out, body, operation.base, depth + 1);
            try out.appendSlice(allocator, ".len");
        },
        else => return error.InvalidExpression,
    }
    if (operation.checked) try out.print(
        allocator,
        "; if (mc_range_start_{d} > mc_range_end_{d} || mc_range_end_{d} > mc_range_len_{d}) mc_trap_Bounds()",
        .{ id, id, id, id },
    );
    try out.appendSlice(allocator, "; (");
    try appendSliceCType(allocator, out, expression.result_ty);
    try out.print(allocator, "){{ .ptr = ", .{});
    try emitExpression(allocator, out, body, operation.base, depth + 1);
    try out.appendSlice(allocator, switch (base.result_ty) {
        .array => ".elems",
        .pointer, .slice => ".ptr",
        else => return error.InvalidExpression,
    });
    try out.print(
        allocator,
        " + mc_range_start_{d}, .len = mc_range_end_{d} - mc_range_start_{d} }}; }})",
        .{ id, id, id },
    );
}

fn appendSliceCType(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    ty: mir.ValueType,
) (RenderError || std.mem.Allocator.Error)!void {
    const shape = switch (ty) {
        .pointer => |shape| if (shape.kind == .slice) shape else return error.UnsupportedType,
        else => return error.UnsupportedType,
    };
    if (primitiveType(shape.child) == null) return error.UnsupportedType;
    try out.print(allocator, "mc_slice_{s}_{s}", .{ @tagName(shape.mutability), shape.child });
}

fn projectionRootIsLocalArray(body: *const mir.ExecutableBody, start: mir.ExprId) bool {
    var current = start;
    var depth: usize = 0;
    while (depth <= mir.max_executable_projections) : (depth += 1) {
        if (localArrayIndexBase(body, current) or parameterArrayIndexBase(body, current)) return true;
        const expression = expressionById(body, current) orelse return false;
        current = switch (expression.operation) {
            .index => |index| if (index.kind == .fixed_array) index.base else return false,
            else => return false,
        };
    }
    return false;
}

fn localArrayIndexBase(body: *const mir.ExecutableBody, id: mir.ExprId) bool {
    const expression = expressionById(body, id) orelse return false;
    const local_id = switch (expression.operation) {
        .local => |local| local,
        else => return false,
    };
    if (expression.result_ty != .array or localById(body, local_id) == null) return false;
    for (body.statements) |statement| switch (statement.operation) {
        .local_init => |local| if (local.local.eql(local_id))
            return sameValueType(local.ty, expression.result_ty),
        else => {},
    };
    return false;
}

fn loadedLocalArrayIndexBase(body: *const mir.ExecutableBody, id: mir.ExprId) bool {
    const expression = expressionById(body, id) orelse return false;
    if (expression.result_ty != .array) return false;
    const load = switch (expression.operation) {
        .load => |value| value,
        else => return false,
    };
    const place = placeById(body, load.place) orelse return false;
    if (place.projection_count != 0 or place.root != .local or
        !sameValueType(place.ty, expression.result_ty) or load.access.kind != .plain) return false;
    return localById(body, place.root.local) != null;
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
        .range_slice => |range| if (range.base.eql(expression.id)) return true,
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

fn structConstructionSupported(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    operation: @FieldType(mir.ExecutableExpression.Operation, "struct_"),
) bool {
    const shape = aggregateType(body, expression.type_id) orelse return false;
    if ((shape.construction != .declared_struct and shape.construction != .c_union and shape.construction != .packed_bits) or
        operation.construction != shape.construction or
        shape.field_count == 0 or
        (shape.construction == .c_union and operation.operand_count != 1) or
        (shape.construction != .c_union and shape.field_count != operation.operand_count) or
        !sameValueType(shape.ty, expression.result_ty)) return false;
    var seen = [_]bool{false} ** mir.max_executable_operands;
    for (operation.operands[0..operation.operand_count], operation.field_indices[0..operation.operand_count]) |operand_id, field_index| {
        if (field_index >= shape.field_count or seen[field_index]) return false;
        seen[field_index] = true;
        const operand = expressionById(body, operand_id) orelse return false;
        if (!sameValueType(operand.result_ty, shape.field_types[field_index]) or
            !operand.type_id.eql(shape.field_type_ids[field_index]) or
            !(supportsType(body, operand.result_ty) or functionSymbolExpressionSupported(body, operand.*) or
                if (shape.field_callable_signatures[field_index]) |signature|
                    callableExpressionMatches(body, operand.*, signature)
                else
                    expressionMatchesDynTrait(body, operand.*, shape.field_dyn_trait_symbols[field_index]))) return false;
    }
    if (shape.construction != .c_union)
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
        shape.array_length == null or shape.array_length.? != operation.operands.len or
        (shape.field_count != 1 and shape.field_count != operation.operands.len) or
        !sameValueType(shape.ty, expression.result_ty)) return false;
    if (!arrayElementTypeSupported(body, shape.field_types[0], shape.field_dyn_trait_symbols[0], 0)) return false;
    for (operation.operands, 0..) |operand_id, index| {
        const operand = expressionById(body, operand_id) orelse return false;
        const metadata_index: usize = if (shape.field_count == 1) 0 else index;
        if (!sameValueType(operand.result_ty, shape.field_types[metadata_index]) or
            !operand.type_id.eql(shape.field_type_ids[metadata_index]) or
            !(supportsType(body, operand.result_ty) or
                if (shape.field_callable_signatures[metadata_index]) |signature|
                    callableExpressionMatches(body, operand.*, signature)
                else
                    expressionMatchesDynTrait(body, operand.*, shape.field_dyn_trait_symbols[metadata_index]))) return false;
    }
    return true;
}

fn aggregateType(body: *const mir.ExecutableBody, type_id: mir.TypeId) ?*const mir.ExecutableAggregateType {
    if (!type_id.isValid()) return null;
    for (body.aggregate_types) |*aggregate| if (aggregate.type_id.eql(type_id)) return aggregate;
    return null;
}

fn taggedUnionType(body: *const mir.ExecutableBody, type_id: mir.TypeId) ?*const mir.ExecutableTaggedUnionType {
    if (!type_id.isValid()) return null;
    for (body.tagged_union_types) |*shape| if (shape.type_id.eql(type_id)) return shape;
    return null;
}

fn taggedUnionConstructionSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, operation: @FieldType(mir.ExecutableExpression.Operation, "tagged_union_construct")) bool {
    const shape = taggedUnionType(body, expression.type_id) orelse return false;
    if (!sameValueType(shape.ty, expression.result_ty) or operation.case_index >= shape.case_count) return false;
    const case = shape.cases[operation.case_index];
    if (!case.has_payload) return operation.payload == null;
    const payload = expressionById(body, operation.payload orelse return false) orelse return false;
    return sameValueType(payload.result_ty, case.payload_ty) and payload.type_id.eql(case.payload_type_id);
}

fn taggedUnionTagSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, operand_id: mir.ExprId) bool {
    const operand = expressionById(body, operand_id) orelse return false;
    const shape = taggedUnionType(body, operand.type_id) orelse return false;
    return sameValueType(operand.result_ty, shape.ty) and sameValueType(expression.result_ty, .{ .integer = "u32" }) and
        expression.type_id.eql(shape.tag_type_id);
}

fn taggedUnionPayloadSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, operation: @FieldType(mir.ExecutableExpression.Operation, "tagged_union_payload")) bool {
    const operand = expressionById(body, operation.operand) orelse return false;
    const shape = taggedUnionType(body, operand.type_id) orelse return false;
    if (!sameValueType(operand.result_ty, shape.ty) or operation.case_index >= shape.case_count) return false;
    const case = shape.cases[operation.case_index];
    return case.has_payload and sameValueType(expression.result_ty, case.payload_ty) and expression.type_id.eql(case.payload_type_id);
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
        .dma_cache_clean, .dma_cache_invalidate, .dma_addr, .dma_as_slice, .const_get, .phys, .reduce_sum_checked, .reduce_sum_left, .reduce_sum_fast, .wrapping_add, .wrap_residue, .serial_before, .serial_after, .serial_distance, .serial_compare, .counter_delta_mod, .counter_elapsed_bounded, .enum_raw, .conversion_from, .conversion_try_from, .conversion_trap_from, .conversion_wrap_from, .conversion_sat_from, .conversion_from_mod, .bitcast, .raw_many_offset, .raw_load, .raw_ptr, .raw_store, .byte_view_as_bytes, .byte_view_equal, .declassify, .assume_noalias, .forget_unchecked, .va_start, .va_arg, .va_end, .cpu_pause, .fence_full, .fence_release, .fence_acquire => {},
        else => return false,
    }
    if (call.argument_count > mir.max_executable_operands) return false;
    var operand_types: [mir.max_executable_operands]mir.ValueType = undefined;
    for (call.arguments[0..call.argument_count], 0..) |argument, index| {
        const operand = expressionById(body, argument) orelse return false;
        operand_types[index] = operand.result_ty;
    }
    if (!mir.executableBuiltinTypesValid(call.kind, expression.result_ty, operand_types[0..call.argument_count])) return false;
    switch (call.kind) {
        .dma_cache_clean, .dma_cache_invalidate, .dma_addr, .dma_as_slice => {
            const parameter = mir.executableDmaBufferParameter(body, call.dma_buffer) orelse return false;
            if (call.vararg_cursor.isValid()) return false;
            if ((call.kind == .dma_cache_clean or call.kind == .dma_cache_invalidate) and
                parameter.dma_mode.? != .noncoherent) return false;
            if (call.kind == .dma_as_slice) switch (expression.result_ty) {
                .pointer => |shape| if (!std.mem.eql(u8, shape.child, parameter.dma_payload_ty.name())) return false,
                .slice => |child| if (!std.mem.eql(u8, child, parameter.dma_payload_ty.name())) return false,
                else => return false,
            };
        },
        .va_start => return !call.dma_buffer.isValid() and !call.vararg_cursor.isValid() and
            mir.executableVaStartLocal(body, expression.id) != null and
            body.is_variadic and body.last_named_parameter.isValid() and
            ownedTrapEdgeCount(body, expression.id) == 0,
        .va_arg, .va_end => return !call.dma_buffer.isValid() and mir.executableVaListLocal(body, call.vararg_cursor) and
            call.representation_source == null and !call.representation_span_id.isValid() and
            ownedTrapEdgeCount(body, expression.id) == 0,
        else => if (call.vararg_cursor.isValid() or call.dma_buffer.isValid()) return false,
    }
    if (call.kind == .reduce_sum_checked and !reduceCheckedResultSupported(body, expression, call)) return false;
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

fn reduceCheckedResultSupported(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    call: @FieldType(mir.ExecutableExpression.Operation, "builtin_call"),
) bool {
    if (call.argument_count != 1) return false;
    const source = expressionById(body, call.arguments[0]) orelse return false;
    const element_name = switch (source.result_ty) {
        .pointer => |shape| if (shape.kind == .slice) shape.child else return false,
        .slice => |child| child,
        else => return false,
    };
    const shape = resultType(body, expression.type_id) orelse return false;
    return sameValueType(shape.ty, expression.result_ty) and
        sameValueType(shape.ok_ty, .{ .integer = element_name }) and
        sameValueType(shape.err_ty, .{ .integer = "u8" });
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
    expression: *const mir.ExecutableExpression,
    call: @FieldType(mir.ExecutableExpression.Operation, "builtin_call"),
    depth: usize,
) (RenderError || std.mem.Allocator.Error)!void {
    const result_ty = expression.result_ty;
    switch (call.kind) {
        .const_get => {
            const index = call.const_index orelse return error.InvalidExpression;
            try out.append(allocator, '(');
            try emitExpression(allocator, out, body, call.arguments[0], depth + 1);
            try out.print(allocator, ").elems[{d}]", .{index});
        },
        .phys => {
            try out.appendSlice(allocator, "((uintptr_t)(");
            try emitExpression(allocator, out, body, call.arguments[0], depth + 1);
            try out.appendSlice(allocator, "))");
        },
        .reduce_sum_checked => {
            const source = expressionById(body, call.arguments[0]) orelse return error.InvalidExpression;
            const element_name = switch (source.result_ty) {
                .pointer => |shape| if (shape.kind == .slice) shape.child else return error.UnsupportedType,
                .slice => |child| child,
                else => return error.UnsupportedType,
            };
            const element_ty: mir.ValueType = .{ .integer = element_name };
            const info = mir.ExecutableCastKind.integerInfo(element_ty) orelse return error.UnsupportedType;
            if (info.bits > 64) return error.UnsupportedType;
            const range = integerCRange(element_name) orelse return error.UnsupportedType;
            const shape = resultType(body, expression.type_id) orelse return error.UnsupportedType;
            const id = expression.id.raw;
            try out.print(allocator, "({{ __auto_type mc_reduce_xs_{d} = ", .{id});
            try emitExpression(allocator, out, body, call.arguments[0], depth + 1);
            try out.print(allocator, "; __int128 mc_acc_{d} = 0; for (uintptr_t mc_reduce_i_{d} = 0; mc_reduce_i_{d} < mc_reduce_xs_{d}.len; ++mc_reduce_i_{d}) mc_acc_{d} += (__int128)mc_reduce_xs_{d}.ptr[mc_reduce_i_{d}]; (mc_acc_{d} < (__int128)({s}) || mc_acc_{d} > (__int128)({s})) ? (", .{
                id,
                id,
                id,
                id,
                id,
                id,
                id,
                id,
                id,
                range.minimum,
                id,
                range.maximum,
            });
            try appendCType(allocator, out, body, expression.result_ty);
            try out.appendSlice(allocator, "){ .is_ok = false, .payload.err = (");
            try appendCType(allocator, out, body, shape.err_ty);
            try out.appendSlice(allocator, ")0 } : (");
            try appendCType(allocator, out, body, expression.result_ty);
            try out.appendSlice(allocator, "){ .is_ok = true, .payload.ok = (");
            try appendCType(allocator, out, body, shape.ok_ty);
            try out.print(allocator, ")mc_acc_{d} }}; }})", .{id});
        },
        .reduce_sum_left, .reduce_sum_fast => {
            const element_name = switch (expression.result_ty) {
                .float => |name| name,
                else => return error.UnsupportedType,
            };
            const element_c = primitiveType(element_name) orelse return error.UnsupportedType;
            const id = expression.id.raw;
            try out.print(allocator, "({{ __auto_type mc_reduce_xs_{d} = ", .{id});
            try emitExpression(allocator, out, body, call.arguments[0], depth + 1);
            try out.print(allocator, "; {s} mc_acc_{d} = ({s})0; ", .{ element_c, id, element_c });
            if (call.kind == .reduce_sum_fast) {
                try out.appendSlice(allocator, "/* MC_SUM_FAST: reassociation/vectorization opt-in */\n#if defined(__clang__)\n{\n#pragma clang fp reassociate(on)\n#pragma clang loop vectorize(enable) interleave(enable)\n");
                try out.print(allocator, "for (uintptr_t mc_reduce_i_{d} = 0; mc_reduce_i_{d} < mc_reduce_xs_{d}.len; ++mc_reduce_i_{d}) mc_acc_{d} = ({s})(mc_acc_{d} + mc_reduce_xs_{d}.ptr[mc_reduce_i_{d}]);\n", .{ id, id, id, id, id, element_c, id, id, id });
                try out.appendSlice(allocator, "}\n#else\n");
                try out.print(allocator, "for (uintptr_t mc_reduce_i_{d} = 0; mc_reduce_i_{d} < mc_reduce_xs_{d}.len; ++mc_reduce_i_{d}) mc_acc_{d} = ({s})(mc_acc_{d} + mc_reduce_xs_{d}.ptr[mc_reduce_i_{d}]);\n#endif\n", .{ id, id, id, id, id, element_c, id, id, id });
            } else {
                try out.print(allocator, "for (uintptr_t mc_reduce_i_{d} = 0; mc_reduce_i_{d} < mc_reduce_xs_{d}.len; ++mc_reduce_i_{d}) mc_acc_{d} = ({s})(mc_acc_{d} + mc_reduce_xs_{d}.ptr[mc_reduce_i_{d}]); ", .{ id, id, id, id, id, element_c, id, id, id });
            }
            try out.print(allocator, "mc_acc_{d}; }})", .{id});
        },
        .byte_view_as_bytes => {
            if (call.argument_count != 1) return error.InvalidExpression;
            try out.appendSlice(allocator, "((");
            try appendSliceCType(allocator, out, result_ty);
            try out.appendSlice(allocator, "){ .ptr = (uint8_t const *)(void *)(");
            try emitExpression(allocator, out, body, call.arguments[0], depth + 1);
            try out.appendSlice(allocator, "), .len = (uintptr_t)sizeof(*(");
            try emitExpression(allocator, out, body, call.arguments[0], depth + 1);
            try out.appendSlice(allocator, ")) })");
        },
        .byte_view_equal => {
            if (call.argument_count != 2) return error.InvalidExpression;
            const id = expression.id.raw;
            try out.print(allocator, "({{ __auto_type mc_bytes_left_{d} = ", .{id});
            try emitExpression(allocator, out, body, call.arguments[0], depth + 1);
            try out.print(allocator, "; __auto_type mc_bytes_right_{d} = ", .{id});
            try emitExpression(allocator, out, body, call.arguments[1], depth + 1);
            try out.print(
                allocator,
                "; (mc_bytes_left_{d}.len == mc_bytes_right_{d}.len) && " ++
                    "((mc_bytes_left_{d}.len == 0) || " ++
                    "(__builtin_memcmp(mc_bytes_left_{d}.ptr, mc_bytes_right_{d}.ptr, mc_bytes_left_{d}.len) == 0)); }})",
                .{ id, id, id, id, id, id },
            );
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
        .declassify, .assume_noalias, .wrap_residue, .enum_raw => {
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
        .dma_cache_clean, .dma_cache_invalidate => {
            try out.appendSlice(allocator, "((void)(");
            try appendLocal(allocator, out, body, call.dma_buffer);
            try out.appendSlice(allocator, if (call.kind == .dma_cache_clean)
                "), mc_barrier_release_before())"
            else
                "), mc_barrier_acquire_after())");
        },
        .dma_addr => {
            try out.appendSlice(allocator, "((uintptr_t)(");
            try appendLocal(allocator, out, body, call.dma_buffer);
            try out.appendSlice(allocator, "))");
        },
        .dma_as_slice => {
            const parameter = mir.executableDmaBufferParameter(body, call.dma_buffer) orelse return error.InvalidExpression;
            try out.appendSlice(allocator, "((");
            try out.appendSlice(allocator, "mc_slice_mut_");
            try appendCTypeSuffix(allocator, out, parameter.dma_payload_ty);
            try out.appendSlice(allocator, "){ .ptr = ");
            try appendLocal(allocator, out, body, call.dma_buffer);
            try out.appendSlice(allocator, ", .len = 1 })");
        },
        .va_start => return error.InvalidExpression,
        .va_arg => {
            try out.appendSlice(allocator, "__builtin_va_arg(");
            try appendLocal(allocator, out, body, call.vararg_cursor);
            try out.appendSlice(allocator, ", ");
            try appendCType(allocator, out, body, result_ty);
            try out.append(allocator, ')');
        },
        .va_end => {
            try out.appendSlice(allocator, "__builtin_va_end(");
            try appendLocal(allocator, out, body, call.vararg_cursor);
            try out.append(allocator, ')');
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
    const expected = mir.ExecutableCastKind.classify(operand.result_ty, expression.result_ty) orelse
        if (mir.executableFunctionPointerToIntegerCast(body, operand.*, expression.result_ty, cast.kind))
            mir.ExecutableCastKind.pointer_to_integer
        else
            return false;
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
    const aggregate_copy = mir.executableAggregateCopyAlignment(expression.result_ty) != null;
    const callable = callableLoadTargetSupported(body, expression, load);
    const dyn_value = dynLoadTargetSupported(body, expression, load);
    const slice_value = sliceLoadTargetSupported(body, expression, load);
    const place = placeById(body, load.place) orelse return false;
    const pointer_value = expression.result_ty == .pointer and sameValueType(place.ty, expression.result_ty) and
        place.type_id.eql(expression.type_id) and
        (mir.executableAggregatePointerFieldDerefPlace(body, place.*, false) != null or
            mir.executableParameterProjectedPlace(body, place.*, false));
    if (!aggregate_copy and scalarMemoryInfo(expression.result_ty) == null and enumTypeForValueType(body, expression.result_ty) == null and
        !callable and !dyn_value and !slice_value and !pointer_value) return false;
    if (load.access.alignment != mir.executableMemoryAlignment(body.enum_types, expression.result_ty)) return false;
    if (aggregate_copy and load.access.kind == .race_unordered and
        !mir.executableRaceAggregateTypeSupported(body, expression.type_id, expression.result_ty)) return false;
    if (place.storage != .ordinary) return false;
    if (place.projection_count != 0) {
        if (mir.executableFixedArrayIndexPlace(body, place.*)) |indexed| {
            const expected_kind: mir.ExecutableMemoryAccessKind = if (indexed.indirectPointee())
                .race_unordered
            else switch (place.root) {
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
                indexed.indirectPointee() == (load.representation_source != null and load.representation_span_id.isValid()) and
                if (mir.executableFixedArrayCheckedProjectionCount(place.*) != 0)
                    fixedArrayLoadBoundsTrapEdge(body, expression) != null and
                        ownedTrapEdgeCount(body, expression.id) == mir.executableFixedArrayCheckedProjectionCount(place.*) +
                            @as(usize, @intFromBool(indexed.indirectPointee()))
                else
                    ownedTrapEdgeCount(body, expression.id) == @as(usize, @intFromBool(indexed.indirectPointee()));
        }
        if (callable or dyn_value or slice_value) {
            const projected_through_pointer = switch (place.root_ty) {
                .pointer, .nullable_pointer => true,
                else => place.projections[0] == .deref,
            };
            if (projected_through_pointer)
                return load.access.kind == .race_unordered and representationOperationHasExactTrapEdge(body, expression);
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
            return load.access.kind == expected_kind and load.representation_source == null and
                !load.representation_span_id.isValid() and ownedTrapEdgeCount(body, expression.id) == 0;
        }
        if (mir.executableAggregateFieldPlace(
            body.locals,
            body.statements,
            body.aggregate_types,
            place.*,
            false,
        )) {
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
                ownedTrapEdgeCount(body, expression.id) == 0;
        }
        if (mir.executableAggregatePointerFieldDerefPlace(body, place.*, false) != null) {
            return load.access.kind == .race_unordered and representationOperationHasExactTrapEdge(body, expression);
        }
        if (!scalarAccessPlaceSupported(body, place.*) and
            !(aggregate_copy and mir.executableGuardedLocalAggregateDerefPlace(body, place.*, false))) return false;
        const expected_kind = mir.executablePointerDerefAccessKind(body, place.*) orelse return false;
        if (load.access.kind != expected_kind) return false;
        if (computedRawManyDerefPlaceSupported(body, place.*, false)) {
            return load.representation_source == null and !load.representation_span_id.isValid() and
                ownedTrapEdgeCount(body, expression.id) == 0;
        }
        if (!placeNeedsRepresentationGuard(place.*)) {
            return load.representation_source == null and !load.representation_span_id.isValid() and
                ownedTrapEdgeCount(body, expression.id) == 0;
        }
        return representationOperationHasExactTrapEdge(body, expression);
    }
    const symbol = switch (place.root) {
        .local => |id| return localById(body, id) != null and load.access.kind == .plain,
        .symbol => |id| symbolById(body, id) orelse return false,
        .value => return false,
    };
    if (symbol.kind != .global) return false;
    const expected_kind: mir.ExecutableMemoryAccessKind = if (mir.executableAggregateRequiresPlainAccess(
        body,
        place.type_id,
        place.ty,
    )) .plain else if (symbol.mutable) .race_unordered else .plain;
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

fn maybeUninitWriteSupported(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    operation: @FieldType(mir.ExecutableExpression.Operation, "maybe_uninit_write"),
) bool {
    const operand = expressionById(body, operation.value) orelse return false;
    return expression.result_ty == .void and
        mir.executableMaybeUninitLocal(body, operation.local, operand.result_ty, operand.type_id) and
        ownedTrapEdgeCount(body, expression.id) == 0;
}

fn maybeUninitAssumeInitSupported(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    operation: @FieldType(mir.ExecutableExpression.Operation, "maybe_uninit_assume_init"),
) bool {
    const write = expressionById(body, operation.initialized_by) orelse return false;
    const write_operation = switch (write.operation) {
        .maybe_uninit_write => |candidate| candidate,
        else => return false,
    };
    return write.block_id.eql(expression.block_id) and
        write.owner_statement.index() < expression.owner_statement.index() and
        write_operation.local.eql(operation.local) and
        mir.executableMaybeUninitLocal(body, operation.local, expression.result_ty, expression.type_id) and
        ownedTrapEdgeCount(body, expression.id) == 0;
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
        mmioStorageSupported(read.storage_ty) and mmioReadResultSupported(body, expression, read.storage_ty, read.storage_type_id) and
        ownedTrapEdgeCount(body, expression.id) == 0;
}

fn mmioReadResultSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, storage_ty: mir.ValueType, storage_type_id: mir.TypeId) bool {
    if (sameValueType(expression.result_ty, storage_ty) and expression.type_id.eql(storage_type_id)) return true;
    const aggregate = aggregateType(body, expression.type_id) orelse return false;
    return aggregate.construction == .packed_bits and sameValueType(aggregate.ty, expression.result_ty) and
        sameValueType(aggregate.storage_ty, storage_ty) and aggregate.storage_type_id.eql(storage_type_id);
}

fn mmioWriteSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, write: anytype) bool {
    const operand = expressionById(body, write.value) orelse return false;
    return write.ordering.validForWrite() and mmioBaseSupported(body, write.base) and
        mmioStorageSupported(write.storage_ty) and expression.result_ty == .void and
        sameValueType(operand.result_ty, write.storage_ty) and operand.type_id.eql(write.storage_type_id) and
        ownedTrapEdgeCount(body, expression.id) == 0;
}

fn mmioBaseSupported(body: *const mir.ExecutableBody, id: mir.LocalId) bool {
    return mir.executableMmioBase(body, id);
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
    if (place.projection_count == 0) return mir.executableDirectAtomicParameterPlace(body.parameters, place) or switch (place.root) {
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
    if (place.projection_count != 0) {
        var ordinary = place;
        ordinary.storage = .ordinary;
        if (scalarAccessPlaceSupported(body, ordinary)) return true;
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
    if (place.root_nonnull_proven) return false;
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
    if (mir.executableFixedArrayIndexPlace(body, place.*)) |indexed| {
        if (!fixedArrayAddressablePlaceSupported(body, place.*)) return false;
        if (indexed.indirectPointee() != (address.representation_source != null and address.representation_span_id.isValid()))
            return false;
        return fixedArrayLoadBoundsTrapEdge(body, expression) != null;
    }
    if (mir.executableSliceIndexPlace(body, place.*) != null) {
        return address.representation_source == null and !address.representation_span_id.isValid() and
            fixedArrayLoadBoundsTrapEdge(body, expression) != null;
    }
    if (mir.executableAggregateFieldPlace(
        body.locals,
        body.statements,
        body.aggregate_types,
        place.*,
        false,
    )) return address.representation_source == null and
        !address.representation_span_id.isValid() and ownedTrapEdgeCount(body, expression.id) == 0;
    if (mir.executableParameterProjectedPlace(body, place.*, false)) {
        return address.representation_source != null and address.representation_span_id.isValid() and
            representationOperationHasExactTrapEdge(body, expression);
    }
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

fn fixedArrayAddressablePlaceSupported(body: *const mir.ExecutableBody, place: mir.ExecutablePlace) bool {
    const indexed = mir.executableFixedArrayIndexPlace(body, place) orelse return false;
    if (indexed.indirectPointee()) return true;
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
        .value => mir.executableFixedArrayCallResultRoot(body, place),
    };
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
            for (body.parameters) |parameter| if (parameter.local.eql(id)) break :local true;
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
    return mir.executableAggregateFieldPlace(
        body.locals,
        body.statements,
        body.aggregate_types,
        place,
        false,
    ) or mir.executableAggregatePointerFieldDerefPlace(body, place, false) != null or
        parameterScalarAccessPlaceSupported(body, place) or
        mir.executableParameterProjectedPlace(body, place, false) or
        mir.executableLocalAddressDerefPlace(body, place, false) or
        mir.executableGuardedLocalScalarDerefPlace(body, place, false) or
        mir.executableGlobalPointerDerefPlace(body, place, false) or
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
    const aggregate_copy = mir.executableAggregateCopyAlignment(store.ty) != null;
    const dyn_store = dynStoreTargetSupported(body, place.*, value.*);
    const alignment = mir.executableMemoryAlignment(body.enum_types, store.ty) orelse return false;
    if (store.access.alignment != alignment) return false;
    if (aggregate_copy and store.access.kind == .race_unordered and
        !mir.executableRaceAggregateTypeSupported(body, place.type_id, place.ty)) return false;
    if (place.projection_count != 0) {
        if (!aggregate_copy and !isSliceType(store.ty) and scalarMemoryInfo(store.ty) == null and enumTypeForValueType(body, store.ty) == null and
            mir.executableCallablePlace(body.aggregate_types, place.*) == null and !dyn_store) return false;
        if (mir.executableFixedArrayIndexPlace(body, place.*)) |indexed| {
            const access_ok = if (indexed.indirectPointee())
                store.access.kind == .race_unordered and mir.executableFixedArrayIndirectPointeePlace(body, place.*, true)
            else switch (place.root) {
                .local => store.access.kind == .plain,
                .symbol => |id| if (symbolById(body, id)) |symbol|
                    symbol.kind == .global and symbol.mutable and store.access.kind == .race_unordered
                else
                    false,
                .value => false,
            };
            return access_ok and
                indexed.indirectPointee() == (store.representation_source != null and store.representation_span_id.isValid()) and
                if (mir.executableFixedArrayCheckedProjectionCount(place.*) != 0)
                    statementBoundsTrapEdge(body, statement) != null and
                        ownedStatementTrapEdgeCount(body, statement.id) == mir.executableFixedArrayCheckedProjectionCount(place.*) +
                            @as(usize, @intFromBool(indexed.indirectPointee()))
                else
                    ownedStatementTrapEdgeCount(body, statement.id) == @as(usize, @intFromBool(indexed.indirectPointee()));
        }
        if (mir.executableSliceIndexPlace(body, place.*) != null) {
            const mutable_slice = switch (place.root_ty) {
                .pointer => |shape| shape.kind == .slice and shape.mutability == .mut,
                else => false,
            };
            return mutable_slice and mir.executableCheckedSliceValueRoot(body, place.*) and
                store.access.kind == .race_unordered and
                store.representation_source == null and !store.representation_span_id.isValid() and
                statementBoundsTrapEdge(body, statement) != null and
                ownedStatementTrapEdgeCount(body, statement.id) == 1;
        }
        if (mir.executableAggregateFieldPlace(
            body.locals,
            body.statements,
            body.aggregate_types,
            place.*,
            true,
        )) {
            const expected_kind: mir.ExecutableMemoryAccessKind = switch (place.root) {
                .local => .plain,
                .symbol => |id| if (symbolById(body, id)) |symbol|
                    if (symbol.kind == .global and symbol.mutable) .race_unordered else return false
                else
                    return false,
                .value => return false,
            };
            return store.access.kind == expected_kind and
                store.representation_source == null and !store.representation_span_id.isValid() and
                ownedStatementTrapEdgeCount(body, statement.id) == 0;
        }
        const shape = switch (place.root_ty) {
            .pointer => |pointer| pointer,
            else => return false,
        };
        const local_alias = mir.executableLocalAddressDerefTarget(body, place.*, false) != null;
        const expected_kind = mir.executablePointerDerefAccessKind(body, place.*) orelse return false;
        if (shape.mutability != .mut or store.access.kind != expected_kind) return false;
        if (computedRawManyDerefPlaceSupported(body, place.*, true)) {
            return store.representation_source == null and !store.representation_span_id.isValid() and
                ownedStatementTrapEdgeCount(body, statement.id) == 0;
        }
        return (parameterScalarAccessPlaceSupported(body, place.*) or
            (scalarMemoryInfo(store.ty) != null and
                mir.executableParameterProjectedPlace(body, place.*, true)) or
            (isSliceType(store.ty) and mir.executableParameterProjectedPlace(body, place.*, true)) or
            (dyn_store and mir.executableParameterProjectedPlace(body, place.*, true)) or local_alias or
            (scalarMemoryInfo(store.ty) != null and mir.executableParameterProjectedPlace(body, place.*, true)) or
            mir.executableGuardedLocalScalarDerefPlace(body, place.*, true) or
            (aggregate_copy and mir.executableGuardedLocalAggregateDerefPlace(body, place.*, true)) or
            (aggregate_copy and mir.executableParameterProjectedPlace(body, place.*, true)) or
            mir.executableGlobalPointerDerefPlace(body, place.*, true)) and
            statementRepresentationOperationHasExactTrapEdge(body, statement, store);
    }
    return switch (place.root) {
        .local => |local| localById(body, local) != null and store.access.kind == .plain,
        .symbol => |id| if (symbolById(body, id)) |symbol| global: {
            const expected_kind: mir.ExecutableMemoryAccessKind = if (mir.executableAggregateRequiresPlainAccess(
                body,
                place.type_id,
                place.ty,
            )) .plain else .race_unordered;
            break :global symbol.kind == .global and symbol.mutable and
                store.access.kind == expected_kind and
                (aggregate_copy or scalarMemoryInfo(store.ty) != null or enumTypeForValueType(body, store.ty) != null or
                    (store.ty == .value and mir.executableCallablePlace(body.aggregate_types, place.*) != null));
        } else false,
        .value => false,
    };
}

fn dynStoreTargetSupported(
    body: *const mir.ExecutableBody,
    place: mir.ExecutablePlace,
    value: mir.ExecutableExpression,
) bool {
    const target_trait = mir.executableDynTraitPlace(body, place) orelse return false;
    if (value.result_ty != .value) return false;
    const local_id = switch (value.operation) {
        .local => |id| id,
        else => return false,
    };
    for (body.parameters) |parameter| if (parameter.local.eql(local_id))
        return parameter.dyn_trait_symbol_id.isValid() and parameter.dyn_trait_symbol_id.eql(target_trait);
    return false;
}

fn binarySupported(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    binary: @FieldType(mir.ExecutableExpression.Operation, "binary"),
) bool {
    const left = expressionById(body, binary.left) orelse return false;
    const right = expressionById(body, binary.right) orelse return false;
    if (binary.arithmetic != .unchecked and binary.contract_region_id != null) return false;
    if (binary.op == .logical_and or binary.op == .logical_or) {
        return binary.arithmetic == .ordinary and expression.result_ty == .bool and
            left.result_ty == .bool and right.result_ty == .bool and
            (!binary.eager_safe or
                (mir.executableEagerSafeBoolTree(body.expressions, body.trap_edges, left.id) and
                    mir.executableEagerSafeBoolTree(body.expressions, body.trap_edges, right.id))) and
            ownedTrapEdgeCount(body, expression.id) == 0;
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
        .unchecked => binary.contract_region_id != null and
            sameValueType(expression.result_ty, left.result_ty) and
            mir.ExecutableCastKind.integerInfo(expression.result_ty) != null and
            ownedTrapEdgeCount(body, expression.id) == 0 and switch (binary.op) {
            .add, .sub, .mul => true,
            else => false,
        },
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
            if (mir.executableFixedArrayIndexPlace(body, place.*) != null or
                mir.executableSliceIndexPlace(body, place.*) != null)
                fixedArrayLoadBoundsTrapEdge(body, expression) != null
            else
                representationOperationHasExactTrapEdge(body, expression)
        else
            false,
        .address_of => |address| if (placeById(body, address.place)) |place|
            if (mir.executableFixedArrayIndexPlace(body, place.*) != null or
                mir.executableSliceIndexPlace(body, place.*) != null)
                fixedArrayLoadBoundsTrapEdge(body, expression) != null
            else
                representationOperationHasExactTrapEdge(body, expression)
        else
            false,
        .dyn_call => representationOperationHasExactTrapEdge(body, expression),
        .atomic_load, .atomic_update, .representation_check => representationOperationHasExactTrapEdge(body, expression),
        .builtin_call => |call| if (call.kind == .conversion_trap_from)
            builtinTrapConversionHasExactEdge(body, expression)
        else
            representationOperationHasExactTrapEdge(body, expression),
        .try_unwrap => tryUnwrapTrapEdge(body, expression) != null,
        .mmio_map_checked => mmioMapTrapEdge(body, expression) != null,
        .index => |operation| operation.checked and indexTrapEdge(body, expression) != null,
        .range_slice => |operation| operation.checked and rangeSliceTrapEdge(body, expression) != null,
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

fn rangeSliceTrapEdge(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) ?mir.ExecutableTrapEdge {
    if (expression.operation != .range_slice or !expression.operation.range_slice.checked or
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
    const place_id = switch (expression.operation) {
        .load => |value| value.place,
        .address_of => |value| value.place,
        else => return null,
    };
    const place = placeById(body, place_id) orelse return null;
    const indexed = mir.executableFixedArrayIndexPlace(body, place.*);
    if (indexed == null and
        mir.executableSliceIndexPlace(body, place.*) == null) return null;
    const expected = mir.executableCheckedIndexProjectionCount(place.*);
    const representation_count: usize = @intFromBool(indexed != null and indexed.?.indirectPointee());
    if (expected == 0 or ownedTrapEdgeCount(body, expression.id) != expected + representation_count) return null;
    if (representation_count == 1) {
        const has_metadata = switch (expression.operation) {
            .address_of => |value| value.representation_source != null and value.representation_span_id.isValid(),
            .load => |value| value.representation_source != null and value.representation_span_id.isValid(),
            else => return null,
        };
        if (!has_metadata) return null;
    }
    var found: ?mir.ExecutableTrapEdge = null;
    for (place.projections[0..place.projection_count]) |projection| switch (projection) {
        .index => |index| if (index.checked) {
            var matching_span: usize = 0;
            for (body.trap_edges) |edge| if (edgeOwnedByExpression(edge, expression.id) and edge.span_id.eql(index.span_id)) {
                matching_span += 1;
            };
            if (matching_span != 1) return null;
        },
        .field, .deref => {},
    };
    for (body.trap_edges) |edge| {
        if (!edgeOwnedByExpression(edge, expression.id)) continue;
        if (!edge.from_block.eql(expression.block_id)) return null;
        const trap = terminatorByBlock(body, edge.trap_block) orelse return null;
        if (edge.kind == .Bounds and edge.source == .bounds_check) {
            switch (trap.operation) {
                .trap_ => |kind| if (kind != .Bounds) return null,
                else => return null,
            }
            if (found == null) found = edge;
        } else if (representation_count == 1 and edge.kind == .InvalidRepresentation and
            edge.source == .representation_check)
        {
            switch (trap.operation) {
                .trap_ => |kind| if (kind != .InvalidRepresentation) return null,
                else => return null,
            }
        } else {
            return null;
        }
    }
    return found;
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

fn mmioMapTrapEdge(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) ?mir.ExecutableTrapEdge {
    if (expression.operation != .mmio_map_checked or ownedTrapEdgeCount(body, expression.id) != 1) return null;
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
                mir.executableParameterProjectedPlace(body, place.*, false) or
                mir.executableLocalAddressDerefPlace(body, place.*, false) or
                mir.executableGuardedLocalScalarDerefPlace(body, place.*, false) or
                mir.executableGuardedLocalAggregateDerefPlace(body, place.*, false) or
                mir.executableGlobalPointerDerefPlace(body, place.*, false) or
                mir.executableAggregatePointerFieldDerefPlace(body, place.*, false) != null)) return false;
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
                mir.executableLocalAddressDerefPlace(body, place.*, false) or
                mir.executableParameterProjectedPlace(body, place.*, false))) return false;
            break :blk .{ .source = address.representation_source, .span_id = address.representation_span_id };
        },
        .builtin_call => |call| blk: {
            if (call.kind != .raw_ptr) return false;
            break :blk .{ .source = call.representation_source, .span_id = call.representation_span_id };
        },
        .dyn_call => |call| blk: {
            const receiver = placeById(body, call.receiver) orelse return false;
            if (mir.executableDynTraitPlace(body, receiver.*) == null or !placeNeedsRepresentationGuard(receiver.*)) return false;
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
        mir.executableFixedArrayIndirectPointeePlace(body, place.*, true) or
        mir.executableParameterProjectedPlace(body, place.*, true) or
        mir.executableLocalAddressDerefPlace(body, place.*, false) or
        mir.executableGuardedLocalScalarDerefPlace(body, place.*, true) or
        mir.executableGuardedLocalAggregateDerefPlace(body, place.*, true) or
        mir.executableGlobalPointerDerefPlace(body, place.*, true)) or
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
    const store = switch (statement.operation) {
        .store => |value| value,
        else => return null,
    };
    const place = placeById(body, store.place) orelse return null;
    if (mir.executableFixedArrayIndexPlace(body, place.*) == null and
        mir.executableSliceIndexPlace(body, place.*) == null) return null;
    const expected = mir.executableCheckedIndexProjectionCount(place.*);
    const indexed = mir.executableFixedArrayIndexPlace(body, place.*);
    const representation_count: usize = @intFromBool(indexed != null and indexed.?.indirectPointee());
    if (expected == 0 or ownedStatementTrapEdgeCount(body, statement.id) != expected + representation_count) return null;
    if (representation_count == 1 and
        (store.representation_source == null or !store.representation_span_id.isValid())) return null;
    for (place.projections[0..place.projection_count]) |projection| switch (projection) {
        .index => |index| if (index.checked) {
            var matching_span: usize = 0;
            for (body.trap_edges) |edge| if (edgeOwnedByStatement(edge, statement.id) and edge.span_id.eql(index.span_id)) {
                matching_span += 1;
            };
            if (matching_span != 1) return null;
        },
        .field, .deref => {},
    };
    var found: ?mir.ExecutableTrapEdge = null;
    for (body.trap_edges) |edge| {
        if (!edgeOwnedByStatement(edge, statement.id)) continue;
        if (!edge.from_block.eql(statement.block_id)) return null;
        const trap = terminatorByBlock(body, edge.trap_block) orelse return null;
        if (edge.kind == .Bounds and edge.source == .bounds_check) {
            switch (trap.operation) {
                .trap_ => |kind| if (kind != .Bounds) return null,
                else => return null,
            }
            if (found == null) found = edge;
        } else if (representation_count == 1 and edge.kind == .InvalidRepresentation and
            edge.source == .representation_check)
        {
            switch (trap.operation) {
                .trap_ => |kind| if (kind != .InvalidRepresentation) return null,
                else => return null,
            }
        } else return null;
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

fn localInitializerTypeCompatible(target: mir.ValueType, source: mir.ValueType) bool {
    return sameValueType(target, source) or
        mir.ExecutableCastKind.classify(source, target) == .pointer_const_narrow;
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
        .closed_enum, .open_enum, .struct_, .tagged_union => |name| isSafeIdentifier(name),
        .array => if (aggregateTypeForValueType(body, ty)) |shape|
            shape.array_length != null and shape.array_length.? != 0 and
                shape.field_count != 0 and arrayElementTypeSupported(body, shape.field_types[0], shape.field_dyn_trait_symbols[0], 0)
        else
            false,
        .nullable_value => aggregateTypeForValueType(body, ty) != null,
        .result => resultTypeForValueType(body, ty) != null,
        else => false,
    };
}

fn supportsParameterType(body: *const mir.ExecutableBody, ty: mir.ValueType) bool {
    if (supportsType(body, ty)) return true;
    // The semantic type system deliberately erases the spelling of a
    // value-optional pointee to `?`. Function signatures still carry their
    // normalized C type, while executable MIR carries the concrete aggregate
    // type on the guarded dereference place. Such a parameter never needs its
    // erased child spelling reconstructed by the body renderer.
    return switch (ty) {
        .pointer => |shape| shape.kind == .single and std.mem.eql(u8, shape.child, "?"),
        else => false,
    };
}

fn supportsParameter(body: *const mir.ExecutableBody, parameter: mir.ExecutableParameter) bool {
    if (supportsParameterType(body, parameter.ty)) return true;
    if (parameter.ty != .value) return false;
    if (callableParameter(body, parameter.local) or dynTraitParameter(body, parameter.local)) return true;
    if (parameter.atomic_payload_type_id.isValid()) return supportsType(body, parameter.atomic_payload_ty);
    return parameter.dma_mode != null and parameter.dma_payload_type_id.isValid() and
        supportsType(body, parameter.dma_payload_ty);
}

fn isSliceType(ty: mir.ValueType) bool {
    return switch (ty) {
        .pointer => |shape| shape.kind == .slice,
        .slice => true,
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
    return prepareExpressionSet(allocator, out, body, statement, null, indent, source_path);
}

fn prepareExpressionSet(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    statement: mir.ExecutableStatement,
    root: ?mir.ExprId,
    indent: usize,
    source_path: ?[]const u8,
) (RenderError || std.mem.Allocator.Error)!void {
    // ExprIds are emitted by the producer in source evaluation order and the
    // verified body requires operands to precede their consumer under one
    // owner statement.  Materialize every value, including reads, so a later
    // call or store cannot change what an earlier operand observes.
    for (body.expressions) |expression| {
        if (!expression.owner_statement.eql(statement.id)) continue;
        if (root) |selected| if (!expressionDependsOn(body, selected, expression.id, 0)) continue;
        if (expressionDeferredByLazyLogical(body, statement.id, root, expression.id)) continue;
        if (lazyLogical(expression)) |logical| {
            try writeSourceLineDirective(allocator, out, source_path, expression.source);
            try writeIndent(allocator, out, indent);
            try out.print(allocator, "mc_exec_tmp_{d} = ", .{expression.id.raw});
            try emitExpression(allocator, out, body, logical.left, 0);
            try out.appendSlice(allocator, ";\n");
            try writeIndent(allocator, out, indent);
            try out.appendSlice(allocator, if (logical.op == .logical_and) "if (" else "if (!(");
            try out.print(allocator, "mc_exec_tmp_{d}", .{expression.id.raw});
            try out.appendSlice(allocator, if (logical.op == .logical_and) ") {\n" else ")) {\n");
            try prepareExpressionSet(allocator, out, body, statement, logical.right, indent + 1, source_path);
            try writeIndent(allocator, out, indent + 1);
            try out.print(allocator, "mc_exec_tmp_{d} = ", .{expression.id.raw});
            try emitExpression(allocator, out, body, logical.right, 0);
            try out.appendSlice(allocator, ";\n");
            try writeIndent(allocator, out, indent);
            try out.appendSlice(allocator, "}\n");
            continue;
        }
        // `uninit` is a storage policy, not a runtime value. The local
        // declaration intentionally has no initializer expression.
        if (mir.executableUninitLocalInitializer(body, expression)) continue;
        // `va.start` initializes the target cursor in place and has no C
        // value. The owning local-init statement emits the declaration and
        // `__builtin_va_start` together after verifier admission.
        if (mir.executableVaStartLocal(body, expression.id) != null) continue;
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
            const operand_expression = expressionById(body, operand) orelse return error.InvalidExpression;
            try writeSourceLineDirective(allocator, out, source_path, expression.source);
            try writeIndent(allocator, out, indent);
            try out.appendSlice(allocator, "if (");
            try emitExpression(allocator, out, body, operand, 0);
            try out.appendSlice(allocator, switch (operand_expression.result_ty) {
                .nullable_pointer => " == NULL",
                .nullable_value => ".present == false",
                .result => ".is_ok == false",
                else => return error.InvalidExpression,
            });
            try out.appendSlice(allocator, ") mc_trap_NullUnwrap();\n");
        }
        if (expression.operation == .try_propagate) {
            const operation = expression.operation.try_propagate;
            const operand = operation.operand;
            if (!tryPropagateSupported(body, expression, operand)) return error.InvalidExpression;
            try writeSourceLineDirective(allocator, out, source_path, expression.source);
            try writeIndent(allocator, out, indent);
            try out.appendSlice(allocator, "if (!");
            try emitExpression(allocator, out, body, operand, 0);
            try out.appendSlice(allocator, ".is_ok) {\n");
            try emitExecutableCleanupActions(allocator, out, body, operation.error_cleanup_actions, indent + 1, source_path);
            try writeIndent(allocator, out, indent + 1);
            try out.appendSlice(allocator, "return ");
            try emitExpression(allocator, out, body, operand, 0);
            try out.appendSlice(allocator, ";\n");
            try writeIndent(allocator, out, indent);
            try out.appendSlice(allocator, "}\n");
        }
        if (expression.operation == .try_map_error) {
            const operation = expression.operation.try_map_error;
            if (!tryMapErrorSupported(body, expression, operation)) return error.InvalidExpression;
            try writeSourceLineDirective(allocator, out, source_path, expression.source);
            try writeIndent(allocator, out, indent);
            try out.appendSlice(allocator, "if (!");
            try emitExpression(allocator, out, body, operation.operand, 0);
            try out.appendSlice(allocator, ".is_ok) {\n");
            const target = resultType(body, body.return_type_id) orelse return error.InvalidExpression;
            try writeIndent(allocator, out, indent + 1);
            try appendCType(allocator, out, body, target.ty);
            try out.print(allocator, " mc_exec_propagated_{d} = ((", .{expression.id.raw});
            try appendCType(allocator, out, body, target.ty);
            try out.appendSlice(allocator, "){ .is_ok = false, .payload.err = ");
            switch (operation.mapper) {
                .conversion => |conversion| {
                    try appendSymbol(allocator, out, body, conversion.callee);
                    try out.append(allocator, '(');
                    try emitExpression(allocator, out, body, operation.operand, 0);
                    try out.appendSlice(allocator, ".payload.err)");
                },
                .literal => |literal| try emitExpression(allocator, out, body, literal, 0),
            }
            try out.appendSlice(allocator, " });\n");
            try emitExecutableCleanupActions(allocator, out, body, operation.error_cleanup_actions, indent + 1, source_path);
            try writeIndent(allocator, out, indent + 1);
            try out.print(allocator, "return mc_exec_propagated_{d};\n", .{expression.id.raw});
            try writeIndent(allocator, out, indent);
            try out.appendSlice(allocator, "}\n");
        }
        switch (expression.operation) {
            .binary => |binary| if (binary.arithmetic == .unchecked) {
                try writeSourceLineDirective(allocator, out, source_path, expression.source);
                try writeIndent(allocator, out, indent);
                try out.print(allocator, "/* MC_MIR_RANGE no_overflow region={} op={s} */\n", .{
                    binary.contract_region_id orelse return error.InvalidExpression,
                    switch (binary.op) {
                        .add => "add",
                        .sub => "sub",
                        .mul => "mul",
                        else => return error.InvalidExpression,
                    },
                });
            },
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
        if (mmioMapTrapEdge(body, expression) != null) {
            try writeSourceLineDirective(allocator, out, source_path, expression.source);
            try writeIndent(allocator, out, indent);
            try out.print(allocator, "if (mc_exec_tmp_{d} == NULL) mc_trap_NullUnwrap();\n", .{expression.id.raw});
        }
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

fn lazyLogical(expression: mir.ExecutableExpression) ?@FieldType(mir.ExecutableExpression.Operation, "binary") {
    return switch (expression.operation) {
        .binary => |binary| if (!binary.eager_safe and
            (binary.op == .logical_and or binary.op == .logical_or)) binary else null,
        else => null,
    };
}

fn expressionDeferredByLazyLogical(
    body: *const mir.ExecutableBody,
    owner: mir.InstId,
    selected_root: ?mir.ExprId,
    candidate: mir.ExprId,
) bool {
    for (body.expressions) |expression| {
        if (!expression.owner_statement.eql(owner) or expression.id.eql(candidate)) continue;
        if (selected_root) |root| if (!expressionDependsOn(body, root, expression.id, 0)) continue;
        const logical = lazyLogical(expression) orelse continue;
        if (expressionDependsOn(body, logical.right, candidate, 0)) return true;
    }
    return false;
}

fn expressionDependsOn(body: *const mir.ExecutableBody, root: mir.ExprId, candidate: mir.ExprId, depth: usize) bool {
    if (!root.isValid() or root.index() >= body.expressions.len or depth > body.expressions.len) return false;
    if (root.eql(candidate)) return true;
    const expression = body.expressions[root.index()];
    return switch (expression.operation) {
        .local, .symbol, .literal, .mmio_read, .maybe_uninit_assume_init, .optional_none, .unsupported => false,
        .load => |load| placeDependsOn(body, load.place, candidate, depth + 1),
        .atomic_load => |load| placeDependsOn(body, load.place, candidate, depth + 1),
        .atomic_init => |operand| expressionDependsOn(body, operand, candidate, depth + 1),
        .maybe_uninit_write => |operation| expressionDependsOn(body, operation.value, candidate, depth + 1),
        .atomic_update => |update| expressionDependsOn(body, update.value, candidate, depth + 1) or
            placeDependsOn(body, update.place, candidate, depth + 1),
        .mmio_write => |write| expressionDependsOn(body, write.value, candidate, depth + 1),
        .mmio_map_checked => |map| expressionDependsOn(body, map.address, candidate, depth + 1),
        .unary => |unary| expressionDependsOn(body, unary.operand, candidate, depth + 1),
        .binary => |binary| expressionDependsOn(body, binary.left, candidate, depth + 1) or
            expressionDependsOn(body, binary.right, candidate, depth + 1),
        .cast => |cast| expressionDependsOn(body, cast.operand, candidate, depth + 1),
        .representation_check => |check| expressionDependsOn(body, check.operand, candidate, depth + 1),
        .direct_call => |call| expressionListDependsOn(body, call.arguments[0..call.argument_count], candidate, depth + 1),
        .closure_bind => |bind| expressionDependsOn(body, bind.capture, candidate, depth + 1),
        .builtin_call => |call| expressionListDependsOn(body, call.arguments[0..call.argument_count], candidate, depth + 1),
        .indirect_call => |call| expressionDependsOn(body, call.callee, candidate, depth + 1) or
            expressionListDependsOn(body, call.arguments[0..call.argument_count], candidate, depth + 1),
        .dyn_call => |call| placeDependsOn(body, call.receiver, candidate, depth + 1) or
            expressionListDependsOn(body, call.arguments[0..call.argument_count], candidate, depth + 1),
        .dyn_bind => |bind| expressionDependsOn(body, bind.source, candidate, depth + 1),
        .address_of => |address| placeDependsOn(body, address.place, candidate, depth + 1),
        .deref, .slice_length, .optional_some, .try_unwrap => |operand| expressionDependsOn(body, operand, candidate, depth + 1),
        .try_propagate => |operation| expressionDependsOn(body, operation.operand, candidate, depth + 1),
        .index => |index| expressionDependsOn(body, index.base, candidate, depth + 1) or
            expressionDependsOn(body, index.index, candidate, depth + 1),
        .range_slice => |range| expressionDependsOn(body, range.base, candidate, depth + 1) or
            expressionDependsOn(body, range.start, candidate, depth + 1) or
            expressionDependsOn(body, range.end, candidate, depth + 1),
        .member => |member| expressionDependsOn(body, member.base, candidate, depth + 1),
        .variant_test => |variant| expressionDependsOn(body, variant.operand, candidate, depth + 1),
        .variant_payload => |variant| expressionDependsOn(body, variant.operand, candidate, depth + 1),
        .tagged_union_construct => |operation| if (operation.payload) |payload|
            expressionDependsOn(body, payload, candidate, depth + 1)
        else
            false,
        .tagged_union_tag => |operand| expressionDependsOn(body, operand, candidate, depth + 1),
        .tagged_union_payload => |operation| expressionDependsOn(body, operation.operand, candidate, depth + 1),
        .try_map_error => |mapped| expressionDependsOn(body, mapped.operand, candidate, depth + 1) or switch (mapped.mapper) {
            .conversion => false,
            .literal => |literal| expressionDependsOn(body, literal, candidate, depth + 1),
        },
        .result => |result| expressionDependsOn(body, result.payload, candidate, depth + 1),
        .array => |array| expressionListDependsOn(body, array.operands, candidate, depth + 1),
        .struct_ => |aggregate| expressionListDependsOn(body, aggregate.operands[0..aggregate.operand_count], candidate, depth + 1),
    };
}

fn expressionListDependsOn(
    body: *const mir.ExecutableBody,
    operands: []const mir.ExprId,
    candidate: mir.ExprId,
    depth: usize,
) bool {
    for (operands) |operand| if (expressionDependsOn(body, operand, candidate, depth)) return true;
    return false;
}

fn placeDependsOn(body: *const mir.ExecutableBody, id: mir.PlaceId, candidate: mir.ExprId, depth: usize) bool {
    const place = placeById(body, id) orelse return false;
    switch (place.root) {
        .value => |value| if (expressionDependsOn(body, value, candidate, depth)) return true,
        else => {},
    }
    for (place.projections[0..place.projection_count]) |projection| switch (projection) {
        .index => |index| if (expressionDependsOn(body, index.value, candidate, depth)) return true,
        else => {},
    };
    return false;
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
        .dyn_call => |call| if (call.representation_source) |source| .{ .place = call.receiver, .source = source } else null,
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
    const place = placeById(body, guard.place) orelse return error.InvalidPlace;
    if (mir.executableAggregatePointerFieldDerefPlace(body, place.*, false)) |projection| {
        const aggregate = aggregateType(body, place.root_type_id) orelse return error.InvalidPlace;
        try out.append(allocator, '(');
        try emitPlaceRootValue(allocator, out, body, place.*);
        try out.appendSlice(allocator, ").");
        try appendIdent(allocator, out, aggregate.field_spellings[projection.field_index]);
    } else try emitPlaceRoot(allocator, out, body, guard.place);
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
    const source_place = placeById(body, id) orelse return error.InvalidPlace;
    var ordinary_place = source_place.*;
    if (ordinary_place.storage == .atomic) {
        ordinary_place.storage = .ordinary;
        if (!scalarAccessPlaceSupported(body, ordinary_place)) return error.UnsupportedOperation;
    } else if (ordinary_place.storage != .ordinary) return error.UnsupportedOperation;
    const place = &ordinary_place;
    if (mir.executableFixedArrayIndexPlace(body, place.*)) |indexed| {
        try out.append(allocator, '(');
        if (indexed.indirectPointee()) try out.appendSlice(allocator, "*(");
        try emitPlaceRootValue(allocator, out, body, place.*);
        if (indexed.indirectPointee()) try out.append(allocator, ')');
        try out.append(allocator, ')');
        var current_type_id = place.root_type_id;
        if (indexed.indirectPointee()) {
            const pointer = switch (place.root_ty) {
                .pointer => |shape| shape,
                else => return error.InvalidPlace,
            };
            const pointee = aggregateTypeForValueType(body, .{ .struct_ = pointer.child }) orelse return error.InvalidPlace;
            current_type_id = pointee.type_id;
        }
        for (place.projections[0..place.projection_count]) |projection| switch (projection) {
            .index => |index| {
                const array = aggregateType(body, current_type_id) orelse return error.InvalidPlace;
                if (array.field_count == 0) return error.InvalidPlace;
                try out.appendSlice(allocator, ".elems[");
                if (index.checked) try out.appendSlice(allocator, "mc_check_index_usize(");
                try emitExpression(allocator, out, body, index.value, 0);
                if (index.checked) try out.print(allocator, ", {d})", .{index.bound.?});
                try out.append(allocator, ']');
                current_type_id = array.field_type_ids[0];
            },
            .field => |field_index| {
                const aggregate = aggregateType(body, current_type_id) orelse return error.InvalidPlace;
                if (field_index >= aggregate.field_count) return error.InvalidPlace;
                try out.append(allocator, '.');
                try appendIdent(allocator, out, aggregate.field_spellings[field_index]);
                current_type_id = aggregate.field_type_ids[field_index];
            },
            .deref => if (!indexed.indirectPointee()) return error.InvalidPlace,
        };
        return;
    }
    if (mir.executableSliceIndexPlace(body, place.*)) |index| {
        try out.append(allocator, '(');
        try emitPlaceRootValue(allocator, out, body, place.*);
        try out.appendSlice(allocator, ").ptr[mc_check_index_usize(");
        try emitExpression(allocator, out, body, index.value, 0);
        try out.appendSlice(allocator, ", (");
        try emitPlaceRootValue(allocator, out, body, place.*);
        try out.appendSlice(allocator, ").len)]");
        return;
    }
    if (mir.executableAggregateFieldPlace(
        body.locals,
        body.statements,
        body.aggregate_types,
        place.*,
        false,
    )) {
        try out.append(allocator, '(');
        try emitPlaceRootValue(allocator, out, body, place.*);
        try out.append(allocator, ')');
        var current_type_id = place.root_type_id;
        for (place.projections[0..place.projection_count]) |projection| {
            const field_index = switch (projection) {
                .field => |index| index,
                .deref, .index => return error.InvalidPlace,
            };
            const aggregate = aggregateType(body, current_type_id) orelse return error.InvalidPlace;
            if (field_index >= aggregate.field_count) return error.InvalidPlace;
            try out.append(allocator, '.');
            try appendIdent(allocator, out, aggregate.field_spellings[field_index]);
            current_type_id = aggregate.field_type_ids[field_index];
        }
        return;
    }
    if (mir.executableAggregatePointerFieldDerefPlace(body, place.*, false)) |projection| {
        const aggregate = aggregateType(body, place.root_type_id) orelse return error.InvalidPlace;
        try out.appendSlice(allocator, "(*((");
        try emitPlaceRootValue(allocator, out, body, place.*);
        try out.appendSlice(allocator, ").");
        try appendIdent(allocator, out, aggregate.field_spellings[projection.field_index]);
        try out.appendSlice(allocator, "))");
        return;
    }
    if (place.projection_count == 1 and mir.executableLocalAddressDerefPlace(body, place.*, false)) {
        try out.appendSlice(allocator, "(*(");
        try emitPlaceRootValue(allocator, out, body, place.*);
        try out.appendSlice(allocator, "))");
        return;
    }
    if (mir.executableGlobalPointerDerefPlace(body, place.*, false)) {
        try out.appendSlice(allocator, "(*(__atomic_load_n(&");
        try emitPlaceRootValue(allocator, out, body, place.*);
        try out.appendSlice(allocator, ", __ATOMIC_RELAXED)))");
        return;
    }
    if (mir.executableGuardedLocalScalarDerefPlace(body, place.*, false) or
        mir.executableGuardedLocalAggregateDerefPlace(body, place.*, false))
    {
        try out.appendSlice(allocator, "(*(");
        try emitPlaceRootValue(allocator, out, body, place.*);
        try out.appendSlice(allocator, "))");
        return;
    }
    if (mir.executableParameterProjectedPlace(body, place.*, false)) {
        const pointer = switch (place.root_ty) {
            .pointer => |shape| shape,
            else => return error.InvalidPlace,
        };
        var current_aggregate: ?*const mir.ExecutableAggregateType = null;
        for (body.aggregate_types) |*candidate| if (mir.ValueType.eql(candidate.ty, .{ .struct_ = pointer.child })) {
            current_aggregate = candidate;
            break;
        };
        try emitPlaceRootValue(allocator, out, body, place.*);
        var projection_index: usize = 1;
        while (projection_index < place.projection_count) : (projection_index += 1) {
            const projection = place.projections[projection_index];
            const field_index = switch (projection) {
                .field => |index| index,
                .deref, .index => return error.InvalidPlace,
            };
            const aggregate = current_aggregate orelse return error.InvalidPlace;
            if (field_index >= aggregate.field_count) return error.InvalidPlace;
            try out.appendSlice(allocator, if (projection_index == 1) "->" else ".");
            try appendIdent(allocator, out, aggregate.field_spellings[field_index]);
            const field_type_id = aggregate.field_type_ids[field_index];
            current_aggregate = null;
            for (body.aggregate_types) |*candidate| if (candidate.type_id.eql(field_type_id)) {
                current_aggregate = candidate;
                break;
            };
        }
        return;
    }
    if (place.projection_count != 0) return error.UnsupportedOperation;
    try emitPlaceRootValue(allocator, out, body, place.*);
}

const OverlayUnionAccessPlace = struct {
    place: mir.ExecutablePlace,
    index: ?@FieldType(mir.ExecutablePlace.Projection, "index"),
};

/// Recognize only the exact local `overlay.field` and
/// `overlay.array_field[index]` forms whose byte-storage ABI is carried by
/// canonical aggregate metadata. Other projections remain fail-closed.
fn overlayUnionAccessPlace(body: *const mir.ExecutableBody, id: mir.PlaceId) ?OverlayUnionAccessPlace {
    const place = placeById(body, id) orelse return null;
    if (place.storage != .ordinary or place.root != .local or
        (place.projection_count != 1 and place.projection_count != 2)) return null;
    const shape = aggregateType(body, place.root_type_id) orelse return null;
    if (shape.construction != .c_union or !shape.is_overlay_union or
        shape.storage_size == 0 or shape.storage_alignment == 0) return null;
    const field_index = switch (place.projections[0]) {
        .field => |index| index,
        .deref, .index => return null,
    };
    if (field_index >= shape.field_count) return null;
    if (place.projection_count == 1) {
        if (!shape.field_type_ids[field_index].eql(place.type_id) or
            !sameValueType(shape.field_types[field_index], place.ty)) return null;
        return .{ .place = place.*, .index = null };
    }
    const index = switch (place.projections[1]) {
        .index => |value| value,
        .field, .deref => return null,
    };
    if (!index.checked or index.bound == null) return null;
    const array = aggregateType(body, shape.field_type_ids[field_index]) orelse return null;
    if (array.ty != .array or array.array_length == null or array.array_length.? != index.bound.? or
        array.field_count == 0 or !array.field_type_ids[0].eql(place.type_id) or
        !sameValueType(array.field_types[0], place.ty)) return null;
    return .{ .place = place.*, .index = index };
}

fn emitOverlayUnionLoad(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    overlay: OverlayUnionAccessPlace,
    depth: usize,
) (RenderError || std.mem.Allocator.Error)!void {
    try out.appendSlice(allocator, "({ ");
    try appendCType(allocator, out, body, expression.result_ty);
    try out.print(allocator, " mc_overlay_read_{d}; __builtin_memcpy(&mc_overlay_read_{d}, &(", .{
        expression.id.raw,
        expression.id.raw,
    });
    try emitPlaceRootValue(allocator, out, body, overlay.place);
    try out.appendSlice(allocator, ").storage[");
    if (overlay.index) |index| {
        try out.appendSlice(allocator, "mc_check_index_usize(");
        try emitExpression(allocator, out, body, index.value, depth + 1);
        try out.print(allocator, ", {d}) * sizeof(", .{index.bound.?});
    } else {
        try out.appendSlice(allocator, "0 * sizeof(");
    }
    try appendCType(allocator, out, body, expression.result_ty);
    try out.print(allocator, ")], sizeof(mc_overlay_read_{d})); mc_overlay_read_{d}; }})", .{
        expression.id.raw,
        expression.id.raw,
    });
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
    if (mir.executableSliceIndexPlace(body, place.*) != null) {
        try out.appendSlice(allocator, "&(");
        try emitPlace(allocator, out, body, id);
        try out.append(allocator, ')');
        return;
    }
    if (mir.executableAggregateFieldPlace(
        body.locals,
        body.statements,
        body.aggregate_types,
        place.*,
        false,
    )) {
        try out.appendSlice(allocator, "&(");
        try emitPlace(allocator, out, body, id);
        try out.append(allocator, ')');
        return;
    }
    if (mir.executableAggregatePointerFieldDerefPlace(body, place.*, false)) |projection| {
        const aggregate = aggregateType(body, place.root_type_id) orelse return error.InvalidPlace;
        try out.append(allocator, '(');
        try emitPlaceRootValue(allocator, out, body, place.*);
        try out.appendSlice(allocator, ").");
        try appendIdent(allocator, out, aggregate.field_spellings[projection.field_index]);
        return;
    }
    if (place.projection_count == 0) {
        try out.append(allocator, '&');
        try emitPlaceRootValue(allocator, out, body, place.*);
        return;
    }
    if (mir.executableParameterProjectedPlace(body, place.*, false)) {
        try out.appendSlice(allocator, "&(");
        try emitPlace(allocator, out, body, id);
        try out.append(allocator, ')');
        return;
    }
    if (!scalarAccessPlaceSupported(body, place.*)) return error.UnsupportedOperation;
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
    var ordinary = place.*;
    ordinary.storage = .ordinary;
    if (scalarAccessPlaceSupported(body, ordinary)) {
        try out.appendSlice(allocator, "&(");
        try emitPlace(allocator, out, body, id);
        try out.append(allocator, ')');
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
    body: *const mir.ExecutableBody,
    ty: mir.ValueType,
    literal: mir.ExecutableLiteral,
) (RenderError || std.mem.Allocator.Error)!void {
    switch (literal) {
        .integer => |magnitude| try emitUnsignedIntegerLiteral(allocator, out, magnitude),
        .signed_integer => |value| try out.print(allocator, "{d}", .{value}),
        .float => |value| switch (value) {
            .f32_bits => |bits| try out.print(allocator, "__builtin_bit_cast(float, ((uint32_t)0x{X:0>8}U))", .{bits}),
            .f64_bits => |bits| try out.print(allocator, "__builtin_bit_cast(double, ((uint64_t)0x{X:0>16}ULL))", .{bits}),
        },
        .string => |bytes| try emitStringLiteral(allocator, out, body, ty, bytes),
        .boolean => |value| try out.appendSlice(allocator, if (value) "true" else "false"),
        .null => try out.appendSlice(allocator, "NULL"),
        .void => try out.appendSlice(allocator, "((void)0)"),
        .uninit => {
            try out.appendSlice(allocator, "((");
            try appendCType(allocator, out, body, ty);
            try out.appendSlice(allocator, "){0})");
        },
        .enum_value => return error.UnsupportedOperation,
    }
}

fn stringLiteralTypeSupported(ty: mir.ValueType) bool {
    return switch (ty) {
        .cstr => true,
        .pointer => |shape| std.mem.eql(u8, shape.child, "u8"),
        .slice => |child| std.mem.eql(u8, child, "u8"),
        else => false,
    };
}

fn emitStringLiteral(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    ty: mir.ValueType,
    bytes: []const u8,
) (RenderError || std.mem.Allocator.Error)!void {
    switch (ty) {
        .pointer => |shape| if (shape.kind == .slice) {
            try out.appendSlice(allocator, "((");
            try appendSliceCType(allocator, out, ty);
            try out.appendSlice(allocator, "){ .ptr = (");
            try out.appendSlice(allocator, primitiveType(shape.child) orelse return error.UnsupportedType);
            try out.appendSlice(allocator, if (shape.mutability == .@"const") " const *)" else " *)");
            try emitCStringBytes(allocator, out, bytes);
            try out.print(allocator, ", .len = {d} }})", .{bytes.len});
            return;
        },
        else => {},
    }
    if (!stringLiteralTypeSupported(ty)) return error.UnsupportedType;
    try out.appendSlice(allocator, "((");
    try appendCType(allocator, out, body, ty);
    try out.appendSlice(allocator, ")");
    try emitCStringBytes(allocator, out, bytes);
    try out.append(allocator, ')');
}

fn emitCStringBytes(allocator: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8) std.mem.Allocator.Error!void {
    try out.append(allocator, '"');
    for (bytes) |byte| switch (byte) {
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '"' => try out.appendSlice(allocator, "\\\""),
        '\'' => try out.appendSlice(allocator, "\\'"),
        '?' => try out.appendSlice(allocator, "\\?"),
        0 => try out.appendSlice(allocator, "\\000"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        32...33, 35...38, 40...62, 64...91, 93...126 => try out.append(allocator, byte),
        else => {
            try out.append(allocator, '\\');
            try out.append(allocator, '0' + ((byte >> 6) & 0x07));
            try out.append(allocator, '0' + ((byte >> 3) & 0x07));
            try out.append(allocator, '0' + (byte & 0x07));
        },
    };
    try out.append(allocator, '"');
}

fn emitUnsignedIntegerLiteral(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    magnitude: u128,
) std.mem.Allocator.Error!void {
    if (magnitude <= std.math.maxInt(i64)) {
        try out.print(allocator, "{d}", .{magnitude});
        return;
    }
    if (magnitude <= std.math.maxInt(u64)) {
        try out.print(allocator, "{d}ULL", .{magnitude});
        return;
    }

    const high: u64 = @truncate(magnitude >> 64);
    const low: u64 = @truncate(magnitude);
    try out.print(
        allocator,
        "((((unsigned __int128){d}ULL) << 64) | ((unsigned __int128){d}ULL))",
        .{ high, low },
    );
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
            try out.appendSlice(allocator, if (shape.mutability == .@"const") " const *" else " *");
        },
        .address => |class| try out.appendSlice(allocator, if (class == .mmio_ptr) "void volatile *" else "uintptr_t"),
        .array => {
            const shape = aggregateTypeForValueType(body, ty) orelse return error.UnsupportedType;
            if (shape.construction != .declared_struct or shape.ty != .array or shape.field_count == 0 or shape.array_length == null) return error.UnsupportedType;
            try out.appendSlice(allocator, "mc_array_");
            try appendArrayElementTypeSuffix(allocator, out, body, shape.field_types[0], shape.field_dyn_trait_symbols[0], 0);
            try out.print(allocator, "_{d}", .{shape.array_length.?});
        },
        .closed_enum, .open_enum, .struct_, .tagged_union => |name| try appendIdent(allocator, out, name),
        .nullable_value => {
            const shape = aggregateTypeForValueType(body, ty) orelse return error.UnsupportedType;
            if (shape.construction != .declared_struct or shape.ty != .nullable_value or shape.field_count != 2) return error.UnsupportedType;
            try out.appendSlice(allocator, "mc_opt_");
            try appendCTypeSuffix(allocator, out, shape.field_types[1]);
        },
        .result => |identity| {
            const shape = resultTypeForValueType(body, ty) orelse return error.UnsupportedType;
            try out.appendSlice(allocator, "mc_result_");
            try appendResultCTypeSuffix(allocator, out, body, identity.ok, shape.ok_ty);
            try out.append(allocator, '_');
            try appendResultCTypeSuffix(allocator, out, body, identity.err, shape.err_ty);
        },
        else => return error.UnsupportedType,
    }
}

/// Render a verified MIR type for module-level declarations. This is the same
/// type renderer used by executable-body locals and temporaries.
pub fn renderType(allocator: std.mem.Allocator, body: *const mir.ExecutableBody, ty: mir.ValueType) (RenderError || std.mem.Allocator.Error)![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendCType(allocator, &out, body, ty);
    return out.toOwnedSlice(allocator);
}

fn appendResultCTypeSuffix(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: *const mir.ExecutableBody,
    identity: []const u8,
    storage_ty: mir.ValueType,
) (RenderError || std.mem.Allocator.Error)!void {
    switch (storage_ty) {
        .domain_integer => |domain| if (domain.kind == .duration)
            return out.print(allocator, "mc_type_generic_8_Duration_1_{d}_{s}", .{ domain.child.len, domain.child }),
        // Generic instantiation spellings such as `Pair__u32` are valid C
        // identifiers, but their declarations use the canonical nominal
        // struct encoding. Prefer the verified storage identity so expression
        // temporaries name the same typedef as the function signature.
        .struct_ => return appendCTypeSuffix(allocator, out, storage_ty),
        .closed_enum, .open_enum => if (enumTypeForValueType(body, storage_ty)) |enum_ty| {
            if (!enum_ty.explicit_repr)
                return out.print(allocator, "mc_type_name_{d}_{s}", .{ identity.len, identity });
        },
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
        .tagged_union => |name| try out.print(allocator, "mc_type_union_{d}_{s}", .{ name.len, name }),
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
    dyn_trait_symbol: mir.SymbolId,
    depth: usize,
) (RenderError || std.mem.Allocator.Error)!void {
    if (depth >= mir.max_executable_operands) return error.UnsupportedType;
    if (dyn_trait_symbol.isValid()) {
        if (ty != .value) return error.UnsupportedType;
        const trait = symbolById(body, dyn_trait_symbol) orelse return error.UnsupportedType;
        if (trait.kind != .trait or !isSafeIdentifier(trait.spelling)) return error.UnsupportedType;
        return out.print(allocator, "mc_type_dyn_n_{d}_{s}", .{ trait.spelling.len, trait.spelling });
    }
    // Array wrapper names are shared with the module-level declaration
    // collector.  Non-builtin nominal names use the framed source-type suffix
    // there, including enums; reproduce that syntax-free encoding from the
    // verified nominal identity so the canonical body names the typedef that
    // was actually emitted.
    switch (ty) {
        .closed_enum, .open_enum => |name| return out.print(allocator, "mc_type_name_{d}_{s}", .{ name.len, name }),
        else => {},
    }
    if (ty != .array) return appendCTypeSuffix(allocator, out, ty);
    const shape = aggregateTypeForValueType(body, ty) orelse return error.UnsupportedType;
    if (shape.array_length == null or shape.array_length.? == 0 or shape.field_count == 0) return error.UnsupportedType;
    var child: std.ArrayList(u8) = .empty;
    defer child.deinit(allocator);
    try appendArrayElementTypeSuffix(allocator, &child, body, shape.field_types[0], shape.field_dyn_trait_symbols[0], depth + 1);
    const length = try std.fmt.allocPrint(allocator, "{d}", .{shape.array_length.?});
    defer allocator.free(length);
    try out.print(allocator, "mc_type_array_{d}_{s}_{d}_{s}", .{ child.items.len, child.items, length.len, length });
}

fn arrayElementTypeSupported(body: *const mir.ExecutableBody, ty: mir.ValueType, dyn_trait_symbol: mir.SymbolId, depth: usize) bool {
    if (depth >= mir.max_executable_operands) return false;
    if (dyn_trait_symbol.isValid()) {
        const trait = symbolById(body, dyn_trait_symbol) orelse return false;
        return ty == .value and trait.kind == .trait and isSafeIdentifier(trait.spelling);
    }
    return switch (ty) {
        .bool, .address => true,
        .integer, .float => |name| primitiveType(name) != null,
        .struct_, .closed_enum, .open_enum => |name| isSafeIdentifier(name),
        .array => if (aggregateTypeForValueType(body, ty)) |shape|
            shape.array_length != null and shape.array_length.? != 0 and shape.field_count != 0 and
                arrayElementTypeSupported(body, shape.field_types[0], shape.field_dyn_trait_symbols[0], depth + 1)
        else
            false,
        else => false,
    };
}

fn appendLocal(allocator: std.mem.Allocator, out: *std.ArrayList(u8), body: *const mir.ExecutableBody, id: mir.LocalId) (RenderError || std.mem.Allocator.Error)!void {
    const local = localById(body, id) orelse return error.InvalidLocal;
    var first_same_spelling = id;
    for (body.locals) |candidate| {
        if (std.mem.eql(u8, candidate.spelling, local.spelling) and candidate.id.raw < first_same_spelling.raw)
            first_same_spelling = candidate.id;
    }
    if (std.mem.startsWith(u8, local.spelling, "__mc_") or !first_same_spelling.eql(id))
        return out.print(allocator, "{s}_{d}", .{ local.spelling, id.raw });
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

const IntegerCRange = struct {
    minimum: []const u8,
    maximum: []const u8,
};

fn integerCRange(name: []const u8) ?IntegerCRange {
    const Entry = struct { name: []const u8, minimum: []const u8, maximum: []const u8 };
    const entries = [_]Entry{
        .{ .name = "u8", .minimum = "0", .maximum = "UINT8_MAX" },
        .{ .name = "u16", .minimum = "0", .maximum = "UINT16_MAX" },
        .{ .name = "u32", .minimum = "0", .maximum = "UINT32_MAX" },
        .{ .name = "u64", .minimum = "0", .maximum = "UINT64_MAX" },
        .{ .name = "usize", .minimum = "0", .maximum = "UINTPTR_MAX" },
        .{ .name = "i8", .minimum = "INT8_MIN", .maximum = "INT8_MAX" },
        .{ .name = "i16", .minimum = "INT16_MIN", .maximum = "INT16_MAX" },
        .{ .name = "i32", .minimum = "INT32_MIN", .maximum = "INT32_MAX" },
        .{ .name = "i64", .minimum = "INT64_MIN", .maximum = "INT64_MAX" },
        .{ .name = "isize", .minimum = "INTPTR_MIN", .maximum = "INTPTR_MAX" },
    };
    for (entries) |entry| if (std.mem.eql(u8, name, entry.name))
        return .{ .minimum = entry.minimum, .maximum = entry.maximum };
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
    // The C runtime deliberately has no race-access helper for 128-bit
    // scalars. They remain valid direct local storage, but shared/projected
    // access must fail renderer admission closed.
    if (mir.ExecutableCastKind.integerInfo(ty)) |integer| if (integer.bits > 64) return null;
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

test "executable C renderer preserves explicit pointer constness" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    const body: mir.ExecutableBody = .{};

    try appendCType(std.testing.allocator, &output, &body, .{ .pointer = .{
        .kind = .single,
        .mutability = .none,
        .child = "Square",
    } });
    try std.testing.expectEqualStrings("Square *", output.items);

    output.clearRetainingCapacity();
    try appendCType(std.testing.allocator, &output, &body, .{ .pointer = .{
        .kind = .single,
        .mutability = .@"const",
        .child = "Square",
    } });
    try std.testing.expectEqualStrings("Square const *", output.items);
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
        \\    MC_UNUSED uint32_t x = mc_exec_tmp_1;
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
    const first_call: @FieldType(mir.ExecutableExpression.Operation, "direct_call") = .{ .callee = next_symbol };
    const second_call: @FieldType(mir.ExecutableExpression.Operation, "direct_call") = .{ .callee = next_symbol };
    var combine_call: @FieldType(mir.ExecutableExpression.Operation, "direct_call") = .{ .callee = combine_symbol, .argument_count = 2 };
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
    const mutate_call: @FieldType(mir.ExecutableExpression.Operation, "direct_call") = .{ .callee = mutate_symbol };
    var combine_call: @FieldType(mir.ExecutableExpression.Operation, "direct_call") = .{ .callee = combine_symbol, .argument_count = 2 };
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

test "executable C renderer rejects implicit CFG and emits short circuit effects" {
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
    try std.testing.expect(canEmitBody(&logical_body));
    var logical_output: std.ArrayList(u8) = .empty;
    defer logical_output.deinit(std.testing.allocator);
    try emitBody(std.testing.allocator, &logical_output, &logical_body, 0);
    try std.testing.expect(std.mem.indexOf(u8, logical_output.items, "if (mc_exec_tmp_2)") != null);
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
    var phys_call: @FieldType(mir.ExecutableExpression.Operation, "builtin_call") = .{ .kind = .phys, .argument_count = 1 };
    phys_call.arguments[0] = phys_operand;
    var wrapping_call: @FieldType(mir.ExecutableExpression.Operation, "builtin_call") = .{ .kind = .wrapping_add, .argument_count = 2 };
    wrapping_call.arguments[0] = wrap_left;
    wrapping_call.arguments[1] = wrap_right;
    var conversion_call: @FieldType(mir.ExecutableExpression.Operation, "builtin_call") = .{ .kind = .conversion_from, .argument_count = 1 };
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
    var call: @FieldType(mir.ExecutableExpression.Operation, "builtin_call") = .{ .kind = .bitcast, .argument_count = 1 };
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
    var call: @FieldType(mir.ExecutableExpression.Operation, "builtin_call") = .{ .kind = .bitcast, .argument_count = 1 };
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
    var call: @FieldType(mir.ExecutableExpression.Operation, "builtin_call") = .{ .kind = .conversion_from, .argument_count = 1 };
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

test "executable C renderer emits unsigned integer boundaries without implicit unsigned literals" {
    const cases = [_]struct {
        value: u128,
        expected: []const u8,
    }{
        .{ .value = std.math.maxInt(i64), .expected = "9223372036854775807" },
        .{ .value = @as(u128, std.math.maxInt(i64)) + 1, .expected = "9223372036854775808ULL" },
        .{ .value = std.math.maxInt(u64), .expected = "18446744073709551615ULL" },
        .{
            .value = std.math.maxInt(u128),
            .expected = "((((unsigned __int128)18446744073709551615ULL) << 64) | ((unsigned __int128)18446744073709551615ULL))",
        },
    };

    for (cases) |case| {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try emitUnsignedIntegerLiteral(std.testing.allocator, &output, case.value);
        try std.testing.expectEqualStrings(case.expected, output.items);
    }
}
