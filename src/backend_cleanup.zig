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
    defer_ref: mir.DeferCleanupRef,
    fn_name: []const u8,
    span: ast.Span,
    callee_span: ast.Span,
    args: []const ast.Expr,
};

pub const CallTargetDeferCleanup = struct {
    defer_ref: mir.DeferCleanupRef,
    kind: mir.CallTargetKind,
    span: ast.Span,
    callee: ast.Expr,
    callee_span: ast.Span,
    type_args: []const ast.TypeExpr,
    args: []const ast.Expr,
};

pub const DeferBlockCleanup = struct {
    defer_ref: mir.DeferCleanupRef,
    block: ast.Block,
};

pub const DeferredCleanup = union(enum) {
    block: DeferBlockCleanup,
    direct_call: OrdinaryDeferCallCleanup,
    call_target: CallTargetDeferCleanup,
    auto_drop: mir_ownership_authority.OwnershipCleanupActionRef,
    explicit_drop: mir_ownership_authority.OwnershipCleanupActionRef,
};

pub const DeferCleanupStackSnapshot = struct {
    items: []DeferredCleanup,

    pub fn deinit(self: *DeferCleanupStackSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
        self.items = &.{};
    }
};

pub fn captureDeferCleanupStack(
    allocator: std.mem.Allocator,
    stack: []const DeferredCleanup,
) !DeferCleanupStackSnapshot {
    return .{ .items = try allocator.dupe(DeferredCleanup, stack) };
}

pub fn restoreDeferCleanupStack(
    stack: *std.ArrayList(DeferredCleanup),
    snapshot: DeferCleanupStackSnapshot,
) void {
    stack.items.len = snapshot.items.len;
    @memcpy(stack.items[0..snapshot.items.len], snapshot.items);
}

pub fn deferCleanupRef(cleanup: DeferredCleanup) ?mir.DeferCleanupRef {
    return switch (cleanup) {
        .block => |entry| entry.defer_ref,
        .direct_call => |entry| entry.defer_ref,
        .call_target => |entry| entry.defer_ref,
        .auto_drop, .explicit_drop => null,
    };
}

pub fn deferCleanupStackRefsValid(function: mir.Function, stack: []const DeferredCleanup) bool {
    for (stack, 0..) |cleanup, index| {
        const ref = deferCleanupRef(cleanup) orelse continue;
        if (!mir.deferCleanupRefValid(function, ref)) return false;
        var previous_index: usize = 0;
        while (previous_index < index) : (previous_index += 1) {
            const previous = deferCleanupRef(stack[previous_index]) orelse continue;
            if (sameDeferCleanupRef(previous, ref)) return false;
            if (deferCleanupRefAfter(function, previous, ref)) return false;
        }
    }
    return true;
}

pub fn deferCleanupEmissionRangeValid(function: mir.Function, stack: []const DeferredCleanup, start: usize) bool {
    if (start > stack.len) return false;
    if (!deferCleanupStackRefsValid(function, stack)) return false;
    for (stack[start..]) |cleanup| {
        const ref = deferCleanupRef(cleanup) orelse continue;
        if (!mir.deferCleanupRefValid(function, ref)) return false;
    }
    return true;
}

pub fn deferCleanupEmissionCount(stack: []const DeferredCleanup, start: usize) ?usize {
    if (start > stack.len) return null;
    return stack.len - start;
}

pub fn deferCleanupAtEmissionIndex(
    function: mir.Function,
    stack: []const DeferredCleanup,
    start: usize,
    emission_index: usize,
) ?DeferredCleanup {
    const count = deferCleanupEmissionCount(stack, start) orelse return null;
    if (emission_index >= count) return null;
    if (!deferCleanupEmissionRangeValid(function, stack, start)) return null;
    return stack[stack.len - 1 - emission_index];
}

fn sameDeferCleanupRef(a: mir.DeferCleanupRef, b: mir.DeferCleanupRef) bool {
    return a.block_id.eql(b.block_id) and a.instruction_index == b.instruction_index;
}

fn deferCleanupRefAfter(function: mir.Function, a: mir.DeferCleanupRef, b: mir.DeferCleanupRef) bool {
    const a_offset = deferCleanupSourceOrder(function, a) orelse return true;
    const b_offset = deferCleanupSourceOrder(function, b) orelse return true;
    return a_offset > b_offset;
}

fn deferCleanupSourceOrder(function: mir.Function, ref: mir.DeferCleanupRef) ?usize {
    if (!mir.deferCleanupRefValid(function, ref)) return null;
    const instruction = function.blocks[ref.block_id.index()].instructions[ref.instruction_index];
    if (instruction.source_offset != 0) return instruction.source_offset;
    return instruction.line * 1_000_000 + instruction.column;
}

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

