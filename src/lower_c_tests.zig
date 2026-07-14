const std = @import("std");

const diagnostics = @import("diagnostics.zig");
const lower_c = @import("lower_c.zig");
const lower_c_builtin = @import("lower_c_builtin.zig");
const lower_c_expr = @import("lower_c_expr.zig");
const lower_llvm = @import("lower_llvm.zig");
const mir = @import("mir.zig");
const parser = @import("parser.zig");
const test_support = @import("test_support.zig");

fn appendCTest(source_name: []const u8, source: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseModule(source_name, source);
    defer parsed.deinit();

    try lower_c.appendC(std.testing.allocator, parsed.module, output);
}

fn appendCheckedCTest(source_name: []const u8, source: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseCheckedModule(source_name, source);
    defer parsed.deinit();

    try lower_c.appendC(std.testing.allocator, parsed.module, output);
}

fn clearRangeFactsForFunction(module_mir: *mir.Module, name: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        module_mir.allocator.free(function.range_facts);
        function.range_facts = try module_mir.allocator.alloc(mir.RangeFact, 0);
        return;
    }
    return error.TestUnexpectedResult;
}

fn clearBoundsFactsForFunction(module_mir: *mir.Module, name: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        if (function.bounds_facts.len != 0) module_mir.allocator.free(function.bounds_facts);
        function.bounds_facts = &.{};
        return;
    }
    return error.TestUnexpectedResult;
}

fn clearRepresentationFactsForFunction(module_mir: *mir.Module, name: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        module_mir.allocator.free(function.representation_facts);
        function.representation_facts = try module_mir.allocator.alloc(mir.RepresentationFact, 0);
        return;
    }
    return error.TestUnexpectedResult;
}

fn clearIntegerFactsForFunction(module_mir: *mir.Module, name: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        if (function.integer_facts.len != 0) module_mir.allocator.free(function.integer_facts);
        function.integer_facts = try module_mir.allocator.alloc(mir.IntegerFact, 0);
        return;
    }
    return error.TestUnexpectedResult;
}

fn clearCallTargetFactsForFunction(module_mir: *mir.Module, name: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        if (function.call_target_facts.len != 0) module_mir.allocator.free(function.call_target_facts);
        function.call_target_facts = try module_mir.allocator.alloc(mir.CallTargetFact, 0);
        return;
    }
    return error.TestUnexpectedResult;
}

fn clearTargetTypeFactsForFunction(module_mir: *mir.Module, name: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        if (function.target_type_facts.len != 0) module_mir.allocator.free(function.target_type_facts);
        function.target_type_facts = try module_mir.allocator.alloc(mir.TargetTypeFact, 0);
        return;
    }
    return error.TestUnexpectedResult;
}

test "lower-c rejects prebuilt MIR with missing target type facts" {
    const source =
        \\enum E { bad }
        \\fn make(value: u32) -> Result<u32, E> { return ok(value); }
    ;
    var parsed = try test_support.parseCheckedModule("c_missing_target_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.build(std.testing.allocator, parsed.module);
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "make");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_missing_target_type_facts.mc", .{}, false, null));
}

test "lower-c Result constructors require MIR call target facts" {
    const source =
        \\enum E { bad }
        \\fn make(value: u32) -> Result<u32, E> { return ok(value); }
        \\fn forward(value: Result<u32, E>) -> Result<u32, E> { return ok(value?); }
    ;
    var parsed = try test_support.parseCheckedModule("c_result_constructor_call_facts.mc", source);
    defer parsed.deinit();
    for ([_][]const u8{ "make", "forward" }) |name| {
        var module_mir = try mir.build(std.testing.allocator, parsed.module);
        defer module_mir.deinit();
        try clearCallTargetFactsForFunction(&module_mir, name);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirCallTargetFacts, lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_result_constructor_call_facts.mc", .{}, false, null));
    }
}

test "lower-c bind closures require MIR call target facts" {
    const source =
        \\fn add_scalar(env: u32, value: u32) -> u32 { return env + value; }
        \\fn make() -> closure(u32) -> u32 { return (bind(3, add_scalar)); }
    ;
    var parsed = try test_support.parseCheckedModule("c_bind_call_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.build(std.testing.allocator, parsed.module);
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "make");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirCallTargetFacts, lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_bind_call_facts.mc", .{}, false, null));
}

test "lower-c rejects missing tagged-union target type facts" {
    const source =
        \\union Token { number: i64, eof }
        \\fn make() -> Token { return number(7); }
    ;
    var parsed = try test_support.parseCheckedModule("c_missing_union_target_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.build(std.testing.allocator, parsed.module);
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "make");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_missing_union_target_type_facts.mc", .{}, false, null));
}

test "lower-c rejects missing enum-literal target type facts" {
    const source =
        \\enum Mode: u8 { read = 1, write = 2 }
        \\fn make() -> Mode { return .read; }
    ;
    var parsed = try test_support.parseCheckedModule("c_missing_enum_target_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.build(std.testing.allocator, parsed.module);
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "make");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_missing_enum_target_type_facts.mc", .{}, false, null));
}

test "lower-c rejects missing string-literal target type facts" {
    const source =
        \\fn text() -> *const u8 { return "text"; }
    ;
    var parsed = try test_support.parseCheckedModule("c_missing_string_target_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.build(std.testing.allocator, parsed.module);
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "text");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_missing_string_target_type_facts.mc", .{}, false, null));
}

test "lower-c rejects missing aggregate-literal target type facts" {
    const source =
        \\struct Pair { left: u32, right: u32 }
        \\fn pair() -> Pair { return .{ .left = 1, .right = 2 }; }
    ;
    var parsed = try test_support.parseCheckedModule("c_missing_aggregate_target_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.build(std.testing.allocator, parsed.module);
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "pair");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_missing_aggregate_target_type_facts.mc", .{}, false, null));
}

test "lower-c rejects missing float-literal target type facts" {
    const source =
        \\fn value() -> f32 { return 1.25; }
    ;
    var parsed = try test_support.parseCheckedModule("c_missing_float_target_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.build(std.testing.allocator, parsed.module);
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "value");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_missing_float_target_type_facts.mc", .{}, false, null));
}

test "lower-c rejects missing null and value-optional target type facts" {
    const source =
        \\fn present(value: u32) -> ?u32 { return value; }
        \\fn absent() -> ?u32 { return null; }
    ;
    var parsed = try test_support.parseCheckedModule("c_missing_optional_target_type_facts.mc", source);
    defer parsed.deinit();
    for ([_][]const u8{ "present", "absent" }) |name| {
        var module_mir = try mir.build(std.testing.allocator, parsed.module);
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, name);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_missing_optional_target_type_facts.mc", .{}, false, null));
    }
}

test "lower-c rejects missing dyn-coercion target type facts" {
    const source =
        \\trait Shape { fn area(self: *Self) -> u32; }
        \\struct Square { side: u32 }
        \\impl Shape for Square { fn area(self: *Square) -> u32 { return self.side; } }
        \\fn as_dyn(value: *Square) -> *dyn Shape { return value; }
    ;
    var parsed = try test_support.parseCheckedModule("c_missing_dyn_target_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.build(std.testing.allocator, parsed.module);
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "as_dyn");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_missing_dyn_target_type_facts.mc", .{}, false, null));
}

fn retargetCallTargetFactsForFunction(module_mir: *mir.Module, name: []const u8, kind: mir.CallTargetKind) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        if (function.call_target_facts.len == 0) return error.TestUnexpectedResult;
        function.call_target_facts[0].kind = kind;
        return;
    }
    return error.TestUnexpectedResult;
}

test "lower-c conversion builtins require exact MIR call-target facts" {
    const source =
        \\fn convert(x: u64) -> u8 { return u8.trap_from(x); }
    ;
    var parsed = try test_support.parseCheckedModule("c_conversion_call_target_facts.mc", source);
    defer parsed.deinit();

    var missing_mir = try mir.build(std.testing.allocator, parsed.module);
    defer missing_mir.deinit();
    try clearCallTargetFactsForFunction(&missing_mir, "convert");
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirCallTargetFacts, lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &missing_mir, &missing_output, .kernel, "c_conversion_call_target_facts.mc", .{}, false, null));

    var stale_mir = try mir.build(std.testing.allocator, parsed.module);
    defer stale_mir.deinit();
    try retargetCallTargetFactsForFunction(&stale_mir, "convert", .conversion_sat_from);
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirCallTargetFacts, lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &stale_mir, &stale_output, .kernel, "c_conversion_call_target_facts.mc", .{}, false, null));

    var missing_types_mir = try mir.build(std.testing.allocator, parsed.module);
    defer missing_types_mir.deinit();
    try clearTargetTypeFactsForFunction(&missing_types_mir, "convert");
    var missing_types_output: std.ArrayList(u8) = .empty;
    defer missing_types_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &missing_types_mir, &missing_types_output, .kernel, "c_conversion_call_target_facts.mc", .{}, false, null));
}

test "lower-c explicit casts require MIR source and target type facts" {
    const source =
        \\fn widen(value: u32) -> u64 { return value as u64; }
    ;
    var parsed = try test_support.parseCheckedModule("c_explicit_cast_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.build(std.testing.allocator, parsed.module);
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "widen");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_explicit_cast_type_facts.mc", .{}, false, null));
}

test "lower-c implicit view const narrowing requires MIR source and target type facts" {
    const source =
        \\fn narrow(xs: []mut u8) -> []const u8 { return xs; }
    ;
    var parsed = try test_support.parseCheckedModule("c_view_const_narrow_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.build(std.testing.allocator, parsed.module);
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "narrow");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_view_const_narrow_type_facts.mc", .{}, false, null));
}

test "lower-c self-typed union and enum paths require MIR result type facts" {
    const source =
        \\enum E { first, second }
        \\union Token { number: i64, eof }
        \\fn make(value: i64) -> Token { return Token.number(value); }
        \\fn variant() -> E { return E.second; }
    ;
    var parsed = try test_support.parseCheckedModule("c_self_typed_expression_facts.mc", source);
    defer parsed.deinit();
    for ([_][]const u8{ "make", "variant" }) |name| {
        var module_mir = try mir.build(std.testing.allocator, parsed.module);
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, name);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_self_typed_expression_facts.mc", .{}, false, null));
    }
}

fn retargetIntegerFactsForFunction(module_mir: *mir.Module, name: []const u8, target_ty: mir.ValueType) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        if (function.integer_facts.len == 0) return error.TestUnexpectedResult;
        function.integer_facts[0].target_ty = target_ty;
        return;
    }
    return error.TestUnexpectedResult;
}

fn retargetRepresentationFactsForFunction(module_mir: *mir.Module, name: []const u8, value_id: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        if (function.representation_facts.len == 0) return error.TestUnexpectedResult;
        function.representation_facts[0].value_id = value_id;
        return;
    }
    return error.TestUnexpectedResult;
}

fn appendStaleRepresentationFactForFunction(module_mir: *mir.Module, name: []const u8, value_id: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        if (function.representation_facts.len == 0) return error.TestUnexpectedResult;

        var facts: std.ArrayList(mir.RepresentationFact) = .empty;
        errdefer facts.deinit(module_mir.allocator);
        try facts.appendSlice(module_mir.allocator, function.representation_facts);
        var stale = function.representation_facts[0];
        stale.value_id = value_id;
        try facts.append(module_mir.allocator, stale);

        module_mir.allocator.free(function.representation_facts);
        function.representation_facts = try facts.toOwnedSlice(module_mir.allocator);
        return;
    }
    return error.TestUnexpectedResult;
}

fn retargetRangeFactsForFunction(module_mir: *mir.Module, name: []const u8, target: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        for (function.range_facts) |*fact| {
            fact.target = target;
        }
        return;
    }
    return error.TestUnexpectedResult;
}

fn clearPointerProvenanceFactsForFunctionSubject(module_mir: *mir.Module, name: []const u8, subject: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        var retained: std.ArrayList(mir.PointerProvenanceFact) = .empty;
        errdefer retained.deinit(module_mir.allocator);
        for (function.pointer_provenance_facts) |fact| {
            if (std.mem.eql(u8, fact.subject, subject)) {
                if (fact.field_path) |field_path| module_mir.allocator.free(field_path);
                continue;
            }
            try retained.append(module_mir.allocator, fact);
        }
        module_mir.allocator.free(function.pointer_provenance_facts);
        function.pointer_provenance_facts = try retained.toOwnedSlice(module_mir.allocator);
        return;
    }
    return error.TestUnexpectedResult;
}

fn clearPointerProvenanceFactsForFunctionSubjectField(module_mir: *mir.Module, name: []const u8, subject: []const u8, field_path: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        var retained: std.ArrayList(mir.PointerProvenanceFact) = .empty;
        errdefer retained.deinit(module_mir.allocator);
        for (function.pointer_provenance_facts) |fact| {
            if (std.mem.eql(u8, fact.subject, subject)) {
                if (fact.field_path) |actual_field| {
                    if (std.mem.eql(u8, actual_field, field_path)) {
                        module_mir.allocator.free(actual_field);
                        continue;
                    }
                }
            }
            try retained.append(module_mir.allocator, fact);
        }
        module_mir.allocator.free(function.pointer_provenance_facts);
        function.pointer_provenance_facts = try retained.toOwnedSlice(module_mir.allocator);
        return;
    }
    return error.TestUnexpectedResult;
}

fn clearAggregateReturnPointerFact(module_mir: *mir.Module, callee: []const u8, field_path: []const u8) !void {
    var retained: std.ArrayList(mir.AggregateReturnPointerFact) = .empty;
    errdefer retained.deinit(module_mir.allocator);
    var removed = false;
    for (module_mir.aggregate_return_pointer_facts) |fact| {
        if (std.mem.eql(u8, fact.callee, callee) and std.mem.eql(u8, fact.field_path, field_path)) {
            module_mir.allocator.free(fact.field_path);
            removed = true;
            continue;
        }
        try retained.append(module_mir.allocator, fact);
    }
    if (!removed) return error.TestUnexpectedResult;
    module_mir.allocator.free(module_mir.aggregate_return_pointer_facts);
    module_mir.aggregate_return_pointer_facts = try retained.toOwnedSlice(module_mir.allocator);
}

fn appendCheckedCTestWithoutRangeFacts(source_name: []const u8, source: []const u8, function_names: []const []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseCheckedModule(source_name, source);
    defer parsed.deinit();

    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    for (function_names) |function_name| {
        try clearRangeFactsForFunction(&module_mir, function_name);
    }

    try lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, output, .kernel, source_name, .{}, false, null);
}

test "lower-c rejects prebuilt MIR with missing bounds facts" {
    const source =
        \\fn bounds_fact_gate(a: [2]u32, i: usize) -> u32 {
        \\    return a[i];
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_missing_bounds_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.build(std.testing.allocator, parsed.module);
    defer module_mir.deinit();
    try clearBoundsFactsForFunction(&module_mir, "bounds_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_missing_bounds_facts.mc", .{}, false, null));
}

test "lower-c rejects prebuilt MIR with missing representation facts" {
    const source =
        \\fn representation_fact_gate(p: *mut u32) -> u32 {
        \\    unsafe { return p.*; }
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_representation_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try clearRepresentationFactsForFunction(&module_mir, "representation_fact_gate");

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirRepresentationFacts,
        lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_missing_representation_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with stale representation facts" {
    const source =
        \\fn representation_fact_gate(p: *mut u32) -> u32 {
        \\    unsafe { return p.*; }
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_stale_representation_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try retargetRepresentationFactsForFunction(&module_mir, "representation_fact_gate", "stale_value");

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirRepresentationFacts,
        lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_stale_representation_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with extra stale representation facts" {
    const source =
        \\fn representation_fact_gate(p: *mut u32) -> u32 {
        \\    unsafe { return p.*; }
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_extra_stale_representation_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try appendStaleRepresentationFactForFunction(&module_mir, "representation_fact_gate", "extra_stale_value");

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirRepresentationFacts,
        lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_extra_stale_representation_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with missing integer facts" {
    const source =
        \\fn integer_fact_gate() -> u8 {
        \\    let a: u8 = 7;
        \\    return a;
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_integer_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try clearIntegerFactsForFunction(&module_mir, "integer_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirIntegerFacts,
        lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_missing_integer_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with missing call target facts" {
    const source =
        \\fn call_target_fact_gate(xs: []const u32) -> Result<u32, Overflow> {
        \\    return reduce.sum_checked<u32>(xs);
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_missing_call_target_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with missing reflection call target facts" {
    const source =
        \\fn reflection_call_target_fact_gate() -> usize {
        \\    return size_of<u32>();
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_reflection_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "reflection_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_missing_reflection_call_target_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with missing byte-view call target facts" {
    const source =
        \\fn byte_view_call_target_fact_gate(left: []const u8, right: []const u8) -> bool {
        \\    return mem.bytes_equal(left, right);
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_byte_view_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "byte_view_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_missing_byte_view_call_target_facts.mc", .{}, false, null),
    );
}

test "lower-c reflection and byte-view result types require MIR target facts" {
    const source =
        \\fn reflected() -> usize { return size_of<u32>(); }
        \\fn equal(left: []const u8, right: []const u8) -> bool { return mem.bytes_equal(left, right); }
    ;
    var parsed = try test_support.parseCheckedModule("c_reflection_byte_view_result_facts.mc", source);
    defer parsed.deinit();
    for ([_][]const u8{ "reflected", "equal" }) |name| {
        var module_mir = try mir.build(std.testing.allocator, parsed.module);
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, name);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_reflection_byte_view_result_facts.mc", .{}, false, null));
    }
}

test "lower-c rejects prebuilt MIR with missing semantic escape call target facts" {
    const source =
        \\fn reveal_fact_gate(secret: Secret<u8>) -> u8 {
        \\    unsafe { return reveal(secret); }
        \\}
        \\fn noalias_fact_gate(p: *mut u8, n: usize) -> *mut u8 {
        \\    #[unsafe_contract(noalias)] {
        \\        return compiler.assume_noalias_unchecked(p, n);
        \\    }
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_semantic_escape_call_target_facts.mc", source);
    defer parsed.deinit();

    var reveal_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer reveal_mir.deinit();
    try clearCallTargetFactsForFunction(&reveal_mir, "reveal_fact_gate");
    var reveal_output: std.ArrayList(u8) = .empty;
    defer reveal_output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &reveal_mir, &reveal_output, .kernel, "c_missing_semantic_escape_call_target_facts.mc", .{}, false, null),
    );

    var noalias_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer noalias_mir.deinit();
    try clearCallTargetFactsForFunction(&noalias_mir, "noalias_fact_gate");
    var noalias_output: std.ArrayList(u8) = .empty;
    defer noalias_output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &noalias_mir, &noalias_output, .kernel, "c_missing_semantic_escape_call_target_facts.mc", .{}, false, null),
    );
}

test "lower-c semantic escape types require MIR target facts" {
    const source =
        \\fn reveal_type_gate(secret: Secret<u8>) -> u8 {
        \\    unsafe { return reveal(secret); }
        \\}
        \\fn noalias_type_gate(p: *mut u8, n: usize) -> *mut u8 {
        \\    #[unsafe_contract(noalias)] {
        \\        return compiler.assume_noalias_unchecked(p, n);
        \\    }
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_semantic_escape_target_type_facts.mc", source);
    defer parsed.deinit();
    for ([_][]const u8{ "reveal_type_gate", "noalias_type_gate" }) |name| {
        var module_mir = try mir.build(std.testing.allocator, parsed.module);
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, name);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_semantic_escape_target_type_facts.mc", .{}, false, null));
    }
}

test "lower-c rejects prebuilt MIR with missing atomic call target facts" {
    const source =
        \\fn atomic_call_target_fact_gate() -> u32 {
        \\    var counter: atomic<u32> = atomic.init(0);
        \\    return counter.fetch_add(1, .acq_rel);
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_atomic_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "atomic_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_missing_atomic_call_target_facts.mc", .{}, false, null),
    );
}

test "lower-c atomic and MaybeUninit payloads require MIR target facts" {
    const source =
        \\struct Node { value: u32 }
        \\
        \\fn atomic_payload_fact_gate() -> u32 {
        \\    var counter: atomic<u32> = atomic.init(0);
        \\    counter.store(1, .release);
        \\    return counter.fetch_add(1, .acq_rel);
        \\}
        \\fn maybe_uninit_payload_fact_gate() -> u32 {
        \\    var slot: MaybeUninit<Node> = uninit;
        \\    slot.write(.{ .value = 7 });
        \\    return slot.assume_init().value;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_atomic_maybe_uninit_payload_facts.mc", source);
    defer parsed.deinit();
    for ([_][]const u8{ "atomic_payload_fact_gate", "maybe_uninit_payload_fact_gate" }) |name| {
        var module_mir = try mir.build(std.testing.allocator, parsed.module);
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, name);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_atomic_maybe_uninit_payload_facts.mc", .{}, false, null));
    }
}

test "lower-c rejects prebuilt MIR with missing bitcast call target facts" {
    const source =
        \\fn bitcast_call_target_fact_gate(value: f32) -> u32 {
        \\    return bitcast<u32>(value);
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_bitcast_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "bitcast_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_missing_bitcast_call_target_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with missing bitcast target type facts" {
    const source =
        \\fn bitcast_target_type_fact_gate(value: f32) -> u32 {
        \\    return bitcast<u32>(value);
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_bitcast_target_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "bitcast_target_type_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirTargetTypeFacts,
        lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_missing_bitcast_target_type_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with missing const_get call target facts" {
    const source =
        \\fn const_get_call_target_fact_gate(xs: [3]u32) -> u32 {
        \\    return xs.const_get<1>();
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_const_get_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "const_get_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_missing_const_get_call_target_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with missing phys call target facts" {
    const source =
        \\fn phys_call_target_fact_gate(value: usize) -> PAddr {
        \\    return phys(value);
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_phys_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "phys_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_missing_phys_call_target_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with missing phys result type facts" {
    const source =
        \\fn phys_result_type_fact_gate(value: usize) -> PAddr {
        \\    return phys(value);
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_phys_result_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "phys_result_type_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirTargetTypeFacts,
        lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_missing_phys_result_type_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with missing MaybeUninit call target facts" {
    const source =
        \\struct Node { value: u32 }
        \\
        \\fn maybe_uninit_call_target_fact_gate() -> u32 {
        \\    var slot: MaybeUninit<Node> = uninit;
        \\    slot.write(.{ .value = 7 });
        \\    let value: Node = slot.assume_init();
        \\    return value.value;
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_maybe_uninit_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "maybe_uninit_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_missing_maybe_uninit_call_target_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with missing raw store call target facts" {
    const source =
        \\fn raw_store_call_target_fact_gate(addr: PAddr, value: u32) -> void {
        \\    unsafe { raw.store<u32>(addr, value); }
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_raw_store_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "raw_store_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_missing_raw_store_call_target_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with missing raw load call target facts" {
    const source =
        \\fn raw_load_call_target_fact_gate(addr: PAddr) -> u32 {
        \\    unsafe { return raw.load<u32>(addr); }
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_raw_load_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "raw_load_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_missing_raw_load_call_target_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with missing raw ptr call target facts" {
    const source =
        \\fn raw_ptr_call_target_fact_gate(addr: PAddr) -> *mut u32 {
        \\    unsafe { return raw.ptr<u32>(addr); }
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_raw_ptr_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "raw_ptr_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_missing_raw_ptr_call_target_facts.mc", .{}, false, null),
    );
}

test "lower-c raw address result types require MIR target type facts" {
    const source =
        \\fn read(addr: PAddr) -> u32 { unsafe { return raw.load<u32>(addr); } }
        \\fn pointer(addr: PAddr) -> *mut u32 { unsafe { return raw.ptr<u32>(addr); } }
    ;
    var parsed = try test_support.parseCheckedModule("c_raw_address_result_type_facts.mc", source);
    defer parsed.deinit();
    for ([_][]const u8{ "read", "pointer" }) |name| {
        var module_mir = try mir.build(std.testing.allocator, parsed.module);
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, name);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_raw_address_result_type_facts.mc", .{}, false, null));
    }
}

test "lower-c varargs calls require MIR call and result type facts" {
    const source =
        \\export fn first_arg(count: i32, ...) -> i64 {
        \\    var ap: va_list = va.start();
        \\    var value: i64 = 0;
        \\    unsafe { value = va.arg<i64>(&ap); }
        \\    va.end(&ap);
        \\    return value + (count as i64);
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_varargs_call_type_facts.mc", source);
    defer parsed.deinit();
    var missing_calls = try mir.build(std.testing.allocator, parsed.module);
    defer missing_calls.deinit();
    try clearCallTargetFactsForFunction(&missing_calls, "first_arg");
    var call_output: std.ArrayList(u8) = .empty;
    defer call_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirCallTargetFacts, lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &missing_calls, &call_output, .kernel, "c_varargs_call_type_facts.mc", .{}, false, null));

    var missing_types = try mir.build(std.testing.allocator, parsed.module);
    defer missing_types.deinit();
    try clearTargetTypeFactsForFunction(&missing_types, "first_arg");
    var type_output: std.ArrayList(u8) = .empty;
    defer type_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &missing_types, &type_output, .kernel, "c_varargs_call_type_facts.mc", .{}, false, null));
}

test "lower-c rejects prebuilt MIR with missing cpu pause call target facts" {
    const source =
        \\fn cpu_pause_call_target_fact_gate() -> void {
        \\    unsafe { cpu.pause(); }
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_cpu_pause_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "cpu_pause_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_missing_cpu_pause_call_target_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with missing fence call target facts" {
    const source =
        \\fn fence_call_target_fact_gate() -> void {
        \\    fence.full();
        \\    fence.release();
        \\    fence.acquire();
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_fence_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "fence_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_missing_fence_call_target_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with stale call target facts" {
    const source =
        \\fn call_target_fact_gate(xs: []const u32) -> Result<u32, Overflow> {
        \\    return reduce.sum_checked<u32>(xs);
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_stale_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try retargetCallTargetFactsForFunction(&module_mir, "call_target_fact_gate", .const_get);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirCallTargetFacts, lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_stale_call_target_facts.mc", .{}, false, null));
}

test "lower-c rejects prebuilt MIR with stale integer facts" {
    const source =
        \\fn integer_fact_gate() -> u8 {
        \\    let a: u8 = 7;
        \\    return a;
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_stale_integer_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try retargetIntegerFactsForFunction(&module_mir, "integer_fact_gate", .{ .integer = "u16" });
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirIntegerFacts,
        lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, "c_stale_integer_facts.mc", .{}, false, null),
    );
}

fn appendCheckedCTestWithRetargetedRangeFacts(source_name: []const u8, source: []const u8, function_name: []const u8, target: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseCheckedModule(source_name, source);
    defer parsed.deinit();

    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try retargetRangeFactsForFunction(&module_mir, function_name, target);

    try lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, output, .kernel, source_name, .{}, false, null);
}

fn appendCheckedCTestWithoutPointerProvenanceFactsForSubject(source_name: []const u8, source: []const u8, function_name: []const u8, subject: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseCheckedModule(source_name, source);
    defer parsed.deinit();

    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try clearPointerProvenanceFactsForFunctionSubject(&module_mir, function_name, subject);

    try lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, output, .kernel, source_name, .{}, false, null);
}

fn appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField(source_name: []const u8, source: []const u8, function_name: []const u8, subject: []const u8, field_path: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseCheckedModule(source_name, source);
    defer parsed.deinit();

    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try clearPointerProvenanceFactsForFunctionSubjectField(&module_mir, function_name, subject, field_path);

    try lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, output, .kernel, source_name, .{}, false, null);
}

fn appendCheckedCTestWithoutAggregateReturnPointerFact(source_name: []const u8, source: []const u8, callee: []const u8, field_path: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseCheckedModule(source_name, source);
    defer parsed.deinit();

    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try clearAggregateReturnPointerFact(&module_mir, callee, field_path);
    try lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, output, .kernel, source_name, .{}, false, null);
}

fn expectUnsupportedCheckedCEmission(source_name: []const u8, source: []const u8) !void {
    var parsed = try test_support.parseCheckedModule(source_name, source);
    defer parsed.deinit();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, lower_c.appendC(std.testing.allocator, parsed.module, &output));
}

fn expectUnsupportedCheckedCEmissionDiagnostic(source_name: []const u8, source: []const u8, expected_construct: []const u8) !void {
    var parsed = try test_support.parseCheckedModule(source_name, source);
    defer parsed.deinit();

    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    var reporter = diagnostics.Reporter.init(std.testing.allocator, source_name, source);
    defer reporter.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.UnsupportedCEmission,
        lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &output, .kernel, source_name, .{}, false, &reporter),
    );
    try std.testing.expect(reporter.has_errors);
    try std.testing.expectEqual(@as(usize, 1), reporter.diagnostics.items.len);
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, "E_BACKEND_UNSUPPORTED") != null);
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, expected_construct) != null);
}

test "lower-c consumes MIR aggregate-return pointer facts and fails closed when absent" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder() -> Holder {
        \\    return .{ .ptr = &shared_counter, .tag = 1 };
        \\}
        \\
        \\fn use_returned_holder() -> u32 {
        \\    let holder: Holder = returned_holder();
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c aggregate-return bounded call prefixes are MIR-owned" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\fn helper() -> void {}
        \\fn helper_holder(holder: *mut Holder) -> void {
        \\    holder.*.tag = 0;
        \\}
        \\
        \\fn call_free_prefix_holder() -> Holder {
        \\    let noise: u32 = shared_counter;
        \\    return .{ .ptr = &shared_counter, .tag = noise };
        \\}
        \\
        \\fn call_prefix_holder() -> Holder {
        \\    helper();
        \\    return .{ .ptr = &shared_counter, .tag = 1 };
        \\}
        \\
        \\fn local_call_prefix_holder() -> Holder {
        \\    let holder: Holder = .{ .ptr = &shared_counter, .tag = 2 };
        \\    helper();
        \\    return holder;
        \\}
        \\
        \\fn local_arg_call_prefix_holder() -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 3 };
        \\    helper_holder(&holder);
        \\    return holder;
        \\}
        \\
        \\fn use_call_free_prefix_holder() -> u32 {
        \\    let holder: Holder = call_free_prefix_holder();
        \\    return holder.ptr.*;
        \\}
        \\
        \\fn use_call_prefix_holder() -> u32 {
        \\    let holder: Holder = call_prefix_holder();
        \\    return holder.ptr.*;
        \\}
        \\
        \\fn use_local_call_prefix_holder() -> u32 {
        \\    let holder: Holder = local_call_prefix_holder();
        \\    return holder.ptr.*;
        \\}
        \\
        \\fn use_local_arg_call_prefix_holder() -> u32 {
        \\    let holder: Holder = local_arg_call_prefix_holder();
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_aggregate_return_literal_prefix_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_call_free_prefix_holder callee=call_free_prefix_holder field=ptr provenance=global_storage");
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_call_prefix_holder callee=call_prefix_holder field=ptr provenance=global_storage");
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_local_call_prefix_holder callee=local_call_prefix_holder field=ptr provenance=global_storage");
    try expectNotContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_local_arg_call_prefix_holder callee=local_arg_call_prefix_holder field=ptr");
    const local_arg_call_body = try cFunctionBody(output.items, "static uint32_t use_local_arg_call_prefix_holder(void)");
    try expectContains(local_arg_call_body, "mc_race_load_u32");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_aggregate_return_literal_prefix_mir_fact.mc", source, "call_prefix_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_call_prefix_holder callee=call_prefix_holder field=ptr");
    const missing_call_body = try cFunctionBody(missing_output.items, "static uint32_t use_call_prefix_holder(void)");
    try expectContains(missing_call_body, "mc_race_load_u32");

    var missing_local_output: std.ArrayList(u8) = .empty;
    defer missing_local_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_aggregate_return_literal_prefix_mir_fact.mc", source, "local_call_prefix_holder", "ptr", &missing_local_output);
    try expectNotContains(missing_local_output.items, "/* mir aggregate_return_pointer consumed caller=use_local_call_prefix_holder callee=local_call_prefix_holder field=ptr");
    const missing_local_call_body = try cFunctionBody(missing_local_output.items, "static uint32_t use_local_call_prefix_holder(void)");
    try expectContains(missing_local_call_body, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return pointer-array element facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptrs: [2]*mut u32 }
        \\
        \\fn returned_holder() -> Holder {
        \\    return .{ .ptrs = .{ &shared_counter, &shared_counter } };
        \\}
        \\
        \\fn use_returned_holder() -> u32 {
        \\    let holder: Holder = returned_holder();
        \\    return holder.ptrs[0].*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_aggregate_return_array_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptrs[0] provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_aggregate_return_array_mir_fact.mc", source, "returned_holder", "ptrs[0]", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptrs[0]");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR nested aggregate-return pointer facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Inner { ptr: *mut u32, ptrs: [2]*mut u32 }
        \\struct Outer { inner: Inner }
        \\
        \\fn returned_outer() -> Outer {
        \\    return .{ .inner = .{ .ptr = &shared_counter, .ptrs = .{ &shared_counter, &shared_counter } } };
        \\}
        \\
        \\fn use_returned_outer() -> u32 {
        \\    let outer: Outer = returned_outer();
        \\    return outer.inner.ptrs[0].*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_nested_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_outer callee=returned_outer field=inner.ptrs[0] provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_nested_aggregate_return_mir_fact.mc", source, "returned_outer", "inner.ptrs[0]", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_outer callee=returned_outer field=inner.ptrs[0]");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR nested array aggregate-return pointer facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Cell { ptr: *mut u32 }
        \\struct Holder { cells: [2]Cell }
        \\
        \\fn returned_holder() -> Holder {
        \\    return .{ .cells = .{ .{ .ptr = &shared_counter }, .{ .ptr = &shared_counter } } };
        \\}
        \\
        \\fn use_returned_holder() -> u32 {
        \\    let holder: Holder = returned_holder();
        \\    return holder.cells[0].ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_nested_array_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=cells[0].ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_nested_array_aggregate_return_mir_fact.mc", source, "returned_holder", "cells[0].ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=cells[0].ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR trailing aggregate-return facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder(choice: u32) -> Holder {
        \\    switch choice {
        \\        0 => { return .{ .ptr = &shared_counter, .tag = 1 }; }
        \\        _ => {}
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 2 };
        \\}
        \\
        \\fn use_returned_holder(choice: u32) -> u32 {
        \\    let holder: Holder = returned_holder(choice);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_trailing_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_trailing_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c aggregate-return mixed branches fail closed" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder(flag: bool, fallback: *mut u32) -> Holder {
        \\    if flag { return .{ .ptr = &shared_counter, .tag = 1 }; } else { return .{ .ptr = fallback, .tag = 2 }; }
        \\}
        \\
        \\fn use_returned_holder(flag: bool) -> u32 {
        \\    var local: u32 = 3;
        \\    let holder: Holder = returned_holder(flag, &local);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_mixed_branch_aggregate_return_fail_closed.mc", source, &output);
    try expectNotContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    const body = try cFunctionBody(output.items, "static uint32_t use_returned_holder(bool flag)");
    try expectContains(body, "mc_race_load_u32");
}

test "lower-c consumes MIR trailing aggregate-return assignment facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder(choice: u32) -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 1 };
        \\    switch choice {
        \\        0 => { return .{ .ptr = &shared_counter, .tag = 2 }; }
        \\        _ => { holder = .{ .ptr = &shared_counter, .tag = 3 }; }
        \\    }
        \\    return holder;
        \\}
        \\
        \\fn use_returned_holder(choice: u32) -> u32 {
        \\    let holder: Holder = returned_holder(choice);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_trailing_aggregate_return_assignment_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_trailing_aggregate_return_assignment_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR trailing aggregate-return field assignment facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder(choice: u32) -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 1 };
        \\    switch choice {
        \\        0 => { return .{ .ptr = &shared_counter, .tag = 2 }; }
        \\        _ => { holder.ptr = &shared_counter; }
        \\    }
        \\    return holder;
        \\}
        \\
        \\fn use_returned_holder(choice: u32) -> u32 {
        \\    let holder: Holder = returned_holder(choice);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_trailing_aggregate_return_field_assignment_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_trailing_aggregate_return_field_assignment_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR trailing aggregate-return array element assignment facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptrs: [2]*mut u32 }
        \\
        \\fn returned_holder(choice: u32) -> Holder {
        \\    var holder: Holder = .{ .ptrs = .{ &shared_counter, &shared_counter } };
        \\    switch choice {
        \\        0 => { return .{ .ptrs = .{ &shared_counter, &shared_counter } }; }
        \\        _ => { holder.ptrs[0] = &shared_counter; }
        \\    }
        \\    return holder;
        \\}
        \\
        \\fn use_returned_holder(choice: u32) -> u32 {
        \\    let holder: Holder = returned_holder(choice);
        \\    return holder.ptrs[0].*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_trailing_aggregate_return_array_element_assignment_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptrs[0] provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_trailing_aggregate_return_array_element_assignment_mir_fact.mc", source, "returned_holder", "ptrs[0]", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptrs[0]");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return same-address dynamic-index facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptrs: [2]*mut u32 }
        \\
        \\fn returned_holder(choice: u32, index: usize) -> Holder {
        \\    var holder: Holder = .{ .ptrs = .{ &shared_counter, &shared_counter } };
        \\    switch choice {
        \\        0 => { return .{ .ptrs = .{ &shared_counter, &shared_counter } }; }
        \\        _ => { holder.ptrs[index] = &shared_counter; }
        \\    }
        \\    return holder;
        \\}
        \\
        \\fn use_returned_holder(choice: u32, index: usize) -> u32 {
        \\    let holder: Holder = returned_holder(choice, index);
        \\    return holder.ptrs[0].*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_trailing_aggregate_return_dynamic_index_assignment_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptrs[0] provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_trailing_aggregate_return_dynamic_index_assignment_mir_fact.mc", source, "returned_holder", "ptrs[0]", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptrs[0]");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return nested control facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder(choice: u32, flag: bool) -> Holder {
        \\    switch choice {
        \\        0 => {
        \\            if flag { return .{ .ptr = &shared_counter, .tag = 1 }; }
        \\            return .{ .ptr = &shared_counter, .tag = 2 };
        \\        }
        \\        _ => {}
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 3 };
        \\}
        \\fn returned_holder_if_let(choice: u32, maybe: ?u32) -> Holder {
        \\    switch choice {
        \\        0 => {
        \\            if let value = maybe {
        \\                return .{ .ptr = &shared_counter, .tag = value };
        \\            }
        \\            return .{ .ptr = &shared_counter, .tag = 4 };
        \\        }
        \\        _ => {}
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 5 };
        \\}
        \\
        \\fn use_returned_holder(choice: u32, flag: bool) -> u32 {
        \\    let holder: Holder = returned_holder(choice, flag);
        \\    return holder.ptr.*;
        \\}
        \\fn use_returned_holder_if_let(choice: u32, maybe: ?u32) -> u32 {
        \\    let holder: Holder = returned_holder_if_let(choice, maybe);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_nested_control_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder_if_let callee=returned_holder_if_let field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_nested_control_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder_if_let callee=returned_holder_if_let field=ptr provenance=global_storage");
    try expectContains(missing_output.items, "mc_race_load_u32");

    var missing_if_let_output: std.ArrayList(u8) = .empty;
    defer missing_if_let_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_nested_control_aggregate_return_mir_fact.mc", source, "returned_holder_if_let", "ptr", &missing_if_let_output);
    try expectNotContains(missing_if_let_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder_if_let callee=returned_holder_if_let field=ptr");
    try expectContains(missing_if_let_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return loop-control prefix facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder(flag: bool) -> Holder {
        \\    while flag {
        \\        break;
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 1 };
        \\}
        \\
        \\fn use_returned_holder(flag: bool) -> u32 {
        \\    let holder: Holder = returned_holder(flag);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_loop_control_prefix_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_loop_control_prefix_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return continue loop-control prefix facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder(values: [2]u32) -> Holder {
        \\    for value in values {
        \\        let ignored: u32 = value;
        \\        continue;
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 1 };
        \\}
        \\
        \\fn use_returned_holder(values: [2]u32) -> u32 {
        \\    let holder: Holder = returned_holder(values);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_continue_loop_control_prefix_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_continue_loop_control_prefix_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return transparent while-prefix facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder(flag: bool) -> Holder {
        \\    while flag {
        \\        let ignored: u32 = 0;
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 1 };
        \\}
        \\
        \\fn use_returned_holder(flag: bool) -> u32 {
        \\    let holder: Holder = returned_holder(flag);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_transparent_while_prefix_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_transparent_while_prefix_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return scalar-field-mutating while facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder(flag: bool) -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 1 };
        \\    while flag {
        \\        holder.tag = 2;
        \\    }
        \\    return holder;
        \\}
        \\
        \\fn use_returned_holder(flag: bool) -> u32 {
        \\    let holder: Holder = returned_holder(flag);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_scalar_field_mutating_while_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_scalar_field_mutating_while_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return stable pointer-field-mutating while facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder(flag: bool) -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 1 };
        \\    while flag {
        \\        holder.ptr = &shared_counter;
        \\    }
        \\    return holder;
        \\}
        \\
        \\fn use_returned_holder(flag: bool) -> u32 {
        \\    let holder: Holder = returned_holder(flag);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_stable_pointer_field_mutating_while_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_stable_pointer_field_mutating_while_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c aggregate-return mixed pointer-mutating while prefix fails closed" {
    const source =
        \\global shared_counter: u32 = 0;
        \\global other_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder(flag: bool) -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 1 };
        \\    while flag {
        \\        holder.ptr = &other_counter;
        \\    }
        \\    return holder;
        \\}
        \\
        \\fn use_returned_holder(flag: bool) -> u32 {
        \\    let holder: Holder = returned_holder(flag);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_mixed_pointer_mutating_while_prefix_aggregate_return_fail_closed.mc", source, &output);
    try expectNotContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder");
    try expectContains(output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return scalar-mutating loop local facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder(flag: bool) -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 1 };
        \\    var tag: u32 = 0;
        \\    while flag {
        \\        tag = 2;
        \\        break;
        \\    }
        \\    return holder;
        \\}
        \\
        \\fn use_returned_holder(flag: bool) -> u32 {
        \\    let holder: Holder = returned_holder(flag);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_scalar_mutating_loop_local_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_scalar_mutating_loop_local_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return nested loop-control facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder(choice: u32, flag: bool) -> Holder {
        \\    switch choice {
        \\        0 => {
        \\            while flag {
        \\                break;
        \\            }
        \\            return .{ .ptr = &shared_counter, .tag = 1 };
        \\        }
        \\        _ => {}
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 2 };
        \\}
        \\
        \\fn use_returned_holder(choice: u32, flag: bool) -> u32 {
        \\    let holder: Holder = returned_holder(choice, flag);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_nested_loop_control_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_nested_loop_control_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return nested transparent switch facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder(choice: u32, flag: bool) -> Holder {
        \\    switch choice {
        \\        0 => {
        \\            switch flag {
        \\                true => { let ignored: u32 = 0; }
        \\                false => {}
        \\            }
        \\            return .{ .ptr = &shared_counter, .tag = 1 };
        \\        }
        \\        _ => {}
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 2 };
        \\}
        \\
        \\fn use_returned_holder(choice: u32, flag: bool) -> u32 {
        \\    let holder: Holder = returned_holder(choice, flag);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_nested_transparent_switch_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_nested_transparent_switch_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return nested transparent if-let facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder(choice: u32, maybe: ?u32) -> Holder {
        \\    switch choice {
        \\        0 => {
        \\            if let value = maybe {
        \\                let ignored: u32 = value;
        \\            }
        \\            return .{ .ptr = &shared_counter, .tag = 1 };
        \\        }
        \\        _ => {}
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 2 };
        \\}
        \\
        \\fn use_returned_holder(choice: u32, maybe: ?u32) -> u32 {
        \\    let holder: Holder = returned_holder(choice, maybe);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_nested_transparent_if_let_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_nested_transparent_if_let_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c aggregate-return nested call control fails closed" {
    const source =
        \\global shared_counter: u32 = 0;
        \\extern fn invalidate() -> void;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder(choice: u32) -> Holder {
        \\    switch choice {
        \\        0 => {
        \\            invalidate();
        \\            return .{ .ptr = &shared_counter, .tag = 1 };
        \\        }
        \\        _ => {}
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 2 };
        \\}
        \\
        \\fn use_returned_holder(choice: u32) -> u32 {
        \\    let holder: Holder = returned_holder(choice);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_nested_call_control_aggregate_return_fail_closed.mc", source, &output);
    try expectNotContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder");
    try expectContains(output.items, "mc_race_load_u32");
}

test "lower-c aggregate-return nested mutating join fails closed" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder(choice: u32, inner: u32, ptr: *mut u32) -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 1 };
        \\    switch choice {
        \\        0 => {
        \\            switch inner {
        \\                0 => { holder.ptr = ptr; }
        \\                _ => {}
        \\            }
        \\        }
        \\        _ => {}
        \\    }
        \\    return holder;
        \\}
        \\
        \\fn use_returned_holder(choice: u32, inner: u32, ptr: *mut u32) -> u32 {
        \\    let holder: Holder = returned_holder(choice, inner, ptr);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_nested_mutating_join_aggregate_return_fail_closed.mc", source, &output);
    try expectNotContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return if-let facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder(maybe: ?u32) -> Holder {
        \\    if let value = maybe {
        \\        return .{ .ptr = &shared_counter, .tag = value };
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 2 };
        \\}
        \\fn returned_holder_else(maybe: ?u32) -> Holder {
        \\    if let value = maybe {
        \\        return .{ .ptr = &shared_counter, .tag = value };
        \\    } else {
        \\        return .{ .ptr = &shared_counter, .tag = 3 };
        \\    }
        \\}
        \\
        \\fn use_returned_holder(maybe: ?u32) -> u32 {
        \\    let holder: Holder = returned_holder(maybe);
        \\    return holder.ptr.*;
        \\}
        \\fn use_returned_holder_else(maybe: ?u32) -> u32 {
        \\    let holder: Holder = returned_holder_else(maybe);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_if_let_control_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder_else callee=returned_holder_else field=ptr provenance=global_storage");
    try expectContains(output.items, "mc_race_load_u32");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_if_let_control_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder_else callee=returned_holder_else field=ptr provenance=global_storage");
    try expectContains(missing_output.items, "mc_race_load_u32");

    var missing_else_output: std.ArrayList(u8) = .empty;
    defer missing_else_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_if_let_control_aggregate_return_mir_fact.mc", source, "returned_holder_else", "ptr", &missing_else_output);
    try expectNotContains(missing_else_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder_else callee=returned_holder_else field=ptr");
    try expectContains(missing_else_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return scoped-block prefix facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder() -> Holder {
        \\    {
        \\        let ignored: u32 = shared_counter;
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 1 };
        \\}
        \\
        \\fn use_returned_holder() -> u32 {
        \\    let holder: Holder = returned_holder();
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_scoped_block_prefix_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");
    try expectContains(output.items, "mc_race_load_u32");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_scoped_block_prefix_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return unsafe-block prefix facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder() -> Holder {
        \\    unsafe {
        \\        let ignored: u32 = shared_counter;
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 1 };
        \\}
        \\
        \\fn use_returned_holder() -> u32 {
        \\    let holder: Holder = returned_holder();
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_unsafe_block_prefix_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");
    try expectContains(output.items, "mc_race_load_u32");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_unsafe_block_prefix_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return comptime-block prefix facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder() -> Holder {
        \\    comptime {
        \\        assert(1 + 1 == 2);
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 1 };
        \\}
        \\
        \\fn use_returned_holder() -> u32 {
        \\    let holder: Holder = returned_holder();
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_comptime_block_prefix_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");
    try expectContains(output.items, "mc_race_load_u32");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_comptime_block_prefix_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return assert prefix facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder(flag: bool) -> Holder {
        \\    assert(flag || !flag);
        \\    return .{ .ptr = &shared_counter, .tag = 1 };
        \\}
        \\
        \\fn use_returned_holder(flag: bool) -> u32 {
        \\    let holder: Holder = returned_holder(flag);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_assert_prefix_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");
    try expectContains(output.items, "mc_race_load_u32");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_assert_prefix_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return no-overflow contract prefix facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder() -> Holder {
        \\    var tag: u32 = 1;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        tag = unchecked.add(tag, 0);
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = tag };
        \\}
        \\
        \\fn use_returned_holder() -> u32 {
        \\    let holder: Holder = returned_holder();
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_contract_block_prefix_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");
    try expectContains(output.items, "mc_race_load_u32");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_contract_block_prefix_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return no-overflow contract local facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder() -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 1 };
        \\    var tag: u32 = 2;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        tag = unchecked.add(tag, 0);
        \\    }
        \\    return holder;
        \\}
        \\
        \\fn use_returned_holder() -> u32 {
        \\    let holder: Holder = returned_holder();
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_contract_block_local_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");
    try expectContains(output.items, "mc_race_load_u32");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_contract_block_local_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return contract-block update facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder() -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 1 };
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        holder.ptr = &shared_counter;
        \\    }
        \\    return holder;
        \\}
        \\
        \\fn use_returned_holder() -> u32 {
        \\    let holder: Holder = returned_holder();
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_contract_block_update_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");
    try expectContains(output.items, "mc_race_load_u32");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_contract_block_update_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return sequential switch facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder(first: u32, second: u32) -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 1 };
        \\    switch first {
        \\        0 => { holder.ptr = &shared_counter; }
        \\        _ => {}
        \\    }
        \\    switch second {
        \\        0 => { holder.ptr = &shared_counter; }
        \\        _ => {}
        \\    }
        \\    return holder;
        \\}
        \\
        \\fn use_returned_holder(first: u32, second: u32) -> u32 {
        \\    let holder: Holder = returned_holder(first, second);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_sequential_switch_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_sequential_switch_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return triple switch facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder(first: u32, second: u32, third: u32) -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 1 };
        \\    switch first {
        \\        0 => { holder.ptr = &shared_counter; }
        \\        _ => {}
        \\    }
        \\    switch second {
        \\        0 => { holder.ptr = &shared_counter; }
        \\        _ => {}
        \\    }
        \\    switch third {
        \\        0 => { holder.ptr = &shared_counter; }
        \\        _ => {}
        \\    }
        \\    return holder;
        \\}
        \\
        \\fn use_returned_holder(first: u32, second: u32, third: u32) -> u32 {
        \\    let holder: Holder = returned_holder(first, second, third);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_triple_switch_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_triple_switch_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return nine-path switch facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder(first: u32, second: u32) -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 1 };
        \\    switch first {
        \\        0 => { holder.ptr = &shared_counter; }
        \\        1 => { holder.ptr = &shared_counter; }
        \\        _ => { holder.ptr = &shared_counter; }
        \\    }
        \\    switch second {
        \\        0 => { holder.ptr = &shared_counter; }
        \\        1 => { holder.ptr = &shared_counter; }
        \\        _ => { holder.ptr = &shared_counter; }
        \\    }
        \\    return holder;
        \\}
        \\
        \\fn use_returned_holder(first: u32, second: u32) -> u32 {
        \\    let holder: Holder = returned_holder(first, second);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_nine_path_switch_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_nine_path_switch_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c aggregate-return path overflow switches fail closed" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder(first: u32, second: u32, third: u32) -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 1 };
        \\    switch first {
        \\        0 => { holder.ptr = &shared_counter; }
        \\        1 => { holder.ptr = &shared_counter; }
        \\        _ => { holder.ptr = &shared_counter; }
        \\    }
        \\    switch second {
        \\        0 => { holder.ptr = &shared_counter; }
        \\        1 => { holder.ptr = &shared_counter; }
        \\        _ => { holder.ptr = &shared_counter; }
        \\    }
        \\    switch third {
        \\        0 => { holder.ptr = &shared_counter; }
        \\        1 => { holder.ptr = &shared_counter; }
        \\        _ => { holder.ptr = &shared_counter; }
        \\    }
        \\    return holder;
        \\}
        \\
        \\fn use_returned_holder(first: u32, second: u32, third: u32) -> u32 {
        \\    let holder: Holder = returned_holder(first, second, third);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_path_overflow_switch_aggregate_return_fail_closed.mc", source, &output);
    try expectNotContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder");
    try expectContains(output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return if join facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder(flag: bool) -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 1 };
        \\    if flag {
        \\        holder.ptr = &shared_counter;
        \\    }
        \\    return holder;
        \\}
        \\
        \\fn use_returned_holder(flag: bool) -> u32 {
        \\    let holder: Holder = returned_holder(flag);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_if_join_prefix_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_if_join_prefix_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return all-fallthrough switch facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder(choice: u32) -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 1 };
        \\    switch choice {
        \\        0 => { holder.ptr = &shared_counter; }
        \\        _ => { holder.ptr = &shared_counter; }
        \\    }
        \\    return holder;
        \\}
        \\
        \\fn use_returned_holder(choice: u32) -> u32 {
        \\    let holder: Holder = returned_holder(choice);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_all_fallthrough_switch_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_all_fallthrough_switch_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return effectful direct-literal defer prefix facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\extern fn cleanup() -> void;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\fn cleanup_holder(holder: *mut Holder) -> void {
        \\    holder.*.tag = 0;
        \\}
        \\
        \\fn returned_holder() -> Holder {
        \\    defer cleanup();
        \\    return .{ .ptr = &shared_counter, .tag = 1 };
        \\}
        \\
        \\fn local_returned_holder() -> Holder {
        \\    let holder: Holder = .{ .ptr = &shared_counter, .tag = 2 };
        \\    defer cleanup();
        \\    return holder;
        \\}
        \\
        \\fn local_arg_returned_holder() -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 3 };
        \\    defer cleanup_holder(&holder);
        \\    return holder;
        \\}
        \\
        \\fn use_returned_holder() -> u32 {
        \\    let holder: Holder = returned_holder();
        \\    return holder.ptr.*;
        \\}
        \\
        \\fn use_local_returned_holder() -> u32 {
        \\    let holder: Holder = local_returned_holder();
        \\    return holder.ptr.*;
        \\}
        \\
        \\fn use_local_arg_returned_holder() -> u32 {
        \\    let holder: Holder = local_arg_returned_holder();
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_effectful_defer_prefix_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_local_returned_holder callee=local_returned_holder field=ptr provenance=global_storage");
    try expectNotContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_local_arg_returned_holder callee=local_arg_returned_holder field=ptr");
    const local_arg_body = try cFunctionBody(output.items, "static uint32_t use_local_arg_returned_holder(void)");
    try expectContains(local_arg_body, "mc_race_load_u32");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_effectful_defer_prefix_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    const missing_body = try cFunctionBody(missing_output.items, "static uint32_t use_returned_holder(void)");
    try expectContains(missing_body, "mc_race_load_u32");

    var missing_local_output: std.ArrayList(u8) = .empty;
    defer missing_local_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_effectful_defer_prefix_aggregate_return_mir_fact.mc", source, "local_returned_holder", "ptr", &missing_local_output);
    try expectNotContains(missing_local_output.items, "/* mir aggregate_return_pointer consumed caller=use_local_returned_holder callee=local_returned_holder field=ptr");
    const missing_local_body = try cFunctionBody(missing_local_output.items, "static uint32_t use_local_returned_holder(void)");
    try expectContains(missing_local_body, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return call-free defer prefix facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder() -> Holder {
        \\    let cleanup_value: u32 = 0;
        \\    defer cleanup_value;
        \\    return .{ .ptr = &shared_counter, .tag = 1 };
        \\}
        \\
        \\fn use_returned_holder() -> u32 {
        \\    let holder: Holder = returned_holder();
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_call_free_defer_prefix_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");
    try expectContains(output.items, "mc_race_load_u32");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_call_free_defer_prefix_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return transparent for-prefix facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder(values: [2]u32) -> Holder {
        \\    for value in values {
        \\        let ignored: u32 = value;
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 1 };
        \\}
        \\
        \\fn use_returned_holder(values: [2]u32) -> u32 {
        \\    let holder: Holder = returned_holder(values);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_for_prefix_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_for_prefix_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return scalar-field-mutating for facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder(values: [2]u32) -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 1 };
        \\    for value in values {
        \\        holder.tag = value;
        \\    }
        \\    return holder;
        \\}
        \\
        \\fn use_returned_holder(values: [2]u32) -> u32 {
        \\    let holder: Holder = returned_holder(values);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_scalar_field_mutating_for_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_scalar_field_mutating_for_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return nested pointer-array facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptrs: [2][2]*mut u32 }
        \\
        \\fn returned_holder() -> Holder {
        \\    return .{ .ptrs = .{ .{ &shared_counter, &shared_counter }, .{ &shared_counter, &shared_counter } } };
        \\}
        \\
        \\fn use_returned_holder() -> u32 {
        \\    let holder: Holder = returned_holder();
        \\    return holder.ptrs[0][0].*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_nested_pointer_array_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptrs[0][0] provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_nested_pointer_array_aggregate_return_mir_fact.mc", source, "returned_holder", "ptrs[0][0]", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptrs[0][0]");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c aggregate-return nested pointer arrays with missing leaf facts fail closed" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptrs: [2][2]*mut u32 }
        \\
        \\fn returned_holder(ptr: *mut u32) -> Holder {
        \\    return .{ .ptrs = .{ .{ &shared_counter, ptr }, .{ &shared_counter, &shared_counter } } };
        \\}
        \\
        \\fn use_returned_holder(ptr: *mut u32) -> u32 {
        \\    let holder: Holder = returned_holder(ptr);
        \\    return holder.ptrs[0][1].*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_nested_pointer_array_aggregate_return_missing_leaf_fail_closed.mc", source, &output);
    try expectNotContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptrs[0][1]");
    try expectContains(output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR aggregate-return nested struct-array facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Cell { ptr: *mut u32 }
        \\struct Holder { groups: [2][2]Cell }
        \\
        \\fn returned_holder() -> Holder {
        \\    return .{ .groups = .{ .{ .{ .ptr = &shared_counter }, .{ .ptr = &shared_counter } }, .{ .{ .ptr = &shared_counter }, .{ .ptr = &shared_counter } } } };
        \\}
        \\
        \\fn use_returned_holder() -> u32 {
        \\    let holder: Holder = returned_holder();
        \\    return holder.groups[0][0].ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_nested_struct_array_aggregate_return_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=groups[0][0].ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_nested_struct_array_aggregate_return_mir_fact.mc", source, "returned_holder", "groups[0][0].ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=groups[0][0].ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c aggregate-return dereference writes fail closed" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder() -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 1 };
        \\    let alias: *mut Holder = &holder;
        \\    alias.*.ptr = &shared_counter;
        \\    return holder;
        \\}
        \\
        \\fn use_returned_holder() -> u32 {
        \\    let holder: Holder = returned_holder();
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_deref_write_aggregate_return_fail_closed.mc", source, &output);
    try expectNotContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder");
    try expectContains(output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR trailing nested aggregate-return field assignment facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Inner { ptr: *mut u32 }
        \\struct Outer { inner: Inner }
        \\
        \\fn returned_outer(choice: u32) -> Outer {
        \\    var outer: Outer = .{ .inner = .{ .ptr = &shared_counter } };
        \\    switch choice {
        \\        0 => { return .{ .inner = .{ .ptr = &shared_counter } }; }
        \\        _ => { outer.inner.ptr = &shared_counter; }
        \\    }
        \\    return outer;
        \\}
        \\
        \\fn use_returned_outer(choice: u32) -> u32 {
        \\    let outer: Outer = returned_outer(choice);
        \\    return outer.inner.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_trailing_nested_aggregate_return_field_assignment_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_outer callee=returned_outer field=inner.ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_trailing_nested_aggregate_return_field_assignment_mir_fact.mc", source, "returned_outer", "inner.ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_outer callee=returned_outer field=inner.ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c consumes MIR trailing deep aggregate-return field assignment facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Leaf { ptr: *mut u32 }
        \\struct Middle { leaf: Leaf }
        \\struct Outer { middle: Middle }
        \\
        \\fn returned_outer(choice: u32) -> Outer {
        \\    var outer: Outer = .{ .middle = .{ .leaf = .{ .ptr = &shared_counter } } };
        \\    switch choice {
        \\        0 => { return .{ .middle = .{ .leaf = .{ .ptr = &shared_counter } } }; }
        \\        _ => { outer.middle.leaf.ptr = &shared_counter; }
        \\    }
        \\    return outer;
        \\}
        \\
        \\fn use_returned_outer(choice: u32) -> u32 {
        \\    let outer: Outer = returned_outer(choice);
        \\    return outer.middle.leaf.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_trailing_deep_aggregate_return_field_assignment_mir_fact.mc", source, &output);
    try expectContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_outer callee=returned_outer field=middle.leaf.ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_trailing_deep_aggregate_return_field_assignment_mir_fact.mc", source, "returned_outer", "middle.leaf.ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_outer callee=returned_outer field=middle.leaf.ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

fn expectTaggedUnionRaceCopySupported(source_name: []const u8, source: []const u8) !void {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest(source_name, source, &output);
    try expectContains(output.items, "__atomic_");
    try expectContains(output.items, "TokenTag_number");
}

fn expectUnsupportedCEmission(source_name: []const u8, source: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseModule(source_name, source);
    defer parsed.deinit();

    try std.testing.expectError(error.UnsupportedCEmission, lower_c.appendC(std.testing.allocator, parsed.module, output));
}

fn hasTestDiagnosticCode(reporter: diagnostics.Reporter, code: []const u8) bool {
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.startsWith(u8, diag.message, code) and diag.message.len > code.len and diag.message[code.len] == ':') return true;
    }
    return false;
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}

fn commentSourceText(output: []const u8, comment_prefix: []const u8) ![]const u8 {
    const comment_start = std.mem.indexOf(u8, output, comment_prefix) orelse return error.TestExpectedEqual;
    const source_start = std.mem.indexOfPos(u8, output, comment_start, "source=") orelse return error.TestExpectedEqual;
    const line_start = source_start + "source=".len;
    const source_end = std.mem.indexOfPos(u8, output, line_start, " ") orelse return error.TestExpectedEqual;
    return output[line_start..source_end];
}

fn expectCCommentSourceMatchesMirFact(c_output: []const u8, mir_dump: []const u8, comment_prefix: []const u8, mir_prefix: []const u8) !void {
    const source = try commentSourceText(c_output, comment_prefix);
    const colon = std.mem.indexOf(u8, source, ":") orelse return error.TestExpectedEqual;
    const line = try std.fmt.parseUnsigned(usize, source[0..colon], 10);
    const column = try std.fmt.parseUnsigned(usize, source[colon + 1 ..], 10);
    const mir_start = std.mem.indexOf(u8, mir_dump, mir_prefix) orelse return error.TestExpectedEqual;
    const mir_end = std.mem.indexOfPos(u8, mir_dump, mir_start, "\n") orelse mir_dump.len;
    const mir_row = mir_dump[mir_start..mir_end];
    const expected_source = try std.fmt.allocPrint(std.testing.allocator, "line={d} column={d}", .{ line, column });
    defer std.testing.allocator.free(expected_source);
    try expectContains(mir_row, expected_source);
}

fn cFunctionBody(output: []const u8, signature_prefix: []const u8) ![]const u8 {
    var search_from: usize = 0;
    const start = while (std.mem.indexOfPos(u8, output, search_from, signature_prefix)) |candidate| {
        const semicolon = std.mem.indexOfPos(u8, output, candidate, ";\n") orelse output.len;
        const brace = std.mem.indexOfPos(u8, output, candidate, "{\n") orelse return error.TestExpectedEqual;
        if (brace < semicolon) break candidate;
        search_from = candidate + signature_prefix.len;
    } else return error.TestExpectedEqual;
    const body_start = std.mem.indexOfPos(u8, output, start, "{\n") orelse return error.TestExpectedEqual;
    const body_end = std.mem.indexOfPos(u8, output, body_start, "\n}\n\n") orelse return error.TestExpectedEqual;
    return output[body_start + 2 .. body_end];
}

test "C noalias query accepts only the real builtin call shape" {
    const source =
        \\fn probe(p: *mut u32, n: usize) -> *mut u32 {
        \\    return (compiler.assume_noalias_unchecked(p, n))(p, n);
        \\}
        \\fn missing_size(p: *mut u32) -> *mut u32 {
        \\    return compiler.assume_noalias_unchecked(p);
        \\}
        \\fn with_type_arg(p: *mut u32, n: usize) -> *mut u32 {
        \\    return compiler.assume_noalias_unchecked<u32>(p, n);
        \\}
    ;

    var parsed = try test_support.parseModule("c_noalias_grouped_call_callee.mc", source);
    defer parsed.deinit();

    const probe_fn = parsed.module.decls[0].kind.fn_decl;
    const probe_ret = probe_fn.body.?.items[0].kind.@"return".?;
    const outer_call = probe_ret.kind.call;
    try std.testing.expect(!lower_c_builtin.isAssumeNoaliasCall(outer_call));

    const grouped_callee = outer_call.callee.*.kind.grouped;
    const inner_call = grouped_callee.kind.call;
    try std.testing.expect(lower_c_builtin.isAssumeNoaliasCall(inner_call));

    const missing_size_fn = parsed.module.decls[1].kind.fn_decl;
    const missing_size_ret = missing_size_fn.body.?.items[0].kind.@"return".?;
    try std.testing.expect(!lower_c_builtin.isAssumeNoaliasCall(missing_size_ret.kind.call));

    const with_type_arg_fn = parsed.module.decls[2].kind.fn_decl;
    const with_type_arg_ret = with_type_arg_fn.body.?.items[0].kind.@"return".?;
    try std.testing.expect(!lower_c_builtin.isAssumeNoaliasCall(with_type_arg_ret.kind.call));
}

test "C bitcast query accepts only the real builtin call shape" {
    const source =
        \\fn probe(x: u32) -> u32 {
        \\    return (bitcast<u32>(x))(x);
        \\}
        \\fn missing_value() -> u32 {
        \\    return bitcast<u32>();
        \\}
        \\fn missing_type(x: u32) -> u32 {
        \\    return bitcast(x);
        \\}
        \\fn valid(x: u32) -> u32 {
        \\    return bitcast<u32>(x);
        \\}
    ;

    var parsed = try test_support.parseModule("c_bitcast_grouped_call_callee.mc", source);
    defer parsed.deinit();

    const probe_fn = parsed.module.decls[0].kind.fn_decl;
    const probe_ret = probe_fn.body.?.items[0].kind.@"return".?;
    const outer_call = probe_ret.kind.call;
    try std.testing.expect(!lower_c_expr.isBitcastCall(outer_call));

    const grouped_callee = outer_call.callee.*.kind.grouped;
    const inner_call = grouped_callee.kind.call;
    try std.testing.expect(lower_c_expr.isBitcastCall(inner_call));

    const missing_value_fn = parsed.module.decls[1].kind.fn_decl;
    const missing_value_ret = missing_value_fn.body.?.items[0].kind.@"return".?;
    try std.testing.expect(!lower_c_expr.isBitcastCall(missing_value_ret.kind.call));

    const missing_type_fn = parsed.module.decls[2].kind.fn_decl;
    const missing_type_ret = missing_type_fn.body.?.items[0].kind.@"return".?;
    try std.testing.expect(!lower_c_expr.isBitcastCall(missing_type_ret.kind.call));

    const valid_fn = parsed.module.decls[3].kind.fn_decl;
    const valid_ret = valid_fn.body.?.items[0].kind.@"return".?;
    try std.testing.expect(lower_c_expr.isBitcastCall(valid_ret.kind.call));
}

test "lower-c inspection markers for lowering-sensitive spec behavior" {
    const source =
        \\global shared_counter: u32 = 0;
        \\
        \\extern mmio struct Uart16550 {
        \\    thr: Reg<u8, .write>,
        \\    lsr: RegBits<u8, UartLsr, .read>,
        \\}
        \\
        \\fn exercise(uart: MmioPtr<Uart16550>, ch: u8, a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let y = unchecked.add(a, b);
        \\    }
        \\    shared_counter = ch;
        \\    let x = shared_counter;
        \\    uart.thr.write(ch, .release);
        \\    let status = uart.lsr.read(.acquire);
        \\    return a + b;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "lower_c.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendInspection(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "lower checked_arith") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "op=add") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "lower contract_scope") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "metadata_begin=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "metadata_end=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "lower ordinary_access") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "access=store") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "access=load") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "lower mmio_access") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "value_type=UartLsr") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "register_width=8 emitted_width=8") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "ordering=release") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "ordering=acquire") != null);
}

test "lower-c emits support helpers used by evidence" {
    const source =
        \\fn noop() -> void {}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_IntegerOverflow") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_DivideByZero") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_InvalidShift") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Bounds") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Assert") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_NullUnwrap") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_InvalidRepresentation") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Unreachable") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_check_index_usize") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_CHECKED_UNSIGNED(u32, uint32_t, UINT32_MAX)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_CHECKED_UNSIGNED(u64, uint64_t, UINT64_MAX)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_CHECKED_SIGNED(i32, int32_t, INT32_MIN, INT32_MAX)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_CHECKED_NEG_SIGNED(i32, int32_t, INT32_MIN)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_CHECKED_NEG_SIGNED(isize, intptr_t, INTPTR_MIN)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_RACE_SCALAR(NAME, TYPE)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_RACE_SCALAR(bool, bool)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_RACE_SCALAR(u32, uint32_t)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_RACE_SCALAR(i32, int32_t)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_RACE_SCALAR(usize, uintptr_t)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_read_u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_read_u16") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_read_u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_read_u64") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_write_u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_write_u16") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_write_u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_write_u64") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_release_before") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_acquire_after") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "__atomic_thread_fence(__ATOMIC_RELEASE)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "__atomic_thread_fence(__ATOMIC_ACQUIRE)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "__atomic_signal_fence") == null);
}

test "lower-c emits cstr as immutable C string pointer" {
    const source =
        \\extern "C" fn strlen(s: cstr) -> usize;
        \\extern "C" fn identity(s: cstr) -> cstr;
        \\global global_cstr: cstr = "global";
        \\global copied_cstr: cstr = global_cstr;
        \\
        \\export fn use_cstr() -> usize {
        \\    let s: cstr = "abc";
        \\    return strlen(s);
        \\}
        \\
        \\export fn return_cstr() -> cstr {
        \\    return identity("xyz");
        \\}
        \\export fn return_bytes() -> []const u8 { return "bytes"; }
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("cstr_c.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uintptr_t strlen(char const * s);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "char const * identity(char const * s);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "global_cstr = ((char const *)\"global\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "copied_cstr = ((char const *)\"global\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "char const * s = ((char const *)\"abc\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "char const * return_cstr(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "char const * mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " = ((char const *)\"xyz\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return identity(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".len = 5") != null);
}

test "lower-c reuses prebuilt verified MIR without changing output" {
    const source =
        \\fn add_one(value: u32) -> u32 {
        \\    return value + 1;
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_prebuilt_mir.mc", source);
    defer parsed.deinit();

    var rebuilt_output: std.ArrayList(u8) = .empty;
    defer rebuilt_output.deinit(std.testing.allocator);
    try lower_c.appendCProfileWithSourcePath(std.testing.allocator, parsed.module, &rebuilt_output, .kernel, "c_prebuilt_mir.mc", .{ .optimize = true }, false);

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "c_prebuilt_mir.mc", source);
    defer reporter.deinit();
    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{ .optimize = true });
    defer module_mir.deinit();
    try mir.verifyBuiltMir(module_mir, &reporter);
    try std.testing.expect(!reporter.has_errors);

    var prebuilt_output: std.ArrayList(u8) = .empty;
    defer prebuilt_output.deinit(std.testing.allocator);
    try lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &prebuilt_output, .kernel, "c_prebuilt_mir.mc", .{ .optimize = true }, false, &reporter);

    try std.testing.expectEqualSlices(u8, rebuilt_output.items, prebuilt_output.items);
}

test "lower-c path-aware C emission writes source line hints" {
    const source =
        \\global count: u32 = 1;
        \\
        \\fn add_one(x: u32) -> u32 {
        \\    let y: u32 = x + 1;
        \\    return y;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "debug_map.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendCProfileWithSourcePath(std.testing.allocator, module, &output, .kernel, "debug\"map\\case.mc", .{}, false);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "#line 1 \"debug\\\"map\\\\case.mc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "#line 3 \"debug\\\"map\\\\case.mc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "#line 4 \"debug\\\"map\\\\case.mc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "#line 5 \"debug\\\"map\\\\case.mc\"") != null);
}

test "lower-c source map records source spans and generated C lines" {
    const source =
        \\global count: u32 = 1;
        \\
        \\fn add_one(x: u32) -> u32 {
        \\    let y: u32 = x + 1;
        \\    return y;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "debug_map.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendCSourceMap(std.testing.allocator, module, &output, .kernel, "debug_map.mc", "debug_map.c");

    try std.testing.expect(std.mem.indexOf(u8, output.items, "# mcmap v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "source_module=\"debug_map\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "symbol_kind=\"free_fn\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "source_qualname=\"add_one\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "backend_name=\"add_one\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "origin=\"source\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "symbol_kind=\"assoc_const\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"global\" symbol=\"count\" source_line=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"global_initializer_expr\" symbol=\"count\" source_line=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"function\" symbol=\"add_one\" source_line=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"let_decl\" symbol=\"add_one\" source_line=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"initializer_expr\" symbol=\"add_one\" source_line=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"expr_ident\" symbol=\"add_one\" source_line=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"expr_int_literal\" symbol=\"add_one\" source_line=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"return\" symbol=\"add_one\" source_line=5") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"return_expr\" symbol=\"add_one\" source_line=5") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "generated_c_line=0") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "source_path=\"debug_map.mc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "generated_c_path=\"debug_map.c\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "typed_ast_node=\"ast:function:add_one@3:4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "typed_ast_node=\"ast:global_initializer_expr:count@1:21\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "typed_ast_node=\"ast:initializer_expr:add_one@4:18\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "typed_ast_node=\"ast:return_expr:add_one@5:12\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mir_block=\"mir:add_one:block:") != null);
}

test "lower-c source map records defer cleanup spans" {
    const source =
        \\extern fn close_resource() -> void;
        \\
        \\fn cleanup(flag: bool) -> void {
        \\    defer close_resource();
        \\    defer {
        \\        close_resource();
        \\    };
        \\    while flag {
        \\        defer close_resource();
        \\        break;
        \\    }
        \\    return;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "debug_map_defer.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendCSourceMap(std.testing.allocator, module, &output, .kernel, "debug_map_defer.mc", "debug_map_defer.c");

    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"defer\" symbol=\"cleanup\" source_line=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"defer_expr\" symbol=\"cleanup\" source_line=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"defer\" symbol=\"cleanup\" source_line=5") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"expr\" symbol=\"cleanup\" source_line=6") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"defer\" symbol=\"cleanup\" source_line=9") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"defer_expr\" symbol=\"cleanup\" source_line=9") != null);
    var defer_lines = std.mem.splitScalar(u8, output.items, '\n');
    while (defer_lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "generated_c_line=0") == null) continue;
        try std.testing.expect(std.mem.indexOf(u8, line, "symbol_kind=\"extern_fn\"") != null or
            std.mem.indexOf(u8, line, "symbol_kind=\"type\"") != null);
    }
}

test "lower-c f32 literal expressions compute in float, not double" {
    const source =
        \\export fn harness() -> u64 {
        \\    var c: f32 = (1.7 * 2.3);
        \\    return bitcast<u32>(c) as u64;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "f32.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "1.7f") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "2.3f") != null);
}

test "lower-c tuples desugar to one nominal struct with numeric field access" {
    const source =
        \\fn make() -> (u32, u64) { return (7, 100); }
        \\export fn harness() -> u64 {
        \\    var t: (u32, u64) = make();
        \\    return (t.0 as u64) + t.1;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "tup.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.count(u8, output.items, "typedef struct __tuple2_u32_u64 __tuple2_u32_u64;") == 1);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "t._0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "t._1") != null);
}

test "lower-c module blocks namespace functions and constants" {
    const source =
        \\module Math {
        \\    const PI: u32 = 3;
        \\    fn square(x: u32) -> u32 { return x * x; }
        \\}
        \\export fn harness() -> u64 {
        \\    return (Math.square(4) + Math.PI) as u64;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mod.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "Math__square") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Math__PI") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Math__square(4)") != null);
}

test "lower-c impl blocks desugar to mangled free functions" {
    const source =
        \\struct Tensor { v: u32 }
        \\impl Tensor {
        \\    fn get(self: Tensor) -> u32 { return self.v; }
        \\}
        \\export fn harness() -> u64 {
        \\    var t: Tensor = .{ .v = 5 };
        \\    return Tensor.get(t) as u64;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "impl.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "Tensor__get") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Tensor__get(t)") != null);
}

test "lower-c tuple destructuring binds each name to temporary fields" {
    const source =
        \\fn make() -> (u32, u64) { return (7, 100); }
        \\export fn harness() -> u64 {
        \\    let (a, b) = make();
        \\    return (a as u64) + b;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "destr.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "__destr0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "__destr0._0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "__destr0._1") != null);
}

test "lower-c backend_name attribute emits asm label" {
    const source =
        \\#[backend_name("rss_helper_x")]
        \\fn helper(x: u64) -> u64 { return x + 1; }
        \\export fn harness() -> u64 { return helper(7); }
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "bn.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.count(u8, output.items, "__asm__(\"rss_helper_x\")") == 1);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "helper(uint64_t x) __asm__(\"rss_helper_x\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "helper(uint64_t x) {") != null);
}

test "lower-c align attribute and naked default emit aligned attributes" {
    const source =
        \\#[align(64)]
        \\export fn dma_buf_fn() -> void { return; }
        \\#[naked]
        \\export fn trap_vector() -> void {
        \\    asm opaque volatile { "ret" }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "align.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "__attribute__((aligned(64)))") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "__attribute__((aligned(4)))") != null);
}

test "lower-c closure callees materialize once" {
    const source =
        \\struct Env { tag: u32 }
        \\fn run_impl(e: *mut Env, x: u32) -> u32 { return x + e.tag; }
        \\struct Slot { run: closure(u32) -> u32 }
        \\global g_env: Env;
        \\global g_table: [4]Slot;
        \\
        \\fn call_direct(i: usize, x: u32) -> u32 {
        \\    return g_table[i].run(x);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_closure_callee_once.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    const callee = "g_table.elems[mc_check_index_usize(i, 4)].run";
    var count: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, output.items, search_from, callee)) |index| {
        count += 1;
        search_from = index + callee.len;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".code(mc_tmp") != null);
}

test "lower-c casts bool closure-call switch subjects" {
    const source =
        \\fn classify(pred: closure(u32) -> bool, x: u32) -> u32 {
        \\    switch pred(x) {
        \\        true => { return 1; },
        \\        false => { return 0; },
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_closure_bool_switch.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "switch ((int)(({ mc_closure_bool_u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".code(mc_tmp") != null);
}

test "lower-c emits simple MMIO register access" {
    const source =
        \\extern mmio struct Uart16550 {
        \\    thr: Reg<u8, .write>,
        \\    lsr: Reg<u8, .read>,
        \\}
        \\
        \\fn putc(uart: MmioPtr<Uart16550>, ch: u8) -> void {
        \\    uart.thr.write(ch, .release);
        \\}
        \\
        \\fn read_lsr(uart: MmioPtr<Uart16550>) -> u8 {
        \\    return uart.lsr.read(.acquire);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_mmio.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct Uart16550 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t volatile thr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t volatile lsr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void putc(Uart16550 volatile * uart, uint8_t ch)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t mc_tmp0 = ch;\n    mc_barrier_release_before();\n    mc_mmio_write_u8(&uart->thr, mc_tmp0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_release_before();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint8_t read_lsr(Uart16550 volatile * uart)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t mc_tmp1 = (uint8_t)mc_mmio_read_u8(&uart->lsr);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_acquire_after();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_tmp1;") != null);
}

test "lower-c emits wider MMIO register access" {
    const source =
        \\extern mmio struct Device {
        \\    lo: Reg<u16, .read>,
        \\    hi: Reg<u32, .write>,
        \\    wide: Reg<u64, .read_write>,
        \\}
        \\
        \\fn read_lo(dev: MmioPtr<Device>) -> u16 {
        \\    return dev.lo.read(.relaxed);
        \\}
        \\
        \\fn write_hi(dev: MmioPtr<Device>, value: u32) -> void {
        \\    dev.hi.write(value, .release);
        \\}
        \\
        \\fn read_wide(dev: MmioPtr<Device>) -> u64 {
        \\    return dev.wide.read(.acquire);
        \\}
        \\
        \\fn write_wide(dev: MmioPtr<Device>, value: u64) -> void {
        \\    dev.wide.write(value, .relaxed);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_wide_mmio.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint16_t volatile lo;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t volatile hi;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint64_t volatile wide;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return (uint16_t)mc_mmio_read_u16(&dev->lo);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp0 = value;\n    mc_barrier_release_before();\n    mc_mmio_write_u32(&dev->hi, mc_tmp0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint64_t mc_tmp1 = (uint64_t)mc_mmio_read_u64(&dev->wide);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_acquire_after();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint64_t mc_tmp2 = value;\n    mc_mmio_write_u64(&dev->wide, mc_tmp2);") != null);
}

test "lower-c sequences MMIO write value before release barrier" {
    const source =
        \\extern mmio struct Uart16550 {
        \\    thr: Reg<u8, .write>,
        \\}
        \\
        \\extern fn next_byte() -> u8;
        \\extern fn box_byte(value: u8) -> u8;
        \\
        \\fn putc_computed(uart: MmioPtr<Uart16550>) -> void {
        \\    uart.thr.write(box_byte(next_byte()), .release);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_mmio_write_order.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t mc_tmp0 = next_byte();\n    uint8_t mc_tmp1 = box_byte(mc_tmp0);\n    mc_barrier_release_before();\n    mc_mmio_write_u8(&uart->thr, mc_tmp1);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_release_before();\n    mc_mmio_write_u8(&uart->thr, box_byte(next_byte()))") == null);
}

test "lower-c sequences raw store address and value operands" {
    const source =
        \\extern fn next_addr() -> PAddr;
        \\extern fn next_byte() -> u8;
        \\extern fn box_byte(value: u8) -> u8;
        \\
        \\fn store_computed() -> void {
        \\    unsafe {
        \\        raw.store<u8>(next_addr(), box_byte(next_byte()));
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_raw_store_order.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uintptr_t mc_tmp0 = next_addr();\n        uint8_t mc_tmp1 = next_byte();\n        uint8_t mc_tmp2 = box_byte(mc_tmp1);\n        mc_raw_store_u8(mc_tmp0, mc_tmp2);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_raw_store_u8(next_addr(), box_byte(next_byte()))") == null);
}

test "lower-c emits MMIO read local initializers" {
    const source =
        \\packed bits Status: u8 {
        \\    ready: bool,
        \\}
        \\
        \\extern mmio struct Device {
        \\    stat: Reg<u16, .read>,
        \\    flags: RegBits<u8, Status, .read>,
        \\}
        \\
        \\fn read_local(dev: MmioPtr<Device>) -> u16 {
        \\    let value: u16 = dev.stat.read(.acquire);
        \\    return value;
        \\}
        \\
        \\fn read_bits_local(dev: MmioPtr<Device>) -> Status {
        \\    let status: Status = dev.flags.read(.relaxed);
        \\    return status;
        \\}
        \\
        \\fn read_inferred_bits_local(dev: MmioPtr<Device>) -> bool {
        \\    let status = dev.flags.read(.acquire);
        \\    return status.ready;
        \\}
        \\
        \\fn assign_status(dev: MmioPtr<Device>) -> Status {
        \\    var status: Status = dev.flags.read(.relaxed);
        \\    status = dev.flags.read(.acquire);
        \\    return status;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_mmio_read_local_init.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint16_t value = (uint16_t)mc_mmio_read_u16(&dev->stat);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_acquire_after();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Status status = (Status)mc_mmio_read_u8(&dev->flags);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Status status = (Status)mc_mmio_read_u8(&dev->flags);\n    mc_barrier_acquire_after();\n    return ((status & UINT8_C(1)) != 0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Status mc_tmp0 = (Status)mc_mmio_read_u8(&dev->flags);\n    mc_barrier_acquire_after();\n    status = mc_tmp0;\n    return status;") != null);
}

test "lower-c emits packed bits MMIO reads and field masks" {
    const source =
        \\packed bits UartLsr: u8 {
        \\    data_ready: bool,
        \\    tx_empty: bool,
        \\}
        \\
        \\global status: UartLsr = 0;
        \\
        \\extern mmio struct Uart16550 {
        \\    lsr: RegBits<u8, UartLsr, .read>,
        \\}
        \\
        \\fn read_status(uart: MmioPtr<Uart16550>) -> UartLsr {
        \\    return uart.lsr.read(.acquire);
        \\}
        \\
        \\fn ready(status: UartLsr) -> bool {
        \\    return status.tx_empty;
        \\}
        \\
        \\fn set_ready(status: UartLsr, flag: bool) -> UartLsr {
        \\    status.tx_empty = flag;
        \\    return status;
        \\}
        \\
        \\fn set_global_ready(flag: bool) -> void {
        \\    status.tx_empty = flag;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_packed_bits_mmio.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef uint8_t UartLsr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static UartLsr read_status(Uart16550 volatile * uart)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "UartLsr mc_tmp0 = (UartLsr)mc_mmio_read_u8(&uart->lsr);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_acquire_after();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_tmp0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static bool ready(UartLsr status)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((status & UINT8_C(2)) != 0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static UartLsr set_ready(UartLsr status, bool flag)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "status = (UartLsr)((status & (UartLsr)~UINT8_C(2)) | (flag ? UINT8_C(2) : (UartLsr)0));") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void set_global_ready(bool flag)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "UartLsr mc_tmp1 = (UartLsr)mc_race_load_u8(&status);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_tmp1 = (UartLsr)((mc_tmp1 & (UartLsr)~UINT8_C(2)) | (flag ? UINT8_C(2) : (UartLsr)0));") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_race_store_u8(&status, (uint8_t)mc_tmp1);") != null);
}

test "lower-c emits C ABI for simple Result types" {
    const source =
        \\enum Error: u8 {
        \\    denied = 1,
        \\}
        \\
        \\extern fn make_result() -> Result<u32, Error>;
        \\extern fn consume_result(result: Result<u32, Error>) -> void;
        \\
        \\fn pass_result(result: Result<u32, Error>) -> Result<u32, Error> {
        \\    return result;
        \\}
        \\
        \\fn call_consume(result: Result<u32, Error>) -> void {
        \\    consume_result(result);
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_result_abi.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct mc_result_u32_Error {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "bool is_ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Error err;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "} payload;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error make_result(void);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "void consume_result(mc_result_u32_Error result);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static mc_result_u32_Error pass_result(mc_result_u32_Error result)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return result;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp0 = result;\n    consume_result(mc_tmp0);") != null);
}

test "lower-c emits C ABI for tagged unions" {
    const source =
        \\union Token {
        \\    int: i64,
        \\    eof,
        \\}
        \\
        \\fn pass_token(token: Token) -> Token {
        \\    return token;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_tagged_union_abi.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef enum TokenTag {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "TokenTag_int = 0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "TokenTag_eof = 1,") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "} TokenTag;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct Token {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "TokenTag tag;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "int64_t int_;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "} payload;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "} Token;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static Token pass_token(Token token)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return token;") != null);
}

test "lower-c emits tagged union switch narrowing" {
    const source =
        \\union Token {
        \\    int: i64,
        \\    eof,
        \\    space,
        \\}
        \\
        \\fn token_value(token: Token) -> i64 {
        \\    switch token {
        \\        int(v) => { return v; },
        \\        .eof => { return 0; },
        \\    }
        \\}
        \\
        \\fn token_kind(token: Token) -> u32 {
        \\    switch token {
        \\        .int => { return 1; },
        \\        .eof, .space => { return 0; },
        \\    }
        \\}
        \\
        \\extern fn make_token() -> Token;
        \\
        \\fn token_call_value() -> i64 {
        \\    switch make_token() {
        \\        int(v) => { return v; },
        \\        .eof => { return 0; },
        \\    }
        \\}
        \\
        \\fn token_local_value() -> i64 {
        \\    let token = make_token();
        \\    switch token {
        \\        int(v) => { return v; },
        \\        .eof => { return 0; },
        \\    }
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_tagged_union_switch.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static int64_t token_value(Token token)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (token.tag == TokenTag_int) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "int64_t v = token.payload.int_;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return v;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "else if (token.tag == TokenTag_eof) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_InvalidRepresentation();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t token_kind(Token token)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (token.tag == TokenTag_int) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "else if (token.tag == TokenTag_eof || token.tag == TokenTag_space) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static int64_t token_call_value(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Token mc_tmp0 = make_token();\n    if (mc_tmp0.tag == TokenTag_int) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "int64_t v = mc_tmp0.payload.int_;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "else if (mc_tmp0.tag == TokenTag_eof) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static int64_t token_local_value(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Token token = make_token();\n    if (token.tag == TokenTag_int) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "int64_t v = token.payload.int_;") != null);
}

test "lower-c emits tagged union constructors" {
    const source =
        \\union Token {
        \\    number: i64,
        \\    value: i64,
        \\    eof,
        \\    ok: u32,
        \\}
        \\
        \\fn id(token: Token) -> Token {
        \\    return token;
        \\}
        \\
        \\fn make_number() -> Token {
        \\    return value(7);
        \\}
        \\
        \\fn make_eof() -> Token {
        \\    return eof();
        \\}
        \\
        \\fn call_id() -> Token {
        \\    return id(value(7));
        \\}
        \\
        \\fn local_number() -> Token {
        \\    let token: Token = value(9);
        \\    return token;
        \\}
        \\fn number(value: i64) -> Token { return Token.number(value); }
        \\fn call_number() -> Token { return number(11); }
        \\fn make_ok_case() -> Token { return ok(12); }
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_tagged_union_constructors.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((Token){ .tag = TokenTag_value, .payload.value = 7 });") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((Token){ .tag = TokenTag_eof });") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Token mc_tmp0 = ((Token){ .tag = TokenTag_value, .payload.value = 7 });\n    return id(mc_tmp0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Token token = ((Token){ .tag = TokenTag_value, .payload.value = 9 });") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return number(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((Token){ .tag = TokenTag_ok, .payload.ok = 12 });") != null);
}

test "lower-c emits Result ok and err constructors" {
    const source =
        \\enum Error: u8 {
        \\    denied = 1,
        \\}
        \\
        \\extern fn consume_result(result: Result<u32, Error>) -> void;
        \\
        \\fn make_ok(value: u32) -> Result<u32, Error> {
        \\    return ok(value);
        \\}
        \\
        \\fn make_err() -> Result<u32, Error> {
        \\    return err(.denied);
        \\}
        \\
        \\fn send_ok() -> void {
        \\    consume_result(ok(7));
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_result_constructors.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((mc_result_u32_Error){ .is_ok = true, .payload.ok = value });") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((mc_result_u32_Error){ .is_ok = false, .payload.err = Error_denied });") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp0 = ((mc_result_u32_Error){ .is_ok = true, .payload.ok = 7 });\n    consume_result(mc_tmp0);") != null);
}

test "lower-c emits Result try in local initializers" {
    const source =
        \\enum Error: u8 {
        \\    denied = 1,
        \\}
        \\
        \\extern fn make_result() -> Result<u32, Error>;
        \\
        \\fn add_one() -> Result<u32, Error> {
        \\    let value: u32 = make_result()?;
        \\    return ok(value + 1);
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_result_try.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp0 = make_result();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!mc_tmp0.is_ok) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((mc_result_u32_Error){ .is_ok = false, .payload.err = mc_tmp0.payload.err });") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t value = mc_tmp0.payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((mc_result_u32_Error){ .is_ok = true, .payload.ok = mc_checked_add_u32(value, 1) });") != null);
}

test "lower-c emits Result try in return statements" {
    const source =
        \\enum Error: u8 {
        \\    denied = 1,
        \\}
        \\
        \\extern fn make_result() -> Result<u32, Error>;
        \\
        \\fn unwrap_param(result: Result<u32, Error>) -> u32 {
        \\    return result?;
        \\}
        \\
        \\fn unwrap_call() -> u32 {
        \\    return make_result()?;
        \\}
        \\
        \\fn unwrap_grouped_call() -> u32 {
        \\    return (make_result())?;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_result_try_return.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp0 = result;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!mc_tmp0.is_ok) mc_trap_InvalidRepresentation();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_tmp0.payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp1 = make_result();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp2 = (make_result());") != null);
}

test "lower-c emits Result try in return call arguments" {
    const source =
        \\enum Error: u8 {
        \\    denied = 1,
        \\}
        \\
        \\extern fn make_result() -> Result<u32, Error>;
        \\extern fn consume(value: u32) -> u32;
        \\extern fn combine(left: u32, right: u32) -> u32;
        \\extern fn box_value(value: u32) -> u32;
        \\
        \\fn arg_try() -> u32 {
        \\    return consume(make_result()?);
        \\}
        \\
        \\fn two_arg_try() -> u32 {
        \\    return combine(make_result()?, make_result()?);
        \\}
        \\
        \\fn nested_arg_try() -> u32 {
        \\    return consume(box_value(make_result()?));
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_result_try_call_args.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t arg_try(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp0 = make_result();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!mc_tmp0.is_ok) mc_trap_InvalidRepresentation();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return consume(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "make_result();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return combine(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "box_value(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return consume(mc_tmp") != null);
}

test "lower-c emits nullable try in return statements" {
    const source =
        \\extern fn make_nullable_pointer() -> ?*const u8;
        \\extern fn make_nullable_mut_pointer() -> ?*mut u8;
        \\
        \\fn unwrap_param(maybe: ?*const u8) -> *const u8 {
        \\    return maybe?;
        \\}
        \\
        \\fn unwrap_call() -> *const u8 {
        \\    return make_nullable_pointer()?;
        \\}
        \\
        \\fn unwrap_grouped_call() -> *mut u8 {
        \\    return (make_nullable_mut_pointer())?;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_nullable_try_return.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t const * mc_tmp0 = maybe;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (mc_tmp0 == NULL) mc_trap_NullUnwrap();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_tmp0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "make_nullable_pointer();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * mc_tmp2 = (make_nullable_mut_pointer());") != null);
}

test "lower-c emits nullable try in return call arguments" {
    const source =
        \\extern fn make_nullable_pointer() -> ?*const u8;
        \\extern fn consume_ptr(ptr: *const u8) -> u32;
        \\extern fn choose(left: *const u8, right: *const u8) -> u32;
        \\extern fn ptr_id(ptr: *const u8) -> *const u8;
        \\
        \\fn arg_try(maybe: ?*const u8) -> u32 {
        \\    return consume_ptr(maybe?);
        \\}
        \\
        \\fn direct_arg_try() -> u32 {
        \\    return consume_ptr(make_nullable_pointer()?);
        \\}
        \\
        \\fn two_arg_try(maybe: ?*const u8) -> u32 {
        \\    return choose(maybe?, make_nullable_pointer()?);
        \\}
        \\
        \\fn nested_arg_try() -> u32 {
        \\    return consume_ptr(ptr_id(make_nullable_pointer()?));
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_nullable_try_call_args.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t arg_try(uint8_t const * maybe)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t const * mc_tmp0 = maybe;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (mc_tmp0 == NULL) mc_trap_NullUnwrap();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return consume_ptr(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "make_nullable_pointer();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return consume_ptr(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t const * mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return choose(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "make_nullable_pointer();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "ptr_id(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return consume_ptr(mc_tmp") != null);
}

test "lower-c emits try in local initializer call arguments" {
    const source =
        \\enum Error: u8 {
        \\    denied = 1,
        \\}
        \\
        \\extern fn make_result() -> Result<u32, Error>;
        \\extern fn box_value(value: u32) -> u32;
        \\extern fn make_nullable_pointer() -> ?*const u8;
        \\extern fn ptr_id(ptr: *const u8) -> *const u8;
        \\
        \\fn local_result_try() -> Result<u32, Error> {
        \\    let value: u32 = box_value(make_result()?);
        \\    return ok(value);
        \\}
        \\
        \\fn local_nullable_try() -> *const u8 {
        \\    let ptr: *const u8 = ptr_id(make_nullable_pointer()?);
        \\    return ptr;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_try_local_initializer.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static mc_result_u32_Error local_result_try(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp0 = make_result();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!mc_tmp0.is_ok) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((mc_result_u32_Error){ .is_ok = false, .payload.err = mc_tmp0.payload.err });") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t value = box_value(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint8_t const * local_nullable_try(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "make_nullable_pointer();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "== NULL) mc_trap_NullUnwrap();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t const * ptr = ptr_id(mc_tmp") != null);
}

test "lower-c emits try in assignment and expression statements" {
    const source =
        \\enum Error: u8 {
        \\    denied = 1,
        \\}
        \\
        \\global shared_value: u32 = 0;
        \\
        \\extern fn make_result() -> Result<u32, Error>;
        \\extern fn consume(value: u32) -> void;
        \\extern fn make_nullable_pointer() -> ?*const u8;
        \\extern fn consume_ptr(ptr: *const u8) -> void;
        \\
        \\fn assign_result_try() -> Result<u32, Error> {
        \\    var value: u32 = 0;
        \\    value = make_result()?;
        \\    shared_value = make_result()?;
        \\    return ok(value);
        \\}
        \\
        \\fn expr_result_try() -> Result<u32, Error> {
        \\    make_result()?;
        \\    consume(make_result()?);
        \\    return ok(1);
        \\}
        \\
        \\fn assign_nullable_try() -> *const u8 {
        \\    var ptr: *const u8 = make_nullable_pointer()?;
        \\    ptr = make_nullable_pointer()?;
        \\    return ptr;
        \\}
        \\
        \\fn expr_nullable_try() -> void {
        \\    make_nullable_pointer()?;
        \\    consume_ptr(make_nullable_pointer()?);
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_try_assignment_expr_stmt.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp0 = make_result();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "value = mc_tmp0.payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp1 = make_result();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_race_store_u32(&shared_value, (uint32_t)mc_tmp1.payload.ok);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp2 = make_result();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!mc_tmp2.is_ok) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp3 = make_result();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "consume(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "make_nullable_pointer();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t const * ptr = mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "ptr = mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "== NULL) mc_trap_NullUnwrap();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "consume_ptr(mc_tmp") != null);
}

test "lower-c emits simple functions and race-safe globals" {
    const source =
        \\global shared_counter: u32 = 0;
        \\
        \\fn add(a: u32, b: u32) -> u32 {
        \\    return a + b;
        \\}
        \\
        \\fn store(x: u32) -> void {
        \\    shared_counter = x;
        \\}
        \\
        \\fn load() -> u32 {
        \\    return shared_counter;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_functions.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "static MC_UNUSED uint32_t shared_counter = 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t add(uint32_t a, uint32_t b)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_race_store_u32(&shared_counter, (uint32_t)x);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((uint32_t)mc_race_load_u32(&shared_counter));") != null);
}

test "lower-c wide-scalar global race lowering fails closed" {
    // A u128/i128 global scalar access would name a nonexistent mc_race_load_u128/
    // mc_race_store_i128 helper and only fail at C compile time. Spec §I.13: no
    // sound race-tolerant lowering means emission must fail closed.
    try expectUnsupportedCheckedCEmission("emit_c_wide_global_load.mc",
        \\global wide: u128;
        \\
        \\fn read_wide() -> u128 {
        \\    return wide;
        \\}
    );
    try expectUnsupportedCheckedCEmission("emit_c_wide_global_store.mc",
        \\global wide: i128;
        \\
        \\fn write_wide(x: i128) -> void {
        \\    wide = x;
        \\}
    );
}

test "lower-c unproven wide-scalar pointer deref fails closed" {
    // An unproven *mut u128 deref demands race-tolerant lowering (spec I.13
    // default), but no mc_race helper exists for 128-bit scalars -> emission
    // must fail closed rather than name a nonexistent helper.
    try expectUnsupportedCheckedCEmission("emit_c_wide_deref.mc",
        \\fn read_wide(p: *mut u128) -> u128 {
        \\    return p.*;
        \\}
    );
}

test "lower-c proven-local wide-scalar deref stays plain" {
    const source =
        \\fn local_wide() -> u128 {
        \\    var w: u128 = 7;
        \\    let p: *mut u128 = &w;
        \\    p.* = 9;
        \\    return p.*;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_wide_local_deref.mc", source, &output);
    const body = try cFunctionBody(output.items, "static unsigned __int128 local_wide(void)");
    try expectContains(body, "/* mir pointer_provenance consumed fn=local_wide subject=p provenance=local_storage reason=none source=");
    try expectContains(body, "*p = 9;");
    try expectContains(body, "return *p;");
    try expectNotContains(body, "mc_race_");
}

test "lower-c pointer-shaped pointee derefs lower through relaxed atomics" {
    // Pointer-shaped pointees have no mc_race helper; the race-tolerant form is
    // a relaxed __atomic_load_n/__atomic_store_n, mirroring pointer-typed
    // global accesses.
    const source =
        \\global slot: u32;
        \\
        \\fn read_pp(pp: *mut *mut u32) -> *mut u32 {
        \\    return pp.*;
        \\}
        \\
        \\fn write_pp(pp: *mut *mut u32) -> void {
        \\    pp.* = &slot;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_pointer_pointee_deref.mc", source, &output);
    const read_body = try cFunctionBody(output.items, "static uint32_t * read_pp(uint32_t * * pp)");
    try expectContains(read_body, "__atomic_load_n(pp, __ATOMIC_RELAXED)");
    const write_body = try cFunctionBody(output.items, "static void write_pp(uint32_t * * pp)");
    try expectContains(write_body, "__atomic_store_n(pp, ");
    try expectContains(write_body, "__ATOMIC_RELAXED);");
}

test "lower-c pointer member scalar access lowers race-tolerantly" {
    const source =
        \\struct SharedPair {
        \\    value: u32,
        \\}
        \\
        \\extern "C" fn external_pair() -> *mut SharedPair;
        \\
        \\fn pointer_member_load(p: *mut SharedPair) -> u32 {
        \\    return p.value;
        \\}
        \\
        \\fn pointer_member_store(p: *mut SharedPair, x: u32) -> void {
        \\    p.value = x;
        \\}
        \\
        \\fn call_pointer_member_load() -> u32 {
        \\    return external_pair().value;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_pointer_member_access.mc", source, &output);
    const load_body = try cFunctionBody(output.items, "static uint32_t pointer_member_load(SharedPair * p)");
    try expectContains(load_body, "return ((uint32_t)mc_race_load_u32(&(p->value)));");
    const store_body = try cFunctionBody(output.items, "static void pointer_member_store(SharedPair * p, uint32_t x)");
    try expectContains(store_body, "mc_race_store_u32(&(p->value), (uint32_t)x);");
    const call_load_body = try cFunctionBody(output.items, "static uint32_t call_pointer_member_load(void)");
    try expectContains(call_load_body, "return ((uint32_t)mc_race_load_u32(&(external_pair()->value)));");
}

test "lower-c nested pointer member scalar access lowers race-tolerantly" {
    const source =
        \\struct Inner {
        \\    value: u32,
        \\}
        \\struct Outer {
        \\    inner: Inner,
        \\}
        \\
        \\extern "C" fn external_outer() -> *mut Outer;
        \\
        \\fn nested_pointer_member_load(p: *mut Outer) -> u32 {
        \\    return p.inner.value;
        \\}
        \\
        \\fn nested_pointer_member_store(p: *mut Outer, x: u32) -> void {
        \\    p.inner.value = x;
        \\}
        \\
        \\fn call_nested_pointer_member_load() -> u32 {
        \\    return external_outer().inner.value;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_nested_pointer_member_access.mc", source, &output);
    const load_body = try cFunctionBody(output.items, "static uint32_t nested_pointer_member_load(Outer * p)");
    try expectContains(load_body, "return ((uint32_t)mc_race_load_u32(&(p->inner.value)));");
    const store_body = try cFunctionBody(output.items, "static void nested_pointer_member_store(Outer * p, uint32_t x)");
    try expectContains(store_body, "uint32_t mc_tmp");
    try expectContains(store_body, "mc_race_store_u32(&(p->inner.value), (uint32_t)mc_tmp");
    const call_load_body = try cFunctionBody(output.items, "static uint32_t call_nested_pointer_member_load(void)");
    try expectContains(call_load_body, "return ((uint32_t)mc_race_load_u32(&(external_outer()->inner.value)));");
}

test "lower-c pointer member aggregate value copies lower field-wise race-tolerantly" {
    const load_source =
        \\struct Inner {
        \\    value: u32,
        \\}
        \\struct Outer {
        \\    inner: Inner,
        \\}
        \\
        \\fn pointer_member_aggregate_load(p: *mut Outer) -> Inner {
        \\    return p.inner;
        \\}
    ;
    var load_output: std.ArrayList(u8) = .empty;
    defer load_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_pointer_member_aggregate_load.mc", load_source, &load_output);
    const load_body = try cFunctionBody(load_output.items, "static Inner pointer_member_aggregate_load(Outer * p)");
    try expectContains(load_body, "Outer * mc_ptr");
    try expectContains(load_body, "return ({");
    try expectContains(load_body, "mc_race_load_u32");

    const init_source =
        \\struct Inner {
        \\    value: u32,
        \\}
        \\struct Outer {
        \\    inner: Inner,
        \\}
        \\
        \\fn pointer_member_aggregate_init(p: *mut Outer) -> u32 {
        \\    let inner: Inner = p.inner;
        \\    return inner.value;
        \\}
    ;
    var init_output: std.ArrayList(u8) = .empty;
    defer init_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_pointer_member_aggregate_init.mc", init_source, &init_output);
    const init_body = try cFunctionBody(init_output.items, "static uint32_t pointer_member_aggregate_init(Outer * p)");
    try expectContains(init_body, "Inner inner = ({");
    try expectContains(init_body, "mc_race_load_u32");
    try expectContains(init_body, "return inner.value;");

    const store_source =
        \\struct Inner {
        \\    value: u32,
        \\}
        \\struct Outer {
        \\    inner: Inner,
        \\}
        \\
        \\fn pointer_member_aggregate_store(p: *mut Outer, value: Inner) -> void {
        \\    p.inner = value;
        \\}
    ;
    var store_output: std.ArrayList(u8) = .empty;
    defer store_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_pointer_member_aggregate_store.mc", store_source, &store_output);
    const store_body = try cFunctionBody(store_output.items, "static void pointer_member_aggregate_store(Outer * p, Inner value)");
    try expectContains(store_body, "Outer * mc_ptr");
    try expectContains(store_body, "Inner mc_value");
    try expectContains(store_body, "mc_race_store_u32");

    const call_source =
        \\struct Inner {
        \\    value: u32,
        \\}
        \\struct Outer {
        \\    inner: Inner,
        \\}
        \\
        \\extern "C" fn external_outer() -> *mut Outer;
        \\
        \\fn call_pointer_member_aggregate_load() -> Inner {
        \\    return external_outer().inner;
        \\}
        \\
        \\fn call_pointer_member_aggregate_store(value: Inner) -> void {
        \\    external_outer().inner = value;
        \\}
    ;
    var call_output: std.ArrayList(u8) = .empty;
    defer call_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_call_pointer_member_aggregate.mc", call_source, &call_output);
    const call_load_body = try cFunctionBody(call_output.items, "static Inner call_pointer_member_aggregate_load(void)");
    try expectContains(call_load_body, "Outer * mc_ptr");
    try expectContains(call_load_body, "external_outer()");
    try expectContains(call_load_body, "mc_race_load_u32");
    const call_store_body = try cFunctionBody(call_output.items, "static void call_pointer_member_aggregate_store(Inner value)");
    try expectContains(call_store_body, "Outer * mc_ptr");
    try expectContains(call_store_body, "external_outer()");
    try expectContains(call_store_body, "Inner mc_value");
    try expectContains(call_store_body, "mc_race_store_u32");

    const nested_source =
        \\struct Leaf {
        \\    value: u32,
        \\}
        \\struct Middle {
        \\    leaf: Leaf,
        \\}
        \\struct Outer {
        \\    middle: Middle,
        \\}
        \\
        \\fn nested_pointer_member_aggregate_load(p: *mut Outer) -> Leaf {
        \\    return p.middle.leaf;
        \\}
        \\
        \\fn nested_pointer_member_aggregate_init(p: *mut Outer) -> u32 {
        \\    let leaf: Leaf = p.middle.leaf;
        \\    return leaf.value;
        \\}
        \\
        \\fn nested_pointer_member_aggregate_store(p: *mut Outer, value: Leaf) -> void {
        \\    p.middle.leaf = value;
        \\}
    ;
    var nested_output: std.ArrayList(u8) = .empty;
    defer nested_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_nested_pointer_member_aggregate.mc", nested_source, &nested_output);
    const nested_load_body = try cFunctionBody(nested_output.items, "static Leaf nested_pointer_member_aggregate_load(Outer * p)");
    try expectContains(nested_load_body, "Outer * mc_ptr");
    try expectContains(nested_load_body, "mc_race_load_u32");
    const nested_init_body = try cFunctionBody(nested_output.items, "static uint32_t nested_pointer_member_aggregate_init(Outer * p)");
    try expectContains(nested_init_body, "Leaf leaf = ({");
    try expectContains(nested_init_body, "mc_race_load_u32");
    const nested_store_body = try cFunctionBody(nested_output.items, "static void nested_pointer_member_aggregate_store(Outer * p, Leaf value)");
    try expectContains(nested_store_body, "Outer * mc_ptr");
    try expectContains(nested_store_body, "Leaf mc_value");
    try expectContains(nested_store_body, "mc_race_store_u32");

    const nested_call_source =
        \\struct Leaf {
        \\    value: u32,
        \\}
        \\struct Middle {
        \\    leaf: Leaf,
        \\}
        \\struct Outer {
        \\    middle: Middle,
        \\}
        \\
        \\extern "C" fn external_nested_outer() -> *mut Outer;
        \\
        \\fn call_nested_pointer_member_aggregate_load() -> Leaf {
        \\    return external_nested_outer().middle.leaf;
        \\}
        \\
        \\fn call_nested_pointer_member_aggregate_store(value: Leaf) -> void {
        \\    external_nested_outer().middle.leaf = value;
        \\}
    ;
    var nested_call_output: std.ArrayList(u8) = .empty;
    defer nested_call_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_call_nested_pointer_member_aggregate.mc", nested_call_source, &nested_call_output);
    const nested_call_load_body = try cFunctionBody(nested_call_output.items, "static Leaf call_nested_pointer_member_aggregate_load(void)");
    try expectContains(nested_call_load_body, "Outer * mc_ptr");
    try expectContains(nested_call_load_body, "external_nested_outer()");
    try expectContains(nested_call_load_body, "mc_race_load_u32");
    const nested_call_store_body = try cFunctionBody(nested_call_output.items, "static void call_nested_pointer_member_aggregate_store(Leaf value)");
    try expectContains(nested_call_store_body, "Outer * mc_ptr");
    try expectContains(nested_call_store_body, "external_nested_outer()");
    try expectContains(nested_call_store_body, "Leaf mc_value");
    try expectContains(nested_call_store_body, "mc_race_store_u32");

    const local_source =
        \\struct Inner {
        \\    value: u32,
        \\}
        \\struct Middle {
        \\    inner: Inner,
        \\}
        \\struct Outer {
        \\    middle: Middle,
        \\}
        \\
        \\fn local_pointer_member_aggregate_load() -> Inner {
        \\    var outer: Outer = .{ .middle = .{ .inner = .{ .value = 1 } } };
        \\    let p: *mut Outer = &outer;
        \\    return p.middle.inner;
        \\}
        \\
        \\fn local_pointer_member_aggregate_copy_stays_plain() -> u32 {
        \\    var outer: Outer = .{ .middle = .{ .inner = .{ .value = 1 } } };
        \\    let p: *mut Outer = &outer;
        \\    let replacement: Inner = .{ .value = 2 };
        \\    p.middle.inner = replacement;
        \\    let inner: Inner = p.middle.inner;
        \\    return inner.value;
        \\}
    ;
    var local_output: std.ArrayList(u8) = .empty;
    defer local_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_local_pointer_member_aggregate_load.mc", local_source, &local_output);
    const local_body = try cFunctionBody(local_output.items, "static Inner local_pointer_member_aggregate_load(void)");
    try expectContains(local_body, "return p->middle.inner;");
    const local_copy_body = try cFunctionBody(local_output.items, "static uint32_t local_pointer_member_aggregate_copy_stays_plain(void)");
    try expectContains(local_copy_body, "/* mir pointer_provenance consumed fn=local_pointer_member_aggregate_copy_stays_plain subject=p provenance=local_storage reason=none source=");
    try expectContains(local_copy_body, "p->middle.inner = replacement;");
    try expectContains(local_copy_body, "Inner inner = p->middle.inner;");
    try expectNotContains(local_copy_body, "mc_race_");
}

test "lower-c aggregate pointer deref value copies lower field-wise race-tolerantly" {
    const load_source =
        \\struct Cell {
        \\    value: u32,
        \\}
        \\
        \\fn pointer_aggregate_load(p: *mut Cell) -> Cell {
        \\    return p.*;
        \\}
    ;
    var load_output: std.ArrayList(u8) = .empty;
    defer load_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_pointer_aggregate_load.mc", load_source, &load_output);
    const load_body = try cFunctionBody(load_output.items, "static Cell pointer_aggregate_load(Cell * p)");
    try expectContains(load_body, "Cell * mc_ptr");
    try expectContains(load_body, "return ({");
    try expectContains(load_body, "mc_race_load_u32");

    const init_source =
        \\struct Cell {
        \\    value: u32,
        \\}
        \\
        \\fn pointer_aggregate_init(p: *mut Cell) -> u32 {
        \\    let cell: Cell = p.*;
        \\    return cell.value;
        \\}
    ;
    var init_output: std.ArrayList(u8) = .empty;
    defer init_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_pointer_aggregate_init.mc", init_source, &init_output);
    const init_body = try cFunctionBody(init_output.items, "static uint32_t pointer_aggregate_init(Cell * p)");
    try expectContains(init_body, "Cell cell = ({");
    try expectContains(init_body, "mc_race_load_u32");
    try expectContains(init_body, "return cell.value;");

    const store_source =
        \\struct Cell {
        \\    value: u32,
        \\}
        \\
        \\fn pointer_aggregate_store(p: *mut Cell, value: Cell) -> void {
        \\    p.* = value;
        \\}
    ;
    var store_output: std.ArrayList(u8) = .empty;
    defer store_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_pointer_aggregate_store.mc", store_source, &store_output);
    const store_body = try cFunctionBody(store_output.items, "static void pointer_aggregate_store(Cell * p, Cell value)");
    try expectContains(store_body, "Cell * mc_ptr");
    try expectContains(store_body, "Cell mc_value");
    try expectContains(store_body, "mc_race_store_u32");

    const raw_many_load_source =
        \\struct Cell {
        \\    value: u32,
        \\}
        \\
        \\fn raw_many_aggregate_load(p: [*]mut Cell, i: usize) -> Cell {
        \\    unsafe {
        \\        return p.offset(i).*;
        \\    }
        \\}
    ;
    var raw_many_load_output: std.ArrayList(u8) = .empty;
    defer raw_many_load_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_raw_many_aggregate_load.mc", raw_many_load_source, &raw_many_load_output);
    const raw_many_load_body = try cFunctionBody(raw_many_load_output.items, "static Cell raw_many_aggregate_load(Cell * p, uintptr_t i)");
    try expectContains(raw_many_load_body, "Cell * mc_ptr");
    try expectContains(raw_many_load_body, "mc_race_load_u32");
    try expectNotContains(raw_many_load_body, "return *");

    const raw_many_store_source =
        \\struct Cell {
        \\    value: u32,
        \\}
        \\
        \\fn raw_many_aggregate_store(p: [*]mut Cell, i: usize, value: Cell) -> void {
        \\    unsafe {
        \\        p.offset(i).* = value;
        \\    }
        \\}
    ;
    var raw_many_store_output: std.ArrayList(u8) = .empty;
    defer raw_many_store_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_raw_many_aggregate_store.mc", raw_many_store_source, &raw_many_store_output);
    const raw_many_store_body = try cFunctionBody(raw_many_store_output.items, "static void raw_many_aggregate_store(Cell * p, uintptr_t i, Cell value)");
    try expectContains(raw_many_store_body, "Cell * mc_ptr");
    try expectContains(raw_many_store_body, "Cell mc_value");
    try expectContains(raw_many_store_body, "mc_race_store_u32");

    const call_raw_many_source =
        \\struct Cell {
        \\    value: u32,
        \\}
        \\
        \\extern fn external_cells() -> [*]mut Cell;
        \\
        \\fn call_raw_many_aggregate_load(i: usize) -> Cell {
        \\    unsafe {
        \\        return external_cells().offset(i).*;
        \\    }
        \\}
        \\
        \\fn call_raw_many_aggregate_store(i: usize, value: Cell) -> void {
        \\    unsafe {
        \\        external_cells().offset(i).* = value;
        \\    }
        \\}
    ;
    var call_raw_many_output: std.ArrayList(u8) = .empty;
    defer call_raw_many_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_call_raw_many_aggregate.mc", call_raw_many_source, &call_raw_many_output);
    const call_raw_many_load_body = try cFunctionBody(call_raw_many_output.items, "static Cell call_raw_many_aggregate_load(uintptr_t i)");
    try expectContains(call_raw_many_load_body, "Cell * mc_tmp");
    try expectContains(call_raw_many_load_body, "external_cells()");
    try expectNotContains(call_raw_many_load_body, "return *");

    const call_raw_many_store_body = try cFunctionBody(call_raw_many_output.items, "static void call_raw_many_aggregate_store(uintptr_t i, Cell value)");
    try expectContains(call_raw_many_store_body, "Cell * mc_ptr");
    try expectContains(call_raw_many_store_body, "external_cells()");
    try expectContains(call_raw_many_store_body, "Cell mc_value");
    try expectContains(call_raw_many_store_body, "mc_race_store_u32");

    const local_source =
        \\struct Cell {
        \\    value: u32,
        \\}
        \\
        \\fn local_pointer_aggregate_load() -> Cell {
        \\    var cell: Cell = .{ .value = 1 };
        \\    let p: *mut Cell = &cell;
        \\    return p.*;
        \\}
    ;
    var local_output: std.ArrayList(u8) = .empty;
    defer local_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_local_pointer_aggregate_load.mc", local_source, &local_output);
    const local_body = try cFunctionBody(local_output.items, "static Cell local_pointer_aggregate_load(void)");
    try expectContains(local_body, "return *p;");

    const local_raw_many_source =
        \\struct Cell {
        \\    value: u32,
        \\}
        \\
        \\fn local_raw_many_zero_aggregate_load() -> Cell {
        \\    unsafe {
        \\        var cell: Cell = .{ .value = 1 };
        \\        let p: [*]mut Cell = (&cell) as [*]mut Cell;
        \\        let q: [*]mut Cell = p.offset(0);
        \\        return q.*;
        \\    }
        \\}
    ;
    var local_raw_many_output: std.ArrayList(u8) = .empty;
    defer local_raw_many_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_local_raw_many_zero_aggregate_load.mc", local_raw_many_source, &local_raw_many_output);
    const local_raw_many_body = try cFunctionBody(local_raw_many_output.items, "static Cell local_raw_many_zero_aggregate_load(void)");
    try expectContains(local_raw_many_body, "/* mir pointer_provenance consumed fn=local_raw_many_zero_aggregate_load subject=p provenance=local_storage reason=none");
    try expectContains(local_raw_many_body, "/* mir pointer_provenance consumed fn=local_raw_many_zero_aggregate_load subject=q provenance=local_storage reason=none");
    try expectContains(local_raw_many_body, "return *q;");
    try expectNotContains(local_raw_many_body, "mc_race_");

    const local_raw_many_store_source =
        \\struct Cell {
        \\    value: u32,
        \\}
        \\
        \\fn local_raw_many_zero_aggregate_store(value: Cell) -> Cell {
        \\    unsafe {
        \\        var cell: Cell = .{ .value = 1 };
        \\        let p: [*]mut Cell = (&cell) as [*]mut Cell;
        \\        let q: [*]mut Cell = p.offset(0);
        \\        q.* = value;
        \\        return cell;
        \\    }
        \\}
    ;
    var local_raw_many_store_output: std.ArrayList(u8) = .empty;
    defer local_raw_many_store_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_local_raw_many_zero_aggregate_store.mc", local_raw_many_store_source, &local_raw_many_store_output);
    const local_raw_many_store_body = try cFunctionBody(local_raw_many_store_output.items, "static Cell local_raw_many_zero_aggregate_store(Cell value)");
    try expectContains(local_raw_many_store_body, "/* mir pointer_provenance consumed fn=local_raw_many_zero_aggregate_store subject=p provenance=local_storage reason=none");
    try expectContains(local_raw_many_store_body, "/* mir pointer_provenance consumed fn=local_raw_many_zero_aggregate_store subject=q provenance=local_storage reason=none");
    try expectContains(local_raw_many_store_body, "*q = value;");
    try expectNotContains(local_raw_many_store_body, "mc_race_");
}

test "lower-c union aggregate pointer deref value copies fail closed" {
    const overlay_load_source =
        \\overlay union Word {
        \\    value: u32,
        \\    bytes: [4]u8,
        \\}
        \\
        \\fn pointer_union_load(p: *mut Word) -> Word {
        \\    return p.*;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_pointer_union_load.mc", overlay_load_source);
    try expectUnsupportedCheckedCEmissionDiagnostic("emit_c_pointer_union_load_diagnostic.mc", overlay_load_source, "deref");

    const overlay_store_source =
        \\overlay union Word {
        \\    value: u32,
        \\    bytes: [4]u8,
        \\}
        \\
        \\fn pointer_union_store(p: *mut Word, value: Word) -> void {
        \\    p.* = value;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_pointer_union_store.mc", overlay_store_source);

    const c_union_load_source =
        \\#[c_union]
        \\struct CWord {
        \\    value: u32,
        \\    flag: bool,
        \\}
        \\
        \\fn pointer_c_union_load(p: *mut CWord) -> CWord {
        \\    return p.*;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_pointer_c_union_load.mc", c_union_load_source);

    const c_union_store_source =
        \\#[c_union]
        \\struct CWord {
        \\    value: u32,
        \\    flag: bool,
        \\}
        \\
        \\fn pointer_c_union_store(p: *mut CWord, value: CWord) -> void {
        \\    p.* = value;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_pointer_c_union_store.mc", c_union_store_source);

    const overlay_raw_many_load_source =
        \\overlay union Word {
        \\    value: u32,
        \\    bytes: [4]u8,
        \\}
        \\
        \\fn raw_many_union_load(p: [*]mut Word, i: usize) -> Word {
        \\    unsafe {
        \\        return p.offset(i).*;
        \\    }
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_raw_many_union_load.mc", overlay_raw_many_load_source);

    const overlay_raw_many_store_source =
        \\overlay union Word {
        \\    value: u32,
        \\    bytes: [4]u8,
        \\}
        \\
        \\fn raw_many_union_store(p: [*]mut Word, i: usize, value: Word) -> void {
        \\    unsafe {
        \\        p.offset(i).* = value;
        \\    }
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_raw_many_union_store.mc", overlay_raw_many_store_source);

    const c_union_raw_many_load_source =
        \\#[c_union]
        \\struct CWord {
        \\    value: u32,
        \\    flag: bool,
        \\}
        \\
        \\fn raw_many_c_union_load(p: [*]mut CWord, i: usize) -> CWord {
        \\    unsafe {
        \\        return p.offset(i).*;
        \\    }
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_raw_many_c_union_load.mc", c_union_raw_many_load_source);

    const c_union_raw_many_store_source =
        \\#[c_union]
        \\struct CWord {
        \\    value: u32,
        \\    flag: bool,
        \\}
        \\
        \\fn raw_many_c_union_store(p: [*]mut CWord, i: usize, value: CWord) -> void {
        \\    unsafe {
        \\        p.offset(i).* = value;
        \\    }
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_raw_many_c_union_store.mc", c_union_raw_many_store_source);

    const tagged_load_source =
        \\union Token {
        \\    number: u32,
        \\    eof,
        \\}
        \\
        \\fn pointer_tagged_union_load(p: *mut Token) -> Token {
        \\    return p.*;
        \\}
    ;
    try expectTaggedUnionRaceCopySupported("emit_c_pointer_tagged_union_load.mc", tagged_load_source);

    const tagged_store_source =
        \\union Token {
        \\    number: u32,
        \\    eof,
        \\}
        \\
        \\fn pointer_tagged_union_store(p: *mut Token, value: Token) -> void {
        \\    p.* = value;
        \\}
    ;
    try expectTaggedUnionRaceCopySupported("emit_c_pointer_tagged_union_store.mc", tagged_store_source);

    const tagged_raw_many_load_source =
        \\union Token {
        \\    number: u32,
        \\    eof,
        \\}
        \\
        \\fn raw_many_tagged_union_load(p: [*]mut Token, i: usize) -> Token {
        \\    unsafe {
        \\        return p.offset(i).*;
        \\    }
        \\}
    ;
    try expectTaggedUnionRaceCopySupported("emit_c_raw_many_tagged_union_load.mc", tagged_raw_many_load_source);

    const tagged_raw_many_store_source =
        \\union Token {
        \\    number: u32,
        \\    eof,
        \\}
        \\
        \\fn raw_many_tagged_union_store(p: [*]mut Token, i: usize, value: Token) -> void {
        \\    unsafe {
        \\        p.offset(i).* = value;
        \\    }
        \\}
    ;
    try expectTaggedUnionRaceCopySupported("emit_c_raw_many_tagged_union_store.mc", tagged_raw_many_store_source);

    const nested_overlay_load_source =
        \\overlay union Word {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\struct Holder {
        \\    word: Word,
        \\}
        \\
        \\fn pointer_nested_union_load(p: *mut Holder) -> Holder {
        \\    return p.*;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_pointer_nested_union_load.mc", nested_overlay_load_source);

    const nested_overlay_store_source =
        \\overlay union Word {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\struct Holder {
        \\    word: Word,
        \\}
        \\
        \\fn pointer_nested_union_store(p: *mut Holder, value: Holder) -> void {
        \\    p.* = value;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_pointer_nested_union_store.mc", nested_overlay_store_source);

    const nested_c_union_load_source =
        \\#[c_union]
        \\struct CWord {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\struct Holder {
        \\    word: CWord,
        \\}
        \\
        \\fn pointer_nested_c_union_load(p: *mut Holder) -> Holder {
        \\    return p.*;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_pointer_nested_c_union_load.mc", nested_c_union_load_source);

    const nested_c_union_store_source =
        \\#[c_union]
        \\struct CWord {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\struct Holder {
        \\    word: CWord,
        \\}
        \\
        \\fn pointer_nested_c_union_store(p: *mut Holder, value: Holder) -> void {
        \\    p.* = value;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_pointer_nested_c_union_store.mc", nested_c_union_store_source);

    const nested_tagged_load_source =
        \\union Token {
        \\    number: u32,
        \\    eof,
        \\}
        \\struct Holder {
        \\    token: Token,
        \\}
        \\
        \\fn pointer_nested_tagged_union_load(p: *mut Holder) -> Holder {
        \\    return p.*;
        \\}
    ;
    try expectTaggedUnionRaceCopySupported("emit_c_pointer_nested_tagged_union_load.mc", nested_tagged_load_source);

    const nested_tagged_store_source =
        \\union Token {
        \\    number: u32,
        \\    eof,
        \\}
        \\struct Holder {
        \\    token: Token,
        \\}
        \\
        \\fn pointer_nested_tagged_union_store(p: *mut Holder, value: Holder) -> void {
        \\    p.* = value;
        \\}
    ;
    try expectTaggedUnionRaceCopySupported("emit_c_pointer_nested_tagged_union_store.mc", nested_tagged_store_source);
}

test "lower-c union pointer-member aggregate value copies fail closed" {
    const overlay_member_load_source =
        \\overlay union Word {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\struct Holder {
        \\    word: Word,
        \\}
        \\fn pointer_union_member_load(p: *mut Holder) -> Word {
        \\    return p.word;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_pointer_union_member_load.mc", overlay_member_load_source);

    const overlay_member_store_source =
        \\overlay union Word {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\struct Holder {
        \\    word: Word,
        \\}
        \\fn pointer_union_member_store(p: *mut Holder, value: Word) -> void {
        \\    p.word = value;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_pointer_union_member_store.mc", overlay_member_store_source);

    const c_union_member_load_source =
        \\#[c_union]
        \\struct CWord {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\struct Holder {
        \\    word: CWord,
        \\}
        \\fn pointer_c_union_member_load(p: *mut Holder) -> CWord {
        \\    return p.word;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_pointer_c_union_member_load.mc", c_union_member_load_source);

    const c_union_member_store_source =
        \\#[c_union]
        \\struct CWord {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\struct Holder {
        \\    word: CWord,
        \\}
        \\fn pointer_c_union_member_store(p: *mut Holder, value: CWord) -> void {
        \\    p.word = value;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_pointer_c_union_member_store.mc", c_union_member_store_source);

    const nested_overlay_member_load_source =
        \\overlay union Word {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\struct Middle {
        \\    word: Word,
        \\}
        \\struct Holder {
        \\    middle: Middle,
        \\}
        \\fn pointer_nested_union_member_load(p: *mut Holder) -> Word {
        \\    return p.middle.word;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_pointer_nested_union_member_load.mc", nested_overlay_member_load_source);

    const nested_overlay_member_store_source =
        \\overlay union Word {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\struct Middle {
        \\    word: Word,
        \\}
        \\struct Holder {
        \\    middle: Middle,
        \\}
        \\fn pointer_nested_union_member_store(p: *mut Holder, value: Word) -> void {
        \\    p.middle.word = value;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_pointer_nested_union_member_store.mc", nested_overlay_member_store_source);

    const nested_c_union_member_load_source =
        \\#[c_union]
        \\struct CWord {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\struct Middle {
        \\    word: CWord,
        \\}
        \\struct Holder {
        \\    middle: Middle,
        \\}
        \\fn pointer_nested_c_union_member_load(p: *mut Holder) -> CWord {
        \\    return p.middle.word;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_pointer_nested_c_union_member_load.mc", nested_c_union_member_load_source);

    const nested_c_union_member_store_source =
        \\#[c_union]
        \\struct CWord {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\struct Middle {
        \\    word: CWord,
        \\}
        \\struct Holder {
        \\    middle: Middle,
        \\}
        \\fn pointer_nested_c_union_member_store(p: *mut Holder, value: CWord) -> void {
        \\    p.middle.word = value;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_pointer_nested_c_union_member_store.mc", nested_c_union_member_store_source);

    const tagged_member_load_source =
        \\union Token {
        \\    number: u32,
        \\    eof,
        \\}
        \\struct Holder {
        \\    token: Token,
        \\}
        \\fn pointer_tagged_union_member_load(p: *mut Holder) -> Token {
        \\    return p.token;
        \\}
    ;
    try expectTaggedUnionRaceCopySupported("emit_c_pointer_tagged_union_member_load.mc", tagged_member_load_source);

    const tagged_member_store_source =
        \\union Token {
        \\    number: u32,
        \\    eof,
        \\}
        \\struct Holder {
        \\    token: Token,
        \\}
        \\fn pointer_tagged_union_member_store(p: *mut Holder, value: Token) -> void {
        \\    p.token = value;
        \\}
    ;
    try expectTaggedUnionRaceCopySupported("emit_c_pointer_tagged_union_member_store.mc", tagged_member_store_source);

    const nested_tagged_member_load_source =
        \\union Token {
        \\    number: u32,
        \\    eof,
        \\}
        \\struct Middle {
        \\    token: Token,
        \\}
        \\struct Holder {
        \\    middle: Middle,
        \\}
        \\fn pointer_nested_tagged_union_member_load(p: *mut Holder) -> Token {
        \\    return p.middle.token;
        \\}
    ;
    try expectTaggedUnionRaceCopySupported("emit_c_pointer_nested_tagged_union_member_load.mc", nested_tagged_member_load_source);

    const nested_tagged_member_store_source =
        \\union Token {
        \\    number: u32,
        \\    eof,
        \\}
        \\struct Middle {
        \\    token: Token,
        \\}
        \\struct Holder {
        \\    middle: Middle,
        \\}
        \\fn pointer_nested_tagged_union_member_store(p: *mut Holder, value: Token) -> void {
        \\    p.middle.token = value;
        \\}
    ;
    try expectTaggedUnionRaceCopySupported("emit_c_pointer_nested_tagged_union_member_store.mc", nested_tagged_member_store_source);
}

test "lower-c nested aggregate pointer deref value copies lower recursively" {
    const load_source =
        \\struct Inner {
        \\    value: u32,
        \\}
        \\struct Outer {
        \\    inner: Inner,
        \\}
        \\
        \\fn pointer_nested_aggregate_load(p: *mut Outer) -> Outer {
        \\    return p.*;
        \\}
    ;
    var load_output: std.ArrayList(u8) = .empty;
    defer load_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_pointer_nested_aggregate_load.mc", load_source, &load_output);
    const load_body = try cFunctionBody(load_output.items, "static Outer pointer_nested_aggregate_load(Outer * p)");
    try expectContains(load_body, "mc_race_load_u32");

    const store_source =
        \\struct Inner {
        \\    value: u32,
        \\}
        \\struct Outer {
        \\    inner: Inner,
        \\}
        \\
        \\fn pointer_nested_aggregate_store(p: *mut Outer, value: Outer) -> void {
        \\    p.* = value;
        \\}
    ;
    var store_output: std.ArrayList(u8) = .empty;
    defer store_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_pointer_nested_aggregate_store.mc", store_source, &store_output);
    const store_body = try cFunctionBody(store_output.items, "static void pointer_nested_aggregate_store(Outer * p, Outer value)");
    try expectContains(store_body, "mc_race_store_u32");
    try expectContains(store_body, ".inner.value);");

    const call_raw_many_source =
        \\struct Inner {
        \\    value: u32,
        \\}
        \\struct Outer {
        \\    inner: Inner,
        \\}
        \\
        \\extern fn external_outers() -> [*]mut Outer;
        \\
        \\fn call_raw_many_nested_aggregate_load(i: usize) -> Outer {
        \\    unsafe {
        \\        return external_outers().offset(i).*;
        \\    }
        \\}
        \\
        \\fn call_raw_many_nested_aggregate_store(i: usize, value: Outer) -> void {
        \\    unsafe {
        \\        external_outers().offset(i).* = value;
        \\    }
        \\}
    ;
    var call_raw_many_output: std.ArrayList(u8) = .empty;
    defer call_raw_many_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_call_raw_many_nested_aggregate.mc", call_raw_many_source, &call_raw_many_output);
    const call_raw_many_load_body = try cFunctionBody(call_raw_many_output.items, "static Outer call_raw_many_nested_aggregate_load(uintptr_t i)");
    try expectContains(call_raw_many_load_body, "Outer * mc_tmp");
    try expectContains(call_raw_many_load_body, "external_outers()");
    try expectNotContains(call_raw_many_load_body, "return *");

    const call_raw_many_store_body = try cFunctionBody(call_raw_many_output.items, "static void call_raw_many_nested_aggregate_store(uintptr_t i, Outer value)");
    try expectContains(call_raw_many_store_body, "Outer * mc_ptr");
    try expectContains(call_raw_many_store_body, "external_outers()");
    try expectContains(call_raw_many_store_body, "mc_race_store_u32");
    try expectContains(call_raw_many_store_body, ".inner.value);");
}

test "lower-c fixed-array aggregate pointer deref value copies lower recursively" {
    const load_source =
        \\struct WithArray {
        \\    values: [2]u32,
        \\}
        \\
        \\fn pointer_array_aggregate_load(p: *mut WithArray) -> WithArray {
        \\    return p.*;
        \\}
    ;
    var load_output: std.ArrayList(u8) = .empty;
    defer load_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_pointer_array_aggregate_load.mc", load_source, &load_output);
    const load_body = try cFunctionBody(load_output.items, "static WithArray pointer_array_aggregate_load(WithArray * p)");
    try expectContains(load_body, "mc_race_load_u32");

    const store_source =
        \\struct WithArray {
        \\    values: [2]u32,
        \\}
        \\
        \\fn pointer_array_aggregate_store(p: *mut WithArray, value: WithArray) -> void {
        \\    p.* = value;
        \\}
    ;
    var store_output: std.ArrayList(u8) = .empty;
    defer store_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_pointer_array_aggregate_store.mc", store_source, &store_output);
    const store_body = try cFunctionBody(store_output.items, "static void pointer_array_aggregate_store(WithArray * p, WithArray value)");
    try expectContains(store_body, "mc_race_store_u32");

    const call_raw_many_source =
        \\struct WithArray {
        \\    values: [2]u32,
        \\}
        \\
        \\extern fn external_arrays() -> [*]mut WithArray;
        \\
        \\fn call_raw_many_array_aggregate_load(i: usize) -> WithArray {
        \\    unsafe {
        \\        return external_arrays().offset(i).*;
        \\    }
        \\}
        \\
        \\fn call_raw_many_array_aggregate_store(i: usize, value: WithArray) -> void {
        \\    unsafe {
        \\        external_arrays().offset(i).* = value;
        \\    }
        \\}
    ;
    var call_raw_many_output: std.ArrayList(u8) = .empty;
    defer call_raw_many_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_call_raw_many_array_aggregate.mc", call_raw_many_source, &call_raw_many_output);
    const call_raw_many_load_body = try cFunctionBody(call_raw_many_output.items, "static WithArray call_raw_many_array_aggregate_load(uintptr_t i)");
    try expectContains(call_raw_many_load_body, "WithArray * mc_tmp");
    try expectContains(call_raw_many_load_body, "external_arrays()");
    try expectNotContains(call_raw_many_load_body, "return *");

    const call_raw_many_store_body = try cFunctionBody(call_raw_many_output.items, "static void call_raw_many_array_aggregate_store(uintptr_t i, WithArray value)");
    try expectContains(call_raw_many_store_body, "WithArray * mc_ptr");
    try expectContains(call_raw_many_store_body, "external_arrays()");
    try expectContains(call_raw_many_store_body, "mc_race_store_u32");

    const local_source =
        \\struct WithArray {
        \\    values: [2]u32,
        \\}
        \\
        \\fn local_pointer_array_aggregate_copy() -> u32 {
        \\    var cell: WithArray = .{ .values = .{ 1, 2 } };
        \\    let p: *mut WithArray = &cell;
        \\    let replacement: WithArray = .{ .values = .{ 3, 4 } };
        \\    p.* = replacement;
        \\    let copy: WithArray = p.*;
        \\    return copy.values[1];
        \\}
    ;
    var local_output: std.ArrayList(u8) = .empty;
    defer local_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_local_pointer_array_aggregate_copy.mc", local_source, &local_output);
    const local_body = try cFunctionBody(local_output.items, "static uint32_t local_pointer_array_aggregate_copy(void)");
    try expectContains(local_body, "/* mir pointer_provenance consumed fn=local_pointer_array_aggregate_copy subject=p provenance=local_storage reason=none source=");
    try expectContains(local_body, "*p =");
    try expectContains(local_body, "WithArray copy = *p;");
    try expectNotContains(local_body, "mc_race_");

    const local_raw_many_source =
        \\struct WithArray {
        \\    values: [2]u32,
        \\}
        \\
        \\fn local_raw_many_zero_array_aggregate_copy() -> u32 {
        \\    unsafe {
        \\        var cell: WithArray = .{ .values = .{ 1, 2 } };
        \\        let p: [*]mut WithArray = (&cell) as [*]mut WithArray;
        \\        let q: [*]mut WithArray = p.offset(0);
        \\        let replacement: WithArray = .{ .values = .{ 3, 4 } };
        \\        q.* = replacement;
        \\        let copy: WithArray = q.*;
        \\        return copy.values[1];
        \\    }
        \\}
    ;
    var local_raw_many_output: std.ArrayList(u8) = .empty;
    defer local_raw_many_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_local_raw_many_zero_array_aggregate_copy.mc", local_raw_many_source, &local_raw_many_output);
    const local_raw_many_body = try cFunctionBody(local_raw_many_output.items, "static uint32_t local_raw_many_zero_array_aggregate_copy(void)");
    try expectContains(local_raw_many_body, "/* mir pointer_provenance consumed fn=local_raw_many_zero_array_aggregate_copy subject=p provenance=local_storage reason=none source=");
    try expectContains(local_raw_many_body, "/* mir pointer_provenance consumed fn=local_raw_many_zero_array_aggregate_copy subject=q provenance=local_storage reason=none source=");
    try expectContains(local_raw_many_body, "*q =");
    try expectContains(local_raw_many_body, "WithArray copy = *q;");
    try expectNotContains(local_raw_many_body, "mc_race_");
}

test "lower-c pointer-to-array scalar index access lowers race-tolerantly" {
    const source =
        \\fn pointer_array_load(pa: *mut [4]u32, i: usize) -> u32 {
        \\    return pa.*[i];
        \\}
        \\
        \\fn pointer_array_store(pa: *mut [4]u32, i: usize, value: u32) -> void {
        \\    pa.*[i] = value;
        \\}
        \\
        \\fn local_pointer_array_load(i: usize) -> u32 {
        \\    var xs: [4]u32 = .{1, 2, 3, 4};
        \\    let pa: *mut [4]u32 = &xs;
        \\    return pa.*[i];
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_pointer_array_access.mc", source, &output);
    const load_body = try cFunctionBody(output.items, "static uint32_t pointer_array_load(mc_array_u32_4 * pa, uintptr_t i)");
    try expectContains(load_body, "return ((uint32_t)mc_race_load_u32(&((*pa).elems[mc_check_index_usize(i, 4)])));");
    const store_body = try cFunctionBody(output.items, "static void pointer_array_store(mc_array_u32_4 * pa, uintptr_t i, uint32_t value)");
    try expectContains(store_body, "mc_race_store_u32(&((*pa).elems[mc_check_index_usize(");
    try expectContains(store_body, "), (uint32_t)mc_tmp");
    const local_body = try cFunctionBody(output.items, "static uint32_t local_pointer_array_load(uintptr_t i)");
    try expectContains(local_body, "return (*pa).elems[mc_check_index_usize(i, 4)];");
    try expectNotContains(local_body, "mc_race_load_u32");
}

test "lower-c indexed aggregate scalar fields lower race-tolerantly" {
    const source =
        \\struct Cell {
        \\    value: u32,
        \\}
        \\
        \\fn slice_member_load(cells: []mut Cell, i: usize) -> u32 {
        \\    return cells[i].value;
        \\}
        \\
        \\fn slice_member_store(cells: []mut Cell, i: usize, value: u32) -> void {
        \\    cells[i].value = value;
        \\}
        \\
        \\fn pointer_array_member_load(pa: *mut [4]Cell, i: usize) -> u32 {
        \\    return pa.*[i].value;
        \\}
        \\
        \\fn local_array_member_load(i: usize) -> u32 {
        \\    let cells: [4]Cell = .{
        \\        .{ .value = 1 },
        \\        .{ .value = 2 },
        \\        .{ .value = 3 },
        \\        .{ .value = 4 },
        \\    };
        \\    return cells[i].value;
        \\}
        \\
        \\fn local_array_member_store(i: usize, value: u32) -> u32 {
        \\    var cells: [4]Cell = .{
        \\        .{ .value = 1 },
        \\        .{ .value = 2 },
        \\        .{ .value = 3 },
        \\        .{ .value = 4 },
        \\    };
        \\    cells[i].value = value;
        \\    return cells[i].value;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_indexed_member_access.mc", source, &output);

    const slice_load_body = try cFunctionBody(output.items, "static uint32_t slice_member_load(mc_slice_mut_struct_Cell cells, uintptr_t i)");
    try expectContains(slice_load_body, "return ((uint32_t)mc_race_load_u32(&(cells.ptr[mc_check_index_usize(i, cells.len)].value)));");
    const slice_store_body = try cFunctionBody(output.items, "static void slice_member_store(mc_slice_mut_struct_Cell cells, uintptr_t i, uint32_t value)");
    try expectContains(slice_store_body, "mc_race_store_u32(&(cells.ptr[mc_check_index_usize(");
    try expectContains(slice_store_body, ".value), (uint32_t)mc_tmp");
    const pointer_array_body = try cFunctionBody(output.items, "static uint32_t pointer_array_member_load(mc_array_struct_Cell_4 * pa, uintptr_t i)");
    try expectContains(pointer_array_body, "return ((uint32_t)mc_race_load_u32(&((*pa).elems[mc_check_index_usize(i, 4)].value)));");
    const local_body = try cFunctionBody(output.items, "static uint32_t local_array_member_load(uintptr_t i)");
    try expectContains(local_body, "return cells.elems[mc_check_index_usize(i, 4)].value;");
    try expectNotContains(local_body, "mc_race_load_u32");
    const local_store_body = try cFunctionBody(output.items, "static uint32_t local_array_member_store(uintptr_t i, uint32_t value)");
    try expectContains(local_store_body, "cells.elems[mc_check_index_usize(");
    try expectContains(local_store_body, ".value =");
    try expectContains(local_store_body, "return cells.elems[mc_check_index_usize(i, 4)].value;");
    try expectNotContains(local_store_body, "mc_race_load_u32");
    try expectNotContains(local_store_body, "mc_race_store_u32");
}

test "lower-c indexed aggregate field value copies lower recursively" {
    const slice_load_source =
        \\struct Inner {
        \\    value: u32,
        \\}
        \\struct Cell {
        \\    inner: Inner,
        \\}
        \\
        \\fn slice_inner_load(cells: []mut Cell, i: usize) -> Inner {
        \\    return cells[i].inner;
        \\}
    ;
    var slice_load_output: std.ArrayList(u8) = .empty;
    defer slice_load_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_slice_aggregate_field_load.mc", slice_load_source, &slice_load_output);
    const slice_load_body = try cFunctionBody(slice_load_output.items, "static Inner slice_inner_load(mc_slice_mut_struct_Cell cells, uintptr_t i)");
    try expectContains(slice_load_body, "uintptr_t mc_idx");
    try expectContains(slice_load_body, "Inner * mc_ptr");
    try expectContains(slice_load_body, "cells.ptr[mc_check_index_usize(mc_idx");
    try expectContains(slice_load_body, "mc_race_load_u32");

    const slice_store_source =
        \\struct Inner {
        \\    value: u32,
        \\}
        \\struct Cell {
        \\    inner: Inner,
        \\}
        \\
        \\fn slice_inner_store(cells: []mut Cell, i: usize, value: Inner) -> void {
        \\    cells[i].inner = value;
        \\}
    ;
    var slice_store_output: std.ArrayList(u8) = .empty;
    defer slice_store_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_slice_aggregate_field_store.mc", slice_store_source, &slice_store_output);
    const slice_store_body = try cFunctionBody(slice_store_output.items, "static void slice_inner_store(mc_slice_mut_struct_Cell cells, uintptr_t i, Inner value)");
    try expectContains(slice_store_body, "Inner * mc_ptr");
    try expectContains(slice_store_body, "Inner mc_value");
    try expectContains(slice_store_body, "cells.ptr[mc_check_index_usize(");
    try expectContains(slice_store_body, "mc_race_store_u32");

    const pointer_array_load_source =
        \\struct Inner {
        \\    value: u32,
        \\}
        \\struct Cell {
        \\    inner: Inner,
        \\}
        \\
        \\fn pointer_array_inner_load(pa: *mut [4]Cell, i: usize) -> Inner {
        \\    return pa.*[i].inner;
        \\}
    ;
    var pointer_array_load_output: std.ArrayList(u8) = .empty;
    defer pointer_array_load_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_pointer_array_aggregate_field_load.mc", pointer_array_load_source, &pointer_array_load_output);
    const pointer_array_load_body = try cFunctionBody(pointer_array_load_output.items, "static Inner pointer_array_inner_load(mc_array_struct_Cell_4 * pa, uintptr_t i)");
    try expectContains(pointer_array_load_body, "Inner * mc_ptr");
    try expectContains(pointer_array_load_body, "(*pa).elems[mc_check_index_usize(mc_idx");
    try expectContains(pointer_array_load_body, "mc_race_load_u32");

    const pointer_array_store_source =
        \\struct Inner {
        \\    value: u32,
        \\}
        \\struct Cell {
        \\    inner: Inner,
        \\}
        \\
        \\fn pointer_array_inner_store(pa: *mut [4]Cell, i: usize, value: Inner) -> void {
        \\    pa.*[i].inner = value;
        \\}
    ;
    var pointer_array_store_output: std.ArrayList(u8) = .empty;
    defer pointer_array_store_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_pointer_array_aggregate_field_store.mc", pointer_array_store_source, &pointer_array_store_output);
    const pointer_array_store_body = try cFunctionBody(pointer_array_store_output.items, "static void pointer_array_inner_store(mc_array_struct_Cell_4 * pa, uintptr_t i, Inner value)");
    try expectContains(pointer_array_store_body, "Inner * mc_ptr");
    try expectContains(pointer_array_store_body, "(*pa).elems[mc_check_index_usize(");
    try expectContains(pointer_array_store_body, "mc_race_store_u32");

    const local_source =
        \\struct Inner {
        \\    value: u32,
        \\}
        \\struct Cell {
        \\    inner: Inner,
        \\}
        \\
        \\fn local_array_inner_load(i: usize) -> Inner {
        \\    let cells: [4]Cell = .{
        \\        .{ .inner = .{ .value = 1 } },
        \\        .{ .inner = .{ .value = 2 } },
        \\        .{ .inner = .{ .value = 3 } },
        \\        .{ .inner = .{ .value = 4 } },
        \\    };
        \\    return cells[i].inner;
        \\}
        \\
        \\fn local_array_inner_store(i: usize, value: Inner) -> Inner {
        \\    var cells: [4]Cell = .{
        \\        .{ .inner = .{ .value = 1 } },
        \\        .{ .inner = .{ .value = 2 } },
        \\        .{ .inner = .{ .value = 3 } },
        \\        .{ .inner = .{ .value = 4 } },
        \\    };
        \\    cells[i].inner = value;
        \\    return cells[i].inner;
        \\}
    ;
    var local_output: std.ArrayList(u8) = .empty;
    defer local_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_local_aggregate_field_load.mc", local_source, &local_output);
    const local_body = try cFunctionBody(local_output.items, "static Inner local_array_inner_load(uintptr_t i)");
    try expectContains(local_body, "return cells.elems[mc_check_index_usize(i, 4)].inner;");
    try expectNotContains(local_body, "mc_race_load_u32");
    const local_store_body = try cFunctionBody(local_output.items, "static Inner local_array_inner_store(uintptr_t i, Inner value)");
    try expectContains(local_store_body, "cells.elems[mc_check_index_usize(");
    try expectContains(local_store_body, ".inner = value;");
    try expectContains(local_store_body, "return cells.elems[mc_check_index_usize(i, 4)].inner;");
    try expectNotContains(local_store_body, "mc_race_load_u32");
    try expectNotContains(local_store_body, "mc_race_store_u32");
}

test "lower-c union indexed aggregate field value copies fail closed" {
    const overlay_load_source =
        \\overlay union Word {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\struct Cell {
        \\    word: Word,
        \\}
        \\fn slice_union_field_load(cells: []mut Cell, i: usize) -> Word {
        \\    return cells[i].word;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_slice_union_field_load.mc", overlay_load_source);

    const overlay_store_source =
        \\overlay union Word {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\struct Cell {
        \\    word: Word,
        \\}
        \\fn slice_union_field_store(cells: []mut Cell, i: usize, value: Word) -> void {
        \\    cells[i].word = value;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_slice_union_field_store.mc", overlay_store_source);

    const c_union_load_source =
        \\#[c_union]
        \\struct CWord {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\struct Cell {
        \\    word: CWord,
        \\}
        \\fn slice_c_union_field_load(cells: []mut Cell, i: usize) -> CWord {
        \\    return cells[i].word;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_slice_c_union_field_load.mc", c_union_load_source);

    const c_union_store_source =
        \\#[c_union]
        \\struct CWord {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\struct Cell {
        \\    word: CWord,
        \\}
        \\fn slice_c_union_field_store(cells: []mut Cell, i: usize, value: CWord) -> void {
        \\    cells[i].word = value;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_slice_c_union_field_store.mc", c_union_store_source);

    const nested_overlay_load_source =
        \\overlay union Word {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\struct Inner {
        \\    word: Word,
        \\}
        \\struct Cell {
        \\    inner: Inner,
        \\}
        \\fn slice_nested_union_field_load(cells: []mut Cell, i: usize) -> Word {
        \\    return cells[i].inner.word;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_slice_nested_union_field_load.mc", nested_overlay_load_source);

    const nested_overlay_store_source =
        \\overlay union Word {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\struct Inner {
        \\    word: Word,
        \\}
        \\struct Cell {
        \\    inner: Inner,
        \\}
        \\fn slice_nested_union_field_store(cells: []mut Cell, i: usize, value: Word) -> void {
        \\    cells[i].inner.word = value;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_slice_nested_union_field_store.mc", nested_overlay_store_source);

    const nested_c_union_load_source =
        \\#[c_union]
        \\struct CWord {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\struct Inner {
        \\    word: CWord,
        \\}
        \\struct Cell {
        \\    inner: Inner,
        \\}
        \\fn slice_nested_c_union_field_load(cells: []mut Cell, i: usize) -> CWord {
        \\    return cells[i].inner.word;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_slice_nested_c_union_field_load.mc", nested_c_union_load_source);

    const nested_c_union_store_source =
        \\#[c_union]
        \\struct CWord {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\struct Inner {
        \\    word: CWord,
        \\}
        \\struct Cell {
        \\    inner: Inner,
        \\}
        \\fn slice_nested_c_union_field_store(cells: []mut Cell, i: usize, value: CWord) -> void {
        \\    cells[i].inner.word = value;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_slice_nested_c_union_field_store.mc", nested_c_union_store_source);

    const tagged_load_source =
        \\union Token {
        \\    number: u32,
        \\    eof,
        \\}
        \\struct Cell {
        \\    token: Token,
        \\}
        \\fn slice_tagged_union_field_load(cells: []mut Cell, i: usize) -> Token {
        \\    return cells[i].token;
        \\}
    ;
    try expectTaggedUnionRaceCopySupported("emit_c_slice_tagged_union_field_load.mc", tagged_load_source);

    const tagged_store_source =
        \\union Token {
        \\    number: u32,
        \\    eof,
        \\}
        \\struct Cell {
        \\    token: Token,
        \\}
        \\fn slice_tagged_union_field_store(cells: []mut Cell, i: usize, value: Token) -> void {
        \\    cells[i].token = value;
        \\}
    ;
    try expectTaggedUnionRaceCopySupported("emit_c_slice_tagged_union_field_store.mc", tagged_store_source);

    const nested_tagged_load_source =
        \\union Token {
        \\    number: u32,
        \\    eof,
        \\}
        \\struct Inner {
        \\    token: Token,
        \\}
        \\struct Cell {
        \\    inner: Inner,
        \\}
        \\fn slice_nested_tagged_union_field_load(cells: []mut Cell, i: usize) -> Token {
        \\    return cells[i].inner.token;
        \\}
    ;
    try expectTaggedUnionRaceCopySupported("emit_c_slice_nested_tagged_union_field_load.mc", nested_tagged_load_source);

    const nested_tagged_store_source =
        \\union Token {
        \\    number: u32,
        \\    eof,
        \\}
        \\struct Inner {
        \\    token: Token,
        \\}
        \\struct Cell {
        \\    inner: Inner,
        \\}
        \\fn slice_nested_tagged_union_field_store(cells: []mut Cell, i: usize, value: Token) -> void {
        \\    cells[i].inner.token = value;
        \\}
    ;
    try expectTaggedUnionRaceCopySupported("emit_c_slice_nested_tagged_union_field_store.mc", nested_tagged_store_source);
}

test "lower-c nested indexed aggregate field value copies lower recursively" {
    const source =
        \\struct Leaf {
        \\    value: u32,
        \\}
        \\struct Inner {
        \\    leaf: Leaf,
        \\}
        \\struct Cell {
        \\    inner: Inner,
        \\}
        \\
        \\fn slice_leaf_load(cells: []mut Cell, i: usize) -> Leaf {
        \\    return cells[i].inner.leaf;
        \\}
        \\
        \\fn slice_leaf_store(cells: []mut Cell, i: usize, value: Leaf) -> void {
        \\    cells[i].inner.leaf = value;
        \\}
        \\
        \\fn pointer_array_leaf_load(pa: *mut [4]Cell, i: usize) -> Leaf {
        \\    return pa.*[i].inner.leaf;
        \\}
        \\
        \\fn pointer_array_leaf_store(pa: *mut [4]Cell, i: usize, value: Leaf) -> void {
        \\    pa.*[i].inner.leaf = value;
        \\}
        \\
        \\fn local_array_leaf_load(i: usize) -> Leaf {
        \\    let cells: [4]Cell = .{
        \\        .{ .inner = .{ .leaf = .{ .value = 1 } } },
        \\        .{ .inner = .{ .leaf = .{ .value = 2 } } },
        \\        .{ .inner = .{ .leaf = .{ .value = 3 } } },
        \\        .{ .inner = .{ .leaf = .{ .value = 4 } } },
        \\    };
        \\    return cells[i].inner.leaf;
        \\}
        \\
        \\fn local_array_leaf_store(i: usize, value: Leaf) -> Leaf {
        \\    var cells: [4]Cell = .{
        \\        .{ .inner = .{ .leaf = .{ .value = 1 } } },
        \\        .{ .inner = .{ .leaf = .{ .value = 2 } } },
        \\        .{ .inner = .{ .leaf = .{ .value = 3 } } },
        \\        .{ .inner = .{ .leaf = .{ .value = 4 } } },
        \\    };
        \\    cells[i].inner.leaf = value;
        \\    return cells[i].inner.leaf;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_nested_indexed_aggregate_field_value_copy.mc", source, &output);

    const slice_load_body = try cFunctionBody(output.items, "static Leaf slice_leaf_load(mc_slice_mut_struct_Cell cells, uintptr_t i)");
    try expectContains(slice_load_body, "Leaf * mc_ptr");
    try expectContains(slice_load_body, "cells.ptr[mc_check_index_usize(mc_idx");
    try expectContains(slice_load_body, "mc_race_load_u32");

    const slice_store_body = try cFunctionBody(output.items, "static void slice_leaf_store(mc_slice_mut_struct_Cell cells, uintptr_t i, Leaf value)");
    try expectContains(slice_store_body, "Leaf * mc_ptr");
    try expectContains(slice_store_body, "Leaf mc_value");
    try expectContains(slice_store_body, "cells.ptr[mc_check_index_usize(");
    try expectContains(slice_store_body, "mc_race_store_u32");

    const pointer_array_load_body = try cFunctionBody(output.items, "static Leaf pointer_array_leaf_load(mc_array_struct_Cell_4 * pa, uintptr_t i)");
    try expectContains(pointer_array_load_body, "Leaf * mc_ptr");
    try expectContains(pointer_array_load_body, "(*pa).elems[mc_check_index_usize(mc_idx");
    try expectContains(pointer_array_load_body, "mc_race_load_u32");

    const pointer_array_store_body = try cFunctionBody(output.items, "static void pointer_array_leaf_store(mc_array_struct_Cell_4 * pa, uintptr_t i, Leaf value)");
    try expectContains(pointer_array_store_body, "Leaf * mc_ptr");
    try expectContains(pointer_array_store_body, "(*pa).elems[mc_check_index_usize(");
    try expectContains(pointer_array_store_body, "mc_race_store_u32");

    const local_body = try cFunctionBody(output.items, "static Leaf local_array_leaf_load(uintptr_t i)");
    try expectContains(local_body, "return cells.elems[mc_check_index_usize(i, 4)].inner.leaf;");
    try expectNotContains(local_body, "mc_race_load_u32");
    const local_store_body = try cFunctionBody(output.items, "static Leaf local_array_leaf_store(uintptr_t i, Leaf value)");
    try expectContains(local_store_body, "cells.elems[mc_check_index_usize(");
    try expectContains(local_store_body, ".inner.leaf = value;");
    try expectContains(local_store_body, "return cells.elems[mc_check_index_usize(i, 4)].inner.leaf;");
    try expectNotContains(local_store_body, "mc_race_load_u32");
    try expectNotContains(local_store_body, "mc_race_store_u32");
}

test "lower-c nested indexed aggregate scalar member chains lower race-tolerantly" {
    const source =
        \\struct Inner {
        \\    value: u32,
        \\}
        \\struct Cell {
        \\    inner: Inner,
        \\}
        \\
        \\fn slice_nested_load(cells: []mut Cell, i: usize) -> u32 {
        \\    return cells[i].inner.value;
        \\}
        \\
        \\fn slice_nested_store(cells: []mut Cell, i: usize, value: u32) -> void {
        \\    cells[i].inner.value = value;
        \\}
        \\
        \\fn pointer_array_nested_load(pa: *mut [4]Cell, i: usize) -> u32 {
        \\    return pa.*[i].inner.value;
        \\}
        \\
        \\fn pointer_array_nested_store(pa: *mut [4]Cell, i: usize, value: u32) -> void {
        \\    pa.*[i].inner.value = value;
        \\}
        \\
        \\fn local_array_nested_load(i: usize) -> u32 {
        \\    let cells: [4]Cell = .{
        \\        .{ .inner = .{ .value = 1 } },
        \\        .{ .inner = .{ .value = 2 } },
        \\        .{ .inner = .{ .value = 3 } },
        \\        .{ .inner = .{ .value = 4 } },
        \\    };
        \\    return cells[i].inner.value;
        \\}
        \\
        \\fn local_array_nested_store(i: usize, value: u32) -> u32 {
        \\    var cells: [4]Cell = .{
        \\        .{ .inner = .{ .value = 1 } },
        \\        .{ .inner = .{ .value = 2 } },
        \\        .{ .inner = .{ .value = 3 } },
        \\        .{ .inner = .{ .value = 4 } },
        \\    };
        \\    cells[i].inner.value = value;
        \\    return cells[i].inner.value;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_nested_member_access.mc", source, &output);

    const slice_load_body = try cFunctionBody(output.items, "static uint32_t slice_nested_load(mc_slice_mut_struct_Cell cells, uintptr_t i)");
    try expectContains(slice_load_body, "return ((uint32_t)mc_race_load_u32(&(cells.ptr[mc_check_index_usize(i, cells.len)].inner.value)));");
    const slice_store_body = try cFunctionBody(output.items, "static void slice_nested_store(mc_slice_mut_struct_Cell cells, uintptr_t i, uint32_t value)");
    try expectContains(slice_store_body, "mc_race_store_u32(&(cells.ptr[mc_check_index_usize(");
    try expectContains(slice_store_body, ".inner.value), (uint32_t)mc_tmp");
    const pointer_array_load_body = try cFunctionBody(output.items, "static uint32_t pointer_array_nested_load(mc_array_struct_Cell_4 * pa, uintptr_t i)");
    try expectContains(pointer_array_load_body, "return ((uint32_t)mc_race_load_u32(&((*pa).elems[mc_check_index_usize(i, 4)].inner.value)));");
    const pointer_array_store_body = try cFunctionBody(output.items, "static void pointer_array_nested_store(mc_array_struct_Cell_4 * pa, uintptr_t i, uint32_t value)");
    try expectContains(pointer_array_store_body, "mc_race_store_u32(&((*pa).elems[mc_check_index_usize(");
    try expectContains(pointer_array_store_body, ".inner.value), (uint32_t)mc_tmp");
    const local_body = try cFunctionBody(output.items, "static uint32_t local_array_nested_load(uintptr_t i)");
    try expectContains(local_body, "return cells.elems[mc_check_index_usize(i, 4)].inner.value;");
    try expectNotContains(local_body, "mc_race_load_u32");
    const local_store_body = try cFunctionBody(output.items, "static uint32_t local_array_nested_store(uintptr_t i, uint32_t value)");
    try expectContains(local_store_body, "cells.elems[mc_check_index_usize(");
    try expectContains(local_store_body, ".inner.value =");
    try expectContains(local_store_body, "return cells.elems[mc_check_index_usize(i, 4)].inner.value;");
    try expectNotContains(local_store_body, "mc_race_load_u32");
    try expectNotContains(local_store_body, "mc_race_store_u32");
}

test "lower-c aggregate whole-element access lowers recursively" {
    const slice_load_source =
        \\struct Cell {
        \\    value: u32,
        \\}
        \\
        \\fn slice_cell_load(cells: []mut Cell, i: usize) -> Cell {
        \\    return cells[i];
        \\}
    ;
    var slice_load_output: std.ArrayList(u8) = .empty;
    defer slice_load_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_slice_aggregate_load.mc", slice_load_source, &slice_load_output);
    const slice_load_body = try cFunctionBody(slice_load_output.items, "static Cell slice_cell_load(mc_slice_mut_struct_Cell cells, uintptr_t i)");
    try expectContains(slice_load_body, "uintptr_t mc_idx");
    try expectContains(slice_load_body, "Cell * mc_ptr");
    try expectContains(slice_load_body, "cells.ptr[mc_check_index_usize(mc_idx");
    try expectContains(slice_load_body, "mc_race_load_u32");

    const slice_store_source =
        \\struct Cell {
        \\    value: u32,
        \\}
        \\
        \\fn slice_cell_store(cells: []mut Cell, i: usize, value: Cell) -> void {
        \\    cells[i] = value;
        \\}
    ;
    var slice_store_output: std.ArrayList(u8) = .empty;
    defer slice_store_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_slice_aggregate_store.mc", slice_store_source, &slice_store_output);
    const slice_store_body = try cFunctionBody(slice_store_output.items, "static void slice_cell_store(mc_slice_mut_struct_Cell cells, uintptr_t i, Cell value)");
    try expectContains(slice_store_body, "Cell * mc_ptr");
    try expectContains(slice_store_body, "Cell mc_value");
    try expectContains(slice_store_body, "cells.ptr[mc_check_index_usize(");
    try expectContains(slice_store_body, "mc_race_store_u32");

    const pointer_array_source =
        \\struct Cell {
        \\    value: u32,
        \\}
        \\
        \\fn pointer_array_cell_load(pa: *mut [4]Cell, i: usize) -> Cell {
        \\    return pa.*[i];
        \\}
    ;
    var pointer_array_output: std.ArrayList(u8) = .empty;
    defer pointer_array_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_pointer_array_aggregate_load.mc", pointer_array_source, &pointer_array_output);
    const pointer_array_body = try cFunctionBody(pointer_array_output.items, "static Cell pointer_array_cell_load(mc_array_struct_Cell_4 * pa, uintptr_t i)");
    try expectContains(pointer_array_body, "uintptr_t mc_idx");
    try expectContains(pointer_array_body, "Cell * mc_ptr");
    try expectContains(pointer_array_body, "(*pa).elems[mc_check_index_usize(mc_idx");
    try expectContains(pointer_array_body, "mc_race_load_u32");

    const pointer_array_store_source =
        \\struct Cell {
        \\    value: u32,
        \\}
        \\
        \\fn pointer_array_cell_store(pa: *mut [4]Cell, i: usize, value: Cell) -> void {
        \\    pa.*[i] = value;
        \\}
    ;
    var pointer_array_store_output: std.ArrayList(u8) = .empty;
    defer pointer_array_store_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_pointer_array_aggregate_store.mc", pointer_array_store_source, &pointer_array_store_output);
    const pointer_array_store_body = try cFunctionBody(pointer_array_store_output.items, "static void pointer_array_cell_store(mc_array_struct_Cell_4 * pa, uintptr_t i, Cell value)");
    try expectContains(pointer_array_store_body, "Cell * mc_ptr");
    try expectContains(pointer_array_store_body, "Cell mc_value");
    try expectContains(pointer_array_store_body, "(*pa).elems[mc_check_index_usize(");
    try expectContains(pointer_array_store_body, "mc_race_store_u32");

    const local_source =
        \\struct Cell {
        \\    value: u32,
        \\}
        \\
        \\fn local_array_cell_load(i: usize) -> Cell {
        \\    let cells: [4]Cell = .{
        \\        .{ .value = 1 },
        \\        .{ .value = 2 },
        \\        .{ .value = 3 },
        \\        .{ .value = 4 },
        \\    };
        \\    return cells[i];
        \\}
    ;
    var local_output: std.ArrayList(u8) = .empty;
    defer local_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_local_aggregate_load.mc", local_source, &local_output);
    const local_body = try cFunctionBody(local_output.items, "static Cell local_array_cell_load(uintptr_t i)");
    try expectContains(local_body, "return cells.elems[mc_check_index_usize(i, 4)];");

    const local_pointer_array_source =
        \\struct Cell {
        \\    value: u32,
        \\}
        \\
        \\fn local_pointer_array_cell_load(i: usize) -> Cell {
        \\    let cells: [4]Cell = .{
        \\        .{ .value = 1 },
        \\        .{ .value = 2 },
        \\        .{ .value = 3 },
        \\        .{ .value = 4 },
        \\    };
        \\    let pa: *mut [4]Cell = &cells;
        \\    return pa.*[i];
        \\}
        \\
        \\fn local_pointer_array_cell_store(i: usize, value: Cell) -> Cell {
        \\    var cells: [4]Cell = .{
        \\        .{ .value = 1 },
        \\        .{ .value = 2 },
        \\        .{ .value = 3 },
        \\        .{ .value = 4 },
        \\    };
        \\    let pa: *mut [4]Cell = &cells;
        \\    pa.*[i] = value;
        \\    return cells[i];
        \\}
    ;
    var local_pointer_array_output: std.ArrayList(u8) = .empty;
    defer local_pointer_array_output.deinit(std.testing.allocator);
    try appendCTest("emit_c_local_pointer_array_aggregate.mc", local_pointer_array_source, &local_pointer_array_output);
    const local_pointer_array_load_body = try cFunctionBody(local_pointer_array_output.items, "static Cell local_pointer_array_cell_load(uintptr_t i)");
    try expectContains(local_pointer_array_load_body, "/* mir pointer_provenance consumed fn=local_pointer_array_cell_load subject=pa provenance=local_storage reason=none source=");
    try expectContains(local_pointer_array_load_body, "return (*pa).elems[mc_check_index_usize(i, 4)];");
    try expectNotContains(local_pointer_array_load_body, "mc_race_load_u32");
    const local_pointer_array_store_body = try cFunctionBody(local_pointer_array_output.items, "static Cell local_pointer_array_cell_store(uintptr_t i, Cell value)");
    try expectContains(local_pointer_array_store_body, "/* mir pointer_provenance consumed fn=local_pointer_array_cell_store subject=pa provenance=local_storage reason=none source=");
    try expectContains(local_pointer_array_store_body, "(*pa).elems[mc_check_index_usize(i, 4)] = value;");
    try expectNotContains(local_pointer_array_store_body, "mc_race_store_u32");
}

test "lower-c union aggregate whole-element index access fails closed" {
    const overlay_slice_load_source =
        \\overlay union Word {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\
        \\fn slice_union_load(cells: []mut Word, i: usize) -> Word {
        \\    return cells[i];
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_slice_union_element_load.mc", overlay_slice_load_source);

    const overlay_slice_store_source =
        \\overlay union Word {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\
        \\fn slice_union_store(cells: []mut Word, i: usize, value: Word) -> void {
        \\    cells[i] = value;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_slice_union_element_store.mc", overlay_slice_store_source);

    const c_union_slice_load_source =
        \\#[c_union]
        \\struct CWord {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\
        \\fn slice_c_union_load(cells: []mut CWord, i: usize) -> CWord {
        \\    return cells[i];
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_slice_c_union_element_load.mc", c_union_slice_load_source);

    const c_union_slice_store_source =
        \\#[c_union]
        \\struct CWord {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\
        \\fn slice_c_union_store(cells: []mut CWord, i: usize, value: CWord) -> void {
        \\    cells[i] = value;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_slice_c_union_element_store.mc", c_union_slice_store_source);

    const nested_overlay_slice_load_source =
        \\overlay union Word {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\struct Holder {
        \\    word: Word,
        \\}
        \\fn slice_nested_union_element_load(cells: []mut Holder, i: usize) -> Holder {
        \\    return cells[i];
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_slice_nested_union_element_load.mc", nested_overlay_slice_load_source);

    const nested_overlay_slice_store_source =
        \\overlay union Word {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\struct Holder {
        \\    word: Word,
        \\}
        \\fn slice_nested_union_element_store(cells: []mut Holder, i: usize, value: Holder) -> void {
        \\    cells[i] = value;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_slice_nested_union_element_store.mc", nested_overlay_slice_store_source);

    const nested_c_union_slice_load_source =
        \\#[c_union]
        \\struct CWord {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\struct Holder {
        \\    word: CWord,
        \\}
        \\fn slice_nested_c_union_element_load(cells: []mut Holder, i: usize) -> Holder {
        \\    return cells[i];
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_slice_nested_c_union_element_load.mc", nested_c_union_slice_load_source);

    const nested_c_union_slice_store_source =
        \\#[c_union]
        \\struct CWord {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\struct Holder {
        \\    word: CWord,
        \\}
        \\fn slice_nested_c_union_element_store(cells: []mut Holder, i: usize, value: Holder) -> void {
        \\    cells[i] = value;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_slice_nested_c_union_element_store.mc", nested_c_union_slice_store_source);

    const tagged_slice_load_source =
        \\union Token {
        \\    number: u32,
        \\    eof,
        \\}
        \\
        \\fn slice_tagged_union_load(cells: []mut Token, i: usize) -> Token {
        \\    return cells[i];
        \\}
    ;
    try expectTaggedUnionRaceCopySupported("emit_c_slice_tagged_union_element_load.mc", tagged_slice_load_source);

    const tagged_slice_store_source =
        \\union Token {
        \\    number: u32,
        \\    eof,
        \\}
        \\
        \\fn slice_tagged_union_store(cells: []mut Token, i: usize, value: Token) -> void {
        \\    cells[i] = value;
        \\}
    ;
    try expectTaggedUnionRaceCopySupported("emit_c_slice_tagged_union_element_store.mc", tagged_slice_store_source);

    const nested_tagged_slice_load_source =
        \\union Token {
        \\    number: u32,
        \\    eof,
        \\}
        \\struct Holder {
        \\    token: Token,
        \\}
        \\fn slice_nested_tagged_union_load(cells: []mut Holder, i: usize) -> Holder {
        \\    return cells[i];
        \\}
    ;
    try expectTaggedUnionRaceCopySupported("emit_c_slice_nested_tagged_union_element_load.mc", nested_tagged_slice_load_source);

    const nested_tagged_slice_store_source =
        \\union Token {
        \\    number: u32,
        \\    eof,
        \\}
        \\struct Holder {
        \\    token: Token,
        \\}
        \\fn slice_nested_tagged_union_store(cells: []mut Holder, i: usize, value: Holder) -> void {
        \\    cells[i] = value;
        \\}
    ;
    try expectTaggedUnionRaceCopySupported("emit_c_slice_nested_tagged_union_element_store.mc", nested_tagged_slice_store_source);

    const overlay_pointer_array_load_source =
        \\overlay union Word {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\
        \\fn pointer_array_overlay_union_load(pa: *mut [4]Word, i: usize) -> Word {
        \\    return pa.*[i];
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_pointer_array_overlay_union_element_load.mc", overlay_pointer_array_load_source);

    const overlay_pointer_array_store_source =
        \\overlay union Word {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\
        \\fn pointer_array_overlay_union_store(pa: *mut [4]Word, i: usize, value: Word) -> void {
        \\    pa.*[i] = value;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_pointer_array_overlay_union_element_store.mc", overlay_pointer_array_store_source);

    const c_union_pointer_array_load_source =
        \\#[c_union]
        \\struct CWord {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\
        \\fn pointer_array_c_union_load(pa: *mut [4]CWord, i: usize) -> CWord {
        \\    return pa.*[i];
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_pointer_array_c_union_element_load.mc", c_union_pointer_array_load_source);

    const c_union_pointer_array_store_source =
        \\#[c_union]
        \\struct CWord {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\
        \\fn pointer_array_c_union_store(pa: *mut [4]CWord, i: usize, value: CWord) -> void {
        \\    pa.*[i] = value;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_pointer_array_c_union_element_store.mc", c_union_pointer_array_store_source);

    const nested_overlay_pointer_array_load_source =
        \\overlay union Word {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\struct Holder {
        \\    word: Word,
        \\}
        \\fn pointer_array_nested_overlay_union_load(pa: *mut [4]Holder, i: usize) -> Holder {
        \\    return pa.*[i];
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_pointer_array_nested_overlay_union_element_load.mc", nested_overlay_pointer_array_load_source);

    const nested_overlay_pointer_array_store_source =
        \\overlay union Word {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\struct Holder {
        \\    word: Word,
        \\}
        \\fn pointer_array_nested_overlay_union_store(pa: *mut [4]Holder, i: usize, value: Holder) -> void {
        \\    pa.*[i] = value;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_pointer_array_nested_overlay_union_element_store.mc", nested_overlay_pointer_array_store_source);

    const nested_c_union_pointer_array_load_source =
        \\#[c_union]
        \\struct CWord {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\struct Holder {
        \\    word: CWord,
        \\}
        \\fn pointer_array_nested_c_union_load(pa: *mut [4]Holder, i: usize) -> Holder {
        \\    return pa.*[i];
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_pointer_array_nested_c_union_element_load.mc", nested_c_union_pointer_array_load_source);

    const nested_c_union_pointer_array_store_source =
        \\#[c_union]
        \\struct CWord {
        \\    bits: u32,
        \\    flag: bool,
        \\}
        \\struct Holder {
        \\    word: CWord,
        \\}
        \\fn pointer_array_nested_c_union_store(pa: *mut [4]Holder, i: usize, value: Holder) -> void {
        \\    pa.*[i] = value;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_pointer_array_nested_c_union_element_store.mc", nested_c_union_pointer_array_store_source);

    const tagged_pointer_array_load_source =
        \\union Token {
        \\    number: u32,
        \\    eof,
        \\}
        \\
        \\fn pointer_array_tagged_union_load(pa: *mut [4]Token, i: usize) -> Token {
        \\    return pa.*[i];
        \\}
    ;
    try expectTaggedUnionRaceCopySupported("emit_c_pointer_array_tagged_union_element_load.mc", tagged_pointer_array_load_source);

    const tagged_pointer_array_store_source =
        \\union Token {
        \\    number: u32,
        \\    eof,
        \\}
        \\
        \\fn pointer_array_tagged_union_store(pa: *mut [4]Token, i: usize, value: Token) -> void {
        \\    pa.*[i] = value;
        \\}
    ;
    try expectTaggedUnionRaceCopySupported("emit_c_pointer_array_tagged_union_element_store.mc", tagged_pointer_array_store_source);

    const nested_tagged_pointer_array_load_source =
        \\union Token {
        \\    number: u32,
        \\    eof,
        \\}
        \\struct Holder {
        \\    token: Token,
        \\}
        \\fn pointer_array_nested_tagged_union_load(pa: *mut [4]Holder, i: usize) -> Holder {
        \\    return pa.*[i];
        \\}
    ;
    try expectTaggedUnionRaceCopySupported("emit_c_pointer_array_nested_tagged_union_element_load.mc", nested_tagged_pointer_array_load_source);

    const nested_tagged_pointer_array_store_source =
        \\union Token {
        \\    number: u32,
        \\    eof,
        \\}
        \\struct Holder {
        \\    token: Token,
        \\}
        \\fn pointer_array_nested_tagged_union_store(pa: *mut [4]Holder, i: usize, value: Holder) -> void {
        \\    pa.*[i] = value;
        \\}
    ;
    try expectTaggedUnionRaceCopySupported("emit_c_pointer_array_nested_tagged_union_element_store.mc", nested_tagged_pointer_array_store_source);
}

test "lower-c address-of-local deref keeps plain lowering" {
    const source =
        \\fn read_local() -> u32 {
        \\    var local: u32 = 1;
        \\    local = 2;
        \\    return (&local).*;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_address_of_local_deref.mc", source, &output);
    const body = try cFunctionBody(output.items, "static uint32_t read_local(void)");
    try expectContains(body, "return *(&local);");
    try expectNotContains(body, "mc_race_");
}

test "lower-c escaped pointer provenance lowers conservatively" {
    const source =
        \\extern fn consume_pointer(p: *mut u32) -> void;
        \\extern fn consume_box(p: *mut PtrBox) -> void;
        \\
        \\struct PtrBox {
        \\    p: *mut u32,
        \\}
        \\
        \\fn escaped_local_pointer_lowers_race_tolerant() -> u32 {
        \\    var local: u32 = 1;
        \\    let p: *mut u32 = &local;
        \\    consume_pointer(p);
        \\    return p.*;
        \\}
        \\
        \\fn escaped_aggregate_pointer_field_lowers_race_tolerant() -> u32 {
        \\    var local: u32 = 2;
        \\    var box: PtrBox = .{ .p = &local };
        \\    consume_box(&box);
        \\    let p: *mut u32 = box.p;
        \\    return p.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_escaped_pointer_provenance.mc", source, &output);

    const local_body = try cFunctionBody(output.items, "static uint32_t escaped_local_pointer_lowers_race_tolerant(void)");
    try expectContains(local_body, "consume_pointer(");
    try expectContains(local_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(local_body, "return *p;");

    const aggregate_body = try cFunctionBody(output.items, "static uint32_t escaped_aggregate_pointer_field_lowers_race_tolerant(void)");
    try expectContains(aggregate_body, "consume_box(");
    try expectContains(aggregate_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(aggregate_body, "return *p;");
}

test "lower-c consumes MIR pointer provenance facts for direct scalar pointer derefs" {
    const source =
        \\global shared_counter: u32 = 0;
        \\const ZERO_OFFSET: usize = 0;
        \\struct ZeroField { value: u8 }
        \\const REFLECT_ZERO_OFFSET: usize = field_offset<ZeroField>(.value);
        \\
        \\extern fn external_pointer() -> *mut u32;
        \\extern fn external_raw_many_pointer() -> [*]mut u32;
        \\
        \\struct PtrBox { p: *mut u32 }
        \\
        \\fn pointer_fact_global_load() -> u32 {
        \\    let gp: *mut u32 = &shared_counter;
        \\    return gp.*;
        \\}
        \\
        \\fn pointer_fact_global_store(x: u32) -> void {
        \\    let gp: *mut u32 = &shared_counter;
        \\    gp.* = x;
        \\}
        \\
        \\fn pointer_fact_copy_load() -> u32 {
        \\    let gp: *mut u32 = &shared_counter;
        \\    let copy: *mut u32 = gp;
        \\    return copy.*;
        \\}
        \\
        \\fn pointer_fact_copy_store(x: u32) -> void {
        \\    let gp: *mut u32 = &shared_counter;
        \\    var copy: *mut u32 = &shared_counter;
        \\    copy = gp;
        \\    copy.* = x;
        \\}
        \\
        \\fn pointer_fact_local_storage_stays_plain() -> u32 {
        \\    var local: u32 = 5;
        \\    let lp: *mut u32 = &local;
        \\    lp.* = 6;
        \\    return lp.*;
        \\}
        \\
        \\fn pointer_fact_local_copy_stays_plain() -> u32 {
        \\    var local: u32 = 7;
        \\    let lp: *mut u32 = &local;
        \\    let copy: *mut u32 = lp;
        \\    return copy.*;
        \\}
        \\
        \\fn pointer_fact_noalias_global_load() -> u32 {
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        let gp: *mut u32 = compiler.assume_noalias_unchecked(&shared_counter, 4);
        \\        return gp.*;
        \\    }
        \\}
        \\
        \\fn pointer_fact_unknown_assignment_lowers_race_tolerant() -> u32 {
        \\    var gp: *mut u32 = &shared_counter;
        \\    gp = external_pointer();
        \\    return gp.*;
        \\}
        \\
        \\fn call_produced_pointer_lowers_race_tolerant() -> u32 {
        \\    return external_pointer().*;
        \\}
        \\
        \\fn call_produced_pointer_store_lowers_race_tolerant(x: u32) -> void {
        \\    external_pointer().* = x;
        \\}
        \\
        \\fn member_loaded_pointer_lowers_race_tolerant(b: PtrBox) -> u32 {
        \\    return b.p.*;
        \\}
        \\
        \\fn indexed_loaded_pointer_lowers_race_tolerant(i: usize) -> u32 {
        \\    let ptrs: [2]*mut u32 = .{ &shared_counter, external_pointer() };
        \\    return ptrs[i].*;
        \\}
        \\
        \\fn pointer_fact_call_invalidated_lowers_race_tolerant() -> u32 {
        \\    let gp: *mut u32 = &shared_counter;
        \\    external_raw_many_pointer();
        \\    return gp.*;
        \\}
        \\
        \\fn pointer_fact_raw_many_zero_load() -> u32 {
        \\    unsafe {
        \\        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        let q: [*]mut u32 = p.offset(0);
        \\        return q.*;
        \\    }
        \\}
        \\
        \\fn pointer_fact_raw_many_zero_const_global_load() -> u32 {
        \\    unsafe {
        \\        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        let q: [*]mut u32 = p.offset(ZERO_OFFSET);
        \\        return q.*;
        \\    }
        \\}
        \\
        \\fn pointer_fact_raw_many_zero_reflect_load() -> u32 {
        \\    unsafe {
        \\        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        let q: [*]mut u32 = p.offset(field_offset<ZeroField>(.value));
        \\        return q.*;
        \\    }
        \\}
        \\
        \\fn pointer_fact_raw_many_zero_grouped_load() -> u32 {
        \\    unsafe {
        \\        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        let q: [*]mut u32 = (p.offset(0));
        \\        return q.*;
        \\    }
        \\}
        \\
        \\fn pointer_fact_raw_many_zero_casted_load() -> u32 {
        \\    unsafe {
        \\        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        let q: [*]mut u32 = p.offset(0) as [*]mut u32;
        \\        return q.*;
        \\    }
        \\}
        \\
        \\fn pointer_fact_raw_many_zero_noalias_load() -> u32 {
        \\    unsafe {
        \\        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        #[unsafe_contract(noalias)]
        \\        {
        \\            let q: [*]mut u32 = compiler.assume_noalias_unchecked(p.offset(0), 4);
        \\            return q.*;
        \\        }
        \\    }
        \\}
        \\
        \\fn pointer_fact_raw_many_zero_store(x: u32) -> void {
        \\    unsafe {
        \\        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        let q: [*]mut u32 = p.offset(0);
        \\        q.* = x;
        \\    }
        \\}
        \\
        \\fn pointer_fact_raw_many_zero_local_stays_plain() -> u32 {
        \\    unsafe {
        \\        var local: u32 = 7;
        \\        let p: [*]mut u32 = (&local) as [*]mut u32;
        \\        let q: [*]mut u32 = p.offset(0);
        \\        q.* = 9;
        \\        return q.*;
        \\    }
        \\}
        \\
        \\fn pointer_fact_raw_many_copy_load() -> u32 {
        \\    unsafe {
        \\        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        let q: [*]mut u32 = p;
        \\        return q.*;
        \\    }
        \\}
        \\
        \\fn pointer_fact_raw_many_nonzero_lowers_race_tolerant() -> u32 {
        \\    unsafe {
        \\        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        let q: [*]mut u32 = p.offset(1);
        \\        return q.*;
        \\    }
        \\}
        \\
        \\fn pointer_fact_raw_many_dynamic_lowers_race_tolerant(i: usize) -> u32 {
        \\    unsafe {
        \\        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        let q: [*]mut u32 = p.offset(i);
        \\        return q.*;
        \\    }
        \\}
        \\
        \\fn pointer_fact_raw_many_unknown_lowers_race_tolerant() -> u32 {
        \\    unsafe {
        \\        let q: [*]mut u32 = external_raw_many_pointer().offset(0);
        \\        return q.*;
        \\    }
        \\}
        \\
        \\fn direct_raw_many_offset_lowers_race_tolerant(i: usize) -> u32 {
        \\    unsafe {
        \\        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        return p.offset(i).*;
        \\    }
        \\}
        \\
        \\fn direct_call_raw_many_offset_lowers_race_tolerant() -> u32 {
        \\    unsafe {
        \\        return external_raw_many_pointer().offset(0).*;
        \\    }
        \\}
    ;

    var parsed = try test_support.parseModule("emit_c_pointer_provenance.mc", source);
    defer parsed.deinit();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, parsed.module, &output);

    try expectContains(output.items, "/* mir pointer_provenance consumed fn=pointer_fact_global_load subject=gp provenance=global_storage reason=none source=");
    try expectContains(output.items, "return ((uint32_t)mc_race_load_u32(gp));");
    try expectContains(output.items, "/* mir pointer_provenance consumed fn=pointer_fact_global_store subject=gp provenance=global_storage reason=none source=");
    try expectContains(output.items, "mc_race_store_u32(gp, (uint32_t)x);");
    try expectContains(output.items, "/* mir pointer_provenance consumed fn=pointer_fact_copy_load subject=copy provenance=global_storage reason=none source=");
    try expectContains(output.items, "return ((uint32_t)mc_race_load_u32(copy));");
    try expectContains(output.items, "/* mir pointer_provenance consumed fn=pointer_fact_copy_store subject=copy provenance=global_storage reason=reassignment source=");
    try expectContains(output.items, "mc_race_store_u32(copy, (uint32_t)x);");
    try expectContains(output.items, "/* mir pointer_provenance consumed fn=pointer_fact_local_storage_stays_plain subject=lp provenance=local_storage reason=none source=");
    try expectContains(output.items, "*lp = 6;");
    try expectContains(output.items, "return *lp;");
    const local_copy_body = try cFunctionBody(output.items, "static uint32_t pointer_fact_local_copy_stays_plain(void)");
    try expectContains(local_copy_body, "/* mir pointer_provenance consumed fn=pointer_fact_local_copy_stays_plain subject=copy provenance=local_storage reason=none source=");
    try expectContains(local_copy_body, "return *copy;");
    try expectNotContains(local_copy_body, "mc_race_load_u32(copy)");
    const noalias_global_body = try cFunctionBody(output.items, "static uint32_t pointer_fact_noalias_global_load(void)");
    try expectContains(noalias_global_body, "/* mir pointer_provenance consumed fn=pointer_fact_noalias_global_load subject=gp provenance=global_storage reason=none source=");
    try expectContains(noalias_global_body, "return ((uint32_t)mc_race_load_u32(gp));");
    try expectNotContains(noalias_global_body, "return *gp;");
    try expectContains(output.items, "/* mir pointer_provenance consumed fn=pointer_fact_unknown_assignment_lowers_race_tolerant subject=gp provenance=global_storage reason=none source=");
    try expectContains(output.items, "/* mir pointer_provenance consumed fn=pointer_fact_unknown_assignment_lowers_race_tolerant subject=gp provenance=unknown reason=reassignment source=");
    try expectContains(output.items, "return ((uint32_t)mc_race_load_u32(gp));");
    const call_pointer_body = try cFunctionBody(output.items, "static uint32_t call_produced_pointer_lowers_race_tolerant(void)");
    try expectContains(call_pointer_body, "return ((uint32_t)mc_race_load_u32(external_pointer()));");
    try expectNotContains(call_pointer_body, "return *external_pointer();");
    const call_pointer_store_body = try cFunctionBody(output.items, "static void call_produced_pointer_store_lowers_race_tolerant(uint32_t x)");
    try expectContains(call_pointer_store_body, "mc_race_store_u32(external_pointer(), (uint32_t)x);");
    try expectNotContains(call_pointer_store_body, "*external_pointer() = x;");
    const member_pointer_body = try cFunctionBody(output.items, "static uint32_t member_loaded_pointer_lowers_race_tolerant(PtrBox b)");
    try expectContains(member_pointer_body, "return ((uint32_t)mc_race_load_u32(b.p));");
    try expectNotContains(member_pointer_body, "return *b.p;");
    const indexed_pointer_body = try cFunctionBody(output.items, "static uint32_t indexed_loaded_pointer_lowers_race_tolerant(uintptr_t i)");
    try expectContains(indexed_pointer_body, "return ((uint32_t)mc_race_load_u32(ptrs.elems[mc_check_index_usize(i, 2)]));");
    try expectNotContains(indexed_pointer_body, "return *ptrs.elems");

    const invalidated_comment = "/* mir pointer_provenance consumed fn=pointer_fact_call_invalidated_lowers_race_tolerant subject=gp provenance=global_storage reason=none source=";
    const invalidated_pos = std.mem.indexOf(u8, output.items, invalidated_comment) orelse return error.TestExpectedEqual;
    _ = std.mem.indexOfPos(u8, output.items, invalidated_pos, "return ((uint32_t)mc_race_load_u32(gp));") orelse return error.TestExpectedEqual;
    const invalidated_body = try cFunctionBody(output.items, "static uint32_t pointer_fact_call_invalidated_lowers_race_tolerant(void)");
    try expectNotContains(invalidated_body, "return *gp;");

    const raw_many_zero_load_body = try cFunctionBody(output.items, "static uint32_t pointer_fact_raw_many_zero_load(void)");
    try expectContains(raw_many_zero_load_body, "/* mir pointer_provenance consumed fn=pointer_fact_raw_many_zero_load subject=q provenance=global_storage reason=none source=");
    try expectContains(raw_many_zero_load_body, "return ((uint32_t)mc_race_load_u32(q));");

    const raw_many_zero_const_global_load_body = try cFunctionBody(output.items, "static uint32_t pointer_fact_raw_many_zero_const_global_load(void)");
    try expectContains(raw_many_zero_const_global_load_body, "/* mir pointer_provenance consumed fn=pointer_fact_raw_many_zero_const_global_load subject=q provenance=global_storage reason=none source=");
    try expectContains(raw_many_zero_const_global_load_body, "return ((uint32_t)mc_race_load_u32(q));");

    const raw_many_zero_reflect_load_body = try cFunctionBody(output.items, "static uint32_t pointer_fact_raw_many_zero_reflect_load(void)");
    try expectContains(raw_many_zero_reflect_load_body, "/* mir pointer_provenance consumed fn=pointer_fact_raw_many_zero_reflect_load subject=q provenance=global_storage reason=none source=");
    try expectContains(raw_many_zero_reflect_load_body, "return ((uint32_t)mc_race_load_u32(q));");

    const raw_many_zero_grouped_load_body = try cFunctionBody(output.items, "static uint32_t pointer_fact_raw_many_zero_grouped_load(void)");
    try expectContains(raw_many_zero_grouped_load_body, "/* mir pointer_provenance consumed fn=pointer_fact_raw_many_zero_grouped_load subject=q provenance=global_storage reason=none source=");
    try expectContains(raw_many_zero_grouped_load_body, "return ((uint32_t)mc_race_load_u32(q));");

    const raw_many_zero_casted_load_body = try cFunctionBody(output.items, "static uint32_t pointer_fact_raw_many_zero_casted_load(void)");
    try expectContains(raw_many_zero_casted_load_body, "/* mir pointer_provenance consumed fn=pointer_fact_raw_many_zero_casted_load subject=q provenance=global_storage reason=none source=");
    try expectContains(raw_many_zero_casted_load_body, "return ((uint32_t)mc_race_load_u32(q));");

    const raw_many_zero_noalias_load_body = try cFunctionBody(output.items, "static uint32_t pointer_fact_raw_many_zero_noalias_load(void)");
    try expectContains(raw_many_zero_noalias_load_body, "/* mir pointer_provenance consumed fn=pointer_fact_raw_many_zero_noalias_load subject=p provenance=global_storage reason=none source=");
    try expectContains(raw_many_zero_noalias_load_body, "/* mir pointer_provenance consumed fn=pointer_fact_raw_many_zero_noalias_load subject=q provenance=global_storage reason=none source=");
    try expectContains(raw_many_zero_noalias_load_body, "return ((uint32_t)mc_race_load_u32(q));");

    const raw_many_zero_store_body = try cFunctionBody(output.items, "static void pointer_fact_raw_many_zero_store(uint32_t x)");
    try expectContains(raw_many_zero_store_body, "/* mir pointer_provenance consumed fn=pointer_fact_raw_many_zero_store subject=q provenance=global_storage reason=none source=");
    try expectContains(raw_many_zero_store_body, "mc_race_store_u32(q, (uint32_t)x);");

    const raw_many_zero_local_body = try cFunctionBody(output.items, "static uint32_t pointer_fact_raw_many_zero_local_stays_plain(void)");
    try expectContains(raw_many_zero_local_body, "/* mir pointer_provenance consumed fn=pointer_fact_raw_many_zero_local_stays_plain subject=p provenance=local_storage reason=none source=");
    try expectContains(raw_many_zero_local_body, "/* mir pointer_provenance consumed fn=pointer_fact_raw_many_zero_local_stays_plain subject=q provenance=local_storage reason=none source=");
    try expectContains(raw_many_zero_local_body, "*q = 9;");
    try expectContains(raw_many_zero_local_body, "return *q;");
    try expectNotContains(raw_many_zero_local_body, "mc_race_");

    const raw_many_copy_load_body = try cFunctionBody(output.items, "static uint32_t pointer_fact_raw_many_copy_load(void)");
    try expectContains(raw_many_copy_load_body, "/* mir pointer_provenance consumed fn=pointer_fact_raw_many_copy_load subject=q provenance=global_storage reason=none source=");
    try expectContains(raw_many_copy_load_body, "return ((uint32_t)mc_race_load_u32(q));");

    const raw_many_nonzero_body = try cFunctionBody(output.items, "static uint32_t pointer_fact_raw_many_nonzero_lowers_race_tolerant(void)");
    try expectContains(raw_many_nonzero_body, "return ((uint32_t)mc_race_load_u32(q));");
    try expectNotContains(raw_many_nonzero_body, "return *q;");

    const raw_many_dynamic_body = try cFunctionBody(output.items, "static uint32_t pointer_fact_raw_many_dynamic_lowers_race_tolerant(uintptr_t i)");
    try expectContains(raw_many_dynamic_body, "return ((uint32_t)mc_race_load_u32(q));");
    try expectNotContains(raw_many_dynamic_body, "return *q;");

    const raw_many_unknown_body = try cFunctionBody(output.items, "static uint32_t pointer_fact_raw_many_unknown_lowers_race_tolerant(void)");
    try expectContains(raw_many_unknown_body, "return ((uint32_t)mc_race_load_u32(q));");
    try expectNotContains(raw_many_unknown_body, "return *q;");

    const direct_raw_many_offset_body = try cFunctionBody(output.items, "static uint32_t direct_raw_many_offset_lowers_race_tolerant(uintptr_t i)");
    try expectContains(direct_raw_many_offset_body, "return ((uint32_t)mc_race_load_u32((p + i)));");
    try expectNotContains(direct_raw_many_offset_body, "return *(p + i);");

    const direct_call_raw_many_offset_body = try cFunctionBody(output.items, "static uint32_t direct_call_raw_many_offset_lowers_race_tolerant(void)");
    try expectContains(direct_call_raw_many_offset_body, " = (uint32_t)mc_race_load_u32(mc_tmp");
    try expectNotContains(direct_call_raw_many_offset_body, "return *(external_raw_many_pointer()");
    try expectNotContains(direct_call_raw_many_offset_body, "return *mc_tmp");

    var mir_dump: std.ArrayList(u8) = .empty;
    defer mir_dump.deinit(std.testing.allocator);
    try mir.appendDump(std.testing.allocator, parsed.module, &mir_dump);
    try expectCCommentSourceMatchesMirFact(
        output.items,
        mir_dump.items,
        "/* mir pointer_provenance consumed fn=pointer_fact_global_load subject=gp provenance=global_storage reason=none source=",
        "mir pointer_provenance_fact fn=pointer_fact_global_load subject=gp element=none provenance=global_storage storage=shared_counter",
    );

    var llvm_output: std.ArrayList(u8) = .empty;
    defer llvm_output.deinit(std.testing.allocator);
    try lower_llvm.appendLlvm(std.testing.allocator, parsed.module, &llvm_output);
    const c_source = try commentSourceText(output.items, "/* mir pointer_provenance consumed fn=pointer_fact_global_load subject=gp provenance=global_storage reason=none source=");
    const llvm_comment = try std.fmt.allocPrint(
        std.testing.allocator,
        "; mir pointer_provenance consumed fn=pointer_fact_global_load subject=gp provenance=global_storage reason=none source={s}",
        .{c_source},
    );
    defer std.testing.allocator.free(llvm_comment);
    try expectContains(llvm_output.items, llvm_comment);
}

test "lower-c raw-many zero wrappers without MIR destination facts lower conservatively" {
    const source =
        \\global shared_counter: u32 = 0;
        \\
        \\fn c_raw_many_zero_grouped_requires_mir_fact() -> u32 {
        \\    unsafe {
        \\        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        let q: [*]mut u32 = (p.offset(0));
        \\        return q.*;
        \\    }
        \\}
        \\
        \\fn c_raw_many_zero_casted_requires_mir_fact() -> u32 {
        \\    unsafe {
        \\        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        let q: [*]mut u32 = p.offset(0) as [*]mut u32;
        \\        return q.*;
        \\    }
        \\}
        \\
        \\fn c_raw_many_zero_grouped_store_requires_mir_fact() -> u32 {
        \\    unsafe {
        \\        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        var q: [*]mut u32 = (p.offset(0));
        \\        q.* = 9;
        \\        return q.*;
        \\    }
        \\}
        \\
        \\fn c_raw_many_zero_casted_store_requires_mir_fact() -> u32 {
        \\    unsafe {
        \\        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        var q: [*]mut u32 = p.offset(0) as [*]mut u32;
        \\        q.* = 9;
        \\        return q.*;
        \\    }
        \\}
    ;

    var normal_output: std.ArrayList(u8) = .empty;
    defer normal_output.deinit(std.testing.allocator);
    try appendCheckedCTest("emit_c_raw_many_zero_wrappers.mc", source, &normal_output);
    const grouped_body = try cFunctionBody(normal_output.items, "static uint32_t c_raw_many_zero_grouped_requires_mir_fact(void)");
    try expectContains(grouped_body, "/* mir pointer_provenance consumed fn=c_raw_many_zero_grouped_requires_mir_fact subject=p provenance=global_storage reason=none source=");
    try expectContains(grouped_body, "/* mir pointer_provenance consumed fn=c_raw_many_zero_grouped_requires_mir_fact subject=q provenance=global_storage reason=none source=");
    try expectContains(grouped_body, "return ((uint32_t)mc_race_load_u32(q));");

    const casted_body = try cFunctionBody(normal_output.items, "static uint32_t c_raw_many_zero_casted_requires_mir_fact(void)");
    try expectContains(casted_body, "/* mir pointer_provenance consumed fn=c_raw_many_zero_casted_requires_mir_fact subject=p provenance=global_storage reason=none source=");
    try expectContains(casted_body, "/* mir pointer_provenance consumed fn=c_raw_many_zero_casted_requires_mir_fact subject=q provenance=global_storage reason=none source=");
    try expectContains(casted_body, "return ((uint32_t)mc_race_load_u32(q));");

    const grouped_store_body = try cFunctionBody(normal_output.items, "static uint32_t c_raw_many_zero_grouped_store_requires_mir_fact(void)");
    try expectContains(grouped_store_body, "/* mir pointer_provenance consumed fn=c_raw_many_zero_grouped_store_requires_mir_fact subject=q provenance=global_storage reason=none source=");
    try expectContains(grouped_store_body, "mc_race_store_u32(q, (uint32_t)9);");

    const casted_store_body = try cFunctionBody(normal_output.items, "static uint32_t c_raw_many_zero_casted_store_requires_mir_fact(void)");
    try expectContains(casted_store_body, "/* mir pointer_provenance consumed fn=c_raw_many_zero_casted_store_requires_mir_fact subject=q provenance=global_storage reason=none source=");
    try expectContains(casted_store_body, "mc_race_store_u32(q, (uint32_t)9);");

    var missing_grouped_output: std.ArrayList(u8) = .empty;
    defer missing_grouped_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_raw_many_zero_grouped_missing_provenance.mc", source, "c_raw_many_zero_grouped_requires_mir_fact", "q", &missing_grouped_output);
    const missing_grouped_body = try cFunctionBody(missing_grouped_output.items, "static uint32_t c_raw_many_zero_grouped_requires_mir_fact(void)");
    try expectContains(missing_grouped_body, "/* mir pointer_provenance consumed fn=c_raw_many_zero_grouped_requires_mir_fact subject=p provenance=global_storage reason=none source=");
    try expectNotContains(missing_grouped_body, "/* mir pointer_provenance consumed fn=c_raw_many_zero_grouped_requires_mir_fact subject=q");
    try expectContains(missing_grouped_body, "return ((uint32_t)mc_race_load_u32(q));");
    try expectNotContains(missing_grouped_body, "return *q;");

    var missing_casted_output: std.ArrayList(u8) = .empty;
    defer missing_casted_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_raw_many_zero_casted_missing_provenance.mc", source, "c_raw_many_zero_casted_requires_mir_fact", "q", &missing_casted_output);
    const missing_casted_body = try cFunctionBody(missing_casted_output.items, "static uint32_t c_raw_many_zero_casted_requires_mir_fact(void)");
    try expectContains(missing_casted_body, "/* mir pointer_provenance consumed fn=c_raw_many_zero_casted_requires_mir_fact subject=p provenance=global_storage reason=none source=");
    try expectNotContains(missing_casted_body, "/* mir pointer_provenance consumed fn=c_raw_many_zero_casted_requires_mir_fact subject=q");
    try expectContains(missing_casted_body, "return ((uint32_t)mc_race_load_u32(q));");
    try expectNotContains(missing_casted_body, "return *q;");

    var missing_grouped_store_output: std.ArrayList(u8) = .empty;
    defer missing_grouped_store_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_raw_many_zero_grouped_store_missing_provenance.mc", source, "c_raw_many_zero_grouped_store_requires_mir_fact", "q", &missing_grouped_store_output);
    const missing_grouped_store_body = try cFunctionBody(missing_grouped_store_output.items, "static uint32_t c_raw_many_zero_grouped_store_requires_mir_fact(void)");
    try expectContains(missing_grouped_store_body, "/* mir pointer_provenance consumed fn=c_raw_many_zero_grouped_store_requires_mir_fact subject=p provenance=global_storage reason=none source=");
    try expectNotContains(missing_grouped_store_body, "/* mir pointer_provenance consumed fn=c_raw_many_zero_grouped_store_requires_mir_fact subject=q");
    try expectContains(missing_grouped_store_body, "mc_race_store_u32(q, (uint32_t)9);");
    try expectNotContains(missing_grouped_store_body, "*q =");

    var missing_casted_store_output: std.ArrayList(u8) = .empty;
    defer missing_casted_store_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_raw_many_zero_casted_store_missing_provenance.mc", source, "c_raw_many_zero_casted_store_requires_mir_fact", "q", &missing_casted_store_output);
    const missing_casted_store_body = try cFunctionBody(missing_casted_store_output.items, "static uint32_t c_raw_many_zero_casted_store_requires_mir_fact(void)");
    try expectContains(missing_casted_store_body, "/* mir pointer_provenance consumed fn=c_raw_many_zero_casted_store_requires_mir_fact subject=p provenance=global_storage reason=none source=");
    try expectNotContains(missing_casted_store_body, "/* mir pointer_provenance consumed fn=c_raw_many_zero_casted_store_requires_mir_fact subject=q");
    try expectContains(missing_casted_store_body, "mc_race_store_u32(q, (uint32_t)9);");
    try expectNotContains(missing_casted_store_body, "*q =");
}

test "lower-c pointer-local copies without MIR destination facts lower conservatively" {
    const source =
        \\global shared_counter: u32 = 0;
        \\
        \\fn c_pointer_copy_requires_mir_fact() -> u32 {
        \\    let p: *mut u32 = &shared_counter;
        \\    let q: *mut u32 = p;
        \\    return q.*;
        \\}
        \\
        \\fn c_pointer_copy_assignment_requires_mir_fact() -> u32 {
        \\    let p: *mut u32 = &shared_counter;
        \\    var q: *mut u32 = &shared_counter;
        \\    q = p;
        \\    return q.*;
        \\}
        \\
        \\fn c_raw_many_copy_requires_mir_fact() -> u32 {
        \\    unsafe {
        \\        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        let q: [*]mut u32 = p;
        \\        return q.*;
        \\    }
        \\}
        \\
        \\fn c_raw_many_copy_assignment_requires_mir_fact() -> u32 {
        \\    unsafe {
        \\        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        var q: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        q = p;
        \\        return q.*;
        \\    }
        \\}
    ;

    var normal_output: std.ArrayList(u8) = .empty;
    defer normal_output.deinit(std.testing.allocator);
    try appendCheckedCTest("emit_c_pointer_copy_provenance.mc", source, &normal_output);
    const normal_body = try cFunctionBody(normal_output.items, "static uint32_t c_pointer_copy_requires_mir_fact(void)");
    try expectContains(normal_body, "/* mir pointer_provenance consumed fn=c_pointer_copy_requires_mir_fact subject=p provenance=global_storage reason=none source=");
    try expectContains(normal_body, "/* mir pointer_provenance consumed fn=c_pointer_copy_requires_mir_fact subject=q provenance=global_storage reason=none source=");
    try expectContains(normal_body, "return ((uint32_t)mc_race_load_u32(q));");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_pointer_copy_missing_provenance.mc", source, "c_pointer_copy_requires_mir_fact", "q", &missing_output);
    const missing_body = try cFunctionBody(missing_output.items, "static uint32_t c_pointer_copy_requires_mir_fact(void)");
    try expectContains(missing_body, "/* mir pointer_provenance consumed fn=c_pointer_copy_requires_mir_fact subject=p provenance=global_storage reason=none source=");
    try expectNotContains(missing_body, "/* mir pointer_provenance consumed fn=c_pointer_copy_requires_mir_fact subject=q");
    try expectContains(missing_body, "return ((uint32_t)mc_race_load_u32(q));");
    try expectNotContains(missing_body, "return *q;");

    var missing_assignment_output: std.ArrayList(u8) = .empty;
    defer missing_assignment_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_pointer_copy_missing_provenance.mc", source, "c_pointer_copy_assignment_requires_mir_fact", "q", &missing_assignment_output);
    const missing_assignment_body = try cFunctionBody(missing_assignment_output.items, "static uint32_t c_pointer_copy_assignment_requires_mir_fact(void)");
    try expectContains(missing_assignment_body, "/* mir pointer_provenance consumed fn=c_pointer_copy_assignment_requires_mir_fact subject=p provenance=global_storage reason=none source=");
    try expectNotContains(missing_assignment_body, "/* mir pointer_provenance consumed fn=c_pointer_copy_assignment_requires_mir_fact subject=q");
    try expectContains(missing_assignment_body, "return ((uint32_t)mc_race_load_u32(q));");
    try expectNotContains(missing_assignment_body, "return *q;");

    var missing_raw_output: std.ArrayList(u8) = .empty;
    defer missing_raw_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_pointer_copy_missing_provenance.mc", source, "c_raw_many_copy_requires_mir_fact", "q", &missing_raw_output);
    const missing_raw_body = try cFunctionBody(missing_raw_output.items, "static uint32_t c_raw_many_copy_requires_mir_fact(void)");
    try expectContains(missing_raw_body, "/* mir pointer_provenance consumed fn=c_raw_many_copy_requires_mir_fact subject=p provenance=global_storage reason=none source=");
    try expectNotContains(missing_raw_body, "/* mir pointer_provenance consumed fn=c_raw_many_copy_requires_mir_fact subject=q");
    try expectContains(missing_raw_body, "return ((uint32_t)mc_race_load_u32(q));");
    try expectNotContains(missing_raw_body, "return *q;");

    var missing_raw_assignment_output: std.ArrayList(u8) = .empty;
    defer missing_raw_assignment_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_pointer_copy_missing_provenance.mc", source, "c_raw_many_copy_assignment_requires_mir_fact", "q", &missing_raw_assignment_output);
    const missing_raw_assignment_body = try cFunctionBody(missing_raw_assignment_output.items, "static uint32_t c_raw_many_copy_assignment_requires_mir_fact(void)");
    try expectContains(missing_raw_assignment_body, "/* mir pointer_provenance consumed fn=c_raw_many_copy_assignment_requires_mir_fact subject=p provenance=global_storage reason=none source=");
    try expectNotContains(missing_raw_assignment_body, "/* mir pointer_provenance consumed fn=c_raw_many_copy_assignment_requires_mir_fact subject=q");
    try expectContains(missing_raw_assignment_body, "return ((uint32_t)mc_race_load_u32(q));");
    try expectNotContains(missing_raw_assignment_body, "return *q;");
}

test "lower-c consumes MIR facts for direct internal global pointer returns" {
    const source =
        \\global shared_counter: u32 = 0;
        \\fn returned_global_pointer() -> *mut u32 {
        \\    return &shared_counter;
        \\}
        \\export fn exported_global_pointer() -> *mut u32 {
        \\    return &shared_counter;
        \\}
        \\fn forwarded_global_pointer() -> *mut u32 {
        \\    return returned_global_pointer();
        \\}
        \\fn noalias_global_pointer() -> *mut u32 {
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        return compiler.assume_noalias_unchecked(&shared_counter, 4);
        \\    }
        \\}
        \\fn local_global_pointer() -> *mut u32 {
        \\    let gp: *mut u32 = &shared_counter;
        \\    return gp;
        \\}
        \\fn assigned_local_global_pointer() -> *mut u32 {
        \\    var gp: *mut u32 = &shared_counter;
        \\    gp = returned_global_pointer();
        \\    return gp;
        \\}
        \\fn mixed_local_pointer(fallback: *mut u32) -> *mut u32 {
        \\    var gp: *mut u32 = &shared_counter;
        \\    gp = fallback;
        \\    return gp;
        \\}
        \\fn branched_global_pointer(flag: bool) -> *mut u32 {
        \\    if flag { return &shared_counter; } else { return &shared_counter; }
        \\}
        \\fn c_uses_global_pointer_through_alias() -> u32 {
        \\    let producer: fn() -> *mut u32 = returned_global_pointer;
        \\    let gp: *mut u32 = producer();
        \\    return gp.*;
        \\}
        \\fn c_uses_callback_pointer_return(producer: fn() -> *mut u32) -> u32 {
        \\    let gp: *mut u32 = producer();
        \\    return gp.*;
        \\}
        \\fn c_uses_exported_global_pointer() -> u32 {
        \\    let gp: *mut u32 = exported_global_pointer();
        \\    return gp.*;
        \\}
        \\fn c_uses_returned_global_pointer() -> u32 {
        \\    let gp: *mut u32 = returned_global_pointer();
        \\    return gp.*;
        \\}
        \\fn c_uses_forwarded_global_pointer() -> u32 {
        \\    let gp: *mut u32 = forwarded_global_pointer();
        \\    return gp.*;
        \\}
        \\fn c_uses_noalias_global_pointer() -> u32 {
        \\    let gp: *mut u32 = noalias_global_pointer();
        \\    return gp.*;
        \\}
        \\fn c_uses_local_global_pointer() -> u32 {
        \\    let gp: *mut u32 = local_global_pointer();
        \\    return gp.*;
        \\}
        \\fn c_uses_assigned_local_global_pointer() -> u32 {
        \\    let gp: *mut u32 = assigned_local_global_pointer();
        \\    return gp.*;
        \\}
        \\fn c_uses_mixed_local_pointer(fallback: *mut u32) -> u32 {
        \\    let gp: *mut u32 = mixed_local_pointer(fallback);
        \\    return gp.*;
        \\}
        \\fn c_uses_branched_global_pointer(flag: bool) -> u32 {
        \\    let gp: *mut u32 = branched_global_pointer(flag);
        \\    return gp.*;
        \\}
        \\fn c_assigns_returned_global_pointer() -> u32 {
        \\    var gp: *mut u32 = &shared_counter;
        \\    gp = returned_global_pointer();
        \\    return gp.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("emit_c_pointer_return_provenance.mc", source, &output);
    try expectContains(output.items, "/* mir pointer_provenance consumed fn=c_uses_returned_global_pointer subject=gp provenance=global_storage reason=none source=");
    try expectContains(output.items, "/* mir pointer_provenance consumed fn=c_assigns_returned_global_pointer subject=gp provenance=global_storage reason=reassignment source=");
    try expectContains(output.items, "mc_race_load_u32(gp)");
    try expectContains(output.items, "/* mir pointer_provenance consumed fn=c_uses_forwarded_global_pointer subject=gp provenance=global_storage reason=none source=");
    try expectContains(output.items, "/* mir pointer_provenance consumed fn=c_uses_noalias_global_pointer subject=gp provenance=global_storage reason=none source=");
    try expectContains(output.items, "/* mir pointer_provenance consumed fn=c_uses_local_global_pointer subject=gp provenance=global_storage reason=none source=");
    try expectContains(output.items, "/* mir pointer_provenance consumed fn=c_uses_assigned_local_global_pointer subject=gp provenance=global_storage reason=none source=");
    try expectNotContains(output.items, "/* mir pointer_provenance consumed fn=c_uses_mixed_local_pointer subject=gp provenance=global_storage reason=none source=");
    try expectContains(output.items, "/* mir pointer_provenance consumed fn=c_uses_branched_global_pointer subject=gp provenance=global_storage reason=none source=");
    try expectContains(output.items, "/* mir pointer_provenance consumed fn=c_uses_global_pointer_through_alias subject=gp provenance=global_storage reason=none source=");
    try expectNotContains(output.items, "/* mir pointer_provenance consumed fn=c_uses_callback_pointer_return subject=gp provenance=global_storage reason=none source=");
    try expectNotContains(output.items, "/* mir pointer_provenance consumed fn=c_uses_exported_global_pointer subject=gp provenance=global_storage reason=none source=");

    const callback_body = try cFunctionBody(output.items, "static uint32_t c_uses_callback_pointer_return(");
    try expectContains(callback_body, "return ((uint32_t)mc_race_load_u32(gp));");
    try expectNotContains(callback_body, "return *gp;");

    const exported_body = try cFunctionBody(output.items, "static uint32_t c_uses_exported_global_pointer(void)");
    try expectContains(exported_body, "exported_global_pointer()");
    try expectContains(exported_body, "return ((uint32_t)mc_race_load_u32(gp));");
    try expectNotContains(exported_body, "return *gp;");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_pointer_return_provenance.mc", source, "c_uses_returned_global_pointer", "gp", &missing_output);
    try expectNotContains(missing_output.items, "/* mir pointer_provenance consumed fn=c_uses_returned_global_pointer subject=gp provenance=global_storage reason=none source=");
    try expectContains(missing_output.items, "mc_race_load_u32(gp)");

    var missing_forwarded_output: std.ArrayList(u8) = .empty;
    defer missing_forwarded_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_pointer_return_provenance.mc", source, "c_uses_forwarded_global_pointer", "gp", &missing_forwarded_output);
    try expectNotContains(missing_forwarded_output.items, "/* mir pointer_provenance consumed fn=c_uses_forwarded_global_pointer subject=gp provenance=global_storage reason=none source=");
    try expectContains(missing_forwarded_output.items, "mc_race_load_u32(gp)");

    var missing_noalias_output: std.ArrayList(u8) = .empty;
    defer missing_noalias_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_pointer_return_provenance.mc", source, "c_uses_noalias_global_pointer", "gp", &missing_noalias_output);
    try expectNotContains(missing_noalias_output.items, "/* mir pointer_provenance consumed fn=c_uses_noalias_global_pointer subject=gp provenance=global_storage reason=none source=");
    try expectContains(missing_noalias_output.items, "mc_race_load_u32(gp)");

    var missing_local_output: std.ArrayList(u8) = .empty;
    defer missing_local_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_pointer_return_provenance.mc", source, "c_uses_local_global_pointer", "gp", &missing_local_output);
    try expectNotContains(missing_local_output.items, "/* mir pointer_provenance consumed fn=c_uses_local_global_pointer subject=gp provenance=global_storage reason=none source=");
    try expectContains(missing_local_output.items, "mc_race_load_u32(gp)");
}

test "lower-c direct pointer locals without MIR destination facts lower conservatively" {
    const source =
        \\global shared_counter: u32 = 0;
        \\
        \\fn c_direct_initializer_requires_mir_fact() -> u32 {
        \\    let p: *mut u32 = &shared_counter;
        \\    return p.*;
        \\}
        \\
        \\fn c_direct_assignment_requires_mir_fact() -> u32 {
        \\    var local: u32 = 1;
        \\    var p: *mut u32 = &local;
        \\    p = &shared_counter;
        \\    return p.*;
        \\}
    ;

    var normal_output: std.ArrayList(u8) = .empty;
    defer normal_output.deinit(std.testing.allocator);
    try appendCheckedCTest("emit_c_direct_pointer_provenance.mc", source, &normal_output);
    const normal_initializer_body = try cFunctionBody(normal_output.items, "static uint32_t c_direct_initializer_requires_mir_fact(void)");
    try expectContains(normal_initializer_body, "/* mir pointer_provenance consumed fn=c_direct_initializer_requires_mir_fact subject=p provenance=global_storage reason=none source=");
    try expectContains(normal_initializer_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(normal_initializer_body, "return *p;");

    const normal_assignment_body = try cFunctionBody(normal_output.items, "static uint32_t c_direct_assignment_requires_mir_fact(void)");
    try expectContains(normal_assignment_body, "/* mir pointer_provenance consumed fn=c_direct_assignment_requires_mir_fact subject=p provenance=local_storage reason=none source=");
    try expectContains(normal_assignment_body, "/* mir pointer_provenance consumed fn=c_direct_assignment_requires_mir_fact subject=p provenance=global_storage reason=reassignment source=");
    try expectContains(normal_assignment_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(normal_assignment_body, "return *p;");

    var missing_initializer_output: std.ArrayList(u8) = .empty;
    defer missing_initializer_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_direct_pointer_missing_provenance.mc", source, "c_direct_initializer_requires_mir_fact", "p", &missing_initializer_output);
    const missing_initializer_body = try cFunctionBody(missing_initializer_output.items, "static uint32_t c_direct_initializer_requires_mir_fact(void)");
    try expectNotContains(missing_initializer_body, "/* mir pointer_provenance consumed fn=c_direct_initializer_requires_mir_fact subject=p");
    try expectContains(missing_initializer_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(missing_initializer_body, "return *p;");

    var missing_assignment_output: std.ArrayList(u8) = .empty;
    defer missing_assignment_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_direct_pointer_missing_provenance.mc", source, "c_direct_assignment_requires_mir_fact", "p", &missing_assignment_output);
    const missing_assignment_body = try cFunctionBody(missing_assignment_output.items, "static uint32_t c_direct_assignment_requires_mir_fact(void)");
    try expectNotContains(missing_assignment_body, "/* mir pointer_provenance consumed fn=c_direct_assignment_requires_mir_fact subject=p");
    try expectContains(missing_assignment_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(missing_assignment_body, "return *p;");
}

test "lower-c noalias direct pointers without MIR destination facts lower conservatively" {
    const source =
        \\global shared_counter: u32 = 0;
        \\
        \\fn c_noalias_initializer_requires_mir_fact() -> u32 {
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        let p: *mut u32 = compiler.assume_noalias_unchecked(&shared_counter, 4);
        \\        return p.*;
        \\    }
        \\}
        \\
        \\fn c_noalias_assignment_requires_mir_fact() -> u32 {
        \\    var local: u32 = 1;
        \\    var p: *mut u32 = &local;
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        p = compiler.assume_noalias_unchecked(&shared_counter, 4);
        \\    }
        \\    return p.*;
        \\}
        \\
        \\fn c_noalias_pointer_copy_requires_mir_fact() -> u32 {
        \\    let p: *mut u32 = &shared_counter;
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        let q: *mut u32 = compiler.assume_noalias_unchecked(p, 4);
        \\        return q.*;
        \\    }
        \\}
        \\
        \\fn c_noalias_local_requires_mir_fact() -> u32 {
        \\    var local: u32 = 1;
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        let p: *mut u32 = compiler.assume_noalias_unchecked(&local, 4);
        \\        p.* = 9;
        \\        return p.*;
        \\    }
        \\}
    ;

    var normal_output: std.ArrayList(u8) = .empty;
    defer normal_output.deinit(std.testing.allocator);
    try appendCheckedCTest("emit_c_noalias_pointer_provenance.mc", source, &normal_output);
    const normal_initializer_body = try cFunctionBody(normal_output.items, "static uint32_t c_noalias_initializer_requires_mir_fact(void)");
    try expectContains(normal_initializer_body, "/* mir pointer_provenance consumed fn=c_noalias_initializer_requires_mir_fact subject=p provenance=global_storage reason=none source=");
    try expectContains(normal_initializer_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(normal_initializer_body, "return *p;");

    const normal_assignment_body = try cFunctionBody(normal_output.items, "static uint32_t c_noalias_assignment_requires_mir_fact(void)");
    try expectContains(normal_assignment_body, "/* mir pointer_provenance consumed fn=c_noalias_assignment_requires_mir_fact subject=p provenance=global_storage reason=reassignment source=");
    try expectContains(normal_assignment_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(normal_assignment_body, "return *p;");

    const normal_pointer_copy_body = try cFunctionBody(normal_output.items, "static uint32_t c_noalias_pointer_copy_requires_mir_fact(void)");
    try expectContains(normal_pointer_copy_body, "/* mir pointer_provenance consumed fn=c_noalias_pointer_copy_requires_mir_fact subject=p provenance=global_storage reason=none source=");
    try expectContains(normal_pointer_copy_body, "/* mir pointer_provenance consumed fn=c_noalias_pointer_copy_requires_mir_fact subject=q provenance=global_storage reason=none source=");
    try expectContains(normal_pointer_copy_body, "return ((uint32_t)mc_race_load_u32(q));");
    try expectNotContains(normal_pointer_copy_body, "return *q;");

    const normal_local_body = try cFunctionBody(normal_output.items, "static uint32_t c_noalias_local_requires_mir_fact(void)");
    try expectContains(normal_local_body, "/* mir pointer_provenance consumed fn=c_noalias_local_requires_mir_fact subject=p provenance=local_storage reason=none source=");
    try expectContains(normal_local_body, "*p = 9;");
    try expectContains(normal_local_body, "return *p;");
    try expectNotContains(normal_local_body, "mc_race_load_u32(p)");
    try expectNotContains(normal_local_body, "mc_race_store_u32(p");

    var missing_initializer_output: std.ArrayList(u8) = .empty;
    defer missing_initializer_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_noalias_pointer_missing_provenance.mc", source, "c_noalias_initializer_requires_mir_fact", "p", &missing_initializer_output);
    const missing_initializer_body = try cFunctionBody(missing_initializer_output.items, "static uint32_t c_noalias_initializer_requires_mir_fact(void)");
    try expectNotContains(missing_initializer_body, "/* mir pointer_provenance consumed fn=c_noalias_initializer_requires_mir_fact subject=p");
    try expectContains(missing_initializer_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(missing_initializer_body, "return *p;");

    var missing_assignment_output: std.ArrayList(u8) = .empty;
    defer missing_assignment_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_noalias_pointer_missing_provenance.mc", source, "c_noalias_assignment_requires_mir_fact", "p", &missing_assignment_output);
    const missing_assignment_body = try cFunctionBody(missing_assignment_output.items, "static uint32_t c_noalias_assignment_requires_mir_fact(void)");
    try expectNotContains(missing_assignment_body, "/* mir pointer_provenance consumed fn=c_noalias_assignment_requires_mir_fact subject=p");
    try expectContains(missing_assignment_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(missing_assignment_body, "return *p;");

    var missing_pointer_copy_output: std.ArrayList(u8) = .empty;
    defer missing_pointer_copy_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_noalias_pointer_missing_provenance.mc", source, "c_noalias_pointer_copy_requires_mir_fact", "q", &missing_pointer_copy_output);
    const missing_pointer_copy_body = try cFunctionBody(missing_pointer_copy_output.items, "static uint32_t c_noalias_pointer_copy_requires_mir_fact(void)");
    try expectContains(missing_pointer_copy_body, "/* mir pointer_provenance consumed fn=c_noalias_pointer_copy_requires_mir_fact subject=p provenance=global_storage reason=none source=");
    try expectNotContains(missing_pointer_copy_body, "/* mir pointer_provenance consumed fn=c_noalias_pointer_copy_requires_mir_fact subject=q");
    try expectContains(missing_pointer_copy_body, "return ((uint32_t)mc_race_load_u32(q));");
    try expectNotContains(missing_pointer_copy_body, "return *q;");

    var missing_local_output: std.ArrayList(u8) = .empty;
    defer missing_local_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_noalias_pointer_missing_provenance.mc", source, "c_noalias_local_requires_mir_fact", "p", &missing_local_output);
    const missing_local_body = try cFunctionBody(missing_local_output.items, "static uint32_t c_noalias_local_requires_mir_fact(void)");
    try expectNotContains(missing_local_body, "/* mir pointer_provenance consumed fn=c_noalias_local_requires_mir_fact subject=p");
    try expectContains(missing_local_body, "mc_race_store_u32(p,");
    try expectContains(missing_local_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(missing_local_body, "return *p;");
}

test "lower-c consumes MIR pointer provenance facts for fixed pointer-array elements" {
    const source =
        \\global shared_counter: u32 = 0;
        \\
        \\fn c_array_global_pointer_element_load() -> u32 {
        \\    let ptrs: [2]*mut u32 = .{ &shared_counter, &shared_counter };
        \\    let p: *mut u32 = ptrs[0];
        \\    return p.*;
        \\}
        \\
        \\fn c_array_assigned_global_pointer_element_load() -> u32 {
        \\    var local: u32 = 16;
        \\    var ptrs: [2]*mut u32 = .{ &local, &local };
        \\    ptrs[0] = &shared_counter;
        \\    let p: *mut u32 = ptrs[0];
        \\    return p.*;
        \\}
        \\
        \\fn c_array_noalias_pointer_element_load() -> u32 {
        \\    let ptrs: [2]*mut u32 = .{ &shared_counter, &shared_counter };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        let p: *mut u32 = compiler.assume_noalias_unchecked(ptrs[0], 4);
        \\        return p.*;
        \\    }
        \\}
        \\
        \\fn c_array_stack_pointer_element_stays_plain() -> u32 {
        \\    var local: u32 = 17;
        \\    let ptrs: [2]*mut u32 = .{ &local, &local };
        \\    let p: *mut u32 = ptrs[0];
        \\    return p.*;
        \\}
        \\
        \\fn c_array_dynamic_assignment_clears_pointer_element_fact(index: usize) -> u32 {
        \\    var local: u32 = 20;
        \\    var ptrs: [2]*mut u32 = .{ &shared_counter, &shared_counter };
        \\    ptrs[index] = &local;
        \\    let dynamic_p: *mut u32 = ptrs[index];
        \\    let constant_p: *mut u32 = ptrs[0];
        \\    return dynamic_p.* + constant_p.*;
        \\}
        \\
        \\fn c_array_pointer_copy_element_direct_deref() -> u32 {
        \\    var local: u32 = 21;
        \\    var ptrs: [2]*mut u32 = .{ &local, &local };
        \\    let gp: *mut u32 = &shared_counter;
        \\    ptrs[0] = gp;
        \\    return ptrs[0].*;
        \\}
    ;

    var parsed = try test_support.parseModule("emit_c_pointer_array_provenance.mc", source);
    defer parsed.deinit();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, parsed.module, &output);

    const global_body = try cFunctionBody(output.items, "static uint32_t c_array_global_pointer_element_load(void)");
    try expectContains(global_body, "/* mir pointer_provenance consumed fn=c_array_global_pointer_element_load subject=ptrs element=0 provenance=global_storage reason=none source=");
    try expectContains(global_body, "/* mir pointer_provenance consumed fn=c_array_global_pointer_element_load subject=p provenance=global_storage reason=none source=");
    try expectContains(global_body, "return ((uint32_t)mc_race_load_u32(p));");

    const assigned_body = try cFunctionBody(output.items, "static uint32_t c_array_assigned_global_pointer_element_load(void)");
    try expectContains(assigned_body, "/* mir pointer_provenance consumed fn=c_array_assigned_global_pointer_element_load subject=ptrs element=0 provenance=global_storage reason=reassignment source=");
    try expectContains(assigned_body, "/* mir pointer_provenance consumed fn=c_array_assigned_global_pointer_element_load subject=p provenance=global_storage reason=none source=");
    try expectContains(assigned_body, "return ((uint32_t)mc_race_load_u32(p));");

    const noalias_body = try cFunctionBody(output.items, "static uint32_t c_array_noalias_pointer_element_load(void)");
    try expectContains(noalias_body, "/* mir pointer_provenance consumed fn=c_array_noalias_pointer_element_load subject=ptrs element=0 provenance=global_storage reason=none source=");
    try expectContains(noalias_body, "/* mir pointer_provenance consumed fn=c_array_noalias_pointer_element_load subject=p provenance=global_storage reason=none source=");
    try expectContains(noalias_body, "return ((uint32_t)mc_race_load_u32(p));");

    const stack_body = try cFunctionBody(output.items, "static uint32_t c_array_stack_pointer_element_stays_plain(void)");
    try expectContains(stack_body, "/* mir pointer_provenance consumed fn=c_array_stack_pointer_element_stays_plain subject=ptrs element=0 provenance=local_storage reason=none source=");
    try expectContains(stack_body, "/* mir pointer_provenance consumed fn=c_array_stack_pointer_element_stays_plain subject=p provenance=local_storage reason=none source=");
    try expectContains(stack_body, "return *p;");
    try expectNotContains(stack_body, "mc_race_load_u32(p)");

    const dynamic_body = try cFunctionBody(output.items, "static uint32_t c_array_dynamic_assignment_clears_pointer_element_fact(uintptr_t index)");
    try expectContains(dynamic_body, "/* mir pointer_provenance consumed fn=c_array_dynamic_assignment_clears_pointer_element_fact subject=ptrs provenance=unknown reason=dynamic_index_write source=");
    try expectContains(dynamic_body, "mc_race_load_u32(dynamic_p)");
    try expectContains(dynamic_body, "mc_race_load_u32(constant_p)");
    try expectNotContains(dynamic_body, "*dynamic_p");
    try expectNotContains(dynamic_body, "*constant_p");

    const pointer_copy_direct_body = try cFunctionBody(output.items, "static uint32_t c_array_pointer_copy_element_direct_deref(void)");
    try expectContains(pointer_copy_direct_body, "/* mir pointer_provenance consumed fn=c_array_pointer_copy_element_direct_deref subject=gp provenance=global_storage reason=none source=");
    try expectContains(pointer_copy_direct_body, "/* mir pointer_provenance consumed fn=c_array_pointer_copy_element_direct_deref subject=ptrs element=0 provenance=global_storage reason=reassignment source=");
    try expectContains(pointer_copy_direct_body, "return ((uint32_t)mc_race_load_u32(ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(pointer_copy_direct_body, "return *ptrs.elems[mc_check_index_usize(0, 2)];");

    var mir_dump: std.ArrayList(u8) = .empty;
    defer mir_dump.deinit(std.testing.allocator);
    try mir.appendDump(std.testing.allocator, parsed.module, &mir_dump);
    try expectCCommentSourceMatchesMirFact(
        output.items,
        mir_dump.items,
        "/* mir pointer_provenance consumed fn=c_array_global_pointer_element_load subject=ptrs element=0 provenance=global_storage reason=none source=",
        "mir pointer_provenance_fact fn=c_array_global_pointer_element_load subject=ptrs element=0 provenance=global_storage storage=shared_counter",
    );

    var llvm_output: std.ArrayList(u8) = .empty;
    defer llvm_output.deinit(std.testing.allocator);
    try lower_llvm.appendLlvm(std.testing.allocator, parsed.module, &llvm_output);
    const c_source = try commentSourceText(output.items, "/* mir pointer_provenance consumed fn=c_array_global_pointer_element_load subject=ptrs element=0 provenance=global_storage reason=none source=");
    const llvm_comment = try std.fmt.allocPrint(
        std.testing.allocator,
        "; mir pointer_provenance consumed fn=c_array_global_pointer_element_load subject=ptrs element=0 provenance=global_storage reason=none source={s}",
        .{c_source},
    );
    defer std.testing.allocator.free(llvm_comment);
    try expectContains(llvm_output.items, llvm_comment);
    try expectContains(llvm_output.items, "; mir pointer_provenance consumed fn=c_array_global_pointer_element_load subject=p provenance=global_storage reason=none");
}

test "lower-c fixed pointer-array element reads without MIR destination fact lower conservatively" {
    const source =
        \\global shared_counter: u32 = 0;
        \\
        \\fn c_pointer_array_element_read_requires_mir_fact() -> u32 {
        \\    let ptrs: [2]*mut u32 = .{ &shared_counter, &shared_counter };
        \\    let p: *mut u32 = ptrs[0];
        \\    return p.*;
        \\}
        \\
        \\fn c_pointer_array_element_assignment_requires_mir_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var ptrs: [2]*mut u32 = .{ &local, &local };
        \\    ptrs[0] = &shared_counter;
        \\    var p: *mut u32 = &local;
        \\    p = ptrs[0];
        \\    return p.*;
        \\}
        \\
        \\fn c_pointer_array_element_noalias_read_requires_mir_fact() -> u32 {
        \\    let ptrs: [2]*mut u32 = .{ &shared_counter, &shared_counter };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        let p: *mut u32 = compiler.assume_noalias_unchecked(ptrs[0], 4);
        \\        return p.*;
        \\    }
        \\}
        \\
        \\fn c_pointer_array_element_cast_noalias_read_requires_mir_fact() -> u32 {
        \\    let ptrs: [2]*mut u32 = .{ &shared_counter, &shared_counter };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        let p: *mut u32 = compiler.assume_noalias_unchecked(ptrs[0], 4) as *mut u32;
        \\        return p.*;
        \\    }
        \\}
        \\
        \\fn c_pointer_array_element_pointer_copy_direct_deref_requires_mir_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var ptrs: [2]*mut u32 = .{ &local, &local };
        \\    let gp: *mut u32 = &shared_counter;
        \\    ptrs[0] = gp;
        \\    return ptrs[0].*;
        \\}
        \\
        \\fn c_pointer_array_element_local_pointer_copy_direct_deref_requires_mir_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var other: u32 = 0;
        \\    var ptrs: [2]*mut u32 = .{ &other, &other };
        \\    let lp: *mut u32 = &local;
        \\    ptrs[0] = lp;
        \\    return ptrs[0].*;
        \\}
        \\
        \\fn c_pointer_array_element_local_pointer_copy_direct_store_requires_mir_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var other: u32 = 0;
        \\    var ptrs: [2]*mut u32 = .{ &other, &other };
        \\    let lp: *mut u32 = &local;
        \\    ptrs[0] = lp;
        \\    ptrs[0].* = 9;
        \\    return local;
        \\}
    ;

    var normal_output: std.ArrayList(u8) = .empty;
    defer normal_output.deinit(std.testing.allocator);
    try appendCheckedCTest("emit_c_pointer_array_element_provenance_required.mc", source, &normal_output);
    const normal_body = try cFunctionBody(normal_output.items, "static uint32_t c_pointer_array_element_read_requires_mir_fact(void)");
    try expectContains(normal_body, "/* mir pointer_provenance consumed fn=c_pointer_array_element_read_requires_mir_fact subject=ptrs element=0 provenance=global_storage reason=none source=");
    try expectContains(normal_body, "/* mir pointer_provenance consumed fn=c_pointer_array_element_read_requires_mir_fact subject=p provenance=global_storage reason=none source=");
    try expectContains(normal_body, "return ((uint32_t)mc_race_load_u32(p));");

    const normal_cast_noalias_body = try cFunctionBody(normal_output.items, "static uint32_t c_pointer_array_element_cast_noalias_read_requires_mir_fact(void)");
    try expectContains(normal_cast_noalias_body, "/* mir pointer_provenance consumed fn=c_pointer_array_element_cast_noalias_read_requires_mir_fact subject=ptrs element=0 provenance=global_storage reason=none source=");
    try expectContains(normal_cast_noalias_body, "/* mir pointer_provenance consumed fn=c_pointer_array_element_cast_noalias_read_requires_mir_fact subject=p provenance=global_storage reason=none source=");
    try expectContains(normal_cast_noalias_body, "return ((uint32_t)mc_race_load_u32(p));");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_pointer_array_element_missing_provenance.mc", source, "c_pointer_array_element_read_requires_mir_fact", "p", &missing_output);
    const missing_body = try cFunctionBody(missing_output.items, "static uint32_t c_pointer_array_element_read_requires_mir_fact(void)");
    try expectContains(missing_body, "/* mir pointer_provenance consumed fn=c_pointer_array_element_read_requires_mir_fact subject=ptrs element=0 provenance=global_storage reason=none source=");
    try expectNotContains(missing_body, "/* mir pointer_provenance consumed fn=c_pointer_array_element_read_requires_mir_fact subject=p provenance");
    try expectContains(missing_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(missing_body, "return *p;");

    var missing_assignment_output: std.ArrayList(u8) = .empty;
    defer missing_assignment_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_pointer_array_element_missing_provenance.mc", source, "c_pointer_array_element_assignment_requires_mir_fact", "p", &missing_assignment_output);
    const missing_assignment_body = try cFunctionBody(missing_assignment_output.items, "static uint32_t c_pointer_array_element_assignment_requires_mir_fact(void)");
    try expectContains(missing_assignment_body, "/* mir pointer_provenance consumed fn=c_pointer_array_element_assignment_requires_mir_fact subject=ptrs element=0 provenance=global_storage reason=reassignment source=");
    try expectNotContains(missing_assignment_body, "/* mir pointer_provenance consumed fn=c_pointer_array_element_assignment_requires_mir_fact subject=p provenance");
    try expectContains(missing_assignment_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(missing_assignment_body, "return *p;");

    var missing_noalias_output: std.ArrayList(u8) = .empty;
    defer missing_noalias_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_pointer_array_element_noalias_missing_provenance.mc", source, "c_pointer_array_element_noalias_read_requires_mir_fact", "p", &missing_noalias_output);
    const missing_noalias_body = try cFunctionBody(missing_noalias_output.items, "static uint32_t c_pointer_array_element_noalias_read_requires_mir_fact(void)");
    try expectContains(missing_noalias_body, "/* mir pointer_provenance consumed fn=c_pointer_array_element_noalias_read_requires_mir_fact subject=ptrs element=0 provenance=global_storage reason=none source=");
    try expectNotContains(missing_noalias_body, "/* mir pointer_provenance consumed fn=c_pointer_array_element_noalias_read_requires_mir_fact subject=p provenance");
    try expectContains(missing_noalias_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(missing_noalias_body, "return *p;");

    var missing_cast_noalias_output: std.ArrayList(u8) = .empty;
    defer missing_cast_noalias_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_pointer_array_element_cast_noalias_missing_provenance.mc", source, "c_pointer_array_element_cast_noalias_read_requires_mir_fact", "p", &missing_cast_noalias_output);
    const missing_cast_noalias_body = try cFunctionBody(missing_cast_noalias_output.items, "static uint32_t c_pointer_array_element_cast_noalias_read_requires_mir_fact(void)");
    try expectContains(missing_cast_noalias_body, "/* mir pointer_provenance consumed fn=c_pointer_array_element_cast_noalias_read_requires_mir_fact subject=ptrs element=0 provenance=global_storage reason=none source=");
    try expectNotContains(missing_cast_noalias_body, "/* mir pointer_provenance consumed fn=c_pointer_array_element_cast_noalias_read_requires_mir_fact subject=p provenance");
    try expectContains(missing_cast_noalias_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(missing_cast_noalias_body, "return *p;");

    var missing_pointer_copy_direct_output: std.ArrayList(u8) = .empty;
    defer missing_pointer_copy_direct_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_pointer_array_element_missing_provenance.mc", source, "c_pointer_array_element_pointer_copy_direct_deref_requires_mir_fact", "ptrs", &missing_pointer_copy_direct_output);
    const missing_pointer_copy_direct_body = try cFunctionBody(missing_pointer_copy_direct_output.items, "static uint32_t c_pointer_array_element_pointer_copy_direct_deref_requires_mir_fact(void)");
    try expectContains(missing_pointer_copy_direct_body, "/* mir pointer_provenance consumed fn=c_pointer_array_element_pointer_copy_direct_deref_requires_mir_fact subject=gp provenance=global_storage reason=none source=");
    try expectNotContains(missing_pointer_copy_direct_body, "/* mir pointer_provenance consumed fn=c_pointer_array_element_pointer_copy_direct_deref_requires_mir_fact subject=ptrs element=0 provenance");
    try expectContains(missing_pointer_copy_direct_body, "return ((uint32_t)mc_race_load_u32(ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(missing_pointer_copy_direct_body, "return *ptrs.elems[mc_check_index_usize(0, 2)];");

    const normal_local_pointer_copy_direct_body = try cFunctionBody(normal_output.items, "static uint32_t c_pointer_array_element_local_pointer_copy_direct_deref_requires_mir_fact(void)");
    try expectContains(normal_local_pointer_copy_direct_body, "/* mir pointer_provenance consumed fn=c_pointer_array_element_local_pointer_copy_direct_deref_requires_mir_fact subject=lp provenance=local_storage reason=none source=");
    try expectContains(normal_local_pointer_copy_direct_body, "/* mir pointer_provenance consumed fn=c_pointer_array_element_local_pointer_copy_direct_deref_requires_mir_fact subject=ptrs element=0 provenance=local_storage reason=reassignment source=");
    try expectContains(normal_local_pointer_copy_direct_body, "return *ptrs.elems[mc_check_index_usize(0, 2)];");
    try expectNotContains(normal_local_pointer_copy_direct_body, "return ((uint32_t)mc_race_load_u32(ptrs.elems[mc_check_index_usize(0, 2)]));");

    var missing_local_pointer_copy_direct_output: std.ArrayList(u8) = .empty;
    defer missing_local_pointer_copy_direct_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_pointer_array_element_missing_local_pointer_copy_provenance.mc", source, "c_pointer_array_element_local_pointer_copy_direct_deref_requires_mir_fact", "ptrs", &missing_local_pointer_copy_direct_output);
    const missing_local_pointer_copy_direct_body = try cFunctionBody(missing_local_pointer_copy_direct_output.items, "static uint32_t c_pointer_array_element_local_pointer_copy_direct_deref_requires_mir_fact(void)");
    try expectContains(missing_local_pointer_copy_direct_body, "/* mir pointer_provenance consumed fn=c_pointer_array_element_local_pointer_copy_direct_deref_requires_mir_fact subject=lp provenance=local_storage reason=none source=");
    try expectNotContains(missing_local_pointer_copy_direct_body, "/* mir pointer_provenance consumed fn=c_pointer_array_element_local_pointer_copy_direct_deref_requires_mir_fact subject=ptrs element=0 provenance");
    try expectContains(missing_local_pointer_copy_direct_body, "return ((uint32_t)mc_race_load_u32(ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(missing_local_pointer_copy_direct_body, "return *ptrs.elems[mc_check_index_usize(0, 2)];");

    const normal_local_pointer_copy_store_body = try cFunctionBody(normal_output.items, "static uint32_t c_pointer_array_element_local_pointer_copy_direct_store_requires_mir_fact(void)");
    try expectContains(normal_local_pointer_copy_store_body, "/* mir pointer_provenance consumed fn=c_pointer_array_element_local_pointer_copy_direct_store_requires_mir_fact subject=lp provenance=local_storage reason=none source=");
    try expectContains(normal_local_pointer_copy_store_body, "/* mir pointer_provenance consumed fn=c_pointer_array_element_local_pointer_copy_direct_store_requires_mir_fact subject=ptrs element=0 provenance=local_storage reason=reassignment source=");
    try expectNotContains(normal_local_pointer_copy_store_body, "mc_race_store_u32(ptrs.elems[mc_check_index_usize(0, 2)]");

    var missing_local_pointer_copy_store_output: std.ArrayList(u8) = .empty;
    defer missing_local_pointer_copy_store_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_pointer_array_element_missing_local_pointer_copy_store_provenance.mc", source, "c_pointer_array_element_local_pointer_copy_direct_store_requires_mir_fact", "ptrs", &missing_local_pointer_copy_store_output);
    const missing_local_pointer_copy_store_body = try cFunctionBody(missing_local_pointer_copy_store_output.items, "static uint32_t c_pointer_array_element_local_pointer_copy_direct_store_requires_mir_fact(void)");
    try expectContains(missing_local_pointer_copy_store_body, "/* mir pointer_provenance consumed fn=c_pointer_array_element_local_pointer_copy_direct_store_requires_mir_fact subject=lp provenance=local_storage reason=none source=");
    try expectNotContains(missing_local_pointer_copy_store_body, "/* mir pointer_provenance consumed fn=c_pointer_array_element_local_pointer_copy_direct_store_requires_mir_fact subject=ptrs element=0 provenance");
    try expectContains(missing_local_pointer_copy_store_body, "mc_race_store_u32(ptrs.elems[mc_check_index_usize(0, 2)]");
}

test "lower-c consumes MIR pointer provenance facts for aggregate pointer reads" {
    const source =
        \\global shared_counter: u32 = 0;
        \\
        \\struct Holder {
        \\    ptr: *mut u32,
        \\    ptrs: [2]*mut u32,
        \\}
        \\struct Inner {
        \\    ptr: *mut u32,
        \\    ptrs: [2]*mut u32,
        \\}
        \\struct Outer {
        \\    inner: Inner,
        \\}
        \\
        \\fn c_aggregate_pointer_field_load() -> u32 {
        \\    let holder: Holder = .{ .ptr = &shared_counter, .ptrs = .{ &shared_counter, &shared_counter } };
        \\    let p: *mut u32 = holder.ptr;
        \\    return p.*;
        \\}
        \\
        \\fn c_aggregate_assigned_pointer_field_load() -> u32 {
        \\    var local: u32 = 16;
        \\    var holder: Holder = .{ .ptr = &local, .ptrs = .{ &local, &local } };
        \\    holder.ptr = &shared_counter;
        \\    let p: *mut u32 = holder.ptr;
        \\    return p.*;
        \\}
        \\
        \\fn c_aggregate_stack_pointer_field_stays_plain() -> u32 {
        \\    var local: u32 = 17;
        \\    let holder: Holder = .{ .ptr = &local, .ptrs = .{ &local, &local } };
        \\    let p: *mut u32 = holder.ptr;
        \\    return p.*;
        \\}
        \\
        \\fn c_aggregate_pointer_array_element_load() -> u32 {
        \\    let holder: Holder = .{ .ptr = &shared_counter, .ptrs = .{ &shared_counter, &shared_counter } };
        \\    let p: *mut u32 = holder.ptrs[0];
        \\    return p.*;
        \\}
        \\
        \\fn c_aggregate_assigned_pointer_array_element_load() -> u32 {
        \\    var local: u32 = 18;
        \\    var holder: Holder = .{ .ptr = &local, .ptrs = .{ &local, &local } };
        \\    holder.ptrs[0] = &shared_counter;
        \\    let p: *mut u32 = holder.ptrs[0];
        \\    return p.*;
        \\}
        \\
        \\fn c_aggregate_scoped_pointer_array_element_load() -> u32 {
        \\    var local: u32 = 18;
        \\    var holder: Holder = .{ .ptr = &local, .ptrs = .{ &local, &local } };
        \\    unsafe {
        \\        holder.ptrs[0] = &shared_counter;
        \\    }
        \\    let p: *mut u32 = holder.ptrs[0];
        \\    return p.*;
        \\}
        \\
        \\fn c_aggregate_scoped_pointer_array_element_direct_load() -> u32 {
        \\    var local: u32 = 18;
        \\    var holder: Holder = .{ .ptr = &local, .ptrs = .{ &local, &local } };
        \\    unsafe {
        \\        holder.ptrs[0] = &shared_counter;
        \\    }
        \\    return holder.ptrs[0].*;
        \\}
        \\
        \\fn c_aggregate_stack_pointer_array_element_stays_plain() -> u32 {
        \\    var local: u32 = 19;
        \\    let holder: Holder = .{ .ptr = &local, .ptrs = .{ &local, &local } };
        \\    let p: *mut u32 = holder.ptrs[0];
        \\    return p.*;
        \\}
        \\
        \\fn c_aggregate_copy_pointer_field_load() -> u32 {
        \\    let holder: Holder = .{ .ptr = &shared_counter, .ptrs = .{ &shared_counter, &shared_counter } };
        \\    let copied: Holder = holder;
        \\    let p: *mut u32 = copied.ptr;
        \\    return p.*;
        \\}
        \\
        \\fn c_aggregate_copy_pointer_array_element_load() -> u32 {
        \\    let holder: Holder = .{ .ptr = &shared_counter, .ptrs = .{ &shared_counter, &shared_counter } };
        \\    let copied: Holder = holder;
        \\    let p: *mut u32 = copied.ptrs[0];
        \\    return p.*;
        \\}
        \\
        \\fn c_aggregate_assigned_copy_pointer_field_load() -> u32 {
        \\    var local: u32 = 20;
        \\    let holder: Holder = .{ .ptr = &shared_counter, .ptrs = .{ &shared_counter, &shared_counter } };
        \\    var copied: Holder = .{ .ptr = &local, .ptrs = .{ &local, &local } };
        \\    copied = holder;
        \\    let p: *mut u32 = copied.ptr;
        \\    return p.*;
        \\}
        \\
        \\fn c_aggregate_copy_stack_pointer_field_stays_plain() -> u32 {
        \\    var local: u32 = 21;
        \\    let holder: Holder = .{ .ptr = &local, .ptrs = .{ &local, &local } };
        \\    let copied: Holder = holder;
        \\    let p: *mut u32 = copied.ptr;
        \\    return p.*;
        \\}
        \\
        \\fn c_nested_aggregate_pointer_field_load() -> u32 {
        \\    let outer: Outer = .{ .inner = .{ .ptr = &shared_counter, .ptrs = .{ &shared_counter, &shared_counter } } };
        \\    let p: *mut u32 = outer.inner.ptr;
        \\    return p.*;
        \\}
        \\
        \\fn c_nested_aggregate_assigned_pointer_field_load() -> u32 {
        \\    var local: u32 = 22;
        \\    var outer: Outer = .{ .inner = .{ .ptr = &local, .ptrs = .{ &local, &local } } };
        \\    outer.inner.ptr = &shared_counter;
        \\    let p: *mut u32 = outer.inner.ptr;
        \\    return p.*;
        \\}
        \\
        \\fn c_nested_aggregate_scoped_pointer_field_load() -> u32 {
        \\    var local: u32 = 22;
        \\    var outer: Outer = .{ .inner = .{ .ptr = &local, .ptrs = .{ &local, &local } } };
        \\    unsafe {
        \\        outer.inner.ptr = &shared_counter;
        \\    }
        \\    let p: *mut u32 = outer.inner.ptr;
        \\    return p.*;
        \\}
        \\
        \\fn c_nested_aggregate_scoped_pointer_field_direct_load() -> u32 {
        \\    var local: u32 = 22;
        \\    var outer: Outer = .{ .inner = .{ .ptr = &local, .ptrs = .{ &local, &local } } };
        \\    unsafe {
        \\        outer.inner.ptr = &shared_counter;
        \\    }
        \\    return outer.inner.ptr.*;
        \\}
        \\
        \\fn c_nested_aggregate_pointer_array_element_load() -> u32 {
        \\    let outer: Outer = .{ .inner = .{ .ptr = &shared_counter, .ptrs = .{ &shared_counter, &shared_counter } } };
        \\    let p: *mut u32 = outer.inner.ptrs[0];
        \\    return p.*;
        \\}
        \\
        \\fn c_nested_aggregate_scoped_pointer_array_element_load() -> u32 {
        \\    var local: u32 = 22;
        \\    var outer: Outer = .{ .inner = .{ .ptr = &local, .ptrs = .{ &local, &local } } };
        \\    unsafe {
        \\        outer.inner.ptrs[0] = &shared_counter;
        \\    }
        \\    let p: *mut u32 = outer.inner.ptrs[0];
        \\    return p.*;
        \\}
        \\
        \\fn c_nested_aggregate_scoped_pointer_array_element_direct_load() -> u32 {
        \\    var local: u32 = 22;
        \\    var outer: Outer = .{ .inner = .{ .ptr = &local, .ptrs = .{ &local, &local } } };
        \\    unsafe {
        \\        outer.inner.ptrs[0] = &shared_counter;
        \\    }
        \\    return outer.inner.ptrs[0].*;
        \\}
        \\
        \\fn c_nested_aggregate_stack_pointer_field_stays_plain() -> u32 {
        \\    var local: u32 = 23;
        \\    let outer: Outer = .{ .inner = .{ .ptr = &local, .ptrs = .{ &local, &local } } };
        \\    let p: *mut u32 = outer.inner.ptr;
        \\    return p.*;
        \\}
    ;

    var parsed = try test_support.parseModule("emit_c_aggregate_pointer_provenance.mc", source);
    defer parsed.deinit();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, parsed.module, &output);

    const field_body = try cFunctionBody(output.items, "static uint32_t c_aggregate_pointer_field_load(void)");
    try expectContains(field_body, "/* mir pointer_provenance consumed fn=c_aggregate_pointer_field_load subject=p provenance=global_storage reason=none source=");
    try expectContains(field_body, "return ((uint32_t)mc_race_load_u32(p));");

    const assigned_field_body = try cFunctionBody(output.items, "static uint32_t c_aggregate_assigned_pointer_field_load(void)");
    try expectContains(assigned_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_assigned_pointer_field_load subject=p provenance=global_storage reason=none source=");
    try expectContains(assigned_field_body, "return ((uint32_t)mc_race_load_u32(p));");

    const stack_field_body = try cFunctionBody(output.items, "static uint32_t c_aggregate_stack_pointer_field_stays_plain(void)");
    try expectContains(stack_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_stack_pointer_field_stays_plain subject=p provenance=local_storage reason=none source=");
    try expectContains(stack_field_body, "return *p;");
    try expectNotContains(stack_field_body, "mc_race_load_u32(p)");

    const array_body = try cFunctionBody(output.items, "static uint32_t c_aggregate_pointer_array_element_load(void)");
    try expectContains(array_body, "/* mir pointer_provenance consumed fn=c_aggregate_pointer_array_element_load subject=p provenance=global_storage reason=none source=");
    try expectContains(array_body, "return ((uint32_t)mc_race_load_u32(p));");

    const assigned_array_body = try cFunctionBody(output.items, "static uint32_t c_aggregate_assigned_pointer_array_element_load(void)");
    try expectContains(assigned_array_body, "/* mir pointer_provenance consumed fn=c_aggregate_assigned_pointer_array_element_load subject=p provenance=global_storage reason=none source=");
    try expectContains(assigned_array_body, "return ((uint32_t)mc_race_load_u32(p));");

    const scoped_array_body = try cFunctionBody(output.items, "static uint32_t c_aggregate_scoped_pointer_array_element_load(void)");
    try expectContains(scoped_array_body, "/* mir pointer_provenance consumed fn=c_aggregate_scoped_pointer_array_element_load subject=p provenance=global_storage reason=none source=");
    try expectContains(scoped_array_body, "return ((uint32_t)mc_race_load_u32(p));");

    const scoped_array_direct_body = try cFunctionBody(output.items, "static uint32_t c_aggregate_scoped_pointer_array_element_direct_load(void)");
    try expectContains(scoped_array_direct_body, "mc_race_load_u32(");
    try expectNotContains(scoped_array_direct_body, "return *");

    const stack_array_body = try cFunctionBody(output.items, "static uint32_t c_aggregate_stack_pointer_array_element_stays_plain(void)");
    try expectContains(stack_array_body, "/* mir pointer_provenance consumed fn=c_aggregate_stack_pointer_array_element_stays_plain subject=p provenance=local_storage reason=none source=");
    try expectContains(stack_array_body, "return *p;");
    try expectNotContains(stack_array_body, "mc_race_load_u32(p)");

    const copied_field_body = try cFunctionBody(output.items, "static uint32_t c_aggregate_copy_pointer_field_load(void)");
    try expectContains(copied_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_copy_pointer_field_load subject=p provenance=global_storage reason=none source=");
    try expectContains(copied_field_body, "return ((uint32_t)mc_race_load_u32(p));");

    const copied_array_body = try cFunctionBody(output.items, "static uint32_t c_aggregate_copy_pointer_array_element_load(void)");
    try expectContains(copied_array_body, "/* mir pointer_provenance consumed fn=c_aggregate_copy_pointer_array_element_load subject=p provenance=global_storage reason=none source=");
    try expectContains(copied_array_body, "return ((uint32_t)mc_race_load_u32(p));");

    const assigned_copy_body = try cFunctionBody(output.items, "static uint32_t c_aggregate_assigned_copy_pointer_field_load(void)");
    try expectContains(assigned_copy_body, "/* mir pointer_provenance consumed fn=c_aggregate_assigned_copy_pointer_field_load subject=p provenance=global_storage reason=none source=");
    try expectContains(assigned_copy_body, "return ((uint32_t)mc_race_load_u32(p));");

    const copied_stack_body = try cFunctionBody(output.items, "static uint32_t c_aggregate_copy_stack_pointer_field_stays_plain(void)");
    try expectContains(copied_stack_body, "/* mir pointer_provenance consumed fn=c_aggregate_copy_stack_pointer_field_stays_plain subject=p provenance=local_storage reason=none source=");
    try expectContains(copied_stack_body, "return *p;");
    try expectNotContains(copied_stack_body, "mc_race_load_u32(p)");

    const nested_field_body = try cFunctionBody(output.items, "static uint32_t c_nested_aggregate_pointer_field_load(void)");
    try expectContains(nested_field_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_pointer_field_load subject=p provenance=global_storage reason=none source=");
    try expectContains(nested_field_body, "return ((uint32_t)mc_race_load_u32(p));");

    const nested_assigned_field_body = try cFunctionBody(output.items, "static uint32_t c_nested_aggregate_assigned_pointer_field_load(void)");
    try expectContains(nested_assigned_field_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_assigned_pointer_field_load subject=p provenance=global_storage reason=none source=");
    try expectContains(nested_assigned_field_body, "return ((uint32_t)mc_race_load_u32(p));");

    const nested_scoped_field_body = try cFunctionBody(output.items, "static uint32_t c_nested_aggregate_scoped_pointer_field_load(void)");
    try expectContains(nested_scoped_field_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_scoped_pointer_field_load subject=p provenance=global_storage reason=none source=");
    try expectContains(nested_scoped_field_body, "return ((uint32_t)mc_race_load_u32(p));");

    const nested_scoped_field_direct_body = try cFunctionBody(output.items, "static uint32_t c_nested_aggregate_scoped_pointer_field_direct_load(void)");
    try expectContains(nested_scoped_field_direct_body, "mc_race_load_u32(");
    try expectNotContains(nested_scoped_field_direct_body, "return *");

    const nested_array_body = try cFunctionBody(output.items, "static uint32_t c_nested_aggregate_pointer_array_element_load(void)");
    try expectContains(nested_array_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_pointer_array_element_load subject=p provenance=global_storage reason=none source=");
    try expectContains(nested_array_body, "return ((uint32_t)mc_race_load_u32(p));");

    const nested_scoped_array_body = try cFunctionBody(output.items, "static uint32_t c_nested_aggregate_scoped_pointer_array_element_load(void)");
    try expectContains(nested_scoped_array_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_scoped_pointer_array_element_load subject=p provenance=global_storage reason=none source=");
    try expectContains(nested_scoped_array_body, "return ((uint32_t)mc_race_load_u32(p));");

    const nested_scoped_array_direct_body = try cFunctionBody(output.items, "static uint32_t c_nested_aggregate_scoped_pointer_array_element_direct_load(void)");
    try expectContains(nested_scoped_array_direct_body, "mc_race_load_u32(");
    try expectNotContains(nested_scoped_array_direct_body, "return *");

    const nested_stack_body = try cFunctionBody(output.items, "static uint32_t c_nested_aggregate_stack_pointer_field_stays_plain(void)");
    try expectContains(nested_stack_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_stack_pointer_field_stays_plain subject=p provenance=local_storage reason=none source=");
    try expectContains(nested_stack_body, "return *p;");
    try expectNotContains(nested_stack_body, "mc_race_load_u32(p)");

    var mir_dump: std.ArrayList(u8) = .empty;
    defer mir_dump.deinit(std.testing.allocator);
    try mir.appendDump(std.testing.allocator, parsed.module, &mir_dump);
    try expectCCommentSourceMatchesMirFact(
        output.items,
        mir_dump.items,
        "/* mir pointer_provenance consumed fn=c_aggregate_pointer_field_load subject=p provenance=global_storage reason=none source=",
        "mir pointer_provenance_fact fn=c_aggregate_pointer_field_load subject=p element=none provenance=global_storage storage=shared_counter",
    );
    try expectCCommentSourceMatchesMirFact(
        output.items,
        mir_dump.items,
        "/* mir pointer_provenance consumed fn=c_aggregate_pointer_array_element_load subject=p provenance=global_storage reason=none source=",
        "mir pointer_provenance_fact fn=c_aggregate_pointer_array_element_load subject=p element=none provenance=global_storage storage=shared_counter",
    );
    try expectCCommentSourceMatchesMirFact(
        output.items,
        mir_dump.items,
        "/* mir pointer_provenance consumed fn=c_aggregate_copy_pointer_field_load subject=p provenance=global_storage reason=none source=",
        "mir pointer_provenance_fact fn=c_aggregate_copy_pointer_field_load subject=p element=none provenance=global_storage storage=shared_counter",
    );
    try expectCCommentSourceMatchesMirFact(
        output.items,
        mir_dump.items,
        "/* mir pointer_provenance consumed fn=c_nested_aggregate_pointer_field_load subject=p provenance=global_storage reason=none source=",
        "mir pointer_provenance_fact fn=c_nested_aggregate_pointer_field_load subject=p element=none provenance=global_storage storage=shared_counter",
    );
}

test "lower-c aggregate pointer reads without MIR destination fact lower conservatively" {
    const field_source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32 }
        \\struct RawHolder { ptr: [*]mut u32 }
        \\struct Inner { ptr: *mut u32 }
        \\struct Outer { inner: Inner }
        \\struct RawInner { ptr: [*]mut u32 }
        \\struct RawOuter { inner: RawInner }
        \\
        \\fn c_aggregate_field_read_requires_mir_fact() -> u32 {
        \\    let holder: Holder = .{ .ptr = &shared_counter };
        \\    let p: *mut u32 = holder.ptr;
        \\    return p.*;
        \\}
        \\
        \\fn c_aggregate_field_noalias_read_requires_mir_fact() -> u32 {
        \\    let holder: Holder = .{ .ptr = &shared_counter };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        let p: *mut u32 = compiler.assume_noalias_unchecked(holder.ptr, 4);
        \\        return p.*;
        \\    }
        \\}
        \\
        \\fn c_aggregate_field_assignment_requires_mir_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var holder: Holder = .{ .ptr = &local };
        \\    holder.ptr = &shared_counter;
        \\    var p: *mut u32 = &local;
        \\    p = holder.ptr;
        \\    return p.*;
        \\}
        \\
        \\fn c_aggregate_field_pointer_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var holder: Holder = .{ .ptr = &local };
        \\    let gp: *mut u32 = &shared_counter;
        \\    holder.ptr = gp;
        \\    return holder.ptr.*;
        \\}
        \\
        \\fn c_aggregate_field_raw_many_zero_direct_deref_requires_mir_field_fact() -> u32 {
        \\    unsafe {
        \\        var local: u32 = 0;
        \\        var holder: RawHolder = .{ .ptr = (&local) as [*]mut u32 };
        \\        let gp: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        holder.ptr = gp.offset(0);
        \\        return holder.ptr.*;
        \\    }
        \\}
        \\
        \\fn c_aggregate_field_noalias_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var holder: Holder = .{ .ptr = &local };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        holder.ptr = compiler.assume_noalias_unchecked(&shared_counter, 4);
        \\    }
        \\    return holder.ptr.*;
        \\}
        \\
        \\fn c_aggregate_field_noalias_read_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let src: Holder = .{ .ptr = &shared_counter };
        \\    var dst: Holder = .{ .ptr = &local };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        dst.ptr = compiler.assume_noalias_unchecked(src.ptr, 4);
        \\    }
        \\    return dst.ptr.*;
        \\}
        \\
        \\fn c_aggregate_field_casted_noalias_read_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let src: Holder = .{ .ptr = &shared_counter };
        \\    var dst: Holder = .{ .ptr = &local };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        dst.ptr = compiler.assume_noalias_unchecked(src.ptr, 4) as *mut u32;
        \\    }
        \\    return dst.ptr.*;
        \\}
        \\
        \\fn c_aggregate_field_literal_pointer_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let gp: *mut u32 = &shared_counter;
        \\    let holder: Holder = .{ .ptr = gp };
        \\    return holder.ptr.*;
        \\}
        \\
        \\fn c_aggregate_field_literal_raw_many_zero_direct_deref_requires_mir_field_fact() -> u32 {
        \\    unsafe {
        \\        let gp: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        let holder: RawHolder = .{ .ptr = gp.offset(0) };
        \\        return holder.ptr.*;
        \\    }
        \\}
        \\
        \\fn c_aggregate_field_literal_noalias_direct_deref_requires_mir_field_fact() -> u32 {
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        let holder: Holder = .{ .ptr = compiler.assume_noalias_unchecked(&shared_counter, 4) };
        \\        return holder.ptr.*;
        \\    }
        \\}
        \\
        \\fn c_aggregate_field_local_pointer_copy_literal_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let lp: *mut u32 = &local;
        \\    let holder: Holder = .{ .ptr = lp };
        \\    return holder.ptr.*;
        \\}
        \\
        \\fn c_aggregate_field_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var other: u32 = 0;
        \\    let lp: *mut u32 = &local;
        \\    var holder: Holder = .{ .ptr = &other };
        \\    holder = .{ .ptr = lp };
        \\    return holder.ptr.*;
        \\}
        \\
        \\fn c_aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var holder: Holder = .{ .ptr = &local };
        \\    let gp: *mut u32 = &shared_counter;
        \\    holder = .{ .ptr = gp };
        \\    return holder.ptr.*;
        \\}
        \\
        \\fn c_aggregate_field_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact() -> u32 {
        \\    unsafe {
        \\        var local: u32 = 0;
        \\        var holder: RawHolder = .{ .ptr = (&local) as [*]mut u32 };
        \\        let gp: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        holder = .{ .ptr = gp.offset(0) };
        \\        return holder.ptr.*;
        \\    }
        \\}
        \\
        \\fn c_aggregate_field_literal_reassignment_noalias_direct_deref_requires_mir_field_fact() -> u32 {
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        var local: u32 = 0;
        \\        var holder: Holder = .{ .ptr = &local };
        \\        holder = .{ .ptr = compiler.assume_noalias_unchecked(&shared_counter, 4) };
        \\        return holder.ptr.*;
        \\    }
        \\}
        \\
        \\fn c_aggregate_field_copy_requires_mir_fact() -> u32 {
        \\    let holder: Holder = .{ .ptr = &shared_counter };
        \\    let copied: Holder = holder;
        \\    let p: *mut u32 = copied.ptr;
        \\    return p.*;
        \\}
        \\
        \\fn c_aggregate_field_noalias_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    let holder: Holder = .{ .ptr = &shared_counter };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        let copied: Holder = compiler.assume_noalias_unchecked(holder, 4);
        \\        return copied.ptr.*;
        \\    }
        \\}
        \\
        \\fn c_aggregate_field_casted_noalias_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    let holder: Holder = .{ .ptr = &shared_counter };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        let copied: Holder = compiler.assume_noalias_unchecked(holder, 4) as Holder;
        \\        return copied.ptr.*;
        \\    }
        \\}
        \\
        \\fn c_aggregate_field_local_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let holder: Holder = .{ .ptr = &local };
        \\    return holder.ptr.*;
        \\}
        \\
        \\fn c_aggregate_field_local_direct_store_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let holder: Holder = .{ .ptr = &local };
        \\    holder.ptr.* = 9;
        \\    return local;
        \\}
        \\
        \\fn c_aggregate_field_local_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let holder: Holder = .{ .ptr = &local };
        \\    let copied: Holder = holder;
        \\    return copied.ptr.*;
        \\}
        \\
        \\fn c_nested_aggregate_field_read_requires_mir_fact() -> u32 {
        \\    let outer: Outer = .{ .inner = .{ .ptr = &shared_counter } };
        \\    let p: *mut u32 = outer.inner.ptr;
        \\    return p.*;
        \\}
        \\
        \\fn c_nested_aggregate_field_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    let outer: Outer = .{ .inner = .{ .ptr = &shared_counter } };
        \\    let copied: Outer = outer;
        \\    return copied.inner.ptr.*;
        \\}
        \\
        \\fn c_nested_aggregate_field_assignment_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let outer: Outer = .{ .inner = .{ .ptr = &shared_counter } };
        \\    var assigned: Outer = .{ .inner = .{ .ptr = &local } };
        \\    assigned = outer;
        \\    return assigned.inner.ptr.*;
        \\}
        \\
        \\fn c_nested_aggregate_field_literal_local_pointer_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let lp: *mut u32 = &local;
        \\    let outer: Outer = .{ .inner = .{ .ptr = lp } };
        \\    return outer.inner.ptr.*;
        \\}
        \\
        \\fn c_nested_aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var outer: Outer = .{ .inner = .{ .ptr = &local } };
        \\    let gp: *mut u32 = &shared_counter;
        \\    outer.inner = .{ .ptr = gp };
        \\    return outer.inner.ptr.*;
        \\}
        \\
        \\fn c_nested_aggregate_field_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var other: u32 = 0;
        \\    var outer: Outer = .{ .inner = .{ .ptr = &other } };
        \\    let lp: *mut u32 = &local;
        \\    outer.inner = .{ .ptr = lp };
        \\    return outer.inner.ptr.*;
        \\}
        \\
        \\fn c_nested_aggregate_field_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact() -> u32 {
        \\    unsafe {
        \\        var local: u32 = 0;
        \\        var outer: RawOuter = .{ .inner = .{ .ptr = (&local) as [*]mut u32 } };
        \\        let gp: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        outer.inner = .{ .ptr = gp.offset(0) };
        \\        return outer.inner.ptr.*;
        \\    }
        \\}
        \\
        \\fn c_nested_aggregate_field_literal_reassignment_noalias_direct_deref_requires_mir_field_fact() -> u32 {
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        var local: u32 = 0;
        \\        var outer: Outer = .{ .inner = .{ .ptr = &local } };
        \\        outer.inner = .{ .ptr = compiler.assume_noalias_unchecked(&shared_counter, 4) };
        \\        return outer.inner.ptr.*;
        \\    }
        \\}
        \\
        \\fn c_nested_aggregate_field_noalias_member_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let src: Outer = .{ .inner = .{ .ptr = &shared_counter } };
        \\    var dst: Outer = .{ .inner = .{ .ptr = &local } };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        dst.inner = compiler.assume_noalias_unchecked(src.inner, 4);
        \\    }
        \\    return dst.inner.ptr.*;
        \\}
        \\
        \\fn c_nested_aggregate_field_casted_noalias_member_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let src: Outer = .{ .inner = .{ .ptr = &shared_counter } };
        \\    var dst: Outer = .{ .inner = .{ .ptr = &local } };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        dst.inner = compiler.assume_noalias_unchecked(src.inner, 4) as Inner;
        \\    }
        \\    return dst.inner.ptr.*;
        \\}
    ;

    var normal_output: std.ArrayList(u8) = .empty;
    defer normal_output.deinit(std.testing.allocator);
    try appendCheckedCTest("emit_c_aggregate_field_provenance_required.mc", field_source, &normal_output);
    const normal_body = try cFunctionBody(normal_output.items, "static uint32_t c_aggregate_field_read_requires_mir_fact(void)");
    try expectContains(normal_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_read_requires_mir_fact subject=holder field=ptr provenance=global_storage reason=none source=");
    try expectContains(normal_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_read_requires_mir_fact subject=p provenance=global_storage reason=none source=");
    try expectContains(normal_body, "return ((uint32_t)mc_race_load_u32(p));");

    const normal_noalias_read_body = try cFunctionBody(normal_output.items, "static uint32_t c_aggregate_field_noalias_read_requires_mir_fact(void)");
    try expectContains(normal_noalias_read_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_noalias_read_requires_mir_fact subject=holder field=ptr provenance=global_storage reason=none source=");
    try expectContains(normal_noalias_read_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_noalias_read_requires_mir_fact subject=p provenance=global_storage reason=none source=");
    try expectContains(normal_noalias_read_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(normal_noalias_read_body, "return *p;");

    const normal_pointer_copy_direct_body = try cFunctionBody(normal_output.items, "static uint32_t c_aggregate_field_pointer_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_pointer_copy_direct_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none source=");
    try expectContains(normal_pointer_copy_direct_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_pointer_copy_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance=global_storage reason=reassignment source=");
    try expectContains(normal_pointer_copy_direct_body, "return ((uint32_t)mc_race_load_u32(holder.ptr));");
    try expectNotContains(normal_pointer_copy_direct_body, "return *holder.ptr;");

    const normal_raw_many_zero_direct_body = try cFunctionBody(normal_output.items, "static uint32_t c_aggregate_field_raw_many_zero_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_raw_many_zero_direct_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_raw_many_zero_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none source=");
    try expectContains(normal_raw_many_zero_direct_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_raw_many_zero_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance=global_storage reason=reassignment source=");
    try expectContains(normal_raw_many_zero_direct_body, "return ((uint32_t)mc_race_load_u32(holder.ptr));");
    try expectNotContains(normal_raw_many_zero_direct_body, "return *holder.ptr;");

    const normal_noalias_direct_body = try cFunctionBody(normal_output.items, "static uint32_t c_aggregate_field_noalias_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_noalias_direct_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_noalias_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance=global_storage reason=reassignment source=");
    try expectContains(normal_noalias_direct_body, "return ((uint32_t)mc_race_load_u32(holder.ptr));");
    try expectNotContains(normal_noalias_direct_body, "return *holder.ptr;");

    const normal_noalias_read_direct_body = try cFunctionBody(normal_output.items, "static uint32_t c_aggregate_field_noalias_read_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_noalias_read_direct_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_noalias_read_direct_deref_requires_mir_field_fact subject=src field=ptr provenance=global_storage reason=none source=");
    try expectContains(normal_noalias_read_direct_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_noalias_read_direct_deref_requires_mir_field_fact subject=dst field=ptr provenance=global_storage reason=reassignment source=");
    try expectContains(normal_noalias_read_direct_body, "return ((uint32_t)mc_race_load_u32(dst.ptr));");
    try expectNotContains(normal_noalias_read_direct_body, "return *dst.ptr;");

    const normal_casted_noalias_read_direct_body = try cFunctionBody(normal_output.items, "static uint32_t c_aggregate_field_casted_noalias_read_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_casted_noalias_read_direct_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_casted_noalias_read_direct_deref_requires_mir_field_fact subject=src field=ptr provenance=global_storage reason=none source=");
    try expectContains(normal_casted_noalias_read_direct_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_casted_noalias_read_direct_deref_requires_mir_field_fact subject=dst field=ptr provenance=global_storage reason=reassignment source=");
    try expectContains(normal_casted_noalias_read_direct_body, "return ((uint32_t)mc_race_load_u32(dst.ptr));");
    try expectNotContains(normal_casted_noalias_read_direct_body, "return *dst.ptr;");

    const normal_literal_pointer_copy_body = try cFunctionBody(normal_output.items, "static uint32_t c_aggregate_field_literal_pointer_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_literal_pointer_copy_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_literal_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none source=");
    try expectContains(normal_literal_pointer_copy_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_literal_pointer_copy_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance=global_storage reason=none source=");
    try expectContains(normal_literal_pointer_copy_body, "return ((uint32_t)mc_race_load_u32(holder.ptr));");
    try expectNotContains(normal_literal_pointer_copy_body, "return *holder.ptr;");

    const normal_literal_raw_many_zero_body = try cFunctionBody(normal_output.items, "static uint32_t c_aggregate_field_literal_raw_many_zero_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_literal_raw_many_zero_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_literal_raw_many_zero_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none source=");
    try expectContains(normal_literal_raw_many_zero_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_literal_raw_many_zero_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance=global_storage reason=none source=");
    try expectContains(normal_literal_raw_many_zero_body, "return ((uint32_t)mc_race_load_u32(holder.ptr));");
    try expectNotContains(normal_literal_raw_many_zero_body, "return *holder.ptr;");

    const normal_literal_noalias_body = try cFunctionBody(normal_output.items, "static uint32_t c_aggregate_field_literal_noalias_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_literal_noalias_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_literal_noalias_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance=global_storage reason=none source=");
    try expectContains(normal_literal_noalias_body, "return ((uint32_t)mc_race_load_u32(holder.ptr));");
    try expectNotContains(normal_literal_noalias_body, "return *holder.ptr;");

    const normal_local_pointer_copy_literal_body = try cFunctionBody(normal_output.items, "static uint32_t c_aggregate_field_local_pointer_copy_literal_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_local_pointer_copy_literal_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_local_pointer_copy_literal_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none source=");
    try expectContains(normal_local_pointer_copy_literal_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_local_pointer_copy_literal_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance=local_storage reason=none source=");
    try expectContains(normal_local_pointer_copy_literal_body, "return *holder.ptr;");
    try expectNotContains(normal_local_pointer_copy_literal_body, "mc_race_load_u32(");

    const normal_local_pointer_copy_literal_reassignment_body = try cFunctionBody(normal_output.items, "static uint32_t c_aggregate_field_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_local_pointer_copy_literal_reassignment_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none source=");
    try expectContains(normal_local_pointer_copy_literal_reassignment_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance=local_storage reason=none source=");
    try expectContains(normal_local_pointer_copy_literal_reassignment_body, "return *holder.ptr;");
    try expectNotContains(normal_local_pointer_copy_literal_reassignment_body, "mc_race_load_u32(");

    const normal_local_store_body = try cFunctionBody(normal_output.items, "static uint32_t c_aggregate_field_local_direct_store_requires_mir_field_fact(void)");
    try expectContains(normal_local_store_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_local_direct_store_requires_mir_field_fact subject=holder field=ptr provenance=local_storage reason=none source=");
    try expectNotContains(normal_local_store_body, "mc_race_store_u32(holder.ptr");

    const normal_literal_reassignment_pointer_copy_body = try cFunctionBody(normal_output.items, "static uint32_t c_aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_literal_reassignment_pointer_copy_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none source=");
    try expectContains(normal_literal_reassignment_pointer_copy_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance=global_storage reason=none source=");
    try expectContains(normal_literal_reassignment_pointer_copy_body, "return ((uint32_t)mc_race_load_u32(holder.ptr));");
    try expectNotContains(normal_literal_reassignment_pointer_copy_body, "return *holder.ptr;");

    const normal_literal_reassignment_raw_many_zero_body = try cFunctionBody(normal_output.items, "static uint32_t c_aggregate_field_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_literal_reassignment_raw_many_zero_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none source=");
    try expectContains(normal_literal_reassignment_raw_many_zero_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance=global_storage reason=none source=");
    try expectContains(normal_literal_reassignment_raw_many_zero_body, "return ((uint32_t)mc_race_load_u32(holder.ptr));");
    try expectNotContains(normal_literal_reassignment_raw_many_zero_body, "return *holder.ptr;");

    const normal_literal_reassignment_noalias_body = try cFunctionBody(normal_output.items, "static uint32_t c_aggregate_field_literal_reassignment_noalias_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_literal_reassignment_noalias_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_literal_reassignment_noalias_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance=global_storage reason=none source=");
    try expectContains(normal_literal_reassignment_noalias_body, "return ((uint32_t)mc_race_load_u32(holder.ptr));");
    try expectNotContains(normal_literal_reassignment_noalias_body, "return *holder.ptr;");

    const normal_local_direct_body = try cFunctionBody(normal_output.items, "static uint32_t c_aggregate_field_local_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_local_direct_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_local_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance=local_storage reason=none source=");
    try expectContains(normal_local_direct_body, "return *holder.ptr;");
    try expectNotContains(normal_local_direct_body, "mc_race_load_u32(");

    const normal_local_copy_body = try cFunctionBody(normal_output.items, "static uint32_t c_aggregate_field_local_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_local_copy_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_local_copy_direct_deref_requires_mir_field_fact subject=copied field=ptr provenance=local_storage reason=none source=");
    try expectContains(normal_local_copy_body, "return *copied.ptr;");
    try expectNotContains(normal_local_copy_body, "mc_race_load_u32(");

    const normal_nested_literal_local_pointer_copy_body = try cFunctionBody(normal_output.items, "static uint32_t c_nested_aggregate_field_literal_local_pointer_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_nested_literal_local_pointer_copy_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_field_literal_local_pointer_copy_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none source=");
    try expectContains(normal_nested_literal_local_pointer_copy_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_field_literal_local_pointer_copy_direct_deref_requires_mir_field_fact subject=outer field=inner.ptr provenance=local_storage reason=none source=");
    try expectContains(normal_nested_literal_local_pointer_copy_body, "return *outer.inner.ptr;");
    try expectNotContains(normal_nested_literal_local_pointer_copy_body, "mc_race_load_u32(");

    const normal_nested_literal_reassignment_pointer_copy_body = try cFunctionBody(normal_output.items, "static uint32_t c_nested_aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_nested_literal_reassignment_pointer_copy_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none source=");
    try expectContains(normal_nested_literal_reassignment_pointer_copy_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact subject=outer field=inner.ptr provenance=global_storage reason=none source=");
    try expectContains(normal_nested_literal_reassignment_pointer_copy_body, "return ((uint32_t)mc_race_load_u32(outer.inner.ptr));");
    try expectNotContains(normal_nested_literal_reassignment_pointer_copy_body, "return *outer.inner.ptr;");

    const normal_nested_literal_reassignment_local_pointer_copy_body = try cFunctionBody(normal_output.items, "static uint32_t c_nested_aggregate_field_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_nested_literal_reassignment_local_pointer_copy_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_field_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none source=");
    try expectContains(normal_nested_literal_reassignment_local_pointer_copy_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_field_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact subject=outer field=inner.ptr provenance=local_storage reason=none source=");
    try expectContains(normal_nested_literal_reassignment_local_pointer_copy_body, "return *outer.inner.ptr;");
    try expectNotContains(normal_nested_literal_reassignment_local_pointer_copy_body, "mc_race_load_u32(");

    const normal_nested_literal_reassignment_raw_many_zero_body = try cFunctionBody(normal_output.items, "static uint32_t c_nested_aggregate_field_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_nested_literal_reassignment_raw_many_zero_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_field_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none source=");
    try expectContains(normal_nested_literal_reassignment_raw_many_zero_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_field_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact subject=outer field=inner.ptr provenance=global_storage reason=none source=");
    try expectContains(normal_nested_literal_reassignment_raw_many_zero_body, "return ((uint32_t)mc_race_load_u32(outer.inner.ptr));");
    try expectNotContains(normal_nested_literal_reassignment_raw_many_zero_body, "return *outer.inner.ptr;");

    const normal_nested_literal_reassignment_noalias_body = try cFunctionBody(normal_output.items, "static uint32_t c_nested_aggregate_field_literal_reassignment_noalias_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_nested_literal_reassignment_noalias_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_field_literal_reassignment_noalias_direct_deref_requires_mir_field_fact subject=outer field=inner.ptr provenance=global_storage reason=none source=");
    try expectContains(normal_nested_literal_reassignment_noalias_body, "return ((uint32_t)mc_race_load_u32(outer.inner.ptr));");
    try expectNotContains(normal_nested_literal_reassignment_noalias_body, "return *outer.inner.ptr;");

    const normal_nested_copy_body = try cFunctionBody(normal_output.items, "static uint32_t c_nested_aggregate_field_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_nested_copy_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_field_copy_direct_deref_requires_mir_field_fact subject=copied field=inner.ptr provenance=global_storage reason=none source=");
    try expectContains(normal_nested_copy_body, "return ((uint32_t)mc_race_load_u32(copied.inner.ptr));");
    try expectNotContains(normal_nested_copy_body, "return *copied.inner.ptr;");

    const normal_noalias_copy_body = try cFunctionBody(normal_output.items, "static uint32_t c_aggregate_field_noalias_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_noalias_copy_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_noalias_copy_direct_deref_requires_mir_field_fact subject=copied field=ptr provenance=global_storage reason=none source=");
    try expectContains(normal_noalias_copy_body, "return ((uint32_t)mc_race_load_u32(copied.ptr));");
    try expectNotContains(normal_noalias_copy_body, "return *copied.ptr;");

    const normal_casted_noalias_copy_body = try cFunctionBody(normal_output.items, "static uint32_t c_aggregate_field_casted_noalias_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_casted_noalias_copy_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_casted_noalias_copy_direct_deref_requires_mir_field_fact subject=copied field=ptr provenance=global_storage reason=none source=");
    try expectContains(normal_casted_noalias_copy_body, "return ((uint32_t)mc_race_load_u32(copied.ptr));");
    try expectNotContains(normal_casted_noalias_copy_body, "return *copied.ptr;");

    const normal_nested_assignment_copy_body = try cFunctionBody(normal_output.items, "static uint32_t c_nested_aggregate_field_assignment_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_nested_assignment_copy_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_field_assignment_copy_direct_deref_requires_mir_field_fact subject=assigned field=inner.ptr provenance=global_storage reason=reassignment source=");
    try expectContains(normal_nested_assignment_copy_body, "return ((uint32_t)mc_race_load_u32(assigned.inner.ptr));");
    try expectNotContains(normal_nested_assignment_copy_body, "return *assigned.inner.ptr;");

    const normal_nested_noalias_member_copy_body = try cFunctionBody(normal_output.items, "static uint32_t c_nested_aggregate_field_noalias_member_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_nested_noalias_member_copy_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_field_noalias_member_copy_direct_deref_requires_mir_field_fact subject=dst field=inner.ptr provenance=global_storage reason=reassignment source=");
    try expectContains(normal_nested_noalias_member_copy_body, "return ((uint32_t)mc_race_load_u32(dst.inner.ptr));");
    try expectNotContains(normal_nested_noalias_member_copy_body, "return *dst.inner.ptr;");

    const normal_nested_casted_noalias_member_copy_body = try cFunctionBody(normal_output.items, "static uint32_t c_nested_aggregate_field_casted_noalias_member_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_nested_casted_noalias_member_copy_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_field_casted_noalias_member_copy_direct_deref_requires_mir_field_fact subject=dst field=inner.ptr provenance=global_storage reason=reassignment source=");
    try expectContains(normal_nested_casted_noalias_member_copy_body, "return ((uint32_t)mc_race_load_u32(dst.inner.ptr));");
    try expectNotContains(normal_nested_casted_noalias_member_copy_body, "return *dst.inner.ptr;");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_aggregate_field_missing_provenance.mc", field_source, "c_aggregate_field_read_requires_mir_fact", "p", &missing_output);
    const missing_body = try cFunctionBody(missing_output.items, "static uint32_t c_aggregate_field_read_requires_mir_fact(void)");
    try expectNotContains(missing_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_read_requires_mir_fact subject=p provenance");
    try expectContains(missing_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(missing_body, "return *p;");

    var missing_noalias_read_output: std.ArrayList(u8) = .empty;
    defer missing_noalias_read_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_aggregate_field_missing_noalias_read_provenance.mc", field_source, "c_aggregate_field_noalias_read_requires_mir_fact", "p", &missing_noalias_read_output);
    const missing_noalias_read_body = try cFunctionBody(missing_noalias_read_output.items, "static uint32_t c_aggregate_field_noalias_read_requires_mir_fact(void)");
    try expectContains(missing_noalias_read_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_noalias_read_requires_mir_fact subject=holder field=ptr provenance=global_storage reason=none source=");
    try expectNotContains(missing_noalias_read_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_noalias_read_requires_mir_fact subject=p provenance");
    try expectContains(missing_noalias_read_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(missing_noalias_read_body, "return *p;");

    var missing_assignment_output: std.ArrayList(u8) = .empty;
    defer missing_assignment_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_aggregate_field_missing_provenance.mc", field_source, "c_aggregate_field_assignment_requires_mir_fact", "p", &missing_assignment_output);
    const missing_assignment_body = try cFunctionBody(missing_assignment_output.items, "static uint32_t c_aggregate_field_assignment_requires_mir_fact(void)");
    try expectNotContains(missing_assignment_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_assignment_requires_mir_fact subject=p provenance");
    try expectContains(missing_assignment_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(missing_assignment_body, "return *p;");

    var missing_copy_output: std.ArrayList(u8) = .empty;
    defer missing_copy_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_aggregate_field_missing_provenance.mc", field_source, "c_aggregate_field_copy_requires_mir_fact", "p", &missing_copy_output);
    const missing_copy_body = try cFunctionBody(missing_copy_output.items, "static uint32_t c_aggregate_field_copy_requires_mir_fact(void)");
    try expectNotContains(missing_copy_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_copy_requires_mir_fact subject=p provenance");
    try expectContains(missing_copy_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(missing_copy_body, "return *p;");

    var missing_nested_output: std.ArrayList(u8) = .empty;
    defer missing_nested_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_aggregate_field_missing_provenance.mc", field_source, "c_nested_aggregate_field_read_requires_mir_fact", "p", &missing_nested_output);
    const missing_nested_body = try cFunctionBody(missing_nested_output.items, "static uint32_t c_nested_aggregate_field_read_requires_mir_fact(void)");
    try expectNotContains(missing_nested_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_field_read_requires_mir_fact subject=p provenance");
    try expectContains(missing_nested_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(missing_nested_body, "return *p;");

    var missing_field_output: std.ArrayList(u8) = .empty;
    defer missing_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_field_missing_field_provenance.mc", field_source, "c_aggregate_field_local_direct_deref_requires_mir_field_fact", "holder", "ptr", &missing_field_output);
    const missing_field_body = try cFunctionBody(missing_field_output.items, "static uint32_t c_aggregate_field_local_direct_deref_requires_mir_field_fact(void)");
    try expectNotContains(missing_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_local_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance");
    try expectContains(missing_field_body, "return ((uint32_t)mc_race_load_u32(holder.ptr));");
    try expectNotContains(missing_field_body, "return *holder.ptr;");

    var missing_store_field_output: std.ArrayList(u8) = .empty;
    defer missing_store_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_field_missing_store_field_provenance.mc", field_source, "c_aggregate_field_local_direct_store_requires_mir_field_fact", "holder", "ptr", &missing_store_field_output);
    const missing_store_field_body = try cFunctionBody(missing_store_field_output.items, "static uint32_t c_aggregate_field_local_direct_store_requires_mir_field_fact(void)");
    try expectNotContains(missing_store_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_local_direct_store_requires_mir_field_fact subject=holder field=ptr provenance");
    try expectContains(missing_store_field_body, "mc_race_store_u32(holder.ptr,");

    var missing_pointer_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_pointer_copy_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_field_missing_pointer_copy_field_provenance.mc", field_source, "c_aggregate_field_pointer_copy_direct_deref_requires_mir_field_fact", "holder", "ptr", &missing_pointer_copy_field_output);
    const missing_pointer_copy_field_body = try cFunctionBody(missing_pointer_copy_field_output.items, "static uint32_t c_aggregate_field_pointer_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(missing_pointer_copy_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none source=");
    try expectNotContains(missing_pointer_copy_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_pointer_copy_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance");
    try expectContains(missing_pointer_copy_field_body, "return ((uint32_t)mc_race_load_u32(holder.ptr));");
    try expectNotContains(missing_pointer_copy_field_body, "return *holder.ptr;");

    var missing_raw_many_zero_field_output: std.ArrayList(u8) = .empty;
    defer missing_raw_many_zero_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_field_missing_raw_many_zero_field_provenance.mc", field_source, "c_aggregate_field_raw_many_zero_direct_deref_requires_mir_field_fact", "holder", "ptr", &missing_raw_many_zero_field_output);
    const missing_raw_many_zero_field_body = try cFunctionBody(missing_raw_many_zero_field_output.items, "static uint32_t c_aggregate_field_raw_many_zero_direct_deref_requires_mir_field_fact(void)");
    try expectContains(missing_raw_many_zero_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_raw_many_zero_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none source=");
    try expectNotContains(missing_raw_many_zero_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_raw_many_zero_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance");
    try expectContains(missing_raw_many_zero_field_body, "return ((uint32_t)mc_race_load_u32(holder.ptr));");
    try expectNotContains(missing_raw_many_zero_field_body, "return *holder.ptr;");

    var missing_noalias_field_output: std.ArrayList(u8) = .empty;
    defer missing_noalias_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_field_missing_noalias_field_provenance.mc", field_source, "c_aggregate_field_noalias_direct_deref_requires_mir_field_fact", "holder", "ptr", &missing_noalias_field_output);
    const missing_noalias_field_body = try cFunctionBody(missing_noalias_field_output.items, "static uint32_t c_aggregate_field_noalias_direct_deref_requires_mir_field_fact(void)");
    try expectNotContains(missing_noalias_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_noalias_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance");
    try expectContains(missing_noalias_field_body, "return ((uint32_t)mc_race_load_u32(holder.ptr));");
    try expectNotContains(missing_noalias_field_body, "return *holder.ptr;");

    var missing_noalias_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_noalias_copy_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_field_missing_noalias_copy_field_provenance.mc", field_source, "c_aggregate_field_noalias_copy_direct_deref_requires_mir_field_fact", "copied", "ptr", &missing_noalias_copy_field_output);
    const missing_noalias_copy_field_body = try cFunctionBody(missing_noalias_copy_field_output.items, "static uint32_t c_aggregate_field_noalias_copy_direct_deref_requires_mir_field_fact(void)");
    try expectNotContains(missing_noalias_copy_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_noalias_copy_direct_deref_requires_mir_field_fact subject=copied field=ptr provenance");
    try expectContains(missing_noalias_copy_field_body, "return ((uint32_t)mc_race_load_u32(copied.ptr));");
    try expectNotContains(missing_noalias_copy_field_body, "return *copied.ptr;");

    var missing_casted_noalias_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_casted_noalias_copy_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_field_missing_casted_noalias_copy_field_provenance.mc", field_source, "c_aggregate_field_casted_noalias_copy_direct_deref_requires_mir_field_fact", "copied", "ptr", &missing_casted_noalias_copy_field_output);
    const missing_casted_noalias_copy_field_body = try cFunctionBody(missing_casted_noalias_copy_field_output.items, "static uint32_t c_aggregate_field_casted_noalias_copy_direct_deref_requires_mir_field_fact(void)");
    try expectNotContains(missing_casted_noalias_copy_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_casted_noalias_copy_direct_deref_requires_mir_field_fact subject=copied field=ptr provenance");
    try expectContains(missing_casted_noalias_copy_field_body, "return ((uint32_t)mc_race_load_u32(copied.ptr));");
    try expectNotContains(missing_casted_noalias_copy_field_body, "return *copied.ptr;");

    var missing_noalias_read_field_output: std.ArrayList(u8) = .empty;
    defer missing_noalias_read_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_field_missing_noalias_read_field_provenance.mc", field_source, "c_aggregate_field_noalias_read_direct_deref_requires_mir_field_fact", "dst", "ptr", &missing_noalias_read_field_output);
    const missing_noalias_read_field_body = try cFunctionBody(missing_noalias_read_field_output.items, "static uint32_t c_aggregate_field_noalias_read_direct_deref_requires_mir_field_fact(void)");
    try expectContains(missing_noalias_read_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_noalias_read_direct_deref_requires_mir_field_fact subject=src field=ptr provenance=global_storage reason=none source=");
    try expectNotContains(missing_noalias_read_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_noalias_read_direct_deref_requires_mir_field_fact subject=dst field=ptr provenance");
    try expectContains(missing_noalias_read_field_body, "return ((uint32_t)mc_race_load_u32(dst.ptr));");
    try expectNotContains(missing_noalias_read_field_body, "return *dst.ptr;");

    var missing_casted_noalias_read_field_output: std.ArrayList(u8) = .empty;
    defer missing_casted_noalias_read_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_field_missing_casted_noalias_read_field_provenance.mc", field_source, "c_aggregate_field_casted_noalias_read_direct_deref_requires_mir_field_fact", "dst", "ptr", &missing_casted_noalias_read_field_output);
    const missing_casted_noalias_read_field_body = try cFunctionBody(missing_casted_noalias_read_field_output.items, "static uint32_t c_aggregate_field_casted_noalias_read_direct_deref_requires_mir_field_fact(void)");
    try expectContains(missing_casted_noalias_read_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_casted_noalias_read_direct_deref_requires_mir_field_fact subject=src field=ptr provenance=global_storage reason=none source=");
    try expectNotContains(missing_casted_noalias_read_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_casted_noalias_read_direct_deref_requires_mir_field_fact subject=dst field=ptr provenance");
    try expectContains(missing_casted_noalias_read_field_body, "return ((uint32_t)mc_race_load_u32(dst.ptr));");
    try expectNotContains(missing_casted_noalias_read_field_body, "return *dst.ptr;");

    var missing_literal_pointer_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_literal_pointer_copy_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_field_missing_literal_pointer_copy_field_provenance.mc", field_source, "c_aggregate_field_literal_pointer_copy_direct_deref_requires_mir_field_fact", "holder", "ptr", &missing_literal_pointer_copy_field_output);
    const missing_literal_pointer_copy_field_body = try cFunctionBody(missing_literal_pointer_copy_field_output.items, "static uint32_t c_aggregate_field_literal_pointer_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(missing_literal_pointer_copy_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_literal_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none source=");
    try expectNotContains(missing_literal_pointer_copy_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_literal_pointer_copy_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance");
    try expectContains(missing_literal_pointer_copy_field_body, "return ((uint32_t)mc_race_load_u32(holder.ptr));");
    try expectNotContains(missing_literal_pointer_copy_field_body, "return *holder.ptr;");

    var missing_literal_raw_many_zero_field_output: std.ArrayList(u8) = .empty;
    defer missing_literal_raw_many_zero_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_field_missing_literal_raw_many_zero_field_provenance.mc", field_source, "c_aggregate_field_literal_raw_many_zero_direct_deref_requires_mir_field_fact", "holder", "ptr", &missing_literal_raw_many_zero_field_output);
    const missing_literal_raw_many_zero_field_body = try cFunctionBody(missing_literal_raw_many_zero_field_output.items, "static uint32_t c_aggregate_field_literal_raw_many_zero_direct_deref_requires_mir_field_fact(void)");
    try expectContains(missing_literal_raw_many_zero_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_literal_raw_many_zero_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none source=");
    try expectNotContains(missing_literal_raw_many_zero_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_literal_raw_many_zero_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance");
    try expectContains(missing_literal_raw_many_zero_field_body, "return ((uint32_t)mc_race_load_u32(holder.ptr));");
    try expectNotContains(missing_literal_raw_many_zero_field_body, "return *holder.ptr;");

    var missing_literal_noalias_field_output: std.ArrayList(u8) = .empty;
    defer missing_literal_noalias_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_field_missing_literal_noalias_field_provenance.mc", field_source, "c_aggregate_field_literal_noalias_direct_deref_requires_mir_field_fact", "holder", "ptr", &missing_literal_noalias_field_output);
    const missing_literal_noalias_field_body = try cFunctionBody(missing_literal_noalias_field_output.items, "static uint32_t c_aggregate_field_literal_noalias_direct_deref_requires_mir_field_fact(void)");
    try expectNotContains(missing_literal_noalias_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_literal_noalias_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance");
    try expectContains(missing_literal_noalias_field_body, "return ((uint32_t)mc_race_load_u32(holder.ptr));");
    try expectNotContains(missing_literal_noalias_field_body, "return *holder.ptr;");

    var missing_local_pointer_copy_literal_field_output: std.ArrayList(u8) = .empty;
    defer missing_local_pointer_copy_literal_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_field_missing_local_pointer_copy_literal_field_provenance.mc", field_source, "c_aggregate_field_local_pointer_copy_literal_direct_deref_requires_mir_field_fact", "holder", "ptr", &missing_local_pointer_copy_literal_field_output);
    const missing_local_pointer_copy_literal_field_body = try cFunctionBody(missing_local_pointer_copy_literal_field_output.items, "static uint32_t c_aggregate_field_local_pointer_copy_literal_direct_deref_requires_mir_field_fact(void)");
    try expectContains(missing_local_pointer_copy_literal_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_local_pointer_copy_literal_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none source=");
    try expectNotContains(missing_local_pointer_copy_literal_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_local_pointer_copy_literal_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance");
    try expectContains(missing_local_pointer_copy_literal_field_body, "return ((uint32_t)mc_race_load_u32(holder.ptr));");
    try expectNotContains(missing_local_pointer_copy_literal_field_body, "return *holder.ptr;");

    var missing_nested_literal_local_field_output: std.ArrayList(u8) = .empty;
    defer missing_nested_literal_local_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_nested_aggregate_field_missing_literal_local_field_provenance.mc", field_source, "c_nested_aggregate_field_literal_local_pointer_copy_direct_deref_requires_mir_field_fact", "outer", "inner.ptr", &missing_nested_literal_local_field_output);
    const missing_nested_literal_local_field_body = try cFunctionBody(missing_nested_literal_local_field_output.items, "static uint32_t c_nested_aggregate_field_literal_local_pointer_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(missing_nested_literal_local_field_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_field_literal_local_pointer_copy_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none source=");
    try expectNotContains(missing_nested_literal_local_field_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_field_literal_local_pointer_copy_direct_deref_requires_mir_field_fact subject=outer field=inner.ptr provenance");
    try expectContains(missing_nested_literal_local_field_body, "return ((uint32_t)mc_race_load_u32(outer.inner.ptr));");
    try expectNotContains(missing_nested_literal_local_field_body, "return *outer.inner.ptr;");

    var missing_local_pointer_copy_literal_reassignment_field_output: std.ArrayList(u8) = .empty;
    defer missing_local_pointer_copy_literal_reassignment_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_field_missing_local_pointer_copy_literal_reassignment_field_provenance.mc", field_source, "c_aggregate_field_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact", "holder", "ptr", &missing_local_pointer_copy_literal_reassignment_field_output);
    const missing_local_pointer_copy_literal_reassignment_field_body = try cFunctionBody(missing_local_pointer_copy_literal_reassignment_field_output.items, "static uint32_t c_aggregate_field_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact(void)");
    try expectContains(missing_local_pointer_copy_literal_reassignment_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none source=");
    try expectNotContains(missing_local_pointer_copy_literal_reassignment_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance");
    try expectContains(missing_local_pointer_copy_literal_reassignment_field_body, "return ((uint32_t)mc_race_load_u32(holder.ptr));");
    try expectNotContains(missing_local_pointer_copy_literal_reassignment_field_body, "return *holder.ptr;");

    var missing_literal_reassignment_pointer_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_literal_reassignment_pointer_copy_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_field_missing_literal_reassignment_pointer_copy_field_provenance.mc", field_source, "c_aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact", "holder", "ptr", &missing_literal_reassignment_pointer_copy_field_output);
    const missing_literal_reassignment_pointer_copy_field_body = try cFunctionBody(missing_literal_reassignment_pointer_copy_field_output.items, "static uint32_t c_aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(missing_literal_reassignment_pointer_copy_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none source=");
    try expectNotContains(missing_literal_reassignment_pointer_copy_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance");
    try expectContains(missing_literal_reassignment_pointer_copy_field_body, "return ((uint32_t)mc_race_load_u32(holder.ptr));");
    try expectNotContains(missing_literal_reassignment_pointer_copy_field_body, "return *holder.ptr;");

    var missing_literal_reassignment_raw_many_zero_field_output: std.ArrayList(u8) = .empty;
    defer missing_literal_reassignment_raw_many_zero_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_field_missing_literal_reassignment_raw_many_zero_field_provenance.mc", field_source, "c_aggregate_field_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact", "holder", "ptr", &missing_literal_reassignment_raw_many_zero_field_output);
    const missing_literal_reassignment_raw_many_zero_field_body = try cFunctionBody(missing_literal_reassignment_raw_many_zero_field_output.items, "static uint32_t c_aggregate_field_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact(void)");
    try expectContains(missing_literal_reassignment_raw_many_zero_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none source=");
    try expectNotContains(missing_literal_reassignment_raw_many_zero_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance");
    try expectContains(missing_literal_reassignment_raw_many_zero_field_body, "return ((uint32_t)mc_race_load_u32(holder.ptr));");
    try expectNotContains(missing_literal_reassignment_raw_many_zero_field_body, "return *holder.ptr;");

    var missing_literal_reassignment_noalias_field_output: std.ArrayList(u8) = .empty;
    defer missing_literal_reassignment_noalias_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_field_missing_literal_reassignment_noalias_field_provenance.mc", field_source, "c_aggregate_field_literal_reassignment_noalias_direct_deref_requires_mir_field_fact", "holder", "ptr", &missing_literal_reassignment_noalias_field_output);
    const missing_literal_reassignment_noalias_field_body = try cFunctionBody(missing_literal_reassignment_noalias_field_output.items, "static uint32_t c_aggregate_field_literal_reassignment_noalias_direct_deref_requires_mir_field_fact(void)");
    try expectNotContains(missing_literal_reassignment_noalias_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_literal_reassignment_noalias_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance");
    try expectContains(missing_literal_reassignment_noalias_field_body, "return ((uint32_t)mc_race_load_u32(holder.ptr));");
    try expectNotContains(missing_literal_reassignment_noalias_field_body, "return *holder.ptr;");

    var missing_nested_literal_reassignment_field_output: std.ArrayList(u8) = .empty;
    defer missing_nested_literal_reassignment_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_nested_aggregate_field_missing_literal_reassignment_field_provenance.mc", field_source, "c_nested_aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact", "outer", "inner.ptr", &missing_nested_literal_reassignment_field_output);
    const missing_nested_literal_reassignment_field_body = try cFunctionBody(missing_nested_literal_reassignment_field_output.items, "static uint32_t c_nested_aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(missing_nested_literal_reassignment_field_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none source=");
    try expectNotContains(missing_nested_literal_reassignment_field_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact subject=outer field=inner.ptr provenance");
    try expectContains(missing_nested_literal_reassignment_field_body, "return ((uint32_t)mc_race_load_u32(outer.inner.ptr));");
    try expectNotContains(missing_nested_literal_reassignment_field_body, "return *outer.inner.ptr;");

    var missing_nested_literal_reassignment_local_field_output: std.ArrayList(u8) = .empty;
    defer missing_nested_literal_reassignment_local_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_nested_aggregate_field_missing_literal_reassignment_local_field_provenance.mc", field_source, "c_nested_aggregate_field_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact", "outer", "inner.ptr", &missing_nested_literal_reassignment_local_field_output);
    const missing_nested_literal_reassignment_local_field_body = try cFunctionBody(missing_nested_literal_reassignment_local_field_output.items, "static uint32_t c_nested_aggregate_field_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(missing_nested_literal_reassignment_local_field_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_field_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none source=");
    try expectNotContains(missing_nested_literal_reassignment_local_field_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_field_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact subject=outer field=inner.ptr provenance");
    try expectContains(missing_nested_literal_reassignment_local_field_body, "return ((uint32_t)mc_race_load_u32(outer.inner.ptr));");
    try expectNotContains(missing_nested_literal_reassignment_local_field_body, "return *outer.inner.ptr;");

    var missing_nested_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_nested_copy_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_nested_aggregate_field_missing_copy_field_provenance.mc", field_source, "c_nested_aggregate_field_copy_direct_deref_requires_mir_field_fact", "copied", "inner.ptr", &missing_nested_copy_field_output);
    const missing_nested_copy_field_body = try cFunctionBody(missing_nested_copy_field_output.items, "static uint32_t c_nested_aggregate_field_copy_direct_deref_requires_mir_field_fact(void)");
    try expectNotContains(missing_nested_copy_field_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_field_copy_direct_deref_requires_mir_field_fact subject=copied field=inner.ptr provenance");
    try expectContains(missing_nested_copy_field_body, "return ((uint32_t)mc_race_load_u32(copied.inner.ptr));");
    try expectNotContains(missing_nested_copy_field_body, "return *copied.inner.ptr;");

    var missing_nested_assignment_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_nested_assignment_copy_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_nested_aggregate_field_missing_assignment_copy_field_provenance.mc", field_source, "c_nested_aggregate_field_assignment_copy_direct_deref_requires_mir_field_fact", "assigned", "inner.ptr", &missing_nested_assignment_copy_field_output);
    const missing_nested_assignment_copy_field_body = try cFunctionBody(missing_nested_assignment_copy_field_output.items, "static uint32_t c_nested_aggregate_field_assignment_copy_direct_deref_requires_mir_field_fact(void)");
    try expectNotContains(missing_nested_assignment_copy_field_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_field_assignment_copy_direct_deref_requires_mir_field_fact subject=assigned field=inner.ptr provenance");
    try expectContains(missing_nested_assignment_copy_field_body, "return ((uint32_t)mc_race_load_u32(assigned.inner.ptr));");
    try expectNotContains(missing_nested_assignment_copy_field_body, "return *assigned.inner.ptr;");

    var missing_nested_noalias_member_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_nested_noalias_member_copy_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_nested_aggregate_field_missing_noalias_member_copy_field_provenance.mc", field_source, "c_nested_aggregate_field_noalias_member_copy_direct_deref_requires_mir_field_fact", "dst", "inner.ptr", &missing_nested_noalias_member_copy_field_output);
    const missing_nested_noalias_member_copy_field_body = try cFunctionBody(missing_nested_noalias_member_copy_field_output.items, "static uint32_t c_nested_aggregate_field_noalias_member_copy_direct_deref_requires_mir_field_fact(void)");
    try expectNotContains(missing_nested_noalias_member_copy_field_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_field_noalias_member_copy_direct_deref_requires_mir_field_fact subject=dst field=inner.ptr provenance");
    try expectContains(missing_nested_noalias_member_copy_field_body, "return ((uint32_t)mc_race_load_u32(dst.inner.ptr));");
    try expectNotContains(missing_nested_noalias_member_copy_field_body, "return *dst.inner.ptr;");

    var missing_nested_casted_noalias_member_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_nested_casted_noalias_member_copy_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_nested_aggregate_field_missing_casted_noalias_member_copy_field_provenance.mc", field_source, "c_nested_aggregate_field_casted_noalias_member_copy_direct_deref_requires_mir_field_fact", "dst", "inner.ptr", &missing_nested_casted_noalias_member_copy_field_output);
    const missing_nested_casted_noalias_member_copy_field_body = try cFunctionBody(missing_nested_casted_noalias_member_copy_field_output.items, "static uint32_t c_nested_aggregate_field_casted_noalias_member_copy_direct_deref_requires_mir_field_fact(void)");
    try expectNotContains(missing_nested_casted_noalias_member_copy_field_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_field_casted_noalias_member_copy_direct_deref_requires_mir_field_fact subject=dst field=inner.ptr provenance");
    try expectContains(missing_nested_casted_noalias_member_copy_field_body, "return ((uint32_t)mc_race_load_u32(dst.inner.ptr));");
    try expectNotContains(missing_nested_casted_noalias_member_copy_field_body, "return *dst.inner.ptr;");

    var missing_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_copy_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_field_missing_copy_field_provenance.mc", field_source, "c_aggregate_field_local_copy_direct_deref_requires_mir_field_fact", "copied", "ptr", &missing_copy_field_output);
    const missing_copy_field_body = try cFunctionBody(missing_copy_field_output.items, "static uint32_t c_aggregate_field_local_copy_direct_deref_requires_mir_field_fact(void)");
    try expectNotContains(missing_copy_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_field_local_copy_direct_deref_requires_mir_field_fact subject=copied field=ptr provenance");
    try expectContains(missing_copy_field_body, "return ((uint32_t)mc_race_load_u32(copied.ptr));");
    try expectNotContains(missing_copy_field_body, "return *copied.ptr;");

    const array_source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptrs: [2]*mut u32 }
        \\struct RawHolder { ptrs: [2][*]mut u32 }
        \\struct Inner { ptrs: [2]*mut u32 }
        \\struct Outer { inner: Inner }
        \\struct RawInner { ptrs: [2][*]mut u32 }
        \\struct RawOuter { inner: RawInner }
        \\
        \\fn c_aggregate_array_element_read_requires_mir_fact() -> u32 {
        \\    let holder: Holder = .{ .ptrs = .{ &shared_counter, &shared_counter } };
        \\    let p: *mut u32 = holder.ptrs[0];
        \\    return p.*;
        \\}
        \\
        \\fn c_aggregate_array_element_noalias_read_requires_mir_fact() -> u32 {
        \\    let holder: Holder = .{ .ptrs = .{ &shared_counter, &shared_counter } };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        let p: *mut u32 = compiler.assume_noalias_unchecked(holder.ptrs[0], 4);
        \\        return p.*;
        \\    }
        \\}
        \\
        \\fn c_aggregate_array_element_assignment_requires_mir_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var holder: Holder = .{ .ptrs = .{ &local, &local } };
        \\    holder.ptrs[0] = &shared_counter;
        \\    var p: *mut u32 = &local;
        \\    p = holder.ptrs[0];
        \\    return p.*;
        \\}
        \\
        \\fn c_aggregate_array_element_pointer_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var holder: Holder = .{ .ptrs = .{ &local, &local } };
        \\    let gp: *mut u32 = &shared_counter;
        \\    holder.ptrs[0] = gp;
        \\    return holder.ptrs[0].*;
        \\}
        \\
        \\fn c_aggregate_array_element_raw_many_zero_direct_deref_requires_mir_field_fact() -> u32 {
        \\    unsafe {
        \\        var local: u32 = 0;
        \\        var holder: RawHolder = .{ .ptrs = .{ (&local) as [*]mut u32, (&local) as [*]mut u32 } };
        \\        let gp: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        holder.ptrs[0] = gp.offset(0);
        \\        return holder.ptrs[0].*;
        \\    }
        \\}
        \\
        \\fn c_aggregate_array_element_noalias_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var holder: Holder = .{ .ptrs = .{ &local, &local } };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        holder.ptrs[0] = compiler.assume_noalias_unchecked(&shared_counter, 4);
        \\    }
        \\    return holder.ptrs[0].*;
        \\}
        \\
        \\fn c_aggregate_array_element_noalias_read_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let src: Holder = .{ .ptrs = .{ &shared_counter, &local } };
        \\    var dst: Holder = .{ .ptrs = .{ &local, &local } };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        dst.ptrs[0] = compiler.assume_noalias_unchecked(src.ptrs[0], 4);
        \\    }
        \\    return dst.ptrs[0].*;
        \\}
        \\
        \\fn c_aggregate_array_element_casted_noalias_read_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let src: Holder = .{ .ptrs = .{ &shared_counter, &local } };
        \\    var dst: Holder = .{ .ptrs = .{ &local, &local } };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        dst.ptrs[0] = compiler.assume_noalias_unchecked(src.ptrs[0], 4) as *mut u32;
        \\    }
        \\    return dst.ptrs[0].*;
        \\}
        \\
        \\fn c_aggregate_array_element_literal_pointer_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let gp: *mut u32 = &shared_counter;
        \\    let holder: Holder = .{ .ptrs = .{ gp, &local } };
        \\    return holder.ptrs[0].*;
        \\}
        \\
        \\fn c_aggregate_array_element_literal_raw_many_zero_direct_deref_requires_mir_field_fact() -> u32 {
        \\    unsafe {
        \\        var local: u32 = 0;
        \\        let gp: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        let holder: RawHolder = .{ .ptrs = .{ gp.offset(0), (&local) as [*]mut u32 } };
        \\        return holder.ptrs[0].*;
        \\    }
        \\}
        \\
        \\fn c_aggregate_array_element_literal_noalias_direct_deref_requires_mir_field_fact() -> u32 {
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        var local: u32 = 0;
        \\        let holder: Holder = .{ .ptrs = .{ compiler.assume_noalias_unchecked(&shared_counter, 4), &local } };
        \\        return holder.ptrs[0].*;
        \\    }
        \\}
        \\
        \\fn c_aggregate_array_element_local_pointer_copy_literal_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let lp: *mut u32 = &local;
        \\    let holder: Holder = .{ .ptrs = .{ lp, &local } };
        \\    return holder.ptrs[0].*;
        \\}
        \\
        \\fn c_aggregate_array_element_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var holder: Holder = .{ .ptrs = .{ &local, &local } };
        \\    let gp: *mut u32 = &shared_counter;
        \\    holder = .{ .ptrs = .{ gp, &local } };
        \\    return holder.ptrs[0].*;
        \\}
        \\
        \\fn c_aggregate_array_element_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact() -> u32 {
        \\    unsafe {
        \\        var local: u32 = 0;
        \\        var holder: RawHolder = .{ .ptrs = .{ (&local) as [*]mut u32, (&local) as [*]mut u32 } };
        \\        let gp: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        holder = .{ .ptrs = .{ gp.offset(0), (&local) as [*]mut u32 } };
        \\        return holder.ptrs[0].*;
        \\    }
        \\}
        \\
        \\fn c_aggregate_array_element_literal_reassignment_noalias_direct_deref_requires_mir_field_fact() -> u32 {
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        var local: u32 = 0;
        \\        var holder: Holder = .{ .ptrs = .{ &local, &local } };
        \\        holder = .{ .ptrs = .{ compiler.assume_noalias_unchecked(&shared_counter, 4), &local } };
        \\        return holder.ptrs[0].*;
        \\    }
        \\}
        \\
        \\fn c_aggregate_array_element_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var holder: Holder = .{ .ptrs = .{ &local, &local } };
        \\    let lp: *mut u32 = &local;
        \\    holder = .{ .ptrs = .{ lp, &local } };
        \\    return holder.ptrs[0].*;
        \\}
        \\
        \\fn c_aggregate_array_element_copy_requires_mir_fact() -> u32 {
        \\    let holder: Holder = .{ .ptrs = .{ &shared_counter, &shared_counter } };
        \\    let copied: Holder = holder;
        \\    let p: *mut u32 = copied.ptrs[0];
        \\    return p.*;
        \\}
        \\
        \\fn c_aggregate_array_element_local_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let holder: Holder = .{ .ptrs = .{ &local, &local } };
        \\    return holder.ptrs[0].*;
        \\}
        \\
        \\fn c_aggregate_array_element_local_direct_store_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let holder: Holder = .{ .ptrs = .{ &local, &local } };
        \\    holder.ptrs[0].* = 9;
        \\    return local;
        \\}
        \\
        \\fn c_aggregate_array_element_local_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let holder: Holder = .{ .ptrs = .{ &local, &local } };
        \\    let copied: Holder = holder;
        \\    return copied.ptrs[0].*;
        \\}
        \\
        \\fn c_nested_aggregate_array_element_read_requires_mir_fact() -> u32 {
        \\    let outer: Outer = .{ .inner = .{ .ptrs = .{ &shared_counter, &shared_counter } } };
        \\    let p: *mut u32 = outer.inner.ptrs[0];
        \\    return p.*;
        \\}
        \\
        \\fn c_nested_aggregate_array_element_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    let outer: Outer = .{ .inner = .{ .ptrs = .{ &shared_counter, &shared_counter } } };
        \\    let copied: Outer = outer;
        \\    return copied.inner.ptrs[0].*;
        \\}
        \\
        \\fn c_nested_aggregate_array_element_assignment_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let outer: Outer = .{ .inner = .{ .ptrs = .{ &shared_counter, &shared_counter } } };
        \\    var assigned: Outer = .{ .inner = .{ .ptrs = .{ &local, &local } } };
        \\    assigned = outer;
        \\    return assigned.inner.ptrs[0].*;
        \\}
        \\
        \\fn c_nested_aggregate_array_element_noalias_member_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let src: Outer = .{ .inner = .{ .ptrs = .{ &shared_counter, &shared_counter } } };
        \\    var dst: Outer = .{ .inner = .{ .ptrs = .{ &local, &local } } };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        dst.inner = compiler.assume_noalias_unchecked(src.inner, 4);
        \\    }
        \\    return dst.inner.ptrs[0].*;
        \\}
        \\
        \\fn c_nested_aggregate_array_element_casted_noalias_member_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let src: Outer = .{ .inner = .{ .ptrs = .{ &shared_counter, &shared_counter } } };
        \\    var dst: Outer = .{ .inner = .{ .ptrs = .{ &local, &local } } };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        dst.inner = compiler.assume_noalias_unchecked(src.inner, 4) as Inner;
        \\    }
        \\    return dst.inner.ptrs[0].*;
        \\}
        \\
        \\fn c_nested_aggregate_array_element_assignment_requires_mir_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var outer: Outer = .{ .inner = .{ .ptrs = .{ &local, &local } } };
        \\    outer.inner.ptrs[0] = &shared_counter;
        \\    var p: *mut u32 = &local;
        \\    p = outer.inner.ptrs[0];
        \\    return p.*;
        \\}
        \\
        \\fn c_nested_aggregate_array_element_literal_local_pointer_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var other: u32 = 0;
        \\    let lp: *mut u32 = &local;
        \\    let outer: Outer = .{ .inner = .{ .ptrs = .{ lp, &other } } };
        \\    return outer.inner.ptrs[0].*;
        \\}
        \\
        \\fn c_nested_aggregate_array_element_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var outer: Outer = .{ .inner = .{ .ptrs = .{ &local, &local } } };
        \\    let gp: *mut u32 = &shared_counter;
        \\    outer.inner = .{ .ptrs = .{ gp, &local } };
        \\    return outer.inner.ptrs[0].*;
        \\}
        \\
        \\fn c_nested_aggregate_array_element_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var other: u32 = 0;
        \\    var outer: Outer = .{ .inner = .{ .ptrs = .{ &other, &other } } };
        \\    let lp: *mut u32 = &local;
        \\    outer.inner = .{ .ptrs = .{ lp, &other } };
        \\    return outer.inner.ptrs[0].*;
        \\}
        \\
        \\fn c_nested_aggregate_array_element_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact() -> u32 {
        \\    unsafe {
        \\        var local: u32 = 0;
        \\        var outer: RawOuter = .{ .inner = .{ .ptrs = .{ (&local) as [*]mut u32, (&local) as [*]mut u32 } } };
        \\        let gp: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        outer.inner = .{ .ptrs = .{ gp.offset(0), (&local) as [*]mut u32 } };
        \\        return outer.inner.ptrs[0].*;
        \\    }
        \\}
        \\
        \\fn c_nested_aggregate_array_element_literal_reassignment_noalias_direct_deref_requires_mir_field_fact() -> u32 {
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        var local: u32 = 0;
        \\        var outer: Outer = .{ .inner = .{ .ptrs = .{ &local, &local } } };
        \\        outer.inner = .{ .ptrs = .{ compiler.assume_noalias_unchecked(&shared_counter, 4), &local } };
        \\        return outer.inner.ptrs[0].*;
        \\    }
        \\}
    ;

    var missing_array_output: std.ArrayList(u8) = .empty;
    defer missing_array_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_aggregate_array_element_missing_provenance.mc", array_source, "c_aggregate_array_element_read_requires_mir_fact", "p", &missing_array_output);
    const missing_array_body = try cFunctionBody(missing_array_output.items, "static uint32_t c_aggregate_array_element_read_requires_mir_fact(void)");
    try expectNotContains(missing_array_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_read_requires_mir_fact subject=p provenance");
    try expectContains(missing_array_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(missing_array_body, "return *p;");

    var missing_array_noalias_read_output: std.ArrayList(u8) = .empty;
    defer missing_array_noalias_read_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_aggregate_array_element_missing_noalias_read_provenance.mc", array_source, "c_aggregate_array_element_noalias_read_requires_mir_fact", "p", &missing_array_noalias_read_output);
    const missing_array_noalias_read_body = try cFunctionBody(missing_array_noalias_read_output.items, "static uint32_t c_aggregate_array_element_noalias_read_requires_mir_fact(void)");
    try expectContains(missing_array_noalias_read_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_noalias_read_requires_mir_fact subject=holder field=ptrs element=0 provenance=global_storage reason=none source=");
    try expectNotContains(missing_array_noalias_read_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_noalias_read_requires_mir_fact subject=p provenance");
    try expectContains(missing_array_noalias_read_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(missing_array_noalias_read_body, "return *p;");

    var missing_array_assignment_output: std.ArrayList(u8) = .empty;
    defer missing_array_assignment_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_aggregate_array_element_missing_provenance.mc", array_source, "c_aggregate_array_element_assignment_requires_mir_fact", "p", &missing_array_assignment_output);
    const missing_array_assignment_body = try cFunctionBody(missing_array_assignment_output.items, "static uint32_t c_aggregate_array_element_assignment_requires_mir_fact(void)");
    try expectNotContains(missing_array_assignment_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_assignment_requires_mir_fact subject=p provenance");
    try expectContains(missing_array_assignment_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(missing_array_assignment_body, "return *p;");

    var missing_array_copy_output: std.ArrayList(u8) = .empty;
    defer missing_array_copy_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_aggregate_array_element_missing_provenance.mc", array_source, "c_aggregate_array_element_copy_requires_mir_fact", "p", &missing_array_copy_output);
    const missing_array_copy_body = try cFunctionBody(missing_array_copy_output.items, "static uint32_t c_aggregate_array_element_copy_requires_mir_fact(void)");
    try expectNotContains(missing_array_copy_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_copy_requires_mir_fact subject=p provenance");
    try expectContains(missing_array_copy_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(missing_array_copy_body, "return *p;");

    var missing_array_nested_output: std.ArrayList(u8) = .empty;
    defer missing_array_nested_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_aggregate_array_element_missing_provenance.mc", array_source, "c_nested_aggregate_array_element_read_requires_mir_fact", "p", &missing_array_nested_output);
    const missing_array_nested_body = try cFunctionBody(missing_array_nested_output.items, "static uint32_t c_nested_aggregate_array_element_read_requires_mir_fact(void)");
    try expectNotContains(missing_array_nested_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_array_element_read_requires_mir_fact subject=p provenance");
    try expectContains(missing_array_nested_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(missing_array_nested_body, "return *p;");

    var missing_array_nested_assignment_output: std.ArrayList(u8) = .empty;
    defer missing_array_nested_assignment_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_aggregate_array_element_missing_provenance.mc", array_source, "c_nested_aggregate_array_element_assignment_requires_mir_fact", "p", &missing_array_nested_assignment_output);
    const missing_array_nested_assignment_body = try cFunctionBody(missing_array_nested_assignment_output.items, "static uint32_t c_nested_aggregate_array_element_assignment_requires_mir_fact(void)");
    try expectNotContains(missing_array_nested_assignment_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_array_element_assignment_requires_mir_fact subject=p provenance");
    try expectContains(missing_array_nested_assignment_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(missing_array_nested_assignment_body, "return *p;");

    var normal_array_output: std.ArrayList(u8) = .empty;
    defer normal_array_output.deinit(std.testing.allocator);
    try appendCheckedCTest("emit_c_aggregate_array_element_field_provenance_required.mc", array_source, &normal_array_output);
    const normal_array_body = try cFunctionBody(normal_array_output.items, "static uint32_t c_aggregate_array_element_read_requires_mir_fact(void)");
    try expectContains(normal_array_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_read_requires_mir_fact subject=holder field=ptrs element=0 provenance=global_storage reason=none source=");

    const normal_array_noalias_read_body = try cFunctionBody(normal_array_output.items, "static uint32_t c_aggregate_array_element_noalias_read_requires_mir_fact(void)");
    try expectContains(normal_array_noalias_read_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_noalias_read_requires_mir_fact subject=holder field=ptrs element=0 provenance=global_storage reason=none source=");
    try expectContains(normal_array_noalias_read_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_noalias_read_requires_mir_fact subject=p provenance=global_storage reason=none source=");
    try expectContains(normal_array_noalias_read_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(normal_array_noalias_read_body, "return *p;");

    const normal_array_pointer_copy_direct_body = try cFunctionBody(normal_array_output.items, "static uint32_t c_aggregate_array_element_pointer_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_array_pointer_copy_direct_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none source=");
    try expectContains(normal_array_pointer_copy_direct_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_pointer_copy_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance=global_storage reason=reassignment source=");
    try expectContains(normal_array_pointer_copy_direct_body, "return ((uint32_t)mc_race_load_u32(holder.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(normal_array_pointer_copy_direct_body, "return *holder.ptrs.elems[mc_check_index_usize(0, 2)];");

    const normal_array_raw_many_zero_direct_body = try cFunctionBody(normal_array_output.items, "static uint32_t c_aggregate_array_element_raw_many_zero_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_array_raw_many_zero_direct_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_raw_many_zero_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none source=");
    try expectContains(normal_array_raw_many_zero_direct_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_raw_many_zero_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance=global_storage reason=reassignment source=");
    try expectContains(normal_array_raw_many_zero_direct_body, "return ((uint32_t)mc_race_load_u32(holder.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(normal_array_raw_many_zero_direct_body, "return *holder.ptrs.elems[mc_check_index_usize(0, 2)];");

    const normal_array_noalias_direct_body = try cFunctionBody(normal_array_output.items, "static uint32_t c_aggregate_array_element_noalias_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_array_noalias_direct_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_noalias_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance=global_storage reason=reassignment source=");
    try expectContains(normal_array_noalias_direct_body, "return ((uint32_t)mc_race_load_u32(holder.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(normal_array_noalias_direct_body, "return *holder.ptrs.elems[mc_check_index_usize(0, 2)];");

    const normal_array_noalias_read_direct_body = try cFunctionBody(normal_array_output.items, "static uint32_t c_aggregate_array_element_noalias_read_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_array_noalias_read_direct_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_noalias_read_direct_deref_requires_mir_field_fact subject=src field=ptrs element=0 provenance=global_storage reason=none source=");
    try expectContains(normal_array_noalias_read_direct_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_noalias_read_direct_deref_requires_mir_field_fact subject=dst field=ptrs element=0 provenance=global_storage reason=reassignment source=");
    try expectContains(normal_array_noalias_read_direct_body, "return ((uint32_t)mc_race_load_u32(dst.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(normal_array_noalias_read_direct_body, "return *dst.ptrs.elems[mc_check_index_usize(0, 2)];");

    const normal_array_casted_noalias_read_direct_body = try cFunctionBody(normal_array_output.items, "static uint32_t c_aggregate_array_element_casted_noalias_read_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_array_casted_noalias_read_direct_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_casted_noalias_read_direct_deref_requires_mir_field_fact subject=src field=ptrs element=0 provenance=global_storage reason=none source=");
    try expectContains(normal_array_casted_noalias_read_direct_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_casted_noalias_read_direct_deref_requires_mir_field_fact subject=dst field=ptrs element=0 provenance=global_storage reason=reassignment source=");
    try expectContains(normal_array_casted_noalias_read_direct_body, "return ((uint32_t)mc_race_load_u32(dst.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(normal_array_casted_noalias_read_direct_body, "return *dst.ptrs.elems[mc_check_index_usize(0, 2)];");

    const normal_array_literal_pointer_copy_body = try cFunctionBody(normal_array_output.items, "static uint32_t c_aggregate_array_element_literal_pointer_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_array_literal_pointer_copy_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_literal_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none source=");
    try expectContains(normal_array_literal_pointer_copy_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_literal_pointer_copy_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance=global_storage reason=none source=");
    try expectContains(normal_array_literal_pointer_copy_body, "return ((uint32_t)mc_race_load_u32(holder.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(normal_array_literal_pointer_copy_body, "return *holder.ptrs.elems[mc_check_index_usize(0, 2)];");

    const normal_array_literal_raw_many_zero_body = try cFunctionBody(normal_array_output.items, "static uint32_t c_aggregate_array_element_literal_raw_many_zero_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_array_literal_raw_many_zero_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_literal_raw_many_zero_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none source=");
    try expectContains(normal_array_literal_raw_many_zero_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_literal_raw_many_zero_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance=global_storage reason=none source=");
    try expectContains(normal_array_literal_raw_many_zero_body, "return ((uint32_t)mc_race_load_u32(holder.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(normal_array_literal_raw_many_zero_body, "return *holder.ptrs.elems[mc_check_index_usize(0, 2)];");

    const normal_array_literal_noalias_body = try cFunctionBody(normal_array_output.items, "static uint32_t c_aggregate_array_element_literal_noalias_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_array_literal_noalias_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_literal_noalias_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance=global_storage reason=none source=");
    try expectContains(normal_array_literal_noalias_body, "return ((uint32_t)mc_race_load_u32(holder.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(normal_array_literal_noalias_body, "return *holder.ptrs.elems[mc_check_index_usize(0, 2)];");

    const normal_array_local_pointer_copy_literal_body = try cFunctionBody(normal_array_output.items, "static uint32_t c_aggregate_array_element_local_pointer_copy_literal_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_array_local_pointer_copy_literal_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_local_pointer_copy_literal_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none source=");
    try expectContains(normal_array_local_pointer_copy_literal_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_local_pointer_copy_literal_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance=local_storage reason=none source=");
    try expectContains(normal_array_local_pointer_copy_literal_body, "return *holder.ptrs.elems[mc_check_index_usize(0, 2)];");
    try expectNotContains(normal_array_local_pointer_copy_literal_body, "mc_race_load_u32(");

    const normal_array_literal_reassignment_pointer_copy_body = try cFunctionBody(normal_array_output.items, "static uint32_t c_aggregate_array_element_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_array_literal_reassignment_pointer_copy_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none source=");
    try expectContains(normal_array_literal_reassignment_pointer_copy_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance=global_storage reason=none source=");
    try expectContains(normal_array_literal_reassignment_pointer_copy_body, "return ((uint32_t)mc_race_load_u32(holder.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(normal_array_literal_reassignment_pointer_copy_body, "return *holder.ptrs.elems[mc_check_index_usize(0, 2)];");

    const normal_array_literal_reassignment_raw_many_zero_body = try cFunctionBody(normal_array_output.items, "static uint32_t c_aggregate_array_element_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_array_literal_reassignment_raw_many_zero_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none source=");
    try expectContains(normal_array_literal_reassignment_raw_many_zero_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance=global_storage reason=none source=");
    try expectContains(normal_array_literal_reassignment_raw_many_zero_body, "return ((uint32_t)mc_race_load_u32(holder.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(normal_array_literal_reassignment_raw_many_zero_body, "return *holder.ptrs.elems[mc_check_index_usize(0, 2)];");

    const normal_array_literal_reassignment_noalias_body = try cFunctionBody(normal_array_output.items, "static uint32_t c_aggregate_array_element_literal_reassignment_noalias_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_array_literal_reassignment_noalias_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_literal_reassignment_noalias_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance=global_storage reason=none source=");
    try expectContains(normal_array_literal_reassignment_noalias_body, "return ((uint32_t)mc_race_load_u32(holder.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(normal_array_literal_reassignment_noalias_body, "return *holder.ptrs.elems[mc_check_index_usize(0, 2)];");

    const normal_array_local_pointer_copy_literal_reassignment_body = try cFunctionBody(normal_array_output.items, "static uint32_t c_aggregate_array_element_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_array_local_pointer_copy_literal_reassignment_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none source=");
    try expectContains(normal_array_local_pointer_copy_literal_reassignment_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance=local_storage reason=none source=");
    try expectContains(normal_array_local_pointer_copy_literal_reassignment_body, "return *holder.ptrs.elems[mc_check_index_usize(0, 2)];");
    try expectNotContains(normal_array_local_pointer_copy_literal_reassignment_body, "mc_race_load_u32(");

    const normal_nested_array_literal_local_pointer_copy_body = try cFunctionBody(normal_array_output.items, "static uint32_t c_nested_aggregate_array_element_literal_local_pointer_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_nested_array_literal_local_pointer_copy_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_array_element_literal_local_pointer_copy_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none source=");
    try expectContains(normal_nested_array_literal_local_pointer_copy_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_array_element_literal_local_pointer_copy_direct_deref_requires_mir_field_fact subject=outer field=inner.ptrs element=0 provenance=local_storage reason=none source=");
    try expectContains(normal_nested_array_literal_local_pointer_copy_body, "return *outer.inner.ptrs.elems[mc_check_index_usize(0, 2)];");
    try expectNotContains(normal_nested_array_literal_local_pointer_copy_body, "mc_race_load_u32(");

    const normal_nested_array_literal_reassignment_pointer_copy_body = try cFunctionBody(normal_array_output.items, "static uint32_t c_nested_aggregate_array_element_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_nested_array_literal_reassignment_pointer_copy_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_array_element_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none source=");
    try expectContains(normal_nested_array_literal_reassignment_pointer_copy_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_array_element_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact subject=outer field=inner.ptrs element=0 provenance=global_storage reason=none source=");
    try expectContains(normal_nested_array_literal_reassignment_pointer_copy_body, "return ((uint32_t)mc_race_load_u32(outer.inner.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(normal_nested_array_literal_reassignment_pointer_copy_body, "return *outer.inner.ptrs.elems[mc_check_index_usize(0, 2)];");

    const normal_nested_array_literal_reassignment_local_pointer_copy_body = try cFunctionBody(normal_array_output.items, "static uint32_t c_nested_aggregate_array_element_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_nested_array_literal_reassignment_local_pointer_copy_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_array_element_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none source=");
    try expectContains(normal_nested_array_literal_reassignment_local_pointer_copy_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_array_element_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact subject=outer field=inner.ptrs element=0 provenance=local_storage reason=none source=");
    try expectContains(normal_nested_array_literal_reassignment_local_pointer_copy_body, "return *outer.inner.ptrs.elems[mc_check_index_usize(0, 2)];");
    try expectNotContains(normal_nested_array_literal_reassignment_local_pointer_copy_body, "mc_race_load_u32(");

    const normal_nested_array_literal_reassignment_raw_many_zero_body = try cFunctionBody(normal_array_output.items, "static uint32_t c_nested_aggregate_array_element_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_nested_array_literal_reassignment_raw_many_zero_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_array_element_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none source=");
    try expectContains(normal_nested_array_literal_reassignment_raw_many_zero_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_array_element_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact subject=outer field=inner.ptrs element=0 provenance=global_storage reason=none source=");
    try expectContains(normal_nested_array_literal_reassignment_raw_many_zero_body, "return ((uint32_t)mc_race_load_u32(outer.inner.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(normal_nested_array_literal_reassignment_raw_many_zero_body, "return *outer.inner.ptrs.elems[mc_check_index_usize(0, 2)];");

    const normal_nested_array_literal_reassignment_noalias_body = try cFunctionBody(normal_array_output.items, "static uint32_t c_nested_aggregate_array_element_literal_reassignment_noalias_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_nested_array_literal_reassignment_noalias_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_array_element_literal_reassignment_noalias_direct_deref_requires_mir_field_fact subject=outer field=inner.ptrs element=0 provenance=global_storage reason=none source=");
    try expectContains(normal_nested_array_literal_reassignment_noalias_body, "return ((uint32_t)mc_race_load_u32(outer.inner.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(normal_nested_array_literal_reassignment_noalias_body, "return *outer.inner.ptrs.elems[mc_check_index_usize(0, 2)];");

    const normal_nested_array_copy_body = try cFunctionBody(normal_array_output.items, "static uint32_t c_nested_aggregate_array_element_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_nested_array_copy_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_array_element_copy_direct_deref_requires_mir_field_fact subject=copied field=inner.ptrs element=0 provenance=global_storage reason=none source=");
    try expectContains(normal_nested_array_copy_body, "return ((uint32_t)mc_race_load_u32(copied.inner.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(normal_nested_array_copy_body, "return *copied.inner.ptrs.elems[mc_check_index_usize(0, 2)];");

    const normal_nested_array_assignment_copy_body = try cFunctionBody(normal_array_output.items, "static uint32_t c_nested_aggregate_array_element_assignment_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_nested_array_assignment_copy_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_array_element_assignment_copy_direct_deref_requires_mir_field_fact subject=assigned field=inner.ptrs element=0 provenance=global_storage reason=reassignment source=");
    try expectContains(normal_nested_array_assignment_copy_body, "return ((uint32_t)mc_race_load_u32(assigned.inner.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(normal_nested_array_assignment_copy_body, "return *assigned.inner.ptrs.elems[mc_check_index_usize(0, 2)];");

    const normal_nested_array_casted_noalias_member_copy_body = try cFunctionBody(normal_array_output.items, "static uint32_t c_nested_aggregate_array_element_casted_noalias_member_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_nested_array_casted_noalias_member_copy_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_array_element_casted_noalias_member_copy_direct_deref_requires_mir_field_fact subject=dst field=inner.ptrs element=0 provenance=global_storage reason=reassignment source=");
    try expectContains(normal_nested_array_casted_noalias_member_copy_body, "return ((uint32_t)mc_race_load_u32(dst.inner.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(normal_nested_array_casted_noalias_member_copy_body, "return *dst.inner.ptrs.elems[mc_check_index_usize(0, 2)];");

    const normal_nested_array_noalias_member_copy_body = try cFunctionBody(normal_array_output.items, "static uint32_t c_nested_aggregate_array_element_noalias_member_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_nested_array_noalias_member_copy_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_array_element_noalias_member_copy_direct_deref_requires_mir_field_fact subject=dst field=inner.ptrs element=0 provenance=global_storage reason=reassignment source=");
    try expectContains(normal_nested_array_noalias_member_copy_body, "return ((uint32_t)mc_race_load_u32(dst.inner.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(normal_nested_array_noalias_member_copy_body, "return *dst.inner.ptrs.elems[mc_check_index_usize(0, 2)];");

    const normal_array_local_direct_body = try cFunctionBody(normal_array_output.items, "static uint32_t c_aggregate_array_element_local_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_array_local_direct_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_local_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance=local_storage reason=none source=");
    try expectContains(normal_array_local_direct_body, "return *holder.ptrs.elems[mc_check_index_usize(0, 2)];");
    try expectNotContains(normal_array_local_direct_body, "mc_race_load_u32(");

    const normal_array_local_store_body = try cFunctionBody(normal_array_output.items, "static uint32_t c_aggregate_array_element_local_direct_store_requires_mir_field_fact(void)");
    try expectContains(normal_array_local_store_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_local_direct_store_requires_mir_field_fact subject=holder field=ptrs element=0 provenance=local_storage reason=none source=");
    try expectNotContains(normal_array_local_store_body, "mc_race_store_u32(holder.ptrs.elems[mc_check_index_usize(0, 2)]");

    const normal_array_local_copy_body = try cFunctionBody(normal_array_output.items, "static uint32_t c_aggregate_array_element_local_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(normal_array_local_copy_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_local_copy_direct_deref_requires_mir_field_fact subject=copied field=ptrs element=0 provenance=local_storage reason=none source=");
    try expectContains(normal_array_local_copy_body, "return *copied.ptrs.elems[mc_check_index_usize(0, 2)];");
    try expectNotContains(normal_array_local_copy_body, "mc_race_load_u32(");

    var missing_array_field_output: std.ArrayList(u8) = .empty;
    defer missing_array_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_array_element_missing_field_provenance.mc", array_source, "c_aggregate_array_element_local_direct_deref_requires_mir_field_fact", "holder", "ptrs", &missing_array_field_output);
    const missing_array_field_body = try cFunctionBody(missing_array_field_output.items, "static uint32_t c_aggregate_array_element_local_direct_deref_requires_mir_field_fact(void)");
    try expectNotContains(missing_array_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_local_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance");
    try expectContains(missing_array_field_body, "return ((uint32_t)mc_race_load_u32(holder.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(missing_array_field_body, "return *holder.ptrs.elems[mc_check_index_usize(0, 2)];");

    var missing_array_store_field_output: std.ArrayList(u8) = .empty;
    defer missing_array_store_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_array_element_missing_store_field_provenance.mc", array_source, "c_aggregate_array_element_local_direct_store_requires_mir_field_fact", "holder", "ptrs", &missing_array_store_field_output);
    const missing_array_store_field_body = try cFunctionBody(missing_array_store_field_output.items, "static uint32_t c_aggregate_array_element_local_direct_store_requires_mir_field_fact(void)");
    try expectNotContains(missing_array_store_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_local_direct_store_requires_mir_field_fact subject=holder field=ptrs element=0 provenance");
    try expectContains(missing_array_store_field_body, "mc_race_store_u32(holder.ptrs.elems[mc_check_index_usize(0, 2)],");

    var missing_array_pointer_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_array_pointer_copy_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_array_element_missing_pointer_copy_field_provenance.mc", array_source, "c_aggregate_array_element_pointer_copy_direct_deref_requires_mir_field_fact", "holder", "ptrs", &missing_array_pointer_copy_field_output);
    const missing_array_pointer_copy_field_body = try cFunctionBody(missing_array_pointer_copy_field_output.items, "static uint32_t c_aggregate_array_element_pointer_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(missing_array_pointer_copy_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none source=");
    try expectNotContains(missing_array_pointer_copy_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_pointer_copy_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance");
    try expectContains(missing_array_pointer_copy_field_body, "return ((uint32_t)mc_race_load_u32(holder.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(missing_array_pointer_copy_field_body, "return *holder.ptrs.elems[mc_check_index_usize(0, 2)];");

    var missing_array_raw_many_zero_field_output: std.ArrayList(u8) = .empty;
    defer missing_array_raw_many_zero_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_array_element_missing_raw_many_zero_field_provenance.mc", array_source, "c_aggregate_array_element_raw_many_zero_direct_deref_requires_mir_field_fact", "holder", "ptrs", &missing_array_raw_many_zero_field_output);
    const missing_array_raw_many_zero_field_body = try cFunctionBody(missing_array_raw_many_zero_field_output.items, "static uint32_t c_aggregate_array_element_raw_many_zero_direct_deref_requires_mir_field_fact(void)");
    try expectContains(missing_array_raw_many_zero_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_raw_many_zero_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none source=");
    try expectNotContains(missing_array_raw_many_zero_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_raw_many_zero_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance");
    try expectContains(missing_array_raw_many_zero_field_body, "return ((uint32_t)mc_race_load_u32(holder.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(missing_array_raw_many_zero_field_body, "return *holder.ptrs.elems[mc_check_index_usize(0, 2)];");

    var missing_array_noalias_field_output: std.ArrayList(u8) = .empty;
    defer missing_array_noalias_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_array_element_missing_noalias_field_provenance.mc", array_source, "c_aggregate_array_element_noalias_direct_deref_requires_mir_field_fact", "holder", "ptrs", &missing_array_noalias_field_output);
    const missing_array_noalias_field_body = try cFunctionBody(missing_array_noalias_field_output.items, "static uint32_t c_aggregate_array_element_noalias_direct_deref_requires_mir_field_fact(void)");
    try expectNotContains(missing_array_noalias_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_noalias_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance");
    try expectContains(missing_array_noalias_field_body, "return ((uint32_t)mc_race_load_u32(holder.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(missing_array_noalias_field_body, "return *holder.ptrs.elems[mc_check_index_usize(0, 2)];");

    var missing_array_noalias_read_field_output: std.ArrayList(u8) = .empty;
    defer missing_array_noalias_read_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_array_element_missing_noalias_read_field_provenance.mc", array_source, "c_aggregate_array_element_noalias_read_direct_deref_requires_mir_field_fact", "dst", "ptrs", &missing_array_noalias_read_field_output);
    const missing_array_noalias_read_field_body = try cFunctionBody(missing_array_noalias_read_field_output.items, "static uint32_t c_aggregate_array_element_noalias_read_direct_deref_requires_mir_field_fact(void)");
    try expectContains(missing_array_noalias_read_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_noalias_read_direct_deref_requires_mir_field_fact subject=src field=ptrs element=0 provenance=global_storage reason=none source=");
    try expectNotContains(missing_array_noalias_read_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_noalias_read_direct_deref_requires_mir_field_fact subject=dst field=ptrs element=0 provenance");
    try expectContains(missing_array_noalias_read_field_body, "return ((uint32_t)mc_race_load_u32(dst.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(missing_array_noalias_read_field_body, "return *dst.ptrs.elems[mc_check_index_usize(0, 2)];");

    var missing_array_casted_noalias_read_field_output: std.ArrayList(u8) = .empty;
    defer missing_array_casted_noalias_read_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_array_element_missing_casted_noalias_read_field_provenance.mc", array_source, "c_aggregate_array_element_casted_noalias_read_direct_deref_requires_mir_field_fact", "dst", "ptrs", &missing_array_casted_noalias_read_field_output);
    const missing_array_casted_noalias_read_field_body = try cFunctionBody(missing_array_casted_noalias_read_field_output.items, "static uint32_t c_aggregate_array_element_casted_noalias_read_direct_deref_requires_mir_field_fact(void)");
    try expectContains(missing_array_casted_noalias_read_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_casted_noalias_read_direct_deref_requires_mir_field_fact subject=src field=ptrs element=0 provenance=global_storage reason=none source=");
    try expectNotContains(missing_array_casted_noalias_read_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_casted_noalias_read_direct_deref_requires_mir_field_fact subject=dst field=ptrs element=0 provenance");
    try expectContains(missing_array_casted_noalias_read_field_body, "return ((uint32_t)mc_race_load_u32(dst.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(missing_array_casted_noalias_read_field_body, "return *dst.ptrs.elems[mc_check_index_usize(0, 2)];");

    var missing_array_literal_pointer_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_array_literal_pointer_copy_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_array_element_missing_literal_pointer_copy_field_provenance.mc", array_source, "c_aggregate_array_element_literal_pointer_copy_direct_deref_requires_mir_field_fact", "holder", "ptrs", &missing_array_literal_pointer_copy_field_output);
    const missing_array_literal_pointer_copy_field_body = try cFunctionBody(missing_array_literal_pointer_copy_field_output.items, "static uint32_t c_aggregate_array_element_literal_pointer_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(missing_array_literal_pointer_copy_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_literal_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none source=");
    try expectNotContains(missing_array_literal_pointer_copy_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_literal_pointer_copy_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance");
    try expectContains(missing_array_literal_pointer_copy_field_body, "return ((uint32_t)mc_race_load_u32(holder.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(missing_array_literal_pointer_copy_field_body, "return *holder.ptrs.elems[mc_check_index_usize(0, 2)];");

    var missing_array_literal_raw_many_zero_field_output: std.ArrayList(u8) = .empty;
    defer missing_array_literal_raw_many_zero_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_array_element_missing_literal_raw_many_zero_field_provenance.mc", array_source, "c_aggregate_array_element_literal_raw_many_zero_direct_deref_requires_mir_field_fact", "holder", "ptrs", &missing_array_literal_raw_many_zero_field_output);
    const missing_array_literal_raw_many_zero_field_body = try cFunctionBody(missing_array_literal_raw_many_zero_field_output.items, "static uint32_t c_aggregate_array_element_literal_raw_many_zero_direct_deref_requires_mir_field_fact(void)");
    try expectContains(missing_array_literal_raw_many_zero_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_literal_raw_many_zero_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none source=");
    try expectNotContains(missing_array_literal_raw_many_zero_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_literal_raw_many_zero_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance");
    try expectContains(missing_array_literal_raw_many_zero_field_body, "return ((uint32_t)mc_race_load_u32(holder.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(missing_array_literal_raw_many_zero_field_body, "return *holder.ptrs.elems[mc_check_index_usize(0, 2)];");

    var missing_array_literal_noalias_field_output: std.ArrayList(u8) = .empty;
    defer missing_array_literal_noalias_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_array_element_missing_literal_noalias_field_provenance.mc", array_source, "c_aggregate_array_element_literal_noalias_direct_deref_requires_mir_field_fact", "holder", "ptrs", &missing_array_literal_noalias_field_output);
    const missing_array_literal_noalias_field_body = try cFunctionBody(missing_array_literal_noalias_field_output.items, "static uint32_t c_aggregate_array_element_literal_noalias_direct_deref_requires_mir_field_fact(void)");
    try expectNotContains(missing_array_literal_noalias_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_literal_noalias_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance");
    try expectContains(missing_array_literal_noalias_field_body, "return ((uint32_t)mc_race_load_u32(holder.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(missing_array_literal_noalias_field_body, "return *holder.ptrs.elems[mc_check_index_usize(0, 2)];");

    var missing_array_local_pointer_copy_literal_field_output: std.ArrayList(u8) = .empty;
    defer missing_array_local_pointer_copy_literal_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_array_element_missing_local_pointer_copy_literal_field_provenance.mc", array_source, "c_aggregate_array_element_local_pointer_copy_literal_direct_deref_requires_mir_field_fact", "holder", "ptrs", &missing_array_local_pointer_copy_literal_field_output);
    const missing_array_local_pointer_copy_literal_field_body = try cFunctionBody(missing_array_local_pointer_copy_literal_field_output.items, "static uint32_t c_aggregate_array_element_local_pointer_copy_literal_direct_deref_requires_mir_field_fact(void)");
    try expectContains(missing_array_local_pointer_copy_literal_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_local_pointer_copy_literal_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none source=");
    try expectNotContains(missing_array_local_pointer_copy_literal_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_local_pointer_copy_literal_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance");
    try expectContains(missing_array_local_pointer_copy_literal_field_body, "return ((uint32_t)mc_race_load_u32(holder.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(missing_array_local_pointer_copy_literal_field_body, "return *holder.ptrs.elems[mc_check_index_usize(0, 2)];");

    var missing_nested_array_local_pointer_copy_literal_field_output: std.ArrayList(u8) = .empty;
    defer missing_nested_array_local_pointer_copy_literal_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_nested_aggregate_array_element_missing_local_pointer_copy_literal_field_provenance.mc", array_source, "c_nested_aggregate_array_element_literal_local_pointer_copy_direct_deref_requires_mir_field_fact", "outer", "inner.ptrs", &missing_nested_array_local_pointer_copy_literal_field_output);
    const missing_nested_array_local_pointer_copy_literal_field_body = try cFunctionBody(missing_nested_array_local_pointer_copy_literal_field_output.items, "static uint32_t c_nested_aggregate_array_element_literal_local_pointer_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(missing_nested_array_local_pointer_copy_literal_field_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_array_element_literal_local_pointer_copy_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none source=");
    try expectNotContains(missing_nested_array_local_pointer_copy_literal_field_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_array_element_literal_local_pointer_copy_direct_deref_requires_mir_field_fact subject=outer field=inner.ptrs element=0 provenance");
    try expectContains(missing_nested_array_local_pointer_copy_literal_field_body, "return ((uint32_t)mc_race_load_u32(outer.inner.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(missing_nested_array_local_pointer_copy_literal_field_body, "return *outer.inner.ptrs.elems[mc_check_index_usize(0, 2)];");

    var missing_array_literal_reassignment_pointer_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_array_literal_reassignment_pointer_copy_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_array_element_missing_literal_reassignment_pointer_copy_field_provenance.mc", array_source, "c_aggregate_array_element_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact", "holder", "ptrs", &missing_array_literal_reassignment_pointer_copy_field_output);
    const missing_array_literal_reassignment_pointer_copy_field_body = try cFunctionBody(missing_array_literal_reassignment_pointer_copy_field_output.items, "static uint32_t c_aggregate_array_element_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(missing_array_literal_reassignment_pointer_copy_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none source=");
    try expectNotContains(missing_array_literal_reassignment_pointer_copy_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance");
    try expectContains(missing_array_literal_reassignment_pointer_copy_field_body, "return ((uint32_t)mc_race_load_u32(holder.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(missing_array_literal_reassignment_pointer_copy_field_body, "return *holder.ptrs.elems[mc_check_index_usize(0, 2)];");

    var missing_array_literal_reassignment_raw_many_zero_field_output: std.ArrayList(u8) = .empty;
    defer missing_array_literal_reassignment_raw_many_zero_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_array_element_missing_literal_reassignment_raw_many_zero_field_provenance.mc", array_source, "c_aggregate_array_element_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact", "holder", "ptrs", &missing_array_literal_reassignment_raw_many_zero_field_output);
    const missing_array_literal_reassignment_raw_many_zero_field_body = try cFunctionBody(missing_array_literal_reassignment_raw_many_zero_field_output.items, "static uint32_t c_aggregate_array_element_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact(void)");
    try expectContains(missing_array_literal_reassignment_raw_many_zero_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none source=");
    try expectNotContains(missing_array_literal_reassignment_raw_many_zero_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance");
    try expectContains(missing_array_literal_reassignment_raw_many_zero_field_body, "return ((uint32_t)mc_race_load_u32(holder.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(missing_array_literal_reassignment_raw_many_zero_field_body, "return *holder.ptrs.elems[mc_check_index_usize(0, 2)];");

    var missing_array_literal_reassignment_noalias_field_output: std.ArrayList(u8) = .empty;
    defer missing_array_literal_reassignment_noalias_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_array_element_missing_literal_reassignment_noalias_field_provenance.mc", array_source, "c_aggregate_array_element_literal_reassignment_noalias_direct_deref_requires_mir_field_fact", "holder", "ptrs", &missing_array_literal_reassignment_noalias_field_output);
    const missing_array_literal_reassignment_noalias_field_body = try cFunctionBody(missing_array_literal_reassignment_noalias_field_output.items, "static uint32_t c_aggregate_array_element_literal_reassignment_noalias_direct_deref_requires_mir_field_fact(void)");
    try expectNotContains(missing_array_literal_reassignment_noalias_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_literal_reassignment_noalias_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance");
    try expectContains(missing_array_literal_reassignment_noalias_field_body, "return ((uint32_t)mc_race_load_u32(holder.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(missing_array_literal_reassignment_noalias_field_body, "return *holder.ptrs.elems[mc_check_index_usize(0, 2)];");

    var missing_array_local_pointer_copy_literal_reassignment_field_output: std.ArrayList(u8) = .empty;
    defer missing_array_local_pointer_copy_literal_reassignment_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_array_element_missing_local_pointer_copy_literal_reassignment_field_provenance.mc", array_source, "c_aggregate_array_element_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact", "holder", "ptrs", &missing_array_local_pointer_copy_literal_reassignment_field_output);
    const missing_array_local_pointer_copy_literal_reassignment_field_body = try cFunctionBody(missing_array_local_pointer_copy_literal_reassignment_field_output.items, "static uint32_t c_aggregate_array_element_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact(void)");
    try expectContains(missing_array_local_pointer_copy_literal_reassignment_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none source=");
    try expectNotContains(missing_array_local_pointer_copy_literal_reassignment_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance");
    try expectContains(missing_array_local_pointer_copy_literal_reassignment_field_body, "return ((uint32_t)mc_race_load_u32(holder.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(missing_array_local_pointer_copy_literal_reassignment_field_body, "return *holder.ptrs.elems[mc_check_index_usize(0, 2)];");

    var missing_nested_array_local_pointer_copy_literal_reassignment_field_output: std.ArrayList(u8) = .empty;
    defer missing_nested_array_local_pointer_copy_literal_reassignment_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_nested_aggregate_array_element_missing_local_pointer_copy_literal_reassignment_field_provenance.mc", array_source, "c_nested_aggregate_array_element_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact", "outer", "inner.ptrs", &missing_nested_array_local_pointer_copy_literal_reassignment_field_output);
    const missing_nested_array_local_pointer_copy_literal_reassignment_field_body = try cFunctionBody(missing_nested_array_local_pointer_copy_literal_reassignment_field_output.items, "static uint32_t c_nested_aggregate_array_element_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact(void)");
    try expectContains(missing_nested_array_local_pointer_copy_literal_reassignment_field_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_array_element_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none source=");
    try expectNotContains(missing_nested_array_local_pointer_copy_literal_reassignment_field_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_array_element_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact subject=outer field=inner.ptrs element=0 provenance");
    try expectContains(missing_nested_array_local_pointer_copy_literal_reassignment_field_body, "return ((uint32_t)mc_race_load_u32(outer.inner.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(missing_nested_array_local_pointer_copy_literal_reassignment_field_body, "return *outer.inner.ptrs.elems[mc_check_index_usize(0, 2)];");

    var missing_array_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_array_copy_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_aggregate_array_element_missing_copy_field_provenance.mc", array_source, "c_aggregate_array_element_local_copy_direct_deref_requires_mir_field_fact", "copied", "ptrs", &missing_array_copy_field_output);
    const missing_array_copy_field_body = try cFunctionBody(missing_array_copy_field_output.items, "static uint32_t c_aggregate_array_element_local_copy_direct_deref_requires_mir_field_fact(void)");
    try expectNotContains(missing_array_copy_field_body, "/* mir pointer_provenance consumed fn=c_aggregate_array_element_local_copy_direct_deref_requires_mir_field_fact subject=copied field=ptrs element=0 provenance");
    try expectContains(missing_array_copy_field_body, "return ((uint32_t)mc_race_load_u32(copied.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(missing_array_copy_field_body, "return *copied.ptrs.elems[mc_check_index_usize(0, 2)];");

    var missing_nested_array_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_nested_array_copy_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_nested_aggregate_array_element_missing_copy_field_provenance.mc", array_source, "c_nested_aggregate_array_element_copy_direct_deref_requires_mir_field_fact", "copied", "inner.ptrs", &missing_nested_array_copy_field_output);
    const missing_nested_array_copy_field_body = try cFunctionBody(missing_nested_array_copy_field_output.items, "static uint32_t c_nested_aggregate_array_element_copy_direct_deref_requires_mir_field_fact(void)");
    try expectNotContains(missing_nested_array_copy_field_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_array_element_copy_direct_deref_requires_mir_field_fact subject=copied field=inner.ptrs element=0 provenance");
    try expectContains(missing_nested_array_copy_field_body, "return ((uint32_t)mc_race_load_u32(copied.inner.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(missing_nested_array_copy_field_body, "return *copied.inner.ptrs.elems[mc_check_index_usize(0, 2)];");

    var missing_nested_array_assignment_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_nested_array_assignment_copy_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_nested_aggregate_array_element_missing_assignment_copy_field_provenance.mc", array_source, "c_nested_aggregate_array_element_assignment_copy_direct_deref_requires_mir_field_fact", "assigned", "inner.ptrs", &missing_nested_array_assignment_copy_field_output);
    const missing_nested_array_assignment_copy_field_body = try cFunctionBody(missing_nested_array_assignment_copy_field_output.items, "static uint32_t c_nested_aggregate_array_element_assignment_copy_direct_deref_requires_mir_field_fact(void)");
    try expectNotContains(missing_nested_array_assignment_copy_field_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_array_element_assignment_copy_direct_deref_requires_mir_field_fact subject=assigned field=inner.ptrs element=0 provenance");
    try expectContains(missing_nested_array_assignment_copy_field_body, "return ((uint32_t)mc_race_load_u32(assigned.inner.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(missing_nested_array_assignment_copy_field_body, "return *assigned.inner.ptrs.elems[mc_check_index_usize(0, 2)];");

    var missing_nested_array_noalias_member_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_nested_array_noalias_member_copy_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_nested_aggregate_array_element_missing_noalias_member_copy_field_provenance.mc", array_source, "c_nested_aggregate_array_element_noalias_member_copy_direct_deref_requires_mir_field_fact", "dst", "inner.ptrs", &missing_nested_array_noalias_member_copy_field_output);
    const missing_nested_array_noalias_member_copy_field_body = try cFunctionBody(missing_nested_array_noalias_member_copy_field_output.items, "static uint32_t c_nested_aggregate_array_element_noalias_member_copy_direct_deref_requires_mir_field_fact(void)");
    try expectNotContains(missing_nested_array_noalias_member_copy_field_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_array_element_noalias_member_copy_direct_deref_requires_mir_field_fact subject=dst field=inner.ptrs element=0 provenance");
    try expectContains(missing_nested_array_noalias_member_copy_field_body, "return ((uint32_t)mc_race_load_u32(dst.inner.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(missing_nested_array_noalias_member_copy_field_body, "return *dst.inner.ptrs.elems[mc_check_index_usize(0, 2)];");

    var missing_nested_array_casted_noalias_member_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_nested_array_casted_noalias_member_copy_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField("emit_c_nested_aggregate_array_element_missing_casted_noalias_member_copy_field_provenance.mc", array_source, "c_nested_aggregate_array_element_casted_noalias_member_copy_direct_deref_requires_mir_field_fact", "dst", "inner.ptrs", &missing_nested_array_casted_noalias_member_copy_field_output);
    const missing_nested_array_casted_noalias_member_copy_field_body = try cFunctionBody(missing_nested_array_casted_noalias_member_copy_field_output.items, "static uint32_t c_nested_aggregate_array_element_casted_noalias_member_copy_direct_deref_requires_mir_field_fact(void)");
    try expectNotContains(missing_nested_array_casted_noalias_member_copy_field_body, "/* mir pointer_provenance consumed fn=c_nested_aggregate_array_element_casted_noalias_member_copy_direct_deref_requires_mir_field_fact subject=dst field=inner.ptrs element=0 provenance");
    try expectContains(missing_nested_array_casted_noalias_member_copy_field_body, "return ((uint32_t)mc_race_load_u32(dst.inner.ptrs.elems[mc_check_index_usize(0, 2)]));");
    try expectNotContains(missing_nested_array_casted_noalias_member_copy_field_body, "return *dst.inner.ptrs.elems[mc_check_index_usize(0, 2)];");
}

test "lower-c local aggregate pointer aliases require MIR destination facts" {
    const source =
        \\struct Holder { ptr: *mut u32, ptrs: [2]*mut u32 }
        \\
        \\fn c_local_alias_field_requires_mir_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var holder: Holder = .{ .ptr = &local, .ptrs = .{ &local, &local } };
        \\    let hp: *mut Holder = &holder;
        \\    let p: *mut u32 = hp.ptr;
        \\    return p.*;
        \\}
        \\
        \\fn c_local_alias_element_requires_mir_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var holder: Holder = .{ .ptr = &local, .ptrs = .{ &local, &local } };
        \\    let hp: *mut Holder = &holder;
        \\    let q: *mut u32 = hp.ptrs[0];
        \\    return q.*;
        \\}
    ;

    var normal_output: std.ArrayList(u8) = .empty;
    defer normal_output.deinit(std.testing.allocator);
    try appendCheckedCTest("emit_c_local_aggregate_pointer_alias_provenance.mc", source, &normal_output);

    const normal_field = try cFunctionBody(normal_output.items, "static uint32_t c_local_alias_field_requires_mir_fact(void)");
    try expectContains(normal_field, "/* mir pointer_provenance consumed fn=c_local_alias_field_requires_mir_fact subject=p provenance=local_storage reason=none source=");
    try expectContains(normal_field, "return *p;");
    try expectNotContains(normal_field, "mc_race_load_u32(p)");

    const normal_element = try cFunctionBody(normal_output.items, "static uint32_t c_local_alias_element_requires_mir_fact(void)");
    try expectContains(normal_element, "/* mir pointer_provenance consumed fn=c_local_alias_element_requires_mir_fact subject=q provenance=local_storage reason=none source=");
    try expectContains(normal_element, "return *q;");
    try expectNotContains(normal_element, "mc_race_load_u32(q)");

    var missing_field_output: std.ArrayList(u8) = .empty;
    defer missing_field_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_local_aggregate_pointer_alias_missing_field_fact.mc", source, "c_local_alias_field_requires_mir_fact", "p", &missing_field_output);
    const missing_field = try cFunctionBody(missing_field_output.items, "static uint32_t c_local_alias_field_requires_mir_fact(void)");
    try expectNotContains(missing_field, "/* mir pointer_provenance consumed fn=c_local_alias_field_requires_mir_fact subject=p");
    try expectContains(missing_field, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(missing_field, "return *p;");

    var missing_element_output: std.ArrayList(u8) = .empty;
    defer missing_element_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_local_aggregate_pointer_alias_missing_element_fact.mc", source, "c_local_alias_element_requires_mir_fact", "q", &missing_element_output);
    const missing_element = try cFunctionBody(missing_element_output.items, "static uint32_t c_local_alias_element_requires_mir_fact(void)");
    try expectNotContains(missing_element, "/* mir pointer_provenance consumed fn=c_local_alias_element_requires_mir_fact subject=q");
    try expectContains(missing_element, "return ((uint32_t)mc_race_load_u32(q));");
    try expectNotContains(missing_element, "return *q;");
}

test "lower-c local pointer-array aliases require MIR destination facts" {
    const source =
        \\fn c_local_pointer_array_alias_requires_mir_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var ptrs: [2]*mut u32 = .{ &local, &local };
        \\    let pa: *mut [2]*mut u32 = &ptrs;
        \\    let p: *mut u32 = pa.*[0];
        \\    return p.*;
        \\}
    ;

    var normal_output: std.ArrayList(u8) = .empty;
    defer normal_output.deinit(std.testing.allocator);
    try appendCheckedCTest("emit_c_local_pointer_array_alias_provenance.mc", source, &normal_output);
    const normal_body = try cFunctionBody(normal_output.items, "static uint32_t c_local_pointer_array_alias_requires_mir_fact(void)");
    try expectContains(normal_body, "/* mir pointer_provenance consumed fn=c_local_pointer_array_alias_requires_mir_fact subject=p provenance=local_storage reason=none source=");
    try expectContains(normal_body, "return *p;");
    try expectNotContains(normal_body, "mc_race_load_u32(p)");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_local_pointer_array_alias_missing_provenance.mc", source, "c_local_pointer_array_alias_requires_mir_fact", "p", &missing_output);
    const missing_body = try cFunctionBody(missing_output.items, "static uint32_t c_local_pointer_array_alias_requires_mir_fact(void)");
    try expectNotContains(missing_body, "/* mir pointer_provenance consumed fn=c_local_pointer_array_alias_requires_mir_fact subject=p provenance");
    try expectContains(missing_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(missing_body, "return *p;");
}

test "lower-c dynamic local pointer-array aliases require MIR destination facts" {
    const source =
        \\fn c_dynamic_local_pointer_array_alias_requires_mir_fact(index: usize) -> u32 {
        \\    var local: u32 = 0;
        \\    var ptrs: [2]*mut u32 = .{ &local, &local };
        \\    let pa: *mut [2]*mut u32 = &ptrs;
        \\    let p: *mut u32 = pa.*[index];
        \\    return p.*;
        \\}
    ;

    var normal_output: std.ArrayList(u8) = .empty;
    defer normal_output.deinit(std.testing.allocator);
    try appendCheckedCTest("emit_c_dynamic_local_pointer_array_alias_provenance.mc", source, &normal_output);
    const normal_body = try cFunctionBody(normal_output.items, "static uint32_t c_dynamic_local_pointer_array_alias_requires_mir_fact(uintptr_t index)");
    try expectContains(normal_body, "/* mir pointer_provenance consumed fn=c_dynamic_local_pointer_array_alias_requires_mir_fact subject=p provenance=local_storage reason=none source=");
    try expectContains(normal_body, "return *p;");
    try expectNotContains(normal_body, "mc_race_load_u32(p)");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_dynamic_local_pointer_array_alias_missing_provenance.mc", source, "c_dynamic_local_pointer_array_alias_requires_mir_fact", "p", &missing_output);
    const missing_body = try cFunctionBody(missing_output.items, "static uint32_t c_dynamic_local_pointer_array_alias_requires_mir_fact(uintptr_t index)");
    try expectNotContains(missing_body, "/* mir pointer_provenance consumed fn=c_dynamic_local_pointer_array_alias_requires_mir_fact subject=p provenance");
    try expectContains(missing_body, "return ((uint32_t)mc_race_load_u32(p));");
    try expectNotContains(missing_body, "return *p;");
}

test "lower-c emits while loops and loop control" {
    const source =
        \\fn loop_once(flag: bool) -> u32 {
        \\    var out: u32 = 0;
        \\    while flag {
        \\        {
        \\            out = out + 1;
        \\        }
        \\        break;
        \\    }
        \\    while flag {
        \\        continue;
        \\    }
        \\    return out;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_loops.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "while (flag) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "out = mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "goto mc_break_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "goto mc_continue_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return out;") != null);
}

test "lower-c hoists MMIO reads in while conditions" {
    const source =
        \\packed bits Status: u8 {
        \\    ready: bool,
        \\}
        \\
        \\extern mmio struct Device {
        \\    ctrl: Reg<u16, .write>,
        \\    stat: RegBits<u8, Status, .read>,
        \\    raw: Reg<u16, .read>,
        \\}
        \\
        \\extern fn pause() -> void;
        \\
        \\fn poll_and_write(dev: MmioPtr<Device>, value: u16) -> void {
        \\    while !dev.stat.read(.acquire).ready {
        \\        pause();
        \\    }
        \\    dev.ctrl.write(value, .release);
        \\}
        \\
        \\fn wait_raw(dev: MmioPtr<Device>) -> void {
        \\    while dev.raw.read(.relaxed) == 0 {
        \\        pause();
        \\    }
        \\}
        \\
        \\fn require_ready(dev: MmioPtr<Device>) -> void {
        \\    assert(dev.stat.read(.acquire).ready);
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_mmio_read_while_condition.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "while (true) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Status mc_tmp0 = (Status)mc_mmio_read_u8(&dev->stat);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_acquire_after();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!(!(((mc_tmp0 & UINT8_C(1)) != 0)))) break;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "pause();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint16_t mc_tmp1 = value;\n    mc_barrier_release_before();\n    mc_mmio_write_u16(&dev->ctrl, mc_tmp1);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint16_t mc_tmp2 = (uint16_t)mc_mmio_read_u16(&dev->raw);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!((mc_tmp2 == 0))) break;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Status mc_tmp3 = (Status)mc_mmio_read_u8(&dev->stat);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!(((mc_tmp3 & UINT8_C(1)) != 0))) mc_trap_Assert();") != null);
}

test "lower-c hoists MMIO reads in return and expression statements" {
    const source =
        \\packed bits Status: u8 {
        \\    ready: bool,
        \\}
        \\
        \\extern mmio struct Device {
        \\    stat: RegBits<u8, Status, .read>,
        \\    raw: Reg<u32, .read>,
        \\}
        \\
        \\extern fn observe(status: Status) -> void;
        \\
        \\fn observe_status(dev: MmioPtr<Device>) -> void {
        \\    observe(dev.stat.read(.acquire));
        \\}
        \\
        \\fn read_plus(dev: MmioPtr<Device>, extra: u32) -> u32 {
        \\    return dev.raw.read(.relaxed) + extra;
        \\}
        \\
        \\fn read_side_effect(dev: MmioPtr<Device>) -> void {
        \\    dev.raw.read(.acquire);
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_mmio_read_exprs.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_read_u8(&dev->stat);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "observe(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_read_u32(&dev->raw);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_acquire_after();\n    (void)mc_tmp") != null);
}

test "lower-c hoists MMIO reads in local initializer and assignment expressions" {
    const source =
        \\extern mmio struct Device {
        \\    raw: Reg<u32, .read>,
        \\}
        \\
        \\fn local_nested(dev: MmioPtr<Device>, extra: u32) -> u32 {
        \\    let x: u32 = dev.raw.read(.relaxed) + extra;
        \\    return x;
        \\}
        \\
        \\fn assign_nested(dev: MmioPtr<Device>, extra: u32) -> u32 {
        \\    var x: u32 = 0;
        \\    x = dev.raw.read(.acquire) + extra;
        \\    return x;
        \\}
        \\
        \\fn local_untyped_nested(dev: MmioPtr<Device>, extra: u32) -> u32 {
        \\    let x = dev.raw.read(.relaxed) + extra;
        \\    return x;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_mmio_read_nested_init_assignment.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_read_u32(&dev->raw);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t x = mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "x = mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_acquire_after();") != null);
}

test "lower-c hoists MMIO reads in switch subjects" {
    const source =
        \\extern mmio struct Device {
        \\    raw: Reg<u32, .read>,
        \\}
        \\
        \\fn switch_relaxed(dev: MmioPtr<Device>) -> u32 {
        \\    switch dev.raw.read(.relaxed) {
        \\        0 => { return 1; },
        \\        _ => { return 2; },
        \\    }
        \\}
        \\
        \\fn switch_acquire(dev: MmioPtr<Device>) -> u32 {
        \\    switch dev.raw.read(.acquire) {
        \\        0 => { return 1; },
        \\        _ => { return 2; },
        \\    }
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_mmio_read_switch_subject.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp0 = (uint32_t)mc_mmio_read_u32(&dev->raw);\n    switch (mc_tmp0) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp1 = (uint32_t)mc_mmio_read_u32(&dev->raw);\n    mc_barrier_acquire_after();\n    switch (mc_tmp1) {") != null);
}

test "lower-c hoists MMIO reads in switch arm expressions" {
    const source =
        \\extern mmio struct Device {
        \\    raw: Reg<u32, .read>,
        \\}
        \\
        \\fn switch_arm_expr(dev: MmioPtr<Device>, n: u32) -> void {
        \\    switch n {
        \\        0 => dev.raw.read(.acquire),
        \\        _ => dev.raw.read(.relaxed),
        \\    }
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_mmio_read_switch_arm_expr.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp0 = (uint32_t)mc_mmio_read_u32(&dev->raw);\n            mc_barrier_acquire_after();\n            (void)mc_tmp0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp1 = (uint32_t)mc_mmio_read_u32(&dev->raw);\n            (void)mc_tmp1;") != null);
}

test "lower-c emits array and slice for loops" {
    const source =
        \\extern fn make_slice() -> []const u32;
        \\extern fn make_array() -> [4]u32;
        \\
        \\fn sum_slice(xs: []const u32) -> u32 {
        \\    var sum: u32 = 0;
        \\    for x in xs {
        \\        sum = sum + x;
        \\    }
        \\    return sum;
        \\}
        \\
        \\fn sum_array(xs: [4]u32) -> u32 {
        \\    var sum: u32 = 0;
        \\    for x in xs {
        \\        sum = sum + x;
        \\    }
        \\    return sum;
        \\}
        \\
        \\fn sum_call_slice() -> u32 {
        \\    var sum: u32 = 0;
        \\    for x in make_slice() {
        \\        sum = sum + x;
        \\    }
        \\    return sum;
        \\}
        \\
        \\fn first_call_array() -> u32 {
        \\    for x in make_array() {
        \\        return x;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn sum_inferred_slice() -> u32 {
        \\    let xs = make_slice();
        \\    var sum: u32 = 0;
        \\    for x in xs {
        \\        sum = sum + x;
        \\    }
        \\    return sum;
        \\}
        \\
        \\fn sum_inferred_array() -> u32 {
        \\    let xs = make_array();
        \\    var sum: u32 = 0;
        \\    for x in xs {
        \\        sum = sum + x;
        \\    }
        \\    return sum;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_for_loops.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t sum_slice(mc_slice_const_u32 xs)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "for (uintptr_t mc_i0 = 0; mc_i0 < xs.len; mc_i0 += 1) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t x = xs.ptr[mc_i0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct mc_array_u32_4 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t sum_array(mc_array_u32_4 xs)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " < 4; mc_i") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t x = xs.elems[mc_i") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_slice_const_u32 mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".len; mc_i") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".ptr[mc_i") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_array_u32_4 mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_array_u32_4 xs = make_array();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "sum = mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return sum;") != null);
}

test "lower-c emits fixed array indexing with bounds checks" {
    const source =
        \\fn pick_u8(xs: [4]u8, i: usize) -> u8 {
        \\    return xs[i];
        \\}
        \\
        \\fn pick_u32(xs: [4]u32, i: usize) -> u32 {
        \\    return xs[i];
        \\}
        \\
        \\#[no_lang_trap]
        \\fn pick_const(xs: [4]u8) -> u8 {
        \\    return xs.const_get<2>();
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_arrays.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_array_u8_4 xs") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_array_u32_4 xs") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return xs.elems[mc_check_index_usize(i, 4)];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return xs.elems[2];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_check_index_usize(2, 4)") == null);
}

test "lower-c emits slice typedefs and indexing" {
    const source =
        \\extern fn make_u8_slice() -> []const u8;
        \\extern fn make_u32_slice() -> []const u32;
        \\
        \\fn read_slice(xs: []const u8, i: usize) -> u8 {
        \\    return xs[i];
        \\}
        \\
        \\fn read_literal(xs: []const u8) -> u8 {
        \\    return xs[0];
        \\}
        \\
        \\fn write_slice(xs: []mut u32, i: usize, value: u32) -> void {
        \\    xs[i] = value;
        \\}
        \\
        \\fn same_slice(xs: []const u8) -> []const u8 {
        \\    return xs;
        \\}
        \\
        \\fn read_direct_literal() -> u8 {
        \\    return make_u8_slice()[0];
        \\}
        \\
        \\fn read_direct_index(i: usize) -> u32 {
        \\    return make_u32_slice()[i];
        \\}
        \\
        \\fn read_inferred_slice(i: usize) -> u32 {
        \\    let xs = make_u32_slice();
        \\    return xs[i];
        \\}
        \\
        \\fn local_direct_literal() -> u8 {
        \\    let x: u8 = make_u8_slice()[0];
        \\    return x;
        \\}
        \\
        \\fn local_direct_index(i: usize) -> u32 {
        \\    let x: u32 = make_u32_slice()[i];
        \\    return x;
        \\}
        \\
        \\fn const_slice_from_array_range(n: usize) -> u8 {
        \\    var buf: [4]u8 = uninit;
        \\    buf[0] = 7;
        \\    let xs: []const u8 = buf[0..n];
        \\    return xs[0];
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_slices.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct mc_slice_const_u8 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t const * ptr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct mc_slice_mut_u8 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * ptr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct mc_slice_const_u32 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t const * ptr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct mc_slice_mut_u32 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t * ptr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uintptr_t len;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_slice_const_u8 make_u8_slice(void);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_slice_const_u32 make_u32_slice(void);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint8_t read_slice(mc_slice_const_u8 xs, uintptr_t i)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((uint8_t)mc_race_load_u8(&(xs.ptr[mc_check_index_usize(i, xs.len)])));") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((uint8_t)mc_race_load_u8(&(xs.ptr[mc_check_index_usize(0, xs.len)])));") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void write_slice(mc_slice_mut_u32 xs, uintptr_t i, uint32_t value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_race_store_u32(&(xs.ptr[mc_check_index_usize(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static mc_slice_const_u8 same_slice(mc_slice_const_u8 xs)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " = make_u8_slice();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " = (uint8_t)mc_race_load_u8(&mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".ptr[mc_check_index_usize(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " = make_u32_slice();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " = (uint32_t)mc_race_load_u32(&mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_slice_const_u32 xs = make_u32_slice();\n    return ((uint32_t)mc_race_load_u32(&(xs.ptr[mc_check_index_usize(i, xs.len)])));") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t x = mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t x = mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_slice_const_u8 xs = ({ mc_slice_mut_u8 mc_scv") != null);
}

test "lower-c emits checked u32 arithmetic helpers" {
    const source =
        \\fn checked_ops(a: u32, b: u32, n: u32) -> u32 {
        \\    var out: u32 = a - b;
        \\    out = out * b;
        \\    out = out / b;
        \\    out = out % b;
        \\    out = out << n;
        \\    return out >> n;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_checked_ops.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_sub_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_mul_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_div_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_mod_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_shl_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_shr_u32(") != null);
}

test "lower-c emits integer switch arms" {
    const source =
        \\fn classify(n: u32) -> u32 {
        \\    switch n {
        \\        0 => {
        \\            let x: u32 = 10;
        \\            return x;
        \\        },
        \\        1, 2 => { return 20; },
        \\        _ => { return 30; },
        \\    }
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_switch.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "switch (n) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "case 0:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "case 1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "case 2:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "default:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t x = 10;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return 30;") != null);
}

test "lower-c emits closed enum switch arms" {
    const source =
        \\enum Irq: u8 {
        \\    timer = 32,
        \\    keyboard = 33,
        \\}
        \\
        \\fn classify_irq(irq: Irq) -> u32 {
        \\    switch irq {
        \\        .timer => { return 1; },
        \\        .keyboard => { return 2; },
        \\    }
        \\}
        \\
        \\extern fn read_irq() -> Irq;
        \\
        \\fn classify_read_irq() -> u32 {
        \\    switch read_irq() {
        \\        .timer => { return 1; },
        \\        .keyboard => { return 2; },
        \\    }
        \\}
        \\
        \\fn classify_local_irq() -> u32 {
        \\    let irq = read_irq();
        \\    switch irq {
        \\        .timer => { return 1; },
        \\        .keyboard => { return 2; },
        \\    }
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_enum_switch.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef uint8_t Irq;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Irq_timer = 32") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Irq_keyboard = 33") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t classify_irq(Irq irq)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "switch (irq) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "case Irq_timer:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "case Irq_keyboard:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t classify_read_irq(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Irq mc_tmp0 = read_irq();\n    switch (mc_tmp0) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t classify_local_irq(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Irq irq = read_irq();\n    switch (irq) {") != null);
}

test "lower-c casts indexed bool switch subjects and marks ignored locals unused" {
    const source =
        \\extern fn tick() -> u64;
        \\extern fn tick2(a: u64, b: u64) -> u64;
        \\
        \\fn ignore_call() -> void {
        \\    let _ignore: u64 = tick();
        \\    let _seq_ignore: u64 = tick2(1, 2);
        \\}
        \\
        \\fn classify(flags: [2]bool, i: usize) -> u32 {
        \\    switch flags[i] {
        \\        true => { return 1; },
        \\        false => { return 0; },
        \\    }
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_bool_switch_unused.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED uint64_t _ignore = tick();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED uint64_t _seq_ignore = tick2(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "switch ((int)(flags.elems[mc_check_index_usize(i, 2)])) {") != null);
}

test "lower-c emits target-typed enum literals" {
    const source =
        \\enum Mode: u8 {
        \\    read = 1,
        \\    write = 2,
        \\}
        \\
        \\extern fn sink(mode: Mode) -> u32;
        \\global global_mode: Mode = .read;
        \\
        \\fn default_mode() -> Mode {
        \\    return .read;
        \\}
        \\
        \\fn local_mode() -> Mode {
        \\    let mode: Mode = .write;
        \\    return mode;
        \\}
        \\
        \\fn pass_mode() -> u32 {
        \\    return sink(.read);
        \\}
        \\fn is_read(mode: Mode) -> bool { return mode == .read; }
        \\fn cast_mode() -> Mode { return .write as Mode; }
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_enum_literals.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef uint8_t Mode;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Mode_read = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Mode_write = 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t sink(Mode mode);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "global_mode = Mode_read") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return Mode_read;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Mode mode = Mode_write;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Mode mc_tmp0 = Mode_read;\n    return sink(mc_tmp0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mode == Mode_read") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((Mode)Mode_write);") != null);
}

test "lower-c emits optional pointer if-let" {
    const source =
        \\extern fn maybe_ptr() -> ?*mut u8;
        \\extern fn ptr_value(p: *mut u8) -> u32;
        \\
        \\fn unwrap_or(maybe: ?*mut u8, fallback: *mut u8) -> *mut u8 {
        \\    if let p = maybe {
        \\        return p;
        \\    } else {
        \\        return fallback;
        \\    }
        \\}
        \\
        \\fn read_const(maybe: ?*const u8) -> u8 {
        \\    if let p = maybe {
        \\        return p.*;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        \\
        \\fn unwrap_call_or_zero() -> u32 {
        \\    if let p = maybe_ptr() {
        \\        return ptr_value(p);
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn unwrap_local_or_zero() -> u32 {
        \\    let maybe = maybe_ptr();
        \\    if let p = maybe {
        \\        return ptr_value(p);
        \\    }
        \\    return 0;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_if_let.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint8_t * unwrap_or(uint8_t * maybe, uint8_t * fallback)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (maybe != NULL) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * p = maybe;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint8_t read_const(uint8_t const * maybe)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t const * p = maybe;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return *p;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return fallback;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * mc_tmp0 = maybe_ptr();\n    if (mc_tmp0 != NULL) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * p = mc_tmp0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t unwrap_local_or_zero(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * maybe = maybe_ptr();\n    if (maybe != NULL) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * p = maybe;") != null);
}

test "lower-c emits nullable switch binding" {
    const source =
        \\extern fn maybe_ptr() -> ?*mut u8;
        \\extern fn ptr_value(p: *mut u8) -> u32;
        \\
        \\fn nullable_switch(maybe: ?*mut u8) -> u32 {
        \\    switch maybe {
        \\        p => { return ptr_value(p); },
        \\        _ => { return 0; },
        \\    }
        \\}
        \\
        \\fn nullable_call_switch() -> u32 {
        \\    switch maybe_ptr() {
        \\        p => { return ptr_value(p); },
        \\        _ => { return 0; },
        \\    }
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_nullable_switch.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t nullable_switch(uint8_t * maybe)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (maybe != NULL) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * p = maybe;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * mc_tmp0 = p;\n        return ptr_value(mc_tmp0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "else {\n        return 0;\n    }") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * mc_tmp1 = maybe_ptr();\n    if (mc_tmp1 != NULL) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * p = mc_tmp1;") != null);
}

test "lower-c emits Result if-let narrowing" {
    const source =
        \\enum Error: u8 {
        \\    denied = 1,
        \\}
        \\
        \\extern fn make_result() -> Result<u32, Error>;
        \\
        \\fn unwrap_or_zero(result: Result<u32, Error>) -> u32 {
        \\    if let ok(v) = result {
        \\        return v;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        \\
        \\fn has_err(result: Result<u32, Error>) -> bool {
        \\    if let err(e) = result {
        \\        return e != 0;
        \\    }
        \\    return false;
        \\}
        \\
        \\fn unwrap_call_or_zero() -> u32 {
        \\    if let ok(v) = make_result() {
        \\        return v;
        \\    }
        \\    return 0;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_result_if_let.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t unwrap_or_zero(mc_result_u32_Error result)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (result.is_ok) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t v = result.payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return v;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "} else {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static bool has_err(mc_result_u32_Error result)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!result.is_ok) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Error e = result.payload.err;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return (e != 0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp0 = make_result();\n    if (mc_tmp0.is_ok) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t v = mc_tmp0.payload.ok;") != null);
}

test "lower-c emits Result switch narrowing" {
    const source =
        \\enum Error: u8 {
        \\    denied = 1,
        \\}
        \\
        \\fn result_nonzero(result: Result<u32, Error>) -> bool {
        \\    switch result {
        \\        ok(v) => { return v != 0; },
        \\        err(e) => { return e != 0; },
        \\    }
        \\}
        \\
        \\extern fn make_result() -> Result<u32, Error>;
        \\
        \\fn result_call_nonzero() -> bool {
        \\    switch make_result() {
        \\        ok(v) => { return v != 0; },
        \\        err(e) => { return e != 0; },
        \\    }
        \\}
        \\
        \\fn result_local_nonzero() -> bool {
        \\    let result = make_result();
        \\    switch result {
        \\        ok(v) => { return v != 0; },
        \\        err(e) => { return e != 0; },
        \\    }
        \\}
        \\
        \\fn result_payloadless_switch() -> u32 {
        \\    let result = make_result();
        \\    switch result {
        \\        .ok => { return 1; },
        \\        .err => { return 0; },
        \\    }
        \\}
        \\
        \\fn result_multi_payloadless_switch() -> u32 {
        \\    let result = make_result();
        \\    switch result {
        \\        .ok, .err => { return 1; },
        \\    }
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_result_switch.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct mc_result_u32_Error {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static bool result_nonzero(mc_result_u32_Error result)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (result.is_ok) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t v = result.payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return (v != 0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "else {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Error e = result.payload.err;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return (e != 0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp0 = make_result();\n    if (mc_tmp0.is_ok) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t v = mc_tmp0.payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Error e = mc_tmp0.payload.err;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static bool result_local_nonzero(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error result = make_result();\n    if (result.is_ok) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t v = result.payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t result_payloadless_switch(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error result = make_result();\n    if (result.is_ok) {\n        return 1;\n    }\n    else {\n        return 0;\n    }") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t result_multi_payloadless_switch(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error result = make_result();\n    if (result.is_ok || !result.is_ok) {\n        return 1;\n    }") != null);
}

test "lower-c checked conversion evaluates a side-effecting operand once" {
    const source =
        \\extern fn src() -> u64;
        \\fn narrow() -> u8 {
        \\    return u8.trap_from(src());
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_conv_once.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "= (src());") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.items, "src()"));
}

test "lower-c emits extern structs and member access" {
    const source =
        \\extern struct Packet {
        \\    value: u32,
        \\    ptr: *mut u8,
        \\    next: ?*mut Packet,
        \\}
        \\
        \\fn make_packet() -> Packet;
        \\extern fn make_ptr() -> *mut u8;
        \\
        \\fn id_packet_ptr(p: *mut Packet) -> *mut Packet {
        \\    return p;
        \\}
        \\
        \\fn maybe_packet(maybe: ?*mut Packet, fallback: *mut Packet) -> *mut Packet {
        \\    if let p = maybe {
        \\        return p;
        \\    } else {
        \\        return fallback;
        \\    }
        \\}
        \\
        \\fn cast_packet_ptr(raw: *mut u8) -> *mut Packet {
        \\    return raw as *mut Packet;
        \\}
        \\
        \\fn read_value(packet: Packet) -> u32 {
        \\    return packet.value;
        \\}
        \\
        \\fn write_value(packet: Packet, value: u32) -> void {
        \\    packet.value = value;
        \\}
        \\
        \\fn read_ptr(packet: Packet) -> *mut u8 {
        \\    return packet.ptr;
        \\}
        \\
        \\fn read_direct() -> u32 {
        \\    return make_packet().value;
        \\}
        \\
        \\fn inferred_pointer_return() -> *mut u8 {
        \\    let p = make_ptr();
        \\    return p;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_structs.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct Packet {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t value;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * ptr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "struct Packet * next;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Packet make_packet(void);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static Packet * id_packet_ptr(Packet * p)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static Packet * maybe_packet(Packet * maybe, Packet * fallback)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Packet * p = maybe;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static Packet * cast_packet_ptr(uint8_t * raw)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((Packet *)raw);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t read_value(Packet packet)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return packet.value;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "packet.value = value;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return packet.ptr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return make_packet().value;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * make_ptr(void);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint8_t * inferred_pointer_return(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " = make_ptr();\n    if (mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " == NULL) mc_trap_InvalidRepresentation();\n    uint8_t * p = mc_tmp") != null);
}

test "lower-c sanitizes C header names used as fields" {
    const source =
        \\extern struct Packet {
        \\    offsetof: u32,
        \\    uint32_t: u32,
        \\}
        \\
        \\fn sum(packet: Packet) -> u32 {
        \\    return packet.offsetof + packet.uint32_t;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_field_reserved_names.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t offsetof_;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t uint32_t_;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " = packet.offsetof_;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " = packet.uint32_t_;") != null);
}

test "lower-c emits overlay unions as byte storage" {
    const source =
        \\overlay union Word {
        \\    u: u32,
        \\    bytes: [4]u8,
        \\}
        \\
        \\fn pass_word(word: Word) -> Word { return word; }
        \\fn read_u(word: Word) -> u32 { return word.u; }
        \\fn read_b0(word: Word) -> u8 { return word.bytes[0]; }
        \\fn write_u(word: Word, value: u32) -> Word {
        \\    word.u = value;
        \\    return word;
        \\}
        \\fn write_b0(word: Word, value: u8) -> Word {
        \\    word.bytes[0] = value;
        \\    return word;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_overlay_union.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct Word {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "alignas(4) unsigned char storage[4];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "} Word;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static Word pass_word(Word word)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return word;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t read_u(Word word)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "memcpy(&mc_tmp0, word.storage, 4);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_tmp0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return word.storage[mc_check_index_usize(0, 4)];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "memcpy(word.storage, &mc_tmp1, 4);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "word.storage[mc_check_index_usize(0, 4)] = value;") != null);
}

test "lower-c emits assert trap" {
    const source =
        \\fn require_flag(flag: bool) -> void { assert(flag); }
        \\fn require_expr(a: u32, b: u32) -> void { assert(a == b || a != 0); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_assert.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!(flag)) mc_trap_Assert();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!(((a == b) || (a != 0)))) mc_trap_Assert();") != null);
}

test "lower-c emits lexical defer cleanup before return" {
    const source =
        \\extern fn close_a() -> void;
        \\extern fn close_b() -> void;
        \\fn accept_lexical_cleanup() -> void {
        \\    defer close_a();
        \\    defer close_b();
        \\    return;
        \\}
        \\fn accept_block_cleanup() -> void {
        \\    defer { close_a(); };
        \\    return;
        \\}
        \\fn accept_cleanup_before_break(flag: bool) -> void {
        \\    while flag { defer close_a(); break; }
        \\}
        \\fn accept_cleanup_before_continue(flag: bool) -> void {
        \\    while flag { defer close_a(); continue; }
        \\}
        \\fn accept_cleanup_on_fallthrough() -> void { defer close_a(); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_defer.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "void close_a(void);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "void close_b(void);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void accept_lexical_cleanup(void) {\n    close_b();\n    close_a();\n    return;\n}") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void accept_block_cleanup(void) {\n    {\n        close_a();\n    }\n    return;\n}") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void accept_cleanup_before_break(bool flag) {\n    while (flag) {\n        close_a();\n        goto mc_break_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void accept_cleanup_before_continue(bool flag) {\n    while (flag) {\n        close_a();\n        goto mc_continue_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void accept_cleanup_on_fallthrough(void) {\n    close_a();\n}") != null);
}

test "lower-c emits unsafe blocks as scoped blocks" {
    const source =
        \\fn accept_unsafe_block() -> u32 {
        \\    var x: u32 = 1;
        \\    unsafe { x = x + 1; }
        \\    return x;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_unsafe_block.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t accept_unsafe_block(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t x = 1;\n    {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "x = mc_tmp") != null);
}

test "lower-c emits opaque volatile asm" {
    const source =
        \\fn asm_in_unsafe() -> void {
        \\    unsafe {
        \\        asm opaque volatile { "pause" clobber("memory") }
        \\    }
        \\}
        \\fn boot_asm() -> void {
        \\    unsafe { asm opaque volatile { "cli" "hlt" } }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_asm.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void asm_in_unsafe(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "__asm__ __volatile__(\"pause\" ::: \"memory\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "__asm__ __volatile__(\"cli\" \"\\n\\t\" \"hlt\" ::: \"memory\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "#error \"inline asm emission requires compiler support\"") != null);
}

test "lower-c emits precise asm with operands" {
    const source =
        \\fn find_first_set(mask: u64) -> u64 {
        \\    var idx: u64 = 0;
        \\    #[unsafe_contract(precise_asm)]
        \\    {
        \\        unsafe {
        \\            asm precise volatile {
        \\                "bsf %1, %0"
        \\                out("rax") idx: u64,
        \\                in("rbx") mask: u64,
        \\                clobber("cc")
        \\            }
        \\        }
        \\    }
        \\    return idx;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_precise_asm.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "__asm__ __volatile__(\"bsf %1, %0\" : \"=r\"(idx) : \"r\"(mask) : \"cc\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_PRECISE_ASM out(\"rax\")->idx in(\"rbx\") */") != null);
}

test "lower-c emits reduce.sum_checked" {
    const source =
        \\fn sum(xs: []const u32) -> Result<u32, Overflow> {
        \\    return reduce.sum_checked<u32>(xs);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_reduce.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "__int128 mc_acc") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "> (__int128)(UINT32_MAX)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "(mc_result_u32_Overflow){ .is_ok = true, .payload.ok = (uint32_t)mc_acc") != null);
}

test "lower-c emits distinct floating reduction modes" {
    const source =
        \\fn sum_left(xs: []const f64) -> f64 {
        \\    return reduce.sum_left<f64>(xs);
        \\}
        \\fn sum_fast(xs: []const f32) -> f32 {
        \\    return reduce.sum_fast<f32>(xs);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_float_reduce.mc", source, &output);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.items, "MC_SUM_FAST"));
    try std.testing.expect(std.mem.indexOf(u8, output.items, "#pragma clang fp reassociate(on)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "#pragma clang loop vectorize(enable) interleave(enable)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "double mc_acc") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "float mc_acc") != null);
}

test "lower-c omits pure comptime blocks from C runtime output" {
    const source =
        \\fn accept_pure_comptime_block() -> u32 {
        \\    comptime {
        \\        let x: u32 = 1;
        \\        assert(true);
        \\    }
        \\    return 1;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("emit_c_comptime_block.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t accept_pure_comptime_block(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t x = 1;") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Assert") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!(true))") == null);
}

test "lower-c emits explicit traps and unreachable" {
    const source =
        \\fn trap_as_value() -> u32 { return trap(.Bounds); }
        \\fn unreachable_as_value() -> u32 { return unreachable; }
        \\fn never_returns_by_trap() -> never { return trap(.Assert); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_traps.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t trap_as_value(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Bounds();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Unreachable();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void never_returns_by_trap(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Assert();") != null);
}

test "lower-c rejects non-static global initializers instead of zeroing" {
    const source =
        \\fn source() -> u32 { return 1; }
        \\global value: u32 = source();
    ;
    var parsed = try test_support.parseModule("emit_c_reject_global_init.mc", source);
    defer parsed.deinit();
    parsed.check();
    try std.testing.expect(hasTestDiagnosticCode(parsed.reporter, "E_GLOBAL_INITIALIZER_NOT_STATIC"));
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, lower_c.appendC(std.testing.allocator, parsed.module, &output));
}

test "lower-c rejects two MMIO reads in one short-circuit operand" {
    const source =
        \\extern mmio struct ProbeMmio {
        \\    magic: Reg<u32, .read>      @offset(0x000),
        \\    device_id: Reg<u32, .read>  @offset(0x008),
        \\}
        \\fn both(a: u32, b: u32) -> bool { return a == b; }
        \\fn probe(slot: MmioPtr<ProbeMmio>) -> bool {
        \\    return both(slot.magic.read(.acquire), slot.device_id.read(.acquire)) && true;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_reject_mmio_seq.mc", source);
}

test "lower-c keeps a single MMIO read per short-circuit operand" {
    const source =
        \\extern mmio struct ProbeMmio {
        \\    magic: Reg<u32, .read>      @offset(0x000),
        \\    device_id: Reg<u32, .read>  @offset(0x008),
        \\}
        \\fn probe(slot: MmioPtr<ProbeMmio>) -> bool {
        \\    return slot.magic.read(.acquire) == 1 && slot.device_id.read(.acquire) == 2;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("emit_c_single_mmio_seq.mc", source, &output);
    const magic_read = std.mem.indexOf(u8, output.items, "slot->magic") orelse return error.TestUnexpectedResult;
    const amp = std.mem.indexOfPos(u8, output.items, magic_read, "&&") orelse return error.TestUnexpectedResult;
    const devid_read = std.mem.indexOf(u8, output.items, "slot->device_id") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOfPos(u8, output.items, magic_read + 1, "slot->magic") == null);
    try std.testing.expect(std.mem.indexOfPos(u8, output.items, devid_read + 1, "slot->device_id") == null);
    try std.testing.expect(magic_read < amp);
    try std.testing.expect(amp < devid_read);
}

test "lower-c uses type-directed helpers for fixed-width checked arithmetic" {
    const source =
        \\fn add_i32(a: i32, b: i32) -> i32 { return a + b; }
        \\fn div_i32(a: i32, b: i32) -> i32 { return a / b; }
        \\fn mul_u64(a: u64, b: u64) -> u64 { return a * b; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_fixed_width_arith.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_CHECKED_SIGNED(i32, int32_t, INT32_MIN, INT32_MAX)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_i32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_div_i32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_mul_u64(") != null);
}

test "lower-c sequences return call arguments left to right" {
    const source =
        \\extern fn next_value() -> u32;
        \\extern fn box_value(value: u32) -> u32;
        \\extern fn combine(left: u32, right: u32) -> u32;
        \\extern fn consume(left: u32, right: u32) -> void;
        \\global ordered_global: u32 = 0;
        \\fn ordered_two_args() -> u32 { return combine(next_value(), next_value()); }
        \\fn ordered_local_init() -> u32 { let value = combine(next_value(), next_value()); return value; }
        \\fn ordered_typed_local_init() -> u32 { let value: u32 = combine(next_value(), next_value()); return value; }
        \\fn ordered_expr_stmt() -> void { consume(next_value(), next_value()); }
        \\fn ordered_nested_return() -> u32 { return combine(box_value(next_value()), next_value()); }
        \\fn ordered_nested_local_init() -> u32 { let value = combine(box_value(next_value()), next_value()); return value; }
        \\fn ordered_nested_expr_stmt() -> void { consume(box_value(next_value()), next_value()); }
        \\fn ordered_assignment() -> u32 { var value: u32 = 0; value = combine(next_value(), next_value()); return value; }
        \\fn ordered_nested_assignment() -> u32 { var value: u32 = 0; value = combine(box_value(next_value()), next_value()); return value; }
        \\fn ordered_global_assignment() -> void { ordered_global = combine(next_value(), next_value()); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_eval_order.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp0 = next_value();\n    uint32_t mc_tmp1 = next_value();\n    return combine(mc_tmp0, mc_tmp1);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp2 = next_value();\n    uint32_t mc_tmp3 = next_value();\n    uint32_t value = combine(mc_tmp2, mc_tmp3);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp4 = next_value();\n    uint32_t mc_tmp5 = next_value();\n    uint32_t value = combine(mc_tmp4, mc_tmp5);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp6 = next_value();\n    uint32_t mc_tmp7 = next_value();\n    consume(mc_tmp6, mc_tmp7);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp8 = next_value();\n    uint32_t mc_tmp9 = box_value(mc_tmp8);\n    uint32_t mc_tmp10 = next_value();\n    return combine(mc_tmp9, mc_tmp10);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp11 = next_value();\n    uint32_t mc_tmp12 = box_value(mc_tmp11);\n    uint32_t mc_tmp13 = next_value();\n    uint32_t value = combine(mc_tmp12, mc_tmp13);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp14 = next_value();\n    uint32_t mc_tmp15 = box_value(mc_tmp14);\n    uint32_t mc_tmp16 = next_value();\n    consume(mc_tmp15, mc_tmp16);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp17 = next_value();\n    uint32_t mc_tmp18 = next_value();\n    uint32_t mc_tmp19 = combine(mc_tmp17, mc_tmp18);\n    value = mc_tmp19;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp20 = next_value();\n    uint32_t mc_tmp21 = box_value(mc_tmp20);\n    uint32_t mc_tmp22 = next_value();\n    uint32_t mc_tmp23 = combine(mc_tmp21, mc_tmp22);\n    value = mc_tmp23;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp24 = next_value();\n    uint32_t mc_tmp25 = next_value();\n    uint32_t mc_tmp26 = combine(mc_tmp24, mc_tmp25);\n    mc_race_store_u32(&ordered_global, (uint32_t)mc_tmp26);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return combine(next_value(), next_value());") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t value = combine(next_value(), next_value());") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "value = combine(next_value(), next_value());") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "consume(next_value(), next_value());") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "box_value(next_value())") == null);
}

test "lower-c emits unsafe contract blocks as scoped blocks" {
    const source =
        \\extern fn next_value() -> u32;
        \\extern fn consume_value(value: u32) -> void;
        \\extern fn consume_values(values: [1]u32) -> void;
        \\
        \\struct Counter {
        \\    next: u32,
        \\}
        \\
        \\fn consume_counter(counter: Counter) -> void {
        \\    return;
        \\}
        \\
        \\fn accept_plain_contract_scope() -> u32 {
        \\    var x: u32 = 1;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        x = x + 1;
        \\    }
        \\    return x;
        \\}
        \\
        \\fn accept_unchecked_contract_add(a: u32, b: u32) -> u32 {
        \\    var x: u32 = 0;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        x = unchecked.add(a, b);
        \\    }
        \\    return x;
        \\}
        \\
        \\fn accept_unchecked_contract_return_order() -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return unchecked.add(next_value(), next_value());
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn accept_unchecked_contract_cast_return_order() -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return unchecked.add(next_value(), next_value()) as u32;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn accept_unchecked_contract_local_order() -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let value: u32 = unchecked.add(next_value(), next_value());
        \\        return value;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn accept_unchecked_contract_cast_local_order() -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let cast_value: u32 = unchecked.add(next_value(), next_value()) as u32;
        \\        return cast_value;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn accept_unchecked_contract_inferred_local_order() -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let inferred = unchecked.add(next_value(), next_value());
        \\        return inferred;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn accept_unchecked_contract_cast_inferred_local_order() -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let cast_inferred = unchecked.add(next_value(), next_value()) as u32;
        \\        return cast_inferred;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn accept_unchecked_contract_assignment_order() -> u32 {
        \\    var value: u32 = 0;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        value = unchecked.add(next_value(), next_value());
        \\    }
        \\    return value;
        \\}
        \\
        \\fn accept_unchecked_contract_cast_assignment_order() -> u32 {
        \\    var cast_assigned: u32 = 0;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        cast_assigned = unchecked.add(next_value(), next_value()) as u32;
        \\    }
        \\    return cast_assigned;
        \\}
        \\
        \\fn accept_unchecked_contract_arg_order() -> void {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        consume_value(unchecked.add(next_value(), next_value()));
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_cast_arg_order() -> void {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        consume_value(unchecked.add(next_value(), next_value()) as u32);
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_arg_sub_order() -> void {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        consume_value(unchecked.sub(next_value(), next_value()));
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_arg_mul_order() -> void {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        consume_value(unchecked.mul(next_value(), next_value()));
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_sub_order() -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return unchecked.sub(next_value(), next_value());
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn accept_unchecked_contract_mul_order() -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return unchecked.mul(next_value(), next_value());
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn accept_unchecked_contract_nested_binary_order(a: u32, b: u32, c: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return (unchecked.add(a, b)) + c;
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_array_return(a: u32, b: u32) -> [1]u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return .{ unchecked.add(a, b) };
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_cast_array_return(a: u32, b: u32) -> [1]u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return .{ unchecked.add(a, b) as u32 };
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_struct_return(a: u32, b: u32) -> Counter {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return .{ .next = unchecked.mul(a, b) };
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_cast_struct_return(a: u32, b: u32) -> Counter {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return .{ .next = unchecked.mul(a, b) as u32 };
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_array_local(a: u32, b: u32) -> [1]u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let values: [1]u32 = .{ unchecked.sub(a, b) };
        \\        return values;
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_struct_local(a: u32, b: u32) -> Counter {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let counter: Counter = .{ .next = unchecked.add(a, b) };
        \\        return counter;
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_array_arg(a: u32, b: u32) -> void {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        consume_values(.{ unchecked.add(a, b) });
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_struct_arg(a: u32, b: u32) -> void {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        consume_counter(.{ .next = unchecked.mul(a, b) });
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_array_assignment(a: u32, b: u32) -> [1]u32 {
        \\    var values: [1]u32 = .{0};
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        values = .{ unchecked.sub(a, b) };
        \\    }
        \\    return values;
        \\}
        \\
        \\fn accept_unchecked_contract_struct_assignment(a: u32, b: u32) -> Counter {
        \\    var counter: Counter = .{ .next = 0 };
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        counter = .{ .next = unchecked.add(a, b) };
        \\    }
        \\    return counter;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("emit_c_contract_block.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t accept_plain_contract_scope(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t x = 1;\n    /* MC_CONTRACT_BEGIN no_overflow */\n    {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "x = mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t accept_unchecked_contract_add(uint32_t a, uint32_t b)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=x op=add */") != null);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, output.items, "/* MC_MIR_RANGE no_overflow target=value op=add */"));
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=inferred op=add */") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=cast_value op=add */") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=cast_inferred op=add */") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=cast_assigned op=add */") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.items, "/* MC_MIR_RANGE no_overflow target=call_arg op=add */"));
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=call_arg op=sub */") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=call_arg op=mul */") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=binary_operand op=add */") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=value op=sub */") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=value op=mul */") != null);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, output.items, "/* MC_MIR_RANGE no_overflow target=aggregate_element op=add */"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.items, "/* MC_MIR_RANGE no_overflow target=aggregate_element op=sub */"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, output.items, "/* MC_MIR_RANGE no_overflow target=next op=mul */"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.items, "/* MC_MIR_RANGE no_overflow target=next op=add */"));
    try std.testing.expect(std.mem.indexOf(u8, output.items, "consume_values(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "consume_counter(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " = (mc_tmp") != null);
}

test "C race-tolerant aggregate slice loads parenthesize generated pointer expressions" {
    const source =
        \\struct Inner { x: u32 }
        \\extern fn make_inner_slice() -> []const Inner;
        \\fn read_slice_element() -> u32 {
        \\    let inner = make_inner_slice()[0];
        \\    return inner.x;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("emit_c_aggregate_slice_race_parentheses.mc", source, &output);
    try expectContains(output.items, "mc_race_load_u32(&((&mc_tmp0.ptr[mc_check_index_usize(");
    try expectContains(output.items, ")])->x)))");
}

test "lower-c unchecked arithmetic requires MIR no-overflow range fact" {
    const source =
        \\struct Counter {
        \\    next: u32,
        \\}
        \\
        \\extern "C" fn consume_value(value: u32) -> u32;
        \\
        \\fn trusted_add(a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return unchecked.add(a, b);
        \\    }
        \\}
        \\
        \\fn inferred_local(a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let inferred = unchecked.add(a, b);
        \\        return inferred;
        \\    }
        \\}
        \\
        \\fn assigned_local(a: u32, b: u32) -> u32 {
        \\    var sum: u32 = 0;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        sum = unchecked.mul(a, b);
        \\    }
        \\    return sum;
        \\}
        \\
        \\fn call_arg_fact(a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return consume_value(unchecked.add(a, b));
        \\    }
        \\}
        \\
        \\fn binary_operand_fact(a: u32, b: u32, c: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return (unchecked.add(a, b)) + c;
        \\    }
        \\}
        \\
        \\fn aggregate_element_fact(a: u32, b: u32) -> [1]u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return .{ unchecked.add(a, b) };
        \\    }
        \\}
        \\
        \\fn aggregate_field_fact(a: u32, b: u32) -> Counter {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return .{ .next = unchecked.mul(a, b) };
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_range_fact_required.mc", source, &output);
    try expectContains(output.items, "/* MC_MIR_RANGE no_overflow target=value op=add */");
    try expectContains(output.items, "/* MC_MIR_RANGE no_overflow target=inferred op=add */");
    try expectContains(output.items, "/* MC_MIR_RANGE no_overflow target=sum op=mul */");
    try expectContains(output.items, "/* MC_MIR_RANGE no_overflow target=call_arg op=add */");
    try expectContains(output.items, "/* MC_MIR_RANGE no_overflow target=binary_operand op=add */");
    try expectContains(output.items, "/* MC_MIR_RANGE no_overflow target=aggregate_element op=add */");
    try expectContains(output.items, "/* MC_MIR_RANGE no_overflow target=next op=mul */");
    try expectContains(output.items, "uint32_t mc_tmp0 = a;");
    try expectContains(output.items, "uint32_t mc_tmp1 = b;");
    try expectContains(output.items, "uint32_t mc_tmp2 = (mc_tmp0 + mc_tmp1);");

    var missing_fact_output: std.ArrayList(u8) = .empty;
    defer missing_fact_output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.UnsupportedCEmission,
        appendCheckedCTestWithoutRangeFacts("c_range_fact_missing.mc", source, &.{"trusted_add"}, &missing_fact_output),
    );

    const non_value_missing_fact_cases = [_]struct {
        source_name: []const u8,
        function_name: []const u8,
    }{
        .{ .source_name = "c_range_fact_missing_inferred.mc", .function_name = "inferred_local" },
        .{ .source_name = "c_range_fact_missing_assigned.mc", .function_name = "assigned_local" },
        .{ .source_name = "c_range_fact_missing_call_arg.mc", .function_name = "call_arg_fact" },
        .{ .source_name = "c_range_fact_missing_binary_operand.mc", .function_name = "binary_operand_fact" },
        .{ .source_name = "c_range_fact_missing_aggregate_element.mc", .function_name = "aggregate_element_fact" },
        .{ .source_name = "c_range_fact_missing_aggregate_field.mc", .function_name = "aggregate_field_fact" },
    };
    for (non_value_missing_fact_cases) |case| {
        var missing_non_value_fact_output: std.ArrayList(u8) = .empty;
        defer missing_non_value_fact_output.deinit(std.testing.allocator);
        try std.testing.expectError(
            error.UnsupportedCEmission,
            appendCheckedCTestWithoutRangeFacts(case.source_name, source, &.{case.function_name}, &missing_non_value_fact_output),
        );
    }

    var wrong_target_output: std.ArrayList(u8) = .empty;
    defer wrong_target_output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.UnsupportedCEmission,
        appendCheckedCTestWithRetargetedRangeFacts("c_range_fact_wrong_target.mc", source, "trusted_add", "wrong_target", &wrong_target_output),
    );

    var wrong_inferred_local_target_output: std.ArrayList(u8) = .empty;
    defer wrong_inferred_local_target_output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.UnsupportedCEmission,
        appendCheckedCTestWithRetargetedRangeFacts("c_range_fact_inferred_local_wrong_target.mc", source, "inferred_local", "wrong_target", &wrong_inferred_local_target_output),
    );

    var wrong_aggregate_target_output: std.ArrayList(u8) = .empty;
    defer wrong_aggregate_target_output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.UnsupportedCEmission,
        appendCheckedCTestWithRetargetedRangeFacts("c_range_fact_aggregate_wrong_target.mc", source, "aggregate_field_fact", "wrong_target", &wrong_aggregate_target_output),
    );

    var wrong_aggregate_element_target_output: std.ArrayList(u8) = .empty;
    defer wrong_aggregate_element_target_output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.UnsupportedCEmission,
        appendCheckedCTestWithRetargetedRangeFacts("c_range_fact_aggregate_element_wrong_target.mc", source, "aggregate_element_fact", "wrong_target", &wrong_aggregate_element_target_output),
    );

    var wrong_call_arg_target_output: std.ArrayList(u8) = .empty;
    defer wrong_call_arg_target_output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.UnsupportedCEmission,
        appendCheckedCTestWithRetargetedRangeFacts("c_range_fact_call_arg_wrong_target.mc", source, "call_arg_fact", "wrong_target", &wrong_call_arg_target_output),
    );

    var wrong_assigned_local_target_output: std.ArrayList(u8) = .empty;
    defer wrong_assigned_local_target_output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.UnsupportedCEmission,
        appendCheckedCTestWithRetargetedRangeFacts("c_range_fact_assigned_local_wrong_target.mc", source, "assigned_local", "wrong_target", &wrong_assigned_local_target_output),
    );

    var wrong_binary_operand_target_output: std.ArrayList(u8) = .empty;
    defer wrong_binary_operand_target_output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.UnsupportedCEmission,
        appendCheckedCTestWithRetargetedRangeFacts("c_range_fact_binary_operand_wrong_target.mc", source, "binary_operand_fact", "wrong_target", &wrong_binary_operand_target_output),
    );
}
