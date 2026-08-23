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
