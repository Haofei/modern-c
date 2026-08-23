const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const mir = @import("mir.zig");
const parser = @import("parser.zig");
const plan = @import("mir_nullable_control_plan.zig");

test "nullable control plan admits strict if-let call global and field subjects" {
    const source = fixture_source;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "nullable_control.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const parsed = try p.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    var module = try mir.buildFromDecls(std.testing.allocator, parsed.decls);
    defer module.deinit();
    const call_plan = plan.build(functionByName(&module, "unwrap_call_or_zero").?) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(plan.Plan.Form.if_let, call_plan.form);
    switch (call_plan.subject) {
        .direct_call => |subject| {
            try std.testing.expectEqualStrings("maybe_ptr", subject.call.callee_name);
            try std.testing.expect(subject.seed == null);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("p", call_plan.binding.name);
    switch (call_plan.then_return.operand) {
        .direct_call => |call| try std.testing.expectEqualStrings("ptr_value", call.call.callee_name),
        else => return error.TestUnexpectedResult,
    }

    const global_plan = plan.build(functionByName(&module, "unwrap_global_or_zero").?) orelse return error.TestUnexpectedResult;
    switch (global_plan.subject) {
        .global => |subject| try std.testing.expectEqualStrings("saved_nullable", subject.name),
        else => return error.TestUnexpectedResult,
    }

    const field_plan = plan.build(functionByName(&module, "unwrap_field_or_zero").?) orelse return error.TestUnexpectedResult;
    switch (field_plan.subject) {
        .field => |subject| {
            try std.testing.expectEqualStrings("box", subject.base_name);
            try std.testing.expectEqualStrings("maybe", subject.field_name);
            try std.testing.expectEqual(@as(usize, 0), subject.field_index);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "nullable control plan admits strict switch parameter and call seed subjects" {
    const source = fixture_source;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "nullable_control.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const parsed = try p.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    var module = try mir.buildFromDecls(std.testing.allocator, parsed.decls);
    defer module.deinit();

    const parameter_plan = plan.build(functionByName(&module, "nullable_switch").?) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(plan.Plan.Form.switch_, parameter_plan.form);
    switch (parameter_plan.subject) {
        .parameter => |subject| try std.testing.expectEqualStrings("maybe", subject.name),
        else => return error.TestUnexpectedResult,
    }

    const seeded_plan = plan.build(functionByName(&module, "nullable_switch_call_seed").?) orelse return error.TestUnexpectedResult;
    switch (seeded_plan.subject) {
        .direct_call => |subject| {
            try std.testing.expectEqualStrings("maybe_ptr_from", subject.call.callee_name);
            try std.testing.expectEqualStrings("next_seed", subject.seed.?.callee_name);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "nullable control plan admits binding-or-fallback parameter returns" {
    const source = fixture_source;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "nullable_control.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const parsed = try p.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    var module = try mir.buildFromDecls(std.testing.allocator, parsed.decls);
    defer module.deinit();

    const unwrap_plan = plan.build(functionByName(&module, "unwrap_or").?) orelse return error.TestUnexpectedResult;
    switch (unwrap_plan.subject) {
        .parameter => |subject| try std.testing.expectEqualStrings("maybe", subject.name),
        else => return error.TestUnexpectedResult,
    }
    switch (unwrap_plan.then_return.operand) {
        .binding => |binding| try std.testing.expectEqualStrings("p", binding.name),
        else => return error.TestUnexpectedResult,
    }
    switch (unwrap_plan.else_return.operand) {
        .parameter => |parameter| {
            try std.testing.expectEqualStrings("fallback", parameter.name);
            try std.testing.expect(parameter.requires_nonnull_check);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "nullable control plan fails closed for a stale binding identity and extra effect" {
    const source = fixture_source;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "nullable_control.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const parsed = try p.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    var module = try mir.buildFromDecls(std.testing.allocator, parsed.decls);
    defer module.deinit();

    const function = functionByName(&module, "unwrap_call_or_zero").?;
    try std.testing.expect(plan.build(function) != null);
    for (function.target_type_facts) |*fact| {
        if (fact.kind == .direct_call_argument and fact.target_owner != null and std.mem.eql(u8, fact.target_owner.?, "ptr_value") and fact.typed_operand_value_id.isValid()) {
            fact.typed_operand_value_id = .invalid;
            break;
        }
    }
    try std.testing.expect(plan.build(function) == null);
}

fn functionByName(module: *mir.Module, name: []const u8) ?*mir.Function {
    for (module.functions) |*function| if (std.mem.eql(u8, function.name, name)) return function;
    return null;
}

const fixture_source =
    \\extern fn maybe_ptr() -> ?*mut u8;
    \\extern fn maybe_ptr_from(seed: u32) -> ?*mut u8;
    \\extern fn next_seed() -> u32;
    \\extern fn ptr_value(p: *mut u8) -> u32;
    \\global saved_nullable: ?*mut u8 = null;
    \\struct NullableBox { maybe: ?*mut u8, }
    \\
    \\fn unwrap_call_or_zero() -> u32 {
    \\    if let p = maybe_ptr() { return ptr_value(p); }
    \\    return 0;
    \\}
    \\fn unwrap_global_or_zero() -> u32 {
    \\    if let p = saved_nullable { return ptr_value(p); }
    \\    return 0;
    \\}
    \\fn unwrap_field_or_zero(box: NullableBox) -> u32 {
    \\    if let p = box.maybe { return ptr_value(p); }
    \\    return 0;
    \\}
    \\fn nullable_switch(maybe: ?*mut u8) -> u32 {
    \\    switch maybe { p => { return ptr_value(p); }, _ => { return 0; }, }
    \\}
    \\fn nullable_switch_call_seed() -> u32 {
    \\    switch maybe_ptr_from(next_seed()) { p => { return ptr_value(p); }, _ => { return 0; }, }
    \\}
    \\fn unwrap_or(maybe: ?*mut u8, fallback: *mut u8) -> *mut u8 {
    \\    if let p = maybe { return p; }
    \\    return fallback;
    \\}
;
