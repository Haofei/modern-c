const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const parser = @import("parser.zig");
const mir = @import("mir.zig");
const mir_model = @import("mir_model.zig");
const executable = @import("mir_executable_body.zig");

test "owned executable body is complete for scalar locals calls and returns" {
    const source =
        \\fn increment(value: u32) -> u32 { return value ^ 1; }
        \\fn compute(value: u32) -> u32 {
        \\    let intermediate: u32 = increment(value);
        \\    return intermediate ^ 2;
        \\}
        \\fn choose(flag: bool, value: u32) -> u32 {
        \\    var result: u32 = value;
        \\    if flag { result = result ^ 1; } else { result = result ^ 2; }
        \\    return result;
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "executable_body.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source_parser = parser.Parser.init(source, &reporter);
    const parsed = try source_parser.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    var module = try mir.buildFromDecls(std.testing.allocator, parsed.decls);
    defer module.deinit();
    for (module.functions) |*function| {
        try executable.verify(function);
        try std.testing.expect(executable.isComplete(function));
        for (function.executable_body.expressions) |value| {
            try std.testing.expect(value.block_id.isValid());
            try std.testing.expect(value.owner_statement.isValid());
            try assertOperandsPrecede(value);
        }
    }
}

test "executable type identities distinguish structural pointer shapes" {
    const source =
        \\fn pointer_shapes(left: *mut u8, right: *mut u32, maybe: ?*mut u8) -> void {}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "executable_type_keys.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source_parser = parser.Parser.init(source, &reporter);
    const parsed = try source_parser.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    var module = try mir.buildFromDecls(std.testing.allocator, parsed.decls);
    defer module.deinit();
    const function = &module.functions[0];
    try executable.verify(function);
    try std.testing.expect(executable.isComplete(function));
    try std.testing.expectEqual(@as(usize, 3), function.executable_body.parameters.len);

    const left_id = function.executable_body.parameters[0].type_id;
    const right_id = function.executable_body.parameters[1].type_id;
    const maybe_id = function.executable_body.parameters[2].type_id;
    try std.testing.expect(!left_id.eql(right_id));
    try std.testing.expect(!left_id.eql(maybe_id));
    try std.testing.expect(!right_id.eql(maybe_id));

    const saved = function.executable_body.parameters[1].type_id;
    function.executable_body.parameters[1].type_id = left_id;
    try std.testing.expectError(error.InvalidTypeReference, executable.verify(function));
    function.executable_body.parameters[1].type_id = saved;
    try executable.verify(function);
}

test "single parameter pointer deref owns typed place and race access" {
    const source =
        \\fn read_u32(pointer: *u32) -> u32 { return pointer.*; }
        \\fn read_paddr(pointer: *PAddr) -> PAddr { return pointer.*; }
        \\fn ordinary_store(pointer: *mut u32, value: u32) -> void { pointer.* = value; }
        \\fn identity(pointer: *mut u32) -> *mut u32 { return &pointer.*; }
        \\fn const_store(pointer: *u32, value: u32) -> void { pointer.* = value; }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "executable_pointer_deref.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source_parser = parser.Parser.init(source, &reporter);
    const parsed = try source_parser.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    var module = try mir.buildFromDecls(std.testing.allocator, parsed.decls);
    defer module.deinit();

    const complete_indices = [_]usize{ 0, 1, 2, 3 };
    const leaf_names = [_][]const u8{ "u32", "PAddr", "u32", "u32" };
    for (complete_indices, leaf_names) |index, leaf_name| {
        const function = &module.functions[index];
        try executable.verify(function);
        try std.testing.expect(executable.isComplete(function));
        try std.testing.expectEqual(@as(usize, 1), function.executable_body.places.len);
        const place = function.executable_body.places[0];
        try std.testing.expectEqual(@as(usize, 1), place.projection_count);
        try std.testing.expect(place.projections[0] == .deref);
        try std.testing.expectEqualStrings(leaf_name, place.ty.name());
        try std.testing.expect(place.root_type_id.isValid());
        try std.testing.expect(place.type_id.isValid());
        try std.testing.expect(!place.root_type_id.eql(place.type_id));
        try std.testing.expectEqual(@as(usize, 1), function.executable_body.trap_edges.len);
        try std.testing.expect(function.executable_body.trap_edges[0].kind == .InvalidRepresentation);
        try std.testing.expect(function.executable_body.trap_edges[0].source == .representation_check);
    }
    try std.testing.expect(!executable.isComplete(&module.functions[4]));
    for ([_]usize{4}) |index| {
        const store = &module.functions[index];
        store.executable_body.complete = true;
        try std.testing.expectError(error.InvalidCompletionClaim, executable.verify(store));
        store.executable_body.complete = false;
        try executable.verify(store);
    }

    const read = &module.functions[0];
    const read_place = &read.executable_body.places[0];
    const saved_root_type_id = read_place.root_type_id;
    const saved_leaf_type_id = read_place.type_id;
    read_place.root_type_id = saved_leaf_type_id;
    try std.testing.expectError(error.InvalidTypeReference, executable.verify(read));
    read_place.root_type_id = saved_root_type_id;
    read_place.type_id = saved_root_type_id;
    try std.testing.expectError(error.InvalidTypeReference, executable.verify(read));
    read_place.type_id = saved_leaf_type_id;
    try executable.verify(read);

    for (read.executable_body.expressions) |*value| switch (value.operation) {
        .load => |*load| {
            try std.testing.expect(load.access.kind == .race_unordered);
            load.access.kind = .plain;
            try std.testing.expectError(error.InvalidMemoryAccessKind, executable.verify(read));
            load.access.kind = .race_unordered;
            const saved_representation_span_id = load.representation_span_id;
            load.representation_span_id = .invalid;
            try std.testing.expectError(error.InvalidSpanReference, executable.verify(read));
            load.representation_span_id = saved_representation_span_id;
            const saved_edge_kind = read.executable_body.trap_edges[0].kind;
            read.executable_body.trap_edges[0].kind = .DivideByZero;
            try std.testing.expectError(error.InvalidMemoryAccessTrap, executable.verify(read));
            read.executable_body.trap_edges[0].kind = saved_edge_kind;
            try executable.verify(read);
            break;
        },
        else => {},
    } else return error.TestUnexpectedResult;

    const store_function = &module.functions[2];
    const store_statement = store_statement: {
        for (store_function.executable_body.statements) |*statement| switch (statement.operation) {
            .store => break :store_statement statement,
            else => {},
        };
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(@as(usize, 1), store_function.executable_body.trap_edges.len);
    switch (store_function.executable_body.trap_edges[0].owner) {
        .statement => |id| try std.testing.expect(id.eql(store_statement.id)),
        .expression => return error.TestUnexpectedResult,
    }
    switch (store_statement.operation) {
        .store => |*store| {
            try std.testing.expect(store.access.kind == .race_unordered);
            try std.testing.expect(store.representation_source != null);
            try std.testing.expect(store.representation_span_id.isValid());

            const store_place = &store_function.executable_body.places[store.place.index()];
            const saved_store_root_type_id = store_place.root_type_id;
            const saved_store_leaf_type_id = store_place.type_id;
            store_place.root_type_id = saved_store_leaf_type_id;
            try std.testing.expectError(error.InvalidTypeReference, executable.verify(store_function));
            store_place.root_type_id = saved_store_root_type_id;
            store_place.type_id = saved_store_root_type_id;
            try std.testing.expectError(error.InvalidTypeReference, executable.verify(store_function));
            store_place.type_id = saved_store_leaf_type_id;

            const saved_representation_span_id = store.representation_span_id;
            store.representation_span_id = .invalid;
            try std.testing.expectError(error.InvalidTrapEdge, executable.verify(store_function));
            store.representation_span_id = saved_representation_span_id;
        },
        else => return error.TestUnexpectedResult,
    }

    const store_edge = &store_function.executable_body.trap_edges[0];
    const saved_owner = store_edge.owner;
    switch (store_statement.operation) {
        .store => |store| store_edge.owner = .{ .expression = store.value },
        else => unreachable,
    }
    try std.testing.expectError(error.InvalidTrapEdge, executable.verify(store_function));
    store_edge.owner = .{ .statement = .invalid };
    try std.testing.expectError(error.InvalidTrapEdge, executable.verify(store_function));
    store_edge.owner = saved_owner;

    const saved_from_block = store_edge.from_block;
    store_edge.from_block = .invalid;
    try std.testing.expectError(error.InvalidTrapEdge, executable.verify(store_function));
    store_edge.from_block = saved_from_block;
    const saved_kind = store_edge.kind;
    store_edge.kind = .DivideByZero;
    try std.testing.expectError(error.InvalidTrapEdge, executable.verify(store_function));
    store_edge.kind = saved_kind;
    const saved_source = store_edge.source;
    store_edge.source = .checked_arithmetic;
    try std.testing.expectError(error.InvalidTrapEdge, executable.verify(store_function));
    store_edge.source = saved_source;

    const saved_edges = store_function.executable_body.trap_edges;
    defer store_function.executable_body.trap_edges = saved_edges;
    store_function.executable_body.trap_edges = saved_edges[0..0];
    try std.testing.expectError(error.InvalidCompletionClaim, executable.verify(store_function));
    var duplicate_edges = [_]mir.ExecutableTrapEdge{ saved_edges[0], saved_edges[0] };
    store_function.executable_body.trap_edges = duplicate_edges[0..];
    try std.testing.expectError(error.InvalidTrapEdge, executable.verify(store_function));
    store_function.executable_body.trap_edges = saved_edges;
    try executable.verify(store_function);

    const identity = &module.functions[3];
    for (identity.executable_body.expressions) |value| switch (value.operation) {
        .address_of => |address| {
            try std.testing.expect(address.representation_span_id.isValid());
            try std.testing.expect(address.representation_source != null);
            try std.testing.expect(address.place.eql(identity.executable_body.places[0].id));
            return;
        },
        else => {},
    };
    return error.TestUnexpectedResult;
}

test "type keys distinguish every legacy spelling collision family" {
    const pointer_u8: mir.ValueType = .{ .pointer = .{ .kind = .single, .mutability = .mut, .child = "u8" } };
    const pointer_u32: mir.ValueType = .{ .pointer = .{ .kind = .single, .mutability = .mut, .child = "u32" } };
    const nullable_pointer_u8: mir.ValueType = .{ .nullable_pointer = .{ .kind = .single, .mutability = .mut, .child = "u8" } };
    try std.testing.expectEqualStrings(pointer_u8.name(), pointer_u32.name());
    try std.testing.expectEqualStrings(pointer_u8.name(), nullable_pointer_u8.name());
    try std.testing.expect(!mir.TypeKey.eql(mir.TypeKey.fromValueType(pointer_u8), mir.TypeKey.fromValueType(pointer_u32)));
    try std.testing.expect(!mir.TypeKey.eql(mir.TypeKey.fromValueType(pointer_u8), mir.TypeKey.fromValueType(nullable_pointer_u8)));

    const named_collisions = [_]mir.ValueType{
        .{ .nullable_value = "Payload" },
        .{ .slice = "Payload" },
        .{ .array = "Payload" },
        .{ .struct_ = "Payload" },
    };
    for (named_collisions, 0..) |left, left_index| for (named_collisions[left_index + 1 ..]) |right| {
        try std.testing.expectEqualStrings(left.name(), right.name());
        try std.testing.expect(!mir.TypeKey.eql(mir.TypeKey.fromValueType(left), mir.TypeKey.fromValueType(right)));
    };

    const first_result: mir.ValueType = .{ .result = .{ .ok = "u32", .err = "IoError" } };
    const second_result: mir.ValueType = .{ .result = .{ .ok = "u64", .err = "IoError" } };
    try std.testing.expectEqualStrings(first_result.name(), second_result.name());
    try std.testing.expect(!mir.TypeKey.eql(mir.TypeKey.fromValueType(first_result), mir.TypeKey.fromValueType(second_result)));

    const physical: mir.ValueType = .{ .address = .paddr };
    const virtual: mir.ValueType = .{ .address = .vaddr };
    try std.testing.expect(!mir.TypeKey.eql(mir.TypeKey.fromValueType(physical), mir.TypeKey.fromValueType(virtual)));
}

test "shadowed local generations keep executable admission closed" {
    const source =
        \\fn shadowed(flag: bool) -> u32 {
        \\    if flag { let temporary: u32 = 1; } else { let temporary: u32 = 2; }
        \\    return 0;
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "executable_shadow.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source_parser = parser.Parser.init(source, &reporter);
    const parsed = try source_parser.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    var module = try mir.buildFromDecls(std.testing.allocator, parsed.decls);
    defer module.deinit();
    const function = &module.functions[0];
    try executable.verify(function);
    try std.testing.expect(!executable.isComplete(function));
}

test "builtin call is explicit and keeps mechanical admission closed" {
    const source =
        \\fn make_phys(value: usize) -> PAddr {
        \\    return phys(value);
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "executable_builtin.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source_parser = parser.Parser.init(source, &reporter);
    const parsed = try source_parser.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    var module = try mir.buildFromDecls(std.testing.allocator, parsed.decls);
    defer module.deinit();
    const function = &module.functions[0];
    try executable.verify(function);
    try std.testing.expect(!executable.isComplete(function));
    var saw_builtin = false;
    for (function.executable_body.expressions) |value| switch (value.operation) {
        .builtin_call => |call| {
            saw_builtin = true;
            try std.testing.expectEqual(mir.CallTargetKind.phys, call.kind);
            try std.testing.expect(call.callee_span_id.isValid());
        },
        else => {},
    };
    try std.testing.expect(saw_builtin);
}

test "scalar bitcast builtin is complete only for an equal-width bit pattern" {
    const source =
        \\fn int_bits(value: i32) -> u32 { return bitcast<u32>(value); }
        \\fn float_bits(value: f32) -> u32 { return bitcast<u32>(value); }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "executable_bitcast.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source_parser = parser.Parser.init(source, &reporter);
    const parsed = try source_parser.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    var module = try mir.buildFromDecls(std.testing.allocator, parsed.decls);
    defer module.deinit();

    for (module.functions) |*function| {
        try executable.verify(function);
        try std.testing.expect(executable.isComplete(function));
        var saw_bitcast = false;
        for (function.executable_body.expressions) |expression| switch (expression.operation) {
            .builtin_call => |call| {
                try std.testing.expectEqual(mir.CallTargetKind.bitcast, call.kind);
                try std.testing.expectEqual(@as(usize, 1), call.argument_count);
                const operand = function.executable_body.expressions[call.arguments[0].index()];
                try std.testing.expect(mir_model.executableBuiltinTypesValid(.bitcast, expression.result_ty, &.{operand.result_ty}));
                saw_bitcast = true;
            },
            else => {},
        };
        try std.testing.expect(saw_bitcast);
    }

    try std.testing.expect(!mir_model.executableBuiltinTypesValid(.bitcast, .{ .integer = "u64" }, &.{.{ .integer = "u32" }}));
    try std.testing.expect(!mir_model.executableBuiltinTypesValid(.bitcast, .{ .float = "f64" }, &.{.{ .integer = "u32" }}));
    try std.testing.expect(!mir_model.executableBuiltinTypesValid(.bitcast, .{ .integer = "u32" }, &.{}));
}

test "float literal carries canonical width-specific IEEE bits" {
    const source =
        \\fn small() -> f32 { return 1.5; }
        \\fn wide() -> f64 { return 1.5; }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "executable_float.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source_parser = parser.Parser.init(source, &reporter);
    const parsed = try source_parser.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    var module = try mir.buildFromDecls(std.testing.allocator, parsed.decls);
    defer module.deinit();

    var checked: usize = 0;
    for (module.functions, 0..) |*function, function_index| {
        try executable.verify(function);
        try std.testing.expect(executable.isComplete(function));
        for (function.executable_body.expressions) |*value| switch (value.operation) {
            .literal => |*literal| switch (literal.*) {
                .float => |*float| {
                    const saved = float.*;
                    if (function_index == 0) {
                        try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 1.5))), float.f32_bits);
                        float.* = .{ .f64_bits = @bitCast(@as(f64, 1.5)) };
                    } else {
                        try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 1.5))), float.f64_bits);
                        float.* = .{ .f32_bits = @bitCast(@as(f32, 1.5)) };
                    }
                    try std.testing.expectError(error.InvalidLiteral, executable.verify(function));
                    float.* = saved;
                    try executable.verify(function);
                    checked += 1;
                },
                else => {},
            },
            else => {},
        };
    }
    try std.testing.expectEqual(@as(usize, 2), checked);
}

