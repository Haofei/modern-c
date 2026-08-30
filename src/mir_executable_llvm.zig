//! Mechanical LLVM body rendering for canonical executable MIR.
//!
//! This module deliberately has no syntax, semantic-analysis, or declaration
//! artifact dependency.  Admission is structural and typed-ID based; symbol
//! spelling is recovered only after a SymbolId has selected its identity.

const std = @import("std");
const mir = @import("mir_model.zig");
const scalar_repr = @import("scalar_repr.zig");

pub const RenderError = error{ Unsupported, InvalidBody, OutOfMemory };

/// Target ABI facts needed by the syntax-free renderer.  This is deliberately
/// narrower than the driver target configuration: direct calls only need the
/// integer-extension rules of the selected C ABI.
pub const TargetAbi = enum { riscv64, x86_64, aarch64 };

pub const AbiExtension = enum {
    none,
    signext,
    zeroext,

    fn resultPrefix(self: AbiExtension) []const u8 {
        return switch (self) {
            .none => "",
            .signext => "signext ",
            .zeroext => "zeroext ",
        };
    }

    fn parameterSuffix(self: AbiExtension) []const u8 {
        return switch (self) {
            .none => "",
            .signext => " signext",
            .zeroext => " zeroext",
        };
    }
};

/// One normalized direct-call ABI decision. ExprId and SymbolId are the
/// semantic identity; no source spelling or syntax node participates.
pub const DirectCallAbi = struct {
    expression: mir.ExprId,
    callee: mir.SymbolId,
    fixed_arity: usize,
    c_abi: bool,
    result_extension: AbiExtension = .none,
    parameter_extensions: [mir.max_executable_operands]AbiExtension = [_]AbiExtension{.none} ** mir.max_executable_operands,
};

pub const CallAbiPlan = struct {
    target: TargetAbi,
    direct_calls: []const DirectCallAbi,
};

/// The executable-MIR direct-call path implements only the C ABI classes whose
/// LLVM representation is already a scalar value. Aggregate/slice/result and
/// otherwise unknown values require a target layout/ABI plan and must remain on
/// the qualified legacy path until that plan is canonical MIR data.
pub fn cAbiDirectCallTypeSupported(ty: mir.ValueType) bool {
    return switch (ty) {
        .void, .bool, .cstr, .address => true,
        .pointer => |shape| shape.kind != .slice,
        .nullable_pointer => |shape| shape.kind != .slice,
        .integer, .domain_integer, .float => scalarLlvmType(ty) != null,
        else => false,
    };
}

fn cAbiDirectCallParameterTypeSupported(ty: mir.ValueType) bool {
    return ty != .void and cAbiDirectCallTypeSupported(ty);
}

pub fn abiExtension(target: TargetAbi, ty: mir.ValueType) AbiExtension {
    if (target == .aarch64) return .none;
    if (ty == .bool) return .zeroext;
    const scalar_ty: mir.ValueType = switch (ty) {
        .domain_integer => |shape| .{ .integer = shape.child },
        else => ty,
    };
    const integer = mir.ExecutableCastKind.integerInfo(scalar_ty) orelse return .none;
    if (integer.bits > 32) return .none;
    if (integer.bits == 32) return if (target == .riscv64) .signext else .none;
    return if (integer.signed) .signext else .zeroext;
}

const Value = struct {
    ty: []const u8,
    spelling: []const u8,
};

const Local = struct {
    ty: []const u8,
    storage: []const u8,
    addressable: bool,
};

fn directCallAbiFor(plan: CallAbiPlan, expression: mir.ExprId) ?DirectCallAbi {
    var found: ?DirectCallAbi = null;
    for (plan.direct_calls) |entry| {
        if (!entry.expression.eql(expression)) continue;
        if (found != null) return null;
        found = entry;
    }
    return found;
}

fn callAbiPlanValid(body: *const mir.ExecutableBody, plan: CallAbiPlan) bool {
    var direct_call_count: usize = 0;
    for (body.expressions) |expression| switch (expression.operation) {
        .direct_call => |call| {
            direct_call_count += 1;
            const entry = directCallAbiFor(plan, expression.id) orelse return false;
            if (!entry.callee.eql(call.callee) or entry.fixed_arity != call.argument_count or
                entry.fixed_arity > mir.max_executable_operands) return false;
            if (entry.c_abi and !cAbiDirectCallTypeSupported(expression.result_ty)) return false;
            const expected_result = if (entry.c_abi) abiExtension(plan.target, expression.result_ty) else .none;
            if (entry.result_extension != expected_result) return false;
            for (call.arguments[0..call.argument_count], 0..) |argument_id, index| {
                if (!expressionValid(body, argument_id)) return false;
                const argument_ty = body.expressions[argument_id.index()].result_ty;
                if (entry.c_abi and !cAbiDirectCallParameterTypeSupported(argument_ty)) return false;
                const expected = if (entry.c_abi) abiExtension(plan.target, argument_ty) else .none;
                if (entry.parameter_extensions[index] != expected) return false;
            }
            for (entry.parameter_extensions[call.argument_count..]) |extension| if (extension != .none) return false;
        },
        else => {},
    };
    if (direct_call_count != plan.direct_calls.len) return false;
    for (plan.direct_calls) |entry| {
        if (!entry.expression.isValid() or entry.expression.index() >= body.expressions.len) return false;
        switch (body.expressions[entry.expression.index()].operation) {
            .direct_call => {},
            else => return false,
        }
    }
    return true;
}

pub fn supports(body: *const mir.ExecutableBody, return_ty: mir.ValueType) bool {
    if (!body.isComplete() or body.terminators.len == 0 or
        (!llvmTypeSupported(body, return_ty) and !functionSymbolReturnSupported(body, return_ty)))
        return false;
    for (body.parameters) |parameter| {
        if (!parameter.local.isValid() or !(llvmTypeSupported(body, parameter.ty) or
            (parameter.ty == .value and callableParameter(body, parameter.local)))) return false;
    }
    for (body.expressions) |expression| {
        if (!expression.id.isValid() or expression.id.index() >= body.expressions.len or
            (!llvmTypeSupported(body, expression.result_ty) and !functionSymbolExpressionSupported(body, expression) and
                !callableValueExpressionSupported(body, expression))) return false;
        if (!operationSupported(body, expression)) return false;
    }
    for (body.trap_edges) |edge| {
        switch (edge.owner) {
            .expression => |owner_id| {
                if (!expressionValid(body, owner_id)) return false;
                const owner = body.expressions[owner_id.index()];
                switch (owner.operation) {
                    .unary => if (!checkedIntegerUnaryHasExactTrapEdges(body, owner)) return false,
                    .binary => |binary| {
                        if (binary.arithmetic != .checked or !checkedIntegerBinaryHasExactTrapEdges(body, owner)) return false;
                    },
                    .load => |load| {
                        if (!placeValid(body, load.place)) return false;
                        if (mir.executableFixedArrayIndexPlace(body, body.places[load.place.index()]) != null) {
                            if (!fixedArrayLoadBoundsTrapEdgeIsExact(body, owner)) return false;
                        } else if (!representationTrapEdgeIsExact(body, owner)) return false;
                    },
                    .address_of => |address| {
                        if (!placeValid(body, address.place)) return false;
                        if (mir.executableFixedArrayIndexPlace(body, body.places[address.place.index()]) != null) {
                            if (!fixedArrayLoadBoundsTrapEdgeIsExact(body, owner)) return false;
                        } else if (!representationTrapEdgeIsExact(body, owner)) return false;
                    },
                    .atomic_load, .atomic_update, .representation_check => if (!representationTrapEdgeIsExact(body, owner)) return false,
                    .try_unwrap => if (!tryUnwrapTrapEdgeIsExact(body, owner)) return false,
                    .index => |operation| if (!operation.checked or !indexTrapEdgeIsExact(body, owner)) return false,
                    .builtin_call => |call| if (call.kind == .conversion_trap_from) {
                        if (!builtinTrapConversionEdgeIsExact(body, owner)) return false;
                    } else if (!representationTrapEdgeIsExact(body, owner)) return false,
                    else => return false,
                }
            },
            .statement => |owner_id| {
                const owner = statementIdentity(body, owner_id) orelse return false;
                switch (owner.operation) {
                    .store => |store| if (!memoryStoreSupported(body, owner, store)) return false,
                    .guard => |guard| if (guard.kind != .assert_ or !assertTrapEdgeIsExact(body, owner)) return false,
                    else => return false,
                }
            },
        }
    }
    for (body.places) |place| {
        if (!place.id.isValid() or place.id.index() >= body.places.len or place.projection_count > mir.max_executable_projections) return false;
        if (place.storage == .atomic) {
            if (!atomicPlaceSupported(body, place)) return false;
        } else if (place.projection_count == 0) {
            if (!placeRootValid(body, place)) return false;
        } else if (!scalarAccessPlaceSupported(body, place) and mir.executableFixedArrayIndexPlace(body, place) == null) return false;
    }
    for (body.statements) |statement| {
        if (!statement.id.isValid() or !statement.block_id.isValid()) return false;
        switch (statement.operation) {
            .local_init => |local| {
                if (!local.local.isValid() or !(llvmTypeSupported(body, local.ty) or
                    (local.ty == .value and callableLocalUsedAsIndirectCallee(body, local.local)))) return false;
                if (local.value) |value| if (!expressionValid(body, value)) return false;
            },
            .store => |store| {
                if (!placeValid(body, store.place) or !expressionValid(body, store.value) or
                    !sameValueType(store.ty, body.expressions[store.value.index()].result_ty) or
                    !memoryStoreSupported(body, statement, store)) return false;
            },
            .eval => |value| if (!expressionValid(body, value)) return false,
            .guard => |guard| {
                if (!expressionValid(body, guard.condition)) return false;
                const condition_ty = body.expressions[guard.condition.index()].result_ty;
                if (guard.kind == .switch_) {
                    switch (condition_ty) {
                        .bool, .integer, .domain_integer, .closed_enum, .open_enum => {},
                        else => return false,
                    }
                } else if (condition_ty != .bool) return false;
                if (guard.kind == .assert_ and !assertTrapEdgeIsExact(body, statement)) return false;
            },
            .return_ => |value| if (value) |result| {
                if (!expressionValid(body, result)) return false;
            },
            .contract_marker => |marker| if (marker.name.len == 0) return false,
            .control_transfer => {},
            .defer_cleanup, .unsupported => return false,
        }
    }
    for (body.terminators) |terminator| {
        if (!terminator.block_id.isValid()) return false;
        switch (terminator.operation) {
            .fallthrough => return false,
            .jump => |target| if (!blockExists(body, target)) return false,
            .branch => |branch| if (!expressionValid(body, branch.condition) or !blockExists(body, branch.true_block) or !blockExists(body, branch.false_block)) return false,
            .switch_ => |switch_| if (!switchTerminatorSupported(body, switch_)) return false,
            .trap_ => |kind| if (trapHelper(kind) == null) return false,
            .return_ => if (!hasReturnStatement(body, terminator.block_id) and return_ty != .void) return false,
            .unreachable_ => {},
        }
    }
    return true;
}

fn switchTerminatorSupported(body: *const mir.ExecutableBody, switch_: mir.ExecutableSwitchTerminator) bool {
    if (switch_.case_count == 0 or switch_.case_count > switch_.cases.len or
        !blockExists(body, switch_.default_block) or !expressionValid(body, switch_.subject)) return false;
    switch (body.expressions[switch_.subject.index()].result_ty) {
        .integer, .domain_integer, .closed_enum, .open_enum => {},
        else => return false,
    }
    for (switch_.cases[0..switch_.case_count]) |case| if (!blockExists(body, case.target)) return false;
    return true;
}

pub fn render(allocator: std.mem.Allocator, body: *const mir.ExecutableBody, return_ty: mir.ValueType) RenderError![]u8 {
    if (!supports(body, return_ty)) return error.Unsupported;
    return renderValidated(allocator, body, return_ty, null);
}

pub fn supportsWithCallAbi(body: *const mir.ExecutableBody, return_ty: mir.ValueType, plan: CallAbiPlan) bool {
    return supports(body, return_ty) and callAbiPlanValid(body, plan);
}

pub fn renderWithCallAbi(allocator: std.mem.Allocator, body: *const mir.ExecutableBody, return_ty: mir.ValueType, plan: CallAbiPlan) RenderError![]u8 {
    if (!supportsWithCallAbi(body, return_ty, plan)) return error.Unsupported;
    return renderValidated(allocator, body, return_ty, &plan);
}

fn renderValidated(allocator: std.mem.Allocator, body: *const mir.ExecutableBody, return_ty: mir.ValueType, plan: ?*const CallAbiPlan) RenderError![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var renderer = try Renderer.init(arena.allocator(), body, return_ty, plan);
    defer renderer.deinit();
    try renderer.emit();
    return try allocator.dupe(u8, renderer.output.items);
}

