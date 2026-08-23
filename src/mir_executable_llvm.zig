//! Mechanical LLVM body rendering for canonical executable MIR.
//!
//! This module deliberately has no syntax, semantic-analysis, or declaration
//! artifact dependency.  Admission is structural and typed-ID based; symbol
//! spelling is recovered only after a SymbolId has selected its identity.

const std = @import("std");
const mir = @import("mir_model.zig");

pub const RenderError = error{ Unsupported, InvalidBody, OutOfMemory };

const Value = struct {
    ty: []const u8,
    spelling: []const u8,
};

const Local = struct {
    ty: []const u8,
    storage: []const u8,
    addressable: bool,
};

pub fn supports(body: *const mir.ExecutableBody, return_ty: mir.ValueType) bool {
    if (!body.isComplete() or body.terminators.len == 0 or llvmType(return_ty) == null) return false;
    for (body.parameters) |parameter| {
        if (!parameter.local.isValid() or llvmType(parameter.ty) == null) return false;
    }
    for (body.expressions) |expression| {
        if (!expression.id.isValid() or expression.id.index() >= body.expressions.len or llvmType(expression.result_ty) == null) return false;
        if (!operationSupported(body, expression)) return false;
    }
    for (body.trap_edges) |edge| {
        if (!expressionValid(body, edge.owner)) return false;
        const owner = body.expressions[edge.owner.index()];
        switch (owner.operation) {
            .binary => |binary| {
                if (binary.arithmetic != .checked or checkedOverflowEdge(body, owner) == null) return false;
            },
            else => return false,
        }
    }
    for (body.places) |place| {
        if (!place.id.isValid() or place.id.index() >= body.places.len or place.projection_count > mir.max_executable_projections or !placeRootValid(body, place)) return false;
        if (place.projection_count != 0) return false;
    }
    for (body.statements) |statement| {
        if (!statement.id.isValid() or !statement.block_id.isValid()) return false;
        switch (statement.operation) {
            .local_init => |local| {
                if (!local.local.isValid() or llvmType(local.ty) == null) return false;
                if (local.value) |value| if (!expressionValid(body, value)) return false;
            },
            .store => |store| {
                if (!placeValid(body, store.place) or !expressionValid(body, store.value) or
                    !sameValueType(store.ty, body.expressions[store.value.index()].result_ty) or
                    !memoryAccessSupported(body, store.place, store.ty, store.access, true)) return false;
            },
            .eval => |value| if (!expressionValid(body, value)) return false,
            .guard => |guard| {
                // A branch guard is consumed by its terminator. An assertion
                // additionally owns a trap edge which this renderer does not
                // yet model, so admitting it would silently discard the trap.
                if (guard.kind == .assert_ or !expressionValid(body, guard.condition)) return false;
            },
            .return_ => |value| if (value) |result| {
                if (!expressionValid(body, result)) return false;
            },
            .control_transfer, .defer_cleanup, .unsupported => return false,
        }
    }
    for (body.terminators) |terminator| {
        if (!terminator.block_id.isValid()) return false;
        switch (terminator.operation) {
            .fallthrough => return false,
            .jump => |target| if (!blockExists(body, target)) return false,
            .branch => |branch| if (!expressionValid(body, branch.condition) or !blockExists(body, branch.true_block) or !blockExists(body, branch.false_block)) return false,
            .switch_ => return false,
            .trap_ => |kind| if (trapHelper(kind) == null) return false,
            .return_ => if (!hasReturnStatement(body, terminator.block_id)) return false,
            .unreachable_ => {},
        }
    }
    return true;
}