test "verifier rejects expression evaluation order drift" {
    const source = "fn add(left: u32, right: u32) -> u32 { return left + right; }";
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "executable_order.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source_parser = parser.Parser.init(source, &reporter);
    const parsed = try source_parser.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    var module = try mir.buildFromDecls(std.testing.allocator, parsed.decls);
    defer module.deinit();
    const function = &module.functions[0];
    try executable.verify(function);
    for (function.executable_body.expressions) |*value| switch (value.operation) {
        .binary => |*binary| {
            const saved = binary.left;
            binary.left = value.id;
            try std.testing.expectError(error.InvalidEvaluationOrder, executable.verify(function));
            binary.left = saved;
            try executable.verify(function);
            return;
        },
        else => {},
    };
    return error.TestUnexpectedResult;
}

test "lowering admission rejects executable body identity drift" {
    const source = "fn bits(left: u32, right: u32) -> u32 { return left ^ right; }";
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "executable_admission.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source_parser = parser.Parser.init(source, &reporter);
    const parsed = try source_parser.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    var module = try mir.buildFromDecls(std.testing.allocator, parsed.decls);
    defer module.deinit();
    try mir.validateLoweringAdmission(module);
    const function = &module.functions[0];
    for (function.executable_body.expressions) |*value| switch (value.operation) {
        .binary => |*binary| {
            const saved = binary.right;
            binary.right = value.id;
            try std.testing.expectError(error.InvalidMirExecutableBody, mir.validateLoweringAdmission(module));
            binary.right = saved;
            try mir.validateLoweringAdmission(module);
            return;
        },
        else => {},
    };
    return error.TestUnexpectedResult;
}

