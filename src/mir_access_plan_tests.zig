const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const mir = @import("mir.zig");
const parser = @import("parser.zig");
const plan = @import("mir_access_plan.zig");

test "access plan admits strict address deref index and range-slice facts" {
    var module = try buildFixture();
    defer module.deinit();
    var access_plan = try plan.build(std.testing.allocator, functionByName(&module, "access_shapes").?) orelse return error.TestUnexpectedResult;
    defer access_plan.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), access_plan.accesses.len);
    var saw_address = false;
    var saw_deref = false;
    var saw_index = false;
    var saw_slice = false;
    for (access_plan.accesses) |access| switch (access) {
        .address_of => |entry| {
            try std.testing.expect(entry.result.id.isValid());
            try std.testing.expect(entry.operand.location.span_id.isValid());
            try std.testing.expect(entry.operand.value_id != null);
            saw_address = true;
        },
        .deref => |entry| {
            try std.testing.expect(entry.result.id.isValid());
            try std.testing.expect(entry.operand.value_id != null);
            saw_deref = true;
        },
        .index => |entry| {
            try std.testing.expect(entry.result.id.isValid());
            try std.testing.expect(entry.base.value_id != null);
            try std.testing.expect(entry.index.value_id != null);
            saw_index = true;
        },
        .range_slice => |entry| {
            try std.testing.expect(entry.result.id.isValid());
            try std.testing.expect(entry.base.value_id != null);
            try std.testing.expect(entry.start.value_id == null);
            try std.testing.expect(entry.end.value_id == null);
            saw_slice = true;
        },
    };
    try std.testing.expect(saw_address and saw_deref and saw_index and saw_slice);
}

test "access plan fails closed for stale access span and bounds identity" {
    var module = try buildFixture();
    defer module.deinit();
    const function = functionByName(&module, "access_shapes").?;
    var mutated = false;
    for (function.access_facts) |*fact| switch (fact.*) {
        .range_slice => |*access| {
            access.end_span_id = .invalid;
            mutated = true;
            break;
        },
        else => {},
    };
    try std.testing.expect(mutated);
    try std.testing.expect((try plan.build(std.testing.allocator, function)) == null);

    var clean = try buildFixture();
    defer clean.deinit();
    const clean_function = functionByName(&clean, "access_shapes").?;
    for (clean_function.bounds_facts) |*fact| {
        if (fact.kind == .index) {
            fact.typed_span_id = .invalid;
            break;
        }
    }
    try std.testing.expect((try plan.build(std.testing.allocator, clean_function)) == null);

    var stale_type = try buildFixture();
    defer stale_type.deinit();
    const typed_function = functionByName(&stale_type, "access_shapes").?;
    var stale_type_mutated = false;
    for (typed_function.blocks[0].instructions) |*instruction| {
        if (instruction.kind == .index and !std.mem.startsWith(u8, instruction.detail, "range_slice")) {
            instruction.typed_result_ty = .invalid;
            stale_type_mutated = true;
            break;
        }
    }
    try std.testing.expect(stale_type_mutated);
    try std.testing.expect((try plan.build(std.testing.allocator, typed_function)) == null);
}

test "access body plan covers the bounded address and slice bucket" {
    var module = try buildBodyFixture();
    defer module.deinit();
    const names = [_][]const u8{
        "address_global_field",
        "address_array_element",
        "local_address",
        "read_slice",
        "read_literal",
        "write_slice",
        "slice_from_array",
        "slice_from_slice",
        "direct_call_slice",
        "inferred_slice_call_base_arg",
        "inferred_array_call_base",
        "address_field",
        "write_through_global_pointer",
    };
    for (names) |name| {
        var body = try plan.buildAccessBody(std.testing.allocator, functionByName(&module, name).?) orelse return error.TestUnexpectedResult;
        defer body.deinit(std.testing.allocator);
        try std.testing.expect(body.entry_block.isValid());
        try std.testing.expect(body.accesses.len != 0);
        try std.testing.expect(body.statements.len != 0);
        try std.testing.expect(body.statements[body.statements.len - 1] == .return_value);
    }
}

