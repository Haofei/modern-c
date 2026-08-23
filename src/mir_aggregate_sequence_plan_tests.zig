const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const mir = @import("mir.zig");
const parser = @import("parser.zig");
const plan = @import("mir_aggregate_sequence_plan.zig");

test "aggregate sequence plan admits assignment calls and struct field calls" {
    var module = try buildFixture();
    defer module.deinit();
    const assignment = plan.build(functionByName(&module, "aggregate_call_after_assignment").?) orelse return error.TestUnexpectedResult;
    switch (assignment) {
        .aggregate_call_after_assignment => |sequence| {
            try std.testing.expectEqual(@as(usize, 7), sequence.count);
            switch (sequence.steps[1]) {
                .copy_index_assignment => |copy| {
                    try std.testing.expectEqual(@as(usize, 0), copy.index);
                    try std.testing.expectEqual(mir.TrapKind.Bounds, copy.bounds_trap.kind);
                },
                else => return error.TestUnexpectedResult,
            }
            switch (sequence.steps[4]) {
                .direct_call => |call| try std.testing.expectEqualStrings("consume_row", call.callee.name),
                else => return error.TestUnexpectedResult,
            }
            switch (sequence.steps[5]) {
                .direct_call => |call| try std.testing.expectEqualStrings("consume_pair", call.callee.name),
                else => return error.TestUnexpectedResult,
            }
            switch (sequence.steps[6]) {
                .binary_return => |returned| try std.testing.expectEqual(mir.TrapKind.IntegerOverflow, returned.overflow_trap.kind),
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
    const bag_function = functionByName(&module, "make_bag").?;
    const bag = plan.build(bag_function) orelse return error.TestUnexpectedResult;
    switch (bag) {
        .struct_literal_direct_calls => |literal| {
            try std.testing.expectEqual(@as(usize, 0), literal.fields[0].field_index);
            try std.testing.expectEqualStrings("make_values", literal.fields[0].call.callee.name);
            try std.testing.expectEqual(@as(usize, 1), literal.fields[1].field_index);
            try std.testing.expectEqualStrings("make_tail", literal.fields[1].call.callee.name);
            try std.testing.expect(literal.fields[1].representation_trap != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "aggregate sequence plans are invariant under function and local renaming" {
    var module = try buildFixture();
    defer module.deinit();
    const assignment = functionByName(&module, "aggregate_call_after_assignment").?;
    assignment.name = "renamed_assignment";
    for (assignment.value_identities) |*identity| identity.spelling = "renamed_value";
    try std.testing.expect(plan.build(assignment) != null);
    const literal = functionByName(&module, "make_bag").?;
    literal.name = "renamed_literal";
    for (literal.value_identities) |*identity| identity.spelling = "renamed_value";
    try std.testing.expect(plan.build(literal) != null);
}

test "aggregate sequence plan fails closed for stale call and field identities" {
    var module = try buildFixture();
    defer module.deinit();
    const function = functionByName(&module, "aggregate_call_after_assignment").?;
    for (function.target_type_facts) |*fact| {
        if (fact.kind == .direct_call_argument and fact.target_owner != null and std.mem.eql(u8, fact.target_owner.?, "consume_row")) {
            fact.typed_operand_value_id = .invalid;
            break;
        }
    }
    try std.testing.expect(plan.build(function) == null);

    var bag_module = try buildFixture();
    defer bag_module.deinit();
    const bag = functionByName(&bag_module, "make_bag").?;
    var mutated = false;
    for (bag.blocks[0].instructions) |*instruction| {
        if (instruction.kind == .expr and std.mem.eql(u8, instruction.detail, "struct_literal") and instruction.typed_aggregate_operand_count == 2) {
            instruction.typed_aggregate_field_indices[1] = 0;
            mutated = true;
            break;
        }
    }
    try std.testing.expect(mutated);
    try std.testing.expect(plan.build(bag) == null);
}

fn buildFixture() !mir.Module {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_aggregate_sequence.mc", source);
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
    \\struct Pair { left: u32, right: u32 }
    \\struct Bag { values: [4]u32, tail: []const u32 }
    \\global matrix: [2][2]u32 = .{ .{ 1, 2 }, .{ 3, 4 } };
    \\extern fn consume_row(row: [2]u32) -> u32;
    \\extern fn make_values(seed: u32) -> [4]u32;
    \\extern fn make_tail(seed: u32) -> []const u32;
    \\fn consume_pair(pair: Pair) -> u32 { return pair.left + pair.right; }
    \\fn aggregate_call_after_assignment() -> u32 {
    \\    var row: [2]u32 = uninit;
    \\    row = matrix[0];
    \\    var pair: Pair = uninit;
    \\    pair = .{ .left = 71, .right = 72 };
    \\    return consume_row(row) + consume_pair(pair);
    \\}
    \\fn make_bag(seed: u32) -> Bag {
    \\    return .{ .values = make_values(seed), .tail = make_tail(seed) };
    \\}
;