test "defer cleanup stack refs must be valid ordered and unique" {
    const span = ast.Span{ .offset = 10, .len = 1, .line = 1, .column = 10 };
    const later_span = ast.Span{ .offset = 20, .len = 1, .line = 1, .column = 20 };
    var instructions = [_]mir.Instruction{
        .{ .kind = .defer_cleanup, .detail = "cleanup", .result_ty = .void, .line = span.line, .column = span.column, .source_offset = span.offset, .source_len = span.len },
        .{ .kind = .defer_cleanup, .detail = "cleanup", .result_ty = .void, .line = later_span.line, .column = later_span.column, .source_offset = later_span.offset, .source_len = later_span.len },
    };
    var blocks = [_]mir.Block{
        .{
            .id = 0,
            .typed_id = mir.BlockId.fromIndex(0),
            .kind = "entry",
            .instructions = instructions[0..],
            .successors = &.{},
            .terminator = .fallthrough,
        },
    };
    const function: mir.Function = .{
        .name = "f",
        .return_ty = .void,
        .no_lang_trap = false,
        .irq_context = false,
        .blocks = blocks[0..],
        .trap_edges = &.{},
        .contract_regions = &.{},
        .range_facts = &.{},
        .pointer_provenance_facts = &.{},
        .representation_facts = &.{},
        .elided_bounds = &.{},
    };
    const first: mir.DeferCleanupRef = .{ .block_id = mir.BlockId.fromIndex(0), .instruction_index = 0, .source = mir.sourcePointFromSpan(span) };
    const second: mir.DeferCleanupRef = .{ .block_id = mir.BlockId.fromIndex(0), .instruction_index = 1, .source = mir.sourcePointFromSpan(later_span) };
    const block: ast.Block = .{ .span = span, .items = &.{} };

    try std.testing.expect(deferCleanupStackRefsValid(function, &.{
        .{ .block = .{ .defer_ref = first, .block = block } },
        .{ .block = .{ .defer_ref = second, .block = block } },
    }));
    try std.testing.expect(!deferCleanupStackRefsValid(function, &.{
        .{ .block = .{ .defer_ref = second, .block = block } },
        .{ .block = .{ .defer_ref = first, .block = block } },
    }));
    try std.testing.expect(!deferCleanupStackRefsValid(function, &.{
        .{ .block = .{ .defer_ref = first, .block = block } },
        .{ .block = .{ .defer_ref = first, .block = block } },
    }));

    const stack = [_]DeferredCleanup{
        .{ .block = .{ .defer_ref = first, .block = block } },
        .{ .block = .{ .defer_ref = second, .block = block } },
    };
    try std.testing.expectEqual(@as(?usize, 2), deferCleanupEmissionCount(stack[0..], 0));
    const first_emit = deferCleanupAtEmissionIndex(function, stack[0..], 0, 0) orelse return error.TestUnexpectedResult;
    const second_emit = deferCleanupAtEmissionIndex(function, stack[0..], 0, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expect((deferCleanupRef(first_emit) orelse return error.TestUnexpectedResult).instruction_index == 1);
    try std.testing.expect((deferCleanupRef(second_emit) orelse return error.TestUnexpectedResult).instruction_index == 0);
    try std.testing.expect(deferCleanupAtEmissionIndex(function, stack[0..], 0, 2) == null);
}

test "defer cleanup stack snapshot restores full contents" {
    const span = ast.Span{ .offset = 1, .len = 1, .line = 1, .column = 1 };
    const later_span = ast.Span{ .offset = 2, .len = 1, .line = 1, .column = 2 };
    const first: mir.DeferCleanupRef = .{ .block_id = mir.BlockId.fromIndex(0), .instruction_index = 0, .source = mir.sourcePointFromSpan(span) };
    const second: mir.DeferCleanupRef = .{ .block_id = mir.BlockId.fromIndex(0), .instruction_index = 1, .source = mir.sourcePointFromSpan(later_span) };
    const block: ast.Block = .{ .span = span, .items = &.{} };

    var stack: std.ArrayList(DeferredCleanup) = .empty;
    defer stack.deinit(std.testing.allocator);
    try stack.append(std.testing.allocator, .{ .block = .{ .defer_ref = first, .block = block } });

    var snapshot = try captureDeferCleanupStack(std.testing.allocator, stack.items);
    defer snapshot.deinit(std.testing.allocator);

    stack.items[0] = .{ .block = .{ .defer_ref = second, .block = block } };
    try stack.append(std.testing.allocator, .{ .block = .{ .defer_ref = second, .block = block } });
    restoreDeferCleanupStack(&stack, snapshot);

    try std.testing.expectEqual(@as(usize, 1), stack.items.len);
    try std.testing.expect((deferCleanupRef(stack.items[0]) orelse return error.TestUnexpectedResult).instruction_index == 0);
}
