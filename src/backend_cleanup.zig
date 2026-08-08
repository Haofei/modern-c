const std = @import("std");

const ast = @import("ast.zig");
const mir = @import("mir.zig");
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

/// Remove the most recent auto-drop cleanup for a MIR ownership key from a
/// transitional backend cleanup stack.
pub fn removeAutoDropCleanup(stack: *std.ArrayList(DeferredCleanup), key: mir_ownership_authority.AutoDropCleanupKey) void {
    var index = stack.items.len;
    while (index > 0) {
        index -= 1;
        switch (stack.items[index]) {
            .auto_drop => |cleanup| {
                if (!autoDropCleanupMatchesKey(cleanup, key)) continue;
                _ = stack.orderedRemove(index);
                return;
            },
            .expr => continue,
        }
    }
}

fn autoDropCleanupMatchesKey(
    cleanup: mir_ownership_authority.AutoDropLocalCleanup,
    key: mir_ownership_authority.AutoDropCleanupKey,
) bool {
    if (!cleanup.root_value_id.isValid() or !key.root_value_id.isValid()) return false;
    if (!cleanup.root_value_id.eql(key.root_value_id)) return false;
    if (key.resource_type_symbol_id.isValid() and !cleanup.resource_type_symbol_id.eql(key.resource_type_symbol_id)) return false;
    if (key.drop_glue_symbol_id.isValid() and !cleanup.drop_glue_symbol_id.eql(key.drop_glue_symbol_id)) return false;
    return true;
}

test "auto-drop cleanup stack removal uses typed local identity" {
    const span = ast.Span{ .offset = 0, .len = 1, .line = 1, .column = 1 };
    var stack: std.ArrayList(DeferredCleanup) = .empty;
    defer stack.deinit(std.testing.allocator);

    const root_old = mir.ValueId.fromIndex(1);
    const root_shadow = mir.ValueId.fromIndex(2);
    const resource_type = mir.SymbolId.fromIndex(3);
    const drop_glue = mir.SymbolId.fromIndex(4);

    try stack.append(std.testing.allocator, .{ .auto_drop = .{ .fn_name = "close_old", .local_name = "g", .span = span, .root_value_id = root_old, .resource_type_symbol_id = resource_type, .drop_glue_symbol_id = drop_glue } });
    try stack.append(std.testing.allocator, .{ .auto_drop = .{ .fn_name = "close_shadow", .local_name = "g", .span = span, .root_value_id = root_shadow, .resource_type_symbol_id = resource_type, .drop_glue_symbol_id = drop_glue } });

    removeAutoDropCleanup(&stack, .{ .local_name = "g", .root_value_id = root_old, .resource_type_symbol_id = resource_type, .drop_glue_symbol_id = drop_glue });
    try std.testing.expectEqual(@as(usize, 1), stack.items.len);
    switch (stack.items[0]) {
        .auto_drop => |cleanup| try std.testing.expectEqualStrings("close_shadow", cleanup.fn_name),
        .expr => return error.TestUnexpectedResult,
    }
}