test "checked traps are complete while asserts and eager logical operators remain incomplete" {
    const source =
        \\fn checked(value: u32) -> u32 { return value + 1; }
        \\fn logical(left: bool, right: bool) -> bool { return left && right; }
        \\fn asserted(value: u32) -> void { assert(value == 0); }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "executable_effects.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source_parser = parser.Parser.init(source, &reporter);
    const parsed = try source_parser.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    var module = try mir.buildFromDecls(std.testing.allocator, parsed.decls);
    defer module.deinit();
    for (module.functions, 0..) |*function, index| {
        try executable.verify(function);
        try std.testing.expectEqual(index == 0, executable.isComplete(function));
    }
}

test "checked add owns an explicit verified overflow edge" {
    const source = "fn checked(left: u32, right: u32) -> u32 { return left + right; }";
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "executable_checked_add.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source_parser = parser.Parser.init(source, &reporter);
    const parsed = try source_parser.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    var module = try mir.buildFromDecls(std.testing.allocator, parsed.decls);
    defer module.deinit();
    const function = &module.functions[0];
    try executable.verify(function);
    try std.testing.expect(function.executable_body.complete);
    try std.testing.expect(executable.isComplete(function));
    try std.testing.expectEqual(@as(usize, 1), function.executable_body.trap_edges.len);
    const edge = function.executable_body.trap_edges[0];
    try std.testing.expectEqual(mir.TrapKind.IntegerOverflow, edge.kind);
    try std.testing.expectEqual(mir.TrapSource.checked_arithmetic, edge.source);
    const owner_id = edge.owner.expressionId() orelse return error.TestUnexpectedResult;
    const owner = function.executable_body.expressions[owner_id.index()];
    switch (owner.operation) {
        .binary => |binary| {
            try std.testing.expectEqual(mir.ExecutableBinaryOp.add, binary.op);
            try std.testing.expectEqual(mir.ExecutableArithmeticSemantics.checked, binary.arithmetic);
        },
        else => return error.TestUnexpectedResult,
    }

    const saved_target = function.executable_body.trap_edges[0].trap_block;
    function.executable_body.trap_edges[0].trap_block = mir.BlockId.invalid;
    try std.testing.expectError(error.InvalidTrapEdge, executable.verify(function));
    function.executable_body.trap_edges[0].trap_block = saved_target;
    try executable.verify(function);
}

