const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const parser = @import("parser.zig");
const mir = @import("mir.zig");
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

test "unrepresented traps asserts and eager logical operators remain incomplete" {
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
    for (module.functions) |*function| {
        try executable.verify(function);
        try std.testing.expect(!executable.isComplete(function));
    }
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