test "structural operation closes the remaining strict access families" {
    var module = try buildBodyFixture();
    defer module.deinit();
    const returned = [_][]const u8{
        "address_global_field",
        "address_array_element",
        "local_address",
        "slice_from_array",
        "slice_from_slice",
        "inferred_slice_call_base_arg",
        "inferred_array_call_base",
        "address_field",
    };
    for (returned) |name| {
        var body = try plan.buildAccessBody(std.testing.allocator, functionByName(&module, name).?) orelse return error.TestUnexpectedResult;
        defer body.deinit(std.testing.allocator);
        switch (plan.buildStructuralOperation(body) orelse return error.TestUnexpectedResult) {
            .return_access => |operation| {
                try std.testing.expect(operation.access_index < body.accesses.len);
                try std.testing.expect(operation.location.span_id.isValid());
            },
            else => return error.TestUnexpectedResult,
        }
    }

    var stored = try plan.buildAccessBody(std.testing.allocator, functionByName(&module, "write_through_global_pointer").?) orelse return error.TestUnexpectedResult;
    defer stored.deinit(std.testing.allocator);
    switch (plan.buildStructuralOperation(stored) orelse return error.TestUnexpectedResult) {
        .store_access_then_return => |operation| {
            try std.testing.expect(operation.store.target_access_index < stored.accesses.len);
            try std.testing.expect(operation.return_location.span_id.isValid());
        },
        else => return error.TestUnexpectedResult,
    }
}

test "structural operation admission is independent of source names" {
    var module = try buildRenamedBodyFixture();
    defer module.deinit();
    for ([_][]const u8{
        "probe_crate",
        "probe_slot",
        "probe_local",
        "window_of",
        "subwindow",
        "materialized_slice",
        "materialized_array",
        "field_probe",
    }) |name| {
        var body = try plan.buildAccessBody(std.testing.allocator, functionByName(&module, name).?) orelse return error.TestUnexpectedResult;
        defer body.deinit(std.testing.allocator);
        try std.testing.expect((plan.buildStructuralOperation(body) orelse return error.TestUnexpectedResult) == .return_access);
    }
    var stored = try plan.buildAccessBody(std.testing.allocator, functionByName(&module, "mutate_root").?) orelse return error.TestUnexpectedResult;
    defer stored.deinit(std.testing.allocator);
    try std.testing.expect((plan.buildStructuralOperation(stored) orelse return error.TestUnexpectedResult) == .store_access_then_return);
}

test "structural operation fails closed for stale result and duplicate stores" {
    var module = try buildBodyFixture();
    defer module.deinit();
    var returned = try plan.buildAccessBody(std.testing.allocator, functionByName(&module, "address_field").?) orelse return error.TestUnexpectedResult;
    defer returned.deinit(std.testing.allocator);
    for (returned.statements) |*statement| switch (statement.*) {
        .return_value => |*value| {
            value.value.?.location.span_id = .invalid;
            break;
        },
        else => {},
    };
    try std.testing.expect(plan.buildStructuralOperation(returned) == null);

    var stored = try plan.buildAccessBody(std.testing.allocator, functionByName(&module, "write_through_global_pointer").?) orelse return error.TestUnexpectedResult;
    defer stored.deinit(std.testing.allocator);
    var first_store: ?plan.Store = null;
    for (stored.statements) |statement| switch (statement) {
        .deref_store => |value| first_store = value,
        else => {},
    };
    const store = first_store orelse return error.TestUnexpectedResult;
    for (stored.statements) |*statement| switch (statement.*) {
        .deref_load => {
            statement.* = .{ .deref_store = store };
            break;
        },
        else => {},
    };
    try std.testing.expect(plan.buildStructuralOperation(stored) == null);
}

