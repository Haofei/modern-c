const std = @import("std");

const ast = @import("ast.zig");
const lower_llvm = @import("lower_llvm.zig");
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