const Renderer = struct {
    allocator: std.mem.Allocator,
    body: *const mir.ExecutableBody,
    return_ty: []const u8,
    output: std.ArrayList(u8) = .empty,
    values: []?Value,
    locals: std.AutoHashMap(u32, Local),
    returns: std.AutoHashMap(u32, ?Value),
    next_temp: usize = 0,
    call_abi_plan: ?*const CallAbiPlan,

    fn init(allocator: std.mem.Allocator, body: *const mir.ExecutableBody, return_ty: mir.ValueType, call_abi_plan: ?*const CallAbiPlan) RenderError!Renderer {
        const values = try allocator.alloc(?Value, body.expressions.len);
        @memset(values, null);
        var result: Renderer = .{
            .allocator = allocator,
            .body = body,
            .return_ty = "",
            .values = values,
            .locals = std.AutoHashMap(u32, Local).init(allocator),
            .returns = std.AutoHashMap(u32, ?Value).init(allocator),
            .call_abi_plan = call_abi_plan,
        };
        result.return_ty = try result.typeText(return_ty);
        return result;
    }

    fn typeText(self: *Renderer, ty: mir.ValueType) RenderError![]const u8 {
        return self.typeTextDepth(ty, 0);
    }

    fn typeTextDepth(self: *Renderer, ty: mir.ValueType, depth: usize) RenderError![]const u8 {
        if (scalarLlvmType(ty)) |scalar| return scalar;
        // `.value` is admitted only for a canonical function SymbolId. LLVM
        // represents that function identity as an opaque pointer.
        if (ty == .value) return "ptr";
        if (depth >= mir.max_executable_operands) return error.Unsupported;
        if (enumTypeForValueType(self.body, ty)) |enum_ty| return self.typeTextDepth(enum_ty.repr_ty, depth + 1);
        if (resultTypeForValueType(self.body, ty)) |shape| {
            const ok_ty = try self.typeTextDepth(shape.ok_ty, depth + 1);
            const err_ty = try self.typeTextDepth(shape.err_ty, depth + 1);
            return std.fmt.allocPrint(self.allocator, "{{ i1, {s}, {s} }}", .{ ok_ty, err_ty });
        }
        const aggregate = aggregateTypeForValueType(self.body, ty) orelse return error.Unsupported;
        if (aggregate.construction == .packed_bits) return self.typeTextDepth(aggregate.storage_ty, depth + 1);
        if (aggregate.ty == .array) {
            if (aggregate.field_count == 0 or aggregate.array_length == null) return error.Unsupported;
            const element_ty = try self.typeTextDepth(aggregate.field_types[0], depth + 1);
            return std.fmt.allocPrint(self.allocator, "[{d} x {s}]", .{ aggregate.array_length.?, element_ty });
        }
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(self.allocator, "{ ");
        for (aggregate.field_types[0..aggregate.field_count], 0..) |field_ty, index| {
            if (index != 0) try text.appendSlice(self.allocator, ", ");
            try text.appendSlice(self.allocator, try self.typeTextDepth(field_ty, depth + 1));
        }
        try text.appendSlice(self.allocator, " }");
        return text.toOwnedSlice(self.allocator);
    }

    fn deinit(self: *Renderer) void {
        self.output.deinit(self.allocator);
        if (self.values.len != 0) self.allocator.free(self.values);
        self.locals.deinit();
        self.returns.deinit();
    }

    fn emit(self: *Renderer) RenderError!void {
        if (self.values.len != self.body.expressions.len) return error.OutOfMemory;
        for (self.body.parameters) |parameter| {
            const ty = try self.typeText(parameter.ty);
            try self.locals.put(parameter.local.raw, .{ .ty = ty, .storage = try std.fmt.allocPrint(self.allocator, "%mc_arg_{d}", .{parameter.local.raw}), .addressable = false });
        }
        try self.output.appendSlice(self.allocator, "  ; canonical executable MIR\n");
        // Allocate every local once in the entry prologue. An alloca inside a
        // loop block executes on every iteration and would grow the stack.
        for (self.body.statements) |statement| switch (statement.operation) {
            .local_init => |local| {
                if (self.locals.contains(local.local.raw)) return error.InvalidBody;
                const ty = try self.typeText(local.ty);
                const slot = try std.fmt.allocPrint(self.allocator, "%mc_local_{d}", .{local.local.raw});
                try self.output.print(self.allocator, "  {s} = alloca {s}\n", .{ slot, ty });
                try self.locals.put(local.local.raw, .{ .ty = ty, .storage = slot, .addressable = true });
            },
            else => {},
        };
        try self.output.print(self.allocator, "  br label %mc_block_{d}\n", .{self.body.terminators[0].block_id.raw});
        for (self.body.terminators) |terminator| {
            // Expression IDs identify source occurrences, not SSA definitions.
            // Re-render them in each CFG block so a cached local load or call
            // can never violate dominance or observe a stale generation.
            @memset(self.values, null);
            try self.output.print(self.allocator, "mc_block_{d}:\n", .{terminator.block_id.raw});
            for (self.body.statements) |statement| {
                if (!statement.block_id.eql(terminator.block_id)) continue;
                try self.emitStatement(statement);
            }
            try self.emitTerminator(terminator);
        }
    }

    fn emitStatement(self: *Renderer, statement: mir.ExecutableStatement) RenderError!void {
        switch (statement.operation) {
            .local_init => |local| {
                const ty = try self.typeText(local.ty);
                const slot = (self.locals.get(local.local.raw) orelse return error.InvalidBody).storage;
                if (local.value) |initializer| {
                    const value = try self.emitExpression(initializer);
                    if (!std.mem.eql(u8, ty, value.ty)) return error.InvalidBody;
                    try self.output.print(self.allocator, "  store {s} {s}, ptr {s}\n", .{ ty, value.spelling, slot });
                }
            },
            .store => |store| {
                const place = self.body.places[store.place.index()];
                const indexed_pointer = if (mir.executableFixedArrayIndexPlace(self.body, place) != null)
                    try self.emitFixedArrayIndexPlacePointer(place, .{ .statement = statement.id })
                else
                    null;
                const value = try self.emitExpression(store.value);
                const pointer = indexed_pointer orelse if (computedRawManyDerefPlaceSupported(self.body, place, true))
                    try self.emitComputedRawManyDerefPointer(place)
                else if (mir.executableLocalAddressDerefPlace(self.body, place, true))
                    try self.emitGuardedLocalAddressAliasStorePointer(statement, store.place)
                else if (mir.executableDirectAggregateFieldPlace(
                    self.body.locals,
                    self.body.statements,
                    self.body.aggregate_types,
                    place,
                    true,
                ) != null)
                    try self.emitPlace(store.place, value.ty)
                else if (place.projection_count != 0)
                    try self.emitGuardedParameterStorePointer(statement, store.place)
                else
                    try self.emitPlace(store.place, value.ty);
                if (!sameValueType(store.ty, self.body.expressions[store.value.index()].result_ty)) return error.InvalidBody;
                try self.emitMemoryStore(store.place, value, pointer, store.access);
            },
            .eval => |value| _ = try self.emitExpression(value),
            .guard => |guard| {
                const condition = try self.emitExpression(guard.condition);
                if (guard.kind != .switch_ and !std.mem.eql(u8, condition.ty, "i1")) return error.InvalidBody;
                if (guard.kind == .assert_) {
                    const edge = assertTrapEdge(self.body, statement) orelse return error.InvalidBody;
                    const continuation = try std.fmt.allocPrint(self.allocator, "mc_assert_ready_{d}", .{statement.id.raw});
                    try self.output.print(
                        self.allocator,
                        "  br i1 {s}, label %{s}, label %mc_block_{d}\n" ++
                            "{s}:\n",
                        .{ condition.spelling, continuation, edge.trap_block.raw, continuation },
                    );
                }
            },
            .contract_marker => |marker| switch (marker.kind) {
                .begin => try self.output.print(self.allocator, "  ; MC_CONTRACT_BEGIN {s}\n", .{marker.name}),
                .end => try self.output.print(self.allocator, "  ; MC_CONTRACT_END {s}\n", .{marker.name}),
            },
            .return_ => |value| {
                const rendered = if (value) |result| try self.emitExpression(result) else null;
                try self.returns.put(statement.block_id.raw, rendered);
            },
            // The verified CFG terminator owns the actual break/continue
            // edge; the statement only preserves its source identity.
            .control_transfer => {},
            .defer_cleanup, .unsupported => return error.Unsupported,
        }
    }

    fn emitTerminator(self: *Renderer, terminator: mir.ExecutableTerminator) RenderError!void {
        switch (terminator.operation) {
            .jump => |target| try self.output.print(self.allocator, "  br label %mc_block_{d}\n", .{target.raw}),
            .branch => |branch| {
                const condition = try self.emitExpression(branch.condition);
                if (!std.mem.eql(u8, condition.ty, "i1")) return error.InvalidBody;
                try self.output.print(self.allocator, "  br i1 {s}, label %mc_block_{d}, label %mc_block_{d}\n", .{ condition.spelling, branch.true_block.raw, branch.false_block.raw });
            },
            .return_ => {
                const value = self.returns.get(terminator.block_id.raw) orelse null;
                if (std.mem.eql(u8, self.return_ty, "void")) {
                    if (value != null) return error.InvalidBody;
                    try self.output.appendSlice(self.allocator, "  ret void\n");
                } else {
                    const rendered = value orelse return error.InvalidBody;
                    if (!std.mem.eql(u8, rendered.ty, self.return_ty)) return error.InvalidBody;
                    try self.output.print(self.allocator, "  ret {s} {s}\n", .{ rendered.ty, rendered.spelling });
                }
            },
            .trap_ => |kind| try self.output.print(self.allocator, "  call void @{s}()\n  unreachable\n", .{trapHelper(kind) orelse return error.Unsupported}),
            .unreachable_ => try self.output.appendSlice(self.allocator, "  unreachable\n"),
            .switch_ => |switch_| {
                const subject = try self.emitExpression(switch_.subject);
                try self.output.print(self.allocator, "  switch {s} {s}, label %mc_block_{d} [\n", .{ subject.ty, subject.spelling, switch_.default_block.raw });
                for (switch_.cases[0..switch_.case_count]) |case| {
                    try self.output.print(self.allocator, "    {s} ", .{subject.ty});
                    switch (case.value) {
                        .unsigned => |value| try self.output.print(self.allocator, "{d}", .{value}),
                        .signed => |value| try self.output.print(self.allocator, "{d}", .{value}),
                    }
                    try self.output.print(self.allocator, ", label %mc_block_{d}\n", .{case.target.raw});
                }
                try self.output.appendSlice(self.allocator, "  ]\n");
            },
            .fallthrough => return error.Unsupported,
        }
    }

    fn emitExpression(self: *Renderer, id: mir.ExprId) RenderError!Value {
        if (!expressionValid(self.body, id)) return error.InvalidBody;
        if (self.values[id.index()]) |cached| return cached;
        const expression = self.body.expressions[id.index()];
        const ty = try self.typeText(expression.result_ty);
        const result: Value = switch (expression.operation) {
            .local => |local_id| blk: {
                const local = self.locals.get(local_id.raw) orelse return error.InvalidBody;
                if (!std.mem.eql(u8, local.ty, ty)) return error.InvalidBody;
                if (!local.addressable) break :blk .{ .ty = ty, .spelling = local.storage };
                const value = try self.temp();
                try self.output.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ value, ty, local.storage });
                break :blk .{ .ty = ty, .spelling = value };
            },
            .symbol => |symbol_id| blk: {
                const identity = symbolIdentity(self.body, symbol_id) orelse return error.InvalidBody;
                if (identity.kind == .function) {
                    if (expression.result_ty != .value) return error.InvalidBody;
                    break :blk .{ .ty = "ptr", .spelling = try std.fmt.allocPrint(self.allocator, "@{s}", .{identity.spelling}) };
                }
                const value = try self.temp();
                // Memory access mode is semantic data.  In the absence of an
                // explicit atomic/volatile/MMIO access operation, a symbol
                // read is an ordinary load; the backend must not infer an
                // atomic access from the LLVM scalar type.
                try self.output.print(self.allocator, "  {s} = load {s}, ptr @{s}\n", .{ value, ty, identity.spelling });
                break :blk .{ .ty = ty, .spelling = value };
            },
            .load => |load| try self.emitMemoryLoad(expression, load),
            .atomic_load => |load| try self.emitAtomicLoad(expression, load),
            .atomic_init => |operand| try self.emitExpression(operand),
            .atomic_update => |update| try self.emitAtomicUpdate(expression, update),
            .mmio_read => |read| try self.emitMmioRead(expression, read),
            .mmio_write => |write| try self.emitMmioWrite(expression, write),
            .literal => |literal| try self.literalValue(ty, literal),
            .unary => |unary| try self.emitUnary(expression, ty, unary),
            .binary => |binary| try self.emitBinary(expression, ty, binary),
            .direct_call => |call| try self.emitDirectCall(expression, ty, call),
            .builtin_call => |call| try self.emitBuiltinCall(expression, call),
            .representation_check => |check| try self.emitRepresentationCheck(expression, check),
            .indirect_call => |call| try self.emitIndirectCall(ty, call),
            .deref => |operand| blk: {
                const pointer = try self.emitExpression(operand);
                if (!std.mem.eql(u8, pointer.ty, "ptr")) return error.InvalidBody;
                const value = try self.temp();
                try self.output.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ value, ty, pointer.spelling });
                break :blk .{ .ty = ty, .spelling = value };
            },
            .slice_length => |base_id| blk: {
                const base = try self.emitExpression(base_id);
                if (!std.mem.eql(u8, base.ty, "{ ptr, i64 }") or !std.mem.eql(u8, ty, "i64")) return error.InvalidBody;
                const value = try self.temp();
                try self.output.print(self.allocator, "  {s} = extractvalue {{ ptr, i64 }} {s}, 1\n", .{ value, base.spelling });
                break :blk .{ .ty = "i64", .spelling = value };
            },
            .optional_some => |operand_id| try self.emitOptional(expression, operand_id),
            .optional_none => .{ .ty = ty, .spelling = "zeroinitializer" },
            .variant_test => |operation| try self.emitVariant(expression, operation.operand, operation.kind, false),
            .variant_payload => |operation| try self.emitVariant(expression, operation.operand, operation.kind, true),
            .try_unwrap => |operand| try self.emitTryUnwrap(expression, operand),
            .result => |result| try self.emitResult(expression, result),
            .address_of => |address| try self.emitAddressOf(expression, address),
            .cast => |cast| try self.emitCast(expression, cast),
            .array => |aggregate| try self.emitArray(expression, aggregate),
            .struct_ => |aggregate| try self.emitStruct(expression, aggregate),
            .member => |member| try self.emitMember(expression, member),
            .index => |index| try self.emitIndex(expression, index),
            .range_slice, .unsupported => return error.Unsupported,
        };
        self.values[id.index()] = result;
        return result;
    }

    fn emitVariant(
        self: *Renderer,
        expression: mir.ExecutableExpression,
        operand_id: mir.ExprId,
        kind: mir.ExecutableVariantKind,
        payload: bool,
    ) RenderError!Value {
        if (!variantOperationSupported(self.body, expression, operand_id, kind, payload)) return error.InvalidBody;
        const operand = try self.emitExpression(operand_id);
        if (!payload) {
            if (kind == .optional_present and self.body.expressions[operand_id.index()].result_ty == .nullable_pointer) {
                const present = try self.temp();
                try self.output.print(self.allocator, "  {s} = icmp ne ptr {s}, null\n", .{ present, operand.spelling });
                return .{ .ty = "i1", .spelling = present };
            }
            const tag = try self.temp();
            try self.output.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ tag, operand.ty, operand.spelling });
            if (kind != .result_err) return .{ .ty = "i1", .spelling = tag };
            const inverted = try self.temp();
            try self.output.print(self.allocator, "  {s} = xor i1 {s}, true\n", .{ inverted, tag });
            return .{ .ty = "i1", .spelling = inverted };
        }
        if (kind == .optional_present and self.body.expressions[operand_id.index()].result_ty == .nullable_pointer)
            return operand;
        const index: usize = switch (kind) {
            .optional_present, .result_ok => 1,
            .result_err => 2,
        };
        const value = try self.temp();
        const ty = try self.typeText(expression.result_ty);
        try self.output.print(self.allocator, "  {s} = extractvalue {s} {s}, {d}\n", .{ value, operand.ty, operand.spelling, index });
        return .{ .ty = ty, .spelling = value };
    }

    fn emitRepresentationCheck(self: *Renderer, expression: mir.ExecutableExpression, check: anytype) RenderError!Value {
        if (!representationCheckSupported(self.body, expression, check)) return error.InvalidBody;
        const operand = try self.emitExpression(check.operand);
        const edge = representationTrapEdge(self.body, expression) orelse return error.InvalidBody;
        const continuation = try std.fmt.allocPrint(self.allocator, "mc_representation_ready_{d}", .{expression.id.raw});
        switch (check.kind) {
            .nonnull_pointer => {
                if (!std.mem.eql(u8, operand.ty, "ptr")) return error.InvalidBody;
                try self.emitPointerRepresentationGuard(operand.spelling, edge, continuation);
            },
            .valid_slice => {
                if (!std.mem.eql(u8, operand.ty, "{ ptr, i64 }")) return error.InvalidBody;
                try self.emitSliceRepresentationGuard(operand.spelling, edge, continuation);
            },
            .valid_closed_enum => {
                const enum_ty = enumType(self.body, expression.type_id) orelse return error.InvalidBody;
                var valid: ?[]const u8 = null;
                for (enum_ty.valid_values[0..enum_ty.valid_value_count]) |case_value| {
                    const equal = try self.temp();
                    try self.output.print(self.allocator, "  {s} = icmp eq {s} {s}, {d}\n", .{ equal, operand.ty, operand.spelling, case_value });
                    if (valid) |previous| {
                        const combined = try self.temp();
                        try self.output.print(self.allocator, "  {s} = or i1 {s}, {s}\n", .{ combined, previous, equal });
                        valid = combined;
                    } else valid = equal;
                }
                const is_valid = valid orelse return error.InvalidBody;
                try self.output.print(
                    self.allocator,
                    "  br i1 {s}, label %{s}, label %mc_block_{d}\n{s}:\n",
                    .{ is_valid, continuation, edge.trap_block.raw, continuation },
                );
            },
        }
        return operand;
    }

    fn emitTryUnwrap(self: *Renderer, expression: mir.ExecutableExpression, operand_id: mir.ExprId) RenderError!Value {
        if (!tryUnwrapSupported(self.body, expression, operand_id)) return error.InvalidBody;
        const operand = try self.emitExpression(operand_id);
        if (!std.mem.eql(u8, operand.ty, "ptr")) return error.InvalidBody;
        const edge = tryUnwrapTrapEdge(self.body, expression) orelse return error.InvalidBody;
        const continuation = try std.fmt.allocPrint(self.allocator, "mc_unwrap_ready_{d}", .{expression.id.raw});
        try self.emitPointerRepresentationGuard(operand.spelling, edge, continuation);
        return operand;
    }

    fn emitOptional(self: *Renderer, expression: mir.ExecutableExpression, operand_id: mir.ExprId) RenderError!Value {
        if (!optionalConstructionSupported(self.body, expression, operand_id)) return error.InvalidBody;
        const aggregate = aggregateType(self.body, expression.type_id) orelse return error.InvalidBody;
        const optional_ty = try self.typeText(expression.result_ty);
        const payload_ty = try self.typeText(aggregate.field_types[1]);
        const operand = try self.emitExpression(operand_id);
        if (!std.mem.eql(u8, operand.ty, payload_ty)) return error.InvalidBody;
        const with_tag = try self.temp();
        try self.output.print(self.allocator, "  {s} = insertvalue {s} zeroinitializer, i1 true, 0\n", .{ with_tag, optional_ty });
        const with_payload = try self.temp();
        try self.output.print(self.allocator, "  {s} = insertvalue {s} {s}, {s} {s}, 1\n", .{
            with_payload,
            optional_ty,
            with_tag,
            payload_ty,
            operand.spelling,
        });
        return .{ .ty = optional_ty, .spelling = with_payload };
    }

    fn emitResult(self: *Renderer, expression: mir.ExecutableExpression, operation: anytype) RenderError!Value {
        if (!resultConstructionSupported(self.body, expression, operation)) return error.InvalidBody;
        const shape = resultType(self.body, expression.type_id) orelse return error.InvalidBody;
        const result_ty = try self.typeText(expression.result_ty);
        const payload = try self.emitExpression(operation.payload);
        const payload_ty = try self.typeText(if (operation.is_ok) shape.ok_ty else shape.err_ty);
        if (!std.mem.eql(u8, payload.ty, payload_ty)) return error.InvalidBody;
        const tagged = try self.temp();
        try self.output.print(self.allocator, "  {s} = insertvalue {s} zeroinitializer, i1 {s}, 0\n", .{ tagged, result_ty, if (operation.is_ok) "true" else "false" });
        const value = try self.temp();
        try self.output.print(self.allocator, "  {s} = insertvalue {s} {s}, {s} {s}, {d}\n", .{
            value,
            result_ty,
            tagged,
            payload_ty,
            payload.spelling,
            @as(usize, if (operation.is_ok) 1 else 2),
        });
        return .{ .ty = result_ty, .spelling = value };
    }

    fn emitStruct(self: *Renderer, expression: mir.ExecutableExpression, operation: anytype) RenderError!Value {
        if (!structConstructionSupported(self.body, expression, operation)) return error.InvalidBody;
        const shape = aggregateType(self.body, expression.type_id) orelse return error.InvalidBody;
        const aggregate_ty = try self.typeText(shape.ty);
        if (shape.construction == .packed_bits) {
            var current: []const u8 = "0";
            for (operation.operands[0..operation.operand_count], operation.field_indices[0..operation.operand_count]) |operand_id, field_index| {
                const operand = try self.emitExpression(operand_id);
                if (!std.mem.eql(u8, operand.ty, "i1")) return error.InvalidBody;
                const selected = try self.temp();
                try self.output.print(self.allocator, "  {s} = select i1 {s}, {s} {d}, {s} 0\n", .{
                    selected,
                    operand.spelling,
                    aggregate_ty,
                    @as(u128, 1) << @intCast(field_index),
                    aggregate_ty,
                });
                if (std.mem.eql(u8, current, "0")) {
                    current = selected;
                } else {
                    const combined = try self.temp();
                    try self.output.print(self.allocator, "  {s} = or {s} {s}, {s}\n", .{ combined, aggregate_ty, current, selected });
                    current = combined;
                }
            }
            return .{ .ty = aggregate_ty, .spelling = current };
        }
        var current: []const u8 = "zeroinitializer";
        for (operation.operands[0..operation.operand_count], operation.field_indices[0..operation.operand_count]) |operand_id, field_index| {
            const operand = try self.emitExpression(operand_id);
            const field_ty = try self.typeText(shape.field_types[field_index]);
            if (!std.mem.eql(u8, operand.ty, field_ty)) return error.InvalidBody;
            const result = try self.temp();
            try self.output.print(self.allocator, "  {s} = insertvalue {s} {s}, {s} {s}, {d}\n", .{
                result,
                aggregate_ty,
                current,
                field_ty,
                operand.spelling,
                field_index,
            });
            current = result;
        }
        return .{ .ty = aggregate_ty, .spelling = current };
    }

    fn emitArray(self: *Renderer, expression: mir.ExecutableExpression, operation: anytype) RenderError!Value {
        if (!arrayConstructionSupported(self.body, expression, operation)) return error.InvalidBody;
        const shape = aggregateType(self.body, expression.type_id) orelse return error.InvalidBody;
        const aggregate_ty = try self.typeText(shape.ty);
        var current: []const u8 = "zeroinitializer";
        for (operation.operands[0..operation.operand_count], 0..) |operand_id, index| {
            const operand = try self.emitExpression(operand_id);
            const element_ty = try self.typeText(shape.field_types[index]);
            if (!std.mem.eql(u8, operand.ty, element_ty)) return error.InvalidBody;
            const result = try self.temp();
            try self.output.print(self.allocator, "  {s} = insertvalue {s} {s}, {s} {s}, {d}\n", .{
                result,
                aggregate_ty,
                current,
                element_ty,
                operand.spelling,
                index,
            });
            current = result;
        }
        return .{ .ty = aggregate_ty, .spelling = current };
    }

    fn emitMember(self: *Renderer, expression: mir.ExecutableExpression, operation: anytype) RenderError!Value {
        if (!memberSupported(self.body, expression, operation)) return error.InvalidBody;
        const base_expression = self.body.expressions[operation.base.index()];
        const shape = aggregateType(self.body, base_expression.type_id) orelse return error.InvalidBody;
        const base = try self.emitExpression(operation.base);
        const aggregate_ty = try self.typeText(shape.ty);
        const result_ty = try self.typeText(expression.result_ty);
        if (!std.mem.eql(u8, base.ty, aggregate_ty)) return error.InvalidBody;
        if (shape.construction == .packed_bits) {
            const mask = try self.temp();
            const result = try self.temp();
            try self.output.print(self.allocator, "  {s} = and {s} {s}, {d}\n  {s} = icmp ne {s} {s}, 0\n", .{
                mask,
                aggregate_ty,
                base.spelling,
                @as(u128, 1) << @intCast(operation.field_index),
                result,
                aggregate_ty,
                mask,
            });
            return .{ .ty = result_ty, .spelling = result };
        }
        const result = try self.temp();
        try self.output.print(self.allocator, "  {s} = extractvalue {s} {s}, {d}\n", .{ result, aggregate_ty, base.spelling, operation.field_index });
        return .{ .ty = result_ty, .spelling = result };
    }

    fn emitIndex(
        self: *Renderer,
        expression: mir.ExecutableExpression,
        operation: @FieldType(mir.ExecutableExpression.Operation, "index"),
    ) RenderError!Value {
        if (!indexSupported(self.body, expression, operation)) return error.InvalidBody;
        const base_expression = self.body.expressions[operation.base.index()];
        const global_symbol: ?mir.SymbolId = switch (base_expression.operation) {
            .symbol => |symbol| if (globalAggregateIndexBase(self.body, operation.base)) symbol else null,
            else => null,
        };
        const base = if (global_symbol == null) try self.emitExpression(operation.base) else Value{
            .ty = try self.typeText(base_expression.result_ty),
            .spelling = try std.fmt.allocPrint(
                self.allocator,
                "@{s}",
                .{symbolSpelling(self.body, global_symbol.?) orelse return error.InvalidBody},
            ),
        };
        const index = try self.emitExpression(operation.index);
        if (!std.mem.eql(u8, index.ty, "i64")) return error.InvalidBody;
        const result_ty = try self.typeText(expression.result_ty);
        var element_pointer: []const u8 = undefined;

        switch (operation.kind) {
            .fixed_array => {
                const bound = operation.bound orelse return error.InvalidBody;
                if (operation.checked) {
                    const edge = indexTrapEdge(self.body, expression) orelse return error.InvalidBody;
                    const invalid = try self.temp();
                    const continuation = try std.fmt.allocPrint(self.allocator, "mc_index_ready_{d}", .{expression.id.raw});
                    try self.output.print(
                        self.allocator,
                        "  {s} = icmp uge i64 {s}, {d}\n" ++
                            "  br i1 {s}, label %mc_block_{d}, label %{s}\n" ++
                            "{s}:\n",
                        .{ invalid, index.spelling, bound, invalid, edge.trap_block.raw, continuation, continuation },
                    );
                }
                // A global aggregate symbol is already stable storage. Other
                // aggregate values are materialized once because LLVM has no
                // dynamic `extractvalue` for arrays.
                const storage = if (global_symbol != null) base.spelling else storage: {
                    const slot = try self.temp();
                    try self.output.print(self.allocator, "  {s} = alloca {s}\n  store {s} {s}, ptr {s}\n", .{
                        slot,
                        base.ty,
                        base.ty,
                        base.spelling,
                        slot,
                    });
                    break :storage slot;
                };
                element_pointer = try self.temp();
                try self.output.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i64 {s}\n", .{
                    element_pointer,
                    base.ty,
                    storage,
                    index.spelling,
                });
            },
            .slice => {
                if (!std.mem.eql(u8, base.ty, "{ ptr, i64 }")) return error.InvalidBody;
                const pointer = try self.temp();
                const length = try self.temp();
                try self.output.print(self.allocator, "  {s} = extractvalue {{ ptr, i64 }} {s}, 0\n  {s} = extractvalue {{ ptr, i64 }} {s}, 1\n", .{
                    pointer,
                    base.spelling,
                    length,
                    base.spelling,
                });
                if (operation.checked) {
                    const edge = indexTrapEdge(self.body, expression) orelse return error.InvalidBody;
                    const invalid = try self.temp();
                    const continuation = try std.fmt.allocPrint(self.allocator, "mc_index_ready_{d}", .{expression.id.raw});
                    try self.output.print(
                        self.allocator,
                        "  {s} = icmp uge i64 {s}, {s}\n" ++
                            "  br i1 {s}, label %mc_block_{d}, label %{s}\n" ++
                            "{s}:\n",
                        .{ invalid, index.spelling, length, invalid, edge.trap_block.raw, continuation, continuation },
                    );
                }
                element_pointer = try self.temp();
                try self.output.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 {s}\n", .{
                    element_pointer,
                    result_ty,
                    pointer,
                    index.spelling,
                });
            },
        }
        const result = try self.temp();
        try self.output.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ result, result_ty, element_pointer });
        return .{ .ty = result_ty, .spelling = result };
    }

    fn literalValue(self: *Renderer, ty: []const u8, literal: mir.ExecutableLiteral) RenderError!Value {
        return switch (literal) {
            .integer => |magnitude| .{ .ty = ty, .spelling = try std.fmt.allocPrint(self.allocator, "{d}", .{magnitude}) },
            .signed_integer => |value| .{ .ty = ty, .spelling = try std.fmt.allocPrint(self.allocator, "{d}", .{value}) },
            .boolean => |value| .{ .ty = ty, .spelling = if (value) "true" else "false" },
            .float => |value| switch (value) {
                .f32_bits => |bits| if (std.mem.eql(u8, ty, "float"))
                    .{ .ty = ty, .spelling = try std.fmt.allocPrint(self.allocator, "bitcast (i32 {d} to float)", .{bits}) }
                else
                    error.InvalidBody,
                .f64_bits => |bits| if (std.mem.eql(u8, ty, "double"))
                    .{ .ty = ty, .spelling = try std.fmt.allocPrint(self.allocator, "bitcast (i64 {d} to double)", .{bits}) }
                else
                    error.InvalidBody,
            },
            .null => if (std.mem.eql(u8, ty, "ptr")) .{ .ty = ty, .spelling = "null" } else error.Unsupported,
            .void => .{ .ty = "void", .spelling = "" },
            else => error.Unsupported,
        };
    }

    fn emitUnary(self: *Renderer, expression: mir.ExecutableExpression, ty: []const u8, unary: anytype) RenderError!Value {
        const operand = try self.emitExpression(unary.operand);
        if (!std.mem.eql(u8, operand.ty, ty)) return error.InvalidBody;
        if (mir.executableCheckedUnaryTrapRequirements(unary.op, expression.result_ty) != null) {
            const edge = checkedTrapEdge(self.body, expression, .{ .kind = .IntegerOverflow, .source = .checked_arithmetic }) orelse
                return error.InvalidBody;
            const pair = try self.temp();
            const value = try self.temp();
            const overflow = try self.temp();
            const continuation = try std.fmt.allocPrint(self.allocator, "mc_checked_cont_{d}", .{expression.id.raw});
            try self.output.print(
                self.allocator,
                "  {s} = call {{ {s}, i1 }} @llvm.ssub.with.overflow.{s}({s} 0, {s} {s})\n" ++
                    "  {s} = extractvalue {{ {s}, i1 }} {s}, 0\n" ++
                    "  {s} = extractvalue {{ {s}, i1 }} {s}, 1\n" ++
                    "  br i1 {s}, label %mc_block_{d}, label %{s}\n" ++
                    "{s}:\n",
                .{ pair, ty, ty, ty, operand.ty, operand.spelling, value, ty, pair, overflow, ty, pair, overflow, edge.trap_block.raw, continuation, continuation },
            );
            return .{ .ty = ty, .spelling = value };
        }
        const value = try self.temp();
        switch (unary.op) {
            .bit_not => try self.output.print(self.allocator, "  {s} = xor {s} {s}, -1\n", .{ value, ty, operand.spelling }),
            .logical_not => if (std.mem.eql(u8, ty, "i1"))
                try self.output.print(self.allocator, "  {s} = xor i1 {s}, true\n", .{ value, operand.spelling })
            else
                return error.InvalidBody,
            .neg => if (isFloatType(self.body.expressions[unary.operand.index()].result_ty))
                try self.output.print(self.allocator, "  {s} = fneg {s} {s}\n", .{ value, ty, operand.spelling })
            else if (wrappingNegType(expression.result_ty))
                // LLVM integer subtraction is modular unless an overflow flag
                // says otherwise. The verified wrap<T> domain therefore needs
                // no backend-local check or source-shaped fallback.
                try self.output.print(self.allocator, "  {s} = sub {s} 0, {s}\n", .{ value, ty, operand.spelling })
            else
                return error.Unsupported,
        }
        return .{ .ty = ty, .spelling = value };
    }

    fn emitCast(self: *Renderer, expression: mir.ExecutableExpression, cast: anytype) RenderError!Value {
        if (!castSupported(self.body, expression, cast)) return error.InvalidBody;
        const operand_expression = self.body.expressions[cast.operand.index()];
        const operand = try self.emitExpression(cast.operand);
        const target_ty = try self.typeText(expression.result_ty);
        const expected = mir.ExecutableCastKind.classify(operand_expression.result_ty, expression.result_ty) orelse return error.InvalidBody;
        if (expected != cast.kind) return error.InvalidBody;

        const source_info = mir.ExecutableCastKind.integerInfo(castStorageType(self.body, operand_expression.result_ty) orelse operand_expression.result_ty);
        const target_info = mir.ExecutableCastKind.integerInfo(castStorageType(self.body, expression.result_ty) orelse expression.result_ty);
        const operation: ?[]const u8 = switch (expected) {
            .identity => null,
            .integer_reinterpret => null,
            .integer_resize => resize: {
                const source = source_info orelse return error.InvalidBody;
                const target = target_info orelse return error.InvalidBody;
                break :resize if (target.bits > source.bits)
                    (if (source.signed) "sext" else "zext")
                else if (target.bits < source.bits)
                    "trunc"
                else
                    null;
            },
            .integer_to_domain, .domain_to_integer => null,
            .float_resize => float: {
                const source_bits = switch (operand_expression.result_ty) {
                    .float => |name| mir.ExecutableCastKind.floatBits(name) orelse return error.InvalidBody,
                    else => return error.InvalidBody,
                };
                const target_bits = switch (expression.result_ty) {
                    .float => |name| mir.ExecutableCastKind.floatBits(name) orelse return error.InvalidBody,
                    else => return error.InvalidBody,
                };
                break :float if (target_bits > source_bits) "fpext" else if (target_bits < source_bits) "fptrunc" else null;
            },
            .address_to_integer, .integer_to_address => null,
            .pointer_to_integer, .pointer_to_address => "ptrtoint",
            .pointer_to_nullable, .pointer_const_narrow => null,
            .integer_to_open_enum, .enum_to_integer => resize: {
                const source = source_info orelse return error.InvalidBody;
                const target = target_info orelse return error.InvalidBody;
                break :resize if (target.bits > source.bits)
                    (if (source.signed) "sext" else "zext")
                else if (target.bits < source.bits)
                    "trunc"
                else
                    null;
            },
            .unsigned_resize => resize: {
                const source = source_info orelse return error.InvalidBody;
                const target = target_info orelse return error.InvalidBody;
                break :resize if (target.bits > source.bits) "zext" else if (target.bits < source.bits) "trunc" else null;
            },
            .signed_widen => widen: {
                const source = source_info orelse return error.InvalidBody;
                const target = target_info orelse return error.InvalidBody;
                if (target.bits < source.bits) return error.InvalidBody;
                break :widen if (target.bits == source.bits) null else "sext";
            },
        };
        const op = operation orelse {
            if (!std.mem.eql(u8, operand.ty, target_ty)) return error.InvalidBody;
            return .{ .ty = target_ty, .spelling = operand.spelling };
        };
        const result = try self.temp();
        try self.output.print(self.allocator, "  {s} = {s} {s} {s} to {s}\n", .{ result, op, operand.ty, operand.spelling, target_ty });
        return .{ .ty = target_ty, .spelling = result };
    }

    fn emitTrapConversion(
        self: *Renderer,
        expression: mir.ExecutableExpression,
        call: @FieldType(mir.ExecutableExpression.Operation, "builtin_call"),
        operand: Value,
    ) RenderError!Value {
        const source_ty = self.body.expressions[call.arguments[0].index()].result_ty;
        const conversion = mir.executableTrapConversion(source_ty, expression.result_ty) orelse return error.InvalidBody;
        const target_ty = try self.typeText(expression.result_ty);
        const edge = builtinTrapConversionEdge(self.body, expression) orelse return error.InvalidBody;
        var out_of_range: ?[]const u8 = null;
        if (conversion.need_lower) {
            const below = try self.temp();
            try self.output.print(self.allocator, "  {s} = icmp slt {s} {s}, {d}\n", .{
                below,
                operand.ty,
                operand.spelling,
                if (conversion.target.signed) signedMinimum(conversion.target.bits) else @as(i128, 0),
            });
            out_of_range = below;
        }
        if (conversion.need_upper) {
            const above = try self.temp();
            if (conversion.target.signed)
                try self.output.print(self.allocator, "  {s} = icmp {s} {s} {s}, {d}\n", .{
                    above,
                    if (conversion.source.signed) "sgt" else "ugt",
                    operand.ty,
                    operand.spelling,
                    signedMaximum(conversion.target.bits),
                })
            else
                try self.output.print(self.allocator, "  {s} = icmp {s} {s} {s}, {d}\n", .{
                    above,
                    if (conversion.source.signed) "sgt" else "ugt",
                    operand.ty,
                    operand.spelling,
                    unsignedMaximum(conversion.target.bits),
                });
            if (out_of_range) |below| {
                const combined = try self.temp();
                try self.output.print(self.allocator, "  {s} = or i1 {s}, {s}\n", .{ combined, below, above });
                out_of_range = combined;
            } else out_of_range = above;
        }
        if (out_of_range) |condition| {
            const continuation = try std.fmt.allocPrint(self.allocator, "mc_conversion_ready_{d}", .{expression.id.raw});
            try self.output.print(
                self.allocator,
                "  br i1 {s}, label %mc_block_{d}, label %{s}\n" ++
                    "{s}:\n",
                .{ condition, edge.trap_block.raw, continuation, continuation },
            );
        }
        if (conversion.source.bits == conversion.target.bits) {
            if (!std.mem.eql(u8, operand.ty, target_ty)) return error.InvalidBody;
            return .{ .ty = target_ty, .spelling = operand.spelling };
        }
        const result = try self.temp();
        const operation: []const u8 = if (conversion.target.bits < conversion.source.bits)
            "trunc"
        else if (conversion.source.signed)
            "sext"
        else
            "zext";
        try self.output.print(self.allocator, "  {s} = {s} {s} {s} to {s}\n", .{ result, operation, operand.ty, operand.spelling, target_ty });
        return .{ .ty = target_ty, .spelling = result };
    }

    fn emitBinary(self: *Renderer, expression: mir.ExecutableExpression, result_ty: []const u8, binary: anytype) RenderError!Value {
        if (binary.arithmetic == .unchecked) {
            try self.output.print(self.allocator, "  ; mir range_fact consumed region={} op={s} assumption=no_overflow\n", .{
                binary.contract_region_id orelse return error.InvalidBody,
                switch (binary.op) {
                    .add => "add",
                    .sub => "sub",
                    .mul => "mul",
                    else => return error.InvalidBody,
                },
            });
        }
        const left = try self.emitExpression(binary.left);
        const right = try self.emitExpression(binary.right);
        if (!std.mem.eql(u8, left.ty, right.ty)) return error.InvalidBody;
        if (optionalNullComparison(self.body, expression, binary)) {
            const left_expression = self.body.expressions[binary.left.index()];
            const optional_value = if (left_expression.operation == .optional_none) right else left;
            const present = try self.temp();
            try self.output.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ present, optional_value.ty, optional_value.spelling });
            if (binary.op == .ne) return .{ .ty = "i1", .spelling = present };
            const absent = try self.temp();
            try self.output.print(self.allocator, "  {s} = xor i1 {s}, true\n", .{ absent, present });
            return .{ .ty = "i1", .spelling = absent };
        }
        const operand_ty = self.body.expressions[binary.left.index()].result_ty;
        if (isFloatType(operand_ty)) {
            if (binary.arithmetic != .ordinary) return error.InvalidBody;
            const value = try self.temp();
            const operation: []const u8 = switch (binary.op) {
                .add => "fadd",
                .sub => "fsub",
                .mul => "fmul",
                .div => "fdiv",
                .eq, .ne, .lt, .le, .gt, .ge => "fcmp",
                else => return error.Unsupported,
            };
            if (std.mem.eql(u8, operation, "fcmp")) {
                if (!std.mem.eql(u8, result_ty, "i1")) return error.InvalidBody;
                try self.output.print(self.allocator, "  {s} = fcmp {s} {s} {s}, {s}\n", .{
                    value,
                    floatComparisonPredicate(binary.op),
                    left.ty,
                    left.spelling,
                    right.spelling,
                });
            } else {
                if (!std.mem.eql(u8, result_ty, left.ty)) return error.InvalidBody;
                try self.output.print(self.allocator, "  {s} = {s} {s} {s}, {s}\n", .{ value, operation, left.ty, left.spelling, right.spelling });
            }
            return .{ .ty = result_ty, .spelling = value };
        }
        if (binary.arithmetic == .checked) {
            if (!std.mem.eql(u8, result_ty, left.ty)) return error.InvalidBody;
            return switch (binary.op) {
                .add, .sub, .mul => self.emitCheckedOverflowBinary(expression, result_ty, binary.op, left, right),
                .div, .mod => self.emitCheckedDivMod(expression, result_ty, binary.op, left, right),
                .shl, .shr => self.emitCheckedShift(expression, result_ty, binary.op, left, right),
                else => error.InvalidBody,
            };
        }
        if (binary.arithmetic == .saturating) return self.emitSaturatingBinary(expression, result_ty, binary.op, left, right);
        if (binary.arithmetic == .wrapping and (binary.op == .shl or binary.op == .shr))
            return self.emitWrappingShift(expression, result_ty, binary.op, left, right);
        const value = try self.temp();
        const operation: []const u8 = switch (binary.op) {
            .logical_or => "or",
            .logical_and => "and",
            .add => "add",
            .sub => "sub",
            .mul => "mul",
            .bit_or => "or",
            .bit_xor => "xor",
            .bit_and => "and",
            .eq, .ne, .lt, .le, .gt, .ge => "icmp",
            else => return error.Unsupported,
        };
        if (std.mem.eql(u8, operation, "icmp")) {
            if (!std.mem.eql(u8, result_ty, "i1")) return error.InvalidBody;
            const predicate = comparisonPredicate(binary.op, self.body.expressions[binary.left.index()].result_ty);
            try self.output.print(self.allocator, "  {s} = icmp {s} {s} {s}, {s}\n", .{ value, predicate, left.ty, left.spelling, right.spelling });
        } else {
            if (!std.mem.eql(u8, result_ty, left.ty)) return error.InvalidBody;
            try self.output.print(self.allocator, "  {s} = {s} {s} {s}, {s}\n", .{ value, operation, left.ty, left.spelling, right.spelling });
        }
        return .{ .ty = result_ty, .spelling = value };
    }

    fn emitSaturatingBinary(
        self: *Renderer,
        expression: mir.ExecutableExpression,
        result_ty: []const u8,
        op_kind: mir.ExecutableBinaryOp,
        left: Value,
        right: Value,
    ) RenderError!Value {
        const domain = domainInteger(expression.result_ty, .sat) orelse return error.InvalidBody;
        const info = integerInfo(domain.child) orelse return error.InvalidBody;
        if (info.signed or !std.mem.eql(u8, result_ty, left.ty) or !std.mem.eql(u8, left.ty, right.ty)) return error.InvalidBody;
        const op: []const u8 = switch (op_kind) {
            .add => "add",
            .sub => "sub",
            .mul => "mul",
            else => return error.InvalidBody,
        };
        const pair = try self.temp();
        const value = try self.temp();
        const overflow = try self.temp();
        const result = try self.temp();
        const saturation: u128 = if (op_kind == .sub) 0 else info.max;
        try self.output.print(
            self.allocator,
            "  {s} = call {{ {s}, i1 }} @llvm.u{s}.with.overflow.{s}({s} {s}, {s} {s})\n" ++
                "  {s} = extractvalue {{ {s}, i1 }} {s}, 0\n" ++
                "  {s} = extractvalue {{ {s}, i1 }} {s}, 1\n" ++
                "  {s} = select i1 {s}, {s} {d}, {s} {s}\n",
            .{ pair, result_ty, op, result_ty, left.ty, left.spelling, right.ty, right.spelling, value, result_ty, pair, overflow, result_ty, pair, result, overflow, result_ty, saturation, result_ty, value },
        );
        return .{ .ty = result_ty, .spelling = result };
    }

    fn emitWrappingShift(
        self: *Renderer,
        expression: mir.ExecutableExpression,
        result_ty: []const u8,
        op_kind: mir.ExecutableBinaryOp,
        left: Value,
        right: Value,
    ) RenderError!Value {
        const domain = domainInteger(expression.result_ty, .wrap) orelse return error.InvalidBody;
        const info = integerInfo(domain.child) orelse return error.InvalidBody;
        if (info.bits == 0 or !std.mem.eql(u8, result_ty, left.ty) or !std.mem.eql(u8, left.ty, right.ty)) return error.InvalidBody;
        const masked = try self.temp();
        const result = try self.temp();
        try self.output.print(self.allocator, "  {s} = and {s} {s}, {d}\n", .{ masked, right.ty, right.spelling, info.bits - 1 });
        const operation: []const u8 = switch (op_kind) {
            .shl => "shl",
            .shr => if (info.signed) "ashr" else "lshr",
            else => return error.InvalidBody,
        };
        try self.output.print(self.allocator, "  {s} = {s} {s} {s}, {s}\n", .{ result, operation, result_ty, left.spelling, masked });
        return .{ .ty = result_ty, .spelling = result };
    }

    fn emitCheckedOverflowBinary(
        self: *Renderer,
        expression: mir.ExecutableExpression,
        result_ty: []const u8,
        op_kind: mir.ExecutableBinaryOp,
        left: Value,
        right: Value,
    ) RenderError!Value {
        const edge = checkedTrapEdge(self.body, expression, .{ .kind = .IntegerOverflow, .source = .checked_arithmetic }) orelse return error.InvalidBody;
        const op: []const u8 = switch (op_kind) {
            .add => "add",
            .sub => "sub",
            .mul => "mul",
            else => return error.InvalidBody,
        };
        const signedness: []const u8 = if (integerTypeSigned(expression.result_ty)) "s" else "u";
        const pair = try self.temp();
        const value = try self.temp();
        const overflow = try self.temp();
        const continuation = try std.fmt.allocPrint(self.allocator, "mc_checked_cont_{d}", .{expression.id.raw});
        try self.output.print(
            self.allocator,
            "  {s} = call {{ {s}, i1 }} @llvm.{s}{s}.with.overflow.{s}({s} {s}, {s} {s})\n" ++
                "  {s} = extractvalue {{ {s}, i1 }} {s}, 0\n" ++
                "  {s} = extractvalue {{ {s}, i1 }} {s}, 1\n" ++
                "  br i1 {s}, label %mc_block_{d}, label %{s}\n" ++
                "{s}:\n",
            .{ pair, result_ty, signedness, op, result_ty, left.ty, left.spelling, right.ty, right.spelling, value, result_ty, pair, overflow, result_ty, pair, overflow, edge.trap_block.raw, continuation, continuation },
        );
        return .{ .ty = result_ty, .spelling = value };
    }

    fn emitCheckedDivMod(
        self: *Renderer,
        expression: mir.ExecutableExpression,
        result_ty: []const u8,
        op_kind: mir.ExecutableBinaryOp,
        left: Value,
        right: Value,
    ) RenderError!Value {
        const zero_edge = checkedTrapEdge(self.body, expression, .{ .kind = .DivideByZero, .source = .checked_arithmetic }) orelse return error.InvalidBody;
        const after_zero = try std.fmt.allocPrint(self.allocator, "mc_checked_nonzero_{d}", .{expression.id.raw});
        const divisor_zero = try self.temp();
        try self.output.print(
            self.allocator,
            "  {s} = icmp eq {s} {s}, 0\n" ++
                "  br i1 {s}, label %mc_block_{d}, label %{s}\n" ++
                "{s}:\n",
            .{ divisor_zero, right.ty, right.spelling, divisor_zero, zero_edge.trap_block.raw, after_zero, after_zero },
        );

        const signed = integerTypeSigned(expression.result_ty);
        if (signed) {
            const overflow_edge = checkedTrapEdge(self.body, expression, .{ .kind = .IntegerOverflow, .source = .checked_arithmetic }) orelse return error.InvalidBody;
            const info = mir.ExecutableCastKind.integerInfo(expression.result_ty) orelse return error.InvalidBody;
            const minimum = signedMinimumLiteral(info.bits) orelse return error.Unsupported;
            const is_minimum = try self.temp();
            const is_negative_one = try self.temp();
            const overflow = try self.temp();
            const after_overflow = try std.fmt.allocPrint(self.allocator, "mc_checked_div_ready_{d}", .{expression.id.raw});
            try self.output.print(
                self.allocator,
                "  {s} = icmp eq {s} {s}, {s}\n" ++
                    "  {s} = icmp eq {s} {s}, -1\n" ++
                    "  {s} = and i1 {s}, {s}\n" ++
                    "  br i1 {s}, label %mc_block_{d}, label %{s}\n" ++
                    "{s}:\n",
                .{ is_minimum, left.ty, left.spelling, minimum, is_negative_one, right.ty, right.spelling, overflow, is_minimum, is_negative_one, overflow, overflow_edge.trap_block.raw, after_overflow, after_overflow },
            );
        }

        const value = try self.temp();
        const operation: []const u8 = switch (op_kind) {
            .div => if (signed) "sdiv" else "udiv",
            .mod => if (signed) "srem" else "urem",
            else => return error.InvalidBody,
        };
        try self.output.print(self.allocator, "  {s} = {s} {s} {s}, {s}\n", .{ value, operation, result_ty, left.spelling, right.spelling });
        return .{ .ty = result_ty, .spelling = value };
    }

    fn emitCheckedShift(
        self: *Renderer,
        expression: mir.ExecutableExpression,
        result_ty: []const u8,
        op_kind: mir.ExecutableBinaryOp,
        left: Value,
        right: Value,
    ) RenderError!Value {
        const shift_edge = checkedTrapEdge(self.body, expression, .{ .kind = .InvalidShift, .source = .checked_shift }) orelse return error.InvalidBody;
        const info = mir.ExecutableCastKind.integerInfo(expression.result_ty) orelse return error.InvalidBody;
        const invalid_shift = try self.temp();
        const in_range = try std.fmt.allocPrint(self.allocator, "mc_checked_shift_range_{d}", .{expression.id.raw});
        // `uge` also rejects a negative signed shift count because its unsigned
        // representation is necessarily greater than the bit width.
        try self.output.print(
            self.allocator,
            "  {s} = icmp uge {s} {s}, {d}\n" ++
                "  br i1 {s}, label %mc_block_{d}, label %{s}\n" ++
                "{s}:\n",
            .{ invalid_shift, right.ty, right.spelling, info.bits, invalid_shift, shift_edge.trap_block.raw, in_range, in_range },
        );

        if (op_kind == .shr) {
            const value = try self.temp();
            try self.output.print(self.allocator, "  {s} = {s} {s} {s}, {s}\n", .{ value, if (info.signed) "ashr" else "lshr", result_ty, left.spelling, right.spelling });
            return .{ .ty = result_ty, .spelling = value };
        }
        if (op_kind != .shl) return error.InvalidBody;

        const overflow_edge = checkedTrapEdge(self.body, expression, .{ .kind = .IntegerOverflow, .source = .checked_arithmetic }) orelse return error.InvalidBody;
        const wide_bits: u16 = info.bits * 2;
        const wide_ty = try std.fmt.allocPrint(self.allocator, "i{d}", .{wide_bits});
        const wide_left = try self.temp();
        const wide_right = try self.temp();
        const wide_shifted = try self.temp();
        const value = try self.temp();
        const round_trip = try self.temp();
        const overflow = try self.temp();
        const continuation = try std.fmt.allocPrint(self.allocator, "mc_checked_shift_ready_{d}", .{expression.id.raw});
        const extension: []const u8 = if (info.signed) "sext" else "zext";
        try self.output.print(
            self.allocator,
            "  {s} = {s} {s} {s} to {s}\n" ++
                "  {s} = zext {s} {s} to {s}\n" ++
                "  {s} = shl {s} {s}, {s}\n" ++
                "  {s} = trunc {s} {s} to {s}\n" ++
                "  {s} = {s} {s} {s} to {s}\n" ++
                "  {s} = icmp ne {s} {s}, {s}\n" ++
                "  br i1 {s}, label %mc_block_{d}, label %{s}\n" ++
                "{s}:\n",
            .{ wide_left, extension, left.ty, left.spelling, wide_ty, wide_right, right.ty, right.spelling, wide_ty, wide_shifted, wide_ty, wide_left, wide_right, value, wide_ty, wide_shifted, result_ty, round_trip, extension, result_ty, value, wide_ty, overflow, wide_ty, wide_shifted, round_trip, overflow, overflow_edge.trap_block.raw, continuation, continuation },
        );
        return .{ .ty = result_ty, .spelling = value };
    }

    fn emitDirectCall(self: *Renderer, expression: mir.ExecutableExpression, ty: []const u8, call: anytype) RenderError!Value {
        const symbol = symbolSpelling(self.body, call.callee) orelse return error.InvalidBody;
        const abi = if (self.call_abi_plan) |plan| directCallAbiFor(plan.*, expression.id) orelse return error.InvalidBody else null;
        return self.emitCall(ty, try std.fmt.allocPrint(self.allocator, "@{s}", .{symbol}), call.arguments[0..call.argument_count], abi);
    }

    fn emitIndirectCall(self: *Renderer, ty: []const u8, call: anytype) RenderError!Value {
        const callee = try self.emitExpression(call.callee);
        if (!std.mem.eql(u8, callee.ty, "ptr")) return error.InvalidBody;
        return self.emitCall(ty, callee.spelling, call.arguments[0..call.argument_count], null);
    }

    fn emitBuiltinCall(self: *Renderer, expression: mir.ExecutableExpression, call: anytype) RenderError!Value {
        if (!builtinSupported(self.body, expression, call)) return error.InvalidBody;
        var operands: [mir.max_executable_operands]Value = undefined;
        for (call.arguments[0..call.argument_count], 0..) |id, index| operands[index] = try self.emitExpression(id);
        const result_ty = try self.typeText(expression.result_ty);
        return switch (call.kind) {
            .phys => {
                const operand = operands[0];
                if (!std.mem.eql(u8, operand.ty, result_ty)) return error.Unsupported;
                return .{ .ty = result_ty, .spelling = operand.spelling };
            },
            .wrapping_add => {
                const left = operands[0];
                const right = operands[1];
                if (!std.mem.eql(u8, left.ty, result_ty) or !std.mem.eql(u8, right.ty, result_ty)) return error.InvalidBody;
                const result = try self.temp();
                try self.output.print(self.allocator, "  {s} = add {s} {s}, {s}\n", .{ result, result_ty, left.spelling, right.spelling });
                return .{ .ty = result_ty, .spelling = result };
            },
            .wrap_residue, .enum_raw => {
                const operand = operands[0];
                if (!std.mem.eql(u8, operand.ty, result_ty)) return error.InvalidBody;
                return .{ .ty = result_ty, .spelling = operand.spelling };
            },
            .serial_before, .serial_after => {
                const left = operands[0];
                const right = operands[1];
                if (!std.mem.eql(u8, left.ty, right.ty)) return error.InvalidBody;
                const difference = try self.temp();
                const result = try self.temp();
                try self.output.print(self.allocator, "  {s} = sub {s} {s}, {s}\n", .{ difference, left.ty, left.spelling, right.spelling });
                try self.output.print(self.allocator, "  {s} = icmp {s} {s} {s}, 0\n", .{ result, if (call.kind == .serial_before) "slt" else "sgt", left.ty, difference });
                return .{ .ty = "i1", .spelling = result };
            },
            .serial_distance, .counter_delta_mod => {
                const left = operands[0];
                const right = operands[1];
                if (!std.mem.eql(u8, left.ty, result_ty) or !std.mem.eql(u8, right.ty, result_ty)) return error.InvalidBody;
                const result = try self.temp();
                try self.output.print(self.allocator, "  {s} = sub {s} {s}, {s}\n", .{ result, result_ty, left.spelling, right.spelling });
                return .{ .ty = result_ty, .spelling = result };
            },
            .serial_compare => return self.emitSerialCompareCall(expression, call, operands[0], operands[1]),
            .counter_elapsed_bounded => return self.emitCounterElapsedBoundedCall(expression, call, operands[0], operands[1], operands[2]),
            .conversion_from, .conversion_wrap_from, .conversion_from_mod => return self.emitIntegerConversion(expression, call, operands[0]),
            .conversion_try_from => return self.emitTryConversionCall(expression, call, operands[0]),
            .conversion_sat_from => return self.emitSaturatingConversionCall(expression, call, operands[0]),
            .conversion_trap_from => return self.emitTrapConversion(expression, call, operands[0]),
            .bitcast => {
                const operand = operands[0];
                const source_ty = self.body.expressions[call.arguments[0].index()].result_ty;
                if (!pureScalarBitcastTypesSupported(source_ty, expression.result_ty)) return error.InvalidBody;
                if (std.mem.eql(u8, operand.ty, result_ty)) return .{ .ty = result_ty, .spelling = operand.spelling };
                const result = try self.temp();
                try self.output.print(self.allocator, "  {s} = bitcast {s} {s} to {s}\n", .{ result, operand.ty, operand.spelling, result_ty });
                return .{ .ty = result_ty, .spelling = result };
            },
            .raw_many_offset => {
                const pointer_shape = switch (expression.result_ty) {
                    .pointer => |shape| shape,
                    else => return error.InvalidBody,
                };
                if (pointer_shape.kind != .raw_many or !std.mem.eql(u8, result_ty, "ptr") or
                    !std.mem.eql(u8, operands[0].ty, "ptr") or !std.mem.eql(u8, operands[1].ty, "i64"))
                    return error.InvalidBody;
                const element_ty = rawManyElementValueType(self.body, pointer_shape.child) orelse return error.Unsupported;
                const element_text = try self.typeText(element_ty);
                const result = try self.temp();
                try self.output.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 {s}\n", .{ result, element_text, operands[0].spelling, operands[1].spelling });
                return .{ .ty = "ptr", .spelling = result };
            },
            .raw_load => {
                const address = operands[0];
                if (!std.mem.eql(u8, address.ty, "i64") or scalarLlvmType(expression.result_ty) == null) return error.InvalidBody;
                const pointer = try self.temp();
                const result = try self.temp();
                try self.output.print(self.allocator, "  {s} = inttoptr i64 {s} to ptr\n", .{ pointer, address.spelling });
                try self.output.print(self.allocator, "  {s} = load volatile {s}, ptr {s}\n", .{ result, result_ty, pointer });
                return .{ .ty = result_ty, .spelling = result };
            },
            .raw_ptr => {
                const address = operands[0];
                if (!std.mem.eql(u8, address.ty, "i64") or !std.mem.eql(u8, result_ty, "ptr")) return error.InvalidBody;
                const result = try self.temp();
                try self.output.print(self.allocator, "  {s} = inttoptr i64 {s} to ptr\n", .{ result, address.spelling });
                const edge = representationTrapEdge(self.body, expression) orelse return error.InvalidBody;
                const continuation = try std.fmt.allocPrint(self.allocator, "mc_raw_ptr_ready_{d}", .{expression.id.raw});
                try self.emitPointerRepresentationGuard(result, edge, continuation);
                return .{ .ty = "ptr", .spelling = result };
            },
            .raw_store => {
                const address = operands[0];
                const value = operands[1];
                if (!std.mem.eql(u8, result_ty, "void") or !std.mem.eql(u8, address.ty, "i64") or
                    scalarLlvmType(self.body.expressions[call.arguments[1].index()].result_ty) == null)
                    return error.InvalidBody;
                const pointer = try self.temp();
                try self.output.print(self.allocator, "  {s} = inttoptr i64 {s} to ptr\n", .{ pointer, address.spelling });
                try self.output.print(self.allocator, "  store volatile {s} {s}, ptr {s}\n", .{ value.ty, value.spelling, pointer });
                return .{ .ty = "void", .spelling = "" };
            },
            .forget_unchecked => {
                // `operands` were rendered above in source order.  Forgetting
                // consumes the ownership obligation but has no LLVM runtime
                // operation and, in particular, must not invoke drop glue.
                if (!std.mem.eql(u8, result_ty, "void") or call.argument_count != 1) return error.InvalidBody;
                return .{ .ty = "void", .spelling = "" };
            },
            .cpu_pause => {
                if (!std.mem.eql(u8, result_ty, "void") or call.argument_count != 0) return error.InvalidBody;
                try self.output.appendSlice(self.allocator, "  call void asm sideeffect \"pause\", \"~{memory}\"()\n");
                return .{ .ty = "void", .spelling = "" };
            },
            .fence_full, .fence_release, .fence_acquire => {
                if (!std.mem.eql(u8, result_ty, "void")) return error.InvalidBody;
                const ordering: []const u8 = switch (call.kind) {
                    .fence_full => "seq_cst",
                    .fence_release => "release",
                    .fence_acquire => "acquire",
                    else => unreachable,
                };
                try self.output.print(self.allocator, "  fence {s}\n", .{ordering});
                return .{ .ty = "void", .spelling = "" };
            },
            else => return error.Unsupported,
        };
    }

    fn emitIntegerConversion(
        self: *Renderer,
        expression: mir.ExecutableExpression,
        call: @FieldType(mir.ExecutableExpression.Operation, "builtin_call"),
        operand: Value,
    ) RenderError!Value {
        const source_ty = self.body.expressions[call.arguments[0].index()].result_ty;
        const conversion = mir.executableIntegerConversion(source_ty, expression.result_ty) orelse return error.InvalidBody;
        const target_ty = try self.typeText(expression.result_ty);
        if (conversion.source.bits == conversion.target.bits) {
            if (!std.mem.eql(u8, operand.ty, target_ty)) return error.InvalidBody;
            return .{ .ty = target_ty, .spelling = operand.spelling };
        }
        const result = try self.temp();
        const operation: []const u8 = if (conversion.target.bits < conversion.source.bits)
            "trunc"
        else if (conversion.source.signed)
            "sext"
        else
            "zext";
        try self.output.print(self.allocator, "  {s} = {s} {s} {s} to {s}\n", .{ result, operation, operand.ty, operand.spelling, target_ty });
        return .{ .ty = target_ty, .spelling = result };
    }

    fn emitSaturatingConversionCall(
        self: *Renderer,
        expression: mir.ExecutableExpression,
        call: @FieldType(mir.ExecutableExpression.Operation, "builtin_call"),
        operand: Value,
    ) RenderError!Value {
        const source_ty = self.body.expressions[call.arguments[0].index()].result_ty;
        const conversion = mir.executableTrapConversion(source_ty, expression.result_ty) orelse return error.InvalidBody;
        var clamped = operand;
        if (conversion.need_lower) {
            const below = try self.temp();
            const selected = try self.temp();
            const minimum = if (conversion.target.signed) signedMinimum(conversion.target.bits) else @as(i128, 0);
            try self.output.print(self.allocator, "  {s} = icmp slt {s} {s}, {d}\n", .{ below, operand.ty, operand.spelling, minimum });
            try self.output.print(self.allocator, "  {s} = select i1 {s}, {s} {d}, {s} {s}\n", .{ selected, below, operand.ty, minimum, operand.ty, clamped.spelling });
            clamped = .{ .ty = operand.ty, .spelling = selected };
        }
        if (conversion.need_upper) {
            const above = try self.temp();
            const selected = try self.temp();
            const maximum: u128 = if (conversion.target.signed)
                @intCast(signedMaximum(conversion.target.bits))
            else
                unsignedMaximum(conversion.target.bits);
            try self.output.print(self.allocator, "  {s} = icmp {s} {s} {s}, {d}\n", .{
                above,
                if (conversion.source.signed) "sgt" else "ugt",
                operand.ty,
                operand.spelling,
                maximum,
            });
            try self.output.print(self.allocator, "  {s} = select i1 {s}, {s} {d}, {s} {s}\n", .{ selected, above, operand.ty, maximum, operand.ty, clamped.spelling });
            clamped = .{ .ty = operand.ty, .spelling = selected };
        }
        return self.emitIntegerConversion(expression, call, clamped);
    }

    fn emitTryConversionCall(
        self: *Renderer,
        expression: mir.ExecutableExpression,
        call: @FieldType(mir.ExecutableExpression.Operation, "builtin_call"),
        operand: Value,
    ) RenderError!Value {
        const shape = resultType(self.body, expression.type_id) orelse return error.InvalidBody;
        const source_ty = self.body.expressions[call.arguments[0].index()].result_ty;
        const conversion = mir.executableTrapConversion(source_ty, shape.ok_ty) orelse return error.InvalidBody;
        const ok_ty = try self.typeText(shape.ok_ty);

        const converted = if (conversion.source.bits == conversion.target.bits)
            operand
        else converted: {
            const value = try self.temp();
            const operation: []const u8 = if (conversion.target.bits < conversion.source.bits)
                "trunc"
            else if (conversion.source.signed)
                "sext"
            else
                "zext";
            try self.output.print(self.allocator, "  {s} = {s} {s} {s} to {s}\n", .{ value, operation, operand.ty, operand.spelling, ok_ty });
            break :converted Value{ .ty = ok_ty, .spelling = value };
        };
        if (!std.mem.eql(u8, converted.ty, ok_ty)) return error.InvalidBody;

        var out_of_range: ?[]const u8 = null;
        if (conversion.need_lower) {
            const below = try self.temp();
            try self.output.print(self.allocator, "  {s} = icmp slt {s} {s}, {d}\n", .{
                below,
                operand.ty,
                operand.spelling,
                if (conversion.target.signed) signedMinimum(conversion.target.bits) else @as(i128, 0),
            });
            out_of_range = below;
        }
        if (conversion.need_upper) {
            const above = try self.temp();
            try self.output.print(self.allocator, "  {s} = icmp {s} {s} {s}, {d}\n", .{
                above,
                if (conversion.source.signed) "sgt" else "ugt",
                operand.ty,
                operand.spelling,
                if (conversion.target.signed)
                    @as(u128, @intCast(signedMaximum(conversion.target.bits)))
                else
                    unsignedMaximum(conversion.target.bits),
            });
            if (out_of_range) |below| {
                const combined = try self.temp();
                try self.output.print(self.allocator, "  {s} = or i1 {s}, {s}\n", .{ combined, below, above });
                out_of_range = combined;
            } else out_of_range = above;
        }

        const is_ok = if (out_of_range) |condition| ok: {
            const value = try self.temp();
            try self.output.print(self.allocator, "  {s} = xor i1 {s}, true\n", .{ value, condition });
            break :ok value;
        } else "true";
        const result_ty = try self.typeText(expression.result_ty);
        const tagged = try self.temp();
        const result = try self.temp();
        try self.output.print(self.allocator, "  {s} = insertvalue {s} zeroinitializer, i1 {s}, 0\n", .{ tagged, result_ty, is_ok });
        try self.output.print(self.allocator, "  {s} = insertvalue {s} {s}, {s} {s}, 1\n", .{ result, result_ty, tagged, ok_ty, converted.spelling });
        return .{ .ty = result_ty, .spelling = result };
    }

    fn emitSerialCompareCall(
        self: *Renderer,
        expression: mir.ExecutableExpression,
        call: @FieldType(mir.ExecutableExpression.Operation, "builtin_call"),
        left: Value,
        right: Value,
    ) RenderError!Value {
        const domain = domainInteger(self.body.expressions[call.arguments[0].index()].result_ty, .serial) orelse return error.InvalidBody;
        const storage = mir.ExecutableCastKind.integerInfo(.{ .integer = domain.child }) orelse return error.InvalidBody;
        if (storage.signed or storage.bits > 64 or !std.mem.eql(u8, left.ty, right.ty)) return error.InvalidBody;
        const shape = resultType(self.body, expression.type_id) orelse return error.InvalidBody;
        const result_ty = try self.typeText(expression.result_ty);
        const ok_ty = try self.typeText(shape.ok_ty);
        if (!std.mem.eql(u8, ok_ty, "i8")) return error.InvalidBody;

        const difference = try self.temp();
        const ambiguous = try self.temp();
        const not_ambiguous = try self.temp();
        const is_less = try self.temp();
        const is_greater = try self.temp();
        const nonnegative_order = try self.temp();
        const order = try self.temp();
        const selected_order = try self.temp();
        const tagged = try self.temp();
        const result = try self.temp();
        const half_window = @as(u128, 1) << @intCast(storage.bits - 1);
        try self.output.print(self.allocator, "  {s} = sub {s} {s}, {s}\n", .{ difference, left.ty, left.spelling, right.spelling });
        try self.output.print(self.allocator, "  {s} = icmp eq {s} {s}, {d}\n", .{ ambiguous, left.ty, difference, half_window });
        try self.output.print(self.allocator, "  {s} = xor i1 {s}, true\n", .{ not_ambiguous, ambiguous });
        try self.output.print(self.allocator, "  {s} = icmp slt {s} {s}, 0\n", .{ is_less, left.ty, difference });
        try self.output.print(self.allocator, "  {s} = icmp sgt {s} {s}, 0\n", .{ is_greater, left.ty, difference });
        try self.output.print(self.allocator, "  {s} = select i1 {s}, i8 1, i8 0\n", .{ nonnegative_order, is_greater });
        try self.output.print(self.allocator, "  {s} = select i1 {s}, i8 -1, i8 {s}\n", .{ order, is_less, nonnegative_order });
        try self.output.print(self.allocator, "  {s} = select i1 {s}, i8 0, i8 {s}\n", .{ selected_order, ambiguous, order });
        try self.output.print(self.allocator, "  {s} = insertvalue {s} zeroinitializer, i1 {s}, 0\n", .{ tagged, result_ty, not_ambiguous });
        try self.output.print(self.allocator, "  {s} = insertvalue {s} {s}, i8 {s}, 1\n", .{ result, result_ty, tagged, selected_order });
        return .{ .ty = result_ty, .spelling = result };
    }

    fn emitCounterElapsedBoundedCall(
        self: *Renderer,
        expression: mir.ExecutableExpression,
        call: @FieldType(mir.ExecutableExpression.Operation, "builtin_call"),
        now: Value,
        start: Value,
        maximum: Value,
    ) RenderError!Value {
        const counter = domainInteger(self.body.expressions[call.arguments[0].index()].result_ty, .counter) orelse return error.InvalidBody;
        const shape = resultType(self.body, expression.type_id) orelse return error.InvalidBody;
        const duration = domainInteger(shape.ok_ty, .duration) orelse return error.InvalidBody;
        if (!std.mem.eql(u8, counter.child, duration.child) or !std.mem.eql(u8, now.ty, start.ty) or
            !std.mem.eql(u8, now.ty, maximum.ty))
            return error.InvalidBody;
        const result_ty = try self.typeText(expression.result_ty);
        const difference = try self.temp();
        const in_range = try self.temp();
        const selected = try self.temp();
        const tagged = try self.temp();
        const result = try self.temp();
        try self.output.print(self.allocator, "  {s} = sub {s} {s}, {s}\n", .{ difference, now.ty, now.spelling, start.spelling });
        try self.output.print(self.allocator, "  {s} = icmp ule {s} {s}, {s}\n", .{ in_range, now.ty, difference, maximum.spelling });
        try self.output.print(self.allocator, "  {s} = select i1 {s}, {s} {s}, {s} 0\n", .{ selected, in_range, now.ty, difference, now.ty });
        try self.output.print(self.allocator, "  {s} = insertvalue {s} zeroinitializer, i1 {s}, 0\n", .{ tagged, result_ty, in_range });
        try self.output.print(self.allocator, "  {s} = insertvalue {s} {s}, {s} {s}, 1\n", .{ result, result_ty, tagged, now.ty, selected });
        return .{ .ty = result_ty, .spelling = result };
    }

    fn emitCall(self: *Renderer, ty: []const u8, callee: []const u8, arguments: []const mir.ExprId, abi: ?DirectCallAbi) RenderError!Value {
        var rendered: std.ArrayList(u8) = .empty;
        defer rendered.deinit(self.allocator);
        for (arguments, 0..) |argument_id, index| {
            const argument = try self.emitExpression(argument_id);
            if (index != 0) try rendered.appendSlice(self.allocator, ", ");
            const extension = if (abi) |entry| entry.parameter_extensions[index].parameterSuffix() else "";
            try rendered.print(self.allocator, "{s}{s} {s}", .{ argument.ty, extension, argument.spelling });
        }
        const result_extension = if (abi) |entry| entry.result_extension.resultPrefix() else "";
        if (std.mem.eql(u8, ty, "void")) {
            try self.output.print(self.allocator, "  call void {s}({s})\n", .{ callee, rendered.items });
            return .{ .ty = "void", .spelling = "" };
        }
        const result = try self.temp();
        try self.output.print(self.allocator, "  {s} = call {s}{s} {s}({s})\n", .{ result, result_extension, ty, callee, rendered.items });
        return .{ .ty = ty, .spelling = result };
    }

    fn emitMemoryLoad(self: *Renderer, expression: mir.ExecutableExpression, load: anytype) RenderError!Value {
        if (!memoryAccessSupported(self.body, load.place, expression.result_ty, load.access, false)) return error.InvalidBody;
        const value_ty = try self.typeText(expression.result_ty);
        const place = self.body.places[load.place.index()];
        const pointer = if (mir.executableFixedArrayIndexPlace(self.body, place) != null)
            try self.emitFixedArrayIndexPlacePointer(place, .{ .expression = expression.id })
        else if (computedRawManyDerefPlaceSupported(self.body, place, false))
            try self.emitComputedRawManyDerefPointer(place)
        else if (mir.executableLocalAddressDerefPlace(self.body, place, false))
            try self.emitGuardedLocalAddressAliasPointer(expression, load.place)
        else if (mir.executableDirectAggregateFieldPlace(
            self.body.locals,
            self.body.statements,
            self.body.aggregate_types,
            place,
            false,
        ) != null)
            try self.emitPlace(load.place, value_ty)
        else if (place.projection_count != 0)
            try self.emitGuardedParameterAccessPointer(expression, load.place)
        else
            try self.emitPlace(load.place, value_ty);
        const byte_sized_bool = expression.result_ty == .bool and
            (placeIsGlobal(self.body, load.place) or load.access.kind == .race_unordered);
        const storage_ty: []const u8 = if (byte_sized_bool) "i8" else value_ty;
        const loaded = try self.temp();
        switch (load.access.kind) {
            .plain => try self.output.print(self.allocator, "  {s} = load {s}, ptr {s}, align {d}\n", .{ loaded, storage_ty, pointer, load.access.alignment }),
            .race_unordered => try self.output.print(self.allocator, "  {s} = load atomic {s}, ptr {s} unordered, align {d}\n", .{ loaded, storage_ty, pointer, load.access.alignment }),
        }
        if (!byte_sized_bool) return .{ .ty = value_ty, .spelling = loaded };
        const converted = try self.temp();
        try self.output.print(self.allocator, "  {s} = trunc i8 {s} to i1\n", .{ converted, loaded });
        return .{ .ty = "i1", .spelling = converted };
    }

    fn emitAtomicLoad(self: *Renderer, expression: mir.ExecutableExpression, load: anytype) RenderError!Value {
        if (!atomicLoadSupported(self.body, expression, load)) return error.InvalidBody;
        const value_ty = try self.typeText(expression.result_ty);
        const pointer = try self.emitAtomicPlacePointer(expression, load.place);
        const storage_ty: []const u8 = if (expression.result_ty == .bool) "i8" else value_ty;
        const loaded = try self.temp();
        try self.output.print(self.allocator, "  {s} = load atomic {s}, ptr {s} {s}, align {d}\n", .{
            loaded,
            storage_ty,
            pointer,
            llvmAtomicOrdering(load.ordering),
            mir.ExecutableMemoryAccess.scalarAlignment(expression.result_ty) orelse return error.InvalidBody,
        });
        if (expression.result_ty != .bool) return .{ .ty = value_ty, .spelling = loaded };
        const converted = try self.temp();
        try self.output.print(self.allocator, "  {s} = trunc i8 {s} to i1\n", .{ converted, loaded });
        return .{ .ty = "i1", .spelling = converted };
    }

    fn emitAtomicUpdate(self: *Renderer, expression: mir.ExecutableExpression, update: anytype) RenderError!Value {
        if (!atomicUpdateSupported(self.body, expression, update)) return error.InvalidBody;
        const place = self.body.places[update.place.index()];
        const payload_ty = try self.typeText(place.ty);
        const operand = try self.emitExpression(update.value);
        const pointer = try self.emitAtomicPlacePointer(expression, update.place);
        var stored = operand.spelling;
        const storage_ty: []const u8 = if (place.ty == .bool) "i8" else payload_ty;
        if (place.ty == .bool) {
            if (!std.mem.eql(u8, operand.ty, "i1")) return error.InvalidBody;
            stored = try self.temp();
            try self.output.print(self.allocator, "  {s} = zext i1 {s} to i8\n", .{ stored, operand.spelling });
        } else if (!std.mem.eql(u8, operand.ty, storage_ty)) return error.InvalidBody;
        if (update.kind == .store) {
            try self.output.print(self.allocator, "  store atomic {s} {s}, ptr {s} {s}, align {d}\n", .{
                storage_ty,
                stored,
                pointer,
                llvmAtomicOrdering(update.ordering),
                mir.ExecutableMemoryAccess.scalarAlignment(place.ty) orelse return error.InvalidBody,
            });
            return .{ .ty = "void", .spelling = "" };
        }
        const old = try self.temp();
        try self.output.print(self.allocator, "  {s} = atomicrmw {s} ptr {s}, {s} {s} {s}\n", .{
            old,
            if (update.kind == .fetch_add) "add" else "sub",
            pointer,
            storage_ty,
            stored,
            llvmAtomicOrdering(update.ordering),
        });
        if (place.ty != .bool) return .{ .ty = payload_ty, .spelling = old };
        const converted = try self.temp();
        try self.output.print(self.allocator, "  {s} = trunc i8 {s} to i1\n", .{ converted, old });
        return .{ .ty = "i1", .spelling = converted };
    }

    fn emitMmioRead(self: *Renderer, expression: mir.ExecutableExpression, read: anytype) RenderError!Value {
        if (!mmioReadSupported(self.body, expression, read)) return error.InvalidBody;
        const storage_ty = try self.typeText(read.storage_ty);
        const pointer = try self.emitMmioPointer(read.base, read.byte_offset);
        const loaded = try self.temp();
        try self.output.print(self.allocator, "  {s} = load volatile {s}, ptr {s}\n", .{ loaded, storage_ty, pointer });
        if (read.ordering == .acquire) try self.output.appendSlice(self.allocator, "  fence acquire\n");
        return .{ .ty = storage_ty, .spelling = loaded };
    }

    fn emitMmioWrite(self: *Renderer, expression: mir.ExecutableExpression, write: anytype) RenderError!Value {
        if (!mmioWriteSupported(self.body, expression, write)) return error.InvalidBody;
        const operand = try self.emitExpression(write.value);
        const storage_ty = try self.typeText(write.storage_ty);
        if (!std.mem.eql(u8, operand.ty, storage_ty)) return error.InvalidBody;
        if (write.ordering == .release) try self.output.appendSlice(self.allocator, "  fence release\n");
        const pointer = try self.emitMmioPointer(write.base, write.byte_offset);
        try self.output.print(self.allocator, "  store volatile {s} {s}, ptr {s}\n", .{ storage_ty, operand.spelling, pointer });
        return .{ .ty = "void", .spelling = "" };
    }

    fn emitMmioPointer(self: *Renderer, base: mir.LocalId, byte_offset: u64) RenderError![]const u8 {
        if (!mmioBaseSupported(self.body, base)) return error.InvalidBody;
        const local = self.locals.get(base.raw) orelse return error.InvalidBody;
        if (local.addressable) return error.InvalidBody;
        if (byte_offset == 0) return local.storage;
        const pointer = try self.temp();
        try self.output.print(self.allocator, "  {s} = getelementptr i8, ptr {s}, i64 {d}\n", .{ pointer, local.storage, byte_offset });
        return pointer;
    }

    fn emitAtomicPlacePointer(self: *Renderer, expression: mir.ExecutableExpression, place_id: mir.PlaceId) RenderError![]const u8 {
        if (!placeValid(self.body, place_id)) return error.InvalidBody;
        const place = self.body.places[place_id.index()];
        if (!atomicPlaceSupported(self.body, place)) return error.InvalidBody;
        if (place.projection_count == 0) return switch (place.root) {
            .local => |id| blk: {
                const local = self.locals.get(id.raw) orelse return error.InvalidBody;
                if (!local.addressable) return error.InvalidBody;
                break :blk local.storage;
            },
            .symbol => |id| try std.fmt.allocPrint(self.allocator, "@{s}", .{symbolSpelling(self.body, id) orelse return error.InvalidBody}),
            .value => error.InvalidBody,
        };
        const edge = representationTrapEdge(self.body, expression) orelse return error.InvalidBody;
        const local_id = switch (place.root) {
            .local => |id| id,
            .symbol, .value => return error.InvalidBody,
        };
        const local = self.locals.get(local_id.raw) orelse return error.InvalidBody;
        if (local.addressable or !std.mem.eql(u8, local.ty, "ptr")) return error.InvalidBody;
        const continuation = try std.fmt.allocPrint(self.allocator, "mc_atomic_ready_{d}", .{expression.id.raw});
        try self.emitPointerRepresentationGuard(local.storage, edge, continuation);
        return self.emitParameterAccessPointer(place, local.storage);
    }

    fn emitMemoryStore(self: *Renderer, place_id: mir.PlaceId, value: Value, pointer: []const u8, access: mir.ExecutableMemoryAccess) RenderError!void {
        const place = &self.body.places[place_id.index()];
        const byte_sized_bool = std.mem.eql(u8, value.ty, "i1") and
            (place.root == .symbol or access.kind == .race_unordered);
        var stored = value.spelling;
        const storage_ty: []const u8 = if (byte_sized_bool) "i8" else value.ty;
        if (byte_sized_bool) {
            stored = try self.temp();
            try self.output.print(self.allocator, "  {s} = zext i1 {s} to i8\n", .{ stored, value.spelling });
        }
        switch (access.kind) {
            .plain => try self.output.print(self.allocator, "  store {s} {s}, ptr {s}, align {d}\n", .{ storage_ty, stored, pointer, access.alignment }),
            .race_unordered => try self.output.print(self.allocator, "  store atomic {s} {s}, ptr {s} unordered, align {d}\n", .{ storage_ty, stored, pointer, access.alignment }),
        }
    }

    fn emitAddressOf(self: *Renderer, expression: mir.ExecutableExpression, address: anytype) RenderError!Value {
        if (directAddressOfSupported(self.body, expression, address)) {
            return .{ .ty = "ptr", .spelling = try self.emitPlace(address.place, "ptr") };
        }
        const place = self.body.places[address.place.index()];
        if (addressOfFixedArrayIndexSupported(self.body, expression, address)) {
            return .{
                .ty = "ptr",
                .spelling = try self.emitFixedArrayIndexPlacePointer(place, .{ .expression = expression.id }),
            };
        }
        if (computedRawManyDerefPlaceSupported(self.body, place, false)) {
            return .{ .ty = "ptr", .spelling = try self.emitComputedRawManyDerefPointer(place) };
        }
        if (mir.executableLocalAddressDerefPlace(self.body, place, false)) {
            return .{ .ty = "ptr", .spelling = try self.emitGuardedLocalAddressAliasPointer(expression, address.place) };
        }
        if (!addressOfParameterDerefSupported(self.body, expression, address)) return error.InvalidBody;
        return .{ .ty = "ptr", .spelling = try self.emitGuardedParameterDerefPointer(expression, address.place) };
    }

    fn emitPlace(self: *Renderer, place_id: mir.PlaceId, value_ty: []const u8) RenderError![]const u8 {
        const place = &self.body.places[place_id.index()];
        if (place.storage != .ordinary) return error.Unsupported;
        const pointer: []const u8 = switch (place.root) {
            .local => |local_id| blk: {
                const local = self.locals.get(local_id.raw) orelse return error.InvalidBody;
                if (!local.addressable) return error.Unsupported;
                break :blk local.storage;
            },
            .symbol => |symbol_id| try std.fmt.allocPrint(self.allocator, "@{s}", .{symbolSpelling(self.body, symbol_id) orelse return error.InvalidBody}),
            .value => return error.Unsupported,
        };
        if (mir.executableDirectAggregateFieldPlace(
            self.body.locals,
            self.body.statements,
            self.body.aggregate_types,
            place.*,
            false,
        )) |field_index| {
            const aggregate_ty = try self.typeText(place.root_ty);
            const field_pointer = try self.temp();
            try self.output.print(
                self.allocator,
                "  {s} = getelementptr inbounds {s}, ptr {s}, i32 0, i32 {d}\n",
                .{ field_pointer, aggregate_ty, pointer, field_index },
            );
            return field_pointer;
        }
        if (place.projection_count != 0) return error.Unsupported;
        _ = value_ty;
        return pointer;
    }

    const FixedArrayBoundsOwner = union(enum) {
        statement: mir.InstId,
        expression: mir.ExprId,
    };

    fn emitFixedArrayIndexPlacePointer(
        self: *Renderer,
        place: mir.ExecutablePlace,
        owner: FixedArrayBoundsOwner,
    ) RenderError![]const u8 {
        const projection = mir.executableFixedArrayIndexPlace(self.body, place) orelse return error.InvalidBody;
        const root_pointer: []const u8 = switch (place.root) {
            .local => |local_id| blk: {
                const local = self.locals.get(local_id.raw) orelse return error.InvalidBody;
                if (!local.addressable) return error.InvalidBody;
                break :blk local.storage;
            },
            .symbol => |symbol_id| try std.fmt.allocPrint(
                self.allocator,
                "@{s}",
                .{symbolSpelling(self.body, symbol_id) orelse return error.InvalidBody},
            ),
            .value => return error.InvalidBody,
        };
        const index = try self.emitExpression(projection.value);
        if (!std.mem.eql(u8, index.ty, "i64")) return error.InvalidBody;
        if (projection.checked) {
            const edge = switch (owner) {
                .statement => |id| statementBoundsTrapEdge(
                    self.body,
                    statementIdentity(self.body, id) orelse return error.InvalidBody,
                ),
                .expression => |id| fixedArrayLoadBoundsTrapEdge(
                    self.body,
                    if (expressionValid(self.body, id)) self.body.expressions[id.index()] else return error.InvalidBody,
                ),
            } orelse return error.InvalidBody;
            const in_bounds = try self.temp();
            const continuation = switch (owner) {
                .statement => |id| try std.fmt.allocPrint(self.allocator, "mc_index_store_ready_{d}", .{id.raw}),
                .expression => |id| try std.fmt.allocPrint(self.allocator, "mc_index_load_ready_{d}", .{id.raw}),
            };
            try self.output.print(
                self.allocator,
                "  {s} = icmp ult i64 {s}, {d}\n" ++
                    "  br i1 {s}, label %{s}, label %mc_block_{d}\n" ++
                    "{s}:\n",
                .{ in_bounds, index.spelling, projection.bound.?, in_bounds, continuation, edge.trap_block.raw, continuation },
            );
        }
        const array_ty = try self.typeText(place.root_ty);
        const pointer = try self.temp();
        try self.output.print(
            self.allocator,
            "  {s} = getelementptr inbounds {s}, ptr {s}, i64 0, i64 {s}\n",
            .{ pointer, array_ty, root_pointer, index.spelling },
        );
        return pointer;
    }

    fn emitGuardedParameterDerefPointer(self: *Renderer, expression: mir.ExecutableExpression, place_id: mir.PlaceId) RenderError![]const u8 {
        if (!placeValid(self.body, place_id)) return error.InvalidBody;
        const place = self.body.places[place_id.index()];
        if (!singleParameterDerefPlaceSupported(self.body, place)) return error.InvalidBody;
        const edge = representationTrapEdge(self.body, expression) orelse return error.InvalidBody;
        const local_id = switch (place.root) {
            .local => |id| id,
            .symbol, .value => return error.InvalidBody,
        };
        const local = self.locals.get(local_id.raw) orelse return error.InvalidBody;
        if (local.addressable or !std.mem.eql(u8, local.ty, "ptr")) return error.InvalidBody;
        const continuation = try std.fmt.allocPrint(self.allocator, "mc_representation_ready_{d}", .{expression.id.raw});
        try self.emitPointerRepresentationGuard(local.storage, edge, continuation);
        return local.storage;
    }

    fn emitComputedRawManyDerefPointer(self: *Renderer, place: mir.ExecutablePlace) RenderError![]const u8 {
        if (!computedRawManyDerefPlaceSupported(self.body, place, false)) return error.InvalidBody;
        const root_id = switch (place.root) {
            .value => |id| id,
            .local, .symbol => return error.InvalidBody,
        };
        const root = try self.emitExpression(root_id);
        if (!std.mem.eql(u8, root.ty, "ptr")) return error.InvalidBody;
        return root.spelling;
    }

    fn emitGuardedParameterAccessPointer(self: *Renderer, expression: mir.ExecutableExpression, place_id: mir.PlaceId) RenderError![]const u8 {
        if (!placeValid(self.body, place_id)) return error.InvalidBody;
        const place = self.body.places[place_id.index()];
        if (!parameterScalarAccessPlaceSupported(self.body, place)) return error.InvalidBody;
        const edge = representationTrapEdge(self.body, expression) orelse return error.InvalidBody;
        const local_id = switch (place.root) {
            .local => |id| id,
            .symbol, .value => return error.InvalidBody,
        };
        const local = self.locals.get(local_id.raw) orelse return error.InvalidBody;
        if (local.addressable or !std.mem.eql(u8, local.ty, "ptr")) return error.InvalidBody;
        const continuation = try std.fmt.allocPrint(self.allocator, "mc_representation_ready_{d}", .{expression.id.raw});
        try self.emitPointerRepresentationGuard(local.storage, edge, continuation);
        return self.emitParameterAccessPointer(place, local.storage);
    }

    fn emitGuardedParameterStorePointer(self: *Renderer, statement: mir.ExecutableStatement, place_id: mir.PlaceId) RenderError![]const u8 {
        if (!placeValid(self.body, place_id)) return error.InvalidBody;
        const place = self.body.places[place_id.index()];
        if (!parameterScalarAccessStorePlaceSupported(self.body, place)) return error.InvalidBody;
        const edge = statementRepresentationTrapEdge(self.body, statement) orelse return error.InvalidBody;
        const local_id = switch (place.root) {
            .local => |id| id,
            .symbol, .value => return error.InvalidBody,
        };
        const local = self.locals.get(local_id.raw) orelse return error.InvalidBody;
        if (local.addressable or !std.mem.eql(u8, local.ty, "ptr")) return error.InvalidBody;
        const continuation = try std.fmt.allocPrint(self.allocator, "mc_representation_store_ready_{d}", .{statement.id.raw});
        try self.emitPointerRepresentationGuard(local.storage, edge, continuation);
        return self.emitParameterAccessPointer(place, local.storage);
    }

    fn emitGuardedLocalAddressAliasPointer(self: *Renderer, expression: mir.ExecutableExpression, place_id: mir.PlaceId) RenderError![]const u8 {
        if (!placeValid(self.body, place_id)) return error.InvalidBody;
        const place = self.body.places[place_id.index()];
        if (!mir.executableLocalAddressDerefPlace(self.body, place, false)) return error.InvalidBody;
        const edge = representationTrapEdge(self.body, expression) orelse return error.InvalidBody;
        const local_id = switch (place.root) {
            .local => |id| id,
            .symbol, .value => return error.InvalidBody,
        };
        const local = self.locals.get(local_id.raw) orelse return error.InvalidBody;
        if (!local.addressable or !std.mem.eql(u8, local.ty, "ptr")) return error.InvalidBody;
        const pointer = try self.temp();
        try self.output.print(self.allocator, "  {s} = load ptr, ptr {s}\n", .{ pointer, local.storage });
        const continuation = try std.fmt.allocPrint(self.allocator, "mc_local_alias_ready_{d}", .{expression.id.raw});
        try self.emitPointerRepresentationGuard(pointer, edge, continuation);
        return pointer;
    }

    fn emitGuardedLocalAddressAliasStorePointer(self: *Renderer, statement: mir.ExecutableStatement, place_id: mir.PlaceId) RenderError![]const u8 {
        if (!placeValid(self.body, place_id)) return error.InvalidBody;
        const place = self.body.places[place_id.index()];
        if (!mir.executableLocalAddressDerefPlace(self.body, place, true)) return error.InvalidBody;
        const edge = statementRepresentationTrapEdge(self.body, statement) orelse return error.InvalidBody;
        const local_id = switch (place.root) {
            .local => |id| id,
            .symbol, .value => return error.InvalidBody,
        };
        const local = self.locals.get(local_id.raw) orelse return error.InvalidBody;
        if (!local.addressable or !std.mem.eql(u8, local.ty, "ptr")) return error.InvalidBody;
        const pointer = try self.temp();
        try self.output.print(self.allocator, "  {s} = load ptr, ptr {s}\n", .{ pointer, local.storage });
        const continuation = try std.fmt.allocPrint(self.allocator, "mc_local_alias_store_ready_{d}", .{statement.id.raw});
        try self.emitPointerRepresentationGuard(pointer, edge, continuation);
        return pointer;
    }

    fn emitParameterAccessPointer(self: *Renderer, place: mir.ExecutablePlace, root_pointer: []const u8) RenderError![]const u8 {
        if (place.projection_count == 1) return root_pointer;
        if (place.projection_count != 2) return error.InvalidBody;
        const field_index = switch (place.projections[1]) {
            .field => |index| index,
            .deref, .index => return error.InvalidBody,
        };
        const pointer = switch (place.root_ty) {
            .pointer => |shape| shape,
            else => return error.InvalidBody,
        };
        const aggregate = aggregateTypeForValueType(self.body, .{ .struct_ = pointer.child }) orelse return error.InvalidBody;
        if (field_index >= aggregate.field_count) return error.InvalidBody;
        const aggregate_ty = try self.typeText(aggregate.ty);
        const field_pointer = try self.temp();
        try self.output.print(
            self.allocator,
            "  {s} = getelementptr inbounds {s}, ptr {s}, i32 0, i32 {d}\n",
            .{ field_pointer, aggregate_ty, root_pointer, field_index },
        );
        return field_pointer;
    }

    fn emitPointerRepresentationGuard(self: *Renderer, pointer: []const u8, edge: mir.ExecutableTrapEdge, continuation: []const u8) RenderError!void {
        const invalid = try self.temp();
        try self.output.print(
            self.allocator,
            "  {s} = icmp eq ptr {s}, null\n" ++
                "  br i1 {s}, label %mc_block_{d}, label %{s}\n" ++
                "{s}:\n",
            .{ invalid, pointer, invalid, edge.trap_block.raw, continuation, continuation },
        );
    }

    fn emitSliceRepresentationGuard(self: *Renderer, slice: []const u8, edge: mir.ExecutableTrapEdge, continuation: []const u8) RenderError!void {
        const pointer = try self.temp();
        const length = try self.temp();
        const pointer_is_null = try self.temp();
        const length_is_nonzero = try self.temp();
        const invalid = try self.temp();
        try self.output.print(
            self.allocator,
            "  {s} = extractvalue {{ ptr, i64 }} {s}, 0\n" ++
                "  {s} = extractvalue {{ ptr, i64 }} {s}, 1\n" ++
                "  {s} = icmp eq ptr {s}, null\n" ++
                "  {s} = icmp ne i64 {s}, 0\n" ++
                "  {s} = and i1 {s}, {s}\n" ++
                "  br i1 {s}, label %mc_block_{d}, label %{s}\n" ++
                "{s}:\n",
            .{
                pointer,             slice,
                length,              slice,
                pointer_is_null,     pointer,
                length_is_nonzero,   length,
                invalid,             pointer_is_null,
                length_is_nonzero,   invalid,
                edge.trap_block.raw, continuation,
                continuation,
            },
        );
    }

    fn temp(self: *Renderer) RenderError![]const u8 {
        const value = try std.fmt.allocPrint(self.allocator, "%mc_expr_tmp_{d}", .{self.next_temp});
        self.next_temp += 1;
        return value;
    }
};