test "structural operation represents the real strict access tail" {
    var module = try buildSourceModule("real_access_tail.mc", real_access_tail_source);
    defer module.deinit();

    for ([_]struct { name: []const u8, field_index: ?usize }{
        .{ .name = "address_global_field", .field_index = 1 },
        .{ .name = "address_array_element", .field_index = null },
        .{ .name = "address_field", .field_index = 1 },
    }) |expected| {
        var body = try plan.buildAccessBody(std.testing.allocator, functionByName(&module, expected.name).?) orelse return error.TestUnexpectedResult;
        defer body.deinit(std.testing.allocator);
        switch (plan.buildStructuralOperation(body) orelse return error.TestUnexpectedResult) {
            .store_access_then_return_access => |operation| {
                try std.testing.expect(operation.store.target_access_index < body.accesses.len);
                switch (operation.value) {
                    .access_result => |index| {
                        try std.testing.expect(expected.field_index == null);
                        try std.testing.expect(index < body.accesses.len);
                    },
                    .field => |field| {
                        try std.testing.expectEqual(expected.field_index orelse return error.TestUnexpectedResult, field.field_index);
                        try std.testing.expect(field.base.value_id != null);
                        try std.testing.expect(field.result.id.isValid());
                    },
                }
            },
            else => return error.TestUnexpectedResult,
        }
    }

    var global_body = try plan.buildAccessBody(std.testing.allocator, functionByName(&module, "write_through_global_pointer").?) orelse return error.TestUnexpectedResult;
    defer global_body.deinit(std.testing.allocator);
    switch (plan.buildStructuralOperation(global_body) orelse return error.TestUnexpectedResult) {
        .store_access_then_return_operand => |operation| {
            try std.testing.expectEqualStrings("shared", operation.value.name orelse return error.TestUnexpectedResult);
            try std.testing.expect(operation.value.value_id != null);
        },
        else => return error.TestUnexpectedResult,
    }

    var slice_body = try plan.buildAccessBody(std.testing.allocator, functionByName(&module, "slice_from_slice").?) orelse return error.TestUnexpectedResult;
    defer slice_body.deinit(std.testing.allocator);
    switch (plan.buildStructuralOperation(slice_body) orelse return error.TestUnexpectedResult) {
        .range_slice_local_then_return_builtin => |operation| {
            try std.testing.expectEqualStrings("s", operation.local.name);
            switch (operation.local.value) {
                .access_result => |index| try std.testing.expectEqual(operation.range_access_index, index),
                else => return error.TestUnexpectedResult,
            }
            try std.testing.expectEqual(mir.Instruction.BuiltinMember.slice_length, operation.member.member);
            try std.testing.expect(operation.member.base.value_id.?.eql(operation.local.value_id));
        },
        else => return error.TestUnexpectedResult,
    }
}

test "structural operation real tail remains independent of source names" {
    var module = try buildSourceModule("renamed_access_tail.mc", renamed_access_tail_source);
    defer module.deinit();
    for ([_][]const u8{ "change_crate", "change_slot", "change_box" }) |name| {
        var body = try plan.buildAccessBody(std.testing.allocator, functionByName(&module, name).?) orelse return error.TestUnexpectedResult;
        defer body.deinit(std.testing.allocator);
        try std.testing.expect((plan.buildStructuralOperation(body) orelse return error.TestUnexpectedResult) == .store_access_then_return_access);
    }
    var global_body = try plan.buildAccessBody(std.testing.allocator, functionByName(&module, "replace_root").?) orelse return error.TestUnexpectedResult;
    defer global_body.deinit(std.testing.allocator);
    try std.testing.expect((plan.buildStructuralOperation(global_body) orelse return error.TestUnexpectedResult) == .store_access_then_return_operand);
    var slice_body = try plan.buildAccessBody(std.testing.allocator, functionByName(&module, "window_size").?) orelse return error.TestUnexpectedResult;
    defer slice_body.deinit(std.testing.allocator);
    try std.testing.expect((plan.buildStructuralOperation(slice_body) orelse return error.TestUnexpectedResult) == .range_slice_local_then_return_builtin);
}

test "structural operation real tail fails closed on stale projection facts" {
    var field_module = try buildSourceModule("stale_field_tail.mc", real_access_tail_source);
    defer field_module.deinit();
    const field_function = functionByName(&field_module, "address_global_field").?;
    var cleared_field = false;
    for (field_function.blocks[0].instructions) |*instruction| {
        if (instruction.kind == .expr and instruction.member_field_index != null and instruction.typed_span_id.eql(returnOperandSpan(field_function) orelse continue)) {
            instruction.member_field_index = null;
            cleared_field = true;
            break;
        }
    }
    try std.testing.expect(cleared_field);
    try std.testing.expect((try plan.buildAccessBody(std.testing.allocator, field_function)) == null);

    var builtin_module = try buildSourceModule("stale_builtin_tail.mc", real_access_tail_source);
    defer builtin_module.deinit();
    const builtin_function = functionByName(&builtin_module, "slice_from_slice").?;
    var cleared_builtin = false;
    for (builtin_function.blocks[0].instructions) |*instruction| {
        if (instruction.builtin_member == .slice_length) {
            instruction.builtin_member = null;
            cleared_builtin = true;
            break;
        }
    }
    try std.testing.expect(cleared_builtin);
    try std.testing.expect((try plan.buildAccessBody(std.testing.allocator, builtin_function)) == null);

    var identity_module = try buildSourceModule("stale_identity_tail.mc", real_access_tail_source);
    defer identity_module.deinit();
    const identity_function = functionByName(&identity_module, "write_through_global_pointer").?;
    const return_span = returnOperandSpan(identity_function) orelse return error.TestUnexpectedResult;
    var cleared_identity = false;
    for (identity_function.blocks[0].instructions) |*instruction| {
        if (instruction.kind == .expr and instruction.typed_span_id.eql(return_span)) {
            instruction.typed_value_id = null;
            cleared_identity = true;
            break;
        }
    }
    try std.testing.expect(cleared_identity);
    var identity_body = try plan.buildAccessBody(std.testing.allocator, identity_function) orelse return error.TestUnexpectedResult;
    defer identity_body.deinit(std.testing.allocator);
    try std.testing.expect(plan.buildStructuralOperation(identity_body) == null);
}

