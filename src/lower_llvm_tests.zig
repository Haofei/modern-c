const std = @import("std");

const lower_llvm = @import("lower_llvm.zig");
const test_support = @import("test_support.zig");

fn appendLlvmTest(source_name: []const u8, source: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseModule(source_name, source);
    defer parsed.deinit();

    try lower_llvm.appendLlvm(std.testing.allocator, parsed.module, output);
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