fn scalarLlvmType(ty: mir.ValueType) ?[]const u8 {
    return switch (ty) {
        .void, .never => "void",
        .bool => "i1",
        .integer => |name| if (std.mem.eql(u8, name, "IrqOff"))
            (scalar_repr.integer(name) orelse return null).llvm_type
        else if (std.mem.eql(u8, name, "u8") or std.mem.eql(u8, name, "i8"))
            "i8"
        else if (std.mem.eql(u8, name, "u16") or std.mem.eql(u8, name, "i16"))
            "i16"
        else if (std.mem.eql(u8, name, "u32") or std.mem.eql(u8, name, "i32"))
            "i32"
        else if (std.mem.eql(u8, name, "u64") or std.mem.eql(u8, name, "i64") or std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "isize"))
            "i64"
        else if (std.mem.eql(u8, name, "u128") or std.mem.eql(u8, name, "i128"))
            "i128"
        else
            null,
        .domain_integer => |shape| scalarLlvmType(.{ .integer = shape.child }),
        .float => |name| if (std.mem.eql(u8, name, "f32")) "float" else if (std.mem.eql(u8, name, "f64")) "double" else null,
        .pointer => |shape| if (shape.kind == .slice) "{ ptr, i64 }" else "ptr",
        .nullable_pointer => |shape| if (shape.kind == .slice) null else "ptr",
        .cstr => "ptr",
        .slice => "{ ptr, i64 }",
        .address => "i64",
        else => null,
    };
}

