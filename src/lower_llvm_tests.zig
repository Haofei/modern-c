const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const lower_llvm = @import("lower_llvm.zig");
const mir = @import("mir.zig");
const test_support = @import("test_support.zig");

fn appendLlvmTest(source_name: []const u8, source: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseModule(source_name, source);
    defer parsed.deinit();

    try lower_llvm.appendLlvm(std.testing.allocator, parsed.module, output);
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
    try expectContains(pointer_load_body, "load atomic i32, ptr %");
    try expectContains(pointer_load_body, " unordered, align 4");
    try expectNotContains(pointer_load_body, "load i32, ptr %");

    const address_deref_body = try llvmFunctionBody(output.items, "define internal i32 @possibly_racing_direct_address_deref_load");
    try expectContains(address_deref_body, "load atomic i32, ptr @shared_counter unordered, align 4");
    try expectNotContains(address_deref_body, "load i32, ptr @shared_counter");

    const returned_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @possibly_racing_returned_pointer_load");
    try expectContains(returned_pointer_body, "call ptr @returned_global_pointer()");
    try expectContains(returned_pointer_body, "load atomic i32, ptr %");
    try expectContains(returned_pointer_body, " unordered, align 4");
    try expectNotContains(returned_pointer_body, "load i32, ptr %");

    const param_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @consume_global_param");
    try expectContains(param_pointer_body, "load atomic i32, ptr %p unordered, align 4");
    try expectNotContains(param_pointer_body, "load i32, ptr %p");

    const mixed_param_body = try llvmFunctionBody(output.items, "define internal i32 @consume_mixed_param");
    try expectContains(mixed_param_body, "load i32, ptr %p");
    try expectNotContains(mixed_param_body, "load atomic i32, ptr %p");

    const local_only_param_body = try llvmFunctionBody(output.items, "define internal i32 @consume_local_only_param");
    try expectContains(local_only_param_body, "load i32, ptr %p");
    try expectNotContains(local_only_param_body, "load atomic i32, ptr %p");

    const local_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @local_pointer_deref_stays_plain");
    try expectContains(local_pointer_body, "store i32 6, ptr %");
    try expectContains(local_pointer_body, "load i32, ptr %");
    try expectNotContains(local_pointer_body, " atomic ");

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

    const aggregate_stack_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_stack_pointer_field_stays_plain");
    try expectContains(aggregate_stack_pointer_body, "load i32, ptr %");
    try expectNotContains(aggregate_stack_pointer_body, " atomic ");

    const nested_aggregate_stack_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @nested_aggregate_stack_pointer_field_stays_plain");
    try expectContains(nested_aggregate_stack_pointer_body, "load i32, ptr %");
    try expectNotContains(nested_aggregate_stack_pointer_body, " atomic ");

    const aggregate_pointer_alias_stack_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_stack_pointer_field_stays_plain");
    try expectContains(aggregate_pointer_alias_stack_body, "load i32, ptr %");
    try expectNotContains(aggregate_pointer_alias_stack_body, " atomic ");

    const aggregate_pointer_alias_field_assignment_direct_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_field_assignment_clears_direct_field_fact");
    try expectContains(aggregate_pointer_alias_field_assignment_direct_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_pointer_alias_field_assignment_direct_body, "load i32, ptr %");
    try expectNotContains(aggregate_pointer_alias_field_assignment_direct_body, " atomic ");

    const aggregate_pointer_alias_field_assignment_alias_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_field_assignment_clears_alias_field_fact");
    try expectContains(aggregate_pointer_alias_field_assignment_alias_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_pointer_alias_field_assignment_alias_body, "load i32, ptr %");
    try expectNotContains(aggregate_pointer_alias_field_assignment_alias_body, " atomic ");

    const aggregate_pointer_alias_field_assignment_global_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_field_assignment_establishes_global_fact");
    try expectContains(aggregate_pointer_alias_field_assignment_global_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_pointer_alias_field_assignment_global_body, "load atomic i32, ptr %");
    try expectContains(aggregate_pointer_alias_field_assignment_global_body, " unordered, align 4");
    try expectNotContains(aggregate_pointer_alias_field_assignment_global_body, "load i32, ptr %p.addr.");

    const aggregate_pointer_alias_returned_unknown_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_returned_unknown_stays_plain");
    try expectContains(aggregate_pointer_alias_returned_unknown_body, "call ptr @external_pointer_holder()");
    try expectContains(aggregate_pointer_alias_returned_unknown_body, "load i32, ptr %");
    try expectNotContains(aggregate_pointer_alias_returned_unknown_body, " atomic ");

    const aggregate_pointer_param_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_param_field_stays_plain");
    try expectContains(aggregate_pointer_param_body, "load i32, ptr %");
    try expectNotContains(aggregate_pointer_param_body, " atomic ");

    const aggregate_pointer_alias_reassigned_unknown_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_reassigned_unknown_stays_plain");
    try expectContains(aggregate_pointer_alias_reassigned_unknown_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_pointer_alias_reassigned_unknown_body, "call ptr @external_pointer_holder()");
    try expectContains(aggregate_pointer_alias_reassigned_unknown_body, "load i32, ptr %");
    try expectNotContains(aggregate_pointer_alias_reassigned_unknown_body, " atomic ");

    const aggregate_pointer_alias_reassigned_unknown_write_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_reassigned_unknown_write_does_not_clear_old_field_fact");
    try expectContains(aggregate_pointer_alias_reassigned_unknown_write_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_pointer_alias_reassigned_unknown_write_body, "call ptr @external_pointer_holder()");
    try expectContains(aggregate_pointer_alias_reassigned_unknown_write_body, "load atomic i32, ptr %");
    try expectContains(aggregate_pointer_alias_reassigned_unknown_write_body, " unordered, align 4");
    try expectNotContains(aggregate_pointer_alias_reassigned_unknown_write_body, "load i32, ptr %p.addr.");

    const aggregate_reassigned_stack_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_reassigned_stack_pointer_field_stays_plain");
    try expectContains(aggregate_reassigned_stack_body, "load i32, ptr %");
    try expectNotContains(aggregate_reassigned_stack_body, " atomic ");

    const nested_aggregate_reassigned_stack_body = try llvmFunctionBody(output.items, "define internal i32 @nested_aggregate_reassigned_stack_pointer_field_stays_plain");
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

    const aggregate_whole_copy_stack_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_whole_copy_stack_pointer_field_stays_plain");
    try expectContains(aggregate_whole_copy_stack_body, "load i32, ptr %");
    try expectNotContains(aggregate_whole_copy_stack_body, " atomic ");

    const aggregate_computed_copy_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_computed_copy_pointer_field_stays_plain");
    try expectContains(aggregate_computed_copy_body, "call { ptr, i32 } @returned_pointer_holder()");
    try expectContains(aggregate_computed_copy_body, "load i32, ptr %");
    try expectNotContains(aggregate_computed_copy_body, " atomic ");

    const aggregate_exported_return_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_exported_return_pointer_field_stays_plain");
    try expectContains(aggregate_exported_return_body, "call ptr @exported_global_pointer()");
    try expectContains(aggregate_exported_return_body, "load i32, ptr %");
    try expectNotContains(aggregate_exported_return_body, " atomic ");

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

    const aggregate_array_stack_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_array_stack_pointer_element_stays_plain");
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

    const aggregate_array_dynamic_index_partial_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_array_dynamic_index_partial_pointer_elements_stays_plain");
    try expectContains(aggregate_array_dynamic_index_partial_body, "load i32, ptr %");
    try expectNotContains(aggregate_array_dynamic_index_partial_body, " atomic ");

    const aggregate_array_dynamic_assignment_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_array_dynamic_assignment_clears_pointer_element_fact");
    try expectContains(aggregate_array_dynamic_assignment_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_array_dynamic_assignment_body, "load i32, ptr %");
    try expectNotContains(aggregate_array_dynamic_assignment_body, " atomic ");

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

    const aggregate_pointer_alias_array_dynamic_index_partial_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_array_dynamic_index_partial_pointer_elements_stays_plain");
    try expectContains(aggregate_pointer_alias_array_dynamic_index_partial_body, "load i32, ptr %");
    try expectNotContains(aggregate_pointer_alias_array_dynamic_index_partial_body, " atomic ");

    const aggregate_pointer_alias_array_assignment_clears_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_array_assignment_clears_element_fact");
    try expectContains(aggregate_pointer_alias_array_assignment_clears_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_pointer_alias_array_assignment_clears_body, "load i32, ptr %");
    try expectNotContains(aggregate_pointer_alias_array_assignment_clears_body, " atomic ");

    const aggregate_pointer_alias_array_dynamic_assignment_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_array_dynamic_assignment_clears_all_element_facts");
    try expectContains(aggregate_pointer_alias_array_dynamic_assignment_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_pointer_alias_array_dynamic_assignment_body, "load i32, ptr %");
    try expectNotContains(aggregate_pointer_alias_array_dynamic_assignment_body, " atomic ");

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

    const aggregate_pointer_alias_array_dynamic_index_partially_assigned_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_array_dynamic_index_partially_assigned_stays_plain");
    try expectContains(aggregate_pointer_alias_array_dynamic_index_partially_assigned_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_pointer_alias_array_dynamic_index_partially_assigned_body, "load i32, ptr %");
    try expectNotContains(aggregate_pointer_alias_array_dynamic_index_partially_assigned_body, " atomic ");

    const aggregate_pointer_alias_array_returned_unknown_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_array_returned_unknown_stays_plain");
    try expectContains(aggregate_pointer_alias_array_returned_unknown_body, "call ptr @external_pointer_array_holder()");
    try expectContains(aggregate_pointer_alias_array_returned_unknown_body, "load i32, ptr %");
    try expectNotContains(aggregate_pointer_alias_array_returned_unknown_body, " atomic ");

    const aggregate_pointer_alias_array_reassigned_unknown_body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_pointer_alias_array_reassigned_unknown_stays_plain");
    try expectContains(aggregate_pointer_alias_array_reassigned_unknown_body, "store ptr @shared_counter, ptr %");
    try expectContains(aggregate_pointer_alias_array_reassigned_unknown_body, "call ptr @external_pointer_array_holder()");
    try expectContains(aggregate_pointer_alias_array_reassigned_unknown_body, "load i32, ptr %");
    try expectNotContains(aggregate_pointer_alias_array_reassigned_unknown_body, " atomic ");

    const array_global_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @array_global_pointer_element_load");
    try expectContains(array_global_pointer_body, "store ptr @shared_counter, ptr %");
    try expectContains(array_global_pointer_body, "load atomic i32, ptr %");
    try expectContains(array_global_pointer_body, " unordered, align 4");
    try expectNotContains(array_global_pointer_body, "load i32, ptr %p.addr.");

    const array_assigned_global_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @array_assigned_global_pointer_element_load");
    try expectContains(array_assigned_global_pointer_body, "store ptr @shared_counter, ptr %");
    try expectContains(array_assigned_global_pointer_body, "load atomic i32, ptr %");
    try expectContains(array_assigned_global_pointer_body, " unordered, align 4");
    try expectNotContains(array_assigned_global_pointer_body, "load i32, ptr %p.addr.");

    const array_stack_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @array_stack_pointer_element_stays_plain");
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

    const array_dynamic_index_partial_body = try llvmFunctionBody(output.items, "define internal i32 @array_dynamic_index_partial_pointer_elements_stays_plain");
    try expectContains(array_dynamic_index_partial_body, "load i32, ptr %");
    try expectNotContains(array_dynamic_index_partial_body, " atomic ");

    const array_dynamic_assignment_body = try llvmFunctionBody(output.items, "define internal i32 @array_dynamic_assignment_clears_pointer_element_fact");
    try expectContains(array_dynamic_assignment_body, "store ptr @shared_counter, ptr %");
    try expectContains(array_dynamic_assignment_body, "load i32, ptr %");
    try expectNotContains(array_dynamic_assignment_body, " atomic ");

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
    try expectNotContains(slice_stack_pointer_body, " atomic ");

    const slice_partial_pointer_body = try llvmFunctionBody(output.items, "define internal i32 @slice_partial_pointer_elements_stays_plain");
    try expectContains(slice_partial_pointer_body, "store ptr @shared_counter, ptr %");
    try expectContains(slice_partial_pointer_body, "load i32, ptr %");
    try expectNotContains(slice_partial_pointer_body, " atomic ");

    const slice_backing_assignment_body = try llvmFunctionBody(output.items, "define internal i32 @slice_backing_array_assignment_clears_fact");
    try expectContains(slice_backing_assignment_body, "store ptr @shared_counter, ptr %");
    try expectContains(slice_backing_assignment_body, "load i32, ptr %");
    try expectNotContains(slice_backing_assignment_body, " atomic ");

    const slice_backing_dynamic_assignment_body = try llvmFunctionBody(output.items, "define internal i32 @slice_backing_array_dynamic_assignment_clears_fact");
    try expectContains(slice_backing_dynamic_assignment_body, "store ptr @shared_counter, ptr %");
    try expectContains(slice_backing_dynamic_assignment_body, "load i32, ptr %");
    try expectNotContains(slice_backing_dynamic_assignment_body, " atomic ");

    const slice_backing_whole_assignment_body = try llvmFunctionBody(output.items, "define internal i32 @slice_backing_array_whole_assignment_clears_fact");
    try expectContains(slice_backing_whole_assignment_body, "store ptr @shared_counter, ptr %");
    try expectContains(slice_backing_whole_assignment_body, "load i32, ptr %");
    try expectNotContains(slice_backing_whole_assignment_body, " atomic ");

    const slice_element_assignment_body = try llvmFunctionBody(output.items, "define internal i32 @slice_element_assignment_clears_fact");
    try expectContains(slice_element_assignment_body, "store ptr @shared_counter, ptr %");
    try expectContains(slice_element_assignment_body, "load i32, ptr %");
    try expectNotContains(slice_element_assignment_body, " atomic ");

    const slice_reassignment_body = try llvmFunctionBody(output.items, "define internal i32 @slice_reassignment_clears_fact");
    try expectContains(slice_reassignment_body, "store ptr @shared_counter, ptr %");
    try expectContains(slice_reassignment_body, "load i32, ptr %");
    try expectNotContains(slice_reassignment_body, " atomic ");

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