test "access body initializer and address place carry typed operations" {
    var module = try buildBodyFixture();
    defer module.deinit();

    var array_body = try plan.buildAccessBody(std.testing.allocator, functionByName(&module, "address_array_element").?) orelse return error.TestUnexpectedResult;
    defer array_body.deinit(std.testing.allocator);
    const array_local = localByName(array_body, "values") orelse return error.TestUnexpectedResult;
    switch (array_local.value) {
        .graph => |graph| {
            const root = graph.nodes[graph.root];
            switch (root.operation) {
                .array_literal => |array| {
                    try std.testing.expectEqual(@as(usize, 2), array.count);
                    switch (graph.nodes[array.children[0]].operation) {
                        .integer_literal => |literal| try std.testing.expectEqual(@as(usize, 4), literal.value),
                        else => return error.TestUnexpectedResult,
                    }
                },
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
    const array_address = firstAddress(array_body) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(plan.AddressPlace.RootKind.local, array_address.place.root_kind);
    try std.testing.expectEqual(@as(usize, 1), array_address.place.projection_count);
    switch (array_address.place.projections[0]) {
        .constant_index => |index| {
            try std.testing.expectEqual(@as(usize, 0), index.index);
            try std.testing.expectEqual(@as(usize, 2), index.bound);
        },
        else => return error.TestUnexpectedResult,
    }

    var call_body = try plan.buildAccessBody(std.testing.allocator, functionByName(&module, "inferred_slice_call_base_arg").?) orelse return error.TestUnexpectedResult;
    defer call_body.deinit(std.testing.allocator);
    switch ((localByName(call_body, "values") orelse return error.TestUnexpectedResult).value) {
        .direct_call => |call| {
            try std.testing.expectEqualStrings("make_slice", call.callee_name);
            try std.testing.expect(call.callee_value_id.isValid());
        },
        else => return error.TestUnexpectedResult,
    }

    var address_body = try plan.buildAccessBody(std.testing.allocator, functionByName(&module, "address_field").?) orelse return error.TestUnexpectedResult;
    defer address_body.deinit(std.testing.allocator);
    const address = firstAddress(address_body) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(plan.AddressPlace.RootKind.local, address.place.root_kind);
    try std.testing.expectEqual(@as(usize, 1), address.place.projection_count);
    switch (address.place.projections[0]) {
        .field => |field| try std.testing.expectEqual(@as(usize, 0), field.index),
        else => return error.TestUnexpectedResult,
    }
}

test "access body plan fails closed for stale initializer aggregate and address projection" {
    var aggregate_module = try buildBodyFixture();
    defer aggregate_module.deinit();
    const aggregate_function = functionByName(&aggregate_module, "address_array_element").?;
    for (aggregate_function.blocks[0].instructions) |*instruction| {
        if (instruction.kind == .expr and std.mem.eql(u8, instruction.detail, "array_literal")) {
            instruction.typed_aggregate_operand_span_ids[0] = .invalid;
            break;
        }
    }
    try std.testing.expect((try plan.buildAccessBody(std.testing.allocator, aggregate_function)) == null);

    var place_module = try buildBodyFixture();
    defer place_module.deinit();
    const place_function = functionByName(&place_module, "address_field").?;
    for (place_function.blocks[0].instructions) |*instruction| {
        if (instruction.kind == .expr and instruction.member_field_index != null) {
            instruction.member_field_index = null;
            break;
        }
    }
    try std.testing.expect((try plan.buildAccessBody(std.testing.allocator, place_function)) == null);
}

fn localByName(body: plan.AccessBodyPlan, name: []const u8) ?plan.LocalInit {
    for (body.statements) |statement| switch (statement) {
        .local_init => |local| if (std.mem.eql(u8, local.name, name)) return local,
        else => {},
    };
    return null;
}

fn firstAddress(body: plan.AccessBodyPlan) ?plan.AddressOf {
    for (body.accesses) |access| switch (access) {
        .address_of => |address| return address,
        else => {},
    };
    return null;
}

test "access body plan rejects a stale direct-call or store identity" {
    var module = try buildBodyFixture();
    defer module.deinit();
    const function = functionByName(&module, "direct_call_slice").?;
    for (function.target_type_facts) |*fact| {
        if (fact.kind == .direct_call_result) {
            fact.typed_result_ty = .invalid;
            break;
        }
    }
    try std.testing.expect((try plan.buildAccessBody(std.testing.allocator, function)) == null);

    var stores = try buildBodyFixture();
    defer stores.deinit();
    const store_function = functionByName(&stores, "write_through_global_pointer").?;
    for (store_function.blocks[0].instructions) |*instruction| {
        if (instruction.kind == .assign) {
            instruction.typed_target_operand_span_id = .invalid;
            break;
        }
    }
    try std.testing.expect((try plan.buildAccessBody(std.testing.allocator, store_function)) == null);
}

test "access body admits real local-address update" {
    const source =
        \\fn local_address(value: u32) -> u32 { var x: u32 = value; let p: *mut u32 = &x; *p = x + 1; return x; }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "local_address.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const parsed = try p.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    var module = try mir.buildFromDecls(std.testing.allocator, parsed.decls);
    defer module.deinit();
    var body = try plan.buildAccessBody(std.testing.allocator, functionByName(&module, "local_address").?) orelse return error.TestUnexpectedResult;
    defer body.deinit(std.testing.allocator);
    for (body.statements) |statement| switch (statement) {
        .deref_store => |store| switch (store.value) {
            .checked_binary => |binary| {
                try std.testing.expectEqualStrings("add", binary.op);
                try std.testing.expectEqualStrings("x", binary.left.name.?);
                try std.testing.expectEqual(@as(usize, 1), binary.right.integer_value.?);
                return;
            },
            else => return error.TestUnexpectedResult,
        },
        else => {},
    };
    return error.TestUnexpectedResult;
}

fn buildFixture() !mir.Module {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_access_plan.mc", fixture_source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(fixture_source, &reporter);
    const parsed = try p.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    return mir.buildFromDecls(std.testing.allocator, parsed.decls);
}

fn buildBodyFixture() !mir.Module {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_access_body_plan.mc", body_fixture_source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(body_fixture_source, &reporter);
    const parsed = try p.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    return mir.buildFromDecls(std.testing.allocator, parsed.decls);
}

fn buildRenamedBodyFixture() !mir.Module {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "renamed_access_body_plan.mc", renamed_body_fixture_source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(renamed_body_fixture_source, &reporter);
    const parsed = try p.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    return mir.buildFromDecls(std.testing.allocator, parsed.decls);
}

fn buildSourceModule(path: []const u8, source: []const u8) !mir.Module {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, path, source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const parsed = try p.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    return mir.buildFromDecls(std.testing.allocator, parsed.decls);
}

fn returnOperandSpan(function: *const mir.Function) ?mir.SpanId {
    for (function.blocks[0].instructions) |instruction| {
        if (instruction.kind == .return_value) return instruction.typed_value_operand_span_id;
    }
    return null;
}

fn functionByName(module: *mir.Module, name: []const u8) ?*mir.Function {
    for (module.functions) |*function| if (std.mem.eql(u8, function.name, name)) return function;
    return null;
}

const fixture_source =
    \\fn access_shapes(values: [4]u32, index: usize) -> u32 {
    \\    var local: u32 = 1;
    \\    let pointer: *mut u32 = &local;
    \\    let window: []u32 = values[1..3];
    \\    return window[index] + pointer.*;
    \\}
;

const body_fixture_source =
    \\struct Holder { value: u32 }
    \\global shared_holder: Holder = .{ .value = 4 };
    \\global shared_value: u32 = 0;
    \\extern fn make_slice() -> []const u32;
    \\extern fn make_array() -> [2]u32;
    \\
    \\fn address_global_field() -> u32 { let pointer = &shared_holder.value; return pointer.*; }
    \\fn address_array_element() -> u32 { var values: [2]u32 = .{ 4, 5 }; let pointer = &values[0]; return pointer.*; }
    \\fn local_address() -> u32 { var value: u32 = 4; let pointer = &value; return pointer.*; }
    \\fn read_slice(xs: []const u32, i: usize) -> u32 { return xs[i]; }
    \\fn read_literal(xs: []const u32) -> u32 { return xs[0]; }
    \\fn write_slice(xs: []mut u32, i: usize, value: u32) -> void { xs[i] = value; return; }
    \\fn slice_from_array(values: [4]u32, n: usize) -> []const u32 { return values[0..n]; }
    \\fn slice_from_slice(values: []const u32, n: usize) -> []const u32 { return values[0..n]; }
    \\fn direct_call_slice(i: usize) -> u32 { return make_slice()[i]; }
    \\fn inferred_slice_call_base_arg(i: usize) -> u32 { let values = make_slice(); return values[i]; }
    \\fn inferred_array_call_base() -> u32 { let values = make_array(); return values[0]; }
    \\fn address_field() -> u32 { var holder: Holder = .{ .value = 4 }; let pointer = &holder.value; return pointer.*; }
    \\fn write_through_global_pointer(value: u32) -> void { let pointer: *mut u32 = &shared_value; pointer.* = value; return; }
;

const renamed_body_fixture_source =
    \\struct Crate { payload: u32 }
    \\global root_crate: Crate = .{ .payload = 8 };
    \\global root_word: u32 = 0;
    \\extern fn fetch_view() -> []const u32;
    \\extern fn fetch_words() -> [2]u32;
    \\
    \\fn probe_crate() -> u32 { let cursor = &root_crate.payload; return cursor.*; }
    \\fn probe_slot() -> u32 { var table: [2]u32 = .{ 8, 9 }; let cursor = &table[0]; return cursor.*; }
    \\fn probe_local() -> u32 { var cell: u32 = 8; let cursor = &cell; return cursor.*; }
    \\fn window_of(items: [4]u32, limit: usize) -> []const u32 { return items[0..limit]; }
    \\fn subwindow(items: []const u32, limit: usize) -> []const u32 { return items[0..limit]; }
    \\fn materialized_slice(at: usize) -> u32 { let produced = fetch_view(); return produced[at]; }
    \\fn materialized_array() -> u32 { let produced = fetch_words(); return produced[0]; }
    \\fn field_probe() -> u32 { var box: Crate = .{ .payload = 9 }; let cursor = &box.payload; return cursor.*; }
    \\fn mutate_root(next: u32) -> void { let cursor: *mut u32 = &root_word; cursor.* = next; return; }
;

const real_access_tail_source =
    \\struct Pair { left: u32, right: u32 }
    \\global pair: Pair = .{ .left = 1, .right = 2 };
    \\global shared: u32 = 7;
    \\global shared_ptr: *mut u32 = &shared;
    \\fn address_global_field(value: u32) -> u32 { let p: *mut u32 = &pair.right; *p = value; return pair.right; }
    \\fn address_array_element(value: u32) -> u32 { var xs: [2]u32 = .{ 3, 4 }; let p: *mut u32 = &xs[1]; *p = value; return xs[1]; }
    \\fn address_field(value: u32) -> u32 { var pair_local: Pair = .{ .left = 5, .right = 6 }; let p: *mut u32 = &pair_local.right; *p = value; return pair_local.right; }
    \\fn write_through_global_pointer(value: u32) -> u32 { *shared_ptr = value; return shared; }
    \\fn slice_from_slice(xs: []const u8, lo: usize, hi: usize) -> usize { let s: []const u8 = xs[lo..hi]; return s.len; }
;

const renamed_access_tail_source =
    \\struct Crate { first: u32, payload: u32 }
    \\global root_crate: Crate = .{ .first = 10, .payload = 20 };
    \\global root_word: u32 = 9;
    \\global root_cursor: *mut u32 = &root_word;
    \\fn change_crate(next: u32) -> u32 { let cursor: *mut u32 = &root_crate.payload; *cursor = next; return root_crate.payload; }
    \\fn change_slot(next: u32) -> u32 { var table: [2]u32 = .{ 8, 9 }; let cursor: *mut u32 = &table[1]; *cursor = next; return table[1]; }
    \\fn change_box(next: u32) -> u32 { var box: Crate = .{ .first = 3, .payload = 4 }; let cursor: *mut u32 = &box.payload; *cursor = next; return box.payload; }
    \\fn replace_root(next: u32) -> u32 { *root_cursor = next; return root_word; }
    \\fn window_size(items: []const u8, begin: usize, finish: usize) -> usize { let window: []const u8 = items[begin..finish]; return window.len; }
;
