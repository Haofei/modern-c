const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const mir = @import("mir.zig");
const parser = @import("parser.zig");
const plan = @import("mir_workflow_plan.zig");

test "workflow plan admits local vtable dispatch and scoped calls" {
    var module = try buildFixture();
    defer module.deinit();
    try mir.validateBindThunkFactsForLowering(module);
    const vtable = plan.build(functionByName(&module, "local_vtable_call").?) orelse return error.TestUnexpectedResult;
    switch (vtable) {
        .local_vtable_call => |workflow| {
            try std.testing.expectEqualStrings("op", workflow.local.value.name);
            try std.testing.expectEqual(@as(usize, 0), workflow.function_field_index);
            try std.testing.expectEqualStrings("mul", workflow.function_symbol.name);
            try std.testing.expectEqual(@as(usize, 3), workflow.dispatch.arg_count);
            switch (workflow.dispatch.args[0].value) {
                .address_of => |address| try std.testing.expectEqualStrings("op", address.operand.name),
                else => return error.TestUnexpectedResult,
            }
            switch (workflow.dispatch.args[2].value) {
                .value => |value| try std.testing.expectEqualStrings("y", value.name),
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
    const scoped = plan.build(functionByName(&module, "scoped_block").?) orelse return error.TestUnexpectedResult;
    switch (scoped) {
        .scoped_block => |workflow| {
            try std.testing.expectEqualStrings("out", workflow.outer.value.name);
            try std.testing.expectEqualStrings("value", workflow.outer_initializer.name);
            try std.testing.expectEqualStrings("inner", workflow.inner.value.name);
            try std.testing.expectEqualStrings("combine", workflow.inner_call.callee.name);
            switch (workflow.inner_call.args[1].value) {
                .integer_literal => |literal| try std.testing.expectEqual(@as(usize, 1), literal.value),
                else => return error.TestUnexpectedResult,
            }
            try std.testing.expectEqualStrings("consume_u32", workflow.consume_call.callee.name);
            try std.testing.expect(workflow.inner_scope_last_use.span_id.eql(workflow.consume_call.args[0].location.span_id));
        },
        else => return error.TestUnexpectedResult,
    }
    const closure = plan.build(functionByName(&module, "call_closure").?) orelse return error.TestUnexpectedResult;
    switch (closure) {
        .call_closure => |workflow| {
            try std.testing.expectEqualStrings("env", workflow.environment.value.name);
            try std.testing.expectEqualStrings("env", workflow.bind.capture.operand.name);
            try std.testing.expectEqualStrings("store_value", workflow.bind.target.name);
            try std.testing.expectEqualStrings("set", workflow.bind.closure.name);
            try std.testing.expectEqualStrings("value", workflow.call.argument.name);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "workflow plans are invariant under function and local renaming" {
    var module = try buildFixture();
    defer module.deinit();
    try mir.validateBindThunkFactsForLowering(module);
    for ([_][]const u8{ "local_vtable_call", "scoped_block", "call_closure" }) |name| {
        const function = functionByName(&module, name).?;
        function.name = "renamed_workflow";
        for (function.value_identities) |*identity| identity.spelling = "renamed_value";
        try std.testing.expect(plan.build(function) != null);
    }
}

test "workflow plan fails closed for stale address and direct argument identities" {
    var module = try buildFixture();
    defer module.deinit();
    const vtable = functionByName(&module, "local_vtable_call").?;
    var address_mutated = false;
    for (vtable.access_facts) |*fact| switch (fact.*) {
        .address_of => |*address| {
            address.operand_span_id = .invalid;
            address_mutated = true;
            break;
        },
        else => {},
    };
    try std.testing.expect(address_mutated);
    try std.testing.expect(plan.build(vtable) == null);

    var scoped_module = try buildFixture();
    defer scoped_module.deinit();
    const scoped = functionByName(&scoped_module, "scoped_block").?;
    var mutated = false;
    for (scoped.target_type_facts) |*fact| {
        if (fact.kind == .direct_call_argument and fact.target_owner != null and std.mem.eql(u8, fact.target_owner.?, "consume_u32")) {
            fact.typed_operand_value_id = .invalid;
            mutated = true;
            break;
        }
    }
    try std.testing.expect(mutated);
    try std.testing.expect(plan.build(scoped) == null);

    var closure_module = try buildFixture();
    defer closure_module.deinit();
    const closure = functionByName(&closure_module, "call_closure").?;
    try std.testing.expectEqual(@as(usize, 1), closure.bind_thunk_facts.len);
    closure.bind_thunk_facts[0].capture_value_id = .invalid;
    try std.testing.expectError(error.InvalidMirBindThunkFacts, mir.validateBindThunkFactsForLowering(closure_module));
    try std.testing.expect(plan.build(closure) == null);
}

fn buildFixture() !mir.Module {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_workflow.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const parsed = try p.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    return mir.buildFromDecls(std.testing.allocator, parsed.decls);
}

fn functionByName(module: *mir.Module, name: []const u8) ?*mir.Function {
    for (module.functions) |*function| if (std.mem.eql(u8, function.name, name)) return function;
    return null;
}

const source =
    \\struct BinOp { combine: fn(u32, u32) -> u32 }
    \\struct Env { value: u32 }
    \\fn mul(a: u32, b: u32) -> u32 { return a * b; }
    \\fn dispatch(o: *BinOp, x: u32, y: u32) -> u32 { return o.combine(x, y); }
    \\extern fn consume_u32(value: u32) -> void;
    \\extern fn combine(left: u32, right: u32) -> u32;
    \\fn store_value(env: *mut Env, value: u32) -> void { env.value = value; }
    \\fn local_vtable_call(x: u32, y: u32) -> u32 {
    \\    var op: BinOp = .{ .combine = mul };
    \\    return dispatch(&op, x, y);
    \\}
    \\fn scoped_block(value: u32) -> u32 {
    \\    var out: u32 = value;
    \\    { let inner: u32 = combine(value, 1); consume_u32(inner); }
    \\    return out;
    \\}
    \\fn call_closure(value: u32) -> void {
    \\    var env: Env = .{ .value = 0 };
    \\    let set: closure(u32) -> void = bind(&env, store_value);
    \\    set(value);
    \\}
;