test "checked div mod and shifts own their exact exceptional edges" {
    const source =
        \\fn div_u(left: u32, right: u32) -> u32 { return left / right; }
        \\fn mod_i(left: i32, right: i32) -> i32 { return left % right; }
        \\fn shift_left(left: u32, right: u32) -> u32 { return left << right; }
        \\fn shift_right(left: i32, right: i32) -> i32 { return left >> right; }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "executable_checked_binary.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source_parser = parser.Parser.init(source, &reporter);
    const parsed = try source_parser.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    var module = try mir.buildFromDecls(std.testing.allocator, parsed.decls);
    defer module.deinit();

    const expected_counts = [_]usize{ 1, 2, 2, 1 };
    for (module.functions, expected_counts) |*function, expected_count| {
        try executable.verify(function);
        try std.testing.expect(executable.isComplete(function));
        try std.testing.expectEqual(expected_count, function.executable_body.trap_edges.len);
        var checked_owner: ?mir.ExprId = null;
        for (function.executable_body.expressions) |value| switch (value.operation) {
            .binary => |binary| if (binary.arithmetic == .checked) {
                checked_owner = value.id;
                const requirements = mir.executableCheckedBinaryTrapRequirements(binary.op, value.result_ty) orelse return error.TestUnexpectedResult;
                try std.testing.expectEqual(expected_count, requirements.count);
            },
            else => {},
        };
        const owner = checked_owner orelse return error.TestUnexpectedResult;
        for (function.executable_body.trap_edges) |edge| try std.testing.expect(edge.owner.eql(.{ .expression = owner }));
    }

    const mutated = &module.functions[2];
    const saved = mutated.executable_body.trap_edges[0].kind;
    mutated.executable_body.trap_edges[0].kind = .DivideByZero;
    try std.testing.expectError(error.InvalidCheckedArithmetic, executable.verify(mutated));
    mutated.executable_body.trap_edges[0].kind = saved;
    try executable.verify(mutated);
}

