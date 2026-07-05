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
    const expected_value_id = block.instructions[producer_index].value_id;
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
    const expected_value_id = function.blocks[block_index].instructions[instruction_index].value_id;
    if (block_index >= function.blocks.len) return false;
    // The recursion guard must cover every block; a fixed cap would force a conservative
    // false-positive (E_REPRESENTATION_CHECK_MISSING) on large functions.
    const visiting = try allocator.alloc(bool, function.blocks.len);
    defer allocator.free(visiting);
    @memset(visiting, false);
    return blockHasDominatingCheck(function, block_index, instruction_index, expected_kind, expected_value_id, visiting);
}

fn blockHasDominatingCheck(function: Function, block_index: usize, before_index: usize, expected_kind: []const u8, expected_value_id: ?[]const u8, visiting: []bool) bool {
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

fn checkMatches(instruction: Instruction, expected_kind: []const u8, expected_value_id: ?[]const u8) bool {
    if (instruction.kind != .representation_check) return false;
    const actual_kind = checkKind(instruction.result_ty) orelse return false;
    if (!std.mem.eql(u8, actual_kind, expected_kind)) return false;
    const actual_value_id = instruction.value_id;
    if (expected_value_id) |expected| {
        if (actual_value_id) |actual| return std.mem.eql(u8, actual, expected);
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
