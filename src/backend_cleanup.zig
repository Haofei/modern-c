const std = @import("std");

const ast = @import("ast.zig");
const mir_ownership_authority = @import("mir_ownership_authority.zig");

/// Transitional backend cleanup stack entry.
///
/// Ordinary `defer` expressions are still emitted from backend-local lexical
/// stacks while cleanup edges migrate into MIR. Auto-drop payloads remain
/// produced by MIR ownership authority; this module only owns the temporary
/// stack mechanics shared by C and LLVM.
pub const DeferredCleanup = union(enum) {
    expr: ast.Expr,
    auto_drop: mir_ownership_authority.AutoDropLocalCleanup,
};

/// Remove the most recent auto-drop cleanup for a local from a transitional
/// backend cleanup stack.
pub fn removeAutoDropCleanupForLocalName(stack: *std.ArrayList(DeferredCleanup), local_name: []const u8) void {
    var index = stack.items.len;
    while (index > 0) {
        index -= 1;
        switch (stack.items[index]) {
            .auto_drop => |cleanup| {
                if (!std.mem.eql(u8, cleanup.local_name, local_name)) continue;
                _ = stack.orderedRemove(index);
                return;
            },
            .expr => continue,
        }
    }
}

test "auto-drop cleanup stack removal uses the latest matching local" {
    const span = ast.Span{ .offset = 0, .len = 1, .line = 1, .column = 1 };
    var stack: std.ArrayList(DeferredCleanup) = .empty;
    defer stack.deinit(std.testing.allocator);

    try stack.append(std.testing.allocator, .{ .auto_drop = .{ .fn_name = "close_old", .local_name = "g", .span = span } });
    try stack.append(std.testing.allocator, .{ .auto_drop = .{ .fn_name = "close_h", .local_name = "h", .span = span } });
    try stack.append(std.testing.allocator, .{ .auto_drop = .{ .fn_name = "close_new", .local_name = "g", .span = span } });

    removeAutoDropCleanupForLocalName(&stack, "g");
    try std.testing.expectEqual(@as(usize, 2), stack.items.len);
    switch (stack.items[0]) {
        .auto_drop => |cleanup| try std.testing.expectEqualStrings("close_old", cleanup.fn_name),
        .expr => return error.TestUnexpectedResult,
    }
}