test "arithmetic domains are explicit verified executable MIR semantics" {
    const source =
        \\fn wrap_add(left: wrap<u32>, right: wrap<u32>) -> wrap<u32> { return left + right; }
        \\fn wrap_shift(left: wrap<u32>, right: wrap<u32>) -> wrap<u32> { return left << right; }
        \\fn sat_add(left: sat<u32>, right: sat<u32>) -> sat<u32> { return left + right; }
        \\fn sat_sub(left: sat<u32>, right: sat<u32>) -> sat<u32> { return left - right; }
        \\fn sat_mul(left: sat<u16>, right: sat<u16>) -> sat<u16> { return left * right; }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "executable_domains.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source_parser = parser.Parser.init(source, &reporter);
    const parsed = try source_parser.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    var module = try mir.buildFromDecls(std.testing.allocator, parsed.decls);
    defer module.deinit();

    for (module.functions, 0..) |*function, function_index| {
        try executable.verify(function);
        try std.testing.expect(executable.isComplete(function));
        try std.testing.expectEqual(@as(usize, 0), function.executable_body.trap_edges.len);
        var found = false;
        for (function.executable_body.expressions) |value| switch (value.operation) {
            .binary => |binary| {
                const expected: mir.ExecutableArithmeticSemantics = if (function_index < 2) .wrapping else .saturating;
                try std.testing.expectEqual(expected, binary.arithmetic);
                const domain = switch (value.result_ty) {
                    .domain_integer => |shape| shape,
                    else => return error.TestUnexpectedResult,
                };
                try std.testing.expectEqual(if (function_index < 2) mir.IntegerDomainKind.wrap else mir.IntegerDomainKind.sat, domain.kind);
                found = true;
            },
            else => {},
        };
        try std.testing.expect(found);
    }

    const mutated = &module.functions[0];
    for (mutated.executable_body.expressions) |*value| switch (value.operation) {
        .binary => |*binary| {
            binary.arithmetic = .saturating;
            try std.testing.expectError(error.InvalidDomainArithmetic, executable.verify(mutated));
            binary.arithmetic = .wrapping;
            try executable.verify(mutated);
            return;
        },
        else => {},
    };
    return error.TestUnexpectedResult;
}

