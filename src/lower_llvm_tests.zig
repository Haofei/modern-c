const std = @import("std");

const ast = @import("ast.zig");
const backend_mod = @import("backend.zig");
const declaration_artifacts = @import("declaration_artifacts.zig");
const diagnostics = @import("diagnostics.zig");
const lower_llvm = @import("lower_llvm.zig");
const lower_llvm_prelude = @import("lower_llvm_prelude.zig");
const mir = @import("mir.zig");
const test_artifact_support = @import("test_artifact_support.zig");
const test_support = @import("test_support.zig");

test "LLVM canonical MIR renders scalar closure capture through a thunk" {
    const source =
        \\fn add_scalar(env: u32, x: u32) -> u32 { return env + x; }
        \\fn scalar_bind() -> u32 {
        \\    let cb: closure(u32) -> u32 = bind(10, add_scalar);
        \\    return cb(5);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_scalar_closure.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal i32 @scalar_bind");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "inttoptr i32 10 to ptr");
    try expectContains(body, "insertvalue { ptr, ptr } zeroinitializer, ptr @mc_envthunk_add_scalar, 0");
    try expectContains(output.items, "define i32 @mc_envthunk_add_scalar(ptr %env, i32 %a0)");
    try expectContains(output.items, "ptrtoint ptr %env to i32");
}

test "LLVM canonical MIR renders variadic cursor operations" {
    const source =
        \\export fn sum_args(count: i32, ...) -> i64 {
        \\    var ap: va_list = va.start();
        \\    var total: i64 = 0;
        \\    var i: i32 = 0;
        \\    while i < count {
        \\        unsafe { total = total + va.arg<i64>(&ap); }
        \\        i = i + 1;
        \\    }
        \\    va.end(&ap);
        \\    return total;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_varargs.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define i64 @sum_args(i32 signext %mc_arg_0, ...)");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "call void @llvm.va_start(ptr %mc_local_");
    try expectContains(body, "va_arg ptr %mc_local_");
    try expectContains(body, ", i64");
    try expectContains(body, "call void @llvm.va_end(ptr %mc_local_");
}

test "LLVM canonical MIR maps propagated Result errors" {
    const source =
        \\enum LowErr { Failed }
        \\enum HighErr { Other, Mapped }
        \\#[error_from]
        \\fn promote(error_value: LowErr) -> HighErr { return .Mapped; }
        \\fn low() -> Result<u32, LowErr> { return err(.Failed); }
        \\fn converted() -> Result<u32, HighErr> {
        \\    let value: u32 = low()?;
        \\    return ok(value);
        \\}
        \\fn mapped() -> Result<u32, HighErr> {
        \\    let value: u32 = low()? else .Mapped;
        \\    return ok(value);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_try_map_error.mc", source, &output);

    const converted = try llvmFunctionBody(output.items, "define internal { i1, i32, i64 } @converted");
    try expectContains(converted, "; canonical executable MIR");
    try expectContains(converted, "mc_map_error_err_");
    try expectContains(converted, "call i64 @promote(i64");

    const mapped = try llvmFunctionBody(output.items, "define internal { i1, i32, i64 } @mapped");
    try expectContains(mapped, "; canonical executable MIR");
    try expectContains(mapped, "mc_map_error_err_");
    try expectContains(mapped, ", i64 1, 2");
}

test "LLVM canonical MIR renders packed field read-modify-write" {
    const source =
        \\packed bits Flags: u8 { ready: bool, busy: bool }
        \\global shared_flags: Flags = 0;
        \\fn update_local(input: Flags, set: bool) -> Flags {
        \\    var next: Flags = input;
        \\    next.busy = set;
        \\    return next;
        \\}
        \\fn update_global(set: bool) -> void { shared_flags.ready = set; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_packed_field_store.mc", source, &output);

    const local = try llvmFunctionBody(output.items, "define internal i8 @update_local");
    try expectContains(local, "; canonical executable MIR");
    try expectContains(local, "and i8");
    try expectContains(local, "shl i8");
    const global = try llvmFunctionBody(output.items, "define internal void @update_global");
    try expectContains(global, "load atomic i8, ptr @shared_flags unordered, align 1");
    try expectContains(global, "store atomic i8");
}

test "LLVM canonical executable MIR preserves function render attributes" {
    const source =
        \\#[section(".text.hot")]
        \\export fn hot_path(x: u32) -> u32 { return x + 1; }
        \\#[noinline]
        \\export fn never_inlined(x: u32) -> u32 { return x + 1; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_function_attrs.mc", source, &output);

    const hot = try llvmFunctionBody(output.items, "define signext i32 @hot_path(i32 signext %mc_arg_0) section \".text.hot\"");
    try expectContains(hot, "; canonical executable MIR");
    const noinline_body = try llvmFunctionBody(output.items, "define signext i32 @never_inlined(i32 signext %mc_arg_0) noinline");
    try expectContains(noinline_body, "; canonical executable MIR");
}

test "LLVM canonical executable MIR renders projected structs with fixed-array fields" {
    const source =
        \\struct Ring { items: [8]u32, bytes: [16]u8, head: usize }
        \\fn ring_init(ring: *mut Ring) -> void { ring.head = 0; }
        \\fn ring_len(ring: *Ring) -> usize { return ring.head; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_nested_array_field_layout.mc", source, &output);

    const init = try llvmFunctionBody(output.items, "define internal void @ring_init");
    try expectContains(init, "; canonical executable MIR");
    try expectContains(init, "getelementptr inbounds { [8 x i32], [16 x i8], i64 }, ptr %mc_arg_0, i32 0, i32 2");

    const len = try llvmFunctionBody(output.items, "define internal i64 @ring_len");
    try expectContains(len, "; canonical executable MIR");
    try expectContains(len, "getelementptr inbounds { [8 x i32], [16 x i8], i64 }, ptr %mc_arg_0, i32 0, i32 2");
}

test "LLVM lexical unsafe and contract call bodies use canonical executable MIR" {
    const source =
        \\extern fn consume(value: u32) -> void;
        \\fn unsafe_call(value: u32) -> void {
        \\    unsafe { consume(value); }
        \\}
        \\fn contract_call(value: u32) -> void {
        \\    #[unsafe_contract(no_overflow)] {
        \\        consume(value);
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_lexical_contract_calls.mc", source, &output);

    const unsafe_body = try llvmFunctionBody(output.items, "define internal void @unsafe_call");
    try expectContains(unsafe_body, "; canonical executable MIR");
    try expectContains(unsafe_body, "call void @consume(i32 %mc_arg_0)");

    const contract_body = try llvmFunctionBody(output.items, "define internal void @contract_call");
    try expectContains(contract_body, "; canonical executable MIR");
    try expectContains(contract_body, "call void @consume(i32 %mc_arg_0)");
    try expectNotContains(contract_body, "MC_CONTRACT_");
}

test "LLVM fixed-array signatures and direct calls use canonical executable MIR" {
    const source =
        \\extern fn make_array() -> [2]u32;
        \\extern fn consume_array(values: [2]u32) -> void;
        \\fn return_array() -> [2]u32 { return make_array(); }
        \\fn copy_array(values: [2]u32) -> [2]u32 {
        \\    let copy: [2]u32 = values;
        \\    return copy;
        \\}
        \\fn pass_array() -> void {
        \\    let values = make_array();
        \\    consume_array(values);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_fixed_array_calls.mc", source, &output);

    const returned = try llvmFunctionBody(output.items, "define internal [2 x i32] @return_array");
    try expectContains(returned, "; canonical executable MIR");
    try expectContains(returned, "call [2 x i32] @make_array()");
    const copied = try llvmFunctionBody(output.items, "define internal [2 x i32] @copy_array");
    try expectContains(copied, "; canonical executable MIR");
    const passed = try llvmFunctionBody(output.items, "define internal void @pass_array");
    try expectContains(passed, "; canonical executable MIR");
    try expectContains(passed, "call void @consume_array([2 x i32]");
}

test "LLVM fixed-array element addresses use canonical executable MIR" {
    const source =
        \\extern fn consume_pointer(pointer: *mut u8) -> void;
        \\const ELEMENT_COUNT: usize = 4;
        \\global global_buffer: [ELEMENT_COUNT]u8;
        \\fn pass_array_element_address() -> void {
        \\    var buffer: [4]u8 = uninit;
        \\    consume_pointer(&buffer[0]);
        \\}
        \\fn pass_symbolic_global_element_address() -> void {
        \\    consume_pointer(&global_buffer[0]);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_fixed_array_element_address.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal void @pass_array_element_address");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "icmp ult i64 0, 4");
    try expectContains(body, "getelementptr inbounds [4 x i8]");
    try expectContains(body, "call void @consume_pointer(ptr %mc_expr_tmp_");

    const global_body = try llvmFunctionBody(output.items, "define internal void @pass_symbolic_global_element_address");
    try expectContains(global_body, "; canonical executable MIR");
    try expectContains(global_body, "getelementptr inbounds [4 x i8], ptr @global_buffer");
}

test "LLVM callable parameters forward through canonical executable MIR" {
    const source =
        \\extern fn target(sink: fn(u8) -> void, value: u64, shift: i32) -> void;
        \\fn forward(sink: fn(u8) -> void, value: u32) -> void {
        \\    target(sink, value as u64, 28);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_callable_parameter.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal void @forward(ptr %mc_arg_0, i32 %mc_arg_1)");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "call void @target(ptr %mc_arg_0,");
}

test "LLVM callable field stores use verified signatures" {
    const source =
        \\fn add(a: u32, b: u32) -> u32 { return a + b; }
        \\struct BinOp { combine: fn(u32, u32) -> u32 }
        \\global ops: [2]BinOp = .{ .{ .combine = add }, .{ .combine = add } };
        \\fn replace() -> void { ops[1].combine = add; }
        \\struct Env { offset: u32 }
        \\global environment: Env;
        \\fn run(env: *mut Env, value: u32) -> u32 { return value; }
        \\struct Slot { callback: closure(u32) -> u32, probe: fn(u32, u32) -> u32 }
        \\global slot: Slot;
        \\fn install_field() -> void { slot.callback = bind(&environment, run); }
        \\fn install_all() -> void { slot = .{ .callback = bind(&environment, run), .probe = add }; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_callable_field_store.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal void @replace");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "getelementptr inbounds [2 x { ptr }], ptr @ops");
    try expectContains(body, "getelementptr inbounds { ptr }");
    try expectContains(body, "store atomic ptr @add");

    const closure_body = try llvmFunctionBody(output.items, "define internal void @install_field");
    try expectContains(closure_body, "; canonical executable MIR");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, closure_body, "store atomic ptr"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, closure_body, "extractvalue { ptr, ptr }"));

    const aggregate_body = try llvmFunctionBody(output.items, "define internal void @install_all");
    try expectContains(aggregate_body, "; canonical executable MIR");
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, aggregate_body, "store atomic ptr"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, aggregate_body, "extractvalue { ptr, ptr }"));
}

test "LLVM valid slice representation check uses canonical executable MIR" {
    const source =
        \\fn identity_slice(items: []const u32) -> []const u32 {
        \\    return items;
        \\}
        \\fn slice_len(items: []const u32) -> usize {
        \\    return items.len;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_valid_slice.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal { ptr, i64 } @identity_slice");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "extractvalue { ptr, i64 } %mc_arg_0, 0");
    try expectContains(body, "extractvalue { ptr, i64 } %mc_arg_0, 1");
    try expectContains(body, "icmp eq ptr");
    try expectContains(body, "icmp ne i64");
    try expectContains(body, "and i1");
    try expectContains(body, "ret { ptr, i64 } %mc_arg_0");
    const len_body = try llvmFunctionBody(output.items, "define internal i64 @slice_len");
    try expectContains(len_body, "; canonical executable MIR");
}

test "LLVM value optional construction needs no function body fallback" {
    const source =
        \\struct Point { x: u32, y: u32 }
        \\fn scalar(present: bool, value: u32) -> ?u32 {
        \\    if present { return value; }
        \\    return null;
        \\}
        \\fn point(present: bool) -> ?Point {
        \\    if present {
        \\        let value: Point = .{ .x = 3, .y = 4 };
        \\        return value;
        \\    }
        \\    return null;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_value_optional.mc", source, &output);

    const scalar = try llvmFunctionBody(output.items, "define internal { i1, i32 } @scalar");
    try expectContains(scalar, "; canonical executable MIR");
    try expectContains(scalar, "insertvalue { i1, i32 } zeroinitializer, i1 true, 0");
    try expectContains(scalar, "ret { i1, i32 } zeroinitializer");
    const point = try llvmFunctionBody(output.items, "define internal { i1, { i32, i32 } } @point");
    try expectContains(point, "; canonical executable MIR");
    try expectContains(point, "insertvalue { i1, { i32, i32 } } zeroinitializer, i1 true, 0");
    try expectContains(point, "ret { i1, { i32, i32 } } zeroinitializer");
}

test "LLVM atomic loads use canonical executable MIR" {
    const source =
        \\global relaxed_ticks: atomic<u32> = atomic.init(0);
        \\global seq_ticks: atomic<u32> = atomic.init(0);
        \\fn load_global_relaxed() -> u32 { return relaxed_ticks.load(.relaxed); }
        \\fn load_global_seq_cst() -> u32 { return seq_ticks.load(.seq_cst); }
        \\fn load_pointer_acquire(value: *mut atomic<u32>) -> u32 { return value.load(.acquire); }
        \\fn load_bool_acquire(value: *const atomic<bool>) -> bool { return value.load(.acquire); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_atomic_load.mc", source, &output);

    const relaxed = try llvmFunctionBody(output.items, "@load_global_relaxed");
    try expectContains(relaxed, "; canonical executable MIR");
    try expectContains(relaxed, "load atomic i32, ptr @relaxed_ticks monotonic, align 4");
    const seq_cst = try llvmFunctionBody(output.items, "@load_global_seq_cst");
    try expectContains(seq_cst, "load atomic i32, ptr @seq_ticks seq_cst, align 4");

    const pointer = try llvmFunctionBody(output.items, "@load_pointer_acquire");
    const guard_at = std.mem.indexOf(u8, pointer, "icmp eq ptr") orelse return error.TestUnexpectedResult;
    const load_at = std.mem.indexOf(u8, pointer, "load atomic i32") orelse return error.TestUnexpectedResult;
    try std.testing.expect(guard_at < load_at);
    try expectContains(pointer, "acquire, align 4");

    const boolean = try llvmFunctionBody(output.items, "@load_bool_acquire");
    try expectContains(boolean, "load atomic i8");
    try expectContains(boolean, "trunc i8");
    try expectNotContains(boolean, "load atomic i1");
}

test "LLVM atomic updates use canonical executable MIR" {
    const source =
        \\fn update(delta: u32) -> u32 {
        \\    var value: atomic<u32> = atomic.init(4);
        \\    value.store(delta, .release);
        \\    return value.fetch_add(1, .acq_rel);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_atomic_update.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "@update");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "store atomic i32 %mc_arg_0, ptr %mc_local_");
    try expectContains(body, "release, align 4");
    try expectContains(body, "atomicrmw add ptr %mc_local_");
    try expectContains(body, "i32 1 acq_rel");
}

test "LLVM MMIO scalar accesses use canonical executable MIR" {
    const source =
        \\extern mmio struct Device {
        \\    status: Reg<u32, .read> @offset(8),
        \\    command: Reg<u32, .write> @offset(16),
        \\}
        \\extern fn next_value() -> u32;
        \\fn read_relaxed(device: MmioPtr<Device>) -> u32 { return device.status.read(.relaxed); }
        \\fn read_after_call(device: MmioPtr<Device>) -> u32 { return next_value() + device.status.read(.acquire); }
        \\fn write_release(device: MmioPtr<Device>) -> void { device.command.write(next_value(), .release); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_mmio_scalar.mc", source, &output);

    const read = try llvmFunctionBody(output.items, "@read_relaxed");
    try expectContains(read, "; canonical executable MIR");
    try expectContains(read, "getelementptr i8, ptr %mc_arg_0, i64 8");
    try expectContains(read, "load volatile i32");
    try expectNotContains(read, "fence acquire");
    const ordered_read = try llvmFunctionBody(output.items, "@read_after_call");
    try expectNeedlesInOrder(ordered_read, &.{ "call i32 @next_value()", "getelementptr i8", "load volatile i32", "fence acquire", "@llvm.uadd.with.overflow.i32" });
    const write = try llvmFunctionBody(output.items, "@write_release");
    try expectNeedlesInOrder(write, &.{ "call i32 @next_value()", "fence release", "getelementptr i8, ptr %mc_arg_0, i64 16", "store volatile i32" });
}

test "LLVM shared structural body plans cover nested, aggregate, workflow, and hoisted-loop families" {
    const Case = struct { name: []const u8, path: []const u8, function_header: []const u8, needle: []const u8 };
    const cases = [_]Case{
        .{ .name = "llvm_plan_nested.mc", .path = "tests/llvm/bool_switch.mc", .function_header = "define internal i32 @classify", .needle = "icmp ugt i32 %mc_arg_" },
        .{ .name = "llvm_plan_aggregate_assignment.mc", .path = "tests/llvm/aggregate_assignments.mc", .function_header = "define internal i32 @aggregate_call_after_assignment", .needle = "@llvm.uadd.with.overflow.i32" },
        .{ .name = "llvm_plan_aggregate_calls.mc", .path = "tests/llvm/aggregate_rvalues.mc", .function_header = "define internal { [4 x i32], { ptr, i64 } } @make_bag", .needle = "insertvalue { [4 x i32], { ptr, i64 } }" },
        .{ .name = "llvm_plan_local_vtable.mc", .path = "tests/llvm/fn_pointers.mc", .function_header = "define internal i32 @local_vtable_call", .needle = "call i32 @dispatch" },
        .{ .name = "llvm_plan_closure.mc", .path = "tests/llvm/void_indirect_calls.mc", .function_header = "define internal void @call_closure", .needle = "insertvalue { ptr, ptr }" },
        .{ .name = "llvm_plan_alloca_hoist.mc", .path = "tests/llvm/alloca_hoist_in_loop.mc", .function_header = "define signext i32 @alloca_hoist_run", .needle = "alloca [256 x i8]" },
    };
    for (cases) |case| {
        const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, case.path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(source);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try appendLlvmCheckedMirTest(case.name, source, &output);
        const body = try llvmFunctionBody(output.items, case.function_header);
        try expectContains(body, case.needle);
        if (std.mem.eql(u8, case.name, "llvm_plan_aggregate_assignment.mc")) {
            try expectContains(body, "; canonical executable MIR");
            try expectContains(body, "getelementptr inbounds [2 x [2 x i32]], ptr @matrix");
        }
    }
}

test "LLVM nullable initialization and race lowering follow representation" {
    const source =
        \\struct Point { x: u32, y: u32 }
        \\fn reset() -> ?u32 { var value: ?u32 = uninit; value = null; return value; }
        \\fn load_scalar(p: *mut ?u32) -> ?u32 { return p.*; }
        \\fn store_scalar(p: *mut ?u32, value: ?u32) -> void { p.* = value; }
        \\fn load_point(p: *mut ?Point) -> ?Point { return p.*; }
        \\fn store_point(p: *mut ?Point, value: ?Point) -> void { p.* = value; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_nullable_representation.mc", source, &output);

    const reset_body = try llvmFunctionBody(output.items, "define internal { i1, i32 } @reset");
    try expectContains(reset_body, "; canonical executable MIR");
    try expectContains(reset_body, "store { i1, i32 } zeroinitializer");
    try expectNotContains(reset_body, "call void @llvm.memset");

    const scalar_load = try llvmFunctionBody(output.items, "define internal { i1, i32 } @load_scalar");
    try expectContains(scalar_load, "load atomic i8");
    try expectContains(scalar_load, "load atomic i32");
    const scalar_store = try llvmFunctionBody(output.items, "define internal void @store_scalar");
    try expectContains(scalar_store, "store atomic i32");
    try expectContains(scalar_store, "store atomic i8");

    const point_load = try llvmFunctionBody(output.items, "define internal { i1, { i32, i32 } } @load_point");
    try expectContains(point_load, "load atomic i8");
    try std.testing.expect(std.mem.count(u8, point_load, "load atomic i32") == 2);
    const point_store = try llvmFunctionBody(output.items, "define internal void @store_point");
    try std.testing.expect(std.mem.count(u8, point_store, "store atomic i32") == 2);
    try expectContains(point_store, "store atomic i8");
}

test "LLVM emits assertion expression trees from MIR without body fallback" {
    const source =
        \\extern fn next_value() -> u32;
        \\fn require_complex(a: u32, b: u32, flag: bool) -> void {
        \\    assert(flag == (a == b));
        \\}
        \\fn assert_ordered_comparison() -> void {
        \\    assert(next_value() == next_value());
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_assert_expression_tree.mc", source, &output);

    const complex = try llvmFunctionBody(output.items, "define internal void @require_complex");
    try expectContains(complex, "; canonical executable MIR");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, complex, "icmp eq"));
    try expectNotContains(complex, " and i1 ");
    try expectNotContains(complex, " or i1 ");
    try expectContains(complex, "label %mc_assert_ready_");
    try expectContains(complex, "call void @mc_trap_Assert()");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, complex, "call void @mc_trap_Assert()"));
    const ordered = try llvmFunctionBody(output.items, "define internal void @assert_ordered_comparison");
    const first = std.mem.indexOf(u8, ordered, "call i32 @next_value()") orelse return error.TestUnexpectedResult;
    const second = std.mem.indexOfPos(u8, ordered, first + "call i32 @next_value()".len, "call i32 @next_value()") orelse return error.TestUnexpectedResult;
    try std.testing.expect(first < second);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, ordered, "call i32 @next_value()"));
    try expectContains(ordered, "icmp eq i32");
    try expectContains(ordered, "label %mc_assert_ready_");
    try expectContains(ordered, "call void @mc_trap_Assert()");
}

test "LLVM aggregate literal storage materializes every allocation byte" {
    const source =
        \\struct Padded { small: u8, wide: u64 }
        \\struct Nested { value: Padded }
        \\struct OptionalHolder { value: ?Padded }
        \\struct Wide { value: u128 }
        \\union Choice { item: Padded, none }
        \\#[c_union]
        \\struct Storage { small: u8, wide: u64 }
        \\extern fn maybe_padded() -> ?Padded;
        \\fn padded() -> Padded { return .{ .small = 1, .wide = 2 }; }
        \\fn nested() -> Nested { return .{ .value = .{ .small = 1, .wide = 2 } }; }
        \\fn padded_array() -> [1]Padded { return .{ .{ .small = 1, .wide = 2 } }; }
        \\fn optional_holder() -> OptionalHolder { return .{ .value = maybe_padded() }; }
        \\fn storage() -> Storage { return .{ .small = 1, .wide = uninit }; }
        \\fn padded_uninit() -> Padded { var value: Padded = uninit; value = .{ .small = 3, .wide = 4 }; return value; }
        \\extern fn padded_result() -> Result<Padded, u8>;
        \\extern fn padded_value() -> Padded;
        \\fn copy_result() -> Result<Padded, u8> { let value = padded_result(); return value; }
        \\fn choice() -> Choice { return Choice.item(padded_value()); }
        \\fn padded_member() -> u64 { return padded_value().wide; }
        \\fn empty() -> [0]u8 { var value: [0]u8 = uninit; return value; }
        \\fn wide(value: u128) -> Wide { return .{ .value = value }; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMir, appendLlvmTest("llvm_materialized_aggregate_bytes.mc", source, &output));
}

test "LLVM struct literal fields evaluate in lexical source order" {
    const source =
        \\struct Pair { first: u32, second: u32 }
        \\extern fn mark(value: u32) -> u32;
        \\fn ordered_literal() -> Pair { return .{ .second = mark(2), .first = mark(1) }; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_struct_literal_order.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal { i32, i32 } @ordered_literal");
    const second = std.mem.indexOf(u8, body, "call i32 @mark(i32 2)") orelse return error.TestUnexpectedResult;
    const first = std.mem.indexOf(u8, body, "call i32 @mark(i32 1)") orelse return error.TestUnexpectedResult;
    try std.testing.expect(second < first);
}

test "LLVM struct literal call fields lower from MIR without body fallback" {
    const source =
        \\struct Pair { first: u32, second: u32 }
        \\extern fn mark(value: u32) -> u32;
        \\fn ordered_literal() -> Pair {
        \\    return .{ .first = mark(1), .second = mark(2) };
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_struct_literal_call_fields.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal { i32, i32 } @ordered_literal");
    const first = std.mem.indexOf(u8, body, "call i32 @mark(i32 ") orelse return error.TestUnexpectedResult;
    const second = std.mem.indexOfPos(u8, body, first + 1, "call i32 @mark(i32 ") orelse return error.TestUnexpectedResult;
    try std.testing.expect(first < second);
    try expectContains(body, "ret { i32, i32 } %mc_expr_tmp_");
    try expectNotContains(body, "alloca");
    try expectNotContains(body, "store");
}

test "LLVM array literal call elements lower from MIR without body fallback" {
    const source =
        \\extern fn mark(value: u32) -> u32;
        \\fn ordered_literal() -> [2]u32 {
        \\    return .{ mark(1), mark(2) };
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_array_literal_call_elements.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal [2 x i32] @ordered_literal");
    const first = std.mem.indexOf(u8, body, "call i32 @mark(i32 ") orelse return error.TestUnexpectedResult;
    const second = std.mem.indexOfPos(u8, body, first + 1, "call i32 @mark(i32 ") orelse return error.TestUnexpectedResult;
    try std.testing.expect(first < second);
    try expectContains(body, "ret [2 x i32] %mc_expr_tmp_");
    try expectNotContains(body, "alloca");
    try expectNotContains(body, "store");
}

test "LLVM local uninit aggregate assignment returns lower from MIR without body fallback" {
    const source =
        \\struct Pair { first: u32, second: u32 }
        \\fn assigned_struct() -> Pair {
        \\    var out: Pair = uninit;
        \\    out = .{ .second = 22, .first = 11 };
        \\    return out;
        \\}
        \\fn assigned_array() -> [2]u32 {
        \\    var out: [2]u32 = uninit;
        \\    out = .{ 7, 9 };
        \\    return out;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_local_uninit_aggregate_assignment.mc", source, &output);

    const struct_body = try llvmFunctionBody(output.items, "define internal { i32, i32 } @assigned_struct");
    try expectContains(struct_body, "; canonical executable MIR");
    try expectContains(struct_body, "insertvalue { i32, i32 } zeroinitializer, i32 22, 1");
    try expectContains(struct_body, "insertvalue { i32, i32 } %mc_expr_tmp_");
    try expectContains(struct_body, "i32 11, 0");
    try expectContains(struct_body, "store { i32, i32 } %mc_expr_tmp_");
    try expectContains(struct_body, "ret { i32, i32 } %mc_expr_tmp_");

    const array_body = try llvmFunctionBody(output.items, "define internal [2 x i32] @assigned_array");
    try expectContains(array_body, "; canonical executable MIR");
    try expectContains(array_body, "insertvalue [2 x i32] zeroinitializer, i32 7, 0");
    try expectContains(array_body, "insertvalue [2 x i32] %mc_expr_tmp_");
    try expectContains(array_body, "store [2 x i32] %mc_expr_tmp_");
    try expectContains(array_body, "ret [2 x i32] %mc_expr_tmp_");
}

test "LLVM local aggregate place updates return from MIR without body fallback" {
    const source =
        \\struct Pair { left: u32, right: u32 }
        \\struct Box { pair: Pair }
        \\fn assign_field(value: u32) -> u32 {
        \\    var pair: Pair = .{ .left = 1, .right = 2 };
        \\    pair.left = value;
        \\    return pair.left;
        \\}
        \\fn assign_nested_array(value: u32) -> u32 {
        \\    var xs: [2][2]u32 = .{ .{ 1, 2 }, .{ 3, 4 } };
        \\    xs[0][1] = value;
        \\    return xs[0][1];
        \\}
        \\fn local_nested_struct(value: u32) -> u32 {
        \\    var b: Box = .{ .pair = .{ .left = 1, .right = 2 } };
        \\    b.pair.right = value;
        \\    return b.pair.right;
        \\}
        \\fn assign_array_element(value: u32) -> u32 {
        \\    var xs: [2]u32 = .{ 1, 2 };
        \\    xs[0] = value;
        \\    return xs[0];
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_local_aggregate_place_update.mc", source, &output);

    const field_body = try llvmFunctionBody(output.items, "define internal i32 @assign_field");
    try expectContains(field_body, "; canonical executable MIR");
    try expectContains(field_body, "insertvalue { i32, i32 } zeroinitializer, i32 1, 0");
    try expectContains(field_body, "insertvalue { i32, i32 } %mc_expr_tmp_");
    try expectContains(field_body, "store i32 %mc_arg_0, ptr %mc_expr_tmp_");
    try expectContains(field_body, "getelementptr inbounds { i32, i32 }");
    try expectContains(field_body, "load i32, ptr %mc_expr_tmp_");
    try expectContains(field_body, "alloca { i32, i32 }");

    const nested_array_body = try llvmFunctionBody(output.items, "define internal i32 @assign_nested_array");
    try expectContains(nested_array_body, "; canonical executable MIR");
    try expectContains(nested_array_body, "alloca [2 x [2 x i32]]");
    try expectContains(nested_array_body, "store i32 %mc_arg_0, ptr %");
    try expectContains(nested_array_body, "load i32, ptr %");
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, nested_array_body, "call void @mc_trap_Bounds()"));

    const nested_struct_body = try llvmFunctionBody(output.items, "define internal i32 @local_nested_struct");
    try expectContains(nested_struct_body, "; canonical executable MIR");
    try expectContains(nested_struct_body, "alloca { { i32, i32 } }");
    try expectContains(nested_struct_body, "getelementptr inbounds { i32, i32 }");
    try expectContains(nested_struct_body, "store i32 %mc_arg_0, ptr %");
    try expectContains(nested_struct_body, "ret i32 %mc_expr_tmp_");

    const array_body = try llvmFunctionBody(output.items, "define internal i32 @assign_array_element");
    try expectContains(array_body, "; canonical executable MIR");
    try expectContains(array_body, "alloca [2 x i32]");
    try expectContains(array_body, "store i32 %mc_arg_0, ptr %");
    try expectContains(array_body, "load i32, ptr %");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, array_body, "call void @mc_trap_Bounds()"));
}

test "LLVM direct-call aggregate projections return from MIR without body fallback" {
    const source =
        \\struct Bag { values: [4]u32, tail: []const u32 }
        \\extern fn make_values(seed: u32) -> [4]u32;
        \\extern fn make_bag(seed: u32) -> Bag;
        \\fn direct_array_call_index(seed: u32, index: usize) -> u32 { return make_values(seed)[index]; }
        \\fn call_array_field_index(seed: u32, index: usize) -> u32 { return make_bag(seed).values[index]; }
        \\fn call_slice_field_index(seed: u32, index: usize) -> u32 { return make_bag(seed).tail[index]; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_direct_call_aggregate_projections.mc", source, &output);

    const direct_array = try llvmFunctionBody(output.items, "define internal i32 @direct_array_call_index");
    try expectContains(direct_array, "; canonical executable MIR");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, direct_array, "call [4 x i32] @make_values(i32 %mc_arg_0)"));
    try expectContains(direct_array, "call void @mc_trap_Bounds()");
    try expectContains(direct_array, "getelementptr [4 x i32]");

    const array_field = try llvmFunctionBody(output.items, "define internal i32 @call_array_field_index");
    try expectContains(array_field, "; canonical executable MIR");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, array_field, "call { [4 x i32], { ptr, i64 } } @make_bag(i32 %mc_arg_0)"));
    try expectContains(array_field, "extractvalue { [4 x i32], { ptr, i64 } } %mc_expr_tmp_");
    try expectContains(array_field, ", 0");
    try expectContains(array_field, "call void @mc_trap_Bounds()");

    const slice_field = try llvmFunctionBody(output.items, "define internal i32 @call_slice_field_index");
    try expectContains(slice_field, "; canonical executable MIR");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, slice_field, "call { [4 x i32], { ptr, i64 } } @make_bag(i32 %mc_arg_0)"));
    try expectContains(slice_field, "extractvalue { [4 x i32], { ptr, i64 } } %mc_expr_tmp_");
    try expectContains(slice_field, ", 1");
    try expectContains(slice_field, "call void @mc_trap_InvalidRepresentation()");
    try expectContains(slice_field, "call void @mc_trap_Bounds()");
}

test "LLVM returns first fixed-array element from MIR CFG without body fallback" {
    const source =
        \\struct Bag { values: [4]u32 }
        \\extern fn make_values(seed: u32) -> [4]u32;
        \\extern fn make_bag(seed: u32) -> Bag;
        \\extern fn next_seed() -> u32;
        \\extern fn make_slice() -> []const u32;
        \\fn first_value(seed: u32) -> u32 {
        \\    for value in make_values(seed) { return value; }
        \\    return 0;
        \\}
        \\fn first_field(seed: u32) -> u32 {
        \\    for value in make_bag(seed).values { return value; }
        \\    return 0;
        \\}
        \\fn first_parameter(values: [4]u32) -> u32 {
        \\    for value in values { return value; }
        \\    return 0;
        \\}
        \\fn first_nested_call() -> u32 {
        \\    for value in make_values(next_seed()) { return value; }
        \\    return 0;
        \\}
        \\fn first_slice(values: []const u32) -> u32 {
        \\    for value in values { return value; }
        \\    return 0;
        \\}
        \\fn first_slice_call() -> u32 {
        \\    for value in make_slice() { return value; }
        \\    return 0;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_canonical_foreach_return.mc", source, &output);

    const direct = try llvmFunctionBody(output.items, "define internal i32 @first_value");
    try expectContains(direct, "; canonical executable MIR");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, direct, "call [4 x i32] @make_values("));
    try expectContains(direct, "icmp ult i64");
    try expectContains(direct, ", 4");
    try expectContains(direct, "getelementptr inbounds [4 x i32]");
    try expectContains(direct, "ret i32 0");

    const field = try llvmFunctionBody(output.items, "define internal i32 @first_field");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, field, "call { [4 x i32] } @make_bag("));
    try expectContains(field, "extractvalue { [4 x i32] }");
    try expectContains(field, "icmp ult i64");
    try expectContains(field, ", 4");
    try expectContains(field, "ret i32 0");

    const parameter = try llvmFunctionBody(output.items, "define internal i32 @first_parameter");
    try expectContains(parameter, "; canonical executable MIR");
    try expectContains(parameter, "getelementptr inbounds [4 x i32]");
    try expectNotContains(parameter, "@make_values");

    const nested = try llvmFunctionBody(output.items, "define internal i32 @first_nested_call");
    const nested_call = std.mem.indexOf(u8, nested, "call i32 @next_seed()") orelse return error.TestUnexpectedResult;
    const outer_call = std.mem.indexOf(u8, nested, "call [4 x i32] @make_values(") orelse return error.TestUnexpectedResult;
    try std.testing.expect(nested_call < outer_call);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, nested, "call i32 @next_seed()"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, nested, "call [4 x i32] @make_values("));

    const slice = try llvmFunctionBody(output.items, "define internal i32 @first_slice");
    try expectContains(slice, "call void @mc_trap_InvalidRepresentation()");
    try expectContains(slice, "extractvalue { ptr, i64 }");
    try expectContains(slice, "getelementptr i32");

    const slice_call = try llvmFunctionBody(output.items, "define internal i32 @first_slice_call");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, slice_call, "call { ptr, i64 } @make_slice()"));
    try expectContains(slice_call, "call void @mc_trap_InvalidRepresentation()");
    try expectContains(slice_call, "getelementptr i32");
}

test "LLVM emits break and continue while CFG from MIR without body fallback" {
    const source =
        \\fn stop(flag: bool) -> void { while flag { break; } }
        \\fn repeat(flag: bool) -> void { while flag { continue; } }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_while_control.mc", source, &output);

    const stop = try llvmFunctionBody(output.items, "define internal void @stop");
    try expectContains(stop, "; canonical executable MIR");
    try expectContains(stop, "br label %mc_block_1");
    try expectContains(stop, "br i1 %mc_arg_0, label %mc_block_2, label %mc_block_3");
    try expectContains(stop, "mc_block_2:\n  br label %mc_block_3");
    const repeat = try llvmFunctionBody(output.items, "define internal void @repeat");
    try expectContains(repeat, "; canonical executable MIR");
    try expectContains(repeat, "br label %mc_block_1");
    try expectContains(repeat, "br i1 %mc_arg_0, label %mc_block_2, label %mc_block_3");
    try expectContains(repeat, "mc_block_2:\n  br label %mc_block_1");
}

test "LLVM function symbol returns lower from MIR without body fallback" {
    const source =
        \\fn tick() -> void {}
        \\fn entry_of() -> fn() -> void { return tick; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_identity_return.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal ptr @entry_of");
    try expectContains(body, "ret ptr @tick");
}

test "LLVM emits slice length returns from shared MIR plan without body fallback" {
    const source =
        \\fn const_slice_len(values: []const u8) -> usize {
        \\    return values.len;
        \\}
        \\fn mutable_slice_len(values: []mut u32) -> usize {
        \\    return values.len;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_slice_length_return.mc", source, &output);

    const const_body = try llvmFunctionBody(output.items, "define internal i64 @const_slice_len");
    try expectContains(const_body, "extractvalue { ptr, i64 } %mc_arg_0, 0");
    try expectContains(const_body, "extractvalue { ptr, i64 } %mc_arg_0, 1");
    try expectContains(const_body, "ret i64 %mc_expr_tmp_");
    const mutable_body = try llvmFunctionBody(output.items, "define internal i64 @mutable_slice_len");
    try expectContains(mutable_body, "extractvalue { ptr, i64 } %mc_arg_0, 0");
    try expectContains(mutable_body, "extractvalue { ptr, i64 } %mc_arg_0, 1");
    try expectContains(mutable_body, "ret i64 %mc_expr_tmp_");
}

test "LLVM emits slice foreach local updates from MIR without body fallback" {
    const source =
        \\fn sum(values: []const u32) -> u32 {
        \\    var total: u32 = 0;
        \\    for value in values { total = total + value; continue; }
        \\    return total;
        \\}
        \\fn first(values: []const u32) -> u32 {
        \\    var seen: u32 = 0;
        \\    for value in values { seen = value; break; }
        \\    return seen;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_canonical_foreach_update.mc", source, &output);

    const sum = try llvmFunctionBody(output.items, "define internal i32 @sum");
    try expectContains(sum, "; canonical executable MIR");
    try expectContains(sum, "call void @mc_trap_InvalidRepresentation()");
    try expectContains(sum, "@llvm.uadd.with.overflow.i32");
    try expectContains(sum, "mc_for_bind_");
    try expectContains(sum, "add i64");
    try expectContains(sum, "ret i32");
    const first = try llvmFunctionBody(output.items, "define internal i32 @first");
    try expectContains(first, "; canonical executable MIR");
    try expectContains(first, "call void @mc_trap_InvalidRepresentation()");
    try expectContains(first, "mc_for_bind_");
    try expectContains(first, "ret i32");
    try expectNotContains(first, "@llvm.uadd.with.overflow.i32");
}

test "LLVM literal unary components lower from MIR without body fallback" {
    const source =
        \\struct Flags { first: bool, second: bool }
        \\fn struct_ops(flag: bool, other: bool) -> Flags {
        \\    return .{ .first = !flag, .second = !other };
        \\}
        \\fn array_ops(flag: bool, other: bool) -> [2]bool {
        \\    return .{ !flag, !other };
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_literal_unary_components.mc", source, &output);

    const struct_body = try llvmFunctionBody(output.items, "define internal { i1, i1 } @struct_ops");
    try expectContains(struct_body, "; canonical executable MIR");
    try expectContains(struct_body, "xor i1 %mc_arg_0, true");
    try expectContains(struct_body, "xor i1 %mc_arg_1, true");
    try expectContains(struct_body, "ret { i1, i1 } %mc_expr_tmp_");
    try expectNotContains(struct_body, "alloca");
    try expectNotContains(struct_body, "store");

    const array_body = try llvmFunctionBody(output.items, "define internal [2 x i1] @array_ops");
    try expectContains(array_body, "; canonical executable MIR");
    try expectContains(array_body, "xor i1 %mc_arg_0, true");
    try expectContains(array_body, "xor i1 %mc_arg_1, true");
    try expectContains(array_body, "ret [2 x i1] %mc_expr_tmp_");
    try expectNotContains(array_body, "alloca");
    try expectNotContains(array_body, "store");
}

test "LLVM literal compare components lower from MIR without body fallback" {
    const source =
        \\struct Flags { first: bool, second: bool }
        \\fn struct_ops(flag: bool, other: bool) -> Flags {
        \\    return .{ .first = flag == other, .second = flag != other };
        \\}
        \\fn array_ops(flag: bool, other: bool) -> [2]bool {
        \\    return .{ flag == other, flag != other };
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_literal_compare_components.mc", source, &output);

    const struct_body = try llvmFunctionBody(output.items, "define internal { i1, i1 } @struct_ops");
    try expectContains(struct_body, "; canonical executable MIR");
    try expectContains(struct_body, "icmp eq i1");
    try expectContains(struct_body, "icmp ne i1");
    try expectContains(struct_body, "ret { i1, i1 } %mc_expr_tmp_");
    try expectNotContains(struct_body, "alloca");
    try expectNotContains(struct_body, "store");

    const array_body = try llvmFunctionBody(output.items, "define internal [2 x i1] @array_ops");
    try expectContains(array_body, "; canonical executable MIR");
    try expectContains(array_body, "icmp eq i1");
    try expectContains(array_body, "icmp ne i1");
    try expectContains(array_body, "ret [2 x i1] %mc_expr_tmp_");
    try expectNotContains(array_body, "alloca");
    try expectNotContains(array_body, "store");
}

test "LLVM literal checked arithmetic components lower from MIR without body fallback" {
    const source =
        \\struct Pair { first: u32, second: u32 }
        \\fn struct_ops(a: u32, b: u32, c: u32) -> Pair {
        \\    return .{ .first = a + b, .second = b + c };
        \\}
        \\fn array_ops(a: u32, b: u32, c: u32) -> [2]u32 {
        \\    return .{ a + b, b + c };
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_literal_checked_arithmetic_components.mc", source, &output);

    const struct_body = try llvmFunctionBody(output.items, "define internal { i32, i32 } @struct_ops");
    try expectContains(struct_body, "; canonical executable MIR");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, struct_body, "llvm.uadd.with.overflow.i32"));
    try expectContains(struct_body, "call void @mc_trap_IntegerOverflow()");
    try expectContains(struct_body, "ret { i32, i32 } %mc_expr_tmp_");
    try expectNotContains(struct_body, "alloca");
    try expectNotContains(struct_body, "store");

    const array_body = try llvmFunctionBody(output.items, "define internal [2 x i32] @array_ops");
    try expectContains(array_body, "; canonical executable MIR");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, array_body, "llvm.uadd.with.overflow.i32"));
    try expectContains(array_body, "call void @mc_trap_IntegerOverflow()");
    try expectContains(array_body, "ret [2 x i32] %mc_expr_tmp_");
    try expectNotContains(array_body, "alloca");
    try expectNotContains(array_body, "store");
}

test "LLVM literal checked unary components lower from MIR without body fallback" {
    const source =
        \\struct Pair { first: i32, second: i32 }
        \\fn struct_ops(a: i32, b: i32) -> Pair {
        \\    return .{ .first = -a, .second = -b };
        \\}
        \\fn array_ops(a: i32, b: i32) -> [2]i32 {
        \\    return .{ -a, -b };
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_literal_checked_unary_components.mc", source, &output);

    const struct_body = try llvmFunctionBody(output.items, "define internal { i32, i32 } @struct_ops");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, struct_body, "llvm.ssub.with.overflow.i32"));
    if (std.mem.indexOf(u8, struct_body, "; canonical executable MIR") != null) {
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, struct_body, "call void @mc_trap_IntegerOverflow()"));
        try expectContains(struct_body, "ret { i32, i32 } %mc_expr_tmp_");
    } else {
        try expectContains(struct_body, "trap_overflow");
        try expectContains(struct_body, "ret { i32, i32 } %t");
    }
    try expectNotContains(struct_body, "alloca");
    try expectNotContains(struct_body, "store");

    const array_body = try llvmFunctionBody(output.items, "define internal [2 x i32] @array_ops");
    try expectContains(array_body, "; canonical executable MIR");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, array_body, "llvm.ssub.with.overflow.i32"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, array_body, "call void @mc_trap_IntegerOverflow()"));
    try expectContains(array_body, "ret [2 x i32] %mc_expr_tmp_");
    try expectNotContains(array_body, "alloca");
    try expectNotContains(array_body, "store");
}

test "LLVM local literal checked components return from MIR without body fallback" {
    const source =
        \\struct Pair { first: u32, second: u32 }
        \\fn local_struct(a: u32, b: u32, c: u32) -> Pair {
        \\    let p: Pair = .{ .first = a + b, .second = b + c };
        \\    return p;
        \\}
        \\fn local_array(a: u32, b: u32, c: u32) -> [2]u32 {
        \\    let p: [2]u32 = .{ a + b, b + c };
        \\    return p;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_local_literal_checked_components.mc", source, &output);

    const struct_body = try llvmFunctionBody(output.items, "define internal { i32, i32 } @local_struct");
    try expectContains(struct_body, "; canonical executable MIR");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, struct_body, "llvm.uadd.with.overflow.i32"));
    try expectContains(struct_body, "call void @mc_trap_IntegerOverflow()");
    try expectContains(struct_body, "ret { i32, i32 } %mc_expr_tmp_");
    try expectContains(struct_body, "alloca { i32, i32 }");
    try expectContains(struct_body, "store { i32, i32 }");

    const array_body = try llvmFunctionBody(output.items, "define internal [2 x i32] @local_array");
    try expectContains(array_body, "; canonical executable MIR");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, array_body, "llvm.uadd.with.overflow.i32"));
    try expectContains(array_body, "call void @mc_trap_IntegerOverflow()");
    try expectContains(array_body, "ret [2 x i32] %mc_expr_tmp_");
    try expectContains(array_body, "alloca [2 x i32]");
    try expectContains(array_body, "store [2 x i32]");
}

test "LLVM assigned literal checked components return from MIR without body fallback" {
    const source =
        \\struct Pair { first: u32, second: u32 }
        \\fn assigned_struct(a: u32, b: u32, c: u32) -> Pair {
        \\    var p: Pair = .{ .first = a, .second = b };
        \\    p = .{ .first = a + b, .second = b + c };
        \\    return p;
        \\}
        \\fn assigned_array(a: u32, b: u32, c: u32) -> [2]u32 {
        \\    var p: [2]u32 = .{ a, b };
        \\    p = .{ a + b, b + c };
        \\    return p;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_assigned_literal_checked_components.mc", source, &output);

    const struct_body = try llvmFunctionBody(output.items, "define internal { i32, i32 } @assigned_struct");
    try expectContains(struct_body, "; canonical executable MIR");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, struct_body, "llvm.uadd.with.overflow.i32"));
    try expectContains(struct_body, "call void @mc_trap_IntegerOverflow()");
    try expectContains(struct_body, "ret { i32, i32 } %mc_expr_tmp_");
    try expectContains(struct_body, "alloca { i32, i32 }");
    try expectContains(struct_body, "store { i32, i32 }");

    const array_body = try llvmFunctionBody(output.items, "define internal [2 x i32] @assigned_array");
    try expectContains(array_body, "; canonical executable MIR");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, array_body, "llvm.uadd.with.overflow.i32"));
    try expectContains(array_body, "call void @mc_trap_IntegerOverflow()");
    try expectContains(array_body, "ret [2 x i32] %mc_expr_tmp_");
    try expectContains(array_body, "alloca [2 x i32]");
    try expectContains(array_body, "store [2 x i32]");
}

test "LLVM local and assigned literal call components return from MIR without body fallback" {
    const source =
        \\struct Pair { first: u32, second: u32 }
        \\extern fn mark(value: u32) -> u32;
        \\fn local_struct() -> Pair {
        \\    let p: Pair = .{ .first = mark(1), .second = mark(2) };
        \\    return p;
        \\}
        \\fn assigned_struct() -> Pair {
        \\    var p: Pair = .{ .first = 0, .second = 0 };
        \\    p = .{ .first = mark(3), .second = mark(4) };
        \\    return p;
        \\}
        \\fn local_array() -> [2]u32 {
        \\    let p: [2]u32 = .{ mark(5), mark(6) };
        \\    return p;
        \\}
        \\fn assigned_array() -> [2]u32 {
        \\    var p: [2]u32 = .{ 0, 0 };
        \\    p = .{ mark(7), mark(8) };
        \\    return p;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_local_assigned_literal_call_components.mc", source, &output);

    const local_struct_body = try llvmFunctionBody(output.items, "define internal { i32, i32 } @local_struct");
    try expectContains(local_struct_body, "call i32 @mark(i32 1)");
    try expectContains(local_struct_body, "call i32 @mark(i32 2)");
    if (std.mem.indexOf(u8, local_struct_body, "; canonical executable MIR") != null) {
        try expectContains(local_struct_body, "ret { i32, i32 } %mc_expr_tmp_");
        try expectContains(local_struct_body, "alloca { i32, i32 }");
        try expectContains(local_struct_body, "store { i32, i32 }");
    } else {
        try expectContains(local_struct_body, "ret { i32, i32 } %t");
        try expectNotContains(local_struct_body, "alloca");
        try expectNotContains(local_struct_body, "store");
    }

    const assigned_struct_body = try llvmFunctionBody(output.items, "define internal { i32, i32 } @assigned_struct");
    try expectContains(assigned_struct_body, "call i32 @mark(i32 3)");
    try expectContains(assigned_struct_body, "call i32 @mark(i32 4)");
    if (std.mem.indexOf(u8, assigned_struct_body, "; canonical executable MIR") != null) {
        try expectContains(assigned_struct_body, "ret { i32, i32 } %mc_expr_tmp_");
        try expectContains(assigned_struct_body, "alloca { i32, i32 }");
        try expectContains(assigned_struct_body, "store { i32, i32 }");
    } else {
        try expectContains(assigned_struct_body, "ret { i32, i32 } %t");
        try expectNotContains(assigned_struct_body, "alloca");
        try expectNotContains(assigned_struct_body, "store");
    }

    const local_array_body = try llvmFunctionBody(output.items, "define internal [2 x i32] @local_array");
    try expectContains(local_array_body, "call i32 @mark(i32 5)");
    try expectContains(local_array_body, "call i32 @mark(i32 6)");
    if (std.mem.indexOf(u8, local_array_body, "; canonical executable MIR") != null) {
        try expectContains(local_array_body, "ret [2 x i32] %mc_expr_tmp_");
        try expectContains(local_array_body, "alloca [2 x i32]");
        try expectContains(local_array_body, "store [2 x i32]");
    } else {
        try expectContains(local_array_body, "ret [2 x i32] %t");
        try expectNotContains(local_array_body, "alloca");
        try expectNotContains(local_array_body, "store");
    }

    const assigned_array_body = try llvmFunctionBody(output.items, "define internal [2 x i32] @assigned_array");
    try expectContains(assigned_array_body, "call i32 @mark(i32 7)");
    try expectContains(assigned_array_body, "call i32 @mark(i32 8)");
    if (std.mem.indexOf(u8, assigned_array_body, "; canonical executable MIR") != null) {
        try expectContains(assigned_array_body, "ret [2 x i32] %mc_expr_tmp_");
        try expectContains(assigned_array_body, "alloca [2 x i32]");
        try expectContains(assigned_array_body, "store [2 x i32]");
    } else {
        try expectContains(assigned_array_body, "ret [2 x i32] %t");
        try expectNotContains(assigned_array_body, "alloca");
        try expectNotContains(assigned_array_body, "store");
    }
}

test "LLVM local and assigned aggregate direct calls return from MIR without body fallback" {
    const source =
        \\struct Pair { first: u32, second: u32 }
        \\extern fn hit(value: u32) -> void;
        \\extern fn make_pair(value: u32) -> Pair;
        \\extern fn make_array(value: u32) -> [2]u32;
        \\fn local_struct(value: u32) -> Pair {
        \\    let p: Pair = make_pair(value);
        \\    return p;
        \\}
        \\fn assigned_struct(value: u32) -> Pair {
        \\    var p: Pair = .{ .first = 0, .second = 0 };
        \\    p = make_pair(value);
        \\    return p;
        \\}
        \\fn side_then_local_struct(value: u32) -> Pair {
        \\    hit(1);
        \\    let p: Pair = make_pair(value);
        \\    return p;
        \\}
        \\fn local_array(value: u32) -> [2]u32 {
        \\    let p: [2]u32 = make_array(value);
        \\    return p;
        \\}
        \\fn assigned_array(value: u32) -> [2]u32 {
        \\    var p: [2]u32 = .{ 0, 0 };
        \\    p = make_array(value);
        \\    return p;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_local_assigned_aggregate_direct_calls.mc", source, &output);

    const local_struct_body = try llvmFunctionBody(output.items, "define internal { i32, i32 } @local_struct");
    if (std.mem.indexOf(u8, local_struct_body, "; canonical executable MIR") != null) {
        try expectContains(local_struct_body, "call { i32, i32 } @make_pair(i32 %mc_arg_0)");
        try expectContains(local_struct_body, "ret { i32, i32 } %mc_expr_tmp_");
        try expectContains(local_struct_body, "alloca { i32, i32 }");
        try expectContains(local_struct_body, "store { i32, i32 }");
    } else {
        try expectContains(local_struct_body, "call { i32, i32 } @make_pair(i32 %value)");
        try expectContains(local_struct_body, "ret { i32, i32 } %t");
        try expectNotContains(local_struct_body, "alloca");
        try expectNotContains(local_struct_body, "store");
    }

    const assigned_struct_body = try llvmFunctionBody(output.items, "define internal { i32, i32 } @assigned_struct");
    if (std.mem.indexOf(u8, assigned_struct_body, "; canonical executable MIR") != null) {
        try expectContains(assigned_struct_body, "call { i32, i32 } @make_pair(i32 %mc_arg_0)");
        try expectContains(assigned_struct_body, "ret { i32, i32 } %mc_expr_tmp_");
        try expectContains(assigned_struct_body, "alloca { i32, i32 }");
        try expectContains(assigned_struct_body, "store { i32, i32 }");
    } else {
        try expectContains(assigned_struct_body, "call { i32, i32 } @make_pair(i32 %value)");
        try expectContains(assigned_struct_body, "ret { i32, i32 } %t");
        try expectNotContains(assigned_struct_body, "alloca");
        try expectNotContains(assigned_struct_body, "store");
    }

    const side_body = try llvmFunctionBody(output.items, "define internal { i32, i32 } @side_then_local_struct");
    const hit = std.mem.indexOf(u8, side_body, "call void @hit(i32 1)") orelse return error.TestUnexpectedResult;
    const canonical_side = std.mem.indexOf(u8, side_body, "; canonical executable MIR") != null;
    const call = std.mem.indexOf(u8, side_body, if (canonical_side) "call { i32, i32 } @make_pair(i32 %mc_arg_0)" else "call { i32, i32 } @make_pair(i32 %value)") orelse return error.TestUnexpectedResult;
    const ret = std.mem.indexOf(u8, side_body, if (canonical_side) "ret { i32, i32 } %mc_expr_tmp_" else "ret { i32, i32 } %t") orelse return error.TestUnexpectedResult;
    try std.testing.expect(hit < call);
    try std.testing.expect(call < ret);
    if (canonical_side) {
        try expectContains(side_body, "alloca { i32, i32 }");
        try expectContains(side_body, "store { i32, i32 }");
    } else {
        try expectNotContains(side_body, "alloca");
        try expectNotContains(side_body, "store");
    }

    const local_array_body = try llvmFunctionBody(output.items, "define internal [2 x i32] @local_array");
    if (std.mem.indexOf(u8, local_array_body, "; canonical executable MIR") != null) {
        try expectContains(local_array_body, "call [2 x i32] @make_array(i32 %mc_arg_0)");
        try expectContains(local_array_body, "ret [2 x i32] %mc_expr_tmp_");
        try expectContains(local_array_body, "alloca [2 x i32]");
        try expectContains(local_array_body, "store [2 x i32]");
    } else {
        try expectContains(local_array_body, "call [2 x i32] @make_array(i32 %value)");
        try expectContains(local_array_body, "ret [2 x i32] %t");
        try expectNotContains(local_array_body, "alloca");
        try expectNotContains(local_array_body, "store");
    }

    const assigned_array_body = try llvmFunctionBody(output.items, "define internal [2 x i32] @assigned_array");
    if (std.mem.indexOf(u8, assigned_array_body, "; canonical executable MIR") != null) {
        try expectContains(assigned_array_body, "call [2 x i32] @make_array(i32 %mc_arg_0)");
        try expectContains(assigned_array_body, "ret [2 x i32] %mc_expr_tmp_");
        try expectContains(assigned_array_body, "alloca [2 x i32]");
        try expectContains(assigned_array_body, "store [2 x i32]");
    } else {
        try expectContains(assigned_array_body, "call [2 x i32] @make_array(i32 %value)");
        try expectContains(assigned_array_body, "ret [2 x i32] %t");
        try expectNotContains(assigned_array_body, "alloca");
        try expectNotContains(assigned_array_body, "store");
    }
}

test "LLVM grouped scalar expressions return from MIR without body fallback" {
    const source =
        \\extern fn make(value: u16) -> u16;
        \\fn grouped_param(value: u16) -> u16 {
        \\    return (value);
        \\}
        \\fn grouped_binary(value: u16) -> u16 {
        \\    return (value) + 1;
        \\}
        \\fn grouped_call(value: u16) -> u16 {
        \\    let x: u16 = (make(value));
        \\    return x;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_grouped_scalar_returns.mc", source, &output);

    const param_body = try llvmFunctionBody(output.items, "define internal i16 @grouped_param");
    try expectContains(param_body, "ret i16 %");
    try expectNotContains(param_body, "alloca");

    const binary_body = try llvmFunctionBody(output.items, "define internal i16 @grouped_binary");
    try expectContains(binary_body, "@llvm.uadd.with.overflow.i16");
    try expectContains(binary_body, "ret i16 %");
    try expectNotContains(binary_body, "alloca");

    const call_body = try llvmFunctionBody(output.items, "define internal i16 @grouped_call");
    try expectContains(call_body, "call i16 @make(i16 %");
    try expectContains(call_body, "ret i16 %");
}

test "LLVM void calls before grouped scalar returns lower from MIR without body fallback" {
    const source =
        \\extern fn hit(value: u16) -> void;
        \\extern fn make(value: u16) -> u16;
        \\fn side_then_grouped_param(value: u16) -> u16 {
        \\    hit(1);
        \\    return (value);
        \\}
        \\fn side_then_grouped_binary(value: u16) -> u16 {
        \\    hit(2);
        \\    return (value) + 1;
        \\}
        \\fn side_then_grouped_call(value: u16) -> u16 {
        \\    hit(3);
        \\    let x: u16 = (make(value));
        \\    return x;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_void_calls_before_grouped_scalar_returns.mc", source, &output);

    const param_body = try llvmFunctionBody(output.items, "define internal i16 @side_then_grouped_param");
    const param_hit = std.mem.indexOf(u8, param_body, "call void @hit(i16 ") orelse return error.TestUnexpectedResult;
    const param_ret = std.mem.indexOf(u8, param_body, "ret i16 %") orelse return error.TestUnexpectedResult;
    try std.testing.expect(param_hit < param_ret);

    const binary_body = try llvmFunctionBody(output.items, "define internal i16 @side_then_grouped_binary");
    const binary_hit = std.mem.indexOf(u8, binary_body, "call void @hit(i16 ") orelse return error.TestUnexpectedResult;
    const binary_add = std.mem.indexOf(u8, binary_body, "@llvm.uadd.with.overflow.i16") orelse return error.TestUnexpectedResult;
    const binary_ret = std.mem.indexOf(u8, binary_body, "ret i16 %") orelse return error.TestUnexpectedResult;
    try std.testing.expect(binary_hit < binary_add);
    try std.testing.expect(binary_add < binary_ret);

    const call_body = try llvmFunctionBody(output.items, "define internal i16 @side_then_grouped_call");
    const call_hit = std.mem.indexOf(u8, call_body, "call void @hit(i16 ") orelse return error.TestUnexpectedResult;
    const call_make = std.mem.indexOf(u8, call_body, "call i16 @make(i16 %mc_arg_0)") orelse return error.TestUnexpectedResult;
    const call_ret = std.mem.indexOf(u8, call_body, "ret i16 %mc_expr_tmp_") orelse return error.TestUnexpectedResult;
    try std.testing.expect(call_hit < call_make);
    try std.testing.expect(call_make < call_ret);
    if (std.mem.indexOf(u8, call_body, "; canonical executable MIR") == null) try expectNotContains(call_body, "alloca");
}

test "LLVM conditional grouped scalar returns lower from MIR without body fallback" {
    const source =
        \\extern fn make(value: u16) -> u16;
        \\fn choose_grouped_param(flag: bool, value: u16) -> u16 {
        \\    if (flag) {
        \\        return (value);
        \\    } else {
        \\        return (value);
        \\    }
        \\}
        \\fn choose_grouped_binary(flag: bool, value: u16) -> u16 {
        \\    if (flag) {
        \\        return (value) + 1;
        \\    } else {
        \\        return (value) + 2;
        \\    }
        \\}
        \\fn choose_grouped_call(flag: bool, value: u16) -> u16 {
        \\    if (flag) {
        \\        return (make(value));
        \\    } else {
        \\        return (make(value));
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_conditional_grouped_scalar_returns.mc", source, &output);

    const param_body = try llvmFunctionBody(output.items, "define internal i16 @choose_grouped_param");
    try expectCanonicalConditional(param_body);
    try expectContains(param_body, "ret i16 %");
    try expectNotContains(param_body, "alloca");

    const binary_body = try llvmFunctionBody(output.items, "define internal i16 @choose_grouped_binary");
    try expectContains(binary_body, "@llvm.uadd.with.overflow.i16");
    try expectCanonicalConditional(binary_body);
    try expectContains(binary_body, "ret i16 %mc_expr_tmp_");
    try expectNotContains(binary_body, "alloca");

    const call_body = try llvmFunctionBody(output.items, "define internal i16 @choose_grouped_call");
    try expectCanonicalConditional(call_body);
    try expectContains(call_body, "call i16 @make(i16 %mc_arg_1)");
    try expectContains(call_body, "ret i16 %mc_expr_tmp_");
    try expectNotContains(call_body, "alloca");
}

test "LLVM conditional global and call returns lower from MIR without body fallback" {
    const source =
        \\global g: u32 = 0;
        \\extern fn hit(value: u32) -> void;
        \\extern fn make(value: u32) -> u32;
        \\fn choose_global(flag: bool) -> u32 {
        \\    if (flag) {
        \\        hit(g);
        \\        return g;
        \\    } else {
        \\        return g;
        \\    }
        \\}
        \\fn choose_call(flag: bool, value: u32) -> u32 {
        \\    if (flag) {
        \\        hit(value);
        \\        return make(value);
        \\    } else {
        \\        return make(value);
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_conditional_global_call_returns.mc", source, &output);

    const global_body = try llvmFunctionBody(output.items, "define internal i32 @choose_global");
    try expectCanonicalConditional(global_body);
    try expectContains(global_body, "load atomic i32, ptr @g unordered, align 4");
    try expectContains(global_body, "call void @hit(i32 %mc_expr_tmp_");
    try expectContains(global_body, "ret i32 %mc_expr_tmp_");
    try expectNotContains(global_body, "alloca");

    const call_body = try llvmFunctionBody(output.items, "define internal i32 @choose_call");
    try expectCanonicalConditional(call_body);
    try expectContains(call_body, "call void @hit(i32 %mc_arg_1)");
    try expectContains(call_body, "call i32 @make(i32 %mc_arg_1)");
    try expectContains(call_body, "ret i32 %mc_expr_tmp_");
    try expectNotContains(call_body, "alloca");
}

test "LLVM conditional statement returns lower from MIR" {
    const source =
        \\extern fn hit(value: u32) -> void;
        \\extern fn make(value: u32) -> u32;
        \\fn choose_call(flag: bool, value: u32) -> u32 {
        \\    if (flag) {
        \\        hit(value);
        \\        return make(value);
        \\    } else {
        \\        return make(value);
        \\    }
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_mir_fallback_poison.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    var artifacts = try test_artifact_support.collectArtifactsFromDecls(std.testing.allocator, parsed.decls(), &module_mir);
    defer artifacts.deinit(std.testing.allocator);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_llvm.appendLlvmCheckedMirArtifacts(
        std.testing.allocator,
        artifacts.codegen(),
        &module_mir,
        &output,
        "llvm_mir_fallback_poison.mc",
        .{},
        false,
        .riscv64,
        false,
        null,
    );

    const call_body = try llvmFunctionBody(output.items, "define internal i32 @choose_call");
    try expectCanonicalConditional(call_body);
    try expectContains(call_body, "call void @hit(i32 %mc_arg_1)");
    try expectContains(call_body, "call i32 @make(i32 %mc_arg_1)");
}

test "LLVM loop grouped scalar returns lower from MIR without body fallback" {
    const source =
        \\extern fn hit(value: u16) -> void;
        \\extern fn make(value: u16) -> u16;
        \\fn loop_grouped_param(flag: bool, value: u16) -> u16 {
        \\    while flag {
        \\        hit(value);
        \\    }
        \\    return (value);
        \\}
        \\fn loop_grouped_call(flag: bool, value: u16) -> u16 {
        \\    while flag {
        \\        hit(value);
        \\    }
        \\    let x: u16 = (make(value));
        \\    return x;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_loop_grouped_scalar_returns.mc", source, &output);

    const param_body = try llvmFunctionBody(output.items, "define internal i16 @loop_grouped_param");
    try expectContains(param_body, "br i1 %");
    try expectContains(param_body, "call void @hit(i16 %");
    try expectContains(param_body, "ret i16 %");
    try expectNotContains(param_body, "alloca");

    const call_body = try llvmFunctionBody(output.items, "define internal i16 @loop_grouped_call");
    try expectContains(call_body, "br i1 %");
    try expectContains(call_body, "call i16 @make(i16 %");
    try expectContains(call_body, "ret i16 %");
}

test "LLVM loop derived scalar returns lower from MIR without body fallback" {
    const source =
        \\extern fn hit(value: u16) -> void;
        \\fn loop_compare(flag: bool, value: u16) -> bool {
        \\    while flag {
        \\        hit(value);
        \\    }
        \\    return value == 0;
        \\}
        \\fn loop_not(flag: bool, value: u16, other: bool) -> bool {
        \\    while flag {
        \\        hit(value);
        \\    }
        \\    return !other;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_loop_derived_scalar_returns.mc", source, &output);

    const compare_body = try llvmFunctionBody(output.items, "define internal i1 @loop_compare");
    try expectContains(compare_body, "br i1 %");
    try expectContains(compare_body, "call void @hit(i16 %");
    try expectContains(compare_body, "icmp eq i16 %");
    try expectNotContains(compare_body, "alloca");

    const not_body = try llvmFunctionBody(output.items, "define internal i1 @loop_not");
    try expectContains(not_body, "br i1 %");
    try expectContains(not_body, "call void @hit(i16 %");
    try expectContains(not_body, "xor i1 %");
    try expectContains(not_body, ", true");
    try expectNotContains(not_body, "alloca");
}

test "LLVM loop checked scalar returns lower from MIR without body fallback" {
    const source =
        \\extern fn hit(value: u16) -> void;
        \\fn loop_checked_add(flag: bool, value: u16) -> u16 {
        \\    while flag {
        \\        hit(value);
        \\    }
        \\    return (value) + 1;
        \\}
        \\fn loop_checked_neg(flag: bool, value: i16) -> i16 {
        \\    while flag {
        \\        hit(1);
        \\    }
        \\    return -value;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_loop_checked_scalar_returns.mc", source, &output);

    const add_body = try llvmFunctionBody(output.items, "define internal i16 @loop_checked_add");
    try expectContains(add_body, "br i1 %");
    try expectContains(add_body, "call void @hit(i16 %");
    try expectContains(add_body, "@llvm.uadd.with.overflow.i16");
    try expectContains(add_body, "ret i16 %");
    try expectNotContains(add_body, "alloca");

    const neg_body = try llvmFunctionBody(output.items, "define internal i16 @loop_checked_neg");
    try expectContains(neg_body, "br i1 %mc_arg_0");
    try expectContains(neg_body, "call void @hit(i16 ");
    try expectContains(neg_body, "@llvm.ssub.with.overflow.i16");
    try expectContains(neg_body, "ret i16 %mc_expr_tmp_");
    try expectNotContains(neg_body, "alloca");
}

test "LLVM loop call and global returns lower from MIR without body fallback" {
    const source =
        \\global g: u32 = 0;
        \\extern fn hit_u16(value: u16) -> void;
        \\extern fn hit_u32(value: u32) -> void;
        \\extern fn make(value: u16) -> u16;
        \\fn loop_direct_call(flag: bool, value: u16) -> u16 {
        \\    while flag {
        \\        hit_u16(value);
        \\    }
        \\    return make(value);
        \\}
        \\fn loop_global(flag: bool) -> u32 {
        \\    while flag {
        \\        hit_u32(g);
        \\    }
        \\    return g;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_loop_call_global_returns.mc", source, &output);

    const call_body = try llvmFunctionBody(output.items, "define internal i16 @loop_direct_call");
    try expectContains(call_body, "br i1 %");
    try expectContains(call_body, "call void @hit_u16(i16 %");
    try expectContains(call_body, "call i16 @make(i16 %");
    try expectContains(call_body, "ret i16 %");
    try expectNotContains(call_body, "alloca");

    const global_body = try llvmFunctionBody(output.items, "define internal i32 @loop_global");
    try expectContains(global_body, "; canonical executable MIR");
    try expectContains(global_body, "br i1 %mc_");
    try expectContains(global_body, "load atomic i32, ptr @g unordered, align 4");
    try expectContains(global_body, "call void @hit_u32(i32 %mc_expr_tmp_");
    try expectContains(global_body, "ret i32 %mc_expr_tmp_");
    try expectNotContains(global_body, "alloca");
}

test "LLVM MIR conditional fast path uses only the switch subject expression" {
    const source =
        \\global g: u32 = 0;
        \\extern fn hit(value: u32) -> void;
        \\fn choose_cmp(a: i32, b: i32) -> i32 {
        \\    if (a < b) {
        \\        return 1;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        \\fn choose_not(flag: bool) -> i32 {
        \\    if (!flag) {
        \\        return 1;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        \\fn choose_local(a: i32, b: i32) -> i32 {
        \\    var c: bool = a < b;
        \\    if (c) {
        \\        return 1;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        \\fn choose_local_not(flag: bool) -> i32 {
        \\    var c: bool = !flag;
        \\    if (c) {
        \\        return 1;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        \\fn choose_reassign(a: i32, b: i32) -> i32 {
        \\    var c: bool = a < b;
        \\    c = false;
        \\    if (c) {
        \\        return 1;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        \\fn choose_early(flag: bool) -> i32 {
        \\    if (flag) {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
        \\fn choose_branch_local_return(flag: bool) -> i32 {
        \\    if (flag) {
        \\        let x: i32 = 1;
        \\        return x;
        \\    } else {
        \\        var y: i32 = 0;
        \\        y = 2;
        \\        return y;
        \\    }
        \\}
        \\fn choose_literal_local_condition() -> i32 {
        \\    var c: bool = false;
        \\    if (c) {
        \\        return 1;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        \\fn choose_store_then_return(flag: bool, x: u32) -> u32 {
        \\    if (flag) {
        \\        g = x;
        \\    }
        \\    return x;
        \\}
        \\fn choose_call_then_return(flag: bool, x: u32) -> u32 {
        \\    if (flag) {
        \\        hit(x);
        \\    }
        \\    return x;
        \\}
        \\fn choose_store_suffix_return(flag: bool, x: u32) -> u32 {
        \\    if (flag) {
        \\        g = x;
        \\    }
        \\    hit(x);
        \\    return x;
        \\}
        \\fn choose_call_suffix_return(flag: bool, x: u32) -> u32 {
        \\    if (flag) {
        \\        hit(x);
        \\    }
        \\    g = x;
        \\    return x;
        \\}
        \\fn choose_empty_suffix_return(flag: bool, x: u32) -> u32 {
        \\    if (flag) {
        \\    }
        \\    g = x;
        \\    return x;
        \\}
        \\fn choose_empty_return(flag: bool, x: u32) -> u32 {
        \\    if (flag) {
        \\    }
        \\    return x;
        \\}
        \\fn loop_empty_return(flag: bool, x: u32) -> u32 {
        \\    while flag {
        \\    }
        \\    return x;
        \\}
        \\fn loop_call_return(flag: bool, x: u32) -> u32 {
        \\    while flag {
        \\        hit(x);
        \\    }
        \\    return x;
        \\}
        \\fn loop_cmp_return(a: i32, b: i32, x: u32) -> u32 {
        \\    while a < b {
        \\        hit(x);
        \\    }
        \\    return x;
        \\}
        \\fn choose_branch_effect_return(flag: bool, x: u32) -> u32 {
        \\    if (flag) {
        \\        hit(x);
        \\        return 1;
        \\    } else {
        \\        g = x;
        \\        return 2;
        \\    }
        \\}
        \\fn choose_mixed_branch_effect_return(flag: bool, x: u32) -> u32 {
        \\    if (flag) {
        \\        hit(x);
        \\        return 1;
        \\    }
        \\    g = x;
        \\    return 2;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_conditional_subject.mc", source, &output);

    const compare_body = try llvmFunctionBody(output.items, "define internal i32 @choose_cmp");
    try expectContains(compare_body, "icmp slt i32 ");
    try expectContains(compare_body, "br i1 %");

    const not_body = try llvmFunctionBody(output.items, "define internal i32 @choose_not");
    try expectContains(not_body, "br i1 %");

    const local_body = try llvmFunctionBody(output.items, "define internal i32 @choose_local");
    try expectContains(local_body, "icmp slt i32 ");
    try expectContains(local_body, "br i1 %");

    const local_not_body = try llvmFunctionBody(output.items, "define internal i32 @choose_local_not");
    try expectContains(local_not_body, "br i1 %");

    const reassign_body = try llvmFunctionBody(output.items, "define internal i32 @choose_reassign");
    try expectContains(reassign_body, "br i1 ");
    try expectContains(reassign_body, "store i1 false");
    try expectContains(reassign_body, "ret i32 1");
    try expectContains(reassign_body, "ret i32 0");
    try expectNotContains(reassign_body, "switch");

    const early_body = try llvmFunctionBody(output.items, "define internal i32 @choose_early");
    try expectContains(early_body, "br i1 %");
    try expectContains(early_body, "ret i32 1");
    try expectContains(early_body, "ret i32 0");
    try expectNotContains(early_body, "switch");

    const branch_local_body = try llvmFunctionBody(output.items, "define internal i32 @choose_branch_local_return");
    try expectContains(branch_local_body, "br i1 ");
    try expectContains(branch_local_body, "1");
    try expectContains(branch_local_body, "2");
    try expectContains(branch_local_body, "ret i32");
    try expectNotContains(branch_local_body, "switch");

    const literal_body = try llvmFunctionBody(output.items, "define internal i32 @choose_literal_local_condition");
    try expectContains(literal_body, "br i1 ");
    try expectContains(literal_body, "store i1 false");
    try expectContains(literal_body, "ret i32 1");
    try expectContains(literal_body, "ret i32 0");
    try expectNotContains(literal_body, "switch");

    const store_return_body = try llvmFunctionBody(output.items, "define internal i32 @choose_store_then_return");
    const store_branch = std.mem.indexOf(u8, store_return_body, "br i1 %mc_") orelse return error.TestUnexpectedResult;
    const store_stmt = std.mem.indexOf(u8, store_return_body, "store atomic i32 %mc_arg_1, ptr @g unordered, align 4") orelse return error.TestUnexpectedResult;
    const store_return = std.mem.indexOf(u8, store_return_body, "ret i32 %mc_arg_1") orelse return error.TestUnexpectedResult;
    _ = store_branch;
    _ = store_stmt;
    _ = store_return;
    try expectNotContains(store_return_body, "switch");
    try expectNotContains(store_return_body, "alloca");

    const call_return_body = try llvmFunctionBody(output.items, "define internal i32 @choose_call_then_return");
    const call_branch = std.mem.indexOf(u8, call_return_body, "br i1 %") orelse return error.TestUnexpectedResult;
    const call_stmt = std.mem.indexOf(u8, call_return_body, "call void @hit(i32 %") orelse return error.TestUnexpectedResult;
    const call_return = std.mem.indexOf(u8, call_return_body, "ret i32 %") orelse return error.TestUnexpectedResult;
    _ = call_branch;
    _ = call_stmt;
    _ = call_return;
    try expectNotContains(call_return_body, "switch");
    try expectNotContains(call_return_body, "alloca");

    const store_suffix_return_body = try llvmFunctionBody(output.items, "define internal i32 @choose_store_suffix_return");
    const store_suffix_branch = std.mem.indexOf(u8, store_suffix_return_body, "br i1 %mc_") orelse return error.TestUnexpectedResult;
    const store_suffix_store = std.mem.indexOf(u8, store_suffix_return_body, "store atomic i32 %mc_arg_1, ptr @g unordered, align 4") orelse return error.TestUnexpectedResult;
    const store_suffix_call = std.mem.indexOf(u8, store_suffix_return_body, "call void @hit(i32 %mc_arg_1)") orelse return error.TestUnexpectedResult;
    const store_suffix_return = std.mem.indexOf(u8, store_suffix_return_body, "ret i32 %mc_arg_1") orelse return error.TestUnexpectedResult;
    _ = store_suffix_branch;
    _ = store_suffix_store;
    _ = store_suffix_call;
    _ = store_suffix_return;
    try expectNotContains(store_suffix_return_body, "switch");
    try expectNotContains(store_suffix_return_body, "alloca");

    const call_suffix_return_body = try llvmFunctionBody(output.items, "define internal i32 @choose_call_suffix_return");
    const call_suffix_branch = std.mem.indexOf(u8, call_suffix_return_body, "br i1 %mc_") orelse return error.TestUnexpectedResult;
    const call_suffix_call = std.mem.indexOf(u8, call_suffix_return_body, "call void @hit(i32 %mc_arg_1)") orelse return error.TestUnexpectedResult;
    const call_suffix_store = std.mem.indexOf(u8, call_suffix_return_body, "store atomic i32 %mc_arg_1, ptr @g unordered, align 4") orelse return error.TestUnexpectedResult;
    const call_suffix_return = std.mem.indexOf(u8, call_suffix_return_body, "ret i32 %mc_arg_1") orelse return error.TestUnexpectedResult;
    _ = call_suffix_branch;
    _ = call_suffix_call;
    _ = call_suffix_store;
    _ = call_suffix_return;
    try expectNotContains(call_suffix_return_body, "switch");
    try expectNotContains(call_suffix_return_body, "alloca");

    const empty_suffix_return_body = try llvmFunctionBody(output.items, "define internal i32 @choose_empty_suffix_return");
    const empty_suffix_branch = std.mem.indexOf(u8, empty_suffix_return_body, "br i1 %mc_") orelse return error.TestUnexpectedResult;
    const empty_suffix_store = std.mem.indexOf(u8, empty_suffix_return_body, "store atomic i32 %mc_arg_1, ptr @g unordered, align 4") orelse return error.TestUnexpectedResult;
    const empty_suffix_return = std.mem.indexOf(u8, empty_suffix_return_body, "ret i32 %mc_arg_1") orelse return error.TestUnexpectedResult;
    _ = empty_suffix_branch;
    _ = empty_suffix_store;
    _ = empty_suffix_return;
    try expectNotContains(empty_suffix_return_body, "switch");
    try expectNotContains(empty_suffix_return_body, "alloca");

    const empty_return_body = try llvmFunctionBody(output.items, "define internal i32 @choose_empty_return");
    const empty_return_branch = std.mem.indexOf(u8, empty_return_body, "br i1 %") orelse return error.TestUnexpectedResult;
    const empty_return_stmt = std.mem.indexOf(u8, empty_return_body, "ret i32 %") orelse return error.TestUnexpectedResult;
    _ = empty_return_branch;
    _ = empty_return_stmt;
    try expectNotContains(empty_return_body, "switch");
    try expectNotContains(empty_return_body, "alloca");

    const loop_empty_body = try llvmFunctionBody(output.items, "define internal i32 @loop_empty_return");
    const loop_empty_branch = std.mem.indexOf(u8, loop_empty_body, "br i1 %") orelse return error.TestUnexpectedResult;
    const loop_empty_return = std.mem.indexOf(u8, loop_empty_body, "ret i32 %") orelse return error.TestUnexpectedResult;
    _ = loop_empty_branch;
    _ = loop_empty_return;
    try expectNotContains(loop_empty_body, "switch");
    try expectNotContains(loop_empty_body, "alloca");

    const loop_call_body = try llvmFunctionBody(output.items, "define internal i32 @loop_call_return");
    const loop_call_branch = std.mem.indexOf(u8, loop_call_body, "br i1 %") orelse return error.TestUnexpectedResult;
    const loop_call_call = std.mem.indexOf(u8, loop_call_body, "call void @hit(i32 %") orelse return error.TestUnexpectedResult;
    const loop_call_return = std.mem.indexOf(u8, loop_call_body, "ret i32 %") orelse return error.TestUnexpectedResult;
    _ = loop_call_branch;
    _ = loop_call_call;
    _ = loop_call_return;
    try expectNotContains(loop_call_body, "switch");
    try expectNotContains(loop_call_body, "alloca");

    const loop_cmp_return_body = try llvmFunctionBody(output.items, "define internal i32 @loop_cmp_return");
    const loop_cmp_return_compare = std.mem.indexOf(u8, loop_cmp_return_body, "icmp slt i32 ") orelse return error.TestUnexpectedResult;
    const loop_cmp_return_branch = std.mem.indexOf(u8, loop_cmp_return_body, "br i1 %") orelse return error.TestUnexpectedResult;
    const loop_cmp_return_call = std.mem.indexOf(u8, loop_cmp_return_body, "call void @hit(i32 %") orelse return error.TestUnexpectedResult;
    const loop_cmp_return_stmt = std.mem.indexOf(u8, loop_cmp_return_body, "ret i32 %") orelse return error.TestUnexpectedResult;
    _ = loop_cmp_return_compare;
    _ = loop_cmp_return_branch;
    _ = loop_cmp_return_call;
    _ = loop_cmp_return_stmt;
    try expectNotContains(loop_cmp_return_body, "switch");
    try expectNotContains(loop_cmp_return_body, "alloca");

    const branch_effect_body = try llvmFunctionBody(output.items, "define internal i32 @choose_branch_effect_return");
    const branch_effect_branch = std.mem.indexOf(u8, branch_effect_body, "br i1 %mc_") orelse return error.TestUnexpectedResult;
    const branch_effect_call = std.mem.indexOf(u8, branch_effect_body, "call void @hit(i32 %mc_arg_1)") orelse return error.TestUnexpectedResult;
    const branch_effect_return1 = std.mem.indexOf(u8, branch_effect_body, "ret i32 1") orelse return error.TestUnexpectedResult;
    const branch_effect_store = std.mem.indexOf(u8, branch_effect_body, "store atomic i32 %mc_arg_1, ptr @g unordered, align 4") orelse return error.TestUnexpectedResult;
    const branch_effect_return2 = std.mem.indexOf(u8, branch_effect_body, "ret i32 2") orelse return error.TestUnexpectedResult;
    _ = branch_effect_branch;
    _ = branch_effect_call;
    _ = branch_effect_return1;
    _ = branch_effect_store;
    _ = branch_effect_return2;
    try expectNotContains(branch_effect_body, "switch");
    try expectNotContains(branch_effect_body, "alloca");

    const mixed_branch_effect_body = try llvmFunctionBody(output.items, "define internal i32 @choose_mixed_branch_effect_return");
    const mixed_branch_effect_branch = std.mem.indexOf(u8, mixed_branch_effect_body, "br i1 %mc_") orelse return error.TestUnexpectedResult;
    const mixed_branch_effect_call = std.mem.indexOf(u8, mixed_branch_effect_body, "call void @hit(i32 %mc_arg_1)") orelse return error.TestUnexpectedResult;
    const mixed_branch_effect_return1 = std.mem.indexOf(u8, mixed_branch_effect_body, "ret i32 1") orelse return error.TestUnexpectedResult;
    const mixed_branch_effect_store = std.mem.indexOf(u8, mixed_branch_effect_body, "store atomic i32 %mc_arg_1, ptr @g unordered, align 4") orelse return error.TestUnexpectedResult;
    const mixed_branch_effect_return2 = std.mem.indexOf(u8, mixed_branch_effect_body, "ret i32 2") orelse return error.TestUnexpectedResult;
    _ = mixed_branch_effect_branch;
    _ = mixed_branch_effect_call;
    _ = mixed_branch_effect_return1;
    _ = mixed_branch_effect_store;
    _ = mixed_branch_effect_return2;
    try expectNotContains(mixed_branch_effect_body, "switch");
    try expectNotContains(mixed_branch_effect_body, "alloca");
}

test "LLVM emits simple void conditional direct calls from MIR" {
    const source =
        \\global cg: i32 = 0;
        \\extern fn hit(value: i32) -> void;
        \\struct Flags { ok: bool }
        \\struct SignedPair { a: i32, b: i32 }
        \\fn choose_void(flag: bool) -> void {
        \\    if (flag) {
        \\        hit(1);
        \\    } else {
        \\        hit(0);
        \\    }
        \\}
        \\fn choose_void_cmp(a: i32, b: i32) -> void {
        \\    if (a < b) {
        \\        hit(1);
        \\    } else {
        \\        hit(0);
        \\    }
        \\}
        \\fn choose_void_sequence(flag: bool) -> void {
        \\    hit(9);
        \\    if (flag) {
        \\        hit(1);
        \\        hit(2);
        \\    } else {
        \\        hit(3);
        \\        hit(4);
        \\    }
        \\}
        \\fn choose_void_sequence_suffix(flag: bool) -> void {
        \\    hit(9);
        \\    if (flag) {
        \\        hit(1);
        \\    } else {
        \\        hit(0);
        \\    }
        \\    hit(8);
        \\}
        \\fn choose_void_two_suffix(flag: bool, x: i32) -> void {
        \\    if (flag) {
        \\        hit(1);
        \\    } else {
        \\        hit(0);
        \\    }
        \\    hit(x);
        \\    hit(x);
        \\}
        \\fn choose_void_suffix_store(flag: bool, x: i32) -> void {
        \\    if (flag) {
        \\        hit(1);
        \\    } else {
        \\        hit(0);
        \\    }
        \\    cg = x;
        \\    hit(x);
        \\}
        \\fn choose_void_no_else(flag: bool) -> void {
        \\    if (flag) {
        \\        hit(5);
        \\        hit(6);
        \\    }
        \\}
        \\fn choose_void_local_args(flag: bool) -> void {
        \\    if (flag) {
        \\        let x: i32 = 1;
        \\        hit(x);
        \\    } else {
        \\        var y: i32 = 0;
        \\        y = 2;
        \\        hit(y);
        \\    }
        \\}
        \\fn choose_void_checked_args(flag: bool, a: i32, b: i32) -> void {
        \\    if (flag) {
        \\        hit(a + b);
        \\    } else {
        \\        hit(a - b);
        \\    }
        \\}
        \\fn choose_void_field_cond(f: Flags, p: SignedPair) -> void {
        \\    if f.ok {
        \\        hit(p.a);
        \\    } else {
        \\        hit(p.b);
        \\    }
        \\}
        \\fn choose_void_field_cond_not(f: Flags, p: SignedPair) -> void {
        \\    if !f.ok {
        \\        hit(p.a);
        \\    } else {
        \\        hit(p.b);
        \\    }
        \\}
        \\extern fn pred(value: i32) -> bool;
        \\fn choose_void_call_cond(a: i32) -> void {
        \\    if pred(a) {
        \\        hit(1);
        \\    } else {
        \\        hit(0);
        \\    }
        \\}
        \\fn choose_void_local_call_cond(a: i32) -> void {
        \\    let ok: bool = pred(a);
        \\    if ok {
        \\        hit(1);
        \\    } else {
        \\        hit(0);
        \\    }
        \\}
        \\extern fn hit_bool(value: bool) -> void;
        \\fn call_compare_arg(a: i32, b: i32) -> void {
        \\    hit_bool(a < b);
        \\}
        \\fn call_not_arg(flag: bool) -> void {
        \\    hit_bool(!flag);
        \\}
        \\fn loop_void(flag: bool) -> void {
        \\    while flag {
        \\        hit(7);
        \\    }
        \\}
        \\fn loop_void_not(flag: bool) -> void {
        \\    while !flag {
        \\        hit(8);
        \\    }
        \\}
        \\fn loop_void_cmp(a: i32, b: i32) -> void {
        \\    while a < b {
        \\        hit(a);
        \\    }
        \\}
        \\fn loop_void_field(f: Flags, p: SignedPair) -> void {
        \\    while f.ok {
        \\        hit(p.a);
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_void_conditional_calls.mc", source, &output);

    const param_body = try llvmFunctionBody(output.items, "define internal void @choose_void");
    try expectCanonicalConditional(param_body);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, param_body, "call void @hit(i32 "));
    try expectNotContains(param_body, "switch");

    const compare_body = try llvmFunctionBody(output.items, "define internal void @choose_void_cmp");
    try expectContains(compare_body, "icmp slt i32 %mc_arg_0, %mc_arg_1");
    try expectCanonicalConditional(compare_body);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, compare_body, "call void @hit(i32 "));
    try expectNotContains(compare_body, "switch");

    const sequence_body = try llvmFunctionBody(output.items, "define internal void @choose_void_sequence");
    try expectCanonicalConditional(sequence_body);
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, sequence_body, "call void @hit(i32 "));
    try expectNotContains(sequence_body, "switch");

    const suffix_body = try llvmFunctionBody(output.items, "define internal void @choose_void_sequence_suffix");
    try expectCanonicalConditional(suffix_body);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, suffix_body, "call void @hit(i32 "));
    try expectNotContains(suffix_body, "switch");
    try expectNotContains(suffix_body, "alloca");

    const two_suffix_body = try llvmFunctionBody(output.items, "define internal void @choose_void_two_suffix");
    try expectCanonicalConditional(two_suffix_body);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, two_suffix_body, "call void @hit(i32 "));
    try expectNotContains(two_suffix_body, "switch");
    try expectNotContains(two_suffix_body, "alloca");

    const suffix_store_body = try llvmFunctionBody(output.items, "define internal void @choose_void_suffix_store");
    try expectCanonicalConditional(suffix_store_body);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, suffix_store_body, "call void @hit(i32 "));
    try expectContains(suffix_store_body, "store atomic i32 %mc_arg_1, ptr @cg unordered, align 4");
    try expectNotContains(suffix_store_body, "switch");
    try expectNotContains(suffix_store_body, "alloca");

    const no_else_body = try llvmFunctionBody(output.items, "define internal void @choose_void_no_else");
    try expectCanonicalConditional(no_else_body);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, no_else_body, "call void @hit(i32 "));
    try expectNotContains(no_else_body, "switch");
    try expectNotContains(no_else_body, "alloca");

    const local_args_body = try llvmFunctionBody(output.items, "define internal void @choose_void_local_args");
    if (std.mem.indexOf(u8, local_args_body, "; canonical executable MIR") != null) {
        try expectContains(local_args_body, "br i1 %mc_arg_0, label %mc_block_");
        try std.testing.expect(std.mem.count(u8, local_args_body, "call void @hit(i32 %mc_expr_tmp_") == 2);
    } else {
        try expectContains(local_args_body, "br i1 %flag, label %bb_if_then");
        try expectContains(local_args_body, "call void @hit(i32 1)");
        try expectContains(local_args_body, "call void @hit(i32 2)");
    }
    if (std.mem.indexOf(u8, local_args_body, "; canonical executable MIR") == null) {
        try expectNotContains(local_args_body, "alloca");
        try expectNotContains(local_args_body, "store");
    }
    try expectNotContains(local_args_body, "switch");

    const checked_args_body = try llvmFunctionBody(output.items, "define internal void @choose_void_checked_args");
    try expectContains(checked_args_body, "br i1 %mc_arg_0, label %mc_block_");
    try expectContains(checked_args_body, "@llvm.sadd.with.overflow.i32");
    try expectContains(checked_args_body, "@llvm.ssub.with.overflow.i32");
    try expectContains(checked_args_body, "call void @hit(i32 %mc_expr_tmp_");
    try expectNotContains(checked_args_body, "alloca");
    try expectNotContains(checked_args_body, "store");
    try expectNotContains(checked_args_body, "switch");

    const field_cond_body = try llvmFunctionBody(output.items, "define internal void @choose_void_field_cond");
    const field_cond = std.mem.indexOf(u8, field_cond_body, "extractvalue { i1 } %mc_arg_0, 0") orelse return error.TestUnexpectedResult;
    const field_branch = std.mem.indexOf(u8, field_cond_body, "br i1 %mc_expr_tmp_") orelse return error.TestUnexpectedResult;
    const field_then = std.mem.indexOf(u8, field_cond_body, "extractvalue { i32, i32 } %mc_arg_1, 0") orelse return error.TestUnexpectedResult;
    const field_else = std.mem.indexOf(u8, field_cond_body, "extractvalue { i32, i32 } %mc_arg_1, 1") orelse return error.TestUnexpectedResult;
    try std.testing.expect(field_cond < field_branch);
    try std.testing.expect(field_branch < field_then);
    try std.testing.expect(field_branch < field_else);
    try expectContains(field_cond_body, "call void @hit(i32 %mc_expr_tmp_");
    try expectNotContains(field_cond_body, "alloca");
    try expectNotContains(field_cond_body, "store");
    try expectNotContains(field_cond_body, "switch");

    const field_cond_not_body = try llvmFunctionBody(output.items, "define internal void @choose_void_field_cond_not");
    try expectContains(field_cond_not_body, "extractvalue { i1 } %mc_arg_0, 0");
    try expectContains(field_cond_not_body, "br i1 %mc_expr_tmp_");
    try expectContains(field_cond_not_body, "extractvalue { i32, i32 } %mc_arg_1, 0");
    try expectContains(field_cond_not_body, "extractvalue { i32, i32 } %mc_arg_1, 1");
    try expectContains(field_cond_not_body, "xor i1");
    try expectNotContains(field_cond_not_body, "alloca");
    try expectNotContains(field_cond_not_body, "store");
    try expectNotContains(field_cond_not_body, "switch");

    const call_cond_body = try llvmFunctionBody(output.items, "define internal void @choose_void_call_cond");
    try expectContains(call_cond_body, "call i1 @pred(i32 %mc_arg_0)");
    try expectCanonicalConditional(call_cond_body);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, call_cond_body, "call void @hit(i32 "));
    try expectNotContains(call_cond_body, "alloca");
    try expectNotContains(call_cond_body, "store");
    try expectNotContains(call_cond_body, "switch");

    const local_call_cond_body = try llvmFunctionBody(output.items, "define internal void @choose_void_local_call_cond");
    try expectContains(local_call_cond_body, "call i1 @pred(i32 %mc_arg_0)");
    try expectCanonicalConditional(local_call_cond_body);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, local_call_cond_body, "call void @hit(i32 "));
    try expectNotContains(local_call_cond_body, "switch");

    const compare_arg_body = try llvmFunctionBody(output.items, "define internal void @call_compare_arg");
    try expectContains(compare_arg_body, "icmp slt i32 %mc_arg_0, %mc_arg_1");
    try expectContains(compare_arg_body, "call void @hit_bool(i1 %mc_expr_tmp_");
    try expectNotContains(compare_arg_body, "alloca");
    try expectNotContains(compare_arg_body, "store");
    try expectNotContains(compare_arg_body, "switch");

    const not_arg_body = try llvmFunctionBody(output.items, "define internal void @call_not_arg");
    try expectContains(not_arg_body, "xor i1 %mc_arg_0, true");
    try expectContains(not_arg_body, "call void @hit_bool(i1 %mc_expr_tmp_");
    try expectNotContains(not_arg_body, "alloca");
    try expectNotContains(not_arg_body, "store");
    try expectNotContains(not_arg_body, "switch");

    const loop_void_body = try llvmFunctionBody(output.items, "define internal void @loop_void");
    const loop_void_branch = std.mem.indexOf(u8, loop_void_body, "br i1 %mc_arg_0") orelse return error.TestUnexpectedResult;
    const loop_void_call = std.mem.indexOf(u8, loop_void_body, "call void @hit(i32 ") orelse return error.TestUnexpectedResult;
    const loop_void_ret = std.mem.indexOf(u8, loop_void_body, "ret void") orelse return error.TestUnexpectedResult;
    try std.testing.expect(loop_void_branch < loop_void_call);
    try std.testing.expect(loop_void_call < loop_void_ret);
    try expectNotContains(loop_void_body, "switch");
    try expectNotContains(loop_void_body, "alloca");

    const loop_void_not_body = try llvmFunctionBody(output.items, "define internal void @loop_void_not");
    const loop_void_not_branch = std.mem.indexOf(u8, loop_void_not_body, "br i1 %mc_expr_tmp_") orelse return error.TestUnexpectedResult;
    const loop_void_not_call = std.mem.indexOf(u8, loop_void_not_body, "call void @hit(i32 ") orelse return error.TestUnexpectedResult;
    const loop_void_not_ret = std.mem.indexOf(u8, loop_void_not_body, "ret void") orelse return error.TestUnexpectedResult;
    try std.testing.expect(loop_void_not_branch < loop_void_not_call);
    try std.testing.expect(loop_void_not_call < loop_void_not_ret);
    try expectNotContains(loop_void_not_body, "switch");
    try expectNotContains(loop_void_not_body, "alloca");

    const loop_void_cmp_body = try llvmFunctionBody(output.items, "define internal void @loop_void_cmp");
    const loop_void_cmp_compare = std.mem.indexOf(u8, loop_void_cmp_body, "icmp slt i32 %mc_arg_0, %mc_arg_1") orelse return error.TestUnexpectedResult;
    const loop_void_cmp_branch = std.mem.indexOf(u8, loop_void_cmp_body, "br i1 %mc_expr_tmp_") orelse return error.TestUnexpectedResult;
    const loop_void_cmp_call = std.mem.indexOf(u8, loop_void_cmp_body, "call void @hit(i32 %mc_arg_0)") orelse return error.TestUnexpectedResult;
    try std.testing.expect(loop_void_cmp_compare < loop_void_cmp_branch);
    try std.testing.expect(loop_void_cmp_branch < loop_void_cmp_call);
    try expectNotContains(loop_void_cmp_body, "switch");
    try expectNotContains(loop_void_cmp_body, "alloca");

    const loop_void_field_body = try llvmFunctionBody(output.items, "define internal void @loop_void_field");
    const loop_void_field_cond = std.mem.indexOf(u8, loop_void_field_body, "extractvalue { i1 } %mc_arg_0, 0") orelse return error.TestUnexpectedResult;
    const loop_void_field_branch = std.mem.indexOf(u8, loop_void_field_body, "br i1 %mc_expr_tmp_") orelse return error.TestUnexpectedResult;
    const loop_void_field_arg = std.mem.indexOf(u8, loop_void_field_body, "extractvalue { i32, i32 } %mc_arg_1, 0") orelse return error.TestUnexpectedResult;
    try std.testing.expect(loop_void_field_cond < loop_void_field_branch);
    try std.testing.expect(loop_void_field_branch < loop_void_field_arg);
    try expectContains(loop_void_field_body, "call void @hit(i32 %mc_expr_tmp_");
    try expectNotContains(loop_void_field_body, "switch");
    try expectNotContains(loop_void_field_body, "alloca");
    try expectNotContains(loop_void_field_body, "store");
}

test "LLVM emits simple sequential void direct calls from MIR" {
    const source =
        \\extern fn hit(value: i32) -> void;
        \\fn id(value: i32) -> i32 {
        \\    return value;
        \\}
        \\fn sequence() -> void {
        \\    hit(1);
        \\    hit(2);
        \\    hit(3);
        \\}
        \\fn local_then_call() -> void {
        \\    let x: u32 = 1;
        \\    hit(2);
        \\}
        \\fn assign_then_call() -> void {
        \\    var x: u32 = 0;
        \\    x = 1;
        \\    hit(2);
        \\}
        \\fn call_local_arg() -> void {
        \\    let x: i32 = 1;
        \\    hit(x);
        \\}
        \\fn call_assigned_arg() -> void {
        \\    var x: i32 = 0;
        \\    x = 1;
        \\    hit(x);
        \\}
        \\fn call_local_checked_arg(a: i32, b: i32) -> void {
        \\    let x: i32 = a + b;
        \\    hit(x);
        \\}
        \\fn call_assigned_checked_arg(a: i32, b: i32) -> void {
        \\    var x: i32 = 0;
        \\    x = a + b;
        \\    hit(x);
        \\}
        \\fn call_local_call_arg(a: i32) -> void {
        \\    let x: i32 = id(a);
        \\    hit(x);
        \\}
        \\fn call_assigned_call_arg(a: i32) -> void {
        \\    var x: i32 = 0;
        \\    x = id(a);
        \\    hit(x);
        \\}
        \\fn call_checked_add_arg(a: i32, b: i32) -> void {
        \\    hit(a + b);
        \\}
        \\fn call_checked_neg_arg(a: i32) -> void {
        \\    hit(-a);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_void_call_sequence.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal void @sequence");
    try expectContains(body, "call void @hit(i32 1)");
    try expectContains(body, "call void @hit(i32 2)");
    try expectContains(body, "call void @hit(i32 3)");
    try expectNotContains(body, "switch");

    const local_body = try llvmFunctionBody(output.items, "define internal void @local_then_call");
    try expectContains(local_body, "; canonical executable MIR");
    try expectContains(local_body, "call void @hit(i32 2)");
    try expectContains(local_body, "alloca i32");
    try expectContains(local_body, "store i32 1");

    const assign_body = try llvmFunctionBody(output.items, "define internal void @assign_then_call");
    try expectContains(assign_body, "; canonical executable MIR");
    try expectContains(assign_body, "call void @hit(i32 2)");
    try expectContains(assign_body, "alloca i32");
    try expectContains(assign_body, "store i32 1");

    const local_arg_body = try llvmFunctionBody(output.items, "define internal void @call_local_arg");
    try expectContains(local_arg_body, "call void @hit(i32 %mc_expr_tmp_");
    try expectContains(local_arg_body, "alloca i32");
    try expectContains(local_arg_body, "store i32 1");

    const assigned_arg_body = try llvmFunctionBody(output.items, "define internal void @call_assigned_arg");
    try expectContains(assigned_arg_body, "call void @hit(i32 ");
    if (std.mem.indexOf(u8, assigned_arg_body, "; canonical executable MIR") == null) {
        try expectNotContains(assigned_arg_body, "alloca");
        try expectNotContains(assigned_arg_body, "store");
    }

    const local_checked_arg_body = try llvmFunctionBody(output.items, "define internal void @call_local_checked_arg");
    try expectContains(local_checked_arg_body, "@llvm.sadd.with.overflow.i32");
    try expectContains(local_checked_arg_body, "call void @hit(i32 %mc_expr_tmp_");
    try expectContains(local_checked_arg_body, "alloca i32");
    try expectContains(local_checked_arg_body, "store i32 %mc_expr_tmp_");

    const assigned_checked_arg_body = try llvmFunctionBody(output.items, "define internal void @call_assigned_checked_arg");
    try expectContains(assigned_checked_arg_body, "@llvm.sadd.with.overflow.i32");
    try expectContains(assigned_checked_arg_body, "call void @hit(i32 %mc_expr_tmp_");
    try expectContains(assigned_checked_arg_body, "alloca i32");
    try expectContains(assigned_checked_arg_body, "store i32 %mc_expr_tmp_");

    const local_call_arg_body = try llvmFunctionBody(output.items, "define internal void @call_local_call_arg");
    try expectContains(local_call_arg_body, "call i32 @id(i32 %mc_arg_0)");
    try expectContains(local_call_arg_body, "call void @hit(i32 %mc_expr_tmp_");
    try expectContains(local_call_arg_body, "alloca i32");
    try expectContains(local_call_arg_body, "store i32 %mc_expr_tmp_");

    const assigned_call_arg_body = try llvmFunctionBody(output.items, "define internal void @call_assigned_call_arg");
    try expectContains(assigned_call_arg_body, "call i32 @id(i32 %mc_arg_0)");
    try expectContains(assigned_call_arg_body, "call void @hit(i32 %mc_expr_tmp_");
    try expectContains(assigned_call_arg_body, "alloca i32");
    try expectContains(assigned_call_arg_body, "store i32 %mc_expr_tmp_");

    const checked_add_arg_body = try llvmFunctionBody(output.items, "define internal void @call_checked_add_arg");
    try expectContains(checked_add_arg_body, "@llvm.sadd.with.overflow.i32");
    try expectContains(checked_add_arg_body, "call void @hit(i32 %mc_expr_tmp_");
    try expectNotContains(checked_add_arg_body, "alloca");
    try expectNotContains(checked_add_arg_body, "store");

    const checked_neg_arg_body = try llvmFunctionBody(output.items, "define internal void @call_checked_neg_arg");
    try expectContains(checked_neg_arg_body, "@llvm.ssub.with.overflow.i32");
    try expectContains(checked_neg_arg_body, "call void @hit(i32 %");
    try expectNotContains(checked_neg_arg_body, "alloca");
    try expectNotContains(checked_neg_arg_body, "store");
}

test "LLVM emits pure local-only void functions from MIR" {
    const source =
        \\extern fn hit(value: u32) -> void;
        \\fn local_only() { let x: u32 = 1; }
        \\fn param_local(p: u32) { let x: u32 = p; }
        \\fn var_only() { var x: u32 = 1; x = 2; }
        \\fn if_local(flag: bool) { if (flag) { let x: u32 = 1; } else { let y: u32 = 2; } }
        \\fn if_assign(flag: bool) { var x: u32 = 0; if (flag) { x = 1; } else { x = 2; } }
        \\fn if_no_else(flag: bool) { if (flag) { let x: u32 = 1; } }
        \\fn call_then_if_empty(flag: bool, value: u32) { hit(value); if (flag) { let x: u32 = 1; } }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_void_local_only.mc", source, &output);

    const local_body = try llvmFunctionBody(output.items, "define internal void @local_only");
    try expectContains(local_body, "; canonical executable MIR");
    try expectContains(local_body, "ret void");
    try expectContains(local_body, "alloca i32");
    try expectContains(local_body, "store i32 1");

    const param_body = try llvmFunctionBody(output.items, "define internal void @param_local");
    try expectContains(param_body, "; canonical executable MIR");
    try expectContains(param_body, "ret void");
    try expectContains(param_body, "alloca i32");
    try expectContains(param_body, "store i32 %mc_arg_0");

    const var_body = try llvmFunctionBody(output.items, "define internal void @var_only");
    try expectContains(var_body, "; canonical executable MIR");
    try expectContains(var_body, "ret void");
    try expectContains(var_body, "alloca i32");
    try expectContains(var_body, "store i32 2");

    const if_local_body = try llvmFunctionBody(output.items, "define internal void @if_local");
    try expectContains(if_local_body, "; canonical executable MIR");
    try expectContains(if_local_body, "ret void");
    try expectContains(if_local_body, "br i1");
    try expectContains(if_local_body, "alloca i32");
    try expectContains(if_local_body, "store i32 1");

    const if_assign_body = try llvmFunctionBody(output.items, "define internal void @if_assign");
    try expectContains(if_assign_body, "; canonical executable MIR");
    try expectContains(if_assign_body, "ret void");
    try expectContains(if_assign_body, "br i1");
    try expectContains(if_assign_body, "alloca i32");
    try expectContains(if_assign_body, "store i32 2");

    const if_no_else_body = try llvmFunctionBody(output.items, "define internal void @if_no_else");
    try expectContains(if_no_else_body, "; canonical executable MIR");
    try expectContains(if_no_else_body, "ret void");
    try expectContains(if_no_else_body, "br i1");
    try expectContains(if_no_else_body, "alloca i32");
    try expectContains(if_no_else_body, "store i32 1");

    const call_then_empty_body = try llvmFunctionBody(output.items, "define internal void @call_then_if_empty");
    try expectContains(call_then_empty_body, "; canonical executable MIR");
    try expectContains(call_then_empty_body, "call void @hit(i32 %mc_arg_1)");
    try expectContains(call_then_empty_body, "ret void");
    try expectContains(call_then_empty_body, "br i1");
    try expectContains(call_then_empty_body, "alloca i32");
    try expectContains(call_then_empty_body, "store i32 1");
}

test "LLVM emits simple global stores after specialized plan retirement" {
    const source =
        \\enum Color {
        \\    red,
        \\    blue,
        \\}
        \\enum E {
        \\    bad,
        \\}
        \\struct Pair {
        \\    a: u32,
        \\    b: u32,
        \\}
        \\global g: u32 = 0;
        \\global h: u32 = 0;
        \\global flag: bool = false;
        \\global s: i32 = 0;
        \\global wide: u64 = 0;
        \\global byte: u8 = 0;
        \\global small_float: f32 = 0.0;
        \\global wide_float: f64 = 0.0;
        \\global current: Color = .red;
        \\global maybe: ?u32 = null;
        \\global pair: Pair = .{ .a = 0, .b = 0 };
        \\global result: Result<u32, E>;
        \\fn id(x: u32) -> u32 {
        \\    return x;
        \\}
        \\extern fn hit(x: u32) -> void;
        \\fn store_param(x: u32) {
        \\    g = x;
        \\}
        \\fn store_literal() {
        \\    g = 7;
        \\}
        \\fn store_char() {
        \\    byte = 'A';
        \\}
        \\fn store_float() {
        \\    small_float = 1.5;
        \\}
        \\fn store_double() {
        \\    wide_float = 2.5;
        \\}
        \\fn store_local_float() {
        \\    let x: f32 = 1.5;
        \\    small_float = x;
        \\}
        \\fn store_assigned_float() {
        \\    var x: f32 = 0.0;
        \\    x = 1.5;
        \\    small_float = x;
        \\}
        \\fn store_bool_literal() {
        \\    flag = true;
        \\}
        \\fn store_field(p: Pair) {
        \\    g = p.a;
        \\}
        \\fn store_global() {
        \\    h = g;
        \\}
        \\fn store_compare(a: i32, b: i32) {
        \\    flag = a < b;
        \\}
        \\fn store_not(input: bool) {
        \\    flag = !input;
        \\}
        \\fn store_local(x: u32) {
        \\    let y: u32 = x;
        \\    g = y;
        \\}
        \\fn store_var(x: u32) {
        \\    var y: u32 = 0;
        \\    y = x;
        \\    g = y;
        \\}
        \\fn store_call(x: u32) {
        \\    g = id(x);
        \\}
        \\fn store_many(x: u32, input: bool) {
        \\    g = x;
        \\    h = g;
        \\    flag = !input;
        \\}
        \\fn store_add(a: i32, b: i32) {
        \\    s = a + b;
        \\}
        \\fn store_wrap(a: u32) {
        \\    g = wrapping.add(a, 1);
        \\}
        \\fn store_unchecked(a: u32) {
        \\    #[unsafe_contract(no_overflow)] {
        \\        g = unchecked.add(a, 1);
        \\    }
        \\}
        \\fn store_cast(value: u32) {
        \\    wide = value as u64;
        \\}
        \\fn store_conversion(value: u64) {
        \\    byte = u8.wrap_from(value);
        \\}
        \\fn store_enum() {
        \\    current = .blue;
        \\}
        \\fn store_none() {
        \\    maybe = null;
        \\}
        \\fn store_pair(x: u32) {
        \\    pair = .{ .a = x, .b = 7 };
        \\}
        \\fn store_result_ok(x: u32) {
        \\    result = ok(x);
        \\}
        \\fn store_result_err() {
        \\    result = err(.bad);
        \\}
        \\fn store_neg(a: i32) {
        \\    s = -a;
        \\}
        \\fn call_then_store(x: u32) {
        \\    hit(x);
        \\    g = x;
        \\}
        \\fn store_then_call(x: u32) {
        \\    g = x;
        \\    hit(x);
        \\}
        \\fn if_store(flag: bool, x: u32, y: u32) {
        \\    if (flag) {
        \\        g = x;
        \\    } else {
        \\        g = y;
        \\    }
        \\}
        \\fn if_store_float(flag: bool) {
        \\    if (flag) {
        \\        small_float = 1.5;
        \\    } else {
        \\        small_float = 2.5;
        \\    }
        \\}
        \\fn if_store_no_else(flag: bool, x: u32) {
        \\    if (flag) {
        \\        g = x;
        \\    }
        \\}
        \\fn if_store_else_only(flag: bool, x: u32) {
        \\    if (flag) {
        \\    } else {
        \\        g = x;
        \\    }
        \\}
        \\fn call_then_if_store(flag: bool, x: u32, y: u32) {
        \\    hit(x);
        \\    if (flag) {
        \\        g = x;
        \\    } else {
        \\        g = y;
        \\    }
        \\}
        \\fn call_if_store_call(flag: bool, x: u32) {
        \\    hit(x);
        \\    if (flag) {
        \\        g = x;
        \\    }
        \\    hit(x);
        \\}
        \\fn if_store_two_suffix(flag: bool, x: u32) {
        \\    if (flag) {
        \\        g = x;
        \\    }
        \\    hit(x);
        \\    hit(x);
        \\}
        \\fn if_store_suffix_store_call(flag: bool, x: u32) {
        \\    if (flag) {
        \\        g = x;
        \\    }
        \\    h = x;
        \\    hit(x);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_mir_global_store.mc", source, &output);

    const param_body = try llvmFunctionBody(output.items, "define internal void @store_param");
    try expectContains(param_body, "store atomic i32 %mc_arg_0, ptr @g unordered, align 4");
    try expectNotContains(param_body, "alloca");

    const literal_body = try llvmFunctionBody(output.items, "define internal void @store_literal");
    try expectContains(literal_body, "store atomic i32 7, ptr @g unordered, align 4");
    try expectNotContains(literal_body, "alloca");

    const char_body = try llvmFunctionBody(output.items, "define internal void @store_char");
    try expectContains(char_body, "store atomic i8 65, ptr @byte unordered, align 1");
    try expectNotContains(char_body, "alloca");

    const float_body = try llvmFunctionBody(output.items, "define internal void @store_float");
    try expectContains(float_body, "store atomic float bitcast (i32 1069547520 to float), ptr @small_float unordered, align 4");
    try expectNotContains(float_body, "alloca");

    const double_body = try llvmFunctionBody(output.items, "define internal void @store_double");
    try expectContains(double_body, "store atomic double bitcast (i64 4612811918334230528 to double), ptr @wide_float unordered, align 8");
    try expectNotContains(double_body, "alloca");

    const local_float_body = try llvmFunctionBody(output.items, "define internal void @store_local_float");
    try expectContains(local_float_body, "store atomic float %mc_expr_tmp_0, ptr @small_float unordered, align 4");
    try expectContains(local_float_body, "%mc_local_0 = alloca float");

    const assigned_float_body = try llvmFunctionBody(output.items, "define internal void @store_assigned_float");
    try expectContains(assigned_float_body, "store atomic float %mc_expr_tmp_0, ptr @small_float unordered, align 4");
    try expectContains(assigned_float_body, "%mc_local_0 = alloca float");

    const bool_literal_body = try llvmFunctionBody(output.items, "define internal void @store_bool_literal");
    try expectContains(bool_literal_body, "zext i1 true to i8");
    try expectContains(bool_literal_body, "store atomic i8 %mc_expr_tmp_0");
    try expectContains(bool_literal_body, "ptr @flag unordered, align 1");
    try expectNotContains(bool_literal_body, "alloca");

    const field_body = try llvmFunctionBody(output.items, "define internal void @store_field");
    try expectContains(field_body, "extractvalue { i32, i32 } %mc_arg_0, 0");
    try expectContains(field_body, "store atomic i32 %mc_expr_tmp_0");
    try expectContains(field_body, "ptr @g unordered, align 4");
    try expectNotContains(field_body, "alloca");

    const global_body = try llvmFunctionBody(output.items, "define internal void @store_global");
    try expectContains(global_body, "load atomic i32, ptr @g unordered, align 4");
    try expectContains(global_body, "store atomic i32 %mc_expr_tmp_0");
    try expectContains(global_body, "ptr @h unordered, align 4");
    try expectNotContains(global_body, "alloca");

    const compare_body = try llvmFunctionBody(output.items, "define internal void @store_compare");
    try expectContains(compare_body, "icmp slt i32 %mc_arg_0, %mc_arg_1");
    try expectContains(compare_body, "store atomic i8");
    try expectContains(compare_body, "ptr @flag unordered, align 1");
    try expectNotContains(compare_body, "alloca");

    const not_body = try llvmFunctionBody(output.items, "define internal void @store_not");
    try expectContains(not_body, "xor i1 %mc_arg_0, true");
    try expectContains(not_body, "store atomic i8");
    try expectContains(not_body, "ptr @flag unordered, align 1");
    try expectNotContains(not_body, "alloca");

    const local_body = try llvmFunctionBody(output.items, "define internal void @store_local(");
    try expectContains(local_body, "store atomic i32 %mc_expr_tmp_0, ptr @g unordered, align 4");
    try expectContains(local_body, "%mc_local_1 = alloca i32");
    try expectContains(local_body, "load i32, ptr %mc_local_1");

    const var_body = try llvmFunctionBody(output.items, "define internal void @store_var");
    try expectContains(var_body, "store atomic i32 %mc_expr_tmp_0, ptr @g unordered, align 4");
    try expectContains(var_body, "%mc_local_1 = alloca i32");
    try expectContains(var_body, "load i32, ptr %mc_local_1");

    const call_body = try llvmFunctionBody(output.items, "define internal void @store_call");
    try expectContains(call_body, "call i32 @id(i32 %mc_arg_0)");
    try expectContains(call_body, "store atomic i32 %mc_expr_tmp_0");
    try expectContains(call_body, "ptr @g unordered, align 4");
    try expectNotContains(call_body, "alloca");

    const many_body = try llvmFunctionBody(output.items, "define internal void @store_many");
    try expectContains(many_body, "store atomic i32 %mc_arg_0, ptr @g unordered, align 4");
    try expectContains(many_body, "load atomic i32, ptr @g unordered, align 4");
    try expectContains(many_body, "ptr @h unordered, align 4");
    try expectContains(many_body, "xor i1 %mc_arg_1, true");
    try expectContains(many_body, "ptr @flag unordered, align 1");
    try expectNotContains(many_body, "alloca");

    const add_body = try llvmFunctionBody(output.items, "define internal void @store_add");
    try expectContains(add_body, "@llvm.sadd.with.overflow.i32");
    try expectContains(add_body, "store atomic i32 %mc_expr_tmp_1");
    try expectContains(add_body, "ptr @s unordered, align 4");
    try expectNotContains(add_body, "alloca");

    const wrap_body = try llvmFunctionBody(output.items, "define internal void @store_wrap");
    try expectContains(wrap_body, " = add i32 %mc_arg_0, 1");
    try expectContains(wrap_body, "store atomic i32 %mc_expr_tmp_");
    try expectContains(wrap_body, "ptr @g unordered, align 4");
    try expectNotContains(wrap_body, "alloca");

    const unchecked_body = try llvmFunctionBody(output.items, "define internal void @store_unchecked");
    try expectContains(unchecked_body, "mir range_fact consumed region=1 op=add assumption=no_overflow");
    try expectContains(unchecked_body, " = add i32 %mc_arg_0, 1");
    try expectContains(unchecked_body, "store atomic i32 %mc_expr_tmp_");
    try expectContains(unchecked_body, "ptr @g unordered, align 4");
    try expectNotContains(unchecked_body, "alloca");

    const cast_body = try llvmFunctionBody(output.items, "define internal void @store_cast");
    try expectContains(cast_body, "zext i32 %mc_arg_0 to i64");
    try expectContains(cast_body, "store atomic i64 %mc_expr_tmp_0");
    try expectContains(cast_body, "ptr @wide unordered, align 8");
    try expectNotContains(cast_body, "alloca");

    const conversion_body = try llvmFunctionBody(output.items, "define internal void @store_conversion");
    try expectContains(conversion_body, "; canonical executable MIR");
    try expectContains(conversion_body, "trunc i64 %mc_arg_0 to i8");
    try expectContains(conversion_body, "store atomic i8 %mc_expr_tmp_");
    try expectContains(conversion_body, "ptr @byte unordered, align 1");
    try expectNotContains(conversion_body, "alloca");

    const enum_body = try llvmFunctionBody(output.items, "define internal void @store_enum");
    try expectContains(enum_body, "store atomic i64 1, ptr @current unordered, align 8");
    try expectNotContains(enum_body, "alloca");

    const none_body = try llvmFunctionBody(output.items, "define internal void @store_none");
    try expectContains(none_body, "; canonical executable MIR");
    try expectContains(none_body, "store atomic i8");
    try expectContains(none_body, "store atomic i32");
    try expectContains(none_body, "ptr @maybe");
    try expectNotContains(none_body, "alloca");

    const pair_body = try llvmFunctionBody(output.items, "define internal void @store_pair");
    try expectContains(pair_body, "; canonical executable MIR");
    try std.testing.expect(std.mem.count(u8, pair_body, "store atomic i32") == 2);
    try expectContains(pair_body, "ptr @pair");

    const result_ok_body = try llvmFunctionBody(output.items, "define internal void @store_result_ok");
    try expectContains(result_ok_body, "insertvalue { i1, i32, i64 } zeroinitializer, i1 true, 0");
    try expectContains(result_ok_body, "i32 %mc_arg_0, 1");
    try expectContains(result_ok_body, "ptr @result");

    const result_err_body = try llvmFunctionBody(output.items, "define internal void @store_result_err");
    try expectContains(result_err_body, "insertvalue { i1, i32, i64 } zeroinitializer, i1 false, 0");
    try expectContains(result_err_body, "i64 0, 2");
    try expectContains(result_err_body, "ptr @result");

    const neg_body = try llvmFunctionBody(output.items, "define internal void @store_neg");
    try expectContains(neg_body, "@llvm.ssub.with.overflow.i32");
    try expectContains(neg_body, "store atomic i32 %");
    try expectContains(neg_body, "ptr @s unordered, align 4");
    try expectNotContains(neg_body, "alloca");

    const call_then_store_body = try llvmFunctionBody(output.items, "define internal void @call_then_store");
    try expectContains(call_then_store_body, "call void @hit(i32 %mc_arg_0)");
    try expectContains(call_then_store_body, "store atomic i32 %mc_arg_0, ptr @g unordered, align 4");
    try expectNotContains(call_then_store_body, "alloca");

    const store_then_call_body = try llvmFunctionBody(output.items, "define internal void @store_then_call");
    try expectContains(store_then_call_body, "store atomic i32 %mc_arg_0, ptr @g unordered, align 4");
    try expectContains(store_then_call_body, "call void @hit(i32 %mc_arg_0)");
    try expectNotContains(store_then_call_body, "alloca");

    const if_body = try llvmFunctionBody(output.items, "define internal void @if_store");
    try expectCanonicalConditional(if_body);
    try expectContains(if_body, "store atomic i32 %mc_arg_1, ptr @g unordered, align 4");
    try expectContains(if_body, "store atomic i32 %mc_arg_2, ptr @g unordered, align 4");
    try expectNotContains(if_body, "alloca");

    const if_float_body = try llvmFunctionBody(output.items, "define internal void @if_store_float");
    try expectCanonicalConditional(if_float_body);
    try expectContains(if_float_body, "store atomic float ");
    try expectContains(if_float_body, "ptr @small_float unordered, align 4");
    try expectNotContains(if_float_body, "alloca");

    const no_else_body = try llvmFunctionBody(output.items, "define internal void @if_store_no_else");
    try expectCanonicalConditional(no_else_body);
    try expectContains(no_else_body, "store atomic i32 %mc_arg_1, ptr @g unordered, align 4");
    try expectNotContains(no_else_body, "alloca");

    const else_only_body = try llvmFunctionBody(output.items, "define internal void @if_store_else_only");
    try expectCanonicalConditional(else_only_body);
    try expectContains(else_only_body, "store atomic i32 %mc_arg_1, ptr @g unordered, align 4");
    try expectNotContains(else_only_body, "alloca");

    const call_if_body = try llvmFunctionBody(output.items, "define internal void @call_then_if_store");
    try expectCanonicalConditional(call_if_body);
    try expectContains(call_if_body, "call void @hit(i32 %mc_arg_1)");
    try expectContains(call_if_body, "store atomic i32 %mc_arg_1, ptr @g unordered, align 4");
    try expectContains(call_if_body, "store atomic i32 %mc_arg_2, ptr @g unordered, align 4");
    try expectNotContains(call_if_body, "alloca");

    const call_if_call_body = try llvmFunctionBody(output.items, "define internal void @call_if_store_call");
    try expectCanonicalConditional(call_if_call_body);
    try expectContains(call_if_call_body, "call void @hit(i32 %mc_arg_1)");
    try expectContains(call_if_call_body, "store atomic i32 %mc_arg_1, ptr @g unordered, align 4");
    try expectNotContains(call_if_call_body, "switch");
    try expectNotContains(call_if_call_body, "alloca");

    const two_suffix_store_body = try llvmFunctionBody(output.items, "define internal void @if_store_two_suffix");
    try expectCanonicalConditional(two_suffix_store_body);
    try expectContains(two_suffix_store_body, "store atomic i32 %mc_arg_1, ptr @g unordered, align 4");
    try expectContains(two_suffix_store_body, "call void @hit(i32 %mc_arg_1)");
    try expectNotContains(two_suffix_store_body, "switch");
    try expectNotContains(two_suffix_store_body, "alloca");

    const suffix_store_call_body = try llvmFunctionBody(output.items, "define internal void @if_store_suffix_store_call");
    try expectCanonicalConditional(suffix_store_call_body);
    try expectContains(suffix_store_call_body, "store atomic i32 %mc_arg_1, ptr @g unordered, align 4");
    try expectContains(suffix_store_call_body, "store atomic i32 %mc_arg_1, ptr @h unordered, align 4");
    try expectContains(suffix_store_call_body, "call void @hit(i32 %mc_arg_1)");
    try expectNotContains(suffix_store_call_body, "switch");
    try expectNotContains(suffix_store_call_body, "alloca");
}

test "LLVM preserves MIR void calls before simple returns" {
    const source =
        \\extern fn hit(value: i32) -> void;
        \\fn side_then_return(x: i32) -> i32 {
        \\    hit(1);
        \\    hit(2);
        \\    return x;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_void_calls_before_return.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal i32 @side_then_return");
    const hit1 = std.mem.indexOf(u8, body, "call void @hit(i32 1)") orelse return error.TestUnexpectedResult;
    const hit2 = std.mem.indexOf(u8, body, "call void @hit(i32 2)") orelse return error.TestUnexpectedResult;
    const ret = std.mem.indexOf(u8, body, "ret i32 %") orelse return error.TestUnexpectedResult;
    try std.testing.expect(hit1 < hit2);
    try std.testing.expect(hit2 < ret);
}

test "LLVM emits direct struct parameter field returns from MIR" {
    const source =
        \\struct Pair { a: u32, b: u32 }
        \\fn first(p: Pair) -> u32 {
        \\    return p.a;
        \\}
        \\fn local_first(p: Pair) -> u32 {
        \\    let x: u32 = p.a;
        \\    return x;
        \\}
        \\fn assigned_second(p: Pair) -> u32 {
        \\    var x: u32 = 0;
        \\    x = p.b;
        \\    return x;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_param_field_return.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal i32 @first");
    try expectContains(body, "extractvalue { i32, i32 } %mc_arg_0, 0");
    try expectContains(body, "ret i32 %mc_expr_tmp_");
    try expectNotContains(body, "alloca");
    try expectNotContains(body, "store");

    const local_body = try llvmFunctionBody(output.items, "define internal i32 @local_first");
    try expectContains(local_body, "extractvalue { i32, i32 } %mc_arg_0, 0");
    try expectContains(local_body, "ret i32 %mc_expr_tmp_");
    try expectContains(local_body, "alloca i32");
    try expectContains(local_body, "store i32");

    const assigned_body = try llvmFunctionBody(output.items, "define internal i32 @assigned_second");
    try expectContains(assigned_body, "extractvalue { i32, i32 } %mc_arg_0, 1");
    try expectContains(assigned_body, "ret i32 %mc_expr_tmp_");
    try expectContains(assigned_body, "alloca i32");
    try expectContains(assigned_body, "store i32");
}

test "LLVM emits nested parameter and global field places from MIR without body fallback" {
    const source =
        \\struct Pair { left: u32, right: u32 }
        \\struct Box { pair: Pair }
        \\global box: Box = .{ .pair = .{ .left = 1, .right = 2 } };
        \\fn update(value: u32) -> u32 {
        \\    box.pair.left = value;
        \\    return box.pair.left;
        \\}
        \\fn read(value: Box) -> u32 {
        \\    return value.pair.right;
        \\}
        \\fn read_local_global() -> u32 {
        \\    let copy: Box = box;
        \\    return copy.pair.right;
        \\}
        \\fn read_local_parameter(value: Box) -> u32 {
        \\    let copy: Box = value;
        \\    return copy.pair.left;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_nested_place_return.mc", source, &output);

    const update = try llvmFunctionBody(output.items, "define internal i32 @update");
    try expectContains(update, "; canonical executable MIR");
    try expectContains(update, "store atomic i32 %");
    try expectContains(update, "load atomic i32");
    const read = try llvmFunctionBody(output.items, "define internal i32 @read");
    try expectContains(read, "extractvalue { { i32, i32 } } %mc_arg_0, 0");
    try expectContains(read, "extractvalue { i32, i32 } %mc_expr_tmp_");
    try expectContains(read, ", 1");
    try expectNotContains(read, "alloca");
    const read_global = try llvmFunctionBody(output.items, "define internal i32 @read_local_global");
    try expectContains(read_global, "load atomic i32");
    try expectContains(read_global, "insertvalue { { i32, i32 } }");
    try expectContains(read_global, "i32 1");
    const read_parameter = try llvmFunctionBody(output.items, "define internal i32 @read_local_parameter");
    try expectContains(read_parameter, "; canonical executable MIR");
    try expectContains(read_parameter, "getelementptr inbounds { { i32, i32 } }");
    try expectContains(read_parameter, "i32 0");
    try expectContains(read_parameter, "alloca { { i32, i32 } }");
}

test "LLVM emits fixed-array constant-index places from MIR without body fallback" {
    const source =
        \\global values: [2]u32 = .{ 10, 20 };
        \\global matrix: [2][2]u32 = .{ .{ 1, 2 }, .{ 3, 4 } };
        \\fn take_row(row: [2]u32) -> u32 {
        \\    return row[1];
        \\}
        \\fn read_global_array() -> u32 {
        \\    return values[1];
        \\}
        \\fn write_global_array(value: u32) -> u32 {
        \\    values[0] = value;
        \\    return values[0];
        \\}
        \\fn local_array_copy(row: [2]u32) -> u32 {
        \\    let copy: [2]u32 = row;
        \\    return copy[0];
        \\}
        \\fn nested_global() -> u32 {
        \\    matrix[1][0] = 11;
        \\    return matrix[1][0];
        \\}
        \\fn replace_row() -> u32 {
        \\    matrix[1] = .{ 31, 32 };
        \\    return matrix[1][1];
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_array_place_return.mc", source, &output);

    const take = try llvmFunctionBody(output.items, "define internal i32 @take_row");
    try expectContains(take, "; canonical executable MIR");
    try expectContains(take, "icmp uge i64");
    try expectContains(take, "getelementptr [2 x i32]");
    const read = try llvmFunctionBody(output.items, "define internal i32 @read_global_array");
    try expectContains(read, "icmp ult i64 1, 2");
    try expectContains(read, "getelementptr inbounds [2 x i32], ptr @values, i64 0, i64 1");
    try expectContains(read, "load atomic i32");
    const write = try llvmFunctionBody(output.items, "define internal i32 @write_global_array");
    try expectContains(write, "getelementptr inbounds [2 x i32], ptr @values, i64 0, i64 0");
    try expectContains(write, "store atomic i32 %mc_arg_0");
    const local = try llvmFunctionBody(output.items, "define internal i32 @local_array_copy");
    try expectContains(local, "; canonical executable MIR");
    try expectContains(local, "store [2 x i32] %mc_arg_0");
    try expectContains(local, "getelementptr [2 x i32]");
    try expectContains(local, "i64 0, i64 0");
    const nested = try llvmFunctionBody(output.items, "define internal i32 @nested_global");
    try expectContains(nested, "; canonical executable MIR");
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, nested, "icmp ult i64"));
    try expectContains(nested, "getelementptr inbounds [2 x [2 x i32]], ptr @matrix, i64 0, i64 1");
    try expectContains(nested, "getelementptr inbounds [2 x i32], ptr %mc_expr_tmp_");
    try expectContains(nested, "store atomic i32 11");
    try expectContains(nested, "load atomic i32");
    const replace = try llvmFunctionBody(output.items, "define internal i32 @replace_row");
    try expectContains(replace, "; canonical executable MIR");
    try expectContains(replace, "i32 31");
    try expectContains(replace, "i32 32");
    try expectContains(replace, "load atomic i32");
}

test "LLVM checked dynamic fixed-array stores use canonical executable MIR" {
    const source =
        \\global values: [4]u32 = .{ 0, 0, 0, 0 };
        \\fn store_at(index: usize, value: u32) -> void {
        \\    values[index] = value;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_dynamic_array_store.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal void @store_at");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "icmp ult i64");
    try expectContains(body, ", 4");
    try expectContains(body, "getelementptr inbounds [4 x i32], ptr @values");
    try expectContains(body, "store atomic i32");
}

test "LLVM emits conditional struct parameter field returns from MIR" {
    const source =
        \\struct Pair { a: u32, b: u32 }
        \\fn choose(flag: bool, p: Pair) -> u32 {
        \\    if (flag) {
        \\        return p.a;
        \\    } else {
        \\        return p.b;
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_conditional_param_field_return.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal i32 @choose");
    try expectCanonicalConditional(body);
    try expectContains(body, "extractvalue { i32, i32 } %mc_arg_1, 0");
    try expectContains(body, "extractvalue { i32, i32 } %mc_arg_1, 1");
    try expectContains(body, "ret i32 %mc_expr_tmp_");
    try expectNotContains(body, "alloca");
    try expectNotContains(body, "store");
}

test "LLVM emits conditional boolean struct field conditions from MIR" {
    const source =
        \\struct Flags { ok: bool, other: bool }
        \\fn choose(f: Flags) -> bool {
        \\    if (f.ok) {
        \\        return f.other;
        \\    } else {
        \\        return false;
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_conditional_param_bool_field.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal i1 @choose");
    try expectCanonicalConditional(body);
    try expectContains(body, "extractvalue { i1, i1 } %mc_arg_0, 0");
    try expectContains(body, "extractvalue { i1, i1 } %mc_arg_0, 1");
    try expectContains(body, "ret i1 %mc_expr_tmp_");
    try expectNotContains(body, "alloca");
    try expectNotContains(body, "store");
}

test "LLVM emits struct parameter field call arguments from MIR" {
    const source =
        \\struct Pair { a: u32, b: u32 }
        \\extern fn make(x: u32) -> u32;
        \\extern fn hit(x: u32) -> void;
        \\fn call_field(p: Pair) -> u32 {
        \\    return make(p.a);
        \\}
        \\fn void_field(p: Pair) -> void {
        \\    hit(p.b);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_param_field_call_args.mc", source, &output);

    const call_body = try llvmFunctionBody(output.items, "define internal i32 @call_field");
    try expectContains(call_body, "extractvalue { i32, i32 } %mc_arg_0, 0");
    try expectContains(call_body, "call i32 @make(i32 %mc_expr_tmp_");
    try expectContains(call_body, "ret i32 %mc_expr_tmp_");
    try expectNotContains(call_body, "alloca");
    try expectNotContains(call_body, "store");

    const void_body = try llvmFunctionBody(output.items, "define internal void @void_field");
    try expectContains(void_body, "extractvalue { i32, i32 } %mc_arg_0, 1");
    try expectContains(void_body, "call void @hit(i32 %mc_expr_tmp_");
    try expectNotContains(void_body, "alloca");
    try expectNotContains(void_body, "store");
}

test "LLVM emits struct parameter field checked operands from MIR" {
    const source =
        \\struct Pair { a: u32, b: u32 }
        \\fn add_left(p: Pair, x: u32) -> u32 {
        \\    return p.a + x;
        \\}
        \\fn add_right(p: Pair, x: u32) -> u32 {
        \\    return x + p.b;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_param_field_checked_operands.mc", source, &output);

    const left_body = try llvmFunctionBody(output.items, "define internal i32 @add_left");
    try expectContains(left_body, "extractvalue { i32, i32 } %mc_arg_0, 0");
    try expectContains(left_body, "@llvm.uadd.with.overflow.i32(i32 %mc_expr_tmp_");
    try expectContains(left_body, ", i32 %mc_arg_1)");
    try expectNotContains(left_body, "alloca");
    try expectNotContains(left_body, "store");

    const right_body = try llvmFunctionBody(output.items, "define internal i32 @add_right");
    try expectContains(right_body, "extractvalue { i32, i32 } %mc_arg_0, 1");
    try expectContains(right_body, "@llvm.uadd.with.overflow.i32(i32 %mc_arg_1, i32 %mc_expr_tmp_");
    try expectNotContains(right_body, "alloca");
    try expectNotContains(right_body, "store");
}

test "LLVM emits struct parameter field comparisons from MIR" {
    const source =
        \\extern fn take_bool(v: bool) -> void;
        \\struct Pair { a: u32, b: u32 }
        \\fn cmp_left(p: Pair, x: u32) -> bool {
        \\    return p.a == x;
        \\}
        \\fn cmp_right(p: Pair, x: u32) -> bool {
        \\    return x < p.b;
        \\}
        \\fn call_cmp(p: Pair, x: u32) -> void {
        \\    take_bool(p.a == x);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_param_field_compare_operands.mc", source, &output);

    const left_body = try llvmFunctionBody(output.items, "define internal i1 @cmp_left");
    try expectContains(left_body, "extractvalue { i32, i32 } %mc_arg_0, 0");
    try expectContains(left_body, "icmp eq i32 %mc_expr_tmp_");
    try expectContains(left_body, ", %mc_arg_1");

    const right_body = try llvmFunctionBody(output.items, "define internal i1 @cmp_right");
    try expectContains(right_body, "extractvalue { i32, i32 } %mc_arg_0, 1");
    try expectContains(right_body, "icmp ult i32 %mc_arg_1, %mc_expr_tmp_");

    const call_body = try llvmFunctionBody(output.items, "define internal void @call_cmp");
    try expectContains(call_body, "extractvalue { i32, i32 } %mc_arg_0, 0");
    try expectContains(call_body, "icmp eq i32 %mc_expr_tmp_");
    try expectContains(call_body, "call void @take_bool");
    try expectNotContains(call_body, "icmp eq i32 %mc_arg_0, %mc_arg_1");
}

test "LLVM emits simple struct literal returns from MIR" {
    const source =
        \\struct Pair { a: i32, b: i32 }
        \\struct Flags { ok: bool }
        \\extern fn hit(value: i32) -> void;
        \\fn make_pair(a: i32, b: i32) -> Pair {
        \\    return .{ .a = a, .b = b };
        \\}
        \\fn return_field_pair(p: Pair) -> Pair {
        \\    return .{ .a = p.a, .b = p.b };
        \\}
        \\fn bool_pair(f: Flags) -> Flags {
        \\    return .{ .ok = f.ok };
        \\}
        \\fn choose_pair(flag: bool, a: i32, b: i32) -> Pair {
        \\    if (flag) {
        \\        return .{ .a = a, .b = b };
        \\    } else {
        \\        return .{ .a = b, .b = a };
        \\    }
        \\}
        \\fn choose_field_pair(flag: bool, p: Pair) -> Pair {
        \\    if (flag) {
        \\        return .{ .a = p.a, .b = p.b };
        \\    } else {
        \\        return .{ .a = p.b, .b = p.a };
        \\    }
        \\}
        \\fn choose_assign_pair(flag: bool, a: i32, b: i32) -> Pair {
        \\    var out: Pair = .{ .a = a, .b = b };
        \\    if (flag) {
        \\        out = .{ .a = b, .b = a };
        \\    }
        \\    return out;
        \\}
        \\fn choose_assign_field_pair(flag: bool, p: Pair) -> Pair {
        \\    var out: Pair = .{ .a = p.a, .b = p.b };
        \\    if (flag) {
        \\        out = .{ .a = p.b, .b = p.a };
        \\    }
        \\    return out;
        \\}
        \\fn local_pair(a: i32, b: i32) -> Pair {
        \\    var out: Pair = .{ .a = a, .b = b };
        \\    return out;
        \\}
        \\fn local_field_pair(p: Pair) -> Pair {
        \\    var out: Pair = .{ .a = p.a, .b = p.b };
        \\    return out;
        \\}
        \\fn assigned_pair(a: i32, b: i32) -> Pair {
        \\    var out: Pair = .{ .a = a, .b = b };
        \\    out = .{ .a = b, .b = a };
        \\    return out;
        \\}
        \\fn assigned_field_pair(p: Pair) -> Pair {
        \\    var out: Pair = .{ .a = p.a, .b = p.b };
        \\    out = .{ .a = p.b, .b = p.a };
        \\    return out;
        \\}
        \\fn loop_pair(flag: bool, a: i32, b: i32) -> Pair {
        \\    while (flag) {
        \\    }
        \\    return .{ .a = a, .b = b };
        \\}
        \\fn loop_local_pair(flag: bool, a: i32, b: i32) -> Pair {
        \\    while (flag) {
        \\    }
        \\    var out: Pair = .{ .a = a, .b = b };
        \\    return out;
        \\}
        \\fn side_then_pair(a: i32, b: i32) -> Pair {
        \\    hit(a);
        \\    return .{ .a = a, .b = b };
        \\}
        \\fn side_then_local_pair(a: i32, b: i32) -> Pair {
        \\    hit(a);
        \\    var out: Pair = .{ .a = a, .b = b };
        \\    return out;
        \\}
        \\fn early_pair(flag: bool, a: i32, b: i32) -> Pair {
        \\    if (flag) {
        \\        return .{ .a = b, .b = a };
        \\    }
        \\    return .{ .a = a, .b = b };
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_struct_literal_returns.mc", source, &output);

    const make_body = try llvmFunctionBody(output.items, "define internal { i32, i32 } @make_pair");
    try expectContains(make_body, "; canonical executable MIR");
    try expectContains(make_body, "insertvalue { i32, i32 } zeroinitializer, i32 %mc_arg_0, 0");
    try expectContains(make_body, "insertvalue { i32, i32 } %mc_expr_tmp_");
    try expectContains(make_body, "i32 %mc_arg_1, 1");
    try expectContains(make_body, "ret { i32, i32 } %mc_expr_tmp_");
    try expectNotContains(make_body, "alloca");
    try expectNotContains(make_body, "store");

    const field_body = try llvmFunctionBody(output.items, "define internal { i32, i32 } @return_field_pair");
    try expectContains(field_body, "extractvalue { i32, i32 } %mc_arg_0, 0");
    try expectContains(field_body, "extractvalue { i32, i32 } %mc_arg_0, 1");
    try expectContains(field_body, "insertvalue { i32, i32 } zeroinitializer, i32 %mc_expr_tmp_");
    try expectContains(field_body, "ret { i32, i32 } %mc_expr_tmp_");
    try expectNotContains(field_body, "alloca");
    try expectNotContains(field_body, "store");

    const bool_body = try llvmFunctionBody(output.items, "define internal { i1 } @bool_pair");
    try expectContains(bool_body, "extractvalue { i1 } %mc_arg_0, 0");
    try expectContains(bool_body, "insertvalue { i1 } zeroinitializer, i1 %mc_expr_tmp_");
    try expectContains(bool_body, "ret { i1 } %mc_expr_tmp_");
    try expectNotContains(bool_body, "alloca");
    try expectNotContains(bool_body, "store");

    const choose_body = try llvmFunctionBody(output.items, "define internal { i32, i32 } @choose_pair");
    try expectCanonicalConditional(choose_body);
    try expectContains(choose_body, "insertvalue { i32, i32 } zeroinitializer, i32 %mc_arg_");
    try expectContains(choose_body, "insertvalue { i32, i32 } %mc_expr_tmp_");
    try expectContains(choose_body, "ret { i32, i32 } %mc_expr_tmp_");
    try expectNotContains(choose_body, "alloca");
    try expectNotContains(choose_body, "store");
    try expectNotContains(choose_body, "switch");

    const choose_field_body = try llvmFunctionBody(output.items, "define internal { i32, i32 } @choose_field_pair");
    try expectCanonicalConditional(choose_field_body);
    try expectContains(choose_field_body, "extractvalue { i32, i32 } %mc_arg_1, 0");
    try expectContains(choose_field_body, "extractvalue { i32, i32 } %mc_arg_1, 1");
    try expectContains(choose_field_body, "insertvalue { i32, i32 } zeroinitializer, i32 %mc_expr_tmp_");
    try expectContains(choose_field_body, "ret { i32, i32 } %mc_expr_tmp_");
    try expectNotContains(choose_field_body, "alloca");
    try expectNotContains(choose_field_body, "store");
    try expectNotContains(choose_field_body, "switch");

    const choose_assign_body = try llvmFunctionBody(output.items, "define internal { i32, i32 } @choose_assign_pair");
    try expectCanonicalConditional(choose_assign_body);
    try std.testing.expect(std.mem.count(u8, choose_assign_body, "insertvalue { i32, i32 }") >= 4);
    try expectContains(choose_assign_body, "ret { i32, i32 } %mc_expr_tmp_");
    try expectContains(choose_assign_body, "alloca { i32, i32 }");
    try expectContains(choose_assign_body, "store { i32, i32 }");
    try expectNotContains(choose_assign_body, "switch");

    const choose_assign_field_body = try llvmFunctionBody(output.items, "define internal { i32, i32 } @choose_assign_field_pair");
    try expectCanonicalConditional(choose_assign_field_body);
    try std.testing.expect(std.mem.count(u8, choose_assign_field_body, "extractvalue { i32, i32 }") >= 4);
    try std.testing.expect(std.mem.count(u8, choose_assign_field_body, "insertvalue { i32, i32 }") >= 4);
    try expectContains(choose_assign_field_body, "ret { i32, i32 } %mc_expr_tmp_");
    try expectContains(choose_assign_field_body, "alloca { i32, i32 }");
    try expectContains(choose_assign_field_body, "store { i32, i32 }");
    try expectNotContains(choose_assign_field_body, "switch");

    const local_body = try llvmFunctionBody(output.items, "define internal { i32, i32 } @local_pair");
    try expectContains(local_body, "; canonical executable MIR");
    try expectContains(local_body, "insertvalue { i32, i32 } zeroinitializer, i32 %mc_arg_0, 0");
    try expectContains(local_body, "i32 %mc_arg_1, 1");
    try expectContains(local_body, "alloca { i32, i32 }");
    try expectContains(local_body, "store { i32, i32 }");
    try expectContains(local_body, "ret { i32, i32 } %mc_expr_tmp_");

    const local_field_body = try llvmFunctionBody(output.items, "define internal { i32, i32 } @local_field_pair");
    try expectContains(local_field_body, "extractvalue { i32, i32 } %mc_arg_0, 0");
    try expectContains(local_field_body, "extractvalue { i32, i32 } %mc_arg_0, 1");
    try expectContains(local_field_body, "insertvalue { i32, i32 } zeroinitializer, i32 %mc_expr_tmp_");
    try expectContains(local_field_body, "ret { i32, i32 } %mc_expr_tmp_");
    try expectContains(local_field_body, "alloca { i32, i32 }");
    try expectContains(local_field_body, "store { i32, i32 }");

    const assigned_body = try llvmFunctionBody(output.items, "define internal { i32, i32 } @assigned_pair");
    try expectContains(assigned_body, "; canonical executable MIR");
    try std.testing.expect(std.mem.count(u8, assigned_body, "insertvalue { i32, i32 }") >= 4);
    try expectContains(assigned_body, "ret { i32, i32 } %mc_expr_tmp_");
    try expectContains(assigned_body, "alloca { i32, i32 }");
    try expectContains(assigned_body, "store { i32, i32 }");

    const assigned_field_body = try llvmFunctionBody(output.items, "define internal { i32, i32 } @assigned_field_pair");
    try expectContains(assigned_field_body, "; canonical executable MIR");
    try std.testing.expect(std.mem.count(u8, assigned_field_body, "extractvalue { i32, i32 }") >= 4);
    try std.testing.expect(std.mem.count(u8, assigned_field_body, "insertvalue { i32, i32 }") >= 4);
    try expectContains(assigned_field_body, "ret { i32, i32 } %mc_expr_tmp_");
    try expectContains(assigned_field_body, "alloca { i32, i32 }");
    try expectContains(assigned_field_body, "store { i32, i32 }");

    const loop_body = try llvmFunctionBody(output.items, "define internal { i32, i32 } @loop_pair");
    try expectContains(loop_body, "; canonical executable MIR");
    try expectContains(loop_body, "br i1 %mc_arg_0");
    try expectContains(loop_body, "insertvalue { i32, i32 } zeroinitializer, i32 %mc_arg_1, 0");
    try expectContains(loop_body, "i32 %mc_arg_2, 1");
    try expectContains(loop_body, "ret { i32, i32 } %mc_expr_tmp_");
    try expectNotContains(loop_body, "alloca");
    try expectNotContains(loop_body, "store");
    try expectNotContains(loop_body, "switch");

    const loop_local_body = try llvmFunctionBody(output.items, "define internal { i32, i32 } @loop_local_pair");
    try expectContains(loop_local_body, "; canonical executable MIR");
    try expectContains(loop_local_body, "br i1 %mc_arg_0");
    try expectContains(loop_local_body, "alloca { i32, i32 }");
    try expectContains(loop_local_body, "store { i32, i32 }");
    try expectContains(loop_local_body, "ret { i32, i32 } %mc_expr_tmp_");
    try expectNotContains(loop_local_body, "switch");

    const side_body = try llvmFunctionBody(output.items, "define internal { i32, i32 } @side_then_pair");
    try expectContains(side_body, "; canonical executable MIR");
    const side_call = std.mem.indexOf(u8, side_body, "call void @hit(i32 %mc_arg_0)") orelse return error.TestUnexpectedResult;
    const side_ret = std.mem.indexOf(u8, side_body, "ret { i32, i32 } %mc_expr_tmp_") orelse return error.TestUnexpectedResult;
    try std.testing.expect(side_call < side_ret);
    try expectContains(side_body, "insertvalue { i32, i32 } zeroinitializer, i32 %mc_arg_0, 0");
    try expectContains(side_body, "i32 %mc_arg_1, 1");
    try expectNotContains(side_body, "alloca");
    try expectNotContains(side_body, "store");

    const side_local_body = try llvmFunctionBody(output.items, "define internal { i32, i32 } @side_then_local_pair");
    try expectContains(side_local_body, "; canonical executable MIR");
    const side_local_call = std.mem.indexOf(u8, side_local_body, "call void @hit(i32 %mc_arg_0)") orelse return error.TestUnexpectedResult;
    const side_local_ret = std.mem.indexOf(u8, side_local_body, "ret { i32, i32 } %mc_expr_tmp_") orelse return error.TestUnexpectedResult;
    try std.testing.expect(side_local_call < side_local_ret);
    try expectContains(side_local_body, "alloca { i32, i32 }");
    try expectContains(side_local_body, "store { i32, i32 }");

    const early_body = try llvmFunctionBody(output.items, "define internal { i32, i32 } @early_pair");
    try expectContains(early_body, "; canonical executable MIR");
    try expectContains(early_body, "br i1 %mc_arg_0");
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, early_body, "insertvalue { i32, i32 }"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, early_body, "ret { i32, i32 } %mc_expr_tmp_"));
    try expectNotContains(early_body, "alloca");
    try expectNotContains(early_body, "store");
    try expectNotContains(early_body, "switch");
}

test "LLVM canonical executable MIR emits nested by-value struct member reads" {
    const source =
        \\struct Inner { value: u32 }
        \\struct Outer { inner: Inner }
        \\fn read(outer: Outer) -> u32 {
        \\    return outer.inner.value;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_executable_struct_member.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal i32 @read");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "extractvalue { { i32 } }");
    try expectContains(body, "extractvalue { i32 }");
}

test "LLVM canonical executable MIR emits nested parameter array indexes" {
    const source =
        \\fn read(matrix: [2][3]u32) -> u32 {
        \\    return matrix[0][0];
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_nested_parameter_array_index.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal i32 @read");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "getelementptr [2 x [3 x i32]]");
    try expectContains(body, "load [3 x i32]");
    try expectContains(body, "getelementptr [3 x i32]");
    try expectContains(body, "load i32");
}

test "LLVM canonical executable MIR emits guarded pointer member reads" {
    const source =
        \\struct State { winner: i32, ready: bool, count: usize }
        \\struct Cell { address: PAddr, length: usize }
        \\struct LargeState { cells: [40]Cell, spare: [40]Cell, count: usize }
        \\fn winner(state: *State) -> i32 { return state.winner; }
        \\fn ready(state: *State) -> bool { return state.ready; }
        \\fn count(state: *State) -> usize { return state.count; }
        \\fn large_count(state: *mut LargeState) -> usize { return state.count; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_executable_pointer_member.mc", source, &output);

    for ([_][]const u8{
        "define internal i32 @winner",
        "define internal i1 @ready",
        "define internal i64 @count",
        "define internal i64 @large_count",
    }) |signature| {
        const body = try llvmFunctionBody(output.items, signature);
        try expectContains(body, "; canonical executable MIR");
        try expectContains(body, "icmp eq ptr %mc_arg_0, null");
        try expectContains(body, "getelementptr inbounds");
        try expectContains(body, "load atomic");
        try expectContains(body, "ret ");
    }
}

test "LLVM canonical executable local pointer deref owns its representation edge" {
    const source =
        \\fn write(pointer: *mut u32, value: u32) -> void {
        \\    let local_pointer = pointer;
        \\    local_pointer.* = value;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_executable_local_pointer_deref.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal void @write");
    try expectContains(body, "; canonical executable MIR");
    const local_load = std.mem.indexOf(u8, body, "load ptr, ptr %mc_local_") orelse return error.TestUnexpectedResult;
    const guard = std.mem.indexOfPos(u8, body, local_load, "icmp eq ptr %mc_expr_tmp_") orelse return error.TestUnexpectedResult;
    const store = std.mem.indexOfPos(u8, body, guard, "store atomic i32 %mc_arg_1, ptr %mc_expr_tmp_") orelse return error.TestUnexpectedResult;
    try std.testing.expect(local_load < guard and guard < store);
}

test "LLVM canonical executable MIR keeps ordinary len fields distinct from slice length" {
    const source =
        \\struct WithLen { items: [8]u32, len: u32 }
        \\fn read_len(value: WithLen) -> u32 { return value.len; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_struct_len_field.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal i32 @read_len");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "extractvalue { [8 x i32], i32 } %mc_arg_0, 1");
}

test "LLVM emits simple array literal returns from MIR" {
    const source =
        \\const WIDE_LENGTH: usize = 20;
        \\fn array_direct(a: u32, b: u32) -> [2]u32 {
        \\    return .{ a, b };
        \\}
        \\fn array_local(a: u32, b: u32) -> [2]u32 {
        \\    var out: [2]u32 = .{ a, b };
        \\    return out;
        \\}
        \\fn array_assigned(a: u32, b: u32) -> [2]u32 {
        \\    var out: [2]u32 = .{ a, b };
        \\    out = .{ b, a };
        \\    return out;
        \\}
        \\fn array_wide(value: u32) -> [WIDE_LENGTH]u32 {
        \\    return .{ value, value, value, value, value, value, value, value, value, value,
        \\        value, value, value, value, value, value, value, value, value, value };
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_array_literal_returns.mc", source, &output);

    const direct_body = try llvmFunctionBody(output.items, "define internal [2 x i32] @array_direct");
    try expectContains(direct_body, "; canonical executable MIR");
    try expectContains(direct_body, "insertvalue [2 x i32] zeroinitializer, i32 %mc_arg_0, 0");
    try expectContains(direct_body, "insertvalue [2 x i32] %mc_expr_tmp_");
    try expectContains(direct_body, "i32 %mc_arg_1, 1");
    try expectContains(direct_body, "ret [2 x i32] %mc_expr_tmp_");
    try expectNotContains(direct_body, "alloca");
    try expectNotContains(direct_body, "store");

    const local_body = try llvmFunctionBody(output.items, "define internal [2 x i32] @array_local");
    try expectContains(local_body, "; canonical executable MIR");
    try expectContains(local_body, "insertvalue [2 x i32] zeroinitializer, i32 %mc_arg_0, 0");
    try expectContains(local_body, "i32 %mc_arg_1, 1");
    try expectContains(local_body, "ret [2 x i32] %mc_expr_tmp_");
    try expectContains(local_body, "alloca [2 x i32]");
    try expectContains(local_body, "store [2 x i32]");

    const assigned_body = try llvmFunctionBody(output.items, "define internal [2 x i32] @array_assigned");
    try expectContains(assigned_body, "; canonical executable MIR");
    try std.testing.expect(std.mem.count(u8, assigned_body, "insertvalue [2 x i32]") >= 4);
    try expectContains(assigned_body, "ret [2 x i32] %mc_expr_tmp_");
    try expectContains(assigned_body, "alloca [2 x i32]");
    try expectContains(assigned_body, "store [2 x i32]");

    const wide_body = try llvmFunctionBody(output.items, "define internal [20 x i32] @array_wide");
    try expectContains(wide_body, "; canonical executable MIR");
    try expectContains(wide_body, "insertvalue [20 x i32]");
    try expectContains(wide_body, "ret [20 x i32]");
}

test "LLVM emits array control-flow returns from MIR" {
    const source =
        \\extern fn hit(value: u32) -> void;
        \\fn choose_array(flag: bool, a: u32, b: u32) -> [2]u32 {
        \\    if (flag) {
        \\        return .{ a, b };
        \\    } else {
        \\        return .{ b, a };
        \\    }
        \\}
        \\fn choose_assign_array(flag: bool, a: u32, b: u32) -> [2]u32 {
        \\    var out: [2]u32 = .{ a, b };
        \\    if (flag) {
        \\        out = .{ b, a };
        \\    }
        \\    return out;
        \\}
        \\fn loop_array(flag: bool, a: u32, b: u32) -> [2]u32 {
        \\    while (flag) {
        \\    }
        \\    return .{ a, b };
        \\}
        \\fn side_then_array(a: u32, b: u32) -> [2]u32 {
        \\    hit(a);
        \\    return .{ a, b };
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_array_control_returns.mc", source, &output);

    const choose_body = try llvmFunctionBody(output.items, "define internal [2 x i32] @choose_array");
    try expectCanonicalConditional(choose_body);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, choose_body, "insertvalue [2 x i32]"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, choose_body, "ret [2 x i32] %mc_expr_tmp_"));
    try expectNotContains(choose_body, "alloca");
    try expectNotContains(choose_body, "store");
    try expectNotContains(choose_body, "switch");

    const choose_assign_body = try llvmFunctionBody(output.items, "define internal [2 x i32] @choose_assign_array");
    try expectCanonicalConditional(choose_assign_body);
    try std.testing.expect(std.mem.count(u8, choose_assign_body, "insertvalue [2 x i32]") >= 4);
    try expectContains(choose_assign_body, "ret [2 x i32] %mc_expr_tmp_");
    try expectContains(choose_assign_body, "alloca [2 x i32]");
    try expectContains(choose_assign_body, "store [2 x i32]");
    try expectNotContains(choose_assign_body, "switch");

    const loop_body = try llvmFunctionBody(output.items, "define internal [2 x i32] @loop_array");
    try expectContains(loop_body, "; canonical executable MIR");
    try expectContains(loop_body, "br i1 %mc_arg_0");
    try expectContains(loop_body, "insertvalue [2 x i32] zeroinitializer, i32 %mc_arg_1, 0");
    try expectContains(loop_body, "i32 %mc_arg_2, 1");
    try expectContains(loop_body, "ret [2 x i32] %mc_expr_tmp_");
    try expectNotContains(loop_body, "alloca");
    try expectNotContains(loop_body, "store");
    try expectNotContains(loop_body, "switch");

    const side_body = try llvmFunctionBody(output.items, "define internal [2 x i32] @side_then_array");
    const side_call = std.mem.indexOf(u8, side_body, "call void @hit(i32 %mc_arg_0)") orelse return error.TestUnexpectedResult;
    const side_ret = std.mem.indexOf(u8, side_body, "ret [2 x i32] %mc_expr_tmp_") orelse return error.TestUnexpectedResult;
    try std.testing.expect(side_call < side_ret);
    try expectContains(side_body, "insertvalue [2 x i32] zeroinitializer, i32 %mc_arg_0, 0");
    try expectContains(side_body, "i32 %mc_arg_1, 1");
    try expectNotContains(side_body, "alloca");
    try expectNotContains(side_body, "store");
}

test "LLVM emits scalar comparison returns from MIR" {
    const source =
        \\fn lt_u32(a: u32, b: u32) -> bool {
        \\    return a < b;
        \\}
        \\fn eq_i32(a: i32, b: i32) -> bool {
        \\    return a == b;
        \\}
        \\fn local_compare(a: u32, b: u32) -> bool {
        \\    let out: bool = a >= b;
        \\    return out;
        \\}
        \\fn assigned_compare(a: i32, b: i32) -> bool {
        \\    var out: bool = false;
        \\    out = a != b;
        \\    return out;
        \\}
        \\fn lt_f32(a: f32, b: f32) -> bool {
        \\    return a < b;
        \\}
        \\fn local_float_compare(a: f32, b: f32) -> bool {
        \\    let out: bool = a >= b;
        \\    return out;
        \\}
        \\fn assigned_float_compare(a: f32, b: f32) -> bool {
        \\    var out: bool = false;
        \\    out = a != b;
        \\    return out;
        \\}
        \\fn choose_compare(flag: bool, a: u32, b: u32) -> bool {
        \\    if (flag) {
        \\        return a < b;
        \\    } else {
        \\        return a > b;
        \\    }
        \\}
        \\fn choose_float_compare(flag: bool, a: f32, b: f32) -> bool {
        \\    if (flag) {
        \\        return a < b;
        \\    } else {
        \\        return a > b;
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_scalar_comparison_returns.mc", source, &output);

    const lt_body = try llvmFunctionBody(output.items, "define internal i1 @lt_u32");
    try expectContains(lt_body, "icmp ult i32 ");
    try expectContains(lt_body, "ret i1 %");
    try expectNotContains(lt_body, "alloca");
    try expectNotContains(lt_body, "store");

    const eq_body = try llvmFunctionBody(output.items, "define internal i1 @eq_i32");
    try expectContains(eq_body, "icmp eq i32 ");
    try expectContains(eq_body, "ret i1 %");
    try expectNotContains(eq_body, "alloca");
    try expectNotContains(eq_body, "store");

    const local_body = try llvmFunctionBody(output.items, "define internal i1 @local_compare");
    try expectContains(local_body, "icmp uge i32 ");
    try expectContains(local_body, "ret i1 %");

    const assigned_body = try llvmFunctionBody(output.items, "define internal i1 @assigned_compare");
    try expectContains(assigned_body, "icmp ne i32 ");
    try expectContains(assigned_body, "ret i1 %");

    const lt_f32_body = try llvmFunctionBody(output.items, "define internal i1 @lt_f32");
    try expectContains(lt_f32_body, "fcmp olt float ");
    try expectContains(lt_f32_body, "ret i1 %mc_expr_tmp_");
    try expectNotContains(lt_f32_body, "alloca");
    try expectNotContains(lt_f32_body, "store");

    const local_float_body = try llvmFunctionBody(output.items, "define internal i1 @local_float_compare");
    try expectContains(local_float_body, "; canonical executable MIR");
    try expectContains(local_float_body, "fcmp oge float ");
    try expectContains(local_float_body, "ret i1 %mc_expr_tmp_");

    const assigned_float_body = try llvmFunctionBody(output.items, "define internal i1 @assigned_float_compare");
    try expectContains(assigned_float_body, "; canonical executable MIR");
    try expectContains(assigned_float_body, "fcmp une float ");
    try expectContains(assigned_float_body, "ret i1 %mc_expr_tmp_");

    const choose_body = try llvmFunctionBody(output.items, "define internal i1 @choose_compare");
    try expectContains(choose_body, "br i1 %");
    try expectContains(choose_body, "icmp ult i32 ");
    try expectContains(choose_body, "icmp ugt i32 ");
    try expectContains(choose_body, "ret i1 %");
    try expectNotContains(choose_body, "alloca");
    try expectNotContains(choose_body, "store");
    try expectNotContains(choose_body, "switch");

    const choose_float_body = try llvmFunctionBody(output.items, "define internal i1 @choose_float_compare");
    try expectCanonicalConditional(choose_float_body);
    try expectContains(choose_float_body, "fcmp olt float %mc_arg_1, %mc_arg_2");
    try expectContains(choose_float_body, "fcmp ogt float %mc_arg_1, %mc_arg_2");
    try expectContains(choose_float_body, "ret i1 %mc_expr_tmp_");
    try expectNotContains(choose_float_body, "alloca");
    try expectNotContains(choose_float_body, "store");
    try expectNotContains(choose_float_body, "switch");
}

test "LLVM emits typed unary call-target returns from MIR without body fallback" {
    const source =
        \\open enum State: u8 { ready = 1 }
        \\fn float_bits(value: f32) -> u32 {
        \\    return bitcast<u32>(value);
        \\}
        \\fn bits_float(value: u32) -> f32 {
        \\    return bitcast<f32>(value);
        \\}
        \\fn state_raw(state: State) -> u8 {
        \\    return state.raw();
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_typed_unary_call_target_returns.mc", source, &output);

    const float_bits = try llvmFunctionBody(output.items, "define internal i32 @float_bits");
    try expectContains(float_bits, "bitcast float %mc_arg_0 to i32");
    try expectContains(float_bits, "ret i32 %mc_expr_tmp_");

    const bits_float = try llvmFunctionBody(output.items, "define internal float @bits_float");
    try expectContains(bits_float, "bitcast i32 %mc_arg_0 to float");
    try expectContains(bits_float, "ret float %mc_expr_tmp_");

    const state_raw = try llvmFunctionBody(output.items, "define internal i8 @state_raw");
    try expectContains(state_raw, "ret i8 %mc_arg_0");
    try expectNotContains(state_raw, "call");
}

test "LLVM typed unary fast path never substitutes an operand descendant" {
    const source =
        \\fn masked_bits(x: u32, y: u32) -> f32 {
        \\    return bitcast<f32>(x & y);
        \\}
        \\fn masked_phys(x: usize, y: usize) -> PAddr {
        \\    return phys(x & y);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_mir_typed_unary_operand_root.mc", source, &output);

    const masked_bits = try llvmFunctionBody(output.items, "define internal float @masked_bits");
    try expectContains(masked_bits, "and i32 %mc_arg_0, %mc_arg_1");

    const masked_phys = try llvmFunctionBody(output.items, "define internal i64 @masked_phys");
    try expectContains(masked_phys, "; canonical executable MIR");
    try expectContains(masked_phys, "and i64 %mc_arg_0, %mc_arg_1");
}

test "LLVM emits typed binary domain calls from MIR without body fallback" {
    const source =
        \\type S = serial<u32>;
        \\type T = counter<u64>;
        \\#[no_lang_trap]
        \\fn wrap_add(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> {
        \\    return wrapping.add(a, b);
        \\}
        \\fn seq_before(a: S, b: S) -> bool {
        \\    return S.before(a, b);
        \\}
        \\fn seq_after(a: S, b: S) -> bool {
        \\    return S.after(a, b);
        \\}
        \\fn seq_distance(a: S, b: S) -> wrap<u32> {
        \\    return S.distance(a, b);
        \\}
        \\fn tick_delta(now: T, start: T) -> wrap<u64> {
        \\    return T.delta_mod(now, start);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_typed_binary_domain_calls.mc", source, &output);

    try expectContains(try llvmFunctionBody(output.items, "define internal i32 @wrap_add(i32 %mc_arg_0, i32 %mc_arg_1)"), "add i32 %mc_arg_0, %mc_arg_1");
    const before = try llvmFunctionBody(output.items, "define internal i1 @seq_before(i32 %mc_arg_0, i32 %mc_arg_1)");
    try expectContains(before, "sub i32 %mc_arg_0, %mc_arg_1");
    try expectContains(before, "icmp slt i32 %mc_expr_tmp_");
    const after = try llvmFunctionBody(output.items, "define internal i1 @seq_after(i32 %mc_arg_0, i32 %mc_arg_1)");
    try expectContains(after, "sub i32 %mc_arg_0, %mc_arg_1");
    try expectContains(after, "icmp sgt i32 %mc_expr_tmp_");
    try expectContains(try llvmFunctionBody(output.items, "define internal i32 @seq_distance(i32 %mc_arg_0, i32 %mc_arg_1)"), "sub i32 %mc_arg_0, %mc_arg_1");
    try expectContains(try llvmFunctionBody(output.items, "define internal i64 @tick_delta(i64 %mc_arg_0, i64 %mc_arg_1)"), "sub i64 %mc_arg_0, %mc_arg_1");
}

test "LLVM typed binary domain fast path rejects call operands" {
    const source =
        \\type S = serial<u32>;
        \\fn identity(value: S) -> S { return value; }
        \\fn nested(a: S, b: S) -> bool {
        \\    return S.before(identity(a), b);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_mir_typed_binary_domain_nested.mc", source, &output);
    try expectContains(try llvmFunctionBody(output.items, "define internal i1 @nested(i32 %mc_arg_0, i32 %mc_arg_1)"), "call i32 @identity(i32 %mc_arg_0)");
}

test "LLVM emits checked arithmetic returns from MIR without body fallback" {
    const source =
        \\fn add_u32(a: u32, b: u32) -> u32 {
        \\    return a + b;
        \\}
        \\fn add_i32(a: i32, b: i32) -> i32 {
        \\    return a + b;
        \\}
        \\fn sub_i32(a: i32, b: i32) -> i32 {
        \\    return a - b;
        \\}
        \\fn mul_u64(a: u64, b: u64) -> u64 {
        \\    return a * b;
        \\}
        \\fn local_add(a: u32, b: u32) -> u32 {
        \\    let out: u32 = a + b;
        \\    return out;
        \\}
        \\fn assigned_sub(a: i32, b: i32) -> i32 {
        \\    var out: i32 = a;
        \\    out = a - b;
        \\    return out;
        \\}
        \\fn choose_add(flag: bool, a: u32, b: u32) -> u32 {
        \\    if (flag) {
        \\        return a + b;
        \\    } else {
        \\        return a - b;
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_checked_arithmetic_returns.mc", source, &output);

    const add_body = try llvmFunctionBody(output.items, "define internal i32 @add_u32");
    try expectContains(add_body, "@llvm.uadd.with.overflow.i32");
    try expectContains(add_body, "ret i32 %");
    try expectNotContains(add_body, "alloca");
    try expectNotContains(add_body, "store");

    const add_i32_body = try llvmFunctionBody(output.items, "define internal i32 @add_i32");
    try expectContains(add_i32_body, "@llvm.sadd.with.overflow.i32");
    try expectContains(add_i32_body, "ret i32 %");
    try expectNotContains(add_i32_body, "alloca");
    try expectNotContains(add_i32_body, "store");

    const sub_body = try llvmFunctionBody(output.items, "define internal i32 @sub_i32");
    try expectContains(sub_body, "@llvm.ssub.with.overflow.i32");
    try expectContains(sub_body, "ret i32 %");
    try expectNotContains(sub_body, "alloca");
    try expectNotContains(sub_body, "store");

    const mul_u64_body = try llvmFunctionBody(output.items, "define internal i64 @mul_u64");
    try expectContains(mul_u64_body, "@llvm.umul.with.overflow.i64");
    try expectContains(mul_u64_body, "ret i64 %");
    try expectNotContains(mul_u64_body, "alloca");
    try expectNotContains(mul_u64_body, "store");

    const local_body = try llvmFunctionBody(output.items, "define internal i32 @local_add");
    try expectContains(local_body, "@llvm.uadd.with.overflow.i32");
    try expectContains(local_body, "ret i32 %");

    const assigned_body = try llvmFunctionBody(output.items, "define internal i32 @assigned_sub");
    try expectContains(assigned_body, "@llvm.ssub.with.overflow.i32");
    try expectContains(assigned_body, "ret i32 %");
    try expectContains(assigned_body, "; canonical executable MIR");

    const choose_body = try llvmFunctionBody(output.items, "define internal i32 @choose_add");
    try expectContains(choose_body, "br i1 %");
    try expectContains(choose_body, "@llvm.uadd.with.overflow.i32");
    try expectContains(choose_body, "@llvm.usub.with.overflow.i32");
    try expectContains(choose_body, "ret i32 %");
    try expectNotContains(choose_body, "alloca");
    try expectNotContains(choose_body, "store");
    try expectNotContains(choose_body, "switch");
}

test "LLVM emits checked division returns from MIR without body fallback" {
    const source =
        \\fn div_i32(a: i32, b: i32) -> i32 {
        \\    return a / b;
        \\}
        \\fn div_u32(a: u32, b: u32) -> u32 {
        \\    return a / b;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_checked_division_returns.mc", source, &output);

    const signed_body = try llvmFunctionBody(output.items, "define internal i32 @div_i32");
    try expectContains(signed_body, "call void @mc_trap_DivideByZero()");
    try expectContains(signed_body, "call void @mc_trap_IntegerOverflow()");
    try expectContains(signed_body, "sdiv i32 %");
    try expectNotContains(signed_body, "alloca");

    const unsigned_body = try llvmFunctionBody(output.items, "define internal i32 @div_u32");
    try expectContains(unsigned_body, "call void @mc_trap_DivideByZero()");
    try expectNotContains(unsigned_body, "call void @mc_trap_IntegerOverflow()");
    try expectContains(unsigned_body, "udiv i32 %");
    try expectNotContains(unsigned_body, "alloca");
}

test "LLVM emits checked mod and shift returns from MIR without body fallback" {
    const source =
        \\fn mod_u32(a: u32, b: u32) -> u32 {
        \\    return a % b;
        \\}
        \\fn shl_u32(a: u32, n: u32) -> u32 {
        \\    return a << n;
        \\}
        \\fn shr_u32(a: u32, n: u32) -> u32 {
        \\    return a >> n;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_checked_mod_shift_returns.mc", source, &output);

    const mod_body = try llvmFunctionBody(output.items, "define internal i32 @mod_u32");
    try expectContains(mod_body, "call void @mc_trap_DivideByZero()");
    try expectContains(mod_body, "urem i32 %");
    try expectNotContains(mod_body, "alloca");

    const shl_body = try llvmFunctionBody(output.items, "define internal i32 @shl_u32");
    try expectContains(shl_body, "call void @mc_trap_InvalidShift()");
    try expectContains(shl_body, "call void @mc_trap_IntegerOverflow()");
    try expectContains(shl_body, "shl i64 %");
    try expectNotContains(shl_body, "alloca");

    const shr_body = try llvmFunctionBody(output.items, "define internal i32 @shr_u32");
    try expectContains(shr_body, "call void @mc_trap_InvalidShift()");
    try expectContains(shr_body, "lshr i32 %");
    try expectNotContains(shr_body, "call void @mc_trap_IntegerOverflow()");
    try expectNotContains(shr_body, "alloca");
}

test "LLVM emits checked unary returns from MIR without body fallback" {
    const source =
        \\fn neg_i32(a: i32) -> i32 {
        \\    return -a;
        \\}
        \\fn local_neg(a: i32) -> i32 {
        \\    let out: i32 = -a;
        \\    return out;
        \\}
        \\fn assigned_neg(a: i32) -> i32 {
        \\    var out: i32 = 0;
        \\    out = -a;
        \\    return out;
        \\}
        \\fn choose_neg(flag: bool, a: i32, b: i32) -> i32 {
        \\    if (flag) {
        \\        return -a;
        \\    } else {
        \\        return -b;
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_checked_unary_returns.mc", source, &output);

    const neg_body = try llvmFunctionBody(output.items, "define internal i32 @neg_i32");
    try expectContains(neg_body, "@llvm.ssub.with.overflow.i32");
    try expectContains(neg_body, "ret i32 %");
    try expectNotContains(neg_body, "alloca");
    try expectNotContains(neg_body, "store");

    const local_body = try llvmFunctionBody(output.items, "define internal i32 @local_neg");
    try expectContains(local_body, "@llvm.ssub.with.overflow.i32");
    try expectContains(local_body, "ret i32 %");
    if (std.mem.indexOf(u8, local_body, "; canonical executable MIR") == null) {
        try expectNotContains(local_body, "alloca");
        try expectNotContains(local_body, "store");
    }

    const assigned_body = try llvmFunctionBody(output.items, "define internal i32 @assigned_neg");
    try expectContains(assigned_body, "@llvm.ssub.with.overflow.i32");
    try expectContains(assigned_body, "ret i32 %");
    if (std.mem.indexOf(u8, assigned_body, "; canonical executable MIR") == null) {
        try expectNotContains(assigned_body, "alloca");
        try expectNotContains(assigned_body, "store");
    }

    const choose_body = try llvmFunctionBody(output.items, "define internal i32 @choose_neg");
    try expectContains(choose_body, if (std.mem.indexOf(u8, choose_body, "; canonical executable MIR") != null) "br i1 %mc_arg_0" else "br i1 %flag");
    try std.testing.expect(std.mem.count(u8, choose_body, "@llvm.ssub.with.overflow.i32") == 2);
    try expectContains(choose_body, "ret i32 %");
    try expectNotContains(choose_body, "alloca");
    try expectNotContains(choose_body, "store");
    try expectNotContains(choose_body, "switch");
}

test "LLVM target-types negated integer literals in canonical MIR" {
    const source =
        \\fn inferred_suffix() -> i8 { let value = -1_i8; return value; }
        \\fn min_neg() -> i32 { let value: i32 = -2147483648; return -value; }
        \\fn min_div() -> i32 { let value: i32 = -2147483648; return value / -1; }
        \\fn min_rem() -> i32 { let value: i32 = -2147483648; return value % -1; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_target_typed_negated_literals.mc", source, &output);

    const suffix_body = try llvmFunctionBody(output.items, "define internal i8 @inferred_suffix");
    try expectContains(suffix_body, "; canonical executable MIR");
    try expectContains(suffix_body, "store i8 -1");
    try expectNotContains(suffix_body, "@llvm.ssub.with.overflow.i8");

    const neg_body = try llvmFunctionBody(output.items, "define internal i32 @min_neg");
    try expectContains(neg_body, "; canonical executable MIR");
    try expectContains(neg_body, "@llvm.ssub.with.overflow.i32");

    const div_body = try llvmFunctionBody(output.items, "define internal i32 @min_div");
    try expectContains(div_body, "; canonical executable MIR");
    try expectContains(div_body, "sdiv i32");

    const rem_body = try llvmFunctionBody(output.items, "define internal i32 @min_rem");
    try expectContains(rem_body, "; canonical executable MIR");
    try expectContains(rem_body, "srem i32");
}

test "LLVM emits logical-not returns from MIR without body fallback" {
    const source =
        \\fn not_param(flag: bool) -> bool {
        \\    return !flag;
        \\}
        \\fn local_not(flag: bool) -> bool {
        \\    let out: bool = !flag;
        \\    return out;
        \\}
        \\fn assigned_not(flag: bool) -> bool {
        \\    var out: bool = false;
        \\    out = !flag;
        \\    return out;
        \\}
        \\fn choose_not(flag: bool, other: bool) -> bool {
        \\    if (flag) {
        \\        return !other;
        \\    } else {
        \\        return !flag;
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_logical_not_returns.mc", source, &output);

    const not_body = try llvmFunctionBody(output.items, "define internal i1 @not_param");
    try expectContains(not_body, "xor i1 %");
    try expectContains(not_body, ", true");
    try expectContains(not_body, "ret i1 %");
    try expectNotContains(not_body, "alloca");
    try expectNotContains(not_body, "store");

    const local_body = try llvmFunctionBody(output.items, "define internal i1 @local_not");
    try expectContains(local_body, "xor i1 %");
    try expectContains(local_body, ", true");
    try expectContains(local_body, "ret i1 %");

    const assigned_body = try llvmFunctionBody(output.items, "define internal i1 @assigned_not");
    try expectContains(assigned_body, "xor i1 %");
    try expectContains(assigned_body, ", true");
    try expectContains(assigned_body, "ret i1 %");

    const choose_body = try llvmFunctionBody(output.items, "define internal i1 @choose_not");
    try expectCanonicalConditional(choose_body);
    try expectContains(choose_body, "xor i1 %mc_arg_1, true");
    try expectContains(choose_body, "xor i1 %mc_arg_0, true");
    try expectContains(choose_body, "ret i1 %mc_expr_tmp_");
    try expectNotContains(choose_body, "alloca");
    try expectNotContains(choose_body, "store");
    try expectNotContains(choose_body, "switch");
}

test "LLVM emits basic scalar returns from MIR without body fallback" {
    const source =
        \\fn int_literal() -> u32 {
        \\    return 42;
        \\}
        \\fn bool_literal() -> bool {
        \\    return true;
        \\}
        \\fn param_return(a: u32) -> u32 {
        \\    return a;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_basic_scalar_returns.mc", source, &output);

    const int_body = try llvmFunctionBody(output.items, "define internal i32 @int_literal");
    try expectContains(int_body, "ret i32 42");
    try expectNotContains(int_body, "alloca");
    try expectNotContains(int_body, "store");

    const bool_body = try llvmFunctionBody(output.items, "define internal i1 @bool_literal");
    try expectContains(bool_body, "ret i1 true");
    try expectNotContains(bool_body, "alloca");
    try expectNotContains(bool_body, "store");

    const param_body = try llvmFunctionBody(output.items, "define internal i32 @param_return");
    try expectContains(param_body, "ret i32 %");
    try expectNotContains(param_body, "alloca");
    try expectNotContains(param_body, "store");
}

test "LLVM emits local and assigned scalar returns from MIR without body fallback" {
    const source =
        \\fn local_int() -> u32 {
        \\    let x: u32 = 42;
        \\    return x;
        \\}
        \\fn assigned_int() -> u32 {
        \\    var x: u32 = 0;
        \\    x = 42;
        \\    return x;
        \\}
        \\fn local_bool() -> bool {
        \\    let b: bool = true;
        \\    return b;
        \\}
        \\fn assigned_bool() -> bool {
        \\    var b: bool = false;
        \\    b = true;
        \\    return b;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_local_assigned_scalar_returns.mc", source, &output);

    const local_int_body = try llvmFunctionBody(output.items, "define internal i32 @local_int");
    try expectContains(local_int_body, "store i32 42");
    try expectContains(local_int_body, "ret i32 %");

    const assigned_int_body = try llvmFunctionBody(output.items, "define internal i32 @assigned_int");
    try expectContains(assigned_int_body, "42");
    try expectContains(assigned_int_body, "ret i32");

    const local_bool_body = try llvmFunctionBody(output.items, "define internal i1 @local_bool");
    try expectContains(local_bool_body, "store i1 true");
    try expectContains(local_bool_body, "ret i1 %");

    const assigned_bool_body = try llvmFunctionBody(output.items, "define internal i1 @assigned_bool");
    try expectContains(assigned_bool_body, "true");
    try expectContains(assigned_bool_body, "ret i1");
}

test "LLVM preserves nullable pointer promotion locals from MIR without body fallback" {
    const source =
        \\extern fn consume_nullable(p: ?*mut u8) -> void;
        \\fn local_promotion(p: *mut u8) -> ?*mut u8 {
        \\    let maybe: ?*mut u8 = p;
        \\    return maybe;
        \\}
        \\fn call_promotion(p: *mut u8) -> void {
        \\    consume_nullable(p);
        \\}
        \\fn assigned_promotion(p: *mut u8) -> ?*mut u8 {
        \\    var maybe: ?*mut u8 = null;
        \\    maybe = p;
        \\    return maybe;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_nullable_pointer_promotions.mc", source, &output);

    const local_body = try llvmFunctionBody(output.items, "define internal ptr @local_promotion");
    try expectContains(local_body, "; canonical executable MIR");
    try expectContains(local_body, "alloca ptr");
    const local_guard = std.mem.indexOf(u8, local_body, "icmp eq ptr %mc_arg_0, null") orelse return error.TestUnexpectedResult;
    const local_store = std.mem.indexOf(u8, local_body, "store ptr %mc_arg_0, ptr") orelse return error.TestUnexpectedResult;
    try std.testing.expect(local_guard < local_store);
    try expectContains(local_body, "load ptr, ptr");
    try expectContains(local_body, "ret ptr");
    try expectContains(local_body, "mc_trap_InvalidRepresentation");

    const assigned_body = try llvmFunctionBody(output.items, "define internal ptr @assigned_promotion");
    try expectContains(assigned_body, "; canonical executable MIR");
    try expectContains(assigned_body, "alloca ptr");
    try expectContains(assigned_body, "store ptr null, ptr");
    const assigned_guard = std.mem.indexOf(u8, assigned_body, "icmp eq ptr %mc_arg_0, null") orelse return error.TestUnexpectedResult;
    const assigned_store = std.mem.indexOf(u8, assigned_body, "store ptr %mc_arg_0, ptr") orelse return error.TestUnexpectedResult;
    try std.testing.expect(assigned_guard < assigned_store);
    try expectContains(assigned_body, "load ptr, ptr");
    try expectContains(assigned_body, "ret ptr");
    try expectContains(assigned_body, "mc_trap_InvalidRepresentation");

    const call_body = try llvmFunctionBody(output.items, "define internal void @call_promotion");
    try expectContains(call_body, "; canonical executable MIR");
    try expectContains(call_body, "icmp eq ptr %mc_arg_0, null");
    try expectContains(call_body, "call void @consume_nullable(ptr %mc_arg_0)");
    try expectContains(call_body, "ret void");
    try expectContains(call_body, "mc_trap_InvalidRepresentation");
}

test "LLVM emits nullable pointer try from MIR without body fallback" {
    const source =
        \\extern fn maybe_ptr() -> ?*mut u8;
        \\extern fn ptr_value(p: *mut u8) -> u32;
        \\extern fn consume_ptr(p: *mut u8) -> void;
        \\fn unwrap_param(maybe: ?*mut u8) -> *mut u8 {
        \\    return maybe?;
        \\}
        \\fn unwrap_call() -> *mut u8 {
        \\    return maybe_ptr()?;
        \\}
        \\fn arg_try(maybe: ?*mut u8) -> u32 {
        \\    return ptr_value(maybe?);
        \\}
        \\fn direct_arg_try() -> u32 {
        \\    return ptr_value(maybe_ptr()?);
        \\}
        \\fn expr_nullable_try() -> void {
        \\    consume_ptr(maybe_ptr()?);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_nullable_pointer_try.mc", source, &output);

    const unwrap_param_body = try llvmFunctionBody(output.items, "define internal ptr @unwrap_param");
    try expectContains(unwrap_param_body, "icmp eq ptr %");
    try expectContains(unwrap_param_body, "call void @mc_trap_NullUnwrap()");
    try expectContains(unwrap_param_body, "ret ptr %");

    const unwrap_call_body = try llvmFunctionBody(output.items, "define internal ptr @unwrap_call");
    try expectContains(unwrap_call_body, "call ptr @maybe_ptr()");
    try expectContains(unwrap_call_body, "icmp eq ptr %");
    try expectContains(unwrap_call_body, "ret ptr %");

    const arg_try_body = try llvmFunctionBody(output.items, "define internal i32 @arg_try");
    try expectContains(arg_try_body, "icmp eq ptr %");
    try expectContains(arg_try_body, "call i32 @ptr_value(ptr %");

    const direct_arg_body = try llvmFunctionBody(output.items, "define internal i32 @direct_arg_try");
    try expectContains(direct_arg_body, "call ptr @maybe_ptr()");
    try expectContains(direct_arg_body, "call i32 @ptr_value(ptr %");

    const expr_body = try llvmFunctionBody(output.items, "define internal void @expr_nullable_try");
    try expectContains(expr_body, "call ptr @maybe_ptr()");
    try expectContains(expr_body, "call void @consume_ptr(ptr %");
    try expectContains(expr_body, "ret void");
}

test "LLVM emits value optional and Result try from MIR without body fallback" {
    const source =
        \\enum Error: u8 { denied = 1, }
        \\struct Pair { left: u32, right: u32, }
        \\extern fn make_result() -> Result<u32, Error>;
        \\fn unwrap_value(maybe: ?u32) -> u32 {
        \\    return maybe?;
        \\}
        \\fn unwrap_result(result: Result<u32, Error>) -> u32 {
        \\    return result?;
        \\}
        \\fn unwrap_result_call() -> u32 {
        \\    return make_result()?;
        \\}
        \\fn unwrap_pair(result: Result<Pair, Error>) -> u32 {
        \\    let pair: Pair = result?;
        \\    return pair.left + pair.right;
        \\}
        \\fn propagate(result: Result<u32, Error>) -> Result<u32, Error> {
        \\    return ok(result?);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_aggregate_try.mc", source, &output);

    const optional_body = try llvmFunctionBody(output.items, "define internal i32 @unwrap_value");
    try expectContains(optional_body, "; canonical executable MIR");
    try expectContains(optional_body, "extractvalue { i1, i32 }");
    try expectContains(optional_body, "br i1");
    try expectContains(optional_body, "call void @mc_trap_NullUnwrap()");
    try expectContains(optional_body, "ret i32");

    const result_body = try llvmFunctionBody(output.items, "define internal i32 @unwrap_result");
    try expectContains(result_body, "; canonical executable MIR");
    try expectContains(result_body, "extractvalue { i1, i32, i8 }");
    try expectContains(result_body, "call void @mc_trap_NullUnwrap()");
    try expectContains(result_body, "ret i32");

    const call_body = try llvmFunctionBody(output.items, "define internal i32 @unwrap_result_call");
    try expectContains(call_body, "call { i1, i32, i8 } @make_result()");
    try expectContains(call_body, "call void @mc_trap_NullUnwrap()");
    try expectContains(call_body, "ret i32");

    const pair_body = try llvmFunctionBody(output.items, "define internal i32 @unwrap_pair");
    try expectContains(pair_body, "extractvalue { i1, { i32, i32 }, i8 }");
    try expectContains(pair_body, "call void @mc_trap_NullUnwrap()");
    try expectContains(pair_body, "ret i32");

    const propagate_body = try llvmFunctionBody(output.items, "define internal { i1, i32, i8 } @propagate");
    try expectContains(propagate_body, "; canonical executable MIR");
    try expectContains(propagate_body, "label %mc_propagate_ok_");
    try expectContains(propagate_body, "label %mc_propagate_err_");
    try expectContains(propagate_body, "ret { i1, i32, i8 }");
}

test "LLVM emits strict nullable control plans from MIR without body fallback" {
    const source =
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
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_variant_control.mc", source, &output);

    const call_body = try llvmFunctionBody(output.items, "define internal i32 @unwrap_call_or_zero");
    try expectContains(call_body, "call ptr @maybe_ptr()");
    try expectContains(call_body, "icmp ne ptr");
    try expectContains(call_body, "call i32 @ptr_value(ptr");
    try expectContains(call_body, "ret i32 0");

    const global_body = try llvmFunctionBody(output.items, "define internal i32 @unwrap_global_or_zero");
    try expectContains(global_body, "@saved_nullable");
    try expectContains(global_body, "call i32 @ptr_value(ptr");

    const field_body = try llvmFunctionBody(output.items, "define internal i32 @unwrap_field_or_zero");
    try expectContains(field_body, "extractvalue { ptr }");
    try expectContains(field_body, ", 0");
    try expectContains(field_body, "call i32 @ptr_value(ptr");

    const switch_body = try llvmFunctionBody(output.items, "define internal i32 @nullable_switch");
    try expectContains(switch_body, "; canonical executable MIR");
    try expectContains(switch_body, "icmp ne ptr %");
    try expectContains(switch_body, "call i32 @ptr_value(ptr %");

    const seeded_body = try llvmFunctionBody(output.items, "define internal i32 @nullable_switch_call_seed");
    const seed_offset = std.mem.indexOf(u8, seeded_body, "call i32 @next_seed()") orelse return error.TestUnexpectedResult;
    const subject_offset = std.mem.indexOf(u8, seeded_body, "call ptr @maybe_ptr_from(i32") orelse return error.TestUnexpectedResult;
    try std.testing.expect(seed_offset < subject_offset);
    try expectContains(seeded_body, "call i32 @ptr_value(ptr");

    const unwrap_or_body = try llvmFunctionBody(output.items, "define internal ptr @unwrap_or");
    try expectContains(unwrap_or_body, "; canonical executable MIR");
    try expectContains(unwrap_or_body, "icmp ne ptr %mc_expr_tmp_");
    try expectContains(unwrap_or_body, "ret ptr %mc_expr_tmp_");
}

test "LLVM emits nullable none returns from MIR without body fallback" {
    const source =
        \\fn direct_none() -> ?u32 {
        \\    return null;
        \\}
        \\fn local_none() -> ?u32 {
        \\    let x: ?u32 = null;
        \\    return x;
        \\}
        \\fn assigned_none() -> ?u32 {
        \\    var x: ?u32 = null;
        \\    x = null;
        \\    return x;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_nullable_none_returns.mc", source, &output);

    const direct_body = try llvmFunctionBody(output.items, "define internal { i1, i32 } @direct_none");
    try expectContains(direct_body, "ret { i1, i32 } zeroinitializer");
    try expectNotContains(direct_body, "alloca");
    try expectNotContains(direct_body, "store");

    const local_body = try llvmFunctionBody(output.items, "define internal { i1, i32 } @local_none");
    try expectContains(local_body, "; canonical executable MIR");
    try expectContains(local_body, "zeroinitializer");

    const assigned_body = try llvmFunctionBody(output.items, "define internal { i1, i32 } @assigned_none");
    try expectContains(assigned_body, "; canonical executable MIR");
    try expectContains(assigned_body, "ret { i1, i32 } %mc_expr_tmp_");
    try expectContains(assigned_body, "alloca { i1, i32 }");
    try expectContains(assigned_body, "store { i1, i32 }");
}

test "LLVM emits conditional nullable none returns from MIR without body fallback" {
    const source =
        \\fn choose_none(flag: bool) -> ?u32 {
        \\    if (flag) {
        \\        return null;
        \\    } else {
        \\        return null;
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_conditional_nullable_none_returns.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal { i1, i32 } @choose_none");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "br i1 ");
    try expectContains(body, "ret { i1, i32 } zeroinitializer");
    try expectNotContains(body, "alloca");
    try expectNotContains(body, "store");
}

test "LLVM preserves MIR void calls before nullable none returns" {
    const source =
        \\extern fn hit(value: i32) -> void;
        \\fn side_then_none() -> ?u32 {
        \\    hit(7);
        \\    return null;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_void_calls_before_nullable_none_return.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal { i1, i32 } @side_then_none");
    const hit = std.mem.indexOf(u8, body, "call void @hit(i32 7)") orelse return error.TestUnexpectedResult;
    const ret = std.mem.indexOf(u8, body, "ret { i1, i32 } zeroinitializer") orelse return error.TestUnexpectedResult;
    try std.testing.expect(hit < ret);
    try expectNotContains(body, "alloca");
    try expectNotContains(body, "store");
}

test "LLVM emits loop nullable none returns from MIR without body fallback" {
    const source =
        \\extern fn hit(value: i32) -> void;
        \\fn loop_then_none(flag: bool) -> ?u32 {
        \\    while flag {
        \\        hit(9);
        \\    }
        \\    return null;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_loop_nullable_none_return.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal { i1, i32 } @loop_then_none");
    const branch = std.mem.indexOf(u8, body, "br i1 %mc_arg_0") orelse return error.TestUnexpectedResult;
    const hit = std.mem.indexOf(u8, body, "call void @hit(i32 ") orelse return error.TestUnexpectedResult;
    const ret = std.mem.indexOf(u8, body, "ret { i1, i32 } ") orelse return error.TestUnexpectedResult;
    try std.testing.expect(branch < hit);
    try std.testing.expect(hit < ret);
    try expectNotContains(body, "switch");
    try expectNotContains(body, "alloca");
    try expectNotContains(body, "store");
}

test "LLVM emits enum literal returns from MIR without body fallback" {
    const source =
        \\enum Color {
        \\    red,
        \\    blue,
        \\}
        \\fn color() -> Color {
        \\    return .blue;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_enum_literal_return.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal i64 @color");
    try expectContains(body, "ret i64 1");
    try expectNotContains(body, "alloca");
    try expectNotContains(body, "store");
}

test "LLVM emits enum variant raw values from MIR without body fallback" {
    const source =
        \\enum Color: u32 { red = 3, blue = 20 }
        \\open enum OpenTag: u8 { lo = 1, hi = 2 }
        \\fn closed_variant_raw() -> u32 { return Color.blue.raw(); }
        \\fn open_variant_raw() -> u8 { return OpenTag.hi.raw(); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_enum_variant_raw.mc", source, &output);

    const closed = try llvmFunctionBody(output.items, "define internal i32 @closed_variant_raw");
    try expectContains(closed, "; canonical executable MIR");
    try expectContains(closed, "ret i32 20");
    const open = try llvmFunctionBody(output.items, "define internal i8 @open_variant_raw");
    try expectContains(open, "; canonical executable MIR");
    try expectContains(open, "ret i8 2");
}

test "LLVM emits nominal scalar resource flow from MIR without body fallback" {
    const source =
        \\extern fn disable_interrupts() -> IrqOff;
        \\extern fn restore_interrupts(cs: IrqOff) -> void;
        \\fn read_device(reg: u32, cs: IrqOff) -> u32 { return reg; }
        \\fn critical_read(reg: u32) -> u32 {
        \\    let cs: IrqOff = disable_interrupts();
        \\    let value: u32 = read_device(reg, cs);
        \\    restore_interrupts(cs);
        \\    return value;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_nominal_scalar_resource.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal i32 @critical_read");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "call i8 @disable_interrupts()");
    try expectContains(body, "call i32 @read_device(i32 %mc_arg_0, i8");
    try expectContains(body, "call void @restore_interrupts(i8");
}

test "LLVM emits nested fixed-array aggregates from MIR without body fallback" {
    const source =
        \\struct Bag { values: [2][2]u32 }
        \\fn make_bag() -> Bag {
        \\    return .{ .values = .{ .{ 1, 2 }, .{ 3, 4 } } };
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_nested_array_aggregate.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal { [2 x [2 x i32]] } @make_bag");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "insertvalue [2 x [2 x i32]]");
    try expectContains(body, "ret { [2 x [2 x i32]] }");
}

test "LLVM compares value optionals with null from MIR without body fallback" {
    const source =
        \\fn present(value: u32) -> ?u32 { return value; }
        \\fn is_present(value: u32) -> bool { return present(value) != null; }
        \\fn is_absent(value: u32) -> bool { return present(value) == null; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_optional_null_compare.mc", source, &output);

    const present_body = try llvmFunctionBody(output.items, "define internal i1 @is_present");
    try expectContains(present_body, "; canonical executable MIR");
    try expectContains(present_body, "extractvalue { i1, i32 }");
    const absent_body = try llvmFunctionBody(output.items, "define internal i1 @is_absent");
    try expectContains(absent_body, "; canonical executable MIR");
    try expectContains(absent_body, "extractvalue { i1, i32 }");
    try expectContains(absent_body, "xor i1");
}

test "LLVM emits local and loop enum returns from MIR without body fallback" {
    const source =
        \\enum Color {
        \\    red,
        \\    blue,
        \\}
        \\extern fn hit(value: u32) -> void;
        \\fn local_color() -> Color {
        \\    let c: Color = .blue;
        \\    return c;
        \\}
        \\fn assigned_color() -> Color {
        \\    var c: Color = .red;
        \\    c = .blue;
        \\    return c;
        \\}
        \\fn loop_color(flag: bool) -> Color {
        \\    while flag {
        \\        hit(1);
        \\    }
        \\    return .blue;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_local_loop_enum_returns.mc", source, &output);

    const local_body = try llvmFunctionBody(output.items, "define internal i64 @local_color");
    try expectContains(local_body, "; canonical executable MIR");
    try expectContains(local_body, "call void @mc_trap_InvalidRepresentation()");
    try expectContains(local_body, "ret i64 %");

    const assigned_body = try llvmFunctionBody(output.items, "define internal i64 @assigned_color");
    if (std.mem.indexOf(u8, assigned_body, "; canonical executable MIR") != null) {
        try expectContains(assigned_body, "call void @mc_trap_InvalidRepresentation()");
        try expectContains(assigned_body, "ret i64 %");
    } else try expectContains(assigned_body, "ret i64 1");

    const loop_body = try llvmFunctionBody(output.items, "define internal i64 @loop_color");
    const branch = std.mem.indexOf(u8, loop_body, "br i1 %mc_arg_0") orelse return error.TestUnexpectedResult;
    const hit = std.mem.indexOf(u8, loop_body, "call void @hit(i32 ") orelse return error.TestUnexpectedResult;
    const ret = std.mem.indexOf(u8, loop_body, "ret i64 ") orelse return error.TestUnexpectedResult;
    try std.testing.expect(branch < hit);
    try std.testing.expect(hit < ret);
    try expectNotContains(loop_body, "switch");
    try expectNotContains(loop_body, "alloca");
    try expectNotContains(loop_body, "store");
}

test "LLVM preserves MIR void calls before local enum returns" {
    const source =
        \\enum Color {
        \\    red,
        \\    blue,
        \\}
        \\extern fn hit(value: u32) -> void;
        \\fn side_then_local_color() -> Color {
        \\    hit(2);
        \\    let c: Color = .blue;
        \\    return c;
        \\}
        \\fn side_then_assigned_color() -> Color {
        \\    hit(3);
        \\    var c: Color = .red;
        \\    c = .blue;
        \\    return c;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_void_calls_before_local_enum_return.mc", source, &output);

    const local_body = try llvmFunctionBody(output.items, "define internal i64 @side_then_local_color");
    const local_hit = std.mem.indexOf(u8, local_body, "call void @hit(i32 2)") orelse return error.TestUnexpectedResult;
    const local_ret = std.mem.indexOf(u8, local_body, "ret i64 %") orelse return error.TestUnexpectedResult;
    try std.testing.expect(local_hit < local_ret);
    try expectContains(local_body, "call void @mc_trap_InvalidRepresentation()");

    const assigned_body = try llvmFunctionBody(output.items, "define internal i64 @side_then_assigned_color");
    const assigned_hit = std.mem.indexOf(u8, assigned_body, "call void @hit(i32 3)") orelse return error.TestUnexpectedResult;
    const assigned_ret = std.mem.indexOf(u8, assigned_body, if (std.mem.indexOf(u8, assigned_body, "; canonical executable MIR") != null) "ret i64 %" else "ret i64 1") orelse return error.TestUnexpectedResult;
    try std.testing.expect(assigned_hit < assigned_ret);
    if (std.mem.indexOf(u8, assigned_body, "; canonical executable MIR") != null)
        try expectContains(assigned_body, "call void @mc_trap_InvalidRepresentation()");
}

test "LLVM emits conditional enum literal returns from MIR without body fallback" {
    const source =
        \\enum Color {
        \\    red,
        \\    blue,
        \\}
        \\fn choose(flag: bool) -> Color {
        \\    if (flag) {
        \\        return .red;
        \\    } else {
        \\        return .blue;
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_conditional_enum_literal_return.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal i64 @choose");
    try expectCanonicalConditional(body);
    try expectContains(body, "ret i64 0");
    try expectContains(body, "ret i64 1");
    try expectNotContains(body, "alloca");
    try expectNotContains(body, "store");
}

test "LLVM preserves MIR void calls before direct-call returns" {
    const source =
        \\extern fn hit(value: i32) -> void;
        \\extern fn make(value: i32) -> i32;
        \\fn side_then_call() -> i32 {
        \\    hit(0);
        \\    return make(1);
        \\}
        \\fn return_call_add(a: i32, b: i32) -> i32 {
        \\    return make(a + b);
        \\}
        \\fn return_call_neg(a: i32) -> i32 {
        \\    return make(-a);
        \\}
        \\fn return_local_call(a: i32) -> i32 {
        \\    let x: i32 = make(a);
        \\    return x;
        \\}
        \\fn return_call_local_call_arg(a: i32) -> i32 {
        \\    let x: i32 = make(a);
        \\    return make(x);
        \\}
        \\fn return_assigned_call(a: i32) -> i32 {
        \\    var x: i32 = 0;
        \\    x = make(a);
        \\    return x;
        \\}
        \\fn return_local_call_add(a: i32, b: i32) -> i32 {
        \\    let x: i32 = make(a + b);
        \\    return x;
        \\}
        \\fn return_assigned_call_neg(a: i32) -> i32 {
        \\    var x: i32 = 0;
        \\    x = make(-a);
        \\    return x;
        \\}
        \\fn side_then_local_call_add(a: i32, b: i32) -> i32 {
        \\    hit(0);
        \\    let x: i32 = make(a + b);
        \\    return x;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_void_calls_before_direct_call_return.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal i32 @side_then_call");
    const hit = std.mem.indexOf(u8, body, "call void @hit(i32 ") orelse return error.TestUnexpectedResult;
    const call = std.mem.indexOf(u8, body, "call i32 @make(i32 ") orelse return error.TestUnexpectedResult;
    const ret = std.mem.indexOf(u8, body, "ret i32 %mc_expr_tmp_") orelse return error.TestUnexpectedResult;
    try std.testing.expect(hit < call);
    try std.testing.expect(call < ret);

    const add_body = try llvmFunctionBody(output.items, "define internal i32 @return_call_add");
    try expectContains(add_body, "@llvm.sadd.with.overflow.i32");
    try expectContains(add_body, "call i32 @make(i32 %");
    try expectContains(add_body, "ret i32 %");
    try expectNotContains(add_body, "alloca");
    try expectNotContains(add_body, "store");

    const neg_body = try llvmFunctionBody(output.items, "define internal i32 @return_call_neg");
    try expectContains(neg_body, "@llvm.ssub.with.overflow.i32");
    try expectContains(neg_body, "call i32 @make(i32 %");
    try expectContains(neg_body, "ret i32 %");
    try expectNotContains(neg_body, "alloca");
    try expectNotContains(neg_body, "store");

    const local_call_body = try llvmFunctionBody(output.items, "define internal i32 @return_local_call");
    try expectContains(local_call_body, "call i32 @make(i32 %");
    try expectContains(local_call_body, "ret i32 %");

    const local_call_arg_body = try llvmFunctionBody(output.items, "define internal i32 @return_call_local_call_arg");
    const first_local_call = std.mem.indexOf(u8, local_call_arg_body, "call i32 @make(i32 %") orelse return error.TestUnexpectedResult;
    const second_local_call = std.mem.lastIndexOf(u8, local_call_arg_body, "call i32 @make(i32 %") orelse return error.TestUnexpectedResult;
    const local_call_arg_ret = std.mem.indexOf(u8, local_call_arg_body, "ret i32 %") orelse return error.TestUnexpectedResult;
    try std.testing.expect(first_local_call < second_local_call);
    try std.testing.expect(second_local_call < local_call_arg_ret);

    const assigned_call_body = try llvmFunctionBody(output.items, "define internal i32 @return_assigned_call");
    try expectContains(assigned_call_body, "call i32 @make(i32 %");
    try expectContains(assigned_call_body, "ret i32 %");

    const local_call_add_body = try llvmFunctionBody(output.items, "define internal i32 @return_local_call_add");
    try expectContains(local_call_add_body, "@llvm.sadd.with.overflow.i32");
    try expectContains(local_call_add_body, "call i32 @make(i32 %");
    try expectContains(local_call_add_body, "ret i32 %");

    const assigned_call_neg_body = try llvmFunctionBody(output.items, "define internal i32 @return_assigned_call_neg");
    try expectContains(assigned_call_neg_body, "@llvm.ssub.with.overflow.i32");
    try expectContains(assigned_call_neg_body, "call i32 @make(i32 %");
    try expectContains(assigned_call_neg_body, "ret i32 %");
    if (std.mem.indexOf(u8, assigned_call_neg_body, "; canonical executable MIR") == null) {
        try expectNotContains(assigned_call_neg_body, "alloca");
        try expectNotContains(assigned_call_neg_body, "store");
    }

    const side_then_local_call_add_body = try llvmFunctionBody(output.items, "define internal i32 @side_then_local_call_add");
    const side_hit = std.mem.indexOf(u8, side_then_local_call_add_body, "call void @hit(i32 0)") orelse return error.TestUnexpectedResult;
    const side_add = std.mem.indexOf(u8, side_then_local_call_add_body, "@llvm.sadd.with.overflow.i32") orelse return error.TestUnexpectedResult;
    const side_make = std.mem.indexOf(u8, side_then_local_call_add_body, "call i32 @make(i32 %") orelse return error.TestUnexpectedResult;
    const side_ret = std.mem.indexOf(u8, side_then_local_call_add_body, "ret i32 %") orelse return error.TestUnexpectedResult;
    try std.testing.expect(side_hit < side_add);
    try std.testing.expect(side_add < side_make);
    try std.testing.expect(side_make < side_ret);
    if (std.mem.indexOf(u8, side_then_local_call_add_body, "; canonical executable MIR") == null) {
        try expectNotContains(side_then_local_call_add_body, "alloca");
        try expectNotContains(side_then_local_call_add_body, "store");
    }
}

test "LLVM emits enum literal direct-call arguments from MIR without body fallback" {
    const source =
        \\enum Mode: u8 { read = 1, write = 2 }
        \\extern fn sink(mode: Mode) -> Mode;
        \\fn pass() -> Mode {
        \\    return sink(.write);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_enum_direct_call_argument.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal i8 @pass");
    try expectContains(body, "call i8 @sink(i8 2)");
    try expectContains(body, "call void @mc_trap_InvalidRepresentation()");
    try expectContains(body, "ret i8 %mc_expr_tmp_");
    try expectNotContains(body, "alloca");
    try expectNotContains(body, "store");
}

test "LLVM emits enum literal compare operands from MIR without body fallback" {
    const source =
        \\enum Mode: u8 { read = 1, write = 2 }
        \\fn is_read(mode: Mode) -> bool {
        \\    return mode == .read;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_enum_literal_compare_operands.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal i1 @is_read");
    try expectContains(body, "call void @mc_trap_InvalidRepresentation()");
    try expectContains(body, "icmp eq i8");
    try expectContains(body, "ret i1 %");
    try expectNotContains(body, "alloca");
    try expectNotContains(body, "store");
}

test "LLVM emits enum literal explicit casts from MIR without body fallback" {
    const source =
        \\enum Mode: u8 { read = 1, write = 2 }
        \\fn cast_mode() -> Mode {
        \\    return .write as Mode;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_enum_literal_explicit_cast.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal i8 @cast_mode");
    try expectContains(body, "ret i8 2");
    try expectNotContains(body, "alloca");
    try expectNotContains(body, "store");
}

test "LLVM emits enum, pointer-address, and signedness casts from executable MIR" {
    const source =
        \\enum Mode: u8 { read = 1, write = 2 }
        \\fn enum_raw(mode: Mode) -> u8 { return mode as u8; }
        \\fn pointer_address(pointer: *mut u8) -> PAddr { unsafe { return pointer as PAddr; } }
        \\fn signed_bits(value: u64) -> i64 { return value as i64; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_representation_casts.mc", source, &output);

    const enum_body = try llvmFunctionBody(output.items, "define internal i8 @enum_raw");
    try expectContains(enum_body, "; canonical executable MIR");
    const pointer_body = try llvmFunctionBody(output.items, "define internal i64 @pointer_address");
    try expectContains(pointer_body, "ptrtoint ptr %mc_arg_0 to i64");
    const signed_body = try llvmFunctionBody(output.items, "define internal i64 @signed_bits");
    try expectContains(signed_body, "ret i64 %mc_arg_0");
}

test "LLVM emits transparent integer domain casts from executable MIR" {
    const source =
        \\fn wrapping_add_u64(a: u64, b: u64) -> u64 {
        \\    let wa: wrap<u64> = a as wrap<u64>;
        \\    let wb: wrap<u64> = b as wrap<u64>;
        \\    return (wa + wb) as u64;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_domain_casts.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i64 @wrapping_add_u64");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "add i64");
}

test "LLVM scalar switch returns lower from MIR without body fallback" {
    const source =
        \\fn classify(n: i32) -> u32 {
        \\    switch n {
        \\        -1 => { return 1; },
        \\        0, 2 => { return 2; },
        \\        _ => { return 3; },
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_scalar_switch.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal i32 @classify");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "switch i32 %mc_arg_0");
    try expectContains(body, "i32 -1, label %mc_block_");
    try expectContains(body, "i32 0, label %mc_block_");
    try expectContains(body, "i32 2, label %mc_block_");
    try expectContains(body, "ret i32 3");
}

test "LLVM emits local global returns from MIR" {
    const source =
        \\global g: u32 = 0;
        \\fn local_global_return() -> u32 {
        \\    let x: u32 = g;
        \\    return x;
        \\}
        \\fn assigned_global_return() -> u32 {
        \\    var x: u32 = 0;
        \\    x = g;
        \\    return x;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_local_global_return.mc", source, &output);

    const local_body = try llvmFunctionBody(output.items, "define internal i32 @local_global_return");
    try expectContains(local_body, "; canonical executable MIR");
    try expectContains(local_body, "load atomic i32, ptr @g unordered, align 4");
    try expectContains(local_body, "ret i32 %");

    const assigned_body = try llvmFunctionBody(output.items, "define internal i32 @assigned_global_return");
    try expectContains(assigned_body, "; canonical executable MIR");
    try expectContains(assigned_body, "load atomic i32, ptr @g unordered, align 4");
    try expectContains(assigned_body, "ret i32 %");
}

test "LLVM inferred local global return lowers without function body fallback" {
    const source =
        \\global g: u32 = 0;
        \\fn inferred_global_return() -> u32 {
        \\    let x = g;
        \\    return x;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_inferred_local_global_return.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal i32 @inferred_global_return");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "load atomic i32, ptr @g unordered, align 4");
    try expectContains(body, "ret i32 %");
}

test "LLVM preserves MIR void calls before global returns" {
    const source =
        \\global g: u32 = 0;
        \\extern fn hit(value: i32) -> void;
        \\fn side_then_global_return() -> u32 {
        \\    hit(4);
        \\    return g;
        \\}
        \\fn side_then_local_global_return() -> u32 {
        \\    hit(5);
        \\    let x: u32 = g;
        \\    return x;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_void_calls_before_global_return.mc", source, &output);

    const direct_body = try llvmFunctionBody(output.items, "define internal i32 @side_then_global_return");
    const direct_hit = std.mem.indexOf(u8, direct_body, "call void @hit(i32 ") orelse return error.TestUnexpectedResult;
    const direct_load = std.mem.indexOf(u8, direct_body, "load atomic i32, ptr @g unordered, align 4") orelse return error.TestUnexpectedResult;
    const direct_ret = std.mem.indexOf(u8, direct_body, "ret i32 %mc_expr_tmp_") orelse return error.TestUnexpectedResult;
    try std.testing.expect(direct_hit < direct_load);
    try std.testing.expect(direct_load < direct_ret);
    try expectNotContains(direct_body, "alloca");
    try expectNotContains(direct_body, "store");

    const local_body = try llvmFunctionBody(output.items, "define internal i32 @side_then_local_global_return");
    const local_hit = std.mem.indexOf(u8, local_body, "call void @hit(i32 ") orelse return error.TestUnexpectedResult;
    const local_load = std.mem.indexOf(u8, local_body, "load atomic i32, ptr @g unordered, align 4") orelse return error.TestUnexpectedResult;
    const local_ret = std.mem.indexOf(u8, local_body, "ret i32 %mc_expr_tmp_") orelse return error.TestUnexpectedResult;
    try std.testing.expect(local_hit < local_load);
    try std.testing.expect(local_load < local_ret);
    if (std.mem.indexOf(u8, local_body, "; canonical executable MIR") == null) {
        try expectNotContains(local_body, "alloca");
        try expectNotContains(local_body, "store");
    }
}

test "LLVM preserves MIR void calls before conditional returns" {
    const source =
        \\extern fn hit(value: i32) -> void;
        \\extern fn make(value: i32) -> i32;
        \\fn side_then_cond(flag: bool) -> i32 {
        \\    hit(0);
        \\    if (flag) {
        \\        return 1;
        \\    } else {
        \\        return 2;
        \\    }
        \\}
        \\fn choose_return_call_checked(flag: bool, a: i32, b: i32) -> i32 {
        \\    if (flag) {
        \\        return make(a + b);
        \\    } else {
        \\        return make(a - b);
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_void_calls_before_conditional_return.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal i32 @side_then_cond");
    const hit = std.mem.indexOf(u8, body, "call void @hit(i32 ") orelse return error.TestUnexpectedResult;
    const branch = std.mem.indexOf(u8, body, if (std.mem.indexOf(u8, body, "; canonical executable MIR") != null) "br i1 %mc_" else "br i1 %flag") orelse return error.TestUnexpectedResult;
    try std.testing.expect(hit < branch);
    try expectContains(body, "ret i32 1");
    try expectContains(body, "ret i32 2");

    const checked_body = try llvmFunctionBody(output.items, "define internal i32 @choose_return_call_checked");
    try expectCanonicalConditional(checked_body);
    try expectContains(checked_body, "@llvm.sadd.with.overflow.i32");
    try expectContains(checked_body, "@llvm.ssub.with.overflow.i32");
    try expectContains(checked_body, "call i32 @make(i32 %mc_expr_tmp_");
    try expectNotContains(checked_body, "alloca");
    try expectNotContains(checked_body, "store");
    try expectNotContains(checked_body, "switch");
}

test "LLVM discarded direct-call results lower from MIR without body fallback" {
    const source =
        \\extern fn combine(left: u32, right: u32) -> u32;
        \\fn discard_value(left: u32, right: u32) -> void {
        \\    combine(left, right);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_discarded_direct_call_result.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal void @discard_value");
    const call_text = "call i32 @combine(i32 %mc_arg_0, i32 %mc_arg_1)";
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, call_text));
    const call = std.mem.indexOf(u8, body, call_text) orelse return error.TestUnexpectedResult;
    const ret = std.mem.indexOf(u8, body, "ret void") orelse return error.TestUnexpectedResult;
    try std.testing.expect(call < ret);
    try expectContains(body, "= call i32 @combine");
    try expectNotContains(body, "alloca");
    try expectNotContains(body, "store");
}

test "LLVM zero-argument function-pointer calls lower from MIR without body fallback" {
    const source =
        \\extern fn entry_of() -> fn() -> void;
        \\fn call_entry_param(entry: fn() -> void) -> void {
        \\    entry();
        \\}
        \\fn call_fn_pointer() -> void {
        \\    let entry: fn() -> void = entry_of();
        \\    entry();
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_zero_arg_function_pointer_calls.mc", source, &output);

    const param_body = try llvmFunctionBody(output.items, "define internal void @call_entry_param");
    try expectContains(param_body, "; canonical executable MIR");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, param_body, "call void %mc_arg_0()"));
    const param_call = std.mem.indexOf(u8, param_body, "call void %mc_arg_0()") orelse return error.TestUnexpectedResult;
    const param_ret = std.mem.indexOf(u8, param_body, "ret void") orelse return error.TestUnexpectedResult;
    try std.testing.expect(param_call < param_ret);
    try expectNotContains(param_body, "alloca");
    try expectNotContains(param_body, "store");
    try expectNotContains(param_body, "load ptr");

    const local_body = try llvmFunctionBody(output.items, "define internal void @call_fn_pointer");
    try expectContains(local_body, "; canonical executable MIR");
    const producer_text = "call ptr @entry_of()";
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, local_body, producer_text));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, local_body, "call void %"));
    const producer = std.mem.indexOf(u8, local_body, producer_text) orelse return error.TestUnexpectedResult;
    const indirect = std.mem.indexOfPos(u8, local_body, producer + producer_text.len, "call void %") orelse return error.TestUnexpectedResult;
    const local_ret = std.mem.indexOfPos(u8, local_body, indirect, "ret void") orelse return error.TestUnexpectedResult;
    try std.testing.expect(producer < indirect);
    try std.testing.expect(indirect < local_ret);
    try expectContains(local_body, "%mc_local_0 = alloca ptr");
    try expectContains(local_body, "store ptr %mc_expr_tmp_0, ptr %mc_local_0");
    try expectContains(local_body, "%mc_expr_tmp_1 = load ptr, ptr %mc_local_0");
}

test "LLVM typed indirect call returns lower from MIR without body fallback" {
    const source =
        \\fn add(left: u32, right: u32) -> u32 { return left + right; }
        \\fn mul(left: u32, right: u32) -> u32 { return left * right; }
        \\global default_op: fn(u32, u32) -> u32 = add;
        \\global default_ops: [2]fn(u32, u32) -> u32 = .{ add, mul };
        \\struct BinOp { combine: fn(u32, u32) -> u32 }
        \\global default_box: BinOp = .{ .combine = add };
        \\global default_boxes: [2]BinOp = .{ .{ .combine = add }, .{ .combine = mul } };
        \\fn apply(op: fn(u32, u32) -> u32, x: u32, y: u32) -> u32 { return op(x, y); }
        \\fn dispatch(o: *BinOp, x: u32, y: u32) -> u32 { return o.combine(x, y); }
        \\fn global_op_call(x: u32, y: u32) -> u32 { return default_op(x, y); }
        \\fn global_op_array_call(x: u32, y: u32) -> u32 { return default_ops[1](x, y); }
        \\fn global_box_call(x: u32, y: u32) -> u32 { return default_box.combine(x, y); }
        \\fn global_box_array_call(x: u32, y: u32) -> u32 { return default_boxes[1].combine(x, y); }
        \\fn local_fn_pointer_call(x: u32, y: u32) -> u32 {
        \\    let op: fn(u32, u32) -> u32 = mul;
        \\    return op(x, y);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_typed_indirect_call_returns.mc", source, &output);

    const param_body = try llvmFunctionBody(output.items, "define internal i32 @apply");
    try expectContains(param_body, "; canonical executable MIR");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, param_body, "call i32 %mc_arg_0(i32 %mc_arg_1, i32 %mc_arg_2)"));
    try expectContains(param_body, "ret i32");
    try expectNotContains(param_body, "alloca");

    const dispatch_body = try llvmFunctionBody(output.items, "define internal i32 @dispatch");
    try expectContains(dispatch_body, "; canonical executable MIR");
    try expectContains(dispatch_body, "getelementptr inbounds { ptr }, ptr %mc_arg_0, i32 0, i32 0");
    try expectContains(dispatch_body, "load atomic ptr");
    try expectContains(dispatch_body, "call i32 %");

    const global_body = try llvmFunctionBody(output.items, "define internal i32 @global_op_call");
    try expectContains(global_body, "; canonical executable MIR");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, global_body, "load atomic ptr, ptr @default_op unordered"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, global_body, "call i32 %"));
    try expectContains(global_body, "ret i32");
    try expectNotContains(global_body, "alloca");

    const field_body = try llvmFunctionBody(output.items, "define internal i32 @global_box_call");
    try expectContains(field_body, "; canonical executable MIR");
    try expectContains(field_body, "getelementptr inbounds { ptr }, ptr @default_box, i32 0, i32 0");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, field_body, "load atomic ptr"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, field_body, "call i32 %"));
    try expectContains(field_body, "ret i32");
    try expectNotContains(field_body, "alloca");

    const array_body = try llvmFunctionBody(output.items, "define internal i32 @global_op_array_call");
    try expectContains(array_body, "; canonical executable MIR");
    try expectContains(array_body, "mc_trap_Bounds");
    try expectContains(array_body, "getelementptr inbounds [2 x ptr], ptr @default_ops");
    try expectContains(array_body, "load atomic ptr");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, array_body, "call i32 %"));

    const array_field_body = try llvmFunctionBody(output.items, "define internal i32 @global_box_array_call");
    try expectContains(array_field_body, "; canonical executable MIR");
    try expectContains(array_field_body, "mc_trap_Bounds");
    try expectContains(array_field_body, "getelementptr inbounds [2 x { ptr }], ptr @default_boxes");
    try expectContains(array_field_body, "getelementptr inbounds { ptr }");
    try expectContains(array_field_body, "load atomic ptr");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, array_field_body, "call i32 %"));

    const local_body = try llvmFunctionBody(output.items, "define internal i32 @local_fn_pointer_call");
    try expectContains(local_body, "alloca ptr");
    try expectContains(local_body, "store ptr @mul, ptr %");
    try expectContains(local_body, "load ptr, ptr %");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, local_body, "call i32 %"));
    try expectContains(local_body, "ret i32");
}

fn appendLlvmTest(source_name: []const u8, source: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseModule(source_name, source);
    defer parsed.deinit();

    try appendLlvmDeclsTest(std.testing.allocator, parsed.decls(), output);
}

fn appendLlvmDeclsTest(allocator: std.mem.Allocator, decls: []ast.Decl, output: *std.ArrayList(u8)) !void {
    try appendLlvmWithSourcePathDeclsTest(allocator, decls, output, "input.mc", false);
}

fn appendLlvmWithSourcePathDeclsTest(allocator: std.mem.Allocator, decls: []ast.Decl, output: *std.ArrayList(u8), source_path: []const u8, optimize: bool) !void {
    try appendLlvmCheckedDeclsTest(allocator, decls, output, source_path, .{ .optimize = optimize }, false, .riscv64);
}

fn appendLlvmCheckedDeclsTest(allocator: std.mem.Allocator, decls: []ast.Decl, output: *std.ArrayList(u8), source_path: []const u8, checks: backend_mod.Checks, stub_asm: bool, target: backend_mod.TargetArch) !void {
    var module_mir = try mir.buildOptFromDecls(allocator, decls, .{ .optimize = checks.optimize });
    defer module_mir.deinit();
    try appendLlvmCheckedMirDeclsTest(allocator, decls, &module_mir, output, source_path, checks, stub_asm, target, null);
}

fn appendLlvmCheckedMirDeclsTest(allocator: std.mem.Allocator, decls: []ast.Decl, module_mir: *const mir.Module, output: *std.ArrayList(u8), source_path: []const u8, checks: backend_mod.Checks, stub_asm: bool, target: backend_mod.TargetArch, reporter: ?*diagnostics.Reporter) !void {
    try appendLlvmCheckedMirProfileDeclsTest(allocator, decls, module_mir, output, source_path, checks, stub_asm, target, false, reporter);
}

fn appendLlvmCheckedMirProfileDeclsTest(allocator: std.mem.Allocator, decls: []ast.Decl, module_mir: *const mir.Module, output: *std.ArrayList(u8), source_path: []const u8, checks: backend_mod.Checks, stub_asm: bool, target: backend_mod.TargetArch, linux_kernel: bool, reporter: ?*diagnostics.Reporter) !void {
    var artifacts = try test_artifact_support.collectArtifactsFromDecls(allocator, decls, module_mir);
    defer artifacts.deinit(allocator);
    try lower_llvm.appendLlvmCheckedMirArtifacts(allocator, artifacts.codegen(), module_mir, output, source_path, checks, stub_asm, target, linux_kernel, reporter);
}

test "LLVM rejects a verified body with missing declaration facts" {
    const source =
        \\fn value() -> u32 { return 7; }
    ;
    var parsed = try test_support.parseCheckedModule("llvm_missing_declaration_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.UnsupportedLlvmEmission,
        lower_llvm.appendLlvmCheckedMirArtifacts(
            std.testing.allocator,
            .empty,
            &module_mir,
            &output,
            "llvm_missing_declaration_facts.mc",
            .{},
            false,
            .riscv64,
            false,
            null,
        ),
    );
}

fn appendLlvmCheckedMirTest(source_name: []const u8, source: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseModule(source_name, source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try appendLlvmCheckedMirProfileDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, output, source_name, .{}, false, .riscv64, false, null);
}

fn appendLlvmTargetTest(source_name: []const u8, source: []const u8, target: @import("backend.zig").TargetArch, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseModule(source_name, source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, output, source_name, .{}, false, target, null);
}

fn appendLlvmLinuxKernelTest(source_name: []const u8, source: []const u8, target: @import("backend.zig").TargetArch, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseModule(source_name, source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try appendLlvmCheckedMirProfileDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, output, source_name, .{}, false, target, true, null);
}

test "LLVM Linux kernel profile externalizes runtime and emits x86 hardening metadata" {
    const source = "export fn identity(value: u32) -> u32 { return value; }";
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmLinuxKernelTest("linux_kernel_profile.mc", source, .x86_64, &output);

    try expectContains(output.items, "declare void @mc_trap_IntegerOverflow() noreturn");
    try expectNotContains(output.items, "define weak void @mc_trap_IntegerOverflow()");
    try expectNotContains(output.items, "define weak void @mc_ksan_check");
    try expectContains(output.items, "define i32 @identity(i32 %mc_arg_0) nounwind fn_ret_thunk_extern");
    try expectContains(output.items, "!\"cf-protection-branch\", i32 1");
    try expectContains(output.items, "!\"function_return_thunk_extern\", i32 1");
}

test "LLVM runtime hook suppression uses VerifiedProgram runtime hook facts" {
    const source =
        \\export fn mc_trap_Bounds() -> void {}
        \\export fn mc_ksan_check(addr: usize, size: usize) -> void {}
    ;
    var parsed = try test_support.parseModule("llvm_runtime_hook_facts.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const program = try backend_mod.VerifiedProgram.init(&module_mir, &parsed.reporter);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_llvm_prelude.emitTrapDecl(std.testing.allocator, &output, program.runtime_hooks);

    try expectNotContains(output.items, "define weak void @mc_trap_Bounds()");
    try expectContains(output.items, "define weak void @mc_trap_IntegerOverflow()");
    try expectNotContains(output.items, "define weak void @mc_ksan_check");
    try expectContains(output.items, "define weak void @mc_ksan_store");
}

test "LLVM Linux kernel profile emits arm64 BTI hardening metadata" {
    const source = "export fn identity(value: u32) -> u32 { return value; }";
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmLinuxKernelTest("linux_kernel_arm64.mc", source, .aarch64, &output);

    try expectContains(output.items, "define i32 @identity(i32 %mc_arg_0) nounwind \"branch-target-enforcement\"");
    try expectContains(output.items, "!\"branch-target-enforcement\", i32 2");
}

test "LLVM explicit C ABI scalar extensions match each target" {
    const source =
        \\extern "C" fn c_i8(value: i8) -> i8;
        \\extern "C" fn c_u8(value: u8) -> u8;
        \\extern "C" fn c_u32(value: u32) -> u32;
        \\extern "C" fn c_bool(value: bool) -> bool;
        \\extern "C" fn c_order(value: Order) -> Order;
        \\extern "C" fn c_irq(value: IrqOff) -> IrqOff;
        \\extern "C" fn c_overflow(value: Overflow) -> Overflow;
        \\extern "C" fn c_conversion(value: ConversionError) -> ConversionError;
        \\extern "C" fn c_wrap(value: wrap<u8>) -> wrap<u8>;
        \\extern "C" fn c_sat(value: sat<i8>) -> sat<i8>;
        \\extern "C" fn c_counter(value: counter<u32>) -> counter<u32>;
        \\extern fn mc_i8(value: i8) -> i8;
        \\export fn c_export(value: i8) -> i8 { return c_i8(value); }
        \\export fn c_wrap_export(value: wrap<u8>) -> wrap<u8> { return c_wrap(value); }
        \\export fn c_sat_export(value: sat<i8>) -> sat<i8> { return c_sat(value); }
        \\export fn c_counter_export(value: counter<u32>) -> counter<u32> { return c_counter(value); }
        \\#[mc_abi]
        \\export fn mc_export(value: i8) -> i8 { return mc_i8(value); }
    ;

    var riscv: std.ArrayList(u8) = .empty;
    defer riscv.deinit(std.testing.allocator);
    try appendLlvmTargetTest("llvm_c_abi_riscv.mc", source, .riscv64, &riscv);
    try expectContains(riscv.items, "declare signext i8 @c_i8(i8 signext)");
    try expectContains(riscv.items, "declare zeroext i8 @c_u8(i8 zeroext)");
    try expectContains(riscv.items, "declare signext i32 @c_u32(i32 signext)");
    try expectContains(riscv.items, "declare zeroext i1 @c_bool(i1 zeroext)");
    try expectContains(riscv.items, "declare signext i8 @c_order(i8 signext)");
    try expectContains(riscv.items, "declare zeroext i8 @c_irq(i8 zeroext)");
    try expectContains(riscv.items, "declare zeroext i8 @c_overflow(i8 zeroext)");
    try expectContains(riscv.items, "declare zeroext i8 @c_conversion(i8 zeroext)");
    try expectContains(riscv.items, "declare zeroext i8 @c_wrap(i8 zeroext)");
    try expectContains(riscv.items, "declare signext i8 @c_sat(i8 signext)");
    try expectContains(riscv.items, "declare signext i32 @c_counter(i32 signext)");
    try expectContains(riscv.items, "define signext i8 @c_export(i8 signext %mc_arg_0)");
    const c_export_body = try llvmFunctionBody(riscv.items, "define signext i8 @c_export");
    try expectContains(c_export_body, "; canonical executable MIR");
    try expectContains(c_export_body, "call signext i8 @c_i8(i8 signext %mc_arg_0)");
    const c_wrap_body = try llvmFunctionBody(riscv.items, "define zeroext i8 @c_wrap_export");
    try expectContains(c_wrap_body, "; canonical executable MIR");
    try expectContains(c_wrap_body, "call zeroext i8 @c_wrap(i8 zeroext %mc_arg_0)");
    const c_sat_body = try llvmFunctionBody(riscv.items, "define signext i8 @c_sat_export");
    try expectContains(c_sat_body, "; canonical executable MIR");
    try expectContains(c_sat_body, "call signext i8 @c_sat(i8 signext %mc_arg_0)");
    const c_counter_body = try llvmFunctionBody(riscv.items, "define signext i32 @c_counter_export");
    try expectContains(c_counter_body, "; canonical executable MIR");
    try expectContains(c_counter_body, "call signext i32 @c_counter(i32 signext %mc_arg_0)");
    try expectContains(riscv.items, "declare i8 @mc_i8(i8)");
    try expectContains(riscv.items, "define i8 @mc_export(i8 %mc_arg_0)");

    var x86: std.ArrayList(u8) = .empty;
    defer x86.deinit(std.testing.allocator);
    try appendLlvmTargetTest("llvm_c_abi_x86.mc", source, .x86_64, &x86);
    try expectContains(x86.items, "declare signext i8 @c_i8(i8 signext)");
    try expectContains(x86.items, "declare zeroext i8 @c_u8(i8 zeroext)");
    try expectContains(x86.items, "declare signext i8 @c_order(i8 signext)");
    try expectContains(x86.items, "declare zeroext i8 @c_overflow(i8 zeroext)");
    try expectContains(x86.items, "declare i32 @c_u32(i32)");
    const x86_wrap_body = try llvmFunctionBody(x86.items, "define zeroext i8 @c_wrap_export");
    try expectContains(x86_wrap_body, "call zeroext i8 @c_wrap(i8 zeroext %mc_arg_0)");
    const x86_sat_body = try llvmFunctionBody(x86.items, "define signext i8 @c_sat_export");
    try expectContains(x86_sat_body, "call signext i8 @c_sat(i8 signext %mc_arg_0)");
    const x86_counter_body = try llvmFunctionBody(x86.items, "define i32 @c_counter_export");
    try expectContains(x86_counter_body, "call i32 @c_counter(i32 %mc_arg_0)");

    var arm: std.ArrayList(u8) = .empty;
    defer arm.deinit(std.testing.allocator);
    try appendLlvmTargetTest("llvm_c_abi_arm.mc", source, .aarch64, &arm);
    try expectContains(arm.items, "declare i8 @c_i8(i8)");
    try expectContains(arm.items, "declare i8 @c_u8(i8)");
    try expectContains(arm.items, "declare i1 @c_bool(i1)");
    try expectContains(arm.items, "declare i8 @c_order(i8)");
    try expectContains(arm.items, "declare i8 @c_overflow(i8)");
    const arm_wrap_body = try llvmFunctionBody(arm.items, "define i8 @c_wrap_export");
    try expectContains(arm_wrap_body, "call i8 @c_wrap(i8 %mc_arg_0)");
    const arm_sat_body = try llvmFunctionBody(arm.items, "define i8 @c_sat_export");
    try expectContains(arm_sat_body, "call i8 @c_sat(i8 %mc_arg_0)");
    const arm_counter_body = try llvmFunctionBody(arm.items, "define i32 @c_counter_export");
    try expectContains(arm_counter_body, "call i32 @c_counter(i32 %mc_arg_0)");
}

test "LLVM generated locals and blocks avoid source parameter names" {
    const source =
        \\fn collisions(t0: u32, t1: u32, bb_entry: u32, bb_switch_end0: u32) -> u32 {
        \\    if t0 == t1 { return bb_entry; }
        \\    return bb_switch_end0;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_local_name_collisions.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal i32 @collisions");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "icmp eq i32 ");
    try expectContains(body, "br i1 %");
    try expectContains(body, "mc_block_");
    try expectNotContains(body, "\n  %t0 =");
    try expectNotContains(body, "\nbb_switch_end0:");
}

test "LLVM nominal declarations shadow same-named library scalars" {
    const source =
        \\struct Error { code: u32 }
        \\fn identity(value: Error) -> Error { return value; }
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_shadowed_library_scalar.mc", source, &output);
    try expectContains(output.items, "define internal { i32 } @identity({ i32 } %mc_arg_0)");
    try expectNotContains(output.items, "define internal i8 @identity(i8 %value)");
}

test "LLVM target-typed char literals require MIR facts" {
    const source =
        \\fn char_value() -> u16 { return 'A'; }
    ;
    var parsed = try test_support.parseModule("llvm_char_literal_facts.mc", source);
    defer parsed.deinit();

    {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try appendLlvmCheckedMirTest("llvm_mir_char_literal_facts.mc", source, &output);
        try std.testing.expect(std.mem.indexOf(u8, output.items, "ret i16 65") != null);
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try removeTargetTypeKindForFunction(&module_mir, "char_value", .char_literal);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_char_literal_facts.mc", .{}, false, .riscv64, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try renameTargetTypeFactForFunction(&module_mir, "char_value", .char_literal, "u8");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_char_literal_facts.mc", .{}, false, .riscv64, null));
    }
}

test "LLVM local and assigned char literal returns lower without body fallback" {
    const source =
        \\fn local_char() -> u16 {
        \\    let x: u16 = 'A';
        \\    return x;
        \\}
        \\fn assigned_char() -> u16 {
        \\    var x: u16 = 0;
        \\    x = 'B';
        \\    return x;
        \\}
        \\fn choose_char(flag: bool) -> u16 {
        \\    if (flag) {
        \\        return 'A';
        \\    } else {
        \\        return 'B';
        \\    }
        \\}
        \\fn choose_char_early(flag: bool) -> u16 {
        \\    if (flag) {
        \\        return 'A';
        \\    }
        \\    return 'B';
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_local_assigned_char_literal_return.mc", source, &output);

    const local_body = try llvmFunctionBody(output.items, "define internal i16 @local_char");
    try expectContains(local_body, "i16 65");
    if (std.mem.indexOf(u8, local_body, "; canonical executable MIR") != null) {
        try expectContains(local_body, "alloca i16");
        try expectContains(local_body, "store i16");
        try expectContains(local_body, "ret i16 %");
    } else {
        try expectContains(local_body, "ret i16 65");
        try expectNotContains(local_body, "alloca");
        try expectNotContains(local_body, "store");
    }

    const assigned_body = try llvmFunctionBody(output.items, "define internal i16 @assigned_char");
    try expectContains(assigned_body, "i16 66");
    if (std.mem.indexOf(u8, assigned_body, "; canonical executable MIR") != null) {
        try expectContains(assigned_body, "alloca i16");
        try expectContains(assigned_body, "store i16");
        try expectContains(assigned_body, "ret i16 %");
    } else {
        try expectContains(assigned_body, "ret i16 66");
        try expectNotContains(assigned_body, "alloca");
        try expectNotContains(assigned_body, "store");
    }

    const choose_body = try llvmFunctionBody(output.items, "define internal i16 @choose_char");
    try expectContains(choose_body, "ret i16 65");
    try expectContains(choose_body, "ret i16 66");
    try expectNotContains(choose_body, "alloca");

    const choose_early_body = try llvmFunctionBody(output.items, "define internal i16 @choose_char_early");
    try expectContains(choose_early_body, "ret i16 65");
    try expectContains(choose_early_body, "ret i16 66");
    try expectNotContains(choose_early_body, "alloca");
}

test "LLVM float literal returns lower without body fallback" {
    const source =
        \\extern fn mark_float(value: f32) -> f32;
        \\fn small() -> f32 {
        \\    return 1.5;
        \\}
        \\fn wide() -> f64 {
        \\    return 2.5;
        \\}
        \\fn local_small() -> f32 {
        \\    let x: f32 = 1.5;
        \\    return x;
        \\}
        \\fn assigned_small() -> f32 {
        \\    var x: f32 = 0.0;
        \\    x = 1.5;
        \\    return x;
        \\}
        \\fn direct_call_small() -> f32 {
        \\    return mark_float(1.5);
        \\}
        \\fn choose(flag: bool) -> f32 {
        \\    if (flag) {
        \\        return 1.5;
        \\    } else {
        \\        return 2.5;
        \\    }
        \\}
        \\fn choose_early(flag: bool) -> f32 {
        \\    if (flag) {
        \\        return 1.5;
        \\    }
        \\    return 2.5;
        \\}
        \\fn less_than_literal(value: f32) -> bool {
        \\    return value < 1.5;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_float_literal_return.mc", source, &output);

    const small_body = try llvmFunctionBody(output.items, "define internal float @small");
    try expectContains(small_body, "ret float bitcast (i32 1069547520 to float)");
    try expectNotContains(small_body, "alloca");

    const wide_body = try llvmFunctionBody(output.items, "define internal double @wide");
    try expectContains(wide_body, "ret double bitcast (i64 4612811918334230528 to double)");
    try expectNotContains(wide_body, "alloca");

    const local_body = try llvmFunctionBody(output.items, "define internal float @local_small");
    try expectContains(local_body, "store float bitcast (i32 1069547520 to float)");
    try expectContains(local_body, "ret float %mc_expr_tmp_");

    const assigned_body = try llvmFunctionBody(output.items, "define internal float @assigned_small");
    try expectContains(assigned_body, "store float bitcast (i32 1069547520 to float)");
    try expectContains(assigned_body, "ret float %mc_expr_tmp_");

    const call_body = try llvmFunctionBody(output.items, "define internal float @direct_call_small");
    try expectContains(call_body, "call float @mark_float(float bitcast (i32 1069547520 to float))");
    try expectContains(call_body, "ret float %mc_expr_tmp_");
    try expectNotContains(call_body, "alloca");

    const choose_body = try llvmFunctionBody(output.items, "define internal float @choose");
    try expectCanonicalConditional(choose_body);
    try expectContains(choose_body, "bitcast (i32 1069547520 to float)");
    try expectContains(choose_body, "bitcast (i32 1075838976 to float)");
    try expectContains(choose_body, "ret float ");
    try expectNotContains(choose_body, "alloca");

    const choose_early_body = try llvmFunctionBody(output.items, "define internal float @choose_early");
    if (std.mem.indexOf(u8, choose_early_body, "; canonical executable MIR") != null) {
        try expectContains(choose_early_body, "ret float bitcast (i32 1069547520 to float)");
        try expectContains(choose_early_body, "ret float bitcast (i32 1075838976 to float)");
    } else {
        try expectContains(choose_early_body, "ret float 0x3FF8000000000000");
        try expectContains(choose_early_body, "ret float 0x4004000000000000");
    }
    try expectNotContains(choose_early_body, "alloca");

    const less_body = try llvmFunctionBody(output.items, "define internal i1 @less_than_literal");
    try expectContains(less_body, "fcmp olt float %mc_arg_0, bitcast (i32 1069547520 to float)");
    try expectContains(less_body, "ret i1 %mc_expr_tmp_");
    try expectNotContains(less_body, "alloca");
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

fn clearIntegerFactsForFunction(module_mir: *mir.Module, name: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        if (function.integer_facts.len != 0) module_mir.allocator.free(function.integer_facts);
        function.integer_facts = try module_mir.allocator.alloc(mir.IntegerFact, 0);
        return;
    }
    return error.TestUnexpectedResult;
}

fn clearConstGetFactsForFunction(module_mir: *mir.Module, name: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        if (function.const_get_facts.len != 0) module_mir.allocator.free(function.const_get_facts);
        function.const_get_facts = try module_mir.allocator.alloc(mir.ConstGetFact, 0);
        return;
    }
    return error.TestUnexpectedResult;
}

fn retargetConstGetFactForFunction(module_mir: *mir.Module, name: []const u8, index: usize) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        if (function.const_get_facts.len != 1) return error.TestUnexpectedResult;
        function.const_get_facts[0].index = index;
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

fn removeTargetTypeKindForFunction(module_mir: *mir.Module, name: []const u8, kind: mir.TargetTypeKind) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        var retained_count: usize = 0;
        for (function.target_type_facts) |fact| {
            if (fact.kind != kind) retained_count += 1;
        }
        if (retained_count == function.target_type_facts.len) return error.TestUnexpectedResult;
        const retained = try module_mir.allocator.alloc(mir.TargetTypeFact, retained_count);
        var index: usize = 0;
        for (function.target_type_facts) |fact| {
            if (fact.kind == kind) continue;
            retained[index] = fact;
            index += 1;
        }
        if (function.target_type_facts.len != 0) module_mir.allocator.free(function.target_type_facts);
        function.target_type_facts = retained;
        return;
    }
    return error.TestUnexpectedResult;
}

fn renameTargetTypeFactForFunction(module_mir: *mir.Module, name: []const u8, kind: mir.TargetTypeKind, target_name: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        for (function.target_type_facts) |*fact| {
            if (fact.kind != kind) continue;
            fact.target_ty = .{ .span = fact.target_ty.span, .kind = .{ .name = .{ .text = target_name, .span = fact.target_ty.span } } };
            return;
        }
        return error.TestUnexpectedResult;
    }
    return error.TestUnexpectedResult;
}

fn retargetTargetTypeResultForFunction(module_mir: *mir.Module, name: []const u8, kind: mir.TargetTypeKind, result_ty: mir.ValueType) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        var fact_count: usize = 0;
        for (function.target_type_facts) |*fact| {
            if (fact.kind != kind) continue;
            fact.result_ty = result_ty;
            fact_count += 1;
        }
        var instruction_count: usize = 0;
        for (function.blocks) |*block| {
            for (block.instructions) |*instruction| {
                if (instruction.kind != .target_type) continue;
                if (!std.mem.eql(u8, instruction.detail, @tagName(kind))) continue;
                instruction.result_ty = result_ty;
                instruction_count += 1;
            }
        }
        if (fact_count == 0 or instruction_count == 0) return error.TestUnexpectedResult;
        return;
    }
    return error.TestUnexpectedResult;
}

fn renameTargetTypeFactAtOffsetForFunction(module_mir: *mir.Module, name: []const u8, kind: mir.TargetTypeKind, source_offset: usize, source_len: usize, target_name: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        for (function.target_type_facts) |*fact| {
            if (fact.kind != kind or fact.source.offset != source_offset or fact.source.len != source_len) continue;
            fact.target_ty = .{ .span = fact.target_ty.span, .kind = .{ .name = .{ .text = target_name, .span = fact.target_ty.span } } };
            return;
        }
        return error.TestUnexpectedResult;
    }
    return error.TestUnexpectedResult;
}

fn retargetPointerMutabilityFactAtOffsetForFunction(module_mir: *mir.Module, name: []const u8, kind: mir.TargetTypeKind, source_offset: usize, source_len: usize, mutability: ast.Mutability) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        for (function.target_type_facts) |*fact| {
            if (fact.kind != kind or fact.source.offset != source_offset or fact.source.len != source_len) continue;
            const pointer = switch (fact.target_ty.kind) {
                .pointer => |node| node,
                else => return error.TestUnexpectedResult,
            };
            fact.target_ty.kind = .{ .pointer = .{ .mutability = mutability, .child = pointer.child } };
            return;
        }
        return error.TestUnexpectedResult;
    }
    return error.TestUnexpectedResult;
}

fn retargetAggregateConstructionForFunction(module_mir: *mir.Module, name: []const u8, construction: ?mir.AggregateConstructionKind) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        for (function.target_type_facts) |*fact| {
            if (fact.kind != .struct_literal) continue;
            fact.aggregate_construction = construction;
            return;
        }
        return error.TestUnexpectedResult;
    }
    return error.TestUnexpectedResult;
}

fn removeTargetTypeFactAtOffsetForFunction(module_mir: *mir.Module, name: []const u8, kind: mir.TargetTypeKind, source_offset: usize, source_len: usize) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        var retained_count: usize = 0;
        var removed = false;
        for (function.target_type_facts) |fact| {
            if (fact.kind == kind and fact.source.offset == source_offset and fact.source.len == source_len) {
                removed = true;
            } else {
                retained_count += 1;
            }
        }
        if (!removed) return error.TestUnexpectedResult;
        const retained = try module_mir.allocator.alloc(mir.TargetTypeFact, retained_count);
        var index: usize = 0;
        for (function.target_type_facts) |fact| {
            if (fact.kind == kind and fact.source.offset == source_offset and fact.source.len == source_len) continue;
            retained[index] = fact;
            index += 1;
        }
        if (function.target_type_facts.len != 0) module_mir.allocator.free(function.target_type_facts);
        function.target_type_facts = retained;
        return;
    }
    return error.TestUnexpectedResult;
}

test "LLVM rejects prebuilt MIR with missing target type facts" {
    const source =
        \\enum E { bad }
        \\fn make(value: u32) -> Result<u32, E> { return ok(value); }
        \\fn make_err() -> Result<u32, E> { return err(.bad); }
    ;
    var parsed = try test_support.parseCheckedModule("llvm_missing_target_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_result_constructor_target_type_facts.mc", source, &complete_output);

    try clearTargetTypeFactsForFunction(&module_mir, "make");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_missing_target_type_facts.mc", .{}, false, .riscv64, null));
}

test "LLVM Result constructors require MIR call target facts" {
    const source =
        \\enum E { bad }
        \\fn make(value: u32) -> Result<u32, E> { return ok(value); }
        \\fn forward(value: Result<u32, E>) -> Result<u32, E> { return ok(value?); }
    ;
    var parsed = try test_support.parseCheckedModule("llvm_result_constructor_call_facts.mc", source);
    defer parsed.deinit();
    for ([_][]const u8{ "make", "forward" }) |name| {
        var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer module_mir.deinit();
        try clearCallTargetFactsForFunction(&module_mir, name);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirCallTargetFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_result_constructor_call_facts.mc", .{}, false, .riscv64, null));
    }
}

test "LLVM bind closures require MIR call target facts" {
    const source =
        \\fn add_scalar(env: u32, value: u32) -> u32 { return env + value; }
        \\fn make() -> closure(u32) -> u32 { return (bind(3, add_scalar)); }
    ;
    var parsed = try test_support.parseCheckedModule("llvm_bind_call_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "make");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirCallTargetFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_bind_call_facts.mc", .{}, false, .riscv64, null));
}

test "LLVM rejects missing tagged-union target type facts" {
    const source =
        \\union Token { number: i64, eof }
        \\fn make() -> Token { return number(7); }
    ;
    var parsed = try test_support.parseCheckedModule("llvm_missing_union_target_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "make");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_missing_union_target_type_facts.mc", .{}, false, .riscv64, null));
}

test "LLVM rejects missing enum-literal target type facts" {
    const source =
        \\enum Mode: u8 { read = 1, write = 2 }
        \\fn make() -> Mode { return .read; }
    ;
    var parsed = try test_support.parseCheckedModule("llvm_missing_enum_target_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "make");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_missing_enum_target_type_facts.mc", .{}, false, .riscv64, null));
}

test "LLVM rejects missing string-literal target type facts" {
    const source =
        \\fn text() -> *const u8 { return "text"; }
    ;
    var parsed = try test_support.parseCheckedModule("llvm_missing_string_target_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "text");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_missing_string_target_type_facts.mc", .{}, false, .riscv64, null));
}

test "LLVM rejects missing aggregate-literal target type facts" {
    const source =
        \\struct Pair { left: u32, right: u32 }
        \\fn pair() -> Pair { return .{ .left = 1, .right = 2 }; }
    ;
    var parsed = try test_support.parseCheckedModule("llvm_missing_aggregate_target_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "pair");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_missing_aggregate_target_type_facts.mc", .{}, false, .riscv64, null));
}

test "LLVM struct literal construction class is MIR-owned" {
    const source =
        \\struct Pair { left: u32, right: u32 }
        \\packed bits Flags: u8 { ready: bool }
        \\#[c_union]
        \\struct CWord { word: u32, byte: u8 }
        \\fn pair() -> Pair { return .{ .left = 1, .right = 2 }; }
        \\fn flags() -> Flags { return .{ .ready = true }; }
        \\fn c_word() -> CWord { return .{ .word = 7, .byte = uninit }; }
    ;
    var parsed = try test_support.parseCheckedModule("llvm_aggregate_construction_fact.mc", source);
    defer parsed.deinit();
    var valid_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer valid_mir.deinit();
    var valid_output: std.ArrayList(u8) = .empty;
    defer valid_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &valid_mir, &valid_output, "llvm_aggregate_construction_fact.mc", .{}, false, .riscv64, null);

    for ([_]?mir.AggregateConstructionKind{ null, .packed_bits }) |stale| {
        var stale_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer stale_mir.deinit();
        try retargetAggregateConstructionForFunction(&stale_mir, "pair", stale);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_mir, &output, "llvm_aggregate_construction_fact.mc", .{}, false, .riscv64, null));
    }
}

test "LLVM rejects missing float-literal target type facts" {
    const source =
        \\fn value() -> f32 { return 1.25; }
    ;
    var parsed = try test_support.parseCheckedModule("llvm_missing_float_target_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "value");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_missing_float_target_type_facts.mc", .{}, false, .riscv64, null));
}

test "LLVM rejects missing null and value-optional target type facts" {
    const source =
        \\fn present(value: u32) -> ?u32 { return value; }
        \\fn absent() -> ?u32 { return null; }
    ;
    var parsed = try test_support.parseCheckedModule("llvm_missing_optional_target_type_facts.mc", source);
    defer parsed.deinit();
    for ([_][]const u8{ "present", "absent" }) |name| {
        var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, name);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_missing_optional_target_type_facts.mc", .{}, false, .riscv64, null));
    }
}

test "LLVM rejects missing dyn-coercion target type facts" {
    const source =
        \\trait Shape { fn area(self: *Self) -> u32; }
        \\struct Square { side: u32 }
        \\impl Shape for Square { fn area(self: *Square) -> u32 { return self.side; } }
        \\fn as_dyn(value: *Square) -> *dyn Shape { return value; }
    ;
    var parsed = try test_support.parseCheckedModule("llvm_missing_dyn_target_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "as_dyn");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_missing_dyn_target_type_facts.mc", .{}, false, .riscv64, null));
}

test "LLVM consumes f32 and f64 literal target type facts" {
    const source =
        \\global small: f32 = 1.25;
        \\global wide: f64 = 1.25;
        \\fn product() -> f32 { return 1.7 * 2.3; }
        \\fn wide_value() -> f64 { return 2.5; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_float_target_type_facts.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "@small = internal global float") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "@wide = internal global double") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "fmul float") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "define internal double @wide_value") != null);
}

test "LLVM consumes enum-literal target type facts across contexts" {
    const source =
        \\enum Mode: u8 { read = 1, write = 2 }
        \\extern fn sink(mode: Mode) -> Mode;
        \\global global_mode: Mode = .read;
        \\fn make() -> Mode { return .read; }
        \\fn pass() -> Mode { return sink(.write); }
        \\fn compare(mode: Mode) -> bool { return mode == .read; }
        \\fn cast_mode() -> Mode { return .write as Mode; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_enum_target_type_facts.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "@global_mode = internal global i8 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "ret i8 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "@sink(i8 2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "icmp eq i8") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "ret i8 2") != null);
}

test "LLVM consumes tagged-union target type facts without function-name collisions" {
    const source =
        \\union Token { number: i64, eof, ok: u32 }
        \\fn number(value: i64) -> Token { return Token.number(value); }
        \\fn make_number() -> Token { return number(11); }
        \\fn make_eof() -> Token { return eof(); }
        \\fn make_ok_case() -> Token { return ok(12); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_union_target_type_facts.mc", source, &output);
    try expectContainsAny(output.items, &.{ "zext i32 11 to i64", "@number(i64 11)" });
    try expectContainsAny(output.items, &.{ "@number(i64 %", "@number(i64 11)" });
    try std.testing.expect(std.mem.indexOf(u8, output.items, "store i32 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "store i32 2") != null);
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

test "LLVM conversion builtins require exact MIR call-target facts" {
    const source =
        \\fn convert(x: u64) -> u8 { return u8.trap_from(x); }
    ;
    var parsed = try test_support.parseCheckedModule("llvm_conversion_call_target_facts.mc", source);
    defer parsed.deinit();

    var missing_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_mir.deinit();
    try clearCallTargetFactsForFunction(&missing_mir, "convert");
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirCallTargetFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_mir, &missing_output, "llvm_conversion_call_target_facts.mc", .{}, false, .riscv64, null));

    var stale_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale_mir.deinit();
    try retargetCallTargetFactsForFunction(&stale_mir, "convert", .conversion_sat_from);
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirCallTargetFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_mir, &stale_output, "llvm_conversion_call_target_facts.mc", .{}, false, .riscv64, null));

    var missing_types_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_types_mir.deinit();
    try clearTargetTypeFactsForFunction(&missing_types_mir, "convert");
    var missing_types_output: std.ArrayList(u8) = .empty;
    defer missing_types_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_types_mir, &missing_types_output, "llvm_conversion_call_target_facts.mc", .{}, false, .riscv64, null));
}

test "LLVM conversion literal source type comes from MIR" {
    const source =
        \\type W = wrap<u8>;
        \\fn convert() -> W { return W.from_mod(300); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_conversion_literal_source_type.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "trunc i32 300 to i8") != null);
}

test "LLVM negative integer literal uses the MIR unary result type" {
    const source =
        \\fn negative_one() -> i32 { return -1; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_negative_integer_literal_return.mc", source, &output);
    try expectContains(output.items, "ret i32 -1");
}

test "LLVM explicit casts require MIR source and target type facts" {
    const source =
        \\fn widen(value: u32) -> u64 { return value as u64; }
    ;
    const cast_text = "value as u64";
    const cast_offset = std.mem.indexOf(u8, source, cast_text) orelse return error.TestUnexpectedResult;
    var parsed = try test_support.parseCheckedModule("llvm_explicit_cast_type_facts.mc", source);
    defer parsed.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_explicit_cast_type_facts.mc", source, &complete_output);
    try expectContains(complete_output.items, "zext i32 ");
    try expectContains(complete_output.items, " to i64");

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "widen");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_explicit_cast_type_facts.mc", .{}, false, .riscv64, null));

    var missing_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_result.deinit();
    try removeTargetTypeFactAtOffsetForFunction(&missing_result, "widen", .expression_result, cast_offset, cast_text.len);
    var missing_result_output: std.ArrayList(u8) = .empty;
    defer missing_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_result, &missing_result_output, "llvm_explicit_cast_type_facts.mc", .{}, false, .riscv64, null));

    var stale_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale_result.deinit();
    try renameTargetTypeFactAtOffsetForFunction(&stale_result, "widen", .expression_result, cast_offset, cast_text.len, "u32");
    var stale_result_output: std.ArrayList(u8) = .empty;
    defer stale_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_result, &stale_result_output, "llvm_explicit_cast_type_facts.mc", .{}, false, .riscv64, null));
}

test "LLVM local and assigned explicit casts lower from MIR without body fallback" {
    const source =
        \\fn local_cast(value: u32) -> u64 {
        \\    let widened = value as u64;
        \\    return widened;
        \\}
        \\fn assigned_cast(value: u32) -> u64 {
        \\    var widened: u64 = 0;
        \\    widened = value as u64;
        \\    return widened;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_local_assigned_explicit_cast_return.mc", source, &output);

    const local_body = try llvmFunctionBody(output.items, "define internal i64 @local_cast");
    try expectContains(local_body, "zext i32 ");
    try expectContains(local_body, " to i64");
    try expectContains(local_body, "ret i64 %");
    if (std.mem.indexOf(u8, local_body, "; canonical executable MIR") == null) {
        try expectNotContains(local_body, "alloca");
        try expectNotContains(local_body, "store");
    }

    const assigned_body = try llvmFunctionBody(output.items, "define internal i64 @assigned_cast");
    try expectContains(assigned_body, "zext i32 ");
    try expectContains(assigned_body, " to i64");
    try expectContains(assigned_body, "ret i64 %");
    if (std.mem.indexOf(u8, assigned_body, "; canonical executable MIR") == null) {
        try expectNotContains(assigned_body, "alloca");
        try expectNotContains(assigned_body, "store");
    }
}

test "LLVM local and assigned conversion calls lower from MIR without body fallback" {
    const source =
        \\fn local_conversion(value: u64) -> u8 {
        \\    let narrowed = u8.wrap_from(value);
        \\    return narrowed;
        \\}
        \\fn assigned_conversion(value: u64) -> u8 {
        \\    var narrowed: u8 = 0;
        \\    narrowed = u8.wrap_from(value);
        \\    return narrowed;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_local_assigned_conversion_return.mc", source, &output);

    const local_body = try llvmFunctionBody(output.items, "define internal i8 @local_conversion");
    try expectContains(local_body, "; canonical executable MIR");
    try expectContains(local_body, "trunc i64 %mc_arg_0 to i8");
    try expectContains(local_body, "ret i8 %mc_expr_tmp_");

    const assigned_body = try llvmFunctionBody(output.items, "define internal i8 @assigned_conversion");
    try expectContains(assigned_body, "; canonical executable MIR");
    try expectContains(assigned_body, "trunc i64 %mc_arg_0 to i8");
    try expectContains(assigned_body, "ret i8 %mc_expr_tmp_");
}

test "LLVM implicit view const narrowing requires MIR source and target type facts" {
    const source =
        \\fn narrow(xs: []mut u8) -> []const u8 { return xs; }
    ;
    var parsed = try test_support.parseCheckedModule("llvm_view_const_narrow_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "narrow");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_view_const_narrow_type_facts.mc", .{}, false, .riscv64, null));
}

test "LLVM self-typed union and enum paths require MIR result type facts" {
    const source =
        \\enum E { first, second }
        \\union Token { number: i64, eof }
        \\fn make(value: i64) -> Token { return Token.number(value); }
        \\fn variant() -> E { return E.second; }
    ;
    var parsed = try test_support.parseCheckedModule("llvm_self_typed_expression_facts.mc", source);
    defer parsed.deinit();
    for ([_][]const u8{ "make", "variant" }) |name| {
        var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, name);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_self_typed_expression_facts.mc", .{}, false, .riscv64, null));
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

fn appendLlvmTestWithoutPointerProvenanceFacts(source_name: []const u8, source: []const u8, function_names: []const []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseModule(source_name, source);
    defer parsed.deinit();

    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    for (function_names) |function_name| {
        try clearPointerProvenanceFactsForFunction(&module_mir, function_name);
    }

    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, output, source_name, .{}, false, .riscv64, null);
}

fn appendLlvmTestWithoutRangeFacts(source_name: []const u8, source: []const u8, function_names: []const []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseModule(source_name, source);
    defer parsed.deinit();

    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    for (function_names) |function_name| {
        try clearRangeFactsForFunction(&module_mir, function_name);
    }

    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, output, source_name, .{}, false, .riscv64, null);
}

test "LLVM canonical executable body does not depend on legacy bounds facts" {
    const source =
        \\fn bounds_fact_gate(a: [2]u32, i: usize) -> u32 {
        \\    return a[i];
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_missing_bounds_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try clearBoundsFactsForFunction(&module_mir, "bounds_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_missing_bounds_facts.mc", .{}, false, .riscv64, null);
    try expectContains(output.items, "; canonical executable MIR");
}

test "LLVM rejects prebuilt MIR with missing representation facts" {
    const source =
        \\fn representation_fact_gate(p: *mut u32) -> u32 {
        \\    unsafe { return p.*; }
        \\}
    ;

    var parsed = try test_support.parseModule("llvm_missing_representation_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearRepresentationFactsForFunction(&module_mir, "representation_fact_gate");

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirRepresentationFacts,
        appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_missing_representation_facts.mc", .{}, false, .riscv64, null),
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
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try retargetRepresentationFactsForFunction(&module_mir, "representation_fact_gate", "stale_value");

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirRepresentationFacts,
        appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_stale_representation_facts.mc", .{}, false, .riscv64, null),
    );
}

test "LLVM rejects prebuilt MIR with extra stale representation facts" {
    const source =
        \\fn representation_fact_gate(p: *mut u32) -> u32 {
        \\    unsafe { return p.*; }
        \\}
    ;

    var parsed = try test_support.parseModule("llvm_extra_stale_representation_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try appendStaleRepresentationFactForFunction(&module_mir, "representation_fact_gate", "extra_stale_value");

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirRepresentationFacts,
        appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_extra_stale_representation_facts.mc", .{}, false, .riscv64, null),
    );
}

test "LLVM rejects prebuilt MIR with missing Result try payload representation facts" {
    const source =
        \\extern fn make_result_pointer() -> Result<*mut u8, Error>;
        \\
        \\fn result_try_payload_representation_gate() -> *mut u8 {
        \\    return make_result_pointer()?;
        \\}
    ;

    var parsed = try test_support.parseModule("llvm_missing_result_try_payload_representation_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearRepresentationFactsForFunction(&module_mir, "result_try_payload_representation_gate");

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirRepresentationFacts,
        appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_missing_result_try_payload_representation_facts.mc", .{}, false, .riscv64, null),
    );
}

test "LLVM rejects prebuilt MIR with stale Result try payload representation facts" {
    const source =
        \\extern fn make_result_pointer() -> Result<*mut u8, Error>;
        \\
        \\fn result_try_payload_representation_gate() -> *mut u8 {
        \\    return make_result_pointer()?;
        \\}
    ;

    var parsed = try test_support.parseModule("llvm_stale_result_try_payload_representation_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try retargetRepresentationFactsForFunction(&module_mir, "result_try_payload_representation_gate", "stale_try_payload");

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirRepresentationFacts,
        appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_stale_result_try_payload_representation_facts.mc", .{}, false, .riscv64, null),
    );
}

test "LLVM rejects prebuilt MIR with missing integer facts" {
    const source =
        \\fn integer_fact_gate() -> u8 {
        \\    let a: u8 = 7;
        \\    return a;
        \\}
    ;

    var parsed = try test_support.parseModule("llvm_missing_integer_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_integer_fact_gate.mc", source, &complete_output);

    try clearIntegerFactsForFunction(&module_mir, "integer_fact_gate");

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirIntegerFacts,
        appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_missing_integer_facts.mc", .{}, false, .riscv64, null),
    );
}

test "LLVM rejects prebuilt MIR with missing call target facts" {
    const source =
        \\fn call_target_fact_gate(xs: []const u32) -> Result<u32, Overflow> {
        \\    return reduce.sum_checked<u32>(xs);
        \\}
    ;

    var parsed = try test_support.parseModule("llvm_missing_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_missing_call_target_facts.mc", .{}, false, .riscv64, null),
    );
}

test "LLVM rejects prebuilt MIR with missing reflection call target facts" {
    const source =
        \\fn reflection_call_target_fact_gate() -> usize {
        \\    return size_of<u32>();
        \\}
    ;

    var parsed = try test_support.parseModule("llvm_missing_reflection_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "reflection_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_missing_reflection_call_target_facts.mc", .{}, false, .riscv64, null),
    );
}

test "LLVM rejects prebuilt MIR with missing byte-view call target facts" {
    const source =
        \\fn byte_view_call_target_fact_gate(left: []const u8, right: []const u8) -> bool {
        \\    return mem.bytes_equal(left, right);
        \\}
    ;

    var parsed = try test_support.parseModule("llvm_missing_byte_view_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "byte_view_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_missing_byte_view_call_target_facts.mc", .{}, false, .riscv64, null),
    );
}

test "LLVM reflection and complete byte-view types require MIR target facts" {
    const source =
        \\extern struct Packet { len: u16, tag: u8 }
        \\enum Mode: u8 { normal = 0 }
        \\fn reflected_size() -> usize { return size_of<Packet>(); }
        \\fn reflected_alignment() -> usize { return alignof<Packet>(); }
        \\fn reflected_field_offset() -> usize { return field_offset<Packet>(.tag); }
        \\fn reflected_bit_offset() -> usize { return bit_offset<Packet>(.tag); }
        \\fn reflected_repr() -> usize { return repr_of<Mode>(); }
        \\fn view(value: u32) -> []const u8 { return mem.as_bytes(&value); }
        \\fn equal(left: []const u8, right: []const u8) -> bool { return mem.bytes_equal(left, right); }
    ;
    var parsed = try test_support.parseModule("llvm_reflection_byte_view_type_facts.mc", source);
    defer parsed.deinit();
    for ([_][]const u8{ "reflected_size", "reflected_alignment", "reflected_field_offset", "reflected_bit_offset", "reflected_repr", "view", "equal" }) |name| {
        var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, name);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_reflection_byte_view_type_facts.mc", .{}, false, .riscv64, null));
    }
}

test "LLVM rejects prebuilt MIR with missing semantic escape call target facts" {
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

    var parsed = try test_support.parseModule("llvm_missing_semantic_escape_call_target_facts.mc", source);
    defer parsed.deinit();

    var reveal_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer reveal_mir.deinit();
    try clearCallTargetFactsForFunction(&reveal_mir, "reveal_fact_gate");
    var reveal_output: std.ArrayList(u8) = .empty;
    defer reveal_output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &reveal_mir, &reveal_output, "llvm_missing_semantic_escape_call_target_facts.mc", .{}, false, .riscv64, null),
    );

    var noalias_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer noalias_mir.deinit();
    try clearCallTargetFactsForFunction(&noalias_mir, "noalias_fact_gate");
    var noalias_output: std.ArrayList(u8) = .empty;
    defer noalias_output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &noalias_mir, &noalias_output, "llvm_missing_semantic_escape_call_target_facts.mc", .{}, false, .riscv64, null),
    );
}

test "LLVM semantic escape types require MIR target facts" {
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
    var parsed = try test_support.parseModule("llvm_semantic_escape_target_type_facts.mc", source);
    defer parsed.deinit();
    for ([_][]const u8{ "reveal_type_gate", "noalias_type_gate" }) |name| {
        var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, name);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_semantic_escape_target_type_facts.mc", .{}, false, .riscv64, null));
    }
}

test "LLVM executable MIR forget evaluates its operand once without a release call" {
    const source =
        \\linear struct Token { id: u32 }
        \\fn next_value() -> u32 { return 41; }
        \\fn forget_token(token: Token) -> void {
        \\    unsafe { forget_unchecked(token); }
        \\}
        \\fn forget_result() -> u32 {
        \\    unsafe { forget_unchecked(next_value()); }
        \\    return 42;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_discard_value.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "@forget_result");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "call i32 @next_value()"));
    try std.testing.expect(std.mem.indexOf(u8, body, "forget_unchecked(") == null);
    const token_body = try llvmFunctionBody(output.items, "@forget_token");
    try std.testing.expect(std.mem.indexOf(u8, token_body, "; canonical executable MIR") != null);
    try std.testing.expect(std.mem.indexOf(u8, token_body, "forget_unchecked(") == null);
}

test "LLVM rejects auto-drop transfer authorization with stale MIR resource type" {
    const source =
        \\move struct Guard { id: u32 }
        \\fn make_guard() -> Guard { return .{ .id = 1 }; }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void { g.id = 0; }
        \\fn transfer_auto_drop() -> Guard {
        \\    var g: Guard = make_guard();
        \\    return move g;
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_drop_attr_transfer_stale_resource.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const stale_resource_symbol = for (module_mir.functions) |function| {
        if (std.mem.eql(u8, function.name, "make_guard")) break function.typed_symbol_id;
    } else return error.TestUnexpectedResult;
    const transfer_function = for (module_mir.functions) |*function| {
        if (std.mem.eql(u8, function.name, "transfer_auto_drop")) break function;
    } else return error.TestUnexpectedResult;
    for (transfer_function.ownership_events) |*event| {
        if (event.kind == .move_out) {
            event.place.root_type_symbol_id = stale_resource_symbol;
            break;
        }
    } else return error.TestUnexpectedResult;
    try mir.validateLoweringAdmission(module_mir);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_drop_attr_transfer_stale_resource.mc", .{}, false, .riscv64, null));
}

test "LLVM move auto-drop cancellation requires MIR move-out event" {
    const source =
        \\move struct Guard { id: u32 }
        \\fn make_guard() -> Guard { return .{ .id = 1 }; }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void { g.id = 0; }
        \\fn transfer_auto_drop() -> Guard {
        \\    var g: Guard = make_guard();
        \\    return move g;
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_drop_attr_transfer_requires_move_out.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const drop_glue = module_mir.drop_glue_facts[0];
    const function = for (module_mir.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "transfer_auto_drop")) break candidate;
    } else return error.TestUnexpectedResult;
    const generated_events = function.ownership_events;
    var move_index: usize = 0;
    while (move_index < generated_events.len and generated_events[move_index].kind != .move_out) : (move_index += 1) {}
    if (move_index == generated_events.len) return error.TestUnexpectedResult;

    const events = try std.testing.allocator.alloc(mir.OwnershipEvent, generated_events.len + 1);
    @memcpy(events[0 .. move_index + 1], generated_events[0 .. move_index + 1]);
    events[move_index].kind = .auto_drop;
    events[move_index].drop_glue_symbol_id = drop_glue.typed_release_symbol_id;
    events[move_index + 1] = generated_events[move_index];
    events[move_index + 1].kind = .storage_dead;
    events[move_index + 1].drop_glue_symbol_id = .invalid;
    @memcpy(events[move_index + 2 ..], generated_events[move_index + 1 ..]);
    function.ownership_events = events;
    std.testing.allocator.free(generated_events);
    try mir.validateLoweringAdmission(module_mir);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_drop_attr_transfer_requires_move_out.mc", .{}, false, .riscv64, null));
}

test "LLVM move auto-drop cancellation requires source-matched MIR move-out event" {
    const source =
        \\move struct Guard { id: u32 }
        \\fn make_guard() -> Guard { return .{ .id = 1 }; }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void { g.id = 0; }
        \\fn transfer_auto_drop() -> Guard {
        \\    var g: Guard = make_guard();
        \\    return move g;
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_drop_attr_transfer_move_out_source.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const function = for (module_mir.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "transfer_auto_drop")) break candidate;
    } else return error.TestUnexpectedResult;
    for (function.ownership_events) |*event| {
        if (event.kind == .move_out) {
            event.source.line += 1;
            break;
        }
    } else return error.TestUnexpectedResult;
    try mir.validateLoweringAdmission(module_mir);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_drop_attr_transfer_move_out_source.mc", .{}, false, .riscv64, null));
}

test "LLVM deferred drop release requires source-matched MIR explicit-drop event" {
    const source =
        \\move struct Ticket { id: u32 }
        \\fn issue_ticket() -> Ticket { return .{ .id = 1 }; }
        \\#[drop]
        \\fn close_ticket(t: *mut Ticket) -> void { t.id = 0; }
        \\fn accept_deferred_resource_release() -> void {
        \\    var t: Ticket = issue_ticket();
        \\    defer close_ticket(&t);
        \\    return;
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_drop_attr_defer_source_requires_event.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const function = for (module_mir.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "accept_deferred_resource_release")) break candidate;
    } else return error.TestUnexpectedResult;
    for (function.ownership_events) |*event| {
        if (event.kind == .explicit_drop) {
            event.source.line += 1;
            break;
        }
    } else return error.TestUnexpectedResult;
    try mir.validateLoweringAdmission(module_mir);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_drop_attr_defer_source_requires_event.mc", .{}, false, .riscv64, null));
}

test "LLVM ordinary defer requires source-matched MIR cleanup marker" {
    const source =
        \\extern fn close_a() -> void;
        \\fn ordinary_defer_marker() -> void {
        \\    defer close_a();
        \\    return;
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_ordinary_defer_requires_marker.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const function = for (module_mir.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "ordinary_defer_marker")) break candidate;
    } else return error.TestUnexpectedResult;
    for (function.blocks) |*block| {
        for (block.instructions) |*instruction| {
            if (instruction.kind == .defer_cleanup) {
                instruction.line += 1;
                break;
            }
        } else continue;
        break;
    } else return error.TestUnexpectedResult;
    try mir.validateLoweringAdmission(module_mir);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMir, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_ordinary_defer_requires_marker.mc", .{}, false, .riscv64, null));
}

test "LLVM ordinary defer rejects unsupported expression fallback" {
    const source =
        \\fn ordinary_defer_expression_fallback(x: u32) -> void {
        \\    defer x + 1;
        \\    return;
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_ordinary_defer_expression_fallback.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try mir.validateLoweringAdmission(module_mir);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_ordinary_defer_expression_fallback.mc", .{}, false, .riscv64, null));
}

test "LLVM canonical ordinary defer ignores legacy call spelling" {
    const source =
        \\extern fn close_a() -> void;
        \\fn ordinary_defer_call_marker() -> void {
        \\    defer close_a();
        \\    return;
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_ordinary_defer_requires_call_marker.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const function = for (module_mir.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "ordinary_defer_call_marker")) break candidate;
    } else return error.TestUnexpectedResult;
    for (function.blocks) |*block| {
        for (block.instructions) |*instruction| {
            if (instruction.kind == .call and std.mem.eql(u8, instruction.detail, "close_a")) {
                instruction.detail = "other_close";
                break;
            }
        } else continue;
        break;
    } else return error.TestUnexpectedResult;
    try mir.validateLoweringAdmission(module_mir);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_ordinary_defer_requires_call_marker.mc", .{}, false, .riscv64, null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "call void @close_a()") != null);
}

test "LLVM canonical ordinary defer with arguments ignores legacy call spelling" {
    const source =
        \\extern fn takes_u32(value: u32) -> void;
        \\fn ordinary_defer_arg_call_marker(x: u32) -> void {
        \\    defer takes_u32(x);
        \\    return;
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_ordinary_defer_arg_requires_call_marker.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const function = for (module_mir.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "ordinary_defer_arg_call_marker")) break candidate;
    } else return error.TestUnexpectedResult;
    for (function.blocks) |*block| {
        for (block.instructions) |*instruction| {
            if (instruction.kind == .call and std.mem.eql(u8, instruction.detail, "takes_u32")) {
                instruction.detail = "other_takes_u32";
                break;
            }
        } else continue;
        break;
    } else return error.TestUnexpectedResult;
    try mir.validateLoweringAdmission(module_mir);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_ordinary_defer_arg_requires_call_marker.mc", .{}, false, .riscv64, null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "call void @takes_u32(") != null);
}

test "LLVM canonical ordinary defer with arguments ignores legacy argument facts" {
    const source =
        \\extern fn takes_u32(value: u32) -> void;
        \\fn ordinary_defer_arg_fact(x: u32) -> void {
        \\    defer takes_u32(x);
        \\    return;
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_ordinary_defer_arg_requires_fact.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const function = for (module_mir.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "ordinary_defer_arg_fact")) break candidate;
    } else return error.TestUnexpectedResult;
    for (function.blocks) |*block| {
        for (block.instructions) |*instruction| {
            if (instruction.kind == .target_type and std.mem.eql(u8, instruction.detail, "direct_call_argument") and instruction.target_index == 0) {
                instruction.target_index = 7;
                break;
            }
        } else continue;
        break;
    } else return error.TestUnexpectedResult;
    for (function.target_type_facts) |*fact| {
        if (fact.kind == .direct_call_argument and fact.target_index == 0) {
            fact.target_index = 7;
            break;
        }
    } else return error.TestUnexpectedResult;
    try mir.validateLoweringAdmission(module_mir);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_ordinary_defer_arg_requires_fact.mc", .{}, false, .riscv64, null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "call void @takes_u32(") != null);
}

test "LLVM ordinary direct defer with discarded result requires MIR result fact" {
    const source =
        \\extern fn record(value: u32) -> u32;
        \\fn ordinary_defer_result_fact(x: u32) -> void {
        \\    defer record(x);
        \\    return;
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_ordinary_defer_result_requires_fact.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const function = for (module_mir.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "ordinary_defer_result_fact")) break candidate;
    } else return error.TestUnexpectedResult;
    _ = function;
    try mir.validateLoweringAdmission(module_mir);
    var drifted_callee_span = false;
    for (parsed.decls()) |*decl| switch (decl.kind) {
        .fn_decl => |*fn_decl| {
            if (!std.mem.eql(u8, fn_decl.name.text, "ordinary_defer_result_fact")) continue;
            const body = fn_decl.body orelse return error.TestUnexpectedResult;
            for (body.items) |*stmt| switch (stmt.kind) {
                .@"defer" => |*defer_expr| switch (defer_expr.kind) {
                    .call => |*call| {
                        call.callee.*.span.line += 1;
                        drifted_callee_span = true;
                    },
                    else => return error.TestUnexpectedResult,
                },
                else => {},
            };
        },
        else => {},
    };
    if (!drifted_callee_span) return error.TestUnexpectedResult;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_ordinary_defer_result_requires_fact.mc", .{}, false, .riscv64, null));
}

test "LLVM ordinary call-target defer requires MIR call-target fact" {
    const source =
        \\fn ordinary_defer_call_target_fact() -> void {
        \\    defer fence.release();
        \\    return;
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_ordinary_defer_call_target_requires_fact.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try mir.validateLoweringAdmission(module_mir);
    var drifted_callee_span = false;
    for (parsed.decls()) |*decl| switch (decl.kind) {
        .fn_decl => |*fn_decl| {
            if (!std.mem.eql(u8, fn_decl.name.text, "ordinary_defer_call_target_fact")) continue;
            const body = fn_decl.body orelse return error.TestUnexpectedResult;
            for (body.items) |*stmt| switch (stmt.kind) {
                .@"defer" => |*defer_expr| switch (defer_expr.kind) {
                    .call => |*call| {
                        call.callee.*.span.line += 1;
                        drifted_callee_span = true;
                    },
                    else => return error.TestUnexpectedResult,
                },
                else => {},
            };
        },
        else => {},
    };
    if (!drifted_callee_span) return error.TestUnexpectedResult;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_ordinary_defer_call_target_requires_fact.mc", .{}, false, .riscv64, null));
}

test "LLVM ordinary raw-store defer requires MIR target facts" {
    const source =
        \\fn ordinary_defer_raw_store_fact(addr: PAddr, value: u32) -> void {
        \\    unsafe {
        \\        defer raw.store<u32>(addr, value);
        \\    }
        \\    return;
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_ordinary_defer_raw_store_requires_fact.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try mir.validateLoweringAdmission(module_mir);
    var drifted_call_span = false;
    for (parsed.decls()) |*decl| switch (decl.kind) {
        .fn_decl => |*fn_decl| {
            if (!std.mem.eql(u8, fn_decl.name.text, "ordinary_defer_raw_store_fact")) continue;
            const body = fn_decl.body orelse return error.TestUnexpectedResult;
            for (body.items) |*stmt| switch (stmt.kind) {
                .unsafe_block => |*unsafe_block| {
                    for (unsafe_block.items) |*unsafe_stmt| switch (unsafe_stmt.kind) {
                        .@"defer" => |*defer_expr| {
                            defer_expr.span.line += 1;
                            drifted_call_span = true;
                        },
                        else => {},
                    };
                },
                else => {},
            };
        },
        else => {},
    };
    if (!drifted_call_span) return error.TestUnexpectedResult;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_ordinary_defer_raw_store_requires_fact.mc", .{}, false, .riscv64, null));
}

test "LLVM ordinary MMIO write defer requires MIR call-target facts" {
    const source =
        \\extern mmio struct Device {
        \\    raw: Reg<u32, .read_write>,
        \\}
        \\fn ordinary_defer_mmio_write_fact(dev: MmioPtr<Device>, value: u32) -> void {
        \\    defer dev.raw.write(value, .release);
        \\    return;
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_ordinary_defer_mmio_write_requires_fact.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try mir.validateLoweringAdmission(module_mir);
    var drifted_defer_span = false;
    for (parsed.decls()) |*decl| switch (decl.kind) {
        .fn_decl => |*fn_decl| {
            if (!std.mem.eql(u8, fn_decl.name.text, "ordinary_defer_mmio_write_fact")) continue;
            const body = fn_decl.body orelse return error.TestUnexpectedResult;
            for (body.items) |*stmt| switch (stmt.kind) {
                .@"defer" => {
                    stmt.span.line += 1;
                    drifted_defer_span = true;
                },
                else => {},
            };
        },
        else => {},
    };
    if (!drifted_defer_span) return error.TestUnexpectedResult;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_ordinary_defer_mmio_write_requires_fact.mc", .{}, false, .riscv64, null));
}

test "LLVM ordinary MMIO read defer requires MIR call-target facts" {
    const source =
        \\extern mmio struct Device {
        \\    raw: Reg<u32, .read_write>,
        \\}
        \\fn ordinary_defer_mmio_read_fact(dev: MmioPtr<Device>) -> void {
        \\    defer dev.raw.read(.acquire);
        \\    return;
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_ordinary_defer_mmio_read_requires_fact.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try mir.validateLoweringAdmission(module_mir);
    var drifted_defer_span = false;
    for (parsed.decls()) |*decl| switch (decl.kind) {
        .fn_decl => |*fn_decl| {
            if (!std.mem.eql(u8, fn_decl.name.text, "ordinary_defer_mmio_read_fact")) continue;
            const body = fn_decl.body orelse return error.TestUnexpectedResult;
            for (body.items) |*stmt| switch (stmt.kind) {
                .@"defer" => {
                    stmt.span.line += 1;
                    drifted_defer_span = true;
                },
                else => {},
            };
        },
        else => {},
    };
    if (!drifted_defer_span) return error.TestUnexpectedResult;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_ordinary_defer_mmio_read_requires_fact.mc", .{}, false, .riscv64, null));
}

test "LLVM ordinary DMA cache defer requires MIR call-target facts" {
    const source =
        \\extern struct Packet { len: u32 }
        \\type Buffer = DmaBuf<Packet, .noncoherent>;
        \\fn ordinary_defer_dma_cache_fact(buf: Buffer) -> void {
        \\    defer cache.clean(buf);
        \\    return;
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_ordinary_defer_dma_cache_requires_fact.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try mir.validateLoweringAdmission(module_mir);
    var drifted_defer_span = false;
    for (parsed.decls()) |*decl| switch (decl.kind) {
        .fn_decl => |*fn_decl| {
            if (!std.mem.eql(u8, fn_decl.name.text, "ordinary_defer_dma_cache_fact")) continue;
            const body = fn_decl.body orelse return error.TestUnexpectedResult;
            for (body.items) |*stmt| switch (stmt.kind) {
                .@"defer" => {
                    stmt.span.line += 1;
                    drifted_defer_span = true;
                },
                else => {},
            };
        },
        else => {},
    };
    if (!drifted_defer_span) return error.TestUnexpectedResult;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_ordinary_defer_dma_cache_requires_fact.mc", .{}, false, .riscv64, null));
}

test "LLVM ordinary MaybeUninit write defer requires MIR call-target facts" {
    const source =
        \\extern struct Node { value: u32 }
        \\fn ordinary_defer_maybe_uninit_write_fact(value: Node) -> void {
        \\    var slot: MaybeUninit<Node> = uninit;
        \\    defer slot.write(value);
        \\    return;
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_ordinary_defer_maybe_uninit_write_requires_fact.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try mir.validateLoweringAdmission(module_mir);
    var drifted_defer_span = false;
    for (parsed.decls()) |*decl| switch (decl.kind) {
        .fn_decl => |*fn_decl| {
            if (!std.mem.eql(u8, fn_decl.name.text, "ordinary_defer_maybe_uninit_write_fact")) continue;
            const body = fn_decl.body orelse return error.TestUnexpectedResult;
            for (body.items) |*stmt| switch (stmt.kind) {
                .@"defer" => {
                    stmt.span.line += 1;
                    drifted_defer_span = true;
                },
                else => {},
            };
        },
        else => {},
    };
    if (!drifted_defer_span) return error.TestUnexpectedResult;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_ordinary_defer_maybe_uninit_write_requires_fact.mc", .{}, false, .riscv64, null));
}

test "LLVM ordinary atomic store defer requires MIR call-target facts" {
    const source =
        \\fn ordinary_defer_atomic_store_fact(value: u32) -> void {
        \\    var counter: atomic<u32> = atomic.init(0);
        \\    defer counter.store(value, .release);
        \\    return;
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_ordinary_defer_atomic_store_requires_fact.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try mir.validateLoweringAdmission(module_mir);
    var drifted_defer_span = false;
    for (parsed.decls()) |*decl| switch (decl.kind) {
        .fn_decl => |*fn_decl| {
            if (!std.mem.eql(u8, fn_decl.name.text, "ordinary_defer_atomic_store_fact")) continue;
            const body = fn_decl.body orelse return error.TestUnexpectedResult;
            for (body.items) |*stmt| switch (stmt.kind) {
                .@"defer" => {
                    stmt.span.line += 1;
                    drifted_defer_span = true;
                },
                else => {},
            };
        },
        else => {},
    };
    if (!drifted_defer_span) return error.TestUnexpectedResult;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_ordinary_defer_atomic_store_requires_fact.mc", .{}, false, .riscv64, null));
}

test "LLVM ordinary va.end defer requires MIR call-target facts" {
    const source =
        \\export fn ordinary_defer_va_end_fact(count: i32, ...) -> i32 {
        \\    var ap: va_list = va.start();
        \\    defer va.end(&ap);
        \\    return count;
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_ordinary_defer_va_end_requires_fact.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try mir.validateLoweringAdmission(module_mir);
    var drifted_defer_span = false;
    for (parsed.decls()) |*decl| switch (decl.kind) {
        .fn_decl => |*fn_decl| {
            if (!std.mem.eql(u8, fn_decl.name.text, "ordinary_defer_va_end_fact")) continue;
            const body = fn_decl.body orelse return error.TestUnexpectedResult;
            for (body.items) |*stmt| switch (stmt.kind) {
                .@"defer" => {
                    stmt.span.line += 1;
                    drifted_defer_span = true;
                },
                else => {},
            };
        },
        else => {},
    };
    if (!drifted_defer_span) return error.TestUnexpectedResult;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_ordinary_defer_va_end_requires_fact.mc", .{}, false, .riscv64, null));
}

test "LLVM explicit drop release cancellation requires MIR explicit-drop event" {
    const source =
        \\move struct Guard { id: u32 }
        \\fn make_guard(id: u32) -> Guard { return .{ .id = id }; }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void { g.id = 0; }
        \\fn explicit_release_keeps_other_auto_drop() -> u32 {
        \\    var g: Guard = make_guard(1);
        \\    var h: Guard = make_guard(2);
        \\    close_guard(&g);
        \\    return h.id;
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_drop_attr_release_requires_mir_event.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const function = for (module_mir.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "explicit_release_keeps_other_auto_drop")) break candidate;
    } else return error.TestUnexpectedResult;
    const generated_events = function.ownership_events;
    var explicit_index: usize = 0;
    while (explicit_index < generated_events.len and generated_events[explicit_index].kind != .explicit_drop) : (explicit_index += 1) {}
    if (explicit_index == generated_events.len) return error.TestUnexpectedResult;

    const events = try std.testing.allocator.alloc(mir.OwnershipEvent, generated_events.len + 1);
    @memcpy(events[0 .. explicit_index + 1], generated_events[0 .. explicit_index + 1]);
    events[explicit_index].kind = .auto_drop;
    events[explicit_index + 1] = generated_events[explicit_index];
    events[explicit_index + 1].kind = .storage_dead;
    events[explicit_index + 1].drop_glue_symbol_id = .invalid;
    @memcpy(events[explicit_index + 2 ..], generated_events[explicit_index + 1 ..]);
    function.ownership_events = events;
    std.testing.allocator.free(generated_events);
    try mir.validateLoweringAdmission(module_mir);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_drop_attr_release_requires_mir_event.mc", .{}, false, .riscv64, null));
}

test "LLVM explicit drop release cancellation requires source-matched MIR explicit-drop event" {
    const source =
        \\move struct Guard { id: u32 }
        \\fn make_guard(id: u32) -> Guard { return .{ .id = id }; }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void { g.id = 0; }
        \\fn explicit_release_keeps_other_auto_drop() -> u32 {
        \\    var g: Guard = make_guard(1);
        \\    var h: Guard = make_guard(2);
        \\    close_guard(&g);
        \\    return h.id;
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_drop_attr_release_source_requires_event.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const function = for (module_mir.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "explicit_release_keeps_other_auto_drop")) break candidate;
    } else return error.TestUnexpectedResult;
    for (function.ownership_events) |*event| {
        if (event.kind == .explicit_drop) {
            event.source.line += 1;
            break;
        }
    } else return error.TestUnexpectedResult;
    try mir.validateLoweringAdmission(module_mir);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_drop_attr_release_source_requires_event.mc", .{}, false, .riscv64, null));
}

test "LLVM rejects auto-drop ownership holes before lowering" {
    const source =
        \\move struct Guard { id: u32 }
        \\fn make_guard(id: u32) -> Guard { return .{ .id = id }; }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void { g.id = 0; }
        \\fn reject_return_via_alias() -> Guard {
        \\    var g: Guard = make_guard(1);
        \\    let p: *Guard = &g;
        \\    return move p.*;
        \\}
        \\fn reject_forget_auto_drop() -> void {
        \\    var g: Guard = make_guard(2);
        \\    unsafe { forget_unchecked(g); }
        \\}
        \\fn reject_reinit_after_move() -> Guard {
        \\    var g: Guard = make_guard(3);
        \\    let result: Guard = move g;
        \\    g = make_guard(4);
        \\    return move result;
        \\}
    ;
    try std.testing.expectError(error.TestUnexpectedResult, test_support.parseCheckedModule("llvm_auto_drop_v0_rejects.mc", source));
}

test "LLVM wrapping arithmetic requires MIR identity and operand/result type facts" {
    const source =
        \\fn wrapping_fact_gate(a: u32) -> u32 {
        \\    return wrapping.add(a, 1);
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_wrapping_call_facts.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirProfileDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_mir_wrapping_call_facts.mc", .{}, false, .riscv64, false, null);
    try expectContains(complete_output.items, " = add i32 %mc_arg_0, 1");

    var missing_identity = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_identity.deinit();
    try clearCallTargetFactsForFunction(&missing_identity, "wrapping_fact_gate");
    var identity_output: std.ArrayList(u8) = .empty;
    defer identity_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirCallTargetFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_identity, &identity_output, "llvm_wrapping_call_facts.mc", .{}, false, .riscv64, null));

    inline for ([_]mir.TargetTypeKind{ .wrapping_left, .wrapping_right, .wrapping_result }) |kind| {
        var missing_type = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer missing_type.deinit();
        try removeTargetTypeKindForFunction(&missing_type, "wrapping_fact_gate", kind);
        var type_output: std.ArrayList(u8) = .empty;
        defer type_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_type, &type_output, "llvm_wrapping_call_facts.mc", .{}, false, .riscv64, null));
    }
}

test "LLVM emits wrapping arithmetic call from MIR without body fallback" {
    const source =
        \\fn wrapping_fact_gate(a: u32) -> u32 {
        \\    return wrapping.add(a, 1);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_wrapping_call.mc", source, &output);
    try expectContains(output.items, " = add i32 %mc_arg_0, 1");
}

test "LLVM emits local wrapping arithmetic from MIR without body fallback" {
    const source =
        \\fn local_wrap(a: u32) -> u32 {
        \\    let out = wrapping.add(a, 1);
        \\    return out;
        \\}
        \\fn assigned_wrap(a: u32) -> u32 {
        \\    var out: u32 = 0;
        \\    out = wrapping.add(a, 1);
        \\    return out;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_local_wrapping_call.mc", source, &output);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.items, " = add i32 %mc_arg_0, 1"));
}

test "LLVM unchecked arithmetic requires MIR identity and operand/result type facts" {
    const source =
        \\fn unchecked_fact_gate(a: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)] {
        \\        return unchecked.add(a, 1);
        \\    }
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_unchecked_call_facts.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirProfileDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_mir_unchecked_call_facts.mc", .{}, false, .riscv64, false, null);
    try expectContains(complete_output.items, " = add i32 %mc_arg_0, 1");

    var missing_identity = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_identity.deinit();
    try clearCallTargetFactsForFunction(&missing_identity, "unchecked_fact_gate");
    var identity_output: std.ArrayList(u8) = .empty;
    defer identity_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirCallTargetFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_identity, &identity_output, "llvm_unchecked_call_facts.mc", .{}, false, .riscv64, null));

    inline for ([_]mir.TargetTypeKind{ .unchecked_left, .unchecked_right, .unchecked_result }) |kind| {
        var missing_type = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer missing_type.deinit();
        try removeTargetTypeKindForFunction(&missing_type, "unchecked_fact_gate", kind);
        var type_output: std.ArrayList(u8) = .empty;
        defer type_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_type, &type_output, "llvm_unchecked_call_facts.mc", .{}, false, .riscv64, null));
    }
}

test "LLVM emits unchecked arithmetic call from MIR without body fallback" {
    const source =
        \\fn unchecked_fact_gate(a: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)] {
        \\        return unchecked.add(a, 1);
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_unchecked_call.mc", source, &output);
    try expectContains(output.items, "mir range_fact consumed region=1 op=add assumption=no_overflow");
    try expectContains(output.items, " = add i32 %mc_arg_0, 1");
}

test "LLVM emits local unchecked arithmetic from MIR without body fallback" {
    const source =
        \\fn local_unchecked(a: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)] {
        \\        let out = unchecked.add(a, 1);
        \\        return out;
        \\    }
        \\}
        \\fn assigned_unchecked(a: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)] {
        \\        var out: u32 = 0;
        \\        out = unchecked.add(a, 1);
        \\        return out;
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_local_unchecked_call.mc", source, &output);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.items, "mir range_fact consumed region=1 op=add assumption=no_overflow"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.items, " = add i32 %mc_arg_0, 1"));
}

test "LLVM emits unchecked sub and mul returns from MIR without body fallback" {
    const source =
        \\fn unchecked_sub_gate(a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)] {
        \\        return unchecked.sub(a, b);
        \\    }
        \\}
        \\fn unchecked_mul_gate(a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)] {
        \\        return unchecked.mul(a, b);
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_unchecked_sub_mul_calls.mc", source, &output);
    try expectContains(output.items, "mir range_fact consumed region=1 op=sub assumption=no_overflow");
    try expectContains(output.items, " = sub i32 %mc_arg_0, %mc_arg_1");
    try expectContains(output.items, "mir range_fact consumed region=1 op=mul assumption=no_overflow");
    try expectContains(output.items, " = mul i32 %mc_arg_0, %mc_arg_1");
}

test "LLVM rejects prebuilt MIR with missing atomic call target facts" {
    const source =
        \\fn atomic_call_target_fact_gate() -> u32 {
        \\    var counter: atomic<u32> = atomic.init(0);
        \\    return counter.fetch_add(1, .acq_rel);
        \\}
    ;

    var parsed = try test_support.parseModule("llvm_missing_atomic_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "atomic_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_missing_atomic_call_target_facts.mc", .{}, false, .riscv64, null),
    );
}

test "LLVM atomic and MaybeUninit payloads require MIR target facts" {
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
    var parsed = try test_support.parseModule("llvm_atomic_maybe_uninit_payload_facts.mc", source);
    defer parsed.deinit();
    for ([_][]const u8{ "atomic_payload_fact_gate", "maybe_uninit_payload_fact_gate" }) |name| {
        var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, name);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_atomic_maybe_uninit_payload_facts.mc", .{}, false, .riscv64, null));
    }
}

test "LLVM atomic init requires MIR identity and complete types" {
    const source =
        \\global boot_counter: atomic<u64> = atomic.init(9);
        \\fn local_init() -> void {
        \\    var counter: atomic<u32> = atomic.init(1);
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_atomic_init_facts.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_atomic_init_facts.mc", .{}, false, .riscv64, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "@boot_counter = internal global i64 9") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "store i32 1") != null);

    for ([_][]const u8{ "boot_counter", "local_init" }) |name| {
        var missing_identity = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer missing_identity.deinit();
        try clearCallTargetFactsForFunction(&missing_identity, name);
        var missing_identity_output: std.ArrayList(u8) = .empty;
        defer missing_identity_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirCallTargetFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_identity, &missing_identity_output, "llvm_atomic_init_facts.mc", .{}, false, .riscv64, null));

        inline for ([_]mir.TargetTypeKind{ .atomic_init_payload, .atomic_init_result }) |kind| {
            var missing_type = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
            defer missing_type.deinit();
            try removeTargetTypeKindForFunction(&missing_type, name, kind);
            var missing_type_output: std.ArrayList(u8) = .empty;
            defer missing_type_output.deinit(std.testing.allocator);
            try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_type, &missing_type_output, "llvm_atomic_init_facts.mc", .{}, false, .riscv64, null));
        }

        var stale_payload = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer stale_payload.deinit();
        try renameTargetTypeFactForFunction(&stale_payload, name, .atomic_init_payload, "bool");
        var stale_payload_output: std.ArrayList(u8) = .empty;
        defer stale_payload_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_payload, &stale_payload_output, "llvm_atomic_init_facts.mc", .{}, false, .riscv64, null));

        var stale_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer stale_result.deinit();
        try renameTargetTypeFactForFunction(&stale_result, name, .atomic_init_result, "u32");
        var stale_result_output: std.ArrayList(u8) = .empty;
        defer stale_result_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_result, &stale_result_output, "llvm_atomic_init_facts.mc", .{}, false, .riscv64, null));
    }
}

test "LLVM rejects prebuilt MIR with missing bitcast call target facts" {
    const source =
        \\fn bitcast_call_target_fact_gate(value: f32) -> u32 {
        \\    return bitcast<u32>(value);
        \\}
    ;

    var parsed = try test_support.parseModule("llvm_missing_bitcast_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "bitcast_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_missing_bitcast_call_target_facts.mc", .{}, false, .riscv64, null),
    );
}

test "LLVM rejects prebuilt MIR with missing bitcast target type facts" {
    const source =
        \\fn bitcast_target_type_fact_gate(value: f32) -> u32 {
        \\    return bitcast<u32>(value);
        \\}
    ;

    var parsed = try test_support.parseModule("llvm_missing_bitcast_target_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "bitcast_target_type_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirTargetTypeFacts,
        appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_missing_bitcast_target_type_facts.mc", .{}, false, .riscv64, null),
    );
}

test "LLVM rejects prebuilt MIR with missing const_get call target facts" {
    const source =
        \\fn const_get_call_target_fact_gate(xs: [3]u32) -> u32 {
        \\    return xs.const_get<1>();
        \\}
    ;

    var parsed = try test_support.parseModule("llvm_missing_const_get_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "const_get_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_missing_const_get_call_target_facts.mc", .{}, false, .riscv64, null),
    );
}

test "LLVM const_get consumes MIR base result and index facts" {
    const source =
        \\type Words = [3]u32;
        \\fn const_get_fact_gate(xs: Words) -> u32 { let value = xs.const_get<2>(); return value; }
    ;
    var parsed = try test_support.parseModule("llvm_const_get_facts.mc", source);
    defer parsed.deinit();
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_const_get_facts.mc", .{}, false, .riscv64, null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, "extractvalue [3 x i32]") != null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, ", 2") != null);
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, "const_get_fact_gate");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_const_get_facts.mc", .{}, false, .riscv64, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try clearConstGetFactsForFunction(&module_mir, "const_get_fact_gate");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirConstGetFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_const_get_facts.mc", .{}, false, .riscv64, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try retargetConstGetFactForFunction(&module_mir, "const_get_fact_gate", 1);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirConstGetFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_const_get_facts.mc", .{}, false, .riscv64, null));
    }
}

test "LLVM DMA calls consume MIR identities and complete types" {
    const source =
        \\extern struct Packet { len: u16, tag: u8 }
        \\type Buffer = DmaBuf<Packet, .noncoherent>;
        \\fn dma_fact_gate(buf: Buffer) -> []mut Packet {
        \\    cache.clean(buf);
        \\    cache.invalidate(buf);
        \\    let addr: DmaAddr = buf.dma_addr();
        \\    let view = buf.as_slice();
        \\    return view;
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_dma_facts.mc", source);
    defer parsed.deinit();
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_dma_facts.mc", .{}, false, .riscv64, null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, "; canonical executable MIR") != null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, "fence release") != null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, "fence acquire") != null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, "inttoptr i64") != null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, "insertvalue { ptr, i64 }") != null);
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try clearCallTargetFactsForFunction(&module_mir, "dma_fact_gate");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirCallTargetFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_dma_facts.mc", .{}, false, .riscv64, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try retargetCallTargetFactsForFunction(&module_mir, "dma_fact_gate", .const_get);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirCallTargetFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_dma_facts.mc", .{}, false, .riscv64, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, "dma_fact_gate");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_dma_facts.mc", .{}, false, .riscv64, null));
    }
}

test "LLVM raw-many offset consumes MIR identity and complete types" {
    const source =
        \\type Words = [*]mut u16;
        \\fn raw_many_offset_fact_gate(p: Words, index: usize) -> Words {
        \\    unsafe { let q = p.offset(index); return q; }
        \\}
        \\fn raw_many_offset_deref_fact_gate(p: Words, index: usize) -> u16 {
        \\    unsafe { let value = p.offset(index).*; return value; }
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_raw_many_offset_facts.mc", source);
    defer parsed.deinit();
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_raw_many_offset_facts.mc", .{}, false, .riscv64, null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, "getelementptr i16") != null);
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try clearCallTargetFactsForFunction(&module_mir, "raw_many_offset_fact_gate");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirCallTargetFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_raw_many_offset_facts.mc", .{}, false, .riscv64, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try retargetCallTargetFactsForFunction(&module_mir, "raw_many_offset_fact_gate", .const_get);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirCallTargetFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_raw_many_offset_facts.mc", .{}, false, .riscv64, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, "raw_many_offset_fact_gate");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_raw_many_offset_facts.mc", .{}, false, .riscv64, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try removeTargetTypeKindForFunction(&module_mir, "raw_many_offset_fact_gate", .inferred_local);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_raw_many_offset_facts.mc", .{}, false, .riscv64, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try renameTargetTypeFactForFunction(&module_mir, "raw_many_offset_fact_gate", .inferred_local, "u64");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_raw_many_offset_facts.mc", .{}, false, .riscv64, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try removeTargetTypeKindForFunction(&module_mir, "raw_many_offset_deref_fact_gate", .inferred_local);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_raw_many_offset_facts.mc", .{}, false, .riscv64, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try renameTargetTypeFactForFunction(&module_mir, "raw_many_offset_deref_fact_gate", .inferred_local, "u64");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_raw_many_offset_facts.mc", .{}, false, .riscv64, null));
    }
}

test "LLVM inferred local try payloads require MIR types" {
    const source =
        \\extern fn make_result() -> Result<u32, u32>;
        \\extern fn make_nullable() -> ?*const u8;
        \\fn result_local() -> Result<u32, u32> { let value = make_result()?; return ok(value); }
        \\fn nullable_local() -> *const u8 { let value = make_nullable()?; return value; }
    ;
    var parsed = try test_support.parseCheckedModule("llvm_inferred_local_try_payloads.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_inferred_local_try_payloads.mc", .{}, false, .riscv64, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "@result_local") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "@nullable_local") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "result_local", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_inferred_local_try_payloads.mc", .{}, false, .riscv64, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "result_local", .inferred_local, "u64");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_inferred_local_try_payloads.mc", .{}, false, .riscv64, null));
}

test "LLVM grouped expressions consume their own MIR result facts" {
    const source =
        \\fn grouped_result(value: u16) -> u16 {
        \\    return (value) + 1;
        \\}
    ;
    const grouped_text = "(value)";
    const grouped_offset = std.mem.indexOf(u8, source, grouped_text) orelse return error.TestUnexpectedResult;

    var parsed = try test_support.parseCheckedModule("llvm_grouped_expression_result.mc", source);
    defer parsed.deinit();

    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_grouped_expression_result_fact_gate.mc", source, &complete_output);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "grouped_result") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeFactAtOffsetForFunction(&missing, "grouped_result", .expression_result, grouped_offset, grouped_text.len);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_grouped_expression_result.mc", .{}, false, .riscv64, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactAtOffsetForFunction(&stale, "grouped_result", .expression_result, grouped_offset, grouped_text.len, "u32");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_grouped_expression_result.mc", .{}, false, .riscv64, null));
}

test "LLVM grouped direct calls consume the outer MIR result fact" {
    const source =
        \\fn make() -> u16 { return 7; }
        \\fn grouped_call_result() -> u16 {
        \\    let value = (make());
        \\    return value;
        \\}
    ;
    const grouped_text = "(make())";
    const grouped_offset = std.mem.indexOf(u8, source, grouped_text) orelse return error.TestUnexpectedResult;
    var parsed = try test_support.parseCheckedModule("llvm_grouped_call_result.mc", source);
    defer parsed.deinit();

    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_grouped_call_result_fact_gate.mc", source, &complete_output);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeFactAtOffsetForFunction(&missing, "grouped_call_result", .expression_result, grouped_offset, grouped_text.len);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_grouped_call_result.mc", .{}, false, .riscv64, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactAtOffsetForFunction(&stale, "grouped_call_result", .expression_result, grouped_offset, grouped_text.len, "u32");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_grouped_call_result.mc", .{}, false, .riscv64, null));
}

test "LLVM direct-call inferred local lowers without function body fallback" {
    const source =
        \\fn make_count() -> u64 { return 7; }
        \\fn caller() -> u64 {
        \\    let count = make_count();
        \\    return count;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_inferred_local_direct_call_return.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i64 @caller");
    try expectContains(body, "call i64 @make_count()");
    try expectContains(body, "ret i64 %");
}

test "LLVM literal inferred local lowers without function body fallback" {
    const source =
        \\fn literal_local() -> u32 {
        \\    let count = 7;
        \\    return count;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_inferred_local_literal_return.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @literal_local");
    try expectContains(body, "store i32 7");
    try expectContains(body, "ret i32 %");
}

test "LLVM bool-literal inferred local lowers without function body fallback" {
    const source =
        \\fn bool_local() -> bool {
        \\    let flag = true;
        \\    return flag;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_inferred_local_bool_literal_return.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i1 @bool_local");
    try expectContains(body, "store i1 true");
    try expectContains(body, "ret i1 %");
}

test "LLVM checked-unary inferred local lowers without function body fallback" {
    const source =
        \\fn unary_local(value: i64) -> i64 {
        \\    let negated = -value;
        \\    return negated;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_inferred_local_checked_unary_return.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "llvm.ssub.with.overflow.i64") != null);
}

test "LLVM checked-binary inferred local lowers without function body fallback" {
    const source =
        \\fn binary_local(left: u64, right: u64) -> u64 {
        \\    let sum = left + right;
        \\    return sum;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_inferred_local_checked_binary_return.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "llvm.uadd.with.overflow.i64") != null);
}

test "LLVM logical-not inferred local lowers without function body fallback" {
    const source =
        \\fn not_local(enabled: bool) -> bool {
        \\    let disabled = !enabled;
        \\    return disabled;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_inferred_local_logical_not_return.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i1 @not_local");
    try expectContains(body, "xor i1 %");
    try expectContains(body, ", true");
}

test "LLVM logical return tree lowers without function body fallback" {
    const source =
        \\fn bool_and(a: bool, b: bool) -> bool { return a && b; }
        \\fn bool_or(a: bool, b: bool) -> bool { return a || b; }
        \\fn nested_bool(a: bool, b: bool, c: bool) -> bool { return !a || (b && c); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_logical_return_tree.mc", source, &output);
    const and_body = try llvmFunctionBody(output.items, "define internal i1 @bool_and");
    const or_body = try llvmFunctionBody(output.items, "define internal i1 @bool_or");
    const nested = try llvmFunctionBody(output.items, "define internal i1 @nested_bool");
    for ([_][]const u8{ and_body, or_body, nested }) |body| try expectContains(body, "; canonical executable MIR");
    try expectContains(and_body, "and i1 %mc_arg_0, %mc_arg_1");
    try expectContains(or_body, "or i1 %mc_arg_0, %mc_arg_1");
    try expectContains(nested, "xor i1 %mc_arg_0, true");
    try expectContains(nested, "and i1 %mc_arg_1, %mc_arg_2");
    try expectContains(nested, "or i1 %mc_expr_tmp_");
}

test "LLVM compare inferred local lowers without function body fallback" {
    const source =
        \\fn compare_local(left: u64, right: u64) -> bool {
        \\    let less = left < right;
        \\    return less;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_inferred_local_compare_return.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i1 @compare_local");
    try expectContains(body, "icmp ult i64 ");
}

test "LLVM copied inferred local lowers without function body fallback" {
    const source =
        \\fn copy_local(value: u64) -> u64 {
        \\    let copy = value;
        \\    return copy;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_inferred_local_copy_return.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i64 @copy_local");
    try expectContains(body, "store i64 %mc_arg_0");
    try expectContains(body, "ret i64 %");
}

test "LLVM param-field copied inferred local lowers without function body fallback" {
    const source =
        \\struct Box { value: u64 }
        \\fn copy_field(box: Box) -> u64 {
        \\    let copy = box.value;
        \\    return copy;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_inferred_local_param_field_copy_return.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "ret i64") != null);
}

test "LLVM null inferred local lowers without function body fallback" {
    const source =
        \\fn null_local() -> ?u32 {
        \\    let none: ?u32 = null;
        \\    return none;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_inferred_local_null_return.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal { i1, i32 } @null_local");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "zeroinitializer");
}

test "LLVM nested array member and index results require MIR expression facts" {
    const source =
        \\struct MatrixHolder { rows: [2][2]u32 }
        \\fn read_matrix_member(holder: MatrixHolder) -> u32 {
        \\    return holder.rows[0][1];
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_array_member_expression_result_facts.mc", source);
    defer parsed.deinit();
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_array_member_expression_result_facts.mc", .{}, false, .riscv64, null);
        try expectContains(output.items, "extractvalue");
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        const member_offset = std.mem.indexOf(u8, source, "holder.rows") orelse return error.TestUnexpectedResult;
        try removeTargetTypeFactAtOffsetForFunction(&module_mir, "read_matrix_member", .expression_result, member_offset, "holder.rows".len);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_array_member_expression_result_facts.mc", .{}, false, .riscv64, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        const member_offset = std.mem.indexOf(u8, source, "holder.rows") orelse return error.TestUnexpectedResult;
        try renameTargetTypeFactAtOffsetForFunction(&module_mir, "read_matrix_member", .expression_result, member_offset, "holder.rows".len, "u64");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_array_member_expression_result_facts.mc", .{}, false, .riscv64, null));
    }
}

test "LLVM nested struct members require MIR expression facts" {
    const source =
        \\struct Leaf { value: u32 }
        \\struct Holder { child: Leaf }
        \\fn read_nested_member(holder: Holder) -> u32 {
        \\    return holder.child.value;
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_struct_member_expression_result_facts.mc", source);
    defer parsed.deinit();
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_struct_member_expression_result_facts.mc", .{}, false, .riscv64, null);
        try expectContains(output.items, "extractvalue { { i32 } }");
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        const member_offset = std.mem.indexOf(u8, source, "holder.child") orelse return error.TestUnexpectedResult;
        try removeTargetTypeFactAtOffsetForFunction(&module_mir, "read_nested_member", .expression_result, member_offset, "holder.child".len);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_struct_member_expression_result_facts.mc", .{}, false, .riscv64, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        const member_offset = std.mem.indexOf(u8, source, "holder.child") orelse return error.TestUnexpectedResult;
        try renameTargetTypeFactAtOffsetForFunction(&module_mir, "read_nested_member", .expression_result, member_offset, "holder.child".len, "u32");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_struct_member_expression_result_facts.mc", .{}, false, .riscv64, null));
    }
}

test "LLVM MMIO calls consume MIR identities and complete types" {
    const source =
        \\packed bits Status: u8 { ready: bool }
        \\extern mmio struct Device {
        \\    raw: Reg<u32, .read_write>,
        \\    flags: RegBits<u8, Status, .read>,
        \\}
        \\fn mmio_fact_gate(dev: MmioPtr<Device>, value: u32) -> Status {
        \\    dev.raw.write(value, .release);
        \\    let raw = dev.raw.read(.relaxed);
        \\    return dev.flags.read(.acquire);
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_mmio_facts.mc", source);
    defer parsed.deinit();
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_mmio_facts.mc", .{}, false, .riscv64, null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, "store volatile i32") != null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, "load volatile i32") != null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, "load volatile i8") != null);
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try clearCallTargetFactsForFunction(&module_mir, "mmio_fact_gate");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirCallTargetFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_mmio_facts.mc", .{}, false, .riscv64, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try retargetCallTargetFactsForFunction(&module_mir, "mmio_fact_gate", .const_get);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirCallTargetFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_mmio_facts.mc", .{}, false, .riscv64, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, "mmio_fact_gate");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_mmio_facts.mc", .{}, false, .riscv64, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try removeTargetTypeKindForFunction(&module_mir, "mmio_fact_gate", .inferred_local);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_mmio_facts.mc", .{}, false, .riscv64, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try renameTargetTypeFactForFunction(&module_mir, "mmio_fact_gate", .inferred_local, "u64");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_mmio_facts.mc", .{}, false, .riscv64, null));
    }
}

test "LLVM MMIO map consumes MIR identity and complete types" {
    const source =
        \\extern mmio struct Device {
        \\    raw: Reg<u32, .read>,
        \\}
        \\fn map_fact_gate(pa: PAddr) -> MmioPtr<Device> {
        \\    unsafe { return mmio.map<Device>(pa)?; }
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_mmio_map_facts.mc", source);
    defer parsed.deinit();
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_mmio_map_facts.mc", .{}, false, .riscv64, null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, "; canonical executable MIR") != null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, "inttoptr i64 %mc_arg_0 to ptr") != null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, "icmp eq ptr %mc_expr_tmp_0, null") != null);
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try clearCallTargetFactsForFunction(&module_mir, "map_fact_gate");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirCallTargetFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_mmio_map_facts.mc", .{}, false, .riscv64, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try retargetCallTargetFactsForFunction(&module_mir, "map_fact_gate", .mmio_read);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirCallTargetFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_mmio_map_facts.mc", .{}, false, .riscv64, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, "map_fact_gate");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_mmio_map_facts.mc", .{}, false, .riscv64, null));
    }
}

test "LLVM reductions require MIR source and element type facts" {
    const source =
        \\fn reduce_element_fact_gate(xs: []const u32) -> Result<u32, Overflow> {
        \\    return reduce.sum_checked<u32>(xs);
        \\}
    ;

    var parsed = try test_support.parseModule("llvm_missing_reduce_element_facts.mc", source);
    defer parsed.deinit();
    for ([_]mir.TargetTypeKind{ .reduce_source, .reduce_element }) |kind| {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try removeTargetTypeKindForFunction(&module_mir, "reduce_element_fact_gate", kind);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(
            error.InvalidMirTargetTypeFacts,
            appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_missing_reduce_element_facts.mc", .{}, false, .riscv64, null),
        );
    }
}

test "LLVM enum raw requires MIR call and target type facts" {
    const source =
        \\enum Color: u32 { red = 1 }
        \\open enum Tag: u8 { ready = 2 }
        \\enum DefaultTag { idle }
        \\fn enum_raw_fact_gate(value: Color) -> u32 { return value.raw(); }
        \\fn open_raw(value: Tag) -> u8 { return value.raw(); }
        \\fn default_raw(value: DefaultTag) -> isize { return value.raw(); }
        \\fn path_raw() -> u32 { return Color.red.raw(); }
    ;

    var parsed = try test_support.parseModule("llvm_enum_raw_facts.mc", source);
    defer parsed.deinit();
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_enum_raw_facts.mc", .{}, false, .riscv64, null);
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try clearCallTargetFactsForFunction(&module_mir, "enum_raw_fact_gate");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(
            error.InvalidMirCallTargetFacts,
            appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_enum_raw_facts.mc", .{}, false, .riscv64, null),
        );
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, "enum_raw_fact_gate");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(
            error.InvalidMirTargetTypeFacts,
            appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_enum_raw_facts.mc", .{}, false, .riscv64, null),
        );
    }
}

test "LLVM rejects prebuilt MIR with missing phys call target facts" {
    const source =
        \\fn phys_call_target_fact_gate(value: usize) -> PAddr {
        \\    return phys(value);
        \\}
    ;

    var parsed = try test_support.parseModule("llvm_missing_phys_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "phys_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_missing_phys_call_target_facts.mc", .{}, false, .riscv64, null),
    );
}

test "LLVM rejects prebuilt MIR with missing phys result type facts" {
    const source =
        \\fn phys_result_type_fact_gate(value: usize) -> PAddr {
        \\    return phys(value);
        \\}
    ;

    var parsed = try test_support.parseModule("llvm_missing_phys_result_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "phys_result_type_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirTargetTypeFacts,
        appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_missing_phys_result_type_facts.mc", .{}, false, .riscv64, null),
    );
}

test "LLVM rejects prebuilt MIR with missing MaybeUninit call target facts" {
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

    var parsed = try test_support.parseModule("llvm_missing_maybe_uninit_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "maybe_uninit_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_missing_maybe_uninit_call_target_facts.mc", .{}, false, .riscv64, null),
    );
}

test "LLVM rejects prebuilt MIR with missing raw store call target facts" {
    const source =
        \\fn raw_store_call_target_fact_gate(addr: PAddr, value: u32) -> void {
        \\    unsafe { raw.store<u32>(addr, value); }
        \\}
    ;

    var parsed = try test_support.parseModule("llvm_missing_raw_store_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "raw_store_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_missing_raw_store_call_target_facts.mc", .{}, false, .riscv64, null),
    );
}

test "LLVM rejects prebuilt MIR with missing raw load call target facts" {
    const source =
        \\fn raw_load_call_target_fact_gate(addr: PAddr) -> u32 {
        \\    unsafe { return raw.load<u32>(addr); }
        \\}
    ;

    var parsed = try test_support.parseModule("llvm_missing_raw_load_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "raw_load_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_missing_raw_load_call_target_facts.mc", .{}, false, .riscv64, null),
    );
}

test "LLVM rejects prebuilt MIR with missing raw ptr call target facts" {
    const source =
        \\fn raw_ptr_call_target_fact_gate(addr: PAddr) -> *mut u32 {
        \\    unsafe { return raw.ptr<u32>(addr); }
        \\}
    ;

    var parsed = try test_support.parseModule("llvm_missing_raw_ptr_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "raw_ptr_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_missing_raw_ptr_call_target_facts.mc", .{}, false, .riscv64, null),
    );
}

test "LLVM raw memory calls require complete MIR target type facts" {
    const source =
        \\fn read(addr: PAddr) -> u32 { unsafe { return raw.load<u32>(addr); } }
        \\fn pointer(addr: PAddr) -> *mut u32 { unsafe { return raw.ptr<u32>(addr); } }
        \\fn write(addr: PAddr, value: u32) -> void { unsafe { raw.store<u32>(addr, value); } }
    ;
    var parsed = try test_support.parseModule("llvm_raw_memory_type_facts.mc", source);
    defer parsed.deinit();
    for ([_][]const u8{ "read", "pointer", "write" }) |name| {
        var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, name);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_raw_memory_type_facts.mc", .{}, false, .riscv64, null));
    }
}

test "LLVM explicit traps require exact MIR reason identities" {
    const source =
        \\fn trap_bounds() -> never { return trap(.Bounds); }
        \\fn trap_null_unwrap() -> never { return trap(.NullUnwrap); }
        \\fn trap_integer_overflow() -> never { return trap(.IntegerOverflow); }
        \\fn trap_divide_by_zero() -> never { return trap(.DivideByZero); }
        \\fn trap_invalid_shift() -> never { return trap(.InvalidShift); }
        \\fn trap_invalid_representation() -> never { return trap(.InvalidRepresentation); }
        \\fn trap_assert() -> never { return trap(.Assert); }
        \\fn trap_unreachable() -> never { return trap(.Unreachable); }
    ;
    var parsed = try test_support.parseCheckedModule("llvm_explicit_trap_target_facts.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirProfileDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_mir_explicit_trap_target_facts.mc", .{}, false, .riscv64, false, null);
    for ([_][]const u8{ "Bounds", "NullUnwrap", "IntegerOverflow", "DivideByZero", "InvalidShift", "InvalidRepresentation", "Assert", "Unreachable" }) |reason| {
        const helper = try std.fmt.allocPrint(std.testing.allocator, "call void @mc_trap_{s}()", .{reason});
        defer std.testing.allocator.free(helper);
        try std.testing.expect(std.mem.indexOf(u8, complete_output.items, helper) != null);
    }

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try clearCallTargetFactsForFunction(&missing, "trap_bounds");
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirCallTargetFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_explicit_trap_target_facts.mc", .{}, false, .riscv64, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try retargetCallTargetFactsForFunction(&stale, "trap_bounds", .trap_assert);
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirCallTargetFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_explicit_trap_target_facts.mc", .{}, false, .riscv64, null));
}

test "LLVM emits explicit traps from MIR without body fallback" {
    const source =
        \\fn trap_bounds() -> never { return trap(.Bounds); }
        \\fn trap_assert() -> never { return trap(.Assert); }
        \\fn trap_unreachable() -> never { return trap(.Unreachable); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_explicit_traps.mc", source, &output);
    try expectContains(output.items, "call void @mc_trap_Bounds()");
    try expectContains(output.items, "call void @mc_trap_Assert()");
    try expectContains(output.items, "call void @mc_trap_Unreachable()");
}

test "LLVM runtime asserts require MIR bool condition types" {
    const source =
        \\fn require_flag(flag: bool) -> void { assert(flag); }
    ;
    var parsed = try test_support.parseCheckedModule("llvm_assert_condition_type_facts.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirProfileDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_mir_assert_condition_type_facts.mc", .{}, false, .riscv64, false, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "br i1 %") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "call void @mc_trap_Assert()") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "require_flag", .assert_condition);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_assert_condition_type_facts.mc", .{}, false, .riscv64, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "require_flag", .assert_condition, "u32");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_assert_condition_type_facts.mc", .{}, false, .riscv64, null));
}

test "LLVM emits runtime assert from MIR without body fallback" {
    const source =
        \\fn require_flag(flag: bool) -> void { assert(flag); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_runtime_assert.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal void @require_flag");
    try expectContains(body, "; canonical executable MIR");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "br i1 %mc_arg_0"));
    try expectContains(body, "label %mc_assert_ready_");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "call void @mc_trap_Assert()"));
}

test "LLVM while loops require MIR bool condition types" {
    const source =
        \\fn wait_for_flag(flag: bool) -> void { while flag { return; } }
    ;
    var parsed = try test_support.parseCheckedModule("llvm_loop_condition_type_facts.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirProfileDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_mir_loop_condition_type_facts.mc", .{}, false, .riscv64, false, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "br i1 %") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "wait_for_flag", .loop_condition);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_loop_condition_type_facts.mc", .{}, false, .riscv64, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "wait_for_flag", .loop_condition, "u32");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_loop_condition_type_facts.mc", .{}, false, .riscv64, null));
}

test "LLVM emits void-returning while loop from MIR without body fallback" {
    const source =
        \\fn wait_for_flag(flag: bool) -> void { while flag { return; } }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_void_returning_while_loop.mc", source, &output);
    try expectContains(output.items, "br i1 %mc_arg_0");
    try expectContains(output.items, "ret void");
}

test "LLVM switches require MIR subject types" {
    const source =
        \\enum Choice { left, right }
        \\union Token { number: u32, eof }
        \\fn result_subject(value: Result<u32, u32>) -> u32 { switch value { ok(v) => { return v; }, err(e) => { return e; }, } }
        \\fn nullable_subject(value: ?*const u8) -> u32 { switch value { p => { return 1; }, _ => { return 0; }, } }
        \\fn union_subject(value: Token) -> u32 { switch value { number(v) => { return v; }, .eof => { return 0; }, } }
        \\fn enum_subject(value: Choice) -> u32 { switch value { .left => { return 1; }, .right => { return 0; }, } }
        \\fn bool_subject(value: bool) -> u32 { switch (value) { true => { return 1; }, false => { return 0; }, } }
    ;
    var parsed = try test_support.parseCheckedModule("llvm_switch_subject_type_facts.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_switch_subject_type_facts.mc", .{}, false, .riscv64, null);
    for ([_][]const u8{ "result_subject", "nullable_subject", "union_subject", "enum_subject", "bool_subject" }) |name| {
        try std.testing.expect(std.mem.indexOf(u8, complete_output.items, name) != null);
    }

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "result_subject", .switch_subject);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_switch_subject_type_facts.mc", .{}, false, .riscv64, null));

    for ([_][]const u8{ "result_subject", "nullable_subject", "union_subject", "enum_subject", "bool_subject" }) |name| {
        var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer stale.deinit();
        try renameTargetTypeFactForFunction(&stale, name, .switch_subject, "u32");
        var stale_output: std.ArrayList(u8) = .empty;
        defer stale_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_switch_subject_type_facts.mc", .{}, false, .riscv64, null));
    }

    var stale_nullable_repr = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale_nullable_repr.deinit();
    try retargetTargetTypeResultForFunction(&stale_nullable_repr, "nullable_subject", .switch_subject, .{ .nullable_value = "u32" });
    var stale_nullable_repr_output: std.ArrayList(u8) = .empty;
    defer stale_nullable_repr_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_nullable_repr, &stale_nullable_repr_output, "llvm_switch_subject_type_facts.mc", .{}, false, .riscv64, null));

    var unknown_subject_repr = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer unknown_subject_repr.deinit();
    try retargetTargetTypeResultForFunction(&unknown_subject_repr, "nullable_subject", .switch_subject, .unknown);
    var unknown_subject_repr_output: std.ArrayList(u8) = .empty;
    defer unknown_subject_repr_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &unknown_subject_repr, &unknown_subject_repr_output, "llvm_switch_subject_type_facts.mc", .{}, false, .riscv64, null));
}

test "LLVM emits enum switch returns from MIR without body fallback" {
    const source =
        \\enum Choice { left, right }
        \\fn choose(value: Choice) -> u32 {
        \\    switch value {
        \\        .left => { return 1; },
        \\        .right => { return 2; },
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_enum_switch_returns.mc", source, &output);
    try expectContains(output.items, "; canonical executable MIR");
    try expectContains(output.items, "switch ");
    try expectContains(output.items, "label %mc_block_");
    try expectContains(output.items, "ret i32 1");
    try expectContains(output.items, "ret i32 2");
    try expectContains(output.items, "call void @mc_trap_InvalidRepresentation()");
}

test "LLVM emits multi-arm enum switch returns from MIR without body fallback" {
    const source =
        \\enum Choice { left, middle, right }
        \\fn choose(value: Choice) -> u32 {
        \\    switch value {
        \\        .left => { return 1; },
        \\        .middle => { return 2; },
        \\        .right => { return 3; },
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_enum_switch_multi_arm_returns.mc", source, &output);
    try expectContains(output.items, "; canonical executable MIR");
    try expectContains(output.items, "switch ");
    try expectContains(output.items, "label %mc_block_");
    try expectContains(output.items, "ret i32 1");
    try expectContains(output.items, "ret i32 2");
    try expectContains(output.items, "ret i32 3");
    try expectContains(output.items, "call void @mc_trap_InvalidRepresentation()");
}

test "LLVM if-let statements require MIR subject types" {
    const source =
        \\extern fn make_result() -> Result<u32, u32>;
        \\extern fn make_nullable() -> ?*const u8;
        \\fn result_subject(value: Result<u32, u32>) -> u32 { if let ok(v) = value { return v; } else { return 0; } }
        \\fn nullable_subject(value: ?*const u8) -> u32 { if let p = value { return 1; } else { return 0; } }
        \\fn result_call_subject() -> u32 { if let ok(v) = make_result() { return v; } else { return 0; } }
        \\fn nullable_call_subject() -> u32 { if let p = make_nullable() { return 1; } else { return 0; } }
    ;
    var parsed = try test_support.parseCheckedModule("llvm_if_let_subject_type_facts.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_if_let_subject_type_facts.mc", .{}, false, .riscv64, null);
    for ([_][]const u8{ "result_subject", "nullable_subject", "result_call_subject", "nullable_call_subject" }) |name| {
        try std.testing.expect(std.mem.indexOf(u8, complete_output.items, name) != null);
    }

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "result_subject", .if_let_subject);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_if_let_subject_type_facts.mc", .{}, false, .riscv64, null));

    for ([_][]const u8{ "result_subject", "nullable_subject" }) |name| {
        var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer stale.deinit();
        try renameTargetTypeFactForFunction(&stale, name, .if_let_subject, "u32");
        var stale_output: std.ArrayList(u8) = .empty;
        defer stale_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_if_let_subject_type_facts.mc", .{}, false, .riscv64, null));
    }

    var stale_nullable_repr = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale_nullable_repr.deinit();
    try retargetTargetTypeResultForFunction(&stale_nullable_repr, "nullable_subject", .if_let_subject, .{ .nullable_value = "u32" });
    var stale_nullable_repr_output: std.ArrayList(u8) = .empty;
    defer stale_nullable_repr_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_nullable_repr, &stale_nullable_repr_output, "llvm_if_let_subject_type_facts.mc", .{}, false, .riscv64, null));
}

test "LLVM try expressions require MIR operand and result types" {
    const source =
        \\extern fn make_result() -> Result<u32, u32>;
        \\extern fn make_nullable() -> ?*const u8;
        \\fn result_try() -> Result<u32, u32> { let value = make_result()?; return ok(value); }
        \\fn nullable_try() -> *const u8 { let value = make_nullable()?; return value; }
    ;
    var parsed = try test_support.parseCheckedModule("llvm_try_operand_type_facts.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_try_operand_type_facts.mc", .{}, false, .riscv64, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "result_try") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "nullable_try") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "result_try", .try_operand);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_try_operand_type_facts.mc", .{}, false, .riscv64, null));

    var missing_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_result.deinit();
    try removeTargetTypeKindForFunction(&missing_result, "result_try", .expression_result);
    var missing_result_output: std.ArrayList(u8) = .empty;
    defer missing_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_result, &missing_result_output, "llvm_try_operand_type_facts.mc", .{}, false, .riscv64, null));

    for ([_][]const u8{ "result_try", "nullable_try" }) |name| {
        var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer stale.deinit();
        try renameTargetTypeFactForFunction(&stale, name, .try_operand, "u32");
        var stale_output: std.ArrayList(u8) = .empty;
        defer stale_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_try_operand_type_facts.mc", .{}, false, .riscv64, null));
    }

    for ([_][]const u8{ "result_try", "nullable_try" }) |name| {
        var stale_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer stale_result.deinit();
        try renameTargetTypeFactForFunction(&stale_result, name, .expression_result, "u64");
        var stale_result_output: std.ArrayList(u8) = .empty;
        defer stale_result_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_result, &stale_result_output, "llvm_try_operand_type_facts.mc", .{}, false, .riscv64, null));
    }
}

test "LLVM for loops require MIR iterable and element types" {
    const source =
        \\extern fn make_slice() -> []const u32;
        \\fn array_loop(values: [2]u32) -> u32 { for value in values { return value; } return 0; }
        \\fn slice_loop(values: []const u32) -> u32 { for value in values { return value; } return 0; }
        \\fn call_loop() -> u32 { for value in make_slice() { return value; } return 0; }
    ;
    var parsed = try test_support.parseCheckedModule("llvm_for_loop_type_facts.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_for_loop_type_facts.mc", .{}, false, .riscv64, null);
    for ([_][]const u8{ "array_loop", "slice_loop", "call_loop" }) |name| {
        try std.testing.expect(std.mem.indexOf(u8, complete_output.items, name) != null);
    }

    for ([_]mir.TargetTypeKind{ .for_iterable, .for_element }) |kind| {
        var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer missing.deinit();
        try removeTargetTypeKindForFunction(&missing, "array_loop", kind);
        var missing_output: std.ArrayList(u8) = .empty;
        defer missing_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_for_loop_type_facts.mc", .{}, false, .riscv64, null));

        var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer stale.deinit();
        try renameTargetTypeFactForFunction(&stale, "array_loop", kind, "u64");
        var stale_output: std.ArrayList(u8) = .empty;
        defer stale_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_for_loop_type_facts.mc", .{}, false, .riscv64, null));
    }
}

test "LLVM inferred local copies require MIR types" {
    const source =
        \\fn copies(value: u64, ptr: *u8) -> u64 {
        \\    let copied_value = value;
        \\    let copied_ptr = ptr;
        \\    return copied_value;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("llvm_inferred_local_copy_types.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_inferred_local_copy_types.mc", .{}, false, .riscv64, null);
    const copies_body = try llvmFunctionBody(complete_output.items, "define internal i64 @copies");
    try expectContains(copies_body, "; canonical executable MIR");
    try expectContains(copies_body, "alloca i64");
    try expectContains(copies_body, "icmp eq ptr %mc_arg_1, null");

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "copies", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_inferred_local_copy_types.mc", .{}, false, .riscv64, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "copies", .inferred_local, "u32");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_inferred_local_copy_types.mc", .{}, false, .riscv64, null));
}

test "LLVM inferred local casts require MIR types" {
    const source =
        \\fn casts(value: u64, ptr: *const u64) -> u32 {
        \\    let narrowed = value as u32;
        \\    let view = ptr as *const u64;
        \\    return narrowed;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("llvm_inferred_local_cast_types.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_inferred_local_cast_types.mc", .{}, false, .riscv64, null);
    const casts_body = try llvmFunctionBody(complete_output.items, "define internal i32 @casts");
    try expectContains(casts_body, "; canonical executable MIR");
    try expectContains(casts_body, "trunc i64 %mc_arg_0 to i32");
    try expectContains(casts_body, "icmp eq ptr %mc_arg_1, null");

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "casts", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_inferred_local_cast_types.mc", .{}, false, .riscv64, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "casts", .inferred_local, "u64");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_inferred_local_cast_types.mc", .{}, false, .riscv64, null));
}

test "LLVM inferred local binary expressions require MIR types" {
    const source =
        \\fn binary(base: u64, limit: u64, left: bool, right: bool) -> u64 {
        \\    let sum = base + 1;
        \\    let is_less = base < limit;
        \\    let both = left && right;
        \\    if is_less && both { return sum; }
        \\    return base;
        \\}
        \\fn bitwise(value: u32) -> u32 {
        \\    let combined = value & 7;
        \\    let shifted = combined << 1;
        \\    return combined | shifted;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("llvm_inferred_local_binary_types.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_inferred_local_binary_types.mc", .{}, false, .riscv64, null);
    const binary_body = try llvmFunctionBody(complete_output.items, "define internal i64 @binary");
    try expectContains(binary_body, "; canonical executable MIR");
    try expectContains(binary_body, "@llvm.uadd.with.overflow.i64");
    try expectContains(binary_body, "icmp ult i64");
    try expectContains(binary_body, "and i1");
    const bitwise_body = try llvmFunctionBody(complete_output.items, "define internal i32 @bitwise");
    try expectContains(bitwise_body, "; canonical executable MIR");
    try expectContains(bitwise_body, "and i32");
    try expectContains(bitwise_body, "shl i64");
    try expectContains(bitwise_body, "or i32");

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "binary", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_inferred_local_binary_types.mc", .{}, false, .riscv64, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "binary", .inferred_local, "u32");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_inferred_local_binary_types.mc", .{}, false, .riscv64, null));

    var missing_bitwise = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_bitwise.deinit();
    try removeTargetTypeKindForFunction(&missing_bitwise, "bitwise", .inferred_local);
    var missing_bitwise_output: std.ArrayList(u8) = .empty;
    defer missing_bitwise_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_bitwise, &missing_bitwise_output, "llvm_inferred_local_binary_types.mc", .{}, false, .riscv64, null));

    var stale_bitwise = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale_bitwise.deinit();
    try renameTargetTypeFactForFunction(&stale_bitwise, "bitwise", .inferred_local, "u64");
    var stale_bitwise_output: std.ArrayList(u8) = .empty;
    defer stale_bitwise_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_bitwise, &stale_bitwise_output, "llvm_inferred_local_binary_types.mc", .{}, false, .riscv64, null));
}

test "LLVM inferred local literals require MIR types" {
    const source =
        \\fn literals() -> u32 {
        \\    let count = 7;
        \\    let enabled = true;
        \\    if enabled { return count; }
        \\    return 0;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("llvm_inferred_local_literal_types.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_inferred_local_literal_types.mc", .{}, false, .riscv64, null);
    // Local spelling is not semantic identity.  The canonical executable MIR
    // renderer names storage by LocalId, so assert the typed values instead of
    // coupling this test to source variable names.
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "store i32 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "store i1 true") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "literals", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_inferred_local_literal_types.mc", .{}, false, .riscv64, null));

    var missing_literal_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_literal_result.deinit();
    try removeTargetTypeKindForFunction(&missing_literal_result, "literals", .expression_result);
    var missing_literal_result_output: std.ArrayList(u8) = .empty;
    defer missing_literal_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_literal_result, &missing_literal_result_output, "llvm_inferred_local_literal_types.mc", .{}, false, .riscv64, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "literals", .inferred_local, "u64");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_inferred_local_literal_types.mc", .{}, false, .riscv64, null));

    var stale_literal_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale_literal_result.deinit();
    try renameTargetTypeFactForFunction(&stale_literal_result, "literals", .expression_result, "u64");
    var stale_literal_result_output: std.ArrayList(u8) = .empty;
    defer stale_literal_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_literal_result, &stale_literal_result_output, "llvm_inferred_local_literal_types.mc", .{}, false, .riscv64, null));
}

test "LLVM sequenced comparison literals require MIR result types" {
    const source =
        \\fn wide() -> u64 { return 9; }
        \\fn compare() -> bool { return wide() == 7; }
    ;
    var parsed = try test_support.parseCheckedModule("llvm_condition_literal_result.mc", source);
    defer parsed.deinit();
    const literal_offset = std.mem.indexOf(u8, source, "7") orelse return error.TestUnexpectedResult;

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_condition_literal_result.mc", .{}, false, .riscv64, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "icmp eq i64") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeFactAtOffsetForFunction(&missing, "compare", .expression_result, literal_offset, 1);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_condition_literal_result.mc", .{}, false, .riscv64, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactAtOffsetForFunction(&stale, "compare", .expression_result, literal_offset, 1, "bool");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_condition_literal_result.mc", .{}, false, .riscv64, null));
}

test "LLVM sequenced comparison member operands require MIR result types" {
    const source =
        \\struct Holder { value: u64 }
        \\fn compare(holder: Holder) -> bool { return holder.value == 7; }
    ;
    const member_text = "holder.value";
    const member_offset = std.mem.indexOf(u8, source, member_text) orelse return error.TestUnexpectedResult;
    var parsed = try test_support.parseCheckedModule("llvm_condition_member_result.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_condition_member_result.mc", .{}, false, .riscv64, null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeFactAtOffsetForFunction(&missing, "compare", .expression_result, member_offset, member_text.len);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_condition_member_result.mc", .{}, false, .riscv64, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactAtOffsetForFunction(&stale, "compare", .expression_result, member_offset, member_text.len, "bool");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_condition_member_result.mc", .{}, false, .riscv64, null));
}

test "LLVM boolean expressions require MIR result types" {
    const source =
        \\fn compare(left: u32, right: u32) -> bool { return !(left < right); }
    ;
    const comparison_text = "left < right";
    const comparison_offset = std.mem.indexOf(u8, source, comparison_text) orelse return error.TestUnexpectedResult;
    var parsed = try test_support.parseCheckedModule("llvm_boolean_expression_result.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_boolean_expression_result.mc", .{}, false, .riscv64, null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeFactAtOffsetForFunction(&missing, "compare", .expression_result, comparison_offset, comparison_text.len);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_boolean_expression_result.mc", .{}, false, .riscv64, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactAtOffsetForFunction(&stale, "compare", .expression_result, comparison_offset, comparison_text.len, "u32");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_boolean_expression_result.mc", .{}, false, .riscv64, null));
}

test "LLVM inferred local unary expressions require MIR types" {
    const source =
        \\fn unary(value: i64, enabled: bool) -> i64 {
        \\    let negated = -value;
        \\    let disabled = !enabled;
        \\    if disabled { return negated; }
        \\    return value;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("llvm_inferred_local_unary_types.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_inferred_local_unary_types.mc", .{}, false, .riscv64, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "llvm.ssub.with.overflow.i64") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "xor i1") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "unary", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_inferred_local_unary_types.mc", .{}, false, .riscv64, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "unary", .inferred_local, "i32");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_inferred_local_unary_types.mc", .{}, false, .riscv64, null));
}

test "LLVM inferred local direct calls require MIR types" {
    const source =
        \\fn make_count() -> u64 { return 7; }
        \\fn caller() -> u64 {
        \\    let count = make_count();
        \\    return count;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("llvm_inferred_local_call_types.mc", source);
    defer parsed.deinit();

    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_inferred_local_call_types.mc", source, &complete_output);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "@make_count") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "caller", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_inferred_local_call_types.mc", .{}, false, .riscv64, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "caller", .inferred_local, "u32");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_inferred_local_call_types.mc", .{}, false, .riscv64, null));

    const caller_offset = std.mem.indexOf(u8, source, "fn caller") orelse return error.TestUnexpectedResult;
    const call_offset = std.mem.indexOfPos(u8, source, caller_offset, "make_count()") orelse return error.TestUnexpectedResult;

    var missing_call_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_call_result.deinit();
    try removeTargetTypeFactAtOffsetForFunction(&missing_call_result, "caller", .expression_result, call_offset, "make_count()".len);
    var missing_call_result_output: std.ArrayList(u8) = .empty;
    defer missing_call_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_call_result, &missing_call_result_output, "llvm_inferred_local_call_types.mc", .{}, false, .riscv64, null));

    var stale_call_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale_call_result.deinit();
    try renameTargetTypeFactAtOffsetForFunction(&stale_call_result, "caller", .expression_result, call_offset, "make_count()".len, "u32");
    var stale_call_result_output: std.ArrayList(u8) = .empty;
    defer stale_call_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_call_result, &stale_call_result_output, "llvm_inferred_local_call_types.mc", .{}, false, .riscv64, null));
}

test "LLVM inferred local Result direct calls require MIR types" {
    const source =
        \\enum Error: u8 { failed = 1 }
        \\extern fn make_result() -> Result<u32, Error>;
        \\fn caller() -> bool {
        \\    let result = make_result();
        \\    switch result {
        \\        ok(v) => { return v != 0; },
        \\        err(e) => { return e != 0; },
        \\    }
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("llvm_inferred_local_result_call_types.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_inferred_local_result_call_types.mc", .{}, false, .riscv64, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "; canonical executable MIR") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "@make_result()") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "caller", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_inferred_local_result_call_types.mc", .{}, false, .riscv64, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "caller", .inferred_local, "u64");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_inferred_local_result_call_types.mc", .{}, false, .riscv64, null));
}

test "LLVM inferred local indirect calls require MIR types" {
    const source =
        \\fn caller(callback: fn(u32) -> u32, value: u32) -> u32 {
        \\    let result = callback(value);
        \\    return result;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("llvm_inferred_local_indirect_call_types.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_inferred_local_indirect_call_types.mc", .{}, false, .riscv64, null);
    try expectContains(complete_output.items, "; canonical executable MIR");
    try expectContains(complete_output.items, "call i32 %mc_arg_0(i32 %mc_arg_1)");
    try expectContains(complete_output.items, "ret i32 %mc_expr_tmp_");

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "caller", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_inferred_local_indirect_call_types.mc", .{}, false, .riscv64, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "caller", .inferred_local, "u64");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_inferred_local_indirect_call_types.mc", .{}, false, .riscv64, null));
}

test "LLVM inferred local atomic and MaybeUninit calls require MIR types" {
    const source =
        \\struct Node { value: u32 }
        \\
        \\fn atomic_inferred_locals() -> u32 {
        \\    var counter: atomic<u32> = atomic.init(1);
        \\    let previous = counter.fetch_add(3, .acq_rel);
        \\    let loaded = counter.load(.acquire);
        \\    return previous + loaded;
        \\}
        \\
        \\fn maybe_uninit_inferred_local() -> u32 {
        \\    var slot: MaybeUninit<Node> = uninit;
        \\    slot.write(.{ .value = 7 });
        \\    let value = slot.assume_init();
        \\    return value.value;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("llvm_builtin_inferred_local_types.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_builtin_inferred_local_types.mc", .{}, false, .riscv64, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "; canonical executable MIR") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "atomicrmw add") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "load atomic") != null);
    try expectContains(complete_output.items, "store { i32 }");
    try expectContains(complete_output.items, "load { i32 }");

    for ([_][]const u8{ "atomic_inferred_locals", "maybe_uninit_inferred_local" }) |name| {
        var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer missing.deinit();
        try removeTargetTypeKindForFunction(&missing, name, .inferred_local);
        var missing_output: std.ArrayList(u8) = .empty;
        defer missing_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_builtin_inferred_local_types.mc", .{}, false, .riscv64, null));

        var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer stale.deinit();
        try renameTargetTypeFactForFunction(&stale, name, .inferred_local, "u64");
        var stale_output: std.ArrayList(u8) = .empty;
        defer stale_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_builtin_inferred_local_types.mc", .{}, false, .riscv64, null));
    }
}

test "LLVM inferred local phys calls require MIR types" {
    const source =
        \\fn inferred_phys(value: usize) -> PAddr {
        \\    let address = phys(value);
        \\    return address;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("llvm_inferred_phys_local_type.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_inferred_phys_local_type.mc", .{}, false, .riscv64, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "; canonical executable MIR") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "%mc_local_1 = alloca i64") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "inferred_phys", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_inferred_phys_local_type.mc", .{}, false, .riscv64, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "inferred_phys", .inferred_local, "u64");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_inferred_phys_local_type.mc", .{}, false, .riscv64, null));
}

test "LLVM inferred local bitcast calls require MIR types" {
    const source =
        \\fn inferred_bitcast(value: f32) -> u32 {
        \\    let bits = bitcast<u32>(value);
        \\    return bits;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("llvm_inferred_bitcast_local_type.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_inferred_bitcast_local_type.mc", .{}, false, .riscv64, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "; canonical executable MIR") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "inferred_bitcast", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_inferred_bitcast_local_type.mc", .{}, false, .riscv64, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "inferred_bitcast", .inferred_local, "u64");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_inferred_bitcast_local_type.mc", .{}, false, .riscv64, null));
}

test "LLVM inferred local byte-view calls require MIR types" {
    const source =
        \\fn inferred_byte_view(value: u32) -> u8 {
        \\    var storage: u32 = value;
        \\    let bytes = mem.as_bytes(&storage);
        \\    return bytes[0];
        \\}
        \\
        \\fn inferred_byte_equal(left: []const u8, right: []const u8) -> bool {
        \\    let equal = mem.bytes_equal(left, right);
        \\    return equal;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("llvm_inferred_byte_view_local_types.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_inferred_byte_view_local_types.mc", .{}, false, .riscv64, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "; canonical executable MIR") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "insertvalue { ptr, i64 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "mc_bytes_equal_cond_") != null);

    for ([_][]const u8{ "inferred_byte_view", "inferred_byte_equal" }) |name| {
        var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer missing.deinit();
        try removeTargetTypeKindForFunction(&missing, name, .inferred_local);
        var missing_output: std.ArrayList(u8) = .empty;
        defer missing_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_inferred_byte_view_local_types.mc", .{}, false, .riscv64, null));

        var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer stale.deinit();
        try renameTargetTypeFactForFunction(&stale, name, .inferred_local, "u64");
        var stale_output: std.ArrayList(u8) = .empty;
        defer stale_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_inferred_byte_view_local_types.mc", .{}, false, .riscv64, null));
    }
}

test "LLVM inferred local enum raw calls require MIR types" {
    const source =
        \\enum Color: u32 { red = 1 }
        \\fn inferred_enum_raw(value: Color) -> u32 {
        \\    let raw = value.raw();
        \\    return raw;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("llvm_inferred_enum_raw_local_type.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_inferred_enum_raw_local_type.mc", .{}, false, .riscv64, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "; canonical executable MIR") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "inferred_enum_raw", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_inferred_enum_raw_local_type.mc", .{}, false, .riscv64, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "inferred_enum_raw", .inferred_local, "u64");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_inferred_enum_raw_local_type.mc", .{}, false, .riscv64, null));
}

test "LLVM inferred local conversion calls require MIR types" {
    const source =
        \\fn inferred_conversion(value: u64) -> u8 {
        \\    let narrowed = u8.trap_from(value);
        \\    return narrowed;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("llvm_inferred_conversion_local_type.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_inferred_conversion_local_type.mc", .{}, false, .riscv64, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "; canonical executable MIR") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "alloca i8") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "inferred_conversion", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_inferred_conversion_local_type.mc", .{}, false, .riscv64, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "inferred_conversion", .inferred_local, "u64");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_inferred_conversion_local_type.mc", .{}, false, .riscv64, null));
}

test "LLVM inferred local reflection calls require MIR types" {
    const source =
        \\fn inferred_reflection() -> usize {
        \\    let size = size_of<u32>();
        \\    return size;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("llvm_inferred_reflection_local_type.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_inferred_reflection_local_type.mc", .{}, false, .riscv64, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "; canonical executable MIR") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "inferred_reflection", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_inferred_reflection_local_type.mc", .{}, false, .riscv64, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "inferred_reflection", .inferred_local, "u64");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_inferred_reflection_local_type.mc", .{}, false, .riscv64, null));
}

test "LLVM inferred local semantic escape calls require MIR types" {
    const source =
        \\fn inferred_noalias(pointer: *mut u8, len: usize) -> *mut u8 {
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        let alias = compiler.assume_noalias_unchecked(pointer, len);
        \\        return alias;
        \\    }
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("llvm_inferred_semantic_escape_local_type.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_inferred_semantic_escape_local_type.mc", .{}, false, .riscv64, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "; canonical executable MIR") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "ret ptr") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "inferred_noalias", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_inferred_semantic_escape_local_type.mc", .{}, false, .riscv64, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "inferred_noalias", .inferred_local, "u64");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_inferred_semantic_escape_local_type.mc", .{}, false, .riscv64, null));
}

test "LLVM inferred local raw result calls require MIR types" {
    const source =
        \\fn inferred_raw_load(addr: PAddr) -> u32 {
        \\    unsafe {
        \\        let value = raw.load<u32>(addr);
        \\        return value;
        \\    }
        \\}
        \\
        \\fn inferred_raw_ptr(addr: PAddr) -> *mut u32 {
        \\    unsafe {
        \\        let pointer = raw.ptr<u32>(addr);
        \\        return pointer;
        \\    }
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("llvm_inferred_raw_local_types.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_inferred_raw_local_types.mc", .{}, false, .riscv64, null);
    const raw_load = try llvmFunctionBody(complete_output.items, "define internal i32 @inferred_raw_load");
    try expectContains(raw_load, "; canonical executable MIR");
    try expectContains(raw_load, "load volatile i32, ptr");
    const raw_pointer = try llvmFunctionBody(complete_output.items, "define internal ptr @inferred_raw_ptr");
    try expectContains(raw_pointer, "; canonical executable MIR");
    try expectContains(raw_pointer, "inttoptr i64");
    try expectContains(raw_pointer, "mc_trap_InvalidRepresentation");

    for ([_][]const u8{ "inferred_raw_load", "inferred_raw_ptr" }) |name| {
        var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer missing.deinit();
        try removeTargetTypeKindForFunction(&missing, name, .inferred_local);
        var missing_output: std.ArrayList(u8) = .empty;
        defer missing_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_inferred_raw_local_types.mc", .{}, false, .riscv64, null));

        var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer stale.deinit();
        try renameTargetTypeFactForFunction(&stale, name, .inferred_local, "u64");
        var stale_output: std.ArrayList(u8) = .empty;
        defer stale_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_inferred_raw_local_types.mc", .{}, false, .riscv64, null));
    }
}

test "LLVM inferred local dyn dispatch calls require MIR types" {
    const source =
        \\trait Shape { fn scale(self: *Self, amount: u32) -> u32; fn set(self: *mut Self, value: u32) -> void; }
        \\struct Square { side: u32 }
        \\struct Holder { shape: *mut dyn Shape }
        \\impl Shape for Square { fn scale(self: *Square, amount: u32) -> u32 { return self.side * amount; } fn set(self: *mut Square, value: u32) -> void { self.side = value; } }
        \\fn caller(shape: *dyn Shape, amount: u32) -> u32 {
        \\    let result = shape.scale(amount);
        \\    return result;
        \\}
        \\fn notify(shape: *mut dyn Shape, value: u32) -> void { shape.set(value); }
        \\fn holder_init(holder: *mut Holder, shape: *mut dyn Shape) -> void { holder.shape = shape; }
        \\fn holder_scale(holder: *mut Holder, amount: u32) -> u32 { return holder.shape.scale(amount); }
    ;
    var parsed = try test_support.parseCheckedModule("llvm_inferred_local_dyn_dispatch_call_types.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_inferred_local_dyn_dispatch_call_types.mc", .{}, false, .riscv64, null);
    const caller_body = try llvmFunctionBody(complete_output.items, "define internal i32 @caller");
    try expectContains(caller_body, "; canonical executable MIR");
    try expectContains(caller_body, "getelementptr ptr, ptr");
    try expectContains(caller_body, "call i32 %");
    const notify_body = try llvmFunctionBody(complete_output.items, "define internal void @notify");
    try expectContains(notify_body, "; canonical executable MIR");
    try expectContains(notify_body, "call void %");
    const holder_init_body = try llvmFunctionBody(complete_output.items, "define internal void @holder_init");
    try expectContains(holder_init_body, "; canonical executable MIR");
    try expectContains(holder_init_body, "store atomic ptr");
    const holder_scale_body = try llvmFunctionBody(complete_output.items, "define internal i32 @holder_scale");
    try expectContains(holder_scale_body, "; canonical executable MIR");
    try expectContains(holder_scale_body, "getelementptr ptr, ptr");

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "caller", .dyn_dispatch_result);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, "llvm_inferred_local_dyn_dispatch_call_types.mc", .{}, false, .riscv64, null));

    var missing_argument = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_argument.deinit();
    try removeTargetTypeKindForFunction(&missing_argument, "caller", .dyn_dispatch_argument);
    var missing_argument_output: std.ArrayList(u8) = .empty;
    defer missing_argument_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_argument, &missing_argument_output, "llvm_inferred_local_dyn_dispatch_call_types.mc", .{}, false, .riscv64, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "caller", .dyn_dispatch_result, "u64");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_inferred_local_dyn_dispatch_call_types.mc", .{}, false, .riscv64, null));

    var stale_argument = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale_argument.deinit();
    try renameTargetTypeFactForFunction(&stale_argument, "caller", .dyn_dispatch_argument, "u64");
    var stale_argument_output: std.ArrayList(u8) = .empty;
    defer stale_argument_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_argument, &stale_argument_output, "llvm_inferred_local_dyn_dispatch_call_types.mc", .{}, false, .riscv64, null));
}

test "LLVM ordinary direct calls require MIR result and argument types" {
    const source =
        \\fn widen(value: u64) -> u64 { return value; }
        \\fn caller(value: u64) -> u64 { return widen(value); }
    ;
    var parsed = try test_support.parseCheckedModule("llvm_direct_call_type_facts.mc", source);
    defer parsed.deinit();

    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_direct_call_type_facts.mc", source, &complete_output);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "call i64 @widen(i64") != null);

    var missing_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_result.deinit();
    try removeTargetTypeKindForFunction(&missing_result, "caller", .direct_call_result);
    var missing_result_output: std.ArrayList(u8) = .empty;
    defer missing_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_result, &missing_result_output, "llvm_direct_call_type_facts.mc", .{}, false, .riscv64, null));

    var missing_argument = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_argument.deinit();
    try removeTargetTypeKindForFunction(&missing_argument, "caller", .direct_call_argument);
    var missing_argument_output: std.ArrayList(u8) = .empty;
    defer missing_argument_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_argument, &missing_argument_output, "llvm_direct_call_type_facts.mc", .{}, false, .riscv64, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "caller", .direct_call_result, "u32");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_direct_call_type_facts.mc", .{}, false, .riscv64, null));

    var stale_signature = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale_signature.deinit();
    var changed = false;
    for (stale_signature.functions) |*function| {
        if (!std.mem.eql(u8, function.name, "widen")) continue;
        try std.testing.expectEqual(@as(usize, 1), function.param_types.len);
        function.param_types[0] = .{ .integer = "u32" };
        changed = true;
    }
    try std.testing.expect(changed);
    var stale_signature_output: std.ArrayList(u8) = .empty;
    defer stale_signature_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirExecutableBody, appendLlvmCheckedMirProfileDeclsTest(std.testing.allocator, parsed.decls(), &stale_signature, &stale_signature_output, "llvm_direct_call_signature_mutation.mc", .{}, false, .riscv64, false, null));
}

test "LLVM indirect calls require MIR callee signature facts" {
    const source =
        \\fn increment(value: u32) -> u32 { return value + 1; }
        \\fn invoke_pointer(callback: fn(u32) -> u32, value: u32) -> u32 { return callback(value); }
        \\fn invoke_closure(callback: closure(u32) -> u32, value: u32) -> u32 { return callback(value); }
    ;
    var parsed = try test_support.parseCheckedModule("llvm_indirect_call_signature_facts.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, "llvm_indirect_call_signature_facts.mc", .{}, false, .riscv64, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "call i32 %") != null);

    for ([_][]const u8{ "invoke_pointer", "invoke_closure" }) |name| {
        var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer missing.deinit();
        try removeTargetTypeKindForFunction(&missing, name, .indirect_call_callee);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &output, "llvm_indirect_call_signature_facts.mc", .{}, false, .riscv64, null));

        var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer stale.deinit();
        try renameTargetTypeFactForFunction(&stale, name, .indirect_call_callee, "u32");
        var stale_output: std.ArrayList(u8) = .empty;
        defer stale_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, "llvm_indirect_call_signature_facts.mc", .{}, false, .riscv64, null));
    }
}

test "LLVM direct global closure calls use canonical fat-value loads" {
    const source =
        \\struct Slot { run: closure(u32) -> u32 }
        \\global slot: Slot;
        \\global table: [4]Slot;
        \\fn invoke(value: u32) -> u32 { return slot.run(value); }
        \\fn invoke_at(index: usize, value: u32) -> u32 { return table[index].run(value); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_direct_global_closure.mc", source, &output);

    for ([_][]const u8{ "@invoke", "@invoke_at" }) |name| {
        const body = try llvmFunctionBody(output.items, name);
        try expectContains(body, "; canonical executable MIR");
        try expectContains(body, "load atomic ptr");
        try expectContains(body, "insertvalue { ptr, ptr }");
        try expectContains(body, "extractvalue { ptr, ptr }");
        try expectContains(body, "call i32 %");
    }
}

test "LLVM rejects prebuilt MIR with missing cpu pause call target facts" {
    const source =
        \\fn cpu_pause_call_target_fact_gate() -> void {
        \\    unsafe { cpu.pause(); }
        \\}
    ;

    var parsed = try test_support.parseModule("llvm_missing_cpu_pause_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "cpu_pause_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_missing_cpu_pause_call_target_facts.mc", .{}, false, .riscv64, null),
    );
}

test "LLVM emits cpu pause after MIR call-target dispatch" {
    const source =
        \\fn cpu_pause_call_target_dispatch() -> void {
        \\    unsafe { cpu.pause(); }
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_cpu_pause_call_target_dispatch.mc", source, &output);
    try expectContains(output.items, "call void asm sideeffect \"pause\", \"~{memory}\"()");
}

test "LLVM emits opaque asm from canonical executable MIR" {
    const source =
        \\fn asm_in_unsafe() -> void {
        \\    unsafe { asm opaque volatile { "pause" clobber("memory") } }
        \\}
        \\fn boot_asm() -> void {
        \\    unsafe { asm opaque volatile { "cli" "hlt" } }
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_canonical_opaque_asm.mc", source, &output);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.items, "; canonical executable MIR"));
    try expectContains(output.items, "call void asm sideeffect \"pause\", \"~{memory}\"()");
    try expectContains(output.items, "call void asm sideeffect \"cli\\0A\\09hlt\", \"~{memory}\"()");
}

test "LLVM emits precise asm from canonical executable MIR" {
    const source =
        \\fn find_first_set(mask: u64) -> u64 {
        \\    var idx: u64 = 0;
        \\    #[unsafe_contract(precise_asm)] {
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
    try appendLlvmCheckedMirTest("llvm_canonical_precise_asm.mc", source, &output);
    try expectContains(output.items, "; canonical executable MIR");
    try expectContains(output.items, "call i64 asm sideeffect \"bsf $1, $0\", \"=r,r,~{cc}\"");
}

test "LLVM pointer-member closure loads lower leaf-wise race-tolerantly" {
    const source =
        \\struct Env { tag: u32 }
        \\fn run_impl(env: *mut Env, value: u32) -> u32 { return value + env.tag; }
        \\struct Slot { run: closure(u32) -> u32 }
        \\fn invoke(slot: *Slot, value: u32) -> u32 {
        \\    let callback: closure(u32) -> u32 = slot.run;
        \\    return callback(value);
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_pointer_member_closure_load.mc", source, &output);
    try expectContains(output.items, "load atomic ptr, ptr %");
    try expectContains(output.items, "insertvalue { ptr, ptr }");
    try expectContains(output.items, "call i32 %");
}

test "LLVM pointer-member slice copies lower leaf-wise race-tolerantly" {
    const source =
        \\struct Holder { view: []const u8 }
        \\fn load_view(holder: *mut Holder) -> []const u8 {
        \\    return holder.view;
        \\}
        \\fn store_view(holder: *mut Holder, value: []const u8) -> void {
        \\    holder.view = value;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_pointer_member_slice_copy.mc", source, &output);

    const load_body = try llvmFunctionBody(output.items, "define internal { ptr, i64 } @load_view");
    try expectContains(load_body, "load atomic ptr, ptr %");
    try expectContains(load_body, "load atomic i64, ptr %");
    try expectContains(load_body, "insertvalue { ptr, i64 }");
    try expectNotContains(load_body, "load atomic { ptr, i64 }");

    const store_body = try llvmFunctionBody(output.items, "define internal void @store_view");
    try expectContains(store_body, "store atomic ptr ");
    try expectContains(store_body, "store atomic i64 ");
    try expectNotContains(store_body, "store atomic { ptr, i64 }");
}

test "LLVM rejects prebuilt MIR with missing fence call target facts" {
    const source =
        \\fn fence_call_target_fact_gate() -> void {
        \\    fence.full();
        \\    fence.release();
        \\    fence.acquire();
        \\}
    ;

    var parsed = try test_support.parseModule("llvm_missing_fence_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "fence_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_missing_fence_call_target_facts.mc", .{}, false, .riscv64, null),
    );
}

test "LLVM rejects prebuilt MIR with stale call target facts" {
    const source =
        \\fn call_target_fact_gate(xs: []const u32) -> Result<u32, Overflow> {
        \\    return reduce.sum_checked<u32>(xs);
        \\}
    ;
    var parsed = try test_support.parseModule("llvm_stale_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try retargetCallTargetFactsForFunction(&module_mir, "call_target_fact_gate", .const_get);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirCallTargetFacts, appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_stale_call_target_facts.mc", .{}, false, .riscv64, null));
}

test "LLVM rejects prebuilt MIR with stale integer facts" {
    const source =
        \\fn integer_fact_gate() -> u8 {
        \\    let a: u8 = 7;
        \\    return a;
        \\}
    ;

    var parsed = try test_support.parseModule("llvm_stale_integer_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try retargetIntegerFactsForFunction(&module_mir, "integer_fact_gate", .{ .integer = "u16" });

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirIntegerFacts,
        appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, "llvm_stale_integer_facts.mc", .{}, false, .riscv64, null),
    );
}

fn appendLlvmTestWithRetargetedRangeFacts(source_name: []const u8, source: []const u8, function_name: []const u8, target: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseModule(source_name, source);
    defer parsed.deinit();

    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try retargetRangeFactsForFunction(&module_mir, function_name, target);

    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, output, source_name, .{}, false, .riscv64, null);
}

fn appendLlvmTestWithoutPointerProvenanceFactsForSubject(source_name: []const u8, source: []const u8, function_name: []const u8, subject: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseModule(source_name, source);
    defer parsed.deinit();

    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearPointerProvenanceFactsForFunctionSubject(&module_mir, function_name, subject);

    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, output, source_name, .{}, false, .riscv64, null);
}

fn appendLlvmTestWithoutPointerProvenanceFactsForSubjectField(source_name: []const u8, source: []const u8, function_name: []const u8, subject: []const u8, field_path: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseModule(source_name, source);
    defer parsed.deinit();

    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearPointerProvenanceFactsForFunctionSubjectField(&module_mir, function_name, subject, field_path);

    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, output, source_name, .{}, false, .riscv64, null);
}

fn appendLlvmTestWithoutAggregateReturnPointerFact(source_name: []const u8, source: []const u8, callee: []const u8, field_path: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseModule(source_name, source);
    defer parsed.deinit();

    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearAggregateReturnPointerFact(&module_mir, callee, field_path);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, output, source_name, .{}, false, .riscv64, null);
}

fn llvmFunctionBody(output: []const u8, signature_prefix: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, output, signature_prefix) orelse return error.TestUnexpectedResult;
    const body_end = std.mem.indexOf(u8, output[start..], "\n}\n\n") orelse return error.TestUnexpectedResult;
    return output[start .. start + body_end];
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectLlvmNoOverflowFactRejection(result: anytype) !void {
    if (result) |_| return error.TestExpectedError else |err| switch (err) {
        error.InvalidMirExecutableBody, error.UnsupportedLlvmEmission => {},
        else => return err,
    }
}

fn expectLlvmNoOverflowLegacyRetarget(result: anytype) !void {
    if (result) |_| return else |err| switch (err) {
        error.UnsupportedLlvmEmission => {},
        else => return err,
    }
}

fn expectNeedlesInOrder(haystack: []const u8, needles: []const []const u8) !void {
    var offset: usize = 0;
    for (needles) |needle| {
        const relative = std.mem.indexOf(u8, haystack[offset..], needle) orelse return error.TestUnexpectedResult;
        offset += relative + needle.len;
    }
}

fn expectContainsAny(haystack: []const u8, needles: []const []const u8) !void {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, haystack, needle) != null) return;
    }
    return error.TestUnexpectedResult;
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}

fn expectCanonicalConditional(body: []const u8) !void {
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "br i1 %mc_");
    try expectContains(body, "label %mc_block_");
}

test "LLVM backend emits a backend_name alias for the override symbol" {
    const source =
        \\#[backend_name("rss_helper_x")]
        \\fn helper(x: u64) -> u64 { return x + 1; }
        \\export fn harness() -> u64 { return helper(7); }
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_backend_name_alias.mc", source, &output);

    // The function keeps its source name; the override is exposed via a module-level alias.
    try std.testing.expect(std.mem.indexOf(u8, output.items, "define internal i64 @helper(i64 %") != null);
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
    try appendLlvmCheckedMirTest("llvm_mir_smoke_checked_add.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "define internal i32 @add_one(i32 %") != null);
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
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "; mir range_fact consumed region=1 op=add assumption=no_overflow");
    try expectContains(body, " = add i32 %mc_arg_0, %mc_arg_1");
    try expectNotContains(body, "@llvm.uadd.with.overflow.i32");
    try expectNotContains(body, "call void @mc_trap_IntegerOverflow()");
    try std.testing.expectEqual(@as(usize, 7), std.mem.count(u8, output.items, "mir range_fact consumed"));
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, output.items, " op=add assumption=no_overflow"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.items, " op=mul assumption=no_overflow"));

    var missing_fact_output: std.ArrayList(u8) = .empty;
    defer missing_fact_output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirExecutableBody,
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
        try expectLlvmNoOverflowFactRejection(
            appendLlvmTestWithoutRangeFacts(case.source_name, source, &.{case.function_name}, &missing_non_value_fact_output),
        );
    }

    var wrong_target_output: std.ArrayList(u8) = .empty;
    defer wrong_target_output.deinit(std.testing.allocator);
    try appendLlvmTestWithRetargetedRangeFacts("llvm_range_fact_wrong_target.mc", source, "trusted_add", "wrong_target", &wrong_target_output);
    try expectContains(wrong_target_output.items, "mir range_fact consumed region=1 op=add assumption=no_overflow");

    var wrong_inferred_local_target_output: std.ArrayList(u8) = .empty;
    defer wrong_inferred_local_target_output.deinit(std.testing.allocator);
    try expectLlvmNoOverflowLegacyRetarget(
        appendLlvmTestWithRetargetedRangeFacts("llvm_range_fact_inferred_local_wrong_target.mc", source, "inferred_local", "wrong_target", &wrong_inferred_local_target_output),
    );

    var wrong_aggregate_target_output: std.ArrayList(u8) = .empty;
    defer wrong_aggregate_target_output.deinit(std.testing.allocator);
    try expectLlvmNoOverflowLegacyRetarget(
        appendLlvmTestWithRetargetedRangeFacts("llvm_range_fact_aggregate_wrong_target.mc", source, "aggregate_field_fact", "wrong_target", &wrong_aggregate_target_output),
    );

    var wrong_aggregate_element_target_output: std.ArrayList(u8) = .empty;
    defer wrong_aggregate_element_target_output.deinit(std.testing.allocator);
    try expectLlvmNoOverflowLegacyRetarget(
        appendLlvmTestWithRetargetedRangeFacts("llvm_range_fact_aggregate_element_wrong_target.mc", source, "aggregate_element_fact", "wrong_target", &wrong_aggregate_element_target_output),
    );

    var wrong_call_arg_target_output: std.ArrayList(u8) = .empty;
    defer wrong_call_arg_target_output.deinit(std.testing.allocator);
    try expectLlvmNoOverflowLegacyRetarget(
        appendLlvmTestWithRetargetedRangeFacts("llvm_range_fact_call_arg_wrong_target.mc", source, "call_arg_fact", "wrong_target", &wrong_call_arg_target_output),
    );

    var wrong_assigned_local_target_output: std.ArrayList(u8) = .empty;
    defer wrong_assigned_local_target_output.deinit(std.testing.allocator);
    try expectLlvmNoOverflowLegacyRetarget(
        appendLlvmTestWithRetargetedRangeFacts("llvm_range_fact_assigned_local_wrong_target.mc", source, "assigned_local", "wrong_target", &wrong_assigned_local_target_output),
    );

    var wrong_binary_operand_target_output: std.ArrayList(u8) = .empty;
    defer wrong_binary_operand_target_output.deinit(std.testing.allocator);
    try expectLlvmNoOverflowLegacyRetarget(
        appendLlvmTestWithRetargetedRangeFacts("llvm_range_fact_binary_operand_wrong_target.mc", source, "binary_operand_fact", "wrong_target", &wrong_binary_operand_target_output),
    );
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
    try appendLlvmCheckedMirTest("llvm_mir_aggregate_return_pointer_fact.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_direct_holder");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "mc_aggregate_pointer_ready_");
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

test "LLVM lowers pointer parameter field stores after specialized plan retirement" {
    const source =
        \\struct Cell { value: u32 }
        \\struct Frame { child: Cell, slots: [4]u32 }
        \\fn make_cell(value: u32) -> Cell { return .{ .value = value }; }
        \\fn store_cell(cell: *mut Cell) -> void {
        \\    cell.*.value = 7;
        \\}
        \\fn store_child(frame: *mut Frame, value: u32) -> void {
        \\    frame.*.child = make_cell(value);
        \\}
        \\fn load_child(frame: *mut Frame) -> Cell {
        \\    return frame.*.child;
        \\}
        \\fn load_slot(frame: *mut Frame, index: usize) -> u32 {
        \\    return frame.*.slots[index];
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_pointer_param_field_store.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal void @store_cell");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "getelementptr inbounds { i32 }, ptr %mc_arg_0, i32 0, i32 0");
    try expectContains(body, "store atomic i32 7, ptr %");
    const aggregate_body = try llvmFunctionBody(output.items, "define internal void @store_child");
    try expectContains(aggregate_body, "; canonical executable MIR");
    try expectContains(aggregate_body, "getelementptr inbounds { { i32 }, [4 x i32] }, ptr %mc_arg_0, i32 0, i32 0");
    try expectContains(aggregate_body, "store atomic i32 %");
    const load_body = try llvmFunctionBody(output.items, "define internal { i32 } @load_child");
    try expectContains(load_body, "; canonical executable MIR");
    try expectContains(load_body, "load atomic i32");
    const indexed_load_body = try llvmFunctionBody(output.items, "define internal i32 @load_slot");
    try expectContains(indexed_load_body, "; canonical executable MIR");
    try expectContains(indexed_load_body, "icmp ult i64 %mc_arg_1, 4");
    try expectContains(indexed_load_body, "load atomic i32");
}

test "LLVM admits direct-return checked arithmetic in normal emit without losing source fidelity" {
    // Symmetric to the C backend: a direct `return <checked op of simple operands>`
    // folds no source construct, so the fast path is admitted even with a body
    // fallback available (normal emit). The admitted function carries the checked
    // intrinsic directly and — like every fast-path function — omits the param
    // `llvm.dbg.value` that the AST fallback would emit.
    const source =
        \\fn sub_params(a: u32, b: u32) -> u32 { return b - a; }
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_direct_checked_return.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @sub_params");
    try expectContains(body, "@llvm.usub.with.overflow.i32(i32 %mc_arg_1, i32 %mc_arg_0)");
    // Fast-path admission (not the fallback, which emits param dbg.value).
    try std.testing.expect(std.mem.indexOf(u8, body, "llvm.dbg.value") == null);
}

test "LLVM lowers bare pointer parameter checks through canonical MIR" {
    // The canonical value wrapper validates the ABI value before returning it.
    const source =
        \\fn ret_ptr(p: *mut u32) -> *mut u32 { return p; }
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_bare_ptr_return.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal ptr @ret_ptr");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "icmp eq ptr %mc_arg_0, null");
    try expectContains(body, "ret ptr %mc_arg_0");
    try expectContains(body, "mc_trap_InvalidRepresentation");
    try std.testing.expect(std.mem.indexOf(u8, body, "llvm.dbg.value") == null);
}

test "LLVM applies pointer return coercions through canonical MIR" {
    const source =
        \\fn promote(p: *mut u32) -> ?*mut u32 { return p; }
        \\fn narrow(p: *mut u32) -> *const u32 { return p; }
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_pointer_return_coercions.mc", source, &output);
    for ([_][]const u8{
        "define internal ptr @promote",
        "define internal ptr @narrow",
    }) |signature| {
        const body = try llvmFunctionBody(output.items, signature);
        try expectContains(body, "; canonical executable MIR");
        const guard = std.mem.indexOf(u8, body, "icmp eq ptr %mc_arg_0, null") orelse return error.TestUnexpectedResult;
        const returned = std.mem.indexOf(u8, body, "ret ptr %mc_arg_0") orelse return error.TestUnexpectedResult;
        try std.testing.expect(guard < returned);
    }
}

test "LLVM admits scalar deref returns from MIR; optional-pointee derefs stay on fallback" {
    // `return p.*` for a plain scalar pointee lowers to an unordered atomic load.
    // An optional pointee needs a tag+value load, so it must stay on the fallback.
    const source =
        \\fn read_i32(p: *i32) -> i32 { return p.*; }
        \\fn read_opt(p: *mut ?u32) -> ?u32 { return p.*; }
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_scalar_deref_return.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @read_i32");
    try expectContains(body, "; canonical executable MIR");
    const guard = std.mem.indexOf(u8, body, "icmp eq ptr %mc_arg_0, null") orelse return error.TestUnexpectedResult;
    const load = std.mem.indexOf(u8, body, "load atomic i32, ptr %mc_arg_0 unordered") orelse return error.TestUnexpectedResult;
    try std.testing.expect(guard < load);
    try expectContains(body, "ret i32 ");
    // Optional deref (fallback): loads the tag (i8) too — never a single i32 load.
    const opt = try llvmFunctionBody(output.items, "@read_opt");
    try expectContains(opt, "load atomic i8");
}

test "LLVM admits address-typed scalar deref returns from MIR" {
    // `return p.*` for `*PAddr` (repr i64): `load atomic i64` + `ret i64`.
    const source =
        \\fn deref_pa(p: *PAddr) -> PAddr { return p.*; }
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_addr_deref.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i64 @deref_pa");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "icmp eq ptr %mc_arg_0, null");
    try expectContains(body, "load atomic i64, ptr %mc_arg_0 unordered");
    try expectContains(body, "ret i64 %");
}

test "LLVM checks pointer comparison operands from canonical MIR" {
    // Each nonnull parameter is validated before the ordinary comparison; a
    // contextual null literal is emitted from the same typed pointer operand.
    const source =
        \\fn ptr_eq(a: *u32, b: *u32) -> bool { return a == b; }
        \\fn ptr_present(a: *u32) -> bool { return a != null; }
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_ptr_cmp.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i1 @ptr_eq");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "icmp eq ptr %mc_arg_0, null");
    try expectContains(body, "icmp eq ptr %mc_arg_1, null");
    try expectContains(body, "icmp eq ptr %mc_arg_0, %mc_arg_1");
    try expectContains(body, "mc_trap_InvalidRepresentation");
    const present = try llvmFunctionBody(output.items, "define internal i1 @ptr_present");
    try expectContains(present, "; canonical executable MIR");
    try expectContains(present, "icmp ne ptr %mc_arg_0, null");
}

test "LLVM admits single nested-call argument returns inline" {
    // `return g(f())`: the inner call is emitted once and fed to the outer call
    // (f before g), no ordering ambiguity.
    const source =
        \\extern fn f() -> u32;
        \\extern fn g(x: u32) -> u32;
        \\fn direct() -> u32 { return g(f()); }
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_nested_call.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @direct");
    try expectContains(body, "call i32 @f()");
    try expectContains(body, "call i32 @g(i32 %");
}

test "LLVM admits multi-arg call with one nested call and pure leaves" {
    const source =
        \\extern fn f() -> u32;
        \\extern fn g2(a: u32, b: u32) -> u32;
        \\fn one_call(b: u32) -> u32 { return g2(f(), b); }
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_multi_arg.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @one_call");
    try expectContains(body, "call i32 @f()");
    try expectContains(body, "call i32 @g2(i32 %");
}

test "LLVM admits unsigned wrap binary returns from MIR (i32)" {
    // `return a + b` for `wrap<u32>` lowers to a plain integer `add i32`.
    const source =
        \\fn u_add(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> { return a + b; }
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_wrap_binary.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @u_add");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "add i32 %mc_arg_0, %mc_arg_1");
}

test "LLVM emits raw-many offset from typed MIR without body fallback" {
    const source =
        \\extern fn next_index() -> usize;
        \\fn offset(pointer: [*]mut u8) -> [*]mut u8 {
        \\    unsafe { return pointer.offset(next_index()); }
        \\}
        \\fn load(pointer: [*]const u8) -> u8 {
        \\    unsafe { return pointer.offset(next_index()).*; }
        \\}
        \\fn address(pointer: [*]mut u8) -> *mut u8 {
        \\    unsafe { return &pointer.offset(next_index()).*; }
        \\}
        \\fn store(pointer: [*]mut u8, value: u8) -> void {
        \\    unsafe { pointer.offset(next_index()).* = value; }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_raw_many_offset_executable.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal ptr @offset");
    try expectContains(body, "; canonical executable MIR");
    const call = std.mem.indexOf(u8, body, "call i64 @next_index()") orelse return error.TestUnexpectedResult;
    const offset = std.mem.indexOf(u8, body, "getelementptr i8, ptr %mc_arg_0, i64 %") orelse return error.TestUnexpectedResult;
    const ret = std.mem.indexOf(u8, body, "ret ptr %") orelse return error.TestUnexpectedResult;
    try std.testing.expect(call < offset and offset < ret);

    const load_body = try llvmFunctionBody(output.items, "define internal i8 @load");
    try expectContains(load_body, "; canonical executable MIR");
    try expectContains(load_body, "getelementptr i8");
    try expectContains(load_body, "load atomic i8");
    try expectNotContains(load_body, "mc_trap_InvalidRepresentation");

    const address_body = try llvmFunctionBody(output.items, "define internal ptr @address");
    try expectContains(address_body, "; canonical executable MIR");
    try expectContains(address_body, "getelementptr i8");
    try expectContains(address_body, "ret ptr %");
    try expectNotContains(address_body, "mc_trap_InvalidRepresentation");

    const store_body = try llvmFunctionBody(output.items, "define internal void @store");
    try expectContains(store_body, "; canonical executable MIR");
    try expectContains(store_body, "getelementptr i8");
    try expectContains(store_body, "store atomic i8");
    try expectNotContains(store_body, "mc_trap_InvalidRepresentation");
}

test "LLVM admits plain unsigned bitwise binary returns from MIR (and/or/xor)" {
    const source =
        \\fn u_and(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> { return a & b; }
        \\fn u_xor(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> { return a ^ b; }
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_bitwise.mc", source, &output);
    const and_body = try llvmFunctionBody(output.items, "define internal i32 @u_and");
    try expectContains(and_body, "; canonical executable MIR");
    try expectContains(and_body, "and i32 %mc_arg_0, %mc_arg_1");
    const xor_body = try llvmFunctionBody(output.items, "define internal i32 @u_xor");
    try expectContains(xor_body, "; canonical executable MIR");
    try expectContains(xor_body, "xor i32 %mc_arg_0, %mc_arg_1");
}

test "LLVM admits plain unary returns from MIR (bitwise not, wrapping negate)" {
    const source =
        \\fn bnot(a: u32) -> u32 { return ~a; }
        \\fn wneg(a: wrap<u32>) -> wrap<u32> { return -a; }
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_plain_unary.mc", source, &output);
    const bnot = try llvmFunctionBody(output.items, "define internal i32 @bnot");
    try expectContains(bnot, "; canonical executable MIR");
    try expectContains(bnot, "xor i32 %");
    try expectContains(bnot, ", -1");
    try std.testing.expect(std.mem.indexOf(u8, bnot, "llvm.dbg.value") == null);
    const wneg = try llvmFunctionBody(output.items, "define internal i32 @wneg");
    try expectContains(wneg, "; canonical executable MIR");
    try expectContains(wneg, "sub i32 0, %mc_arg_0");
}

test "LLVM admits scalar pointer-field-load returns from MIR" {
    // `return r.a` lowers to a getelementptr for the field, then an unordered
    // atomic load.
    const source =
        \\struct S { a: u32, b: u64 }
        \\fn get_b(r: *S) -> u64 { return r.b; }
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_scalar_field_load.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i64 @get_b");
    try expectContains(body, "; canonical executable MIR");
    const guard = std.mem.indexOf(u8, body, "icmp eq ptr %mc_arg_0, null") orelse return error.TestUnexpectedResult;
    const field = std.mem.indexOf(u8, body, "getelementptr inbounds { i32, i64 }, ptr %mc_arg_0, i32 0, i32 1") orelse return error.TestUnexpectedResult;
    try std.testing.expect(guard < field);
    try expectContains(body, "load atomic i64, ptr %");
    try expectContains(body, "unordered");
}

test "LLVM admits address-typed pointer-field-load returns from MIR" {
    // `return r.start` for an opaque address field (PAddr, i64): GEP + load i64.
    const source =
        \\struct PhysRange { start: PAddr, len: usize }
        \\fn pr_start(r: *PhysRange) -> PAddr { return r.start; }
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_addr_field.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i64 @pr_start");
    try expectContains(body, "; canonical executable MIR");
    const guard = std.mem.indexOf(u8, body, "icmp eq ptr %mc_arg_0, null") orelse return error.TestUnexpectedResult;
    const field = std.mem.indexOf(u8, body, "getelementptr inbounds { i64, i64 }, ptr %mc_arg_0, i32 0, i32 0") orelse return error.TestUnexpectedResult;
    try std.testing.expect(guard < field);
    try expectContains(body, "load atomic i64, ptr %");
    try expectContains(body, "ret i64 %");
}

test "LLVM admits phys address-constructor returns from MIR" {
    // `phys(v)` (usize -> PAddr, both i64) is a no-op cast: `ret i64 %v`.
    const source =
        \\fn to_pa(v: usize) -> PAddr { return phys(v); }
        \\fn offset(address: PAddr, amount: usize) -> PAddr {
        \\    return phys((address as usize) + amount);
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_phys.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i64 @to_pa");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "ret i64 %mc_arg_0");
    // Fast-path admission (not the fallback, which emits param dbg.value).
    try std.testing.expect(std.mem.indexOf(u8, body, "llvm.dbg.value") == null);
    const offset = try llvmFunctionBody(output.items, "define internal i64 @offset");
    try expectContains(offset, "; canonical executable MIR");
    try expectContains(offset, "call { i64, i1 } @llvm.uadd.with.overflow.i64");
    try expectContains(offset, "call void @mc_trap_IntegerOverflow()");
}

test "LLVM emits global address direct-call args from MIR without body fallback" {
    const source =
        \\global shared_counter: u32 = 0;
        \\
        \\fn consume_ptr(ptr: *mut u32) -> u32 {
        \\    return 7;
        \\}
        \\
        \\fn use_global_address_arg() -> u32 {
        \\    return consume_ptr(&shared_counter);
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_global_address_call_arg.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @use_global_address_arg");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "call i32 @consume_ptr(ptr @shared_counter)");
}

test "LLVM emits global address returns from MIR without body fallback" {
    const source =
        \\global shared_counter: u32 = 0;
        \\
        \\fn returned_global_pointer() -> *mut u32 {
        \\    return & shared_counter;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_global_address_return.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal ptr @returned_global_pointer");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "ret ptr @shared_counter");
}

test "LLVM emits local global address returns from MIR without body fallback" {
    const source =
        \\global shared_counter: u32 = 0;
        \\
        \\fn local_global_pointer() -> *mut u32 {
        \\    let gp: *mut u32 = &shared_counter;
        \\    return gp;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_local_global_address_return.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal ptr @local_global_pointer");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "store ptr @shared_counter");
    try expectContains(body, "icmp eq ptr");
    try expectContains(body, "ret ptr %mc_expr_tmp_");
}

test "LLVM emits conditional global address returns from MIR without body fallback" {
    const source =
        \\global shared_counter: u32 = 0;
        \\
        \\fn branched_global_pointer(flag: bool) -> *mut u32 {
        \\    if flag { return &shared_counter; } else { return &shared_counter; }
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_conditional_global_address_return.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal ptr @branched_global_pointer");
    try expectContains(body, "ret ptr @shared_counter");
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

test "LLVM rejects ordinary defer expression cleanup fallback" {
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
    try std.testing.expectError(error.UnsupportedLlvmEmission, appendLlvmTest("llvm_ordinary_defer_expression_cleanup_fallback.mc", source, &output));
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

test "LLVM escaped pointer provenance lowers conservatively" {
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
    try appendLlvmTest("escaped_pointer_provenance.mc", source, &output);

    const local_body = try llvmFunctionBody(output.items, "define internal i32 @escaped_local_pointer_lowers_race_tolerant");
    try expectContains(local_body, "call void @consume_pointer(ptr %");
    try expectContains(local_body, "load atomic i32, ptr %");
    try expectContains(local_body, " unordered, align 4");
    try expectNotContains(local_body, "load i32, ptr %");

    const aggregate_body = try llvmFunctionBody(output.items, "define internal i32 @escaped_aggregate_pointer_field_lowers_race_tolerant");
    try expectContains(aggregate_body, "call void @consume_box(ptr %");
    try expectContains(aggregate_body, "load atomic i32, ptr %");
    try expectContains(aggregate_body, " unordered, align 4");
    try expectNotContains(aggregate_body, "load i32, ptr %");
}

test "LLVM checked pointer-root field store does not use function body fallback" {
    const source =
        \\struct Env { value: u32 }
        \\fn store_value(env: *mut Env, value: u32) -> void {
        \\    env.value = value;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_pointer_root_store.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal void @store_value");
    try expectContains(body, "; canonical executable MIR");
    const guard = std.mem.indexOf(u8, body, "icmp eq ptr %mc_arg_0, null") orelse return error.TestUnexpectedResult;
    const field = std.mem.indexOf(u8, body, "getelementptr inbounds { i32 }, ptr %mc_arg_0, i32 0, i32 0") orelse return error.TestUnexpectedResult;
    const store = std.mem.indexOf(u8, body, "store atomic i32 %mc_arg_1, ptr %") orelse return error.TestUnexpectedResult;
    try std.testing.expect(guard < field and field < store);
}

test "LLVM checked pointer-to-integer cast does not use function body fallback" {
    const source =
        \\fn pointer_to_usize(p: *mut u32) -> usize {
        \\    return p as usize;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_pointer_to_integer.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i64 @pointer_to_usize");
    try expectContains(body, "; canonical executable MIR");
    const guard = std.mem.indexOf(u8, body, "icmp eq ptr %mc_arg_0, null") orelse return error.TestUnexpectedResult;
    const cast = std.mem.indexOf(u8, body, "ptrtoint ptr %mc_arg_0 to i64") orelse return error.TestUnexpectedResult;
    const returned = std.mem.indexOfPos(u8, body, cast, "ret i64 %mc_expr_tmp_") orelse return error.TestUnexpectedResult;
    try std.testing.expect(guard < cast and cast < returned);
}

test "LLVM address representation cast does not use function body fallback" {
    const source =
        \\fn address_value(value: PAddr) -> usize {
        \\    return value as usize;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_address_representation_cast.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i64 @address_value");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "ret i64 %mc_arg_0");
}

test "LLVM checked scalar local return does not use function body fallback" {
    const source =
        \\fn local_copy(n: u32) -> u32 {
        \\    let x: u32 = n + 1;
        \\    return x;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_scalar_local_checked_return.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @local_copy");
    try expectContains(body, "@llvm.uadd.with.overflow.i32(i32 %mc_arg_0, i32 1)");
    try expectContains(body, "call void @mc_trap_IntegerOverflow()");
    try expectContains(body, "alloca i32");
    try expectContains(body, "load i32, ptr %");
    try expectContains(body, "ret i32 %");
}

test "LLVM canonical executable MIR preserves typed high-word local and flag-set order" {
    const source =
        \\extern fn read_word(addr: usize) -> u64;
        \\fn high_word(v: u64) -> u32 {
        \\    let hi: u32 = (v >> 32) as u32;
        \\    return hi + 1;
        \\}
        \\fn flag_set(addr: usize, mask: u64) -> bool {
        \\    return (read_word(addr) & mask) != 0;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_canonical_scalar_expressions.mc", source, &output);

    const high = try llvmFunctionBody(output.items, "define internal i32 @high_word");
    try expectContains(high, "lshr i64 %mc_arg_0, 32");
    try expectContains(high, "trunc i64 %");
    try expectContains(high, "alloca i32");
    try expectContains(high, "call void @mc_trap_InvalidShift()");
    try expectContains(high, "@llvm.uadd.with.overflow.i32");
    try expectContains(high, "call void @mc_trap_IntegerOverflow()");
    const store = std.mem.indexOf(u8, high, "store i32") orelse return error.TestUnexpectedResult;
    const checked_add = std.mem.indexOf(u8, high, "@llvm.uadd.with.overflow.i32") orelse return error.TestUnexpectedResult;
    try std.testing.expect(store < checked_add);

    const flag = try llvmFunctionBody(output.items, "define internal i1 @flag_set");
    const call = std.mem.indexOf(u8, flag, "call i64 @read_word(") orelse return error.TestUnexpectedResult;
    const and_ = std.mem.indexOf(u8, flag, "and i64") orelse return error.TestUnexpectedResult;
    const compare = std.mem.indexOf(u8, flag, "icmp ne i64") orelse return error.TestUnexpectedResult;
    try std.testing.expect(call < and_ and and_ < compare);
    try expectContains(flag, "ret i1 %");
}

test "LLVM scalar control plans preserve checked local CFGs without body fallback" {
    const source =
        \\fn adjust(n: u32, flag: bool) -> u32 {
        \\    var x: u32 = n;
        \\    if flag { x = x + 1; } else { x = x - 1; }
        \\    return x;
        \\}
        \\fn maybe_inc(n: u32, flag: bool) -> u32 {
        \\    var x: u32 = n;
        \\    if flag { x = x + 1; }
        \\    return x;
        \\}
        \\fn count_down(n: u32) -> u32 {
        \\    var x: u32 = n;
        \\    while x != 0 { x = x - 1; }
        \\    return x;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_canonical_scalar_control.mc", source, &output);

    const adjust = try llvmFunctionBody(output.items, "define internal i32 @adjust");
    try expectContains(adjust, "alloca i32");
    try expectContains(adjust, "br i1 %");
    try expectContains(adjust, "@llvm.uadd.with.overflow.i32");
    try expectContains(adjust, "@llvm.usub.with.overflow.i32");
    try std.testing.expect(std.mem.count(u8, adjust, "call void @mc_trap_IntegerOverflow()") == 2);
    try expectContains(adjust, "ret i32 %");

    const maybe = try llvmFunctionBody(output.items, "define internal i32 @maybe_inc");
    try expectContains(maybe, "br i1 %");
    try expectContains(maybe, "@llvm.uadd.with.overflow.i32");
    try expectNotContains(maybe, "@llvm.usub.with.overflow.i32");
    try std.testing.expect(std.mem.count(u8, maybe, "call void @mc_trap_IntegerOverflow()") == 1);

    const down = try llvmFunctionBody(output.items, "define internal i32 @count_down");
    try expectContains(down, "icmp ne i32");
    try expectContains(down, "@llvm.usub.with.overflow.i32");
    try expectContains(down, "br label %");
    try expectContains(down, "call void @mc_trap_IntegerOverflow()");
    try expectContains(down, "ret i32 %");
}

test "LLVM canonical slice bucket lowers without function body fallback" {
    const source =
        \\fn read_slice(xs: []const u8, i: usize) -> u8 { return xs[i]; }
        \\fn read_literal(xs: []const u8) -> u8 { return xs[0]; }
        \\fn write_slice(xs: []mut u32, i: usize, value: u32) -> void { xs[i] = value; return; }
        \\extern fn make_slice() -> []const u8;
        \\fn direct_call_slice() -> u8 { return make_slice()[0]; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_access_plan_slice_bucket.mc", source, &output);

    const read_body = try llvmFunctionBody(output.items, "define internal i8 @read_slice");
    try expectContains(read_body, "mc_representation_ready_");
    try expectContains(read_body, "call void @mc_trap_InvalidRepresentation()");
    try expectContains(read_body, "call void @mc_trap_Bounds()");
    try expectContains(read_body, "load atomic i8, ptr %");

    const literal_body = try llvmFunctionBody(output.items, "define internal i8 @read_literal");
    try expectContains(literal_body, "icmp uge i64 0, %");
    try expectContains(literal_body, "load atomic i8, ptr %");

    const write_body = try llvmFunctionBody(output.items, "define internal void @write_slice");
    try expectContains(write_body, "icmp uge i64 ");
    try expectContains(write_body, "store atomic i32 ");

    const direct_body = try llvmFunctionBody(output.items, "define internal i8 @direct_call_slice");
    try expectContains(direct_body, "call { ptr, i64 } @make_slice()");
    try expectContains(direct_body, "load atomic i8, ptr %");
}

test "LLVM canonical access lowering materializes locals and addresses without body fallback" {
    const source =
        \\struct Holder { value: u32 }
        \\global shared_holder: Holder = .{ .value = 9 };
        \\global shared_value: u32 = 3;
        \\extern fn make_slice(seed: u8) -> []const u8;
        \\extern fn make_array() -> [4]u8;
        \\extern fn next_byte() -> u8;
        \\extern fn next_index() -> usize;
        \\fn global_field_address() -> u32 { let pointer = &shared_holder.value; return pointer.*; }
        \\fn local_array_address() -> u32 { var values: [2]u32 = .{ 4, 5 }; let pointer = &values[0]; return pointer.*; }
        \\fn array_window(n: usize) -> u8 { var values: [4]u8 = .{ 1, 2, 3, 4 }; let window: []mut u8 = values[0..n]; return window[0]; }
        \\fn materialized_slice() -> u8 { let values = make_slice(next_byte()); return values[next_index()]; }
        \\fn materialized_array() -> u8 { let values = make_array(); return values[next_index()]; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_structural_access_plan.mc", source, &output);

    const global_field = try llvmFunctionBody(output.items, "define internal i32 @global_field_address");
    try expectContains(global_field, "getelementptr inbounds { i32 }, ptr @shared_holder");
    try expectContains(global_field, "load atomic i32");

    const local_array = try llvmFunctionBody(output.items, "define internal i32 @local_array_address");
    try expectContains(local_array, "alloca [2 x i32]");
    try expectContains(local_array, "getelementptr inbounds [2 x i32]");

    const window = try llvmFunctionBody(output.items, "define internal i8 @array_window");
    try expectContains(window, "call void @mc_trap_Bounds()");
    try expectContains(window, "load atomic i8");

    const slice = try llvmFunctionBody(output.items, "define internal i8 @materialized_slice");
    try expectContains(slice, "call i8 @next_byte()");
    try expectContains(slice, "call { ptr, i64 } @make_slice(i8");
    try expectContains(slice, "load atomic i8");

    const array = try llvmFunctionBody(output.items, "define internal i8 @materialized_array");
    try expectContains(array, "call [4 x i8] @make_array()");
    try expectContains(array, "load i8");
}

test "LLVM canonical access lowering handles store-return and range terminals without body fallback" {
    const source =
        \\struct Pair { left: u32, right: u32 }
        \\global pair: Pair = .{ .left = 1, .right = 2 };
        \\global shared: u32 = 7;
        \\global shared_ptr: *mut u32 = &shared;
        \\fn address_global_field(value: u32) -> u32 { let p: *mut u32 = &pair.right; *p = value; return pair.right; }
        \\fn address_array_element(value: u32) -> u32 { var xs: [2]u32 = .{ 3, 4 }; let p: *mut u32 = &xs[1]; *p = value; return xs[1]; }
        \\fn address_field(value: u32) -> u32 { var item: Pair = .{ .left = 5, .right = 6 }; let p: *mut u32 = &item.right; *p = value; return item.right; }
        \\fn write_through_global_pointer(value: u32) -> u32 { *shared_ptr = value; return shared; }
        \\fn slice_from_slice(xs: []const u8, lo: usize, hi: usize) -> usize { let window: []const u8 = xs[lo..hi]; return window.len; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_structural_access_terminals.mc", source, &output);

    const global_field = try llvmFunctionBody(output.items, "define internal i32 @address_global_field");
    try expectContains(global_field, "store atomic i32 %mc_arg_0");
    try expectContains(global_field, "getelementptr inbounds { i32, i32 }, ptr @pair, i32 0, i32 1");
    try expectContains(global_field, "load atomic i32");

    const array_element = try llvmFunctionBody(output.items, "define internal i32 @address_array_element");
    try expectContains(array_element, "alloca [2 x i32]");
    try expectContains(array_element, "store i32 %mc_arg_0");
    try expectContains(array_element, "load i32");

    const field = try llvmFunctionBody(output.items, "define internal i32 @address_field");
    try expectContains(field, "alloca { i32, i32 }");
    try expectContains(field, "store i32 %mc_arg_0");
    try expectContains(field, "load i32");

    const global_pointer = try llvmFunctionBody(output.items, "define internal i32 @write_through_global_pointer");
    try expectContains(global_pointer, "load atomic ptr, ptr @shared_ptr");
    try expectContains(global_pointer, "store atomic i32 %mc_arg_0");
    try expectContains(global_pointer, "load atomic i32, ptr @shared");

    const range = try llvmFunctionBody(output.items, "define internal i64 @slice_from_slice");
    try expectContains(range, "call void @mc_trap_Bounds()");
    try expectContains(range, "alloca { ptr, i64 }");
    try expectContains(range, "extractvalue { ptr, i64 }");
    try expectContains(range, "ret i64");
}

test "LLVM canonical executable MIR lowers broad local bodies without AST fallback" {
    const source =
        \\extern fn transform(value: u32) -> u32;
        \\fn local_pipeline(a: u32, b: u32) -> u32 {
        \\    let left: u32 = transform(a);
        \\    let right: u32 = transform(b);
        \\    let mixed: u32 = left ^ right;
        \\    return mixed;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_executable_body_broad.mc", source, &output);

    const pipeline = try llvmFunctionBody(output.items, "define internal i32 @local_pipeline");
    try expectContains(pipeline, "; canonical executable MIR");
    try expectContains(pipeline, "call i32 @transform(i32 %mc_arg_0)");
    try expectContains(pipeline, "call i32 @transform(i32 %mc_arg_1)");
    try expectContains(pipeline, " = xor i32 ");
}

test "LLVM canonical executable MIR models explicit uninit as storage without a value" {
    const source =
        \\fn explicit_uninit(value: u32) -> u32 {
        \\    var x: u32 = uninit;
        \\    x = value;
        \\    return x;
        \\}
        \\fn grouped_uninit(value: u32) -> u32 {
        \\    var x: u32 = (uninit);
        \\    x = value;
        \\    return x;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_executable_uninit_local.mc", source, &output);

    for ([_][]const u8{
        "define internal i32 @explicit_uninit",
        "define internal i32 @grouped_uninit",
    }) |signature| {
        const body = try llvmFunctionBody(output.items, signature);
        try expectContains(body, "; canonical executable MIR");
        try expectContains(body, "alloca i32");
        try expectContains(body, "store i32 %mc_arg_0");
        try expectContains(body, "ret i32");
    }
}

test "LLVM canonical executable MIR owns scalar integer conversions" {
    const source =
        \\type W = wrap<u8>;
        \\fn narrow_unsigned(value: u32) -> u8 { return u8.trap_from(value); }
        \\fn signed_to_unsigned(value: i32) -> u8 { return u8.trap_from(value); }
        \\fn unsigned_to_signed(value: u32) -> i8 { return i8.trap_from(value); }
        \\fn widen(value: u8) -> u64 { return u64.trap_from(value); }
        \\fn narrow_wrap(value: u32) -> u8 { return u8.wrap_from(value); }
        \\fn narrow_sat(value: u32) -> u8 { return u8.sat_from(value); }
        \\fn signed_sat(value: i32) -> u8 { return u8.sat_from(value); }
        \\fn unsigned_signed_sat(value: u32) -> i8 { return i8.sat_from(value); }
        \\fn narrow_try(value: u32) -> Result<u8, ConversionError> { return u8.try_from(value); }
        \\fn widen_try(value: u8) -> Result<u64, ConversionError> { return u64.try_from(value); }
        \\fn conversion_source() -> u32 { return 300; }
        \\fn narrow_try_call() -> Result<u8, ConversionError> { return u8.try_from(conversion_source()); }
        \\fn make_wrap(value: u8) -> W { return W.from(value); }
        \\fn make_wrap_mod() -> W { return W.from_mod(300); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_trap_conversion.mc", source, &output);

    const narrow = try llvmFunctionBody(output.items, "define internal i8 @narrow_unsigned");
    try expectContains(narrow, "; canonical executable MIR");
    try expectContains(narrow, "icmp ugt i32 %mc_arg_0, 255");
    try expectContains(narrow, "trunc i32 %mc_arg_0 to i8");
    const crossed = try llvmFunctionBody(output.items, "define internal i8 @signed_to_unsigned");
    try expectContains(crossed, "icmp slt i32 %mc_arg_0, 0");
    try expectContains(crossed, "icmp sgt i32 %mc_arg_0, 255");
    const signed = try llvmFunctionBody(output.items, "define internal i8 @unsigned_to_signed");
    try expectContains(signed, "icmp ugt i32 %mc_arg_0, 127");
    const widen = try llvmFunctionBody(output.items, "define internal i64 @widen");
    try expectContains(widen, "zext i8 %mc_arg_0 to i64");
    try expectNotContains(widen, "br i1");
    const wrapped = try llvmFunctionBody(output.items, "define internal i8 @narrow_wrap");
    try expectContains(wrapped, "trunc i32 %mc_arg_0 to i8");
    const saturated = try llvmFunctionBody(output.items, "define internal i8 @narrow_sat");
    try expectContains(saturated, "icmp ugt i32 %mc_arg_0, 255");
    try expectContains(saturated, "select i1");
    try expectNotContains(saturated, "br i1");
    const sat_crossed = try llvmFunctionBody(output.items, "define internal i8 @signed_sat");
    try expectContains(sat_crossed, "icmp slt i32 %mc_arg_0, 0");
    try expectContains(sat_crossed, "icmp sgt i32 %mc_arg_0, 255");
    const sat_signed = try llvmFunctionBody(output.items, "define internal i8 @unsigned_signed_sat");
    try expectContains(sat_signed, "icmp ugt i32 %mc_arg_0, 127");
    const tried = try llvmFunctionBody(output.items, "define internal { i1, i8, i8 } @narrow_try");
    try expectContains(tried, "icmp ugt i32 %mc_arg_0, 255");
    try expectContains(tried, "xor i1");
    try expectContains(tried, "insertvalue { i1, i8, i8 }");
    const tried_widen = try llvmFunctionBody(output.items, "define internal { i1, i64, i8 } @widen_try");
    try expectContains(tried_widen, "zext i8 %mc_arg_0 to i64");
    try expectContains(tried_widen, "i1 true, 0");
    try expectNotContains(tried_widen, "icmp");
    const tried_call = try llvmFunctionBody(output.items, "define internal { i1, i8, i8 } @narrow_try_call");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, tried_call, "call i32 @conversion_source()"));
    try expectContains(tried_call, "icmp ugt i32");
    const domain = try llvmFunctionBody(output.items, "define internal i8 @make_wrap");
    try expectContains(domain, "ret i8 %mc_arg_0");
    const modulo = try llvmFunctionBody(output.items, "define internal i8 @make_wrap_mod");
    try expectContains(modulo, "trunc i32 300 to i8");
}

test "LLVM canonical executable MIR owns serial compare Result" {
    const source =
        \\type Seq = serial<u32>;
        \\fn compare(a: Seq, b: Seq) -> Result<Order, AmbiguousSerialOrder> { return Seq.compare(a, b); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_serial_compare.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal { i1, i8, i8 } @compare");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "sub i32 %mc_arg_0, %mc_arg_1");
    try expectContains(body, "icmp eq i32");
    try expectContains(body, "2147483648");
    try expectContains(body, "select i1");
    try expectContains(body, "insertvalue { i1, i8, i8 }");
}

test "LLVM canonical executable MIR owns bounded counter Result" {
    const source =
        \\type Ticks = counter<u64>;
        \\fn bounded(now: Ticks, start: Ticks, max: Duration<u64>) -> Result<Duration<u64>, AmbiguousCounterInterval> {
        \\    return Ticks.elapsed_bounded(now, start, max);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_counter_elapsed_bounded.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal { i1, i64, i8 } @bounded");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "sub i64 %mc_arg_0, %mc_arg_1");
    try expectContains(body, "icmp ule i64");
    try expectContains(body, "select i1");
    try expectContains(body, "insertvalue { i1, i64, i8 }");
}

test "LLVM canonical executable MIR precedes legacy specialized plans" {
    const source =
        \\fn identity(value: u32) -> u32 {
        \\    return value;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_executable_body_preferred.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal i32 @identity");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "ret i32 %mc_arg_0");
}

test "LLVM canonical executable MIR lowers pure scalar bitcasts without body fallback" {
    const source =
        \\fn bits_to_float(value: u32) -> f32 { return bitcast<f32>(value); }
        \\fn float_to_bits(value: f64) -> u64 { return bitcast<u64>(value); }
        \\fn signed_to_unsigned(value: i32) -> u32 { return bitcast<u32>(value); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_executable_scalar_bitcast.mc", source, &output);

    const bits_to_float = try llvmFunctionBody(output.items, "define internal float @bits_to_float");
    try expectContains(bits_to_float, "; canonical executable MIR");
    try expectContains(bits_to_float, "bitcast i32 %mc_arg_0 to float");
    try expectContains(bits_to_float, "ret float %mc_expr_tmp_");

    const float_to_bits = try llvmFunctionBody(output.items, "define internal i64 @float_to_bits");
    try expectContains(float_to_bits, "; canonical executable MIR");
    try expectContains(float_to_bits, "bitcast double %mc_arg_0 to i64");
    try expectContains(float_to_bits, "ret i64 %mc_expr_tmp_");

    const signed_to_unsigned = try llvmFunctionBody(output.items, "define internal i32 @signed_to_unsigned");
    try expectContains(signed_to_unsigned, "; canonical executable MIR");
    try expectContains(signed_to_unsigned, "ret i32 %mc_arg_0");
    try expectNotContains(signed_to_unsigned, "bitcast");
}

test "LLVM canonical executable MIR emits raw scalar load and store without AST fallback" {
    const source =
        \\fn load(address: PAddr) -> u32 { unsafe { return raw.load<u32>(address); } }
        \\fn pointer(address: PAddr) -> *mut u32 { unsafe { return raw.ptr<u32>(address); } }
        \\fn store(address: PAddr, value: u32) -> void { unsafe { raw.store<u32>(address, value); } }
        \\fn sync() -> void { fence.release(); fence.acquire(); fence.full(); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_executable_raw_scalar.mc", source, &output);

    const load = try llvmFunctionBody(output.items, "define internal i32 @load");
    try expectContains(load, "; canonical executable MIR");
    try expectContains(load, "inttoptr i64 %mc_arg_0 to ptr");
    try expectContains(load, "load volatile i32, ptr");
    const pointer = try llvmFunctionBody(output.items, "define internal ptr @pointer");
    try expectContains(pointer, "; canonical executable MIR");
    try expectNeedlesInOrder(pointer, &.{ "inttoptr i64 %mc_arg_0 to ptr", "icmp eq ptr %mc_expr_tmp_", "ret ptr %mc_expr_tmp_" });
    try expectContains(pointer, "call void @mc_trap_InvalidRepresentation()");
    const store = try llvmFunctionBody(output.items, "define internal void @store");
    try expectContains(store, "; canonical executable MIR");
    try expectContains(store, "inttoptr i64 %mc_arg_0 to ptr");
    try expectContains(store, "store volatile i32 %mc_arg_1, ptr");
    const sync = try llvmFunctionBody(output.items, "define internal void @sync");
    try expectContains(sync, "; canonical executable MIR");
    try expectNeedlesInOrder(sync, &.{ "fence release", "fence acquire", "fence seq_cst" });
}

test "LLVM canonical executable MIR owns reflection constants without AST fallback" {
    const source =
        \\extern struct Packet {
        \\    len: u16,
        \\    tag: u8,
        \\}
        \\enum Mode: u8 { normal = 0 }
        \\overlay union Overlay { byte: u8, word: u32 }
        \\#[c_union]
        \\struct CUnion { byte: u8, word: u64 }
        \\fn packet_size() -> usize { return sizeof<Packet>(); }
        \\fn packet_alignment() -> usize { return alignof<Packet>(); }
        \\fn packet_tag_offset() -> usize { return field_offset<Packet>(.tag); }
        \\fn packet_tag_bit_offset() -> usize { return bit_offset<Packet>(.tag); }
        \\fn mode_repr() -> usize { return repr_of<Mode>(); }
        \\fn overlay_size() -> usize { return sizeof<Overlay>(); }
        \\fn overlay_word_offset() -> usize { return field_offset<Overlay>(.word); }
        \\fn c_union_size() -> usize { return sizeof<CUnion>(); }
        \\fn c_union_word_offset() -> usize { return field_offset<CUnion>(.word); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_executable_reflection_constants.mc", source, &output);

    const packet_size = try llvmFunctionBody(output.items, "define internal i64 @packet_size");
    try expectContains(packet_size, "; canonical executable MIR");
    try expectContains(packet_size, "ret i64 4");
    const packet_alignment = try llvmFunctionBody(output.items, "define internal i64 @packet_alignment");
    try expectContains(packet_alignment, "ret i64 2");
    const packet_tag_offset = try llvmFunctionBody(output.items, "define internal i64 @packet_tag_offset");
    try expectContains(packet_tag_offset, "ret i64 2");
    const packet_tag_bit_offset = try llvmFunctionBody(output.items, "define internal i64 @packet_tag_bit_offset");
    try expectContains(packet_tag_bit_offset, "ret i64 16");
    const mode_repr = try llvmFunctionBody(output.items, "define internal i64 @mode_repr");
    try expectContains(mode_repr, "ret i64 1");
    const overlay_size = try llvmFunctionBody(output.items, "define internal i64 @overlay_size");
    try expectContains(overlay_size, "ret i64 4");
    const overlay_word_offset = try llvmFunctionBody(output.items, "define internal i64 @overlay_word_offset");
    try expectContains(overlay_word_offset, "ret i64 0");
    const c_union_size = try llvmFunctionBody(output.items, "define internal i64 @c_union_size");
    try expectContains(c_union_size, "ret i64 8");
    const c_union_word_offset = try llvmFunctionBody(output.items, "define internal i64 @c_union_word_offset");
    try expectContains(c_union_word_offset, "ret i64 0");
}

test "LLVM canonical executable MIR guards parameter deref load and address identity" {
    const source =
        \\fn read(pointer: *u32) -> u32 { return pointer.*; }
        \\fn write(pointer: *mut u32, value: u32) -> void { pointer.* = value; }
        \\fn identity(pointer: *mut u32) -> *mut u32 { return &pointer.*; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_executable_parameter_deref.mc", source, &output);

    const read = try llvmFunctionBody(output.items, "define internal i32 @read");
    try expectContains(read, "; canonical executable MIR");
    const read_guard = std.mem.indexOf(u8, read, "icmp eq ptr %mc_arg_0, null") orelse return error.TestUnexpectedResult;
    const read_load = std.mem.indexOf(u8, read, "load atomic i32, ptr %mc_arg_0 unordered, align 4") orelse return error.TestUnexpectedResult;
    try std.testing.expect(read_guard < read_load);
    try expectContains(read, "call void @mc_trap_InvalidRepresentation()");

    const write = try llvmFunctionBody(output.items, "define internal void @write");
    try expectContains(write, "; canonical executable MIR");
    const write_guard = std.mem.indexOf(u8, write, "icmp eq ptr %mc_arg_0, null") orelse return error.TestUnexpectedResult;
    const write_store = std.mem.indexOf(u8, write, "store atomic i32 %mc_arg_1, ptr %mc_arg_0 unordered, align 4") orelse return error.TestUnexpectedResult;
    try std.testing.expect(write_guard < write_store);
    try expectContains(write, "call void @mc_trap_InvalidRepresentation()");

    const identity = try llvmFunctionBody(output.items, "define internal ptr @identity");
    try expectContains(identity, "; canonical executable MIR");
    try expectContains(identity, "icmp eq ptr %mc_arg_0, null");
    try expectContains(identity, "ret ptr %mc_arg_0");
    try expectNotContains(identity, "load ptr, ptr %mc_arg_0");
}

test "LLVM local-address access tag lowers checked update without function body fallback" {
    const source =
        \\fn local_address(value: u32) -> u32 { var x: u32 = value; let p: *mut u32 = &x; *p = x + 1; return x; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_local_address_tag.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @local_address");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "@llvm.uadd.with.overflow.i32");
    try expectContains(body, "call void @mc_trap_IntegerOverflow()");
    try expectContains(body, "load ptr, ptr %mc_local_");
    try expectContains(body, "call void @mc_trap_InvalidRepresentation()");
    try expectContains(body, "store i32 %mc_expr_tmp_");
}

test "LLVM aggregate alias writes do not prove backing aggregate fields" {
    const source =
        \\global shared_counter: u32 = 0;
        \\
        \\struct Holder { ptr: *mut u32 }
        \\
        \\fn aggregate_alias_write_backing_read_stays_conservative() -> u32 {
        \\    var local: u32 = 0;
        \\    var holder: Holder = .{ .ptr = &shared_counter };
        \\    let hp: *mut Holder = &holder;
        \\    hp.ptr = &local;
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmTest("llvm_aggregate_alias_write_backing_read.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal i32 @aggregate_alias_write_backing_read_stays_conservative");
    try expectContains(body, "load atomic i32, ptr %");
    try expectContains(body, " unordered, align 4");
    try expectNotContains(body, "load i32, ptr %");
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
    try appendLlvmCheckedMirTest("llvm_mir_ordinary_bool_global.mc", source, &output);

    const load_body = try llvmFunctionBody(output.items, "define internal i1 @read_flag");
    try expectContains(load_body, "load atomic i8, ptr @flag unordered, align 1");
    try expectContains(load_body, "trunc i8 ");
    try expectNotContains(load_body, "load atomic i1");

    const store_body = try llvmFunctionBody(output.items, "define internal void @write_flag");
    try expectContains(store_body, "zext i1 %mc_arg_0 to i8");
    try expectContains(store_body, "store atomic i8 ");
    try expectContains(store_body, "ptr @flag unordered, align 1");
    try expectNotContains(store_body, "store atomic i1");
}

test "LLVM immutable scalar global value reads avoid atomic traffic" {
    const source =
        \\const LIMIT: u32 = 7;
        \\
        \\fn read_limit() -> u32 {
        \\    return LIMIT;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_immutable_scalar_global.mc", source, &output);

    const body = try llvmFunctionBody(output.items, "define internal i32 @read_limit");
    try expectContains(body, "load i32, ptr @LIMIT");
    try expectNotContains(body, "load atomic");
}

test "LLVM scalar global reads lower from MIR without body fallback" {
    const source =
        \\global flag: bool = false;
        \\const LIMIT: u32 = 7;
        \\fn read_flag() -> bool {
        \\    return flag;
        \\}
        \\fn write_flag(value: bool) -> void {
        \\    flag = value;
        \\}
        \\fn read_limit() -> u32 {
        \\    return LIMIT;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_scalar_global_reads.mc", source, &output);

    const load_body = try llvmFunctionBody(output.items, "define internal i1 @read_flag");
    try expectContains(load_body, "load atomic i8, ptr @flag unordered, align 1");

    const store_body = try llvmFunctionBody(output.items, "define internal void @write_flag");
    try expectContains(store_body, "store atomic i8 ");
    try expectContains(store_body, "ptr @flag unordered, align 1");

    const const_body = try llvmFunctionBody(output.items, "define internal i32 @read_limit");
    try expectContains(const_body, "load i32, ptr @LIMIT");
    try expectNotContains(const_body, "load atomic");
}

test "LLVM simple functions and race-safe globals lower from MIR without body fallback" {
    const source =
        \\global shared_counter: u32 = 0;
        \\fn add(a: u32, b: u32) -> u32 {
        \\    return a + b;
        \\}
        \\fn store(x: u32) -> void {
        \\    shared_counter = x;
        \\}
        \\fn load() -> u32 {
        \\    return shared_counter;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_simple_functions_race_safe_globals.mc", source, &output);

    const add_body = try llvmFunctionBody(output.items, "define internal i32 @add");
    try expectContains(add_body, "@llvm.uadd.with.overflow.i32");
    try expectContains(add_body, "ret i32 %");

    const store_body = try llvmFunctionBody(output.items, "define internal void @store");
    try expectContains(store_body, "store atomic i32 %mc_arg_0, ptr @shared_counter unordered, align 4");

    const load_body = try llvmFunctionBody(output.items, "define internal i32 @load");
    try expectContains(load_body, "load atomic i32, ptr @shared_counter unordered, align 4");
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

test "LLVM omits checked comptime blocks from canonical runtime bodies" {
    const source =
        \\fn accept_pure_comptime_block() -> u32 {
        \\    comptime {
        \\        let x: u32 = 1;
        \\        assert(x == 1);
        \\    }
        \\    return 1;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_comptime_block.mc", source, &output);
    const body = try llvmFunctionBody(output.items, "define internal i32 @accept_pure_comptime_block");
    try expectContains(body, "; canonical executable MIR");
    try expectContains(body, "ret i32 1");
    try expectNotContains(body, "alloca i32");
    try expectNotContains(body, "mc_trap_Assert");
}

test "LLVM renders canonical string bytes without body fallback" {
    const source =
        \\fn escaped() -> cstr { return "line\nquote\""; }
        \\fn bytes() -> []const u8 { return "A\0B"; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirTest("llvm_mir_string_bytes.mc", source, &output);
    const escaped_body = try llvmFunctionBody(output.items, "define internal ptr @escaped");
    try expectContains(escaped_body, "; canonical executable MIR");
    try expectContains(escaped_body, "getelementptr [12 x i8], ptr @.str.");
    const bytes_body = try llvmFunctionBody(output.items, "define internal { ptr, i64 } @bytes");
    try expectContains(bytes_body, "; canonical executable MIR");
    try expectContains(bytes_body, "insertvalue { ptr, i64 }");
    try expectContains(output.items, "c\"line\\0Aquote\\22\\00\"");
    try expectContains(output.items, "c\"A\\00B\\00\"");
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
    try expectContainsAny(body, &.{ "zext i32 9 to i128", "store i128 9, ptr %" });
    try expectContains(body, "load i128, ptr %");
    try expectNotContains(body, " atomic ");
}

test "LLVM backend emits cstr as ptr" {
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
    try appendLlvmTest("cstr_llvm.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "declare i64 @strlen(ptr)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "declare ptr @identity(ptr)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "@global_cstr = internal global ptr getelementptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "@copied_cstr = internal global ptr getelementptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "define ptr @return_cstr()") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "call ptr @identity(ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "insertvalue { ptr, i64 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "i64 5, 1") != null);
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

    const total_decls = proven.decls().len + checked.decls().len;
    const decls = try std.testing.allocator.alloc(ast.Decl, total_decls);
    defer std.testing.allocator.free(decls);
    @memcpy(decls[0..proven.decls().len], proven.decls());
    @memcpy(decls[proven.decls().len..], checked.decls());
    const module = ast.Module{ .decls = decls };

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvmWithSourcePathDeclsTest(std.testing.allocator, module.decls, &output, "combined.mc", true);

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
    try appendLlvmWithSourcePathDeclsTest(std.testing.allocator, parsed.decls(), &rebuilt_output, "llvm_prebuilt_mir.mc", true);

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "llvm_prebuilt_mir.mc", source);
    defer reporter.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{ .optimize = true });
    defer module_mir.deinit();
    try mir.verifyBuiltMir(module_mir, &reporter);
    try std.testing.expect(!reporter.has_errors);

    var prebuilt_output: std.ArrayList(u8) = .empty;
    defer prebuilt_output.deinit(std.testing.allocator);
    try appendLlvmCheckedMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &prebuilt_output, "llvm_prebuilt_mir.mc", .{ .optimize = true }, false, .riscv64, &reporter);

    try std.testing.expectEqualSlices(u8, rebuilt_output.items, prebuilt_output.items);
}