fn llvmTypeSupported(body: *const mir.ExecutableBody, ty: mir.ValueType) bool {
    return llvmTypeSupportedDepth(body, ty, 0);
}

fn llvmTypeSupportedDepth(body: *const mir.ExecutableBody, ty: mir.ValueType, depth: usize) bool {
    if (scalarLlvmType(ty) != null) return true;
    if (ty == .value) return true;
    if (depth >= mir.max_executable_operands) return false;
    if (enumTypeForValueType(body, ty)) |enum_ty| return llvmTypeSupportedDepth(body, enum_ty.repr_ty, depth + 1);
    if (resultTypeForValueType(body, ty)) |shape|
        return llvmTypeSupportedDepth(body, shape.ok_ty, depth + 1) and
            llvmTypeSupportedDepth(body, shape.err_ty, depth + 1);
    const aggregate = aggregateTypeForValueType(body, ty) orelse return false;
    if (aggregate.construction == .packed_bits)
        return llvmTypeSupportedDepth(body, aggregate.storage_ty, depth + 1);
    if (aggregate.construction != .declared_struct or aggregate.field_count == 0) return false;
    for (aggregate.field_types[0..aggregate.field_count], aggregate.field_layout_complete[0..aggregate.field_count]) |field_ty, layout_complete| {
        // Only fixed arrays need the producer's explicit nested-layout bit.
        // Other aggregates are resolved recursively from their canonical type
        // metadata, and scalar fields have no nested layout to complete.
        if (field_ty == .array and !layout_complete) return false;
        if (!llvmTypeSupportedDepth(body, field_ty, depth + 1)) return false;
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

fn enumTypeForValueType(body: *const mir.ExecutableBody, ty: mir.ValueType) ?*const mir.ExecutableEnumType {
    for (body.enum_types) |*enum_ty| if (sameValueType(enum_ty.ty, ty)) return enum_ty;
    return null;
}

fn enumType(body: *const mir.ExecutableBody, type_id: mir.TypeId) ?*const mir.ExecutableEnumType {
    if (!type_id.isValid()) return null;
    for (body.enum_types) |*enum_ty| if (enum_ty.type_id.eql(type_id) and
        enum_ty.ty == .closed_enum and enum_ty.valid_value_count != 0) return enum_ty;
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
    if (!expressionValid(body, operation.payload) or !sameValueType(shape.ty, expression.result_ty)) return false;
    const payload = body.expressions[operation.payload.index()];
    return if (operation.is_ok)
        sameValueType(payload.result_ty, shape.ok_ty) and payload.type_id.eql(shape.ok_type_id)
    else
        sameValueType(payload.result_ty, shape.err_ty) and payload.type_id.eql(shape.err_type_id);
}

fn structConstructionSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, operation: anytype) bool {
    const shape = aggregateType(body, expression.type_id) orelse return false;
    if ((shape.construction != .declared_struct and shape.construction != .packed_bits) or
        operation.construction != shape.construction or
        shape.field_count == 0 or shape.field_count != operation.operand_count or !sameValueType(shape.ty, expression.result_ty)) return false;
    var seen = [_]bool{false} ** mir.max_executable_operands;
    for (operation.operands[0..operation.operand_count], operation.field_indices[0..operation.operand_count]) |operand_id, field_index| {
        if (field_index >= shape.field_count or seen[field_index] or !expressionValid(body, operand_id)) return false;
        seen[field_index] = true;
        const operand = body.expressions[operand_id.index()];
        if (!sameValueType(operand.result_ty, shape.field_types[field_index]) or
            !operand.type_id.eql(shape.field_type_ids[field_index]) or !llvmTypeSupported(body, operand.result_ty)) return false;
    }
    for (seen[0..shape.field_count]) |present| if (!present) return false;
    return true;
}

fn arrayConstructionSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, operation: anytype) bool {
    const shape = aggregateType(body, expression.type_id) orelse return false;
    if (shape.construction != .declared_struct or shape.ty != .array or shape.field_count == 0 or
        shape.array_length == null or shape.array_length.? != operation.operand_count or
        shape.field_count != operation.operand_count or !sameValueType(shape.ty, expression.result_ty)) return false;
    for (operation.operands[0..operation.operand_count], 0..) |operand_id, index| {
        if (!expressionValid(body, operand_id)) return false;
        const operand = body.expressions[operand_id.index()];
        if (!sameValueType(operand.result_ty, shape.field_types[index]) or
            !operand.type_id.eql(shape.field_type_ids[index]) or !llvmTypeSupported(body, operand.result_ty)) return false;
    }
    return true;
}

fn operationSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    return switch (expression.operation) {
        .local => |id| localExists(body, id),
        // A global aggregate symbol is admitted only as storage owned by one
        // typed fixed-array index; every standalone global read stays closed.
        .symbol => functionSymbolExpressionSupported(body, expression) or
            globalAggregateIndexBaseSupported(body, expression),
        .load => |load| memoryLoadSupported(body, expression, load),
        .atomic_load => |load| atomicLoadSupported(body, expression, load),
        .atomic_init => |operand| atomicInitSupported(body, expression, operand),
        .atomic_update => |update| atomicUpdateSupported(body, expression, update),
        .mmio_read => |read| mmioReadSupported(body, expression, read),
        .mmio_write => |write| mmioWriteSupported(body, expression, write),
        .literal => |literal| switch (literal) {
            .integer, .signed_integer, .boolean, .null, .void => true,
            .float => |value| mir.executableFloatMatchesType(value, expression.result_ty),
            else => false,
        },
        .unary => |unary| unarySupported(body, expression, unary),
        .binary => |binary| binarySupported(body, expression, binary),
        .direct_call => |call| call.argument_count <= mir.max_executable_operands and symbolSpelling(body, call.callee) != null and expressionListValid(body, call.arguments[0..call.argument_count]),
        .builtin_call => |call| builtinSupported(body, expression, call),
        .representation_check => |check| representationCheckSupported(body, expression, check),
        .indirect_call => |call| indirectCallSupported(body, expression, call),
        .address_of => |address| directAddressOfSupported(body, expression, address) or
            addressOfFixedArrayIndexSupported(body, expression, address) or
            addressOfParameterDerefSupported(body, expression, address) or
            addressOfLocalAddressAliasDerefSupported(body, expression, address) or
            addressOfComputedRawManyDerefSupported(body, expression, address),
        .deref => |id| expressionValid(body, id) and switch (body.expressions[id.index()].result_ty) {
            .pointer => true,
            else => false,
        },
        .slice_length => |id| expressionValid(body, id) and switch (body.expressions[id.index()].result_ty) {
            .pointer => |shape| shape.kind == .slice,
            .slice => true,
            else => false,
        },
        .cast => |cast| castSupported(body, expression, cast),
        .array => |aggregate| arrayConstructionSupported(body, expression, aggregate),
        .struct_ => |aggregate| structConstructionSupported(body, expression, aggregate),
        .member => |member| memberSupported(body, expression, member),
        .index => |index| indexSupported(body, expression, index),
        .optional_some => |operand| optionalConstructionSupported(body, expression, operand),
        .optional_none => optionalConstructionSupported(body, expression, null),
        .variant_test => |operation| variantOperationSupported(body, expression, operation.operand, operation.kind, false),
        .variant_payload => |operation| variantOperationSupported(body, expression, operation.operand, operation.kind, true),
        .try_unwrap => |operand| tryUnwrapSupported(body, expression, operand),
        .result => |result| resultConstructionSupported(body, expression, result),
        .range_slice, .unsupported => false,
    };
}

fn variantOperationSupported(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    operand_id: mir.ExprId,
    kind: mir.ExecutableVariantKind,
    payload: bool,
) bool {
    if (!expressionValid(body, operand_id)) return false;
    const operand = body.expressions[operand_id.index()];
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
    if (!expressionValid(body, operand_id)) return false;
    const operand = body.expressions[operand_id.index()];
    const shape = switch (operand.result_ty) {
        .nullable_pointer => |pointer| pointer,
        else => return false,
    };
    return sameValueType(expression.result_ty, .{ .pointer = shape }) and
        tryUnwrapTrapEdgeIsExact(body, expression);
}

fn optionalConstructionSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, operand_id: ?mir.ExprId) bool {
    if (expression.result_ty != .nullable_value) return false;
    const shape = aggregateType(body, expression.type_id) orelse return false;
    if (shape.construction != .declared_struct or shape.ty != .nullable_value or shape.field_count != 2 or
        !sameValueType(shape.field_types[0], .bool)) return false;
    const id = operand_id orelse return true;
    if (!expressionValid(body, id)) return false;
    const operand = body.expressions[id.index()];
    return sameValueType(operand.result_ty, shape.field_types[1]) and
        operand.type_id.eql(shape.field_type_ids[1]);
}

fn indirectCallSupported(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    call: @FieldType(mir.ExecutableExpression.Operation, "indirect_call"),
) bool {
    if (call.argument_count > mir.max_executable_operands or call.signature.parameter_count != call.argument_count or
        !sameValueType(call.signature.return_ty, expression.result_ty) or
        !call.signature.return_type_id.eql(expression.type_id) or !expressionValid(body, call.callee)) return false;
    const callee = body.expressions[call.callee.index()];
    if (callee.result_ty != .value) return false;
    for (call.arguments[0..call.argument_count], 0..) |argument_id, index| {
        if (!expressionValid(body, argument_id)) return false;
        const argument = body.expressions[argument_id.index()];
        if (!sameValueType(argument.result_ty, call.signature.parameter_types[index]) or
            !argument.type_id.eql(call.signature.parameter_type_ids[index])) return false;
    }
    return true;
}

fn callableValueExpressionSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    if (expression.result_ty != .value) return false;
    return switch (expression.operation) {
        .local => |local| localExists(body, local) and
            (callableParameter(body, local) or callableLocalUsedAsIndirectCallee(body, local)),
        .symbol => functionSymbolExpressionSupported(body, expression),
        .direct_call => |call| call.argument_count <= mir.max_executable_operands and
            symbolSpelling(body, call.callee) != null and expressionListValid(body, call.arguments[0..call.argument_count]) and
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
            if (!expressionValid(body, call.callee)) continue;
            switch (body.expressions[call.callee.index()].operation) {
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

fn functionSymbolExpressionSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    if (expression.result_ty != .value) return false;
    const id = switch (expression.operation) {
        .symbol => |id| id,
        else => return false,
    };
    const identity = symbolIdentity(body, id) orelse return false;
    return identity.kind == .function;
}

fn functionSymbolReturnSupported(body: *const mir.ExecutableBody, return_ty: mir.ValueType) bool {
    if (return_ty != .value) return false;
    var saw_return = false;
    for (body.statements) |statement| switch (statement.operation) {
        .return_ => |value| {
            const id = value orelse return false;
            if (!expressionValid(body, id) or
                !functionSymbolExpressionSupported(body, body.expressions[id.index()])) return false;
            saw_return = true;
        },
        else => {},
    };
    return saw_return;
}

fn representationCheckSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, check: anytype) bool {
    if (!expressionValid(body, check.operand) or check.operand.index() >= expression.id.index()) return false;
    const operand = body.expressions[check.operand.index()];
    return operand.block_id.eql(expression.block_id) and operand.owner_statement.eql(expression.owner_statement) and
        expression.type_id.eql(operand.type_id) and
        mir.ExecutableRepresentationCheckKind.typesValid(check.kind, expression.result_ty, operand.result_ty) and
        (check.kind != .valid_closed_enum or enumType(body, expression.type_id) != null) and
        representationTrapEdgeIsExact(body, expression);
}

fn memberSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, operation: anytype) bool {
    if (!expressionValid(body, operation.base)) return false;
    const base = body.expressions[operation.base.index()];
    const shape = aggregateType(body, base.type_id) orelse return false;
    const construction_supported = shape.construction == .declared_struct or
        (shape.construction == .packed_bits and expression.result_ty == .bool and
            mir.ExecutableCastKind.integerInfo(shape.storage_ty) != null);
    return construction_supported and operation.field_index < shape.field_count and
        sameValueType(base.result_ty, shape.ty) and
        sameValueType(expression.result_ty, shape.field_types[operation.field_index]) and
        expression.type_id.eql(shape.field_type_ids[operation.field_index]) and
        llvmTypeSupported(body, base.result_ty) and llvmTypeSupported(body, expression.result_ty);
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
    if (!expressionValid(body, operation.base) or !expressionValid(body, operation.index)) return false;
    const base = body.expressions[operation.base.index()];
    const index = body.expressions[operation.index.index()];
    if (!base.block_id.eql(expression.block_id) or !index.block_id.eql(expression.block_id) or
        !base.owner_statement.eql(expression.owner_statement) or !index.owner_statement.eql(expression.owner_statement) or
        !sameValueType(index.result_ty, .{ .integer = "usize" }) or !llvmTypeSupported(body, expression.result_ty))
        return false;
    switch (operation.kind) {
        .fixed_array => {
            // Dynamic array extraction is materialized through an entry-block
            // alloca. Keep loop/body indexes closed until scratch storage is
            // hoisted by MIR rather than emitted inside a repeated block.
            if (expression.block_id.raw != 0) return false;
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
                !expression.type_id.eql(aggregate.field_type_ids[0]) or !llvmTypeSupported(body, base.result_ty))
                return false;
        },
        .slice => {
            if (operation.bound != null) return false;
            const child = switch (base.result_ty) {
                .pointer => |shape| if (shape.kind == .slice) shape.child else return false,
                .slice => |name| name,
                else => return false,
            };
            if (!std.mem.eql(u8, child, expression.result_ty.name()) or !llvmTypeSupported(body, base.result_ty)) return false;
        },
    }
    if (operation.checked) return indexTrapEdgeIsExact(body, expression);
    if (ownedExpressionTrapCount(body, expression.id) != 0 or operation.kind != .fixed_array) return false;
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
    if (operation.kind != .fixed_array or !indexIsDirectReturn(body, expression) or !expressionValid(body, operation.base)) return false;
    const base = body.expressions[operation.base.index()];
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
            if (!placeValid(body, store.place)) return false;
            const place = body.places[store.place.index()];
            if (place.root == .local and place.root.local.eql(local_id)) return false;
        },
        else => {},
    };
    return initialized;
}

fn globalAggregateIndexBase(body: *const mir.ExecutableBody, id: mir.ExprId) bool {
    if (!expressionValid(body, id)) return false;
    const expression = body.expressions[id.index()];
    const symbol_id = switch (expression.operation) {
        .symbol => |symbol| symbol,
        else => return false,
    };
    const identity = symbolIdentity(body, symbol_id) orelse return false;
    return identity.kind == .global and expression.result_ty == .array and llvmTypeSupported(body, expression.result_ty);
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
    if (!expression.owner_statement.isValid() or expression.owner_statement.index() >= body.statements.len) return false;
    const owner = body.statements[expression.owner_statement.index()];
    const store = switch (owner.operation) {
        .store => |value| value,
        else => return false,
    };
    if (!store.value.eql(expression.id) or store.access.kind != .plain or !placeValid(body, store.place)) return false;
    const place = body.places[store.place.index()];
    return place.projection_count == 0 and place.root == .local and
        (expression.result_ty == .array or expression.result_ty == .struct_) and
        sameValueType(place.ty, expression.result_ty);
}

fn indexIsDirectReturn(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    if (!expression.owner_statement.isValid() or expression.owner_statement.index() >= body.statements.len) return false;
    const owner = body.statements[expression.owner_statement.index()];
    return switch (owner.operation) {
        .return_ => |value| if (value) |id| id.eql(expression.id) else false,
        else => false,
    };
}

fn projectionRootIsDirectCall(body: *const mir.ExecutableBody, start: mir.ExprId) bool {
    var current = start;
    var depth: usize = 0;
    while (depth <= mir.max_executable_operands) : (depth += 1) {
        if (!expressionValid(body, current)) return false;
        const expression = body.expressions[current.index()];
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
        if (!expressionValid(body, current)) return false;
        const expression = body.expressions[current.index()];
        current = switch (expression.operation) {
            .member => return true,
            .representation_check => |check| check.operand,
            else => return false,
        };
    }
    return false;
}

fn builtinSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, call: anytype) bool {
    if (mir.executableBuiltinRequiresUnsafe(call.kind) != call.unsafe_authorized) return false;
    switch (call.kind) {
        .phys, .wrapping_add, .wrap_residue, .serial_before, .serial_after, .serial_distance, .serial_compare, .counter_delta_mod, .counter_elapsed_bounded, .enum_raw, .conversion_from, .conversion_try_from, .conversion_trap_from, .conversion_wrap_from, .conversion_sat_from, .conversion_from_mod, .bitcast, .raw_many_offset, .raw_load, .raw_ptr, .raw_store, .forget_unchecked, .cpu_pause, .fence_full, .fence_release, .fence_acquire => {},
        else => return false,
    }
    if (call.argument_count > mir.max_executable_operands) return false;
    var operand_types: [mir.max_executable_operands]mir.ValueType = undefined;
    for (call.arguments[0..call.argument_count], 0..) |id, index| {
        if (!expressionValid(body, id)) return false;
        operand_types[index] = body.expressions[id.index()].result_ty;
    }
    if (!mir.executableBuiltinTypesValid(call.kind, expression.result_ty, operand_types[0..call.argument_count])) return false;
    if (call.kind == .enum_raw and !enumRawSupported(body, expression, call)) return false;
    if (call.kind == .conversion_try_from and !conversionTryResultSupported(body, expression)) return false;
    if (call.kind == .serial_compare and !serialCompareResultSupported(body, expression)) return false;
    if (call.kind == .counter_elapsed_bounded and !counterElapsedResultSupported(body, expression)) return false;
    if (call.kind == .raw_ptr) {
        if (call.representation_source == null or !call.representation_span_id.isValid() or
            !representationTrapEdgeIsExact(body, expression)) return false;
    } else if (call.kind == .conversion_trap_from) {
        if (call.representation_source != null or call.representation_span_id.isValid() or
            !builtinTrapConversionEdgeIsExact(body, expression)) return false;
    } else if (call.representation_source != null or call.representation_span_id.isValid() or
        ownedExpressionTrapCount(body, expression.id) != 0) return false;
    return call.kind != .bitcast or
        (call.argument_count == 1 and pureScalarBitcastTypesSupported(operand_types[0], expression.result_ty));
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

fn enumRawSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, call: anytype) bool {
    if (call.argument_count != 1 or !expressionValid(body, call.arguments[0])) return false;
    const operand = body.expressions[call.arguments[0].index()];
    const enum_ty = enumTypeForValueType(body, operand.result_ty) orelse return false;
    return enum_ty.type_id.eql(operand.type_id) and enum_ty.repr_type_id.eql(expression.type_id) and
        sameValueType(enum_ty.repr_ty, expression.result_ty);
}

