const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const lower_llvm = @import("lower_llvm.zig");
const lower_llvm_query = @import("lower_llvm_query.zig");
const mir = @import("mir.zig");
const test_support = @import("test_support.zig");

fn appendLlvmTest(source_name: []const u8, source: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseModule(source_name, source);
    defer parsed.deinit();

    try lower_llvm.appendLlvm(std.testing.allocator, parsed.module, output);
}

test "LLVM noalias query accepts only the real builtin call shape" {
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

    var parsed = try test_support.parseModule("llvm_noalias_grouped_call_callee.mc", source);
    defer parsed.deinit();

    const fn_decl = parsed.module.decls[0].kind.fn_decl;
    const ret_expr = fn_decl.body.?.items[0].kind.@"return".?;
    const outer_call = ret_expr.kind.call;
    try std.testing.expect(!lower_llvm_query.isAssumeNoaliasCall(outer_call));

    const grouped_callee = outer_call.callee.*.kind.grouped;
    const inner_call = grouped_callee.kind.call;
    try std.testing.expect(lower_llvm_query.isAssumeNoaliasCall(inner_call));

    const missing_size_fn = parsed.module.decls[1].kind.fn_decl;
    const missing_size_ret = missing_size_fn.body.?.items[0].kind.@"return".?;
    try std.testing.expect(!lower_llvm_query.isAssumeNoaliasCall(missing_size_ret.kind.call));

    const with_type_arg_fn = parsed.module.decls[2].kind.fn_decl;
    const with_type_arg_ret = with_type_arg_fn.body.?.items[0].kind.@"return".?;
    try std.testing.expect(!lower_llvm_query.isAssumeNoaliasCall(with_type_arg_ret.kind.call));
}

fn clearPointerProvenanceFactsForFunction(module_mir: *mir.Module, name: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        for (function.pointer_provenance_facts) |fact| {
            if (fact.field_path) |field_path| module_mir.allocator.free(field_path);
        }
        module_mir.allocator.free(function.pointer_provenance_facts);
        function.pointer_provenance_facts = try module_mir.allocator.alloc(mir.PointerProvenanceFact, 0);
        return;
    }
    return error.TestUnexpectedResult;
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

fn retargetRepresentationFactsForFunction(module_mir: *mir.Module, name: []const u8, value_id: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        if (function.representation_facts.len == 0) return error.TestUnexpectedResult;
        function.representation_facts[0].value_id = value_id;
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

fn appendLlvmTestWithoutPointerProvenanceFacts(source_name: []const u8, source: []const u8, function_names: []const []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseModule(source_name, source);
    defer parsed.deinit();

    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    for (function_names) |function_name| {
        try clearPointerProvenanceFactsForFunction(&module_mir, function_name);
    }

    try lower_llvm.appendLlvmCheckedMir(std.testing.allocator, parsed.module, &module_mir, output, source_name, .{}, false, .riscv64, null);
}

fn appendLlvmTestWithoutRangeFacts(source_name: []const u8, source: []const u8, function_names: []const []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseModule(source_name, source);
    defer parsed.deinit();

    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    for (function_names) |function_name| {
        try clearRangeFactsForFunction(&module_mir, function_name);
    }

    try lower_llvm.appendLlvmCheckedMir(std.testing.allocator, parsed.module, &module_mir, output, source_name, .{}, false, .riscv64, null);
}

test "LLVM rejects prebuilt MIR with missing bounds facts" {
    const source =
        \\fn bounds_fact_gate(a: [2]u32, i: usize) -> u32 {
        \\    return a[i];
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_missing_bounds_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.build(std.testing.allocator, parsed.module);
    defer module_mir.deinit();
    try clearBoundsFactsForFunction(&module_mir, "bounds_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, lower_llvm.appendLlvmCheckedMir(std.testing.allocator, parsed.module, &module_mir, &output, "llvm_missing_bounds_facts.mc", .{}, false, .riscv64, null));
}

test "LLVM rejects prebuilt MIR with missing representation facts" {
    const source =
        \\fn representation_fact_gate(p: *mut u32) -> u32 {
        \\    unsafe { return p.*; }
        \\}
    ;

    var parsed = try test_support.parseModule("llvm_missing_representation_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try clearRepresentationFactsForFunction(&module_mir, "representation_fact_gate");

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirRepresentationFacts,
        lower_llvm.appendLlvmCheckedMir(std.testing.allocator, parsed.module, &module_mir, &output, "llvm_missing_representation_facts.mc", .{}, false, .riscv64, null),
    );
}

test "LLVM rejects prebuilt MIR with stale representation facts" {
    const source =
        \\fn representation_fact_gate(p: *mut u32) -> u32 {
        \\    unsafe { return p.*; }
        \\}
    ;

    var parsed = try test_support.parseModule("llvm_stale_representation_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try retargetRepresentationFactsForFunction(&module_mir, "representation_fact_gate", "stale_value");

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirRepresentationFacts,
        lower_llvm.appendLlvmCheckedMir(std.testing.allocator, parsed.module, &module_mir, &output, "llvm_stale_representation_facts.mc", .{}, false, .riscv64, null),
    );
}

fn appendLlvmTestWithRetargetedRangeFacts(source_name: []const u8, source: []const u8, function_name: []const u8, target: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseModule(source_name, source);
    defer parsed.deinit();

    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try retargetRangeFactsForFunction(&module_mir, function_name, target);

    try lower_llvm.appendLlvmCheckedMir(std.testing.allocator, parsed.module, &module_mir, output, source_name, .{}, false, .riscv64, null);
}

fn appendLlvmTestWithoutPointerProvenanceFactsForSubject(source_name: []const u8, source: []const u8, function_name: []const u8, subject: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseModule(source_name, source);
    defer parsed.deinit();

    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try clearPointerProvenanceFactsForFunctionSubject(&module_mir, function_name, subject);

    try lower_llvm.appendLlvmCheckedMir(std.testing.allocator, parsed.module, &module_mir, output, source_name, .{}, false, .riscv64, null);
}

fn appendLlvmTestWithoutPointerProvenanceFactsForSubjectField(source_name: []const u8, source: []const u8, function_name: []const u8, subject: []const u8, field_path: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseModule(source_name, source);
    defer parsed.deinit();

    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try clearPointerProvenanceFactsForFunctionSubjectField(&module_mir, function_name, subject, field_path);

    try lower_llvm.appendLlvmCheckedMir(std.testing.allocator, parsed.module, &module_mir, output, source_name, .{}, false, .riscv64, null);
}

fn appendLlvmTestWithoutAggregateReturnPointerFact(source_name: []const u8, source: []const u8, callee: []const u8, field_path: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseModule(source_name, source);
    defer parsed.deinit();

    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{});
    defer module_mir.deinit();
    try clearAggregateReturnPointerFact(&module_mir, callee, field_path);
    try lower_llvm.appendLlvmCheckedMir(std.testing.allocator, parsed.module, &module_mir, output, source_name, .{}, false, .riscv64, null);
}

fn llvmFunctionBody(output: []const u8, signature_prefix: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, output, signature_prefix) orelse return error.TestUnexpectedResult;
    const body_end = std.mem.indexOf(u8, output[start..], "\n}\n\n") orelse return error.TestUnexpectedResult;
    return output[start .. start + body_end];
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}

test "LLVM backend emits a backend_name alias for the override symbol" {
    const source =
        \\#[backend_name("rss_helper_x")]
        \\fn helper(x: u64) -> u64 { return x + 1; }
        \\export fn harness() -> u64 { return helper(7); }
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("bn_llvm.mc", source, &output);

    // The function keeps its source name; the override is exposed via a module-level alias.
    try std.testing.expect(std.mem.indexOf(u8, output.items, "define internal i64 @helper(i64 %x)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "@rss_helper_x = alias i64 (i64), ptr @helper") != null);
}

test "LLVM backend emits checked integer add from MIR-gated source" {
    const source =
        \\fn add_one(value: u32) -> u32 {
        \\    return value + 1;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_smoke.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "define internal i32 @add_one(i32 %value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "@llvm.uadd.with.overflow.i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "call void @mc_trap_IntegerOverflow()") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " nsw ") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " nuw ") == null);
}

test "LLVM unchecked arithmetic requires MIR no-overflow range fact" {
    const source =
        \\struct Counter {
        \\    next: u32,
        \\}
        \\
        \\fn consume_value(value: u32) -> u32 {
        \\    return value;
        \\}
        \\
        \\fn trusted_add(a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)] {
        \\        return unchecked.add(a, b);
        \\    }
        \\}
        \\
        \\fn inferred_local(a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)] {
        \\        let inferred = unchecked.add(a, b);
        \\        return inferred;
        \\    }
        \\}
        \\
        \\fn assigned_local(a: u32, b: u32) -> u32 {
        \\    var sum: u32 = a;
        \\    #[unsafe_contract(no_overflow)] {
        \\        sum = unchecked.mul(sum, b);
        \\    }
        \\    return sum;
        \\}
        \\
        \\fn call_arg_fact(a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)] {
        \\        return consume_value(unchecked.add(a, b));
        \\    }
        \\}
        \\
        \\fn binary_operand_fact(a: u32, b: u32, c: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)] {
        \\        return (unchecked.add(a, b)) + c;
        \\    }
        \\}
        \\
        \\fn aggregate_element_fact(a: u32, b: u32) -> [1]u32 {
        \\    #[unsafe_contract(no_overflow)] {
        \\        return .{ unchecked.add(a, b) };
        \\    }
        \\}
        \\
        \\fn aggregate_field_fact(a: u32, b: u32) -> Counter {
        \\    #[unsafe_contract(no_overflow)] {
        \\        return .{ .next = unchecked.mul(a, b) };
        \\    }
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_range_fact.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal i32 @trusted_add");
    try expectContains(body, "; mir range_fact consumed fn=trusted_add target=value op=add assumption=no_overflow source=");
    try expectContains(body, " = add i32 %a, %b");
    try expectNotContains(body, "@llvm.uadd.with.overflow.i32");
    try expectNotContains(body, "call void @mc_trap_IntegerOverflow()");
    try expectContains(output.items, "; mir range_fact consumed fn=inferred_local target=inferred op=add assumption=no_overflow source=");
    try expectContains(output.items, "; mir range_fact consumed fn=assigned_local target=sum op=mul assumption=no_overflow source=");
    try expectContains(output.items, "; mir range_fact consumed fn=call_arg_fact target=call_arg op=add assumption=no_overflow source=");
    try expectContains(output.items, "; mir range_fact consumed fn=binary_operand_fact target=binary_operand op=add assumption=no_overflow source=");
    try expectContains(output.items, "; mir range_fact consumed fn=aggregate_element_fact target=aggregate_element op=add assumption=no_overflow source=");
    try expectContains(output.items, "; mir range_fact consumed fn=aggregate_field_fact target=next op=mul assumption=no_overflow source=");

    var missing_fact_output: std.ArrayList(u8) = .empty;
    defer missing_fact_output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.UnsupportedLlvmEmission,
        appendLlvmTestWithoutRangeFacts("llvm_range_fact_missing.mc", source, &.{"trusted_add"}, &missing_fact_output),
    );

    const non_value_missing_fact_cases = [_]struct {
        source_name: []const u8,
        function_name: []const u8,
    }{
        .{ .source_name = "llvm_range_fact_missing_inferred.mc", .function_name = "inferred_local" },
        .{ .source_name = "llvm_range_fact_missing_assigned.mc", .function_name = "assigned_local" },
        .{ .source_name = "llvm_range_fact_missing_call_arg.mc", .function_name = "call_arg_fact" },
        .{ .source_name = "llvm_range_fact_missing_binary_operand.mc", .function_name = "binary_operand_fact" },
        .{ .source_name = "llvm_range_fact_missing_aggregate_element.mc", .function_name = "aggregate_element_fact" },
        .{ .source_name = "llvm_range_fact_missing_aggregate_field.mc", .function_name = "aggregate_field_fact" },
    };
    for (non_value_missing_fact_cases) |case| {
        var missing_non_value_fact_output: std.ArrayList(u8) = .empty;
        defer missing_non_value_fact_output.deinit(std.testing.allocator);
        try std.testing.expectError(
            error.UnsupportedLlvmEmission,
            appendLlvmTestWithoutRangeFacts(case.source_name, source, &.{case.function_name}, &missing_non_value_fact_output),
        );
    }

    var wrong_target_output: std.ArrayList(u8) = .empty;
    defer wrong_target_output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.UnsupportedLlvmEmission,
        appendLlvmTestWithRetargetedRangeFacts("llvm_range_fact_wrong_target.mc", source, "trusted_add", "wrong_target", &wrong_target_output),
    );

    var wrong_inferred_local_target_output: std.ArrayList(u8) = .empty;
    defer wrong_inferred_local_target_output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.UnsupportedLlvmEmission,
        appendLlvmTestWithRetargetedRangeFacts("llvm_range_fact_inferred_local_wrong_target.mc", source, "inferred_local", "wrong_target", &wrong_inferred_local_target_output),
    );

    var wrong_aggregate_target_output: std.ArrayList(u8) = .empty;
    defer wrong_aggregate_target_output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.UnsupportedLlvmEmission,
        appendLlvmTestWithRetargetedRangeFacts("llvm_range_fact_aggregate_wrong_target.mc", source, "aggregate_field_fact", "wrong_target", &wrong_aggregate_target_output),
    );

    var wrong_aggregate_element_target_output: std.ArrayList(u8) = .empty;
    defer wrong_aggregate_element_target_output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.UnsupportedLlvmEmission,
        appendLlvmTestWithRetargetedRangeFacts("llvm_range_fact_aggregate_element_wrong_target.mc", source, "aggregate_element_fact", "wrong_target", &wrong_aggregate_element_target_output),
    );

    var wrong_call_arg_target_output: std.ArrayList(u8) = .empty;
    defer wrong_call_arg_target_output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.UnsupportedLlvmEmission,
        appendLlvmTestWithRetargetedRangeFacts("llvm_range_fact_call_arg_wrong_target.mc", source, "call_arg_fact", "wrong_target", &wrong_call_arg_target_output),
    );

    var wrong_assigned_local_target_output: std.ArrayList(u8) = .empty;
    defer wrong_assigned_local_target_output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.UnsupportedLlvmEmission,
        appendLlvmTestWithRetargetedRangeFacts("llvm_range_fact_assigned_local_wrong_target.mc", source, "assigned_local", "wrong_target", &wrong_assigned_local_target_output),
    );

    var wrong_binary_operand_target_output: std.ArrayList(u8) = .empty;
    defer wrong_binary_operand_target_output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.UnsupportedLlvmEmission,
        appendLlvmTestWithRetargetedRangeFacts("llvm_range_fact_binary_operand_wrong_target.mc", source, "binary_operand_fact", "wrong_target", &wrong_binary_operand_target_output),
    );
}

test "LLVM consumes MIR facts for direct internal global pointer returns" {
    const source =
        \\global shared_counter: u32 = 0;
        \\fn returned_global_pointer() -> *mut u32 {
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
        \\fn branched_global_pointer(flag: bool) -> *mut u32 {
        \\    if flag { return &shared_counter; } else { return &shared_counter; }
        \\}
        \\fn uses_global_pointer_through_alias() -> u32 {
        \\    let producer: fn() -> *mut u32 = returned_global_pointer;
        \\    let gp: *mut u32 = producer();
        \\    return gp.*;
        \\}
        \\fn uses_returned_global_pointer() -> u32 {
        \\    let gp: *mut u32 = returned_global_pointer();
        \\    return gp.*;
        \\}
        \\fn uses_forwarded_global_pointer() -> u32 {
        \\    let gp: *mut u32 = forwarded_global_pointer();
        \\    return gp.*;
        \\}
        \\fn uses_noalias_global_pointer() -> u32 {
        \\    let gp: *mut u32 = noalias_global_pointer();
        \\    return gp.*;
        \\}
        \\fn uses_branched_global_pointer(flag: bool) -> u32 {
        \\    let gp: *mut u32 = branched_global_pointer(flag);
        \\    return gp.*;
        \\}
        \\fn assigns_returned_global_pointer() -> u32 {
        \\    var gp: *mut u32 = &shared_counter;
        \\    gp = returned_global_pointer();
        \\    return gp.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_pointer_return_provenance.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @uses_returned_global_pointer");
    try expectContains(body, "; mir pointer_provenance consumed fn=uses_returned_global_pointer subject=gp provenance=global_storage reason=none");
    try expectContains(body, "load atomic i32, ptr %");

    const forwarded_body = try llvmFunctionBody(output.items, "define internal i32 @uses_forwarded_global_pointer");
    try expectContains(forwarded_body, "; mir pointer_provenance consumed fn=uses_forwarded_global_pointer subject=gp provenance=global_storage reason=none");
    try expectContains(forwarded_body, "load atomic i32, ptr %");

    const noalias_body = try llvmFunctionBody(output.items, "define internal i32 @uses_noalias_global_pointer");
    try expectContains(noalias_body, "; mir pointer_provenance consumed fn=uses_noalias_global_pointer subject=gp provenance=global_storage reason=none");
    try expectContains(noalias_body, "load atomic i32, ptr %");

    const alias_body = try llvmFunctionBody(output.items, "define internal i32 @uses_global_pointer_through_alias");
    try expectContains(alias_body, "; mir pointer_provenance consumed fn=uses_global_pointer_through_alias subject=gp provenance=global_storage reason=none");
    try expectContains(alias_body, "load atomic i32, ptr %");

    const assignment_body = try llvmFunctionBody(output.items, "define internal i32 @assigns_returned_global_pointer");
    try expectContains(assignment_body, "; mir pointer_provenance consumed fn=assigns_returned_global_pointer subject=gp provenance=global_storage reason=reassignment");

    const branched_body = try llvmFunctionBody(output.items, "define internal i32 @uses_branched_global_pointer");
    try expectContains(branched_body, "; mir pointer_provenance consumed fn=uses_branched_global_pointer subject=gp provenance=global_storage reason=none");
    try expectContains(branched_body, "load atomic i32, ptr %");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_pointer_return_provenance.mc", source, "uses_returned_global_pointer", "gp", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @uses_returned_global_pointer");
    try expectNotContains(missing_body, "; mir pointer_provenance consumed fn=uses_returned_global_pointer subject=gp provenance=global_storage reason=none");
    try expectContains(missing_body, "load atomic i32, ptr %");

    var missing_forwarded_output: std.ArrayList(u8) = .empty;
    defer missing_forwarded_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_pointer_return_provenance.mc", source, "uses_forwarded_global_pointer", "gp", &missing_forwarded_output);
    const missing_forwarded_body = try llvmFunctionBody(missing_forwarded_output.items, "define internal i32 @uses_forwarded_global_pointer");
    try expectNotContains(missing_forwarded_body, "; mir pointer_provenance consumed fn=uses_forwarded_global_pointer subject=gp provenance=global_storage reason=none");
    try expectContains(missing_forwarded_body, "load atomic i32, ptr %");

    var missing_noalias_output: std.ArrayList(u8) = .empty;
    defer missing_noalias_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_pointer_return_provenance.mc", source, "uses_noalias_global_pointer", "gp", &missing_noalias_output);
    const missing_noalias_body = try llvmFunctionBody(missing_noalias_output.items, "define internal i32 @uses_noalias_global_pointer");
    try expectNotContains(missing_noalias_body, "; mir pointer_provenance consumed fn=uses_noalias_global_pointer subject=gp provenance=global_storage reason=none");
    try expectContains(missing_noalias_body, "load atomic i32, ptr %");
}

test "LLVM aggregate-return pointer facts are MIR-owned and fail closed when absent" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn direct_holder() -> Holder {
        \\    return .{ .ptr = &shared_counter, .tag = 1 };
        \\}
        \\
        \\fn use_direct_holder() -> u32 {
        \\    let holder: Holder = direct_holder();
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_direct_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_direct_holder callee=direct_holder field=ptr provenance=global_storage");
    try expectContains(body, "load atomic i32, ptr %");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_aggregate_return_mir_fact.mc", source, "direct_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_direct_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_direct_holder callee=direct_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
    try expectNotContains(missing_body, "load i32, ptr %");
}

test "LLVM aggregate-return bounded call prefixes are MIR-owned" {
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
    try appendLlvmTest("llvm_aggregate_return_literal_prefix_mir_fact.mc", source, &output);
    const call_free_body = try llvmFunctionBody(output.items, "define internal i32 @use_call_free_prefix_holder");
    try expectContains(call_free_body, "; mir aggregate_return_pointer consumed caller=use_call_free_prefix_holder callee=call_free_prefix_holder field=ptr provenance=global_storage");
    const call_body = try llvmFunctionBody(output.items, "define internal i32 @use_call_prefix_holder");
    try expectContains(call_body, "; mir aggregate_return_pointer consumed caller=use_call_prefix_holder callee=call_prefix_holder field=ptr provenance=global_storage");
    const local_call_body = try llvmFunctionBody(output.items, "define internal i32 @use_local_call_prefix_holder");
    try expectContains(local_call_body, "; mir aggregate_return_pointer consumed caller=use_local_call_prefix_holder callee=local_call_prefix_holder field=ptr provenance=global_storage");
    const local_arg_call_body = try llvmFunctionBody(output.items, "define internal i32 @use_local_arg_call_prefix_holder");
    try expectNotContains(local_arg_call_body, "; mir aggregate_return_pointer consumed caller=use_local_arg_call_prefix_holder callee=local_arg_call_prefix_holder field=ptr");
    try expectContains(local_arg_call_body, "load atomic i32, ptr %");
    try expectNotContains(local_arg_call_body, "load i32, ptr %");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_aggregate_return_literal_prefix_mir_fact.mc", source, "call_prefix_holder", "ptr", &missing_output);
    const missing_call_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_call_prefix_holder");
    try expectNotContains(missing_call_body, "; mir aggregate_return_pointer consumed caller=use_call_prefix_holder callee=call_prefix_holder field=ptr");
    try expectContains(missing_call_body, "load atomic i32, ptr %");
    try expectNotContains(missing_call_body, "load i32, ptr %");

    var missing_local_output: std.ArrayList(u8) = .empty;
    defer missing_local_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_aggregate_return_literal_prefix_mir_fact.mc", source, "local_call_prefix_holder", "ptr", &missing_local_output);
    const missing_local_call_body = try llvmFunctionBody(missing_local_output.items, "define internal i32 @use_local_call_prefix_holder");
    try expectNotContains(missing_local_call_body, "; mir aggregate_return_pointer consumed caller=use_local_call_prefix_holder callee=local_call_prefix_holder field=ptr");
    try expectContains(missing_local_call_body, "load atomic i32, ptr %");
    try expectNotContains(missing_local_call_body, "load i32, ptr %");
}

test "LLVM consumes MIR aggregate-return pointer-array element facts" {
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
    try appendLlvmTest("llvm_aggregate_return_array_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptrs[0] provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_aggregate_return_array_mir_fact.mc", source, "returned_holder", "ptrs[0]", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptrs[0]");
    try expectContains(missing_body, "load atomic i32, ptr %");
}

test "LLVM consumes MIR nested aggregate-return pointer facts" {
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
    try appendLlvmTest("llvm_nested_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_outer");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_outer callee=returned_outer field=inner.ptrs[0] provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_nested_aggregate_return_mir_fact.mc", source, "returned_outer", "inner.ptrs[0]", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_outer");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_outer callee=returned_outer field=inner.ptrs[0]");
    try expectContains(missing_body, "load atomic i32, ptr %");
}

test "LLVM consumes MIR nested array aggregate-return pointer facts" {
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
    try appendLlvmTest("llvm_nested_array_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=cells[0].ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_nested_array_aggregate_return_mir_fact.mc", source, "returned_holder", "cells[0].ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=cells[0].ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
}

test "LLVM consumes MIR trailing aggregate-return facts" {
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
    try appendLlvmTest("llvm_trailing_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_trailing_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
}

test "LLVM consumes MIR trailing aggregate-return assignment facts" {
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
    try appendLlvmTest("llvm_trailing_aggregate_return_assignment_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_trailing_aggregate_return_assignment_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
}

test "LLVM consumes MIR trailing aggregate-return field assignment facts" {
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
    try appendLlvmTest("llvm_trailing_aggregate_return_field_assignment_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_trailing_aggregate_return_field_assignment_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
}

test "LLVM consumes MIR trailing aggregate-return array element assignment facts" {
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
    try appendLlvmTest("llvm_trailing_aggregate_return_array_element_assignment_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptrs[0] provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_trailing_aggregate_return_array_element_assignment_mir_fact.mc", source, "returned_holder", "ptrs[0]", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptrs[0]");
    try expectContains(missing_body, "load atomic i32, ptr %");
}

test "LLVM aggregate-return dynamic-index fallthrough writes fail closed" {
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
    try appendLlvmTest("llvm_trailing_aggregate_return_dynamic_index_assignment_fail_closed.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptrs[0]");
    try expectContains(body, "load atomic i32, ptr %");
}

test "LLVM consumes MIR aggregate-return nested control facts" {
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
    try appendLlvmTest("llvm_nested_control_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    const if_let_body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder_if_let");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");
    try expectContains(if_let_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder_if_let callee=returned_holder_if_let field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_nested_control_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    const missing_if_let_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder_if_let");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_if_let_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder_if_let callee=returned_holder_if_let field=ptr provenance=global_storage");
    try expectContains(missing_body, "load atomic i32, ptr %");

    var missing_if_let_output: std.ArrayList(u8) = .empty;
    defer missing_if_let_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_nested_control_aggregate_return_mir_fact.mc", source, "returned_holder_if_let", "ptr", &missing_if_let_output);
    const missing_if_let_only_body = try llvmFunctionBody(missing_if_let_output.items, "define internal i32 @use_returned_holder_if_let");
    try expectNotContains(missing_if_let_only_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder_if_let callee=returned_holder_if_let field=ptr");
    try expectContains(missing_if_let_only_body, "load atomic i32, ptr %");
    try expectNotContains(missing_if_let_only_body, "load i32, ptr %");
}

test "LLVM consumes MIR aggregate-return loop-control prefix facts" {
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
    try appendLlvmTest("llvm_loop_control_prefix_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_loop_control_prefix_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
    try expectNotContains(missing_body, "load i32, ptr %");
}

test "LLVM consumes MIR aggregate-return continue loop-control prefix facts" {
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
    try appendLlvmTest("llvm_continue_loop_control_prefix_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_continue_loop_control_prefix_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
    try expectNotContains(missing_body, "load i32, ptr %");
}

test "LLVM consumes MIR aggregate-return transparent while-prefix facts" {
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
    try appendLlvmTest("llvm_transparent_while_prefix_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_transparent_while_prefix_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
}

test "LLVM consumes MIR aggregate-return scalar-field-mutating while facts" {
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
    try appendLlvmTest("llvm_scalar_field_mutating_while_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_scalar_field_mutating_while_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
    try expectNotContains(missing_body, "load i32, ptr %");
}

test "LLVM consumes MIR aggregate-return stable pointer-field-mutating while facts" {
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
    try appendLlvmTest("llvm_stable_pointer_field_mutating_while_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_stable_pointer_field_mutating_while_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
    try expectNotContains(missing_body, "load i32, ptr %");
}

test "LLVM aggregate-return mixed pointer-mutating while prefix fails closed" {
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
    try appendLlvmTest("llvm_mixed_pointer_mutating_while_prefix_aggregate_return_fail_closed.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder");
    try expectContains(body, "load atomic i32, ptr %");
}

test "LLVM consumes MIR aggregate-return scalar-mutating loop local facts" {
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
    try appendLlvmTest("llvm_scalar_mutating_loop_local_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_scalar_mutating_loop_local_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
    try expectNotContains(missing_body, "load i32, ptr %");
}

test "LLVM consumes MIR aggregate-return nested loop-control facts" {
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
    try appendLlvmTest("llvm_nested_loop_control_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_nested_loop_control_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
    try expectNotContains(missing_body, "load i32, ptr %");
}

test "LLVM consumes MIR aggregate-return nested transparent switch facts" {
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
    try appendLlvmTest("llvm_nested_transparent_switch_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_nested_transparent_switch_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
}

test "LLVM consumes MIR aggregate-return nested transparent if-let facts" {
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
    try appendLlvmTest("llvm_nested_transparent_if_let_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_nested_transparent_if_let_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
}

test "LLVM aggregate-return nested call control fails closed" {
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
    try appendLlvmTest("llvm_nested_call_control_aggregate_return_fail_closed.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder");
    try expectContains(body, "load atomic i32, ptr %");
}

test "LLVM aggregate-return nested mutating join fails closed" {
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
    try appendLlvmTest("llvm_nested_mutating_join_aggregate_return_fail_closed.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(body, "load atomic i32, ptr %");
}

test "LLVM consumes MIR aggregate-return if-let facts" {
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
    try appendLlvmTest("llvm_if_let_control_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    const else_body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder_else");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");
    try expectContains(else_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder_else callee=returned_holder_else field=ptr provenance=global_storage");
    try expectContains(body, "load atomic i32, ptr %");
    try expectContains(else_body, "load atomic i32, ptr %");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_if_let_control_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    const missing_else_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder_else");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_else_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder_else callee=returned_holder_else field=ptr provenance=global_storage");
    try expectContains(missing_body, "load atomic i32, ptr %");
    try expectNotContains(missing_body, "load i32, ptr %");

    var missing_else_output: std.ArrayList(u8) = .empty;
    defer missing_else_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_if_let_control_aggregate_return_mir_fact.mc", source, "returned_holder_else", "ptr", &missing_else_output);
    const missing_else_only_body = try llvmFunctionBody(missing_else_output.items, "define internal i32 @use_returned_holder_else");
    try expectNotContains(missing_else_only_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder_else callee=returned_holder_else field=ptr");
    try expectContains(missing_else_only_body, "load atomic i32, ptr %");
    try expectNotContains(missing_else_only_body, "load i32, ptr %");
}

test "LLVM consumes MIR aggregate-return scoped-block prefix facts" {
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
    try appendLlvmTest("llvm_scoped_block_prefix_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");
    try expectContains(body, "load atomic i32, ptr %");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_scoped_block_prefix_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
    try expectNotContains(missing_body, "load i32, ptr %");
}

test "LLVM consumes MIR aggregate-return unsafe-block prefix facts" {
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
    try appendLlvmTest("llvm_unsafe_block_prefix_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");
    try expectContains(body, "load atomic i32, ptr %");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_unsafe_block_prefix_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
    try expectNotContains(missing_body, "load i32, ptr %");
}

test "LLVM consumes MIR aggregate-return comptime-block prefix facts" {
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
    try appendLlvmTest("llvm_comptime_block_prefix_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");
    try expectContains(body, "load atomic i32, ptr %");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_comptime_block_prefix_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
    try expectNotContains(missing_body, "load i32, ptr %");
}

test "LLVM consumes MIR aggregate-return assert prefix facts" {
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
    try appendLlvmTest("llvm_assert_prefix_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");
    try expectContains(body, "load atomic i32, ptr %");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_assert_prefix_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
    try expectNotContains(missing_body, "load i32, ptr %");
}

test "LLVM consumes MIR aggregate-return no-overflow contract prefix facts" {
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
    try appendLlvmTest("llvm_contract_block_prefix_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");
    try expectContains(body, "load atomic i32, ptr %");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_contract_block_prefix_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
    try expectNotContains(missing_body, "load i32, ptr %");
}

test "LLVM consumes MIR aggregate-return no-overflow contract local facts" {
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
    try appendLlvmTest("llvm_contract_block_local_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");
    try expectContains(body, "load atomic i32, ptr %");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_contract_block_local_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
    try expectNotContains(missing_body, "load i32, ptr %");
}

test "LLVM consumes MIR aggregate-return contract-block update facts" {
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
    try appendLlvmTest("llvm_contract_block_update_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");
    try expectContains(body, "load atomic i32, ptr %");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_contract_block_update_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
    try expectNotContains(missing_body, "load i32, ptr %");
}

test "LLVM consumes MIR aggregate-return sequential switch facts" {
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
    try appendLlvmTest("llvm_sequential_switch_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_sequential_switch_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
}

test "LLVM consumes MIR aggregate-return triple switch facts" {
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
    try appendLlvmTest("llvm_triple_switch_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_triple_switch_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
}

test "LLVM consumes MIR aggregate-return nine-path switch facts" {
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
    try appendLlvmTest("llvm_nine_path_switch_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_nine_path_switch_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
}

test "LLVM aggregate-return path overflow switches fail closed" {
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
    try appendLlvmTest("llvm_path_overflow_switch_aggregate_return_fail_closed.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder");
    try expectContains(body, "load atomic i32, ptr %");
}

test "LLVM consumes MIR aggregate-return if join facts" {
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
    try appendLlvmTest("llvm_if_join_prefix_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_if_join_prefix_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
}

test "LLVM consumes MIR aggregate-return all-fallthrough switch facts" {
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
    try appendLlvmTest("llvm_all_fallthrough_switch_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_all_fallthrough_switch_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
}

test "LLVM consumes MIR aggregate-return effectful direct-literal defer prefix facts" {
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
    try appendLlvmTest("llvm_effectful_defer_prefix_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");
    const local_body = try llvmFunctionBody(output.items, "define internal i32 @use_local_returned_holder");
    try expectContains(local_body, "; mir aggregate_return_pointer consumed caller=use_local_returned_holder callee=local_returned_holder field=ptr provenance=global_storage");
    const local_arg_body = try llvmFunctionBody(output.items, "define internal i32 @use_local_arg_returned_holder");
    try expectNotContains(local_arg_body, "; mir aggregate_return_pointer consumed caller=use_local_arg_returned_holder callee=local_arg_returned_holder field=ptr");
    try expectContains(local_arg_body, "load atomic i32, ptr %");
    try expectNotContains(local_arg_body, "load i32, ptr %");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_effectful_defer_prefix_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
    try expectNotContains(missing_body, "load i32, ptr %");

    var missing_local_output: std.ArrayList(u8) = .empty;
    defer missing_local_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_effectful_defer_prefix_aggregate_return_mir_fact.mc", source, "local_returned_holder", "ptr", &missing_local_output);
    const missing_local_body = try llvmFunctionBody(missing_local_output.items, "define internal i32 @use_local_returned_holder");
    try expectNotContains(missing_local_body, "; mir aggregate_return_pointer consumed caller=use_local_returned_holder callee=local_returned_holder field=ptr");
    try expectContains(missing_local_body, "load atomic i32, ptr %");
    try expectNotContains(missing_local_body, "load i32, ptr %");
}

test "LLVM consumes MIR aggregate-return call-free defer prefix facts" {
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
    try appendLlvmTest("llvm_call_free_defer_prefix_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");
    try expectContains(body, "load atomic i32, ptr %");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_call_free_defer_prefix_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
    try expectNotContains(missing_body, "load i32, ptr %");
}

test "LLVM consumes MIR aggregate-return transparent for-prefix facts" {
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
    try appendLlvmTest("llvm_for_prefix_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_for_prefix_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
}

test "LLVM consumes MIR aggregate-return scalar-field-mutating for facts" {
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
    try appendLlvmTest("llvm_scalar_field_mutating_for_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_scalar_field_mutating_for_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
    try expectNotContains(missing_body, "load i32, ptr %");
}

test "LLVM consumes MIR aggregate-return nested pointer-array facts" {
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
    try appendLlvmTest("llvm_nested_pointer_array_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptrs[0][0] provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_nested_pointer_array_aggregate_return_mir_fact.mc", source, "returned_holder", "ptrs[0][0]", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptrs[0][0]");
    try expectContains(missing_body, "load atomic i32, ptr %");
}

test "LLVM aggregate-return nested pointer arrays with missing leaf facts fail closed" {
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
    try appendLlvmTest("llvm_nested_pointer_array_aggregate_return_missing_leaf_fail_closed.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptrs[0][1]");
    try expectContains(body, "load atomic i32, ptr %");
}

test "LLVM consumes MIR aggregate-return nested struct-array facts" {
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
    try appendLlvmTest("llvm_nested_struct_array_aggregate_return_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=groups[0][0].ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_nested_struct_array_aggregate_return_mir_fact.mc", source, "returned_holder", "groups[0][0].ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=groups[0][0].ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
}

test "LLVM aggregate-return dereference writes fail closed" {
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
    try appendLlvmTest("llvm_deref_write_aggregate_return_fail_closed.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_holder");
    try expectNotContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder");
    try expectContains(body, "load atomic i32, ptr %");
}

test "LLVM consumes MIR trailing nested aggregate-return field assignment facts" {
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
    try appendLlvmTest("llvm_trailing_nested_aggregate_return_field_assignment_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_outer");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_outer callee=returned_outer field=inner.ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_trailing_nested_aggregate_return_field_assignment_mir_fact.mc", source, "returned_outer", "inner.ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_outer");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_outer callee=returned_outer field=inner.ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
}

test "LLVM consumes MIR trailing deep aggregate-return field assignment facts" {
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
    try appendLlvmTest("llvm_trailing_deep_aggregate_return_field_assignment_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_returned_outer");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_returned_outer callee=returned_outer field=middle.leaf.ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_trailing_deep_aggregate_return_field_assignment_mir_fact.mc", source, "returned_outer", "middle.leaf.ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_returned_outer");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_returned_outer callee=returned_outer field=middle.leaf.ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
}

test "LLVM consumes MIR aggregate-return facts through straight-line local values" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn local_holder() -> Holder {
        \\    let holder: Holder = .{ .ptr = &shared_counter, .tag = 1 };
        \\    return holder;
        \\}
        \\
        \\fn assigned_holder() -> Holder {
        \\    var local: u32 = 2;
        \\    var holder: Holder = .{ .ptr = &local, .tag = 2 };
        \\    holder = .{ .ptr = &shared_counter, .tag = 3 };
        \\    return holder;
        \\}
        \\
        \\fn copied_holder() -> Holder {
        \\    let source: Holder = .{ .ptr = &shared_counter, .tag = 4 };
        \\    let holder: Holder = source;
        \\    return holder;
        \\}
        \\
        \\fn use_local_holder() -> u32 {
        \\    let holder: Holder = local_holder();
        \\    return holder.ptr.*;
        \\}
        \\
        \\fn use_assigned_holder() -> u32 {
        \\    let holder: Holder = assigned_holder();
        \\    return holder.ptr.*;
        \\}
        \\
        \\fn use_copied_holder() -> u32 {
        \\    let holder: Holder = copied_holder();
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_aggregate_return_local_mir_fact.mc", source, &output);
    const local_body = try llvmFunctionBody(output.items, "define internal i32 @use_local_holder");
    try expectContains(local_body, "; mir aggregate_return_pointer consumed caller=use_local_holder callee=local_holder field=ptr provenance=global_storage");
    const assigned_body = try llvmFunctionBody(output.items, "define internal i32 @use_assigned_holder");
    try expectContains(assigned_body, "; mir aggregate_return_pointer consumed caller=use_assigned_holder callee=assigned_holder field=ptr provenance=global_storage");
    const copied_body = try llvmFunctionBody(output.items, "define internal i32 @use_copied_holder");
    try expectContains(copied_body, "; mir aggregate_return_pointer consumed caller=use_copied_holder callee=copied_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_aggregate_return_local_mir_fact.mc", source, "assigned_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_assigned_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_assigned_holder callee=assigned_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");
}

test "LLVM consumes MIR aggregate-return facts across exhaustive direct-return branches" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn branched_holder(flag: bool) -> Holder {
        \\    if flag { return .{ .ptr = &shared_counter, .tag = 1 }; } else { return .{ .ptr = &shared_counter, .tag = 2 }; }
        \\}
        \\
        \\fn mixed_branched_holder(flag: bool, fallback: *mut u32) -> Holder {
        \\    if flag { return .{ .ptr = &shared_counter, .tag = 3 }; } else { return .{ .ptr = fallback, .tag = 4 }; }
        \\}
        \\
        \\fn use_branched_holder(flag: bool) -> u32 {
        \\    let holder: Holder = branched_holder(flag);
        \\    return holder.ptr.*;
        \\}
        \\
        \\fn use_mixed_branched_holder(flag: bool) -> u32 {
        \\    var local: u32 = 5;
        \\    let holder: Holder = mixed_branched_holder(flag, &local);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_aggregate_return_branch_mir_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_branched_holder");
    try expectContains(body, "; mir aggregate_return_pointer consumed caller=use_branched_holder callee=branched_holder field=ptr provenance=global_storage");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutAggregateReturnPointerFact("llvm_aggregate_return_branch_mir_fact.mc", source, "branched_holder", "ptr", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @use_branched_holder");
    try expectNotContains(missing_body, "; mir aggregate_return_pointer consumed caller=use_branched_holder callee=branched_holder field=ptr");
    try expectContains(missing_body, "load atomic i32, ptr %");

    const mixed_body = try llvmFunctionBody(output.items, "define internal i32 @use_mixed_branched_holder");
    try expectNotContains(mixed_body, "; mir aggregate_return_pointer consumed caller=use_mixed_branched_holder callee=mixed_branched_holder field=ptr");
    try expectContains(mixed_body, "load atomic i32, ptr %");
}

test "LLVM ordinary global scalar accesses lower to unordered atomics" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/spec/data_race_semantics.mc", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(source);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("data_race_semantics.mc", source, &output);

    const local_body = try llvmFunctionBody(output.items, "define internal i32 @local_non_racing_access");
    try expectContains(local_body, "load i32, ptr %local.addr.");
    try expectContains(local_body, "store i32 ");
    try expectNotContains(local_body, " atomic ");

    const global_store_body = try llvmFunctionBody(output.items, "define internal void @possibly_racing_store");
    try expectContains(global_store_body, "store atomic i32 %x, ptr @shared_counter unordered, align 4");
    try expectNotContains(global_store_body, "store i32 %x, ptr @shared_counter");

    const global_load_body = try llvmFunctionBody(output.items, "define internal i32 @possibly_racing_load");
    try expectContains(global_load_body, "load atomic i32, ptr @shared_counter unordered, align 4");
    try expectNotContains(global_load_body, "load i32, ptr @shared_counter");

    const pointer_store_body = try llvmFunctionBody(output.items, "define internal void @possibly_racing_pointer_store");
    try expectContains(pointer_store_body, "store ptr @shared_counter, ptr %gp.addr.");
    try expectContains(pointer_store_body, "store atomic i32 %x, ptr %");
    try expectContains(pointer_store_body, " unordered, align 4");
    try expectNotContains(pointer_store_body, "store i32 %x, ptr %");

    const pointer_load_body = try llvmFunctionBody(output.items, "define internal i32 @possibly_racing_pointer_load");
    try expectContains(pointer_load_body, "store ptr @shared_counter, ptr %gp.addr.");
    try expectContains(pointer_load_body, "; mir pointer_provenance consumed fn=possibly_racing_pointer_load subject=gp provenance=global_storage reason=none");
    try expectContains(pointer_load_body, "load atomic i32, ptr %");
    try expectContains(pointer_load_body, " unordered, align 4");
    try expectNotContains(pointer_load_body, "load i32, ptr %");

    const pointer_call_invalidated_body = try llvmFunctionBody(output.items, "define internal i32 @pointer_global_invalidated_by_call_lowers_atomic");
    try expectContains(pointer_call_invalidated_body, "; mir pointer_provenance consumed fn=pointer_global_invalidated_by_call_lowers_atomic subject=gp provenance=global_storage reason=none");
    try expectContains(pointer_call_invalidated_body, "call ptr @external_raw_many_pointer()");
    try expectContains(pointer_call_invalidated_body, "load atomic i32, ptr %");
    try expectContains(pointer_call_invalidated_body, " unordered, align 4");
    try expectNotContains(pointer_call_invalidated_body, "load i32, ptr %");

    const address_deref_body = try llvmFunctionBody(output.items, "define internal i32 @possibly_racing_direct_address_deref_load");
    try expectContains(address_deref_body, "load atomic i32, ptr @shared_counter unordered, align 4");
    try expectNotContains(address_deref_body, "load i32, ptr @shared_counter");

    const raw_many_offset_zero_body = try llvmFunctionBody(output.items, "define internal i32 @possibly_racing_raw_many_offset_zero_pointer_load");
    try expectContains(raw_many_offset_zero_body, "store ptr @shared_counter, ptr %p.addr.");
    try expectContains(raw_many_offset_zero_body, "; mir pointer_provenance consumed fn=possibly_racing_raw_many_offset_zero_pointer_load subject=q provenance=global_storage reason=none");
    try expectContains(raw_many_offset_zero_body, "getelementptr i32, ptr %");
    try expectContains(raw_many_offset_zero_body, ", i64 0");
    try expectContains(raw_many_offset_zero_body, "load atomic i32, ptr %");
    try expectContains(raw_many_offset_zero_body, " unordered, align 4");
    try expectNotContains(raw_many_offset_zero_body, "load i32, ptr %");

    const raw_many_offset_one_body = try llvmFunctionBody(output.items, "define internal i32 @raw_many_offset_one_pointer_lowers_atomic");
    try expectContains(raw_many_offset_one_body, "store ptr @shared_counter, ptr %p.addr.");
    try expectContains(raw_many_offset_one_body, ", i64 1");
    try expectContains(raw_many_offset_one_body, "load atomic i32, ptr %");
    try expectContains(raw_many_offset_one_body, " unordered, align 4");
    try expectNotContains(raw_many_offset_one_body, "load i32, ptr %");

    const raw_many_offset_dynamic_body = try llvmFunctionBody(output.items, "define internal i32 @raw_many_offset_dynamic_pointer_lowers_atomic");
    try expectContains(raw_many_offset_dynamic_body, "store ptr @shared_counter, ptr %p.addr.");
    try expectContains(raw_many_offset_dynamic_body, "getelementptr i32, ptr %");
    try expectContains(raw_many_offset_dynamic_body, "load atomic i32, ptr %");
    try expectContains(raw_many_offset_dynamic_body, " unordered, align 4");
    try expectNotContains(raw_many_offset_dynamic_body, "load i32, ptr %");

    const raw_many_offset_unknown_body = try llvmFunctionBody(output.items, "define internal i32 @raw_many_offset_unknown_pointer_lowers_atomic");
    try expectContains(raw_many_offset_unknown_body, "call ptr @external_raw_many_pointer()");
    try expectContains(raw_many_offset_unknown_body, ", i64 0");
    try expectContains(raw_many_offset_unknown_body, "load atomic i32, ptr %");
    try expectContains(raw_many_offset_unknown_body, " unordered, align 4");
    try expectNotContains(raw_many_offset_unknown_body, "load i32, ptr %");

    const returned_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @possibly_racing_returned_pointer_load");
    try expectContains(returned_pointer_body, "call ptr @returned_global_pointer()");
    try expectContains(returned_pointer_body, "load atomic i32, ptr %");
    try expectContains(returned_pointer_body, " unordered, align 4");
    try expectNotContains(returned_pointer_body, "load i32, ptr %");

    const param_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @consume_global_param");
    try expectContains(param_pointer_body, "load atomic i32, ptr %p unordered, align 4");
    try expectNotContains(param_pointer_body, "load i32, ptr %p");

    const indirect_param_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @consume_indirect_global_param");
    try expectContains(indirect_param_pointer_body, "load atomic i32, ptr %p unordered, align 4");
    try expectNotContains(indirect_param_pointer_body, "load i32, ptr %p");

    const indirect_local_param_body = try llvmFunctionBody(output.items, "define internal i32 @consume_indirect_local_param");
    try expectContains(indirect_local_param_body, "load atomic i32, ptr %p unordered, align 4");
    try expectNotContains(indirect_local_param_body, "load i32, ptr %p");

    const alias_copy_param_body = try llvmFunctionBody(output.items, "define internal i32 @consume_alias_copy_param");
    try expectContains(alias_copy_param_body, "load atomic i32, ptr %p unordered, align 4");
    try expectNotContains(alias_copy_param_body, "load i32, ptr %p");

    const indirect_reassigned_param_body = try llvmFunctionBody(output.items, "define internal i32 @consume_indirect_reassigned_param");
    try expectContains(indirect_reassigned_param_body, "load atomic i32, ptr %p unordered, align 4");
    try expectNotContains(indirect_reassigned_param_body, "load i32, ptr %p");

    const indirect_reassigned_other_param_body = try llvmFunctionBody(output.items, "define internal i32 @consume_indirect_reassigned_other_param");
    try expectContains(indirect_reassigned_other_param_body, "load atomic i32, ptr %p unordered, align 4");
    try expectNotContains(indirect_reassigned_other_param_body, "load i32, ptr %p");

    const alias_copy_reassigned_param_body = try llvmFunctionBody(output.items, "define internal i32 @consume_alias_copy_reassigned_param");
    try expectContains(alias_copy_reassigned_param_body, "load atomic i32, ptr %p unordered, align 4");
    try expectNotContains(alias_copy_reassigned_param_body, "load i32, ptr %p");

    const alias_copy_reassigned_other_param_body = try llvmFunctionBody(output.items, "define internal i32 @consume_alias_copy_reassigned_other_param");
    try expectContains(alias_copy_reassigned_other_param_body, "load atomic i32, ptr %p unordered, align 4");
    try expectNotContains(alias_copy_reassigned_other_param_body, "load i32, ptr %p");

    const alias_copy_escape_param_body = try llvmFunctionBody(output.items, "define internal i32 @consume_alias_copy_escape_param");
    try expectContains(alias_copy_escape_param_body, "load atomic i32, ptr %p unordered, align 4");
    try expectNotContains(alias_copy_escape_param_body, "load i32, ptr %p");

    const mixed_param_body = try llvmFunctionBody(output.items, "define internal i32 @consume_mixed_param");
    try expectContains(mixed_param_body, "load atomic i32, ptr %p unordered, align 4");
    try expectNotContains(mixed_param_body, "load i32, ptr %p");

    const local_only_param_body = try llvmFunctionBody(output.items, "define internal i32 @consume_local_only_param");
    try expectContains(local_only_param_body, "load atomic i32, ptr %p unordered, align 4");
    try expectNotContains(local_only_param_body, "load i32, ptr %p");

    const unproven_param_store_body = try llvmFunctionBody(output.items, "define internal void @unproven_param_pointer_store_lowers_atomic");
    try expectContains(unproven_param_store_body, "store atomic i32 %x, ptr %p unordered, align 4");
    try expectNotContains(unproven_param_store_body, "store i32 %x, ptr %p");

    const local_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @local_pointer_deref_stays_plain");
    try expectContains(local_pointer_body, "store i32 6, ptr %");
    try expectContains(local_pointer_body, "; mir pointer_provenance consumed fn=local_pointer_deref_stays_plain subject=lp provenance=local_storage reason=none");
    try expectContains(local_pointer_body, "load i32, ptr %");
    try expectNotContains(local_pointer_body, " atomic ");

    const deref_address_of_local_body = try llvmFunctionBody(output.items, "define internal i32 @deref_address_of_local_stays_plain");
    try expectContains(deref_address_of_local_body, "load i32, ptr %");
    try expectNotContains(deref_address_of_local_body, " atomic ");

    const local_pointer_copy_body = try llvmFunctionBody(output.items, "define internal i32 @local_pointer_copy_deref_stays_plain");
    try expectContains(local_pointer_copy_body, "; mir pointer_provenance consumed fn=local_pointer_copy_deref_stays_plain subject=lp provenance=local_storage reason=none");
    try expectContains(local_pointer_copy_body, "; mir pointer_provenance consumed fn=local_pointer_copy_deref_stays_plain subject=copy provenance=local_storage reason=none");
    try expectContains(local_pointer_copy_body, "load i32, ptr %");
    try expectNotContains(local_pointer_copy_body, " atomic ");

    const local_pointer_invalidated_body = try llvmFunctionBody(output.items, "define internal i32 @local_pointer_fact_invalidated_by_call_lowers_atomic");
    try expectContains(local_pointer_invalidated_body, "; mir pointer_provenance consumed fn=local_pointer_fact_invalidated_by_call_lowers_atomic subject=lp provenance=local_storage reason=none");
    try expectContains(local_pointer_invalidated_body, "call ptr @external_raw_many_pointer()");
    try expectContains(local_pointer_invalidated_body, "load atomic i32, ptr %");
    try expectContains(local_pointer_invalidated_body, " unordered, align 4");
    try expectNotContains(local_pointer_invalidated_body, "load i32, ptr %");

    const aggregate_global_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_global_pointer_field_load");
    try expectContains(aggregate_global_pointer_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_global_pointer_body, "load atomic i32, ptr %");
    try expectContains(aggregate_global_pointer_body, " unordered, align 4");
    try expectNotContains(aggregate_global_pointer_body, "load i32, ptr %p.addr.");

    const nested_aggregate_global_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @nested_aggregate_global_pointer_field_load");
    try expectContains(nested_aggregate_global_pointer_body, "store ptr @shared_counter, ptr %");
    try expectContains(nested_aggregate_global_pointer_body, "load atomic i32, ptr %");
    try expectContains(nested_aggregate_global_pointer_body, " unordered, align 4");
    try expectNotContains(nested_aggregate_global_pointer_body, "load i32, ptr %p.addr.");

    const aggregate_pointer_alias_global_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_global_pointer_field_load");
    try expectContains(aggregate_pointer_alias_global_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_pointer_alias_global_body, "load atomic i32, ptr %");
    try expectContains(aggregate_pointer_alias_global_body, " unordered, align 4");
    try expectNotContains(aggregate_pointer_alias_global_body, "load i32, ptr %p.addr.");

    const nested_aggregate_pointer_alias_global_body = try llvmFunctionBody(output.items, "define internal i32 @nested_aggregate_pointer_alias_global_pointer_field_load");
    try expectContains(nested_aggregate_pointer_alias_global_body, "store ptr @shared_counter, ptr %");
    try expectContains(nested_aggregate_pointer_alias_global_body, "load atomic i32, ptr %");
    try expectContains(nested_aggregate_pointer_alias_global_body, " unordered, align 4");
    try expectNotContains(nested_aggregate_pointer_alias_global_body, "load i32, ptr %p.addr.");

    const nested_aggregate_assigned_global_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @nested_aggregate_assigned_global_pointer_field_load");
    try expectContains(nested_aggregate_assigned_global_pointer_body, "store ptr @shared_counter, ptr %");
    try expectContains(nested_aggregate_assigned_global_pointer_body, "load atomic i32, ptr %");
    try expectContains(nested_aggregate_assigned_global_pointer_body, " unordered, align 4");
    try expectNotContains(nested_aggregate_assigned_global_pointer_body, "load i32, ptr %p.addr.");

    const aggregate_stack_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_stack_pointer_field_lowers_atomic");
    try expectContains(aggregate_stack_pointer_body, "; mir pointer_provenance consumed fn=aggregate_stack_pointer_field_lowers_atomic subject=p provenance=local_storage reason=none");
    try expectContains(aggregate_stack_pointer_body, "load i32, ptr %");
    try expectNotContains(aggregate_stack_pointer_body, " atomic ");

    const nested_aggregate_stack_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @nested_aggregate_stack_pointer_field_lowers_atomic");
    try expectContains(nested_aggregate_stack_pointer_body, "; mir pointer_provenance consumed fn=nested_aggregate_stack_pointer_field_lowers_atomic subject=p provenance=local_storage reason=none");
    try expectContains(nested_aggregate_stack_pointer_body, "load i32, ptr %");
    try expectNotContains(nested_aggregate_stack_pointer_body, " atomic ");

    const aggregate_pointer_alias_stack_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_stack_pointer_field_stays_plain");
    try expectContains(aggregate_pointer_alias_stack_body, "load i32, ptr %");
    try expectNotContains(aggregate_pointer_alias_stack_body, "load atomic i32");

    const aggregate_pointer_alias_field_assignment_direct_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_field_assignment_clears_direct_field_fact");
    try expectContains(aggregate_pointer_alias_field_assignment_direct_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_pointer_alias_field_assignment_direct_body, "load atomic i32, ptr %");
    try expectContains(aggregate_pointer_alias_field_assignment_direct_body, " unordered, align 4");
    try expectNotContains(aggregate_pointer_alias_field_assignment_direct_body, "load i32, ptr %");

    const aggregate_pointer_alias_field_assignment_alias_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_field_assignment_establishes_alias_local_fact");
    try expectContains(aggregate_pointer_alias_field_assignment_alias_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_pointer_alias_field_assignment_alias_body, "load i32, ptr %");
    try expectNotContains(aggregate_pointer_alias_field_assignment_alias_body, "load atomic i32");

    const aggregate_pointer_alias_field_assignment_global_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_field_assignment_establishes_global_fact");
    try expectContains(aggregate_pointer_alias_field_assignment_global_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_pointer_alias_field_assignment_global_body, "load atomic i32, ptr %");
    try expectContains(aggregate_pointer_alias_field_assignment_global_body, " unordered, align 4");
    try expectNotContains(aggregate_pointer_alias_field_assignment_global_body, "load i32, ptr %p.addr.");

    const aggregate_pointer_alias_returned_unknown_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_returned_unknown_lowers_atomic");
    try expectContains(aggregate_pointer_alias_returned_unknown_body, "call ptr @external_pointer_holder()");
    try expectContains(aggregate_pointer_alias_returned_unknown_body, "load atomic i32, ptr %");
    try expectContains(aggregate_pointer_alias_returned_unknown_body, " unordered, align 4");
    try expectNotContains(aggregate_pointer_alias_returned_unknown_body, "load i32, ptr %");

    const aggregate_pointer_param_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_param_field_lowers_atomic");
    try expectContains(aggregate_pointer_param_body, "load atomic i32, ptr %");
    try expectContains(aggregate_pointer_param_body, " unordered, align 4");
    try expectNotContains(aggregate_pointer_param_body, "load i32, ptr %");

    const aggregate_global_param_body = try llvmFunctionBody(output.items, "define internal i32 @consume_aggregate_global_param");
    try expectContains(aggregate_global_param_body, "load atomic i32, ptr %");
    try expectContains(aggregate_global_param_body, " unordered, align 4");
    try expectNotContains(aggregate_global_param_body, "load i32, ptr %p.addr.");

    const aggregate_array_global_param_body = try llvmFunctionBody(output.items, "define internal i32 @consume_aggregate_array_global_param");
    try expectContains(aggregate_array_global_param_body, "load atomic i32, ptr %");
    try expectContains(aggregate_array_global_param_body, " unordered, align 4");
    try expectNotContains(aggregate_array_global_param_body, "load i32, ptr %p.addr.");

    const aggregate_local_param_body = try llvmFunctionBody(output.items, "define internal i32 @consume_aggregate_local_param");
    try expectContains(aggregate_local_param_body, "load atomic i32, ptr %");
    try expectNotContains(aggregate_local_param_body, "load i32, ptr %");

    const indirect_aggregate_local_param_body = try llvmFunctionBody(output.items, "define internal i32 @consume_indirect_aggregate_local_param");
    try expectContains(indirect_aggregate_local_param_body, "load atomic i32, ptr %");
    try expectNotContains(indirect_aggregate_local_param_body, "load i32, ptr %");

    const aggregate_mixed_param_body = try llvmFunctionBody(output.items, "define internal i32 @consume_aggregate_mixed_param");
    try expectContains(aggregate_mixed_param_body, "load atomic i32, ptr %");
    try expectContains(aggregate_mixed_param_body, " unordered, align 4");
    try expectNotContains(aggregate_mixed_param_body, "load i32, ptr %");

    const aggregate_unknown_address_param_body = try llvmFunctionBody(output.items, "define internal i32 @consume_aggregate_unknown_address_param");
    try expectContains(aggregate_unknown_address_param_body, "load atomic i32, ptr %");
    try expectContains(aggregate_unknown_address_param_body, " unordered, align 4");
    try expectNotContains(aggregate_unknown_address_param_body, "load i32, ptr %");

    const indirect_aggregate_alias_param_body = try llvmFunctionBody(output.items, "define internal i32 @consume_indirect_aggregate_alias_param");
    try expectContains(indirect_aggregate_alias_param_body, "load atomic i32, ptr %");
    try expectContains(indirect_aggregate_alias_param_body, " unordered, align 4");
    try expectNotContains(indirect_aggregate_alias_param_body, "load i32, ptr %p.addr.");

    const aggregate_alias_copy_param_body = try llvmFunctionBody(output.items, "define internal i32 @consume_aggregate_alias_copy_param");
    try expectContains(aggregate_alias_copy_param_body, "load atomic i32, ptr %");
    try expectContains(aggregate_alias_copy_param_body, " unordered, align 4");
    try expectNotContains(aggregate_alias_copy_param_body, "load i32, ptr %p.addr.");

    const indirect_aggregate_reassigned_param_body = try llvmFunctionBody(output.items, "define internal i32 @consume_indirect_aggregate_reassigned_param");
    try expectContains(indirect_aggregate_reassigned_param_body, "load atomic i32, ptr %");
    try expectContains(indirect_aggregate_reassigned_param_body, " unordered, align 4");
    try expectNotContains(indirect_aggregate_reassigned_param_body, "load i32, ptr %");

    const indirect_aggregate_reassigned_other_param_body = try llvmFunctionBody(output.items, "define internal i32 @consume_indirect_aggregate_reassigned_other_param");
    try expectContains(indirect_aggregate_reassigned_other_param_body, "load atomic i32, ptr %");
    try expectContains(indirect_aggregate_reassigned_other_param_body, " unordered, align 4");
    try expectNotContains(indirect_aggregate_reassigned_other_param_body, "load i32, ptr %");

    const aggregate_alias_copy_escape_param_body = try llvmFunctionBody(output.items, "define internal i32 @consume_aggregate_alias_copy_escape_param");
    try expectContains(aggregate_alias_copy_escape_param_body, "load atomic i32, ptr %");
    try expectContains(aggregate_alias_copy_escape_param_body, " unordered, align 4");
    try expectNotContains(aggregate_alias_copy_escape_param_body, "load i32, ptr %");

    const aggregate_indirect_escape_param_body = try llvmFunctionBody(output.items, "define internal i32 @consume_aggregate_indirect_escape_param");
    try expectContains(aggregate_indirect_escape_param_body, "load atomic i32, ptr %");
    try expectContains(aggregate_indirect_escape_param_body, " unordered, align 4");
    try expectNotContains(aggregate_indirect_escape_param_body, "load i32, ptr %");

    const aggregate_param_write_clears_body = try llvmFunctionBody(output.items, "define internal i32 @consume_aggregate_param_write_clears");
    try expectContains(aggregate_param_write_clears_body, "call ptr @exported_global_pointer()");
    try expectContains(aggregate_param_write_clears_body, "load atomic i32, ptr %");
    try expectContains(aggregate_param_write_clears_body, " unordered, align 4");
    try expectNotContains(aggregate_param_write_clears_body, "load i32, ptr %");

    const exported_aggregate_param_body = try llvmFunctionBody(output.items, "define i32 @exported_aggregate_global_param_lowers_atomic");
    try expectContains(exported_aggregate_param_body, "load atomic i32, ptr %");
    try expectContains(exported_aggregate_param_body, " unordered, align 4");
    try expectNotContains(exported_aggregate_param_body, "load i32, ptr %");

    const aggregate_pointer_alias_reassigned_unknown_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_reassigned_unknown_lowers_atomic");
    try expectContains(aggregate_pointer_alias_reassigned_unknown_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_pointer_alias_reassigned_unknown_body, "call ptr @external_pointer_holder()");
    try expectContains(aggregate_pointer_alias_reassigned_unknown_body, "load atomic i32, ptr %");
    try expectContains(aggregate_pointer_alias_reassigned_unknown_body, " unordered, align 4");
    try expectNotContains(aggregate_pointer_alias_reassigned_unknown_body, "load i32, ptr %");

    const aggregate_pointer_alias_reassigned_unknown_write_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_reassigned_unknown_write_does_not_clear_old_field_fact");
    try expectContains(aggregate_pointer_alias_reassigned_unknown_write_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_pointer_alias_reassigned_unknown_write_body, "call ptr @external_pointer_holder()");
    try expectContains(aggregate_pointer_alias_reassigned_unknown_write_body, "load atomic i32, ptr %");
    try expectContains(aggregate_pointer_alias_reassigned_unknown_write_body, " unordered, align 4");
    try expectNotContains(aggregate_pointer_alias_reassigned_unknown_write_body, "load i32, ptr %p.addr.");

    const aggregate_reassigned_stack_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_reassigned_stack_pointer_field_lowers_atomic");
    try expectContains(aggregate_reassigned_stack_body, "; mir pointer_provenance consumed fn=aggregate_reassigned_stack_pointer_field_lowers_atomic subject=p provenance=local_storage reason=none");
    try expectContains(aggregate_reassigned_stack_body, "load i32, ptr %");
    try expectNotContains(aggregate_reassigned_stack_body, " atomic ");

    const nested_aggregate_reassigned_stack_body = try llvmFunctionBody(output.items, "define internal i32 @nested_aggregate_reassigned_stack_pointer_field_lowers_atomic");
    try expectContains(nested_aggregate_reassigned_stack_body, "; mir pointer_provenance consumed fn=nested_aggregate_reassigned_stack_pointer_field_lowers_atomic subject=p provenance=local_storage reason=none");
    try expectContains(nested_aggregate_reassigned_stack_body, "load i32, ptr %");
    try expectNotContains(nested_aggregate_reassigned_stack_body, " atomic ");

    const aggregate_whole_copy_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_whole_copy_pointer_field_load");
    try expectContains(aggregate_whole_copy_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_whole_copy_body, "load atomic i32, ptr %");
    try expectContains(aggregate_whole_copy_body, " unordered, align 4");
    try expectNotContains(aggregate_whole_copy_body, "load i32, ptr %p.addr.");

    const aggregate_init_copy_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_init_copy_pointer_field_load");
    try expectContains(aggregate_init_copy_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_init_copy_body, "load atomic i32, ptr %");
    try expectContains(aggregate_init_copy_body, " unordered, align 4");
    try expectNotContains(aggregate_init_copy_body, "load i32, ptr %p.addr.");

    const aggregate_whole_copy_stack_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_whole_copy_stack_pointer_field_lowers_atomic");
    try expectContains(aggregate_whole_copy_stack_body, "; mir pointer_provenance consumed fn=aggregate_whole_copy_stack_pointer_field_lowers_atomic subject=p provenance=local_storage reason=none");
    try expectContains(aggregate_whole_copy_stack_body, "load i32, ptr %");
    try expectNotContains(aggregate_whole_copy_stack_body, " atomic ");

    const aggregate_computed_copy_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_computed_copy_pointer_field_load");
    try expectContains(aggregate_computed_copy_body, "call { ptr, i32 } @returned_pointer_holder()");
    try expectContains(aggregate_computed_copy_body, "load atomic i32, ptr %");
    try expectContains(aggregate_computed_copy_body, " unordered, align 4");
    try expectNotContains(aggregate_computed_copy_body, "load i32, ptr %p.addr.");

    const aggregate_return_init_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_return_init_pointer_field_load");
    try expectContains(aggregate_return_init_body, "call { ptr, i32 } @returned_pointer_holder()");
    try expectContains(aggregate_return_init_body, "load atomic i32, ptr %");
    try expectContains(aggregate_return_init_body, " unordered, align 4");
    try expectNotContains(aggregate_return_init_body, "load i32, ptr %p.addr.");

    const aggregate_return_local_init_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_return_local_init_pointer_field_load");
    try expectContains(aggregate_return_local_init_body, "call { ptr, i32 } @returned_pointer_holder_via_local()");
    try expectContains(aggregate_return_local_init_body, "load atomic i32, ptr %");
    try expectContains(aggregate_return_local_init_body, " unordered, align 4");
    try expectNotContains(aggregate_return_local_init_body, "load i32, ptr %p.addr.");

    const aggregate_return_local_assignment_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_return_local_assignment_pointer_field_load");
    try expectContains(aggregate_return_local_assignment_body, "call { ptr, i32 } @returned_pointer_holder_via_assignment()");
    try expectContains(aggregate_return_local_assignment_body, "load atomic i32, ptr %");
    try expectContains(aggregate_return_local_assignment_body, " unordered, align 4");
    try expectNotContains(aggregate_return_local_assignment_body, "load i32, ptr %p.addr.");

    const aggregate_return_local_only_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_return_local_only_pointer_field_lowers_atomic");
    try expectContains(aggregate_return_local_only_body, "call { ptr, i32 } @returned_pointer_holder_local_only()");
    try expectContains(aggregate_return_local_only_body, "load atomic i32, ptr %");
    try expectContains(aggregate_return_local_only_body, " unordered, align 4");
    try expectNotContains(aggregate_return_local_only_body, "load i32, ptr %");

    const aggregate_return_if_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_return_if_pointer_field_load");
    try expectContains(aggregate_return_if_body, "call { ptr, i32 } @returned_pointer_holder_via_if(");
    try expectContains(aggregate_return_if_body, "load atomic i32, ptr %");
    try expectContains(aggregate_return_if_body, " unordered, align 4");
    try expectNotContains(aggregate_return_if_body, "load i32, ptr %p.addr.");

    const aggregate_return_mixed_if_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_return_mixed_if_pointer_field_lowers_atomic");
    try expectContains(aggregate_return_mixed_if_body, "call { ptr, i32 } @returned_pointer_holder_via_mixed_if_else(");
    try expectContains(aggregate_return_mixed_if_body, "load atomic i32, ptr %");
    try expectContains(aggregate_return_mixed_if_body, " unordered, align 4");
    try expectNotContains(aggregate_return_mixed_if_body, "load i32, ptr %");

    const aggregate_return_branch_local_if_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_return_branch_local_if_pointer_field_load");
    try expectContains(aggregate_return_branch_local_if_body, "call { ptr, i32 } @returned_pointer_holder_via_branch_local_if(");
    try expectContains(aggregate_return_branch_local_if_body, "load atomic i32, ptr %");
    try expectContains(aggregate_return_branch_local_if_body, " unordered, align 4");
    try expectNotContains(aggregate_return_branch_local_if_body, "load i32, ptr %p.addr.");

    const aggregate_return_mixed_branch_local_if_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_return_mixed_branch_local_if_pointer_field_lowers_atomic");
    try expectContains(aggregate_return_mixed_branch_local_if_body, "call { ptr, i32 } @returned_pointer_holder_via_mixed_branch_local_if(");
    try expectContains(aggregate_return_mixed_branch_local_if_body, "load atomic i32, ptr %");
    try expectContains(aggregate_return_mixed_branch_local_if_body, " unordered, align 4");
    try expectNotContains(aggregate_return_mixed_branch_local_if_body, "load i32, ptr %");

    const aggregate_return_switch_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_return_switch_pointer_field_load");
    try expectContains(aggregate_return_switch_body, "call { ptr, i32 } @returned_pointer_holder_via_switch(");
    try expectContains(aggregate_return_switch_body, "load atomic i32, ptr %");
    try expectContains(aggregate_return_switch_body, " unordered, align 4");
    try expectNotContains(aggregate_return_switch_body, "load i32, ptr %p.addr.");

    const aggregate_return_mixed_switch_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_return_mixed_switch_pointer_field_lowers_atomic");
    try expectContains(aggregate_return_mixed_switch_body, "call { ptr, i32 } @returned_pointer_holder_via_mixed_switch(");
    try expectContains(aggregate_return_mixed_switch_body, "load atomic i32, ptr %");
    try expectContains(aggregate_return_mixed_switch_body, " unordered, align 4");
    try expectNotContains(aggregate_return_mixed_switch_body, "load i32, ptr %");

    const aggregate_return_prefix_bool_switch_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_return_prefix_bool_switch_pointer_field_load");
    try expectContains(aggregate_return_prefix_bool_switch_body, "call { ptr, i32 } @returned_pointer_holder_via_prefix_bool_switch(");
    try expectContains(aggregate_return_prefix_bool_switch_body, "load atomic i32, ptr %");
    try expectContains(aggregate_return_prefix_bool_switch_body, " unordered, align 4");
    try expectNotContains(aggregate_return_prefix_bool_switch_body, "load i32, ptr %p.addr.");

    const aggregate_return_prefix_wildcard_switch_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_return_prefix_wildcard_switch_pointer_field_load");
    try expectContains(aggregate_return_prefix_wildcard_switch_body, "call { ptr, i32 } @returned_pointer_holder_via_prefix_wildcard_switch(");
    try expectContains(aggregate_return_prefix_wildcard_switch_body, "load atomic i32, ptr %");
    try expectContains(aggregate_return_prefix_wildcard_switch_body, " unordered, align 4");
    try expectNotContains(aggregate_return_prefix_wildcard_switch_body, "load i32, ptr %p.addr.");

    const aggregate_return_wildcard_switch_trailing_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_return_wildcard_switch_trailing_pointer_field_load");
    try expectContains(aggregate_return_wildcard_switch_trailing_body, "call { ptr, i32 } @returned_pointer_holder_via_wildcard_switch_trailing(");
    try expectContains(aggregate_return_wildcard_switch_trailing_body, "load atomic i32, ptr %");
    try expectContains(aggregate_return_wildcard_switch_trailing_body, " unordered, align 4");
    try expectNotContains(aggregate_return_wildcard_switch_trailing_body, "load i32, ptr %p.addr.");

    const aggregate_return_multi_wildcard_switch_trailing_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_return_multi_wildcard_switch_trailing_pointer_field_load");
    try expectContains(aggregate_return_multi_wildcard_switch_trailing_body, "call { ptr, i32 } @returned_pointer_holder_via_multi_wildcard_switch_trailing(");
    try expectContains(aggregate_return_multi_wildcard_switch_trailing_body, "load atomic i32, ptr %");
    try expectContains(aggregate_return_multi_wildcard_switch_trailing_body, " unordered, align 4");
    try expectNotContains(aggregate_return_multi_wildcard_switch_trailing_body, "load i32, ptr %p.addr.");

    const aggregate_return_fallthrough_update_switch_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_return_fallthrough_update_switch_pointer_field_load");
    try expectContains(aggregate_return_fallthrough_update_switch_body, "call { ptr, i32 } @returned_pointer_holder_via_fallthrough_update_switch(");
    try expectContains(aggregate_return_fallthrough_update_switch_body, "load atomic i32, ptr %");
    try expectContains(aggregate_return_fallthrough_update_switch_body, " unordered, align 4");
    try expectNotContains(aggregate_return_fallthrough_update_switch_body, "load i32, ptr %p.addr.");

    const aggregate_return_prefix_unknown_call_switch_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_return_prefix_unknown_call_switch_pointer_field_lowers_atomic");
    try expectContains(aggregate_return_prefix_unknown_call_switch_body, "call { ptr, i32 } @returned_pointer_holder_via_prefix_unknown_call_switch(");
    try expectContains(aggregate_return_prefix_unknown_call_switch_body, "load atomic i32, ptr %");
    try expectContains(aggregate_return_prefix_unknown_call_switch_body, " unordered, align 4");
    try expectNotContains(aggregate_return_prefix_unknown_call_switch_body, "load i32, ptr %");

    const aggregate_return_prefix_mixed_switch_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_return_prefix_mixed_switch_pointer_field_lowers_atomic");
    try expectContains(aggregate_return_prefix_mixed_switch_body, "call { ptr, i32 } @returned_pointer_holder_via_prefix_mixed_switch(");
    try expectContains(aggregate_return_prefix_mixed_switch_body, "load atomic i32, ptr %");
    try expectContains(aggregate_return_prefix_mixed_switch_body, " unordered, align 4");
    try expectNotContains(aggregate_return_prefix_mixed_switch_body, "load i32, ptr %");

    const aggregate_return_prereturn_literal_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_return_prereturn_literal_pointer_field_load");
    try expectContains(aggregate_return_prereturn_literal_body, "call { ptr, i32 } @returned_pointer_holder_after_side_effect()");
    try expectContains(aggregate_return_prereturn_literal_body, "load atomic i32, ptr %");
    try expectContains(aggregate_return_prereturn_literal_body, " unordered, align 4");
    try expectNotContains(aggregate_return_prereturn_literal_body, "load i32, ptr %p.addr.");

    const aggregate_return_prereturn_local_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_return_prereturn_local_pointer_field_load");
    try expectContains(aggregate_return_prereturn_local_body, "call { ptr, i32 } @returned_pointer_holder_via_local_after_noise()");
    try expectContains(aggregate_return_prereturn_local_body, "load atomic i32, ptr %");
    try expectContains(aggregate_return_prereturn_local_body, " unordered, align 4");
    try expectNotContains(aggregate_return_prereturn_local_body, "load i32, ptr %p.addr.");

    const aggregate_return_prereturn_reassigned_stack_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_return_prereturn_reassigned_stack_pointer_field_lowers_atomic");
    try expectContains(aggregate_return_prereturn_reassigned_stack_body, "call { ptr, i32 } @returned_pointer_holder_via_local_reassigned_stack_after_noise()");
    try expectContains(aggregate_return_prereturn_reassigned_stack_body, "load atomic i32, ptr %");
    try expectContains(aggregate_return_prereturn_reassigned_stack_body, " unordered, align 4");
    try expectNotContains(aggregate_return_prereturn_reassigned_stack_body, "load i32, ptr %");

    const aggregate_return_prereturn_unknown_call_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_return_prereturn_unknown_call_pointer_field_lowers_atomic");
    try expectContains(aggregate_return_prereturn_unknown_call_body, "call { ptr, i32 } @returned_pointer_holder_after_unknown_call()");
    try expectContains(aggregate_return_prereturn_unknown_call_body, "load atomic i32, ptr %");
    try expectContains(aggregate_return_prereturn_unknown_call_body, " unordered, align 4");
    try expectNotContains(aggregate_return_prereturn_unknown_call_body, "load i32, ptr %");

    const aggregate_exported_return_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_exported_return_pointer_field_lowers_atomic");
    try expectContains(aggregate_exported_return_body, "call ptr @exported_global_pointer()");
    try expectContains(aggregate_exported_return_body, "load atomic i32, ptr %");
    try expectContains(aggregate_exported_return_body, " unordered, align 4");
    try expectNotContains(aggregate_exported_return_body, "load i32, ptr %");

    const aggregate_return_array_dynamic_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_return_array_dynamic_index_pointer_element_load");
    try expectContains(aggregate_return_array_dynamic_body, "call { [2 x ptr], i32 } @returned_pointer_array_holder()");
    try expectContains(aggregate_return_array_dynamic_body, "load atomic i32, ptr %");
    try expectContains(aggregate_return_array_dynamic_body, " unordered, align 4");
    try expectNotContains(aggregate_return_array_dynamic_body, "load i32, ptr %p.addr.");

    const aggregate_return_array_local_dynamic_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_return_array_local_dynamic_index_pointer_element_load");
    try expectContains(aggregate_return_array_local_dynamic_body, "call { [2 x ptr], i32 } @returned_pointer_array_holder_via_local()");
    try expectContains(aggregate_return_array_local_dynamic_body, "load atomic i32, ptr %");
    try expectContains(aggregate_return_array_local_dynamic_body, " unordered, align 4");
    try expectNotContains(aggregate_return_array_local_dynamic_body, "load i32, ptr %p.addr.");

    const aggregate_array_global_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_array_global_pointer_element_load");
    try expectContains(aggregate_array_global_pointer_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_array_global_pointer_body, "load atomic i32, ptr %");
    try expectContains(aggregate_array_global_pointer_body, " unordered, align 4");
    try expectNotContains(aggregate_array_global_pointer_body, "load i32, ptr %p.addr.");

    const aggregate_array_assigned_global_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_array_assigned_global_pointer_element_load");
    try expectContains(aggregate_array_assigned_global_pointer_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_array_assigned_global_pointer_body, "load atomic i32, ptr %");
    try expectContains(aggregate_array_assigned_global_pointer_body, " unordered, align 4");
    try expectNotContains(aggregate_array_assigned_global_pointer_body, "load i32, ptr %p.addr.");

    const aggregate_array_stack_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_array_stack_pointer_element_lowers_atomic");
    try expectContains(aggregate_array_stack_pointer_body, "; mir pointer_provenance consumed fn=aggregate_array_stack_pointer_element_lowers_atomic subject=p provenance=local_storage reason=none");
    try expectContains(aggregate_array_stack_pointer_body, "load i32, ptr %");
    try expectNotContains(aggregate_array_stack_pointer_body, " atomic ");

    const aggregate_array_dynamic_index_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_array_dynamic_index_all_global_pointer_elements_load");
    try expectContains(aggregate_array_dynamic_index_body, "load atomic i32, ptr %");
    try expectContains(aggregate_array_dynamic_index_body, " unordered, align 4");
    try expectNotContains(aggregate_array_dynamic_index_body, "load i32, ptr %p.addr.");

    const aggregate_array_dynamic_index_assigned_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_array_dynamic_index_assigned_all_global_pointer_elements_load");
    try expectContains(aggregate_array_dynamic_index_assigned_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_array_dynamic_index_assigned_body, "load atomic i32, ptr %");
    try expectContains(aggregate_array_dynamic_index_assigned_body, " unordered, align 4");
    try expectNotContains(aggregate_array_dynamic_index_assigned_body, "load i32, ptr %p.addr.");

    const aggregate_array_dynamic_index_partial_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_array_dynamic_index_partial_pointer_elements_load");
    try expectContains(aggregate_array_dynamic_index_partial_body, "load atomic i32, ptr %");
    try expectContains(aggregate_array_dynamic_index_partial_body, " unordered, align 4");
    try expectNotContains(aggregate_array_dynamic_index_partial_body, "load i32, ptr %p.addr.");

    const aggregate_array_dynamic_index_all_local_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_array_dynamic_index_all_local_pointer_elements_stays_plain");
    try expectContains(aggregate_array_dynamic_index_all_local_body, "load i32, ptr %");
    try expectNotContains(aggregate_array_dynamic_index_all_local_body, " atomic ");

    const aggregate_array_dynamic_assignment_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_array_dynamic_assignment_clears_pointer_element_fact");
    try expectContains(aggregate_array_dynamic_assignment_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_array_dynamic_assignment_body, "load atomic i32, ptr %");
    try expectContains(aggregate_array_dynamic_assignment_body, " unordered, align 4");
    try expectNotContains(aggregate_array_dynamic_assignment_body, "load i32, ptr %");

    const aggregate_pointer_alias_array_global_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_array_global_pointer_element_load");
    try expectContains(aggregate_pointer_alias_array_global_pointer_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_pointer_alias_array_global_pointer_body, "load atomic i32, ptr %");
    try expectContains(aggregate_pointer_alias_array_global_pointer_body, " unordered, align 4");
    try expectNotContains(aggregate_pointer_alias_array_global_pointer_body, "load i32, ptr %p.addr.");

    const aggregate_pointer_alias_array_dynamic_index_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_array_dynamic_index_all_global_pointer_elements_load");
    try expectContains(aggregate_pointer_alias_array_dynamic_index_body, "load atomic i32, ptr %");
    try expectContains(aggregate_pointer_alias_array_dynamic_index_body, " unordered, align 4");
    try expectNotContains(aggregate_pointer_alias_array_dynamic_index_body, "load i32, ptr %p.addr.");

    const aggregate_pointer_alias_array_stack_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_array_stack_pointer_element_stays_plain");
    try expectContains(aggregate_pointer_alias_array_stack_pointer_body, "load i32, ptr %");
    try expectNotContains(aggregate_pointer_alias_array_stack_pointer_body, " atomic ");

    const aggregate_pointer_alias_array_dynamic_index_partial_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_array_dynamic_index_partial_pointer_elements_load");
    try expectContains(aggregate_pointer_alias_array_dynamic_index_partial_body, "load atomic i32, ptr %");
    try expectContains(aggregate_pointer_alias_array_dynamic_index_partial_body, " unordered, align 4");
    try expectNotContains(aggregate_pointer_alias_array_dynamic_index_partial_body, "load i32, ptr %p.addr.");

    const aggregate_pointer_alias_array_dynamic_index_all_local_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_array_dynamic_index_all_local_pointer_elements_stays_plain");
    try expectContains(aggregate_pointer_alias_array_dynamic_index_all_local_body, "load i32, ptr %");
    try expectNotContains(aggregate_pointer_alias_array_dynamic_index_all_local_body, " atomic ");

    const aggregate_pointer_alias_array_assignment_clears_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_array_assignment_clears_element_fact");
    try expectContains(aggregate_pointer_alias_array_assignment_clears_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_pointer_alias_array_assignment_clears_body, "load atomic i32, ptr %");
    try expectContains(aggregate_pointer_alias_array_assignment_clears_body, " unordered, align 4");
    try expectNotContains(aggregate_pointer_alias_array_assignment_clears_body, "load i32, ptr %");

    const aggregate_pointer_alias_array_dynamic_assignment_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_array_dynamic_assignment_clears_all_element_facts");
    try expectContains(aggregate_pointer_alias_array_dynamic_assignment_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_pointer_alias_array_dynamic_assignment_body, "load atomic i32, ptr %");
    try expectContains(aggregate_pointer_alias_array_dynamic_assignment_body, " unordered, align 4");
    try expectNotContains(aggregate_pointer_alias_array_dynamic_assignment_body, "load i32, ptr %");

    const aggregate_pointer_alias_array_assignment_global_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_array_assignment_establishes_element_fact");
    try expectContains(aggregate_pointer_alias_array_assignment_global_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_pointer_alias_array_assignment_global_body, "load atomic i32, ptr %");
    try expectContains(aggregate_pointer_alias_array_assignment_global_body, " unordered, align 4");
    try expectNotContains(aggregate_pointer_alias_array_assignment_global_body, "load i32, ptr %p.addr.");

    const aggregate_pointer_alias_array_dynamic_index_assigned_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_array_dynamic_index_assigned_all_global_pointer_elements_load");
    try expectContains(aggregate_pointer_alias_array_dynamic_index_assigned_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_pointer_alias_array_dynamic_index_assigned_body, "load atomic i32, ptr %");
    try expectContains(aggregate_pointer_alias_array_dynamic_index_assigned_body, " unordered, align 4");
    try expectNotContains(aggregate_pointer_alias_array_dynamic_index_assigned_body, "load i32, ptr %p.addr.");

    const aggregate_pointer_alias_array_dynamic_index_partially_assigned_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_array_dynamic_index_partially_assigned_load");
    try expectContains(aggregate_pointer_alias_array_dynamic_index_partially_assigned_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_pointer_alias_array_dynamic_index_partially_assigned_body, "load atomic i32, ptr %");
    try expectContains(aggregate_pointer_alias_array_dynamic_index_partially_assigned_body, " unordered, align 4");
    try expectNotContains(aggregate_pointer_alias_array_dynamic_index_partially_assigned_body, "load i32, ptr %p.addr.");

    const aggregate_pointer_alias_array_returned_unknown_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_array_returned_unknown_lowers_atomic");
    try expectContains(aggregate_pointer_alias_array_returned_unknown_body, "call ptr @external_pointer_array_holder()");
    try expectContains(aggregate_pointer_alias_array_returned_unknown_body, "load atomic i32, ptr %");
    try expectContains(aggregate_pointer_alias_array_returned_unknown_body, " unordered, align 4");
    try expectNotContains(aggregate_pointer_alias_array_returned_unknown_body, "load i32, ptr %");

    const aggregate_pointer_alias_array_reassigned_unknown_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_array_reassigned_unknown_lowers_atomic");
    try expectContains(aggregate_pointer_alias_array_reassigned_unknown_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_pointer_alias_array_reassigned_unknown_body, "call ptr @external_pointer_array_holder()");
    try expectContains(aggregate_pointer_alias_array_reassigned_unknown_body, "load atomic i32, ptr %");
    try expectContains(aggregate_pointer_alias_array_reassigned_unknown_body, " unordered, align 4");
    try expectNotContains(aggregate_pointer_alias_array_reassigned_unknown_body, "load i32, ptr %");

    const aggregate_slice_global_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_slice_global_pointer_element_load");
    try expectContains(aggregate_slice_global_pointer_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_slice_global_pointer_body, "load atomic i32, ptr %");
    try expectContains(aggregate_slice_global_pointer_body, " unordered, align 4");
    try expectNotContains(aggregate_slice_global_pointer_body, "load i32, ptr %p.addr.");

    const aggregate_pointer_alias_slice_global_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_slice_global_pointer_element_load");
    try expectContains(aggregate_pointer_alias_slice_global_pointer_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_pointer_alias_slice_global_pointer_body, "load atomic i32, ptr %");
    try expectContains(aggregate_pointer_alias_slice_global_pointer_body, " unordered, align 4");
    try expectNotContains(aggregate_pointer_alias_slice_global_pointer_body, "load i32, ptr %p.addr.");

    const aggregate_slice_stack_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_slice_stack_pointer_element_stays_plain");
    try expectContains(aggregate_slice_stack_pointer_body, "load i32, ptr %");
    try expectNotContains(aggregate_slice_stack_pointer_body, "load atomic i32");

    const aggregate_slice_partial_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_slice_partial_pointer_elements_load");
    try expectContains(aggregate_slice_partial_pointer_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_slice_partial_pointer_body, "load atomic i32, ptr %");
    try expectContains(aggregate_slice_partial_pointer_body, " unordered, align 4");
    try expectNotContains(aggregate_slice_partial_pointer_body, "load i32, ptr %p.addr.");

    const aggregate_pointer_alias_slice_partial_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_slice_partial_pointer_elements_load");
    try expectContains(aggregate_pointer_alias_slice_partial_pointer_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_pointer_alias_slice_partial_pointer_body, "load atomic i32, ptr %");
    try expectContains(aggregate_pointer_alias_slice_partial_pointer_body, " unordered, align 4");
    try expectNotContains(aggregate_pointer_alias_slice_partial_pointer_body, "load i32, ptr %p.addr.");

    const aggregate_slice_partial_constant_global_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_slice_partial_constant_global_element_load");
    try expectContains(aggregate_slice_partial_constant_global_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_slice_partial_constant_global_body, "load atomic i32, ptr %");
    try expectContains(aggregate_slice_partial_constant_global_body, " unordered, align 4");
    try expectNotContains(aggregate_slice_partial_constant_global_body, "load i32, ptr %p.addr.");

    const aggregate_slice_partial_constant_stack_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_slice_partial_constant_stack_element_stays_plain");
    try expectContains(aggregate_slice_partial_constant_stack_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_slice_partial_constant_stack_body, "load i32, ptr %");
    try expectNotContains(aggregate_slice_partial_constant_stack_body, "load atomic i32");

    const aggregate_slice_partial_range_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_slice_partial_range_pointer_elements_load");
    try expectContains(aggregate_slice_partial_range_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_slice_partial_range_body, "load atomic i32, ptr %");
    try expectContains(aggregate_slice_partial_range_body, " unordered, align 4");
    try expectNotContains(aggregate_slice_partial_range_body, "load i32, ptr %p.addr.");

    const aggregate_pointer_alias_slice_partial_range_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_slice_partial_range_pointer_elements_load");
    try expectContains(aggregate_pointer_alias_slice_partial_range_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_pointer_alias_slice_partial_range_body, "load atomic i32, ptr %");
    try expectContains(aggregate_pointer_alias_slice_partial_range_body, " unordered, align 4");
    try expectNotContains(aggregate_pointer_alias_slice_partial_range_body, "load i32, ptr %p.addr.");

    const aggregate_slice_partial_range_constant_global_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_slice_partial_range_constant_global_element_load");
    try expectContains(aggregate_slice_partial_range_constant_global_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_slice_partial_range_constant_global_body, "load atomic i32, ptr %");
    try expectContains(aggregate_slice_partial_range_constant_global_body, " unordered, align 4");
    try expectNotContains(aggregate_slice_partial_range_constant_global_body, "load i32, ptr %p.addr.");

    const aggregate_slice_partial_range_constant_stack_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_slice_partial_range_constant_stack_element_stays_plain");
    try expectContains(aggregate_slice_partial_range_constant_stack_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_slice_partial_range_constant_stack_body, "load i32, ptr %");
    try expectNotContains(aggregate_slice_partial_range_constant_stack_body, "load atomic i32");

    const aggregate_slice_partial_range_all_local_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_slice_partial_range_all_local_stays_plain");
    try expectContains(aggregate_slice_partial_range_all_local_body, "load i32, ptr %");
    try expectNotContains(aggregate_slice_partial_range_all_local_body, "load atomic i32");

    const aggregate_slice_dynamic_end_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_slice_dynamic_end_pointer_elements_load");
    try expectContains(aggregate_slice_dynamic_end_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_slice_dynamic_end_body, "load atomic i32, ptr %");
    try expectContains(aggregate_slice_dynamic_end_body, " unordered, align 4");
    try expectNotContains(aggregate_slice_dynamic_end_body, "load i32, ptr %p.addr.");

    const aggregate_pointer_alias_slice_dynamic_end_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_slice_dynamic_end_pointer_elements_load");
    try expectContains(aggregate_pointer_alias_slice_dynamic_end_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_pointer_alias_slice_dynamic_end_body, "load atomic i32, ptr %");
    try expectContains(aggregate_pointer_alias_slice_dynamic_end_body, " unordered, align 4");
    try expectNotContains(aggregate_pointer_alias_slice_dynamic_end_body, "load i32, ptr %p.addr.");

    const aggregate_slice_dynamic_start_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_slice_dynamic_start_pointer_elements_load");
    try expectContains(aggregate_slice_dynamic_start_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_slice_dynamic_start_body, "load atomic i32, ptr %");
    try expectContains(aggregate_slice_dynamic_start_body, " unordered, align 4");
    try expectNotContains(aggregate_slice_dynamic_start_body, "load i32, ptr %p.addr.");

    const aggregate_pointer_alias_slice_fully_dynamic_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_slice_fully_dynamic_pointer_elements_load");
    try expectContains(aggregate_pointer_alias_slice_fully_dynamic_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_pointer_alias_slice_fully_dynamic_body, "load atomic i32, ptr %");
    try expectContains(aggregate_pointer_alias_slice_fully_dynamic_body, " unordered, align 4");
    try expectNotContains(aggregate_pointer_alias_slice_fully_dynamic_body, "load i32, ptr %p.addr.");

    const aggregate_slice_backing_assignment_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_slice_backing_array_assignment_clears_fact");
    try expectContains(aggregate_slice_backing_assignment_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_slice_backing_assignment_body, "load atomic i32, ptr %");
    try expectContains(aggregate_slice_backing_assignment_body, " unordered, align 4");
    try expectNotContains(aggregate_slice_backing_assignment_body, "load i32, ptr %");

    const aggregate_pointer_alias_slice_backing_assignment_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_slice_backing_assignment_clears_fact");
    try expectContains(aggregate_pointer_alias_slice_backing_assignment_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_pointer_alias_slice_backing_assignment_body, "load atomic i32, ptr %");
    try expectContains(aggregate_pointer_alias_slice_backing_assignment_body, " unordered, align 4");
    try expectNotContains(aggregate_pointer_alias_slice_backing_assignment_body, "load i32, ptr %");

    const aggregate_slice_element_assignment_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_slice_element_assignment_clears_fact");
    try expectContains(aggregate_slice_element_assignment_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_slice_element_assignment_body, "load atomic i32, ptr %");
    try expectContains(aggregate_slice_element_assignment_body, " unordered, align 4");
    try expectNotContains(aggregate_slice_element_assignment_body, "load i32, ptr %");

    const array_global_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @array_global_pointer_element_load");
    try expectContains(array_global_pointer_body, "store ptr @shared_counter, ptr %");
    try expectContains(array_global_pointer_body, "; mir pointer_provenance consumed fn=array_global_pointer_element_load subject=ptrs element=0 provenance=global_storage reason=none");
    try expectContains(array_global_pointer_body, "load atomic i32, ptr %");
    try expectContains(array_global_pointer_body, " unordered, align 4");
    try expectNotContains(array_global_pointer_body, "load i32, ptr %p.addr.");

    const array_assigned_global_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @array_assigned_global_pointer_element_load");
    try expectContains(array_assigned_global_pointer_body, "store ptr @shared_counter, ptr %");
    try expectContains(array_assigned_global_pointer_body, "; mir pointer_provenance consumed fn=array_assigned_global_pointer_element_load subject=ptrs element=0 provenance=global_storage reason=reassignment");
    try expectContains(array_assigned_global_pointer_body, "load atomic i32, ptr %");
    try expectContains(array_assigned_global_pointer_body, " unordered, align 4");
    try expectNotContains(array_assigned_global_pointer_body, "load i32, ptr %p.addr.");

    const array_stack_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @array_stack_pointer_element_stays_plain");
    try expectContains(array_stack_pointer_body, "; mir pointer_provenance consumed fn=array_stack_pointer_element_stays_plain subject=ptrs element=0 provenance=local_storage reason=none");
    try expectContains(array_stack_pointer_body, "; mir pointer_provenance consumed fn=array_stack_pointer_element_stays_plain subject=p provenance=local_storage reason=none");
    try expectContains(array_stack_pointer_body, "load i32, ptr %");
    try expectNotContains(array_stack_pointer_body, " atomic ");

    const array_dynamic_index_body = try llvmFunctionBody(output.items, "define internal i32 @array_dynamic_index_all_global_pointer_elements_load");
    try expectContains(array_dynamic_index_body, "load atomic i32, ptr %");
    try expectContains(array_dynamic_index_body, " unordered, align 4");
    try expectNotContains(array_dynamic_index_body, "load i32, ptr %p.addr.");

    const array_dynamic_index_assigned_body = try llvmFunctionBody(output.items, "define internal i32 @array_dynamic_index_assigned_all_global_pointer_elements_load");
    try expectContains(array_dynamic_index_assigned_body, "store ptr @shared_counter, ptr %");
    try expectContains(array_dynamic_index_assigned_body, "load atomic i32, ptr %");
    try expectContains(array_dynamic_index_assigned_body, " unordered, align 4");
    try expectNotContains(array_dynamic_index_assigned_body, "load i32, ptr %p.addr.");

    const array_dynamic_index_partial_body = try llvmFunctionBody(output.items, "define internal i32 @array_dynamic_index_partial_pointer_elements_load");
    try expectContains(array_dynamic_index_partial_body, "load atomic i32, ptr %");
    try expectContains(array_dynamic_index_partial_body, " unordered, align 4");
    try expectNotContains(array_dynamic_index_partial_body, "load i32, ptr %p.addr.");

    const array_dynamic_index_all_local_body = try llvmFunctionBody(output.items, "define internal i32 @array_dynamic_index_all_local_pointer_elements_stays_plain");
    try expectContains(array_dynamic_index_all_local_body, "load i32, ptr %");
    try expectNotContains(array_dynamic_index_all_local_body, " atomic ");

    const array_dynamic_assignment_body = try llvmFunctionBody(output.items, "define internal i32 @array_dynamic_assignment_clears_pointer_element_fact");
    try expectContains(array_dynamic_assignment_body, "store ptr @shared_counter, ptr %");
    try expectContains(array_dynamic_assignment_body, "; mir pointer_provenance consumed fn=array_dynamic_assignment_clears_pointer_element_fact subject=ptrs provenance=unknown reason=dynamic_index_write");
    try expectContains(array_dynamic_assignment_body, "load atomic i32, ptr %");
    try expectContains(array_dynamic_assignment_body, " unordered, align 4");
    try expectNotContains(array_dynamic_assignment_body, "load i32, ptr %");

    const pointer_to_array_dynamic_index_body = try llvmFunctionBody(output.items, "define internal i32 @pointer_to_array_dynamic_index_all_global_pointer_elements_load");
    try expectContains(pointer_to_array_dynamic_index_body, "store ptr @shared_counter, ptr %");
    try expectContains(pointer_to_array_dynamic_index_body, "load atomic i32, ptr %");
    try expectContains(pointer_to_array_dynamic_index_body, " unordered, align 4");
    try expectNotContains(pointer_to_array_dynamic_index_body, "load i32, ptr %p.addr.");

    const pointer_to_array_stack_body = try llvmFunctionBody(output.items, "define internal i32 @pointer_to_array_stack_pointer_elements_stays_plain");
    try expectContains(pointer_to_array_stack_body, "load i32, ptr %");
    try expectNotContains(pointer_to_array_stack_body, " atomic ");

    const pointer_to_array_partial_body = try llvmFunctionBody(output.items, "define internal i32 @pointer_to_array_partial_pointer_elements_load");
    try expectContains(pointer_to_array_partial_body, "store ptr @shared_counter, ptr %");
    try expectContains(pointer_to_array_partial_body, "load atomic i32, ptr %");
    try expectContains(pointer_to_array_partial_body, " unordered, align 4");
    try expectNotContains(pointer_to_array_partial_body, "load i32, ptr %p.addr.");

    const pointer_to_array_reassigned_body = try llvmFunctionBody(output.items, "define internal i32 @pointer_to_array_reassigned_pointer_lowers_atomic");
    try expectContains(pointer_to_array_reassigned_body, "store ptr @shared_counter, ptr %");
    try expectContains(pointer_to_array_reassigned_body, "load atomic i32, ptr %");
    try expectContains(pointer_to_array_reassigned_body, " unordered, align 4");
    try expectNotContains(pointer_to_array_reassigned_body, "load i32, ptr %");

    const pointer_to_array_backing_write_body = try llvmFunctionBody(output.items, "define internal i32 @pointer_to_array_backing_array_write_clears_fact");
    try expectContains(pointer_to_array_backing_write_body, "store ptr @shared_counter, ptr %");
    try expectContains(pointer_to_array_backing_write_body, "load atomic i32, ptr %");
    try expectContains(pointer_to_array_backing_write_body, " unordered, align 4");
    try expectNotContains(pointer_to_array_backing_write_body, "load i32, ptr %");

    const slice_global_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @slice_global_pointer_element_load");
    try expectContains(slice_global_pointer_body, "store ptr @shared_counter, ptr %");
    try expectContains(slice_global_pointer_body, "load atomic i32, ptr %");
    try expectContains(slice_global_pointer_body, " unordered, align 4");
    try expectNotContains(slice_global_pointer_body, "load i32, ptr %p.addr.");

    const slice_assigned_global_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @slice_assigned_global_pointer_element_load");
    try expectContains(slice_assigned_global_pointer_body, "store ptr @shared_counter, ptr %");
    try expectContains(slice_assigned_global_pointer_body, "load atomic i32, ptr %");
    try expectContains(slice_assigned_global_pointer_body, " unordered, align 4");
    try expectNotContains(slice_assigned_global_pointer_body, "load i32, ptr %p.addr.");

    const slice_stack_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @slice_stack_pointer_element_stays_plain");
    try expectContains(slice_stack_pointer_body, "load i32, ptr %");
    try expectNotContains(slice_stack_pointer_body, "load atomic i32");

    const slice_partial_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @slice_partial_pointer_elements_load");
    try expectContains(slice_partial_pointer_body, "store ptr @shared_counter, ptr %");
    try expectContains(slice_partial_pointer_body, "load atomic i32, ptr %");
    try expectContains(slice_partial_pointer_body, " unordered, align 4");
    try expectNotContains(slice_partial_pointer_body, "load i32, ptr %p.addr.");

    const slice_partial_constant_global_body = try llvmFunctionBody(output.items, "define internal i32 @slice_partial_constant_global_element_load");
    try expectContains(slice_partial_constant_global_body, "store ptr @shared_counter, ptr %");
    try expectContains(slice_partial_constant_global_body, "load atomic i32, ptr %");
    try expectContains(slice_partial_constant_global_body, " unordered, align 4");
    try expectNotContains(slice_partial_constant_global_body, "load i32, ptr %p.addr.");

    const slice_partial_constant_stack_body = try llvmFunctionBody(output.items, "define internal i32 @slice_partial_constant_stack_element_stays_plain");
    try expectContains(slice_partial_constant_stack_body, "store ptr @shared_counter, ptr %");
    try expectContains(slice_partial_constant_stack_body, "load i32, ptr %");
    try expectNotContains(slice_partial_constant_stack_body, "load atomic i32");

    const slice_partial_range_body = try llvmFunctionBody(output.items, "define internal i32 @slice_partial_range_pointer_elements_load");
    try expectContains(slice_partial_range_body, "store ptr @shared_counter, ptr %");
    try expectContains(slice_partial_range_body, "load atomic i32, ptr %");
    try expectContains(slice_partial_range_body, " unordered, align 4");
    try expectNotContains(slice_partial_range_body, "load i32, ptr %p.addr.");

    const slice_partial_range_constant_global_body = try llvmFunctionBody(output.items, "define internal i32 @slice_partial_range_constant_global_element_load");
    try expectContains(slice_partial_range_constant_global_body, "store ptr @shared_counter, ptr %");
    try expectContains(slice_partial_range_constant_global_body, "load atomic i32, ptr %");
    try expectContains(slice_partial_range_constant_global_body, " unordered, align 4");
    try expectNotContains(slice_partial_range_constant_global_body, "load i32, ptr %p.addr.");

    const slice_partial_range_constant_stack_body = try llvmFunctionBody(output.items, "define internal i32 @slice_partial_range_constant_stack_element_stays_plain");
    try expectContains(slice_partial_range_constant_stack_body, "store ptr @shared_counter, ptr %");
    try expectContains(slice_partial_range_constant_stack_body, "load i32, ptr %");
    try expectNotContains(slice_partial_range_constant_stack_body, "load atomic i32");

    const slice_partial_range_all_local_body = try llvmFunctionBody(output.items, "define internal i32 @slice_partial_range_all_local_stays_plain");
    try expectContains(slice_partial_range_all_local_body, "load i32, ptr %");
    try expectNotContains(slice_partial_range_all_local_body, "load atomic i32");

    const slice_dynamic_end_partial_body = try llvmFunctionBody(output.items, "define internal i32 @slice_dynamic_end_partial_pointer_elements_load");
    try expectContains(slice_dynamic_end_partial_body, "store ptr @shared_counter, ptr %");
    try expectContains(slice_dynamic_end_partial_body, "load atomic i32, ptr %");
    try expectContains(slice_dynamic_end_partial_body, " unordered, align 4");
    try expectNotContains(slice_dynamic_end_partial_body, "load i32, ptr %p.addr.");

    const slice_dynamic_end_constant_global_body = try llvmFunctionBody(output.items, "define internal i32 @slice_dynamic_end_constant_global_element_load");
    try expectContains(slice_dynamic_end_constant_global_body, "store ptr @shared_counter, ptr %");
    try expectContains(slice_dynamic_end_constant_global_body, "load atomic i32, ptr %");
    try expectContains(slice_dynamic_end_constant_global_body, " unordered, align 4");
    try expectNotContains(slice_dynamic_end_constant_global_body, "load i32, ptr %p.addr.");

    const slice_dynamic_end_constant_stack_body = try llvmFunctionBody(output.items, "define internal i32 @slice_dynamic_end_constant_stack_element_stays_plain");
    try expectContains(slice_dynamic_end_constant_stack_body, "store ptr @shared_counter, ptr %");
    try expectContains(slice_dynamic_end_constant_stack_body, "load i32, ptr %");
    try expectNotContains(slice_dynamic_end_constant_stack_body, "load atomic i32");

    const slice_dynamic_end_all_local_body = try llvmFunctionBody(output.items, "define internal i32 @slice_dynamic_end_all_local_stays_plain");
    try expectContains(slice_dynamic_end_all_local_body, "load i32, ptr %");
    try expectNotContains(slice_dynamic_end_all_local_body, "load atomic i32");

    const slice_dynamic_start_body = try llvmFunctionBody(output.items, "define internal i32 @slice_dynamic_start_pointer_elements_load");
    try expectContains(slice_dynamic_start_body, "store ptr @shared_counter, ptr %");
    try expectContains(slice_dynamic_start_body, "load atomic i32, ptr %");
    try expectContains(slice_dynamic_start_body, " unordered, align 4");
    try expectNotContains(slice_dynamic_start_body, "load i32, ptr %p.addr.");

    const slice_dynamic_start_constant_body = try llvmFunctionBody(output.items, "define internal i32 @slice_dynamic_start_constant_index_is_conservative");
    try expectContains(slice_dynamic_start_constant_body, "store ptr @shared_counter, ptr %");
    try expectContains(slice_dynamic_start_constant_body, "load atomic i32, ptr %");
    try expectContains(slice_dynamic_start_constant_body, " unordered, align 4");
    try expectNotContains(slice_dynamic_start_constant_body, "load i32, ptr %p.addr.");

    const slice_dynamic_start_all_local_body = try llvmFunctionBody(output.items, "define internal i32 @slice_dynamic_start_all_local_stays_plain");
    try expectContains(slice_dynamic_start_all_local_body, "load i32, ptr %");
    try expectNotContains(slice_dynamic_start_all_local_body, "load atomic i32");

    const slice_fully_dynamic_body = try llvmFunctionBody(output.items, "define internal i32 @slice_fully_dynamic_pointer_elements_load");
    try expectContains(slice_fully_dynamic_body, "store ptr @shared_counter, ptr %");
    try expectContains(slice_fully_dynamic_body, "load atomic i32, ptr %");
    try expectContains(slice_fully_dynamic_body, " unordered, align 4");
    try expectNotContains(slice_fully_dynamic_body, "load i32, ptr %p.addr.");

    const slice_backing_assignment_body = try llvmFunctionBody(output.items, "define internal i32 @slice_backing_array_assignment_clears_fact");
    try expectContains(slice_backing_assignment_body, "store ptr @shared_counter, ptr %");
    try expectContains(slice_backing_assignment_body, "load atomic i32, ptr %");
    try expectContains(slice_backing_assignment_body, " unordered, align 4");
    try expectNotContains(slice_backing_assignment_body, "load i32, ptr %");

    const slice_backing_dynamic_assignment_body = try llvmFunctionBody(output.items, "define internal i32 @slice_backing_array_dynamic_assignment_clears_fact");
    try expectContains(slice_backing_dynamic_assignment_body, "store ptr @shared_counter, ptr %");
    try expectContains(slice_backing_dynamic_assignment_body, "load atomic i32, ptr %");
    try expectContains(slice_backing_dynamic_assignment_body, " unordered, align 4");
    try expectNotContains(slice_backing_dynamic_assignment_body, "load i32, ptr %");

    const slice_backing_whole_assignment_body = try llvmFunctionBody(output.items, "define internal i32 @slice_backing_array_whole_assignment_clears_fact");
    try expectContains(slice_backing_whole_assignment_body, "store ptr @shared_counter, ptr %");
    try expectContains(slice_backing_whole_assignment_body, "load atomic i32, ptr %");
    try expectContains(slice_backing_whole_assignment_body, " unordered, align 4");
    try expectNotContains(slice_backing_whole_assignment_body, "load i32, ptr %");

    const slice_element_assignment_body = try llvmFunctionBody(output.items, "define internal i32 @slice_element_assignment_clears_fact");
    try expectContains(slice_element_assignment_body, "store ptr @shared_counter, ptr %");
    try expectContains(slice_element_assignment_body, "load atomic i32, ptr %");
    try expectContains(slice_element_assignment_body, " unordered, align 4");
    try expectNotContains(slice_element_assignment_body, "load i32, ptr %");

    const slice_reassignment_body = try llvmFunctionBody(output.items, "define internal i32 @slice_reassignment_to_local_stays_plain");
    try expectContains(slice_reassignment_body, "store ptr @shared_counter, ptr %");
    try expectContains(slice_reassignment_body, "load i32, ptr %");
    try expectNotContains(slice_reassignment_body, "load atomic i32");

    const field_store_body = try llvmFunctionBody(output.items, "define internal void @possibly_racing_field_store");
    try expectContains(field_store_body, "store atomic i32 %x, ptr %");
    try expectContains(field_store_body, " unordered, align 4");
    try expectNotContains(field_store_body, "store i32 %x, ptr %");

    const field_load_body = try llvmFunctionBody(output.items, "define internal i32 @possibly_racing_field_load");
    try expectContains(field_load_body, "load atomic i32, ptr %");
    try expectContains(field_load_body, " unordered, align 4");
    try expectNotContains(field_load_body, "load i32, ptr %");

    const array_store_body = try llvmFunctionBody(output.items, "define internal void @possibly_racing_array_store");
    try expectContains(array_store_body, "store atomic i32 %value, ptr %");
    try expectContains(array_store_body, " unordered, align 4");
    try expectNotContains(array_store_body, "store i32 %value, ptr %");

    const array_load_body = try llvmFunctionBody(output.items, "define internal i32 @possibly_racing_array_load");
    try expectContains(array_load_body, "load atomic i32, ptr %");
    try expectContains(array_load_body, " unordered, align 4");
    try expectNotContains(array_load_body, "load i32, ptr %");
}

test "LLVM call-produced scalar pointer derefs lower race-tolerantly" {
    const source =
        \\extern fn external_pointer() -> *mut u32;
        \\
        \\fn call_produced_pointer_lowers_atomic() -> u32 {
        \\    return external_pointer().*;
        \\}
        \\
        \\fn call_produced_pointer_store_lowers_atomic(value: u32) -> void {
        \\    external_pointer().* = value;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_call_produced_pointer_deref.mc", source, &output);

    const load_body = try llvmFunctionBody(output.items, "define internal i32 @call_produced_pointer_lowers_atomic");
    try expectContains(load_body, "call ptr @external_pointer()");
    try expectContains(load_body, "load atomic i32, ptr %");
    try expectContains(load_body, " unordered, align 4");
    try expectNotContains(load_body, "load i32, ptr %");

    const store_body = try llvmFunctionBody(output.items, "define internal void @call_produced_pointer_store_lowers_atomic");
    try expectContains(store_body, "call ptr @external_pointer()");
    try expectContains(store_body, "store atomic i32 ");
    try expectContains(store_body, " unordered, align 4");
    try expectNotContains(store_body, "store i32 ");
}

test "LLVM pointer-member scalar access lowers race-tolerantly" {
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
        \\
        \\fn local_pointer_member_access_stays_plain() -> u32 {
        \\    var outer: Outer = .{ .inner = .{ .value = 1 } };
        \\    let p: *mut Outer = &outer;
        \\    p.inner.value = 2;
        \\    return p.inner.value;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_pointer_member_scalar_access.mc", source, &output);

    const load_body = try llvmFunctionBody(output.items, "define internal i32 @nested_pointer_member_load");
    try expectContains(load_body, "load atomic i32, ptr %");
    try expectContains(load_body, " unordered, align 4");
    try expectNotContains(load_body, "load i32, ptr %");

    const store_body = try llvmFunctionBody(output.items, "define internal void @nested_pointer_member_store");
    try expectContains(store_body, "store atomic i32 %x, ptr %");
    try expectContains(store_body, " unordered, align 4");
    try expectNotContains(store_body, "store i32 %x, ptr %");

    const call_load_body = try llvmFunctionBody(output.items, "define internal i32 @call_nested_pointer_member_load");
    try expectContains(call_load_body, "call ptr @external_outer()");
    try expectContains(call_load_body, "load atomic i32, ptr %");
    try expectContains(call_load_body, " unordered, align 4");
    try expectNotContains(call_load_body, "load i32, ptr %");

    const local_body = try llvmFunctionBody(output.items, "define internal i32 @local_pointer_member_access_stays_plain");
    try expectContains(local_body, "; mir pointer_provenance consumed fn=local_pointer_member_access_stays_plain subject=p provenance=local_storage reason=none");
    try expectContains(local_body, "store i32 2, ptr %");
    try expectContains(local_body, "load i32, ptr %");
    try expectNotContains(local_body, " atomic ");
}

test "LLVM pointer-member aggregate value copies lower recursively" {
    const source =
        \\struct Inner {
        \\    value: u32,
        \\}
        \\struct Middle {
        \\    inner: Inner,
        \\}
        \\struct Outer {
        \\    inner: Inner,
        \\}
        \\struct NestedOuter {
        \\    middle: Middle,
        \\}
        \\
        \\extern "C" fn external_outer() -> *mut Outer;
        \\extern "C" fn external_nested_outer() -> *mut NestedOuter;
        \\
        \\fn pointer_member_aggregate_load(p: *mut Outer) -> Inner {
        \\    return p.inner;
        \\}
        \\
        \\fn call_pointer_member_aggregate_load() -> Inner {
        \\    return external_outer().inner;
        \\}
        \\
        \\fn pointer_member_aggregate_init(p: *mut Outer) -> u32 {
        \\    let inner: Inner = p.inner;
        \\    return inner.value;
        \\}
        \\
        \\fn pointer_member_aggregate_store(p: *mut Outer, value: Inner) -> void {
        \\    p.inner = value;
        \\}
        \\
        \\fn call_pointer_member_aggregate_store(value: Inner) -> void {
        \\    external_outer().inner = value;
        \\}
        \\
        \\fn call_nested_pointer_member_aggregate_load() -> Inner {
        \\    return external_nested_outer().middle.inner;
        \\}
        \\
        \\fn call_nested_pointer_member_aggregate_store(value: Inner) -> void {
        \\    external_nested_outer().middle.inner = value;
        \\}
        \\
        \\fn local_pointer_member_aggregate_copy_stays_plain() -> u32 {
        \\    var outer: Outer = .{ .inner = .{ .value = 1 } };
        \\    let p: *mut Outer = &outer;
        \\    p.inner = .{ .value = 2 };
        \\    let inner: Inner = p.inner;
        \\    return inner.value;
        \\}
        \\
        \\fn local_nested_pointer_member_aggregate_copy_stays_plain() -> u32 {
        \\    var outer: NestedOuter = .{ .middle = .{ .inner = .{ .value = 1 } } };
        \\    let p: *mut NestedOuter = &outer;
        \\    let replacement: Inner = .{ .value = 2 };
        \\    p.middle.inner = replacement;
        \\    let inner: Inner = p.middle.inner;
        \\    return inner.value;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_pointer_member_aggregate_copy.mc", source, &output);

    const load_body = try llvmFunctionBody(output.items, "define internal { i32 } @pointer_member_aggregate_load");
    try expectContains(load_body, "load atomic i32, ptr %");
    try expectContains(load_body, "insertvalue { i32 } zeroinitializer, i32");
    try expectContains(load_body, " unordered, align 4");
    try expectNotContains(load_body, "load { i32 }, ptr %");

    const call_load_body = try llvmFunctionBody(output.items, "define internal { i32 } @call_pointer_member_aggregate_load");
    try expectContains(call_load_body, "call ptr @external_outer()");
    try expectContains(call_load_body, "load atomic i32, ptr %");
    try expectContains(call_load_body, "insertvalue { i32 } zeroinitializer, i32");
    try expectContains(call_load_body, " unordered, align 4");
    try expectNotContains(call_load_body, "load { i32 }, ptr %");

    const init_body = try llvmFunctionBody(output.items, "define internal i32 @pointer_member_aggregate_init");
    try expectContains(init_body, "load atomic i32, ptr %");
    try expectContains(init_body, "insertvalue { i32 } zeroinitializer, i32");
    try expectContains(init_body, " unordered, align 4");
    try expectNotContains(init_body, "load { i32 }, ptr %");

    const store_body = try llvmFunctionBody(output.items, "define internal void @pointer_member_aggregate_store");
    try expectContains(store_body, "extractvalue { i32 }");
    try expectContains(store_body, "store atomic i32 ");
    try expectContains(store_body, " unordered, align 4");
    try expectNotContains(store_body, "store { i32 } %t1, ptr %t0");

    const call_store_body = try llvmFunctionBody(output.items, "define internal void @call_pointer_member_aggregate_store");
    try expectContains(call_store_body, "call ptr @external_outer()");
    try expectContains(call_store_body, "extractvalue { i32 }");
    try expectContains(call_store_body, "store atomic i32 ");
    try expectContains(call_store_body, " unordered, align 4");

    const call_nested_load_body = try llvmFunctionBody(output.items, "define internal { i32 } @call_nested_pointer_member_aggregate_load");
    try expectContains(call_nested_load_body, "call ptr @external_nested_outer()");
    try expectContains(call_nested_load_body, "load atomic i32, ptr %");
    try expectContains(call_nested_load_body, "insertvalue { i32 } zeroinitializer, i32");
    try expectContains(call_nested_load_body, " unordered, align 4");
    try expectNotContains(call_nested_load_body, "load { i32 }, ptr %");

    const call_nested_store_body = try llvmFunctionBody(output.items, "define internal void @call_nested_pointer_member_aggregate_store");
    try expectContains(call_nested_store_body, "call ptr @external_nested_outer()");
    try expectContains(call_nested_store_body, "extractvalue { i32 }");
    try expectContains(call_nested_store_body, "store atomic i32 ");
    try expectContains(call_nested_store_body, " unordered, align 4");

    const local_body = try llvmFunctionBody(output.items, "define internal i32 @local_pointer_member_aggregate_copy_stays_plain");
    try expectContains(local_body, "; mir pointer_provenance consumed fn=local_pointer_member_aggregate_copy_stays_plain subject=p provenance=local_storage reason=none");
    try expectContains(local_body, "store { i32 } %");
    try expectContains(local_body, "load { i32 }, ptr %");
    try expectNotContains(local_body, " atomic ");

    const local_nested_body = try llvmFunctionBody(output.items, "define internal i32 @local_nested_pointer_member_aggregate_copy_stays_plain");
    try expectContains(local_nested_body, "; mir pointer_provenance consumed fn=local_nested_pointer_member_aggregate_copy_stays_plain subject=p provenance=local_storage reason=none");
    try expectContains(local_nested_body, "store { i32 } %");
    try expectContains(local_nested_body, "load { i32 }, ptr %");
    try expectNotContains(local_nested_body, " atomic ");
}

test "LLVM slice scalar index access lowers race-tolerantly" {
    const source =
        \\fn slice_scalar_load(xs: []mut u32, i: usize) -> u32 {
        \\    return xs[i];
        \\}
        \\
        \\fn slice_scalar_store(xs: []mut u32, i: usize, value: u32) -> void {
        \\    xs[i] = value;
        \\}
        \\
        \\fn slice_pointer_element_load(xs: []mut *mut u32, i: usize) -> *mut u32 {
        \\    return xs[i];
        \\}
        \\
        \\fn local_array_index_stays_plain(i: usize) -> u32 {
        \\    let xs: [4]u32 = .{ 1, 2, 3, 4 };
        \\    return xs[i];
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_slice_scalar_index_access.mc", source, &output);

    const load_body = try llvmFunctionBody(output.items, "define internal i32 @slice_scalar_load");
    try expectContains(load_body, "load atomic i32, ptr %");
    try expectContains(load_body, " unordered, align 4");
    try expectNotContains(load_body, "load i32, ptr %");

    const store_body = try llvmFunctionBody(output.items, "define internal void @slice_scalar_store");
    try expectContains(store_body, "store atomic i32 %value, ptr %");
    try expectContains(store_body, " unordered, align 4");
    try expectNotContains(store_body, "store i32 %value, ptr %");

    const pointer_load_body = try llvmFunctionBody(output.items, "define internal ptr @slice_pointer_element_load");
    try expectContains(pointer_load_body, "load atomic ptr, ptr %");
    try expectContains(pointer_load_body, " unordered, align 8");
    try expectNotContains(pointer_load_body, "load ptr, ptr %");

    const local_body = try llvmFunctionBody(output.items, "define internal i32 @local_array_index_stays_plain");
    try expectContains(local_body, "load i32, ptr %");
    try expectNotContains(local_body, " atomic ");
}

test "LLVM pointer-to-array scalar index access lowers race-tolerantly" {
    const source =
        \\fn pointer_array_load(pa: *mut [4]u32, i: usize) -> u32 {
        \\    return pa.*[i];
        \\}
        \\
        \\fn pointer_array_store(pa: *mut [4]u32, i: usize, value: u32) -> void {
        \\    pa.*[i] = value;
        \\}
        \\
        \\fn pointer_array_pointer_element_load(pa: *mut [4]*mut u32, i: usize) -> *mut u32 {
        \\    return pa.*[i];
        \\}
        \\
        \\fn local_pointer_array_load(i: usize) -> u32 {
        \\    var xs: [4]u32 = .{ 1, 2, 3, 4 };
        \\    let pa: *mut [4]u32 = &xs;
        \\    return pa.*[i];
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_pointer_array_index_access.mc", source, &output);

    const load_body = try llvmFunctionBody(output.items, "define internal i32 @pointer_array_load");
    try expectContains(load_body, "load atomic i32, ptr %");
    try expectContains(load_body, " unordered, align 4");
    try expectNotContains(load_body, "load i32, ptr %");

    const store_body = try llvmFunctionBody(output.items, "define internal void @pointer_array_store");
    try expectContains(store_body, "store atomic i32 %value, ptr %");
    try expectContains(store_body, " unordered, align 4");
    try expectNotContains(store_body, "store i32 %value, ptr %");

    const pointer_load_body = try llvmFunctionBody(output.items, "define internal ptr @pointer_array_pointer_element_load");
    try expectContains(pointer_load_body, "load atomic ptr, ptr %");
    try expectContains(pointer_load_body, " unordered, align 8");
    try expectNotContains(pointer_load_body, "load ptr, ptr %");

    const local_body = try llvmFunctionBody(output.items, "define internal i32 @local_pointer_array_load");
    try expectContains(local_body, "; mir pointer_provenance consumed fn=local_pointer_array_load subject=pa provenance=local_storage reason=none");
    try expectContains(local_body, "load i32, ptr %");
    try expectNotContains(local_body, " atomic ");
}

test "LLVM aggregate whole-element index access lowers recursively" {
    const source =
        \\struct Cell {
        \\    value: u32,
        \\}
        \\
        \\fn slice_cell_load(cells: []mut Cell, i: usize) -> Cell {
        \\    return cells[i];
        \\}
        \\
        \\fn slice_cell_store(cells: []mut Cell, i: usize, value: Cell) -> void {
        \\    cells[i] = value;
        \\}
        \\
        \\fn pointer_array_cell_load(pa: *mut [4]Cell, i: usize) -> Cell {
        \\    return pa.*[i];
        \\}
        \\
        \\fn pointer_array_cell_store(pa: *mut [4]Cell, i: usize, value: Cell) -> void {
        \\    pa.*[i] = value;
        \\}
        \\
        \\fn local_pointer_array_cell_load(i: usize) -> Cell {
        \\    var cells: [4]Cell = .{
        \\        .{ .value = 1 },
        \\        .{ .value = 2 },
        \\        .{ .value = 3 },
        \\        .{ .value = 4 },
        \\    };
        \\    let pa: *mut [4]Cell = &cells;
        \\    return pa.*[i];
        \\}
        \\
        \\fn local_pointer_array_cell_store(i: usize, value: Cell) -> u32 {
        \\    var cells: [4]Cell = .{
        \\        .{ .value = 1 },
        \\        .{ .value = 2 },
        \\        .{ .value = 3 },
        \\        .{ .value = 4 },
        \\    };
        \\    let pa: *mut [4]Cell = &cells;
        \\    pa.*[i] = value;
        \\    return cells[i].value;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_aggregate_whole_element_index_access.mc", source, &output);

    const slice_load_body = try llvmFunctionBody(output.items, "define internal { i32 } @slice_cell_load");
    try expectContains(slice_load_body, "load atomic i32, ptr %");
    try expectContains(slice_load_body, "insertvalue { i32 } zeroinitializer, i32");
    try expectContains(slice_load_body, " unordered, align 4");
    try expectNotContains(slice_load_body, "load { i32 }, ptr %");

    const slice_store_body = try llvmFunctionBody(output.items, "define internal void @slice_cell_store");
    try expectContains(slice_store_body, "extractvalue { i32 }");
    try expectContains(slice_store_body, "store atomic i32 ");
    try expectContains(slice_store_body, " unordered, align 4");
    try expectNotContains(slice_store_body, "store { i32 } %t5, ptr %t4");

    const pointer_load_body = try llvmFunctionBody(output.items, "define internal { i32 } @pointer_array_cell_load");
    try expectContains(pointer_load_body, "load atomic i32, ptr %");
    try expectContains(pointer_load_body, "insertvalue { i32 } zeroinitializer, i32");
    try expectContains(pointer_load_body, " unordered, align 4");
    try expectNotContains(pointer_load_body, "load { i32 }, ptr %");

    const pointer_store_body = try llvmFunctionBody(output.items, "define internal void @pointer_array_cell_store");
    try expectContains(pointer_store_body, "extractvalue { i32 }");
    try expectContains(pointer_store_body, "store atomic i32 ");
    try expectContains(pointer_store_body, " unordered, align 4");
    try expectNotContains(pointer_store_body, "store { i32 } %t2, ptr %t1");

    const local_body = try llvmFunctionBody(output.items, "define internal { i32 } @local_pointer_array_cell_load");
    try expectContains(local_body, "; mir pointer_provenance consumed fn=local_pointer_array_cell_load subject=pa provenance=local_storage reason=none");
    try expectContains(local_body, "load { i32 }, ptr %");
    try expectNotContains(local_body, " atomic ");

    const local_store_body = try llvmFunctionBody(output.items, "define internal i32 @local_pointer_array_cell_store");
    try expectContains(local_store_body, "; mir pointer_provenance consumed fn=local_pointer_array_cell_store subject=pa provenance=local_storage reason=none");
    try expectContains(local_store_body, "store { i32 }");
    try expectContains(local_store_body, "load i32, ptr %");
    try expectNotContains(local_store_body, " atomic ");
}

test "LLVM union aggregate whole-element index access fails closed" {
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
    var overlay_slice_load_output: std.ArrayList(u8) = .empty;
    defer overlay_slice_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_slice_union_element_load.mc", overlay_slice_load_source, &overlay_slice_load_output));

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
    var overlay_slice_store_output: std.ArrayList(u8) = .empty;
    defer overlay_slice_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_slice_union_element_store.mc", overlay_slice_store_source, &overlay_slice_store_output));

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
    var c_union_slice_load_output: std.ArrayList(u8) = .empty;
    defer c_union_slice_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_slice_c_union_element_load.mc", c_union_slice_load_source, &c_union_slice_load_output));

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
    var c_union_slice_store_output: std.ArrayList(u8) = .empty;
    defer c_union_slice_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_slice_c_union_element_store.mc", c_union_slice_store_source, &c_union_slice_store_output));

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
    var nested_overlay_slice_load_output: std.ArrayList(u8) = .empty;
    defer nested_overlay_slice_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_slice_nested_union_element_load.mc", nested_overlay_slice_load_source, &nested_overlay_slice_load_output));

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
    var nested_overlay_slice_store_output: std.ArrayList(u8) = .empty;
    defer nested_overlay_slice_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_slice_nested_union_element_store.mc", nested_overlay_slice_store_source, &nested_overlay_slice_store_output));

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
    var nested_c_union_slice_load_output: std.ArrayList(u8) = .empty;
    defer nested_c_union_slice_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_slice_nested_c_union_element_load.mc", nested_c_union_slice_load_source, &nested_c_union_slice_load_output));

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
    var nested_c_union_slice_store_output: std.ArrayList(u8) = .empty;
    defer nested_c_union_slice_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_slice_nested_c_union_element_store.mc", nested_c_union_slice_store_source, &nested_c_union_slice_store_output));

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
    var tagged_slice_load_output: std.ArrayList(u8) = .empty;
    defer tagged_slice_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_slice_tagged_union_element_load.mc", tagged_slice_load_source, &tagged_slice_load_output));

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
    var tagged_slice_store_output: std.ArrayList(u8) = .empty;
    defer tagged_slice_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_slice_tagged_union_element_store.mc", tagged_slice_store_source, &tagged_slice_store_output));

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
    var nested_tagged_slice_load_output: std.ArrayList(u8) = .empty;
    defer nested_tagged_slice_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_slice_nested_tagged_union_element_load.mc", nested_tagged_slice_load_source, &nested_tagged_slice_load_output));

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
    var nested_tagged_slice_store_output: std.ArrayList(u8) = .empty;
    defer nested_tagged_slice_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_slice_nested_tagged_union_element_store.mc", nested_tagged_slice_store_source, &nested_tagged_slice_store_output));

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
    var overlay_pointer_array_load_output: std.ArrayList(u8) = .empty;
    defer overlay_pointer_array_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_array_overlay_union_element_load.mc", overlay_pointer_array_load_source, &overlay_pointer_array_load_output));

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
    var overlay_pointer_array_store_output: std.ArrayList(u8) = .empty;
    defer overlay_pointer_array_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_array_overlay_union_element_store.mc", overlay_pointer_array_store_source, &overlay_pointer_array_store_output));

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
    var c_union_pointer_array_load_output: std.ArrayList(u8) = .empty;
    defer c_union_pointer_array_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_array_c_union_element_load.mc", c_union_pointer_array_load_source, &c_union_pointer_array_load_output));

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
    var c_union_pointer_array_store_output: std.ArrayList(u8) = .empty;
    defer c_union_pointer_array_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_array_c_union_element_store.mc", c_union_pointer_array_store_source, &c_union_pointer_array_store_output));

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
    var nested_overlay_pointer_array_load_output: std.ArrayList(u8) = .empty;
    defer nested_overlay_pointer_array_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_array_nested_overlay_union_element_load.mc", nested_overlay_pointer_array_load_source, &nested_overlay_pointer_array_load_output));

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
    var nested_overlay_pointer_array_store_output: std.ArrayList(u8) = .empty;
    defer nested_overlay_pointer_array_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_array_nested_overlay_union_element_store.mc", nested_overlay_pointer_array_store_source, &nested_overlay_pointer_array_store_output));

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
    var nested_c_union_pointer_array_load_output: std.ArrayList(u8) = .empty;
    defer nested_c_union_pointer_array_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_array_nested_c_union_element_load.mc", nested_c_union_pointer_array_load_source, &nested_c_union_pointer_array_load_output));

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
    var nested_c_union_pointer_array_store_output: std.ArrayList(u8) = .empty;
    defer nested_c_union_pointer_array_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_array_nested_c_union_element_store.mc", nested_c_union_pointer_array_store_source, &nested_c_union_pointer_array_store_output));

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
    var tagged_pointer_array_load_output: std.ArrayList(u8) = .empty;
    defer tagged_pointer_array_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_array_tagged_union_element_load.mc", tagged_pointer_array_load_source, &tagged_pointer_array_load_output));

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
    var tagged_pointer_array_store_output: std.ArrayList(u8) = .empty;
    defer tagged_pointer_array_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_array_tagged_union_element_store.mc", tagged_pointer_array_store_source, &tagged_pointer_array_store_output));

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
    var nested_tagged_pointer_array_load_output: std.ArrayList(u8) = .empty;
    defer nested_tagged_pointer_array_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_array_nested_tagged_union_element_load.mc", nested_tagged_pointer_array_load_source, &nested_tagged_pointer_array_load_output));

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
    var nested_tagged_pointer_array_store_output: std.ArrayList(u8) = .empty;
    defer nested_tagged_pointer_array_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_array_nested_tagged_union_element_store.mc", nested_tagged_pointer_array_store_source, &nested_tagged_pointer_array_store_output));
}

test "LLVM indexed aggregate scalar fields lower race-tolerantly" {
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
    try appendLlvmTest("llvm_indexed_member_scalar_access.mc", source, &output);

    const slice_load_body = try llvmFunctionBody(output.items, "define internal i32 @slice_member_load");
    try expectContains(slice_load_body, "load atomic i32, ptr %");
    try expectContains(slice_load_body, " unordered, align 4");
    try expectNotContains(slice_load_body, "load i32, ptr %");

    const slice_store_body = try llvmFunctionBody(output.items, "define internal void @slice_member_store");
    try expectContains(slice_store_body, "store atomic i32 %value, ptr %");
    try expectContains(slice_store_body, " unordered, align 4");
    try expectNotContains(slice_store_body, "store i32 %value, ptr %");

    const pointer_array_body = try llvmFunctionBody(output.items, "define internal i32 @pointer_array_member_load");
    try expectContains(pointer_array_body, "load atomic i32, ptr %");
    try expectContains(pointer_array_body, " unordered, align 4");
    try expectNotContains(pointer_array_body, "load i32, ptr %");

    const local_body = try llvmFunctionBody(output.items, "define internal i32 @local_array_member_load");
    try expectContains(local_body, "load i32, ptr %");
    try expectNotContains(local_body, " atomic ");

    const local_store_body = try llvmFunctionBody(output.items, "define internal i32 @local_array_member_store");
    try expectContains(local_store_body, "store i32 %value, ptr %");
    try expectContains(local_store_body, "load i32, ptr %");
    try expectNotContains(local_store_body, " atomic ");
}

test "LLVM nested indexed aggregate scalar member chains lower race-tolerantly" {
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
    try appendLlvmTest("llvm_nested_indexed_member_scalar_access.mc", source, &output);

    const slice_load_body = try llvmFunctionBody(output.items, "define internal i32 @slice_nested_load");
    try expectContains(slice_load_body, "load atomic i32, ptr %");
    try expectContains(slice_load_body, " unordered, align 4");
    try expectNotContains(slice_load_body, "load i32, ptr %");

    const slice_store_body = try llvmFunctionBody(output.items, "define internal void @slice_nested_store");
    try expectContains(slice_store_body, "store atomic i32 %value, ptr %");
    try expectContains(slice_store_body, " unordered, align 4");
    try expectNotContains(slice_store_body, "store i32 %value, ptr %");

    const pointer_array_load_body = try llvmFunctionBody(output.items, "define internal i32 @pointer_array_nested_load");
    try expectContains(pointer_array_load_body, "load atomic i32, ptr %");
    try expectContains(pointer_array_load_body, " unordered, align 4");
    try expectNotContains(pointer_array_load_body, "load i32, ptr %");

    const pointer_array_store_body = try llvmFunctionBody(output.items, "define internal void @pointer_array_nested_store");
    try expectContains(pointer_array_store_body, "store atomic i32 %value, ptr %");
    try expectContains(pointer_array_store_body, " unordered, align 4");
    try expectNotContains(pointer_array_store_body, "store i32 %value, ptr %");

    const local_body = try llvmFunctionBody(output.items, "define internal i32 @local_array_nested_load");
    try expectContains(local_body, "load i32, ptr %");
    try expectNotContains(local_body, " atomic ");

    const local_store_body = try llvmFunctionBody(output.items, "define internal i32 @local_array_nested_store");
    try expectContains(local_store_body, "store i32 %value, ptr %");
    try expectContains(local_store_body, "load i32, ptr %");
    try expectNotContains(local_store_body, " atomic ");
}

test "LLVM indexed aggregate field value copies lower recursively" {
    const source =
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
        \\
        \\fn slice_inner_store(cells: []mut Cell, i: usize, value: Inner) -> void {
        \\    cells[i].inner = value;
        \\}
        \\
        \\fn pointer_array_inner_load(pa: *mut [4]Cell, i: usize) -> Inner {
        \\    return pa.*[i].inner;
        \\}
        \\
        \\fn pointer_array_inner_store(pa: *mut [4]Cell, i: usize, value: Inner) -> void {
        \\    pa.*[i].inner = value;
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

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_indexed_aggregate_field_value_copy.mc", source, &output);

    const slice_load_body = try llvmFunctionBody(output.items, "define internal { i32 } @slice_inner_load");
    try expectContains(slice_load_body, "load atomic i32, ptr %");
    try expectContains(slice_load_body, "insertvalue { i32 } zeroinitializer, i32");
    try expectContains(slice_load_body, " unordered, align 4");
    try expectNotContains(slice_load_body, "load { i32 }, ptr %");

    const slice_store_body = try llvmFunctionBody(output.items, "define internal void @slice_inner_store");
    try expectContains(slice_store_body, "extractvalue { i32 }");
    try expectContains(slice_store_body, "store atomic i32 ");
    try expectContains(slice_store_body, " unordered, align 4");

    const pointer_array_load_body = try llvmFunctionBody(output.items, "define internal { i32 } @pointer_array_inner_load");
    try expectContains(pointer_array_load_body, "load atomic i32, ptr %");
    try expectContains(pointer_array_load_body, "insertvalue { i32 } zeroinitializer, i32");
    try expectContains(pointer_array_load_body, " unordered, align 4");
    try expectNotContains(pointer_array_load_body, "load { i32 }, ptr %");

    const pointer_array_store_body = try llvmFunctionBody(output.items, "define internal void @pointer_array_inner_store");
    try expectContains(pointer_array_store_body, "extractvalue { i32 }");
    try expectContains(pointer_array_store_body, "store atomic i32 ");
    try expectContains(pointer_array_store_body, " unordered, align 4");

    const local_body = try llvmFunctionBody(output.items, "define internal { i32 } @local_array_inner_load");
    try expectContains(local_body, "load { i32 }, ptr %");
    try expectNotContains(local_body, " atomic ");

    const local_store_body = try llvmFunctionBody(output.items, "define internal { i32 } @local_array_inner_store");
    try expectContains(local_store_body, "store { i32 }");
    try expectContains(local_store_body, "load { i32 }, ptr %");
    try expectNotContains(local_store_body, " atomic ");
}

test "LLVM union indexed aggregate field value copies fail closed" {
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
    var overlay_load_output: std.ArrayList(u8) = .empty;
    defer overlay_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_slice_union_field_load.mc", overlay_load_source, &overlay_load_output));

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
    var overlay_store_output: std.ArrayList(u8) = .empty;
    defer overlay_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_slice_union_field_store.mc", overlay_store_source, &overlay_store_output));

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
    var c_union_load_output: std.ArrayList(u8) = .empty;
    defer c_union_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_slice_c_union_field_load.mc", c_union_load_source, &c_union_load_output));

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
    var c_union_store_output: std.ArrayList(u8) = .empty;
    defer c_union_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_slice_c_union_field_store.mc", c_union_store_source, &c_union_store_output));

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
    var nested_overlay_load_output: std.ArrayList(u8) = .empty;
    defer nested_overlay_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_slice_nested_union_field_load.mc", nested_overlay_load_source, &nested_overlay_load_output));

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
    var nested_overlay_store_output: std.ArrayList(u8) = .empty;
    defer nested_overlay_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_slice_nested_union_field_store.mc", nested_overlay_store_source, &nested_overlay_store_output));

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
    var nested_c_union_load_output: std.ArrayList(u8) = .empty;
    defer nested_c_union_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_slice_nested_c_union_field_load.mc", nested_c_union_load_source, &nested_c_union_load_output));

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
    var nested_c_union_store_output: std.ArrayList(u8) = .empty;
    defer nested_c_union_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_slice_nested_c_union_field_store.mc", nested_c_union_store_source, &nested_c_union_store_output));

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
    var tagged_load_output: std.ArrayList(u8) = .empty;
    defer tagged_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_slice_tagged_union_field_load.mc", tagged_load_source, &tagged_load_output));

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
    var tagged_store_output: std.ArrayList(u8) = .empty;
    defer tagged_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_slice_tagged_union_field_store.mc", tagged_store_source, &tagged_store_output));

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
    var nested_tagged_load_output: std.ArrayList(u8) = .empty;
    defer nested_tagged_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_slice_nested_tagged_union_field_load.mc", nested_tagged_load_source, &nested_tagged_load_output));

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
    var nested_tagged_store_output: std.ArrayList(u8) = .empty;
    defer nested_tagged_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_slice_nested_tagged_union_field_store.mc", nested_tagged_store_source, &nested_tagged_store_output));
}

test "LLVM nested indexed aggregate field value copies lower recursively" {
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
    try appendLlvmTest("llvm_nested_indexed_aggregate_field_value_copy.mc", source, &output);

    const slice_load_body = try llvmFunctionBody(output.items, "define internal { i32 } @slice_leaf_load");
    try expectContains(slice_load_body, "load atomic i32, ptr %");
    try expectContains(slice_load_body, "insertvalue { i32 } zeroinitializer, i32");
    try expectContains(slice_load_body, " unordered, align 4");
    try expectNotContains(slice_load_body, "load { i32 }, ptr %");

    const slice_store_body = try llvmFunctionBody(output.items, "define internal void @slice_leaf_store");
    try expectContains(slice_store_body, "extractvalue { i32 }");
    try expectContains(slice_store_body, "store atomic i32 ");
    try expectContains(slice_store_body, " unordered, align 4");

    const pointer_array_load_body = try llvmFunctionBody(output.items, "define internal { i32 } @pointer_array_leaf_load");
    try expectContains(pointer_array_load_body, "load atomic i32, ptr %");
    try expectContains(pointer_array_load_body, "insertvalue { i32 } zeroinitializer, i32");
    try expectContains(pointer_array_load_body, " unordered, align 4");
    try expectNotContains(pointer_array_load_body, "load { i32 }, ptr %");

    const pointer_array_store_body = try llvmFunctionBody(output.items, "define internal void @pointer_array_leaf_store");
    try expectContains(pointer_array_store_body, "extractvalue { i32 }");
    try expectContains(pointer_array_store_body, "store atomic i32 ");
    try expectContains(pointer_array_store_body, " unordered, align 4");

    const local_body = try llvmFunctionBody(output.items, "define internal { i32 } @local_array_leaf_load");
    try expectContains(local_body, "load { i32 }, ptr %");
    try expectNotContains(local_body, " atomic ");

    const local_store_body = try llvmFunctionBody(output.items, "define internal { i32 } @local_array_leaf_store");
    try expectContains(local_store_body, "store { i32 }");
    try expectContains(local_store_body, "load { i32 }, ptr %");
    try expectNotContains(local_store_body, " atomic ");
}

test "LLVM direct pointer locals without MIR facts lower conservatively" {
    // With the facts stripped the pointers have no proven storage class in
    // either direction, so the spec I.13 conservative default applies: the
    // derefs lower to unordered atomics (they can no longer prove LOCAL).
    const source =
        \\global shared_counter: u32 = 0;
        \\
        \\fn direct_initializer_requires_mir_fact() -> u32 {
        \\    let p: *mut u32 = &shared_counter;
        \\    return p.*;
        \\}
        \\
        \\fn direct_assignment_requires_mir_fact() -> u32 {
        \\    var local: u32 = 1;
        \\    var p: *mut u32 = &local;
        \\    p = &shared_counter;
        \\    return p.*;
        \\}
        \\
        \\fn noalias_initializer_requires_mir_fact() -> u32 {
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        let p: *mut u32 = compiler.assume_noalias_unchecked(&shared_counter, 4);
        \\        return p.*;
        \\    }
        \\}
        \\
        \\fn noalias_assignment_requires_mir_fact() -> u32 {
        \\    var local: u32 = 1;
        \\    var p: *mut u32 = &local;
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        p = compiler.assume_noalias_unchecked(&shared_counter, 4);
        \\    }
        \\    return p.*;
        \\}
        \\
        \\fn noalias_local_requires_mir_fact() -> u32 {
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
    try appendLlvmTest("llvm_noalias_pointer_provenance.mc", source, &normal_output);

    const normal_noalias_initializer_body = try llvmFunctionBody(normal_output.items, "define internal i32 @noalias_initializer_requires_mir_fact");
    try expectContains(normal_noalias_initializer_body, "; mir pointer_provenance consumed fn=noalias_initializer_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectContains(normal_noalias_initializer_body, "load atomic i32, ptr %");
    try expectContains(normal_noalias_initializer_body, " unordered, align 4");

    const normal_noalias_assignment_body = try llvmFunctionBody(normal_output.items, "define internal i32 @noalias_assignment_requires_mir_fact");
    try expectContains(normal_noalias_assignment_body, "; mir pointer_provenance consumed fn=noalias_assignment_requires_mir_fact subject=p provenance=global_storage reason=reassignment");
    try expectContains(normal_noalias_assignment_body, "load atomic i32, ptr %");
    try expectContains(normal_noalias_assignment_body, " unordered, align 4");

    const normal_noalias_local_body = try llvmFunctionBody(normal_output.items, "define internal i32 @noalias_local_requires_mir_fact");
    try expectContains(normal_noalias_local_body, "; mir pointer_provenance consumed fn=noalias_local_requires_mir_fact subject=p provenance=local_storage reason=none");
    try expectContains(normal_noalias_local_body, "store i32 9, ptr %");
    try expectContains(normal_noalias_local_body, "load i32, ptr %");
    try expectNotContains(normal_noalias_local_body, " atomic ");

    const cleared = [_][]const u8{
        "direct_initializer_requires_mir_fact",
        "direct_assignment_requires_mir_fact",
        "noalias_initializer_requires_mir_fact",
        "noalias_assignment_requires_mir_fact",
        "noalias_local_requires_mir_fact",
    };

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFacts("llvm_missing_pointer_provenance.mc", source, &cleared, &output);

    const initializer_body = try llvmFunctionBody(output.items, "define internal i32 @direct_initializer_requires_mir_fact");
    try expectContains(initializer_body, "store ptr @shared_counter, ptr %p.addr.");
    try expectNotContains(initializer_body, "; mir pointer_provenance consumed");
    try expectContains(initializer_body, "load atomic i32, ptr %");
    try expectContains(initializer_body, " unordered, align 4");
    try expectNotContains(initializer_body, "load i32, ptr %");

    const assignment_body = try llvmFunctionBody(output.items, "define internal i32 @direct_assignment_requires_mir_fact");
    try expectContains(assignment_body, "store ptr @shared_counter, ptr %p.addr.");
    try expectNotContains(assignment_body, "; mir pointer_provenance consumed");
    try expectContains(assignment_body, "load atomic i32, ptr %");
    try expectContains(assignment_body, " unordered, align 4");
    try expectNotContains(assignment_body, "load i32, ptr %");

    const noalias_initializer_body = try llvmFunctionBody(output.items, "define internal i32 @noalias_initializer_requires_mir_fact");
    try expectNotContains(noalias_initializer_body, "; mir pointer_provenance consumed");
    try expectContains(noalias_initializer_body, "load atomic i32, ptr %");
    try expectContains(noalias_initializer_body, " unordered, align 4");
    try expectNotContains(noalias_initializer_body, "load i32, ptr %");

    const noalias_assignment_body = try llvmFunctionBody(output.items, "define internal i32 @noalias_assignment_requires_mir_fact");
    try expectNotContains(noalias_assignment_body, "; mir pointer_provenance consumed");
    try expectContains(noalias_assignment_body, "load atomic i32, ptr %");
    try expectContains(noalias_assignment_body, " unordered, align 4");
    try expectNotContains(noalias_assignment_body, "load i32, ptr %");

    const noalias_local_body = try llvmFunctionBody(output.items, "define internal i32 @noalias_local_requires_mir_fact");
    try expectNotContains(noalias_local_body, "; mir pointer_provenance consumed");
    try expectContains(noalias_local_body, "store atomic i32 9, ptr %");
    try expectContains(noalias_local_body, " unordered, align 4");
    try expectContains(noalias_local_body, "load atomic i32, ptr %");
    try expectNotContains(noalias_local_body, "load i32, ptr %");
}

test "LLVM pointer-local copies without MIR destination facts lower conservatively" {
    const source =
        \\global shared_counter: u32 = 0;
        \\
        \\fn pointer_copy_requires_mir_fact() -> u32 {
        \\    let p: *mut u32 = &shared_counter;
        \\    let q: *mut u32 = p;
        \\    return q.*;
        \\}
        \\
        \\fn pointer_copy_assignment_requires_mir_fact() -> u32 {
        \\    let p: *mut u32 = &shared_counter;
        \\    var q: *mut u32 = &shared_counter;
        \\    q = p;
        \\    return q.*;
        \\}
        \\
        \\fn noalias_pointer_copy_requires_mir_fact() -> u32 {
        \\    let p: *mut u32 = &shared_counter;
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        let q: *mut u32 = compiler.assume_noalias_unchecked(p, 4);
        \\        return q.*;
        \\    }
        \\}
        \\
        \\fn raw_many_copy_requires_mir_fact() -> u32 {
        \\    unsafe {
        \\        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        let q: [*]mut u32 = p;
        \\        return q.*;
        \\    }
        \\}
        \\
        \\fn raw_many_copy_assignment_requires_mir_fact() -> u32 {
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
    try appendLlvmTest("llvm_pointer_copy_provenance.mc", source, &normal_output);

    const normal_body = try llvmFunctionBody(normal_output.items, "define internal i32 @pointer_copy_requires_mir_fact");
    try expectContains(normal_body, "; mir pointer_provenance consumed fn=pointer_copy_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectContains(normal_body, "; mir pointer_provenance consumed fn=pointer_copy_requires_mir_fact subject=q provenance=global_storage reason=none");
    try expectContains(normal_body, "load atomic i32, ptr %");
    try expectContains(normal_body, " unordered, align 4");

    const normal_assignment_body = try llvmFunctionBody(normal_output.items, "define internal i32 @pointer_copy_assignment_requires_mir_fact");
    try expectContains(normal_assignment_body, "; mir pointer_provenance consumed fn=pointer_copy_assignment_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectContains(normal_assignment_body, "; mir pointer_provenance consumed fn=pointer_copy_assignment_requires_mir_fact subject=q provenance=global_storage reason=reassignment");
    try expectContains(normal_assignment_body, "load atomic i32, ptr %");
    try expectContains(normal_assignment_body, " unordered, align 4");

    const normal_noalias_copy_body = try llvmFunctionBody(normal_output.items, "define internal i32 @noalias_pointer_copy_requires_mir_fact");
    try expectContains(normal_noalias_copy_body, "; mir pointer_provenance consumed fn=noalias_pointer_copy_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectContains(normal_noalias_copy_body, "; mir pointer_provenance consumed fn=noalias_pointer_copy_requires_mir_fact subject=q provenance=global_storage reason=none");
    try expectContains(normal_noalias_copy_body, "load atomic i32, ptr %");
    try expectContains(normal_noalias_copy_body, " unordered, align 4");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_pointer_copy_missing_provenance.mc", source, "pointer_copy_requires_mir_fact", "q", &missing_output);

    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @pointer_copy_requires_mir_fact");
    try expectContains(missing_body, "; mir pointer_provenance consumed fn=pointer_copy_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectNotContains(missing_body, "; mir pointer_provenance consumed fn=pointer_copy_requires_mir_fact subject=q");
    try expectContains(missing_body, "load atomic i32, ptr %");
    try expectContains(missing_body, " unordered, align 4");
    try expectNotContains(missing_body, "load i32, ptr %");

    var missing_assignment_output: std.ArrayList(u8) = .empty;
    defer missing_assignment_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_pointer_copy_missing_provenance.mc", source, "pointer_copy_assignment_requires_mir_fact", "q", &missing_assignment_output);

    const missing_assignment_body = try llvmFunctionBody(missing_assignment_output.items, "define internal i32 @pointer_copy_assignment_requires_mir_fact");
    try expectContains(missing_assignment_body, "; mir pointer_provenance consumed fn=pointer_copy_assignment_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectNotContains(missing_assignment_body, "; mir pointer_provenance consumed fn=pointer_copy_assignment_requires_mir_fact subject=q");
    try expectContains(missing_assignment_body, "load atomic i32, ptr %");
    try expectContains(missing_assignment_body, " unordered, align 4");
    try expectNotContains(missing_assignment_body, "load i32, ptr %");

    var missing_noalias_copy_output: std.ArrayList(u8) = .empty;
    defer missing_noalias_copy_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_pointer_copy_missing_provenance.mc", source, "noalias_pointer_copy_requires_mir_fact", "q", &missing_noalias_copy_output);

    const missing_noalias_copy_body = try llvmFunctionBody(missing_noalias_copy_output.items, "define internal i32 @noalias_pointer_copy_requires_mir_fact");
    try expectContains(missing_noalias_copy_body, "; mir pointer_provenance consumed fn=noalias_pointer_copy_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectNotContains(missing_noalias_copy_body, "; mir pointer_provenance consumed fn=noalias_pointer_copy_requires_mir_fact subject=q");
    try expectContains(missing_noalias_copy_body, "load atomic i32, ptr %");
    try expectContains(missing_noalias_copy_body, " unordered, align 4");
    try expectNotContains(missing_noalias_copy_body, "load i32, ptr %");

    var missing_raw_output: std.ArrayList(u8) = .empty;
    defer missing_raw_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_pointer_copy_missing_provenance.mc", source, "raw_many_copy_requires_mir_fact", "q", &missing_raw_output);

    const missing_raw_body = try llvmFunctionBody(missing_raw_output.items, "define internal i32 @raw_many_copy_requires_mir_fact");
    try expectContains(missing_raw_body, "; mir pointer_provenance consumed fn=raw_many_copy_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectNotContains(missing_raw_body, "; mir pointer_provenance consumed fn=raw_many_copy_requires_mir_fact subject=q");
    try expectContains(missing_raw_body, "load atomic i32, ptr %");
    try expectContains(missing_raw_body, " unordered, align 4");
    try expectNotContains(missing_raw_body, "load i32, ptr %");

    var missing_raw_assignment_output: std.ArrayList(u8) = .empty;
    defer missing_raw_assignment_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_pointer_copy_missing_provenance.mc", source, "raw_many_copy_assignment_requires_mir_fact", "q", &missing_raw_assignment_output);

    const missing_raw_assignment_body = try llvmFunctionBody(missing_raw_assignment_output.items, "define internal i32 @raw_many_copy_assignment_requires_mir_fact");
    try expectContains(missing_raw_assignment_body, "; mir pointer_provenance consumed fn=raw_many_copy_assignment_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectNotContains(missing_raw_assignment_body, "; mir pointer_provenance consumed fn=raw_many_copy_assignment_requires_mir_fact subject=q");
    try expectContains(missing_raw_assignment_body, "load atomic i32, ptr %");
    try expectContains(missing_raw_assignment_body, " unordered, align 4");
    try expectNotContains(missing_raw_assignment_body, "load i32, ptr %");
}

test "LLVM raw-many zero direct local without MIR fact lowers conservatively" {
    const source =
        \\global shared_counter: u32 = 0;
        \\const ZERO_OFFSET: usize = 0;
        \\struct ZeroField { value: u8 }
        \\const REFLECT_ZERO_OFFSET: usize = field_offset<ZeroField>(.value);
        \\
        \\fn raw_many_zero_requires_mir_fact() -> u32 {
        \\    unsafe {
        \\        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        let q: [*]mut u32 = p.offset(0);
        \\        return q.*;
        \\    }
        \\}
        \\
        \\fn raw_many_zero_const_global_requires_mir_fact() -> u32 {
        \\    unsafe {
        \\        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        let q: [*]mut u32 = p.offset(ZERO_OFFSET);
        \\        return q.*;
        \\    }
        \\}
        \\
        \\fn raw_many_zero_reflect_requires_mir_fact() -> u32 {
        \\    unsafe {
        \\        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        let q: [*]mut u32 = p.offset(field_offset<ZeroField>(.value));
        \\        return q.*;
        \\    }
        \\}
        \\
        \\fn raw_many_zero_grouped_requires_mir_fact() -> u32 {
        \\    unsafe {
        \\        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        let q: [*]mut u32 = (p.offset(0));
        \\        return q.*;
        \\    }
        \\}
        \\
        \\fn raw_many_zero_casted_requires_mir_fact() -> u32 {
        \\    unsafe {
        \\        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        let q: [*]mut u32 = p.offset(0) as [*]mut u32;
        \\        return q.*;
        \\    }
        \\}
        \\
        \\fn raw_many_zero_grouped_store_requires_mir_fact() -> u32 {
        \\    unsafe {
        \\        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        var q: [*]mut u32 = (p.offset(0));
        \\        q.* = 9;
        \\        return q.*;
        \\    }
        \\}
        \\
        \\fn raw_many_zero_casted_store_requires_mir_fact() -> u32 {
        \\    unsafe {
        \\        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        var q: [*]mut u32 = p.offset(0) as [*]mut u32;
        \\        q.* = 9;
        \\        return q.*;
        \\    }
        \\}
        \\
        \\fn raw_many_zero_noalias_requires_mir_fact() -> u32 {
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
        \\fn raw_many_zero_assignment_requires_mir_fact() -> u32 {
        \\    unsafe {
        \\        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        var q: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        q = p.offset(0);
        \\        return q.*;
        \\    }
        \\}
        \\
        \\fn raw_many_zero_local_stays_plain() -> u32 {
        \\    unsafe {
        \\        var local: u32 = 7;
        \\        let p: [*]mut u32 = (&local) as [*]mut u32;
        \\        let q: [*]mut u32 = p.offset(0);
        \\        q.* = 9;
        \\        return q.*;
        \\    }
        \\}
    ;

    var normal_output: std.ArrayList(u8) = .empty;
    defer normal_output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_raw_many_zero_local_pointer_provenance.mc", source, &normal_output);

    const local_body = try llvmFunctionBody(normal_output.items, "define internal i32 @raw_many_zero_local_stays_plain");
    try expectContains(local_body, "; mir pointer_provenance consumed fn=raw_many_zero_local_stays_plain subject=p provenance=local_storage reason=none");
    try expectContains(local_body, "; mir pointer_provenance consumed fn=raw_many_zero_local_stays_plain subject=q provenance=local_storage reason=none");
    try expectContains(local_body, "store i32 9, ptr %");
    try expectContains(local_body, "load i32, ptr %");
    try expectNotContains(local_body, " atomic ");

    const const_global_body = try llvmFunctionBody(normal_output.items, "define internal i32 @raw_many_zero_const_global_requires_mir_fact");
    try expectContains(const_global_body, "; mir pointer_provenance consumed fn=raw_many_zero_const_global_requires_mir_fact subject=q provenance=global_storage reason=none");
    try expectContains(const_global_body, "load atomic i32, ptr %");
    try expectContains(const_global_body, " unordered, align 4");

    const reflect_body = try llvmFunctionBody(normal_output.items, "define internal i32 @raw_many_zero_reflect_requires_mir_fact");
    try expectContains(reflect_body, "; mir pointer_provenance consumed fn=raw_many_zero_reflect_requires_mir_fact subject=q provenance=global_storage reason=none");
    try expectContains(reflect_body, "load atomic i32, ptr %");
    try expectContains(reflect_body, " unordered, align 4");

    const grouped_body = try llvmFunctionBody(normal_output.items, "define internal i32 @raw_many_zero_grouped_requires_mir_fact");
    try expectContains(grouped_body, "; mir pointer_provenance consumed fn=raw_many_zero_grouped_requires_mir_fact subject=q provenance=global_storage reason=none");
    try expectContains(grouped_body, "load atomic i32, ptr %");
    try expectContains(grouped_body, " unordered, align 4");

    const casted_body = try llvmFunctionBody(normal_output.items, "define internal i32 @raw_many_zero_casted_requires_mir_fact");
    try expectContains(casted_body, "; mir pointer_provenance consumed fn=raw_many_zero_casted_requires_mir_fact subject=q provenance=global_storage reason=none");
    try expectContains(casted_body, "load atomic i32, ptr %");
    try expectContains(casted_body, " unordered, align 4");

    const grouped_store_body = try llvmFunctionBody(normal_output.items, "define internal i32 @raw_many_zero_grouped_store_requires_mir_fact");
    try expectContains(grouped_store_body, "; mir pointer_provenance consumed fn=raw_many_zero_grouped_store_requires_mir_fact subject=q provenance=global_storage reason=none");
    try expectContains(grouped_store_body, "store atomic i32 9, ptr %");
    try expectContains(grouped_store_body, " unordered, align 4");

    const casted_store_body = try llvmFunctionBody(normal_output.items, "define internal i32 @raw_many_zero_casted_store_requires_mir_fact");
    try expectContains(casted_store_body, "; mir pointer_provenance consumed fn=raw_many_zero_casted_store_requires_mir_fact subject=q provenance=global_storage reason=none");
    try expectContains(casted_store_body, "store atomic i32 9, ptr %");
    try expectContains(casted_store_body, " unordered, align 4");

    const noalias_body = try llvmFunctionBody(normal_output.items, "define internal i32 @raw_many_zero_noalias_requires_mir_fact");
    try expectContains(noalias_body, "; mir pointer_provenance consumed fn=raw_many_zero_noalias_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectContains(noalias_body, "; mir pointer_provenance consumed fn=raw_many_zero_noalias_requires_mir_fact subject=q provenance=global_storage reason=none");
    try expectContains(noalias_body, "load atomic i32, ptr %");
    try expectContains(noalias_body, " unordered, align 4");

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_raw_many_zero_missing_pointer_provenance.mc", source, "raw_many_zero_requires_mir_fact", "q", &output);

    const body = try llvmFunctionBody(output.items, "define internal i32 @raw_many_zero_requires_mir_fact");
    try expectContains(body, "; mir pointer_provenance consumed fn=raw_many_zero_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectNotContains(body, "; mir pointer_provenance consumed fn=raw_many_zero_requires_mir_fact subject=q");
    try expectContains(body, "getelementptr i32, ptr %");
    try expectContains(body, ", i64 0");
    try expectContains(body, "load atomic i32, ptr %");
    try expectContains(body, " unordered, align 4");
    try expectNotContains(body, "load i32, ptr %");

    var const_global_missing_output: std.ArrayList(u8) = .empty;
    defer const_global_missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_raw_many_zero_const_global_missing_pointer_provenance.mc", source, "raw_many_zero_const_global_requires_mir_fact", "q", &const_global_missing_output);

    const const_global_missing_body = try llvmFunctionBody(const_global_missing_output.items, "define internal i32 @raw_many_zero_const_global_requires_mir_fact");
    try expectContains(const_global_missing_body, "; mir pointer_provenance consumed fn=raw_many_zero_const_global_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectNotContains(const_global_missing_body, "; mir pointer_provenance consumed fn=raw_many_zero_const_global_requires_mir_fact subject=q");
    try expectContains(const_global_missing_body, "load atomic i32, ptr %");
    try expectContains(const_global_missing_body, " unordered, align 4");
    try expectNotContains(const_global_missing_body, "load i32, ptr %");

    var reflect_missing_output: std.ArrayList(u8) = .empty;
    defer reflect_missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_raw_many_zero_reflect_missing_pointer_provenance.mc", source, "raw_many_zero_reflect_requires_mir_fact", "q", &reflect_missing_output);

    const reflect_missing_body = try llvmFunctionBody(reflect_missing_output.items, "define internal i32 @raw_many_zero_reflect_requires_mir_fact");
    try expectContains(reflect_missing_body, "; mir pointer_provenance consumed fn=raw_many_zero_reflect_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectNotContains(reflect_missing_body, "; mir pointer_provenance consumed fn=raw_many_zero_reflect_requires_mir_fact subject=q");
    try expectContains(reflect_missing_body, "load atomic i32, ptr %");
    try expectContains(reflect_missing_body, " unordered, align 4");
    try expectNotContains(reflect_missing_body, "load i32, ptr %");

    var grouped_missing_output: std.ArrayList(u8) = .empty;
    defer grouped_missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_raw_many_zero_grouped_missing_pointer_provenance.mc", source, "raw_many_zero_grouped_requires_mir_fact", "q", &grouped_missing_output);

    const grouped_missing_body = try llvmFunctionBody(grouped_missing_output.items, "define internal i32 @raw_many_zero_grouped_requires_mir_fact");
    try expectContains(grouped_missing_body, "; mir pointer_provenance consumed fn=raw_many_zero_grouped_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectNotContains(grouped_missing_body, "; mir pointer_provenance consumed fn=raw_many_zero_grouped_requires_mir_fact subject=q");
    try expectContains(grouped_missing_body, "load atomic i32, ptr %");
    try expectContains(grouped_missing_body, " unordered, align 4");
    try expectNotContains(grouped_missing_body, "load i32, ptr %");

    var casted_missing_output: std.ArrayList(u8) = .empty;
    defer casted_missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_raw_many_zero_casted_missing_pointer_provenance.mc", source, "raw_many_zero_casted_requires_mir_fact", "q", &casted_missing_output);

    const casted_missing_body = try llvmFunctionBody(casted_missing_output.items, "define internal i32 @raw_many_zero_casted_requires_mir_fact");
    try expectContains(casted_missing_body, "; mir pointer_provenance consumed fn=raw_many_zero_casted_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectNotContains(casted_missing_body, "; mir pointer_provenance consumed fn=raw_many_zero_casted_requires_mir_fact subject=q");
    try expectContains(casted_missing_body, "load atomic i32, ptr %");
    try expectContains(casted_missing_body, " unordered, align 4");
    try expectNotContains(casted_missing_body, "load i32, ptr %");

    var grouped_store_missing_output: std.ArrayList(u8) = .empty;
    defer grouped_store_missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_raw_many_zero_grouped_store_missing_pointer_provenance.mc", source, "raw_many_zero_grouped_store_requires_mir_fact", "q", &grouped_store_missing_output);

    const grouped_store_missing_body = try llvmFunctionBody(grouped_store_missing_output.items, "define internal i32 @raw_many_zero_grouped_store_requires_mir_fact");
    try expectContains(grouped_store_missing_body, "; mir pointer_provenance consumed fn=raw_many_zero_grouped_store_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectNotContains(grouped_store_missing_body, "; mir pointer_provenance consumed fn=raw_many_zero_grouped_store_requires_mir_fact subject=q");
    try expectContains(grouped_store_missing_body, "store atomic i32 9, ptr %");
    try expectContains(grouped_store_missing_body, " unordered, align 4");
    try expectNotContains(grouped_store_missing_body, "store i32 9, ptr %");

    var casted_store_missing_output: std.ArrayList(u8) = .empty;
    defer casted_store_missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_raw_many_zero_casted_store_missing_pointer_provenance.mc", source, "raw_many_zero_casted_store_requires_mir_fact", "q", &casted_store_missing_output);

    const casted_store_missing_body = try llvmFunctionBody(casted_store_missing_output.items, "define internal i32 @raw_many_zero_casted_store_requires_mir_fact");
    try expectContains(casted_store_missing_body, "; mir pointer_provenance consumed fn=raw_many_zero_casted_store_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectNotContains(casted_store_missing_body, "; mir pointer_provenance consumed fn=raw_many_zero_casted_store_requires_mir_fact subject=q");
    try expectContains(casted_store_missing_body, "store atomic i32 9, ptr %");
    try expectContains(casted_store_missing_body, " unordered, align 4");
    try expectNotContains(casted_store_missing_body, "store i32 9, ptr %");

    var noalias_missing_output: std.ArrayList(u8) = .empty;
    defer noalias_missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_raw_many_zero_noalias_missing_pointer_provenance.mc", source, "raw_many_zero_noalias_requires_mir_fact", "q", &noalias_missing_output);

    const noalias_missing_body = try llvmFunctionBody(noalias_missing_output.items, "define internal i32 @raw_many_zero_noalias_requires_mir_fact");
    try expectContains(noalias_missing_body, "; mir pointer_provenance consumed fn=raw_many_zero_noalias_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectNotContains(noalias_missing_body, "; mir pointer_provenance consumed fn=raw_many_zero_noalias_requires_mir_fact subject=q");
    try expectContains(noalias_missing_body, "load atomic i32, ptr %");
    try expectContains(noalias_missing_body, " unordered, align 4");
    try expectNotContains(noalias_missing_body, "load i32, ptr %");

    var assignment_output: std.ArrayList(u8) = .empty;
    defer assignment_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_raw_many_zero_missing_pointer_provenance.mc", source, "raw_many_zero_assignment_requires_mir_fact", "q", &assignment_output);

    const assignment_body = try llvmFunctionBody(assignment_output.items, "define internal i32 @raw_many_zero_assignment_requires_mir_fact");
    try expectContains(assignment_body, "; mir pointer_provenance consumed fn=raw_many_zero_assignment_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectNotContains(assignment_body, "; mir pointer_provenance consumed fn=raw_many_zero_assignment_requires_mir_fact subject=q");
    try expectContains(assignment_body, "getelementptr i32, ptr %");
    try expectContains(assignment_body, ", i64 0");
    try expectContains(assignment_body, "load atomic i32, ptr %");
    try expectContains(assignment_body, " unordered, align 4");
    try expectNotContains(assignment_body, "load i32, ptr %");
}

test "LLVM fixed pointer-array element reads without MIR destination fact lower conservatively" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct ZeroField { value: u8 }
        \\const REFLECT_INDEX: usize = field_offset<ZeroField>(.value);
        \\
        \\fn pointer_array_element_read_requires_mir_fact() -> u32 {
        \\    let ptrs: [2]*mut u32 = .{ &shared_counter, &shared_counter };
        \\    let p: *mut u32 = ptrs[0];
        \\    return p.*;
        \\}
        \\
        \\fn pointer_array_element_reflect_read_requires_mir_fact() -> u32 {
        \\    let ptrs: [2]*mut u32 = .{ &shared_counter, &shared_counter };
        \\    let p: *mut u32 = ptrs[field_offset<ZeroField>(.value)];
        \\    return p.*;
        \\}
        \\
        \\fn pointer_array_element_noalias_read_requires_mir_fact() -> u32 {
        \\    let ptrs: [2]*mut u32 = .{ &shared_counter, &shared_counter };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        let p: *mut u32 = compiler.assume_noalias_unchecked(ptrs[0], 4);
        \\        return p.*;
        \\    }
        \\}
        \\
        \\fn pointer_array_element_cast_noalias_read_requires_mir_fact() -> u32 {
        \\    let ptrs: [2]*mut u32 = .{ &shared_counter, &shared_counter };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        let p: *mut u32 = compiler.assume_noalias_unchecked(ptrs[0], 4) as *mut u32;
        \\        return p.*;
        \\    }
        \\}
        \\
        \\fn pointer_array_element_assignment_requires_mir_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var ptrs: [2]*mut u32 = .{ &local, &local };
        \\    ptrs[0] = &shared_counter;
        \\    var p: *mut u32 = &local;
        \\    p = ptrs[0];
        \\    return p.*;
        \\}
        \\
        \\fn pointer_array_element_scoped_direct_deref_lowers_atomic() -> u32 {
        \\    var local: u32 = 0;
        \\    var ptrs: [2]*mut u32 = .{ &local, &local };
        \\    unsafe {
        \\        ptrs[0] = &shared_counter;
        \\    }
        \\    return ptrs[0].*;
        \\}
        \\
        \\fn pointer_array_element_pointer_copy_direct_deref_requires_mir_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var ptrs: [2]*mut u32 = .{ &local, &local };
        \\    let gp: *mut u32 = &shared_counter;
        \\    ptrs[0] = gp;
        \\    return ptrs[0].*;
        \\}
        \\
        \\fn pointer_array_element_local_pointer_copy_direct_deref_requires_mir_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var other: u32 = 0;
        \\    var ptrs: [2]*mut u32 = .{ &other, &other };
        \\    let lp: *mut u32 = &local;
        \\    ptrs[0] = lp;
        \\    return ptrs[0].*;
        \\}
    ;

    var normal_output: std.ArrayList(u8) = .empty;
    defer normal_output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_pointer_array_element_provenance.mc", source, &normal_output);

    const normal_body = try llvmFunctionBody(normal_output.items, "define internal i32 @pointer_array_element_read_requires_mir_fact");
    try expectContains(normal_body, "; mir pointer_provenance consumed fn=pointer_array_element_read_requires_mir_fact subject=ptrs element=0 provenance=global_storage reason=none");
    try expectContains(normal_body, "; mir pointer_provenance consumed fn=pointer_array_element_read_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectContains(normal_body, "load atomic i32, ptr %");
    try expectContains(normal_body, " unordered, align 4");

    const normal_reflect_body = try llvmFunctionBody(normal_output.items, "define internal i32 @pointer_array_element_reflect_read_requires_mir_fact");
    try expectContains(normal_reflect_body, "; mir pointer_provenance consumed fn=pointer_array_element_reflect_read_requires_mir_fact subject=ptrs element=0 provenance=global_storage reason=none");
    try expectContains(normal_reflect_body, "; mir pointer_provenance consumed fn=pointer_array_element_reflect_read_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectContains(normal_reflect_body, "load atomic i32, ptr %");
    try expectContains(normal_reflect_body, " unordered, align 4");

    const normal_noalias_body = try llvmFunctionBody(normal_output.items, "define internal i32 @pointer_array_element_noalias_read_requires_mir_fact");
    try expectContains(normal_noalias_body, "; mir pointer_provenance consumed fn=pointer_array_element_noalias_read_requires_mir_fact subject=ptrs element=0 provenance=global_storage reason=none");
    try expectContains(normal_noalias_body, "; mir pointer_provenance consumed fn=pointer_array_element_noalias_read_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectContains(normal_noalias_body, "load atomic i32, ptr %");
    try expectContains(normal_noalias_body, " unordered, align 4");

    const normal_cast_noalias_body = try llvmFunctionBody(normal_output.items, "define internal i32 @pointer_array_element_cast_noalias_read_requires_mir_fact");
    try expectContains(normal_cast_noalias_body, "; mir pointer_provenance consumed fn=pointer_array_element_cast_noalias_read_requires_mir_fact subject=ptrs element=0 provenance=global_storage reason=none");
    try expectContains(normal_cast_noalias_body, "; mir pointer_provenance consumed fn=pointer_array_element_cast_noalias_read_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectContains(normal_cast_noalias_body, "load atomic i32, ptr %");
    try expectContains(normal_cast_noalias_body, " unordered, align 4");

    const normal_assignment_body = try llvmFunctionBody(normal_output.items, "define internal i32 @pointer_array_element_assignment_requires_mir_fact");
    try expectContains(normal_assignment_body, "; mir pointer_provenance consumed fn=pointer_array_element_assignment_requires_mir_fact subject=ptrs element=0 provenance=global_storage reason=reassignment");
    try expectContains(normal_assignment_body, "; mir pointer_provenance consumed fn=pointer_array_element_assignment_requires_mir_fact subject=p provenance=global_storage reason=reassignment");
    try expectContains(normal_assignment_body, "load atomic i32, ptr %");
    try expectContains(normal_assignment_body, " unordered, align 4");

    const normal_scoped_direct_body = try llvmFunctionBody(normal_output.items, "define internal i32 @pointer_array_element_scoped_direct_deref_lowers_atomic");
    try expectContains(normal_scoped_direct_body, "load atomic i32, ptr %");
    try expectContains(normal_scoped_direct_body, " unordered, align 4");
    try expectNotContains(normal_scoped_direct_body, "load i32, ptr %");

    const normal_pointer_copy_direct_body = try llvmFunctionBody(normal_output.items, "define internal i32 @pointer_array_element_pointer_copy_direct_deref_requires_mir_fact");
    try expectContains(normal_pointer_copy_direct_body, "; mir pointer_provenance consumed fn=pointer_array_element_pointer_copy_direct_deref_requires_mir_fact subject=gp provenance=global_storage reason=none");
    try expectContains(normal_pointer_copy_direct_body, "; mir pointer_provenance consumed fn=pointer_array_element_pointer_copy_direct_deref_requires_mir_fact subject=ptrs element=0 provenance=global_storage reason=reassignment");
    try expectContains(normal_pointer_copy_direct_body, "load atomic i32, ptr %");
    try expectContains(normal_pointer_copy_direct_body, " unordered, align 4");
    try expectNotContains(normal_pointer_copy_direct_body, "load i32, ptr %");

    const normal_local_pointer_copy_direct_body = try llvmFunctionBody(normal_output.items, "define internal i32 @pointer_array_element_local_pointer_copy_direct_deref_requires_mir_fact");
    try expectContains(normal_local_pointer_copy_direct_body, "; mir pointer_provenance consumed fn=pointer_array_element_local_pointer_copy_direct_deref_requires_mir_fact subject=lp provenance=local_storage reason=none");
    try expectContains(normal_local_pointer_copy_direct_body, "; mir pointer_provenance consumed fn=pointer_array_element_local_pointer_copy_direct_deref_requires_mir_fact subject=ptrs element=0 provenance=local_storage reason=reassignment");
    try expectNotContains(normal_local_pointer_copy_direct_body, "load atomic i32, ptr %");
    try expectContains(normal_local_pointer_copy_direct_body, "load i32, ptr %");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_pointer_array_element_missing_provenance.mc", source, "pointer_array_element_read_requires_mir_fact", "p", &missing_output);

    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @pointer_array_element_read_requires_mir_fact");
    try expectContains(missing_body, "; mir pointer_provenance consumed fn=pointer_array_element_read_requires_mir_fact subject=ptrs element=0 provenance=global_storage reason=none");
    try expectNotContains(missing_body, "; mir pointer_provenance consumed fn=pointer_array_element_read_requires_mir_fact subject=p provenance");
    try expectContains(missing_body, "load atomic i32, ptr %");
    try expectContains(missing_body, " unordered, align 4");
    try expectNotContains(missing_body, "load i32, ptr %");

    var missing_reflect_output: std.ArrayList(u8) = .empty;
    defer missing_reflect_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_pointer_array_element_reflect_missing_provenance.mc", source, "pointer_array_element_reflect_read_requires_mir_fact", "p", &missing_reflect_output);

    const missing_reflect_body = try llvmFunctionBody(missing_reflect_output.items, "define internal i32 @pointer_array_element_reflect_read_requires_mir_fact");
    try expectContains(missing_reflect_body, "; mir pointer_provenance consumed fn=pointer_array_element_reflect_read_requires_mir_fact subject=ptrs element=0 provenance=global_storage reason=none");
    try expectNotContains(missing_reflect_body, "; mir pointer_provenance consumed fn=pointer_array_element_reflect_read_requires_mir_fact subject=p provenance");
    try expectContains(missing_reflect_body, "load atomic i32, ptr %");
    try expectContains(missing_reflect_body, " unordered, align 4");
    try expectNotContains(missing_reflect_body, "load i32, ptr %");

    var missing_noalias_output: std.ArrayList(u8) = .empty;
    defer missing_noalias_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_pointer_array_element_noalias_missing_provenance.mc", source, "pointer_array_element_noalias_read_requires_mir_fact", "p", &missing_noalias_output);

    const missing_noalias_body = try llvmFunctionBody(missing_noalias_output.items, "define internal i32 @pointer_array_element_noalias_read_requires_mir_fact");
    try expectContains(missing_noalias_body, "; mir pointer_provenance consumed fn=pointer_array_element_noalias_read_requires_mir_fact subject=ptrs element=0 provenance=global_storage reason=none");
    try expectNotContains(missing_noalias_body, "; mir pointer_provenance consumed fn=pointer_array_element_noalias_read_requires_mir_fact subject=p provenance");
    try expectContains(missing_noalias_body, "load atomic i32, ptr %");
    try expectContains(missing_noalias_body, " unordered, align 4");
    try expectNotContains(missing_noalias_body, "load i32, ptr %");

    var missing_cast_noalias_output: std.ArrayList(u8) = .empty;
    defer missing_cast_noalias_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_pointer_array_element_cast_noalias_missing_provenance.mc", source, "pointer_array_element_cast_noalias_read_requires_mir_fact", "p", &missing_cast_noalias_output);

    const missing_cast_noalias_body = try llvmFunctionBody(missing_cast_noalias_output.items, "define internal i32 @pointer_array_element_cast_noalias_read_requires_mir_fact");
    try expectContains(missing_cast_noalias_body, "; mir pointer_provenance consumed fn=pointer_array_element_cast_noalias_read_requires_mir_fact subject=ptrs element=0 provenance=global_storage reason=none");
    try expectNotContains(missing_cast_noalias_body, "; mir pointer_provenance consumed fn=pointer_array_element_cast_noalias_read_requires_mir_fact subject=p provenance");
    try expectContains(missing_cast_noalias_body, "load atomic i32, ptr %");
    try expectContains(missing_cast_noalias_body, " unordered, align 4");
    try expectNotContains(missing_cast_noalias_body, "load i32, ptr %");

    var missing_assignment_output: std.ArrayList(u8) = .empty;
    defer missing_assignment_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_pointer_array_element_missing_provenance.mc", source, "pointer_array_element_assignment_requires_mir_fact", "p", &missing_assignment_output);

    const missing_assignment_body = try llvmFunctionBody(missing_assignment_output.items, "define internal i32 @pointer_array_element_assignment_requires_mir_fact");
    try expectContains(missing_assignment_body, "; mir pointer_provenance consumed fn=pointer_array_element_assignment_requires_mir_fact subject=ptrs element=0 provenance=global_storage reason=reassignment");
    try expectNotContains(missing_assignment_body, "; mir pointer_provenance consumed fn=pointer_array_element_assignment_requires_mir_fact subject=p provenance");
    try expectContains(missing_assignment_body, "load atomic i32, ptr %");
    try expectContains(missing_assignment_body, " unordered, align 4");
    try expectNotContains(missing_assignment_body, "load i32, ptr %");

    var missing_pointer_copy_direct_output: std.ArrayList(u8) = .empty;
    defer missing_pointer_copy_direct_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_pointer_array_element_missing_provenance.mc", source, "pointer_array_element_pointer_copy_direct_deref_requires_mir_fact", "ptrs", &missing_pointer_copy_direct_output);

    const missing_pointer_copy_direct_body = try llvmFunctionBody(missing_pointer_copy_direct_output.items, "define internal i32 @pointer_array_element_pointer_copy_direct_deref_requires_mir_fact");
    try expectContains(missing_pointer_copy_direct_body, "; mir pointer_provenance consumed fn=pointer_array_element_pointer_copy_direct_deref_requires_mir_fact subject=gp provenance=global_storage reason=none");
    try expectNotContains(missing_pointer_copy_direct_body, "; mir pointer_provenance consumed fn=pointer_array_element_pointer_copy_direct_deref_requires_mir_fact subject=ptrs element=0 provenance");
    try expectContains(missing_pointer_copy_direct_body, "load atomic i32, ptr %");
    try expectContains(missing_pointer_copy_direct_body, " unordered, align 4");
    try expectNotContains(missing_pointer_copy_direct_body, "load i32, ptr %");

    var missing_local_pointer_copy_direct_output: std.ArrayList(u8) = .empty;
    defer missing_local_pointer_copy_direct_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_pointer_array_element_missing_local_pointer_copy_provenance.mc", source, "pointer_array_element_local_pointer_copy_direct_deref_requires_mir_fact", "ptrs", &missing_local_pointer_copy_direct_output);

    const missing_local_pointer_copy_direct_body = try llvmFunctionBody(missing_local_pointer_copy_direct_output.items, "define internal i32 @pointer_array_element_local_pointer_copy_direct_deref_requires_mir_fact");
    try expectContains(missing_local_pointer_copy_direct_body, "; mir pointer_provenance consumed fn=pointer_array_element_local_pointer_copy_direct_deref_requires_mir_fact subject=lp provenance=local_storage reason=none");
    try expectNotContains(missing_local_pointer_copy_direct_body, "; mir pointer_provenance consumed fn=pointer_array_element_local_pointer_copy_direct_deref_requires_mir_fact subject=ptrs element=0 provenance");
    try expectContains(missing_local_pointer_copy_direct_body, "load atomic i32, ptr %");
    try expectContains(missing_local_pointer_copy_direct_body, " unordered, align 4");
    try expectNotContains(missing_local_pointer_copy_direct_body, "load i32, ptr %");
}

test "LLVM aggregate pointer-field reads without MIR destination fact lower conservatively" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32 }
        \\struct RawHolder { ptr: [*]mut u32 }
        \\struct Inner { ptr: *mut u32 }
        \\struct Outer { inner: Inner }
        \\struct RawInner { ptr: [*]mut u32 }
        \\struct RawOuter { inner: RawInner }
        \\
        \\fn aggregate_field_read_requires_mir_fact() -> u32 {
        \\    let holder: Holder = .{ .ptr = &shared_counter };
        \\    let p: *mut u32 = holder.ptr;
        \\    return p.*;
        \\}
        \\
        \\fn aggregate_field_noalias_read_requires_mir_fact() -> u32 {
        \\    let holder: Holder = .{ .ptr = &shared_counter };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        let p: *mut u32 = compiler.assume_noalias_unchecked(holder.ptr, 4);
        \\        return p.*;
        \\    }
        \\}
        \\
        \\fn aggregate_field_assignment_requires_mir_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var holder: Holder = .{ .ptr = &local };
        \\    holder.ptr = &shared_counter;
        \\    var p: *mut u32 = &local;
        \\    p = holder.ptr;
        \\    return p.*;
        \\}
        \\
        \\fn aggregate_field_pointer_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var holder: Holder = .{ .ptr = &local };
        \\    let gp: *mut u32 = &shared_counter;
        \\    holder.ptr = gp;
        \\    return holder.ptr.*;
        \\}
        \\
        \\fn aggregate_field_raw_many_zero_direct_deref_requires_mir_field_fact() -> u32 {
        \\    unsafe {
        \\        var local: u32 = 0;
        \\        var holder: RawHolder = .{ .ptr = (&local) as [*]mut u32 };
        \\        let gp: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        holder.ptr = gp.offset(0);
        \\        return holder.ptr.*;
        \\    }
        \\}
        \\
        \\fn aggregate_field_noalias_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var holder: Holder = .{ .ptr = &local };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        holder.ptr = compiler.assume_noalias_unchecked(&shared_counter, 4);
        \\    }
        \\    return holder.ptr.*;
        \\}
        \\
        \\fn aggregate_field_noalias_read_direct_deref_requires_mir_field_fact() -> u32 {
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
        \\fn aggregate_field_casted_noalias_read_direct_deref_requires_mir_field_fact() -> u32 {
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
        \\fn aggregate_field_literal_pointer_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let gp: *mut u32 = &shared_counter;
        \\    let holder: Holder = .{ .ptr = gp };
        \\    return holder.ptr.*;
        \\}
        \\
        \\fn aggregate_field_literal_raw_many_zero_direct_deref_requires_mir_field_fact() -> u32 {
        \\    unsafe {
        \\        let gp: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        let holder: RawHolder = .{ .ptr = gp.offset(0) };
        \\        return holder.ptr.*;
        \\    }
        \\}
        \\
        \\fn aggregate_field_literal_noalias_direct_deref_requires_mir_field_fact() -> u32 {
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        let holder: Holder = .{ .ptr = compiler.assume_noalias_unchecked(&shared_counter, 4) };
        \\        return holder.ptr.*;
        \\    }
        \\}
        \\
        \\fn aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var holder: Holder = .{ .ptr = &local };
        \\    let gp: *mut u32 = &shared_counter;
        \\    holder = .{ .ptr = gp };
        \\    return holder.ptr.*;
        \\}
        \\
        \\fn aggregate_field_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact() -> u32 {
        \\    unsafe {
        \\        var local: u32 = 0;
        \\        var holder: RawHolder = .{ .ptr = (&local) as [*]mut u32 };
        \\        let gp: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        holder = .{ .ptr = gp.offset(0) };
        \\        return holder.ptr.*;
        \\    }
        \\}
        \\
        \\fn aggregate_field_literal_reassignment_noalias_direct_deref_requires_mir_field_fact() -> u32 {
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        var local: u32 = 0;
        \\        var holder: Holder = .{ .ptr = &local };
        \\        holder = .{ .ptr = compiler.assume_noalias_unchecked(&shared_counter, 4) };
        \\        return holder.ptr.*;
        \\    }
        \\}
        \\
        \\fn aggregate_field_scoped_assignment_preserves_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var holder: Holder = .{ .ptr = &local };
        \\    unsafe {
        \\        holder.ptr = &shared_counter;
        \\    }
        \\    let p: *mut u32 = holder.ptr;
        \\    return p.*;
        \\}
        \\
        \\fn aggregate_field_scoped_direct_deref_lowers_atomic() -> u32 {
        \\    var local: u32 = 0;
        \\    var holder: Holder = .{ .ptr = &local };
        \\    unsafe {
        \\        holder.ptr = &shared_counter;
        \\    }
        \\    return holder.ptr.*;
        \\}
        \\
        \\fn aggregate_field_local_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let holder: Holder = .{ .ptr = &local };
        \\    return holder.ptr.*;
        \\}
        \\
        \\fn aggregate_field_local_direct_store_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let holder: Holder = .{ .ptr = &local };
        \\    holder.ptr.* = 9;
        \\    return local;
        \\}
        \\
        \\fn aggregate_field_local_pointer_copy_literal_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let lp: *mut u32 = &local;
        \\    let holder: Holder = .{ .ptr = lp };
        \\    return holder.ptr.*;
        \\}
        \\
        \\fn aggregate_field_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var other: u32 = 0;
        \\    let lp: *mut u32 = &local;
        \\    var holder: Holder = .{ .ptr = &other };
        \\    holder = .{ .ptr = lp };
        \\    return holder.ptr.*;
        \\}
        \\
        \\fn aggregate_field_copy_requires_mir_fact() -> u32 {
        \\    let holder: Holder = .{ .ptr = &shared_counter };
        \\    let copied: Holder = holder;
        \\    let p: *mut u32 = copied.ptr;
        \\    return p.*;
        \\}
        \\
        \\fn aggregate_field_noalias_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    let holder: Holder = .{ .ptr = &shared_counter };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        let copied: Holder = compiler.assume_noalias_unchecked(holder, 4);
        \\        return copied.ptr.*;
        \\    }
        \\}
        \\
        \\fn aggregate_field_casted_noalias_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    let holder: Holder = .{ .ptr = &shared_counter };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        let copied: Holder = compiler.assume_noalias_unchecked(holder, 4) as Holder;
        \\        return copied.ptr.*;
        \\    }
        \\}
        \\
        \\fn aggregate_field_local_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let holder: Holder = .{ .ptr = &local };
        \\    let copied: Holder = holder;
        \\    return copied.ptr.*;
        \\}
        \\
        \\fn nested_aggregate_field_read_requires_mir_fact() -> u32 {
        \\    let outer: Outer = .{ .inner = .{ .ptr = &shared_counter } };
        \\    let p: *mut u32 = outer.inner.ptr;
        \\    return p.*;
        \\}
        \\
        \\fn nested_aggregate_field_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    let outer: Outer = .{ .inner = .{ .ptr = &shared_counter } };
        \\    let copied: Outer = outer;
        \\    return copied.inner.ptr.*;
        \\}
        \\
        \\fn nested_aggregate_field_assignment_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let outer: Outer = .{ .inner = .{ .ptr = &shared_counter } };
        \\    var assigned: Outer = .{ .inner = .{ .ptr = &local } };
        \\    assigned = outer;
        \\    return assigned.inner.ptr.*;
        \\}
        \\
        \\fn nested_aggregate_field_noalias_member_copy_direct_deref_requires_mir_field_fact() -> u32 {
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
        \\fn nested_aggregate_field_casted_noalias_member_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let src: Outer = .{ .inner = .{ .ptr = &shared_counter } };
        \\    var dst: Outer = .{ .inner = .{ .ptr = &local } };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        dst.inner = compiler.assume_noalias_unchecked(src.inner, 4) as Inner;
        \\    }
        \\    return dst.inner.ptr.*;
        \\}
        \\
        \\fn nested_aggregate_field_literal_local_pointer_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let lp: *mut u32 = &local;
        \\    let outer: Outer = .{ .inner = .{ .ptr = lp } };
        \\    return outer.inner.ptr.*;
        \\}
        \\
        \\fn nested_aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var outer: Outer = .{ .inner = .{ .ptr = &local } };
        \\    let gp: *mut u32 = &shared_counter;
        \\    outer.inner = .{ .ptr = gp };
        \\    return outer.inner.ptr.*;
        \\}
        \\
        \\fn nested_aggregate_field_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var other: u32 = 0;
        \\    var outer: Outer = .{ .inner = .{ .ptr = &other } };
        \\    let lp: *mut u32 = &local;
        \\    outer.inner = .{ .ptr = lp };
        \\    return outer.inner.ptr.*;
        \\}
        \\
        \\fn nested_aggregate_field_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact() -> u32 {
        \\    unsafe {
        \\        var local: u32 = 0;
        \\        var outer: RawOuter = .{ .inner = .{ .ptr = (&local) as [*]mut u32 } };
        \\        let gp: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        outer.inner = .{ .ptr = gp.offset(0) };
        \\        return outer.inner.ptr.*;
        \\    }
        \\}
        \\
        \\fn nested_aggregate_field_literal_reassignment_noalias_direct_deref_requires_mir_field_fact() -> u32 {
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        var local: u32 = 0;
        \\        var outer: Outer = .{ .inner = .{ .ptr = &local } };
        \\        outer.inner = .{ .ptr = compiler.assume_noalias_unchecked(&shared_counter, 4) };
        \\        return outer.inner.ptr.*;
        \\    }
        \\}
        \\
        \\fn nested_aggregate_field_scoped_assignment_preserves_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var outer: Outer = .{ .inner = .{ .ptr = &local } };
        \\    unsafe {
        \\        outer.inner.ptr = &shared_counter;
        \\    }
        \\    let p: *mut u32 = outer.inner.ptr;
        \\    return p.*;
        \\}
        \\
        \\fn nested_aggregate_field_scoped_direct_deref_lowers_atomic() -> u32 {
        \\    var local: u32 = 0;
        \\    var outer: Outer = .{ .inner = .{ .ptr = &local } };
        \\    unsafe {
        \\        outer.inner.ptr = &shared_counter;
        \\    }
        \\    return outer.inner.ptr.*;
        \\}
    ;

    var normal_output: std.ArrayList(u8) = .empty;
    defer normal_output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_aggregate_field_provenance.mc", source, &normal_output);

    const normal_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_field_read_requires_mir_fact");
    try expectContains(normal_body, "; mir pointer_provenance consumed fn=aggregate_field_read_requires_mir_fact subject=holder field=ptr provenance=global_storage reason=none");
    try expectContains(normal_body, "; mir pointer_provenance consumed fn=aggregate_field_read_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectContains(normal_body, "load atomic i32, ptr %");
    try expectContains(normal_body, " unordered, align 4");

    const normal_noalias_read_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_field_noalias_read_requires_mir_fact");
    try expectContains(normal_noalias_read_body, "; mir pointer_provenance consumed fn=aggregate_field_noalias_read_requires_mir_fact subject=holder field=ptr provenance=global_storage reason=none");
    try expectContains(normal_noalias_read_body, "; mir pointer_provenance consumed fn=aggregate_field_noalias_read_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectContains(normal_noalias_read_body, "load atomic i32, ptr %");
    try expectContains(normal_noalias_read_body, " unordered, align 4");
    try expectNotContains(normal_noalias_read_body, "load i32, ptr %");

    const normal_assignment_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_field_assignment_requires_mir_fact");
    try expectContains(normal_assignment_body, "; mir pointer_provenance consumed fn=aggregate_field_assignment_requires_mir_fact subject=holder field=ptr provenance=local_storage reason=none");
    try expectContains(normal_assignment_body, "; mir pointer_provenance consumed fn=aggregate_field_assignment_requires_mir_fact subject=holder field=ptr provenance=global_storage reason=reassignment");
    try expectContains(normal_assignment_body, "; mir pointer_provenance consumed fn=aggregate_field_assignment_requires_mir_fact subject=p provenance=global_storage reason=reassignment");
    try expectContains(normal_assignment_body, "load atomic i32, ptr %");
    try expectContains(normal_assignment_body, " unordered, align 4");

    const normal_pointer_copy_direct_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_field_pointer_copy_direct_deref_requires_mir_field_fact");
    try expectContains(normal_pointer_copy_direct_body, "; mir pointer_provenance consumed fn=aggregate_field_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none");
    try expectContains(normal_pointer_copy_direct_body, "; mir pointer_provenance consumed fn=aggregate_field_pointer_copy_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance=global_storage reason=reassignment");
    try expectContains(normal_pointer_copy_direct_body, "load atomic i32, ptr %");
    try expectContains(normal_pointer_copy_direct_body, " unordered, align 4");
    try expectNotContains(normal_pointer_copy_direct_body, "load i32, ptr %");

    const normal_raw_many_zero_direct_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_field_raw_many_zero_direct_deref_requires_mir_field_fact");
    try expectContains(normal_raw_many_zero_direct_body, "; mir pointer_provenance consumed fn=aggregate_field_raw_many_zero_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none");
    try expectContains(normal_raw_many_zero_direct_body, "; mir pointer_provenance consumed fn=aggregate_field_raw_many_zero_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance=global_storage reason=reassignment");
    try expectContains(normal_raw_many_zero_direct_body, "load atomic i32, ptr %");
    try expectContains(normal_raw_many_zero_direct_body, " unordered, align 4");
    try expectNotContains(normal_raw_many_zero_direct_body, "load i32, ptr %");

    const normal_noalias_direct_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_field_noalias_direct_deref_requires_mir_field_fact");
    try expectContains(normal_noalias_direct_body, "; mir pointer_provenance consumed fn=aggregate_field_noalias_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance=global_storage reason=reassignment");
    try expectContains(normal_noalias_direct_body, "load atomic i32, ptr %");
    try expectContains(normal_noalias_direct_body, " unordered, align 4");
    try expectNotContains(normal_noalias_direct_body, "load i32, ptr %");

    const normal_noalias_read_direct_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_field_noalias_read_direct_deref_requires_mir_field_fact");
    try expectContains(normal_noalias_read_direct_body, "; mir pointer_provenance consumed fn=aggregate_field_noalias_read_direct_deref_requires_mir_field_fact subject=src field=ptr provenance=global_storage reason=none");
    try expectContains(normal_noalias_read_direct_body, "; mir pointer_provenance consumed fn=aggregate_field_noalias_read_direct_deref_requires_mir_field_fact subject=dst field=ptr provenance=global_storage reason=reassignment");
    try expectContains(normal_noalias_read_direct_body, "load atomic i32, ptr %");
    try expectContains(normal_noalias_read_direct_body, " unordered, align 4");
    try expectNotContains(normal_noalias_read_direct_body, "load i32, ptr %");

    const normal_casted_noalias_read_direct_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_field_casted_noalias_read_direct_deref_requires_mir_field_fact");
    try expectContains(normal_casted_noalias_read_direct_body, "; mir pointer_provenance consumed fn=aggregate_field_casted_noalias_read_direct_deref_requires_mir_field_fact subject=src field=ptr provenance=global_storage reason=none");
    try expectContains(normal_casted_noalias_read_direct_body, "; mir pointer_provenance consumed fn=aggregate_field_casted_noalias_read_direct_deref_requires_mir_field_fact subject=dst field=ptr provenance=global_storage reason=reassignment");
    try expectContains(normal_casted_noalias_read_direct_body, "load atomic i32, ptr %");
    try expectContains(normal_casted_noalias_read_direct_body, " unordered, align 4");
    try expectNotContains(normal_casted_noalias_read_direct_body, "load i32, ptr %");

    const normal_literal_pointer_copy_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_field_literal_pointer_copy_direct_deref_requires_mir_field_fact");
    try expectContains(normal_literal_pointer_copy_body, "; mir pointer_provenance consumed fn=aggregate_field_literal_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none");
    try expectContains(normal_literal_pointer_copy_body, "; mir pointer_provenance consumed fn=aggregate_field_literal_pointer_copy_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance=global_storage reason=none");
    try expectContains(normal_literal_pointer_copy_body, "load atomic i32, ptr %");
    try expectContains(normal_literal_pointer_copy_body, " unordered, align 4");
    try expectNotContains(normal_literal_pointer_copy_body, "load i32, ptr %");

    const normal_literal_raw_many_zero_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_field_literal_raw_many_zero_direct_deref_requires_mir_field_fact");
    try expectContains(normal_literal_raw_many_zero_body, "; mir pointer_provenance consumed fn=aggregate_field_literal_raw_many_zero_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none");
    try expectContains(normal_literal_raw_many_zero_body, "; mir pointer_provenance consumed fn=aggregate_field_literal_raw_many_zero_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance=global_storage reason=none");
    try expectContains(normal_literal_raw_many_zero_body, "load atomic i32, ptr %");
    try expectContains(normal_literal_raw_many_zero_body, " unordered, align 4");
    try expectNotContains(normal_literal_raw_many_zero_body, "load i32, ptr %");

    const normal_literal_noalias_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_field_literal_noalias_direct_deref_requires_mir_field_fact");
    try expectContains(normal_literal_noalias_body, "; mir pointer_provenance consumed fn=aggregate_field_literal_noalias_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance=global_storage reason=none");
    try expectContains(normal_literal_noalias_body, "load atomic i32, ptr %");
    try expectContains(normal_literal_noalias_body, " unordered, align 4");
    try expectNotContains(normal_literal_noalias_body, "load i32, ptr %");

    const normal_literal_reassignment_pointer_copy_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact");
    try expectContains(normal_literal_reassignment_pointer_copy_body, "; mir pointer_provenance consumed fn=aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none");
    try expectContains(normal_literal_reassignment_pointer_copy_body, "; mir pointer_provenance consumed fn=aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance=global_storage reason=none");
    try expectContains(normal_literal_reassignment_pointer_copy_body, "load atomic i32, ptr %");
    try expectContains(normal_literal_reassignment_pointer_copy_body, " unordered, align 4");
    try expectNotContains(normal_literal_reassignment_pointer_copy_body, "load i32, ptr %");

    const normal_literal_reassignment_raw_many_zero_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_field_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact");
    try expectContains(normal_literal_reassignment_raw_many_zero_body, "; mir pointer_provenance consumed fn=aggregate_field_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none");
    try expectContains(normal_literal_reassignment_raw_many_zero_body, "; mir pointer_provenance consumed fn=aggregate_field_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance=global_storage reason=none");
    try expectContains(normal_literal_reassignment_raw_many_zero_body, "load atomic i32, ptr %");
    try expectContains(normal_literal_reassignment_raw_many_zero_body, " unordered, align 4");
    try expectNotContains(normal_literal_reassignment_raw_many_zero_body, "load i32, ptr %");

    const normal_literal_reassignment_noalias_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_field_literal_reassignment_noalias_direct_deref_requires_mir_field_fact");
    try expectContains(normal_literal_reassignment_noalias_body, "; mir pointer_provenance consumed fn=aggregate_field_literal_reassignment_noalias_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance=global_storage reason=none");
    try expectContains(normal_literal_reassignment_noalias_body, "load atomic i32, ptr %");
    try expectContains(normal_literal_reassignment_noalias_body, " unordered, align 4");
    try expectNotContains(normal_literal_reassignment_noalias_body, "load i32, ptr %");

    const normal_scoped_assignment_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_field_scoped_assignment_preserves_fact");
    try expectContains(normal_scoped_assignment_body, "; mir pointer_provenance consumed fn=aggregate_field_scoped_assignment_preserves_fact subject=p provenance=global_storage reason=none");
    try expectContains(normal_scoped_assignment_body, "load atomic i32, ptr %");
    try expectContains(normal_scoped_assignment_body, " unordered, align 4");
    try expectNotContains(normal_scoped_assignment_body, "load i32, ptr %");

    const normal_scoped_direct_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_field_scoped_direct_deref_lowers_atomic");
    try expectContains(normal_scoped_direct_body, "; mir pointer_provenance consumed fn=aggregate_field_scoped_direct_deref_lowers_atomic subject=holder field=ptr provenance=global_storage reason=reassignment");
    try expectContains(normal_scoped_direct_body, "load atomic i32, ptr %");
    try expectContains(normal_scoped_direct_body, " unordered, align 4");
    try expectNotContains(normal_scoped_direct_body, "load i32, ptr %");

    const normal_local_direct_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_field_local_direct_deref_requires_mir_field_fact");
    try expectContains(normal_local_direct_body, "; mir pointer_provenance consumed fn=aggregate_field_local_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance=local_storage reason=none");
    try expectContains(normal_local_direct_body, "load i32, ptr %");
    try expectNotContains(normal_local_direct_body, "load atomic i32, ptr %");

    const normal_local_store_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_field_local_direct_store_requires_mir_field_fact");
    try expectContains(normal_local_store_body, "; mir pointer_provenance consumed fn=aggregate_field_local_direct_store_requires_mir_field_fact subject=holder field=ptr provenance=local_storage reason=none");
    try expectContains(normal_local_store_body, "store i32 9, ptr %");
    try expectNotContains(normal_local_store_body, "store atomic i32 9, ptr %");

    const normal_local_pointer_copy_literal_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_field_local_pointer_copy_literal_direct_deref_requires_mir_field_fact");
    try expectContains(normal_local_pointer_copy_literal_body, "; mir pointer_provenance consumed fn=aggregate_field_local_pointer_copy_literal_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none");
    try expectContains(normal_local_pointer_copy_literal_body, "; mir pointer_provenance consumed fn=aggregate_field_local_pointer_copy_literal_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance=local_storage reason=none");
    try expectContains(normal_local_pointer_copy_literal_body, "load i32, ptr %");
    try expectNotContains(normal_local_pointer_copy_literal_body, "load atomic i32, ptr %");

    const normal_local_pointer_copy_literal_reassignment_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_field_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact");
    try expectContains(normal_local_pointer_copy_literal_reassignment_body, "; mir pointer_provenance consumed fn=aggregate_field_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none");
    try expectContains(normal_local_pointer_copy_literal_reassignment_body, "; mir pointer_provenance consumed fn=aggregate_field_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance=local_storage reason=none");
    try expectContains(normal_local_pointer_copy_literal_reassignment_body, "load i32, ptr %");
    try expectNotContains(normal_local_pointer_copy_literal_reassignment_body, "load atomic i32, ptr %");

    const normal_copy_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_field_copy_requires_mir_fact");
    try expectContains(normal_copy_body, "; mir pointer_provenance consumed fn=aggregate_field_copy_requires_mir_fact subject=copied field=ptr provenance=global_storage reason=none");
    try expectContains(normal_copy_body, "; mir pointer_provenance consumed fn=aggregate_field_copy_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectContains(normal_copy_body, "load atomic i32, ptr %");
    try expectContains(normal_copy_body, " unordered, align 4");

    const normal_noalias_copy_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_field_noalias_copy_direct_deref_requires_mir_field_fact");
    try expectContains(normal_noalias_copy_body, "; mir pointer_provenance consumed fn=aggregate_field_noalias_copy_direct_deref_requires_mir_field_fact subject=copied field=ptr provenance=global_storage reason=none");
    try expectContains(normal_noalias_copy_body, "load atomic i32, ptr %");
    try expectContains(normal_noalias_copy_body, " unordered, align 4");

    const normal_casted_noalias_copy_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_field_casted_noalias_copy_direct_deref_requires_mir_field_fact");
    try expectContains(normal_casted_noalias_copy_body, "; mir pointer_provenance consumed fn=aggregate_field_casted_noalias_copy_direct_deref_requires_mir_field_fact subject=copied field=ptr provenance=global_storage reason=none");
    try expectContains(normal_casted_noalias_copy_body, "load atomic i32, ptr %");
    try expectContains(normal_casted_noalias_copy_body, " unordered, align 4");
    try expectNotContains(normal_casted_noalias_copy_body, "load i32, ptr %");

    const normal_local_copy_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_field_local_copy_direct_deref_requires_mir_field_fact");
    try expectContains(normal_local_copy_body, "; mir pointer_provenance consumed fn=aggregate_field_local_copy_direct_deref_requires_mir_field_fact subject=copied field=ptr provenance=local_storage reason=none");
    try expectContains(normal_local_copy_body, "load i32, ptr %");
    try expectNotContains(normal_local_copy_body, "load atomic i32, ptr %");

    const normal_nested_body = try llvmFunctionBody(normal_output.items, "define internal i32 @nested_aggregate_field_read_requires_mir_fact");
    try expectContains(normal_nested_body, "; mir pointer_provenance consumed fn=nested_aggregate_field_read_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectContains(normal_nested_body, "load atomic i32, ptr %");
    try expectContains(normal_nested_body, " unordered, align 4");

    const normal_nested_literal_local_pointer_copy_body = try llvmFunctionBody(normal_output.items, "define internal i32 @nested_aggregate_field_literal_local_pointer_copy_direct_deref_requires_mir_field_fact");
    try expectContains(normal_nested_literal_local_pointer_copy_body, "; mir pointer_provenance consumed fn=nested_aggregate_field_literal_local_pointer_copy_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none");
    try expectContains(normal_nested_literal_local_pointer_copy_body, "; mir pointer_provenance consumed fn=nested_aggregate_field_literal_local_pointer_copy_direct_deref_requires_mir_field_fact subject=outer field=inner.ptr provenance=local_storage reason=none");
    try expectContains(normal_nested_literal_local_pointer_copy_body, "load i32, ptr %");
    try expectNotContains(normal_nested_literal_local_pointer_copy_body, "load atomic i32, ptr %");

    const normal_nested_literal_reassignment_pointer_copy_body = try llvmFunctionBody(normal_output.items, "define internal i32 @nested_aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact");
    try expectContains(normal_nested_literal_reassignment_pointer_copy_body, "; mir pointer_provenance consumed fn=nested_aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none");
    try expectContains(normal_nested_literal_reassignment_pointer_copy_body, "; mir pointer_provenance consumed fn=nested_aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact subject=outer field=inner.ptr provenance=global_storage reason=none");
    try expectContains(normal_nested_literal_reassignment_pointer_copy_body, "load atomic i32, ptr %");
    try expectContains(normal_nested_literal_reassignment_pointer_copy_body, " unordered, align 4");
    try expectNotContains(normal_nested_literal_reassignment_pointer_copy_body, "load i32, ptr %");

    const normal_nested_literal_reassignment_local_pointer_copy_body = try llvmFunctionBody(normal_output.items, "define internal i32 @nested_aggregate_field_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact");
    try expectContains(normal_nested_literal_reassignment_local_pointer_copy_body, "; mir pointer_provenance consumed fn=nested_aggregate_field_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none");
    try expectContains(normal_nested_literal_reassignment_local_pointer_copy_body, "; mir pointer_provenance consumed fn=nested_aggregate_field_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact subject=outer field=inner.ptr provenance=local_storage reason=none");
    try expectContains(normal_nested_literal_reassignment_local_pointer_copy_body, "load i32, ptr %");
    try expectNotContains(normal_nested_literal_reassignment_local_pointer_copy_body, "load atomic i32, ptr %");

    const normal_nested_literal_reassignment_raw_many_zero_body = try llvmFunctionBody(normal_output.items, "define internal i32 @nested_aggregate_field_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact");
    try expectContains(normal_nested_literal_reassignment_raw_many_zero_body, "; mir pointer_provenance consumed fn=nested_aggregate_field_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none");
    try expectContains(normal_nested_literal_reassignment_raw_many_zero_body, "; mir pointer_provenance consumed fn=nested_aggregate_field_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact subject=outer field=inner.ptr provenance=global_storage reason=none");
    try expectContains(normal_nested_literal_reassignment_raw_many_zero_body, "load atomic i32, ptr %");
    try expectContains(normal_nested_literal_reassignment_raw_many_zero_body, " unordered, align 4");
    try expectNotContains(normal_nested_literal_reassignment_raw_many_zero_body, "load i32, ptr %");

    const normal_nested_literal_reassignment_noalias_body = try llvmFunctionBody(normal_output.items, "define internal i32 @nested_aggregate_field_literal_reassignment_noalias_direct_deref_requires_mir_field_fact");
    try expectContains(normal_nested_literal_reassignment_noalias_body, "; mir pointer_provenance consumed fn=nested_aggregate_field_literal_reassignment_noalias_direct_deref_requires_mir_field_fact subject=outer field=inner.ptr provenance=global_storage reason=none");
    try expectContains(normal_nested_literal_reassignment_noalias_body, "load atomic i32, ptr %");
    try expectContains(normal_nested_literal_reassignment_noalias_body, " unordered, align 4");
    try expectNotContains(normal_nested_literal_reassignment_noalias_body, "load i32, ptr %");

    const normal_nested_copy_body = try llvmFunctionBody(normal_output.items, "define internal i32 @nested_aggregate_field_copy_direct_deref_requires_mir_field_fact");
    try expectContains(normal_nested_copy_body, "; mir pointer_provenance consumed fn=nested_aggregate_field_copy_direct_deref_requires_mir_field_fact subject=copied field=inner.ptr provenance=global_storage reason=none");
    try expectContains(normal_nested_copy_body, "load atomic i32, ptr %");
    try expectContains(normal_nested_copy_body, " unordered, align 4");
    try expectNotContains(normal_nested_copy_body, "load i32, ptr %");

    const normal_nested_assignment_copy_body = try llvmFunctionBody(normal_output.items, "define internal i32 @nested_aggregate_field_assignment_copy_direct_deref_requires_mir_field_fact");
    try expectContains(normal_nested_assignment_copy_body, "; mir pointer_provenance consumed fn=nested_aggregate_field_assignment_copy_direct_deref_requires_mir_field_fact subject=assigned field=inner.ptr provenance=global_storage reason=reassignment");
    try expectContains(normal_nested_assignment_copy_body, "load atomic i32, ptr %");
    try expectContains(normal_nested_assignment_copy_body, " unordered, align 4");
    try expectNotContains(normal_nested_assignment_copy_body, "load i32, ptr %");

    const normal_nested_noalias_member_copy_body = try llvmFunctionBody(normal_output.items, "define internal i32 @nested_aggregate_field_noalias_member_copy_direct_deref_requires_mir_field_fact");
    try expectContains(normal_nested_noalias_member_copy_body, "; mir pointer_provenance consumed fn=nested_aggregate_field_noalias_member_copy_direct_deref_requires_mir_field_fact subject=dst field=inner.ptr provenance=global_storage reason=reassignment");
    try expectContains(normal_nested_noalias_member_copy_body, "load atomic i32, ptr %");
    try expectContains(normal_nested_noalias_member_copy_body, " unordered, align 4");
    try expectNotContains(normal_nested_noalias_member_copy_body, "load i32, ptr %");

    const normal_nested_casted_noalias_member_copy_body = try llvmFunctionBody(normal_output.items, "define internal i32 @nested_aggregate_field_casted_noalias_member_copy_direct_deref_requires_mir_field_fact");
    try expectContains(normal_nested_casted_noalias_member_copy_body, "; mir pointer_provenance consumed fn=nested_aggregate_field_casted_noalias_member_copy_direct_deref_requires_mir_field_fact subject=dst field=inner.ptr provenance=global_storage reason=reassignment");
    try expectContains(normal_nested_casted_noalias_member_copy_body, "load atomic i32, ptr %");
    try expectContains(normal_nested_casted_noalias_member_copy_body, " unordered, align 4");
    try expectNotContains(normal_nested_casted_noalias_member_copy_body, "load i32, ptr %");

    const normal_nested_scoped_body = try llvmFunctionBody(normal_output.items, "define internal i32 @nested_aggregate_field_scoped_assignment_preserves_fact");
    try expectContains(normal_nested_scoped_body, "; mir pointer_provenance consumed fn=nested_aggregate_field_scoped_assignment_preserves_fact subject=p provenance=global_storage reason=none");
    try expectContains(normal_nested_scoped_body, "load atomic i32, ptr %");
    try expectContains(normal_nested_scoped_body, " unordered, align 4");
    try expectNotContains(normal_nested_scoped_body, "load i32, ptr %");

    const normal_nested_scoped_direct_body = try llvmFunctionBody(normal_output.items, "define internal i32 @nested_aggregate_field_scoped_direct_deref_lowers_atomic");
    try expectContains(normal_nested_scoped_direct_body, "load atomic i32, ptr %");
    try expectContains(normal_nested_scoped_direct_body, " unordered, align 4");
    try expectNotContains(normal_nested_scoped_direct_body, "load i32, ptr %");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_aggregate_field_missing_provenance.mc", source, "aggregate_field_read_requires_mir_fact", "p", &missing_output);

    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @aggregate_field_read_requires_mir_fact");
    try expectNotContains(missing_body, "; mir pointer_provenance consumed fn=aggregate_field_read_requires_mir_fact subject=p provenance");
    try expectContains(missing_body, "load atomic i32, ptr %");
    try expectContains(missing_body, " unordered, align 4");
    try expectNotContains(missing_body, "load i32, ptr %");

    var missing_noalias_read_output: std.ArrayList(u8) = .empty;
    defer missing_noalias_read_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_aggregate_field_missing_noalias_read_provenance.mc", source, "aggregate_field_noalias_read_requires_mir_fact", "p", &missing_noalias_read_output);

    const missing_noalias_read_body = try llvmFunctionBody(missing_noalias_read_output.items, "define internal i32 @aggregate_field_noalias_read_requires_mir_fact");
    try expectContains(missing_noalias_read_body, "; mir pointer_provenance consumed fn=aggregate_field_noalias_read_requires_mir_fact subject=holder field=ptr provenance=global_storage reason=none");
    try expectNotContains(missing_noalias_read_body, "; mir pointer_provenance consumed fn=aggregate_field_noalias_read_requires_mir_fact subject=p provenance");
    try expectContains(missing_noalias_read_body, "load atomic i32, ptr %");
    try expectContains(missing_noalias_read_body, " unordered, align 4");
    try expectNotContains(missing_noalias_read_body, "load i32, ptr %");

    var missing_assignment_output: std.ArrayList(u8) = .empty;
    defer missing_assignment_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_aggregate_field_missing_provenance.mc", source, "aggregate_field_assignment_requires_mir_fact", "p", &missing_assignment_output);

    const missing_assignment_body = try llvmFunctionBody(missing_assignment_output.items, "define internal i32 @aggregate_field_assignment_requires_mir_fact");
    try expectNotContains(missing_assignment_body, "; mir pointer_provenance consumed fn=aggregate_field_assignment_requires_mir_fact subject=p provenance");
    try expectContains(missing_assignment_body, "load atomic i32, ptr %");
    try expectContains(missing_assignment_body, " unordered, align 4");
    try expectNotContains(missing_assignment_body, "load i32, ptr %");

    var missing_copy_output: std.ArrayList(u8) = .empty;
    defer missing_copy_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_aggregate_field_missing_provenance.mc", source, "aggregate_field_copy_requires_mir_fact", "p", &missing_copy_output);

    const missing_copy_body = try llvmFunctionBody(missing_copy_output.items, "define internal i32 @aggregate_field_copy_requires_mir_fact");
    try expectNotContains(missing_copy_body, "; mir pointer_provenance consumed fn=aggregate_field_copy_requires_mir_fact subject=p provenance");
    try expectContains(missing_copy_body, "load atomic i32, ptr %");
    try expectContains(missing_copy_body, " unordered, align 4");
    try expectNotContains(missing_copy_body, "load i32, ptr %");

    var missing_nested_output: std.ArrayList(u8) = .empty;
    defer missing_nested_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_aggregate_field_missing_provenance.mc", source, "nested_aggregate_field_read_requires_mir_fact", "p", &missing_nested_output);

    const missing_nested_body = try llvmFunctionBody(missing_nested_output.items, "define internal i32 @nested_aggregate_field_read_requires_mir_fact");
    try expectNotContains(missing_nested_body, "; mir pointer_provenance consumed fn=nested_aggregate_field_read_requires_mir_fact subject=p provenance");
    try expectContains(missing_nested_body, "load atomic i32, ptr %");
    try expectContains(missing_nested_body, " unordered, align 4");
    try expectNotContains(missing_nested_body, "load i32, ptr %");

    var missing_field_output: std.ArrayList(u8) = .empty;
    defer missing_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_field_missing_field_provenance.mc", source, "aggregate_field_local_direct_deref_requires_mir_field_fact", "holder", "ptr", &missing_field_output);

    const missing_field_body = try llvmFunctionBody(missing_field_output.items, "define internal i32 @aggregate_field_local_direct_deref_requires_mir_field_fact");
    try expectNotContains(missing_field_body, "; mir pointer_provenance consumed fn=aggregate_field_local_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance");
    try expectContains(missing_field_body, "load atomic i32, ptr %");
    try expectContains(missing_field_body, " unordered, align 4");
    try expectNotContains(missing_field_body, "load i32, ptr %");

    var missing_store_field_output: std.ArrayList(u8) = .empty;
    defer missing_store_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_field_missing_store_field_provenance.mc", source, "aggregate_field_local_direct_store_requires_mir_field_fact", "holder", "ptr", &missing_store_field_output);

    const missing_store_field_body = try llvmFunctionBody(missing_store_field_output.items, "define internal i32 @aggregate_field_local_direct_store_requires_mir_field_fact");
    try expectNotContains(missing_store_field_body, "; mir pointer_provenance consumed fn=aggregate_field_local_direct_store_requires_mir_field_fact subject=holder field=ptr provenance");
    try expectContains(missing_store_field_body, "store atomic i32 9, ptr %");
    try expectContains(missing_store_field_body, " unordered, align 4");
    try expectNotContains(missing_store_field_body, "store i32 9, ptr %");

    var missing_local_pointer_copy_literal_field_output: std.ArrayList(u8) = .empty;
    defer missing_local_pointer_copy_literal_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_field_missing_local_pointer_copy_literal_field_provenance.mc", source, "aggregate_field_local_pointer_copy_literal_direct_deref_requires_mir_field_fact", "holder", "ptr", &missing_local_pointer_copy_literal_field_output);

    const missing_local_pointer_copy_literal_field_body = try llvmFunctionBody(missing_local_pointer_copy_literal_field_output.items, "define internal i32 @aggregate_field_local_pointer_copy_literal_direct_deref_requires_mir_field_fact");
    try expectContains(missing_local_pointer_copy_literal_field_body, "; mir pointer_provenance consumed fn=aggregate_field_local_pointer_copy_literal_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none");
    try expectNotContains(missing_local_pointer_copy_literal_field_body, "; mir pointer_provenance consumed fn=aggregate_field_local_pointer_copy_literal_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance");
    try expectContains(missing_local_pointer_copy_literal_field_body, "load atomic i32, ptr %");
    try expectContains(missing_local_pointer_copy_literal_field_body, " unordered, align 4");
    try expectNotContains(missing_local_pointer_copy_literal_field_body, "load i32, ptr %");

    var missing_nested_literal_local_field_output: std.ArrayList(u8) = .empty;
    defer missing_nested_literal_local_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_nested_aggregate_field_missing_literal_local_field_provenance.mc", source, "nested_aggregate_field_literal_local_pointer_copy_direct_deref_requires_mir_field_fact", "outer", "inner.ptr", &missing_nested_literal_local_field_output);

    const missing_nested_literal_local_field_body = try llvmFunctionBody(missing_nested_literal_local_field_output.items, "define internal i32 @nested_aggregate_field_literal_local_pointer_copy_direct_deref_requires_mir_field_fact");
    try expectContains(missing_nested_literal_local_field_body, "; mir pointer_provenance consumed fn=nested_aggregate_field_literal_local_pointer_copy_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none");
    try expectNotContains(missing_nested_literal_local_field_body, "; mir pointer_provenance consumed fn=nested_aggregate_field_literal_local_pointer_copy_direct_deref_requires_mir_field_fact subject=outer field=inner.ptr provenance");
    try expectContains(missing_nested_literal_local_field_body, "load atomic i32, ptr %");
    try expectContains(missing_nested_literal_local_field_body, " unordered, align 4");
    try expectNotContains(missing_nested_literal_local_field_body, "load i32, ptr %");

    var missing_local_pointer_copy_literal_reassignment_field_output: std.ArrayList(u8) = .empty;
    defer missing_local_pointer_copy_literal_reassignment_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_field_missing_local_pointer_copy_literal_reassignment_field_provenance.mc", source, "aggregate_field_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact", "holder", "ptr", &missing_local_pointer_copy_literal_reassignment_field_output);

    const missing_local_pointer_copy_literal_reassignment_field_body = try llvmFunctionBody(missing_local_pointer_copy_literal_reassignment_field_output.items, "define internal i32 @aggregate_field_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact");
    try expectContains(missing_local_pointer_copy_literal_reassignment_field_body, "; mir pointer_provenance consumed fn=aggregate_field_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none");
    try expectNotContains(missing_local_pointer_copy_literal_reassignment_field_body, "; mir pointer_provenance consumed fn=aggregate_field_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance");
    try expectContains(missing_local_pointer_copy_literal_reassignment_field_body, "load atomic i32, ptr %");
    try expectContains(missing_local_pointer_copy_literal_reassignment_field_body, " unordered, align 4");
    try expectNotContains(missing_local_pointer_copy_literal_reassignment_field_body, "load i32, ptr %");

    var missing_pointer_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_pointer_copy_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_field_missing_pointer_copy_field_provenance.mc", source, "aggregate_field_pointer_copy_direct_deref_requires_mir_field_fact", "holder", "ptr", &missing_pointer_copy_field_output);

    const missing_pointer_copy_field_body = try llvmFunctionBody(missing_pointer_copy_field_output.items, "define internal i32 @aggregate_field_pointer_copy_direct_deref_requires_mir_field_fact");
    try expectContains(missing_pointer_copy_field_body, "; mir pointer_provenance consumed fn=aggregate_field_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none");
    try expectNotContains(missing_pointer_copy_field_body, "; mir pointer_provenance consumed fn=aggregate_field_pointer_copy_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance");
    try expectContains(missing_pointer_copy_field_body, "load atomic i32, ptr %");
    try expectContains(missing_pointer_copy_field_body, " unordered, align 4");
    try expectNotContains(missing_pointer_copy_field_body, "load i32, ptr %");

    var missing_raw_many_zero_field_output: std.ArrayList(u8) = .empty;
    defer missing_raw_many_zero_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_field_missing_raw_many_zero_field_provenance.mc", source, "aggregate_field_raw_many_zero_direct_deref_requires_mir_field_fact", "holder", "ptr", &missing_raw_many_zero_field_output);

    const missing_raw_many_zero_field_body = try llvmFunctionBody(missing_raw_many_zero_field_output.items, "define internal i32 @aggregate_field_raw_many_zero_direct_deref_requires_mir_field_fact");
    try expectContains(missing_raw_many_zero_field_body, "; mir pointer_provenance consumed fn=aggregate_field_raw_many_zero_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none");
    try expectNotContains(missing_raw_many_zero_field_body, "; mir pointer_provenance consumed fn=aggregate_field_raw_many_zero_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance");
    try expectContains(missing_raw_many_zero_field_body, "load atomic i32, ptr %");
    try expectContains(missing_raw_many_zero_field_body, " unordered, align 4");
    try expectNotContains(missing_raw_many_zero_field_body, "load i32, ptr %");

    var missing_noalias_field_output: std.ArrayList(u8) = .empty;
    defer missing_noalias_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_field_missing_noalias_field_provenance.mc", source, "aggregate_field_noalias_direct_deref_requires_mir_field_fact", "holder", "ptr", &missing_noalias_field_output);

    const missing_noalias_field_body = try llvmFunctionBody(missing_noalias_field_output.items, "define internal i32 @aggregate_field_noalias_direct_deref_requires_mir_field_fact");
    try expectNotContains(missing_noalias_field_body, "; mir pointer_provenance consumed fn=aggregate_field_noalias_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance");
    try expectContains(missing_noalias_field_body, "load atomic i32, ptr %");
    try expectContains(missing_noalias_field_body, " unordered, align 4");
    try expectNotContains(missing_noalias_field_body, "load i32, ptr %");

    var missing_noalias_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_noalias_copy_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_field_missing_noalias_copy_field_provenance.mc", source, "aggregate_field_noalias_copy_direct_deref_requires_mir_field_fact", "copied", "ptr", &missing_noalias_copy_field_output);

    const missing_noalias_copy_field_body = try llvmFunctionBody(missing_noalias_copy_field_output.items, "define internal i32 @aggregate_field_noalias_copy_direct_deref_requires_mir_field_fact");
    try expectNotContains(missing_noalias_copy_field_body, "; mir pointer_provenance consumed fn=aggregate_field_noalias_copy_direct_deref_requires_mir_field_fact subject=copied field=ptr provenance");
    try expectContains(missing_noalias_copy_field_body, "load atomic i32, ptr %");
    try expectContains(missing_noalias_copy_field_body, " unordered, align 4");
    try expectNotContains(missing_noalias_copy_field_body, "load i32, ptr %");

    var missing_casted_noalias_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_casted_noalias_copy_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_field_missing_casted_noalias_copy_field_provenance.mc", source, "aggregate_field_casted_noalias_copy_direct_deref_requires_mir_field_fact", "copied", "ptr", &missing_casted_noalias_copy_field_output);

    const missing_casted_noalias_copy_field_body = try llvmFunctionBody(missing_casted_noalias_copy_field_output.items, "define internal i32 @aggregate_field_casted_noalias_copy_direct_deref_requires_mir_field_fact");
    try expectNotContains(missing_casted_noalias_copy_field_body, "; mir pointer_provenance consumed fn=aggregate_field_casted_noalias_copy_direct_deref_requires_mir_field_fact subject=copied field=ptr provenance");
    try expectContains(missing_casted_noalias_copy_field_body, "load atomic i32, ptr %");
    try expectContains(missing_casted_noalias_copy_field_body, " unordered, align 4");
    try expectNotContains(missing_casted_noalias_copy_field_body, "load i32, ptr %");

    var missing_noalias_read_field_output: std.ArrayList(u8) = .empty;
    defer missing_noalias_read_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_field_missing_noalias_read_field_provenance.mc", source, "aggregate_field_noalias_read_direct_deref_requires_mir_field_fact", "dst", "ptr", &missing_noalias_read_field_output);

    const missing_noalias_read_field_body = try llvmFunctionBody(missing_noalias_read_field_output.items, "define internal i32 @aggregate_field_noalias_read_direct_deref_requires_mir_field_fact");
    try expectContains(missing_noalias_read_field_body, "; mir pointer_provenance consumed fn=aggregate_field_noalias_read_direct_deref_requires_mir_field_fact subject=src field=ptr provenance=global_storage reason=none");
    try expectNotContains(missing_noalias_read_field_body, "; mir pointer_provenance consumed fn=aggregate_field_noalias_read_direct_deref_requires_mir_field_fact subject=dst field=ptr provenance");
    try expectContains(missing_noalias_read_field_body, "load atomic i32, ptr %");
    try expectContains(missing_noalias_read_field_body, " unordered, align 4");
    try expectNotContains(missing_noalias_read_field_body, "load i32, ptr %");

    var missing_casted_noalias_read_field_output: std.ArrayList(u8) = .empty;
    defer missing_casted_noalias_read_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_field_missing_casted_noalias_read_field_provenance.mc", source, "aggregate_field_casted_noalias_read_direct_deref_requires_mir_field_fact", "dst", "ptr", &missing_casted_noalias_read_field_output);

    const missing_casted_noalias_read_field_body = try llvmFunctionBody(missing_casted_noalias_read_field_output.items, "define internal i32 @aggregate_field_casted_noalias_read_direct_deref_requires_mir_field_fact");
    try expectContains(missing_casted_noalias_read_field_body, "; mir pointer_provenance consumed fn=aggregate_field_casted_noalias_read_direct_deref_requires_mir_field_fact subject=src field=ptr provenance=global_storage reason=none");
    try expectNotContains(missing_casted_noalias_read_field_body, "; mir pointer_provenance consumed fn=aggregate_field_casted_noalias_read_direct_deref_requires_mir_field_fact subject=dst field=ptr provenance");
    try expectContains(missing_casted_noalias_read_field_body, "load atomic i32, ptr %");
    try expectContains(missing_casted_noalias_read_field_body, " unordered, align 4");
    try expectNotContains(missing_casted_noalias_read_field_body, "load i32, ptr %");

    var missing_literal_pointer_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_literal_pointer_copy_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_field_missing_literal_pointer_copy_field_provenance.mc", source, "aggregate_field_literal_pointer_copy_direct_deref_requires_mir_field_fact", "holder", "ptr", &missing_literal_pointer_copy_field_output);

    const missing_literal_pointer_copy_field_body = try llvmFunctionBody(missing_literal_pointer_copy_field_output.items, "define internal i32 @aggregate_field_literal_pointer_copy_direct_deref_requires_mir_field_fact");
    try expectContains(missing_literal_pointer_copy_field_body, "; mir pointer_provenance consumed fn=aggregate_field_literal_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none");
    try expectNotContains(missing_literal_pointer_copy_field_body, "; mir pointer_provenance consumed fn=aggregate_field_literal_pointer_copy_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance");
    try expectContains(missing_literal_pointer_copy_field_body, "load atomic i32, ptr %");
    try expectContains(missing_literal_pointer_copy_field_body, " unordered, align 4");
    try expectNotContains(missing_literal_pointer_copy_field_body, "load i32, ptr %");

    var missing_literal_raw_many_zero_field_output: std.ArrayList(u8) = .empty;
    defer missing_literal_raw_many_zero_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_field_missing_literal_raw_many_zero_field_provenance.mc", source, "aggregate_field_literal_raw_many_zero_direct_deref_requires_mir_field_fact", "holder", "ptr", &missing_literal_raw_many_zero_field_output);

    const missing_literal_raw_many_zero_field_body = try llvmFunctionBody(missing_literal_raw_many_zero_field_output.items, "define internal i32 @aggregate_field_literal_raw_many_zero_direct_deref_requires_mir_field_fact");
    try expectContains(missing_literal_raw_many_zero_field_body, "; mir pointer_provenance consumed fn=aggregate_field_literal_raw_many_zero_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none");
    try expectNotContains(missing_literal_raw_many_zero_field_body, "; mir pointer_provenance consumed fn=aggregate_field_literal_raw_many_zero_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance");
    try expectContains(missing_literal_raw_many_zero_field_body, "load atomic i32, ptr %");
    try expectContains(missing_literal_raw_many_zero_field_body, " unordered, align 4");
    try expectNotContains(missing_literal_raw_many_zero_field_body, "load i32, ptr %");

    var missing_literal_noalias_field_output: std.ArrayList(u8) = .empty;
    defer missing_literal_noalias_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_field_missing_literal_noalias_field_provenance.mc", source, "aggregate_field_literal_noalias_direct_deref_requires_mir_field_fact", "holder", "ptr", &missing_literal_noalias_field_output);

    const missing_literal_noalias_field_body = try llvmFunctionBody(missing_literal_noalias_field_output.items, "define internal i32 @aggregate_field_literal_noalias_direct_deref_requires_mir_field_fact");
    try expectNotContains(missing_literal_noalias_field_body, "; mir pointer_provenance consumed fn=aggregate_field_literal_noalias_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance");
    try expectContains(missing_literal_noalias_field_body, "load atomic i32, ptr %");
    try expectContains(missing_literal_noalias_field_body, " unordered, align 4");
    try expectNotContains(missing_literal_noalias_field_body, "load i32, ptr %");

    var missing_literal_reassignment_pointer_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_literal_reassignment_pointer_copy_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_field_missing_literal_reassignment_pointer_copy_field_provenance.mc", source, "aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact", "holder", "ptr", &missing_literal_reassignment_pointer_copy_field_output);

    const missing_literal_reassignment_pointer_copy_field_body = try llvmFunctionBody(missing_literal_reassignment_pointer_copy_field_output.items, "define internal i32 @aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact");
    try expectContains(missing_literal_reassignment_pointer_copy_field_body, "; mir pointer_provenance consumed fn=aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none");
    try expectNotContains(missing_literal_reassignment_pointer_copy_field_body, "; mir pointer_provenance consumed fn=aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance");
    try expectContains(missing_literal_reassignment_pointer_copy_field_body, "load atomic i32, ptr %");
    try expectContains(missing_literal_reassignment_pointer_copy_field_body, " unordered, align 4");
    try expectNotContains(missing_literal_reassignment_pointer_copy_field_body, "load i32, ptr %");

    var missing_literal_reassignment_raw_many_zero_field_output: std.ArrayList(u8) = .empty;
    defer missing_literal_reassignment_raw_many_zero_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_field_missing_literal_reassignment_raw_many_zero_field_provenance.mc", source, "aggregate_field_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact", "holder", "ptr", &missing_literal_reassignment_raw_many_zero_field_output);

    const missing_literal_reassignment_raw_many_zero_field_body = try llvmFunctionBody(missing_literal_reassignment_raw_many_zero_field_output.items, "define internal i32 @aggregate_field_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact");
    try expectContains(missing_literal_reassignment_raw_many_zero_field_body, "; mir pointer_provenance consumed fn=aggregate_field_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none");
    try expectNotContains(missing_literal_reassignment_raw_many_zero_field_body, "; mir pointer_provenance consumed fn=aggregate_field_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance");
    try expectContains(missing_literal_reassignment_raw_many_zero_field_body, "load atomic i32, ptr %");
    try expectContains(missing_literal_reassignment_raw_many_zero_field_body, " unordered, align 4");
    try expectNotContains(missing_literal_reassignment_raw_many_zero_field_body, "load i32, ptr %");

    var missing_literal_reassignment_noalias_field_output: std.ArrayList(u8) = .empty;
    defer missing_literal_reassignment_noalias_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_field_missing_literal_reassignment_noalias_field_provenance.mc", source, "aggregate_field_literal_reassignment_noalias_direct_deref_requires_mir_field_fact", "holder", "ptr", &missing_literal_reassignment_noalias_field_output);

    const missing_literal_reassignment_noalias_field_body = try llvmFunctionBody(missing_literal_reassignment_noalias_field_output.items, "define internal i32 @aggregate_field_literal_reassignment_noalias_direct_deref_requires_mir_field_fact");
    try expectNotContains(missing_literal_reassignment_noalias_field_body, "; mir pointer_provenance consumed fn=aggregate_field_literal_reassignment_noalias_direct_deref_requires_mir_field_fact subject=holder field=ptr provenance");
    try expectContains(missing_literal_reassignment_noalias_field_body, "load atomic i32, ptr %");
    try expectContains(missing_literal_reassignment_noalias_field_body, " unordered, align 4");
    try expectNotContains(missing_literal_reassignment_noalias_field_body, "load i32, ptr %");

    var missing_nested_literal_reassignment_field_output: std.ArrayList(u8) = .empty;
    defer missing_nested_literal_reassignment_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_nested_aggregate_field_missing_literal_reassignment_field_provenance.mc", source, "nested_aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact", "outer", "inner.ptr", &missing_nested_literal_reassignment_field_output);

    const missing_nested_literal_reassignment_field_body = try llvmFunctionBody(missing_nested_literal_reassignment_field_output.items, "define internal i32 @nested_aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact");
    try expectContains(missing_nested_literal_reassignment_field_body, "; mir pointer_provenance consumed fn=nested_aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none");
    try expectNotContains(missing_nested_literal_reassignment_field_body, "; mir pointer_provenance consumed fn=nested_aggregate_field_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact subject=outer field=inner.ptr provenance");
    try expectContains(missing_nested_literal_reassignment_field_body, "load atomic i32, ptr %");
    try expectContains(missing_nested_literal_reassignment_field_body, " unordered, align 4");
    try expectNotContains(missing_nested_literal_reassignment_field_body, "load i32, ptr %");

    var missing_nested_literal_reassignment_local_field_output: std.ArrayList(u8) = .empty;
    defer missing_nested_literal_reassignment_local_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_nested_aggregate_field_missing_literal_reassignment_local_field_provenance.mc", source, "nested_aggregate_field_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact", "outer", "inner.ptr", &missing_nested_literal_reassignment_local_field_output);

    const missing_nested_literal_reassignment_local_field_body = try llvmFunctionBody(missing_nested_literal_reassignment_local_field_output.items, "define internal i32 @nested_aggregate_field_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact");
    try expectContains(missing_nested_literal_reassignment_local_field_body, "; mir pointer_provenance consumed fn=nested_aggregate_field_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none");
    try expectNotContains(missing_nested_literal_reassignment_local_field_body, "; mir pointer_provenance consumed fn=nested_aggregate_field_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact subject=outer field=inner.ptr provenance");
    try expectContains(missing_nested_literal_reassignment_local_field_body, "load atomic i32, ptr %");
    try expectContains(missing_nested_literal_reassignment_local_field_body, " unordered, align 4");
    try expectNotContains(missing_nested_literal_reassignment_local_field_body, "load i32, ptr %");

    var missing_nested_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_nested_copy_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_nested_aggregate_field_missing_copy_field_provenance.mc", source, "nested_aggregate_field_copy_direct_deref_requires_mir_field_fact", "copied", "inner.ptr", &missing_nested_copy_field_output);

    const missing_nested_copy_field_body = try llvmFunctionBody(missing_nested_copy_field_output.items, "define internal i32 @nested_aggregate_field_copy_direct_deref_requires_mir_field_fact");
    try expectNotContains(missing_nested_copy_field_body, "; mir pointer_provenance consumed fn=nested_aggregate_field_copy_direct_deref_requires_mir_field_fact subject=copied field=inner.ptr provenance");
    try expectContains(missing_nested_copy_field_body, "load atomic i32, ptr %");
    try expectContains(missing_nested_copy_field_body, " unordered, align 4");
    try expectNotContains(missing_nested_copy_field_body, "load i32, ptr %");

    var missing_nested_assignment_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_nested_assignment_copy_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_nested_aggregate_field_missing_assignment_copy_field_provenance.mc", source, "nested_aggregate_field_assignment_copy_direct_deref_requires_mir_field_fact", "assigned", "inner.ptr", &missing_nested_assignment_copy_field_output);

    const missing_nested_assignment_copy_field_body = try llvmFunctionBody(missing_nested_assignment_copy_field_output.items, "define internal i32 @nested_aggregate_field_assignment_copy_direct_deref_requires_mir_field_fact");
    try expectNotContains(missing_nested_assignment_copy_field_body, "; mir pointer_provenance consumed fn=nested_aggregate_field_assignment_copy_direct_deref_requires_mir_field_fact subject=assigned field=inner.ptr provenance");
    try expectContains(missing_nested_assignment_copy_field_body, "load atomic i32, ptr %");
    try expectContains(missing_nested_assignment_copy_field_body, " unordered, align 4");
    try expectNotContains(missing_nested_assignment_copy_field_body, "load i32, ptr %");

    var missing_nested_noalias_member_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_nested_noalias_member_copy_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_nested_aggregate_field_missing_noalias_member_copy_field_provenance.mc", source, "nested_aggregate_field_noalias_member_copy_direct_deref_requires_mir_field_fact", "dst", "inner.ptr", &missing_nested_noalias_member_copy_field_output);

    const missing_nested_noalias_member_copy_field_body = try llvmFunctionBody(missing_nested_noalias_member_copy_field_output.items, "define internal i32 @nested_aggregate_field_noalias_member_copy_direct_deref_requires_mir_field_fact");
    try expectNotContains(missing_nested_noalias_member_copy_field_body, "; mir pointer_provenance consumed fn=nested_aggregate_field_noalias_member_copy_direct_deref_requires_mir_field_fact subject=dst field=inner.ptr provenance");
    try expectContains(missing_nested_noalias_member_copy_field_body, "load atomic i32, ptr %");
    try expectContains(missing_nested_noalias_member_copy_field_body, " unordered, align 4");
    try expectNotContains(missing_nested_noalias_member_copy_field_body, "load i32, ptr %");

    var missing_nested_casted_noalias_member_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_nested_casted_noalias_member_copy_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_nested_aggregate_field_missing_casted_noalias_member_copy_field_provenance.mc", source, "nested_aggregate_field_casted_noalias_member_copy_direct_deref_requires_mir_field_fact", "dst", "inner.ptr", &missing_nested_casted_noalias_member_copy_field_output);

    const missing_nested_casted_noalias_member_copy_field_body = try llvmFunctionBody(missing_nested_casted_noalias_member_copy_field_output.items, "define internal i32 @nested_aggregate_field_casted_noalias_member_copy_direct_deref_requires_mir_field_fact");
    try expectNotContains(missing_nested_casted_noalias_member_copy_field_body, "; mir pointer_provenance consumed fn=nested_aggregate_field_casted_noalias_member_copy_direct_deref_requires_mir_field_fact subject=dst field=inner.ptr provenance");
    try expectContains(missing_nested_casted_noalias_member_copy_field_body, "load atomic i32, ptr %");
    try expectContains(missing_nested_casted_noalias_member_copy_field_body, " unordered, align 4");
    try expectNotContains(missing_nested_casted_noalias_member_copy_field_body, "load i32, ptr %");

    var missing_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_copy_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_field_missing_copy_field_provenance.mc", source, "aggregate_field_local_copy_direct_deref_requires_mir_field_fact", "copied", "ptr", &missing_copy_field_output);

    const missing_copy_field_body = try llvmFunctionBody(missing_copy_field_output.items, "define internal i32 @aggregate_field_local_copy_direct_deref_requires_mir_field_fact");
    try expectNotContains(missing_copy_field_body, "; mir pointer_provenance consumed fn=aggregate_field_local_copy_direct_deref_requires_mir_field_fact subject=copied field=ptr provenance");
    try expectContains(missing_copy_field_body, "load atomic i32, ptr %");
    try expectContains(missing_copy_field_body, " unordered, align 4");
    try expectNotContains(missing_copy_field_body, "load i32, ptr %");
}

test "LLVM local aggregate pointer aliases require MIR destination facts" {
    const source =
        \\struct Holder { ptr: *mut u32, ptrs: [2]*mut u32 }
        \\
        \\fn local_alias_field_requires_mir_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let holder: Holder = .{ .ptr = &local, .ptrs = .{ &local, &local } };
        \\    let hp: *mut Holder = &holder;
        \\    let p: *mut u32 = hp.ptr;
        \\    return p.*;
        \\}
        \\
        \\fn local_alias_element_requires_mir_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let holder: Holder = .{ .ptr = &local, .ptrs = .{ &local, &local } };
        \\    let hp: *mut Holder = &holder;
        \\    let q: *mut u32 = hp.ptrs[0];
        \\    return q.*;
        \\}
    ;

    var normal_output: std.ArrayList(u8) = .empty;
    defer normal_output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_local_aggregate_pointer_alias_provenance.mc", source, &normal_output);

    const normal_field = try llvmFunctionBody(normal_output.items, "define internal i32 @local_alias_field_requires_mir_fact");
    try expectContains(normal_field, "; mir pointer_provenance consumed fn=local_alias_field_requires_mir_fact subject=p provenance=local_storage reason=none");
    try expectContains(normal_field, "load i32, ptr %");
    try expectNotContains(normal_field, "load atomic i32");

    const normal_element = try llvmFunctionBody(normal_output.items, "define internal i32 @local_alias_element_requires_mir_fact");
    try expectContains(normal_element, "; mir pointer_provenance consumed fn=local_alias_element_requires_mir_fact subject=q provenance=local_storage reason=none");
    try expectContains(normal_element, "load i32, ptr %");
    try expectNotContains(normal_element, "load atomic i32");

    var missing_field_output: std.ArrayList(u8) = .empty;
    defer missing_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_local_aggregate_pointer_alias_missing_field_fact.mc", source, "local_alias_field_requires_mir_fact", "p", &missing_field_output);
    const missing_field = try llvmFunctionBody(missing_field_output.items, "define internal i32 @local_alias_field_requires_mir_fact");
    try expectNotContains(missing_field, "; mir pointer_provenance consumed fn=local_alias_field_requires_mir_fact subject=p");
    try expectContains(missing_field, "load atomic i32, ptr %");
    try expectContains(missing_field, " unordered, align 4");
    try expectNotContains(missing_field, "load i32, ptr %");

    var missing_element_output: std.ArrayList(u8) = .empty;
    defer missing_element_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_local_aggregate_pointer_alias_missing_element_fact.mc", source, "local_alias_element_requires_mir_fact", "q", &missing_element_output);
    const missing_element = try llvmFunctionBody(missing_element_output.items, "define internal i32 @local_alias_element_requires_mir_fact");
    try expectNotContains(missing_element, "; mir pointer_provenance consumed fn=local_alias_element_requires_mir_fact subject=q");
    try expectContains(missing_element, "load atomic i32, ptr %");
    try expectContains(missing_element, " unordered, align 4");
    try expectNotContains(missing_element, "load i32, ptr %");
}

test "LLVM local pointer-array aliases require MIR destination facts" {
    const source =
        \\fn local_pointer_array_alias_requires_mir_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var ptrs: [2]*mut u32 = .{ &local, &local };
        \\    let pa: *mut [2]*mut u32 = &ptrs;
        \\    let p: *mut u32 = pa.*[0];
        \\    return p.*;
        \\}
    ;

    var normal_output: std.ArrayList(u8) = .empty;
    defer normal_output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_local_pointer_array_alias_provenance.mc", source, &normal_output);
    const normal_body = try llvmFunctionBody(normal_output.items, "define internal i32 @local_pointer_array_alias_requires_mir_fact");
    try expectContains(normal_body, "; mir pointer_provenance consumed fn=local_pointer_array_alias_requires_mir_fact subject=p provenance=local_storage reason=none");
    try expectContains(normal_body, "load i32, ptr %");
    try expectNotContains(normal_body, "load atomic i32");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_local_pointer_array_alias_missing_provenance.mc", source, "local_pointer_array_alias_requires_mir_fact", "p", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @local_pointer_array_alias_requires_mir_fact");
    try expectNotContains(missing_body, "; mir pointer_provenance consumed fn=local_pointer_array_alias_requires_mir_fact subject=p provenance");
    try expectContains(missing_body, "load atomic i32, ptr %");
    try expectContains(missing_body, " unordered, align 4");
    try expectNotContains(missing_body, "load i32, ptr %");
}

test "LLVM dynamic local pointer-array aliases require MIR destination facts" {
    const source =
        \\fn dynamic_local_pointer_array_alias_requires_mir_fact(index: usize) -> u32 {
        \\    var local: u32 = 0;
        \\    var ptrs: [2]*mut u32 = .{ &local, &local };
        \\    let pa: *mut [2]*mut u32 = &ptrs;
        \\    let p: *mut u32 = pa.*[index];
        \\    return p.*;
        \\}
    ;

    var normal_output: std.ArrayList(u8) = .empty;
    defer normal_output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_dynamic_local_pointer_array_alias_provenance.mc", source, &normal_output);
    const normal_body = try llvmFunctionBody(normal_output.items, "define internal i32 @dynamic_local_pointer_array_alias_requires_mir_fact");
    try expectContains(normal_body, "; mir pointer_provenance consumed fn=dynamic_local_pointer_array_alias_requires_mir_fact subject=p provenance=local_storage reason=none");
    try expectContains(normal_body, "load i32, ptr %");
    try expectNotContains(normal_body, "load atomic i32");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_dynamic_local_pointer_array_alias_missing_provenance.mc", source, "dynamic_local_pointer_array_alias_requires_mir_fact", "p", &missing_output);
    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @dynamic_local_pointer_array_alias_requires_mir_fact");
    try expectNotContains(missing_body, "; mir pointer_provenance consumed fn=dynamic_local_pointer_array_alias_requires_mir_fact subject=p provenance");
    try expectContains(missing_body, "load atomic i32, ptr %");
    try expectContains(missing_body, " unordered, align 4");
    try expectNotContains(missing_body, "load i32, ptr %");
}

test "LLVM aggregate pointer-array element reads without MIR destination fact lower conservatively" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptrs: [2]*mut u32 }
        \\struct RawHolder { ptrs: [2][*]mut u32 }
        \\struct Inner { ptrs: [2]*mut u32 }
        \\struct Outer { inner: Inner }
        \\struct RawInner { ptrs: [2][*]mut u32 }
        \\struct RawOuter { inner: RawInner }
        \\
        \\fn aggregate_array_element_read_requires_mir_fact() -> u32 {
        \\    let holder: Holder = .{ .ptrs = .{ &shared_counter, &shared_counter } };
        \\    let p: *mut u32 = holder.ptrs[0];
        \\    return p.*;
        \\}
        \\
        \\fn aggregate_array_element_noalias_read_requires_mir_fact() -> u32 {
        \\    let holder: Holder = .{ .ptrs = .{ &shared_counter, &shared_counter } };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        let p: *mut u32 = compiler.assume_noalias_unchecked(holder.ptrs[0], 4);
        \\        return p.*;
        \\    }
        \\}
        \\
        \\fn aggregate_array_element_assignment_requires_mir_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var holder: Holder = .{ .ptrs = .{ &local, &local } };
        \\    holder.ptrs[0] = &shared_counter;
        \\    var p: *mut u32 = &local;
        \\    p = holder.ptrs[0];
        \\    return p.*;
        \\}
        \\
        \\fn aggregate_array_element_pointer_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var holder: Holder = .{ .ptrs = .{ &local, &local } };
        \\    let gp: *mut u32 = &shared_counter;
        \\    holder.ptrs[0] = gp;
        \\    return holder.ptrs[0].*;
        \\}
        \\
        \\fn aggregate_array_element_raw_many_zero_direct_deref_requires_mir_field_fact() -> u32 {
        \\    unsafe {
        \\        var local: u32 = 0;
        \\        var holder: RawHolder = .{ .ptrs = .{ (&local) as [*]mut u32, (&local) as [*]mut u32 } };
        \\        let gp: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        holder.ptrs[0] = gp.offset(0);
        \\        return holder.ptrs[0].*;
        \\    }
        \\}
        \\
        \\fn aggregate_array_element_noalias_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var holder: Holder = .{ .ptrs = .{ &local, &local } };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        holder.ptrs[0] = compiler.assume_noalias_unchecked(&shared_counter, 4);
        \\    }
        \\    return holder.ptrs[0].*;
        \\}
        \\
        \\fn aggregate_array_element_local_pointer_copy_assignment_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var other: u32 = 0;
        \\    var holder: Holder = .{ .ptrs = .{ &other, &other } };
        \\    let lp: *mut u32 = &local;
        \\    holder.ptrs[0] = lp;
        \\    return holder.ptrs[0].*;
        \\}
        \\
        \\fn aggregate_array_element_noalias_read_direct_deref_requires_mir_field_fact() -> u32 {
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
        \\fn aggregate_array_element_casted_noalias_read_direct_deref_requires_mir_field_fact() -> u32 {
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
        \\fn aggregate_array_element_literal_pointer_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let gp: *mut u32 = &shared_counter;
        \\    let holder: Holder = .{ .ptrs = .{ gp, &local } };
        \\    return holder.ptrs[0].*;
        \\}
        \\
        \\fn aggregate_array_element_literal_raw_many_zero_direct_deref_requires_mir_field_fact() -> u32 {
        \\    unsafe {
        \\        var local: u32 = 0;
        \\        let gp: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        let holder: RawHolder = .{ .ptrs = .{ gp.offset(0), (&local) as [*]mut u32 } };
        \\        return holder.ptrs[0].*;
        \\    }
        \\}
        \\
        \\fn aggregate_array_element_literal_noalias_direct_deref_requires_mir_field_fact() -> u32 {
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        var local: u32 = 0;
        \\        let holder: Holder = .{ .ptrs = .{ compiler.assume_noalias_unchecked(&shared_counter, 4), &local } };
        \\        return holder.ptrs[0].*;
        \\    }
        \\}
        \\
        \\fn aggregate_array_element_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var holder: Holder = .{ .ptrs = .{ &local, &local } };
        \\    let gp: *mut u32 = &shared_counter;
        \\    holder = .{ .ptrs = .{ gp, &local } };
        \\    return holder.ptrs[0].*;
        \\}
        \\
        \\fn aggregate_array_element_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact() -> u32 {
        \\    unsafe {
        \\        var local: u32 = 0;
        \\        var holder: RawHolder = .{ .ptrs = .{ (&local) as [*]mut u32, (&local) as [*]mut u32 } };
        \\        let gp: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        holder = .{ .ptrs = .{ gp.offset(0), (&local) as [*]mut u32 } };
        \\        return holder.ptrs[0].*;
        \\    }
        \\}
        \\
        \\fn aggregate_array_element_literal_reassignment_noalias_direct_deref_requires_mir_field_fact() -> u32 {
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        var local: u32 = 0;
        \\        var holder: Holder = .{ .ptrs = .{ &local, &local } };
        \\        holder = .{ .ptrs = .{ compiler.assume_noalias_unchecked(&shared_counter, 4), &local } };
        \\        return holder.ptrs[0].*;
        \\    }
        \\}
        \\
        \\fn aggregate_array_element_scoped_assignment_preserves_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var holder: Holder = .{ .ptrs = .{ &local, &local } };
        \\    unsafe {
        \\        holder.ptrs[0] = &shared_counter;
        \\    }
        \\    let p: *mut u32 = holder.ptrs[0];
        \\    return p.*;
        \\}
        \\
        \\fn aggregate_array_element_scoped_direct_deref_lowers_atomic() -> u32 {
        \\    var local: u32 = 0;
        \\    var holder: Holder = .{ .ptrs = .{ &local, &local } };
        \\    unsafe {
        \\        holder.ptrs[0] = &shared_counter;
        \\    }
        \\    return holder.ptrs[0].*;
        \\}
        \\
        \\fn aggregate_array_element_local_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let holder: Holder = .{ .ptrs = .{ &local, &local } };
        \\    return holder.ptrs[0].*;
        \\}
        \\
        \\fn aggregate_array_element_local_pointer_copy_literal_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let lp: *mut u32 = &local;
        \\    let holder: Holder = .{ .ptrs = .{ lp, &local } };
        \\    return holder.ptrs[0].*;
        \\}
        \\
        \\fn aggregate_array_element_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var other: u32 = 0;
        \\    let lp: *mut u32 = &local;
        \\    var holder: Holder = .{ .ptrs = .{ &other, &other } };
        \\    holder = .{ .ptrs = .{ lp, &other } };
        \\    return holder.ptrs[0].*;
        \\}
        \\
        \\fn aggregate_array_element_copy_requires_mir_fact() -> u32 {
        \\    let holder: Holder = .{ .ptrs = .{ &shared_counter, &shared_counter } };
        \\    let copied: Holder = holder;
        \\    let p: *mut u32 = copied.ptrs[0];
        \\    return p.*;
        \\}
        \\
        \\fn aggregate_array_element_local_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let holder: Holder = .{ .ptrs = .{ &local, &local } };
        \\    let copied: Holder = holder;
        \\    return copied.ptrs[0].*;
        \\}
        \\
        \\fn nested_aggregate_array_element_read_requires_mir_fact() -> u32 {
        \\    let outer: Outer = .{ .inner = .{ .ptrs = .{ &shared_counter, &shared_counter } } };
        \\    let p: *mut u32 = outer.inner.ptrs[0];
        \\    return p.*;
        \\}
        \\
        \\fn nested_aggregate_array_element_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    let outer: Outer = .{ .inner = .{ .ptrs = .{ &shared_counter, &shared_counter } } };
        \\    let copied: Outer = outer;
        \\    return copied.inner.ptrs[0].*;
        \\}
        \\
        \\fn nested_aggregate_array_element_assignment_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    let outer: Outer = .{ .inner = .{ .ptrs = .{ &shared_counter, &shared_counter } } };
        \\    var assigned: Outer = .{ .inner = .{ .ptrs = .{ &local, &local } } };
        \\    assigned = outer;
        \\    return assigned.inner.ptrs[0].*;
        \\}
        \\
        \\fn nested_aggregate_array_element_noalias_member_copy_direct_deref_requires_mir_field_fact() -> u32 {
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
        \\fn nested_aggregate_array_element_casted_noalias_member_copy_direct_deref_requires_mir_field_fact() -> u32 {
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
        \\fn nested_aggregate_array_element_assignment_requires_mir_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var outer: Outer = .{ .inner = .{ .ptrs = .{ &local, &local } } };
        \\    outer.inner.ptrs[0] = &shared_counter;
        \\    var p: *mut u32 = &local;
        \\    p = outer.inner.ptrs[0];
        \\    return p.*;
        \\}
        \\
        \\fn nested_aggregate_array_element_literal_local_pointer_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var other: u32 = 0;
        \\    let lp: *mut u32 = &local;
        \\    let outer: Outer = .{ .inner = .{ .ptrs = .{ lp, &other } } };
        \\    return outer.inner.ptrs[0].*;
        \\}
        \\
        \\fn nested_aggregate_array_element_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var outer: Outer = .{ .inner = .{ .ptrs = .{ &local, &local } } };
        \\    let gp: *mut u32 = &shared_counter;
        \\    outer.inner = .{ .ptrs = .{ gp, &local } };
        \\    return outer.inner.ptrs[0].*;
        \\}
        \\
        \\fn nested_aggregate_array_element_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var other: u32 = 0;
        \\    var outer: Outer = .{ .inner = .{ .ptrs = .{ &other, &other } } };
        \\    let lp: *mut u32 = &local;
        \\    outer.inner = .{ .ptrs = .{ lp, &other } };
        \\    return outer.inner.ptrs[0].*;
        \\}
        \\
        \\fn nested_aggregate_array_element_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact() -> u32 {
        \\    unsafe {
        \\        var local: u32 = 0;
        \\        var outer: RawOuter = .{ .inner = .{ .ptrs = .{ (&local) as [*]mut u32, (&local) as [*]mut u32 } } };
        \\        let gp: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        outer.inner = .{ .ptrs = .{ gp.offset(0), (&local) as [*]mut u32 } };
        \\        return outer.inner.ptrs[0].*;
        \\    }
        \\}
        \\
        \\fn nested_aggregate_array_element_literal_reassignment_noalias_direct_deref_requires_mir_field_fact() -> u32 {
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        var local: u32 = 0;
        \\        var outer: Outer = .{ .inner = .{ .ptrs = .{ &local, &local } } };
        \\        outer.inner = .{ .ptrs = .{ compiler.assume_noalias_unchecked(&shared_counter, 4), &local } };
        \\        return outer.inner.ptrs[0].*;
        \\    }
        \\}
        \\
        \\fn nested_aggregate_array_element_scoped_assignment_preserves_fact() -> u32 {
        \\    var local: u32 = 0;
        \\    var outer: Outer = .{ .inner = .{ .ptrs = .{ &local, &local } } };
        \\    unsafe {
        \\        outer.inner.ptrs[0] = &shared_counter;
        \\    }
        \\    let p: *mut u32 = outer.inner.ptrs[0];
        \\    return p.*;
        \\}
        \\
        \\fn nested_aggregate_array_element_scoped_direct_deref_lowers_atomic() -> u32 {
        \\    var local: u32 = 0;
        \\    var outer: Outer = .{ .inner = .{ .ptrs = .{ &local, &local } } };
        \\    unsafe {
        \\        outer.inner.ptrs[0] = &shared_counter;
        \\    }
        \\    return outer.inner.ptrs[0].*;
        \\}
    ;

    var normal_output: std.ArrayList(u8) = .empty;
    defer normal_output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_aggregate_array_element_provenance.mc", source, &normal_output);

    const normal_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_array_element_read_requires_mir_fact");
    try expectContains(normal_body, "; mir pointer_provenance consumed fn=aggregate_array_element_read_requires_mir_fact subject=holder field=ptrs element=0 provenance=global_storage reason=none");
    try expectContains(normal_body, "; mir pointer_provenance consumed fn=aggregate_array_element_read_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectContains(normal_body, "load atomic i32, ptr %");
    try expectContains(normal_body, " unordered, align 4");

    const normal_noalias_read_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_array_element_noalias_read_requires_mir_fact");
    try expectContains(normal_noalias_read_body, "; mir pointer_provenance consumed fn=aggregate_array_element_noalias_read_requires_mir_fact subject=holder field=ptrs element=0 provenance=global_storage reason=none");
    try expectContains(normal_noalias_read_body, "; mir pointer_provenance consumed fn=aggregate_array_element_noalias_read_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectContains(normal_noalias_read_body, "load atomic i32, ptr %");
    try expectContains(normal_noalias_read_body, " unordered, align 4");
    try expectNotContains(normal_noalias_read_body, "load i32, ptr %");

    const normal_assignment_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_array_element_assignment_requires_mir_fact");
    try expectContains(normal_assignment_body, "; mir pointer_provenance consumed fn=aggregate_array_element_assignment_requires_mir_fact subject=holder field=ptrs element=0 provenance=local_storage reason=none");
    try expectContains(normal_assignment_body, "; mir pointer_provenance consumed fn=aggregate_array_element_assignment_requires_mir_fact subject=holder field=ptrs element=0 provenance=global_storage reason=reassignment");
    try expectContains(normal_assignment_body, "; mir pointer_provenance consumed fn=aggregate_array_element_assignment_requires_mir_fact subject=p provenance=global_storage reason=reassignment");
    try expectContains(normal_assignment_body, "load atomic i32, ptr %");
    try expectContains(normal_assignment_body, " unordered, align 4");

    const normal_pointer_copy_direct_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_array_element_pointer_copy_direct_deref_requires_mir_field_fact");
    try expectContains(normal_pointer_copy_direct_body, "; mir pointer_provenance consumed fn=aggregate_array_element_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none");
    try expectContains(normal_pointer_copy_direct_body, "; mir pointer_provenance consumed fn=aggregate_array_element_pointer_copy_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance=global_storage reason=reassignment");
    try expectContains(normal_pointer_copy_direct_body, "load atomic i32, ptr %");
    try expectContains(normal_pointer_copy_direct_body, " unordered, align 4");
    try expectNotContains(normal_pointer_copy_direct_body, "load i32, ptr %");

    const normal_raw_many_zero_direct_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_array_element_raw_many_zero_direct_deref_requires_mir_field_fact");
    try expectContains(normal_raw_many_zero_direct_body, "; mir pointer_provenance consumed fn=aggregate_array_element_raw_many_zero_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none");
    try expectContains(normal_raw_many_zero_direct_body, "; mir pointer_provenance consumed fn=aggregate_array_element_raw_many_zero_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance=global_storage reason=reassignment");
    try expectContains(normal_raw_many_zero_direct_body, "load atomic i32, ptr %");
    try expectContains(normal_raw_many_zero_direct_body, " unordered, align 4");
    try expectNotContains(normal_raw_many_zero_direct_body, "load i32, ptr %");

    const normal_noalias_direct_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_array_element_noalias_direct_deref_requires_mir_field_fact");
    try expectContains(normal_noalias_direct_body, "; mir pointer_provenance consumed fn=aggregate_array_element_noalias_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance=global_storage reason=reassignment");
    try expectContains(normal_noalias_direct_body, "load atomic i32, ptr %");
    try expectContains(normal_noalias_direct_body, " unordered, align 4");
    try expectNotContains(normal_noalias_direct_body, "load i32, ptr %");

    const normal_noalias_read_direct_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_array_element_noalias_read_direct_deref_requires_mir_field_fact");
    try expectContains(normal_noalias_read_direct_body, "; mir pointer_provenance consumed fn=aggregate_array_element_noalias_read_direct_deref_requires_mir_field_fact subject=src field=ptrs element=0 provenance=global_storage reason=none");
    try expectContains(normal_noalias_read_direct_body, "; mir pointer_provenance consumed fn=aggregate_array_element_noalias_read_direct_deref_requires_mir_field_fact subject=dst field=ptrs element=0 provenance=global_storage reason=reassignment");
    try expectContains(normal_noalias_read_direct_body, "load atomic i32, ptr %");
    try expectContains(normal_noalias_read_direct_body, " unordered, align 4");
    try expectNotContains(normal_noalias_read_direct_body, "load i32, ptr %");

    const normal_casted_noalias_read_direct_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_array_element_casted_noalias_read_direct_deref_requires_mir_field_fact");
    try expectContains(normal_casted_noalias_read_direct_body, "; mir pointer_provenance consumed fn=aggregate_array_element_casted_noalias_read_direct_deref_requires_mir_field_fact subject=src field=ptrs element=0 provenance=global_storage reason=none");
    try expectContains(normal_casted_noalias_read_direct_body, "; mir pointer_provenance consumed fn=aggregate_array_element_casted_noalias_read_direct_deref_requires_mir_field_fact subject=dst field=ptrs element=0 provenance=global_storage reason=reassignment");
    try expectContains(normal_casted_noalias_read_direct_body, "load atomic i32, ptr %");
    try expectContains(normal_casted_noalias_read_direct_body, " unordered, align 4");
    try expectNotContains(normal_casted_noalias_read_direct_body, "load i32, ptr %");

    const normal_local_pointer_copy_assignment_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_array_element_local_pointer_copy_assignment_direct_deref_requires_mir_field_fact");
    try expectContains(normal_local_pointer_copy_assignment_body, "; mir pointer_provenance consumed fn=aggregate_array_element_local_pointer_copy_assignment_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none");
    try expectContains(normal_local_pointer_copy_assignment_body, "; mir pointer_provenance consumed fn=aggregate_array_element_local_pointer_copy_assignment_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance=local_storage reason=reassignment");
    try expectNotContains(normal_local_pointer_copy_assignment_body, "load atomic i32, ptr %");
    try expectContains(normal_local_pointer_copy_assignment_body, "load i32, ptr %");

    const normal_literal_pointer_copy_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_array_element_literal_pointer_copy_direct_deref_requires_mir_field_fact");
    try expectContains(normal_literal_pointer_copy_body, "; mir pointer_provenance consumed fn=aggregate_array_element_literal_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none");
    try expectContains(normal_literal_pointer_copy_body, "; mir pointer_provenance consumed fn=aggregate_array_element_literal_pointer_copy_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance=global_storage reason=none");
    try expectContains(normal_literal_pointer_copy_body, "load atomic i32, ptr %");
    try expectContains(normal_literal_pointer_copy_body, " unordered, align 4");
    try expectNotContains(normal_literal_pointer_copy_body, "load i32, ptr %");

    const normal_literal_raw_many_zero_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_array_element_literal_raw_many_zero_direct_deref_requires_mir_field_fact");
    try expectContains(normal_literal_raw_many_zero_body, "; mir pointer_provenance consumed fn=aggregate_array_element_literal_raw_many_zero_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none");
    try expectContains(normal_literal_raw_many_zero_body, "; mir pointer_provenance consumed fn=aggregate_array_element_literal_raw_many_zero_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance=global_storage reason=none");
    try expectContains(normal_literal_raw_many_zero_body, "load atomic i32, ptr %");
    try expectContains(normal_literal_raw_many_zero_body, " unordered, align 4");
    try expectNotContains(normal_literal_raw_many_zero_body, "load i32, ptr %");

    const normal_literal_noalias_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_array_element_literal_noalias_direct_deref_requires_mir_field_fact");
    try expectContains(normal_literal_noalias_body, "; mir pointer_provenance consumed fn=aggregate_array_element_literal_noalias_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance=global_storage reason=none");
    try expectContains(normal_literal_noalias_body, "load atomic i32, ptr %");
    try expectContains(normal_literal_noalias_body, " unordered, align 4");
    try expectNotContains(normal_literal_noalias_body, "load i32, ptr %");

    const normal_literal_reassignment_pointer_copy_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_array_element_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact");
    try expectContains(normal_literal_reassignment_pointer_copy_body, "; mir pointer_provenance consumed fn=aggregate_array_element_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none");
    try expectContains(normal_literal_reassignment_pointer_copy_body, "; mir pointer_provenance consumed fn=aggregate_array_element_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance=global_storage reason=none");
    try expectContains(normal_literal_reassignment_pointer_copy_body, "load atomic i32, ptr %");
    try expectContains(normal_literal_reassignment_pointer_copy_body, " unordered, align 4");
    try expectNotContains(normal_literal_reassignment_pointer_copy_body, "load i32, ptr %");

    const normal_literal_reassignment_raw_many_zero_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_array_element_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact");
    try expectContains(normal_literal_reassignment_raw_many_zero_body, "; mir pointer_provenance consumed fn=aggregate_array_element_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none");
    try expectContains(normal_literal_reassignment_raw_many_zero_body, "; mir pointer_provenance consumed fn=aggregate_array_element_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance=global_storage reason=none");
    try expectContains(normal_literal_reassignment_raw_many_zero_body, "load atomic i32, ptr %");
    try expectContains(normal_literal_reassignment_raw_many_zero_body, " unordered, align 4");
    try expectNotContains(normal_literal_reassignment_raw_many_zero_body, "load i32, ptr %");

    const normal_literal_reassignment_noalias_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_array_element_literal_reassignment_noalias_direct_deref_requires_mir_field_fact");
    try expectContains(normal_literal_reassignment_noalias_body, "; mir pointer_provenance consumed fn=aggregate_array_element_literal_reassignment_noalias_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance=global_storage reason=none");
    try expectContains(normal_literal_reassignment_noalias_body, "load atomic i32, ptr %");
    try expectContains(normal_literal_reassignment_noalias_body, " unordered, align 4");
    try expectNotContains(normal_literal_reassignment_noalias_body, "load i32, ptr %");

    const normal_nested_array_literal_local_pointer_copy_body = try llvmFunctionBody(normal_output.items, "define internal i32 @nested_aggregate_array_element_literal_local_pointer_copy_direct_deref_requires_mir_field_fact");
    try expectContains(normal_nested_array_literal_local_pointer_copy_body, "; mir pointer_provenance consumed fn=nested_aggregate_array_element_literal_local_pointer_copy_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none");
    try expectContains(normal_nested_array_literal_local_pointer_copy_body, "; mir pointer_provenance consumed fn=nested_aggregate_array_element_literal_local_pointer_copy_direct_deref_requires_mir_field_fact subject=outer field=inner.ptrs element=0 provenance=local_storage reason=none");
    try expectContains(normal_nested_array_literal_local_pointer_copy_body, "load i32, ptr %");
    try expectNotContains(normal_nested_array_literal_local_pointer_copy_body, "load atomic i32, ptr %");

    const normal_nested_array_literal_reassignment_pointer_copy_body = try llvmFunctionBody(normal_output.items, "define internal i32 @nested_aggregate_array_element_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact");
    try expectContains(normal_nested_array_literal_reassignment_pointer_copy_body, "; mir pointer_provenance consumed fn=nested_aggregate_array_element_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none");
    try expectContains(normal_nested_array_literal_reassignment_pointer_copy_body, "; mir pointer_provenance consumed fn=nested_aggregate_array_element_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact subject=outer field=inner.ptrs element=0 provenance=global_storage reason=none");
    try expectContains(normal_nested_array_literal_reassignment_pointer_copy_body, "load atomic i32, ptr %");
    try expectContains(normal_nested_array_literal_reassignment_pointer_copy_body, " unordered, align 4");
    try expectNotContains(normal_nested_array_literal_reassignment_pointer_copy_body, "load i32, ptr %");

    const normal_nested_array_literal_reassignment_local_pointer_copy_body = try llvmFunctionBody(normal_output.items, "define internal i32 @nested_aggregate_array_element_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact");
    try expectContains(normal_nested_array_literal_reassignment_local_pointer_copy_body, "; mir pointer_provenance consumed fn=nested_aggregate_array_element_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none");
    try expectContains(normal_nested_array_literal_reassignment_local_pointer_copy_body, "; mir pointer_provenance consumed fn=nested_aggregate_array_element_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact subject=outer field=inner.ptrs element=0 provenance=local_storage reason=none");
    try expectContains(normal_nested_array_literal_reassignment_local_pointer_copy_body, "load i32, ptr %");
    try expectNotContains(normal_nested_array_literal_reassignment_local_pointer_copy_body, "load atomic i32, ptr %");

    const normal_nested_array_literal_reassignment_raw_many_zero_body = try llvmFunctionBody(normal_output.items, "define internal i32 @nested_aggregate_array_element_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact");
    try expectContains(normal_nested_array_literal_reassignment_raw_many_zero_body, "; mir pointer_provenance consumed fn=nested_aggregate_array_element_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none");
    try expectContains(normal_nested_array_literal_reassignment_raw_many_zero_body, "; mir pointer_provenance consumed fn=nested_aggregate_array_element_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact subject=outer field=inner.ptrs element=0 provenance=global_storage reason=none");
    try expectContains(normal_nested_array_literal_reassignment_raw_many_zero_body, "load atomic i32, ptr %");
    try expectContains(normal_nested_array_literal_reassignment_raw_many_zero_body, " unordered, align 4");
    try expectNotContains(normal_nested_array_literal_reassignment_raw_many_zero_body, "load i32, ptr %");

    const normal_nested_array_literal_reassignment_noalias_body = try llvmFunctionBody(normal_output.items, "define internal i32 @nested_aggregate_array_element_literal_reassignment_noalias_direct_deref_requires_mir_field_fact");
    try expectContains(normal_nested_array_literal_reassignment_noalias_body, "; mir pointer_provenance consumed fn=nested_aggregate_array_element_literal_reassignment_noalias_direct_deref_requires_mir_field_fact subject=outer field=inner.ptrs element=0 provenance=global_storage reason=none");
    try expectContains(normal_nested_array_literal_reassignment_noalias_body, "load atomic i32, ptr %");
    try expectContains(normal_nested_array_literal_reassignment_noalias_body, " unordered, align 4");
    try expectNotContains(normal_nested_array_literal_reassignment_noalias_body, "load i32, ptr %");

    const normal_nested_array_copy_body = try llvmFunctionBody(normal_output.items, "define internal i32 @nested_aggregate_array_element_copy_direct_deref_requires_mir_field_fact");
    try expectContains(normal_nested_array_copy_body, "; mir pointer_provenance consumed fn=nested_aggregate_array_element_copy_direct_deref_requires_mir_field_fact subject=copied field=inner.ptrs element=0 provenance=global_storage reason=none");
    try expectContains(normal_nested_array_copy_body, "load atomic i32, ptr %");
    try expectContains(normal_nested_array_copy_body, " unordered, align 4");
    try expectNotContains(normal_nested_array_copy_body, "load i32, ptr %");

    const normal_nested_array_assignment_copy_body = try llvmFunctionBody(normal_output.items, "define internal i32 @nested_aggregate_array_element_assignment_copy_direct_deref_requires_mir_field_fact");
    try expectContains(normal_nested_array_assignment_copy_body, "; mir pointer_provenance consumed fn=nested_aggregate_array_element_assignment_copy_direct_deref_requires_mir_field_fact subject=assigned field=inner.ptrs element=0 provenance=global_storage reason=reassignment");
    try expectContains(normal_nested_array_assignment_copy_body, "load atomic i32, ptr %");
    try expectContains(normal_nested_array_assignment_copy_body, " unordered, align 4");
    try expectNotContains(normal_nested_array_assignment_copy_body, "load i32, ptr %");

    const normal_nested_array_noalias_member_copy_body = try llvmFunctionBody(normal_output.items, "define internal i32 @nested_aggregate_array_element_noalias_member_copy_direct_deref_requires_mir_field_fact");
    try expectContains(normal_nested_array_noalias_member_copy_body, "; mir pointer_provenance consumed fn=nested_aggregate_array_element_noalias_member_copy_direct_deref_requires_mir_field_fact subject=dst field=inner.ptrs element=0 provenance=global_storage reason=reassignment");
    try expectContains(normal_nested_array_noalias_member_copy_body, "load atomic i32, ptr %");
    try expectContains(normal_nested_array_noalias_member_copy_body, " unordered, align 4");
    try expectNotContains(normal_nested_array_noalias_member_copy_body, "load i32, ptr %");

    const normal_nested_array_casted_noalias_member_copy_body = try llvmFunctionBody(normal_output.items, "define internal i32 @nested_aggregate_array_element_casted_noalias_member_copy_direct_deref_requires_mir_field_fact");
    try expectContains(normal_nested_array_casted_noalias_member_copy_body, "; mir pointer_provenance consumed fn=nested_aggregate_array_element_casted_noalias_member_copy_direct_deref_requires_mir_field_fact subject=dst field=inner.ptrs element=0 provenance=global_storage reason=reassignment");
    try expectContains(normal_nested_array_casted_noalias_member_copy_body, "load atomic i32, ptr %");
    try expectContains(normal_nested_array_casted_noalias_member_copy_body, " unordered, align 4");
    try expectNotContains(normal_nested_array_casted_noalias_member_copy_body, "load i32, ptr %");

    const normal_scoped_assignment_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_array_element_scoped_assignment_preserves_fact");
    try expectContains(normal_scoped_assignment_body, "; mir pointer_provenance consumed fn=aggregate_array_element_scoped_assignment_preserves_fact subject=p provenance=global_storage reason=none");
    try expectContains(normal_scoped_assignment_body, "load atomic i32, ptr %");
    try expectContains(normal_scoped_assignment_body, " unordered, align 4");
    try expectNotContains(normal_scoped_assignment_body, "load i32, ptr %");

    const normal_scoped_direct_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_array_element_scoped_direct_deref_lowers_atomic");
    try expectContains(normal_scoped_direct_body, "; mir pointer_provenance consumed fn=aggregate_array_element_scoped_direct_deref_lowers_atomic subject=holder field=ptrs element=0 provenance=global_storage reason=reassignment");
    try expectContains(normal_scoped_direct_body, "load atomic i32, ptr %");
    try expectContains(normal_scoped_direct_body, " unordered, align 4");
    try expectNotContains(normal_scoped_direct_body, "load i32, ptr %");

    const normal_local_direct_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_array_element_local_direct_deref_requires_mir_field_fact");
    try expectContains(normal_local_direct_body, "; mir pointer_provenance consumed fn=aggregate_array_element_local_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance=local_storage reason=none");
    try expectContains(normal_local_direct_body, "load i32, ptr %");
    try expectNotContains(normal_local_direct_body, "load atomic i32, ptr %");

    const normal_local_pointer_copy_literal_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_array_element_local_pointer_copy_literal_direct_deref_requires_mir_field_fact");
    try expectContains(normal_local_pointer_copy_literal_body, "; mir pointer_provenance consumed fn=aggregate_array_element_local_pointer_copy_literal_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none");
    try expectContains(normal_local_pointer_copy_literal_body, "; mir pointer_provenance consumed fn=aggregate_array_element_local_pointer_copy_literal_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance=local_storage reason=none");
    try expectContains(normal_local_pointer_copy_literal_body, "load i32, ptr %");
    try expectNotContains(normal_local_pointer_copy_literal_body, "load atomic i32, ptr %");

    const normal_local_pointer_copy_literal_reassignment_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_array_element_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact");
    try expectContains(normal_local_pointer_copy_literal_reassignment_body, "; mir pointer_provenance consumed fn=aggregate_array_element_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none");
    try expectContains(normal_local_pointer_copy_literal_reassignment_body, "; mir pointer_provenance consumed fn=aggregate_array_element_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance=local_storage reason=none");
    try expectContains(normal_local_pointer_copy_literal_reassignment_body, "load i32, ptr %");
    try expectNotContains(normal_local_pointer_copy_literal_reassignment_body, "load atomic i32, ptr %");

    const normal_copy_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_array_element_copy_requires_mir_fact");
    try expectContains(normal_copy_body, "; mir pointer_provenance consumed fn=aggregate_array_element_copy_requires_mir_fact subject=copied field=ptrs element=0 provenance=global_storage reason=none");
    try expectContains(normal_copy_body, "; mir pointer_provenance consumed fn=aggregate_array_element_copy_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectContains(normal_copy_body, "load atomic i32, ptr %");
    try expectContains(normal_copy_body, " unordered, align 4");

    const normal_local_copy_body = try llvmFunctionBody(normal_output.items, "define internal i32 @aggregate_array_element_local_copy_direct_deref_requires_mir_field_fact");
    try expectContains(normal_local_copy_body, "; mir pointer_provenance consumed fn=aggregate_array_element_local_copy_direct_deref_requires_mir_field_fact subject=copied field=ptrs element=0 provenance=local_storage reason=none");
    try expectContains(normal_local_copy_body, "load i32, ptr %");
    try expectNotContains(normal_local_copy_body, "load atomic i32, ptr %");

    const normal_nested_body = try llvmFunctionBody(normal_output.items, "define internal i32 @nested_aggregate_array_element_read_requires_mir_fact");
    try expectContains(normal_nested_body, "; mir pointer_provenance consumed fn=nested_aggregate_array_element_read_requires_mir_fact subject=p provenance=global_storage reason=none");
    try expectContains(normal_nested_body, "load atomic i32, ptr %");
    try expectContains(normal_nested_body, " unordered, align 4");

    const normal_nested_assignment_body = try llvmFunctionBody(normal_output.items, "define internal i32 @nested_aggregate_array_element_assignment_requires_mir_fact");
    try expectContains(normal_nested_assignment_body, "; mir pointer_provenance consumed fn=nested_aggregate_array_element_assignment_requires_mir_fact subject=p provenance=global_storage reason=reassignment");
    try expectContains(normal_nested_assignment_body, "load atomic i32, ptr %");
    try expectContains(normal_nested_assignment_body, " unordered, align 4");

    const normal_nested_scoped_body = try llvmFunctionBody(normal_output.items, "define internal i32 @nested_aggregate_array_element_scoped_assignment_preserves_fact");
    try expectContains(normal_nested_scoped_body, "; mir pointer_provenance consumed fn=nested_aggregate_array_element_scoped_assignment_preserves_fact subject=p provenance=global_storage reason=none");
    try expectContains(normal_nested_scoped_body, "load atomic i32, ptr %");
    try expectContains(normal_nested_scoped_body, " unordered, align 4");
    try expectNotContains(normal_nested_scoped_body, "load i32, ptr %");

    const normal_nested_scoped_direct_body = try llvmFunctionBody(normal_output.items, "define internal i32 @nested_aggregate_array_element_scoped_direct_deref_lowers_atomic");
    try expectContains(normal_nested_scoped_direct_body, "load atomic i32, ptr %");
    try expectContains(normal_nested_scoped_direct_body, " unordered, align 4");
    try expectNotContains(normal_nested_scoped_direct_body, "load i32, ptr %");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_aggregate_array_element_missing_provenance.mc", source, "aggregate_array_element_read_requires_mir_fact", "p", &missing_output);

    const missing_body = try llvmFunctionBody(missing_output.items, "define internal i32 @aggregate_array_element_read_requires_mir_fact");
    try expectNotContains(missing_body, "; mir pointer_provenance consumed fn=aggregate_array_element_read_requires_mir_fact subject=p provenance");
    try expectContains(missing_body, "load atomic i32, ptr %");
    try expectContains(missing_body, " unordered, align 4");
    try expectNotContains(missing_body, "load i32, ptr %");

    var missing_noalias_read_output: std.ArrayList(u8) = .empty;
    defer missing_noalias_read_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_aggregate_array_element_missing_noalias_read_provenance.mc", source, "aggregate_array_element_noalias_read_requires_mir_fact", "p", &missing_noalias_read_output);

    const missing_noalias_read_body = try llvmFunctionBody(missing_noalias_read_output.items, "define internal i32 @aggregate_array_element_noalias_read_requires_mir_fact");
    try expectContains(missing_noalias_read_body, "; mir pointer_provenance consumed fn=aggregate_array_element_noalias_read_requires_mir_fact subject=holder field=ptrs element=0 provenance=global_storage reason=none");
    try expectNotContains(missing_noalias_read_body, "; mir pointer_provenance consumed fn=aggregate_array_element_noalias_read_requires_mir_fact subject=p provenance");
    try expectContains(missing_noalias_read_body, "load atomic i32, ptr %");
    try expectContains(missing_noalias_read_body, " unordered, align 4");
    try expectNotContains(missing_noalias_read_body, "load i32, ptr %");

    var missing_assignment_output: std.ArrayList(u8) = .empty;
    defer missing_assignment_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_aggregate_array_element_missing_provenance.mc", source, "aggregate_array_element_assignment_requires_mir_fact", "p", &missing_assignment_output);

    const missing_assignment_body = try llvmFunctionBody(missing_assignment_output.items, "define internal i32 @aggregate_array_element_assignment_requires_mir_fact");
    try expectNotContains(missing_assignment_body, "; mir pointer_provenance consumed fn=aggregate_array_element_assignment_requires_mir_fact subject=p provenance");
    try expectContains(missing_assignment_body, "load atomic i32, ptr %");
    try expectContains(missing_assignment_body, " unordered, align 4");
    try expectNotContains(missing_assignment_body, "load i32, ptr %");

    var missing_copy_output: std.ArrayList(u8) = .empty;
    defer missing_copy_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_aggregate_array_element_missing_provenance.mc", source, "aggregate_array_element_copy_requires_mir_fact", "p", &missing_copy_output);

    const missing_copy_body = try llvmFunctionBody(missing_copy_output.items, "define internal i32 @aggregate_array_element_copy_requires_mir_fact");
    try expectNotContains(missing_copy_body, "; mir pointer_provenance consumed fn=aggregate_array_element_copy_requires_mir_fact subject=p provenance");
    try expectContains(missing_copy_body, "load atomic i32, ptr %");
    try expectContains(missing_copy_body, " unordered, align 4");
    try expectNotContains(missing_copy_body, "load i32, ptr %");

    var missing_nested_output: std.ArrayList(u8) = .empty;
    defer missing_nested_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_aggregate_array_element_missing_provenance.mc", source, "nested_aggregate_array_element_read_requires_mir_fact", "p", &missing_nested_output);

    const missing_nested_body = try llvmFunctionBody(missing_nested_output.items, "define internal i32 @nested_aggregate_array_element_read_requires_mir_fact");
    try expectNotContains(missing_nested_body, "; mir pointer_provenance consumed fn=nested_aggregate_array_element_read_requires_mir_fact subject=p provenance");
    try expectContains(missing_nested_body, "load atomic i32, ptr %");
    try expectContains(missing_nested_body, " unordered, align 4");
    try expectNotContains(missing_nested_body, "load i32, ptr %");

    var missing_nested_assignment_output: std.ArrayList(u8) = .empty;
    defer missing_nested_assignment_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubject("llvm_aggregate_array_element_missing_provenance.mc", source, "nested_aggregate_array_element_assignment_requires_mir_fact", "p", &missing_nested_assignment_output);

    const missing_nested_assignment_body = try llvmFunctionBody(missing_nested_assignment_output.items, "define internal i32 @nested_aggregate_array_element_assignment_requires_mir_fact");
    try expectNotContains(missing_nested_assignment_body, "; mir pointer_provenance consumed fn=nested_aggregate_array_element_assignment_requires_mir_fact subject=p provenance");
    try expectContains(missing_nested_assignment_body, "load atomic i32, ptr %");
    try expectContains(missing_nested_assignment_body, " unordered, align 4");
    try expectNotContains(missing_nested_assignment_body, "load i32, ptr %");

    var missing_field_output: std.ArrayList(u8) = .empty;
    defer missing_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_array_element_missing_field_provenance.mc", source, "aggregate_array_element_local_direct_deref_requires_mir_field_fact", "holder", "ptrs", &missing_field_output);

    const missing_field_body = try llvmFunctionBody(missing_field_output.items, "define internal i32 @aggregate_array_element_local_direct_deref_requires_mir_field_fact");
    try expectNotContains(missing_field_body, "; mir pointer_provenance consumed fn=aggregate_array_element_local_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance");
    try expectContains(missing_field_body, "load atomic i32, ptr %");
    try expectContains(missing_field_body, " unordered, align 4");
    try expectNotContains(missing_field_body, "load i32, ptr %");

    var missing_local_pointer_copy_literal_field_output: std.ArrayList(u8) = .empty;
    defer missing_local_pointer_copy_literal_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_array_element_missing_local_pointer_copy_literal_field_provenance.mc", source, "aggregate_array_element_local_pointer_copy_literal_direct_deref_requires_mir_field_fact", "holder", "ptrs", &missing_local_pointer_copy_literal_field_output);

    const missing_local_pointer_copy_literal_field_body = try llvmFunctionBody(missing_local_pointer_copy_literal_field_output.items, "define internal i32 @aggregate_array_element_local_pointer_copy_literal_direct_deref_requires_mir_field_fact");
    try expectContains(missing_local_pointer_copy_literal_field_body, "; mir pointer_provenance consumed fn=aggregate_array_element_local_pointer_copy_literal_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none");
    try expectNotContains(missing_local_pointer_copy_literal_field_body, "; mir pointer_provenance consumed fn=aggregate_array_element_local_pointer_copy_literal_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance");
    try expectContains(missing_local_pointer_copy_literal_field_body, "load atomic i32, ptr %");
    try expectContains(missing_local_pointer_copy_literal_field_body, " unordered, align 4");
    try expectNotContains(missing_local_pointer_copy_literal_field_body, "load i32, ptr %");

    var missing_nested_local_pointer_copy_literal_field_output: std.ArrayList(u8) = .empty;
    defer missing_nested_local_pointer_copy_literal_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_nested_aggregate_array_element_missing_local_pointer_copy_literal_field_provenance.mc", source, "nested_aggregate_array_element_literal_local_pointer_copy_direct_deref_requires_mir_field_fact", "outer", "inner.ptrs", &missing_nested_local_pointer_copy_literal_field_output);

    const missing_nested_local_pointer_copy_literal_field_body = try llvmFunctionBody(missing_nested_local_pointer_copy_literal_field_output.items, "define internal i32 @nested_aggregate_array_element_literal_local_pointer_copy_direct_deref_requires_mir_field_fact");
    try expectContains(missing_nested_local_pointer_copy_literal_field_body, "; mir pointer_provenance consumed fn=nested_aggregate_array_element_literal_local_pointer_copy_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none");
    try expectNotContains(missing_nested_local_pointer_copy_literal_field_body, "; mir pointer_provenance consumed fn=nested_aggregate_array_element_literal_local_pointer_copy_direct_deref_requires_mir_field_fact subject=outer field=inner.ptrs element=0 provenance");
    try expectContains(missing_nested_local_pointer_copy_literal_field_body, "load atomic i32, ptr %");
    try expectContains(missing_nested_local_pointer_copy_literal_field_body, " unordered, align 4");
    try expectNotContains(missing_nested_local_pointer_copy_literal_field_body, "load i32, ptr %");

    var missing_local_pointer_copy_literal_reassignment_field_output: std.ArrayList(u8) = .empty;
    defer missing_local_pointer_copy_literal_reassignment_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_array_element_missing_local_pointer_copy_literal_reassignment_field_provenance.mc", source, "aggregate_array_element_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact", "holder", "ptrs", &missing_local_pointer_copy_literal_reassignment_field_output);

    const missing_local_pointer_copy_literal_reassignment_field_body = try llvmFunctionBody(missing_local_pointer_copy_literal_reassignment_field_output.items, "define internal i32 @aggregate_array_element_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact");
    try expectContains(missing_local_pointer_copy_literal_reassignment_field_body, "; mir pointer_provenance consumed fn=aggregate_array_element_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none");
    try expectNotContains(missing_local_pointer_copy_literal_reassignment_field_body, "; mir pointer_provenance consumed fn=aggregate_array_element_local_pointer_copy_literal_reassignment_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance");
    try expectContains(missing_local_pointer_copy_literal_reassignment_field_body, "load atomic i32, ptr %");
    try expectContains(missing_local_pointer_copy_literal_reassignment_field_body, " unordered, align 4");
    try expectNotContains(missing_local_pointer_copy_literal_reassignment_field_body, "load i32, ptr %");

    var missing_nested_local_pointer_copy_literal_reassignment_field_output: std.ArrayList(u8) = .empty;
    defer missing_nested_local_pointer_copy_literal_reassignment_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_nested_aggregate_array_element_missing_local_pointer_copy_literal_reassignment_field_provenance.mc", source, "nested_aggregate_array_element_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact", "outer", "inner.ptrs", &missing_nested_local_pointer_copy_literal_reassignment_field_output);

    const missing_nested_local_pointer_copy_literal_reassignment_field_body = try llvmFunctionBody(missing_nested_local_pointer_copy_literal_reassignment_field_output.items, "define internal i32 @nested_aggregate_array_element_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact");
    try expectContains(missing_nested_local_pointer_copy_literal_reassignment_field_body, "; mir pointer_provenance consumed fn=nested_aggregate_array_element_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none");
    try expectNotContains(missing_nested_local_pointer_copy_literal_reassignment_field_body, "; mir pointer_provenance consumed fn=nested_aggregate_array_element_literal_reassignment_local_pointer_copy_direct_deref_requires_mir_field_fact subject=outer field=inner.ptrs element=0 provenance");
    try expectContains(missing_nested_local_pointer_copy_literal_reassignment_field_body, "load atomic i32, ptr %");
    try expectContains(missing_nested_local_pointer_copy_literal_reassignment_field_body, " unordered, align 4");
    try expectNotContains(missing_nested_local_pointer_copy_literal_reassignment_field_body, "load i32, ptr %");

    var missing_local_pointer_copy_assignment_field_output: std.ArrayList(u8) = .empty;
    defer missing_local_pointer_copy_assignment_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_array_element_missing_local_pointer_copy_assignment_field_provenance.mc", source, "aggregate_array_element_local_pointer_copy_assignment_direct_deref_requires_mir_field_fact", "holder", "ptrs", &missing_local_pointer_copy_assignment_field_output);

    const missing_local_pointer_copy_assignment_field_body = try llvmFunctionBody(missing_local_pointer_copy_assignment_field_output.items, "define internal i32 @aggregate_array_element_local_pointer_copy_assignment_direct_deref_requires_mir_field_fact");
    try expectContains(missing_local_pointer_copy_assignment_field_body, "; mir pointer_provenance consumed fn=aggregate_array_element_local_pointer_copy_assignment_direct_deref_requires_mir_field_fact subject=lp provenance=local_storage reason=none");
    try expectNotContains(missing_local_pointer_copy_assignment_field_body, "; mir pointer_provenance consumed fn=aggregate_array_element_local_pointer_copy_assignment_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance");
    try expectContains(missing_local_pointer_copy_assignment_field_body, "load atomic i32, ptr %");
    try expectContains(missing_local_pointer_copy_assignment_field_body, " unordered, align 4");
    try expectNotContains(missing_local_pointer_copy_assignment_field_body, "load i32, ptr %");

    var missing_pointer_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_pointer_copy_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_array_element_missing_pointer_copy_field_provenance.mc", source, "aggregate_array_element_pointer_copy_direct_deref_requires_mir_field_fact", "holder", "ptrs", &missing_pointer_copy_field_output);

    const missing_pointer_copy_field_body = try llvmFunctionBody(missing_pointer_copy_field_output.items, "define internal i32 @aggregate_array_element_pointer_copy_direct_deref_requires_mir_field_fact");
    try expectContains(missing_pointer_copy_field_body, "; mir pointer_provenance consumed fn=aggregate_array_element_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none");
    try expectNotContains(missing_pointer_copy_field_body, "; mir pointer_provenance consumed fn=aggregate_array_element_pointer_copy_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance");
    try expectContains(missing_pointer_copy_field_body, "load atomic i32, ptr %");
    try expectContains(missing_pointer_copy_field_body, " unordered, align 4");
    try expectNotContains(missing_pointer_copy_field_body, "load i32, ptr %");

    var missing_raw_many_zero_field_output: std.ArrayList(u8) = .empty;
    defer missing_raw_many_zero_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_array_element_missing_raw_many_zero_field_provenance.mc", source, "aggregate_array_element_raw_many_zero_direct_deref_requires_mir_field_fact", "holder", "ptrs", &missing_raw_many_zero_field_output);

    const missing_raw_many_zero_field_body = try llvmFunctionBody(missing_raw_many_zero_field_output.items, "define internal i32 @aggregate_array_element_raw_many_zero_direct_deref_requires_mir_field_fact");
    try expectContains(missing_raw_many_zero_field_body, "; mir pointer_provenance consumed fn=aggregate_array_element_raw_many_zero_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none");
    try expectNotContains(missing_raw_many_zero_field_body, "; mir pointer_provenance consumed fn=aggregate_array_element_raw_many_zero_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance");
    try expectContains(missing_raw_many_zero_field_body, "load atomic i32, ptr %");
    try expectContains(missing_raw_many_zero_field_body, " unordered, align 4");
    try expectNotContains(missing_raw_many_zero_field_body, "load i32, ptr %");

    var missing_noalias_field_output: std.ArrayList(u8) = .empty;
    defer missing_noalias_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_array_element_missing_noalias_field_provenance.mc", source, "aggregate_array_element_noalias_direct_deref_requires_mir_field_fact", "holder", "ptrs", &missing_noalias_field_output);

    const missing_noalias_field_body = try llvmFunctionBody(missing_noalias_field_output.items, "define internal i32 @aggregate_array_element_noalias_direct_deref_requires_mir_field_fact");
    try expectNotContains(missing_noalias_field_body, "; mir pointer_provenance consumed fn=aggregate_array_element_noalias_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance");
    try expectContains(missing_noalias_field_body, "load atomic i32, ptr %");
    try expectContains(missing_noalias_field_body, " unordered, align 4");
    try expectNotContains(missing_noalias_field_body, "load i32, ptr %");

    var missing_noalias_read_field_output: std.ArrayList(u8) = .empty;
    defer missing_noalias_read_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_array_element_missing_noalias_read_field_provenance.mc", source, "aggregate_array_element_noalias_read_direct_deref_requires_mir_field_fact", "dst", "ptrs", &missing_noalias_read_field_output);

    const missing_noalias_read_field_body = try llvmFunctionBody(missing_noalias_read_field_output.items, "define internal i32 @aggregate_array_element_noalias_read_direct_deref_requires_mir_field_fact");
    try expectContains(missing_noalias_read_field_body, "; mir pointer_provenance consumed fn=aggregate_array_element_noalias_read_direct_deref_requires_mir_field_fact subject=src field=ptrs element=0 provenance=global_storage reason=none");
    try expectNotContains(missing_noalias_read_field_body, "; mir pointer_provenance consumed fn=aggregate_array_element_noalias_read_direct_deref_requires_mir_field_fact subject=dst field=ptrs element=0 provenance");
    try expectContains(missing_noalias_read_field_body, "load atomic i32, ptr %");
    try expectContains(missing_noalias_read_field_body, " unordered, align 4");
    try expectNotContains(missing_noalias_read_field_body, "load i32, ptr %");

    var missing_casted_noalias_read_field_output: std.ArrayList(u8) = .empty;
    defer missing_casted_noalias_read_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_array_element_missing_casted_noalias_read_field_provenance.mc", source, "aggregate_array_element_casted_noalias_read_direct_deref_requires_mir_field_fact", "dst", "ptrs", &missing_casted_noalias_read_field_output);

    const missing_casted_noalias_read_field_body = try llvmFunctionBody(missing_casted_noalias_read_field_output.items, "define internal i32 @aggregate_array_element_casted_noalias_read_direct_deref_requires_mir_field_fact");
    try expectContains(missing_casted_noalias_read_field_body, "; mir pointer_provenance consumed fn=aggregate_array_element_casted_noalias_read_direct_deref_requires_mir_field_fact subject=src field=ptrs element=0 provenance=global_storage reason=none");
    try expectNotContains(missing_casted_noalias_read_field_body, "; mir pointer_provenance consumed fn=aggregate_array_element_casted_noalias_read_direct_deref_requires_mir_field_fact subject=dst field=ptrs element=0 provenance");
    try expectContains(missing_casted_noalias_read_field_body, "load atomic i32, ptr %");
    try expectContains(missing_casted_noalias_read_field_body, " unordered, align 4");
    try expectNotContains(missing_casted_noalias_read_field_body, "load i32, ptr %");

    var missing_literal_pointer_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_literal_pointer_copy_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_array_element_missing_literal_pointer_copy_field_provenance.mc", source, "aggregate_array_element_literal_pointer_copy_direct_deref_requires_mir_field_fact", "holder", "ptrs", &missing_literal_pointer_copy_field_output);

    const missing_literal_pointer_copy_field_body = try llvmFunctionBody(missing_literal_pointer_copy_field_output.items, "define internal i32 @aggregate_array_element_literal_pointer_copy_direct_deref_requires_mir_field_fact");
    try expectContains(missing_literal_pointer_copy_field_body, "; mir pointer_provenance consumed fn=aggregate_array_element_literal_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none");
    try expectNotContains(missing_literal_pointer_copy_field_body, "; mir pointer_provenance consumed fn=aggregate_array_element_literal_pointer_copy_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance");
    try expectContains(missing_literal_pointer_copy_field_body, "load atomic i32, ptr %");
    try expectContains(missing_literal_pointer_copy_field_body, " unordered, align 4");
    try expectNotContains(missing_literal_pointer_copy_field_body, "load i32, ptr %");

    var missing_literal_raw_many_zero_field_output: std.ArrayList(u8) = .empty;
    defer missing_literal_raw_many_zero_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_array_element_missing_literal_raw_many_zero_field_provenance.mc", source, "aggregate_array_element_literal_raw_many_zero_direct_deref_requires_mir_field_fact", "holder", "ptrs", &missing_literal_raw_many_zero_field_output);

    const missing_literal_raw_many_zero_field_body = try llvmFunctionBody(missing_literal_raw_many_zero_field_output.items, "define internal i32 @aggregate_array_element_literal_raw_many_zero_direct_deref_requires_mir_field_fact");
    try expectContains(missing_literal_raw_many_zero_field_body, "; mir pointer_provenance consumed fn=aggregate_array_element_literal_raw_many_zero_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none");
    try expectNotContains(missing_literal_raw_many_zero_field_body, "; mir pointer_provenance consumed fn=aggregate_array_element_literal_raw_many_zero_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance");
    try expectContains(missing_literal_raw_many_zero_field_body, "load atomic i32, ptr %");
    try expectContains(missing_literal_raw_many_zero_field_body, " unordered, align 4");
    try expectNotContains(missing_literal_raw_many_zero_field_body, "load i32, ptr %");

    var missing_literal_noalias_field_output: std.ArrayList(u8) = .empty;
    defer missing_literal_noalias_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_array_element_missing_literal_noalias_field_provenance.mc", source, "aggregate_array_element_literal_noalias_direct_deref_requires_mir_field_fact", "holder", "ptrs", &missing_literal_noalias_field_output);

    const missing_literal_noalias_field_body = try llvmFunctionBody(missing_literal_noalias_field_output.items, "define internal i32 @aggregate_array_element_literal_noalias_direct_deref_requires_mir_field_fact");
    try expectNotContains(missing_literal_noalias_field_body, "; mir pointer_provenance consumed fn=aggregate_array_element_literal_noalias_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance");
    try expectContains(missing_literal_noalias_field_body, "load atomic i32, ptr %");
    try expectContains(missing_literal_noalias_field_body, " unordered, align 4");
    try expectNotContains(missing_literal_noalias_field_body, "load i32, ptr %");

    var missing_literal_reassignment_pointer_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_literal_reassignment_pointer_copy_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_array_element_missing_literal_reassignment_pointer_copy_field_provenance.mc", source, "aggregate_array_element_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact", "holder", "ptrs", &missing_literal_reassignment_pointer_copy_field_output);

    const missing_literal_reassignment_pointer_copy_field_body = try llvmFunctionBody(missing_literal_reassignment_pointer_copy_field_output.items, "define internal i32 @aggregate_array_element_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact");
    try expectContains(missing_literal_reassignment_pointer_copy_field_body, "; mir pointer_provenance consumed fn=aggregate_array_element_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none");
    try expectNotContains(missing_literal_reassignment_pointer_copy_field_body, "; mir pointer_provenance consumed fn=aggregate_array_element_literal_reassignment_pointer_copy_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance");
    try expectContains(missing_literal_reassignment_pointer_copy_field_body, "load atomic i32, ptr %");
    try expectContains(missing_literal_reassignment_pointer_copy_field_body, " unordered, align 4");
    try expectNotContains(missing_literal_reassignment_pointer_copy_field_body, "load i32, ptr %");

    var missing_literal_reassignment_raw_many_zero_field_output: std.ArrayList(u8) = .empty;
    defer missing_literal_reassignment_raw_many_zero_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_array_element_missing_literal_reassignment_raw_many_zero_field_provenance.mc", source, "aggregate_array_element_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact", "holder", "ptrs", &missing_literal_reassignment_raw_many_zero_field_output);

    const missing_literal_reassignment_raw_many_zero_field_body = try llvmFunctionBody(missing_literal_reassignment_raw_many_zero_field_output.items, "define internal i32 @aggregate_array_element_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact");
    try expectContains(missing_literal_reassignment_raw_many_zero_field_body, "; mir pointer_provenance consumed fn=aggregate_array_element_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact subject=gp provenance=global_storage reason=none");
    try expectNotContains(missing_literal_reassignment_raw_many_zero_field_body, "; mir pointer_provenance consumed fn=aggregate_array_element_literal_reassignment_raw_many_zero_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance");
    try expectContains(missing_literal_reassignment_raw_many_zero_field_body, "load atomic i32, ptr %");
    try expectContains(missing_literal_reassignment_raw_many_zero_field_body, " unordered, align 4");
    try expectNotContains(missing_literal_reassignment_raw_many_zero_field_body, "load i32, ptr %");

    var missing_literal_reassignment_noalias_field_output: std.ArrayList(u8) = .empty;
    defer missing_literal_reassignment_noalias_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_array_element_missing_literal_reassignment_noalias_field_provenance.mc", source, "aggregate_array_element_literal_reassignment_noalias_direct_deref_requires_mir_field_fact", "holder", "ptrs", &missing_literal_reassignment_noalias_field_output);

    const missing_literal_reassignment_noalias_field_body = try llvmFunctionBody(missing_literal_reassignment_noalias_field_output.items, "define internal i32 @aggregate_array_element_literal_reassignment_noalias_direct_deref_requires_mir_field_fact");
    try expectNotContains(missing_literal_reassignment_noalias_field_body, "; mir pointer_provenance consumed fn=aggregate_array_element_literal_reassignment_noalias_direct_deref_requires_mir_field_fact subject=holder field=ptrs element=0 provenance");
    try expectContains(missing_literal_reassignment_noalias_field_body, "load atomic i32, ptr %");
    try expectContains(missing_literal_reassignment_noalias_field_body, " unordered, align 4");
    try expectNotContains(missing_literal_reassignment_noalias_field_body, "load i32, ptr %");

    var missing_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_copy_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_aggregate_array_element_missing_copy_field_provenance.mc", source, "aggregate_array_element_local_copy_direct_deref_requires_mir_field_fact", "copied", "ptrs", &missing_copy_field_output);

    const missing_copy_field_body = try llvmFunctionBody(missing_copy_field_output.items, "define internal i32 @aggregate_array_element_local_copy_direct_deref_requires_mir_field_fact");
    try expectNotContains(missing_copy_field_body, "; mir pointer_provenance consumed fn=aggregate_array_element_local_copy_direct_deref_requires_mir_field_fact subject=copied field=ptrs element=0 provenance");
    try expectContains(missing_copy_field_body, "load atomic i32, ptr %");
    try expectContains(missing_copy_field_body, " unordered, align 4");
    try expectNotContains(missing_copy_field_body, "load i32, ptr %");

    var missing_nested_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_nested_copy_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_nested_aggregate_array_element_missing_copy_field_provenance.mc", source, "nested_aggregate_array_element_copy_direct_deref_requires_mir_field_fact", "copied", "inner.ptrs", &missing_nested_copy_field_output);

    const missing_nested_copy_field_body = try llvmFunctionBody(missing_nested_copy_field_output.items, "define internal i32 @nested_aggregate_array_element_copy_direct_deref_requires_mir_field_fact");
    try expectNotContains(missing_nested_copy_field_body, "; mir pointer_provenance consumed fn=nested_aggregate_array_element_copy_direct_deref_requires_mir_field_fact subject=copied field=inner.ptrs element=0 provenance");
    try expectContains(missing_nested_copy_field_body, "load atomic i32, ptr %");
    try expectContains(missing_nested_copy_field_body, " unordered, align 4");
    try expectNotContains(missing_nested_copy_field_body, "load i32, ptr %");

    var missing_nested_array_assignment_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_nested_array_assignment_copy_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_nested_aggregate_array_element_missing_assignment_copy_field_provenance.mc", source, "nested_aggregate_array_element_assignment_copy_direct_deref_requires_mir_field_fact", "assigned", "inner.ptrs", &missing_nested_array_assignment_copy_field_output);

    const missing_nested_array_assignment_copy_field_body = try llvmFunctionBody(missing_nested_array_assignment_copy_field_output.items, "define internal i32 @nested_aggregate_array_element_assignment_copy_direct_deref_requires_mir_field_fact");
    try expectNotContains(missing_nested_array_assignment_copy_field_body, "; mir pointer_provenance consumed fn=nested_aggregate_array_element_assignment_copy_direct_deref_requires_mir_field_fact subject=assigned field=inner.ptrs element=0 provenance");
    try expectContains(missing_nested_array_assignment_copy_field_body, "load atomic i32, ptr %");
    try expectContains(missing_nested_array_assignment_copy_field_body, " unordered, align 4");
    try expectNotContains(missing_nested_array_assignment_copy_field_body, "load i32, ptr %");

    var missing_nested_array_noalias_member_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_nested_array_noalias_member_copy_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_nested_aggregate_array_element_missing_noalias_member_copy_field_provenance.mc", source, "nested_aggregate_array_element_noalias_member_copy_direct_deref_requires_mir_field_fact", "dst", "inner.ptrs", &missing_nested_array_noalias_member_copy_field_output);

    const missing_nested_array_noalias_member_copy_field_body = try llvmFunctionBody(missing_nested_array_noalias_member_copy_field_output.items, "define internal i32 @nested_aggregate_array_element_noalias_member_copy_direct_deref_requires_mir_field_fact");
    try expectNotContains(missing_nested_array_noalias_member_copy_field_body, "; mir pointer_provenance consumed fn=nested_aggregate_array_element_noalias_member_copy_direct_deref_requires_mir_field_fact subject=dst field=inner.ptrs element=0 provenance");
    try expectContains(missing_nested_array_noalias_member_copy_field_body, "load atomic i32, ptr %");
    try expectContains(missing_nested_array_noalias_member_copy_field_body, " unordered, align 4");
    try expectNotContains(missing_nested_array_noalias_member_copy_field_body, "load i32, ptr %");

    var missing_nested_array_casted_noalias_member_copy_field_output: std.ArrayList(u8) = .empty;
    defer missing_nested_array_casted_noalias_member_copy_field_output.deinit(std.testing.allocator);
    try appendLlvmTestWithoutPointerProvenanceFactsForSubjectField("llvm_nested_aggregate_array_element_missing_casted_noalias_member_copy_field_provenance.mc", source, "nested_aggregate_array_element_casted_noalias_member_copy_direct_deref_requires_mir_field_fact", "dst", "inner.ptrs", &missing_nested_array_casted_noalias_member_copy_field_output);

    const missing_nested_array_casted_noalias_member_copy_field_body = try llvmFunctionBody(missing_nested_array_casted_noalias_member_copy_field_output.items, "define internal i32 @nested_aggregate_array_element_casted_noalias_member_copy_direct_deref_requires_mir_field_fact");
    try expectNotContains(missing_nested_array_casted_noalias_member_copy_field_body, "; mir pointer_provenance consumed fn=nested_aggregate_array_element_casted_noalias_member_copy_direct_deref_requires_mir_field_fact subject=dst field=inner.ptrs element=0 provenance");
    try expectContains(missing_nested_array_casted_noalias_member_copy_field_body, "load atomic i32, ptr %");
    try expectContains(missing_nested_array_casted_noalias_member_copy_field_body, " unordered, align 4");
    try expectNotContains(missing_nested_array_casted_noalias_member_copy_field_body, "load i32, ptr %");
}

test "LLVM ordinary bool global accesses use byte-sized atomics" {
    const source =
        \\global flag: bool = false;
        \\
        \\fn read_flag() -> bool {
        \\    return flag;
        \\}
        \\
        \\fn write_flag(value: bool) -> void {
        \\    flag = value;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("ordinary_bool_global.mc", source, &output);

    const load_body = try llvmFunctionBody(output.items, "define internal i1 @read_flag");
    try expectContains(load_body, "load atomic i8, ptr @flag unordered, align 1");
    try expectContains(load_body, "trunc i8 ");
    try expectNotContains(load_body, "load atomic i1");

    const store_body = try llvmFunctionBody(output.items, "define internal void @write_flag");
    try expectContains(store_body, "zext i1 %value to i8");
    try expectContains(store_body, "store atomic i8 ");
    try expectContains(store_body, "ptr @flag unordered, align 1");
    try expectNotContains(store_body, "store atomic i1");
}

test "LLVM wide-scalar global race lowering fails closed" {
    // A u128 global scalar access would need `load atomic i128`, which lowers to an
    // `__atomic_load_16` libcall the freestanding kernel cannot link. Spec §I.13:
    // no sound race-tolerant lowering means emission must fail, not guess.
    const load_source =
        \\global wide: u128;
        \\
        \\fn read_wide() -> u128 {
        \\    return wide;
        \\}
    ;
    var load_output: std.ArrayList(u8) = .empty;
    defer load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_wide_global_load.mc", load_source, &load_output));

    const store_source =
        \\global wide: i128;
        \\
        \\fn write_wide(x: i128) -> void {
        \\    wide = x;
        \\}
    ;
    var store_output: std.ArrayList(u8) = .empty;
    defer store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_wide_global_store.mc", store_source, &store_output));
}

test "LLVM unproven wide-scalar pointer deref fails closed" {
    // An unproven *mut u128 deref demands race-tolerant lowering (spec I.13
    // default), but 128-bit atomics would need an __atomic_load_16 libcall the
    // freestanding kernel cannot link -> emission must fail closed.
    const source =
        \\fn read_wide(p: *mut u128) -> u128 {
        \\    return p.*;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_wide_deref.mc", source, &output));
}

test "LLVM simple aggregate pointer deref value copy lowers field-wise race-tolerantly" {
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
    try appendLlvmTest("llvm_pointer_aggregate_load.mc", load_source, &load_output);
    const load_body = try llvmFunctionBody(load_output.items, "define internal { i32 } @pointer_aggregate_load");
    try expectContains(load_body, "load atomic i32, ptr %");
    try expectContains(load_body, " unordered, align 4");
    try expectNotContains(load_body, "load { i32 }, ptr %");

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
    try appendLlvmTest("llvm_pointer_aggregate_init.mc", init_source, &init_output);
    const init_body = try llvmFunctionBody(init_output.items, "define internal i32 @pointer_aggregate_init");
    try expectContains(init_body, "load atomic i32, ptr %");
    try expectContains(init_body, " unordered, align 4");
    try expectNotContains(init_body, "load { i32 }, ptr %");

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
    try appendLlvmTest("llvm_pointer_aggregate_store.mc", store_source, &store_output);
    const store_body = try llvmFunctionBody(store_output.items, "define internal void @pointer_aggregate_store");
    try expectContains(store_body, "extractvalue { i32 }");
    try expectContains(store_body, ", 0");
    try expectContains(store_body, "store atomic i32 ");
    try expectContains(store_body, " unordered, align 4");

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
    try appendLlvmTest("llvm_raw_many_aggregate_load.mc", raw_many_load_source, &raw_many_load_output);
    const raw_many_load_body = try llvmFunctionBody(raw_many_load_output.items, "define internal { i32 } @raw_many_aggregate_load");
    try expectContains(raw_many_load_body, "getelementptr { i32 }, ptr %");
    try expectContains(raw_many_load_body, "load atomic i32, ptr %");
    try expectContains(raw_many_load_body, " unordered, align 4");
    try expectNotContains(raw_many_load_body, "load { i32 }, ptr %");

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
    try appendLlvmTest("llvm_raw_many_aggregate_store.mc", raw_many_store_source, &raw_many_store_output);
    const raw_many_store_body = try llvmFunctionBody(raw_many_store_output.items, "define internal void @raw_many_aggregate_store");
    try expectContains(raw_many_store_body, "getelementptr { i32 }, ptr %");
    try expectContains(raw_many_store_body, "extractvalue { i32 }");
    try expectContains(raw_many_store_body, "store atomic i32 ");
    try expectContains(raw_many_store_body, " unordered, align 4");

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
    try appendLlvmTest("llvm_call_raw_many_aggregate.mc", call_raw_many_source, &call_raw_many_output);
    const call_raw_many_load_body = try llvmFunctionBody(call_raw_many_output.items, "define internal { i32 } @call_raw_many_aggregate_load");
    try expectContains(call_raw_many_load_body, "call ptr @external_cells()");
    try expectContains(call_raw_many_load_body, "getelementptr { i32 }, ptr %");
    try expectContains(call_raw_many_load_body, "load atomic i32, ptr %");
    try expectContains(call_raw_many_load_body, " unordered, align 4");
    try expectNotContains(call_raw_many_load_body, "load { i32 }, ptr %");

    const call_raw_many_store_body = try llvmFunctionBody(call_raw_many_output.items, "define internal void @call_raw_many_aggregate_store");
    try expectContains(call_raw_many_store_body, "call ptr @external_cells()");
    try expectContains(call_raw_many_store_body, "getelementptr { i32 }, ptr %");
    try expectContains(call_raw_many_store_body, "extractvalue { i32 }");
    try expectContains(call_raw_many_store_body, "store atomic i32 ");
    try expectContains(call_raw_many_store_body, " unordered, align 4");

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
    try appendLlvmTest("llvm_local_raw_many_zero_aggregate_load.mc", local_raw_many_source, &local_raw_many_output);
    const local_raw_many_body = try llvmFunctionBody(local_raw_many_output.items, "define internal { i32 } @local_raw_many_zero_aggregate_load");
    try expectContains(local_raw_many_body, "; mir pointer_provenance consumed fn=local_raw_many_zero_aggregate_load subject=p provenance=local_storage reason=none");
    try expectContains(local_raw_many_body, "; mir pointer_provenance consumed fn=local_raw_many_zero_aggregate_load subject=q provenance=local_storage reason=none");
    try expectContains(local_raw_many_body, "load { i32 }, ptr %");
    try expectNotContains(local_raw_many_body, " atomic ");

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
    try appendLlvmTest("llvm_local_raw_many_zero_aggregate_store.mc", local_raw_many_store_source, &local_raw_many_store_output);
    const local_raw_many_store_body = try llvmFunctionBody(local_raw_many_store_output.items, "define internal { i32 } @local_raw_many_zero_aggregate_store");
    try expectContains(local_raw_many_store_body, "; mir pointer_provenance consumed fn=local_raw_many_zero_aggregate_store subject=p provenance=local_storage reason=none");
    try expectContains(local_raw_many_store_body, "; mir pointer_provenance consumed fn=local_raw_many_zero_aggregate_store subject=q provenance=local_storage reason=none");
    try expectContains(local_raw_many_store_body, "store { i32 }");
    try expectContains(local_raw_many_store_body, "load { i32 }, ptr %cell");
    try expectNotContains(local_raw_many_store_body, " atomic ");
}

test "LLVM union aggregate pointer deref value copies fail closed" {
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
    var load_output: std.ArrayList(u8) = .empty;
    defer load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_union_load.mc", overlay_load_source, &load_output));

    var diagnostic_parsed = try test_support.parseCheckedModule("llvm_pointer_union_load_diagnostic.mc", overlay_load_source);
    defer diagnostic_parsed.deinit();
    var diagnostic_reporter = diagnostics.Reporter.init(std.testing.allocator, "llvm_pointer_union_load_diagnostic.mc", overlay_load_source);
    defer diagnostic_reporter.deinit();
    var diagnostic_output: std.ArrayList(u8) = .empty;
    defer diagnostic_output.deinit(std.testing.allocator);
    const llvm_backend = lower_llvm.mcBackend();
    try std.testing.expectError(error.UnsupportedLlvmEmission, llvm_backend.lowerFn(llvm_backend.ctx, std.testing.allocator, diagnostic_parsed.module, &diagnostic_output, .{
        .profile = .kernel,
        .source_path = "llvm_pointer_union_load_diagnostic.mc",
        .reporter = &diagnostic_reporter,
    }));
    try std.testing.expect(diagnostic_reporter.has_errors);
    try std.testing.expectEqual(@as(usize, 1), diagnostic_reporter.diagnostics.items.len);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic_reporter.diagnostics.items[0].message, "E_BACKEND_UNSUPPORTED") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic_reporter.diagnostics.items[0].message, "deref") != null);

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
    var store_output: std.ArrayList(u8) = .empty;
    defer store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_union_store.mc", overlay_store_source, &store_output));

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
    var c_union_load_output: std.ArrayList(u8) = .empty;
    defer c_union_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_c_union_load.mc", c_union_load_source, &c_union_load_output));

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
    var c_union_store_output: std.ArrayList(u8) = .empty;
    defer c_union_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_c_union_store.mc", c_union_store_source, &c_union_store_output));

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
    var raw_many_load_output: std.ArrayList(u8) = .empty;
    defer raw_many_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_raw_many_union_load.mc", overlay_raw_many_load_source, &raw_many_load_output));

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
    var raw_many_store_output: std.ArrayList(u8) = .empty;
    defer raw_many_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_raw_many_union_store.mc", overlay_raw_many_store_source, &raw_many_store_output));

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
    var c_union_raw_many_load_output: std.ArrayList(u8) = .empty;
    defer c_union_raw_many_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_raw_many_c_union_load.mc", c_union_raw_many_load_source, &c_union_raw_many_load_output));

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
    var c_union_raw_many_store_output: std.ArrayList(u8) = .empty;
    defer c_union_raw_many_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_raw_many_c_union_store.mc", c_union_raw_many_store_source, &c_union_raw_many_store_output));

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
    var tagged_load_output: std.ArrayList(u8) = .empty;
    defer tagged_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_tagged_union_load.mc", tagged_load_source, &tagged_load_output));

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
    var tagged_store_output: std.ArrayList(u8) = .empty;
    defer tagged_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_tagged_union_store.mc", tagged_store_source, &tagged_store_output));

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
    var tagged_raw_many_load_output: std.ArrayList(u8) = .empty;
    defer tagged_raw_many_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_raw_many_tagged_union_load.mc", tagged_raw_many_load_source, &tagged_raw_many_load_output));

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
    var tagged_raw_many_store_output: std.ArrayList(u8) = .empty;
    defer tagged_raw_many_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_raw_many_tagged_union_store.mc", tagged_raw_many_store_source, &tagged_raw_many_store_output));

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
    var nested_overlay_load_output: std.ArrayList(u8) = .empty;
    defer nested_overlay_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_nested_union_load.mc", nested_overlay_load_source, &nested_overlay_load_output));

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
    var nested_overlay_store_output: std.ArrayList(u8) = .empty;
    defer nested_overlay_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_nested_union_store.mc", nested_overlay_store_source, &nested_overlay_store_output));

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
    var nested_c_union_load_output: std.ArrayList(u8) = .empty;
    defer nested_c_union_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_nested_c_union_load.mc", nested_c_union_load_source, &nested_c_union_load_output));

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
    var nested_c_union_store_output: std.ArrayList(u8) = .empty;
    defer nested_c_union_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_nested_c_union_store.mc", nested_c_union_store_source, &nested_c_union_store_output));

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
    var nested_tagged_load_output: std.ArrayList(u8) = .empty;
    defer nested_tagged_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_nested_tagged_union_load.mc", nested_tagged_load_source, &nested_tagged_load_output));

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
    var nested_tagged_store_output: std.ArrayList(u8) = .empty;
    defer nested_tagged_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_nested_tagged_union_store.mc", nested_tagged_store_source, &nested_tagged_store_output));
}

test "LLVM union pointer-member aggregate value copies fail closed" {
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
    var overlay_load_output: std.ArrayList(u8) = .empty;
    defer overlay_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_union_member_load.mc", overlay_member_load_source, &overlay_load_output));

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
    var overlay_store_output: std.ArrayList(u8) = .empty;
    defer overlay_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_union_member_store.mc", overlay_member_store_source, &overlay_store_output));

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
    var c_union_load_output: std.ArrayList(u8) = .empty;
    defer c_union_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_c_union_member_load.mc", c_union_member_load_source, &c_union_load_output));

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
    var c_union_store_output: std.ArrayList(u8) = .empty;
    defer c_union_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_c_union_member_store.mc", c_union_member_store_source, &c_union_store_output));

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
    var nested_overlay_load_output: std.ArrayList(u8) = .empty;
    defer nested_overlay_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_nested_union_member_load.mc", nested_overlay_member_load_source, &nested_overlay_load_output));

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
    var nested_overlay_store_output: std.ArrayList(u8) = .empty;
    defer nested_overlay_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_nested_union_member_store.mc", nested_overlay_member_store_source, &nested_overlay_store_output));

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
    var nested_c_union_load_output: std.ArrayList(u8) = .empty;
    defer nested_c_union_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_nested_c_union_member_load.mc", nested_c_union_member_load_source, &nested_c_union_load_output));

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
    var nested_c_union_store_output: std.ArrayList(u8) = .empty;
    defer nested_c_union_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_nested_c_union_member_store.mc", nested_c_union_member_store_source, &nested_c_union_store_output));

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
    var tagged_load_output: std.ArrayList(u8) = .empty;
    defer tagged_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_tagged_union_member_load.mc", tagged_member_load_source, &tagged_load_output));

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
    var tagged_store_output: std.ArrayList(u8) = .empty;
    defer tagged_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_tagged_union_member_store.mc", tagged_member_store_source, &tagged_store_output));

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
    var nested_tagged_load_output: std.ArrayList(u8) = .empty;
    defer nested_tagged_load_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_nested_tagged_union_member_load.mc", nested_tagged_member_load_source, &nested_tagged_load_output));

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
    var nested_tagged_store_output: std.ArrayList(u8) = .empty;
    defer nested_tagged_store_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_pointer_nested_tagged_union_member_store.mc", nested_tagged_member_store_source, &nested_tagged_store_output));
}

test "LLVM nested aggregate pointer deref value copy lowers recursively" {
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
    try appendLlvmTest("llvm_pointer_nested_aggregate_load.mc", load_source, &load_output);
    const load_body = try llvmFunctionBody(load_output.items, "define internal { { i32 } } @pointer_nested_aggregate_load");
    try expectContains(load_body, "load atomic i32, ptr %");
    try expectContains(load_body, "insertvalue { i32 } zeroinitializer, i32");
    try expectContains(load_body, "insertvalue { { i32 } } zeroinitializer, { i32 }");
    try expectNotContains(load_body, "load { { i32 } }, ptr %");

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
    try appendLlvmTest("llvm_pointer_nested_aggregate_store.mc", store_source, &store_output);
    const store_body = try llvmFunctionBody(store_output.items, "define internal void @pointer_nested_aggregate_store");
    try expectContains(store_body, "extractvalue { { i32 } }");
    try expectContains(store_body, "extractvalue { i32 }");
    try expectContains(store_body, "store atomic i32 ");
    try expectContains(store_body, " unordered, align 4");

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
    try appendLlvmTest("llvm_call_raw_many_nested_aggregate.mc", call_raw_many_source, &call_raw_many_output);
    const call_raw_many_load_body = try llvmFunctionBody(call_raw_many_output.items, "define internal { { i32 } } @call_raw_many_nested_aggregate_load");
    try expectContains(call_raw_many_load_body, "call ptr @external_outers()");
    try expectContains(call_raw_many_load_body, "getelementptr { { i32 } }, ptr %");
    try expectContains(call_raw_many_load_body, "load atomic i32, ptr %");
    try expectContains(call_raw_many_load_body, "insertvalue { i32 } zeroinitializer, i32");
    try expectContains(call_raw_many_load_body, "insertvalue { { i32 } } zeroinitializer, { i32 }");
    try expectContains(call_raw_many_load_body, " unordered, align 4");
    try expectNotContains(call_raw_many_load_body, "load { { i32 } }, ptr %");

    const call_raw_many_store_body = try llvmFunctionBody(call_raw_many_output.items, "define internal void @call_raw_many_nested_aggregate_store");
    try expectContains(call_raw_many_store_body, "call ptr @external_outers()");
    try expectContains(call_raw_many_store_body, "getelementptr { { i32 } }, ptr %");
    try expectContains(call_raw_many_store_body, "extractvalue { { i32 } }");
    try expectContains(call_raw_many_store_body, "extractvalue { i32 }");
    try expectContains(call_raw_many_store_body, "store atomic i32 ");
    try expectContains(call_raw_many_store_body, " unordered, align 4");
}

test "LLVM array-field aggregate pointer deref value copy lowers recursively" {
    const load_source =
        \\struct WithArray {
        \\    values: [2]u32,
        \\}
        \\
        \\fn pointer_array_field_aggregate_load(p: *mut WithArray) -> WithArray {
        \\    return p.*;
        \\}
    ;
    var load_output: std.ArrayList(u8) = .empty;
    defer load_output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_pointer_array_field_aggregate_load.mc", load_source, &load_output);
    const load_body = try llvmFunctionBody(load_output.items, "define internal { [2 x i32] } @pointer_array_field_aggregate_load");
    try expectContains(load_body, "load atomic i32, ptr %");
    try expectContains(load_body, "insertvalue [2 x i32] zeroinitializer, i32");
    try expectContains(load_body, "insertvalue { [2 x i32] } zeroinitializer, [2 x i32]");
    try expectNotContains(load_body, "load { [2 x i32] }, ptr %");

    const store_source =
        \\struct WithArray {
        \\    values: [2]u32,
        \\}
        \\
        \\fn pointer_array_field_aggregate_store(p: *mut WithArray, value: WithArray) -> void {
        \\    p.* = value;
        \\}
    ;
    var store_output: std.ArrayList(u8) = .empty;
    defer store_output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_pointer_array_field_aggregate_store.mc", store_source, &store_output);
    const store_body = try llvmFunctionBody(store_output.items, "define internal void @pointer_array_field_aggregate_store");
    try expectContains(store_body, "extractvalue { [2 x i32] }");
    try expectContains(store_body, "extractvalue [2 x i32]");
    try expectContains(store_body, "store atomic i32 ");
    try expectContains(store_body, " unordered, align 4");

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
    try appendLlvmTest("llvm_call_raw_many_array_aggregate.mc", call_raw_many_source, &call_raw_many_output);
    const call_raw_many_load_body = try llvmFunctionBody(call_raw_many_output.items, "define internal { [2 x i32] } @call_raw_many_array_aggregate_load");
    try expectContains(call_raw_many_load_body, "call ptr @external_arrays()");
    try expectContains(call_raw_many_load_body, "getelementptr { [2 x i32] }, ptr %");
    try expectContains(call_raw_many_load_body, "load atomic i32, ptr %");
    try expectContains(call_raw_many_load_body, "insertvalue [2 x i32] zeroinitializer, i32");
    try expectContains(call_raw_many_load_body, " unordered, align 4");
    try expectNotContains(call_raw_many_load_body, "load { [2 x i32] }, ptr %");

    const call_raw_many_store_body = try llvmFunctionBody(call_raw_many_output.items, "define internal void @call_raw_many_array_aggregate_store");
    try expectContains(call_raw_many_store_body, "call ptr @external_arrays()");
    try expectContains(call_raw_many_store_body, "getelementptr { [2 x i32] }, ptr %");
    try expectContains(call_raw_many_store_body, "extractvalue { [2 x i32] }");
    try expectContains(call_raw_many_store_body, "extractvalue [2 x i32]");
    try expectContains(call_raw_many_store_body, "store atomic i32 ");
    try expectContains(call_raw_many_store_body, " unordered, align 4");
}

test "LLVM proven-local aggregate pointer deref value copy stays plain" {
    const source =
        \\struct Cell {
        \\    value: u32,
        \\}
        \\struct WithArray {
        \\    values: [2]u32,
        \\}
        \\
        \\fn local_pointer_aggregate_copy() -> u32 {
        \\    var cell: Cell = .{ .value = 1 };
        \\    let p: *mut Cell = &cell;
        \\    p.* = .{ .value = 2 };
        \\    let copy: Cell = p.*;
        \\    return copy.value;
        \\}
        \\
        \\fn local_pointer_array_aggregate_copy() -> u32 {
        \\    var cell: WithArray = .{ .values = .{ 1, 2 } };
        \\    let p: *mut WithArray = &cell;
        \\    p.* = .{ .values = .{ 3, 4 } };
        \\    let copy: WithArray = p.*;
        \\    return copy.values[1];
        \\}
        \\
        \\fn local_raw_many_zero_array_aggregate_copy() -> u32 {
        \\    unsafe {
        \\        var cell: WithArray = .{ .values = .{ 1, 2 } };
        \\        let p: [*]mut WithArray = (&cell) as [*]mut WithArray;
        \\        let q: [*]mut WithArray = p.offset(0);
        \\        q.* = .{ .values = .{ 3, 4 } };
        \\        let copy: WithArray = q.*;
        \\        return copy.values[1];
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_local_pointer_aggregate_copy.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal i32 @local_pointer_aggregate_copy");
    try expectContains(body, "; mir pointer_provenance consumed fn=local_pointer_aggregate_copy subject=p provenance=local_storage reason=none");
    try expectContains(body, "store { i32 }");
    try expectContains(body, "load { i32 }, ptr %");
    try expectNotContains(body, " atomic ");

    const array_body = try llvmFunctionBody(output.items, "define internal i32 @local_pointer_array_aggregate_copy");
    try expectContains(array_body, "; mir pointer_provenance consumed fn=local_pointer_array_aggregate_copy subject=p provenance=local_storage reason=none");
    try expectContains(array_body, "store { [2 x i32] }");
    try expectContains(array_body, "load { [2 x i32] }, ptr %");
    try expectNotContains(array_body, " atomic ");

    const raw_many_array_body = try llvmFunctionBody(output.items, "define internal i32 @local_raw_many_zero_array_aggregate_copy");
    try expectContains(raw_many_array_body, "; mir pointer_provenance consumed fn=local_raw_many_zero_array_aggregate_copy subject=p provenance=local_storage reason=none");
    try expectContains(raw_many_array_body, "; mir pointer_provenance consumed fn=local_raw_many_zero_array_aggregate_copy subject=q provenance=local_storage reason=none");
    try expectContains(raw_many_array_body, "store { [2 x i32] }");
    try expectContains(raw_many_array_body, "load { [2 x i32] }, ptr %");
    try expectNotContains(raw_many_array_body, " atomic ");
}

test "LLVM proven-local wide-scalar deref stays plain" {
    // A positive locality proof (live MIR local_storage fact) keeps the deref
    // on the plain path, so u128 lowers fine without any atomic form.
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
    try appendLlvmTest("llvm_wide_local_deref.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal i128 @local_wide");
    try expectContains(body, "; mir pointer_provenance consumed fn=local_wide subject=p provenance=local_storage reason=none");
    try expectContains(body, "store i128 9, ptr %");
    try expectContains(body, "load i128, ptr %");
    try expectNotContains(body, " atomic ");
}

test "LLVM backend emits cstr as ptr" {
    const source =
        \\extern "C" fn strlen(s: cstr) -> usize;
        \\extern "C" fn identity(s: cstr) -> cstr;
        \\
        \\export fn use_cstr() -> usize {
        \\    let s: cstr = "abc";
        \\    return strlen(s);
        \\}
        \\
        \\export fn return_cstr() -> cstr {
        \\    return identity("xyz");
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("cstr_llvm.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "declare i64 @strlen(ptr)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "declare ptr @identity(ptr)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "define ptr @return_cstr()") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "call ptr @identity(ptr") != null);
}

test "LLVM reflection rejects oversized tagged union layout without panicking" {
    const source =
        \\union Big {
        \\    data: [18446744073709551615]u8,
        \\    none,
        \\}
        \\fn probe() -> usize {
        \\    return sizeof(Big);
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_reflect_big_union.mc", source, &output));
}

test "LLVM check elision is scoped to the current function" {
    const proven_source =
        \\fn proven(xs: [4]u32) -> u32 {
        \\    return xs[1];
        \\}
    ;
    const checked_source =
        \\fn checked(xs: [4]u32, i: usize) -> u32 {
        \\    return xs[i];
        \\}
    ;

    var proven = try test_support.parseModule("proven.mc", proven_source);
    defer proven.deinit();
    var checked = try test_support.parseModule("checked.mc", checked_source);
    defer checked.deinit();

    const total_decls = proven.module.decls.len + checked.module.decls.len;
    const decls = try std.testing.allocator.alloc(ast.Decl, total_decls);
    defer std.testing.allocator.free(decls);
    @memcpy(decls[0..proven.module.decls.len], proven.module.decls);
    @memcpy(decls[proven.module.decls.len..], checked.module.decls);
    const module = ast.Module{ .decls = decls };

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_llvm.appendLlvmWithSourcePath(std.testing.allocator, module, &output, "combined.mc", true);

    const proven_body = try llvmFunctionBody(output.items, "define internal i32 @proven");
    const checked_body = try llvmFunctionBody(output.items, "define internal i32 @checked");
    try std.testing.expect(std.mem.indexOf(u8, proven_body, "call void @mc_trap_Bounds()") == null);
    try std.testing.expect(std.mem.indexOf(u8, checked_body, "call void @mc_trap_Bounds()") != null);
}

test "LLVM backend reuses prebuilt verified MIR without changing output" {
    const source =
        \\fn add_one(value: u32) -> u32 {
        \\    return value + 1;
        \\}
    ;

    var parsed = try test_support.parseModule("llvm_prebuilt_mir.mc", source);
    defer parsed.deinit();

    var rebuilt_output: std.ArrayList(u8) = .empty;
    defer rebuilt_output.deinit(std.testing.allocator);
    try lower_llvm.appendLlvmWithSourcePath(std.testing.allocator, parsed.module, &rebuilt_output, "llvm_prebuilt_mir.mc", true);

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "llvm_prebuilt_mir.mc", source);
    defer reporter.deinit();
    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{ .optimize = true });
    defer module_mir.deinit();
    try mir.verifyBuiltMir(module_mir, &reporter);
    try std.testing.expect(!reporter.has_errors);

    var prebuilt_output: std.ArrayList(u8) = .empty;
    defer prebuilt_output.deinit(std.testing.allocator);
    try lower_llvm.appendLlvmCheckedMir(std.testing.allocator, parsed.module, &module_mir, &prebuilt_output, "llvm_prebuilt_mir.mc", .{ .optimize = true }, false, .riscv64, &reporter);

    try std.testing.expectEqualSlices(u8, rebuilt_output.items, prebuilt_output.items);
}

test "LLVM unsupported diagnostics use nearest source span for generated nodes" {
    const source =
        \\// generated nodes should not point here
        \\
        \\fn synthetic_uninit() -> u32 { return 0; }
    ;
    const zspan = ast.Span{ .offset = 0, .len = 0, .line = 0, .column = 0 };
    const fn_span = ast.Span{ .offset = 42, .len = 16, .line = 3, .column = 4 };
    const u32_ty = ast.TypeExpr{ .span = fn_span, .kind = .{ .name = .{ .text = "u32", .span = fn_span } } };

    var stmts = [_]ast.Stmt{
        .{ .span = zspan, .kind = .{ .@"return" = .{ .span = zspan, .kind = .uninit_literal } } },
    };
    var decls = [_]ast.Decl{.{ .span = fn_span, .attrs = &.{}, .kind = .{ .fn_decl = .{
        .name = .{ .text = "synthetic_uninit", .span = fn_span },
        .abi = null,
        .params = &.{},
        .return_type = u32_ty,
        .body = .{ .span = fn_span, .items = stmts[0..] },
        .is_const = false,
    } } }};
    const module = ast.Module{ .decls = decls[0..] };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "synthetic.mc", source);
    defer reporter.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    const llvm_backend = lower_llvm.mcBackend();
    try std.testing.expectError(error.UnsupportedLlvmEmission, llvm_backend.lowerFn(llvm_backend.ctx, std.testing.allocator, module, &out, .{
        .profile = .kernel,
        .source_path = "synthetic.mc",
        .reporter = &reporter,
    }));

    try std.testing.expect(reporter.has_errors);
    try std.testing.expectEqual(@as(usize, 1), reporter.diagnostics.items.len);
    try std.testing.expectEqual(@as(usize, 3), reporter.diagnostics.items[0].span.line);
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, "uninit_literal") != null);
}
