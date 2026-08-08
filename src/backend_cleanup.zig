const std = @import("std");

const ast = @import("ast.zig");
const mir = @import("mir.zig");
const mir_ownership_authority = @import("mir_ownership_authority.zig");

/// Transitional backend cleanup stack entry.
///
/// Ordinary `defer` expressions are still emitted from backend-local lexical
/// stacks while cleanup edges migrate into MIR. Direct-call cleanup shapes carry
/// a typed MIR-admitted payload, and deferred blocks are kept structured. Other
/// expression cleanups must be admitted as typed direct-call/call-target payloads
/// before either backend will lower them.
/// Auto-drop payloads remain produced by MIR ownership authority; this module
/// only owns the temporary stack mechanics shared by C and LLVM.
pub const OrdinaryDeferCallCleanup = struct {
    fn_name: []const u8,
    span: ast.Span,
    callee_span: ast.Span,
    args: []const ast.Expr,
};

pub const CallTargetDeferCleanup = struct {
    kind: mir.CallTargetKind,
    defer_span: ast.Span,
    span: ast.Span,
    callee: ast.Expr,
    callee_span: ast.Span,
    type_args: []const ast.TypeExpr,
    args: []const ast.Expr,
};

pub const DeferBlockCleanup = struct {
    defer_span: ast.Span,
    block: ast.Block,
};

pub const DeferredCleanup = union(enum) {
    block: DeferBlockCleanup,
    direct_call: OrdinaryDeferCallCleanup,
    call_target: CallTargetDeferCleanup,
    auto_drop: mir_ownership_authority.OwnershipCleanupActionRef,
    explicit_drop: mir_ownership_authority.OwnershipCleanupActionRef,
};

/// Remove the most recent auto-drop cleanup for a MIR ownership action from a
/// transitional backend cleanup stack. Returning `false` is a backend invariant
/// failure: MIR identified a live cleanup obligation, but the backend-local stack
/// no longer contains it. Callers must fail closed instead of continuing with a
/// silently divergent cleanup model.
pub fn removeAutoDropCleanup(stack: *std.ArrayList(DeferredCleanup), ref: mir_ownership_authority.OwnershipCleanupRemovalRef) bool {
    var index = stack.items.len;
    while (index > 0) {
        index -= 1;
        switch (stack.items[index]) {
            .auto_drop => |cleanup| {
                if (!autoDropCleanupMatchesRef(cleanup, ref)) continue;
                _ = stack.orderedRemove(index);
                return true;
            },
            .block, .direct_call, .call_target => continue,
            .explicit_drop => continue,
        }
    }
    return false;
}

fn autoDropCleanupMatchesRef(
    cleanup: mir_ownership_authority.OwnershipCleanupActionRef,
    ref: mir_ownership_authority.OwnershipCleanupRemovalRef,
) bool {
    if (cleanup.cleanup_action_index != ref.cleanup_action_index) return false;
    if (!cleanup.root_value_id.isValid() or !ref.root_value_id.isValid()) return false;
    if (!cleanup.root_value_id.eql(ref.root_value_id)) return false;
    if (!cleanup.resource_type_symbol_id.eql(ref.resource_type_symbol_id)) return false;
    if (!cleanup.drop_glue_symbol_id.eql(ref.drop_glue_symbol_id)) return false;
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

    try stack.append(std.testing.allocator, .{ .auto_drop = .{ .local_name = "g", .span = span, .cleanup_action_index = 0, .root_value_id = root_old, .resource_type_symbol_id = resource_type, .drop_glue_symbol_id = drop_glue } });
    try stack.append(std.testing.allocator, .{ .auto_drop = .{ .local_name = "g", .span = span, .cleanup_action_index = 1, .root_value_id = root_shadow, .resource_type_symbol_id = resource_type, .drop_glue_symbol_id = drop_glue } });

    try std.testing.expect(removeAutoDropCleanup(&stack, .{ .local_name = "g", .cleanup_action_index = 0, .root_value_id = root_old, .resource_type_symbol_id = resource_type, .drop_glue_symbol_id = drop_glue }));
    try std.testing.expectEqual(@as(usize, 1), stack.items.len);
    switch (stack.items[0]) {
        .auto_drop => |cleanup| try std.testing.expect(cleanup.root_value_id.eql(root_shadow)),
        .block, .direct_call, .call_target, .explicit_drop => return error.TestUnexpectedResult,
    }
    try std.testing.expect(!removeAutoDropCleanup(&stack, .{ .local_name = "g", .cleanup_action_index = 0, .root_value_id = root_old, .resource_type_symbol_id = resource_type, .drop_glue_symbol_id = drop_glue }));
    try std.testing.expect(!removeAutoDropCleanup(&stack, .{ .local_name = "g", .cleanup_action_index = 0, .root_value_id = root_shadow, .resource_type_symbol_id = resource_type, .drop_glue_symbol_id = drop_glue }));
}