fn rawManyElementValueType(body: *const mir.ExecutableBody, name: []const u8) ?mir.ValueType {
    if (std.mem.eql(u8, name, "bool")) return .bool;
    const integer: mir.ValueType = .{ .integer = name };
    if (mir.ExecutableCastKind.integerInfo(integer) != null) return integer;
    if (std.mem.eql(u8, name, "f32") or std.mem.eql(u8, name, "f64")) return .{ .float = name };
    const aggregate: mir.ValueType = .{ .struct_ = name };
    return if (aggregateTypeForValueType(body, aggregate) != null) aggregate else null;
}

fn pureScalarBitcastTypesSupported(source: mir.ValueType, target: mir.ValueType) bool {
    const source_bits = pureScalarBitWidth(source) orelse return false;
    const target_bits = pureScalarBitWidth(target) orelse return false;
    return source_bits == target_bits and scalarLlvmType(source) != null and scalarLlvmType(target) != null;
}

fn pureScalarBitWidth(ty: mir.ValueType) ?u16 {
    if (mir.ExecutableCastKind.integerInfo(ty)) |info| return info.bits;
    return switch (ty) {
        .float => |name| if (std.mem.eql(u8, name, "f32")) 32 else if (std.mem.eql(u8, name, "f64")) 64 else null,
        else => null,
    };
}

fn castSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, cast: anytype) bool {
    if (!expressionValid(body, cast.operand)) return false;
    const operand = body.expressions[cast.operand.index()];
    const expected = mir.ExecutableCastKind.classify(operand.result_ty, expression.result_ty) orelse return false;
    const source_storage = castStorageType(body, operand.result_ty) orelse return false;
    const target_storage = castStorageType(body, expression.result_ty) orelse return false;
    if (expected != cast.kind or scalarLlvmType(source_storage) == null or scalarLlvmType(target_storage) == null) return false;
    const source = mir.ExecutableCastKind.integerInfo(source_storage);
    const target = mir.ExecutableCastKind.integerInfo(target_storage);
    return switch (expected) {
        .identity => true,
        .integer_reinterpret => source != null and target != null and source.?.signed != target.?.signed and source.?.bits == target.?.bits,
        .integer_resize => source != null and target != null and source.?.bits != target.?.bits,
        .float_resize => operand.result_ty == .float and expression.result_ty == .float and
            mir.ExecutableCastKind.floatBits(operand.result_ty.float) != null and
            mir.ExecutableCastKind.floatBits(expression.result_ty.float) != null,
        .integer_to_domain => operand.result_ty == .integer and expression.result_ty == .domain_integer and
            std.mem.eql(u8, operand.result_ty.integer, expression.result_ty.domain_integer.child),
        .domain_to_integer => operand.result_ty == .domain_integer and expression.result_ty == .integer and
            std.mem.eql(u8, operand.result_ty.domain_integer.child, expression.result_ty.integer),
        .address_to_integer => operand.result_ty == .address and target != null and !target.?.signed and target.?.bits == 64,
        .integer_to_address => source != null and !source.?.signed and source.?.bits == 64 and expression.result_ty == .address,
        .pointer_to_integer => operand.result_ty == .pointer and target != null,
        .pointer_to_address => operand.result_ty == .pointer and expression.result_ty == .address,
        .pointer_to_nullable, .pointer_const_narrow => std.mem.eql(u8, scalarLlvmType(operand.result_ty) orelse return false, "ptr") and
            std.mem.eql(u8, scalarLlvmType(expression.result_ty) orelse return false, "ptr"),
        .integer_to_open_enum => source != null and target != null and enumTypeForValueType(body, expression.result_ty) != null,
        .enum_to_integer => source != null and target != null and enumTypeForValueType(body, operand.result_ty) != null,
        .unsigned_resize => source != null and target != null and !source.?.signed and !target.?.signed,
        .signed_widen => source != null and target != null and source.?.signed and target.?.signed and target.?.bits >= source.?.bits,
    };
}

fn castStorageType(body: *const mir.ExecutableBody, ty: mir.ValueType) ?mir.ValueType {
    if (ty == .domain_integer) return .{ .integer = ty.domain_integer.child };
    if (scalarLlvmType(ty) != null) return ty;
    if (enumTypeForValueType(body, ty)) |enum_ty| return enum_ty.repr_ty;
    return null;
}

fn unarySupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, unary: anytype) bool {
    if (!expressionValid(body, unary.operand)) return false;
    const operand_ty = body.expressions[unary.operand.index()].result_ty;
    const result_ty = expression.result_ty;
    if (!sameValueType(result_ty, operand_ty)) return false;
    if (mir.executableCheckedUnaryTrapRequirements(unary.op, result_ty) != null) {
        return checkedIntegerUnaryHasExactTrapEdges(body, expression);
    }
    return switch (unary.op) {
        .bit_not => integerLike(result_ty),
        .logical_not => result_ty == .bool,
        .neg => isFloatType(result_ty) or
            (wrappingNegType(result_ty) and ownedExpressionTrapCount(body, expression.id) == 0),
    };
}

fn checkedIntegerUnaryHasExactTrapEdges(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    const unary = switch (expression.operation) {
        .unary => |value| value,
        else => return false,
    };
    const operand = if (expressionValid(body, unary.operand)) body.expressions[unary.operand.index()] else return false;
    if (!sameValueType(expression.result_ty, operand.result_ty)) return false;
    const requirements = mir.executableCheckedUnaryTrapRequirements(unary.op, expression.result_ty) orelse return false;
    var total: usize = 0;
    for (body.trap_edges) |edge| {
        const owner = edge.owner.expressionId() orelse continue;
        if (!owner.eql(expression.id)) continue;
        total += 1;
        if (!edge.from_block.eql(expression.block_id)) return false;
    }
    if (total != requirements.count) return false;
    for (requirements.items[0..requirements.count]) |requirement| {
        var matches: usize = 0;
        for (body.trap_edges) |edge| {
            const owner = edge.owner.expressionId() orelse continue;
            if (!owner.eql(expression.id) or edge.kind != requirement.kind or edge.source != requirement.source) continue;
            const trap_terminator = terminatorForBlock(body, edge.trap_block) orelse return false;
            switch (trap_terminator.operation) {
                .trap_ => |kind| {
                    if (kind == requirement.kind) matches += 1;
                },
                else => return false,
            }
        }
        if (matches != 1) return false;
    }
    return true;
}

fn binarySupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, binary: anytype) bool {
    if (!expressionValid(body, binary.left) or !expressionValid(body, binary.right)) return false;
    const left_ty = body.expressions[binary.left.index()].result_ty;
    const right_ty = body.expressions[binary.right.index()].result_ty;
    if (binary.arithmetic != .unchecked and binary.contract_region_id != null) return false;
    if (!sameValueType(left_ty, right_ty)) return false;
    if (binary.op == .logical_and or binary.op == .logical_or) {
        return binary.eager_safe and binary.arithmetic == .ordinary and expression.result_ty == .bool and
            mir.executableEagerSafeBoolTree(body.expressions, body.trap_edges, binary.left) and
            mir.executableEagerSafeBoolTree(body.expressions, body.trap_edges, binary.right) and
            ownedExpressionTrapCount(body, expression.id) == 0;
    }
    if (binary.eager_safe) return false;
    if (optionalNullComparison(body, expression, binary)) return ownedExpressionTrapCount(body, expression.id) == 0;
    if (isFloatType(left_ty)) {
        if (binary.arithmetic != .ordinary or ownedExpressionTrapCount(body, expression.id) != 0) return false;
        return switch (binary.op) {
            .add, .sub, .mul, .div => sameValueType(expression.result_ty, left_ty),
            .eq, .ne, .lt, .le, .gt, .ge => expression.result_ty == .bool,
            else => false,
        };
    }
    if (left_ty == .domain_integer) {
        const shape = left_ty.domain_integer;
        if (binary.op == .eq or binary.op == .ne or binary.op == .lt or binary.op == .le or binary.op == .gt or binary.op == .ge) {
            return binary.arithmetic == .ordinary and expression.result_ty == .bool and ownedExpressionTrapCount(body, expression.id) == 0;
        }
        if (!sameValueType(expression.result_ty, left_ty) or ownedExpressionTrapCount(body, expression.id) != 0) return false;
        return switch (shape.kind) {
            .wrap => binary.arithmetic == .wrapping and switch (binary.op) {
                .add, .sub, .mul, .bit_or, .bit_xor, .bit_and, .shl, .shr => integerInfo(shape.child) != null,
                else => false,
            },
            .sat => binary.arithmetic == .saturating and switch (binary.op) {
                .add, .sub, .mul => integerInfo(shape.child) != null,
                else => false,
            },
            .serial, .counter, .duration => false,
        };
    }
    return switch (binary.op) {
        .add, .sub, .mul => sameValueType(expression.result_ty, left_ty) and arithmeticIntegerType(left_ty) and switch (binary.arithmetic) {
            .ordinary => ownedExpressionTrapCount(body, expression.id) == 0,
            .checked => checkedIntegerBinaryHasExactTrapEdges(body, expression),
            .unchecked => binary.contract_region_id != null and ownedExpressionTrapCount(body, expression.id) == 0,
            else => false,
        },
        .div, .mod, .shl, .shr => binary.arithmetic == .checked and sameValueType(expression.result_ty, left_ty) and
            arithmeticIntegerType(left_ty) and checkedIntegerBinaryHasExactTrapEdges(body, expression),
        .bit_or, .bit_xor, .bit_and => binary.arithmetic == .ordinary and sameValueType(expression.result_ty, left_ty) and integerLike(left_ty),
        .eq, .ne => binary.arithmetic == .ordinary and expression.result_ty == .bool and comparableEqualityType(left_ty),
        .lt, .le, .gt, .ge => binary.arithmetic == .ordinary and expression.result_ty == .bool and orderedIntegerType(left_ty),
        else => false,
    };
}

fn optionalNullComparison(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, binary: anytype) bool {
    if (binary.arithmetic != .ordinary or expression.result_ty != .bool or
        (binary.op != .eq and binary.op != .ne)) return false;
    if (!expressionValid(body, binary.left) or !expressionValid(body, binary.right)) return false;
    const left = body.expressions[binary.left.index()];
    const right = body.expressions[binary.right.index()];
    if (left.result_ty != .nullable_value or !sameValueType(left.result_ty, right.result_ty)) return false;
    const left_none = left.operation == .optional_none;
    const right_none = right.operation == .optional_none;
    return left_none != right_none;
}

fn isFloatType(ty: mir.ValueType) bool {
    return switch (ty) {
        .float => true,
        else => false,
    };
}

fn floatComparisonPredicate(op: mir.ExecutableBinaryOp) []const u8 {
    return switch (op) {
        .eq => "oeq",
        .ne => "une",
        .lt => "olt",
        .le => "ole",
        .gt => "ogt",
        .ge => "oge",
        else => unreachable,
    };
}

fn checkedIntegerBinaryHasExactTrapEdges(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    const binary = switch (expression.operation) {
        .binary => |value| value,
        else => return false,
    };
    if (binary.arithmetic != .checked) return false;
    const left = if (expressionValid(body, binary.left)) body.expressions[binary.left.index()] else return false;
    const right = if (expressionValid(body, binary.right)) body.expressions[binary.right.index()] else return false;
    if (!sameValueType(expression.result_ty, left.result_ty) or !sameValueType(expression.result_ty, right.result_ty)) return false;
    const requirements = mir.executableCheckedBinaryTrapRequirements(binary.op, expression.result_ty) orelse return false;
    var total: usize = 0;
    for (body.trap_edges) |edge| {
        const owner = edge.owner.expressionId() orelse continue;
        if (!owner.eql(expression.id)) continue;
        total += 1;
        if (!edge.from_block.eql(expression.block_id)) return false;
    }
    if (total != requirements.count) return false;
    for (requirements.items[0..requirements.count]) |requirement| {
        var matches: usize = 0;
        for (body.trap_edges) |edge| {
            const owner = edge.owner.expressionId() orelse continue;
            if (!owner.eql(expression.id) or edge.kind != requirement.kind or edge.source != requirement.source) continue;
            const trap_terminator = terminatorForBlock(body, edge.trap_block) orelse return false;
            switch (trap_terminator.operation) {
                .trap_ => |kind| {
                    if (kind == requirement.kind) matches += 1;
                },
                else => return false,
            }
        }
        if (matches != 1) return false;
    }
    return true;
}

fn checkedTrapEdge(
    body: *const mir.ExecutableBody,
    expression: mir.ExecutableExpression,
    requirement: mir.ExecutableTrapRequirement,
) ?mir.ExecutableTrapEdge {
    const valid = switch (expression.operation) {
        .unary => checkedIntegerUnaryHasExactTrapEdges(body, expression),
        .binary => checkedIntegerBinaryHasExactTrapEdges(body, expression),
        else => false,
    };
    if (!valid) return null;
    for (body.trap_edges) |edge| {
        const owner = edge.owner.expressionId() orelse continue;
        if (owner.eql(expression.id) and edge.kind == requirement.kind and edge.source == requirement.source) return edge;
    }
    return null;
}

fn terminatorForBlock(body: *const mir.ExecutableBody, id: mir.BlockId) ?mir.ExecutableTerminator {
    if (!id.isValid()) return null;
    for (body.terminators) |terminator| if (terminator.block_id.eql(id)) return terminator;
    return null;
}

fn integerTypeSigned(ty: mir.ValueType) bool {
    return switch (ty) {
        .integer => |name| name.len != 0 and (name[0] == 'i' or std.mem.eql(u8, name, "isize")),
        .domain_integer => |shape| shape.child.len != 0 and (shape.child[0] == 'i' or std.mem.eql(u8, shape.child, "isize")),
        else => false,
    };
}

fn signedMinimumLiteral(bits: u16) ?[]const u8 {
    return switch (bits) {
        8 => "-128",
        16 => "-32768",
        32 => "-2147483648",
        64 => "-9223372036854775808",
        else => null,
    };
}

fn arithmeticIntegerType(ty: mir.ValueType) bool {
    return switch (ty) {
        .integer => true,
        else => false,
    };
}

fn integerLike(ty: mir.ValueType) bool {
    return switch (ty) {
        .bool, .integer, .domain_integer, .address => true,
        else => false,
    };
}

fn orderedIntegerType(ty: mir.ValueType) bool {
    return switch (ty) {
        .integer, .domain_integer, .address => true,
        else => false,
    };
}

fn comparableEqualityType(ty: mir.ValueType) bool {
    return switch (ty) {
        .bool, .integer, .domain_integer, .address, .pointer, .nullable_pointer, .cstr => true,
        else => false,
    };
}

fn sameValueType(left: mir.ValueType, right: mir.ValueType) bool {
    return mir.ValueType.eql(left, right);
}

fn domainInteger(ty: mir.ValueType, expected: mir.IntegerDomainKind) ?mir.DomainIntegerShape {
    const shape = switch (ty) {
        .domain_integer => |value| value,
        else => return null,
    };
    return if (shape.kind == expected) shape else null;
}

fn wrappingNegType(ty: mir.ValueType) bool {
    const shape = domainInteger(ty, .wrap) orelse return false;
    return integerInfo(shape.child) != null;
}

fn durationTypeSpellingMatches(spelling: []const u8, child: []const u8) bool {
    if (std.mem.eql(u8, spelling, "Duration")) return true;
    const prefix = "Duration<";
    return spelling.len == prefix.len + child.len + 1 and
        std.mem.startsWith(u8, spelling, prefix) and spelling[spelling.len - 1] == '>' and
        std.mem.eql(u8, spelling[prefix.len .. spelling.len - 1], child);
}

fn integerInfo(name: []const u8) ?struct { signed: bool, bits: u7, max: u128 } {
    if (std.mem.eql(u8, name, "u8")) return .{ .signed = false, .bits = 8, .max = std.math.maxInt(u8) };
    if (std.mem.eql(u8, name, "u16")) return .{ .signed = false, .bits = 16, .max = std.math.maxInt(u16) };
    if (std.mem.eql(u8, name, "u32")) return .{ .signed = false, .bits = 32, .max = std.math.maxInt(u32) };
    if (std.mem.eql(u8, name, "u64") or std.mem.eql(u8, name, "usize")) return .{ .signed = false, .bits = 64, .max = std.math.maxInt(u64) };
    if (std.mem.eql(u8, name, "i8")) return .{ .signed = true, .bits = 8, .max = 0 };
    if (std.mem.eql(u8, name, "i16")) return .{ .signed = true, .bits = 16, .max = 0 };
    if (std.mem.eql(u8, name, "i32")) return .{ .signed = true, .bits = 32, .max = 0 };
    if (std.mem.eql(u8, name, "i64") or std.mem.eql(u8, name, "isize")) return .{ .signed = true, .bits = 64, .max = 0 };
    return null;
}

fn expressionListValid(body: *const mir.ExecutableBody, expressions: []const mir.ExprId) bool {
    for (expressions) |id| if (!expressionValid(body, id)) return false;
    return true;
}

fn expressionValid(body: *const mir.ExecutableBody, id: mir.ExprId) bool {
    return id.isValid() and id.index() < body.expressions.len and body.expressions[id.index()].id.eql(id);
}

fn statementIdentity(body: *const mir.ExecutableBody, id: mir.InstId) ?mir.ExecutableStatement {
    if (!id.isValid() or id.index() >= body.statements.len) return null;
    const statement = body.statements[id.index()];
    return if (statement.id.eql(id)) statement else null;
}

fn placeValid(body: *const mir.ExecutableBody, id: mir.PlaceId) bool {
    return id.isValid() and id.index() < body.places.len and body.places[id.index()].id.eql(id);
}

fn placeRootValid(body: *const mir.ExecutableBody, place: mir.ExecutablePlace) bool {
    return switch (place.root) {
        .local => |id| localAddressable(body, id),
        .symbol => |id| if (symbolIdentity(body, id)) |identity| identity.kind == .global else false,
        .value => false,
    };
}

fn parameterIdentity(body: *const mir.ExecutableBody, id: mir.LocalId) ?mir.ExecutableParameter {
    if (!id.isValid()) return null;
    for (body.parameters) |parameter| if (parameter.local.eql(id)) return parameter;
    return null;
}

fn singleParameterDerefPlaceSupported(body: *const mir.ExecutableBody, place: mir.ExecutablePlace) bool {
    if (place.storage != .ordinary or place.projection_count != 1 or !place.root_type_id.isValid() or !place.type_id.isValid()) return false;
    switch (place.projections[0]) {
        .deref => {},
        .field, .index => return false,
    }
    const local_id = switch (place.root) {
        .local => |id| id,
        .symbol, .value => return false,
    };
    const parameter = parameterIdentity(body, local_id) orelse return false;
    if (!parameter.type_id.isValid() or !parameter.type_id.eql(place.root_type_id) or
        !sameValueType(parameter.ty, place.root_ty) or mir.executableStorageAlignment(body.enum_types, place.ty) == null) return false;
    const pointer = switch (place.root_ty) {
        .pointer => |shape| shape,
        // A projected nullable pointer would need a different representation
        // contract. Keep this first slice non-nullable and fail closed.
        else => return false,
    };
    return pointer.kind == .single and std.mem.eql(u8, pointer.child, place.ty.name());
}

fn singleParameterDerefStorePlaceSupported(body: *const mir.ExecutableBody, place: mir.ExecutablePlace) bool {
    if (!singleParameterDerefPlaceSupported(body, place)) return false;
    return switch (place.root_ty) {
        .pointer => |shape| shape.mutability == .mut,
        else => false,
    };
}

fn parameterScalarAccessPlaceSupported(body: *const mir.ExecutableBody, place: mir.ExecutablePlace) bool {
    if (place.storage != .ordinary) return false;
    if (place.projection_count == 1) return singleParameterDerefPlaceSupported(body, place);
    if (place.projection_count != 2 or place.projections[0] != .deref or
        !place.root_type_id.isValid() or !place.type_id.isValid() or
        mir.executableStorageAlignment(body.enum_types, place.ty) == null) return false;
    const field_index = switch (place.projections[1]) {
        .field => |index| index,
        .deref, .index => return false,
    };
    const local_id = switch (place.root) {
        .local => |id| id,
        .symbol, .value => return false,
    };
    const parameter = parameterIdentity(body, local_id) orelse return false;
    if (!parameter.type_id.eql(place.root_type_id) or !sameValueType(parameter.ty, place.root_ty)) return false;
    const pointer = switch (place.root_ty) {
        .pointer => |shape| shape,
        else => return false,
    };
    if (pointer.kind != .single) return false;
    const aggregate = aggregateTypeForValueType(body, .{ .struct_ = pointer.child }) orelse return false;
    return aggregate.construction == .declared_struct and field_index < aggregate.field_count and
        llvmTypeSupported(body, aggregate.ty) and
        aggregate.field_type_ids[field_index].eql(place.type_id) and
        sameValueType(aggregate.field_types[field_index], place.ty);
}

fn parameterScalarAccessStorePlaceSupported(body: *const mir.ExecutableBody, place: mir.ExecutablePlace) bool {
    if (!parameterScalarAccessPlaceSupported(body, place)) return false;
    return switch (place.root_ty) {
        .pointer => |shape| shape.mutability == .mut,
        else => false,
    };
}

fn computedRawManyDerefPlaceSupported(body: *const mir.ExecutableBody, place: mir.ExecutablePlace, require_mutable: bool) bool {
    if (place.storage != .ordinary or place.projection_count != 1 or place.projections[0] != .deref or
        !place.root_type_id.isValid() or !place.type_id.isValid() or
        mir.executableStorageAlignment(body.enum_types, place.ty) == null) return false;
    const root_id = switch (place.root) {
        .value => |id| id,
        .local, .symbol => return false,
    };
    if (!expressionValid(body, root_id)) return false;
    const root = body.expressions[root_id.index()];
    if (!root.type_id.eql(place.root_type_id) or !sameValueType(root.result_ty, place.root_ty)) return false;
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

fn memoryLoadSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, load: anytype) bool {
    if (!memoryAccessSupported(body, load.place, expression.result_ty, load.access, false)) return false;
    const place = body.places[load.place.index()];
    if (place.projection_count == 0) {
        return load.representation_source == null and !load.representation_span_id.isValid();
    }
    if (!expression.type_id.isValid() or !expression.type_id.eql(place.type_id)) return false;
    if (mir.executableFixedArrayIndexPlace(body, place)) |index| {
        return load.representation_source == null and !load.representation_span_id.isValid() and
            if (index.checked)
                fixedArrayLoadBoundsTrapEdge(body, expression) != null and ownedExpressionTrapCount(body, expression.id) == 1
            else
                ownedExpressionTrapCount(body, expression.id) == 0;
    }
    if (mir.executableDirectAggregateFieldPlace(
        body.locals,
        body.statements,
        body.aggregate_types,
        place,
        false,
    ) != null) return load.representation_source == null and
        !load.representation_span_id.isValid() and ownedExpressionTrapCount(body, expression.id) == 0;
    if (computedRawManyDerefPlaceSupported(body, place, false)) {
        return load.representation_source == null and !load.representation_span_id.isValid() and
            ownedExpressionTrapCount(body, expression.id) == 0;
    }
    return load.representation_source != null and load.representation_span_id.isValid() and
        representationTrapEdgeIsExact(body, expression);
}

fn addressOfFixedArrayIndexSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, address: anytype) bool {
    if (!placeValid(body, address.place)) return false;
    const place = body.places[address.place.index()];
    const projection = mir.executableFixedArrayIndexPlace(body, place) orelse return false;
    if (!addressResultMatchesPlace(expression.result_ty, place.ty) or
        address.representation_source != null or address.representation_span_id.isValid())
        return false;
    const root_addressable = switch (place.root) {
        .local => |id| localAddressable(body, id),
        .symbol => |id| if (symbolIdentity(body, id)) |identity| identity.kind == .global else false,
        .value => false,
    };
    if (!root_addressable) return false;
    return if (projection.checked)
        fixedArrayLoadBoundsTrapEdge(body, expression) != null and ownedExpressionTrapCount(body, expression.id) == 1
    else
        ownedExpressionTrapCount(body, expression.id) == 0;
}

fn atomicLoadSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, load: anytype) bool {
    if (!load.ordering.validForLoad() or !placeValid(body, load.place)) return false;
    const place = body.places[load.place.index()];
    if (!atomicPlaceSupported(body, place) or !sameValueType(place.ty, expression.result_ty) or
        !place.type_id.eql(expression.type_id)) return false;
    if (place.projection_count == 0) {
        return load.representation_source == null and !load.representation_span_id.isValid() and
            ownedExpressionTrapCount(body, expression.id) == 0;
    }
    return load.representation_source != null and load.representation_span_id.isValid() and
        representationTrapEdgeIsExact(body, expression);
}

fn atomicInitSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, operand_id: mir.ExprId) bool {
    if (!expressionValid(body, operand_id)) return false;
    const operand = body.expressions[operand_id.index()];
    return atomicPayloadTypeSupported(expression.result_ty) and sameValueType(operand.result_ty, expression.result_ty) and
        operand.type_id.eql(expression.type_id) and ownedExpressionTrapCount(body, expression.id) == 0;
}

fn atomicUpdateSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, update: anytype) bool {
    if (!placeValid(body, update.place) or !expressionValid(body, update.value)) return false;
    const place = body.places[update.place.index()];
    const operand = body.expressions[update.value.index()];
    const ordering_valid = switch (update.kind) {
        .store => update.ordering.validForStore(),
        .fetch_add, .fetch_sub => update.ordering.validForRmw(),
    };
    if (!ordering_valid or !atomicPlaceSupported(body, place) or
        !sameValueType(place.ty, operand.result_ty) or !place.type_id.eql(operand.type_id)) return false;
    if (update.kind == .store) {
        if (expression.result_ty != .void) return false;
    } else if (!sameValueType(expression.result_ty, place.ty) or !expression.type_id.eql(place.type_id)) return false;
    if (place.projection_count == 0) return update.representation_source == null and
        !update.representation_span_id.isValid() and ownedExpressionTrapCount(body, expression.id) == 0;
    return update.representation_source != null and update.representation_span_id.isValid() and
        representationTrapEdgeIsExact(body, expression);
}

fn mmioReadSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, read: anytype) bool {
    return read.ordering.validForRead() and mmioBaseSupported(body, read.base) and
        mmioStorageSupported(read.storage_ty) and sameValueType(expression.result_ty, read.storage_ty) and
        expression.type_id.eql(read.storage_type_id) and ownedExpressionTrapCount(body, expression.id) == 0;
}

fn mmioWriteSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, write: anytype) bool {
    if (!expressionValid(body, write.value)) return false;
    const operand = body.expressions[write.value.index()];
    return write.ordering.validForWrite() and mmioBaseSupported(body, write.base) and
        mmioStorageSupported(write.storage_ty) and expression.result_ty == .void and
        sameValueType(operand.result_ty, write.storage_ty) and operand.type_id.eql(write.storage_type_id) and
        ownedExpressionTrapCount(body, expression.id) == 0;
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

fn atomicPayloadTypeSupported(ty: mir.ValueType) bool {
    return switch (ty) {
        .bool => true,
        .integer => mir.ExecutableMemoryAccess.scalarAlignment(ty) != null,
        else => false,
    };
}

fn atomicPlaceSupported(body: *const mir.ExecutableBody, place: mir.ExecutablePlace) bool {
    if (place.storage != .atomic or !place.root_type_id.isValid() or !place.type_id.isValid()) return false;
    switch (place.ty) {
        .bool => {},
        .integer => if (mir.ExecutableMemoryAccess.scalarAlignment(place.ty) == null) return false,
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
        .symbol => |id| if (symbolIdentity(body, id)) |identity|
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
    const local_id = switch (place.root) {
        .local => |id| id,
        .symbol, .value => return false,
    };
    const parameter = parameterIdentity(body, local_id) orelse return false;
    if (!parameter.type_id.eql(place.root_type_id) or !parameter.atomic_payload_type_id.eql(place.type_id) or
        !sameValueType(parameter.ty, place.root_ty)) return false;
    const pointer = switch (parameter.ty) {
        .pointer => |shape| shape,
        else => return false,
    };
    return pointer.kind == .single;
}

fn llvmAtomicOrdering(ordering: mir.ExecutableAtomicOrdering) []const u8 {
    return switch (ordering) {
        .relaxed => "monotonic",
        .acquire => "acquire",
        .release => "release",
        .acq_rel => "acq_rel",
        .seq_cst => "seq_cst",
    };
}

fn addressOfParameterDerefSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, address: anytype) bool {
    if (!placeValid(body, address.place)) return false;
    const place = body.places[address.place.index()];
    return singleParameterDerefPlaceSupported(body, place) and
        sameValueType(expression.result_ty, place.root_ty) and
        expression.type_id.isValid() and expression.type_id.eql(place.root_type_id) and
        address.representation_source != null and address.representation_span_id.isValid() and
        representationTrapEdgeIsExact(body, expression);
}

fn addressOfLocalAddressAliasDerefSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, address: anytype) bool {
    if (!placeValid(body, address.place)) return false;
    const place = body.places[address.place.index()];
    return mir.executableLocalAddressDerefPlace(body, place, false) and
        sameValueType(expression.result_ty, place.root_ty) and
        expression.type_id.isValid() and expression.type_id.eql(place.root_type_id) and
        address.representation_source != null and address.representation_span_id.isValid() and
        representationTrapEdgeIsExact(body, expression);
}

fn addressOfComputedRawManyDerefSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, address: anytype) bool {
    if (!placeValid(body, address.place)) return false;
    const place = body.places[address.place.index()];
    return computedRawManyDerefPlaceSupported(body, place, false) and
        addressResultMatchesPlace(expression.result_ty, place.ty) and expression.type_id.isValid() and
        address.representation_source == null and !address.representation_span_id.isValid() and
        ownedExpressionTrapCount(body, expression.id) == 0;
}

fn directAddressOfSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, address: anytype) bool {
    if (!placeValid(body, address.place)) return false;
    const place = body.places[address.place.index()];
    if (place.storage != .ordinary or place.projection_count != 0 or !sameValueType(place.root_ty, place.ty) or
        !addressResultMatchesPlace(expression.result_ty, place.ty) or
        address.representation_source != null or address.representation_span_id.isValid() or
        ownedExpressionTrapCount(body, expression.id) != 0) return false;
    return switch (place.root) {
        .local => |id| localAddressable(body, id) and parameterIdentity(body, id) == null,
        .symbol => |id| if (symbolIdentity(body, id)) |identity| identity.kind == .global else false,
        .value => false,
    };
}

fn addressResultMatchesPlace(result_ty: mir.ValueType, place_ty: mir.ValueType) bool {
    const shape = switch (result_ty) {
        .pointer => |value| value,
        else => return false,
    };
    return shape.kind == .single and std.mem.eql(u8, shape.child, place_ty.name());
}