test "ownership cleanup obligations keep executable admission closed" {
    const source =
        \\move struct Guard { id: u32 }
        \\fn make_guard() -> Guard { return .{ .id = 1 }; }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void { g.id = 0; }
        \\fn owned() -> void { var g = make_guard(); }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "executable_cleanup.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source_parser = parser.Parser.init(source, &reporter);
    const parsed = try source_parser.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    var module = try mir.buildFromDecls(std.testing.allocator, parsed.decls);
    defer module.deinit();
    for (module.functions) |*function| {
        if (!std.mem.eql(u8, function.name, "owned")) continue;
        try executable.verify(function);
        try std.testing.expect(!executable.isComplete(function));
        return;
    }
    return error.TestUnexpectedResult;
}

fn assertOperandsPrecede(value: mir.ExecutableExpression) !void {
    switch (value.operation) {
        .unary => |operation| try std.testing.expect(operation.operand.index() < value.id.index()),
        .binary => |operation| {
            try std.testing.expect(operation.left.index() < value.id.index());
            try std.testing.expect(operation.right.index() < value.id.index());
        },
        .direct_call => |call| for (call.arguments[0..call.argument_count]) |argument| try std.testing.expect(argument.index() < value.id.index()),
        .builtin_call => |call| for (call.arguments[0..call.argument_count]) |argument| try std.testing.expect(argument.index() < value.id.index()),
        else => {},
    }
}