pub fn render(allocator: std.mem.Allocator, body: *const mir.ExecutableBody, return_ty: mir.ValueType) RenderError![]u8 {
    if (!supports(body, return_ty)) return error.Unsupported;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var renderer = try Renderer.init(arena.allocator(), body, return_ty);
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

    fn init(allocator: std.mem.Allocator, body: *const mir.ExecutableBody, return_ty: mir.ValueType) RenderError!Renderer {
        const values = try allocator.alloc(?Value, body.expressions.len);
        @memset(values, null);
        return .{
            .allocator = allocator,
            .body = body,
            .return_ty = llvmType(return_ty) orelse "",
            .values = values,
            .locals = std.AutoHashMap(u32, Local).init(allocator),
            .returns = std.AutoHashMap(u32, ?Value).init(allocator),
        };
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
            const ty = llvmType(parameter.ty) orelse return error.Unsupported;
            try self.locals.put(parameter.local.raw, .{ .ty = ty, .storage = try std.fmt.allocPrint(self.allocator, "%mc_arg_{d}", .{parameter.local.raw}), .addressable = false });
        }
        try self.output.appendSlice(self.allocator, "  ; canonical executable MIR\n");
        // Allocate every local once in the entry prologue. An alloca inside a
        // loop block executes on every iteration and would grow the stack.
        for (self.body.statements) |statement| switch (statement.operation) {
            .local_init => |local| {
                if (self.locals.contains(local.local.raw)) return error.InvalidBody;
                const ty = llvmType(local.ty) orelse return error.Unsupported;
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
                const ty = llvmType(local.ty) orelse return error.Unsupported;
                const slot = (self.locals.get(local.local.raw) orelse return error.InvalidBody).storage;
                if (local.value) |initializer| {
                    const value = try self.emitExpression(initializer);
                    if (!std.mem.eql(u8, ty, value.ty)) return error.InvalidBody;
                    try self.output.print(self.allocator, "  store {s} {s}, ptr {s}\n", .{ ty, value.spelling, slot });
                }
            },
            .store => |store| {
                const value = try self.emitExpression(store.value);
                const pointer = try self.emitPlace(store.place, value.ty);
                if (!sameValueType(store.ty, self.body.expressions[store.value.index()].result_ty)) return error.InvalidBody;
                try self.emitMemoryStore(store.place, value, pointer, store.access);
            },
            .eval => |value| _ = try self.emitExpression(value),
            .guard => |guard| _ = try self.emitExpression(guard.condition),
            .return_ => |value| {
                const rendered = if (value) |result| try self.emitExpression(result) else null;
                try self.returns.put(statement.block_id.raw, rendered);
            },
            .control_transfer, .defer_cleanup, .unsupported => return error.Unsupported,
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
            .fallthrough, .switch_ => return error.Unsupported,
        }
    }

    fn emitExpression(self: *Renderer, id: mir.ExprId) RenderError!Value {
        if (!expressionValid(self.body, id)) return error.InvalidBody;
        if (self.values[id.index()]) |cached| return cached;
        const expression = self.body.expressions[id.index()];
        const ty = llvmType(expression.result_ty) orelse return error.Unsupported;
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
                const symbol = symbolSpelling(self.body, symbol_id) orelse return error.InvalidBody;
                const value = try self.temp();
                // Memory access mode is semantic data.  In the absence of an
                // explicit atomic/volatile/MMIO access operation, a symbol
                // read is an ordinary load; the backend must not infer an
                // atomic access from the LLVM scalar type.
                try self.output.print(self.allocator, "  {s} = load {s}, ptr @{s}\n", .{ value, ty, symbol });
                break :blk .{ .ty = ty, .spelling = value };
            },
            .load => |load| try self.emitMemoryLoad(expression, load),
            .literal => |literal| try self.literalValue(ty, literal),
            .unary => |unary| try self.emitUnary(ty, unary),
            .binary => |binary| try self.emitBinary(expression, ty, binary),
            .direct_call => |call| try self.emitDirectCall(ty, call),
            .builtin_call => return error.Unsupported,
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
            .address_of => |operand| try self.emitAddressOf(operand),
            .cast, .index, .range_slice, .member, .array, .struct_, .unsupported => return error.Unsupported,
        };
        self.values[id.index()] = result;
        return result;
    }

    fn literalValue(self: *Renderer, ty: []const u8, literal: mir.ExecutableLiteral) RenderError!Value {
        return switch (literal) {
            .integer => |magnitude| .{ .ty = ty, .spelling = try std.fmt.allocPrint(self.allocator, "{d}", .{magnitude}) },
            .boolean => |value| .{ .ty = ty, .spelling = if (value) "true" else "false" },
            .float => |spelling| .{ .ty = ty, .spelling = spelling },
            .null => if (std.mem.eql(u8, ty, "ptr")) .{ .ty = ty, .spelling = "null" } else error.Unsupported,
            .void => .{ .ty = "void", .spelling = "" },
            else => error.Unsupported,
        };
    }

    fn emitUnary(self: *Renderer, ty: []const u8, unary: anytype) RenderError!Value {
        const operand = try self.emitExpression(unary.operand);
        if (!std.mem.eql(u8, operand.ty, ty)) return error.InvalidBody;
        const value = try self.temp();
        switch (unary.op) {
            .bit_not => try self.output.print(self.allocator, "  {s} = xor {s} {s}, -1\n", .{ value, ty, operand.spelling }),
            .logical_not => if (std.mem.eql(u8, ty, "i1"))
                try self.output.print(self.allocator, "  {s} = xor i1 {s}, true\n", .{ value, operand.spelling })
            else
                return error.InvalidBody,
            .neg => return error.Unsupported,
        }
        return .{ .ty = ty, .spelling = value };
    }

    fn emitBinary(self: *Renderer, expression: mir.ExecutableExpression, result_ty: []const u8, binary: anytype) RenderError!Value {
        const left = try self.emitExpression(binary.left);
        const right = try self.emitExpression(binary.right);
        if (!std.mem.eql(u8, left.ty, right.ty)) return error.InvalidBody;
        if (binary.arithmetic == .checked) {
            if (!std.mem.eql(u8, result_ty, left.ty)) return error.InvalidBody;
            const edge = checkedOverflowEdge(self.body, expression) orelse return error.InvalidBody;
            const op: []const u8 = switch (binary.op) {
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
        const value = try self.temp();
        const operation: []const u8 = switch (binary.op) {
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

    fn emitDirectCall(self: *Renderer, ty: []const u8, call: anytype) RenderError!Value {
        const symbol = symbolSpelling(self.body, call.callee) orelse return error.InvalidBody;
        return self.emitCall(ty, try std.fmt.allocPrint(self.allocator, "@{s}", .{symbol}), call.arguments[0..call.argument_count]);
    }

    fn emitIndirectCall(self: *Renderer, ty: []const u8, call: anytype) RenderError!Value {
        const callee = try self.emitExpression(call.callee);
        if (!std.mem.eql(u8, callee.ty, "ptr")) return error.InvalidBody;
        return self.emitCall(ty, callee.spelling, call.arguments[0..call.argument_count]);
    }

    fn emitCall(self: *Renderer, ty: []const u8, callee: []const u8, arguments: []const mir.ExprId) RenderError!Value {
        var rendered: std.ArrayList(u8) = .empty;
        defer rendered.deinit(self.allocator);
        for (arguments, 0..) |argument_id, index| {
            const argument = try self.emitExpression(argument_id);
            if (index != 0) try rendered.appendSlice(self.allocator, ", ");
            try rendered.print(self.allocator, "{s} {s}", .{ argument.ty, argument.spelling });
        }
        if (std.mem.eql(u8, ty, "void")) {
            try self.output.print(self.allocator, "  call void {s}({s})\n", .{ callee, rendered.items });
            return .{ .ty = "void", .spelling = "" };
        }
        const result = try self.temp();
        try self.output.print(self.allocator, "  {s} = call {s} {s}({s})\n", .{ result, ty, callee, rendered.items });
        return .{ .ty = ty, .spelling = result };
    }

    fn emitMemoryLoad(self: *Renderer, expression: mir.ExecutableExpression, load: anytype) RenderError!Value {
        if (!memoryAccessSupported(self.body, load.place, expression.result_ty, load.access, false)) return error.InvalidBody;
        const value_ty = llvmType(expression.result_ty) orelse return error.Unsupported;
        const pointer = try self.emitPlace(load.place, value_ty);
        const global_bool = placeIsGlobal(self.body, load.place) and expression.result_ty == .bool;
        const storage_ty: []const u8 = if (global_bool) "i8" else value_ty;
        const loaded = try self.temp();
        switch (load.access.kind) {
            .plain => try self.output.print(self.allocator, "  {s} = load {s}, ptr {s}, align {d}\n", .{ loaded, storage_ty, pointer, load.access.alignment }),
            .race_unordered => try self.output.print(self.allocator, "  {s} = load atomic {s}, ptr {s} unordered, align {d}\n", .{ loaded, storage_ty, pointer, load.access.alignment }),
        }
        if (!global_bool) return .{ .ty = value_ty, .spelling = loaded };
        const converted = try self.temp();
        try self.output.print(self.allocator, "  {s} = trunc i8 {s} to i1\n", .{ converted, loaded });
        return .{ .ty = "i1", .spelling = converted };
    }

    fn emitMemoryStore(self: *Renderer, place_id: mir.PlaceId, value: Value, pointer: []const u8, access: mir.ExecutableMemoryAccess) RenderError!void {
        const place = &self.body.places[place_id.index()];
        const global_bool = switch (place.root) {
            .symbol => std.mem.eql(u8, value.ty, "i1"),
            .local => false,
        };
        var stored = value.spelling;
        const storage_ty: []const u8 = if (global_bool) "i8" else value.ty;
        if (global_bool) {
            stored = try self.temp();
            try self.output.print(self.allocator, "  {s} = zext i1 {s} to i8\n", .{ stored, value.spelling });
        }
        switch (access.kind) {
            .plain => try self.output.print(self.allocator, "  store {s} {s}, ptr {s}, align {d}\n", .{ storage_ty, stored, pointer, access.alignment }),
            .race_unordered => try self.output.print(self.allocator, "  store atomic {s} {s}, ptr {s} unordered, align {d}\n", .{ storage_ty, stored, pointer, access.alignment }),
        }
    }

    fn emitAddressOf(self: *Renderer, place_id: mir.PlaceId) RenderError!Value {
        return .{ .ty = "ptr", .spelling = try self.emitPlace(place_id, "ptr") };
    }

    fn emitPlace(self: *Renderer, place_id: mir.PlaceId, value_ty: []const u8) RenderError![]const u8 {
        const place = &self.body.places[place_id.index()];
        var pointer: []const u8 = switch (place.root) {
            .local => |local_id| blk: {
                const local = self.locals.get(local_id.raw) orelse return error.InvalidBody;
                if (!local.addressable) return error.Unsupported;
                break :blk local.storage;
            },
            .symbol => |symbol_id| try std.fmt.allocPrint(self.allocator, "@{s}", .{symbolSpelling(self.body, symbol_id) orelse return error.InvalidBody}),
        };
        for (place.projections[0..place.projection_count]) |projection| switch (projection) {
            .deref => {
                const next = try self.temp();
                try self.output.print(self.allocator, "  {s} = load ptr, ptr {s}\n", .{ next, pointer });
                pointer = next;
            },
            .field, .index => return error.Unsupported,
        };
        _ = value_ty;
        return pointer;
    }

    fn temp(self: *Renderer) RenderError![]const u8 {
        const value = try std.fmt.allocPrint(self.allocator, "%mc_expr_tmp_{d}", .{self.next_temp});
        self.next_temp += 1;
        return value;
    }
};

fn llvmType(ty: mir.ValueType) ?[]const u8 {
    return switch (ty) {
        .void => "void",
        .bool => "i1",
        .integer => |name| if (std.mem.eql(u8, name, "u8") or std.mem.eql(u8, name, "i8")) "i8" else if (std.mem.eql(u8, name, "u16") or std.mem.eql(u8, name, "i16")) "i16" else if (std.mem.eql(u8, name, "u32") or std.mem.eql(u8, name, "i32")) "i32" else if (std.mem.eql(u8, name, "u64") or std.mem.eql(u8, name, "i64") or std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "isize")) "i64" else null,
        .float => |name| if (std.mem.eql(u8, name, "f32")) "float" else if (std.mem.eql(u8, name, "f64")) "double" else null,
        .pointer, .nullable_pointer, .cstr => "ptr",
        .slice => "{ ptr, i64 }",
        .address => "i64",
        else => null,
    };
}

fn operationSupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) bool {
    return switch (expression.operation) {
        .local => |id| localExists(body, id),
        // A bare symbol has no memory access mode. Direct calls carry their
        // SymbolId separately; global value reads remain fail-closed.
        .symbol => false,
        .load => |load| memoryAccessSupported(body, load.place, expression.result_ty, load.access, false),
        .literal => |literal| switch (literal) {
            .integer, .boolean, .null, .void => true,
            else => false,
        },
        .unary => |unary| unarySupported(body, expression.result_ty, unary),
        .binary => |binary| binarySupported(body, expression, binary),
        .direct_call => |call| call.argument_count <= mir.max_executable_operands and symbolSpelling(body, call.callee) != null and expressionListValid(body, call.arguments[0..call.argument_count]),
        .builtin_call => false,
        .indirect_call => |call| call.argument_count <= mir.max_executable_operands and expressionValid(body, call.callee) and expressionListValid(body, call.arguments[0..call.argument_count]),
        .address_of => |id| placeValid(body, id) and body.places[id.index()].projection_count == 0,
        .deref => |id| expressionValid(body, id) and switch (body.expressions[id.index()].result_ty) {
            .pointer => true,
            else => false,
        },
        .slice_length => |id| expressionValid(body, id) and switch (body.expressions[id.index()].result_ty) {
            .slice => true,
            else => false,
        },
        .cast, .index, .range_slice, .member, .array, .struct_, .unsupported => false,
    };
}

fn unarySupported(body: *const mir.ExecutableBody, result_ty: mir.ValueType, unary: anytype) bool {
    if (!expressionValid(body, unary.operand)) return false;
    const operand_ty = body.expressions[unary.operand.index()].result_ty;
    if (!sameValueType(result_ty, operand_ty)) return false;
    return switch (unary.op) {
        .bit_not => integerLike(result_ty),
        .logical_not => result_ty == .bool,
        .neg => false,
    };
}

fn binarySupported(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression, binary: anytype) bool {
    if (!expressionValid(body, binary.left) or !expressionValid(body, binary.right)) return false;
    const left_ty = body.expressions[binary.left.index()].result_ty;
    const right_ty = body.expressions[binary.right.index()].result_ty;
    if (!sameValueType(left_ty, right_ty)) return false;
    return switch (binary.op) {
        .add, .sub, .mul => sameValueType(expression.result_ty, left_ty) and arithmeticIntegerType(left_ty) and
            (binary.arithmetic == .ordinary or checkedOverflowEdge(body, expression) != null),
        .bit_or, .bit_xor, .bit_and => binary.arithmetic == .ordinary and sameValueType(expression.result_ty, left_ty) and integerLike(left_ty),
        .eq, .ne => binary.arithmetic == .ordinary and expression.result_ty == .bool and comparableEqualityType(left_ty),
        .lt, .le, .gt, .ge => binary.arithmetic == .ordinary and expression.result_ty == .bool and orderedIntegerType(left_ty),
        else => false,
    };
}

fn checkedOverflowEdge(body: *const mir.ExecutableBody, expression: mir.ExecutableExpression) ?mir.ExecutableTrapEdge {
    var result: ?mir.ExecutableTrapEdge = null;
    var owned_count: usize = 0;
    for (body.trap_edges) |edge| {
        if (!edge.owner.eql(expression.id)) continue;
        owned_count += 1;
        if (!edge.from_block.eql(expression.block_id) or edge.kind != .IntegerOverflow or edge.source != .checked_arithmetic) continue;
        const trap_terminator = terminatorForBlock(body, edge.trap_block) orelse continue;
        switch (trap_terminator.operation) {
            .trap_ => |kind| {
                if (kind == .IntegerOverflow) result = edge;
            },
            else => {},
        }
    }
    return if (owned_count == 1) result else null;
}

fn terminatorForBlock(body: *const mir.ExecutableBody, id: mir.BlockId) ?mir.ExecutableTerminator {
    if (!id.isValid()) return null;
    for (body.terminators) |terminator| if (terminator.block_id.eql(id)) return terminator;
    return null;
}

fn integerTypeSigned(ty: mir.ValueType) bool {
    return switch (ty) {
        .integer => |name| name.len != 0 and (name[0] == 'i' or std.mem.eql(u8, name, "isize")),
        else => false,
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
        .bool, .integer, .address => true,
        else => false,
    };
}

fn orderedIntegerType(ty: mir.ValueType) bool {
    return switch (ty) {
        .integer, .address => true,
        else => false,
    };
}

fn comparableEqualityType(ty: mir.ValueType) bool {
    return switch (ty) {
        .bool, .integer, .address, .pointer, .nullable_pointer, .cstr => true,
        else => false,
    };
}

fn sameValueType(left: mir.ValueType, right: mir.ValueType) bool {
    return std.meta.activeTag(left) == std.meta.activeTag(right) and std.mem.eql(u8, left.name(), right.name());
}

fn expressionListValid(body: *const mir.ExecutableBody, expressions: []const mir.ExprId) bool {
    for (expressions) |id| if (!expressionValid(body, id)) return false;
    return true;
}

fn expressionValid(body: *const mir.ExecutableBody, id: mir.ExprId) bool {
    return id.isValid() and id.index() < body.expressions.len and body.expressions[id.index()].id.eql(id);
}

fn placeValid(body: *const mir.ExecutableBody, id: mir.PlaceId) bool {
    return id.isValid() and id.index() < body.places.len and body.places[id.index()].id.eql(id);
}

fn placeRootValid(body: *const mir.ExecutableBody, place: mir.ExecutablePlace) bool {
    return switch (place.root) {
        .local => |id| localAddressable(body, id),
        .symbol => |id| if (symbolIdentity(body, id)) |identity| identity.kind == .global else false,
    };
}

fn memoryAccessSupported(body: *const mir.ExecutableBody, place_id: mir.PlaceId, ty: mir.ValueType, access: mir.ExecutableMemoryAccess, is_store: bool) bool {
    if (!placeValid(body, place_id) or mir.ExecutableMemoryAccess.scalarAlignment(ty) != access.alignment) return false;
    const place = body.places[place_id.index()];
    if (place.projection_count != 0) return false;
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
    };
}

fn placeIsGlobal(body: *const mir.ExecutableBody, id: mir.PlaceId) bool {
    if (!placeValid(body, id)) return false;
    return switch (body.places[id.index()].root) {
        .symbol => true,
        .local => false,
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

test "mechanical renderer rejects assertions until their trap edge is explicit" {
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
    const terminators = [_]mir.ExecutableTerminator{.{ .block_id = mir.BlockId.fromIndex(0), .operation = .return_ }};
    const body: mir.ExecutableBody = .{ .parameters = @constCast(&parameters), .expressions = @constCast(&expressions), .statements = @constCast(&statements), .terminators = @constCast(&terminators) };
    try std.testing.expect(!supports(&body, .void));
    try std.testing.expectError(error.Unsupported, render(std.testing.allocator, &body, .void));
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

test "mechanical renderer rejects floating comparison without fcmp semantics" {
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
    try std.testing.expect(!supports(&body, .bool));
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
            .owner = mir.ExprId.fromIndex(2),
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
        .owner = mir.ExprId.fromIndex(2),
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
    wrong_owner.owner = mir.ExprId.fromIndex(0);
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