fn memoryStoreSupported(body: *const mir.ExecutableBody, statement: mir.ExecutableStatement, store: anytype) bool {
    if (!memoryAccessSupported(body, store.place, store.ty, store.access, true) or !expressionValid(body, store.value)) return false;
    const place = body.places[store.place.index()];
    const value = body.expressions[store.value.index()];
    if (!sameValueType(store.ty, value.result_ty)) return false;
    if (place.projection_count == 0) {
        return store.representation_source == null and !store.representation_span_id.isValid();
    }
    if (!store.type_id.isValid() or !store.type_id.eql(place.type_id) or
        !value.type_id.isValid() or !value.type_id.eql(store.type_id)) return false;
    if (mir.executableFixedArrayIndexPlace(body, place)) |index| {
        return store.representation_source == null and !store.representation_span_id.isValid() and
            if (index.checked)
                statementBoundsTrapEdge(body, statement) != null and ownedStatementTrapEdgeCount(body, statement.id) == 1
            else
                ownedStatementTrapEdgeCount(body, statement.id) == 0;
    }
    if (mir.executableDirectAggregateFieldPlace(
        body.locals,
        body.statements,
        body.aggregate_types,
        place,
        true,
    ) != null) return store.representation_source == null and
        !store.representation_span_id.isValid() and ownedStatementTrapEdgeCount(body, statement.id) == 0;
    if (computedRawManyDerefPlaceSupported(body, place, true)) {
        return store.representation_source == null and !store.representation_span_id.isValid() and
            statementRepresentationTrapEdge(body, statement) == null;
    }
    return (parameterScalarAccessStorePlaceSupported(body, place) or
        mir.executableLocalAddressDerefPlace(body, place, true)) and
        store.representation_source != null and store.representation_span_id.isValid() and
        statementRepresentationTrapEdgeIsExact(body, statement);
}

fn memoryAccessSupported(body: *const mir.ExecutableBody, place_id: mir.PlaceId, ty: mir.ValueType, access: mir.ExecutableMemoryAccess, is_store: bool) bool {
    if (!placeValid(body, place_id)) return false;
    const place = body.places[place_id.index()];
    if (place.storage != .ordinary) return false;
    const expected_alignment = mir.executableStorageAlignment(body.enum_types, ty) orelse aggregate_local: {
        if (place.projection_count != 0 or access.kind != .plain) return false;
        switch (place.root) {
            .local => {},
            .symbol, .value => return false,
        }
        switch (ty) {
            .array, .struct_, .nullable_value => break :aggregate_local 1,
            else => return false,
        }
    };
    if (access.alignment != expected_alignment) return false;
    // LLVM atomic load/store does not accept aggregate values. Aggregate
    // accesses through shared pointer/global storage must remain on the
    // legacy leaf-wise path until executable MIR carries a leaf access plan.
    if (access.kind == .race_unordered and !unorderedMemoryTypeSupported(body, ty)) return false;
    if (place.projection_count != 0) {
        if (mir.executableFixedArrayIndexPlace(body, place) != null) {
            const expected_kind: mir.ExecutableMemoryAccessKind = switch (place.root) {
                .local => .plain,
                .symbol => |id| if (symbolIdentity(body, id)) |identity|
                    if (identity.kind == .global and (!is_store or identity.mutable))
                        if (identity.mutable) .race_unordered else .plain
                    else
                        return false
                else
                    return false,
                .value => return false,
            };
            return sameValueType(place.ty, ty) and access.kind == expected_kind;
        }
        if (mir.executableDirectAggregateFieldPlace(
            body.locals,
            body.statements,
            body.aggregate_types,
            place,
            is_store,
        ) != null) return sameValueType(place.ty, ty) and access.kind == .plain;
        const local_alias = mir.executableLocalAddressDerefPlace(body, place, false);
        const expected_kind: mir.ExecutableMemoryAccessKind = if (local_alias) .plain else .race_unordered;
        return sameValueType(place.ty, ty) and access.kind == expected_kind and
            if (is_store)
                parameterScalarAccessStorePlaceSupported(body, place) or
                    mir.executableLocalAddressDerefPlace(body, place, true) or
                    computedRawManyDerefPlaceSupported(body, place, true)
            else
                scalarAccessPlaceSupported(body, place);
    }
    return switch (place.root) {
        .local => |id| localAddressable(body, id) and access.kind == .plain,
        .symbol => |id| if (symbolIdentity(body, id)) |identity|
            identity.kind == .global and
                if (identity.mutable)
                    access.kind == .race_unordered
                else
                    !is_store and access.kind == .plain
        else
            false,
        .value => false,
    };
}

fn unorderedMemoryTypeSupported(body: *const mir.ExecutableBody, ty: mir.ValueType) bool {
    return switch (ty) {
        .bool, .integer, .domain_integer, .float, .cstr, .address => true,
        .pointer => |shape| shape.kind != .slice,
        .nullable_pointer => |shape| shape.kind != .slice,
        .closed_enum, .open_enum => enumTypeForValueType(body, ty) != null,
        else => false,
    };
}

fn representationTrapEdgeIsExact(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    return representationTrapEdge(body, expression) != null;
}

fn tryUnwrapTrapEdgeIsExact(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    return tryUnwrapTrapEdge(body, expression) != null;
}

fn indexTrapEdgeIsExact(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    return indexTrapEdge(body, expression) != null;
}

fn fixedArrayLoadBoundsTrapEdgeIsExact(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    return fixedArrayLoadBoundsTrapEdge(body, expression) != null;
}

fn fixedArrayLoadBoundsTrapEdge(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) ?mir.ExecutableTrapEdge {
    const place_id = switch (expression.operation) {
        .load => |value| value.place,
        .address_of => |value| value.place,
        else => return null,
    };
    if (!placeValid(body, place_id)) return null;
    const projection = mir.executableFixedArrayIndexPlace(body, body.places[place_id.index()]) orelse return null;
    if (!projection.checked or ownedExpressionTrapCount(body, expression.id) != 1) return null;
    var found: ?mir.ExecutableTrapEdge = null;
    for (body.trap_edges) |edge| {
        const owner = edge.owner.expressionId() orelse continue;
        if (!owner.eql(expression.id)) continue;
        if (found != null or !edge.from_block.eql(expression.block_id) or edge.kind != .Bounds or edge.source != .bounds_check)
            return null;
        const trap = terminatorForBlock(body, edge.trap_block) orelse return null;
        switch (trap.operation) {
            .trap_ => |kind| if (kind != .Bounds) return null,
            else => return null,
        }
        found = edge;
    }
    return found;
}

fn indexTrapEdge(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) ?mir.ExecutableTrapEdge {
    if (expression.operation != .index or !expression.operation.index.checked or
        ownedExpressionTrapCount(body, expression.id) != 1) return null;
    var found: ?mir.ExecutableTrapEdge = null;
    for (body.trap_edges) |edge| {
        const owner = edge.owner.expressionId() orelse continue;
        if (!owner.eql(expression.id)) continue;
        if (found != null or !edge.from_block.eql(expression.block_id) or edge.kind != .Bounds or edge.source != .bounds_check)
            return null;
        const trap = terminatorForBlock(body, edge.trap_block) orelse return null;
        switch (trap.operation) {
            .trap_ => |kind| if (kind != .Bounds) return null,
            else => return null,
        }
        found = edge;
    }
    return found;
}

fn tryUnwrapTrapEdge(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) ?mir.ExecutableTrapEdge {
    if (expression.operation != .try_unwrap or ownedExpressionTrapCount(body, expression.id) != 1) return null;
    var found: ?mir.ExecutableTrapEdge = null;
    for (body.trap_edges) |edge| {
        const owner = edge.owner.expressionId() orelse continue;
        if (!owner.eql(expression.id)) continue;
        if (found != null or !edge.from_block.eql(expression.block_id) or edge.kind != .Unwrap or edge.source != .unwrap)
            return null;
        const trap = terminatorForBlock(body, edge.trap_block) orelse return null;
        switch (trap.operation) {
            .trap_ => |kind| if (kind != .Unwrap) return null,
            else => return null,
        }
        found = edge;
    }
    return found;
}

fn builtinTrapConversionEdgeIsExact(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    return builtinTrapConversionEdge(body, expression) != null;
}

fn builtinTrapConversionEdge(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) ?mir.ExecutableTrapEdge {
    const call = switch (expression.operation) {
        .builtin_call => |value| value,
        else => return null,
    };
    if (call.kind != .conversion_trap_from) return null;
    var found: ?mir.ExecutableTrapEdge = null;
    for (body.trap_edges) |edge| {
        const owner = edge.owner.expressionId() orelse continue;
        if (!owner.eql(expression.id)) continue;
        if (found != null or !edge.from_block.eql(expression.block_id) or edge.kind != .IntegerOverflow or
            edge.source != .checked_arithmetic) return null;
        const trap = terminatorForBlock(body, edge.trap_block) orelse return null;
        switch (trap.operation) {
            .trap_ => |kind| if (kind != .IntegerOverflow) return null,
            else => return null,
        }
        found = edge;
    }
    return found;
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

fn ownedExpressionTrapCount(body: *const mir.ExecutableBody, expression_id: mir.ExprId) usize {
    var count: usize = 0;
    for (body.trap_edges) |edge| if (edge.owner.expressionId()) |owner| {
        if (owner.eql(expression_id)) count += 1;
    };
    return count;
}

fn ownedStatementTrapEdgeCount(body: *const mir.ExecutableBody, statement_id: mir.InstId) usize {
    var count: usize = 0;
    for (body.trap_edges) |edge| if (edge.owner.statementId()) |owner| {
        if (owner.eql(statement_id)) count += 1;
    };
    return count;
}

fn representationTrapEdge(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) ?mir.ExecutableTrapEdge {
    var found: ?mir.ExecutableTrapEdge = null;
    for (body.trap_edges) |edge| {
        const owner = edge.owner.expressionId() orelse continue;
        if (!owner.eql(expression.id)) continue;
        if (found != null or !edge.from_block.eql(expression.block_id) or edge.kind != .InvalidRepresentation or
            edge.source != .representation_check) return null;
        const trap_terminator = terminatorForBlock(body, edge.trap_block) orelse return null;
        switch (trap_terminator.operation) {
            .trap_ => |kind| if (kind != .InvalidRepresentation) return null,
            else => return null,
        }
        found = edge;
    }
    return found;
}

fn statementRepresentationTrapEdgeIsExact(body: *const mir.ExecutableBody, statement: mir.ExecutableStatement) bool {
    return statementRepresentationTrapEdge(body, statement) != null;
}

fn statementRepresentationTrapEdge(body: *const mir.ExecutableBody, statement: mir.ExecutableStatement) ?mir.ExecutableTrapEdge {
    var found: ?mir.ExecutableTrapEdge = null;
    for (body.trap_edges) |edge| {
        const owner = edge.owner.statementId() orelse continue;
        if (!owner.eql(statement.id)) continue;
        if (found != null or !edge.from_block.eql(statement.block_id) or edge.kind != .InvalidRepresentation or
            edge.source != .representation_check) return null;
        const trap_terminator = terminatorForBlock(body, edge.trap_block) orelse return null;
        switch (trap_terminator.operation) {
            .trap_ => |kind| if (kind != .InvalidRepresentation) return null,
            else => return null,
        }
        found = edge;
    }
    return found;
}

fn statementBoundsTrapEdge(body: *const mir.ExecutableBody, statement: mir.ExecutableStatement) ?mir.ExecutableTrapEdge {
    var found: ?mir.ExecutableTrapEdge = null;
    for (body.trap_edges) |edge| {
        const owner = edge.owner.statementId() orelse continue;
        if (!owner.eql(statement.id)) continue;
        if (found != null or !edge.from_block.eql(statement.block_id) or
            edge.kind != .Bounds or edge.source != .bounds_check) return null;
        const trap_terminator = terminatorForBlock(body, edge.trap_block) orelse return null;
        switch (trap_terminator.operation) {
            .trap_ => |kind| if (kind != .Bounds) return null,
            else => return null,
        }
        found = edge;
    }
    return found;
}

fn assertTrapEdgeIsExact(body: *const mir.ExecutableBody, statement: mir.ExecutableStatement) bool {
    return assertTrapEdge(body, statement) != null;
}

fn assertTrapEdge(body: *const mir.ExecutableBody, statement: mir.ExecutableStatement) ?mir.ExecutableTrapEdge {
    const guard = switch (statement.operation) {
        .guard => |value| value,
        else => return null,
    };
    if (guard.kind != .assert_ or !expressionValid(body, guard.condition) or
        body.expressions[guard.condition.index()].result_ty != .bool) return null;
    var found: ?mir.ExecutableTrapEdge = null;
    for (body.trap_edges) |edge| {
        const owner = edge.owner.statementId() orelse continue;
        if (!owner.eql(statement.id)) continue;
        if (found != null or !edge.from_block.eql(statement.block_id) or edge.kind != .Assert or
            edge.source != .assert_stmt) return null;
        const trap_terminator = terminatorForBlock(body, edge.trap_block) orelse return null;
        switch (trap_terminator.operation) {
            .trap_ => |kind| if (kind != .Assert) return null,
            else => return null,
        }
        found = edge;
    }
    return found;
}

fn placeIsGlobal(body: *const mir.ExecutableBody, id: mir.PlaceId) bool {
    if (!placeValid(body, id)) return false;
    return switch (body.places[id.index()].root) {
        .symbol => true,
        .local, .value => false,
    };
}

fn localAddressable(body: *const mir.ExecutableBody, id: mir.LocalId) bool {
    if (!id.isValid()) return false;
    for (body.locals) |local| if (local.id.eql(id)) return true;
    return false;
}

fn localExists(body: *const mir.ExecutableBody, id: mir.LocalId) bool {
    if (!id.isValid()) return false;
    for (body.parameters) |parameter| if (parameter.local.eql(id)) return true;
    for (body.locals) |local| if (local.id.eql(id)) return true;
    return false;
}

fn symbolSpelling(body: *const mir.ExecutableBody, id: mir.SymbolId) ?[]const u8 {
    return if (symbolIdentity(body, id)) |identity| identity.spelling else null;
}

fn symbolIdentity(body: *const mir.ExecutableBody, id: mir.SymbolId) ?mir.SymbolIdentity {
    if (!id.isValid()) return null;
    for (body.symbols) |identity| if (identity.id.eql(id)) return identity;
    return null;
}

fn blockExists(body: *const mir.ExecutableBody, id: mir.BlockId) bool {
    if (!id.isValid()) return false;
    for (body.terminators) |terminator| if (terminator.block_id.eql(id)) return true;
    return false;
}

fn hasReturnStatement(body: *const mir.ExecutableBody, block_id: mir.BlockId) bool {
    var count: usize = 0;
    for (body.statements) |statement| {
        if (!statement.block_id.eql(block_id)) continue;
        switch (statement.operation) {
            .return_ => count += 1,
            else => {},
        }
    }
    return count == 1;
}

fn comparisonPredicate(op: mir.ExecutableBinaryOp, operand_ty: mir.ValueType) []const u8 {
    const signed = switch (operand_ty) {
        .integer => |name| name.len != 0 and name[0] == 'i',
        else => false,
    };
    return switch (op) {
        .eq => "eq",
        .ne => "ne",
        .lt => if (signed) "slt" else "ult",
        .le => if (signed) "sle" else "ule",
        .gt => if (signed) "sgt" else "ugt",
        .ge => if (signed) "sge" else "uge",
        else => unreachable,
    };
}

fn trapHelper(kind: mir.TrapKind) ?[]const u8 {
    return switch (kind) {
        .IntegerOverflow => "mc_trap_IntegerOverflow",
        .DivideByZero => "mc_trap_DivideByZero",
        .InvalidShift => "mc_trap_InvalidShift",
        .Bounds => "mc_trap_Bounds",
        .Assert => "mc_trap_Assert",
        .Unreachable => "mc_trap_Unreachable",
        .ExplicitTrap => "mc_trap_ExplicitTrap",
        .Unwrap => "mc_trap_NullUnwrap",
        .InvalidRepresentation => "mc_trap_InvalidRepresentation",
        .CallMayTrap, .Unknown => null,
    };
}

test "mechanical renderer emits typed BlockId branch CFG" {
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const parameters = [_]mir.ExecutableParameter{
        .{ .local = mir.LocalId.fromIndex(0), .ty = .bool, .source = source },
        .{ .local = mir.LocalId.fromIndex(1), .ty = .{ .integer = "u32" }, .source = source },
    };
    const expressions = [_]mir.ExecutableExpression{
        .{ .id = mir.ExprId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = .bool, .operation = .{ .local = mir.LocalId.fromIndex(0) } },
        .{ .id = mir.ExprId.fromIndex(1), .block_id = mir.BlockId.fromIndex(1), .owner_statement = mir.InstId.fromIndex(1), .source = source, .result_ty = .{ .integer = "u32" }, .operation = .{ .local = mir.LocalId.fromIndex(1) } },
        .{ .id = mir.ExprId.fromIndex(2), .block_id = mir.BlockId.fromIndex(1), .owner_statement = mir.InstId.fromIndex(1), .source = source, .result_ty = .{ .integer = "u32" }, .operation = .{ .literal = .{ .integer = 1 } } },
        .{ .id = mir.ExprId.fromIndex(3), .block_id = mir.BlockId.fromIndex(1), .owner_statement = mir.InstId.fromIndex(1), .source = source, .result_ty = .{ .integer = "u32" }, .operation = .{ .binary = .{ .op = .bit_xor, .left = mir.ExprId.fromIndex(1), .right = mir.ExprId.fromIndex(2) } } },
        .{ .id = mir.ExprId.fromIndex(4), .block_id = mir.BlockId.fromIndex(2), .owner_statement = mir.InstId.fromIndex(2), .source = source, .result_ty = .{ .integer = "u32" }, .operation = .{ .local = mir.LocalId.fromIndex(1) } },
    };
    const statements = [_]mir.ExecutableStatement{
        .{ .id = mir.InstId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .guard = .{ .kind = .if_, .condition = mir.ExprId.fromIndex(0) } } },
        .{ .id = mir.InstId.fromIndex(1), .block_id = mir.BlockId.fromIndex(1), .source = source, .operation = .{ .return_ = mir.ExprId.fromIndex(3) } },
        .{ .id = mir.InstId.fromIndex(2), .block_id = mir.BlockId.fromIndex(2), .source = source, .operation = .{ .return_ = mir.ExprId.fromIndex(4) } },
    };
    const terminators = [_]mir.ExecutableTerminator{
        .{ .block_id = mir.BlockId.fromIndex(0), .operation = .{ .branch = .{ .condition = mir.ExprId.fromIndex(0), .true_block = mir.BlockId.fromIndex(1), .false_block = mir.BlockId.fromIndex(2) } } },
        .{ .block_id = mir.BlockId.fromIndex(1), .operation = .return_ },
        .{ .block_id = mir.BlockId.fromIndex(2), .operation = .return_ },
    };
    const body: mir.ExecutableBody = .{ .parameters = @constCast(&parameters), .expressions = @constCast(&expressions), .statements = @constCast(&statements), .terminators = @constCast(&terminators) };
    const rendered = try render(std.testing.allocator, &body, .{ .integer = "u32" });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "br i1 %mc_arg_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "mc_block_1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, " = xor i32 ") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, rendered, "ret i32"));
}

test "mechanical renderer emits checked-free integer arithmetic and logical not" {
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const int_ty: mir.ValueType = .{ .integer = "u32" };
    const parameters = [_]mir.ExecutableParameter{
        .{ .local = mir.LocalId.fromIndex(0), .ty = .bool, .source = source },
        .{ .local = mir.LocalId.fromIndex(1), .ty = int_ty, .source = source },
        .{ .local = mir.LocalId.fromIndex(2), .ty = int_ty, .source = source },
        .{ .local = mir.LocalId.fromIndex(3), .ty = int_ty, .source = source },
    };
    const expressions = [_]mir.ExecutableExpression{
        .{ .id = mir.ExprId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = .bool, .operation = .{ .local = mir.LocalId.fromIndex(0) } },
        .{ .id = mir.ExprId.fromIndex(1), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = .bool, .operation = .{ .unary = .{ .op = .logical_not, .operand = mir.ExprId.fromIndex(0) } } },
        .{ .id = mir.ExprId.fromIndex(2), .block_id = mir.BlockId.fromIndex(1), .owner_statement = mir.InstId.fromIndex(1), .source = source, .result_ty = int_ty, .operation = .{ .local = mir.LocalId.fromIndex(1) } },
        .{ .id = mir.ExprId.fromIndex(3), .block_id = mir.BlockId.fromIndex(1), .owner_statement = mir.InstId.fromIndex(1), .source = source, .result_ty = int_ty, .operation = .{ .local = mir.LocalId.fromIndex(2) } },
        .{ .id = mir.ExprId.fromIndex(4), .block_id = mir.BlockId.fromIndex(1), .owner_statement = mir.InstId.fromIndex(1), .source = source, .result_ty = int_ty, .operation = .{ .binary = .{ .op = .add, .left = mir.ExprId.fromIndex(2), .right = mir.ExprId.fromIndex(3) } } },
        .{ .id = mir.ExprId.fromIndex(5), .block_id = mir.BlockId.fromIndex(1), .owner_statement = mir.InstId.fromIndex(1), .source = source, .result_ty = int_ty, .operation = .{ .local = mir.LocalId.fromIndex(3) } },
        .{ .id = mir.ExprId.fromIndex(6), .block_id = mir.BlockId.fromIndex(1), .owner_statement = mir.InstId.fromIndex(1), .source = source, .result_ty = int_ty, .operation = .{ .binary = .{ .op = .sub, .left = mir.ExprId.fromIndex(4), .right = mir.ExprId.fromIndex(5) } } },
        .{ .id = mir.ExprId.fromIndex(7), .block_id = mir.BlockId.fromIndex(1), .owner_statement = mir.InstId.fromIndex(1), .source = source, .result_ty = int_ty, .operation = .{ .binary = .{ .op = .mul, .left = mir.ExprId.fromIndex(6), .right = mir.ExprId.fromIndex(3) } } },
        .{ .id = mir.ExprId.fromIndex(8), .block_id = mir.BlockId.fromIndex(2), .owner_statement = mir.InstId.fromIndex(2), .source = source, .result_ty = int_ty, .operation = .{ .literal = .{ .integer = 0 } } },
    };
    const statements = [_]mir.ExecutableStatement{
        .{ .id = mir.InstId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .guard = .{ .kind = .if_, .condition = mir.ExprId.fromIndex(1) } } },
        .{ .id = mir.InstId.fromIndex(1), .block_id = mir.BlockId.fromIndex(1), .source = source, .operation = .{ .return_ = mir.ExprId.fromIndex(7) } },
        .{ .id = mir.InstId.fromIndex(2), .block_id = mir.BlockId.fromIndex(2), .source = source, .operation = .{ .return_ = mir.ExprId.fromIndex(8) } },
    };
    const terminators = [_]mir.ExecutableTerminator{
        .{ .block_id = mir.BlockId.fromIndex(0), .operation = .{ .branch = .{ .condition = mir.ExprId.fromIndex(1), .true_block = mir.BlockId.fromIndex(1), .false_block = mir.BlockId.fromIndex(2) } } },
        .{ .block_id = mir.BlockId.fromIndex(1), .operation = .return_ },
        .{ .block_id = mir.BlockId.fromIndex(2), .operation = .return_ },
    };
    const body: mir.ExecutableBody = .{ .parameters = @constCast(&parameters), .expressions = @constCast(&expressions), .statements = @constCast(&statements), .terminators = @constCast(&terminators) };
    try std.testing.expect(supports(&body, int_ty));
    const rendered = try render(std.testing.allocator, &body, int_ty);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, " = xor i1 %mc_arg_0, true") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, " = add i32 %mc_arg_1, %mc_arg_2") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, " = sub i32 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, " = mul i32 ") != null);
}

test "mechanical renderer keeps arithmetic restricted to integer ValueType" {
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const parameters = [_]mir.ExecutableParameter{
        .{ .local = mir.LocalId.fromIndex(0), .ty = .{ .address = .vaddr }, .source = source },
        .{ .local = mir.LocalId.fromIndex(1), .ty = .{ .address = .vaddr }, .source = source },
    };
    const expressions = [_]mir.ExecutableExpression{
        .{ .id = mir.ExprId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = .{ .address = .vaddr }, .operation = .{ .local = mir.LocalId.fromIndex(0) } },
        .{ .id = mir.ExprId.fromIndex(1), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = .{ .address = .vaddr }, .operation = .{ .local = mir.LocalId.fromIndex(1) } },
        .{ .id = mir.ExprId.fromIndex(2), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = .{ .address = .vaddr }, .operation = .{ .binary = .{ .op = .add, .left = mir.ExprId.fromIndex(0), .right = mir.ExprId.fromIndex(1) } } },
    };
    const statements = [_]mir.ExecutableStatement{
        .{ .id = mir.InstId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .return_ = mir.ExprId.fromIndex(2) } },
    };
    const terminators = [_]mir.ExecutableTerminator{.{ .block_id = mir.BlockId.fromIndex(0), .operation = .return_ }};
    const body: mir.ExecutableBody = .{ .parameters = @constCast(&parameters), .expressions = @constCast(&expressions), .statements = @constCast(&statements), .terminators = @constCast(&terminators) };
    try std.testing.expect(!supports(&body, .{ .address = .vaddr }));
    try std.testing.expectError(error.Unsupported, render(std.testing.allocator, &body, .{ .address = .vaddr }));
}

test "mechanical renderer resolves direct calls by SymbolId" {
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const symbols = [_]mir.SymbolIdentity{.{ .id = mir.SymbolId.fromIndex(0), .spelling = "next_value" }};
    const locals = [_]mir.ExecutableLocalIdentity{.{ .id = mir.LocalId.fromIndex(0), .spelling = "renaming_does_not_select_semantics" }};
    const expressions = [_]mir.ExecutableExpression{
        .{ .id = mir.ExprId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = .{ .integer = "u32" }, .operation = .{ .direct_call = .{ .callee = mir.SymbolId.fromIndex(0), .callee_source = source } } },
        .{ .id = mir.ExprId.fromIndex(1), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(1), .source = source, .result_ty = .{ .integer = "u32" }, .operation = .{ .local = mir.LocalId.fromIndex(0) } },
    };
    const statements = [_]mir.ExecutableStatement{
        .{ .id = mir.InstId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .local_init = .{ .local = mir.LocalId.fromIndex(0), .ty = .{ .integer = "u32" }, .value = mir.ExprId.fromIndex(0), .mutable = false } } },
        .{ .id = mir.InstId.fromIndex(1), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .return_ = mir.ExprId.fromIndex(1) } },
    };
    const terminators = [_]mir.ExecutableTerminator{.{ .block_id = mir.BlockId.fromIndex(0), .operation = .return_ }};
    const body: mir.ExecutableBody = .{ .locals = @constCast(&locals), .symbols = @constCast(&symbols), .expressions = @constCast(&expressions), .statements = @constCast(&statements), .terminators = @constCast(&terminators) };
    const rendered = try render(std.testing.allocator, &body, .{ .integer = "u32" });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "call i32 @next_value()") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "%mc_local_0 = alloca i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "renaming_does_not_select_semantics") == null);
}

test "mechanical renderer applies normalized C ABI direct-call extensions" {
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const symbols = [_]mir.SymbolIdentity{.{ .id = mir.SymbolId.fromIndex(0), .spelling = "c_predicate" }};
    const parameters = [_]mir.ExecutableParameter{
        .{ .local = mir.LocalId.fromIndex(0), .ty = .bool, .source = source },
        .{ .local = mir.LocalId.fromIndex(1), .ty = .{ .integer = "u32" }, .source = source },
    };
    const expressions = [_]mir.ExecutableExpression{
        .{ .id = mir.ExprId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = .bool, .operation = .{ .local = mir.LocalId.fromIndex(0) } },
        .{ .id = mir.ExprId.fromIndex(1), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = .{ .integer = "u32" }, .operation = .{ .local = mir.LocalId.fromIndex(1) } },
        .{ .id = mir.ExprId.fromIndex(2), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = .bool, .operation = .{ .direct_call = .{
            .callee = mir.SymbolId.fromIndex(0),
            .callee_source = source,
            .arguments = .{ mir.ExprId.fromIndex(0), mir.ExprId.fromIndex(1) } ++ [_]mir.ExprId{.invalid} ** (mir.max_executable_operands - 2),
            .argument_count = 2,
        } } },
    };
    const statements = [_]mir.ExecutableStatement{
        .{ .id = mir.InstId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .return_ = mir.ExprId.fromIndex(2) } },
    };
    const terminators = [_]mir.ExecutableTerminator{.{ .block_id = mir.BlockId.fromIndex(0), .operation = .return_ }};
    const body: mir.ExecutableBody = .{
        .parameters = @constCast(&parameters),
        .symbols = @constCast(&symbols),
        .expressions = @constCast(&expressions),
        .statements = @constCast(&statements),
        .terminators = @constCast(&terminators),
    };
    var calls = [_]DirectCallAbi{.{
        .expression = mir.ExprId.fromIndex(2),
        .callee = mir.SymbolId.fromIndex(0),
        .fixed_arity = 2,
        .c_abi = true,
        .result_extension = .zeroext,
        .parameter_extensions = .{ .zeroext, .signext } ++ [_]AbiExtension{.none} ** (mir.max_executable_operands - 2),
    }};
    const plan: CallAbiPlan = .{ .target = .riscv64, .direct_calls = &calls };
    try std.testing.expect(supportsWithCallAbi(&body, .bool, plan));
    const rendered = try renderWithCallAbi(std.testing.allocator, &body, .bool, plan);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "call zeroext i1 @c_predicate(i1 zeroext %mc_arg_0, i32 signext %mc_arg_1)") != null);

    calls[0].result_extension = .none;
    try std.testing.expect(!supportsWithCallAbi(&body, .bool, plan));
    try std.testing.expectError(error.Unsupported, renderWithCallAbi(std.testing.allocator, &body, .bool, plan));
    calls[0].result_extension = .zeroext;
    calls[0].fixed_arity = 1;
    try std.testing.expect(!supportsWithCallAbi(&body, .bool, plan));

    // A missing target ABI classification is not equivalent to an ABI with no
    // extension attributes. Keep aggregate-like values on the legacy path.
    calls[0].fixed_arity = 2;
    calls[0].parameter_extensions[0] = .none;
    var unsupported_parameters = parameters;
    unsupported_parameters[0].ty = .{ .slice = "u8" };
    var unsupported_expressions = expressions;
    unsupported_expressions[0].result_ty = .{ .slice = "u8" };
    const unsupported_body: mir.ExecutableBody = .{
        .parameters = &unsupported_parameters,
        .symbols = @constCast(&symbols),
        .expressions = &unsupported_expressions,
        .statements = @constCast(&statements),
        .terminators = @constCast(&terminators),
    };
    try std.testing.expect(!supportsWithCallAbi(&unsupported_body, .bool, plan));
    try std.testing.expectError(error.Unsupported, renderWithCallAbi(std.testing.allocator, &unsupported_body, .bool, plan));
}

test "mechanical renderer classifies only supported C ABI direct-call types" {
    try std.testing.expect(cAbiDirectCallTypeSupported(.{ .domain_integer = .{ .kind = .wrap, .child = "u8" } }));
    try std.testing.expect(cAbiDirectCallTypeSupported(.{ .domain_integer = .{ .kind = .sat, .child = "i8" } }));
    try std.testing.expect(cAbiDirectCallTypeSupported(.{ .domain_integer = .{ .kind = .counter, .child = "u32" } }));
    try std.testing.expect(!cAbiDirectCallTypeSupported(.{ .struct_ = "Packet" }));
    try std.testing.expect(!cAbiDirectCallTypeSupported(.{ .slice = "u8" }));
    try std.testing.expect(!cAbiDirectCallTypeSupported(.unknown));

    try std.testing.expectEqual(AbiExtension.zeroext, abiExtension(.riscv64, .{ .domain_integer = .{ .kind = .wrap, .child = "u8" } }));
    try std.testing.expectEqual(AbiExtension.signext, abiExtension(.riscv64, .{ .domain_integer = .{ .kind = .sat, .child = "i8" } }));
    try std.testing.expectEqual(AbiExtension.signext, abiExtension(.riscv64, .{ .domain_integer = .{ .kind = .counter, .child = "u32" } }));
    try std.testing.expectEqual(AbiExtension.none, abiExtension(.aarch64, .{ .domain_integer = .{ .kind = .wrap, .child = "u8" } }));
}

