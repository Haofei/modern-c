const std = @import("std");

const mir_model = @import("mir_model.zig");

const Block = mir_model.Block;
const Function = mir_model.Function;
const Instruction = mir_model.Instruction;
const ValueType = mir_model.ValueType;

pub fn isSensitiveProducer(instruction: Instruction) bool {
    return (instruction.kind == .call or instruction.kind == .indirect_call or instruction.kind == .typed_load) and checkKind(instruction.result_ty) != null;
}

pub fn isSensitiveUse(instruction: Instruction) bool {
    return (instruction.kind == .return_value or instruction.kind == .representation_use) and checkKind(instruction.result_ty) != null;
}

pub fn defaultInstructionValueId(kind: Instruction.Kind, detail: []const u8) ?[]const u8 {
    return switch (kind) {
        .call, .indirect_call, .typed_load => detail,
        else => null,
    };
}

pub fn producerHasDominatingCheck(block: Block, producer_index: usize, ty: ValueType) bool {
    const expected_kind = checkKind(ty) orelse return true;
    if (producer_index >= block.instructions.len) return false;
    const expected_value_id = block.instructions[producer_index].typed_value_id;
    var i = producer_index + 1;
    while (i < block.instructions.len) : (i += 1) {
        const instruction = block.instructions[i];
        if (checkMatches(instruction, expected_kind, expected_value_id)) {
            return true;
        }
        if (instruction.kind == .call or instruction.kind == .indirect_call or instruction.kind == .typed_load or instruction.kind == .return_value or instruction.kind == .representation_use or instruction.kind == .assign) return false;
    }
    return false;
}

pub fn useHasDominatingCheck(allocator: std.mem.Allocator, function: Function, block_index: usize, instruction_index: usize, ty: ValueType) !bool {
    const expected_kind = checkKind(ty) orelse return true;
    if (block_index >= function.blocks.len) return false;
    const block = function.blocks[block_index];
    if (instruction_index >= block.instructions.len) return false;
    const expected_value_id = block.instructions[instruction_index].typed_value_id;
    // The recursion guard must cover every block; a fixed cap would force a conservative
    // false-positive (E_REPRESENTATION_CHECK_MISSING) on large functions.
    const visiting = try allocator.alloc(bool, function.blocks.len);
    defer allocator.free(visiting);
    @memset(visiting, false);
    return blockHasDominatingCheck(function, block_index, instruction_index, expected_kind, expected_value_id, visiting);
}

fn blockHasDominatingCheck(function: Function, block_index: usize, before_index: usize, expected_kind: []const u8, expected_value_id: ?mir_model.ValueId, visiting: []bool) bool {
    if (block_index >= function.blocks.len) return false;
    const block = function.blocks[block_index];
    var i = before_index;
    while (i > 0) {
        i -= 1;
        const instruction = block.instructions[i];
        if (checkMatches(instruction, expected_kind, expected_value_id)) {
            return true;
        }
    }

    if (block_index == 0) return false;
    if (visiting[block_index]) return false;
    visiting[block_index] = true;
    defer visiting[block_index] = false;

    var saw_predecessor = false;
    for (function.blocks, 0..) |candidate, predecessor_index| {
        if (!successorListed(candidate, block_index)) continue;
        saw_predecessor = true;
        if (!blockHasDominatingCheck(function, predecessor_index, candidate.instructions.len, expected_kind, expected_value_id, visiting)) return false;
    }
    return saw_predecessor;
}

fn checkMatches(instruction: Instruction, expected_kind: []const u8, expected_value_id: ?mir_model.ValueId) bool {
    if (instruction.kind != .representation_check) return false;
    const actual_kind = checkKind(instruction.result_ty) orelse return false;
    if (!std.mem.eql(u8, actual_kind, expected_kind)) return false;
    const actual_value_id = instruction.typed_value_id;
    if (expected_value_id) |expected| {
        if (actual_value_id) |actual| return actual.eql(expected);
        return false;
    }
    return actual_value_id == null;
}

pub fn checkKind(ty: ValueType) ?[]const u8 {
    return switch (ty) {
        .pointer => "nonnull_pointer",
        .cstr => "nonnull_cstr",
        .closed_enum => "closed_enum",
        else => null,
    };
}

pub fn typeName(ty: ValueType) []const u8 {
    return switch (ty) {
        .pointer => "nonnull_pointer",
        .cstr => "nonnull_cstr",
        .closed_enum => |name| name,
        else => "unknown",
    };
}

pub fn checkTraps(ty: ValueType) bool {
    return switch (ty) {
        .pointer => |shape| shape.kind != .raw_many,
        .cstr => true,
        .closed_enum => true,
        else => false,
    };
}

fn successorListed(block: Block, target: usize) bool {
    for (block.successors) |successor| {
        if (successor == target) return true;
    }
    return false;
}

test "dominating representation lookup rejects invalid instruction coordinates" {
    var instructions = [_]Instruction{
        .{
            .kind = .representation_use,
            .result_ty = .{ .pointer = .{ .kind = .single, .mutability = .@"const", .child = "u8" } },
            .detail = "p",
            .line = 1,
            .column = 1,
        },
    };
    var successors = [_]usize{};
    var blocks = [_]Block{.{
        .id = 0,
        .kind = "entry",
        .instructions = instructions[0..],
        .successors = successors[0..],
        .terminator = .{ .return_ = .void },
    }};
    const function = Function{
        .name = "invalid_coordinates",
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
    const pointer_ty = ValueType{ .pointer = .{ .kind = .single, .mutability = .@"const", .child = "u8" } };

    try std.testing.expect(!try useHasDominatingCheck(std.testing.allocator, function, 1, 0, pointer_ty));
    try std.testing.expect(!try useHasDominatingCheck(std.testing.allocator, function, 0, 1, pointer_ty));
    try std.testing.expect(!producerHasDominatingCheck(blocks[0], 1, pointer_ty));
}