test "mechanical renderer consumes exact statement-owned assertion trap edge" {
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const parameters = [_]mir.ExecutableParameter{
        .{ .local = mir.LocalId.fromIndex(0), .ty = .bool, .source = source },
    };
    const expressions = [_]mir.ExecutableExpression{
        .{ .id = mir.ExprId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = .bool, .operation = .{ .local = mir.LocalId.fromIndex(0) } },
    };
    const statements = [_]mir.ExecutableStatement{
        .{ .id = mir.InstId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .guard = .{ .kind = .assert_, .condition = mir.ExprId.fromIndex(0) } } },
        .{ .id = mir.InstId.fromIndex(1), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .return_ = null } },
    };
    var edge = [_]mir.ExecutableTrapEdge{.{
        .owner = .{ .statement = mir.InstId.fromIndex(0) },
        .from_block = mir.BlockId.fromIndex(0),
        .trap_block = mir.BlockId.fromIndex(1),
        .kind = .Assert,
        .source = .assert_stmt,
    }};
    const terminators = [_]mir.ExecutableTerminator{
        .{ .block_id = mir.BlockId.fromIndex(0), .operation = .return_ },
        .{ .block_id = mir.BlockId.fromIndex(1), .operation = .{ .trap_ = .Assert } },
    };
    var body: mir.ExecutableBody = .{
        .complete = true,
        .parameters = @constCast(&parameters),
        .expressions = @constCast(&expressions),
        .trap_edges = &edge,
        .statements = @constCast(&statements),
        .terminators = @constCast(&terminators),
    };
    try std.testing.expect(supports(&body, .void));
    const rendered = try render(std.testing.allocator, &body, .void);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "br i1 %mc_arg_0"));
    try std.testing.expect(std.mem.indexOf(u8, rendered, "label %mc_assert_ready_0, label %mc_block_1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "call void @mc_trap_Assert()") != null);

    edge[0].source = .bounds_check;
    try std.testing.expect(!supports(&body, .void));
    edge[0].source = .assert_stmt;
    const duplicate = [_]mir.ExecutableTrapEdge{ edge[0], edge[0] };
    body.trap_edges = @constCast(&duplicate);
    try std.testing.expect(!supports(&body, .void));
}

test "mechanical renderer hoists loop local alloca to the entry prologue" {
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const locals = [_]mir.ExecutableLocalIdentity{.{ .id = mir.LocalId.fromIndex(0), .spelling = "loop_local" }};
    const expressions = [_]mir.ExecutableExpression{
        .{ .id = mir.ExprId.fromIndex(0), .block_id = mir.BlockId.fromIndex(1), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = .{ .integer = "u32" }, .operation = .{ .literal = .{ .integer = 1 } } },
    };
    const statements = [_]mir.ExecutableStatement{
        .{ .id = mir.InstId.fromIndex(0), .block_id = mir.BlockId.fromIndex(1), .source = source, .operation = .{ .local_init = .{ .local = mir.LocalId.fromIndex(0), .ty = .{ .integer = "u32" }, .value = mir.ExprId.fromIndex(0), .mutable = true } } },
    };
    const terminators = [_]mir.ExecutableTerminator{
        .{ .block_id = mir.BlockId.fromIndex(0), .operation = .{ .jump = mir.BlockId.fromIndex(1) } },
        .{ .block_id = mir.BlockId.fromIndex(1), .operation = .{ .jump = mir.BlockId.fromIndex(1) } },
    };
    const body: mir.ExecutableBody = .{ .locals = @constCast(&locals), .expressions = @constCast(&expressions), .statements = @constCast(&statements), .terminators = @constCast(&terminators) };
    const rendered = try render(std.testing.allocator, &body, .void);
    defer std.testing.allocator.free(rendered);
    const alloca_at = std.mem.indexOf(u8, rendered, "%mc_local_0 = alloca i32") orelse return error.TestUnexpectedResult;
    const entry_branch_at = std.mem.indexOf(u8, rendered, "br label %mc_block_0") orelse return error.TestUnexpectedResult;
    try std.testing.expect(alloca_at < entry_branch_at);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "%mc_local_0 = alloca i32"));
}

test "mechanical renderer emits canonical floating comparison semantics" {
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const parameters = [_]mir.ExecutableParameter{
        .{ .local = mir.LocalId.fromIndex(0), .ty = .{ .float = "f32" }, .source = source },
        .{ .local = mir.LocalId.fromIndex(1), .ty = .{ .float = "f32" }, .source = source },
    };
    const expressions = [_]mir.ExecutableExpression{
        .{ .id = mir.ExprId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = .{ .float = "f32" }, .operation = .{ .local = mir.LocalId.fromIndex(0) } },
        .{ .id = mir.ExprId.fromIndex(1), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = .{ .float = "f32" }, .operation = .{ .local = mir.LocalId.fromIndex(1) } },
        .{ .id = mir.ExprId.fromIndex(2), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = .bool, .operation = .{ .binary = .{ .op = .eq, .left = mir.ExprId.fromIndex(0), .right = mir.ExprId.fromIndex(1) } } },
    };
    const statements = [_]mir.ExecutableStatement{
        .{ .id = mir.InstId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .return_ = mir.ExprId.fromIndex(2) } },
    };
    const terminators = [_]mir.ExecutableTerminator{.{ .block_id = mir.BlockId.fromIndex(0), .operation = .return_ }};
    const body: mir.ExecutableBody = .{ .parameters = @constCast(&parameters), .expressions = @constCast(&expressions), .statements = @constCast(&statements), .terminators = @constCast(&terminators) };
    try std.testing.expect(supports(&body, .bool));
    const rendered = try render(std.testing.allocator, &body, .bool);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "fcmp oeq float") != null);
}

test "mechanical renderer emits bit-exact canonical float literals" {
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const f32_ty: mir.ValueType = .{ .float = "f32" };
    const f64_ty: mir.ValueType = .{ .float = "f64" };
    const locals = [_]mir.ExecutableLocalIdentity{.{ .id = mir.LocalId.fromIndex(0), .spelling = "negative_zero" }};
    const expressions = [_]mir.ExecutableExpression{
        .{ .id = mir.ExprId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = f32_ty, .operation = .{ .literal = .{ .float = .{ .f32_bits = 0x8000_0000 } } } },
        .{ .id = mir.ExprId.fromIndex(1), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(1), .source = source, .result_ty = f64_ty, .operation = .{ .literal = .{ .float = .{ .f64_bits = 0x7ff8_0000_0000_0042 } } } },
    };
    const statements = [_]mir.ExecutableStatement{
        .{ .id = mir.InstId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .local_init = .{ .local = mir.LocalId.fromIndex(0), .ty = f32_ty, .value = mir.ExprId.fromIndex(0), .mutable = false } } },
        .{ .id = mir.InstId.fromIndex(1), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .return_ = mir.ExprId.fromIndex(1) } },
    };
    const terminators = [_]mir.ExecutableTerminator{.{ .block_id = mir.BlockId.fromIndex(0), .operation = .return_ }};
    const body: mir.ExecutableBody = .{
        .locals = @constCast(&locals),
        .expressions = @constCast(&expressions),
        .statements = @constCast(&statements),
        .terminators = @constCast(&terminators),
    };

    try std.testing.expect(supports(&body, f64_ty));
    const rendered = try render(std.testing.allocator, &body, f64_ty);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "store float bitcast (i32 2147483648 to float)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "ret double bitcast (i64 9221120237041090626 to double)") != null);
}

test "mechanical renderer rejects canonical float payload and type tag mismatch" {
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const f32_ty: mir.ValueType = .{ .float = "f32" };
    const f64_ty: mir.ValueType = .{ .float = "f64" };
    var expressions = [_]mir.ExecutableExpression{
        .{ .id = mir.ExprId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = f64_ty, .operation = .{ .literal = .{ .float = .{ .f32_bits = 0 } } } },
    };
    const statements = [_]mir.ExecutableStatement{
        .{ .id = mir.InstId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .return_ = mir.ExprId.fromIndex(0) } },
    };
    const terminators = [_]mir.ExecutableTerminator{.{ .block_id = mir.BlockId.fromIndex(0), .operation = .return_ }};
    const body: mir.ExecutableBody = .{
        .expressions = &expressions,
        .statements = @constCast(&statements),
        .terminators = @constCast(&terminators),
    };

    try std.testing.expect(!supports(&body, f64_ty));
    try std.testing.expectError(error.Unsupported, render(std.testing.allocator, &body, f64_ty));

    expressions[0].result_ty = f32_ty;
    expressions[0].operation = .{ .literal = .{ .float = .{ .f64_bits = 0 } } };
    try std.testing.expect(!supports(&body, f32_ty));
    try std.testing.expectError(error.Unsupported, render(std.testing.allocator, &body, f32_ty));
}

test "mechanical renderer rejects global value access without explicit load mode" {
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const symbols = [_]mir.SymbolIdentity{.{ .id = mir.SymbolId.fromIndex(0), .spelling = "global_count" }};
    const expressions = [_]mir.ExecutableExpression{
        .{ .id = mir.ExprId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = .{ .integer = "u32" }, .operation = .{ .symbol = mir.SymbolId.fromIndex(0) } },
    };
    const statements = [_]mir.ExecutableStatement{
        .{ .id = mir.InstId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .return_ = mir.ExprId.fromIndex(0) } },
    };
    const terminators = [_]mir.ExecutableTerminator{.{ .block_id = mir.BlockId.fromIndex(0), .operation = .return_ }};
    const body: mir.ExecutableBody = .{ .symbols = @constCast(&symbols), .expressions = @constCast(&expressions), .statements = @constCast(&statements), .terminators = @constCast(&terminators) };
    try std.testing.expect(!supports(&body, .{ .integer = "u32" }));
    try std.testing.expectError(error.Unsupported, render(std.testing.allocator, &body, .{ .integer = "u32" }));
}

test "mechanical renderer emits signed and unsigned checked add sub mul edges" {
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const Case = struct {
        type_name: []const u8,
        op: mir.ExecutableBinaryOp,
        intrinsic: []const u8,
    };
    const cases = [_]Case{
        .{ .type_name = "i32", .op = .add, .intrinsic = "@llvm.sadd.with.overflow.i32" },
        .{ .type_name = "i32", .op = .sub, .intrinsic = "@llvm.ssub.with.overflow.i32" },
        .{ .type_name = "i32", .op = .mul, .intrinsic = "@llvm.smul.with.overflow.i32" },
        .{ .type_name = "u32", .op = .add, .intrinsic = "@llvm.uadd.with.overflow.i32" },
        .{ .type_name = "u32", .op = .sub, .intrinsic = "@llvm.usub.with.overflow.i32" },
        .{ .type_name = "u32", .op = .mul, .intrinsic = "@llvm.umul.with.overflow.i32" },
    };

    for (cases) |case| {
        const int_ty: mir.ValueType = .{ .integer = case.type_name };
        const parameters = [_]mir.ExecutableParameter{
            .{ .local = mir.LocalId.fromIndex(0), .ty = int_ty, .source = source },
            .{ .local = mir.LocalId.fromIndex(1), .ty = int_ty, .source = source },
        };
        const expressions = [_]mir.ExecutableExpression{
            .{ .id = mir.ExprId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = int_ty, .operation = .{ .local = mir.LocalId.fromIndex(0) } },
            .{ .id = mir.ExprId.fromIndex(1), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = int_ty, .operation = .{ .local = mir.LocalId.fromIndex(1) } },
            .{ .id = mir.ExprId.fromIndex(2), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = int_ty, .operation = .{ .binary = .{ .op = case.op, .left = mir.ExprId.fromIndex(0), .right = mir.ExprId.fromIndex(1), .arithmetic = .checked } } },
        };
        const trap_edges = [_]mir.ExecutableTrapEdge{.{
            .owner = .{ .expression = mir.ExprId.fromIndex(2) },
            .from_block = mir.BlockId.fromIndex(0),
            .trap_block = mir.BlockId.fromIndex(1),
            .kind = .IntegerOverflow,
            .source = .checked_arithmetic,
        }};
        const statements = [_]mir.ExecutableStatement{
            .{ .id = mir.InstId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .return_ = mir.ExprId.fromIndex(2) } },
        };
        const terminators = [_]mir.ExecutableTerminator{
            .{ .block_id = mir.BlockId.fromIndex(0), .operation = .return_ },
            .{ .block_id = mir.BlockId.fromIndex(1), .operation = .{ .trap_ = .IntegerOverflow } },
        };
        const body: mir.ExecutableBody = .{
            .parameters = @constCast(&parameters),
            .expressions = @constCast(&expressions),
            .trap_edges = @constCast(&trap_edges),
            .statements = @constCast(&statements),
            .terminators = @constCast(&terminators),
        };

        try std.testing.expect(supports(&body, int_ty));
        const rendered = try render(std.testing.allocator, &body, int_ty);
        defer std.testing.allocator.free(rendered);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, case.intrinsic));
        try std.testing.expect(std.mem.indexOf(u8, rendered, " = extractvalue { i32, i1 }") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "label %mc_block_1, label %mc_checked_cont_2") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "mc_checked_cont_2:") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "call void @mc_trap_IntegerOverflow()") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, " nsw ") == null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, " nuw ") == null);
    }
}

test "mechanical renderer guards checked div mod and shifts before unsafe operations" {
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const Case = struct {
        type_name: []const u8,
        op: mir.ExecutableBinaryOp,
        rendered_operation: []const u8,
    };
    const cases = [_]Case{
        .{ .type_name = "u32", .op = .div, .rendered_operation = " = udiv i32 " },
        .{ .type_name = "i32", .op = .div, .rendered_operation = " = sdiv i32 " },
        .{ .type_name = "u32", .op = .mod, .rendered_operation = " = urem i32 " },
        .{ .type_name = "i32", .op = .mod, .rendered_operation = " = srem i32 " },
        .{ .type_name = "u32", .op = .shl, .rendered_operation = " = shl i64 " },
        .{ .type_name = "i32", .op = .shl, .rendered_operation = " = shl i64 " },
        .{ .type_name = "u32", .op = .shr, .rendered_operation = " = lshr i32 " },
        .{ .type_name = "i32", .op = .shr, .rendered_operation = " = ashr i32 " },
    };

    for (cases) |case| {
        const int_ty: mir.ValueType = .{ .integer = case.type_name };
        const parameters = [_]mir.ExecutableParameter{
            .{ .local = mir.LocalId.fromIndex(0), .ty = int_ty, .source = source },
            .{ .local = mir.LocalId.fromIndex(1), .ty = int_ty, .source = source },
        };
        const expressions = [_]mir.ExecutableExpression{
            .{ .id = mir.ExprId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = int_ty, .operation = .{ .local = mir.LocalId.fromIndex(0) } },
            .{ .id = mir.ExprId.fromIndex(1), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = int_ty, .operation = .{ .local = mir.LocalId.fromIndex(1) } },
            .{ .id = mir.ExprId.fromIndex(2), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = int_ty, .operation = .{ .binary = .{ .op = case.op, .left = mir.ExprId.fromIndex(0), .right = mir.ExprId.fromIndex(1), .arithmetic = .checked } } },
        };
        const requirements = mir.executableCheckedBinaryTrapRequirements(case.op, int_ty) orelse return error.TestUnexpectedResult;
        var edges: [2]mir.ExecutableTrapEdge = undefined;
        var terminators: [3]mir.ExecutableTerminator = undefined;
        terminators[0] = .{ .block_id = mir.BlockId.fromIndex(0), .operation = .return_ };
        for (requirements.items[0..requirements.count], 0..) |requirement, index| {
            const trap_block = mir.BlockId.fromIndex(index + 1);
            edges[index] = .{
                .owner = .{ .expression = mir.ExprId.fromIndex(2) },
                .from_block = mir.BlockId.fromIndex(0),
                .trap_block = trap_block,
                .kind = requirement.kind,
                .source = requirement.source,
            };
            terminators[index + 1] = .{ .block_id = trap_block, .operation = .{ .trap_ = requirement.kind } };
        }
        const statements = [_]mir.ExecutableStatement{
            .{ .id = mir.InstId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .return_ = mir.ExprId.fromIndex(2) } },
        };
        const body: mir.ExecutableBody = .{
            .parameters = @constCast(&parameters),
            .expressions = @constCast(&expressions),
            .trap_edges = edges[0..requirements.count],
            .statements = @constCast(&statements),
            .terminators = terminators[0 .. requirements.count + 1],
        };

        try std.testing.expect(supports(&body, int_ty));
        const rendered = try render(std.testing.allocator, &body, int_ty);
        defer std.testing.allocator.free(rendered);
        const operation_at = std.mem.indexOf(u8, rendered, case.rendered_operation) orelse return error.TestUnexpectedResult;
        if (case.op == .div or case.op == .mod) {
            const zero_check_at = std.mem.indexOf(u8, rendered, " = icmp eq i32 %mc_arg_1, 0") orelse return error.TestUnexpectedResult;
            try std.testing.expect(zero_check_at < operation_at);
            if (case.type_name[0] == 'i') {
                const signed_overflow_at = std.mem.indexOf(u8, rendered, " = and i1 ") orelse return error.TestUnexpectedResult;
                try std.testing.expect(signed_overflow_at < operation_at);
                try std.testing.expect(std.mem.indexOf(u8, rendered, "icmp eq i32 %mc_arg_0, -2147483648") != null);
                try std.testing.expect(std.mem.indexOf(u8, rendered, "call void @mc_trap_IntegerOverflow()") != null);
            }
            try std.testing.expect(std.mem.indexOf(u8, rendered, "call void @mc_trap_DivideByZero()") != null);
        } else {
            const range_check_at = std.mem.indexOf(u8, rendered, " = icmp uge i32 %mc_arg_1, 32") orelse return error.TestUnexpectedResult;
            try std.testing.expect(range_check_at < operation_at);
            try std.testing.expect(std.mem.indexOf(u8, rendered, "call void @mc_trap_InvalidShift()") != null);
            if (case.op == .shl) {
                const overflow_check_at = std.mem.indexOf(u8, rendered, " = icmp ne i64 ") orelse return error.TestUnexpectedResult;
                try std.testing.expect(operation_at < overflow_check_at);
                try std.testing.expect(std.mem.indexOf(u8, rendered, " = shl i32 ") == null);
                try std.testing.expect(std.mem.indexOf(u8, rendered, "call void @mc_trap_IntegerOverflow()") != null);
            }
        }
    }
}

test "mechanical renderer rejects checked div and shift trap requirement drift" {
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const int_ty: mir.ValueType = .{ .integer = "i32" };
    const parameters = [_]mir.ExecutableParameter{
        .{ .local = mir.LocalId.fromIndex(0), .ty = int_ty, .source = source },
        .{ .local = mir.LocalId.fromIndex(1), .ty = int_ty, .source = source },
    };
    var expressions = [_]mir.ExecutableExpression{
        .{ .id = mir.ExprId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = int_ty, .operation = .{ .local = mir.LocalId.fromIndex(0) } },
        .{ .id = mir.ExprId.fromIndex(1), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = int_ty, .operation = .{ .local = mir.LocalId.fromIndex(1) } },
        .{ .id = mir.ExprId.fromIndex(2), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = int_ty, .operation = .{ .binary = .{ .op = .div, .left = mir.ExprId.fromIndex(0), .right = mir.ExprId.fromIndex(1), .arithmetic = .checked } } },
    };
    var edges = [_]mir.ExecutableTrapEdge{
        .{ .owner = .{ .expression = mir.ExprId.fromIndex(2) }, .from_block = mir.BlockId.fromIndex(0), .trap_block = mir.BlockId.fromIndex(1), .kind = .DivideByZero, .source = .checked_arithmetic },
        .{ .owner = .{ .expression = mir.ExprId.fromIndex(2) }, .from_block = mir.BlockId.fromIndex(0), .trap_block = mir.BlockId.fromIndex(2), .kind = .IntegerOverflow, .source = .checked_arithmetic },
    };
    const statements = [_]mir.ExecutableStatement{
        .{ .id = mir.InstId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .return_ = mir.ExprId.fromIndex(2) } },
    };
    var terminators = [_]mir.ExecutableTerminator{
        .{ .block_id = mir.BlockId.fromIndex(0), .operation = .return_ },
        .{ .block_id = mir.BlockId.fromIndex(1), .operation = .{ .trap_ = .DivideByZero } },
        .{ .block_id = mir.BlockId.fromIndex(2), .operation = .{ .trap_ = .IntegerOverflow } },
    };
    const body: mir.ExecutableBody = .{
        .parameters = @constCast(&parameters),
        .expressions = &expressions,
        .trap_edges = &edges,
        .statements = @constCast(&statements),
        .terminators = &terminators,
    };
    try std.testing.expect(supports(&body, int_ty));

    const saved_overflow = edges[1];
    edges[1] = edges[0];
    try std.testing.expect(!supports(&body, int_ty));
    edges[1] = saved_overflow;

    edges[1].source = .checked_shift;
    try std.testing.expect(!supports(&body, int_ty));
    edges[1].source = .checked_arithmetic;

    terminators[2].operation = .{ .trap_ = .DivideByZero };
    try std.testing.expect(!supports(&body, int_ty));
    terminators[2].operation = .{ .trap_ = .IntegerOverflow };

    expressions[2].operation.binary.op = .shl;
    try std.testing.expect(!supports(&body, int_ty));
    expressions[2].operation.binary.op = .div;

    edges[0].from_block = mir.BlockId.fromIndex(2);
    try std.testing.expect(!supports(&body, int_ty));
}

test "mechanical renderer rejects mutated checked arithmetic trap edges" {
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const int_ty: mir.ValueType = .{ .integer = "u32" };
    const parameters = [_]mir.ExecutableParameter{
        .{ .local = mir.LocalId.fromIndex(0), .ty = int_ty, .source = source },
        .{ .local = mir.LocalId.fromIndex(1), .ty = int_ty, .source = source },
    };
    const expressions = [_]mir.ExecutableExpression{
        .{ .id = mir.ExprId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = int_ty, .operation = .{ .local = mir.LocalId.fromIndex(0) } },
        .{ .id = mir.ExprId.fromIndex(1), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = int_ty, .operation = .{ .local = mir.LocalId.fromIndex(1) } },
        .{ .id = mir.ExprId.fromIndex(2), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = int_ty, .operation = .{ .binary = .{ .op = .add, .left = mir.ExprId.fromIndex(0), .right = mir.ExprId.fromIndex(1), .arithmetic = .checked } } },
    };
    const statements = [_]mir.ExecutableStatement{
        .{ .id = mir.InstId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .return_ = mir.ExprId.fromIndex(2) } },
    };
    const valid_terminators = [_]mir.ExecutableTerminator{
        .{ .block_id = mir.BlockId.fromIndex(0), .operation = .return_ },
        .{ .block_id = mir.BlockId.fromIndex(1), .operation = .{ .trap_ = .IntegerOverflow } },
    };
    const valid_edge: mir.ExecutableTrapEdge = .{
        .owner = .{ .expression = mir.ExprId.fromIndex(2) },
        .from_block = mir.BlockId.fromIndex(0),
        .trap_block = mir.BlockId.fromIndex(1),
        .kind = .IntegerOverflow,
        .source = .checked_arithmetic,
    };

    const empty_edges = [_]mir.ExecutableTrapEdge{};
    const missing: mir.ExecutableBody = .{ .parameters = @constCast(&parameters), .expressions = @constCast(&expressions), .trap_edges = @constCast(&empty_edges), .statements = @constCast(&statements), .terminators = @constCast(&valid_terminators) };
    try std.testing.expect(!supports(&missing, int_ty));
    try std.testing.expectError(error.Unsupported, render(std.testing.allocator, &missing, int_ty));

    var wrong_kind = valid_edge;
    wrong_kind.kind = .DivideByZero;
    const wrong_kind_edges = [_]mir.ExecutableTrapEdge{wrong_kind};
    const wrong_kind_body: mir.ExecutableBody = .{ .parameters = @constCast(&parameters), .expressions = @constCast(&expressions), .trap_edges = @constCast(&wrong_kind_edges), .statements = @constCast(&statements), .terminators = @constCast(&valid_terminators) };
    try std.testing.expect(!supports(&wrong_kind_body, int_ty));

    var wrong_source = valid_edge;
    wrong_source.source = .checked_shift;
    const wrong_source_edges = [_]mir.ExecutableTrapEdge{wrong_source};
    const wrong_source_body: mir.ExecutableBody = .{ .parameters = @constCast(&parameters), .expressions = @constCast(&expressions), .trap_edges = @constCast(&wrong_source_edges), .statements = @constCast(&statements), .terminators = @constCast(&valid_terminators) };
    try std.testing.expect(!supports(&wrong_source_body, int_ty));

    const duplicate_edges = [_]mir.ExecutableTrapEdge{ valid_edge, valid_edge };
    const duplicate_body: mir.ExecutableBody = .{ .parameters = @constCast(&parameters), .expressions = @constCast(&expressions), .trap_edges = @constCast(&duplicate_edges), .statements = @constCast(&statements), .terminators = @constCast(&valid_terminators) };
    try std.testing.expect(!supports(&duplicate_body, int_ty));

    var wrong_owner = valid_edge;
    wrong_owner.owner = .{ .expression = mir.ExprId.fromIndex(0) };
    const wrong_owner_edges = [_]mir.ExecutableTrapEdge{wrong_owner};
    const wrong_owner_body: mir.ExecutableBody = .{ .parameters = @constCast(&parameters), .expressions = @constCast(&expressions), .trap_edges = @constCast(&wrong_owner_edges), .statements = @constCast(&statements), .terminators = @constCast(&valid_terminators) };
    try std.testing.expect(!supports(&wrong_owner_body, int_ty));

    const wrong_trap_terminators = [_]mir.ExecutableTerminator{
        .{ .block_id = mir.BlockId.fromIndex(0), .operation = .return_ },
        .{ .block_id = mir.BlockId.fromIndex(1), .operation = .{ .trap_ = .DivideByZero } },
    };
    const valid_edges = [_]mir.ExecutableTrapEdge{valid_edge};
    const wrong_trap_body: mir.ExecutableBody = .{ .parameters = @constCast(&parameters), .expressions = @constCast(&expressions), .trap_edges = @constCast(&valid_edges), .statements = @constCast(&statements), .terminators = @constCast(&wrong_trap_terminators) };
    try std.testing.expect(!supports(&wrong_trap_body, int_ty));
}

test "mechanical renderer emits plain immutable global load" {
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const int_ty: mir.ValueType = .{ .integer = "u32" };
    const symbols = [_]mir.SymbolIdentity{.{ .id = mir.SymbolId.fromIndex(0), .spelling = "constant_count", .kind = .global, .mutable = false }};
    const places = [_]mir.ExecutablePlace{.{ .id = mir.PlaceId.fromIndex(0), .source = source, .root = .{ .symbol = mir.SymbolId.fromIndex(0) } }};
    const expressions = [_]mir.ExecutableExpression{.{
        .id = mir.ExprId.fromIndex(0),
        .block_id = mir.BlockId.fromIndex(0),
        .owner_statement = mir.InstId.fromIndex(0),
        .source = source,
        .result_ty = int_ty,
        .operation = .{ .load = .{ .place = mir.PlaceId.fromIndex(0), .access = .{ .kind = .plain, .alignment = 4 } } },
    }};
    const statements = [_]mir.ExecutableStatement{.{ .id = mir.InstId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .return_ = mir.ExprId.fromIndex(0) } }};
    const terminators = [_]mir.ExecutableTerminator{.{ .block_id = mir.BlockId.fromIndex(0), .operation = .return_ }};
    const body: mir.ExecutableBody = .{
        .symbols = @constCast(&symbols),
        .expressions = @constCast(&expressions),
        .places = @constCast(&places),
        .statements = @constCast(&statements),
        .terminators = @constCast(&terminators),
    };

    try std.testing.expect(supports(&body, int_ty));
    const rendered = try render(std.testing.allocator, &body, int_ty);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "load i32, ptr @constant_count, align 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "load atomic") == null);
}

test "mechanical renderer emits race-unordered mutable bool global load and store" {
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const parameters = [_]mir.ExecutableParameter{.{ .local = mir.LocalId.fromIndex(0), .ty = .bool, .source = source }};
    const symbols = [_]mir.SymbolIdentity{.{ .id = mir.SymbolId.fromIndex(0), .spelling = "ready", .kind = .global, .mutable = true }};
    const places = [_]mir.ExecutablePlace{.{ .id = mir.PlaceId.fromIndex(0), .source = source, .root = .{ .symbol = mir.SymbolId.fromIndex(0) } }};
    const expressions = [_]mir.ExecutableExpression{
        .{ .id = mir.ExprId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = .bool, .operation = .{ .local = mir.LocalId.fromIndex(0) } },
        .{ .id = mir.ExprId.fromIndex(1), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(1), .source = source, .result_ty = .bool, .operation = .{ .load = .{ .place = mir.PlaceId.fromIndex(0), .access = .{ .kind = .race_unordered, .alignment = 1 } } } },
    };
    const statements = [_]mir.ExecutableStatement{
        .{ .id = mir.InstId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .store = .{ .place = mir.PlaceId.fromIndex(0), .value = mir.ExprId.fromIndex(0), .ty = .bool, .access = .{ .kind = .race_unordered, .alignment = 1 } } } },
        .{ .id = mir.InstId.fromIndex(1), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .return_ = mir.ExprId.fromIndex(1) } },
    };
    const terminators = [_]mir.ExecutableTerminator{.{ .block_id = mir.BlockId.fromIndex(0), .operation = .return_ }};
    const body: mir.ExecutableBody = .{
        .parameters = @constCast(&parameters),
        .symbols = @constCast(&symbols),
        .expressions = @constCast(&expressions),
        .places = @constCast(&places),
        .statements = @constCast(&statements),
        .terminators = @constCast(&terminators),
    };

    try std.testing.expect(supports(&body, .bool));
    const rendered = try render(std.testing.allocator, &body, .bool);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "zext i1 %mc_arg_0 to i8") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "store atomic i8") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "ptr @ready unordered, align 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "load atomic i8, ptr @ready unordered, align 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "trunc i8") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, " to i1") != null);
}

test "mechanical renderer preserves plain local stores" {
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const int_ty: mir.ValueType = .{ .integer = "u32" };
    const locals = [_]mir.ExecutableLocalIdentity{.{ .id = mir.LocalId.fromIndex(0), .spelling = "value" }};
    const places = [_]mir.ExecutablePlace{.{ .id = mir.PlaceId.fromIndex(0), .source = source, .root = .{ .local = mir.LocalId.fromIndex(0) } }};
    const expressions = [_]mir.ExecutableExpression{
        .{ .id = mir.ExprId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(1), .source = source, .result_ty = int_ty, .operation = .{ .literal = .{ .integer = 7 } } },
        .{ .id = mir.ExprId.fromIndex(1), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(2), .source = source, .result_ty = int_ty, .operation = .{ .local = mir.LocalId.fromIndex(0) } },
    };
    const statements = [_]mir.ExecutableStatement{
        .{ .id = mir.InstId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .local_init = .{ .local = mir.LocalId.fromIndex(0), .ty = int_ty, .value = null, .mutable = true } } },
        .{ .id = mir.InstId.fromIndex(1), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .store = .{ .place = mir.PlaceId.fromIndex(0), .value = mir.ExprId.fromIndex(0), .ty = int_ty, .access = .{ .kind = .plain, .alignment = 4 } } } },
        .{ .id = mir.InstId.fromIndex(2), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .return_ = mir.ExprId.fromIndex(1) } },
    };
    const terminators = [_]mir.ExecutableTerminator{.{ .block_id = mir.BlockId.fromIndex(0), .operation = .return_ }};
    const body: mir.ExecutableBody = .{ .locals = @constCast(&locals), .expressions = @constCast(&expressions), .places = @constCast(&places), .statements = @constCast(&statements), .terminators = @constCast(&terminators) };

    try std.testing.expect(supports(&body, int_ty));
    const rendered = try render(std.testing.allocator, &body, int_ty);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "store i32 7, ptr %mc_local_0, align 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "store atomic") == null);
}

test "mechanical renderer rejects mutated scalar memory access facts" {
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const int_ty: mir.ValueType = .{ .integer = "u32" };
    const mutable_symbols = [_]mir.SymbolIdentity{.{ .id = mir.SymbolId.fromIndex(0), .spelling = "count", .kind = .global, .mutable = true }};
    const places = [_]mir.ExecutablePlace{.{ .id = mir.PlaceId.fromIndex(0), .source = source, .root = .{ .symbol = mir.SymbolId.fromIndex(0) } }};
    const statements = [_]mir.ExecutableStatement{.{ .id = mir.InstId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .return_ = mir.ExprId.fromIndex(0) } }};
    const terminators = [_]mir.ExecutableTerminator{.{ .block_id = mir.BlockId.fromIndex(0), .operation = .return_ }};

    var expression: mir.ExecutableExpression = .{ .id = mir.ExprId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = int_ty, .operation = .{ .load = .{ .place = mir.PlaceId.fromIndex(0), .access = .{ .kind = .race_unordered, .alignment = 2 } } } };
    var expressions = [_]mir.ExecutableExpression{expression};
    var body: mir.ExecutableBody = .{ .symbols = @constCast(&mutable_symbols), .expressions = &expressions, .places = @constCast(&places), .statements = @constCast(&statements), .terminators = @constCast(&terminators) };
    try std.testing.expect(!supports(&body, int_ty));

    expression.operation.load.access = .{ .kind = .plain, .alignment = 4 };
    expressions[0] = expression;
    try std.testing.expect(!supports(&body, int_ty));

    const function_symbols = [_]mir.SymbolIdentity{.{ .id = mir.SymbolId.fromIndex(0), .spelling = "count", .kind = .function, .mutable = false }};
    expression.operation.load.access = .{ .kind = .plain, .alignment = 4 };
    expressions[0] = expression;
    body.symbols = @constCast(&function_symbols);
    try std.testing.expect(!supports(&body, int_ty));
    try std.testing.expectError(error.Unsupported, render(std.testing.allocator, &body, int_ty));
}

test "mechanical renderer emits canonical restricted integer casts" {
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const Case = struct {
        source_name: []const u8,
        target_name: []const u8,
        kind: mir.ExecutableCastKind,
        instruction: ?[]const u8,
    };
    const cases = [_]Case{
        .{ .source_name = "u32", .target_name = "u32", .kind = .identity, .instruction = null },
        .{ .source_name = "u8", .target_name = "u32", .kind = .unsigned_resize, .instruction = "zext i8 %mc_arg_0 to i32" },
        .{ .source_name = "u32", .target_name = "u8", .kind = .unsigned_resize, .instruction = "trunc i32 %mc_arg_0 to i8" },
        .{ .source_name = "u64", .target_name = "usize", .kind = .unsigned_resize, .instruction = null },
        .{ .source_name = "i8", .target_name = "i32", .kind = .signed_widen, .instruction = "sext i8 %mc_arg_0 to i32" },
        .{ .source_name = "i64", .target_name = "isize", .kind = .signed_widen, .instruction = null },
    };

    for (cases) |case| {
        const source_ty: mir.ValueType = .{ .integer = case.source_name };
        const target_ty: mir.ValueType = .{ .integer = case.target_name };
        const parameters = [_]mir.ExecutableParameter{.{ .local = mir.LocalId.fromIndex(0), .ty = source_ty, .source = source }};
        const expressions = [_]mir.ExecutableExpression{
            .{ .id = mir.ExprId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = source_ty, .operation = .{ .local = mir.LocalId.fromIndex(0) } },
            .{ .id = mir.ExprId.fromIndex(1), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = target_ty, .operation = .{ .cast = .{ .operand = mir.ExprId.fromIndex(0), .kind = case.kind } } },
        };
        const statements = [_]mir.ExecutableStatement{.{ .id = mir.InstId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .return_ = mir.ExprId.fromIndex(1) } }};
        const terminators = [_]mir.ExecutableTerminator{.{ .block_id = mir.BlockId.fromIndex(0), .operation = .return_ }};
        const body: mir.ExecutableBody = .{ .parameters = @constCast(&parameters), .expressions = @constCast(&expressions), .statements = @constCast(&statements), .terminators = @constCast(&terminators) };

        try std.testing.expect(supports(&body, target_ty));
        const rendered = try render(std.testing.allocator, &body, target_ty);
        defer std.testing.allocator.free(rendered);
        if (case.instruction) |instruction| {
            try std.testing.expect(std.mem.indexOf(u8, rendered, instruction) != null);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, rendered, " = zext ") == null);
            try std.testing.expect(std.mem.indexOf(u8, rendered, " = trunc ") == null);
            try std.testing.expect(std.mem.indexOf(u8, rendered, " = sext ") == null);
            try std.testing.expect(std.mem.indexOf(u8, rendered, "%mc_arg_0") != null);
        }
    }
}

test "mechanical renderer rejects mutated restricted cast facts" {
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const source_ty: mir.ValueType = .{ .integer = "u8" };
    const target_ty: mir.ValueType = .{ .integer = "u32" };
    const parameters = [_]mir.ExecutableParameter{.{ .local = mir.LocalId.fromIndex(0), .ty = source_ty, .source = source }};
    var cast_expression: mir.ExecutableExpression = .{ .id = mir.ExprId.fromIndex(1), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = target_ty, .operation = .{ .cast = .{ .operand = mir.ExprId.fromIndex(0), .kind = .signed_widen } } };
    var expressions = [_]mir.ExecutableExpression{
        .{ .id = mir.ExprId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .owner_statement = mir.InstId.fromIndex(0), .source = source, .result_ty = source_ty, .operation = .{ .local = mir.LocalId.fromIndex(0) } },
        cast_expression,
    };
    const statements = [_]mir.ExecutableStatement{.{ .id = mir.InstId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .return_ = mir.ExprId.fromIndex(1) } }};
    const terminators = [_]mir.ExecutableTerminator{.{ .block_id = mir.BlockId.fromIndex(0), .operation = .return_ }};
    var body: mir.ExecutableBody = .{ .parameters = @constCast(&parameters), .expressions = &expressions, .statements = @constCast(&statements), .terminators = @constCast(&terminators) };

    try std.testing.expect(!supports(&body, target_ty));
    try std.testing.expectError(error.Unsupported, render(std.testing.allocator, &body, target_ty));

    const signed_source_ty: mir.ValueType = .{ .integer = "i32" };
    const signed_target_ty: mir.ValueType = .{ .integer = "i8" };
    const signed_parameters = [_]mir.ExecutableParameter{.{ .local = mir.LocalId.fromIndex(0), .ty = signed_source_ty, .source = source }};
    expressions[0].result_ty = signed_source_ty;
    cast_expression.result_ty = signed_target_ty;
    cast_expression.operation.cast.kind = .signed_widen;
    expressions[1] = cast_expression;
    body.parameters = @constCast(&signed_parameters);
    try std.testing.expect(!supports(&body, signed_target_ty));
}

fn renderBuiltinForTest(allocator: std.mem.Allocator, kind: mir.CallTargetKind, operand_types: []const mir.ValueType, result_ty: mir.ValueType) RenderError![]u8 {
    if (operand_types.len > mir.max_executable_operands) return error.Unsupported;
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    var parameters: [mir.max_executable_operands]mir.ExecutableParameter = undefined;
    var expressions: [mir.max_executable_operands + 1]mir.ExecutableExpression = undefined;
    var arguments = [_]mir.ExprId{mir.ExprId.invalid} ** mir.max_executable_operands;
    for (operand_types, 0..) |operand_ty, index| {
        const local = mir.LocalId.fromIndex(index);
        const expression = mir.ExprId.fromIndex(index);
        parameters[index] = .{ .local = local, .ty = operand_ty, .source = source };
        expressions[index] = .{
            .id = expression,
            .block_id = mir.BlockId.fromIndex(0),
            .owner_statement = mir.InstId.fromIndex(0),
            .source = source,
            .result_ty = operand_ty,
            .operation = .{ .local = local },
        };
        arguments[index] = expression;
    }
    const result_id = mir.ExprId.fromIndex(operand_types.len);
    expressions[operand_types.len] = .{
        .id = result_id,
        .block_id = mir.BlockId.fromIndex(0),
        .owner_statement = mir.InstId.fromIndex(0),
        .source = source,
        .result_ty = result_ty,
        .operation = .{ .builtin_call = .{
            .kind = kind,
            .callee_source = source,
            .arguments = arguments,
            .argument_count = operand_types.len,
        } },
    };
    const statements = [_]mir.ExecutableStatement{.{ .id = mir.InstId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .return_ = result_id } }};
    const terminators = [_]mir.ExecutableTerminator{.{ .block_id = mir.BlockId.fromIndex(0), .operation = .return_ }};
    const body: mir.ExecutableBody = .{
        .parameters = parameters[0..operand_types.len],
        .expressions = expressions[0 .. operand_types.len + 1],
        .statements = @constCast(&statements),
        .terminators = @constCast(&terminators),
    };
    return render(allocator, &body, result_ty);
}

test "mechanical renderer emits selected canonical builtins" {
    const unsigned_source = [_]mir.ValueType{.{ .integer = "u8" }};
    const signed_source = [_]mir.ValueType{.{ .integer = "i8" }};
    const same_width_source = [_]mir.ValueType{.{ .integer = "u64" }};
    const wrapping_operands = [_]mir.ValueType{ .{ .integer = "u32" }, .{ .integer = "u32" } };
    const u32_source = [_]mir.ValueType{.{ .integer = "u32" }};
    const f64_source = [_]mir.ValueType{.{ .float = "f64" }};
    const i32_source = [_]mir.ValueType{.{ .integer = "i32" }};

    const phys = try renderBuiltinForTest(std.testing.allocator, .phys, &same_width_source, .{ .address = .paddr });
    defer std.testing.allocator.free(phys);
    try std.testing.expect(std.mem.indexOf(u8, phys, "ret i64 %mc_arg_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, phys, " = trunc ") == null);

    const wrapping = try renderBuiltinForTest(std.testing.allocator, .wrapping_add, &wrapping_operands, .{ .integer = "u32" });
    defer std.testing.allocator.free(wrapping);
    try std.testing.expect(std.mem.indexOf(u8, wrapping, " = add i32 %mc_arg_0, %mc_arg_1") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrapping, " nsw ") == null);
    try std.testing.expect(std.mem.indexOf(u8, wrapping, " nuw ") == null);

    const unsigned_conversion = try renderBuiltinForTest(std.testing.allocator, .conversion_from, &unsigned_source, .{ .integer = "u32" });
    defer std.testing.allocator.free(unsigned_conversion);
    try std.testing.expect(std.mem.indexOf(u8, unsigned_conversion, "zext i8 %mc_arg_0 to i32") != null);

    const signed_conversion = try renderBuiltinForTest(std.testing.allocator, .conversion_from, &signed_source, .{ .integer = "i32" });
    defer std.testing.allocator.free(signed_conversion);
    try std.testing.expect(std.mem.indexOf(u8, signed_conversion, "sext i8 %mc_arg_0 to i32") != null);

    const same_width_conversion = try renderBuiltinForTest(std.testing.allocator, .conversion_from, &same_width_source, .{ .integer = "usize" });
    defer std.testing.allocator.free(same_width_conversion);
    try std.testing.expect(std.mem.indexOf(u8, same_width_conversion, "ret i64 %mc_arg_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, same_width_conversion, " = zext ") == null);

    const bits_float = try renderBuiltinForTest(std.testing.allocator, .bitcast, &u32_source, .{ .float = "f32" });
    defer std.testing.allocator.free(bits_float);
    try std.testing.expect(std.mem.indexOf(u8, bits_float, " = bitcast i32 %mc_arg_0 to float") != null);

    const float_bits = try renderBuiltinForTest(std.testing.allocator, .bitcast, &f64_source, .{ .integer = "u64" });
    defer std.testing.allocator.free(float_bits);
    try std.testing.expect(std.mem.indexOf(u8, float_bits, " = bitcast double %mc_arg_0 to i64") != null);

    const same_llvm_type = try renderBuiltinForTest(std.testing.allocator, .bitcast, &i32_source, .{ .integer = "u32" });
    defer std.testing.allocator.free(same_llvm_type);
    try std.testing.expect(std.mem.indexOf(u8, same_llvm_type, "ret i32 %mc_arg_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, same_llvm_type, " = bitcast ") == null);
}

test "mechanical renderer rejects mutated selected builtin types and kinds" {
    const signed_phys = [_]mir.ValueType{.{ .integer = "i64" }};
    try std.testing.expectError(error.Unsupported, renderBuiltinForTest(std.testing.allocator, .phys, &signed_phys, .{ .address = .paddr }));

    const wrapping_operands = [_]mir.ValueType{ .{ .integer = "u32" }, .{ .integer = "u32" } };
    try std.testing.expectError(error.Unsupported, renderBuiltinForTest(std.testing.allocator, .wrapping_add, &wrapping_operands, .{ .integer = "i32" }));
    try std.testing.expectError(error.Unsupported, renderBuiltinForTest(std.testing.allocator, .conversion_from, &wrapping_operands, .{ .integer = "u32" }));

    const narrowing_source = [_]mir.ValueType{.{ .integer = "u32" }};
    try std.testing.expectError(error.Unsupported, renderBuiltinForTest(std.testing.allocator, .conversion_from, &narrowing_source, .{ .integer = "u8" }));
    try std.testing.expectError(error.Unsupported, renderBuiltinForTest(std.testing.allocator, .cpu_pause, &narrowing_source, .{ .integer = "u32" }));

    try std.testing.expectError(error.Unsupported, renderBuiltinForTest(std.testing.allocator, .bitcast, &narrowing_source, .{ .float = "f64" }));
    try std.testing.expectError(error.Unsupported, renderBuiltinForTest(std.testing.allocator, .bitcast, &wrapping_operands, .{ .float = "f32" }));
    const bool_source = [_]mir.ValueType{.bool};
    try std.testing.expectError(error.Unsupported, renderBuiltinForTest(std.testing.allocator, .bitcast, &bool_source, .{ .integer = "u8" }));
    const pointer_source = [_]mir.ValueType{.{ .pointer = .{ .kind = .single, .mutability = .@"const", .child = "u32" } }};
    try std.testing.expectError(error.Unsupported, renderBuiltinForTest(std.testing.allocator, .bitcast, &pointer_source, .{ .integer = "u64" }));
}

test "mechanical renderer guards single parameter deref before race-unordered load" {
    const source: mir.SourcePoint = .{ .line = 1, .column = 12, .offset = 11, .len = 2 };
    const pointer_ty: mir.ValueType = .{ .pointer = .{ .kind = .single, .mutability = .@"const", .child = "u32" } };
    const value_ty: mir.ValueType = .{ .integer = "u32" };
    var parameters = [_]mir.ExecutableParameter{.{
        .local = mir.LocalId.fromIndex(0),
        .ty = pointer_ty,
        .type_id = mir.TypeId.fromIndex(0),
        .source = source,
        .span_id = mir.SpanId.fromIndex(0),
    }};
    var places = [_]mir.ExecutablePlace{.{
        .id = mir.PlaceId.fromIndex(0),
        .source = source,
        .span_id = mir.SpanId.fromIndex(0),
        .root = .{ .local = mir.LocalId.fromIndex(0) },
        .root_ty = pointer_ty,
        .root_type_id = mir.TypeId.fromIndex(0),
        .ty = value_ty,
        .type_id = mir.TypeId.fromIndex(1),
        .projection_count = 1,
    }};
    var expressions = [_]mir.ExecutableExpression{.{
        .id = mir.ExprId.fromIndex(0),
        .block_id = mir.BlockId.fromIndex(0),
        .owner_statement = mir.InstId.fromIndex(0),
        .source = source,
        .span_id = mir.SpanId.fromIndex(0),
        .result_ty = value_ty,
        .type_id = mir.TypeId.fromIndex(1),
        .operation = .{ .load = .{
            .place = mir.PlaceId.fromIndex(0),
            .access = .{ .kind = .race_unordered, .alignment = 4 },
            .representation_source = source,
            .representation_span_id = mir.SpanId.fromIndex(0),
        } },
    }};
    var edges = [_]mir.ExecutableTrapEdge{.{
        .owner = .{ .expression = mir.ExprId.fromIndex(0) },
        .from_block = mir.BlockId.fromIndex(0),
        .trap_block = mir.BlockId.fromIndex(1),
        .kind = .InvalidRepresentation,
        .source = .representation_check,
    }};
    var statements = [_]mir.ExecutableStatement{.{
        .id = mir.InstId.fromIndex(0),
        .block_id = mir.BlockId.fromIndex(0),
        .source = source,
        .operation = .{ .return_ = mir.ExprId.fromIndex(0) },
    }};
    var terminators = [_]mir.ExecutableTerminator{
        .{ .block_id = mir.BlockId.fromIndex(0), .operation = .return_ },
        .{ .block_id = mir.BlockId.fromIndex(1), .operation = .{ .trap_ = .InvalidRepresentation } },
    };
    const body: mir.ExecutableBody = .{
        .parameters = &parameters,
        .expressions = &expressions,
        .trap_edges = &edges,
        .places = &places,
        .statements = &statements,
        .terminators = &terminators,
    };

    try std.testing.expect(supports(&body, value_ty));
    const rendered = try render(std.testing.allocator, &body, value_ty);
    defer std.testing.allocator.free(rendered);
    const guard = std.mem.indexOf(u8, rendered, "icmp eq ptr %mc_arg_0, null") orelse return error.TestUnexpectedResult;
    const load = std.mem.indexOf(u8, rendered, "load atomic i32, ptr %mc_arg_0 unordered, align 4") orelse return error.TestUnexpectedResult;
    try std.testing.expect(guard < load);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "br i1 %mc_expr_tmp_0, label %mc_block_1, label %mc_representation_ready_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "mc_block_1:\n  call void @mc_trap_InvalidRepresentation()") != null);
}

test "mechanical renderer guards address of parameter deref and returns the same pointer" {
    const source: mir.SourcePoint = .{ .line = 1, .column = 10, .offset = 9, .len = 3 };
    const pointer_ty: mir.ValueType = .{ .pointer = .{ .kind = .single, .mutability = .mut, .child = "u32" } };
    const value_ty: mir.ValueType = .{ .integer = "u32" };
    var parameters = [_]mir.ExecutableParameter{.{ .local = mir.LocalId.fromIndex(0), .ty = pointer_ty, .type_id = mir.TypeId.fromIndex(0), .source = source, .span_id = mir.SpanId.fromIndex(0) }};
    var places = [_]mir.ExecutablePlace{.{
        .id = mir.PlaceId.fromIndex(0),
        .source = source,
        .span_id = mir.SpanId.fromIndex(0),
        .root = .{ .local = mir.LocalId.fromIndex(0) },
        .root_ty = pointer_ty,
        .root_type_id = mir.TypeId.fromIndex(0),
        .ty = value_ty,
        .type_id = mir.TypeId.fromIndex(1),
        .projection_count = 1,
    }};
    var expressions = [_]mir.ExecutableExpression{.{
        .id = mir.ExprId.fromIndex(0),
        .block_id = mir.BlockId.fromIndex(0),
        .owner_statement = mir.InstId.fromIndex(0),
        .source = source,
        .span_id = mir.SpanId.fromIndex(0),
        .result_ty = pointer_ty,
        .type_id = mir.TypeId.fromIndex(0),
        .operation = .{ .address_of = .{
            .place = mir.PlaceId.fromIndex(0),
            .representation_source = source,
            .representation_span_id = mir.SpanId.fromIndex(0),
        } },
    }};
    var edges = [_]mir.ExecutableTrapEdge{.{
        .owner = .{ .expression = mir.ExprId.fromIndex(0) },
        .from_block = mir.BlockId.fromIndex(0),
        .trap_block = mir.BlockId.fromIndex(1),
        .kind = .InvalidRepresentation,
        .source = .representation_check,
    }};
    var statements = [_]mir.ExecutableStatement{.{ .id = mir.InstId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .return_ = mir.ExprId.fromIndex(0) } }};
    var terminators = [_]mir.ExecutableTerminator{
        .{ .block_id = mir.BlockId.fromIndex(0), .operation = .return_ },
        .{ .block_id = mir.BlockId.fromIndex(1), .operation = .{ .trap_ = .InvalidRepresentation } },
    };
    const body: mir.ExecutableBody = .{ .parameters = &parameters, .expressions = &expressions, .trap_edges = &edges, .places = &places, .statements = &statements, .terminators = &terminators };

    try std.testing.expect(supports(&body, pointer_ty));
    const rendered = try render(std.testing.allocator, &body, pointer_ty);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "icmp eq ptr %mc_arg_0, null") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "ret ptr %mc_arg_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "load ptr, ptr %mc_arg_0") == null);
}

test "mechanical renderer rejects mutated parameter deref place access and trap facts" {
    const source: mir.SourcePoint = .{ .line = 1, .column = 1 };
    const pointer_ty: mir.ValueType = .{ .pointer = .{ .kind = .single, .mutability = .@"const", .child = "u32" } };
    const value_ty: mir.ValueType = .{ .integer = "u32" };
    var parameters = [_]mir.ExecutableParameter{.{ .local = mir.LocalId.fromIndex(0), .ty = pointer_ty, .type_id = mir.TypeId.fromIndex(0), .source = source }};
    var places = [_]mir.ExecutablePlace{.{
        .id = mir.PlaceId.fromIndex(0),
        .source = source,
        .root = .{ .local = mir.LocalId.fromIndex(0) },
        .root_ty = pointer_ty,
        .root_type_id = mir.TypeId.fromIndex(0),
        .ty = value_ty,
        .type_id = mir.TypeId.fromIndex(1),
        .projection_count = 1,
    }};
    var expressions = [_]mir.ExecutableExpression{.{
        .id = mir.ExprId.fromIndex(0),
        .block_id = mir.BlockId.fromIndex(0),
        .owner_statement = mir.InstId.fromIndex(0),
        .source = source,
        .result_ty = value_ty,
        .type_id = mir.TypeId.fromIndex(1),
        .operation = .{ .load = .{
            .place = mir.PlaceId.fromIndex(0),
            .access = .{ .kind = .race_unordered, .alignment = 4 },
            .representation_source = source,
            .representation_span_id = mir.SpanId.fromIndex(0),
        } },
    }};
    var edges = [_]mir.ExecutableTrapEdge{.{ .owner = .{ .expression = mir.ExprId.fromIndex(0) }, .from_block = mir.BlockId.fromIndex(0), .trap_block = mir.BlockId.fromIndex(1), .kind = .InvalidRepresentation, .source = .representation_check }};
    var statements = [_]mir.ExecutableStatement{.{ .id = mir.InstId.fromIndex(0), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .return_ = mir.ExprId.fromIndex(0) } }};
    var terminators = [_]mir.ExecutableTerminator{
        .{ .block_id = mir.BlockId.fromIndex(0), .operation = .return_ },
        .{ .block_id = mir.BlockId.fromIndex(1), .operation = .{ .trap_ = .InvalidRepresentation } },
    };
    var body: mir.ExecutableBody = .{ .parameters = &parameters, .expressions = &expressions, .trap_edges = &edges, .places = &places, .statements = &statements, .terminators = &terminators };
    try std.testing.expect(supports(&body, value_ty));

    expressions[0].operation.load.access.kind = .plain;
    try std.testing.expect(!supports(&body, value_ty));
    expressions[0].operation.load.access.kind = .race_unordered;

    edges[0].source = .checked_arithmetic;
    try std.testing.expect(!supports(&body, value_ty));
    edges[0].source = .representation_check;

    edges[0].owner = .{ .expression = mir.ExprId.fromIndex(1) };
    try std.testing.expect(!supports(&body, value_ty));
    edges[0].owner = .{ .expression = mir.ExprId.fromIndex(0) };

    places[0].root_type_id = mir.TypeId.fromIndex(2);
    try std.testing.expect(!supports(&body, value_ty));
    places[0].root_type_id = mir.TypeId.fromIndex(0);

    expressions[0].type_id = mir.TypeId.fromIndex(2);
    try std.testing.expect(!supports(&body, value_ty));
    expressions[0].type_id = mir.TypeId.fromIndex(1);

    places[0].projections[0] = .{ .field = 0 };
    try std.testing.expect(!supports(&body, value_ty));
    places[0].projections[0] = .deref;

    const nullable_ty: mir.ValueType = .{ .nullable_pointer = .{ .kind = .single, .mutability = .@"const", .child = "u32" } };
    parameters[0].ty = nullable_ty;
    places[0].root_ty = nullable_ty;
    try std.testing.expect(!supports(&body, value_ty));
    parameters[0].ty = pointer_ty;
    places[0].root_ty = pointer_ty;

    const raw_many_ty: mir.ValueType = .{ .pointer = .{ .kind = .raw_many, .mutability = .@"const", .child = "u32" } };
    parameters[0].ty = raw_many_ty;
    places[0].root_ty = raw_many_ty;
    try std.testing.expect(!supports(&body, value_ty));
    try std.testing.expectError(error.Unsupported, render(std.testing.allocator, &body, value_ty));
}

test "mechanical renderer guards statement-owned parameter deref before atomic store" {
    const source: mir.SourcePoint = .{ .line = 1, .column = 20, .offset = 19, .len = 2 };
    const pointer_ty: mir.ValueType = .{ .pointer = .{ .kind = .single, .mutability = .mut, .child = "u32" } };
    const value_ty: mir.ValueType = .{ .integer = "u32" };
    var parameters = [_]mir.ExecutableParameter{
        .{ .local = mir.LocalId.fromIndex(0), .ty = pointer_ty, .type_id = mir.TypeId.fromIndex(0), .source = source, .span_id = mir.SpanId.fromIndex(0) },
        .{ .local = mir.LocalId.fromIndex(1), .ty = value_ty, .type_id = mir.TypeId.fromIndex(1), .source = source, .span_id = mir.SpanId.fromIndex(0) },
    };
    var places = [_]mir.ExecutablePlace{.{
        .id = mir.PlaceId.fromIndex(0),
        .source = source,
        .span_id = mir.SpanId.fromIndex(0),
        .root = .{ .local = mir.LocalId.fromIndex(0) },
        .root_ty = pointer_ty,
        .root_type_id = mir.TypeId.fromIndex(0),
        .ty = value_ty,
        .type_id = mir.TypeId.fromIndex(1),
        .projection_count = 1,
    }};
    var expressions = [_]mir.ExecutableExpression{.{
        .id = mir.ExprId.fromIndex(0),
        .block_id = mir.BlockId.fromIndex(0),
        .owner_statement = mir.InstId.fromIndex(0),
        .source = source,
        .span_id = mir.SpanId.fromIndex(0),
        .result_ty = value_ty,
        .type_id = mir.TypeId.fromIndex(1),
        .operation = .{ .local = mir.LocalId.fromIndex(1) },
    }};
    var edges = [_]mir.ExecutableTrapEdge{.{
        .owner = .{ .statement = mir.InstId.fromIndex(0) },
        .from_block = mir.BlockId.fromIndex(0),
        .trap_block = mir.BlockId.fromIndex(1),
        .kind = .InvalidRepresentation,
        .source = .representation_check,
    }};
    var statements = [_]mir.ExecutableStatement{
        .{
            .id = mir.InstId.fromIndex(0),
            .block_id = mir.BlockId.fromIndex(0),
            .source = source,
            .span_id = mir.SpanId.fromIndex(0),
            .operation = .{ .store = .{
                .place = mir.PlaceId.fromIndex(0),
                .value = mir.ExprId.fromIndex(0),
                .ty = value_ty,
                .type_id = mir.TypeId.fromIndex(1),
                .access = .{ .kind = .race_unordered, .alignment = 4 },
                .representation_source = source,
                .representation_span_id = mir.SpanId.fromIndex(0),
            } },
        },
        .{ .id = mir.InstId.fromIndex(1), .block_id = mir.BlockId.fromIndex(0), .source = source, .operation = .{ .return_ = null } },
    };
    var terminators = [_]mir.ExecutableTerminator{
        .{ .block_id = mir.BlockId.fromIndex(0), .operation = .return_ },
        .{ .block_id = mir.BlockId.fromIndex(1), .operation = .{ .trap_ = .InvalidRepresentation } },
    };
    var body: mir.ExecutableBody = .{ .parameters = &parameters, .expressions = &expressions, .trap_edges = &edges, .places = &places, .statements = &statements, .terminators = &terminators };

    try std.testing.expect(supports(&body, .void));
    const rendered = try render(std.testing.allocator, &body, .void);
    defer std.testing.allocator.free(rendered);
    const guard = std.mem.indexOf(u8, rendered, "icmp eq ptr %mc_arg_0, null") orelse return error.TestUnexpectedResult;
    const store = std.mem.indexOf(u8, rendered, "store atomic i32 %mc_arg_1, ptr %mc_arg_0 unordered, align 4") orelse return error.TestUnexpectedResult;
    try std.testing.expect(guard < store);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "label %mc_block_1, label %mc_representation_store_ready_0") != null);

    statements[0].operation.store.access.kind = .plain;
    try std.testing.expect(!supports(&body, .void));
    statements[0].operation.store.access.kind = .race_unordered;

    statements[0].operation.store.representation_span_id = .invalid;
    try std.testing.expect(!supports(&body, .void));
    statements[0].operation.store.representation_span_id = mir.SpanId.fromIndex(0);

    edges[0].owner = .{ .expression = mir.ExprId.fromIndex(0) };
    try std.testing.expect(!supports(&body, .void));
    edges[0].owner = .{ .statement = mir.InstId.fromIndex(0) };

    edges[0].owner = .{ .statement = mir.InstId.fromIndex(1) };
    try std.testing.expect(!supports(&body, .void));
    edges[0].owner = .{ .statement = mir.InstId.fromIndex(0) };

    statements[0].operation.store.type_id = mir.TypeId.fromIndex(2);
    try std.testing.expect(!supports(&body, .void));
    statements[0].operation.store.type_id = mir.TypeId.fromIndex(1);

    expressions[0].type_id = mir.TypeId.fromIndex(2);
    try std.testing.expect(!supports(&body, .void));
    expressions[0].type_id = mir.TypeId.fromIndex(1);

    places[0].root_ty.pointer.mutability = .@"const";
    parameters[0].ty.pointer.mutability = .@"const";
    try std.testing.expect(!supports(&body, .void));
    places[0].root_ty.pointer.mutability = .mut;
    parameters[0].ty.pointer.mutability = .mut;

    places[0].projections[0] = .{ .index = .{
        .value = mir.ExprId.fromIndex(0),
        .kind = .fixed_array,
        .bound = 1,
        .span_id = mir.SpanId.fromIndex(0),
    } };
    try std.testing.expect(!supports(&body, .void));
    try std.testing.expectError(error.Unsupported, render(std.testing.allocator, &body, .void));
}

test "mechanical renderer validates a slice once with an exact representation edge" {
    const slice_ty: mir.ValueType = .{ .pointer = .{ .kind = .slice, .mutability = .@"const", .child = "u32" } };
    const source: mir.SourcePoint = .{ .line = 1, .column = 35, .offset = 34, .len = 2 };
    const entry = mir.BlockId.fromIndex(0);
    const trap = mir.BlockId.fromIndex(1);
    const return_statement = mir.InstId.fromIndex(0);
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
        .expressions = &expressions,
        .trap_edges = edges[0..1],
        .statements = &statements,
        .terminators = &terminators,
    };

    try std.testing.expect(supports(&body, slice_ty));
    const rendered = try render(std.testing.allocator, &body, slice_ty);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "extractvalue { ptr, i64 } %mc_arg_0, 0"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "extractvalue { ptr, i64 } %mc_arg_0, 1"));
    try std.testing.expect(std.mem.indexOf(u8, rendered, "icmp eq ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "icmp ne i64") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "and i1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "label %mc_block_1, label %mc_representation_ready_1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "ret { ptr, i64 } %mc_arg_0") != null);

    body.trap_edges = &.{};
    try std.testing.expect(!supports(&body, slice_ty));
    body.trap_edges = edges[0..2];
    try std.testing.expect(!supports(&body, slice_ty));
    body.trap_edges = edges[0..1];
    edges[0].kind = .Bounds;
    try std.testing.expect(!supports(&body, slice_ty));
    edges[0].kind = .InvalidRepresentation;
    edges[0].source = .bounds_check;
    try std.testing.expect(!supports(&body, slice_ty));
    edges[0].source = .representation_check;
    edges[0].from_block = trap;
    try std.testing.expect(!supports(&body, slice_ty));
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
        try std.testing.expect(!supports(&body, rejected));
    }
}
