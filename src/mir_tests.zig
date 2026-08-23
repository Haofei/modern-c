const std = @import("std");

const ast = @import("ast.zig");
const checked_program = @import("checked_program.zig");
const diagnostics = @import("diagnostics.zig");
const parser = @import("parser.zig");
const mir = @import("mir.zig");
const mir_executable_body = @import("mir_executable_body.zig");
const mir_ownership_authority = @import("mir_ownership_authority.zig");
const mir_facts_view = @import("mir_facts_view.zig");
const mir_body_plan = @import("mir_body_plan.zig");
const mir_statement_plan = @import("mir_statement_plan.zig");
const module_parser = @import("module_parser.zig");
const test_support = @import("test_support.zig");

const Block = mir.Block;
const BlockId = mir.BlockId;
const ContractRegion = mir.ContractRegion;
const Function = mir.Function;
const Instruction = mir.Instruction;
const Module = mir.Module;
const PointerProvenance = mir.PointerProvenance;
const PointerProvenanceInvalidationReason = mir.PointerProvenanceInvalidationReason;
const RangeFact = mir.RangeFact;
const SourcePoint = mir.SourcePoint;
const SourceId = mir.SourceId;
const SpanId = mir.SpanId;
const TrapEdge = mir.TrapEdge;
const TrapKind = mir.TrapKind;
const SymbolId = mir.SymbolId;
const TypeId = mir.TypeId;
const ValueId = mir.ValueId;
const ValueType = mir.ValueType;

test "executable MIR classifies address representation casts" {
    const paddr: ValueType = .{ .address = .paddr };
    const usize_ty: ValueType = .{ .integer = "usize" };
    try std.testing.expectEqual(mir.ExecutableCastKind.address_to_integer, mir.ExecutableCastKind.classify(paddr, usize_ty).?);
    try std.testing.expectEqual(mir.ExecutableCastKind.integer_to_address, mir.ExecutableCastKind.classify(usize_ty, paddr).?);
    try std.testing.expect(mir.ExecutableCastKind.classify(paddr, .{ .integer = "u32" }) == null);
}

test "executable MIR owns address representation cast" {
    const source =
        \\fn address_value(value: PAddr) -> usize {
        \\    return value as usize;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("mir_executable_address_cast.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();

    const function = functionByName(module_mir, "address_value") orelse return error.TestUnexpectedResult;
    try std.testing.expect(function.executable_body.complete);
    try mir.validateLoweringAdmission(module_mir);
    const expression = function.executable_body.expressions[function.executable_body.expressions.len - 1];
    try std.testing.expectEqual(mir.ExecutableCastKind.address_to_integer, expression.operation.cast.kind);
}

test "executable MIR owns declared struct literal field order and types" {
    const source =
        \\struct Pair { first: u32, second: u64 }
        \\fn pair(first: u32, second: u64) -> Pair {
        \\    return .{ .second = second, .first = first };
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "executable_struct_literal.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source_parser = parser.Parser.init(source, &reporter);
    const module = try source_parser.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var module_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer module_mir.deinit();
    const function = functionByName(module_mir, "pair") orelse return error.TestUnexpectedResult;
    try std.testing.expect(function.executable_body.complete);
    try std.testing.expect(function.executable_body.return_type_id.isValid());
    try std.testing.expectEqual(@as(usize, 1), function.executable_body.aggregate_types.len);
    const aggregate_type = function.executable_body.aggregate_types[0];
    try std.testing.expectEqual(@as(usize, 2), aggregate_type.field_count);
    try std.testing.expectEqualStrings("u32", aggregate_type.field_types[0].name());
    try std.testing.expectEqualStrings("u64", aggregate_type.field_types[1].name());

    const result = function.executable_body.expressions[function.executable_body.expressions.len - 1];
    const aggregate = switch (result.operation) {
        .struct_ => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 2), aggregate.operand_count);
    try std.testing.expectEqual(@as(usize, 1), aggregate.field_indices[0]);
    try std.testing.expectEqual(@as(usize, 0), aggregate.field_indices[1]);
    try mir.validateLoweringAdmission(module_mir);

    const mutable_function = functionByNameMut(&module_mir, "pair") orelse return error.TestUnexpectedResult;
    const aggregate_expression = &mutable_function.executable_body.expressions[mutable_function.executable_body.expressions.len - 1];
    aggregate_expression.operation.struct_.field_indices[1] = 1;
    try std.testing.expectError(error.InvalidMirExecutableBody, mir.validateLoweringAdmission(module_mir));
    aggregate_expression.operation.struct_.field_indices[1] = 0;
    mutable_function.executable_body.aggregate_types[0].field_type_ids[0] = mutable_function.executable_body.aggregate_types[0].field_type_ids[1];
    try std.testing.expectError(error.InvalidMirExecutableBody, mir.validateLoweringAdmission(module_mir));
}

test "executable MIR owns nested by-value struct member identity and spelling" {
    const source =
        \\struct Inner { value: u32 }
        \\struct Outer { inner: Inner }
        \\fn read(outer: Outer) -> u32 {
        \\    return outer.inner.value;
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "executable_struct_member.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source_parser = parser.Parser.init(source, &reporter);
    const module = try source_parser.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var module_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer module_mir.deinit();
    const function = functionByName(module_mir, "read") orelse return error.TestUnexpectedResult;
    try std.testing.expect(function.executable_body.complete);
    try std.testing.expectEqual(@as(usize, 2), function.executable_body.aggregate_types.len);
    const result = function.executable_body.expressions[function.executable_body.expressions.len - 1];
    const outer_member = switch (result.operation) {
        .member => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 0), outer_member.field_index);
    const inner_member_expression = function.executable_body.expressions[outer_member.base.index()];
    const inner_member = switch (inner_member_expression.operation) {
        .member => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 0), inner_member.field_index);
    const inner_shape = mir_executable_body.aggregateType(&function.executable_body, inner_member_expression.type_id) orelse return error.TestUnexpectedResult;
    const outer_shape = mir_executable_body.aggregateType(&function.executable_body, function.executable_body.expressions[inner_member.base.index()].type_id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("value", inner_shape.field_spellings[0]);
    try std.testing.expectEqualStrings("inner", outer_shape.field_spellings[0]);
    try mir.validateLoweringAdmission(module_mir);

    const mutable_function = functionByNameMut(&module_mir, "read") orelse return error.TestUnexpectedResult;
    const mutable_result = &mutable_function.executable_body.expressions[mutable_function.executable_body.expressions.len - 1];
    mutable_result.operation.member.field_index = 1;
    try std.testing.expectError(error.InvalidMirExecutableBody, mir.validateLoweringAdmission(module_mir));
    mutable_result.operation.member.field_index = 0;
    const inner_type_id = mutable_function.executable_body.expressions[mutable_result.operation.member.base.index()].type_id;
    var inner_shape_index: ?usize = null;
    for (mutable_function.executable_body.aggregate_types, 0..) |shape, index| if (shape.type_id.eql(inner_type_id)) {
        inner_shape_index = index;
        break;
    };
    mutable_function.executable_body.aggregate_types[inner_shape_index orelse return error.TestUnexpectedResult].field_spellings[0] = "";
    try std.testing.expectError(error.InvalidMirExecutableBody, mir.validateLoweringAdmission(module_mir));
}

test "executable MIR owns pointer member load place and representation edge" {
    const source =
        \\struct Pair { first: u32, second: u64 }
        \\fn read(pair: *Pair) -> u64 { return pair.second; }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "executable_pointer_member.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source_parser = parser.Parser.init(source, &reporter);
    const module = try source_parser.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var module_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer module_mir.deinit();
    const function = functionByName(module_mir, "read") orelse return error.TestUnexpectedResult;
    try std.testing.expect(function.executable_body.complete);
    try std.testing.expectEqual(@as(usize, 1), function.executable_body.aggregate_types.len);
    try std.testing.expectEqual(@as(usize, 1), function.executable_body.places.len);
    const place = function.executable_body.places[0];
    try std.testing.expectEqual(@as(usize, 2), place.projection_count);
    try std.testing.expect(place.projections[0] == .deref);
    try std.testing.expectEqual(@as(usize, 1), place.projections[1].field);
    try std.testing.expectEqualStrings("u64", place.ty.name());
    const result = function.executable_body.expressions[function.executable_body.expressions.len - 1];
    const load = switch (result.operation) {
        .load => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(load.place.eql(place.id));
    try std.testing.expect(load.access.kind == .race_unordered);
    try std.testing.expectEqual(@as(usize, 1), function.executable_body.trap_edges.len);
    try mir.validateLoweringAdmission(module_mir);

    const mutable_function = functionByNameMut(&module_mir, "read") orelse return error.TestUnexpectedResult;
    mutable_function.executable_body.places[0].projections[1] = .{ .field = 0 };
    try std.testing.expectError(error.InvalidMirExecutableBody, mir.validateLoweringAdmission(module_mir));
}

test "MIR carries resolved per-file source identity into verified functions" {
    const first_source = "fn first() -> u32 { return 1; }\n";
    const second_source = "fn second() -> u32 { return 2; }\n";

    var first_reporter = diagnostics.Reporter.init(std.testing.allocator, "first.mc", first_source);
    defer first_reporter.deinit();
    var second_reporter = diagnostics.Reporter.init(std.testing.allocator, "second.mc", second_source);
    defer second_reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var first_parser = parser.Parser.init(first_source, &first_reporter);
    const first_module = try first_parser.parseModule(arena.allocator());
    defer first_module.deinit(arena.allocator());
    var second_parser = parser.Parser.init(second_source, &second_reporter);
    const second_module = try second_parser.parseModule(arena.allocator());
    defer second_module.deinit(arena.allocator());
    try std.testing.expect(!first_reporter.has_errors);
    try std.testing.expect(!second_reporter.has_errors);

    const resolved = [_]module_parser.ResolvedDecl{
        .{ .file_id = @enumFromInt(7), .decl = first_module.decls[0] },
        .{ .file_id = @enumFromInt(3), .decl = second_module.decls[0] },
    };
    var module_mir = try mir.buildOptFromResolvedDecls(std.testing.allocator, &resolved, .{});
    defer module_mir.deinit();

    try std.testing.expectEqual(@as(usize, 2), module_mir.source_identities.len);
    try std.testing.expectEqual(@as(u32, 7), module_mir.source_identities[0].file_id);
    try std.testing.expectEqual(@as(u32, 3), module_mir.source_identities[1].file_id);
    const first = functionByName(module_mir, "first") orelse return error.TestUnexpectedResult;
    const second = functionByName(module_mir, "second") orelse return error.TestUnexpectedResult;
    try std.testing.expect(first.typed_source_id.eql(SourceId.fromIndex(0)));
    try std.testing.expect(second.typed_source_id.eql(SourceId.fromIndex(1)));
    try mir.verifyBuiltMir(module_mir, &first_reporter);
    try std.testing.expect(!first_reporter.has_errors);
}

test "CheckedProgram is a syntax-free callable and body table" {
    const source =
        \\global seed: u32 = 1;
        \\extern fn sink(value: u32) -> void;
        \\#[no_lang_trap]
        \\fn read(value: u32) -> u32 { return value; }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "checked_program.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var module_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer module_mir.deinit();
    const checked = try checked_program.CheckedProgram.init(module_mir.checked_callables);
    try std.testing.expect(checked.matchesMir(module_mir));
    try std.testing.expectEqual(module_mir.functions.len, checked.callables.len);

    var saw_initializer = false;
    var saw_extern = false;
    var saw_function = false;
    for (checked.callables) |callable| switch (callable.kind) {
        .global_initializer => {
            saw_initializer = true;
            try std.testing.expect(callable.body_id.isValid());
            try std.testing.expectEqual(mir.ValueType.void, callable.return_ty);
        },
        .extern_function => {
            saw_extern = true;
            try std.testing.expect(!callable.body_id.isValid());
        },
        .function => {
            saw_function = true;
            try std.testing.expect(callable.body_id.isValid());
            try std.testing.expect(callable.no_lang_trap);
        },
    };
    try std.testing.expect(saw_initializer and saw_extern and saw_function);

    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(std.testing.allocator);
    try mir.appendDumpFromMir(std.testing.allocator, module_mir, &dump);
    try std.testing.expectEqual(module_mir.functions.len, std.mem.count(u8, dump.items, "checked callable "));

    module_mir.checked_callables[0].param_count += 1;
    try std.testing.expect(!checked.matchesMir(module_mir));
}

test "MIR statement plan owns fixed-array constant index and bounds trap" {
    const source =
        \\global matrix: [2][2]u32 = .{ .{ 1, 2 }, .{ 3, 4 } };
        \\fn take_row(row: [2]u32) -> u32 {
        \\    return row[1];
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
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_array_place_plan.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var module_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer module_mir.deinit();
    const function = functionByName(module_mir, "take_row") orelse return error.TestUnexpectedResult;
    const plan = mir_statement_plan.buildSingleBlockPlaceReturn(function) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), plan.returned.projection_count);
    switch (plan.returned.projections[0]) {
        .constant_index => |index| {
            try std.testing.expectEqual(@as(usize, 1), index.index);
            try std.testing.expectEqual(@as(usize, 2), index.bound);
            try std.testing.expect(index.checked);
        },
        else => return error.TestUnexpectedResult,
    }

    const nested = functionByName(module_mir, "nested_global") orelse return error.TestUnexpectedResult;
    const nested_plan = mir_statement_plan.buildSingleBlockPlaceReturn(nested) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), nested_plan.returned.projection_count);
    const store = nested_plan.store orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), store.target.projection_count);
    switch (store.value) {
        .integer_literal => |literal| try std.testing.expectEqual(@as(usize, 11), literal.value),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 4), nested.trap_edges.len);

    const replace = functionByName(module_mir, "replace_row") orelse return error.TestUnexpectedResult;
    const replace_plan = mir_statement_plan.buildSingleBlockPlaceReturn(replace) orelse return error.TestUnexpectedResult;
    const replace_store = replace_plan.store orelse return error.TestUnexpectedResult;
    switch (replace_store.value) {
        .array_literal => |literal| {
            try std.testing.expectEqual(@as(usize, 2), literal.element_count);
            try std.testing.expectEqual(@as(usize, 31), literal.elements[0].value);
            try std.testing.expectEqual(@as(usize, 32), literal.elements[1].value);
        },
        else => return error.TestUnexpectedResult,
    }

    const mutable_replace = functionByNameMut(&module_mir, "replace_row") orelse return error.TestUnexpectedResult;
    var aggregate_instruction: ?*mir.Instruction = null;
    for (mutable_replace.blocks) |*block| for (block.instructions) |*instruction| {
        if (instruction.kind == .expr and std.mem.eql(u8, instruction.detail, "array_literal")) {
            aggregate_instruction = instruction;
            break;
        }
    };
    const aggregate = aggregate_instruction orelse return error.TestUnexpectedResult;
    const saved_operand = aggregate.typed_aggregate_operand_span_ids[0];
    aggregate.typed_aggregate_operand_span_ids[0] = .invalid;
    var aggregate_reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_array_place_plan.mc", source);
    defer aggregate_reporter.deinit();
    try mir.verifyBuiltMir(module_mir, &aggregate_reporter);
    try std.testing.expect(aggregate_reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, aggregate_reporter.diagnostics.items[0].message, "E_MIR_IDENTITY") != null);
    aggregate.typed_aggregate_operand_span_ids[0] = saved_operand;

    const mutable_function = functionByNameMut(&module_mir, "take_row") orelse return error.TestUnexpectedResult;
    var mutated = false;
    for (mutable_function.blocks) |*block| for (block.instructions) |*instruction| {
        if (instruction.kind != .index) continue;
        instruction.constant_index_value = 0;
        mutated = true;
        break;
    };
    try std.testing.expect(mutated);
    var verifier_reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_array_place_plan.mc", source);
    defer verifier_reporter.deinit();
    try mir.verifyBuiltMir(module_mir, &verifier_reporter);
    try std.testing.expect(verifier_reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, verifier_reporter.diagnostics.items[0].message, "E_MIR_IDENTITY") != null);
}

test "MIR verifier rejects per-file source identity drift" {
    // DIAGNOSTIC_UNIT: E_MIR_SOURCE_ID
    const source = "fn main() -> u32 { return 1; }\n";
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "source_identity_drift.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());

    const resolved = [_]module_parser.ResolvedDecl{
        .{ .file_id = @enumFromInt(9), .decl = module.decls[0] },
    };
    var module_mir = try mir.buildOptFromResolvedDecls(std.testing.allocator, &resolved, .{});
    defer module_mir.deinit();
    module_mir.functions[0].typed_source_id = SourceId.fromIndex(4096);

    var verifier_reporter = diagnostics.Reporter.init(std.testing.allocator, "source_identity_drift.mc", source);
    defer verifier_reporter.deinit();
    try mir.verifyBuiltMir(module_mir, &verifier_reporter);
    try std.testing.expect(verifier_reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, verifier_reporter.diagnostics.items[0].message, "E_MIR_SOURCE_ID") != null);
}

test "MIR block model carries typed block identity" {
    const source =
        \\fn main() -> u32 {
        \\    return 1;
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_block_id.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());

    var module_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer module_mir.deinit();

    const main_fn = functionByName(module_mir, "main").?;
    const main_symbol = symbolIdentityBySpelling(module_mir, "main").?;
    try std.testing.expect(main_fn.typed_symbol_id.isValid());
    try std.testing.expect(main_fn.typed_symbol_id.eql(main_symbol.id));
    try std.testing.expect(main_fn.blocks.len > 0);
    for (main_fn.blocks) |block| {
        try std.testing.expect(block.typed_id.isValid());
        try std.testing.expectEqual(block.id, block.typed_id.index());
        try std.testing.expectEqual(BlockId.fromIndex(block.id), block.typed_id);
        try std.testing.expectEqual(block.successors.len, block.typed_successors.len);
        for (block.successors, 0..) |successor, index| {
            try std.testing.expect(block.typed_successors[index].isValid());
            try std.testing.expectEqual(successor, block.typed_successors[index].index());
        }
    }
}

fn symbolIdentityBySpelling(module: mir.Module, spelling: []const u8) ?mir.SymbolIdentity {
    for (module.symbol_identities) |identity| {
        if (std.mem.eql(u8, identity.spelling, spelling)) return identity;
    }
    return null;
}

fn functionByName(module: mir.Module, name: []const u8) ?mir.Function {
    for (module.functions) |function| {
        if (std.mem.eql(u8, function.name, name)) return function;
    }
    return null;
}

fn callInstructionByDetail(function: mir.Function, detail: []const u8) ?mir.Instruction {
    for (function.blocks) |block| {
        for (block.instructions) |instruction| {
            if (instruction.kind == .call and std.mem.eql(u8, instruction.detail, detail)) return instruction;
        }
    }
    return null;
}

fn targetTypeFactByKind(function: mir.Function, kind: mir.TargetTypeKind) ?mir.TargetTypeFact {
    for (function.target_type_facts) |fact| if (fact.kind == kind) return fact;
    return null;
}

fn countTargetTypeFactsByKind(function: mir.Function, kind: mir.TargetTypeKind) usize {
    var count: usize = 0;
    for (function.target_type_facts) |fact| {
        if (fact.kind == kind) count += 1;
    }
    return count;
}

fn countOwnershipEventsByKind(function: mir.Function, kind: mir.OwnershipEventKind) usize {
    var count: usize = 0;
    for (function.ownership_events) |event| {
        if (event.kind == kind) count += 1;
    }
    return count;
}

fn typeOwnershipByName(module: mir.Module, name: []const u8) ?mir.TypeOwnershipFact {
    for (module.type_ownership_facts) |fact| {
        if (std.mem.eql(u8, fact.type_name, name)) return fact;
    }
    return null;
}

fn valueIdentityBySpelling(function: mir.Function, spelling: []const u8) ?mir.ValueIdentity {
    for (function.value_identities) |identity| {
        if (std.mem.eql(u8, identity.spelling, spelling)) return identity;
    }
    return null;
}

fn targetOwnerIdentityBySpelling(function: mir.Function, spelling: []const u8) ?mir.SymbolIdentity {
    for (function.target_owner_identities) |identity| {
        if (std.mem.eql(u8, identity.spelling, spelling)) return identity;
    }
    return null;
}

fn typeIdentityBySpelling(function: mir.Function, spelling: []const u8) ?mir.TypeIdentity {
    for (function.type_identities) |identity| {
        if (std.mem.eql(u8, identity.spelling, spelling)) return identity;
    }
    return null;
}

fn spanIdentityBySource(function: mir.Function, source: SourcePoint) ?mir.SpanIdentity {
    for (function.span_identities) |identity| {
        if (identity.source.line == source.line and
            identity.source.column == source.column and
            identity.source.offset == source.offset and
            identity.source.len == source.len)
        {
            return identity;
        }
    }
    return null;
}

fn functionByNameMut(module: *mir.Module, name: []const u8) ?*mir.Function {
    for (module.functions) |*function| {
        if (std.mem.eql(u8, function.name, name)) return function;
    }
    return null;
}

fn functionByNamePtr(module: *const mir.Module, name: []const u8) ?*const mir.Function {
    for (module.functions) |*function| {
        if (std.mem.eql(u8, function.name, name)) return function;
    }
    return null;
}

test "MIR verifier rejects function symbol identity drift" {
    // DIAGNOSTIC_UNIT: E_MIR_SYMBOL_ID
    const source =
        \\fn main() -> u32 {
        \\    return 1;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "bad_symbol_id.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var module_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer module_mir.deinit();
    try std.testing.expect(module_mir.symbol_identities.len > 0);
    module_mir.functions[0].typed_symbol_id = SymbolId.fromIndex(4096);

    var verifier_reporter = diagnostics.Reporter.init(std.testing.allocator, "bad_symbol_id.mc", source);
    defer verifier_reporter.deinit();
    try mir.verifyBuiltMir(module_mir, &verifier_reporter);
    try std.testing.expect(verifier_reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, verifier_reporter.diagnostics.items[0].message, "E_MIR_SYMBOL_ID") != null);
}

test "MIR verifier rejects instruction typed identity drift" {
    // DIAGNOSTIC_UNIT: E_MIR_IDENTITY
    const source =
        \\fn main() -> u32 {
        \\    let x: u32 = 1;
        \\    return x;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "bad_instruction_identity.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var type_drift_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer type_drift_mir.deinit();
    var type_drift_fn = functionByNameMut(&type_drift_mir, "main").?;
    type_drift_fn.blocks[0].instructions[0].typed_result_ty = TypeId.fromIndex(4096);

    var type_reporter = diagnostics.Reporter.init(std.testing.allocator, "bad_instruction_type_identity.mc", source);
    defer type_reporter.deinit();
    try mir.verifyBuiltMir(type_drift_mir, &type_reporter);
    try std.testing.expect(type_reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, type_reporter.diagnostics.items[0].message, "E_MIR_IDENTITY") != null);

    var span_drift_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer span_drift_mir.deinit();
    var span_drift_fn = functionByNameMut(&span_drift_mir, "main").?;
    span_drift_fn.blocks[0].instructions[0].typed_span_id = SpanId.fromIndex(4096);

    var span_reporter = diagnostics.Reporter.init(std.testing.allocator, "bad_instruction_span_identity.mc", source);
    defer span_reporter.deinit();
    try mir.verifyBuiltMir(span_drift_mir, &span_reporter);
    try std.testing.expect(span_reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, span_reporter.diagnostics.items[0].message, "E_MIR_IDENTITY") != null);
}

test "MIR owns member, assignment, and return operand identities" {
    // DIAGNOSTIC_UNIT: E_MIR_IDENTITY
    const source =
        \\struct Pair { left: u32, right: u32 }
        \\struct Box { pair: Pair }
        \\global box: Box = .{ .pair = .{ .left = 1, .right = 2 } };
        \\fn update(value: u32) -> u32 {
        \\    box.pair.left = value;
        \\    return box.pair.left;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_place_identity.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var module_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer module_mir.deinit();
    const function = functionByName(module_mir, "update").?;
    var member_edges: usize = 0;
    var saw_assignment_edges = false;
    var saw_return_edge = false;
    for (function.blocks[0].instructions) |instruction| {
        if (instruction.typed_base_operand_span_id.isValid()) {
            try std.testing.expect(instruction.member_field_index != null);
            member_edges += 1;
        }
        if (instruction.kind == .assign) {
            try std.testing.expect(instruction.typed_target_operand_span_id.isValid());
            try std.testing.expect(instruction.typed_value_operand_span_id.isValid());
            saw_assignment_edges = true;
        }
        if (instruction.kind == .return_value) {
            try std.testing.expect(instruction.typed_value_operand_span_id.isValid());
            saw_return_edge = true;
        }
    }
    try std.testing.expectEqual(@as(usize, 4), member_edges);
    try std.testing.expect(saw_assignment_edges);
    try std.testing.expect(saw_return_edge);

    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(std.testing.allocator);
    try mir.appendDumpFromMir(std.testing.allocator, module_mir, &dump);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, dump.items, "mir place_identity fn=update"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, dump.items, "mir statement_operand_identity fn=update"));

    const mutable_function = functionByNameMut(&module_mir, "update").?;
    var corrupted = false;
    for (mutable_function.blocks[0].instructions) |*instruction| {
        if (!instruction.typed_base_operand_span_id.isValid()) continue;
        instruction.typed_base_operand_span_id = .invalid;
        corrupted = true;
        break;
    }
    try std.testing.expect(corrupted);
    var invalid_reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_place_identity_invalid.mc", source);
    defer invalid_reporter.deinit();
    try mir.verifyBuiltMir(module_mir, &invalid_reporter);
    try std.testing.expect(invalid_reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, invalid_reporter.diagnostics.items[0].message, "E_MIR_IDENTITY") != null);
}

test "MIR statement plan traces a local aggregate copy to its initializer" {
    const source =
        \\struct Pair { left: u32, right: u32 }
        \\global default_pair: Pair = .{ .left = 1, .right = 2 };
        \\fn read() -> u32 {
        \\    let pair: Pair = default_pair;
        \\    return pair.right;
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_local_place_plan.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    var module_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer module_mir.deinit();

    const plan = mir_statement_plan.buildSingleBlockPlaceReturn(functionByName(module_mir, "read").?) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(mir_statement_plan.PlaceRootKind.local, plan.returned.root_kind);
    try std.testing.expectEqualStrings("pair", plan.returned.root_name);
    try std.testing.expectEqual(@as(usize, 1), plan.returned.projection_count);
    const local = plan.local_init orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("pair", local.name);
    try std.testing.expectEqual(mir_statement_plan.PlaceRootKind.global, local.value.root_kind);
    try std.testing.expectEqualStrings("default_pair", local.value.root_name);
}

test "MIR shared local aggregate assignment plans retain literal identities" {
    // DIAGNOSTIC_UNIT: E_MIR_IDENTITY
    const source =
        \\struct Pair { left: u32, right: u32 }
        \\fn array_value() -> [2]u32 {
        \\    var values: [2]u32 = uninit;
        \\    values = .{ 17, 29 };
        \\    return values;
        \\}
        \\fn struct_value() -> Pair {
        \\    var pair: Pair = uninit;
        \\    pair = .{ .right = 29, .left = 17 };
        \\    return pair;
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_local_aggregate_assignment.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var module_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer module_mir.deinit();

    const array_function = functionByName(module_mir, "array_value") orelse return error.TestUnexpectedResult;
    const array_plan = mir_statement_plan.buildLocalAggregateAssignmentReturn(array_function) orelse return error.TestUnexpectedResult;
    const array_local = array_function.blocks[0].instructions[0];
    try std.testing.expectEqualStrings("values", array_plan.local_name);
    try std.testing.expect(array_plan.local_id.eql(array_local.typed_value_id orelse return error.TestUnexpectedResult));
    switch (array_plan.value) {
        .array_literal => |literal| {
            try std.testing.expectEqual(@as(usize, 2), literal.element_count);
            try std.testing.expectEqual(@as(usize, 17), literal.elements[0].value);
            try std.testing.expectEqual(@as(usize, 29), literal.elements[1].value);
        },
        else => return error.TestUnexpectedResult,
    }

    const struct_function = functionByName(module_mir, "struct_value") orelse return error.TestUnexpectedResult;
    const struct_plan = mir_statement_plan.buildLocalAggregateAssignmentReturn(struct_function) orelse return error.TestUnexpectedResult;
    const struct_local = struct_function.blocks[0].instructions[0];
    try std.testing.expectEqualStrings("pair", struct_plan.local_name);
    try std.testing.expect(struct_plan.local_id.eql(struct_local.typed_value_id orelse return error.TestUnexpectedResult));
    switch (struct_plan.value) {
        .struct_literal => |literal| {
            try std.testing.expectEqual(@as(usize, 2), literal.field_count);
            // The source literal is right then left, while the declaration is
            // left then right. The plan retains source operand order plus
            // declaration identities instead of relying on either alone.
            try std.testing.expectEqual(@as(usize, 1), literal.fields[0].field_index);
            try std.testing.expectEqual(@as(usize, 29), literal.fields[0].value.value);
            try std.testing.expectEqual(@as(usize, 0), literal.fields[1].field_index);
            try std.testing.expectEqual(@as(usize, 17), literal.fields[1].value.value);
        },
        else => return error.TestUnexpectedResult,
    }

    const mutable_struct = functionByNameMut(&module_mir, "struct_value") orelse return error.TestUnexpectedResult;
    var aggregate: ?*mir.Instruction = null;
    for (mutable_struct.blocks) |*block| for (block.instructions) |*instruction| {
        if (instruction.kind == .expr and std.mem.eql(u8, instruction.detail, "struct_literal")) {
            aggregate = instruction;
            break;
        }
    };
    const duplicate_field_index = aggregate orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), duplicate_field_index.typed_aggregate_operand_count);
    duplicate_field_index.typed_aggregate_field_indices[1] = duplicate_field_index.typed_aggregate_field_indices[0];
    var duplicate_reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_local_aggregate_duplicate.mc", source);
    defer duplicate_reporter.deinit();
    try mir.verifyBuiltMir(module_mir, &duplicate_reporter);
    try std.testing.expect(duplicate_reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, duplicate_reporter.diagnostics.items[0].message, "E_MIR_IDENTITY") != null);

    var sentinel_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer sentinel_mir.deinit();
    const sentinel_struct = functionByNameMut(&sentinel_mir, "struct_value") orelse return error.TestUnexpectedResult;
    var sentinel_aggregate: ?*mir.Instruction = null;
    for (sentinel_struct.blocks) |*block| for (block.instructions) |*instruction| {
        if (instruction.kind == .expr and std.mem.eql(u8, instruction.detail, "struct_literal")) {
            sentinel_aggregate = instruction;
            break;
        }
    };
    const sentinel_field_index = sentinel_aggregate orelse return error.TestUnexpectedResult;
    sentinel_field_index.typed_aggregate_field_indices[0] = std.math.maxInt(usize);
    var sentinel_reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_local_aggregate_sentinel.mc", source);
    defer sentinel_reporter.deinit();
    try mir.verifyBuiltMir(sentinel_mir, &sentinel_reporter);
    try std.testing.expect(sentinel_reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, sentinel_reporter.diagnostics.items[0].message, "E_MIR_IDENTITY") != null);
}

test "MIR shared local aggregate place-update plan owns nested values and fails closed" {
    const source =
        \\struct Pair { left: u32, right: u32 }
        \\struct Holder { pair: Pair, grid: [2][2]u32 }
        \\extern fn touch() -> void;
        \\fn flat() -> u32 {
        \\    let pair: Pair = .{ .right = 2, .left = 1 };
        \\    return pair.left;
        \\}
        \\fn nested_update() -> u32 {
        \\    var holder: Holder = .{
        \\        .grid = .{ .{ 1, 2 }, .{ 3, 4 } },
        \\        .pair = .{ .right = 8, .left = 7 },
        \\    };
        \\    holder.grid[1][0] = 9;
        \\    return holder.grid[1][0];
        \\}
        \\fn extra_effect() -> u32 {
        \\    let pair: Pair = .{ .right = 2, .left = 1 };
        \\    touch();
        \\    return pair.left;
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_local_aggregate_place_update.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var module_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer module_mir.deinit();

    const flat = mir_statement_plan.buildLocalAggregatePlaceUpdateReturn(functionByName(module_mir, "flat").?) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("pair", flat.local_name);
    try std.testing.expectEqual(@as(usize, 3), flat.initializer.count);
    const flat_root = flat.initializer.nodes[flat.initializer.root];
    switch (flat_root.operation) {
        .struct_literal => |fields| {
            try std.testing.expectEqual(@as(usize, 2), fields.child_count);
            try std.testing.expectEqual(@as(usize, 1), fields.children[0].field_index);
            try std.testing.expectEqual(@as(usize, 0), fields.children[1].field_index);
            switch (flat.initializer.nodes[fields.children[0].node].operation) {
                .integer_literal => |value| try std.testing.expectEqual(@as(usize, 2), value),
                else => return error.TestUnexpectedResult,
            }
            switch (flat.initializer.nodes[fields.children[1].node].operation) {
                .integer_literal => |value| try std.testing.expectEqual(@as(usize, 1), value),
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }

    const nested = mir_statement_plan.buildLocalAggregatePlaceUpdateReturn(functionByName(module_mir, "nested_update").?) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("holder", nested.local_name);
    try std.testing.expectEqual(@as(usize, 11), nested.initializer.count);
    const nested_root = nested.initializer.nodes[nested.initializer.root];
    switch (nested_root.operation) {
        .struct_literal => |fields| {
            try std.testing.expectEqual(@as(usize, 2), fields.child_count);
            try std.testing.expectEqual(@as(usize, 1), fields.children[0].field_index);
            try std.testing.expectEqual(@as(usize, 0), fields.children[1].field_index);
            switch (nested.initializer.nodes[fields.children[0].node].operation) {
                .array_literal => |grid| {
                    try std.testing.expectEqual(@as(usize, 2), grid.child_count);
                    switch (nested.initializer.nodes[grid.children[1].node].operation) {
                        .array_literal => |row| {
                            try std.testing.expectEqual(@as(usize, 2), row.child_count);
                            switch (nested.initializer.nodes[row.children[0].node].operation) {
                                .integer_literal => |value| try std.testing.expectEqual(@as(usize, 3), value),
                                else => return error.TestUnexpectedResult,
                            }
                            switch (nested.initializer.nodes[row.children[1].node].operation) {
                                .integer_literal => |value| try std.testing.expectEqual(@as(usize, 4), value),
                                else => return error.TestUnexpectedResult,
                            }
                        },
                        else => return error.TestUnexpectedResult,
                    }
                },
                else => return error.TestUnexpectedResult,
            }
            switch (nested.initializer.nodes[fields.children[1].node].operation) {
                .struct_literal => |pair| {
                    try std.testing.expectEqual(@as(usize, 2), pair.child_count);
                    try std.testing.expectEqual(@as(usize, 1), pair.children[0].field_index);
                    try std.testing.expectEqual(@as(usize, 0), pair.children[1].field_index);
                },
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
    const update = nested.update orelse return error.TestUnexpectedResult;
    try std.testing.expect(update.target.root_id.eql(nested.local_id));
    try std.testing.expectEqual(@as(usize, 3), update.target.projection_count);
    switch (update.target.projections[0]) {
        .field => |field| try std.testing.expectEqual(@as(usize, 1), field.field_index),
        else => return error.TestUnexpectedResult,
    }
    for (update.target.projections[1..3], [_]usize{ 1, 0 }) |projection, expected_index| switch (projection) {
        .constant_index => |index| {
            try std.testing.expectEqual(expected_index, index.index);
            try std.testing.expect(index.checked);
        },
        else => return error.TestUnexpectedResult,
    };
    switch (update.value) {
        .integer_literal => |literal| try std.testing.expectEqual(@as(usize, 9), literal.value),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(nested.returned.root_id.eql(nested.local_id));
    try std.testing.expectEqual(@as(usize, 3), nested.returned.projection_count);

    try std.testing.expect(mir_statement_plan.buildLocalAggregatePlaceUpdateReturn(functionByName(module_mir, "extra_effect").?) == null);

    var identity_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer identity_mir.deinit();
    const identity_function = functionByNameMut(&identity_mir, "nested_update") orelse return error.TestUnexpectedResult;
    var local_id: ?mir.ValueId = null;
    var mismatched_id: ?mir.ValueId = null;
    for (identity_function.blocks[0].instructions) |*instruction| {
        if (instruction.kind == .local and std.mem.eql(u8, instruction.detail, "holder")) local_id = instruction.typed_value_id;
        if (instruction.kind == .return_value) mismatched_id = instruction.typed_value_id;
    }
    try std.testing.expect(local_id != null and mismatched_id != null);
    try std.testing.expect(!local_id.?.eql(mismatched_id.?));
    for (identity_function.blocks[0].instructions) |*instruction| {
        if (instruction.kind == .local and std.mem.eql(u8, instruction.detail, "holder")) {
            instruction.typed_value_id = mismatched_id;
            break;
        }
    }
    try std.testing.expect(mir_statement_plan.buildLocalAggregatePlaceUpdateReturn(identity_function.*) == null);

    var bounds_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer bounds_mir.deinit();
    const bounds_function = functionByNameMut(&bounds_mir, "nested_update") orelse return error.TestUnexpectedResult;
    try std.testing.expect(bounds_function.trap_edges.len != 0);
    bounds_function.trap_edges[0].source = .assert_stmt;
    try std.testing.expect(mir_statement_plan.buildLocalAggregatePlaceUpdateReturn(bounds_function.*) == null);

    bounds_function.trap_edges[0].source = .bounds_check;
    const trap_span_id = bounds_function.trap_edges[0].typed_span_id;
    bounds_function.trap_edges[0].typed_span_id = .invalid;
    try std.testing.expect(mir_statement_plan.buildLocalAggregatePlaceUpdateReturn(bounds_function.*) == null);
    bounds_function.trap_edges[0].typed_span_id = trap_span_id;

    try std.testing.expect(bounds_function.bounds_facts.len != 0);
    bounds_function.bounds_facts[0].typed_span_id = .invalid;
    try std.testing.expect(mir_statement_plan.buildLocalAggregatePlaceUpdateReturn(bounds_function.*) == null);
}

test "MIR direct-call aggregate projected returns own identities and checks" {
    const source =
        \\struct Bag { values: [2]u32, tail: [2]*mut u8 }
        \\fn make_values(seed: u32) -> [2]u32 { return uninit; }
        \\fn make_bag(seed: u32) -> Bag { return uninit; }
        \\fn values_at(seed: u32, index: usize) -> u32 {
        \\    return make_values(seed)[index];
        \\}
        \\fn bag_values_at(seed: u32, index: usize) -> u32 {
        \\    return make_bag(seed).values[index];
        \\}
        \\fn bag_tail_at(seed: u32, index: usize) -> *mut u8 {
        \\    return make_bag(seed).tail[index];
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_direct_aggregate_projected_return.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var module_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer module_mir.deinit();

    const values_plan = mir_statement_plan.buildDirectCallProjectedReturn(functionByName(module_mir, "values_at").?) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("make_values", values_plan.callee_name);
    try std.testing.expect(values_plan.callee_value_id.isValid());
    try std.testing.expect(values_plan.call_location.span_id.isValid());
    try std.testing.expectEqual(@as(usize, 1), values_plan.argument_count);
    try std.testing.expectEqual(@as(usize, 0), values_plan.arguments[0].index);
    switch (values_plan.arguments[0].value) {
        .parameter => |parameter| {
            try std.testing.expectEqualStrings("seed", parameter.name);
            try std.testing.expect(parameter.value_id.isValid());
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(values_plan.arguments[0].type_fact.typed_callee_span_id.eql(values_plan.call_location.span_id));
    try std.testing.expectEqual(@as(usize, 1), values_plan.projection_count);
    switch (values_plan.projections[0]) {
        .index => |index| {
            try std.testing.expectEqualStrings("index", index.operand_name);
            try std.testing.expect(index.operand_id.isValid());
            try std.testing.expect(index.operand_fact.typed_span_id.isValid());
            try std.testing.expect(index.location.span_id.isValid());
            try std.testing.expect(index.constant_value == null);
            try std.testing.expect(index.static_bound == null);
            try std.testing.expect(index.checked);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(values_plan.representation_check == null);

    const bag_values_plan = mir_statement_plan.buildDirectCallProjectedReturn(functionByName(module_mir, "bag_values_at").?) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("make_bag", bag_values_plan.callee_name);
    try std.testing.expectEqual(@as(usize, 2), bag_values_plan.projection_count);
    switch (bag_values_plan.projections[0]) {
        .field => |field| {
            try std.testing.expectEqualStrings("values", field.field_name);
            try std.testing.expectEqual(@as(usize, 0), field.field_index);
            try std.testing.expect(field.location.span_id.isValid());
        },
        else => return error.TestUnexpectedResult,
    }
    switch (bag_values_plan.projections[1]) {
        .index => |index| try std.testing.expectEqualStrings("index", index.operand_name),
        else => return error.TestUnexpectedResult,
    }

    const tail_function = functionByName(module_mir, "bag_tail_at").?;
    const tail_plan = mir_statement_plan.buildDirectCallProjectedReturn(tail_function) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("make_bag", tail_plan.callee_name);
    try std.testing.expectEqual(@as(usize, 2), tail_plan.projection_count);
    switch (tail_plan.projections[0]) {
        .field => |field| {
            try std.testing.expectEqualStrings("tail", field.field_name);
            try std.testing.expectEqual(@as(usize, 1), field.field_index);
        },
        else => return error.TestUnexpectedResult,
    }
    const tail_index = switch (tail_plan.projections[1]) {
        .index => |index| index,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("index", tail_index.operand_name);
    try std.testing.expect(tail_index.checked);
    try std.testing.expect(tail_index.operand_fact.typed_span_id.isValid());
    const representation = tail_plan.representation_check orelse return error.TestUnexpectedResult;
    try std.testing.expect(representation.location.span_id.isValid());
    try std.testing.expect(representation.value_id.isValid());
    try std.testing.expectEqual(@as(std.meta.Tag(mir.ValueType), .pointer), std.meta.activeTag(representation.result_ty));
    try std.testing.expectEqual(@as(usize, 1), tail_function.bounds_facts.len);
    try std.testing.expect(tail_function.bounds_facts[0].typed_span_id.eql(tail_index.operand_fact.typed_span_id));
    try std.testing.expectEqual(@as(usize, 2), tail_function.trap_edges.len);
    var saw_bounds_trap = false;
    var saw_representation_trap = false;
    for (tail_function.trap_edges) |edge| {
        if (edge.kind == .Bounds) {
            try std.testing.expect(edge.typed_span_id.eql(tail_index.location.span_id));
            saw_bounds_trap = true;
        }
        if (edge.kind == .InvalidRepresentation) {
            try std.testing.expect(edge.typed_span_id.eql(representation.location.span_id));
            saw_representation_trap = true;
        }
    }
    try std.testing.expect(saw_bounds_trap and saw_representation_trap);

    var callee_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer callee_mir.deinit();
    const callee_function = functionByNameMut(&callee_mir, "bag_tail_at") orelse return error.TestUnexpectedResult;
    for (callee_function.blocks[0].instructions) |*instruction| {
        if (instruction.kind == .call) {
            instruction.typed_callee_span_id = .invalid;
            break;
        }
    }
    try std.testing.expect(mir_statement_plan.buildDirectCallProjectedReturn(callee_function.*) == null);

    var argument_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer argument_mir.deinit();
    const argument_function = functionByNameMut(&argument_mir, "bag_tail_at") orelse return error.TestUnexpectedResult;
    for (argument_function.target_type_facts) |*fact| {
        if (fact.kind == .direct_call_argument) {
            fact.typed_operand_value_id = .invalid;
            break;
        }
    }
    try std.testing.expect(mir_statement_plan.buildDirectCallProjectedReturn(argument_function.*) == null);

    var index_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer index_mir.deinit();
    const index_function = functionByNameMut(&index_mir, "bag_tail_at") orelse return error.TestUnexpectedResult;
    for (index_function.blocks[0].instructions) |*instruction| {
        if (instruction.kind == .index) {
            instruction.typed_index_operand_span_id = .invalid;
            break;
        }
    }
    try std.testing.expect(mir_statement_plan.buildDirectCallProjectedReturn(index_function.*) == null);

    var bounds_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer bounds_mir.deinit();
    const bounds_function = functionByNameMut(&bounds_mir, "bag_tail_at") orelse return error.TestUnexpectedResult;
    try std.testing.expect(bounds_function.bounds_facts.len > 0);
    bounds_function.bounds_facts[0].typed_span_id = .invalid;
    try std.testing.expect(mir_statement_plan.buildDirectCallProjectedReturn(bounds_function.*) == null);

    var representation_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer representation_mir.deinit();
    const representation_function = functionByNameMut(&representation_mir, "bag_tail_at") orelse return error.TestUnexpectedResult;
    try std.testing.expect(representation_function.representation_facts.len > 0);
    for (representation_function.representation_facts) |*fact| fact.typed_span_id = .invalid;
    try std.testing.expect(mir_statement_plan.buildDirectCallProjectedReturn(representation_function.*) == null);
}

test "MIR sequence foreach return owns iterable evaluation binding representation and CFG" {
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
    var parsed = try test_support.parseModule("mir_sequence_foreach_return.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();

    const direct = mir_statement_plan.buildSequenceForEachReturn(functionByName(module_mir, "first_value").?) orelse return error.TestUnexpectedResult;
    const direct_call = switch (direct.iterable) {
        .direct_call => |call| call,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("make_values", direct_call.callee_name);
    try std.testing.expectEqual(@as(usize, 1), direct_call.argument_count);
    try std.testing.expectEqual(@as(usize, 0), direct_call.projection_count);
    try std.testing.expectEqualStrings("value", direct.binding_name);
    try std.testing.expect(direct.binding_id.isValid());
    try std.testing.expect(direct.element_fact.typed_operand_value_id.eql(direct.binding_id));
    try std.testing.expectEqual(@as(usize, 0), direct.fallback.value);

    const field = mir_statement_plan.buildSequenceForEachReturn(functionByName(module_mir, "first_field").?) orelse return error.TestUnexpectedResult;
    const field_call = switch (field.iterable) {
        .direct_call => |call| call,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("make_bag", field_call.callee_name);
    try std.testing.expectEqual(@as(usize, 1), field_call.projection_count);
    switch (field_call.projections[0]) {
        .field => |projection| {
            try std.testing.expectEqualStrings("values", projection.field_name);
            try std.testing.expectEqual(@as(usize, 0), projection.field_index);
        },
        else => return error.TestUnexpectedResult,
    }

    const parameter = mir_statement_plan.buildSequenceForEachReturn(functionByName(module_mir, "first_parameter").?) orelse return error.TestUnexpectedResult;
    switch (parameter.iterable) {
        .parameter => |root| {
            try std.testing.expectEqualStrings("values", root.name);
            try std.testing.expect(root.value_id.isValid());
        },
        else => return error.TestUnexpectedResult,
    }

    const nested = mir_statement_plan.buildSequenceForEachReturn(functionByName(module_mir, "first_nested_call").?) orelse return error.TestUnexpectedResult;
    const nested_call = switch (nested.iterable) {
        .direct_call => |call| call,
        else => return error.TestUnexpectedResult,
    };
    switch (nested_call.arguments[0].value) {
        .zero_arg_call => |call| try std.testing.expectEqualStrings("next_seed", call.callee_name),
        else => return error.TestUnexpectedResult,
    }

    const slice = mir_statement_plan.buildSequenceForEachReturn(functionByName(module_mir, "first_slice").?) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(.slice, std.meta.activeTag(slice.iterable_fact.target_ty.kind));
    try std.testing.expect(slice.representation_check != null);
    try std.testing.expect(slice.representation_check.?.value_id.isValid());

    const slice_call = mir_statement_plan.buildSequenceForEachReturn(functionByName(module_mir, "first_slice_call").?) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(.slice, std.meta.activeTag(slice_call.iterable_fact.target_ty.kind));
    try std.testing.expect(slice_call.representation_check != null);
    switch (slice_call.iterable) {
        .direct_call => |call| try std.testing.expectEqualStrings("make_slice", call.callee_name),
        else => return error.TestUnexpectedResult,
    }

    var optimized_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer optimized_mir.deinit();
    try std.testing.expect(mir_statement_plan.buildSequenceForEachReturn(functionByName(optimized_mir, "first_slice").?) != null);
    try std.testing.expect(mir_statement_plan.buildSequenceForEachReturn(functionByName(optimized_mir, "first_slice_call").?) != null);

    var binding_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer binding_mir.deinit();
    const binding_function = functionByNameMut(&binding_mir, "first_value") orelse return error.TestUnexpectedResult;
    for (binding_function.target_type_facts) |*fact| {
        if (fact.kind == .for_element) {
            fact.typed_operand_value_id = .invalid;
            break;
        }
    }
    try std.testing.expect(mir_statement_plan.buildSequenceForEachReturn(binding_function.*) == null);

    var field_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer field_mir.deinit();
    const field_function = functionByNameMut(&field_mir, "first_field") orelse return error.TestUnexpectedResult;
    for (field_function.blocks[0].instructions) |*instruction| {
        if (instruction.member_field_index != null) {
            instruction.member_field_index = std.math.maxInt(usize);
            break;
        }
    }
    try std.testing.expect(mir_statement_plan.buildSequenceForEachReturn(field_function.*) == null);
}

test "MIR while control plan owns break and continue CFG edges" {
    const source =
        \\fn stop(flag: bool) -> void {
        \\    while flag { break; }
        \\}
        \\fn repeat(flag: bool) -> void {
        \\    while flag { continue; }
        \\}
    ;
    var parsed = try test_support.parseModule("mir_while_control.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();

    const stop = mir_statement_plan.buildWhileControl(functionByName(module_mir, "stop").?) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(.break_, stop.control);
    try std.testing.expectEqualStrings("flag", stop.condition_name);
    try std.testing.expect(stop.condition_id.isValid());
    try std.testing.expect(stop.control_location.span_id.isValid());

    const repeat = mir_statement_plan.buildWhileControl(functionByName(module_mir, "repeat").?) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(.continue_, repeat.control);
    try std.testing.expect(repeat.control_location.span_id.isValid());

    var corrupted = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer corrupted.deinit();
    const corrupted_stop = functionByNameMut(&corrupted, "stop") orelse return error.TestUnexpectedResult;
    corrupted_stop.blocks[1].instructions[0].detail = "continue";
    try std.testing.expect(mir_statement_plan.buildWhileControl(corrupted_stop.*) == null);
}

test "MIR identity return plan owns resolved function symbol return" {
    const source =
        \\fn tick() -> void {}
        \\fn entry_of() -> fn() -> void { return tick; }
    ;
    var parsed = try test_support.parseModule("mir_identity_return.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();

    const plan = mir_statement_plan.buildIdentityReturn(functionByName(module_mir, "entry_of").?) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("tick", plan.name);
    try std.testing.expect(plan.value_id.isValid());
    try std.testing.expect(plan.value_location.span_id.isValid());
    try std.testing.expect(plan.return_location.span_id.isValid());

    var corrupted = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer corrupted.deinit();
    const function = functionByNameMut(&corrupted, "entry_of") orelse return error.TestUnexpectedResult;
    function.blocks[0].instructions[0].detail = "not_tick";
    try std.testing.expect(mir_statement_plan.buildIdentityReturn(function.*) == null);
}

test "MIR sequence foreach update plan owns local generation update traps and control" {
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
    var parsed = try test_support.parseModule("mir_sequence_foreach_update.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();

    const sum = mir_statement_plan.buildSequenceForEachUpdate(functionByName(module_mir, "sum").?) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("total", sum.local_name);
    try std.testing.expectEqualStrings("value", sum.binding_name);
    try std.testing.expectEqual(.continue_, sum.control);
    switch (sum.update) {
        .checked_add_element => |update| try std.testing.expectEqual(.integer, std.meta.activeTag(update.operation_fact.result_ty)),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(sum.representation_check.value_id.isValid());

    const first = mir_statement_plan.buildSequenceForEachUpdate(functionByName(module_mir, "first").?) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(.break_, first.control);
    try std.testing.expectEqual(.replace_with_element, first.update);

    var corrupted = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer corrupted.deinit();
    const corrupted_first = functionByNameMut(&corrupted, "first") orelse return error.TestUnexpectedResult;
    corrupted_first.blocks[2].instructions[corrupted_first.blocks[2].instructions.len - 1].detail = "continue";
    try std.testing.expect(mir_statement_plan.buildSequenceForEachUpdate(corrupted_first.*) == null);
}

test "MIR target-type owner identities mirror direct calls" {
    const source =
        \\fn callee(x: u32) -> u32 {
        \\    return x;
        \\}
        \\
        \\fn caller() -> u32 {
        \\    return callee(7);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_target_owner_id.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var module_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer module_mir.deinit();

    const caller = functionByName(module_mir, "caller").?;
    const owner = targetOwnerIdentityBySpelling(caller, "callee") orelse return error.TestUnexpectedResult;
    const result_type = typeIdentityBySpelling(caller, "u32") orelse return error.TestUnexpectedResult;
    const result_fact = targetTypeFactByKind(caller, .direct_call_result) orelse return error.TestUnexpectedResult;
    const result_span = spanIdentityBySource(caller, result_fact.source) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("callee", result_fact.target_owner.?);
    try std.testing.expect(result_fact.typed_target_owner_id.eql(owner.id));
    try std.testing.expect(result_fact.typed_result_ty.eql(result_type.id));
    try std.testing.expect(result_fact.typed_span_id.eql(result_span.id));

    var saw_instruction = false;
    var saw_call = false;
    for (caller.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.kind == .call and std.mem.eql(u8, instruction.detail, "callee")) {
            try std.testing.expect(instruction.typed_callee_span_id.eql(result_span.id));
            saw_call = true;
        }
        if (instruction.kind != .target_type) continue;
        if (!std.mem.eql(u8, instruction.detail, @tagName(mir.TargetTypeKind.direct_call_result))) continue;
        try std.testing.expectEqualStrings("callee", instruction.target_owner.?);
        try std.testing.expect(instruction.typed_target_owner_id.?.eql(owner.id));
        try std.testing.expect(instruction.typed_result_ty.eql(result_type.id));
        try std.testing.expect(instruction.typed_span_id.eql(result_span.id));
        saw_instruction = true;
    };
    try std.testing.expect(saw_instruction);
    try std.testing.expect(saw_call);

    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(std.testing.allocator);
    try mir.appendDumpFromMir(std.testing.allocator, module_mir, &dump);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir target_owner_identity fn=caller id=0 spelling=callee") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir target_type_fact fn=caller kind=direct_call_result target_type=u32 result_type=u32 aggregate_construction=none target_owner=callee target_index=none recorded=true") != null);
    const expected_call_identity = try std.fmt.allocPrint(std.testing.allocator, "mir call_identity fn=caller block=0 kind=call detail=callee callee_span_id={}", .{result_span.id.index()});
    defer std.testing.allocator.free(expected_call_identity);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, expected_call_identity) != null);
    const expected_fact_result = try std.fmt.allocPrint(std.testing.allocator, "typed_result_ty_id={}", .{result_type.id.index()});
    defer std.testing.allocator.free(expected_fact_result);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, expected_fact_result) != null);
    const expected_fact_span = try std.fmt.allocPrint(std.testing.allocator, "typed_span_id={}", .{result_span.id.index()});
    defer std.testing.allocator.free(expected_fact_span);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, expected_fact_span) != null);
    const expected_fact_owner = try std.fmt.allocPrint(std.testing.allocator, "typed_target_owner_id={}", .{owner.id.index()});
    defer std.testing.allocator.free(expected_fact_owner);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, expected_fact_owner) != null);

    const caller_mut = functionByNameMut(&module_mir, "caller").?;
    var cleared_call_identity = false;
    for (caller_mut.blocks) |*block| {
        for (block.instructions) |*instruction| {
            if (instruction.kind != .call) continue;
            instruction.typed_callee_span_id = .invalid;
            cleared_call_identity = true;
            break;
        }
        if (cleared_call_identity) break;
    }
    try std.testing.expect(cleared_call_identity);

    var identity_reporter = diagnostics.Reporter.init(std.testing.allocator, "bad_call_identity.mc", source);
    defer identity_reporter.deinit();
    try mir.verifyBuiltMir(module_mir, &identity_reporter);
    try std.testing.expect(identity_reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, identity_reporter.diagnostics.items[0].message, "E_MIR_IDENTITY") != null);
}

test "MIR facts view keeps typed lookup and module fallback separate" {
    const source =
        \\enum E { bad }
        \\
        \\fn callee(x: u32) -> u32 {
        \\    return x;
        \\}
        \\
        \\fn caller() -> u32 {
        \\    let local = callee(7);
        \\    return local;
        \\}
        \\
        \\fn literal_source() -> f64 {
        \\    return 1.5;
        \\}
        \\
        \\fn text_source() -> cstr {
        \\    return "txt";
        \\}
        \\
        \\fn array_source() -> [2]u32 {
        \\    return .{ 1, 2 };
        \\}
        \\
        \\fn ok_source(value: u32) -> Result<u32, E> {
        \\    return ok(value);
        \\}
        \\
        \\fn err_source() -> Result<u32, E> {
        \\    return err(.bad);
        \\}
        \\
        \\fn add(env: *mut u32, value: u32) -> u32 {
        \\    return env.* + value;
        \\}
        \\
        \\fn bind_source(env: *mut u32) -> closure(u32) -> u32 {
        \\    return bind(env, add);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_facts_view_typed_target_type.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var module_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer module_mir.deinit();

    const callee = functionByName(module_mir, "callee").?;
    const caller = functionByName(module_mir, "caller").?;
    const literal_source = functionByName(module_mir, "literal_source").?;
    const text_source = functionByName(module_mir, "text_source").?;
    const array_source = functionByName(module_mir, "array_source").?;
    const ok_source = functionByName(module_mir, "ok_source").?;
    const err_source = functionByName(module_mir, "err_source").?;
    const bind_source = functionByName(module_mir, "bind_source").?;
    const result_fact = targetTypeFactByKind(caller, .direct_call_result) orelse return error.TestUnexpectedResult;
    const expression_fact = targetTypeFactByKind(caller, .expression_result) orelse return error.TestUnexpectedResult;
    const local_fact = targetTypeFactByKind(caller, .inferred_local) orelse return error.TestUnexpectedResult;
    const float_fact = targetTypeFactByKind(literal_source, .float_literal) orelse return error.TestUnexpectedResult;
    const string_fact = targetTypeFactByKind(text_source, .string_literal) orelse return error.TestUnexpectedResult;
    const array_fact = targetTypeFactByKind(array_source, .array_literal) orelse return error.TestUnexpectedResult;
    const ok_fact = targetTypeFactByKind(ok_source, .result_ok) orelse return error.TestUnexpectedResult;
    const err_fact = targetTypeFactByKind(err_source, .result_err) orelse return error.TestUnexpectedResult;
    const bind_fact = targetTypeFactByKind(bind_source, .bind) orelse return error.TestUnexpectedResult;
    const db = mir_facts_view.MirFactsView.init();
    const result_span = result_fact.source;

    try std.testing.expect(db.targetTypeFactAtOwned(&callee, .direct_call_result, result_span, result_fact.target_owner.?, result_fact.target_index) == null);
    try std.testing.expect(db.targetTypeFactAtOwnedCurrentSpan(.{
        .current = &callee,
        .fact = .{
            .kind = .direct_call_result,
            .source = result_span,
            .owner = result_fact.target_owner.?,
            .index = result_fact.target_index,
        },
    }) == null);
    try std.testing.expect(db.targetTypeFactAtCurrentSpan(.{
        .current = &callee,
        .fact = .{
            .kind = .expression_result,
            .source = expression_fact.source,
        },
    }) == null);
    try std.testing.expect(db.targetTypeFactAtOwnedCurrentSpan(.{
        .current = &callee,
        .fact = .{
            .kind = .inferred_local,
            .source = local_fact.source,
            .owner = local_fact.target_owner.?,
            .index = local_fact.target_index,
        },
    }) == null);
    try std.testing.expect(db.targetTypeFactAtCurrentSpan(.{
        .current = &callee,
        .fact = .{
            .kind = .float_literal,
            .source = float_fact.source,
        },
    }) == null);
    try std.testing.expect(db.targetTypeFactAtCurrentSpan(.{
        .current = &callee,
        .fact = .{
            .kind = .string_literal,
            .source = string_fact.source,
        },
    }) == null);
    try std.testing.expect(db.targetTypeFactAtCurrentSpan(.{
        .current = &callee,
        .fact = .{
            .kind = .array_literal,
            .source = array_fact.source,
        },
    }) == null);
    try std.testing.expect(db.targetTypeFactAtCurrentSpan(.{
        .current = &callee,
        .fact = .{
            .kind = .result_ok,
            .source = ok_fact.source,
        },
    }) == null);
    try std.testing.expect(db.targetTypeFactAtCurrentSpan(.{
        .current = &callee,
        .fact = .{
            .kind = .result_err,
            .source = err_fact.source,
        },
    }) == null);
    try std.testing.expect(db.targetTypeFactAtCurrentSpan(.{
        .current = &callee,
        .fact = .{
            .kind = .bind,
            .source = bind_fact.source,
        },
    }) == null);

    const wrong_span = mir.SourcePoint{
        .line = result_fact.source.line + 100,
        .column = result_fact.source.column + 100,
        .offset = result_fact.source.offset + 100,
        .len = result_fact.source.len,
    };
    try std.testing.expect(db.targetTypeFactAtOwned(&caller, .direct_call_result, wrong_span, result_fact.target_owner.?, result_fact.target_index) == null);

    const by_id = db.targetTypeFactById(&caller, .{
        .kind = .direct_call_result,
        .typed_span_id = result_fact.typed_span_id,
        .typed_result_ty = result_fact.typed_result_ty,
        .typed_target_owner_id = result_fact.typed_target_owner_id,
        .target_index = result_fact.target_index,
    }) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.meta.eql(result_fact, by_id));

    try std.testing.expect(db.targetTypeFactById(&caller, .{
        .kind = .direct_call_result,
        .typed_span_id = result_fact.typed_span_id,
        .typed_result_ty = result_fact.typed_result_ty,
        .target_index = result_fact.target_index,
    }) == null);
}

test "MIR exposes generic typed span identity matching for codegen facts" {
    const source =
        \\extern fn close_a(value: u32) -> void;
        \\
        \\fn direct_call(x: u32) -> void {
        \\    close_a(x);
        \\}
        \\
        \\fn call_target() -> void {
        \\    fence.release();
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_generic_typed_span_identity.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var module_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer module_mir.deinit();

    const direct_fn = functionByName(module_mir, "direct_call").?;
    const direct_call = callInstructionByDetail(direct_fn, "close_a") orelse return error.TestUnexpectedResult;
    const direct_result = targetTypeFactByKind(direct_fn, .direct_call_result) orelse return error.TestUnexpectedResult;
    const direct_arg = targetTypeFactByKind(direct_fn, .direct_call_argument) orelse return error.TestUnexpectedResult;
    try std.testing.expect(direct_call.typed_span_id.isValid());
    try std.testing.expect(direct_result.typed_span_id.isValid());
    try std.testing.expect(direct_arg.typed_span_id.isValid());

    const direct_call_source = mir.sourcePointForSpanId(direct_fn, direct_call.typed_span_id) orelse return error.TestUnexpectedResult;
    try std.testing.expect((mir.spanIdAtSource(direct_fn, direct_call_source) orelse return error.TestUnexpectedResult).eql(direct_call.typed_span_id));
    try std.testing.expect(mir.instructionMatchesSpanId(direct_fn, direct_call, direct_call.typed_span_id));
    try std.testing.expect(mir.targetTypeFactMatchesSpanId(direct_fn, direct_result, direct_result.typed_span_id));
    try std.testing.expect(mir.targetTypeFactMatchesSpanId(direct_fn, direct_arg, direct_arg.typed_span_id));

    var drifted_instruction = direct_call;
    drifted_instruction.line += 100;
    drifted_instruction.column += 100;
    try std.testing.expect(mir.instructionMatchesSpanId(direct_fn, drifted_instruction, direct_call.typed_span_id));

    var drifted_result = direct_result;
    drifted_result.source.line += 100;
    drifted_result.source.column += 100;
    try std.testing.expect(mir.targetTypeFactMatchesSpanId(direct_fn, drifted_result, direct_result.typed_span_id));
    try std.testing.expect(mir.spanIdAtSource(direct_fn, drifted_result.source) == null);

    const call_target_fn = functionByName(module_mir, "call_target").?;
    const call_target_fact = if (call_target_fn.call_target_facts.len == 1) call_target_fn.call_target_facts[0] else return error.TestUnexpectedResult;
    try std.testing.expect(call_target_fact.typed_span_id.isValid());
    const db = mir_facts_view.MirFactsView.init();
    try std.testing.expect(std.meta.eql(call_target_fact, db.callTargetFactById(&call_target_fn, .{
        .kind = .fence_release,
        .typed_span_id = call_target_fact.typed_span_id,
    }).?));
    try std.testing.expect(mir.callTargetFactMatchesSpanId(call_target_fn, call_target_fact, call_target_fact.typed_span_id));
    var drifted_call_target = call_target_fact;
    drifted_call_target.source.line += 100;
    drifted_call_target.source.column += 100;
    try std.testing.expect(mir.callTargetFactMatchesSpanId(call_target_fn, drifted_call_target, call_target_fact.typed_span_id));
}

test "MIR verifier rejects target owner instruction identity drift" {
    const source =
        \\fn callee(x: u32) -> u32 {
        \\    return x;
        \\}
        \\
        \\fn caller() -> u32 {
        \\    return callee(7);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "bad_target_owner_instruction_id.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var module_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer module_mir.deinit();

    const caller = functionByNameMut(&module_mir, "caller").?;
    var mutated = false;
    for (caller.blocks) |*block| {
        for (block.instructions) |*instruction| {
            if (instruction.kind != .target_type) continue;
            if (!std.mem.eql(u8, instruction.detail, @tagName(mir.TargetTypeKind.direct_call_result))) continue;
            instruction.typed_target_owner_id = SymbolId.fromIndex(4096);
            mutated = true;
            break;
        }
        if (mutated) break;
    }
    try std.testing.expect(mutated);

    var verifier_reporter = diagnostics.Reporter.init(std.testing.allocator, "bad_target_owner_instruction_id.mc", source);
    defer verifier_reporter.deinit();
    try mir.verifyBuiltMir(module_mir, &verifier_reporter);
    try std.testing.expect(verifier_reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, verifier_reporter.diagnostics.items[0].message, "E_MIR_IDENTITY") != null);
}

test "MIR target-type admission rejects target owner fact identity drift" {
    const source =
        \\fn callee(x: u32) -> u32 {
        \\    return x;
        \\}
        \\
        \\fn caller() -> u32 {
        \\    return callee(7);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "bad_target_owner_fact_id.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var module_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer module_mir.deinit();
    const caller = functionByNameMut(&module_mir, "caller").?;
    for (caller.target_type_facts) |*fact| {
        if (fact.kind != .direct_call_result) continue;
        fact.typed_target_owner_id = SymbolId.fromIndex(4096);
        break;
    } else return error.TestUnexpectedResult;

    try std.testing.expectError(error.InvalidMirTargetTypeFacts, mir.validateTargetTypeFactsForLowering(module_mir));
}

test "MIR target-type admission rejects target result type identity drift" {
    const source =
        \\fn callee(x: u32) -> u32 {
        \\    return x;
        \\}
        \\
        \\fn caller() -> u32 {
        \\    return callee(7);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "bad_target_result_type_id.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var module_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer module_mir.deinit();
    const caller = functionByNameMut(&module_mir, "caller").?;
    for (caller.target_type_facts) |*fact| {
        if (fact.kind != .direct_call_result) continue;
        fact.typed_result_ty = TypeId.fromIndex(4096);
        break;
    } else return error.TestUnexpectedResult;

    try std.testing.expectError(error.InvalidMirTargetTypeFacts, mir.validateTargetTypeFactsForLowering(module_mir));
}

test "MIR target-type admission rejects target span identity drift" {
    const source =
        \\fn callee(x: u32) -> u32 {
        \\    return x;
        \\}
        \\
        \\fn caller() -> u32 {
        \\    return callee(7);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "bad_target_span_id.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var module_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer module_mir.deinit();
    const caller = functionByNameMut(&module_mir, "caller").?;
    for (caller.target_type_facts) |*fact| {
        if (fact.kind != .direct_call_result) continue;
        fact.typed_span_id = SpanId.fromIndex(4096);
        break;
    } else return error.TestUnexpectedResult;

    try std.testing.expectError(error.InvalidMirTargetTypeFacts, mir.validateTargetTypeFactsForLowering(module_mir));
}

test "MIR target-type admission rejects target fact identity table drift" {
    const source =
        \\fn callee(x: u32) -> u32 {
        \\    return x;
        \\}
        \\
        \\fn caller() -> u32 {
        \\    return callee(7);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "bad_target_fact_identity_table.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    {
        var module_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
        defer module_mir.deinit();
        const caller = functionByNameMut(&module_mir, "caller").?;
        const fact = targetTypeFactByKind(caller.*, .direct_call_result) orelse return error.TestUnexpectedResult;
        caller.type_identities[fact.typed_result_ty.index()].spelling = "u64";

        try std.testing.expectError(error.InvalidMirTargetTypeFacts, mir.validateTargetTypeFactsForLowering(module_mir));
    }

    {
        var module_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
        defer module_mir.deinit();
        const caller = functionByNameMut(&module_mir, "caller").?;
        const fact = targetTypeFactByKind(caller.*, .direct_call_result) orelse return error.TestUnexpectedResult;
        caller.span_identities[fact.typed_span_id.index()].source.line += 1;

        try std.testing.expectError(error.InvalidMirTargetTypeFacts, mir.validateTargetTypeFactsForLowering(module_mir));
    }

    {
        var module_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
        defer module_mir.deinit();
        const caller = functionByNameMut(&module_mir, "caller").?;
        const fact = targetTypeFactByKind(caller.*, .direct_call_result) orelse return error.TestUnexpectedResult;
        caller.target_owner_identities[fact.typed_target_owner_id.index()].spelling = "other_callee";

        try std.testing.expectError(error.InvalidMirTargetTypeFacts, mir.validateTargetTypeFactsForLowering(module_mir));
    }
}

test "MIR target-type admission rejects unknown target-type result identity drift" {
    const source =
        \\fn callee(x: u32) -> u32 {
        \\    return x;
        \\}
        \\
        \\fn caller() -> u32 {
        \\    return callee(7);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "unknown_target_result_type.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var module_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer module_mir.deinit();
    const caller = functionByNameMut(&module_mir, "caller").?;
    var fact_count: usize = 0;
    for (caller.target_type_facts) |*fact| {
        if (fact.kind != .direct_call_result) continue;
        fact.result_ty = .unknown;
        fact_count += 1;
    }
    var instruction_count: usize = 0;
    for (caller.blocks) |*block| for (block.instructions) |*instruction| {
        if (instruction.kind != .target_type or !std.mem.eql(u8, instruction.detail, @tagName(mir.TargetTypeKind.direct_call_result))) continue;
        instruction.result_ty = .unknown;
        instruction_count += 1;
    };
    try std.testing.expect(fact_count != 0);
    try std.testing.expect(instruction_count != 0);

    try std.testing.expectError(error.InvalidMirTargetTypeFacts, mir.validateTargetTypeFactsForLowering(module_mir));
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, mir.validateLoweringAdmission(module_mir));
}

test "MIR dump exposes bounded FFI parameter contracts" {
    const source =
        \\extern "C" fn dma_submit(cpu: [*]mut u8, dma: DmaAddr, len: usize) -> i32;
        \\extern fn inspect(bytes: []const u8, optional: ?*const u8) -> void;
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_ffi_contracts.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());

    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(std.testing.allocator);
    try mir.appendDumpFromDecls(std.testing.allocator, module.decls, &dump);

    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir function name=dma_submit symbol_id=") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "return=i32 no_lang_trap=false irq_context=false extern=true c_abi=true params=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "fn=dma_submit index=0 name=cpu kind=raw_many_pointer nonnull=true access=read_write extent=extern_contract alignment=type provenance=extern_unknown stable_until=call_return") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "fn=dma_submit index=1 name=dma kind=address address_class=dma conversion=explicit") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "fn=inspect index=0 name=bytes kind=slice nonnull=when_nonempty access=read extent=slice_length") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "fn=inspect index=1 name=optional kind=pointer nonnull=false access=read") != null);
}

fn functionHasInstruction(function: mir.Function, kind: mir.Instruction.Kind, detail: []const u8) bool {
    for (function.blocks) |block| {
        for (block.instructions) |instruction| {
            if (instruction.kind == kind and std.mem.eql(u8, instruction.detail, detail)) return true;
        }
    }
    return false;
}

fn functionHasTerminator(function: mir.Function, kind: std.meta.Tag(mir.Terminator)) bool {
    for (function.blocks) |block| {
        if (std.meta.activeTag(block.terminator) == kind) return true;
    }
    return false;
}

fn typeExprHeadName(ty: ast.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .name => |name| name.text,
        .generic => |node| node.base.text,
        else => null,
    };
}

fn countTrapEdges(function: mir.Function, kind: mir.TrapKind) usize {
    var count: usize = 0;
    for (function.trap_edges) |edge| {
        if (edge.kind == kind) count += 1;
    }
    return count;
}

fn hasPointerProvenanceFact(function: mir.Function, subject: []const u8, element_index: ?usize, provenance: PointerProvenance, reason: PointerProvenanceInvalidationReason, storage: ?[]const u8) bool {
    for (function.pointer_provenance_facts) |fact| {
        if (!std.mem.eql(u8, fact.subject, subject)) continue;
        if (fact.field_path != null) continue;
        if (fact.element_index != element_index) continue;
        if (fact.provenance != provenance) continue;
        if (fact.invalidation_reason != reason) continue;
        if (storage) |expected_storage| {
            if (fact.storage == null or !std.mem.eql(u8, fact.storage.?, expected_storage)) continue;
        } else if (fact.storage != null) {
            continue;
        }
        return true;
    }
    return false;
}

fn hasPointerProvenanceFieldFact(function: mir.Function, subject: []const u8, field_path: []const u8, element_index: ?usize, provenance: PointerProvenance, reason: PointerProvenanceInvalidationReason, storage: ?[]const u8) bool {
    for (function.pointer_provenance_facts) |fact| {
        if (!std.mem.eql(u8, fact.subject, subject)) continue;
        const actual_field = fact.field_path orelse continue;
        if (!std.mem.eql(u8, actual_field, field_path)) continue;
        if (fact.element_index != element_index) continue;
        if (fact.provenance != provenance) continue;
        if (fact.invalidation_reason != reason) continue;
        if (storage) |expected_storage| {
            if (fact.storage == null or !std.mem.eql(u8, fact.storage.?, expected_storage)) continue;
        } else if (fact.storage != null) {
            continue;
        }
        return true;
    }
    return false;
}

fn countPointerProvenanceFacts(function: mir.Function, subject: []const u8, provenance: PointerProvenance) usize {
    var count: usize = 0;
    for (function.pointer_provenance_facts) |fact| {
        if (fact.field_path != null) continue;
        if (std.mem.eql(u8, fact.subject, subject) and fact.provenance == provenance) count += 1;
    }
    return count;
}

fn hasAggregateReturnSummaryFact(module: mir.Module, callee: []const u8) bool {
    for (module.aggregate_return_summaries) |fact| {
        if (std.mem.eql(u8, fact.callee, callee)) return true;
    }
    return false;
}

fn hasAggregateReturnPointerFact(module: mir.Module, callee: []const u8, field_path: []const u8, provenance: PointerProvenance) bool {
    for (module.aggregate_return_pointer_facts) |fact| {
        if (!std.mem.eql(u8, fact.callee, callee)) continue;
        if (!std.mem.eql(u8, fact.field_path, field_path)) continue;
        if (fact.provenance == provenance) return true;
    }
    return false;
}

fn duplicateCallTargetFact(function: *mir.Function, allocator: std.mem.Allocator) !void {
    if (function.call_target_facts.len == 0) return error.TestUnexpectedResult;
    const facts = try allocator.alloc(mir.CallTargetFact, function.call_target_facts.len + 1);
    @memcpy(facts[0..function.call_target_facts.len], function.call_target_facts);
    facts[function.call_target_facts.len] = function.call_target_facts[0];
    allocator.free(function.call_target_facts);
    function.call_target_facts = facts;
}

fn duplicateCallTargetInstruction(function: *mir.Function, allocator: std.mem.Allocator) !void {
    for (function.blocks) |*block| {
        for (block.instructions) |instruction| {
            if (instruction.kind != .call_target) continue;
            const instructions = try allocator.alloc(mir.Instruction, block.instructions.len + 1);
            @memcpy(instructions[0..block.instructions.len], block.instructions);
            instructions[block.instructions.len] = instruction;
            allocator.free(block.instructions);
            block.instructions = instructions;
            return;
        }
    }
    return error.TestUnexpectedResult;
}

fn duplicateTargetTypeFact(function: *mir.Function, allocator: std.mem.Allocator) !void {
    if (function.target_type_facts.len == 0) return error.TestUnexpectedResult;
    const facts = try allocator.alloc(mir.TargetTypeFact, function.target_type_facts.len + 1);
    @memcpy(facts[0..function.target_type_facts.len], function.target_type_facts);
    facts[function.target_type_facts.len] = function.target_type_facts[0];
    allocator.free(function.target_type_facts);
    function.target_type_facts = facts;
}

fn simpleTypeExprForTest(name: []const u8, span: ast.Span) ast.TypeExpr {
    return .{ .span = span, .kind = .{ .name = .{ .text = name, .span = span } } };
}

fn retargetFirstTargetTypeFactAndInstruction(
    function: *mir.Function,
    kind: mir.TargetTypeKind,
    spelling: []const u8,
    result_ty: ValueType,
) !void {
    const type_identity = typeIdentityBySpelling(function.*, spelling) orelse return error.TestUnexpectedResult;
    var fact_source: ?mir.SourcePoint = null;
    for (function.target_type_facts) |*fact| {
        if (fact.kind != kind) continue;
        const replacement_ty = simpleTypeExprForTest(spelling, fact.target_ty.span);
        fact.target_ty = replacement_ty;
        fact.result_ty = result_ty;
        fact.typed_result_ty = type_identity.id;
        fact_source = fact.source;
        break;
    } else return error.TestUnexpectedResult;

    const source = fact_source.?;
    for (function.blocks) |*block| {
        for (block.instructions) |*instruction| {
            if (instruction.kind != .target_type) continue;
            if (!std.mem.eql(u8, instruction.detail, @tagName(kind))) continue;
            if (instruction.line != source.line or instruction.column != source.column) continue;
            instruction.target_ty = simpleTypeExprForTest(spelling, instruction.target_ty.?.span);
            instruction.result_ty = result_ty;
            instruction.typed_result_ty = type_identity.id;
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "MIR owns all scalar conversion builtin call targets" {
    const source =
        \\type W = wrap<u8>;
        \\fn from_value(x: u8) -> u64 { return u64.from(x); }
        \\fn try_value(x: u64) -> Result<u8, ConversionError> { return u8.try_from(x); }
        \\fn trap_value(x: u64) -> u8 { return u8.trap_from(x); }
        \\fn wrap_value(x: u64) -> u8 { return u8.wrap_from(x); }
        \\fn sat_value(x: u64) -> u8 { return u8.sat_from(x); }
        \\fn mod_value() -> W { return W.from_mod(300); }
        \\fn adapted_binary(x: u64) -> u8 { return u8.trap_from(1 + x); }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_conversion_call_targets.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    try mir.validateCallTargetFactsForLowering(typed_mir);

    const cases = [_]struct { name: []const u8, kind: mir.CallTargetKind, result_name: []const u8 }{
        .{ .name = "from_value", .kind = .conversion_from, .result_name = "u64" },
        .{ .name = "try_value", .kind = .conversion_try_from, .result_name = "Result" },
        .{ .name = "trap_value", .kind = .conversion_trap_from, .result_name = "u8" },
        .{ .name = "wrap_value", .kind = .conversion_wrap_from, .result_name = "u8" },
        .{ .name = "sat_value", .kind = .conversion_sat_from, .result_name = "u8" },
        .{ .name = "mod_value", .kind = .conversion_from_mod, .result_name = "value" },
        .{ .name = "adapted_binary", .kind = .conversion_trap_from, .result_name = "u8" },
    };
    for (cases) |case| {
        const function = functionByName(typed_mir, case.name).?;
        try std.testing.expectEqual(@as(usize, 1), function.call_target_facts.len);
        try std.testing.expectEqual(case.kind, function.call_target_facts[0].kind);
        try std.testing.expectEqualStrings(case.result_name, function.call_target_facts[0].result_ty.name());
        try std.testing.expect(function.target_type_facts.len >= 2);
        try std.testing.expect(targetTypeFactByKind(function, .conversion_source) != null);
        try std.testing.expect(targetTypeFactByKind(function, .conversion_target) != null);
    }
    try mir.validateLoweringAdmission(typed_mir);
    try std.testing.expectEqualStrings("u32", valueTypeName((targetTypeFactByKind(functionByName(typed_mir, "mod_value").?, .conversion_source) orelse return error.TestUnexpectedResult).result_ty));
    try std.testing.expectEqualStrings("u64", valueTypeName((targetTypeFactByKind(functionByName(typed_mir, "adapted_binary").?, .conversion_source) orelse return error.TestUnexpectedResult).result_ty));
}

test "MIR lowering admission rejects unknown call-target result facts" {
    const source =
        \\fn from_value(x: u8) -> u64 { return u64.from(x); }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_unknown_call_target_type.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByNameMut(&typed_mir, "from_value").?;
    for (function.call_target_facts) |*fact| {
        if (fact.kind != .conversion_from) continue;
        fact.result_ty = .unknown;
        break;
    } else return error.TestUnexpectedResult;
    for (function.blocks) |*block| {
        for (block.instructions) |*instruction| {
            if (instruction.kind != .call_target or !std.mem.eql(u8, instruction.detail, @tagName(mir.CallTargetKind.conversion_from))) continue;
            instruction.result_ty = .unknown;
            break;
        } else continue;
        break;
    } else return error.TestUnexpectedResult;

    try mir.validateCallTargetFactsForLowering(typed_mir);
    try std.testing.expectError(error.UnknownMirLoweringType, mir.validateKnownFactTypesForLowering(typed_mir));
    try std.testing.expectError(error.UnknownMirLoweringType, mir.validateLoweringAdmission(typed_mir));
}

test "MIR assign instructions carry known lowering types" {
    const source =
        \\fn assign_value() -> u32 {
        \\    var x: u32 = 1;
        \\    x = 2;
        \\    return x;
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_assign_known_type.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    try mir.validateLoweringAdmission(typed_mir);

    const function = functionByName(typed_mir, "assign_value").?;
    for (function.blocks) |block| {
        for (block.instructions) |instruction| {
            if (instruction.kind != .assign) continue;
            try std.testing.expectEqualStrings("x", instruction.detail);
            try std.testing.expectEqualStrings("u32", valueTypeName(instruction.result_ty));
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "MIR lowering admission rejects unknown assign instruction types" {
    const source =
        \\fn assign_value() -> u32 {
        \\    var x: u32 = 1;
        \\    x = 2;
        \\    return x;
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_unknown_assign_type.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByNameMut(&typed_mir, "assign_value").?;
    for (function.blocks) |*block| {
        for (block.instructions) |*instruction| {
            if (instruction.kind != .assign) continue;
            instruction.result_ty = .unknown;
            try std.testing.expectError(error.UnknownMirLoweringType, mir.validateKnownFactTypesForLowering(typed_mir));
            try std.testing.expectError(error.UnknownMirLoweringType, mir.validateLoweringAdmission(typed_mir));
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "MIR lowering admission rejects unknown runtime instruction types" {
    const source =
        \\fn add_value(x: u32) -> u32 {
        \\    return x + 1;
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_unknown_runtime_instruction_type.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByNameMut(&typed_mir, "add_value").?;
    for (function.blocks) |*block| {
        for (block.instructions) |*instruction| {
            if (instruction.kind != .binary) continue;
            instruction.result_ty = .unknown;
            try std.testing.expectError(error.UnknownMirLoweringType, mir.validateKnownFactTypesForLowering(typed_mir));
            try std.testing.expectError(error.UnknownMirLoweringType, mir.validateLoweringAdmission(typed_mir));
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "MIR lowering admission rejects unknown contextual call instruction types" {
    const source =
        \\enum E { bad }
        \\fn make_ok(value: u32) -> Result<u32, E> {
        \\    return ok(value);
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_unknown_contextual_call_type.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByNameMut(&typed_mir, "make_ok").?;
    for (function.blocks) |*block| {
        for (block.instructions) |*instruction| {
            if (instruction.kind != .call or !std.mem.eql(u8, instruction.detail, "ok")) continue;
            instruction.result_ty = .unknown;
            try mir.validateCallTargetFactsForLowering(typed_mir);
            try mir.validateTargetTypeFactsForLowering(typed_mir);
            try std.testing.expectError(error.UnknownMirLoweringType, mir.validateKnownFactTypesForLowering(typed_mir));
            try std.testing.expectError(error.UnknownMirLoweringType, mir.validateLoweringAdmission(typed_mir));
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "MIR lowering admission rejects unknown qualified union constructor call instruction types" {
    const source =
        \\union Token { number: i64, eof }
        \\fn make(value: i64) -> Token {
        \\    return Token.number(value);
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_unknown_qualified_union_call_type.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByNameMut(&typed_mir, "make").?;
    for (function.blocks) |*block| {
        for (block.instructions) |*instruction| {
            if (instruction.kind != .call or !std.mem.eql(u8, instruction.detail, "number")) continue;
            instruction.result_ty = .unknown;
            try mir.validateTargetTypeFactsForLowering(typed_mir);
            try std.testing.expectError(error.UnknownMirLoweringType, mir.validateKnownFactTypesForLowering(typed_mir));
            try std.testing.expectError(error.UnknownMirLoweringType, mir.validateLoweringAdmission(typed_mir));
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "MIR owns inferred local types for conversion results" {
    const source =
        \\fn inferred_conversion(value: u64) -> u8 {
        \\    let narrowed = u8.trap_from(value);
        \\    return narrowed;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_inferred_conversion_local_type.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "inferred_conversion").?;
    const result_fact = targetTypeFactByKind(function, .conversion_target) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("u8", result_fact.target_ty.kind.name.text);
    const local_fact = targetTypeFactByKind(function, .inferred_local) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("narrowed", local_fact.target_owner.?);
    try std.testing.expectEqualStrings("u8", local_fact.target_ty.kind.name.text);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns inferred local types for reflection results" {
    const source =
        \\fn inferred_reflection() -> usize {
        \\    let size = size_of<u32>();
        \\    return size;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_inferred_reflection_local_type.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "inferred_reflection").?;
    const result_fact = targetTypeFactByKind(function, .reflection_result) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("usize", result_fact.target_ty.kind.name.text);
    const local_fact = targetTypeFactByKind(function, .inferred_local) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("size", local_fact.target_owner.?);
    try std.testing.expectEqualStrings("usize", local_fact.target_ty.kind.name.text);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns target types for contextual constructors and literals" {
    const source =
        \\enum E { bad }
        \\struct Slot { cb: closure(u32) -> u32, result: Result<u32, E> }
        \\struct TextSlot { ptr: *const u8, bytes: []const u8 }
        \\struct FloatSlot { small: f32, wide: f64 }
        \\packed bits Flags: u8 { ready: bool }
        \\#[c_union]
        \\struct CWord { word: u32, byte: u8 }
        \\union Token { number: i64, eof, ok: u32 }
        \\union Event { mode: E }
        \\global default_error: E = .bad;
        \\global default_text: *const u8 = "global";
        \\global default_float: f32 = 1.25;
        \\global default_char: u8 = 'a';
        \\fn add(env: *mut u32, value: u32) -> u32 { return env.* + value; }
        \\fn consume(value: Result<u32, E>) -> u32 { return 0; }
        \\fn make_bind(env: *mut u32) -> closure(u32) -> u32 { return bind(env, add); }
        \\fn make_ok(value: u32) -> Result<u32, E> { return ok(value); }
        \\fn make_err() -> Result<u32, E> { return err(.bad); }
        \\fn pass_ok(value: u32) -> u32 { return consume(ok(value)); }
        \\fn make_slot(env: *mut u32, value: u32) -> Slot { return .{ .cb = bind(env, add), .result = ok(value) }; }
        \\fn number(value: i64) -> Token { return Token.number(value); }
        \\fn make_number(value: i64) -> Token { return number(value); }
        \\fn make_eof() -> Token { return eof(); }
        \\fn make_union_ok(value: u32) -> Token { return ok(value); }
        \\fn make_enum() -> E { return .bad; }
        \\fn compare_enum(value: E) -> bool { return .bad == value; }
        \\fn cast_enum() -> E { return .bad as E; }
        \\fn make_event() -> Event { return mode(.bad); }
        \\fn make_text() -> *const u8 { return "text"; }
        \\fn make_text_result() -> Result<*const u8, E> { return ok("ok"); }
        \\fn make_text_slot() -> TextSlot { return .{ .ptr = "ptr", .bytes = "bytes" }; }
        \\fn make_array() -> [2]u32 { return .{ 1, 2 }; }
        \\fn make_flags() -> Flags { return .{ .ready = true }; }
        \\fn make_c_word() -> CWord { return .{ .word = 7, .byte = uninit }; }
        \\fn make_float() -> f32 { return 1.5; }
        \\fn make_float_expr() -> f32 { return 1.7 * 2.3; }
        \\fn make_float_slot() -> FloatSlot { return .{ .small = 1.0, .wide = 2.0 }; }
        \\fn make_char() -> u16 { return 'A'; }
        \\fn maybe_value(value: u32) -> ?u32 { return value; }
        \\fn no_value() -> ?u32 { return null; }
        \\fn maybe_text_slot() -> ?TextSlot { return .{ .ptr = "ptr", .bytes = "bytes" }; }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_target_types.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    try mir.validateCallTargetFactsForLowering(typed_mir);
    try mir.validateTargetTypeFactsForLowering(typed_mir);

    const bind_fn = functionByName(typed_mir, "make_bind").?;
    try std.testing.expectEqual(@as(usize, 1), bind_fn.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.bind, bind_fn.call_target_facts[0].kind);
    const bind_fact = targetTypeFactByKind(bind_fn, .bind) orelse return error.TestUnexpectedResult;
    try std.testing.expect(bind_fact.target_ty.kind == .closure_type);
    try std.testing.expect(callInstructionByDetail(bind_fn, "bind").?.result_ty != .unknown);

    const ok_fn = functionByName(typed_mir, "make_ok").?;
    try std.testing.expectEqual(@as(usize, 1), ok_fn.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.result_ok, ok_fn.call_target_facts[0].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.result_ok, ok_fn.target_type_facts[0].kind);
    try std.testing.expect(ok_fn.target_type_facts[0].target_ty.kind == .generic);
    try std.testing.expectEqualStrings("Result", ok_fn.target_type_facts[0].target_ty.kind.generic.base.text);
    try std.testing.expectEqualStrings("Result", valueTypeName(callInstructionByDetail(ok_fn, "ok").?.result_ty));

    const err_fn = functionByName(typed_mir, "make_err").?;
    try std.testing.expectEqual(@as(usize, 1), err_fn.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.result_err, err_fn.call_target_facts[0].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.result_err, err_fn.target_type_facts[0].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.enum_literal, err_fn.target_type_facts[1].kind);
    try std.testing.expectEqualStrings("Result", valueTypeName(callInstructionByDetail(err_fn, "err").?.result_ty));
    const arg_fn = functionByName(typed_mir, "pass_ok").?;
    try std.testing.expect(targetTypeFactByKind(arg_fn, .result_ok) != null);
    const slot_fn = functionByName(typed_mir, "make_slot").?;
    try std.testing.expect(targetTypeFactByKind(slot_fn, .struct_literal) != null);
    try std.testing.expect(targetTypeFactByKind(slot_fn, .bind) != null);
    try std.testing.expect(targetTypeFactByKind(slot_fn, .result_ok) != null);
    const number_fn = functionByName(typed_mir, "make_number").?;
    try std.testing.expectEqual(@as(usize, 0), countTargetTypeFactsByKind(number_fn, .tagged_union));
    try std.testing.expectEqual(@as(usize, 1), countTargetTypeFactsByKind(number_fn, .direct_call_result));
    try std.testing.expectEqual(@as(usize, 1), countTargetTypeFactsByKind(number_fn, .direct_call_argument));
    try std.testing.expectEqual(mir.TargetTypeKind.tagged_union, functionByName(typed_mir, "make_eof").?.target_type_facts[0].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.tagged_union, functionByName(typed_mir, "make_union_ok").?.target_type_facts[0].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.enum_literal, functionByName(typed_mir, "make_enum").?.target_type_facts[0].kind);
    try std.testing.expect(targetTypeFactByKind(functionByName(typed_mir, "compare_enum").?, .enum_literal) != null);
    const cast_enum_fn = functionByName(typed_mir, "cast_enum").?;
    try std.testing.expect(targetTypeFactByKind(cast_enum_fn, .explicit_cast_source) != null);
    try std.testing.expect(targetTypeFactByKind(cast_enum_fn, .explicit_cast_target) != null);
    try std.testing.expect(targetTypeFactByKind(cast_enum_fn, .enum_literal) != null);
    try std.testing.expect(targetTypeFactByKind(cast_enum_fn, .expression_result) != null);
    try std.testing.expectEqual(mir.TargetTypeKind.enum_literal, functionByName(typed_mir, "default_error").?.target_type_facts[0].kind);
    const event_fn = functionByName(typed_mir, "make_event").?;
    try std.testing.expectEqual(mir.TargetTypeKind.tagged_union, event_fn.target_type_facts[0].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.enum_literal, event_fn.target_type_facts[1].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.string_literal, functionByName(typed_mir, "default_text").?.target_type_facts[0].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.string_literal, functionByName(typed_mir, "make_text").?.target_type_facts[0].kind);
    const text_result_fn = functionByName(typed_mir, "make_text_result").?;
    try std.testing.expectEqual(mir.TargetTypeKind.result_ok, text_result_fn.target_type_facts[0].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.string_literal, text_result_fn.target_type_facts[1].kind);
    const text_slot_fn = functionByName(typed_mir, "make_text_slot").?;
    try std.testing.expectEqual(mir.TargetTypeKind.struct_literal, text_slot_fn.target_type_facts[0].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.string_literal, text_slot_fn.target_type_facts[1].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.string_literal, text_slot_fn.target_type_facts[2].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.array_literal, functionByName(typed_mir, "make_array").?.target_type_facts[0].kind);
    const flags_fact = functionByName(typed_mir, "make_flags").?.target_type_facts[0];
    try std.testing.expectEqual(mir.TargetTypeKind.struct_literal, flags_fact.kind);
    try std.testing.expectEqual(mir.AggregateConstructionKind.packed_bits, flags_fact.aggregate_construction.?);
    const slot_fact = targetTypeFactByKind(slot_fn, .struct_literal) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(mir.AggregateConstructionKind.declared_struct, slot_fact.aggregate_construction.?);
    const c_word_fact = functionByName(typed_mir, "make_c_word").?.target_type_facts[0];
    try std.testing.expectEqual(mir.AggregateConstructionKind.c_union, c_word_fact.aggregate_construction.?);
    var construction_dump: std.ArrayList(u8) = .empty;
    defer construction_dump.deinit(std.testing.allocator);
    try mir.appendDumpFromDecls(std.testing.allocator, module.decls, &construction_dump);
    try std.testing.expect(std.mem.indexOf(u8, construction_dump.items, "fn=make_slot kind=struct_literal target_type=Slot result_type=Slot aggregate_construction=declared_struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, construction_dump.items, "fn=make_flags kind=struct_literal target_type=Flags result_type=Flags aggregate_construction=packed_bits") != null);
    try std.testing.expect(std.mem.indexOf(u8, construction_dump.items, "fn=make_c_word kind=struct_literal target_type=CWord result_type=CWord aggregate_construction=c_union") != null);
    try std.testing.expectEqual(mir.TargetTypeKind.float_literal, functionByName(typed_mir, "default_float").?.target_type_facts[0].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.char_literal, functionByName(typed_mir, "default_char").?.target_type_facts[0].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.float_literal, functionByName(typed_mir, "make_float").?.target_type_facts[0].kind);
    const float_expr_fn = functionByName(typed_mir, "make_float_expr").?;
    try std.testing.expectEqual(@as(usize, 2), countTargetTypeFactsByKind(float_expr_fn, .float_literal));
    try std.testing.expect(targetTypeFactByKind(float_expr_fn, .expression_result) != null);
    const float_slot_fn = functionByName(typed_mir, "make_float_slot").?;
    try std.testing.expectEqual(mir.TargetTypeKind.struct_literal, float_slot_fn.target_type_facts[0].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.float_literal, float_slot_fn.target_type_facts[1].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.float_literal, float_slot_fn.target_type_facts[2].kind);
    const char_fn = functionByName(typed_mir, "make_char").?;
    try std.testing.expectEqual(@as(usize, 1), char_fn.target_type_facts.len);
    try std.testing.expectEqual(mir.TargetTypeKind.char_literal, char_fn.target_type_facts[0].kind);
    try std.testing.expectEqualStrings("u16", char_fn.target_type_facts[0].target_ty.kind.name.text);
    try std.testing.expectEqual(mir.TargetTypeKind.value_optional_coercion, functionByName(typed_mir, "maybe_value").?.target_type_facts[0].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.null_literal, functionByName(typed_mir, "no_value").?.target_type_facts[0].kind);
    const maybe_text_fn = functionByName(typed_mir, "maybe_text_slot").?;
    try std.testing.expectEqual(mir.TargetTypeKind.value_optional_coercion, maybe_text_fn.target_type_facts[0].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.struct_literal, maybe_text_fn.target_type_facts[1].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.string_literal, maybe_text_fn.target_type_facts[2].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.string_literal, maybe_text_fn.target_type_facts[3].kind);

    try duplicateTargetTypeFact(functionByNameMut(&typed_mir, "make_ok").?, std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, mir.validateTargetTypeFactsForLowering(typed_mir));
}

test "MIR target-type admission rejects stale complete syntax" {
    const source =
        \\fn read(pointer: *const u32) -> u32 {
        \\    return pointer.*;
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_stale_target_type.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    const function = functionByNameMut(&typed_mir, "read") orelse return error.TestUnexpectedResult;
    for (function.target_type_facts) |*fact| {
        if (fact.kind != .expression_result) continue;
        fact.target_ty = .{ .span = fact.target_ty.span, .kind = .{ .name = .{ .text = "u64", .span = fact.target_ty.span } } };
        break;
    } else return error.TestUnexpectedResult;

    try std.testing.expectError(error.StaleMirTargetTypeFacts, mir.validateTargetTypeFactsForLowering(typed_mir));
}

test "MIR target-type admission accepts computed array lengths" {
    const source =
        \\fn read() -> u32 {
        \\    let xs: [1 + 2]u32 = .{10, 20, 30};
        \\    return xs[2];
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_computed_array_length.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    const function = functionByName(typed_mir, "read") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), countTargetTypeFactsByKind(function, .array_literal));
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns implicit view const narrowing source and target types" {
    const source =
        \\fn consume(xs: []const u8) -> usize { return xs.len; }
        \\fn slice_return(xs: []mut u8) -> []const u8 { return xs; }
        \\fn slice_local(xs: []mut u8) -> []const u8 { let view: []const u8 = xs; return view; }
        \\fn slice_argument(xs: []mut u8) -> usize { return consume(xs); }
        \\fn pointer_return(ptr: *mut u8) -> *const u8 { return ptr; }
        \\fn slice_passthrough(xs: []const u8) -> []const u8 { return xs; }
        \\fn raw_many_passthrough(ptr: [*]mut u8) -> [*]mut u8 { return ptr; }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_view_const_narrow_types.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    try mir.validateTargetTypeFactsForLowering(typed_mir);

    for ([_][]const u8{ "slice_return", "slice_local", "slice_argument", "pointer_return" }) |name| {
        const function = functionByName(typed_mir, name).?;
        try std.testing.expectEqual(@as(usize, 1), countTargetTypeFactsByKind(function, .view_const_narrow_source));
        try std.testing.expectEqual(@as(usize, 1), countTargetTypeFactsByKind(function, .view_const_narrow_target));
    }

    try std.testing.expectEqual(@as(usize, 0), countTargetTypeFactsByKind(functionByName(typed_mir, "slice_passthrough").?, .view_const_narrow_source));
    try std.testing.expectEqual(@as(usize, 0), countTargetTypeFactsByKind(functionByName(typed_mir, "slice_passthrough").?, .view_const_narrow_target));
    try std.testing.expectEqual(@as(usize, 0), countTargetTypeFactsByKind(functionByName(typed_mir, "raw_many_passthrough").?, .view_const_narrow_source));
    try std.testing.expectEqual(@as(usize, 0), countTargetTypeFactsByKind(functionByName(typed_mir, "raw_many_passthrough").?, .view_const_narrow_target));
}

test "MIR owns mapped try error target types" {
    const source =
        \\enum LowErr { Failed }
        \\enum HighErr { Mapped }
        \\fn low() -> Result<u32, LowErr> { return err(.Failed); }
        \\fn high() -> Result<u32, HighErr> { let value: u32 = low()? else .Mapped; return ok(value); }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_mapped_try_target_types.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    try mir.validateTargetTypeFactsForLowering(typed_mir);

    const function = functionByName(typed_mir, "high").?;
    var found_mapped = false;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .enum_literal) continue;
        try std.testing.expectEqualStrings("HighErr", fact.target_ty.kind.name.text);
        found_mapped = true;
    }
    try std.testing.expect(found_mapped);
}

test "MIR owns qualified union and enum variant path result types" {
    const source =
        \\enum E { first, second }
        \\union Token { number: i64, eof }
        \\struct Holder { first: u32 }
        \\fn make(value: i64) -> Token { return Token.number(value); }
        \\fn variant() -> E { return E.second; }
        \\fn shadow(E: Holder) -> u32 { return E.first; }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_self_typed_expression_facts.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    try mir.validateTargetTypeFactsForLowering(typed_mir);

    const make = functionByName(typed_mir, "make").?;
    var qualified_fact: ?mir.TargetTypeFact = null;
    var qualified_count: usize = 0;
    for (make.target_type_facts) |fact| if (fact.kind == .qualified_union_result) {
        try std.testing.expectEqualStrings("Token", fact.target_ty.kind.name.text);
        qualified_fact = fact;
        qualified_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), qualified_count);
    try std.testing.expect(callInstructionByDetail(make, "number").?.result_ty != .unknown);

    const variant = functionByName(typed_mir, "variant").?;
    var variant_fact: ?mir.TargetTypeFact = null;
    var variant_count: usize = 0;
    for (variant.target_type_facts) |fact| if (fact.kind == .enum_variant_path_result) {
        try std.testing.expectEqualStrings("E", fact.target_ty.kind.name.text);
        variant_fact = fact;
        variant_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), variant_count);

    const shadow = functionByName(typed_mir, "shadow").?;
    for (shadow.target_type_facts) |fact| {
        try std.testing.expect(fact.kind != .enum_variant_path_result);
    }
    const facts = mir_facts_view.MirFactsView.init();
    try std.testing.expect(facts.targetTypeFactAtCurrentSpan(.{
        .current = &shadow,
        .fact = .{
            .kind = .qualified_union_result,
            .source = qualified_fact.?.source,
        },
    }) == null);
    try std.testing.expect(facts.targetTypeFactAtCurrentSpan(.{
        .current = &shadow,
        .fact = .{
            .kind = .enum_variant_path_result,
            .source = variant_fact.?.source,
        },
    }) == null);
}

test "MIR owns dyn coercion targets and excludes pass-through values" {
    const source =
        \\trait Shape { fn area(self: *Self) -> u32; }
        \\struct Square { side: u32 }
        \\impl Shape for Square { fn area(self: *Square) -> u32 { return self.side; } }
        \\struct Holder { inner: *dyn Shape }
        \\fn as_dyn(p: *Square) -> *dyn Shape { return p; }
        \\fn hold(p: *Square) -> Holder { return .{ .inner = p }; }
        \\fn consume(value: *dyn Shape) -> u32 { return value.area(); }
        \\fn pass_arg(p: *Square) -> u32 { return consume(p); }
        \\fn pass_through(value: *dyn Shape) -> *dyn Shape { return value; }
        \\fn pass_nullable(value: ?*dyn Shape) -> ?*dyn Shape { return value; }
        \\fn no_dyn() -> ?*dyn Shape { return null; }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_dyn_target_types.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const as_dyn = functionByName(typed_mir, "as_dyn").?;
    try std.testing.expectEqual(mir.TargetTypeKind.dyn_coercion, as_dyn.target_type_facts[0].kind);
    try std.testing.expect(targetTypeFactByKind(as_dyn, .dyn_coercion_source) != null);
    const holder = functionByName(typed_mir, "hold").?;
    try std.testing.expectEqual(mir.TargetTypeKind.struct_literal, holder.target_type_facts[0].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.dyn_coercion, holder.target_type_facts[1].kind);
    try std.testing.expect(targetTypeFactByKind(holder, .dyn_coercion_source) != null);
    const pass_arg = functionByName(typed_mir, "pass_arg").?;
    try std.testing.expect(targetTypeFactByKind(pass_arg, .dyn_coercion) != null);
    try std.testing.expect(targetTypeFactByKind(pass_arg, .dyn_coercion_source) != null);
    try std.testing.expectEqual(@as(usize, 0), countTargetTypeFactsByKind(functionByName(typed_mir, "pass_through").?, .dyn_coercion));
    try std.testing.expectEqual(@as(usize, 0), countTargetTypeFactsByKind(functionByName(typed_mir, "pass_nullable").?, .dyn_coercion));
    try std.testing.expectEqual(mir.TargetTypeKind.null_literal, functionByName(typed_mir, "no_dyn").?.target_type_facts[0].kind);
}

fn valueTypeName(ty: mir.ValueType) []const u8 {
    return switch (ty) {
        .void => "void",
        .never => "never",
        .bool => "bool",
        .value => "value",
        .integer => |name| name,
        .float => |name| name,
        .slice => |name| name,
        .array => |name| name,
        .closed_enum => |name| name,
        .open_enum => |name| name,
        .struct_ => |name| name,
        .result => "Result",
        .contract => "contract",
        .branch => "branch",
        .trap => "language_trap",
        .unknown => "unknown",
        else => "aggregate",
    };
}

test "MIR resolves type aliases for checked ints and arithmetic domains" {
    const source =
        \\type Count = u32;
        \\type HashWord = wrap<u32>;
        \\type Level = sat<u8>;
        \\
        \\fn checked_alias_add(a: Count, b: Count) -> Count {
        \\    return a + b;
        \\}
        \\
        \\fn wrap_alias_add(a: HashWord, b: HashWord) -> HashWord {
        \\    return a + b;
        \\}
        \\
        \\fn sat_alias_add(a: Level, b: Level) -> Level {
        \\    return a + b;
        \\}
        \\
        \\fn wrap_cast_add(a: u32, b: u32) -> HashWord {
        \\    return (a as HashWord) + (b as HashWord);
        \\}
        \\
        \\fn sat_cast_add(a: u8, b: u8) -> Level {
        \\    return (a as Level) + (b as Level);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_alias_domains.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    const checked_fn = functionByName(typed_mir, "checked_alias_add").?;
    const wrap_fn = functionByName(typed_mir, "wrap_alias_add").?;
    const sat_fn = functionByName(typed_mir, "sat_alias_add").?;
    const wrap_cast_fn = functionByName(typed_mir, "wrap_cast_add").?;
    const sat_cast_fn = functionByName(typed_mir, "sat_cast_add").?;

    try std.testing.expect(functionHasInstruction(checked_fn, .add_overflow, "add"));
    try std.testing.expect(!functionHasInstruction(wrap_fn, .add_overflow, "add"));
    try std.testing.expect(!functionHasInstruction(sat_fn, .add_overflow, "add"));
    try std.testing.expect(!functionHasInstruction(wrap_cast_fn, .add_overflow, "add"));
    try std.testing.expect(!functionHasInstruction(sat_cast_fn, .add_overflow, "add"));
    try std.testing.expectEqual(@as(usize, 0), wrap_fn.trap_edges.len);
    try std.testing.expectEqual(@as(usize, 0), sat_fn.trap_edges.len);
    try std.testing.expectEqual(@as(usize, 0), wrap_cast_fn.trap_edges.len);
    try std.testing.expectEqual(@as(usize, 0), sat_cast_fn.trap_edges.len);
}

test "OPT const-index bounds-check elision drops only provably-dead Bounds trap edges" {
    const source =
        \\fn const_index(a: [4]u32) -> u32 {
        \\    return a[2];
        \\}
        \\fn var_index(a: [4]u32, i: usize) -> u32 {
        \\    return a[i];
        \\}
        \\fn const_div(x: u32) -> u32 {
        \\    return x / 7;
        \\}
        \\fn var_div(x: u32, y: u32) -> u32 {
        \\    return x / y;
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_opt_bounds.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    // Default mir.build keeps each check and its trap edge (Bounds for the indices, DivideByZero
    // for the divisions).
    var base = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer base.deinit();
    try std.testing.expectEqual(@as(usize, 1), functionByName(base, "const_index").?.trap_edges.len);
    try std.testing.expectEqual(@as(usize, 1), functionByName(base, "var_index").?.trap_edges.len);
    try std.testing.expectEqual(@as(usize, 1), functionByName(base, "const_div").?.trap_edges.len);
    try std.testing.expectEqual(@as(usize, 1), functionByName(base, "var_div").?.trap_edges.len);

    // Optimized mir.build elides the provably-dead checks — the in-range constant index (2 < 4)
    // and the unsigned division by a non-zero literal (/ 7) — but keeps the variable index's
    // and variable divisor's checks; the proofs are conservative.
    var opt = try mir.buildOptFromDecls(std.testing.allocator, module.decls, .{ .optimize = true });
    defer opt.deinit();
    try std.testing.expectEqual(@as(usize, 0), functionByName(opt, "const_index").?.trap_edges.len);
    try std.testing.expectEqual(@as(usize, 1), functionByName(opt, "var_index").?.trap_edges.len);
    try std.testing.expectEqual(@as(usize, 0), functionByName(opt, "const_div").?.trap_edges.len);
    try std.testing.expectEqual(@as(usize, 1), functionByName(opt, "var_div").?.trap_edges.len);
}

test "MIR verifier reports arithmetic-domain misuse" {
    const source =
        \\type HashWord = wrap<u32>;
        \\type Level = sat<u8>;
        \\type Seq = serial<u32>;
        \\type Ticks = counter<u64>;
        \\
        \\fn reject_wrap_checked_mix(a: HashWord, b: u32) -> HashWord {
        \\    return a + b;
        \\}
        \\
        \\fn reject_sat_bitwise(a: Level, b: Level) -> Level {
        \\    return a & b;
        \\}
        \\
        \\fn reject_wrap_div(a: HashWord, b: HashWord) -> HashWord {
        \\    return a / b;
        \\}
        \\
        \\fn reject_serial_checked_mix(a: Seq, b: u32) -> Seq {
        \\    return a + b;
        \\}
        \\
        \\fn reject_counter_bitwise(a: Ticks, b: Ticks) -> Ticks {
        \\    return a & b;
        \\}
        \\
        \\fn reject_cast_wrap_checked_mix(a: u32, b: u32) -> HashWord {
        \\    return (a as HashWord) + b;
        \\}
        \\
        \\fn reject_cast_sat_bitwise(a: u8, b: u8) -> Level {
        \\    return (a as Level) & (b as Level);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_arith_domains.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    try mir.verifyFromDecls(std.testing.allocator, module.decls, &reporter);

    var found_mix = false;
    var found_division = false;
    var found_bitwise: usize = 0;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_ARITH_POLICY_MIX") != null) found_mix = true;
        if (std.mem.indexOf(u8, diag.message, "E_ARITH_DOMAIN_DIVISION") != null) found_division = true;
        if (std.mem.indexOf(u8, diag.message, "E_BITWISE_ARITH_DOMAIN_OPERAND") != null) found_bitwise += 1;
    }
    try std.testing.expect(found_mix);
    try std.testing.expect(found_division);
    try std.testing.expect(found_bitwise >= 2);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFactsFromDecls(std.testing.allocator, module.decls, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_wrap_checked_mix pass=core finding=arith_policy_mix") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_sat_bitwise pass=core finding=bitwise_arith_domain_operand") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_wrap_div pass=core finding=arith_domain_division") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_serial_checked_mix pass=core finding=arith_policy_mix") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_counter_bitwise pass=core finding=bitwise_arith_domain_operand") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_cast_wrap_checked_mix pass=core finding=arith_policy_mix") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_cast_sat_bitwise pass=core finding=bitwise_arith_domain_operand") != null);
}

test "MIR verifier reports invalid operator operands" {
    const source =
        \\fn reject_unsigned_negation(x: u32) -> u32 {
        \\    return -x;
        \\}
        \\
        \\fn reject_integer_not(n: u32) -> bool {
        \\    return !n;
        \\}
        \\
        \\fn reject_integer_logical_and(flag: bool, n: u32) -> bool {
        \\    return flag && n;
        \\}
        \\
        \\fn reject_signed_bitwise(a: i32, b: i32) -> i32 {
        \\    return a & b;
        \\}
        \\
        \\fn reject_bool_bitwise(a: bool, b: bool) -> bool {
        \\    return a & b;
        \\}
        \\
        \\fn reject_pointer_bitwise(a: *mut u8, b: *mut u8) -> *mut u8 {
        \\    return a & b;
        \\}
        \\
        \\fn reject_null_bitwise() -> void {
        \\    let value = null & null;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_operator_operands.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    try mir.verifyFromDecls(std.testing.allocator, module.decls, &reporter);

    var found_unsigned_negation = false;
    var found_bool_operator: usize = 0;
    var found_signed_bitwise = false;
    var found_bool_bitwise = false;
    var found_pointer_bitwise = false;
    var found_operator_operand = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_UNSIGNED_NEGATION") != null) found_unsigned_negation = true;
        if (std.mem.indexOf(u8, diag.message, "E_BOOL_OPERATOR_OPERAND") != null) found_bool_operator += 1;
        if (std.mem.indexOf(u8, diag.message, "E_BITWISE_SIGNED_OPERAND") != null) found_signed_bitwise = true;
        if (std.mem.indexOf(u8, diag.message, "E_BITWISE_BOOL_OPERAND") != null) found_bool_bitwise = true;
        if (std.mem.indexOf(u8, diag.message, "E_BITWISE_POINTER_OPERAND") != null) found_pointer_bitwise = true;
        if (std.mem.indexOf(u8, diag.message, "E_OPERATOR_OPERAND") != null) found_operator_operand = true;
    }
    try std.testing.expect(found_unsigned_negation);
    try std.testing.expect(found_bool_operator >= 2);
    try std.testing.expect(found_signed_bitwise);
    try std.testing.expect(found_bool_bitwise);
    try std.testing.expect(found_pointer_bitwise);
    try std.testing.expect(found_operator_operand);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFactsFromDecls(std.testing.allocator, module.decls, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_unsigned_negation pass=core finding=unsigned_negation") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_integer_not pass=core finding=bool_operator_operand") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_integer_logical_and pass=core finding=bool_operator_operand") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_signed_bitwise pass=core finding=bitwise_signed_operand") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_bool_bitwise pass=core finding=bitwise_bool_operand") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_pointer_bitwise pass=core finding=bitwise_pointer_operand") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_null_bitwise pass=core finding=operator_operand") != null);
}

test "MIR verifier reports binary numeric compatibility errors" {
    const source =
        \\fn reject_signed_unsigned_arithmetic(a: i32, b: u32) -> i32 {
        \\    return a + b;
        \\}
        \\
        \\fn reject_unsigned_signed_comparison(a: u32, b: i32) -> bool {
        \\    return a < b;
        \\}
        \\
        \\fn reject_integer_width_arithmetic(a: u16, b: u32) -> u16 {
        \\    return a + b;
        \\}
        \\
        \\fn reject_signed_width_comparison(a: i16, b: i32) -> bool {
        \\    return a == b;
        \\}
        \\
        \\fn reject_f32_f64_mix(a: f32, b: f64) -> f64 {
        \\    return a + b;
        \\}
        \\
        \\fn reject_float_int_mix(a: f32, b: u32) -> f32 {
        \\    return a + b;
        \\}
        \\
        \\fn reject_float_remainder(a: f64, b: f64) -> f64 {
        \\    return a % b;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_numeric_compat.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    try mir.verifyFromDecls(std.testing.allocator, module.decls, &reporter);

    var signed_unsigned_count: usize = 0;
    var promotion_count: usize = 0;
    var no_implicit_count: usize = 0;
    var operator_operand_found = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_SIGNED_UNSIGNED_MIX") != null) signed_unsigned_count += 1;
        if (std.mem.indexOf(u8, diag.message, "E_NO_IMPLICIT_INTEGER_PROMOTION") != null) promotion_count += 1;
        if (std.mem.indexOf(u8, diag.message, "E_NO_IMPLICIT_CONVERSION") != null) no_implicit_count += 1;
        if (std.mem.indexOf(u8, diag.message, "E_OPERATOR_OPERAND") != null) operator_operand_found = true;
    }
    try std.testing.expect(signed_unsigned_count >= 2);
    try std.testing.expect(promotion_count >= 2);
    try std.testing.expect(no_implicit_count >= 2);
    try std.testing.expect(operator_operand_found);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFactsFromDecls(std.testing.allocator, module.decls, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_signed_unsigned_arithmetic pass=core finding=signed_unsigned_mix") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_unsigned_signed_comparison pass=core finding=signed_unsigned_mix") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_integer_width_arithmetic pass=core finding=integer_promotion") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_signed_width_comparison pass=core finding=integer_promotion") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_f32_f64_mix pass=core finding=float_binary_conversion") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_float_int_mix pass=core finding=float_binary_conversion") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_float_remainder pass=core finding=operator_operand") != null);
}

test "builds typed MIR CFG with explicit trap edge" {
    const source =
        \\#[no_lang_trap]
        \\fn checked_add(a: u32, b: u32) -> u32 {
        \\    return a + b;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_cfg.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    try std.testing.expectEqual(@as(usize, 1), typed_mir.functions.len);
    try std.testing.expect(typed_mir.functions[0].blocks.len >= 2);
    try std.testing.expectEqual(@as(usize, 1), typed_mir.functions[0].trap_edges.len);
    try std.testing.expectEqual(TrapKind.IntegerOverflow, typed_mir.functions[0].trap_edges[0].kind);
}

test "MIR owns every explicit trap reason identity" {
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
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_explicit_trap_targets.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const cases = [_]struct { name: []const u8, kind: mir.CallTargetKind }{
        .{ .name = "trap_bounds", .kind = .trap_bounds },
        .{ .name = "trap_null_unwrap", .kind = .trap_null_unwrap },
        .{ .name = "trap_integer_overflow", .kind = .trap_integer_overflow },
        .{ .name = "trap_divide_by_zero", .kind = .trap_divide_by_zero },
        .{ .name = "trap_invalid_shift", .kind = .trap_invalid_shift },
        .{ .name = "trap_invalid_representation", .kind = .trap_invalid_representation },
        .{ .name = "trap_assert", .kind = .trap_assert },
        .{ .name = "trap_unreachable", .kind = .trap_unreachable },
    };
    for (cases) |case| {
        const function = functionByName(typed_mir, case.name).?;
        try std.testing.expectEqual(@as(usize, 1), function.call_target_facts.len);
        try std.testing.expectEqual(case.kind, function.call_target_facts[0].kind);
        try std.testing.expectEqualStrings("never", function.call_target_facts[0].result_ty.name());
        try std.testing.expectEqual(@as(usize, 1), function.trap_edges.len);
        try std.testing.expectEqual(mir.TrapSource.explicit_trap, function.trap_edges[0].source);
    }
    try mir.validateCallTargetFactsForLowering(typed_mir);
}

test "MIR owns runtime assert condition types" {
    const source =
        \\fn require_flag(flag: bool) -> void {
        \\    assert(flag);
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_assert_condition_type.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "require_flag").?;
    const fact = targetTypeFactByKind(function, .assert_condition) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(mir.TargetTypeKind.assert_condition, fact.kind);
    try std.testing.expectEqualStrings("bool", fact.target_ty.kind.name.text);
    try std.testing.expectEqualStrings("bool", fact.result_ty.name());
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns while-loop condition types" {
    const source =
        \\fn wait_for_flag(flag: bool) -> void {
        \\    while flag { return; }
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_loop_condition_type.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "wait_for_flag").?;
    const fact = targetTypeFactByKind(function, .loop_condition) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("bool", fact.target_ty.kind.name.text);
    try std.testing.expectEqualStrings("bool", fact.result_ty.name());
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns switch subject types" {
    const source =
        \\enum Choice { left, right }
        \\union Token { number: u32, eof }
        \\fn result_subject(value: Result<u32, u32>) -> u32 { switch value { ok(v) => { return v; }, err(e) => { return e; }, } }
        \\fn nullable_subject(value: ?*const u8) -> u32 { switch value { p => { return 1; }, _ => { return 0; }, } }
        \\fn union_subject(value: Token) -> u32 { switch value { number(v) => { return v; }, .eof => { return 0; }, } }
        \\fn enum_subject(value: Choice) -> u32 { switch value { .left => { return 1; }, .right => { return 0; }, } }
        \\fn bool_subject(value: bool) -> u32 { switch (value) { true => { return 1; }, false => { return 0; }, } }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_switch_subject_types.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const result_fact = targetTypeFactByKind(functionByName(typed_mir, "result_subject").?, .switch_subject) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Result", result_fact.target_ty.kind.generic.base.text);
    const nullable_fact = targetTypeFactByKind(functionByName(typed_mir, "nullable_subject").?, .switch_subject) orelse return error.TestUnexpectedResult;
    try std.testing.expect(nullable_fact.target_ty.kind == .nullable);
    const union_fact = targetTypeFactByKind(functionByName(typed_mir, "union_subject").?, .switch_subject) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Token", union_fact.target_ty.kind.name.text);
    const enum_fact = targetTypeFactByKind(functionByName(typed_mir, "enum_subject").?, .switch_subject) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Choice", enum_fact.target_ty.kind.name.text);
    const bool_fact = targetTypeFactByKind(functionByName(typed_mir, "bool_subject").?, .switch_subject) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("bool", bool_fact.target_ty.kind.name.text);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns if-let subject types" {
    const source =
        \\fn result_subject(value: Result<u32, u32>) -> u32 { if let ok(v) = value { return v; } else { return 0; } }
        \\fn nullable_subject(value: ?*const u8) -> u32 { if let p = value { return 1; } else { return 0; } }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_if_let_subject_types.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const result_fact = targetTypeFactByKind(functionByName(typed_mir, "result_subject").?, .if_let_subject) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Result", result_fact.target_ty.kind.generic.base.text);
    const nullable_fact = targetTypeFactByKind(functionByName(typed_mir, "nullable_subject").?, .if_let_subject) orelse return error.TestUnexpectedResult;
    try std.testing.expect(nullable_fact.target_ty.kind == .nullable);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR target-type admission rejects forged if-let subject family" {
    const source =
        \\fn result_subject(value: Result<u32, u32>) -> u32 { if let ok(v) = value { return v; } else { return 0; } }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_bad_if_let_subject_family.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByNameMut(&typed_mir, "result_subject") orelse return error.TestUnexpectedResult;
    try retargetFirstTargetTypeFactAndInstruction(function, .if_let_subject, "u32", .{ .integer = "u32" });
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, mir.validateTargetTypeFactsForLowering(typed_mir));
}

test "MIR owns try operand and result types" {
    const source =
        \\extern fn make_result() -> Result<u32, u32>;
        \\extern fn make_nullable() -> ?*const u8;
        \\fn result_try() -> u32 { return make_result()?; }
        \\fn nullable_try() -> *const u8 { return make_nullable()?; }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_try_operand_types.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const result_fact = targetTypeFactByKind(functionByName(typed_mir, "result_try").?, .try_operand) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Result", result_fact.target_ty.kind.generic.base.text);
    const result_payload_fact = targetTypeFactByKind(functionByName(typed_mir, "result_try").?, .expression_result) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("u32", result_payload_fact.target_ty.kind.name.text);
    const nullable_fact = targetTypeFactByKind(functionByName(typed_mir, "nullable_try").?, .try_operand) orelse return error.TestUnexpectedResult;
    try std.testing.expect(nullable_fact.target_ty.kind == .nullable);
    const nullable_payload_fact = targetTypeFactByKind(functionByName(typed_mir, "nullable_try").?, .expression_result) orelse return error.TestUnexpectedResult;
    try std.testing.expect(nullable_payload_fact.target_ty.kind == .pointer);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR target-type admission rejects forged try operand family" {
    const source =
        \\extern fn make_result() -> Result<u32, u32>;
        \\fn result_try() -> u32 { return make_result()?; }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_bad_try_operand_family.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByNameMut(&typed_mir, "result_try") orelse return error.TestUnexpectedResult;
    try retargetFirstTargetTypeFactAndInstruction(function, .try_operand, "u32", .{ .integer = "u32" });
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, mir.validateTargetTypeFactsForLowering(typed_mir));
}

test "MIR owns for-loop iterable and element types" {
    const source =
        \\extern fn make_slice() -> []const u32;
        \\fn array_loop(values: [2]u32) -> u32 { for value in values { return value; } return 0; }
        \\fn slice_loop(values: []const u32) -> u32 { for value in values { return value; } return 0; }
        \\fn call_loop() -> u32 { for value in make_slice() { return value; } return 0; }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_for_loop_types.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const array_iterable = targetTypeFactByKind(functionByName(typed_mir, "array_loop").?, .for_iterable) orelse return error.TestUnexpectedResult;
    const array_element = targetTypeFactByKind(functionByName(typed_mir, "array_loop").?, .for_element) orelse return error.TestUnexpectedResult;
    try std.testing.expect(array_iterable.target_ty.kind == .array);
    try std.testing.expectEqualStrings("u32", array_element.target_ty.kind.name.text);
    const slice_iterable = targetTypeFactByKind(functionByName(typed_mir, "slice_loop").?, .for_iterable) orelse return error.TestUnexpectedResult;
    const slice_element = targetTypeFactByKind(functionByName(typed_mir, "slice_loop").?, .for_element) orelse return error.TestUnexpectedResult;
    try std.testing.expect(slice_iterable.target_ty.kind == .slice);
    try std.testing.expectEqualStrings("u32", slice_element.target_ty.kind.name.text);
    _ = targetTypeFactByKind(functionByName(typed_mir, "call_loop").?, .for_iterable) orelse return error.TestUnexpectedResult;
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns inferred local copy types" {
    const source =
        \\fn copies(value: u64, ptr: *u8, values: [2]u32) -> u64 {
        \\    let copied_value = value;
        \\    let copied_ptr = ptr;
        \\    let copied_values = values;
        \\    return copied_value;
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_inferred_local_copy_types.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "copies").?;
    try std.testing.expectEqual(@as(usize, 3), countTargetTypeFactsByKind(function, .inferred_local));
    for (function.target_type_facts) |fact| {
        if (fact.kind != .inferred_local) continue;
        try std.testing.expect(fact.target_owner != null);
        try std.testing.expect(fact.target_index == null);
    }
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns inferred local direct storage read types" {
    const source =
        \\struct Packet { head: u32, values: [2]u32 }
        \\fn storage_reads(packet: Packet, ptr: *mut u32) -> u32 {
        \\    unsafe {
        \\        let field = packet.head;
        \\        let item = packet.values[0];
        \\        let window = packet.values[0..1];
        \\        let loaded = ptr.*;
        \\        return field + item + window[0] + loaded;
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_inferred_local_storage_read_types.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "storage_reads").?;
    try std.testing.expectEqual(@as(usize, 4), countTargetTypeFactsByKind(function, .inferred_local));
    var saw_field = false;
    var saw_item = false;
    var saw_window = false;
    var saw_loaded = false;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .inferred_local) continue;
        if (std.mem.eql(u8, fact.target_owner.?, "field")) {
            try std.testing.expectEqualStrings("u32", fact.target_ty.kind.name.text);
            saw_field = true;
        }
        if (std.mem.eql(u8, fact.target_owner.?, "item")) {
            try std.testing.expectEqualStrings("u32", fact.target_ty.kind.name.text);
            saw_item = true;
        }
        if (std.mem.eql(u8, fact.target_owner.?, "window")) {
            try std.testing.expect(fact.target_ty.kind == .slice);
            saw_window = true;
        }
        if (std.mem.eql(u8, fact.target_owner.?, "loaded")) {
            try std.testing.expectEqualStrings("u32", fact.target_ty.kind.name.text);
            saw_loaded = true;
        }
    }
    try std.testing.expect(saw_field);
    try std.testing.expect(saw_item);
    try std.testing.expect(saw_window);
    try std.testing.expect(saw_loaded);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns inferred local try payload types" {
    const source =
        \\extern fn make_result() -> Result<u32, u32>;
        \\extern fn make_nullable() -> ?*const u8;
        \\fn result_local() -> Result<u32, u32> { let value = make_result()?; return ok(value); }
        \\fn nullable_local() -> *const u8 { let value = make_nullable()?; return value; }
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_inferred_local_try_payload_types.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const result_fact = targetTypeFactByKind(functionByName(typed_mir, "result_local").?, .inferred_local) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("u32", result_fact.target_ty.kind.name.text);
    const nullable_fact = targetTypeFactByKind(functionByName(typed_mir, "nullable_local").?, .inferred_local) orelse return error.TestUnexpectedResult;
    try std.testing.expect(nullable_fact.target_ty.kind == .pointer);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns inferred local direct address types" {
    const source =
        \\global shared_value: u32 = 4;
        \\const readonly_value: u32 = 6;
        \\struct Holder { value: u32 }
        \\fn address_global() -> u32 {
        \\    let pointer = &shared_value;
        \\    pointer.* = 9;
        \\    return pointer.*;
        \\}
        \\fn address_const_global() -> u32 {
        \\    let pointer = &readonly_value;
        \\    return pointer.*;
        \\}
        \\fn address_local() -> u32 {
        \\    var value: u32 = 4;
        \\    let pointer = &value;
        \\    pointer.* = 9;
        \\    return pointer.*;
        \\}
        \\fn address_const_local() -> u32 {
        \\    let value: u32 = 4;
        \\    let pointer = &value;
        \\    return pointer.*;
        \\}
        \\fn address_field() -> u32 {
        \\    var holder: Holder = .{ .value = 4 };
        \\    let pointer = &holder.value;
        \\    pointer.* = 9;
        \\    return pointer.*;
        \\}
        \\fn address_const_field() -> u32 {
        \\    let holder: Holder = .{ .value = 4 };
        \\    let pointer = &holder.value;
        \\    return pointer.*;
        \\}
        \\fn address_element() -> u32 {
        \\    var values: [2]u32 = .{ 4, 5 };
        \\    let pointer = &values[0];
        \\    pointer.* = 9;
        \\    return pointer.*;
        \\}
        \\fn address_const_element() -> u32 {
        \\    let values: [2]u32 = .{ 4, 5 };
        \\    let pointer = &values[0];
        \\    return pointer.*;
        \\}
        \\fn address_pointee() -> u32 {
        \\    var value: u32 = 4;
        \\    let source: *mut u32 = &value;
        \\    let pointer = &source.*;
        \\    pointer.* = 9;
        \\    return pointer.*;
        \\}
        \\fn address_const_pointee() -> u32 {
        \\    let value: u32 = 4;
        \\    let source: *const u32 = &value;
        \\    let pointer = &source.*;
        \\    return pointer.*;
        \\}
        \\fn address_raw_many_pointee() -> u32 {
        \\    var value: u32 = 4;
        \\    let source: [*]mut u32 = (&value) as [*]mut u32;
        \\    unsafe {
        \\        let pointer = &source.*;
        \\        pointer.* = 9;
        \\        return pointer.*;
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_inferred_local_address_types.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const global_fact = targetTypeFactByKind(functionByName(typed_mir, "address_global").?, .inferred_local) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(ast.Mutability.mut, global_fact.target_ty.kind.pointer.mutability);
    try std.testing.expectEqualStrings("u32", global_fact.target_ty.kind.pointer.child.kind.name.text);
    const const_global_fact = targetTypeFactByKind(functionByName(typed_mir, "address_const_global").?, .inferred_local) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(ast.Mutability.@"const", const_global_fact.target_ty.kind.pointer.mutability);
    try std.testing.expectEqualStrings("u32", const_global_fact.target_ty.kind.pointer.child.kind.name.text);
    const fact = targetTypeFactByKind(functionByName(typed_mir, "address_local").?, .inferred_local) orelse return error.TestUnexpectedResult;
    const pointer = fact.target_ty.kind.pointer;
    try std.testing.expectEqual(ast.Mutability.mut, pointer.mutability);
    try std.testing.expectEqualStrings("u32", pointer.child.kind.name.text);
    const const_fact = targetTypeFactByKind(functionByName(typed_mir, "address_const_local").?, .inferred_local) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(ast.Mutability.@"const", const_fact.target_ty.kind.pointer.mutability);
    const field_fact = targetTypeFactByKind(functionByName(typed_mir, "address_field").?, .inferred_local) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(ast.Mutability.mut, field_fact.target_ty.kind.pointer.mutability);
    try std.testing.expectEqualStrings("u32", field_fact.target_ty.kind.pointer.child.kind.name.text);
    const const_field_fact = targetTypeFactByKind(functionByName(typed_mir, "address_const_field").?, .inferred_local) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(ast.Mutability.@"const", const_field_fact.target_ty.kind.pointer.mutability);
    const element_fact = targetTypeFactByKind(functionByName(typed_mir, "address_element").?, .inferred_local) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(ast.Mutability.mut, element_fact.target_ty.kind.pointer.mutability);
    try std.testing.expectEqualStrings("u32", element_fact.target_ty.kind.pointer.child.kind.name.text);
    const const_element_fact = targetTypeFactByKind(functionByName(typed_mir, "address_const_element").?, .inferred_local) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(ast.Mutability.@"const", const_element_fact.target_ty.kind.pointer.mutability);
    const pointee_fact = targetTypeFactByKind(functionByName(typed_mir, "address_pointee").?, .inferred_local) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(ast.Mutability.mut, pointee_fact.target_ty.kind.pointer.mutability);
    try std.testing.expectEqualStrings("u32", pointee_fact.target_ty.kind.pointer.child.kind.name.text);
    const const_pointee_fact = targetTypeFactByKind(functionByName(typed_mir, "address_const_pointee").?, .inferred_local) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(ast.Mutability.@"const", const_pointee_fact.target_ty.kind.pointer.mutability);
    const raw_many_pointee_fact = targetTypeFactByKind(functionByName(typed_mir, "address_raw_many_pointee").?, .inferred_local) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(ast.Mutability.mut, raw_many_pointee_fact.target_ty.kind.pointer.mutability);
    try std.testing.expectEqualStrings("u32", raw_many_pointee_fact.target_ty.kind.pointer.child.kind.name.text);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns inferred local cast types" {
    const source =
        \\fn casts(value: u64, ptr: *const u64) -> u32 {
        \\    let narrowed = value as u32;
        \\    let view = ptr as *const u64;
        \\    return narrowed;
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_inferred_local_cast_types.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "casts").?;
    try std.testing.expectEqual(@as(usize, 2), countTargetTypeFactsByKind(function, .inferred_local));
    var saw_narrowed = false;
    var saw_view = false;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .inferred_local) continue;
        if (std.mem.eql(u8, fact.target_owner.?, "narrowed")) {
            try std.testing.expectEqualStrings("u32", fact.target_ty.kind.name.text);
            saw_narrowed = true;
        }
        if (std.mem.eql(u8, fact.target_owner.?, "view")) {
            try std.testing.expect(fact.target_ty.kind == .pointer);
            saw_view = true;
        }
    }
    try std.testing.expect(saw_narrowed);
    try std.testing.expect(saw_view);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns inferred local binary types" {
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
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_inferred_local_binary_types.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "binary").?;
    try std.testing.expectEqual(@as(usize, 3), countTargetTypeFactsByKind(function, .inferred_local));
    var saw_sum = false;
    var saw_is_less = false;
    var saw_both = false;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .inferred_local) continue;
        if (std.mem.eql(u8, fact.target_owner.?, "sum")) {
            try std.testing.expectEqualStrings("u64", fact.target_ty.kind.name.text);
            saw_sum = true;
        }
        if (std.mem.eql(u8, fact.target_owner.?, "is_less")) {
            try std.testing.expectEqualStrings("bool", fact.target_ty.kind.name.text);
            saw_is_less = true;
        }
        if (std.mem.eql(u8, fact.target_owner.?, "both")) {
            try std.testing.expectEqualStrings("bool", fact.target_ty.kind.name.text);
            saw_both = true;
        }
    }
    try std.testing.expect(saw_sum);
    try std.testing.expect(saw_is_less);
    try std.testing.expect(saw_both);
    const bitwise_function = functionByName(typed_mir, "bitwise").?;
    try std.testing.expectEqual(@as(usize, 2), countTargetTypeFactsByKind(bitwise_function, .inferred_local));
    for (bitwise_function.target_type_facts) |fact| {
        if (fact.kind != .inferred_local) continue;
        try std.testing.expectEqualStrings("u32", fact.target_ty.kind.name.text);
    }
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns inferred local literal types" {
    const source =
        \\fn literals() -> u32 {
        \\    let count = 7;
        \\    let enabled = true;
        \\    if enabled { return count; }
        \\    return 0;
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_inferred_local_literal_types.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "literals").?;
    try std.testing.expectEqual(@as(usize, 2), countTargetTypeFactsByKind(function, .inferred_local));
    try std.testing.expectEqual(@as(usize, 5), countTargetTypeFactsByKind(function, .expression_result));
    var saw_count = false;
    var saw_enabled = false;
    var saw_literal_results: usize = 0;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .inferred_local) continue;
        if (std.mem.eql(u8, fact.target_owner.?, "count")) {
            try std.testing.expectEqualStrings("u32", fact.target_ty.kind.name.text);
            saw_count = true;
        }
        if (std.mem.eql(u8, fact.target_owner.?, "enabled")) {
            try std.testing.expectEqualStrings("bool", fact.target_ty.kind.name.text);
            saw_enabled = true;
        }
    }
    for (function.target_type_facts) |fact| {
        if (fact.kind != .expression_result) continue;
        if (std.mem.eql(u8, fact.target_ty.kind.name.text, "u32") or std.mem.eql(u8, fact.target_ty.kind.name.text, "bool")) saw_literal_results += 1;
    }
    try std.testing.expect(saw_count);
    try std.testing.expect(saw_enabled);
    try std.testing.expectEqual(@as(usize, 5), saw_literal_results);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns direct identifier expression result types" {
    const source =
        \\global enabled: bool = true;
        \\fn direct_identifier(value: u32) -> u32 {
        \\    if enabled { return value; }
        \\    return value;
        \\}
    ;
    const value_text = "value";
    const value_offset = std.mem.indexOf(u8, source, "return value;") orelse return error.TestUnexpectedResult;
    const ident_offset = value_offset + "return ".len;
    const enabled_use = std.mem.indexOf(u8, source, "if enabled") orelse return error.TestUnexpectedResult;
    const enabled_offset = enabled_use + "if ".len;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_direct_identifier_expression_result.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "direct_identifier").?;
    var saw_value = false;
    var saw_enabled = false;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .expression_result) continue;
        if (fact.source.offset == ident_offset and fact.source.len == value_text.len) {
            try std.testing.expectEqualStrings("u32", fact.target_ty.kind.name.text);
            saw_value = true;
        }
        if (fact.source.offset == enabled_offset and fact.source.len == "enabled".len) {
            try std.testing.expectEqualStrings("bool", fact.target_ty.kind.name.text);
            saw_enabled = true;
        }
    }
    try std.testing.expect(saw_value);
    try std.testing.expect(saw_enabled);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns direct call expression result types" {
    const source =
        \\fn make() -> u16 { return 9; }
        \\fn use_call() -> u16 {
        \\    return make();
        \\}
    ;
    const call_text = "make()";
    const call_offset = std.mem.indexOfPos(u8, source, std.mem.indexOf(u8, source, "return make();") orelse return error.TestUnexpectedResult, call_text) orelse return error.TestUnexpectedResult;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_direct_call_expression_result.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "use_call").?;
    var saw_call = false;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .expression_result or fact.source.offset != call_offset or fact.source.len != call_text.len) continue;
        try std.testing.expectEqualStrings("u16", fact.target_ty.kind.name.text);
        saw_call = true;
    }
    try std.testing.expect(saw_call);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns inferred local unary types" {
    const source =
        \\fn unary(value: i64, enabled: bool) -> i64 {
        \\    let negated = -value;
        \\    let disabled = !enabled;
        \\    if disabled { return negated; }
        \\    return value;
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_inferred_local_unary_types.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "unary").?;
    try std.testing.expectEqual(@as(usize, 2), countTargetTypeFactsByKind(function, .inferred_local));
    var saw_negated = false;
    var saw_disabled = false;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .inferred_local) continue;
        if (std.mem.eql(u8, fact.target_owner.?, "negated")) {
            try std.testing.expectEqualStrings("i64", fact.target_ty.kind.name.text);
            saw_negated = true;
        }
        if (std.mem.eql(u8, fact.target_owner.?, "disabled")) {
            try std.testing.expectEqualStrings("bool", fact.target_ty.kind.name.text);
            saw_disabled = true;
        }
    }
    try std.testing.expect(saw_negated);
    try std.testing.expect(saw_disabled);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns contextual negative integer unary result types" {
    const source =
        \\fn compares(value: i32) -> bool {
        \\    return value == -6;
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_contextual_negative_unary.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "compares").?;
    var saw_negative_i32 = false;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .expression_result) continue;
        const end = fact.source.offset + fact.source.len;
        if (!std.mem.eql(u8, source[fact.source.offset..end], "-6")) continue;
        try std.testing.expectEqualStrings("i32", fact.target_ty.kind.name.text);
        saw_negative_i32 = true;
    }
    try std.testing.expect(saw_negative_i32);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR continues building facts after inline asm" {
    const source =
        \\fn asm_then_cast(mask: u64) -> u8 {
        \\    var result: u64 = 0;
        \\    #[unsafe_contract(precise_asm)] {
        \\        unsafe {
        \\            asm precise volatile {
        \\                "mov %1, %0"
        \\                out("rax") result: u64,
        \\                in("rbx") mask: u64,
        \\                clobber("cc")
        \\            }
        \\        }
        \\    }
        \\    return (result & 0xFF) as u8;
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_asm_continuation.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "asm_then_cast").?;
    try std.testing.expect(functionHasInstruction(function, .asm_effect, "opaque"));
    try std.testing.expect(targetTypeFactByKind(function, .explicit_cast_source) != null);
    try std.testing.expect(functionHasTerminator(function, .return_));
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns inferred local direct call types" {
    const source =
        \\fn make_count() -> u64 { return 7; }
        \\fn caller() -> u64 {
        \\    let count = make_count();
        \\    return count;
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_inferred_local_call_types.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "caller").?;
    const fact = targetTypeFactByKind(function, .inferred_local) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("count", fact.target_owner.?);
    try std.testing.expectEqualStrings("u64", fact.target_ty.kind.name.text);
    var local_value_id: ?ValueId = null;
    var found_typed_local_use = false;
    for (function.blocks) |block| {
        for (block.instructions) |instruction| {
            if (!std.mem.eql(u8, instruction.detail, "count")) continue;
            if (instruction.kind == .local) {
                local_value_id = instruction.typed_value_id orelse return error.TestUnexpectedResult;
                try std.testing.expect(local_value_id.?.isValid());
                try std.testing.expectEqualStrings("count", function.value_identities[local_value_id.?.index()].spelling);
            } else if (instruction.kind == .expr) {
                const use_value_id = instruction.typed_value_id orelse return error.TestUnexpectedResult;
                if (local_value_id) |expected| try std.testing.expect(use_value_id.eql(expected));
                found_typed_local_use = true;
            }
        }
    }
    try std.testing.expect(local_value_id != null);
    try std.testing.expect(found_typed_local_use);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns inferred local indirect call types" {
    const source =
        \\fn invoke_pointer(callback: fn(u32) -> u32, value: u32) -> u32 {
        \\    let result = callback(value);
        \\    return result;
        \\}
        \\fn invoke_closure(callback: closure(u32) -> u32, value: u32) -> u32 {
        \\    let result = callback(value);
        \\    return result;
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_inferred_local_indirect_call_types.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    for ([_][]const u8{ "invoke_pointer", "invoke_closure" }) |name| {
        const function = functionByName(typed_mir, name).?;
        const fact = targetTypeFactByKind(function, .inferred_local) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("result", fact.target_owner.?);
        try std.testing.expectEqualStrings("u32", fact.target_ty.kind.name.text);
        try std.testing.expectEqual(@as(usize, 1), countTargetTypeFactsByKind(function, .indirect_call_callee));
    }
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns inferred local dyn dispatch call types" {
    const source =
        \\trait Shape { fn scale(self: *Self, amount: u32) -> u32; fn set(self: *mut Self, value: u32) -> void; }
        \\struct Square { side: u32 }
        \\impl Shape for Square { fn scale(self: *Square, amount: u32) -> u32 { return self.side * amount; } fn set(self: *mut Square, value: u32) -> void { self.side = value; } }
        \\fn caller(shape: *dyn Shape, amount: u32) -> u32 {
        \\    let result = shape.scale(amount);
        \\    return result;
        \\}
        \\fn notify(shape: *mut dyn Shape, value: u32) -> void { shape.set(value); }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_inferred_local_dyn_dispatch_call_types.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "caller").?;
    const local_fact = targetTypeFactByKind(function, .inferred_local) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("result", local_fact.target_owner.?);
    try std.testing.expectEqualStrings("u32", local_fact.target_ty.kind.name.text);
    const dispatch_fact = targetTypeFactByKind(function, .dyn_dispatch_result) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Shape", dispatch_fact.target_owner.?);
    try std.testing.expectEqual(@as(?usize, 0), dispatch_fact.target_index);
    try std.testing.expectEqualStrings("u32", dispatch_fact.target_ty.kind.name.text);
    const argument_fact = targetTypeFactByKind(function, .dyn_dispatch_argument) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Shape", argument_fact.target_owner.?);
    try std.testing.expectEqual(@as(?usize, mir.dynDispatchArgumentFactIndex(0, 0)), argument_fact.target_index);
    try std.testing.expectEqualStrings("u32", argument_fact.target_ty.kind.name.text);
    const notify = functionByName(typed_mir, "notify").?;
    try std.testing.expectEqual(@as(usize, 0), countTargetTypeFactsByKind(notify, .dyn_dispatch_result));
    const void_argument_fact = targetTypeFactByKind(notify, .dyn_dispatch_argument) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(?usize, mir.dynDispatchArgumentFactIndex(1, 0)), void_argument_fact.target_index);
    const notify_ptr = functionByNamePtr(&typed_mir, "notify").?;
    const facts = mir_facts_view.MirFactsView.init();
    try std.testing.expect(facts.targetTypeFactAtOwnedCurrentSpan(.{
        .current = notify_ptr,
        .fact = .{
            .kind = .dyn_dispatch_result,
            .source = dispatch_fact.source,
            .owner = dispatch_fact.target_owner,
            .index = dispatch_fact.target_index,
        },
    }) == null);
    try std.testing.expect(facts.targetTypeFactAtOwnedCurrentSpan(.{
        .current = notify_ptr,
        .fact = .{
            .kind = .dyn_dispatch_argument,
            .source = argument_fact.source,
            .owner = argument_fact.target_owner,
            .index = argument_fact.target_index,
        },
    }) == null);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns ordinary direct call result and argument types" {
    const source =
        \\trait Width { fn widen(self: *Self) -> u32; }
        \\struct Narrow { value: u32 }
        \\impl Width for Narrow { fn widen(self: *Narrow) -> u32 { return self.value; } }
        \\extern fn log(level: u32, ...) -> void;
        \\fn widen(value: u64) -> u64 { return value; }
        \\fn caller(value: u64) -> u64 {
        \\    log(1, value);
        \\    return widen(value);
        \\}
        \\fn method_caller(value: *Narrow) -> u32 { return value.widen(); }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_direct_call_types.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const caller = functionByName(typed_mir, "caller").?;
    var result_count: usize = 0;
    var argument_count: usize = 0;
    for (caller.target_type_facts) |fact| switch (fact.kind) {
        .direct_call_result => {
            result_count += 1;
            try std.testing.expect(fact.target_owner != null);
            try std.testing.expect(fact.target_index == null);
            try std.testing.expect(std.mem.eql(u8, fact.target_owner.?, "log") or std.mem.eql(u8, fact.target_owner.?, "widen"));
            try std.testing.expect(std.mem.eql(u8, fact.target_ty.kind.name.text, "void") or std.mem.eql(u8, fact.target_ty.kind.name.text, "u64"));
        },
        .direct_call_argument => {
            argument_count += 1;
            try std.testing.expect(fact.target_owner != null);
            try std.testing.expect(std.mem.eql(u8, fact.target_owner.?, "log") or std.mem.eql(u8, fact.target_owner.?, "widen"));
            if (std.mem.eql(u8, fact.target_owner.?, "log")) {
                try std.testing.expect(fact.target_index == @as(?usize, 0) or fact.target_index == @as(?usize, 1));
            } else {
                try std.testing.expectEqual(@as(?usize, 0), fact.target_index);
            }
            try std.testing.expect(std.mem.eql(u8, fact.target_ty.kind.name.text, "u32") or std.mem.eql(u8, fact.target_ty.kind.name.text, "u64"));
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), result_count);
    try std.testing.expectEqual(@as(usize, 3), argument_count);
    const method_caller = functionByName(typed_mir, "method_caller").?;
    try std.testing.expectEqual(@as(usize, 0), countTargetTypeFactsByKind(method_caller, .direct_call_result));
    try std.testing.expectEqual(@as(usize, 0), countTargetTypeFactsByKind(method_caller, .direct_call_argument));
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns indirect function-pointer and closure callee signatures" {
    const source =
        \\fn increment(value: u32) -> u32 { return value + 1; }
        \\fn invoke_pointer(callback: fn(u32) -> u32, value: u32) -> u32 { return callback(value); }
        \\fn invoke_closure(callback: closure(u32) -> u32, value: u32) -> u32 { return callback(value); }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_indirect_call_signature_facts.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const increment = functionByName(typed_mir, "increment").?;
    const facts = mir_facts_view.MirFactsView.init();
    for ([_][]const u8{ "invoke_pointer", "invoke_closure" }) |name| {
        const function = functionByName(typed_mir, name).?;
        const fact = targetTypeFactByKind(function, .indirect_call_callee) orelse return error.TestUnexpectedResult;
        const resolved = switch (fact.target_ty.kind) {
            .fn_pointer, .closure_type => true,
            else => false,
        };
        try std.testing.expect(resolved);
        try std.testing.expectEqual(@as(usize, 1), countTargetTypeFactsByKind(function, .indirect_call_callee));
        try std.testing.expect(facts.targetTypeFactAtCurrentSpan(.{
            .current = &increment,
            .fact = .{
                .kind = .indirect_call_callee,
                .source = fact.source,
            },
        }) == null);
    }
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR plans nullable pointer local promotions with typed identities" {
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
    var parsed = try test_support.parseCheckedModule("mir_nullable_pointer_promotions.mc", source);
    defer parsed.deinit();
    var typed_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer typed_mir.deinit();

    const local_plan = mir_statement_plan.buildNullablePointerLocalReturn(functionByName(typed_mir, "local_promotion").?) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("maybe", local_plan.local_name);
    try std.testing.expectEqualStrings("p", local_plan.source_name);
    try std.testing.expect(local_plan.local_id.isValid());
    try std.testing.expect(local_plan.source_id.isValid());
    try std.testing.expect(!local_plan.initializesWithNull());

    const assigned_plan = mir_statement_plan.buildNullablePointerLocalReturn(functionByName(typed_mir, "assigned_promotion").?) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("maybe", assigned_plan.local_name);
    try std.testing.expectEqualStrings("p", assigned_plan.source_name);
    try std.testing.expect(assigned_plan.initializesWithNull());
    try std.testing.expect(assigned_plan.assignment_location != null);

    const call_plan = mir_statement_plan.buildNullablePointerVoidCall(functionByName(typed_mir, "call_promotion").?) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("consume_nullable", call_plan.callee_name);
    try std.testing.expectEqualStrings("p", call_plan.argument_name);
    try std.testing.expect(call_plan.callee_id.isValid());
    try std.testing.expect(call_plan.argument_id.isValid());
}

test "MIR plans typed indirect call arguments and canonical callee roots" {
    const source =
        \\fn add(left: u32, right: u32) -> u32 { return left + right; }
        \\fn mul(left: u32, right: u32) -> u32 { return left * right; }
        \\global default_op: fn(u32, u32) -> u32 = add;
        \\global default_ops: [2]fn(u32, u32) -> u32 = .{ add, mul };
        \\struct BinOp { combine: fn(u32, u32) -> u32 }
        \\global default_box: BinOp = .{ .combine = add };
        \\global default_boxes: [2]BinOp = .{ .{ .combine = add }, .{ .combine = mul } };
        \\fn apply(op: fn(u32, u32) -> u32, x: u32, y: u32) -> u32 { return op(x, y); }
        \\fn global_op_call(x: u32, y: u32) -> u32 { return default_op(x, y); }
        \\fn global_op_array_call(x: u32, y: u32) -> u32 { return default_ops[1](x, y); }
        \\fn global_box_call(x: u32, y: u32) -> u32 { return default_box.combine(x, y); }
        \\fn global_box_array_call(x: u32, y: u32) -> u32 { return default_boxes[1].combine(x, y); }
        \\fn local_fn_pointer_call(x: u32, y: u32) -> u32 {
        \\    let op: fn(u32, u32) -> u32 = mul;
        \\    return op(x, y);
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("mir_indirect_call_plan.mc", source);
    defer parsed.deinit();
    var typed_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer typed_mir.deinit();
    for ([_][]const u8{ "apply", "global_op_call", "global_op_array_call", "global_box_call", "global_box_array_call", "local_fn_pointer_call" }) |name| {
        const function = functionByName(typed_mir, name).?;
        try std.testing.expectEqual(@as(usize, 2), countTargetTypeFactsByKind(function, .indirect_call_argument));
        const plan = mir_statement_plan.buildSingleBlockIndirectCallReturn(function) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 2), plan.argument_count);
        try std.testing.expectEqual(@as(usize, 0), plan.arguments[0].index);
        try std.testing.expectEqual(@as(usize, 1), plan.arguments[1].index);
        try std.testing.expectEqualStrings("x", plan.arguments[0].name);
        try std.testing.expectEqualStrings("y", plan.arguments[1].name);
        if (std.mem.eql(u8, name, "local_fn_pointer_call")) switch (plan.callee) {
            .local_function => |local| {
                try std.testing.expectEqualStrings("op", local.local_name);
                try std.testing.expectEqualStrings("mul", local.function_name);
                try std.testing.expect(local.local_id.isValid());
                try std.testing.expect(local.function_id.isValid());
            },
            else => return error.TestUnexpectedResult,
        } else if (std.mem.eql(u8, name, "global_op_array_call")) switch (plan.callee) {
            .projected_place => |place| {
                try std.testing.expectEqualStrings("default_ops", place.root_name);
                try std.testing.expectEqual(@as(usize, 1), place.projection_count);
                try std.testing.expectEqual(@as(usize, 1), place.projections[0].constant_index.index);
            },
            else => return error.TestUnexpectedResult,
        } else if (std.mem.eql(u8, name, "global_box_array_call")) switch (plan.callee) {
            .projected_place => |place| {
                try std.testing.expectEqualStrings("default_boxes", place.root_name);
                try std.testing.expectEqual(@as(usize, 2), place.projection_count);
                try std.testing.expectEqual(@as(usize, 1), place.projections[0].constant_index.index);
                try std.testing.expectEqualStrings("combine", place.projections[1].field.field_name);
            },
            else => return error.TestUnexpectedResult,
        };
    }
    try mir.validateTargetTypeFactsForLowering(typed_mir);

    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(std.testing.allocator);
    try mir.appendDumpFromMir(std.testing.allocator, typed_mir, &dump);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir indirect_callee_place fn=apply block=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir indirect_callee_place fn=global_box_call block=0") != null);

    const apply_mut = functionByNameMut(&typed_mir, "apply").?;
    for (apply_mut.target_type_facts) |*fact| {
        if (fact.kind != .indirect_call_argument or fact.target_index != 0) continue;
        fact.typed_operand_value_id = ValueId.fromIndex(4096);
        break;
    } else return error.TestUnexpectedResult;
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, mir.validateTargetTypeFactsForLowering(typed_mir));
}

test "MIR plans a checked pointer-root field store" {
    const source =
        \\struct Env { value: u32 }
        \\fn store_value(env: *mut Env, value: u32) -> void {
        \\    env.value = value;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("mir_pointer_root_store.mc", source);
    defer parsed.deinit();
    var typed_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer typed_mir.deinit();

    const function = functionByName(typed_mir, "store_value") orelse return error.TestUnexpectedResult;
    const plan = mir_statement_plan.buildSingleBlockPlaceStore(function) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(mir_statement_plan.PlaceRootKind.parameter, plan.target.root_kind);
    try std.testing.expect(plan.target.root_indirect);
    try std.testing.expectEqualStrings("env", plan.target.root_name);
    try std.testing.expectEqual(@as(usize, 1), plan.target.projection_count);
    switch (plan.value) {
        .parameter => |parameter| try std.testing.expectEqualStrings("value", parameter.name),
        else => return error.TestUnexpectedResult,
    }
}

test "MIR plans a checked pointer-to-integer cast" {
    const source =
        \\fn pointer_to_usize(p: *mut u32) -> usize {
        \\    return p as usize;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("mir_pointer_to_integer.mc", source);
    defer parsed.deinit();
    var typed_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer typed_mir.deinit();

    const function = functionByName(typed_mir, "pointer_to_usize") orelse return error.TestUnexpectedResult;
    const plan = mir_statement_plan.buildPointerToIntegerCast(function) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("p", plan.source_name);
    try std.testing.expect(plan.source_id.isValid());
    try std.testing.expectEqual(.pointer, std.meta.activeTag(plan.source_fact.result_ty));
    try std.testing.expectEqual(.integer, std.meta.activeTag(plan.target_fact.result_ty));
}

test "MIR plans a checked scalar local generation and return" {
    const source =
        \\fn local_copy(n: u32) -> u32 {
        \\    let x: u32 = n + 1;
        \\    return x;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("mir_scalar_local_checked_binary_return.mc", source);
    defer parsed.deinit();
    var typed_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer typed_mir.deinit();

    const function = functionByName(typed_mir, "local_copy") orelse return error.TestUnexpectedResult;
    const plan = mir_statement_plan.buildScalarLocalCheckedBinaryReturn(function) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("x", plan.local_name);
    try std.testing.expect(plan.local_id.isValid());
    try std.testing.expectEqualStrings("add", plan.operation);
    switch (plan.left) {
        .parameter => |parameter| try std.testing.expectEqualStrings("n", parameter.name),
        else => return error.TestUnexpectedResult,
    }
    switch (plan.right) {
        .integer_literal => |literal| try std.testing.expectEqual(@as(usize, 1), literal.value),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 2), plan.declaration_location.source.line);
    try std.testing.expectEqual(@as(usize, 3), plan.return_location.source.line);
}

test "MIR plans pure logical returns from typed operand identities" {
    // DIAGNOSTIC_UNIT: E_MIR_IDENTITY
    const source =
        \\fn bool_and(a: bool, b: bool) -> bool { return a && b; }
        \\fn bool_or(a: bool, b: bool) -> bool { return a || b; }
        \\fn nested_bool(a: bool, b: bool, c: bool) -> bool { return !a || (b && c); }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_logical_return_plan.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    for ([_][]const u8{ "bool_and", "bool_or" }) |name| {
        const function = functionByName(typed_mir, name).?;
        const plan = mir_statement_plan.buildSingleBlockLogicalReturn(function) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 3), plan.count);
        switch (plan.nodes[plan.root].operation) {
            .logical_and, .logical_or => {},
            else => return error.TestUnexpectedResult,
        }
    }
    const nested = mir_statement_plan.buildSingleBlockLogicalReturn(functionByName(typed_mir, "nested_bool").?) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 6), nested.count);
    switch (nested.nodes[nested.root].operation) {
        .logical_or => {},
        else => return error.TestUnexpectedResult,
    }

    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(std.testing.allocator);
    try mir.appendDumpFromMir(std.testing.allocator, typed_mir, &dump);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir operand_identity fn=nested_bool") != null);

    const bool_and = functionByNameMut(&typed_mir, "bool_and").?;
    for (bool_and.blocks[0].instructions) |*instruction| {
        if (instruction.kind != .binary or !std.mem.eql(u8, instruction.detail, "logical_and")) continue;
        instruction.typed_left_operand_span_id = .invalid;
        break;
    } else return error.TestUnexpectedResult;
    var verifier_reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_logical_return_plan.mc", source);
    defer verifier_reporter.deinit();
    try mir.verifyBuiltMir(typed_mir, &verifier_reporter);
    try std.testing.expect(verifier_reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, verifier_reporter.diagnostics.items[0].message, "E_MIR_IDENTITY") != null);
}

test "MIR owns explicit cast source types for call results" {
    const source =
        \\fn byte() -> u8 { return 7; }
        \\fn widen() -> u32 { return byte() as u32; }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_call_cast_source_type.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "widen").?;
    const source_fact = targetTypeFactByKind(function, .explicit_cast_source) orelse return error.TestUnexpectedResult;
    const target_fact = targetTypeFactByKind(function, .explicit_cast_target) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("u8", source_fact.target_ty.kind.name.text);
    try std.testing.expectEqualStrings("u32", target_fact.target_ty.kind.name.text);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR identifies indirect function-pointer struct fields before direct calls" {
    const source =
        \\fn increment(value: u32) -> u32 { return value + 1; }
        \\struct Callback { run: fn(u32) -> u32 }
        \\fn invoke(callback: *Callback, value: u32) -> u32 { return callback.run(value); }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_indirect_member_call_signature_facts.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "invoke").?;
    const fact = targetTypeFactByKind(function, .indirect_call_callee) orelse return error.TestUnexpectedResult;
    try std.testing.expect(switch (fact.target_ty.kind) {
        .fn_pointer => true,
        else => false,
    });
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR records complete checked binary trap edges for division remainder and shifts" {
    const source =
        \\fn unsigned_div(a: u32, b: u32) -> u32 {
        \\    return a / b;
        \\}
        \\
        \\fn unsigned_rem(a: u32, b: u32) -> u32 {
        \\    return a % b;
        \\}
        \\
        \\fn signed_div(a: i32, b: i32) -> i32 {
        \\    return a / b;
        \\}
        \\
        \\fn signed_rem(a: i32, b: i32) -> i32 {
        \\    return a % b;
        \\}
        \\
        \\fn checked_shl(a: u32, b: u32) -> u32 {
        \\    return a << b;
        \\}
        \\
        \\fn checked_shr(a: u32, b: u32) -> u32 {
        \\    return a >> b;
        \\}
        \\
        \\#[no_lang_trap]
        \\fn reject_no_lang_div(a: u32, b: u32) -> u32 {
        \\    return a / b;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_binary_traps.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    const unsigned_div_fn = functionByName(typed_mir, "unsigned_div").?;
    try std.testing.expectEqual(@as(usize, 1), countTrapEdges(unsigned_div_fn, .DivideByZero));
    try std.testing.expectEqual(@as(usize, 0), countTrapEdges(unsigned_div_fn, .IntegerOverflow));

    const unsigned_rem_fn = functionByName(typed_mir, "unsigned_rem").?;
    try std.testing.expectEqual(@as(usize, 1), countTrapEdges(unsigned_rem_fn, .DivideByZero));
    try std.testing.expectEqual(@as(usize, 0), countTrapEdges(unsigned_rem_fn, .IntegerOverflow));

    const signed_div_fn = functionByName(typed_mir, "signed_div").?;
    try std.testing.expectEqual(@as(usize, 1), countTrapEdges(signed_div_fn, .DivideByZero));
    try std.testing.expectEqual(@as(usize, 1), countTrapEdges(signed_div_fn, .IntegerOverflow));

    const signed_rem_fn = functionByName(typed_mir, "signed_rem").?;
    try std.testing.expectEqual(@as(usize, 1), countTrapEdges(signed_rem_fn, .DivideByZero));
    try std.testing.expectEqual(@as(usize, 1), countTrapEdges(signed_rem_fn, .IntegerOverflow));

    const checked_shl_fn = functionByName(typed_mir, "checked_shl").?;
    try std.testing.expectEqual(@as(usize, 1), countTrapEdges(checked_shl_fn, .InvalidShift));
    try std.testing.expectEqual(@as(usize, 1), countTrapEdges(checked_shl_fn, .IntegerOverflow));

    const checked_shr_fn = functionByName(typed_mir, "checked_shr").?;
    try std.testing.expectEqual(@as(usize, 1), countTrapEdges(checked_shr_fn, .InvalidShift));
    try std.testing.expectEqual(@as(usize, 0), countTrapEdges(checked_shr_fn, .IntegerOverflow));

    try mir.verifyBuiltMir(typed_mir, &reporter);
    var found_no_lang = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_NO_LANG_TRAP_EDGE") != null) found_no_lang = true;
    }
    try std.testing.expect(found_no_lang);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFactsFromDecls(std.testing.allocator, module.decls, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=signed_div pass=trap finding=trap_edge detail=DivideByZero") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=signed_div pass=trap finding=trap_edge detail=IntegerOverflow") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=checked_shl pass=trap finding=trap_edge detail=InvalidShift") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=checked_shl pass=trap finding=trap_edge detail=IntegerOverflow") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=checked_shr pass=trap finding=trap_edge detail=InvalidShift") != null);
}

test "MIR const_get fixed indexing has no bounds trap edge" {
    const source =
        \\#[no_lang_trap]
        \\fn fixed(xs: [2]u32) -> u32 {
        \\    return xs.const_get<1>();
        \\}
        \\
        \\#[no_lang_trap]
        \\fn rejected(xs: [2]u32, i: usize) -> u32 {
        \\    return xs[i];
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_const_get.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    const fixed_fn = functionByName(typed_mir, "fixed").?;
    const rejected_fn = functionByName(typed_mir, "rejected").?;
    try std.testing.expect(functionHasInstruction(fixed_fn, .index, "const_get"));
    try std.testing.expectEqual(@as(usize, 0), countTrapEdges(fixed_fn, .Bounds));
    try std.testing.expectEqual(@as(usize, 1), countTrapEdges(rejected_fn, .Bounds));

    try mir.verifyBuiltMir(typed_mir, &reporter);
    try std.testing.expect(reporter.has_errors);
    var no_lang_count: usize = 0;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_NO_LANG_TRAP_EDGE") != null) no_lang_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), no_lang_count);
}

test "MIR records typed call target facts for reductions" {
    const source =
        \\fn checked(xs: []const u32) -> Result<u32, Overflow> {
        \\    return reduce.sum_checked<u32>(xs);
        \\}
        \\
        \\fn left(xs: []const f64) -> f64 {
        \\    return reduce.sum_left<f64>(xs);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_reduce_call_targets.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    const checked = functionByName(typed_mir, "checked").?;
    try std.testing.expectEqual(@as(usize, 1), checked.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.reduce_sum_checked, checked.call_target_facts[0].kind);
    try std.testing.expectEqualStrings("Result", checked.call_target_facts[0].result_ty.name());
    try std.testing.expectEqual(@as(usize, 1), countTargetTypeFactsByKind(checked, .reduce_source));
    try std.testing.expectEqual(@as(usize, 1), countTargetTypeFactsByKind(checked, .reduce_element));
    var checked_has_source = false;
    var checked_has_element = false;
    for (checked.target_type_facts) |fact| switch (fact.kind) {
        .reduce_source => {
            const slice = fact.target_ty.kind.slice;
            try std.testing.expectEqual(.@"const", slice.mutability);
            try std.testing.expectEqualStrings("u32", slice.child.kind.name.text);
            checked_has_source = true;
        },
        .reduce_element => {
            try std.testing.expectEqualStrings("u32", fact.target_ty.kind.name.text);
            checked_has_element = true;
        },
        .expression_result => {},
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(checked_has_source);
    try std.testing.expect(checked_has_element);

    const left = functionByName(typed_mir, "left").?;
    try std.testing.expectEqual(@as(usize, 1), left.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.reduce_sum_left, left.call_target_facts[0].kind);
    try std.testing.expectEqualStrings("f64", left.call_target_facts[0].result_ty.name());
    try std.testing.expectEqual(@as(usize, 1), countTargetTypeFactsByKind(left, .reduce_source));
    try std.testing.expectEqual(@as(usize, 1), countTargetTypeFactsByKind(left, .reduce_element));
    var left_has_source = false;
    var left_has_element = false;
    for (left.target_type_facts) |fact| switch (fact.kind) {
        .reduce_source => {
            const slice = fact.target_ty.kind.slice;
            try std.testing.expectEqual(.@"const", slice.mutability);
            try std.testing.expectEqualStrings("f64", slice.child.kind.name.text);
            left_has_source = true;
        },
        .reduce_element => {
            try std.testing.expectEqualStrings("f64", fact.target_ty.kind.name.text);
            left_has_element = true;
        },
        .expression_result => {},
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(left_has_source);
    try std.testing.expect(left_has_element);
    try mir.validateCallTargetFactsForLowering(typed_mir);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns enum raw call identities and source result types" {
    const source =
        \\enum Color: u32 { red = 1, blue = 2 }
        \\open enum Tag: u8 { ready = 3 }
        \\enum DefaultTag { idle }
        \\fn closed_raw(value: Color) -> u32 { return value.raw(); }
        \\fn open_raw(value: Tag) -> u8 { return value.raw(); }
        \\fn path_raw() -> u32 { return Color.blue.raw(); }
        \\fn default_raw(value: DefaultTag) -> isize { return value.raw(); }
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_enum_raw_facts.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    for ([_]struct { name: []const u8, source_name: []const u8, result_name: []const u8 }{
        .{ .name = "closed_raw", .source_name = "Color", .result_name = "u32" },
        .{ .name = "open_raw", .source_name = "Tag", .result_name = "u8" },
        .{ .name = "path_raw", .source_name = "Color", .result_name = "u32" },
        .{ .name = "default_raw", .source_name = "DefaultTag", .result_name = "isize" },
    }) |case| {
        const function = functionByName(typed_mir, case.name).?;
        try std.testing.expectEqual(@as(usize, 1), function.call_target_facts.len);
        try std.testing.expectEqual(mir.CallTargetKind.enum_raw, function.call_target_facts[0].kind);
        try std.testing.expectEqualStrings(case.result_name, function.call_target_facts[0].result_ty.name());
        var source_fact: ?mir.TargetTypeFact = null;
        var result_fact: ?mir.TargetTypeFact = null;
        for (function.target_type_facts) |fact| switch (fact.kind) {
            .enum_raw_source => source_fact = fact,
            .enum_raw_result => result_fact = fact,
            else => {},
        };
        try std.testing.expectEqualStrings(case.source_name, source_fact.?.target_ty.kind.name.text);
        try std.testing.expectEqualStrings(case.result_name, result_fact.?.target_ty.kind.name.text);
    }
    try mir.validateCallTargetFactsForLowering(typed_mir);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns inferred local types for enum raw results" {
    const source =
        \\enum Color: u32 { red = 1 }
        \\fn inferred_enum_raw(value: Color) -> u32 {
        \\    let raw = value.raw();
        \\    return raw;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_inferred_enum_raw_local_type.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "inferred_enum_raw").?;
    const result_fact = targetTypeFactByKind(function, .enum_raw_result) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("u32", result_fact.target_ty.kind.name.text);
    const local_fact = targetTypeFactByKind(function, .inferred_local) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("raw", local_fact.target_owner.?);
    try std.testing.expectEqualStrings("u32", local_fact.target_ty.kind.name.text);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns arithmetic domain call identities and complete types" {
    const source =
        \\type Raw = u16;
        \\type Word = wrap<Raw>;
        \\type Seq = serial<u32>;
        \\type Ticks = counter<u64>;
        \\fn residue(value: Word) -> u16 { return value.residue(); }
        \\fn before(a: Seq, b: Seq) -> bool { return Seq.before(a, b); }
        \\fn after(a: Seq, b: Seq) -> bool { return Seq.after(a, b); }
        \\fn distance(a: Seq, b: Seq) -> wrap<u32> { return Seq.distance(a, b); }
        \\fn compare(a: Seq, b: Seq) -> Result<Order, AmbiguousSerialOrder> { return Seq.compare(a, b); }
        \\fn delta(now: Ticks, start: Ticks) -> wrap<u64> { return Ticks.delta_mod(now, start); }
        \\fn elapsed(now: Ticks, start: Ticks, max: Duration<u64>) -> Duration<u64> { return Ticks.elapsed_assume_within(now, start, max); }
        \\fn bounded(now: Ticks, start: Ticks, max: Duration<u64>) -> Result<Duration<u64>, AmbiguousCounterInterval> { return Ticks.elapsed_bounded(now, start, max); }
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_domain_call_facts.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    for ([_]struct {
        name: []const u8,
        kind: mir.CallTargetKind,
        domain_name: []const u8,
        payload_name: []const u8,
        result_name: []const u8,
        has_interval: bool = false,
    }{
        .{ .name = "residue", .kind = .wrap_residue, .domain_name = "Word", .payload_name = "Raw", .result_name = "Raw" },
        .{ .name = "before", .kind = .serial_before, .domain_name = "Seq", .payload_name = "u32", .result_name = "bool" },
        .{ .name = "after", .kind = .serial_after, .domain_name = "Seq", .payload_name = "u32", .result_name = "bool" },
        .{ .name = "distance", .kind = .serial_distance, .domain_name = "Seq", .payload_name = "u32", .result_name = "wrap" },
        .{ .name = "compare", .kind = .serial_compare, .domain_name = "Seq", .payload_name = "u32", .result_name = "Result" },
        .{ .name = "delta", .kind = .counter_delta_mod, .domain_name = "Ticks", .payload_name = "u64", .result_name = "wrap" },
        .{ .name = "elapsed", .kind = .counter_elapsed_assume_within, .domain_name = "Ticks", .payload_name = "u64", .result_name = "Duration", .has_interval = true },
        .{ .name = "bounded", .kind = .counter_elapsed_bounded, .domain_name = "Ticks", .payload_name = "u64", .result_name = "Result", .has_interval = true },
    }) |case| {
        const function = functionByName(typed_mir, case.name).?;
        try std.testing.expectEqual(@as(usize, 1), function.call_target_facts.len);
        try std.testing.expectEqual(case.kind, function.call_target_facts[0].kind);
        var domain_fact: ?mir.TargetTypeFact = null;
        var payload_fact: ?mir.TargetTypeFact = null;
        var result_fact: ?mir.TargetTypeFact = null;
        var interval_fact: ?mir.TargetTypeFact = null;
        for (function.target_type_facts) |fact| switch (fact.kind) {
            .domain_type => domain_fact = fact,
            .domain_payload => payload_fact = fact,
            .domain_result => result_fact = fact,
            .domain_interval => interval_fact = fact,
            else => {},
        };
        try std.testing.expectEqualStrings(case.domain_name, typeExprHeadName(domain_fact.?.target_ty).?);
        try std.testing.expectEqualStrings(case.payload_name, typeExprHeadName(payload_fact.?.target_ty).?);
        try std.testing.expectEqualStrings(case.result_name, typeExprHeadName(result_fact.?.target_ty).?);
        try std.testing.expectEqual(case.has_interval, interval_fact != null);
        if (interval_fact) |fact| try std.testing.expectEqualStrings("Duration", typeExprHeadName(fact.target_ty).?);
    }
    try mir.validateCallTargetFactsForLowering(typed_mir);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
    try mir.validateLoweringAdmission(typed_mir);
}

test "MIR owns inferred local types for arithmetic domain call results" {
    const source =
        \\type Ticks = counter<u64>;
        \\fn inferred_bounded(now: Ticks, start: Ticks, max: Duration<u64>) -> Result<Duration<u64>, AmbiguousCounterInterval> {
        \\    let value = Ticks.elapsed_bounded(now, start, max);
        \\    return value;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_inferred_domain_call_local_type.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "inferred_bounded").?;
    const domain_fact = targetTypeFactByKind(function, .domain_result) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Result", typeExprHeadName(domain_fact.target_ty).?);
    const local_fact = targetTypeFactByKind(function, .inferred_local) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("value", local_fact.target_owner.?);
    try std.testing.expectEqualStrings("Result", typeExprHeadName(local_fact.target_ty).?);
    try mir.validateLoweringAdmission(typed_mir);
}

test "MIR owns const_get base result and index facts" {
    const source =
        \\type Words = [3]u32;
        \\fn other() -> u32 { return 0; }
        \\fn get_word(values: Words) -> u32 { return values.const_get<2>(); }
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_const_get_facts.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "get_word").?;
    const other = functionByNamePtr(&typed_mir, "other").?;
    try std.testing.expectEqual(@as(usize, 1), function.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.const_get, function.call_target_facts[0].kind);
    try std.testing.expectEqual(@as(usize, 1), function.const_get_facts.len);
    try std.testing.expectEqual(@as(usize, 2), function.const_get_facts[0].index);

    var base_fact: ?mir.TargetTypeFact = null;
    var result_fact: ?mir.TargetTypeFact = null;
    var instruction_index: ?usize = null;
    for (function.target_type_facts) |fact| switch (fact.kind) {
        .const_get_base => base_fact = fact,
        .const_get_result => result_fact = fact,
        else => {},
    };
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.kind == .index and std.mem.eql(u8, instruction.detail, "const_get")) instruction_index = instruction.const_index;
    };
    try std.testing.expectEqualStrings("Words", typeExprHeadName(base_fact.?.target_ty).?);
    try std.testing.expectEqualStrings("u32", typeExprHeadName(result_fact.?.target_ty).?);
    try std.testing.expectEqual(@as(?usize, 2), instruction_index);
    const facts = mir_facts_view.MirFactsView.init();
    try std.testing.expect(facts.targetTypeFactAtCurrentSpan(.{
        .current = other,
        .fact = .{
            .kind = .const_get_base,
            .source = base_fact.?.source,
        },
    }) == null);
    try std.testing.expect(facts.targetTypeFactAtCurrentSpan(.{
        .current = other,
        .fact = .{
            .kind = .const_get_result,
            .source = result_fact.?.source,
        },
    }) == null);
    try mir.validateConstGetFactsForLowering(typed_mir);
    try mir.validateCallTargetFactsForLowering(typed_mir);
    try mir.validateTargetTypeFactsForLowering(typed_mir);

    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(std.testing.allocator);
    try mir.appendDumpFromDecls(std.testing.allocator, module.decls, &dump);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "kind=index detail=const_get type=u32 const_index=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir const_get_fact fn=get_word index=2 recorded=true") != null);
}

test "MIR rejects const_get with both index instruction and fact removed" {
    const source =
        \\fn get_word(values: [3]u32) -> u32 { return values.const_get<2>(); }
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_const_get_missing_pair.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    try mir.validateConstGetFactsForLowering(typed_mir);

    const function = functionByNameMut(&typed_mir, "get_word").?;
    std.testing.allocator.free(function.const_get_facts);
    function.const_get_facts = &.{};

    var removed = false;
    for (function.blocks) |*block| {
        var remove_count: usize = 0;
        for (block.instructions) |instruction| {
            if (instruction.kind == .index and std.mem.eql(u8, instruction.detail, "const_get")) remove_count += 1;
        }
        if (remove_count == 0) continue;
        const filtered = try std.testing.allocator.alloc(Instruction, block.instructions.len - remove_count);
        var next: usize = 0;
        for (block.instructions) |instruction| {
            if (instruction.kind == .index and std.mem.eql(u8, instruction.detail, "const_get")) continue;
            filtered[next] = instruction;
            next += 1;
        }
        std.testing.allocator.free(block.instructions);
        block.instructions = filtered;
        removed = true;
    }
    try std.testing.expect(removed);
    try std.testing.expectError(error.InvalidMirConstGetFacts, mir.validateConstGetFactsForLowering(typed_mir));
}

test "MIR owns DMA call identities and complete types" {
    const source =
        \\extern struct Packet { len: u16, tag: u8 }
        \\type Buffer = DmaBuf<Packet, .noncoherent>;
        \\fn dma_cycle(buf: Buffer) -> []mut Packet {
        \\    cache.clean(buf);
        \\    cache.invalidate(buf);
        \\    let addr: DmaAddr = buf.dma_addr();
        \\    return buf.as_slice();
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_dma_facts.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "dma_cycle").?;
    try std.testing.expectEqual(@as(usize, 4), function.call_target_facts.len);

    var clean = false;
    var invalidate = false;
    var dma_addr = false;
    var as_slice = false;
    for (function.call_target_facts) |fact| switch (fact.kind) {
        .dma_cache_clean => clean = true,
        .dma_cache_invalidate => invalidate = true,
        .dma_addr => dma_addr = true,
        .dma_as_slice => as_slice = true,
        else => {},
    };
    try std.testing.expect(clean and invalidate and dma_addr and as_slice);

    var buffer_count: usize = 0;
    var payload_count: usize = 0;
    var result_count: usize = 0;
    var void_results: usize = 0;
    var address_results: usize = 0;
    var slice_results: usize = 0;
    for (function.target_type_facts) |fact| switch (fact.kind) {
        .dma_buffer => {
            buffer_count += 1;
            try std.testing.expectEqualStrings("Buffer", typeExprHeadName(fact.target_ty).?);
        },
        .dma_payload => {
            payload_count += 1;
            try std.testing.expectEqualStrings("Packet", typeExprHeadName(fact.target_ty).?);
        },
        .dma_result => {
            result_count += 1;
            switch (fact.target_ty.kind) {
                .name => |name| {
                    if (std.mem.eql(u8, name.text, "void")) void_results += 1 else if (std.mem.eql(u8, name.text, "DmaAddr")) address_results += 1;
                },
                .slice => |slice| {
                    try std.testing.expectEqual(ast.Mutability.mut, slice.mutability);
                    try std.testing.expectEqualStrings("Packet", typeExprHeadName(slice.child.*).?);
                    slice_results += 1;
                },
                else => return error.TestUnexpectedResult,
            }
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 4), buffer_count);
    try std.testing.expectEqual(@as(usize, 4), payload_count);
    try std.testing.expectEqual(@as(usize, 4), result_count);
    try std.testing.expectEqual(@as(usize, 2), void_results);
    try std.testing.expectEqual(@as(usize, 1), address_results);
    try std.testing.expectEqual(@as(usize, 1), slice_results);
    try mir.validateCallTargetFactsForLowering(typed_mir);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns value reflection call target facts" {
    const source =
        \\extern struct Packet {
        \\    len: u16,
        \\    tag: u8,
        \\}
        \\enum Mode: u8 {
        \\    normal = 0,
        \\}
        \\fn reflected_size() -> usize { return size_of<Packet>(); }
        \\fn reflected_alignment() -> usize { return alignof<Packet>(); }
        \\fn reflected_field_offset() -> usize { return field_offset<Packet>(.tag); }
        \\fn reflected_bit_offset() -> usize { return bit_offset<Packet>(.tag); }
        \\fn reflected_repr() -> usize { return repr_of<Mode>(); }
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_reflection_call_targets.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    const expected = [_]struct { name: []const u8, kind: mir.CallTargetKind, target: []const u8 }{
        .{ .name = "reflected_size", .kind = .reflection_size, .target = "Packet" },
        .{ .name = "reflected_alignment", .kind = .reflection_alignment, .target = "Packet" },
        .{ .name = "reflected_field_offset", .kind = .reflection_field_offset, .target = "Packet" },
        .{ .name = "reflected_bit_offset", .kind = .reflection_bit_offset, .target = "Packet" },
        .{ .name = "reflected_repr", .kind = .reflection_repr, .target = "Mode" },
    };
    for (expected) |item| {
        const function = functionByName(typed_mir, item.name).?;
        try std.testing.expectEqual(@as(usize, 1), function.call_target_facts.len);
        try std.testing.expectEqual(item.kind, function.call_target_facts[0].kind);
        try std.testing.expectEqualStrings("usize", function.call_target_facts[0].result_ty.name());
        const reflection_target = targetTypeFactByKind(function, .reflection_target) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(item.target, reflection_target.target_ty.kind.name.text);
        const reflection_result = targetTypeFactByKind(function, .reflection_result) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("usize", reflection_result.target_ty.kind.name.text);
    }
    try mir.validateCallTargetFactsForLowering(typed_mir);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns byte-view call target facts" {
    const source =
        \\fn byte_view(value: u32) -> []const u8 {
        \\    return mem.as_bytes(&value);
        \\}
        \\fn byte_equal(left: []const u8, right: []const u8) -> bool {
        \\    return mem.bytes_equal(left, right);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_byte_view_call_targets.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    const view = functionByName(typed_mir, "byte_view").?;
    try std.testing.expectEqual(@as(usize, 1), view.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.byte_view_as_bytes, view.call_target_facts[0].kind);
    try std.testing.expectEqualStrings("[]const", view.call_target_facts[0].result_ty.name());
    const view_source = targetTypeFactByKind(view, .byte_view_source) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("u32", view_source.target_ty.kind.name.text);
    const view_result = targetTypeFactByKind(view, .byte_view_result) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(ast.Mutability.@"const", view_result.target_ty.kind.slice.mutability);
    var saw_view_pointer_result = false;
    for (view.target_type_facts) |fact| {
        if (fact.kind != .expression_result or fact.target_ty.kind != .pointer) continue;
        try std.testing.expectEqual(ast.Mutability.@"const", fact.target_ty.kind.pointer.mutability);
        try std.testing.expectEqualStrings("u32", fact.target_ty.kind.pointer.child.kind.name.text);
        saw_view_pointer_result = true;
    }
    try std.testing.expect(saw_view_pointer_result);

    const equal = functionByName(typed_mir, "byte_equal").?;
    try std.testing.expectEqual(@as(usize, 1), equal.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.byte_view_equal, equal.call_target_facts[0].kind);
    try std.testing.expectEqualStrings("bool", equal.call_target_facts[0].result_ty.name());
    const equal_source = targetTypeFactByKind(equal, .byte_view_source) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(ast.Mutability.@"const", equal_source.target_ty.kind.slice.mutability);
    const equal_result = targetTypeFactByKind(equal, .byte_view_result) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("bool", equal_result.target_ty.kind.name.text);
    try mir.validateCallTargetFactsForLowering(typed_mir);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns raw-many offset identity and complete types" {
    const source =
        \\type Words = [*]mut u16;
        \\fn shifted(p: Words, index: usize) -> Words {
        \\    unsafe { return p.offset(index); }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_raw_many_offset_facts.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    const shifted = functionByName(typed_mir, "shifted").?;
    try std.testing.expectEqual(@as(usize, 1), shifted.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.raw_many_offset, shifted.call_target_facts[0].kind);
    try std.testing.expectEqualStrings("[*]mut", shifted.call_target_facts[0].result_ty.name());
    const raw_base = targetTypeFactByKind(shifted, .raw_many_offset_base) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Words", raw_base.target_ty.kind.name.text);
    const raw_element = targetTypeFactByKind(shifted, .raw_many_offset_element) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("u16", raw_element.target_ty.kind.name.text);
    const raw_result = targetTypeFactByKind(shifted, .raw_many_offset_result) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Words", raw_result.target_ty.kind.name.text);
    try mir.validateCallTargetFactsForLowering(typed_mir);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns inferred local types for raw-many offset results" {
    const source =
        \\type Words = [*]mut u16;
        \\fn inferred_raw_many(p: Words, index: usize) -> Words {
        \\    unsafe {
        \\        let shifted = p.offset(index);
        \\        return shifted;
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_inferred_raw_many_local_type.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "inferred_raw_many").?;
    const result_fact = targetTypeFactByKind(function, .raw_many_offset_result) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Words", result_fact.target_ty.kind.name.text);
    const local_fact = targetTypeFactByKind(function, .inferred_local) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("shifted", local_fact.target_owner.?);
    try std.testing.expectEqualStrings("Words", local_fact.target_ty.kind.name.text);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns inferred local types for raw-many offset dereferences" {
    const source =
        \\type Words = [*]mut u16;
        \\fn inferred_raw_many_deref(p: Words, index: usize) -> u16 {
        \\    unsafe {
        \\        let value = p.offset(index).*;
        \\        return value;
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_inferred_raw_many_deref_local_type.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "inferred_raw_many_deref").?;
    const element_fact = targetTypeFactByKind(function, .raw_many_offset_element) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("u16", element_fact.target_ty.kind.name.text);
    const local_fact = targetTypeFactByKind(function, .inferred_local) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("value", local_fact.target_owner.?);
    try std.testing.expectEqualStrings("u16", local_fact.target_ty.kind.name.text);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns span-identified result types for compound expressions" {
    const source =
        \\struct Packet { values: [2]u32 }
        \\fn expression_results(packet: Packet, index: usize, ptr: *mut u32) -> u32 {
        \\    unsafe {
        \\        let value = packet.values[index];
        \\        let window: []u32 = packet.values[0..1];
        \\        let same = !(value == window[0]);
        \\        if (same) { return value + window[0] + ptr.*; }
        \\        return value;
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_expression_result_facts.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "expression_results").?;
    try std.testing.expect(countTargetTypeFactsByKind(function, .expression_result) >= 15);
    var last_source: ?mir.SourcePoint = null;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .expression_result) continue;
        try std.testing.expect(fact.source.len != 0);
        if (last_source) |previous| try std.testing.expect(previous.offset != fact.source.offset or previous.len != fact.source.len);
        last_source = fact.source;
    }
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns grouped expression result types" {
    const source =
        \\fn grouped_result(value: u16) -> u16 {
        \\    return (value) + 1;
        \\}
    ;
    const grouped_text = "(value)";
    const grouped_offset = std.mem.indexOf(u8, source, grouped_text) orelse return error.TestUnexpectedResult;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_grouped_expression_result.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "grouped_result").?;
    var found = false;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .expression_result or fact.source.offset != grouped_offset or fact.source.len != grouped_text.len) continue;
        try std.testing.expectEqualStrings("u16", fact.target_ty.kind.name.text);
        found = true;
    }
    try std.testing.expect(found);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns grouped direct-call result types" {
    const source =
        \\fn make() -> u16 { return 7; }
        \\fn grouped_call_result() -> u16 { return (make()); }
    ;
    const grouped_text = "(make())";
    const grouped_offset = std.mem.indexOf(u8, source, grouped_text) orelse return error.TestUnexpectedResult;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_grouped_call_result.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "grouped_call_result").?;
    var found = false;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .expression_result or fact.source.offset != grouped_offset or fact.source.len != grouped_text.len) continue;
        try std.testing.expectEqualStrings("u16", fact.target_ty.kind.name.text);
        found = true;
    }
    try std.testing.expect(found);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns source block expression result types" {
    const source =
        \\fn block_result() -> u32 { return { 1 + 2; }; }
    ;
    const block_text = "{ 1 + 2; }";
    const block_offset = std.mem.indexOf(u8, source, block_text) orelse return error.TestUnexpectedResult;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_block_expression_policy.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "block_result").?;
    var found = false;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .expression_result or fact.source.offset != block_offset or fact.source.len != block_text.len) continue;
        try std.testing.expectEqualStrings("u32", fact.target_ty.kind.name.text);
        found = true;
    }
    try std.testing.expect(found);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns source boolean expression result types" {
    const source =
        \\fn compare(left: u32, right: u32) -> bool { return !(left < right); }
    ;
    const comparison_text = "left < right";
    const comparison_offset = std.mem.indexOf(u8, source, comparison_text) orelse return error.TestUnexpectedResult;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_boolean_expression_result.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "compare").?;
    var found = false;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .expression_result or fact.source.offset != comparison_offset or fact.source.len != comparison_text.len) continue;
        try std.testing.expectEqualStrings("bool", fact.target_ty.kind.name.text);
        found = true;
    }
    try std.testing.expect(found);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns source void literal expression result types" {
    const source =
        \\fn explicit_void() -> void { (); }
    ;
    const void_text = "()";
    const void_offset = (std.mem.indexOf(u8, source, "{ ();") orelse return error.TestUnexpectedResult) + "{ ".len;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_void_literal_expression_result.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "explicit_void").?;
    var found = false;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .expression_result or fact.source.offset != void_offset or fact.source.len != void_text.len) continue;
        try std.testing.expectEqualStrings("void", fact.target_ty.kind.name.text);
        found = true;
    }
    try std.testing.expect(found);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns direct address dereference result types" {
    const source =
        \\fn read_local() -> u32 {
        \\    var local: u32 = 1;
        \\    return (&local).*;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_address_deref_result.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "read_local").?;
    const fact = targetTypeFactByKind(function, .expression_result) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("u32", fact.target_ty.kind.name.text);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns structural access facts and projects them through the body plan" {
    const source =
        \\fn access_shapes(values: [4]u32, index: usize) -> u32 {
        \\    var local: u32 = 1;
        \\    let pointer: *mut u32 = &local;
        \\    let window: []u32 = values[1..3];
        \\    return window[index] + pointer.*;
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_access_facts.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "access_shapes") orelse return error.TestUnexpectedResult;
    var saw_index = false;
    var saw_range_slice = false;
    var saw_address_of = false;
    var saw_deref = false;
    for (function.access_facts) |fact| switch (fact) {
        .index => |access| {
            try std.testing.expectEqual(.integer, std.meta.activeTag(access.index_ty));
            try std.testing.expect(mir.sourcePointForSpanId(function, access.typed_span_id) != null);
            try std.testing.expect(mir.sourcePointForSpanId(function, access.base_span_id) != null);
            try std.testing.expect(mir.sourcePointForSpanId(function, access.index_span_id) != null);
            saw_index = true;
        },
        .range_slice => |access| {
            switch (access.result_ty) {
                .slice => {},
                .pointer => |shape| try std.testing.expectEqual(.slice, shape.kind),
                else => return error.TestUnexpectedResult,
            }
            try std.testing.expectEqual(.integer, std.meta.activeTag(access.start_ty));
            try std.testing.expectEqual(.integer, std.meta.activeTag(access.end_ty));
            try std.testing.expect(mir.sourcePointForSpanId(function, access.typed_span_id) != null);
            try std.testing.expect(mir.sourcePointForSpanId(function, access.base_span_id) != null);
            try std.testing.expect(mir.sourcePointForSpanId(function, access.start_span_id) != null);
            try std.testing.expect(mir.sourcePointForSpanId(function, access.end_span_id) != null);
            saw_range_slice = true;
        },
        .address_of => |access| {
            try std.testing.expectEqual(.pointer, std.meta.activeTag(access.result_ty));
            try std.testing.expect(mir.sourcePointForSpanId(function, access.operand_span_id) != null);
            saw_address_of = true;
        },
        .deref => |access| {
            try std.testing.expectEqual(.pointer, std.meta.activeTag(access.operand_ty));
            try std.testing.expect(mir.sourcePointForSpanId(function, access.operand_span_id) != null);
            saw_deref = true;
        },
    };
    try std.testing.expect(saw_index and saw_range_slice and saw_address_of and saw_deref);

    var plan = try mir_body_plan.build(std.testing.allocator, functionByNamePtr(&typed_mir, "access_shapes").?);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(function.access_facts.len, plan.access_facts.len);
    for (function.access_facts, plan.access_facts) |access_fact, planned_access_fact| {
        try std.testing.expect(std.meta.eql(access_fact, planned_access_fact));
    }
    try mir.verifyBuiltMir(typed_mir, &reporter);
    try std.testing.expect(!reporter.has_errors);
}

test "MIR verifier rejects malformed structural access facts" {
    // DIAGNOSTIC_UNIT: E_MIR_ACCESS_FACT
    const source =
        \\fn access_shapes(values: [4]u32) -> []u32 {
        \\    return values[1..3];
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_access_fact_mutation.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByNameMut(&typed_mir, "access_shapes") orelse return error.TestUnexpectedResult;
    var mutated = false;
    for (function.access_facts) |*fact| switch (fact.*) {
        .range_slice => |*access| {
            access.end_span_id = .invalid;
            mutated = true;
            break;
        },
        else => {},
    };
    try std.testing.expect(mutated);
    try std.testing.expectError(error.InvalidAccessFact, mir_body_plan.verify(function));
    try mir.verifyBuiltMir(typed_mir, &reporter);
    try std.testing.expect(reporter.has_errors);
}

test "MIR owns MMIO read write identities and complete types" {
    const source =
        \\packed bits Status: u8 { ready: bool }
        \\extern mmio struct Device {
        \\    raw: Reg<u32, .read_write>,
        \\    flags: RegBits<u8, Status, .read>,
        \\}
        \\fn read_raw(dev: MmioPtr<Device>) -> u32 { return dev.raw.read(.relaxed); }
        \\fn read_raw_inferred(dev: MmioPtr<Device>) -> u32 {
        \\    let value = dev.raw.read(.relaxed);
        \\    return value;
        \\}
        \\fn write_raw(dev: MmioPtr<Device>, value: u32) -> void { dev.raw.write(value, .release); }
        \\fn read_flags(dev: MmioPtr<Device>) -> Status { return dev.flags.read(.acquire); }
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_mmio_call_facts.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    const cases = [_]struct { name: []const u8, kind: mir.CallTargetKind, storage: []const u8, value: []const u8, result: []const u8 }{
        .{ .name = "read_raw", .kind = .mmio_read, .storage = "u32", .value = "u32", .result = "u32" },
        .{ .name = "write_raw", .kind = .mmio_write, .storage = "u32", .value = "u32", .result = "void" },
        .{ .name = "read_flags", .kind = .mmio_read, .storage = "u8", .value = "Status", .result = "Status" },
    };
    for (cases) |case| {
        const function = functionByName(typed_mir, case.name).?;
        try std.testing.expectEqual(@as(usize, 1), function.call_target_facts.len);
        try std.testing.expectEqual(case.kind, function.call_target_facts[0].kind);
        const mmio_struct = targetTypeFactByKind(function, .mmio_struct) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("Device", mmio_struct.target_ty.kind.name.text);
        const mmio_storage = targetTypeFactByKind(function, .mmio_storage) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(case.storage, mmio_storage.target_ty.kind.name.text);
        const mmio_value = targetTypeFactByKind(function, .mmio_value) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(case.value, mmio_value.target_ty.kind.name.text);
        const mmio_result = targetTypeFactByKind(function, .mmio_result) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(case.result, mmio_result.target_ty.kind.name.text);
    }
    const inferred = functionByName(typed_mir, "read_raw_inferred").?;
    try std.testing.expectEqual(@as(usize, 1), inferred.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.mmio_read, inferred.call_target_facts[0].kind);
    const result_fact = targetTypeFactByKind(inferred, .mmio_result) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("u32", result_fact.target_ty.kind.name.text);
    const local_fact = targetTypeFactByKind(inferred, .inferred_local) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("value", local_fact.target_owner.?);
    try std.testing.expectEqualStrings("u32", local_fact.target_ty.kind.name.text);
    try mir.validateCallTargetFactsForLowering(typed_mir);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns MMIO map identity and complete types" {
    const source =
        \\extern mmio struct Device {
        \\    raw: Reg<u32, .read>,
        \\}
        \\fn map_device(pa: PAddr) -> MmioPtr<Device> {
        \\    unsafe { return mmio.map<Device>(pa)?; }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_mmio_map_facts.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "map_device").?;
    try std.testing.expectEqual(@as(usize, 1), function.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.mmio_map, function.call_target_facts[0].kind);
    const try_result = targetTypeFactByKind(function, .expression_result) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("MmioPtr", try_result.target_ty.kind.generic.base.text);
    try std.testing.expectEqualStrings("Device", try_result.target_ty.kind.generic.args[0].kind.name.text);
    const try_operand = targetTypeFactByKind(function, .try_operand) orelse return error.TestUnexpectedResult;
    try std.testing.expect(try_operand.target_ty.kind == .nullable);
    const map_source = targetTypeFactByKind(function, .mmio_map_source) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("PAddr", map_source.target_ty.kind.name.text);
    const map_payload = targetTypeFactByKind(function, .mmio_map_payload) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("MmioPtr", map_payload.target_ty.kind.generic.base.text);
    try std.testing.expectEqualStrings("Device", map_payload.target_ty.kind.generic.args[0].kind.name.text);
    const map_result = targetTypeFactByKind(function, .mmio_map_result) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("MmioPtr", map_result.target_ty.kind.nullable.kind.generic.base.text);
    try mir.validateCallTargetFactsForLowering(typed_mir);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns semantic escape call target facts" {
    const source =
        \\global shared: u8 = 0;
        \\fn reveal_value(secret: Secret<u8>) -> u8 {
        \\    unsafe { return reveal(secret); }
        \\}
        \\fn noalias_value(p: *mut u8, n: usize) -> *mut u8 {
        \\    #[unsafe_contract(noalias)] {
        \\        return compiler.assume_noalias_unchecked(p, n);
        \\    }
        \\}
        \\fn noalias_address(n: usize) -> *mut u8 {
        \\    #[unsafe_contract(noalias)] {
        \\        return compiler.assume_noalias_unchecked(&shared, n);
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_semantic_escape_call_targets.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    const reveal_fn = functionByName(typed_mir, "reveal_value").?;
    try std.testing.expectEqual(@as(usize, 1), reveal_fn.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.declassify, reveal_fn.call_target_facts[0].kind);
    try std.testing.expectEqualStrings("u8", reveal_fn.call_target_facts[0].result_ty.name());
    const declassify_source = targetTypeFactByKind(reveal_fn, .declassify_source) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Secret", declassify_source.target_ty.kind.generic.base.text);
    const declassify_result = targetTypeFactByKind(reveal_fn, .declassify_result) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("u8", declassify_result.result_ty.name());

    const noalias_fn = functionByName(typed_mir, "noalias_value").?;
    try std.testing.expectEqual(@as(usize, 1), noalias_fn.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.assume_noalias, noalias_fn.call_target_facts[0].kind);
    try std.testing.expectEqualStrings("*mut", noalias_fn.call_target_facts[0].result_ty.name());
    try std.testing.expect(targetTypeFactByKind(noalias_fn, .assume_noalias_source) != null);
    try std.testing.expect(targetTypeFactByKind(noalias_fn, .assume_noalias_result) != null);

    const address_fn = functionByName(typed_mir, "noalias_address").?;
    try std.testing.expectEqual(@as(usize, 1), address_fn.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.assume_noalias, address_fn.call_target_facts[0].kind);
    try std.testing.expectEqualStrings("*mut", address_fn.call_target_facts[0].result_ty.name());
    const noalias_address_source = targetTypeFactByKind(address_fn, .assume_noalias_source) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("*mut", noalias_address_source.result_ty.name());
    try std.testing.expect(targetTypeFactByKind(address_fn, .assume_noalias_result) != null);
    var saw_mut_u8_pointer_result = false;
    for (address_fn.target_type_facts) |fact| {
        if (fact.kind != .expression_result or fact.target_ty.kind != .pointer) continue;
        try std.testing.expectEqual(ast.Mutability.mut, fact.target_ty.kind.pointer.mutability);
        try std.testing.expectEqualStrings("u8", fact.target_ty.kind.pointer.child.kind.name.text);
        saw_mut_u8_pointer_result = true;
    }
    try std.testing.expect(saw_mut_u8_pointer_result);
    try mir.validateCallTargetFactsForLowering(typed_mir);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns discard call identities and argument types" {
    const source =
        \\move struct Guard { id: u32 }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void {
        \\    g.id = 0;
        \\}
        \\fn discard_values(value: Guard) -> void {
        \\    drop(value);
        \\    unsafe { forget_unchecked(value); }
        \\}
        \\fn discard_plain(value: u32) -> void {
        \\    drop(value);
        \\    unsafe { forget_unchecked(value); }
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_discard_call_targets.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "discard_values").?;
    const plain_function = functionByName(typed_mir, "discard_plain").?;
    try std.testing.expectEqual(@as(usize, 2), function.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.drop, function.call_target_facts[0].kind);
    try std.testing.expectEqual(mir.CallTargetKind.forget_unchecked, function.call_target_facts[1].kind);
    try std.testing.expectEqual(@as(usize, 2), countTargetTypeFactsByKind(function, .discard_argument));
    try std.testing.expectEqual(@as(usize, 2), function.ownership_events.len);
    try std.testing.expectEqual(@as(usize, 0), plain_function.ownership_events.len);
    try std.testing.expectEqual(@as(usize, 1), typed_mir.drop_glue_facts.len);
    const drop_glue_fact = typed_mir.drop_glue_facts[0];
    const value_identity = valueIdentityBySpelling(function, "value") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(mir.OwnershipEventKind.explicit_drop, function.ownership_events[0].kind);
    try std.testing.expect(function.ownership_events[0].place.root_value_id.eql(value_identity.id));
    try std.testing.expect(function.ownership_events[0].place.root_type_symbol_id.eql(drop_glue_fact.typed_resource_symbol_id));
    try std.testing.expect(function.ownership_events[0].drop_glue_symbol_id.eql(drop_glue_fact.typed_release_symbol_id));
    try std.testing.expectEqual(mir.OwnershipEventKind.forget, function.ownership_events[1].kind);
    try std.testing.expect(function.ownership_events[1].place.root_value_id.eql(value_identity.id));
    try std.testing.expect(function.ownership_events[1].place.root_type_symbol_id.eql(drop_glue_fact.typed_resource_symbol_id));
    try std.testing.expect(!function.ownership_events[1].drop_glue_symbol_id.isValid());
    for (function.target_type_facts) |fact| {
        if (fact.kind == .expression_result) continue;
        try std.testing.expectEqual(mir.TargetTypeKind.discard_argument, fact.kind);
        try std.testing.expectEqualStrings("Guard", fact.target_ty.kind.name.text);
    }
    try std.testing.expectEqual(@as(usize, 2), countTargetTypeFactsByKind(plain_function, .discard_argument));
    try mir.validateLoweringAdmission(typed_mir);

    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(std.testing.allocator);
    try mir.appendDumpFromMir(std.testing.allocator, typed_mir, &dump);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir ownership_event fn=discard_values kind=explicit_drop") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "root_type_symbol=") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir ownership_event fn=discard_values kind=forget") != null);
}

test "MIR ownership event admission rejects explicit drop without glue identity" {
    // DIAGNOSTIC_UNIT: E_MIR_OWNERSHIP_EVENT
    const source =
        \\move struct Guard { id: u32 }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void { g.id = 0; }
        \\fn discard_values(value: Guard) -> void {
        \\    drop(value);
        \\}
    ;
    var parsed = try test_support.parseModule("mir_explicit_drop_requires_glue.mc", source);
    defer parsed.deinit();

    var bad_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer bad_mir.deinit();
    const function = functionByNameMut(&bad_mir, "discard_values") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), function.ownership_events.len);
    try std.testing.expectEqual(mir.OwnershipEventKind.explicit_drop, function.ownership_events[0].kind);
    function.ownership_events[0].drop_glue_symbol_id = .invalid;

    try std.testing.expectError(error.InvalidMirOwnershipEvents, mir.validateLoweringAdmission(bad_mir));

    var verifier_reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_explicit_drop_requires_glue.mc", source);
    defer verifier_reporter.deinit();
    try mir.verifyBuiltMir(bad_mir, &verifier_reporter);
    try std.testing.expect(verifier_reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, verifier_reporter.diagnostics.items[0].message, "E_MIR_OWNERSHIP_EVENT") != null);
}

test "MIR ownership event admission rejects symbol-root drop glue type drift" {
    // DIAGNOSTIC_UNIT: E_MIR_OWNERSHIP_EVENT
    const source =
        \\move struct Guard { id: u32 }
        \\move struct Other { id: u32 }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void { g.id = 0; }
        \\#[drop]
        \\fn close_other(o: *mut Other) -> void { o.id = 0; }
        \\fn use_guard() -> u32 {
        \\    var g: Guard = .{ .id = 1 };
        \\    return g.id;
        \\}
    ;
    var parsed = try test_support.parseModule("mir_drop_glue_type_drift.mc", source);
    defer parsed.deinit();

    var bad_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer bad_mir.deinit();
    try std.testing.expectEqual(@as(usize, 2), bad_mir.drop_glue_facts.len);
    const guard_fact = bad_mir.drop_glue_facts[0];
    const other_fact = bad_mir.drop_glue_facts[1];
    const function = functionByNameMut(&bad_mir, "use_guard") orelse return error.TestUnexpectedResult;
    const generated_events = function.ownership_events;
    const events = try std.testing.allocator.alloc(mir.OwnershipEvent, 1);
    events[0] = .{
        .kind = .explicit_drop,
        .place = .{ .root_symbol_id = guard_fact.typed_resource_symbol_id },
        .drop_glue_symbol_id = other_fact.typed_release_symbol_id,
        .block_id = BlockId.fromIndex(0),
        .source = .{ .line = 8, .column = 5 },
    };
    function.ownership_events = events;
    std.testing.allocator.free(generated_events);

    try std.testing.expectError(error.InvalidMirOwnershipEvents, mir.validateLoweringAdmission(bad_mir));

    var verifier_reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_drop_glue_type_drift.mc", source);
    defer verifier_reporter.deinit();
    try mir.verifyBuiltMir(bad_mir, &verifier_reporter);
    try std.testing.expect(verifier_reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, verifier_reporter.diagnostics.items[0].message, "E_MIR_OWNERSHIP_EVENT") != null);
}

test "MIR ownership event admission rejects local-root drop glue type drift" {
    // DIAGNOSTIC_UNIT: E_MIR_OWNERSHIP_EVENT
    const source =
        \\move struct Guard { id: u32 }
        \\move struct Other { id: u32 }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void { g.id = 0; }
        \\#[drop]
        \\fn close_other(o: *mut Other) -> void { o.id = 0; }
        \\fn discard_guard(value: Guard) -> void {
        \\    drop(value);
        \\}
    ;
    var parsed = try test_support.parseModule("mir_local_drop_glue_type_drift.mc", source);
    defer parsed.deinit();

    var bad_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer bad_mir.deinit();
    try std.testing.expectEqual(@as(usize, 2), bad_mir.drop_glue_facts.len);
    const other_fact = bad_mir.drop_glue_facts[1];
    const function = functionByNameMut(&bad_mir, "discard_guard") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), function.ownership_events.len);
    try std.testing.expectEqual(mir.OwnershipEventKind.explicit_drop, function.ownership_events[0].kind);
    function.ownership_events[0].drop_glue_symbol_id = other_fact.typed_release_symbol_id;

    try std.testing.expectError(error.InvalidMirOwnershipEvents, mir.validateLoweringAdmission(bad_mir));

    var verifier_reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_local_drop_glue_type_drift.mc", source);
    defer verifier_reporter.deinit();
    try mir.verifyBuiltMir(bad_mir, &verifier_reporter);
    try std.testing.expect(verifier_reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, verifier_reporter.diagnostics.items[0].message, "E_MIR_OWNERSHIP_EVENT") != null);
}

test "MIR records drop glue facts for auto-drop resources" {
    const source =
        \\move struct Ticket { id: u32 }
        \\struct Wrapper { ticket: Ticket }
        \\#[drop]
        \\fn close_ticket(ticket: *mut Ticket) -> void {
        \\    ticket.id = 0;
        \\}
        \\#[drop]
        \\fn close_wrapper(wrapper: *mut Wrapper) -> void {
        \\    wrapper.ticket.id = 0;
        \\}
        \\fn use_wrapper() -> u32 {
        \\    var wrapper: Wrapper = .{ .ticket = .{ .id = 1 } };
        \\    return wrapper.ticket.id;
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_drop_glue_facts.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var module_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer module_mir.deinit();
    try std.testing.expectEqual(@as(usize, 2), module_mir.drop_glue_facts.len);
    try std.testing.expectEqualStrings("Ticket", module_mir.drop_glue_facts[0].resource_type);
    try std.testing.expect(module_mir.drop_glue_facts[0].typed_resource_symbol_id.isValid());
    try std.testing.expectEqualStrings("Ticket", module_mir.symbol_identities[module_mir.drop_glue_facts[0].typed_resource_symbol_id.index()].spelling);
    try std.testing.expectEqualStrings("close_ticket", module_mir.drop_glue_facts[0].release_fn);
    try std.testing.expect(module_mir.drop_glue_facts[0].typed_release_symbol_id.isValid());
    try std.testing.expectEqualStrings("close_ticket", module_mir.symbol_identities[module_mir.drop_glue_facts[0].typed_release_symbol_id.index()].spelling);
    try std.testing.expectEqualStrings("Wrapper", module_mir.drop_glue_facts[1].resource_type);
    try std.testing.expect(module_mir.drop_glue_facts[1].typed_resource_symbol_id.isValid());
    try std.testing.expectEqualStrings("Wrapper", module_mir.symbol_identities[module_mir.drop_glue_facts[1].typed_resource_symbol_id.index()].spelling);
    try std.testing.expectEqualStrings("close_wrapper", module_mir.drop_glue_facts[1].release_fn);
    try std.testing.expect(module_mir.drop_glue_facts[1].typed_release_symbol_id.isValid());
    try std.testing.expectEqualStrings("close_wrapper", module_mir.symbol_identities[module_mir.drop_glue_facts[1].typed_release_symbol_id.index()].spelling);

    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(std.testing.allocator);
    try mir.appendDumpFromMir(std.testing.allocator, module_mir, &dump);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir drop_glue_fact resource_type=Ticket resource_symbol=") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "release_fn=close_ticket release_symbol=") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir drop_glue_fact resource_type=Wrapper resource_symbol=") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "release_fn=close_wrapper release_symbol=") != null);
}

test "MIR records canonical type ownership facts" {
    const source =
        \\struct Plain { id: u32 }
        \\move struct Ticket { id: u32 }
        \\struct Wrapper { ticket: Ticket }
        \\linear struct Token { id: u32 }
        \\#[experimental_ownership]
        \\region struct Node { id: u32 }
        \\#[experimental_ownership]
        \\view struct SliceView { len: usize }
        \\#[experimental_ownership]
        \\thread_move move struct WorkerTicket { id: u32 }
        \\#[drop]
        \\fn close_ticket(ticket: *mut Ticket) -> void {
        \\    ticket.id = 0;
        \\}
        \\#[drop]
        \\fn close_wrapper(wrapper: *mut Wrapper) -> void {
        \\    wrapper.ticket.id = 0;
        \\}
    ;
    var parsed = try test_support.parseModule("mir_type_ownership_facts.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try std.testing.expectEqual(@as(usize, 7), module_mir.type_ownership_facts.len);
    try std.testing.expectEqual(mir.TypeOwnershipKind.copy, typeOwnershipByName(module_mir, "Plain").?.kind);
    const ticket = typeOwnershipByName(module_mir, "Ticket").?;
    try std.testing.expectEqual(mir.TypeOwnershipKind.affine, ticket.kind);
    try std.testing.expect(ticket.typed_type_symbol_id.isValid());
    try std.testing.expect(ticket.drop_glue_symbol_id.isValid());
    try std.testing.expect(!ticket.thread_move);
    const wrapper = typeOwnershipByName(module_mir, "Wrapper").?;
    try std.testing.expectEqual(mir.TypeOwnershipKind.affine, wrapper.kind);
    try std.testing.expect(wrapper.drop_glue_symbol_id.isValid());
    try std.testing.expectEqual(mir.TypeOwnershipKind.linear, typeOwnershipByName(module_mir, "Token").?.kind);
    try std.testing.expectEqual(mir.TypeOwnershipKind.region, typeOwnershipByName(module_mir, "Node").?.kind);
    try std.testing.expectEqual(mir.TypeOwnershipKind.view, typeOwnershipByName(module_mir, "SliceView").?.kind);
    const worker = typeOwnershipByName(module_mir, "WorkerTicket").?;
    try std.testing.expectEqual(mir.TypeOwnershipKind.affine, worker.kind);
    try std.testing.expect(worker.thread_move);
    try mir.validateLoweringAdmission(module_mir);

    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(std.testing.allocator);
    try mir.appendDumpFromMir(std.testing.allocator, module_mir, &dump);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir type_ownership type=Ticket symbol=") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "kind=affine") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir type_ownership type=Wrapper symbol=") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir type_ownership type=Token symbol=") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "kind=linear") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir type_ownership type=WorkerTicket symbol=") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "thread_move=true") != null);
}

test "MIR type ownership fact admission rejects symbol and duplicate drift" {
    const source =
        \\move struct Ticket { id: u32 }
        \\#[drop]
        \\fn close_ticket(ticket: *mut Ticket) -> void {
        \\    ticket.id = 0;
        \\}
    ;
    var parsed = try test_support.parseModule("mir_type_ownership_fact_admission.mc", source);
    defer parsed.deinit();

    var symbol_drift = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer symbol_drift.deinit();
    try std.testing.expectEqual(@as(usize, 1), symbol_drift.type_ownership_facts.len);
    symbol_drift.type_ownership_facts[0].typed_type_symbol_id = .invalid;
    try std.testing.expectError(error.InvalidMirTypeOwnershipFacts, mir.validateLoweringAdmission(symbol_drift));

    var drop_drift = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer drop_drift.deinit();
    try std.testing.expectEqual(@as(usize, 1), drop_drift.type_ownership_facts.len);
    drop_drift.type_ownership_facts[0].drop_glue_symbol_id = .invalid;
    try std.testing.expectError(error.InvalidMirDropGlueFacts, mir.validateLoweringAdmission(drop_drift));
    drop_drift.type_ownership_facts[0].drop_glue_symbol_id = mir.SymbolId.fromIndex(4096);
    try std.testing.expectError(error.InvalidMirDropGlueFacts, mir.validateLoweringAdmission(drop_drift));

    var duplicate = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer duplicate.deinit();
    try std.testing.expectEqual(@as(usize, 1), duplicate.type_ownership_facts.len);
    const original = duplicate.type_ownership_facts;
    const forged = try std.testing.allocator.alloc(mir.TypeOwnershipFact, 2);
    forged[0] = original[0];
    forged[1] = original[0];
    duplicate.type_ownership_facts = forged;
    std.testing.allocator.free(original);
    try std.testing.expectError(error.InvalidMirTypeOwnershipFacts, mir.validateLoweringAdmission(duplicate));
}

test "MIR drop glue fact admission rejects unknown and duplicate release facts" {
    const source =
        \\move struct Guard { id: u32 }
        \\fn make_guard() -> Guard { return .{ .id = 1 }; }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void {
        \\    g.id = 0;
        \\}
        \\fn use_guard() -> u32 {
        \\    var g = make_guard();
        \\    return g.id;
        \\}
    ;
    var parsed = try test_support.parseModule("mir_drop_glue_fact_admission.mc", source);
    defer parsed.deinit();

    var unknown = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer unknown.deinit();
    try std.testing.expectEqual(@as(usize, 1), unknown.drop_glue_facts.len);
    unknown.drop_glue_facts[0].release_fn = "missing_close_guard";
    try std.testing.expectError(error.InvalidMirDropGlueFacts, mir.validateLoweringAdmission(unknown));

    var release_drift = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer release_drift.deinit();
    try std.testing.expectEqual(@as(usize, 1), release_drift.drop_glue_facts.len);
    release_drift.drop_glue_facts[0].typed_release_symbol_id = .invalid;
    try std.testing.expectError(error.InvalidMirDropGlueFacts, mir.validateLoweringAdmission(release_drift));

    var resource_drift = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer resource_drift.deinit();
    try std.testing.expectEqual(@as(usize, 1), resource_drift.drop_glue_facts.len);
    resource_drift.drop_glue_facts[0].typed_resource_symbol_id = .invalid;
    try std.testing.expectError(error.InvalidMirDropGlueFacts, mir.validateLoweringAdmission(resource_drift));

    var duplicate = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer duplicate.deinit();
    try std.testing.expectEqual(@as(usize, 1), duplicate.drop_glue_facts.len);
    const original = duplicate.drop_glue_facts;
    const forged = try std.testing.allocator.alloc(mir.DropGlueFact, 2);
    forged[0] = original[0];
    forged[1] = original[0];
    duplicate.drop_glue_facts = forged;
    std.testing.allocator.free(original);
    try std.testing.expectError(error.InvalidMirDropGlueFacts, mir.validateLoweringAdmission(duplicate));
}

test "MIR ownership events are admitted and dumped through typed MIR" {
    const source =
        \\move struct Guard { id: u32 }
        \\fn make_guard() -> Guard { return .{ .id = 1 }; }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void {
        \\    g.id = 0;
        \\}
        \\fn use_guard() -> u32 {
        \\    var g = make_guard();
        \\    return g.id;
        \\}
    ;
    var parsed = try test_support.parseModule("mir_ownership_event.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try std.testing.expectEqual(@as(usize, 1), module_mir.drop_glue_facts.len);
    const drop_fact = module_mir.drop_glue_facts[0];
    const use_guard = functionByNameMut(&module_mir, "use_guard") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 4), use_guard.ownership_events.len);
    try std.testing.expectEqual(mir.OwnershipEventKind.storage_live, use_guard.ownership_events[0].kind);
    try std.testing.expect(use_guard.ownership_events[0].place.root_type_symbol_id.eql(drop_fact.typed_resource_symbol_id));
    try std.testing.expectEqual(mir.OwnershipEventKind.init, use_guard.ownership_events[1].kind);
    try std.testing.expect(use_guard.ownership_events[1].place.root_type_symbol_id.eql(drop_fact.typed_resource_symbol_id));
    try std.testing.expectEqual(mir.OwnershipEventKind.auto_drop, use_guard.ownership_events[2].kind);
    try std.testing.expect(use_guard.ownership_events[2].place.root_type_symbol_id.eql(drop_fact.typed_resource_symbol_id));
    try std.testing.expect(use_guard.ownership_events[2].drop_glue_symbol_id.eql(drop_fact.typed_release_symbol_id));
    try std.testing.expectEqual(mir.OwnershipEventKind.storage_dead, use_guard.ownership_events[3].kind);
    try std.testing.expect(use_guard.ownership_events[3].place.root_type_symbol_id.eql(drop_fact.typed_resource_symbol_id));
    var unified_cleanup_plan: std.ArrayList(mir.CleanupActionPlanEntry) = .empty;
    defer unified_cleanup_plan.deinit(std.testing.allocator);
    try mir.appendOwnershipCleanupPlan(std.testing.allocator, module_mir, use_guard.*, &unified_cleanup_plan);
    try std.testing.expectEqual(@as(usize, 1), unified_cleanup_plan.items.len);
    try std.testing.expectEqual(mir.CleanupActionKind.auto_drop, unified_cleanup_plan.items[0].kind);
    try std.testing.expectEqual(@as(usize, 2), unified_cleanup_plan.items[0].primary_event_index);
    try std.testing.expectEqual(@as(usize, 3), unified_cleanup_plan.items[0].storage_dead_event_index);
    try std.testing.expect(unified_cleanup_plan.items[0].place.root_value_id.eql(use_guard.ownership_events[2].place.root_value_id));
    try std.testing.expect(unified_cleanup_plan.items[0].place.root_type_symbol_id.eql(drop_fact.typed_resource_symbol_id));
    try std.testing.expect(unified_cleanup_plan.items[0].drop_glue_symbol_id.eql(drop_fact.typed_release_symbol_id));
    var cleanup_edge_table = try mir.buildOwnershipCleanupEdgeTable(std.testing.allocator, module_mir, use_guard.*, .{ .actions = unified_cleanup_plan.items });
    defer cleanup_edge_table.deinit(std.testing.allocator);
    try std.testing.expect(cleanup_edge_table.edges.len >= 1);
    const scope_ownership_edge = for (cleanup_edge_table.edges) |edge| {
        if (edge.kind == .scope_exit) break edge;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), scope_ownership_edge.actions.len);
    try std.testing.expectEqual(@as(usize, 0), scope_ownership_edge.actions[0].cleanup_action_index);
    try std.testing.expect(scope_ownership_edge.actions[0].root_value_id.eql(use_guard.ownership_events[2].place.root_value_id));
    try std.testing.expect(mir.ownershipCleanupEdgeTableValid(module_mir, use_guard.*, .{ .actions = unified_cleanup_plan.items }, cleanup_edge_table));
    cleanup_edge_table.edges[0].actions[0].drop_glue_symbol_id = .invalid;
    try std.testing.expect(!mir.ownershipCleanupEdgeTableValid(module_mir, use_guard.*, .{ .actions = unified_cleanup_plan.items }, cleanup_edge_table));
    cleanup_edge_table.edges[0].actions[0].drop_glue_symbol_id = drop_fact.typed_release_symbol_id;
    var cleanup_cfg = try mir.buildCleanupCfg(std.testing.allocator, module_mir, use_guard.*, .{ .actions = unified_cleanup_plan.items });
    defer cleanup_cfg.deinit(std.testing.allocator);
    try std.testing.expect(mir.cleanupCfgValid(module_mir, use_guard.*, .{ .actions = unified_cleanup_plan.items }, cleanup_cfg));
    try std.testing.expect(cleanup_cfg.edges.len >= 1);
    const scope_cleanup_edge = for (cleanup_cfg.edges) |edge| {
        if (edge.kind == .scope_exit) break edge;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), scope_cleanup_edge.actions.len);
    switch (scope_cleanup_edge.actions[0]) {
        .ownership => |action| try std.testing.expectEqual(@as(usize, 0), action.cleanup_action_index),
        .defer_cleanup => return error.TestUnexpectedResult,
    }
    const g_identity = valueIdentityBySpelling(use_guard.*, "g") orelse return error.TestUnexpectedResult;
    try std.testing.expect(mir.ownershipLocalHasAutoDropResourceEvent(module_mir, use_guard.*, g_identity.id));
    const local_span = ast.Span{ .offset = 1, .len = 1, .line = 1, .column = 2 };
    const cleanup_ref: mir_ownership_authority.OwnershipCleanupActionRef = .{
        .local_name = "g",
        .source = mir.sourcePointFromSpan(local_span),
        .cleanup_action_index = cleanup_edge_table.edges[0].actions[0].cleanup_action_index,
        .root_value_id = cleanup_edge_table.edges[0].actions[0].root_value_id,
        .resource_type_symbol_id = cleanup_edge_table.edges[0].actions[0].resource_type_symbol_id,
        .drop_glue_symbol_id = cleanup_edge_table.edges[0].actions[0].drop_glue_symbol_id,
    };
    const cleanup = mir_ownership_authority.autoDropLocalCleanupFromActionRef(&module_mir, use_guard, &.{ .actions = unified_cleanup_plan.items }, cleanup_ref) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("close_guard", cleanup.fn_name);
    try std.testing.expectEqualStrings("g", cleanup.local_name);
    try std.testing.expectEqual(local_span, cleanup.span);
    try std.testing.expect(cleanup.root_value_id.eql(g_identity.id));
    try std.testing.expect(cleanup.resource_type_symbol_id.eql(drop_fact.typed_resource_symbol_id));
    try std.testing.expect(cleanup.drop_glue_symbol_id.eql(drop_fact.typed_release_symbol_id));
    try std.testing.expectEqual(@as(usize, 0), cleanup.cleanup_action_index);
    try std.testing.expectEqual(unified_cleanup_plan.items[0].primary_event_index, cleanup.auto_drop_event_index);
    try std.testing.expectEqual(unified_cleanup_plan.items[0].storage_dead_event_index, cleanup.storage_dead_event_index);
    var stale_ref = cleanup_ref;
    stale_ref.cleanup_action_index = 99;
    try std.testing.expect(mir_ownership_authority.autoDropLocalCleanupFromActionRef(&module_mir, use_guard, &.{ .actions = unified_cleanup_plan.items }, stale_ref) == null);
    stale_ref = cleanup_ref;
    stale_ref.drop_glue_symbol_id = .invalid;
    try std.testing.expect(mir_ownership_authority.autoDropLocalCleanupFromActionRef(&module_mir, use_guard, &.{ .actions = unified_cleanup_plan.items }, stale_ref) == null);
    const generated_events = use_guard.ownership_events;
    const events = try std.testing.allocator.alloc(mir.OwnershipEvent, 1);
    events[0] = .{
        .kind = .explicit_drop,
        .place = .{ .root_symbol_id = drop_fact.typed_resource_symbol_id },
        .drop_glue_symbol_id = drop_fact.typed_release_symbol_id,
        .block_id = BlockId.fromIndex(0),
        .source = .{ .line = 7, .column = 5 },
    };
    use_guard.ownership_events = events;
    std.testing.allocator.free(generated_events);

    try mir.validateLoweringAdmission(module_mir);

    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(std.testing.allocator);
    try mir.appendDumpFromMir(std.testing.allocator, module_mir, &dump);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir ownership_event fn=use_guard kind=explicit_drop") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "drop_glue_symbol=") != null);
}

test "MIR ownership event admission rejects missing simple local cleanup" {
    // DIAGNOSTIC_UNIT: E_MIR_OWNERSHIP_EVENT
    const source =
        \\move struct Guard { id: u32 }
        \\fn make_guard() -> Guard { return .{ .id = 1 }; }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void { g.id = 0; }
        \\fn use_guard() -> u32 {
        \\    var g = make_guard();
        \\    return g.id;
        \\}
    ;
    var parsed = try test_support.parseModule("mir_missing_simple_local_cleanup.mc", source);
    defer parsed.deinit();

    var bad_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer bad_mir.deinit();
    const use_guard = functionByNameMut(&bad_mir, "use_guard") orelse return error.TestUnexpectedResult;
    const generated_events = use_guard.ownership_events;
    try std.testing.expectEqual(@as(usize, 4), generated_events.len);
    const events = try std.testing.allocator.alloc(mir.OwnershipEvent, 2);
    @memcpy(events, generated_events[0..2]);
    use_guard.ownership_events = events;
    std.testing.allocator.free(generated_events);

    try std.testing.expectError(error.InvalidMirOwnershipEvents, mir.validateLoweringAdmission(bad_mir));

    var verifier_reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_missing_simple_local_cleanup.mc", source);
    defer verifier_reporter.deinit();
    try mir.verifyBuiltMir(bad_mir, &verifier_reporter);
    try std.testing.expect(verifier_reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, verifier_reporter.diagnostics.items[0].message, "E_MIR_OWNERSHIP_EVENT") != null);
}

test "MIR ownership event admission rejects storage-dead without auto-drop" {
    // DIAGNOSTIC_UNIT: E_MIR_OWNERSHIP_EVENT
    const source =
        \\move struct Guard { id: u32 }
        \\fn make_guard() -> Guard { return .{ .id = 1 }; }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void { g.id = 0; }
        \\fn use_guard() -> u32 {
        \\    var g = make_guard();
        \\    return g.id;
        \\}
    ;
    var parsed = try test_support.parseModule("mir_storage_dead_without_auto_drop.mc", source);
    defer parsed.deinit();

    var bad_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer bad_mir.deinit();
    const use_guard = functionByNameMut(&bad_mir, "use_guard") orelse return error.TestUnexpectedResult;
    const generated_events = use_guard.ownership_events;
    try std.testing.expectEqual(@as(usize, 4), generated_events.len);
    const events = try std.testing.allocator.alloc(mir.OwnershipEvent, 3);
    events[0] = generated_events[0];
    events[1] = generated_events[1];
    events[2] = generated_events[3];
    use_guard.ownership_events = events;
    std.testing.allocator.free(generated_events);

    try std.testing.expectError(error.InvalidMirOwnershipEvents, mir.validateLoweringAdmission(bad_mir));

    var verifier_reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_storage_dead_without_auto_drop.mc", source);
    defer verifier_reporter.deinit();
    try mir.verifyBuiltMir(bad_mir, &verifier_reporter);
    try std.testing.expect(verifier_reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, verifier_reporter.diagnostics.items[0].message, "E_MIR_OWNERSHIP_EVENT") != null);
}

test "MIR ownership event admission rejects auto-drop without storage-dead" {
    // DIAGNOSTIC_UNIT: E_MIR_OWNERSHIP_EVENT
    const source =
        \\move struct Guard { id: u32 }
        \\fn make_guard() -> Guard { return .{ .id = 1 }; }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void { g.id = 0; }
        \\fn use_guard() -> u32 {
        \\    var g = make_guard();
        \\    return g.id;
        \\}
    ;
    var parsed = try test_support.parseModule("mir_auto_drop_without_storage_dead.mc", source);
    defer parsed.deinit();

    var bad_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer bad_mir.deinit();
    const use_guard = functionByNameMut(&bad_mir, "use_guard") orelse return error.TestUnexpectedResult;
    const generated_events = use_guard.ownership_events;
    try std.testing.expectEqual(@as(usize, 4), generated_events.len);
    const events = try std.testing.allocator.alloc(mir.OwnershipEvent, 3);
    @memcpy(events, generated_events[0..3]);
    use_guard.ownership_events = events;
    std.testing.allocator.free(generated_events);

    try std.testing.expectError(error.InvalidMirOwnershipEvents, mir.validateLoweringAdmission(bad_mir));
    var cleanup_plan: std.ArrayList(mir.CleanupActionPlanEntry) = .empty;
    defer cleanup_plan.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirOwnershipEvents, mir.appendOwnershipCleanupPlan(std.testing.allocator, bad_mir, use_guard.*, &cleanup_plan));

    var verifier_reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_auto_drop_without_storage_dead.mc", source);
    defer verifier_reporter.deinit();
    try mir.verifyBuiltMir(bad_mir, &verifier_reporter);
    try std.testing.expect(verifier_reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, verifier_reporter.diagnostics.items[0].message, "E_MIR_OWNERSHIP_EVENT") != null);
}

test "MIR records local reinit ownership events" {
    const source =
        \\fn reassign_local() -> u32 {
        \\    var value: u32 = 1;
        \\    value = 2;
        \\    return value;
        \\}
    ;
    var parsed = try test_support.parseModule("mir_ownership_reinit.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const function = functionByName(module_mir, "reassign_local") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), function.ownership_events.len);
    const value_identity = valueIdentityBySpelling(function, "value") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(mir.OwnershipEventKind.storage_live, function.ownership_events[0].kind);
    try std.testing.expect(function.ownership_events[0].place.root_value_id.eql(value_identity.id));
    try std.testing.expectEqual(mir.OwnershipEventKind.init, function.ownership_events[1].kind);
    try std.testing.expect(function.ownership_events[1].place.root_value_id.eql(value_identity.id));
    try std.testing.expectEqual(mir.OwnershipEventKind.reinit, function.ownership_events[2].kind);
    try std.testing.expect(function.ownership_events[2].place.root_value_id.eql(value_identity.id));
    try mir.validateLoweringAdmission(module_mir);

    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(std.testing.allocator);
    try mir.appendDumpFromMir(std.testing.allocator, module_mir, &dump);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir ownership_event fn=reassign_local kind=storage_live") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir ownership_event fn=reassign_local kind=init") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir ownership_event fn=reassign_local kind=reinit") != null);
}

test "MIR ownership event admission accepts sibling copy locals with reused names" {
    const source =
        \\fn sibling_copy_locals() -> u32 {
        \\    var total: u32 = 0;
        \\    {
        \\        let t: u32 = 3;
        \\        total = total + t;
        \\    }
        \\    {
        \\        let t: u64 = 40;
        \\        total = total + (t as u32);
        \\    }
        \\    return total;
        \\}
    ;
    var parsed = try test_support.parseModule("mir_sibling_copy_locals.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try mir.validateLoweringAdmission(module_mir);

    var verifier_reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_sibling_copy_locals.mc", source);
    defer verifier_reporter.deinit();
    try mir.verifyBuiltMir(module_mir, &verifier_reporter);
    try std.testing.expect(!verifier_reporter.has_errors);
}

test "MIR records forget events for no-drop move resources" {
    const source =
        \\move struct Token { id: u32 }
        \\fn make_token() -> Token { return .{ .id = 1 }; }
        \\fn forget_token() -> u32 {
        \\    var token: Token = make_token();
        \\    unsafe { forget_unchecked(token); }
        \\    return 0;
        \\}
    ;
    var parsed = try test_support.parseModule("mir_no_drop_forget.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const function = functionByName(module_mir, "forget_token") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), function.ownership_events.len);
    try std.testing.expectEqual(mir.OwnershipEventKind.storage_live, function.ownership_events[0].kind);
    try std.testing.expectEqual(mir.OwnershipEventKind.init, function.ownership_events[1].kind);
    try std.testing.expectEqual(mir.OwnershipEventKind.forget, function.ownership_events[2].kind);
    try std.testing.expect(function.ownership_events[2].place.root_type_symbol_id.isValid());
    try std.testing.expect(!function.ownership_events[2].drop_glue_symbol_id.isValid());
    try mir.validateLoweringAdmission(module_mir);
}

test "MIR cleanup cfg records ordinary defer cleanup actions" {
    const source =
        \\fn cleanup() -> void {}
        \\fn use_defer() -> void {
        \\    defer cleanup();
        \\}
    ;
    var parsed = try test_support.parseModule("mir_cleanup_cfg_defer.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const function = functionByName(module_mir, "use_defer") orelse return error.TestUnexpectedResult;
    var cleanup_plan = try mir.buildOwnershipCleanupPlan(std.testing.allocator, module_mir, function);
    defer cleanup_plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), cleanup_plan.actions.len);

    var cleanup_cfg = try mir.buildCleanupCfg(std.testing.allocator, module_mir, function, cleanup_plan);
    defer cleanup_cfg.deinit(std.testing.allocator);
    try std.testing.expect(mir.cleanupCfgValid(module_mir, function, cleanup_plan, cleanup_cfg));
    try std.testing.expect(cleanup_cfg.edges.len >= 1);
    const scope_cleanup_edge = for (cleanup_cfg.edges) |edge| {
        if (edge.kind == .scope_exit) break edge;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), scope_cleanup_edge.actions.len);
    switch (scope_cleanup_edge.actions[0]) {
        .defer_cleanup => |action| try std.testing.expectEqual(@as(usize, 0), action.instruction_index),
        .ownership => return error.TestUnexpectedResult,
    }
}

test "MIR ownership authority does not let forget authorize auto-drop registration" {
    const source =
        \\move struct Guard { id: u32 }
        \\fn make_guard() -> Guard { return .{ .id = 1 }; }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void { g.id = 0; }
        \\fn forget_guard() -> u32 {
        \\    var g: Guard = make_guard();
        \\    unsafe { forget_unchecked(g); }
        \\    return 0;
        \\}
    ;
    var parsed = try test_support.parseModule("mir_forget_not_auto_drop_authority.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const function = functionByName(module_mir, "forget_guard") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), function.ownership_events.len);
    try std.testing.expectEqual(mir.OwnershipEventKind.forget, function.ownership_events[2].kind);
    try mir.validateLoweringAdmission(module_mir);
    var cleanup_plan = try mir.buildOwnershipCleanupPlan(std.testing.allocator, module_mir, function);
    defer cleanup_plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), cleanup_plan.actions.len);
    var cleanup_edge_table = try mir.buildOwnershipCleanupEdgeTable(std.testing.allocator, module_mir, function, cleanup_plan);
    defer cleanup_edge_table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), cleanup_edge_table.edges.len);
}

test "MIR records explicit drop glue call ownership events" {
    const source =
        \\move struct Guard { id: u32 }
        \\fn make_guard(id: u32) -> Guard { return .{ .id = id }; }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void { g.id = 0; }
        \\fn release_one() -> u32 {
        \\    var g: Guard = make_guard(1);
        \\    var h: Guard = make_guard(2);
        \\    close_guard(&g);
        \\    return h.id;
        \\}
    ;
    var parsed = try test_support.parseModule("mir_explicit_drop_glue_call.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const function = functionByName(module_mir, "release_one") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 7), function.ownership_events.len);
    try std.testing.expectEqual(mir.OwnershipEventKind.storage_live, function.ownership_events[0].kind);
    try std.testing.expectEqual(mir.OwnershipEventKind.init, function.ownership_events[1].kind);
    try std.testing.expectEqual(mir.OwnershipEventKind.storage_live, function.ownership_events[2].kind);
    try std.testing.expectEqual(mir.OwnershipEventKind.init, function.ownership_events[3].kind);
    try std.testing.expectEqual(mir.OwnershipEventKind.explicit_drop, function.ownership_events[4].kind);
    try std.testing.expect(function.ownership_events[4].drop_glue_symbol_id.isValid());
    try std.testing.expectEqual(mir.OwnershipEventKind.auto_drop, function.ownership_events[5].kind);
    try std.testing.expectEqual(mir.OwnershipEventKind.storage_dead, function.ownership_events[6].kind);
    var unified_cleanup_plan: std.ArrayList(mir.CleanupActionPlanEntry) = .empty;
    defer unified_cleanup_plan.deinit(std.testing.allocator);
    try mir.appendOwnershipCleanupPlan(std.testing.allocator, module_mir, function, &unified_cleanup_plan);
    try std.testing.expectEqual(@as(usize, 2), unified_cleanup_plan.items.len);
    try std.testing.expectEqual(mir.CleanupActionKind.explicit_drop, unified_cleanup_plan.items[0].kind);
    try std.testing.expectEqual(@as(usize, 4), unified_cleanup_plan.items[0].primary_event_index);
    try std.testing.expect(unified_cleanup_plan.items[0].place.root_type_symbol_id.eql(function.ownership_events[4].place.root_type_symbol_id));
    try std.testing.expect(unified_cleanup_plan.items[0].drop_glue_symbol_id.eql(function.ownership_events[4].drop_glue_symbol_id));
    try std.testing.expectEqual(mir.CleanupActionKind.auto_drop, unified_cleanup_plan.items[1].kind);
    try std.testing.expectEqual(@as(usize, 5), unified_cleanup_plan.items[1].primary_event_index);
    try std.testing.expectEqual(@as(usize, 6), unified_cleanup_plan.items[1].storage_dead_event_index);
    var cancellation_plan: std.ArrayList(mir.CleanupCancellationPlanEntry) = .empty;
    defer cancellation_plan.deinit(std.testing.allocator);
    try mir.appendOwnershipCleanupCancellationPlan(std.testing.allocator, module_mir, function, &cancellation_plan);
    try std.testing.expectEqual(@as(usize, 1), cancellation_plan.items.len);
    try std.testing.expectEqual(mir.CleanupCancellationKind.explicit_drop, cancellation_plan.items[0].kind);
    try std.testing.expectEqual(@as(usize, 4), cancellation_plan.items[0].event_index);
    try std.testing.expect(cancellation_plan.items[0].place.root_type_symbol_id.eql(function.ownership_events[4].place.root_type_symbol_id));
    try std.testing.expect(cancellation_plan.items[0].drop_glue_symbol_id.eql(function.ownership_events[4].drop_glue_symbol_id));

    const built_cleanup_plan = try mir.buildOwnershipCleanupPlan(std.testing.allocator, module_mir, function);
    defer built_cleanup_plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(unified_cleanup_plan.items.len, built_cleanup_plan.actions.len);
    try std.testing.expectEqual(cancellation_plan.items.len, built_cleanup_plan.cancellations.len);
    try std.testing.expectEqual(mir.CleanupActionKind.explicit_drop, built_cleanup_plan.actions[0].kind);
    try std.testing.expectEqual(mir.CleanupActionKind.auto_drop, built_cleanup_plan.actions[1].kind);
    try std.testing.expectEqual(mir.CleanupCancellationKind.explicit_drop, built_cleanup_plan.cancellations[0].kind);
    var cleanup_edge_table = try mir.buildOwnershipCleanupEdgeTable(std.testing.allocator, module_mir, function, built_cleanup_plan);
    defer cleanup_edge_table.deinit(std.testing.allocator);
    try std.testing.expect(cleanup_edge_table.edges.len >= 1);
    const scope_cleanup_edge = for (cleanup_edge_table.edges) |edge| {
        if (edge.kind == .scope_exit) break edge;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), scope_cleanup_edge.actions.len);
    try std.testing.expectEqual(@as(usize, 1), scope_cleanup_edge.actions[0].cleanup_action_index);
    try std.testing.expectEqual(mir.CleanupActionKind.auto_drop, scope_cleanup_edge.actions[0].kind);
    try std.testing.expect(mir.ownershipCleanupEdgeTableValid(module_mir, function, built_cleanup_plan, cleanup_edge_table));

    const g_identity = valueIdentityBySpelling(function, "g") orelse return error.TestUnexpectedResult;
    const explicit_ref: mir_ownership_authority.OwnershipCleanupActionRef = .{
        .local_name = "g",
        .source = built_cleanup_plan.actions[0].source,
        .cleanup_action_index = 0,
        .root_value_id = g_identity.id,
        .resource_type_symbol_id = built_cleanup_plan.actions[0].place.root_type_symbol_id,
        .drop_glue_symbol_id = built_cleanup_plan.actions[0].drop_glue_symbol_id,
    };
    const cleanup = mir_ownership_authority.explicitDropLocalCleanupFromActionRef(&module_mir, &function, &built_cleanup_plan, explicit_ref) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("close_guard", cleanup.fn_name);
    try std.testing.expectEqualStrings("g", cleanup.local_name);
    try std.testing.expect(cleanup.root_value_id.eql(g_identity.id));
    try std.testing.expect(cleanup.resource_type_symbol_id.eql(function.ownership_events[4].place.root_type_symbol_id));
    try std.testing.expect(cleanup.drop_glue_symbol_id.eql(function.ownership_events[4].drop_glue_symbol_id));
    try std.testing.expectEqual(@as(usize, 0), cleanup.cleanup_action_index);
    try std.testing.expectEqual(@as(usize, 4), cleanup.explicit_drop_event_index);
    const ref_cleanup = mir_ownership_authority.explicitDropLocalCleanupFromActionRef(&module_mir, &function, &built_cleanup_plan, explicit_ref) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(cleanup.fn_name, ref_cleanup.fn_name);
    try std.testing.expectEqual(cleanup.explicit_drop_event_index, ref_cleanup.explicit_drop_event_index);
    var stale_ref = explicit_ref;
    stale_ref.cleanup_action_index = 99;
    try std.testing.expect(mir_ownership_authority.explicitDropLocalCleanupFromActionRef(&module_mir, &function, &built_cleanup_plan, stale_ref) == null);
    stale_ref = explicit_ref;
    stale_ref.source.line += 1;
    try std.testing.expect(mir_ownership_authority.explicitDropLocalCleanupFromActionRef(&module_mir, &function, &built_cleanup_plan, stale_ref) == null);
    try mir.validateLoweringAdmission(module_mir);
}

test "MIR reinit ownership events require mutable locals" {
    const source =
        \\fn accept_var() -> u32 {
        \\    var value: u32 = 1;
        \\    value = 2;
        \\    return value;
        \\}
        \\
        \\fn reject_let() -> u32 {
        \\    let value: u32 = 1;
        \\    value = 2;
        \\    return value;
        \\}
        \\
        \\fn reject_param(value: u32) -> u32 {
        \\    value = 2;
        \\    return value;
        \\}
    ;
    var parsed = try test_support.parseModule("mir_ownership_reinit_mutable.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try std.testing.expectEqual(@as(usize, 1), countOwnershipEventsByKind(functionByName(module_mir, "accept_var").?, .reinit));
    try std.testing.expectEqual(@as(usize, 0), countOwnershipEventsByKind(functionByName(module_mir, "reject_let").?, .reinit));
    try std.testing.expectEqual(@as(usize, 0), countOwnershipEventsByKind(functionByName(module_mir, "reject_param").?, .reinit));
}

test "MIR records simple move-out ownership events" {
    const source =
        \\move struct Guard { id: u32 }
        \\fn make_guard() -> Guard { return .{ .id = 1 }; }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void { g.id = 0; }
        \\fn return_guard() -> Guard {
        \\    var g = make_guard();
        \\    return move g;
        \\}
    ;
    var parsed = try test_support.parseModule("mir_ownership_move_out.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const function = functionByName(module_mir, "return_guard") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), function.ownership_events.len);
    const g_identity = valueIdentityBySpelling(function, "g") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(mir.OwnershipEventKind.storage_live, function.ownership_events[0].kind);
    try std.testing.expect(function.ownership_events[0].place.root_value_id.eql(g_identity.id));
    try std.testing.expectEqual(mir.OwnershipEventKind.init, function.ownership_events[1].kind);
    try std.testing.expect(function.ownership_events[1].place.root_value_id.eql(g_identity.id));
    try std.testing.expectEqual(mir.OwnershipEventKind.move_out, function.ownership_events[2].kind);
    try std.testing.expect(function.ownership_events[2].place.root_value_id.eql(g_identity.id));
    var cancellation_plan: std.ArrayList(mir.CleanupCancellationPlanEntry) = .empty;
    defer cancellation_plan.deinit(std.testing.allocator);
    try mir.appendOwnershipCleanupCancellationPlan(std.testing.allocator, module_mir, function, &cancellation_plan);
    try std.testing.expectEqual(@as(usize, 1), cancellation_plan.items.len);
    try std.testing.expectEqual(mir.CleanupCancellationKind.move_out, cancellation_plan.items[0].kind);
    try std.testing.expectEqual(@as(usize, 2), cancellation_plan.items[0].event_index);
    try std.testing.expect(cancellation_plan.items[0].place.root_value_id.eql(g_identity.id));
    try std.testing.expect(cancellation_plan.items[0].drop_glue_symbol_id.isValid());
    try mir.validateLoweringAdmission(module_mir);

    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(std.testing.allocator);
    try mir.appendDumpFromMir(std.testing.allocator, module_mir, &dump);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir ownership_event fn=return_guard kind=move_out") != null);
}

test "MIR ownership authority skips cleanup registration for move-out" {
    const source =
        \\move struct Guard { id: u32 }
        \\fn make_guard() -> Guard { return .{ .id = 1 }; }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void { g.id = 0; }
        \\fn return_guard() -> Guard {
        \\    var g: Guard = make_guard();
        \\    return move g;
        \\}
    ;
    var parsed = try test_support.parseModule("mir_ownership_registration_decision.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const function = functionByName(module_mir, "return_guard") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), function.ownership_events.len);
    try std.testing.expectEqual(mir.OwnershipEventKind.move_out, function.ownership_events[2].kind);
    const g_identity = valueIdentityBySpelling(function, "g") orelse return error.TestUnexpectedResult;
    try std.testing.expect(mir.ownershipLocalHasConsumingResourceEvent(function, g_identity.id, function.ownership_events[2].place.root_type_symbol_id));
    var cleanup_plan = try mir.buildOwnershipCleanupPlan(std.testing.allocator, module_mir, function);
    defer cleanup_plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), cleanup_plan.actions.len);
    var cleanup_edge_table = try mir.buildOwnershipCleanupEdgeTable(std.testing.allocator, module_mir, function, cleanup_plan);
    defer cleanup_edge_table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), cleanup_edge_table.edges.len);
}

test "MIR cleanup producer ignores move-out events that cannot reach fallthrough cleanup" {
    const source =
        \\move struct Guard { id: u32 }
        \\fn make_guard(id: u32) -> Guard { return .{ .id = id }; }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void { g.id = 0; }
        \\fn transfer_in_loop(flag: bool) -> Guard {
        \\    var g: Guard = make_guard(1);
        \\    while flag {
        \\        return move g;
        \\    }
        \\    return make_guard(2);
        \\}
    ;
    var parsed = try test_support.parseModule("mir_path_sensitive_cleanup_after_loop.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const function = functionByName(module_mir, "transfer_in_loop") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), countOwnershipEventsByKind(function, .move_out));
    try std.testing.expectEqual(@as(usize, 1), countOwnershipEventsByKind(function, .auto_drop));
    try std.testing.expectEqual(@as(usize, 1), countOwnershipEventsByKind(function, .storage_dead));
    try mir.validateLoweringAdmission(module_mir);
}

test "MIR ownership event admission rejects duplicate local consumption" {
    // DIAGNOSTIC_UNIT: E_MIR_OWNERSHIP_EVENT
    const source =
        \\move struct Guard { id: u32 }
        \\fn make_guard() -> Guard { return .{ .id = 1 }; }
        \\fn return_guard() -> Guard {
        \\    var g = make_guard();
        \\    return move g;
        \\}
    ;
    var parsed = try test_support.parseModule("mir_ownership_duplicate_consume.mc", source);
    defer parsed.deinit();

    var bad_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer bad_mir.deinit();
    const function = functionByNameMut(&bad_mir, "return_guard") orelse return error.TestUnexpectedResult;
    const generated_events = function.ownership_events;
    try std.testing.expectEqual(@as(usize, 3), generated_events.len);
    const events = try std.testing.allocator.alloc(mir.OwnershipEvent, generated_events.len + 1);
    @memcpy(events[0..generated_events.len], generated_events);
    events[generated_events.len] = generated_events[generated_events.len - 1];
    function.ownership_events = events;
    std.testing.allocator.free(generated_events);

    try std.testing.expectError(error.InvalidMirOwnershipEvents, mir.validateLoweringAdmission(bad_mir));

    var verifier_reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_ownership_duplicate_consume.mc", source);
    defer verifier_reporter.deinit();
    try mir.verifyBuiltMir(bad_mir, &verifier_reporter);
    try std.testing.expect(verifier_reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, verifier_reporter.diagnostics.items[0].message, "E_MIR_OWNERSHIP_EVENT") != null);
}

test "MIR ownership event admission enforces local generations" {
    // DIAGNOSTIC_UNIT: E_MIR_OWNERSHIP_EVENT
    const source =
        \\move struct Guard { id: u32 }
        \\fn make_guard() -> Guard { return .{ .id = 1 }; }
        \\fn return_guard() -> Guard {
        \\    var g = make_guard();
        \\    return move g;
        \\}
    ;
    var parsed = try test_support.parseModule("mir_ownership_generation.mc", source);
    defer parsed.deinit();

    var good_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer good_mir.deinit();
    const good_function = functionByNameMut(&good_mir, "return_guard") orelse return error.TestUnexpectedResult;
    const generated_good_events = good_function.ownership_events;
    try std.testing.expectEqual(@as(usize, 3), generated_good_events.len);
    const good_events = try std.testing.allocator.alloc(mir.OwnershipEvent, 5);
    @memcpy(good_events[0..3], generated_good_events);
    good_events[3] = generated_good_events[1];
    good_events[3].kind = .reinit;
    good_events[3].generation = 1;
    good_events[4] = generated_good_events[2];
    good_events[4].generation = 1;
    good_function.ownership_events = good_events;
    std.testing.allocator.free(generated_good_events);
    try mir.validateLoweringAdmission(good_mir);

    var bad_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer bad_mir.deinit();
    const bad_function = functionByNameMut(&bad_mir, "return_guard") orelse return error.TestUnexpectedResult;
    const generated_bad_events = bad_function.ownership_events;
    const bad_events = try std.testing.allocator.alloc(mir.OwnershipEvent, 5);
    @memcpy(bad_events[0..3], generated_bad_events);
    bad_events[3] = generated_bad_events[1];
    bad_events[3].kind = .reinit;
    bad_events[3].generation = 0;
    bad_events[4] = generated_bad_events[2];
    bad_events[4].generation = 1;
    bad_function.ownership_events = bad_events;
    std.testing.allocator.free(generated_bad_events);
    try std.testing.expectError(error.InvalidMirOwnershipEvents, mir.validateLoweringAdmission(bad_mir));

    var stale_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale_mir.deinit();
    const stale_function = functionByNameMut(&stale_mir, "return_guard") orelse return error.TestUnexpectedResult;
    const generated_stale_events = stale_function.ownership_events;
    const stale_events = try std.testing.allocator.alloc(mir.OwnershipEvent, 5);
    @memcpy(stale_events[0..3], generated_stale_events);
    stale_events[3] = generated_stale_events[1];
    stale_events[3].kind = .reinit;
    stale_events[3].generation = 1;
    stale_events[4] = generated_stale_events[2];
    stale_events[4].generation = 0;
    stale_function.ownership_events = stale_events;
    std.testing.allocator.free(generated_stale_events);
    try std.testing.expectError(error.InvalidMirOwnershipEvents, mir.validateLoweringAdmission(stale_mir));
}

test "MIR ownership event admission rejects malformed event identity" {
    // DIAGNOSTIC_UNIT: E_MIR_OWNERSHIP_EVENT
    const source =
        \\move struct Guard { id: u32 }
        \\fn make_guard() -> Guard { return .{ .id = 1 }; }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void {
        \\    g.id = 0;
        \\}
        \\fn use_guard() -> u32 {
        \\    var g = make_guard();
        \\    return g.id;
        \\}
    ;
    var parsed = try test_support.parseModule("mir_bad_ownership_event.mc", source);
    defer parsed.deinit();

    var bad_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer bad_mir.deinit();
    try std.testing.expectEqual(@as(usize, 1), bad_mir.drop_glue_facts.len);
    const drop_fact = bad_mir.drop_glue_facts[0];
    const use_guard = functionByNameMut(&bad_mir, "use_guard") orelse return error.TestUnexpectedResult;
    const generated_events = use_guard.ownership_events;
    const events = try std.testing.allocator.alloc(mir.OwnershipEvent, 1);
    events[0] = .{
        .kind = .auto_drop,
        .place = .{ .root_symbol_id = drop_fact.typed_resource_symbol_id },
        .drop_glue_symbol_id = drop_fact.typed_release_symbol_id,
        .block_id = BlockId.fromIndex(4096),
        .source = .{ .line = 8, .column = 5 },
    };
    use_guard.ownership_events = events;
    std.testing.allocator.free(generated_events);

    try std.testing.expectError(error.InvalidMirOwnershipEvents, mir.validateLoweringAdmission(bad_mir));

    var verifier_reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_bad_ownership_event.mc", source);
    defer verifier_reporter.deinit();
    try mir.verifyBuiltMir(bad_mir, &verifier_reporter);
    try std.testing.expect(verifier_reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, verifier_reporter.diagnostics.items[0].message, "E_MIR_OWNERSHIP_EVENT") != null);
}

test "MIR rejects duplicate call target facts" {
    const source =
        \\fn checked(xs: []const u32) -> Result<u32, Overflow> {
        \\    return reduce.sum_checked<u32>(xs);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_duplicate_call_target_fact.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    for (typed_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, "checked")) continue;
        try duplicateCallTargetFact(function, typed_mir.allocator);
        break;
    }
    try std.testing.expectError(error.InvalidMirCallTargetFacts, mir.validateCallTargetFactsForLowering(typed_mir));
}

test "MIR accepts matching call target multiplicity at one source point" {
    const source =
        \\enum E { bad }
        \\fn make(value: u32) -> Result<u32, E> { return ok(value); }
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_call_target_multiplicity.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByNameMut(&typed_mir, "make").?;
    try duplicateCallTargetFact(function, typed_mir.allocator);
    try duplicateCallTargetInstruction(function, typed_mir.allocator);
    try mir.validateCallTargetFactsForLowering(typed_mir);
}

test "MIR call target facts do not collide with ordinary call names" {
    const source =
        \\fn sum_checked() -> u32 {
        \\    return 7;
        \\}
        \\
        \\fn caller() -> u32 {
        \\    return sum_checked();
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_call_target_name_collision.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const caller = functionByName(typed_mir, "caller").?;
    try std.testing.expectEqual(@as(usize, 0), caller.call_target_facts.len);
    try mir.validateCallTargetFactsForLowering(typed_mir);
}

test "MIR records typed call target facts for atomic member calls" {
    const source =
        \\global boot_counter: atomic<u64> = atomic.init(9);
        \\
        \\fn atomic_ops() -> u32 {
        \\    var counter: atomic<u32> = atomic.init(1);
        \\    counter.store(2, .release);
        \\    let previous: u32 = counter.fetch_add(3, .acq_rel);
        \\    let next: u32 = counter.fetch_sub(1, .seq_cst);
        \\    return previous + next + counter.load(.acquire);
        \\}
        \\
        \\fn other() -> u32 {
        \\    return 0;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_atomic_call_targets.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const global = functionByName(typed_mir, "boot_counter").?;
    try std.testing.expectEqual(@as(usize, 1), global.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.atomic_init, global.call_target_facts[0].kind);
    try std.testing.expectEqual(@as(usize, 1), countTargetTypeFactsByKind(global, .atomic_init_payload));
    try std.testing.expectEqual(@as(usize, 1), countTargetTypeFactsByKind(global, .atomic_init_result));
    const global_payload = targetTypeFactByKind(global, .atomic_init_payload).?;
    const global_result = targetTypeFactByKind(global, .atomic_init_result).?;
    try std.testing.expectEqualStrings("atomic.init", global_payload.target_owner.?);
    try std.testing.expectEqual(global_payload.target_index, global_result.target_index);
    try std.testing.expectEqualStrings("u64", global_payload.target_ty.kind.name.text);
    try std.testing.expectEqualStrings("atomic", global_result.target_ty.kind.generic.base.text);

    const function = functionByName(typed_mir, "atomic_ops").?;
    try std.testing.expectEqual(@as(usize, 5), function.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.atomic_init, function.call_target_facts[0].kind);
    try std.testing.expectEqual(mir.CallTargetKind.atomic_store, function.call_target_facts[1].kind);
    try std.testing.expectEqualStrings("void", function.call_target_facts[1].result_ty.name());
    try std.testing.expectEqual(mir.CallTargetKind.atomic_fetch_add, function.call_target_facts[2].kind);
    try std.testing.expectEqual(mir.CallTargetKind.atomic_fetch_sub, function.call_target_facts[3].kind);
    try std.testing.expectEqual(mir.CallTargetKind.atomic_load, function.call_target_facts[4].kind);
    for (function.call_target_facts[2..]) |fact| try std.testing.expectEqualStrings("u32", fact.result_ty.name());
    try std.testing.expectEqual(@as(usize, 1), countTargetTypeFactsByKind(function, .atomic_init_payload));
    try std.testing.expectEqual(@as(usize, 1), countTargetTypeFactsByKind(function, .atomic_init_result));
    try std.testing.expectEqual(@as(usize, 4), countTargetTypeFactsByKind(function, .atomic_payload));
    const init_payload = targetTypeFactByKind(function, .atomic_init_payload).?;
    const init_result = targetTypeFactByKind(function, .atomic_init_result).?;
    try std.testing.expectEqualStrings("atomic.init", init_payload.target_owner.?);
    try std.testing.expectEqual(init_payload.target_index, init_result.target_index);
    try std.testing.expectEqualStrings("u32", init_payload.target_ty.kind.name.text);
    try std.testing.expectEqualStrings("atomic", init_result.target_ty.kind.generic.base.text);
    const other = functionByNamePtr(&typed_mir, "other").?;
    const facts = mir_facts_view.MirFactsView.init();
    try std.testing.expect(facts.targetTypeFactAtOwnedCurrentSpan(.{
        .current = other,
        .fact = .{
            .kind = .atomic_init_payload,
            .source = init_payload.source,
            .owner = init_payload.target_owner,
            .index = init_payload.target_index,
        },
    }) == null);
    try std.testing.expect(facts.targetTypeFactAtOwnedCurrentSpan(.{
        .current = other,
        .fact = .{
            .kind = .atomic_init_result,
            .source = init_result.source,
            .owner = init_result.target_owner,
            .index = init_result.target_index,
        },
    }) == null);
    try mir.validateCallTargetFactsForLowering(typed_mir);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR records typed call target facts for MaybeUninit member calls" {
    const source =
        \\struct Node { value: u32 }
        \\
        \\fn maybe_uninit_ops() -> u32 {
        \\    var slot: MaybeUninit<Node> = uninit;
        \\    slot.write(.{ .value = 7 });
        \\    let value: Node = slot.assume_init();
        \\    return value.value;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_maybe_uninit_call_targets.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "maybe_uninit_ops").?;
    try std.testing.expectEqual(@as(usize, 2), function.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.maybe_uninit_write, function.call_target_facts[0].kind);
    try std.testing.expectEqualStrings("void", function.call_target_facts[0].result_ty.name());
    try std.testing.expectEqual(mir.CallTargetKind.maybe_uninit_assume_init, function.call_target_facts[1].kind);
    try std.testing.expectEqualStrings("Node", function.call_target_facts[1].result_ty.name());
    var payload_fact_count: usize = 0;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .maybe_uninit_payload) continue;
        payload_fact_count += 1;
        try std.testing.expectEqualStrings("Node", fact.result_ty.name());
    }
    try std.testing.expectEqual(@as(usize, 2), payload_fact_count);
    try mir.validateCallTargetFactsForLowering(typed_mir);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns inferred local types for atomic and MaybeUninit result calls" {
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

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_builtin_inferred_local_types.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const atomic_function = functionByName(typed_mir, "atomic_inferred_locals").?;
    try std.testing.expectEqual(@as(usize, 2), countTargetTypeFactsByKind(atomic_function, .inferred_local));
    for (atomic_function.target_type_facts) |fact| {
        if (fact.kind != .inferred_local) continue;
        try std.testing.expect(fact.target_owner != null);
        try std.testing.expect(std.mem.eql(u8, fact.target_owner.?, "previous") or std.mem.eql(u8, fact.target_owner.?, "loaded"));
        try std.testing.expectEqualStrings("u32", fact.target_ty.kind.name.text);
    }
    const maybe_function = functionByName(typed_mir, "maybe_uninit_inferred_local").?;
    const maybe_fact = targetTypeFactByKind(maybe_function, .inferred_local) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("value", maybe_fact.target_owner.?);
    try std.testing.expectEqualStrings("Node", maybe_fact.target_ty.kind.name.text);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR records typed call target facts for bitcast calls" {
    const source =
        \\fn bitcast_bits(value: f32) -> u32 {
        \\    return bitcast<u32>(value);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_bitcast_call_targets.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "bitcast_bits").?;
    try std.testing.expectEqual(@as(usize, 1), function.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.bitcast, function.call_target_facts[0].kind);
    try std.testing.expectEqualStrings("u32", function.call_target_facts[0].result_ty.name());
    const bitcast_source = targetTypeFactByKind(function, .bitcast_source) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("f32", bitcast_source.result_ty.name());
    const bitcast_target = targetTypeFactByKind(function, .bitcast_target) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("u32", bitcast_target.result_ty.name());
    try mir.validateCallTargetFactsForLowering(typed_mir);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns inferred local types for bitcast results" {
    const source =
        \\fn inferred_bitcast(value: f32) -> u32 {
        \\    let bits = bitcast<u32>(value);
        \\    return bits;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_inferred_bitcast_local_type.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "inferred_bitcast").?;
    const result_fact = targetTypeFactByKind(function, .bitcast_target) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("u32", result_fact.target_ty.kind.name.text);
    const local_fact = targetTypeFactByKind(function, .inferred_local) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("bits", local_fact.target_owner.?);
    try std.testing.expectEqualStrings("u32", local_fact.target_ty.kind.name.text);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns inferred local types for byte-view results" {
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

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_inferred_byte_view_local_types.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const view_fact = targetTypeFactByKind(functionByName(typed_mir, "inferred_byte_view").?, .inferred_local) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("bytes", view_fact.target_owner.?);
    try std.testing.expectEqual(@as(std.meta.Tag(ast.TypeExpr.Kind), .slice), std.meta.activeTag(view_fact.target_ty.kind));
    const equal_fact = targetTypeFactByKind(functionByName(typed_mir, "inferred_byte_equal").?, .inferred_local) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("equal", equal_fact.target_owner.?);
    try std.testing.expectEqualStrings("bool", equal_fact.target_ty.kind.name.text);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns inferred local types for semantic escape results" {
    const source =
        \\fn inferred_noalias(pointer: *mut u8, len: usize) -> *mut u8 {
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        let alias = compiler.assume_noalias_unchecked(pointer, len);
        \\        return alias;
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_inferred_semantic_escape_local_type.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "inferred_noalias").?;
    const result_fact = targetTypeFactByKind(function, .assume_noalias_result) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(.pointer, std.meta.activeTag(result_fact.target_ty.kind));
    const local_fact = targetTypeFactByKind(function, .inferred_local) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("alias", local_fact.target_owner.?);
    try std.testing.expectEqual(.pointer, std.meta.activeTag(local_fact.target_ty.kind));
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR records typed call target facts for phys calls" {
    const source =
        \\fn make_phys(value: usize) -> PAddr {
        \\    return phys(value);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_phys_call_targets.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "make_phys").?;
    try std.testing.expectEqual(@as(usize, 1), function.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.phys, function.call_target_facts[0].kind);
    try std.testing.expectEqualStrings("PAddr", function.call_target_facts[0].result_ty.name());
    const phys_result = targetTypeFactByKind(function, .phys_result) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("PAddr", phys_result.result_ty.name());
    try mir.validateCallTargetFactsForLowering(typed_mir);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns inferred local types for phys results" {
    const source =
        \\fn inferred_phys(value: usize) -> PAddr {
        \\    let address = phys(value);
        \\    return address;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_inferred_phys_local_type.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "inferred_phys").?;
    const result_fact = targetTypeFactByKind(function, .phys_result) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("PAddr", result_fact.target_ty.kind.name.text);
    const local_fact = targetTypeFactByKind(function, .inferred_local) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("address", local_fact.target_owner.?);
    try std.testing.expectEqualStrings("PAddr", local_fact.target_ty.kind.name.text);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns inferred local types for raw result calls" {
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

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_inferred_raw_local_types.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const load = functionByName(typed_mir, "inferred_raw_load").?;
    const load_fact = targetTypeFactByKind(load, .inferred_local) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("value", load_fact.target_owner.?);
    try std.testing.expectEqualStrings("u32", load_fact.target_ty.kind.name.text);
    const pointer = functionByName(typed_mir, "inferred_raw_ptr").?;
    const pointer_fact = targetTypeFactByKind(pointer, .inferred_local) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("pointer", pointer_fact.target_owner.?);
    try std.testing.expect(pointer_fact.target_ty.kind == .pointer);
    try std.testing.expectEqual(ast.Mutability.mut, pointer_fact.target_ty.kind.pointer.mutability);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR records typed call target facts for raw address calls" {
    const source =
        \\fn read(addr: PAddr) -> u32 {
        \\    unsafe { return raw.load<u32>(addr); }
        \\}
        \\fn pointer(addr: PAddr) -> *mut u32 {
        \\    unsafe { return raw.ptr<u32>(addr); }
        \\}
        \\fn store(addr: PAddr, value: u32) -> void {
        \\    unsafe { raw.store<u32>(addr, value); }
        \\}
        \\fn store_pointer(addr: *mut u32, value: u32) -> void {
        \\    unsafe { raw.store<u32>(addr, value); }
        \\}
        \\fn pause() -> void {
        \\    unsafe { cpu.pause(); }
        \\}
        \\fn fences() -> void {
        \\    fence.full();
        \\    fence.release();
        \\    fence.acquire();
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_raw_address_call_targets.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const read = functionByName(typed_mir, "read").?;
    const pointer = functionByName(typed_mir, "pointer").?;
    const store = functionByName(typed_mir, "store").?;
    const store_pointer = functionByName(typed_mir, "store_pointer").?;
    const pause = functionByName(typed_mir, "pause").?;
    const fences = functionByName(typed_mir, "fences").?;
    try std.testing.expectEqual(@as(usize, 1), read.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.raw_load, read.call_target_facts[0].kind);
    try std.testing.expectEqualStrings("u32", read.call_target_facts[0].result_ty.name());
    try std.testing.expectEqual(@as(usize, 1), pointer.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.raw_ptr, pointer.call_target_facts[0].kind);
    try std.testing.expectEqualStrings("*mut", pointer.call_target_facts[0].result_ty.name());
    try std.testing.expectEqual(@as(usize, 1), store.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.raw_store, store.call_target_facts[0].kind);
    try std.testing.expectEqualStrings("void", store.call_target_facts[0].result_ty.name());
    for ([_]mir.Function{ read, pointer, store }) |function| {
        const raw_address = targetTypeFactByKind(function, .raw_address) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("PAddr", raw_address.target_ty.kind.name.text);
        const raw_payload = targetTypeFactByKind(function, .raw_payload) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("u32", raw_payload.target_ty.kind.name.text);
        try std.testing.expect(targetTypeFactByKind(function, .raw_result) != null);
    }
    try std.testing.expectEqualStrings("u32", (targetTypeFactByKind(read, .raw_result) orelse return error.TestUnexpectedResult).target_ty.kind.name.text);
    try std.testing.expectEqualStrings("u32", (targetTypeFactByKind(pointer, .raw_result) orelse return error.TestUnexpectedResult).target_ty.kind.pointer.child.kind.name.text);
    try std.testing.expectEqualStrings("void", (targetTypeFactByKind(store, .raw_result) orelse return error.TestUnexpectedResult).target_ty.kind.name.text);
    try std.testing.expect(targetTypeFactByKind(store_pointer, .paddr_coercion_source) != null);
    try std.testing.expectEqual(@as(usize, 1), pause.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.cpu_pause, pause.call_target_facts[0].kind);
    try std.testing.expectEqualStrings("void", pause.call_target_facts[0].result_ty.name());
    try std.testing.expectEqual(@as(usize, 3), fences.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.fence_full, fences.call_target_facts[0].kind);
    try std.testing.expectEqual(mir.CallTargetKind.fence_release, fences.call_target_facts[1].kind);
    try std.testing.expectEqual(mir.CallTargetKind.fence_acquire, fences.call_target_facts[2].kind);
    try mir.validateCallTargetFactsForLowering(typed_mir);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR owns complete varargs cursor payload and result types" {
    const source =
        \\export fn sum_args(count: i32, ...) -> i64 {
        \\    var ap: va_list = va.start();
        \\    var value: i64 = 0;
        \\    unsafe { value = va.arg<i64>(&ap); }
        \\    va.end(&ap);
        \\    return value + (count as i64);
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_varargs_call_targets.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "sum_args").?;
    try std.testing.expectEqual(@as(usize, 3), function.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.va_start, function.call_target_facts[0].kind);
    try std.testing.expectEqual(mir.CallTargetKind.va_arg, function.call_target_facts[1].kind);
    try std.testing.expectEqual(mir.CallTargetKind.va_end, function.call_target_facts[2].kind);
    var cursor_count: usize = 0;
    var payload_count: usize = 0;
    var va_list_result_count: usize = 0;
    var i64_result_count: usize = 0;
    var void_result_count: usize = 0;
    for (function.target_type_facts) |fact| switch (fact.kind) {
        .va_cursor => {
            cursor_count += 1;
            try std.testing.expectEqual(ast.Mutability.mut, fact.target_ty.kind.pointer.mutability);
            try std.testing.expectEqualStrings("va_list", fact.target_ty.kind.pointer.child.kind.name.text);
        },
        .va_payload => {
            payload_count += 1;
            try std.testing.expectEqualStrings("i64", fact.target_ty.kind.name.text);
        },
        .va_result => {
            const name = fact.target_ty.kind.name.text;
            if (std.mem.eql(u8, name, "va_list")) va_list_result_count += 1;
            if (std.mem.eql(u8, name, "i64")) i64_result_count += 1;
            if (std.mem.eql(u8, name, "void")) void_result_count += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), cursor_count);
    try std.testing.expectEqual(@as(usize, 1), payload_count);
    try std.testing.expectEqual(@as(usize, 1), va_list_result_count);
    try std.testing.expectEqual(@as(usize, 1), i64_result_count);
    try std.testing.expectEqual(@as(usize, 1), void_result_count);
    try mir.validateCallTargetFactsForLowering(typed_mir);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
}

test "MIR verifier reports no_lang_trap, fallthrough, contract, and irq findings" {
    const source =
        \\fn missing_return(flag: bool) -> u32 {
        \\    if let value = null {
        \\        return 1;
        \\    }
        \\}
        \\
        \\#[no_lang_trap]
        \\fn checked_add(a: u32, b: u32) -> u32 {
        \\    return a + b;
        \\}
        \\
        \\fn blocking() -> void {}
        \\
        \\#[irq_context]
        \\fn irq_entry() -> void {
        \\    blocking();
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_verify.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    try mir.verifyFromDecls(std.testing.allocator, module.decls, &reporter);

    var found_missing_return = false;
    var found_no_lang_trap = false;
    var found_irq = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_RETURN_MISSING") != null) found_missing_return = true;
        if (std.mem.indexOf(u8, diag.message, "E_NO_LANG_TRAP_EDGE") != null) found_no_lang_trap = true;
        if (std.mem.indexOf(u8, diag.message, "E_IRQ_CONTEXT_CALL") != null) found_irq = true;
    }
    try std.testing.expect(found_missing_return);
    try std.testing.expect(found_no_lang_trap);
    try std.testing.expect(found_irq);
}

test "MIR verifier requires matching unsafe contract kind" {
    const source =
        \\fn wrong_overflow_contract(a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        return unchecked.add(a, b);
        \\    }
        \\}
        \\
        \\fn wrong_noalias_contract(p: *mut u8, n: usize) -> *mut u8 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return compiler.assume_noalias_unchecked(p, n);
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_contract_kind.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    try mir.verifyFromDecls(std.testing.allocator, module.decls, &reporter);

    var count: usize = 0;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_UNCHECKED_OUTSIDE_CONTRACT") != null) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "MIR verifier reports strict unsafe effects outside unsafe blocks" {
    const source =
        \\extern mmio struct Uart16550 {
        \\    thr: Reg<u8, .write>,
        \\}
        \\
        \\fn reject_raw_store(addr: PAddr, value: u64) -> void {
        \\    raw.store<u64>(addr, value);
        \\}
        \\
        \\fn reject_mmio_map(pa: PAddr) -> void {
        \\    mmio.map<Uart16550>(pa);
        \\}
        \\
        \\fn reject_asm() -> void {
        \\    asm opaque volatile {
        \\        "cli"
        \\    }
        \\}
        \\
        \\fn reject_raw_many_deref(p: [*]mut u8) -> u8 {
        \\    return p.*;
        \\}
        \\
        \\fn accept_unsafe_effects(addr: PAddr, value: u64, pa: PAddr) -> void {
        \\    unsafe {
        \\        raw.store<u64>(addr, value);
        \\        mmio.map<Uart16550>(pa);
        \\        asm opaque volatile {
        \\            "cli"
        \\        }
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_strict_unsafe.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    try mir.verifyFromDecls(std.testing.allocator, module.decls, &reporter);

    var unsafe_required_count: usize = 0;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_UNSAFE_REQUIRED") != null) unsafe_required_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), unsafe_required_count);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFactsFromDecls(std.testing.allocator, module.decls, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_raw_store pass=unsafe finding=unsafe_required detail=raw.store") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_mmio_map pass=unsafe finding=unsafe_required detail=mmio.map") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_asm pass=unsafe finding=unsafe_required detail=asm.opaque") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_raw_many_deref pass=unsafe finding=unsafe_required detail=raw_many.deref") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_unsafe_effects pass=unsafe finding=unsafe_required") == null);
}

test "MIR context verifier handles extern irq callees and ordinary store name" {
    const source =
        \\packed bits UartLsr: u8 {
        \\    tx_empty: bool,
        \\}
        \\
        \\extern mmio struct Uart16550 {
        \\    thr: Reg<u8, .write>,
        \\    lsr: RegBits<u8, UartLsr, .read>,
        \\}
        \\
        \\#[irq_context]
        \\extern fn irq_poll() -> void;
        \\
        \\type IrqCounter = atomic<u32>;
        \\type IrqUart = MmioPtr<Uart16550>;
        \\
        \\fn store() -> void {}
        \\
        \\#[irq_context]
        \\fn accepted_irq() -> void {
        \\    irq_poll();
        \\}
        \\
        \\#[irq_context]
        \\fn accepted_atomic(flag: atomic<u32>, counter: IrqCounter, value: u32) -> void {
        \\    flag.store(value, .release);
        \\    counter.fetch_add(value, .acq_rel);
        \\}
        \\
        \\#[irq_context]
        \\fn accepted_mmio(uart: IrqUart, value: u8) -> void {
        \\    uart.thr.write(value, .release);
        \\    let status = uart.lsr.read(.acquire);
        \\}
        \\
        \\#[irq_context]
        \\fn accepted_builtins(addr: usize, token: u32) -> void {
        \\    unsafe {
        \\        raw.store<u32>(phys(addr), 0);
        \\        forget_unchecked(token);
        \\    }
        \\}
        \\
        \\#[irq_context]
        \\fn rejected_store_name() -> void {
        \\    store();
        \\}
        \\
        \\#[irq_context]
        \\fn rejected_blocking(n: usize, path: u32) -> void {
        \\    lock.acquire();
        \\    heap.alloc(n);
        \\    device.wait_irq();
        \\    fs.read(path);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_irq.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    try mir.verifyFromDecls(std.testing.allocator, module.decls, &reporter);

    var irq_call_count: usize = 0;
    var irq_blocking_count: usize = 0;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_IRQ_CONTEXT_CALL") != null) irq_call_count += 1;
        if (std.mem.indexOf(u8, diag.message, "E_IRQ_CONTEXT_BLOCKING") != null) irq_blocking_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), irq_call_count);
    try std.testing.expectEqual(@as(usize, 4), irq_blocking_count);
    try std.testing.expectEqual(@as(usize, 5), reporter.diagnostics.items.len);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const accepted_mmio_fn = functionByName(typed_mir, "accepted_mmio").?;
    try std.testing.expect(functionHasInstruction(accepted_mmio_fn, .call, "mmio.write"));
    try std.testing.expect(functionHasInstruction(accepted_mmio_fn, .call, "mmio.read"));

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFactsFromDecls(std.testing.allocator, module.decls, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=rejected_store_name pass=context finding=irq_call detail=store") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=rejected_blocking pass=context finding=irq_blocking detail=lock.acquire") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=rejected_blocking pass=context finding=irq_blocking detail=heap.alloc") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=rejected_blocking pass=context finding=irq_blocking detail=device.wait_irq") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=rejected_blocking pass=context finding=irq_blocking detail=fs.read") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accepted_irq pass=context finding=irq_call detail=irq_poll") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accepted_atomic pass=context finding=irq_call") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accepted_mmio pass=context finding=irq_call") == null);
    // Pure builtins (`phys` address-cast as a call-arg, `forget_unchecked` discard) are
    // non-blocking and must NOT be flagged on an irq_context path — the plic.mc regression.
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accepted_builtins pass=context finding=irq_call") == null);
}

test "MIR verifier enforces typed MMIO register access modes" {
    const source =
        \\packed bits Status: u8 {
        \\    ready: bool,
        \\}
        \\
        \\type TxReg = Reg<u8, .write>;
        \\type StatusReg = RegBits<u8, Status, .read>;
        \\
        \\extern mmio struct Uart {
        \\    tx: TxReg,
        \\    status: StatusReg,
        \\    ctrl: Reg<u8, .read_write>,
        \\}
        \\
        \\fn reject_read_write_only(uart: MmioPtr<Uart>) -> u8 {
        \\    return uart.tx.read(.relaxed);
        \\}
        \\
        \\fn reject_write_read_only(uart: MmioPtr<Uart>, value: u8) -> void {
        \\    uart.status.write(value, .relaxed);
        \\}
        \\
        \\fn accept_read_write(uart: MmioPtr<Uart>, value: u8) -> u8 {
        \\    uart.ctrl.write(value, .relaxed);
        \\    return uart.ctrl.read(.relaxed);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_mmio_access.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    const reject_read_fn = functionByName(typed_mir, "reject_read_write_only").?;
    const reject_write_fn = functionByName(typed_mir, "reject_write_read_only").?;
    const accept_fn = functionByName(typed_mir, "accept_read_write").?;
    try std.testing.expect(functionHasInstruction(reject_read_fn, .call, "mmio.read"));
    try std.testing.expect(functionHasInstruction(reject_read_fn, .mmio_check, "read"));
    try std.testing.expect(functionHasInstruction(reject_write_fn, .call, "mmio.write"));
    try std.testing.expect(functionHasInstruction(reject_write_fn, .mmio_check, "write"));
    try std.testing.expect(functionHasInstruction(accept_fn, .call, "mmio.write"));
    try std.testing.expect(functionHasInstruction(accept_fn, .call, "mmio.read"));
    try std.testing.expect(!functionHasInstruction(accept_fn, .mmio_check, "read"));
    try std.testing.expect(!functionHasInstruction(accept_fn, .mmio_check, "write"));

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFactsFromDecls(std.testing.allocator, module.decls, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_read_write_only pass=mmio finding=access_forbidden op=read") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_write_read_only pass=mmio finding=access_forbidden op=write") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_read_write pass=mmio finding=access_forbidden") == null);

    try mir.verifyBuiltMir(typed_mir, &reporter);
    var mmio_errors: usize = 0;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_MMIO_ACCESS_FORBIDDEN") != null) mmio_errors += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), mmio_errors);
}

test "MIR models local callee values as indirect calls" {
    const source =
        \\#[no_lang_trap]
        \\fn reject_indirect_no_lang_trap(callee: u32) -> void {
        \\    callee();
        \\}
        \\
        \\#[irq_context]
        \\fn reject_indirect_irq(callee: u32) -> void {
        \\    callee();
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_indirect_call.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    const no_trap_fn = functionByName(typed_mir, "reject_indirect_no_lang_trap").?;
    const irq_fn = functionByName(typed_mir, "reject_indirect_irq").?;
    try std.testing.expect(functionHasInstruction(no_trap_fn, .indirect_call, "callee"));
    try std.testing.expect(functionHasInstruction(irq_fn, .indirect_call, "callee"));

    try mir.verifyBuiltMir(typed_mir, &reporter);

    var found_no_lang_trap = false;
    var found_irq = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_NO_LANG_TRAP_EDGE") != null) found_no_lang_trap = true;
        if (std.mem.indexOf(u8, diag.message, "E_IRQ_CONTEXT_CALL") != null) found_irq = true;
    }
    try std.testing.expect(found_no_lang_trap);
    try std.testing.expect(found_irq);
}

test "MIR CFG loop control uses explicit jump successors" {
    const source =
        \\fn loop_control(flag: bool) -> void {
        \\    while flag {
        \\        continue;
        \\    }
        \\    while flag {
        \\        break;
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_loop_cfg.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    const function = typed_mir.functions[0];
    var jump_blocks: usize = 0;
    for (function.blocks) |block| {
        for (block.successors) |successor| try std.testing.expect(successor < function.blocks.len);
        switch (block.terminator) {
            .jump => |target| {
                jump_blocks += 1;
                var listed = false;
                for (block.successors) |successor| {
                    if (successor == target) listed = true;
                }
                try std.testing.expect(listed);
            },
            .trap_ => try std.testing.expectEqual(@as(usize, 0), block.successors.len),
            .return_, .unreachable_ => try std.testing.expectEqual(@as(usize, 0), block.successors.len),
            else => {},
        }
    }
    try std.testing.expect(jump_blocks >= 2);
}

test "MIR verifier rejects malformed CFG structure" {
    var instructions = [_]Instruction{};
    var successors = [_]usize{99};
    var trap_edges = [_]TrapEdge{};
    var contract_regions = [_]ContractRegion{};
    var range_facts = [_]RangeFact{};
    var blocks = [_]Block{
        .{
            .id = 0,
            .kind = "entry",
            .instructions = instructions[0..],
            .successors = successors[0..],
            .terminator = .{ .jump = 99 },
        },
    };
    var functions = [_]Function{
        .{
            .name = "bad_cfg",
            .return_ty = .void,
            .no_lang_trap = false,
            .irq_context = false,
            .blocks = blocks[0..],
            .trap_edges = trap_edges[0..],
            .contract_regions = contract_regions[0..],
            .range_facts = range_facts[0..],
            .pointer_provenance_facts = &.{},
            .representation_facts = &.{},
            .elided_bounds = &.{},
        },
    };
    const module = Module{ .allocator = std.testing.allocator, .functions = functions[0..] };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "bad_cfg.mc", "");
    defer reporter.deinit();
    try mir.verifyBuiltMir(module, &reporter);

    try std.testing.expect(reporter.has_errors);
    // DIAGNOSTIC_UNIT: E_MIR_CFG
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, "E_MIR_CFG") != null);
}

test "MIR verifier rejects block id mismatch in CFG" {
    var instructions = [_]Instruction{};
    var successors = [_]usize{};
    var trap_edges = [_]TrapEdge{};
    var contract_regions = [_]ContractRegion{};
    var range_facts = [_]RangeFact{};
    var blocks = [_]Block{
        .{
            .id = 7,
            .kind = "entry",
            .instructions = instructions[0..],
            .successors = successors[0..],
            .terminator = .{ .return_ = .void },
        },
    };
    var functions = [_]Function{
        .{
            .name = "bad_block_id",
            .return_ty = .void,
            .no_lang_trap = false,
            .irq_context = false,
            .blocks = blocks[0..],
            .trap_edges = trap_edges[0..],
            .contract_regions = contract_regions[0..],
            .range_facts = range_facts[0..],
            .pointer_provenance_facts = &.{},
            .representation_facts = &.{},
            .elided_bounds = &.{},
        },
    };
    const module = Module{ .allocator = std.testing.allocator, .functions = functions[0..] };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "bad_block_id.mc", "");
    defer reporter.deinit();
    try mir.verifyBuiltMir(module, &reporter);

    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, "E_MIR_CFG") != null);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFactsFromMir(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=bad_block_id pass=cfg finding=malformed_cfg") != null);
}

test "MIR verifier rejects typed successor drift in CFG" {
    var instructions = [_]Instruction{};
    var entry_successors = [_]usize{1};
    var entry_typed_successors = [_]BlockId{BlockId.fromIndex(2)};
    var empty_successors = [_]usize{};
    var trap_edges = [_]TrapEdge{};
    var contract_regions = [_]ContractRegion{};
    var range_facts = [_]RangeFact{};
    var blocks = [_]Block{
        .{
            .id = 0,
            .typed_id = BlockId.fromIndex(0),
            .kind = "entry",
            .instructions = instructions[0..],
            .successors = entry_successors[0..],
            .typed_successors = entry_typed_successors[0..],
            .terminator = .{ .jump = 1 },
        },
        .{
            .id = 1,
            .typed_id = BlockId.fromIndex(1),
            .kind = "target",
            .instructions = instructions[0..],
            .successors = empty_successors[0..],
            .terminator = .{ .return_ = .void },
        },
        .{
            .id = 2,
            .typed_id = BlockId.fromIndex(2),
            .kind = "wrong",
            .instructions = instructions[0..],
            .successors = empty_successors[0..],
            .terminator = .{ .return_ = .void },
        },
    };
    var functions = [_]Function{
        .{
            .name = "bad_typed_successor",
            .return_ty = .void,
            .no_lang_trap = false,
            .irq_context = false,
            .blocks = blocks[0..],
            .trap_edges = trap_edges[0..],
            .contract_regions = contract_regions[0..],
            .range_facts = range_facts[0..],
            .pointer_provenance_facts = &.{},
            .representation_facts = &.{},
            .elided_bounds = &.{},
        },
    };
    const module = Module{ .allocator = std.testing.allocator, .functions = functions[0..] };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "bad_typed_successor.mc", "");
    defer reporter.deinit();
    try mir.verifyBuiltMir(module, &reporter);

    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, "E_MIR_CFG") != null);
}

test "MIR verifier rejects fallthrough successors and trap kind mismatch" {
    var instructions = [_]Instruction{};
    var successors = [_]usize{1};
    var trap_successors = [_]usize{};
    var blocks = [_]Block{
        .{
            .id = 0,
            .kind = "entry",
            .instructions = instructions[0..],
            .successors = successors[0..],
            .terminator = .fallthrough,
        },
        .{
            .id = 1,
            .kind = "trap",
            .instructions = instructions[0..],
            .successors = trap_successors[0..],
            .terminator = .{ .trap_ = .Bounds },
        },
    };
    var trap_edges = [_]TrapEdge{
        .{ .from_block = 0, .trap_block = 1, .kind = .IntegerOverflow, .source = .checked_arithmetic, .line = 1, .column = 1 },
    };
    var contract_regions = [_]ContractRegion{};
    var range_facts = [_]RangeFact{};
    var functions = [_]Function{
        .{
            .name = "bad_cfg",
            .return_ty = .void,
            .no_lang_trap = false,
            .irq_context = false,
            .blocks = blocks[0..],
            .trap_edges = trap_edges[0..],
            .contract_regions = contract_regions[0..],
            .range_facts = range_facts[0..],
            .pointer_provenance_facts = &.{},
            .representation_facts = &.{},
            .elided_bounds = &.{},
        },
    };
    const module = Module{ .allocator = std.testing.allocator, .functions = functions[0..] };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "bad_cfg_2.mc", "");
    defer reporter.deinit();
    try mir.verifyBuiltMir(module, &reporter);

    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, "E_MIR_CFG") != null);
}

test "MIR records no_overflow range facts for unchecked add contract" {
    const source =
        \\fn accumulate(a: u32, b: u32) -> u32 {
        \\    var sum: u32 = a;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        sum = unchecked.add(sum, b);
        \\    }
        \\    return sum;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_range.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    try std.testing.expectEqual(@as(usize, 1), typed_mir.functions[0].range_facts.len);
    const fact = typed_mir.functions[0].range_facts[0];
    try std.testing.expectEqualStrings("sum", fact.target);
    try std.testing.expectEqualStrings("add", fact.op);
    try std.testing.expectEqualStrings("sum", fact.left);
    try std.testing.expectEqualStrings("b", fact.right);
    try std.testing.expectEqualStrings("u32", valueTypeName(fact.result_ty));

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFactsFromDecls(std.testing.allocator, module.decls, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accumulate pass=range finding=no_overflow_range target=sum op=add left=sum right=b") != null);
}

test "MIR records unchecked call identity and operand/result type facts" {
    const source =
        \\fn unchecked_ops(a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)] {
        \\        let sum = unchecked.add(a, b);
        \\        return unchecked.sub(sum, unchecked.mul(a, 1));
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_unchecked_facts.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "unchecked_ops") orelse return error.TestUnexpectedResult;
    try mir.validateCallTargetFactsForLowering(typed_mir);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
    try std.testing.expect(functionHasInstruction(function, .call_target, "unchecked_add"));
    try std.testing.expect(functionHasInstruction(function, .call_target, "unchecked_sub"));
    try std.testing.expect(functionHasInstruction(function, .call_target, "unchecked_mul"));
    try std.testing.expectEqual(@as(usize, 3), countTargetTypeFactsByKind(function, .unchecked_left));
    try std.testing.expectEqual(@as(usize, 3), countTargetTypeFactsByKind(function, .unchecked_right));
    try std.testing.expectEqual(@as(usize, 3), countTargetTypeFactsByKind(function, .unchecked_result));
    try std.testing.expectEqualStrings("u32", typeExprHeadName((targetTypeFactByKind(function, .unchecked_result) orelse return error.TestUnexpectedResult).target_ty).?);
}

test "MIR records wrapping facts through inferred local results" {
    const source =
        \\fn wrapping_ops(a: u32, b: u32) -> u32 {
        \\    let sum = wrapping.add(a, b);
        \\    return wrapping.add(sum, 1);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_wrapping_facts.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "wrapping_ops") orelse return error.TestUnexpectedResult;
    try mir.validateCallTargetFactsForLowering(typed_mir);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
    try std.testing.expectEqual(@as(usize, 2), countTargetTypeFactsByKind(function, .wrapping_left));
    try std.testing.expectEqual(@as(usize, 2), countTargetTypeFactsByKind(function, .wrapping_right));
    try std.testing.expectEqual(@as(usize, 2), countTargetTypeFactsByKind(function, .wrapping_result));
}

test "MIR dump exposes elided bounds facts" {
    const source =
        \\fn read_const_index() -> u32 {
        \\    let arr: [2]u32 = .{ 10, 20 };
        \\    return arr[1];
        \\}
        \\
        \\fn read_const_slice() -> u32 {
        \\    let arr: [3]u32 = .{ 1, 2, 3 };
        \\    let s: []u32 = arr[0..2];
        \\    return s[1];
        \\}
        \\
        \\fn divide_const_nonzero(x: u32) -> u32 {
        \\    return x / 2;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_elided_bounds.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildOptFromDecls(std.testing.allocator, module.decls, .{ .optimize = true });
    defer typed_mir.deinit();

    const index_fn = functionByName(typed_mir, "read_const_index").?;
    const slice_fn = functionByName(typed_mir, "read_const_slice").?;
    const div_fn = functionByName(typed_mir, "divide_const_nonzero").?;
    try std.testing.expect(index_fn.elided_bounds.len >= 1);
    try std.testing.expect(slice_fn.elided_bounds.len >= 1);
    try std.testing.expect(div_fn.elided_bounds.len >= 1);

    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(std.testing.allocator);
    try mir.appendDumpOptFromDecls(std.testing.allocator, module.decls, &dump, .{ .optimize = true });
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir function name=read_const_index") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "elided_bounds=") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir elided_bounds_fact fn=read_const_index check=bounds_elided recorded=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir elided_bounds_fact fn=read_const_slice check=bounds_elided recorded=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir elided_bounds_fact fn=divide_const_nonzero check=bounds_elided recorded=true") != null);
}

test "MIR dump emits non-elided bounds facts" {
    const source =
        \\fn read_at(values: [2]u32, index: usize) -> u32 {
        \\    return values[index];
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_bounds_dump.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(std.testing.allocator);
    try mir.appendDumpFromDecls(std.testing.allocator, module.decls, &dump);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "bounds_facts=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir bounds_fact fn=read_at kind=index recorded=true") != null);
}

test "MIR dump emits target-typed integer literal facts" {
    const source =
        \\extern fn takes_u8(value: u8) -> void;
        \\fn integer_literals() -> u8 {
        \\    let a: u8 = 255;
        \\    takes_u8(0xff);
        \\    return 7;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_integer_literal_facts.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(std.testing.allocator);
    try mir.appendDumpFromDecls(std.testing.allocator, module.decls, &dump);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "integer_facts=6") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir integer_fact fn=integer_literals literal=255 target_type=u8 recorded=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir integer_fact fn=integer_literals literal=0xff target_type=u8 recorded=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir integer_fact fn=integer_literals literal=7 target_type=u8 recorded=true") != null);
}

test "MIR dump exposes representation value identities" {
    const source =
        \\fn return_ptr_param(p: *mut u8) -> *mut u8 {
        \\    return p;
        \\}
        \\
        \\fn read_ptr_param(p: *mut u8) -> u8 {
        \\    return p.*;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_representation_dump.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    const return_fn = functionByName(typed_mir, "return_ptr_param").?;
    const read_fn = functionByName(typed_mir, "read_ptr_param").?;
    const return_p_identity = valueIdentityBySpelling(return_fn, "p").?;
    const read_p_identity = valueIdentityBySpelling(read_fn, "p").?;
    const return_mut_ptr_identity = typeIdentityBySpelling(return_fn, "*mut").?;
    const read_mut_ptr_identity = typeIdentityBySpelling(read_fn, "*mut").?;
    const read_load_span_identity = spanIdentityBySource(read_fn, read_fn.representation_facts[0].source).?;
    try std.testing.expectEqual(@as(usize, 2), return_fn.representation_facts.len);
    try std.testing.expectEqual(.typed_load, return_fn.representation_facts[0].kind);
    try std.testing.expectEqualStrings("p", return_fn.representation_facts[0].detail);
    try std.testing.expectEqualStrings("p", return_fn.representation_facts[0].value_id);
    try std.testing.expect(return_fn.representation_facts[0].typed_result_ty.isValid());
    try std.testing.expect(return_fn.representation_facts[0].typed_result_ty.eql(return_mut_ptr_identity.id));
    try std.testing.expect(return_fn.representation_facts[0].typed_value_id.isValid());
    try std.testing.expect(return_fn.representation_facts[0].typed_value_id.eql(return_p_identity.id));
    try std.testing.expectEqual(.representation_check, return_fn.representation_facts[1].kind);
    try std.testing.expectEqualStrings("nonnull_pointer", return_fn.representation_facts[1].detail);
    try std.testing.expectEqualStrings("p", return_fn.representation_facts[1].value_id);
    try std.testing.expectEqual(return_fn.representation_facts[0].typed_result_ty, return_fn.representation_facts[1].typed_result_ty);
    try std.testing.expectEqual(return_fn.representation_facts[0].typed_value_id, return_fn.representation_facts[1].typed_value_id);
    try std.testing.expectEqual(@as(usize, 3), read_fn.representation_facts.len);
    try std.testing.expectEqual(.typed_load, read_fn.representation_facts[0].kind);
    try std.testing.expectEqualStrings("p", read_fn.representation_facts[0].detail);
    try std.testing.expectEqualStrings("p", read_fn.representation_facts[0].value_id);
    try std.testing.expect(read_fn.representation_facts[0].typed_result_ty.isValid());
    try std.testing.expect(read_fn.representation_facts[0].typed_result_ty.eql(read_mut_ptr_identity.id));
    try std.testing.expect(read_fn.representation_facts[0].typed_value_id.isValid());
    try std.testing.expect(read_fn.representation_facts[0].typed_value_id.eql(read_p_identity.id));
    try std.testing.expect(read_fn.representation_facts[0].typed_span_id.isValid());
    try std.testing.expect(read_fn.representation_facts[0].typed_span_id.eql(read_load_span_identity.id));
    try std.testing.expectEqual(.representation_check, read_fn.representation_facts[1].kind);
    try std.testing.expectEqualStrings("nonnull_pointer", read_fn.representation_facts[1].detail);
    try std.testing.expectEqualStrings("p", read_fn.representation_facts[1].value_id);
    try std.testing.expectEqual(read_fn.representation_facts[0].typed_result_ty, read_fn.representation_facts[1].typed_result_ty);
    try std.testing.expectEqual(read_fn.representation_facts[0].typed_value_id, read_fn.representation_facts[1].typed_value_id);
    try std.testing.expectEqual(.representation_use, read_fn.representation_facts[2].kind);
    try std.testing.expectEqualStrings("deref_base", read_fn.representation_facts[2].detail);
    try std.testing.expectEqualStrings("p", read_fn.representation_facts[2].value_id);
    try std.testing.expectEqual(read_fn.representation_facts[0].typed_result_ty, read_fn.representation_facts[2].typed_result_ty);
    try std.testing.expectEqual(read_fn.representation_facts[0].typed_value_id, read_fn.representation_facts[2].typed_value_id);
    for (read_fn.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.value_id) |value_id| if (std.mem.eql(u8, value_id, "p")) {
            try std.testing.expect(instruction.typed_value_id != null);
            try std.testing.expect(instruction.typed_result_ty.isValid());
            try std.testing.expect(instruction.typed_span_id.isValid());
            try std.testing.expectEqual(read_fn.representation_facts[0].typed_result_ty, instruction.typed_result_ty);
            try std.testing.expectEqual(read_fn.representation_facts[0].typed_value_id, instruction.typed_value_id.?);
        };
    };

    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(std.testing.allocator);
    try mir.appendDumpFromDecls(std.testing.allocator, module.decls, &dump);

    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir instr fn=return_ptr_param") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir type_identity fn=return_ptr_param id=") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir value_identity fn=return_ptr_param id=0 spelling=p") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "representation_facts=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "kind=typed_load detail=p type=*mut value_id=p") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "kind=representation_check detail=nonnull_pointer type=*mut value_id=p") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir instr fn=read_ptr_param") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir type_identity fn=read_ptr_param id=") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir span_identity fn=read_ptr_param id=") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "spelling=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir value_identity fn=read_ptr_param id=0 spelling=p") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "kind=representation_use detail=deref_base type=*mut value_id=p") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir representation_fact fn=return_ptr_param kind=typed_load detail=p type=*mut value_id=p recorded=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir representation_fact fn=return_ptr_param kind=representation_check detail=nonnull_pointer type=*mut value_id=p recorded=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir representation_fact fn=read_ptr_param kind=representation_use detail=deref_base type=*mut value_id=p recorded=true") != null);
    const expected_repr_result = try std.fmt.allocPrint(std.testing.allocator, "typed_result_ty_id={}", .{read_fn.representation_facts[0].typed_result_ty.index()});
    defer std.testing.allocator.free(expected_repr_result);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, expected_repr_result) != null);
    const expected_repr_value = try std.fmt.allocPrint(std.testing.allocator, "typed_value_id={}", .{read_fn.representation_facts[0].typed_value_id.index()});
    defer std.testing.allocator.free(expected_repr_value);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, expected_repr_value) != null);
    const expected_repr_span = try std.fmt.allocPrint(std.testing.allocator, "typed_span_id={}", .{read_fn.representation_facts[0].typed_span_id.index()});
    defer std.testing.allocator.free(expected_repr_span);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, expected_repr_span) != null);
}

test "MIR representation admission rejects typed span identity drift" {
    const source =
        \\fn read_ptr_param(p: *mut u8) -> u8 {
        \\    return p.*;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_representation_typed_span_drift.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    var read_fn = functionByNameMut(&typed_mir, "read_ptr_param").?;
    try std.testing.expect(read_fn.representation_facts.len > 0);
    read_fn.representation_facts[0].typed_span_id = SpanId.fromIndex(4096);
    try std.testing.expectError(error.InvalidMirRepresentationFacts, mir.validateRepresentationFactsForLowering(typed_mir));
}

test "MIR representation admission rejects typed result type drift" {
    const source =
        \\fn read_ptr_param(p: *mut u8) -> u8 {
        \\    return p.*;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_representation_typed_type_drift.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    var read_fn = functionByNameMut(&typed_mir, "read_ptr_param").?;
    try std.testing.expect(read_fn.representation_facts.len > 0);
    read_fn.representation_facts[0].typed_result_ty = TypeId.fromIndex(4096);
    try std.testing.expectError(error.InvalidMirRepresentationFacts, mir.validateRepresentationFactsForLowering(typed_mir));
}

test "MIR representation admission requires typed result identity" {
    const source =
        \\fn read_ptr_param(p: *mut u8) -> u8 {
        \\    return p.*;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_representation_requires_typed_type.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    var read_fn = functionByNameMut(&typed_mir, "read_ptr_param").?;
    try std.testing.expect(read_fn.representation_facts.len > 0);
    const fact = &read_fn.representation_facts[0];
    for (read_fn.blocks) |*block| {
        for (block.instructions) |*instruction| {
            if (instruction.kind != fact.kind) continue;
            if (!std.mem.eql(u8, instruction.detail, fact.detail)) continue;
            instruction.typed_result_ty = .invalid;
            fact.typed_result_ty = .invalid;
            try std.testing.expectError(error.InvalidMirRepresentationFacts, mir.validateRepresentationFactsForLowering(typed_mir));
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "MIR representation admission rejects typed value identity drift" {
    const source =
        \\fn read_ptr_param(p: *mut u8) -> u8 {
        \\    return p.*;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_representation_typed_value_drift.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    var read_fn = functionByNameMut(&typed_mir, "read_ptr_param").?;
    try std.testing.expect(read_fn.representation_facts.len > 0);
    read_fn.representation_facts[0].typed_value_id = ValueId.fromIndex(4096);
    try std.testing.expectError(error.InvalidMirRepresentationFacts, mir.validateRepresentationFactsForLowering(typed_mir));
}

test "MIR records typed pointer provenance facts for direct globals and pointer arrays" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, ptrs: [2]*mut u32 }
        \\struct Inner { ptr: *mut u32, ptrs: [2]*mut u32 }
        \\struct Outer { inner: Inner }
        \\
        \\fn direct_pointer_and_array() {
        \\    var local: u32 = 1;
        \\    let p: *mut u32 = &shared_counter;
        \\    var q: *mut u32 = &local;
        \\    let noalias_global: *mut u32 = compiler.assume_noalias_unchecked(&shared_counter, 4);
        \\    var noalias_assigned: *mut u32 = &local;
        \\    noalias_assigned = compiler.assume_noalias_unchecked(&shared_counter, 4);
        \\    let noalias_local: *mut u32 = compiler.assume_noalias_unchecked(&local, 4);
        \\    var ptrs: [2]*mut u32 = .{ &local, &shared_counter };
        \\    let global_alias: *mut u32 = &shared_counter;
        \\    let copied_ptrs: [2]*mut u32 = .{ global_alias, &shared_counter };
        \\    let from_copied_array_literal: *mut u32 = copied_ptrs[0];
        \\    ptrs[0] = &shared_counter;
        \\    let from_global_element: *mut u32 = ptrs[1];
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        let noalias_from_global_element: *mut u32 = compiler.assume_noalias_unchecked(ptrs[1], 4);
        \\    }
        \\    var assigned_from_global_element: *mut u32 = &local;
        \\    assigned_from_global_element = ptrs[0];
        \\    var holder: Holder = .{ .ptr = &local, .ptrs = .{ &local, &shared_counter } };
        \\    holder.ptr = &shared_counter;
        \\    let from_global_field: *mut u32 = holder.ptr;
        \\    holder.ptrs[0] = &shared_counter;
        \\    let from_global_field_element: *mut u32 = holder.ptrs[0];
        \\    let from_literal_field_element: *mut u32 = holder.ptrs[1];
        \\    let copied_holder: Holder = holder;
        \\    let from_copied_field: *mut u32 = copied_holder.ptr;
        \\    let from_copied_field_element: *mut u32 = copied_holder.ptrs[0];
        \\    var assigned_holder: Holder = .{ .ptr = &local, .ptrs = .{ &local, &local } };
        \\    assigned_holder = holder;
        \\    let from_assigned_copy_field: *mut u32 = assigned_holder.ptr;
        \\    let from_assigned_copy_field_element: *mut u32 = assigned_holder.ptrs[0];
        \\    var outer: Outer = .{ .inner = .{ .ptr = &local, .ptrs = .{ &local, &shared_counter } } };
        \\    outer.inner.ptr = &shared_counter;
        \\    let from_nested_field: *mut u32 = outer.inner.ptr;
        \\    outer.inner.ptrs[0] = &shared_counter;
        \\    let from_nested_field_element: *mut u32 = outer.inner.ptrs[0];
        \\    let copied_outer: Outer = outer;
        \\    let from_copied_nested_field: *mut u32 = copied_outer.inner.ptr;
        \\    let from_copied_nested_field_element: *mut u32 = copied_outer.inner.ptrs[0];
        \\    var assigned_outer: Outer = .{ .inner = .{ .ptr = &local, .ptrs = .{ &local, &local } } };
        \\    assigned_outer = outer;
        \\    let from_assigned_nested_field: *mut u32 = assigned_outer.inner.ptr;
        \\    let from_assigned_nested_field_element: *mut u32 = assigned_outer.inner.ptrs[0];
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_pointer_provenance.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    const function = functionByName(typed_mir, "direct_pointer_and_array").?;
    try std.testing.expect(hasPointerProvenanceFact(function, "p", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "q", null, .local_storage, .none, "local"));
    try std.testing.expect(hasPointerProvenanceFact(function, "noalias_global", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "noalias_assigned", null, .global_storage, .reassignment, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "noalias_local", null, .local_storage, .none, "local"));
    try std.testing.expect(hasPointerProvenanceFact(function, "ptrs", 0, .local_storage, .none, "local"));
    try std.testing.expect(hasPointerProvenanceFact(function, "ptrs", 1, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "ptrs", 0, .global_storage, .reassignment, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "copied_ptrs", 0, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "from_copied_array_literal", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "from_global_element", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "noalias_from_global_element", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "assigned_from_global_element", null, .global_storage, .reassignment, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "from_global_field", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "from_global_field_element", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "from_literal_field_element", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "from_copied_field", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "from_copied_field_element", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "from_assigned_copy_field", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "from_assigned_copy_field_element", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "from_nested_field", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "from_nested_field_element", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "from_copied_nested_field", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "from_copied_nested_field_element", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "from_assigned_nested_field", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "from_assigned_nested_field_element", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(function, "holder", "ptr", null, .local_storage, .none, "local"));
    try std.testing.expect(hasPointerProvenanceFieldFact(function, "holder", "ptr", null, .global_storage, .reassignment, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(function, "holder", "ptrs", 1, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(function, "holder", "ptrs", 0, .global_storage, .reassignment, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(function, "outer", "inner.ptr", null, .global_storage, .reassignment, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(function, "outer", "inner.ptrs", 0, .global_storage, .reassignment, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(function, "copied_outer", "inner.ptr", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(function, "copied_outer", "inner.ptrs", 0, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(function, "assigned_outer", "inner.ptr", null, .global_storage, .reassignment, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(function, "assigned_outer", "inner.ptrs", 0, .global_storage, .reassignment, "shared_counter"));

    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(std.testing.allocator);
    try mir.appendDumpFromDecls(std.testing.allocator, module.decls, &dump);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir function name=direct_pointer_and_array symbol_id=") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "return=void no_lang_trap=false irq_context=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "pointer_provenance_facts=") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=direct_pointer_and_array subject=p element=none provenance=global_storage storage=shared_counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=direct_pointer_and_array subject=noalias_global element=none provenance=global_storage storage=shared_counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=direct_pointer_and_array subject=noalias_assigned element=none provenance=global_storage storage=shared_counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=direct_pointer_and_array subject=ptrs element=0 provenance=global_storage storage=shared_counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=direct_pointer_and_array subject=from_global_element element=none provenance=global_storage storage=shared_counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=direct_pointer_and_array subject=assigned_from_global_element element=none provenance=global_storage storage=shared_counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=direct_pointer_and_array subject=from_global_field element=none provenance=global_storage storage=shared_counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=direct_pointer_and_array subject=from_global_field_element element=none provenance=global_storage storage=shared_counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=direct_pointer_and_array subject=from_literal_field_element element=none provenance=global_storage storage=shared_counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=direct_pointer_and_array subject=from_copied_field element=none provenance=global_storage storage=shared_counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=direct_pointer_and_array subject=from_copied_field_element element=none provenance=global_storage storage=shared_counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=direct_pointer_and_array subject=from_assigned_copy_field element=none provenance=global_storage storage=shared_counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=direct_pointer_and_array subject=from_assigned_copy_field_element element=none provenance=global_storage storage=shared_counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=direct_pointer_and_array subject=from_nested_field element=none provenance=global_storage storage=shared_counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=direct_pointer_and_array subject=from_nested_field_element element=none provenance=global_storage storage=shared_counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=direct_pointer_and_array subject=from_copied_nested_field element=none provenance=global_storage storage=shared_counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=direct_pointer_and_array subject=from_copied_nested_field_element element=none provenance=global_storage storage=shared_counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=direct_pointer_and_array subject=from_assigned_nested_field element=none provenance=global_storage storage=shared_counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=direct_pointer_and_array subject=from_assigned_nested_field_element element=none provenance=global_storage storage=shared_counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=direct_pointer_and_array subject=outer element=none provenance=global_storage storage=shared_counter pointer_kind=single mutability=mut child=u32 field=inner.ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=direct_pointer_and_array subject=outer element=0 provenance=global_storage storage=shared_counter pointer_kind=single mutability=mut child=u32 field=inner.ptrs") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=direct_pointer_and_array subject=copied_outer element=none provenance=global_storage storage=shared_counter pointer_kind=single mutability=mut child=u32 field=inner.ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=direct_pointer_and_array subject=copied_outer element=0 provenance=global_storage storage=shared_counter pointer_kind=single mutability=mut child=u32 field=inner.ptrs") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=direct_pointer_and_array subject=assigned_outer element=none provenance=global_storage storage=shared_counter pointer_kind=single mutability=mut child=u32 field=inner.ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=direct_pointer_and_array subject=assigned_outer element=0 provenance=global_storage storage=shared_counter pointer_kind=single mutability=mut child=u32 field=inner.ptrs") != null);
}

test "MIR records direct aggregate-return pointer facts and excludes legacy shapes" {
    const source =
        \\global shared_counter: u32 = 0;
        \\global other_counter: u32 = 0;
        \\extern fn cleanup() -> void;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\fn cleanup_holder(holder: *mut Holder) -> void {
        \\    holder.*.tag = 0;
        \\}
        \\
        \\fn direct_holder() -> Holder {
        \\    return .{ .ptr = &shared_counter, .tag = 1 };
        \\}
        \\
        \\fn direct_holder_after_noise() -> Holder {
        \\    let noise: u32 = shared_counter;
        \\    return .{ .ptr = &shared_counter, .tag = noise };
        \\}
        \\
        \\fn local_holder() -> Holder {
        \\    let holder: Holder = .{ .ptr = &shared_counter, .tag = 2 };
        \\    return holder;
        \\}
        \\
        \\fn assigned_holder() -> Holder {
        \\    var local: u32 = 3;
        \\    var holder: Holder = .{ .ptr = &local, .tag = 3 };
        \\    holder = .{ .ptr = &shared_counter, .tag = 4 };
        \\    return holder;
        \\}
        \\
        \\fn copied_holder() -> Holder {
        \\    let source: Holder = .{ .ptr = &shared_counter, .tag = 5 };
        \\    let holder: Holder = source;
        \\    return holder;
        \\}
        \\
        \\fn branched_holder(flag: bool) -> Holder {
        \\    if flag { return .{ .ptr = &shared_counter, .tag = 6 }; } else { return .{ .ptr = &shared_counter, .tag = 7 }; }
        \\}
        \\
        \\fn mixed_branched_holder(flag: bool, ptr: *mut u32) -> Holder {
        \\    if flag { return .{ .ptr = &shared_counter, .tag = 8 }; } else { return .{ .ptr = ptr, .tag = 9 }; }
        \\}
        \\fn trailing_holder(choice: u32) -> Holder {
        \\    switch choice {
        \\        0 => { return .{ .ptr = &shared_counter, .tag = 10 }; }
        \\        _ => {}
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 11 };
        \\}
        \\fn trailing_updated_holder(choice: u32) -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 12 };
        \\    switch choice {
        \\        0 => { return .{ .ptr = &shared_counter, .tag = 13 }; }
        \\        _ => { holder = .{ .ptr = &shared_counter, .tag = 14 }; }
        \\    }
        \\    return holder;
        \\}
        \\fn trailing_field_updated_holder(choice: u32) -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 15 };
        \\    switch choice {
        \\        0 => { return .{ .ptr = &shared_counter, .tag = 16 }; }
        \\        _ => { holder.ptr = &shared_counter; }
        \\    }
        \\    return holder;
        \\}
        \\struct ArrayHolder { ptrs: [2]*mut u32 }
        \\fn trailing_array_updated_holder(choice: u32) -> ArrayHolder {
        \\    var holder: ArrayHolder = .{ .ptrs = .{ &shared_counter, &shared_counter } };
        \\    switch choice {
        \\        0 => { return .{ .ptrs = .{ &shared_counter, &shared_counter } }; }
        \\        _ => { holder.ptrs[0] = &shared_counter; }
        \\    }
        \\    return holder;
        \\}
        \\fn trailing_dynamic_array_updated_holder(choice: u32, index: usize) -> ArrayHolder {
        \\    var holder: ArrayHolder = .{ .ptrs = .{ &shared_counter, &shared_counter } };
        \\    switch choice {
        \\        0 => { return .{ .ptrs = .{ &shared_counter, &shared_counter } }; }
        \\        _ => { holder.ptrs[index] = &shared_counter; }
        \\    }
        \\    return holder;
        \\}
        \\fn trailing_mixed_dynamic_array_updated_holder(choice: u32, index: usize) -> ArrayHolder {
        \\    var holder: ArrayHolder = .{ .ptrs = .{ &shared_counter, &other_counter } };
        \\    switch choice {
        \\        0 => { return .{ .ptrs = .{ &shared_counter, &shared_counter } }; }
        \\        _ => { holder.ptrs[index] = &shared_counter; }
        \\    }
        \\    return holder;
        \\}
        \\fn nested_control_holder(choice: u32, flag: bool) -> Holder {
        \\    switch choice {
        \\        0 => {
        \\            if flag { return .{ .ptr = &shared_counter, .tag = 21 }; }
        \\            return .{ .ptr = &shared_counter, .tag = 22 };
        \\        }
        \\        _ => {}
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 23 };
        \\}
        \\fn nested_loop_control_holder(choice: u32, flag: bool) -> Holder {
        \\    switch choice {
        \\        0 => {
        \\            while flag {
        \\                break;
        \\            }
        \\            return .{ .ptr = &shared_counter, .tag = 24 };
        \\        }
        \\        _ => {}
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 25 };
        \\}
        \\fn nested_transparent_switch_control_holder(choice: u32, flag: bool) -> Holder {
        \\    switch choice {
        \\        0 => {
        \\            switch flag {
        \\                true => { let ignored: u32 = 0; }
        \\                false => {}
        \\            }
        \\            return .{ .ptr = &shared_counter, .tag = 26 };
        \\        }
        \\        _ => {}
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 27 };
        \\}
        \\fn nested_transparent_if_let_control_holder(choice: u32, maybe: ?u32) -> Holder {
        \\    switch choice {
        \\        0 => {
        \\            if let value = maybe {
        \\                let ignored: u32 = value;
        \\            }
        \\            return .{ .ptr = &shared_counter, .tag = 28 };
        \\        }
        \\        _ => {}
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 29 };
        \\}
        \\fn nested_call_control_holder(choice: u32) -> Holder {
        \\    switch choice {
        \\        0 => {
        \\            helper();
        \\            return .{ .ptr = &shared_counter, .tag = 30 };
        \\        }
        \\        _ => {}
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 31 };
        \\}
        \\fn nested_mutating_join_holder(choice: u32, inner: u32, ptr: *mut u32) -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 32 };
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
        \\fn nested_if_let_control_holder(choice: u32, maybe: ?u32) -> Holder {
        \\    switch choice {
        \\        0 => {
        \\            if let value = maybe {
        \\                return .{ .ptr = &shared_counter, .tag = value };
        \\            }
        \\            return .{ .ptr = &shared_counter, .tag = 32 };
        \\        }
        \\        _ => {}
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 33 };
        \\}
        \\fn if_let_control_holder(maybe: ?u32) -> Holder {
        \\    if let value = maybe {
        \\        return .{ .ptr = &shared_counter, .tag = value };
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 28 };
        \\}
        \\fn if_let_else_control_holder(maybe: ?u32) -> Holder {
        \\    if let value = maybe {
        \\        return .{ .ptr = &shared_counter, .tag = value };
        \\    } else {
        \\        return .{ .ptr = &shared_counter, .tag = 29 };
        \\    }
        \\}
        \\fn scoped_block_holder() -> Holder {
        \\    {
        \\        let ignored: u32 = shared_counter;
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 29 };
        \\}
        \\fn scoped_block_updated_holder() -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 30 };
        \\    {
        \\        holder.ptr = &shared_counter;
        \\    }
        \\    return holder;
        \\}
        \\fn unsafe_block_holder() -> Holder {
        \\    unsafe {
        \\        let ignored: u32 = shared_counter;
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 31 };
        \\}
        \\fn unsafe_block_updated_holder() -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 32 };
        \\    unsafe {
        \\        holder.ptr = &shared_counter;
        \\    }
        \\    return holder;
        \\}
        \\fn comptime_block_holder() -> Holder {
        \\    comptime {
        \\        assert(1 + 1 == 2);
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 33 };
        \\}
        \\fn assert_prefix_holder(flag: bool) -> Holder {
        \\    assert(flag || !flag);
        \\    return .{ .ptr = &shared_counter, .tag = 34 };
        \\}
        \\fn contract_block_holder() -> Holder {
        \\    var tag: u32 = 35;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        tag = unchecked.add(tag, 0);
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = tag };
        \\}
        \\fn contract_block_local_holder() -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 35 };
        \\    var tag: u32 = 36;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        tag = unchecked.add(tag, 0);
        \\    }
        \\    return holder;
        \\}
        \\fn contract_block_updated_holder() -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 36 };
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        holder.ptr = &shared_counter;
        \\    }
        \\    return holder;
        \\}
        \\fn loop_prefix_holder(flag: bool) -> Holder {
        \\    while flag {
        \\        break;
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 37 };
        \\}
        \\fn transparent_while_prefix_holder(flag: bool) -> Holder {
        \\    while flag {
        \\        let ignored: u32 = 0;
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 38 };
        \\}
        \\fn continue_for_prefix_holder(values: [2]u32) -> Holder {
        \\    for value in values {
        \\        let ignored: u32 = value;
        \\        continue;
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 49 };
        \\}
        \\fn sequential_switch_holder(first: u32, second: u32) -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 39 };
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
        \\fn triple_switch_holder(first: u32, second: u32, third: u32) -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 40 };
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
        \\fn nine_path_switch_holder(first: u32, second: u32) -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 41 };
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
        \\fn path_overflow_switch_holder(first: u32, second: u32, third: u32) -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 42 };
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
        \\fn if_join_holder(flag: bool) -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 43 };
        \\    if flag {
        \\        holder.ptr = &shared_counter;
        \\    }
        \\    return holder;
        \\}
        \\fn all_fallthrough_switch_holder(choice: u32) -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 44 };
        \\    switch choice {
        \\        0 => { holder.ptr = &shared_counter; }
        \\        _ => { holder.ptr = &shared_counter; }
        \\    }
        \\    return holder;
        \\}
        \\fn defer_prefix_holder() -> Holder {
        \\    defer cleanup();
        \\    return .{ .ptr = &shared_counter, .tag = 45 };
        \\}
        \\fn local_defer_prefix_holder() -> Holder {
        \\    let holder: Holder = .{ .ptr = &shared_counter, .tag = 45 };
        \\    defer cleanup();
        \\    return holder;
        \\}
        \\fn local_defer_arg_prefix_holder() -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 45 };
        \\    defer cleanup_holder(&holder);
        \\    return holder;
        \\}
        \\fn defer_expr_prefix_holder() -> Holder {
        \\    let cleanup_value: u32 = 0;
        \\    defer cleanup_value;
        \\    return .{ .ptr = &shared_counter, .tag = 46 };
        \\}
        \\fn for_prefix_holder(values: [2]u32) -> Holder {
        \\    for value in values {
        \\        let ignored: u32 = value;
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 46 };
        \\}
        \\fn mutating_for_prefix_holder(values: [2]u32) -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 47 };
        \\    for value in values {
        \\        holder.tag = value;
        \\    }
        \\    return holder;
        \\}
        \\fn scalar_mutating_for_local_holder(values: [2]u32) -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 47 };
        \\    var tag: u32 = 0;
        \\    for value in values {
        \\        tag = value;
        \\    }
        \\    return holder;
        \\}
        \\fn mutating_while_prefix_holder(flag: bool) -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 48 };
        \\    while flag {
        \\        holder.tag = 49;
        \\    }
        \\    return holder;
        \\}
        \\fn pointer_mutating_while_prefix_holder(flag: bool) -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 48 };
        \\    while flag {
        \\        holder.ptr = &shared_counter;
        \\    }
        \\    return holder;
        \\}
        \\fn mixed_pointer_mutating_while_prefix_holder(flag: bool) -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 48 };
        \\    while flag {
        \\        holder.ptr = &other_counter;
        \\    }
        \\    return holder;
        \\}
        \\fn scalar_mutating_while_local_holder(flag: bool) -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 48 };
        \\    var tag: u32 = 0;
        \\    while flag {
        \\        tag = 49;
        \\        break;
        \\    }
        \\    return holder;
        \\}
        \\fn trailing_nested_field_updated_holder(choice: u32) -> Outer {
        \\    var holder: Outer = .{ .inner = .{ .ptr = &shared_counter, .ptrs = .{ &shared_counter, &shared_counter } }, .tag = 17 };
        \\    switch choice {
        \\        0 => { return .{ .inner = .{ .ptr = &shared_counter, .ptrs = .{ &shared_counter, &shared_counter } }, .tag = 18 }; }
        \\        _ => { holder.inner.ptr = &shared_counter; }
        \\    }
        \\    return holder;
        \\}
        \\struct Leaf { ptr: *mut u32 }
        \\struct Middle { leaf: Leaf }
        \\struct DeepOuter { middle: Middle }
        \\fn trailing_deep_nested_field_updated_holder(choice: u32) -> DeepOuter {
        \\    var holder: DeepOuter = .{ .middle = .{ .leaf = .{ .ptr = &shared_counter } } };
        \\    switch choice {
        \\        0 => { return .{ .middle = .{ .leaf = .{ .ptr = &shared_counter } } }; }
        \\        _ => { holder.middle.leaf.ptr = &shared_counter; }
        \\    }
        \\    return holder;
        \\}
        \\fn deref_updated_holder() -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 19 };
        \\    let alias: *mut Holder = &holder;
        \\    alias.*.ptr = &shared_counter;
        \\    return holder;
        \\}
        \\
        \\fn helper() -> void {}
        \\fn helper_holder(holder: *mut Holder) -> void {
        \\    holder.*.tag = 0;
        \\}
        \\fn call_before_return() -> Holder {
        \\    let holder: Holder = .{ .ptr = &shared_counter, .tag = 5 };
        \\    helper();
        \\    return holder;
        \\}
        \\fn call_arg_before_return() -> Holder {
        \\    var holder: Holder = .{ .ptr = &shared_counter, .tag = 5 };
        \\    helper_holder(&holder);
        \\    return holder;
        \\}
        \\
        \\fn call_before_literal_return() -> Holder {
        \\    helper();
        \\    return .{ .ptr = &shared_counter, .tag = 6 };
        \\}
        \\
        \\fn unknown_holder(ptr: *mut u32) -> Holder {
        \\    return .{ .ptr = ptr, .tag = 3 };
        \\}
        \\
        \\fn local_only_holder() -> Holder {
        \\    var local: u32 = 4;
        \\    return .{ .ptr = &local, .tag = 4 };
        \\}
        \\
        \\export fn exported_holder() -> Holder {
        \\    return .{ .ptr = &shared_counter, .tag = 20 };
        \\}
        \\
        \\struct PointerArrayHolder { ptrs: [2]*mut u32 }
        \\fn pointer_array_holder() -> PointerArrayHolder {
        \\    return .{ .ptrs = .{ &shared_counter, &shared_counter } };
        \\}
        \\struct Inner { ptr: *mut u32, ptrs: [2]*mut u32 }
        \\struct Outer { inner: Inner, tag: u32 }
        \\fn nested_holder() -> Outer {
        \\    return .{ .inner = .{ .ptr = &shared_counter, .ptrs = .{ &shared_counter, &shared_counter } }, .tag = 10 };
        \\}
        \\struct Cell { ptr: *mut u32 }
        \\struct CellHolder { cells: [2]Cell }
        \\fn nested_array_holder() -> CellHolder {
        \\    return .{ .cells = .{ .{ .ptr = &shared_counter }, .{ .ptr = &shared_counter } } };
        \\}
        \\struct CellMatrixHolder { groups: [2][2]Cell }
        \\fn cell_matrix_holder() -> CellMatrixHolder {
        \\    return .{ .groups = .{ .{ .{ .ptr = &shared_counter }, .{ .ptr = &shared_counter } }, .{ .{ .ptr = &shared_counter }, .{ .ptr = &shared_counter } } } };
        \\}
        \\struct NestedPointerArrayHolder { ptrs: [2][2]*mut u32 }
        \\fn nested_pointer_array_holder() -> NestedPointerArrayHolder {
        \\    return .{ .ptrs = .{ .{ &shared_counter, &shared_counter }, .{ &shared_counter, &shared_counter } } };
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_aggregate_return_facts.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "direct_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "direct_holder_after_noise"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "local_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "assigned_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "copied_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "branched_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "mixed_branched_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "trailing_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "trailing_updated_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "trailing_field_updated_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "trailing_array_updated_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "trailing_dynamic_array_updated_holder"));
    try std.testing.expect(!hasAggregateReturnSummaryFact(typed_mir, "trailing_mixed_dynamic_array_updated_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "nested_control_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "nested_loop_control_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "nested_transparent_switch_control_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "nested_transparent_if_let_control_holder"));
    try std.testing.expect(!hasAggregateReturnSummaryFact(typed_mir, "nested_call_control_holder"));
    try std.testing.expect(!hasAggregateReturnPointerFact(typed_mir, "nested_mutating_join_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "nested_if_let_control_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "if_let_control_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "if_let_else_control_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "scoped_block_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "scoped_block_updated_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "unsafe_block_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "unsafe_block_updated_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "comptime_block_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "assert_prefix_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "contract_block_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "contract_block_local_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "contract_block_updated_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "loop_prefix_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "transparent_while_prefix_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "continue_for_prefix_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "sequential_switch_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "triple_switch_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "nine_path_switch_holder"));
    try std.testing.expect(!hasAggregateReturnSummaryFact(typed_mir, "path_overflow_switch_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "if_join_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "all_fallthrough_switch_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "defer_prefix_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "local_defer_prefix_holder"));
    try std.testing.expect(!hasAggregateReturnSummaryFact(typed_mir, "local_defer_arg_prefix_holder"));
    try std.testing.expect(!hasAggregateReturnSummaryFact(typed_mir, "defer_expr_prefix_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "for_prefix_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "mutating_for_prefix_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "scalar_mutating_for_local_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "mutating_while_prefix_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "pointer_mutating_while_prefix_holder"));
    try std.testing.expect(!hasAggregateReturnSummaryFact(typed_mir, "mixed_pointer_mutating_while_prefix_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "scalar_mutating_while_local_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "trailing_nested_field_updated_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "trailing_deep_nested_field_updated_holder"));
    try std.testing.expect(!hasAggregateReturnSummaryFact(typed_mir, "deref_updated_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "unknown_holder"));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "direct_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "direct_holder_after_noise", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "local_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "assigned_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "copied_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "branched_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "nested_control_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "nested_loop_control_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "nested_transparent_switch_control_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "nested_transparent_if_let_control_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "nested_if_let_control_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "if_let_control_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "if_let_else_control_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "trailing_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "trailing_updated_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "trailing_field_updated_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "trailing_array_updated_holder", "ptrs[0]", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "trailing_dynamic_array_updated_holder", "ptrs[0]", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "trailing_dynamic_array_updated_holder", "ptrs[1]", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "scoped_block_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "scoped_block_updated_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "unsafe_block_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "unsafe_block_updated_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "comptime_block_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "assert_prefix_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "contract_block_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "contract_block_local_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "contract_block_updated_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "defer_prefix_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "local_defer_prefix_holder", "ptr", .global_storage));
    try std.testing.expect(!hasAggregateReturnPointerFact(typed_mir, "defer_expr_prefix_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "loop_prefix_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "sequential_switch_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "triple_switch_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "nine_path_switch_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "if_join_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "all_fallthrough_switch_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "for_prefix_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "continue_for_prefix_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "mutating_for_prefix_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "scalar_mutating_for_local_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "transparent_while_prefix_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "mutating_while_prefix_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "pointer_mutating_while_prefix_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "scalar_mutating_while_local_holder", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "trailing_nested_field_updated_holder", "inner.ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "trailing_deep_nested_field_updated_holder", "middle.leaf.ptr", .global_storage));
    try std.testing.expect(!hasAggregateReturnPointerFact(typed_mir, "mixed_branched_holder", "ptr", .global_storage));
    try std.testing.expect(!hasAggregateReturnPointerFact(typed_mir, "unknown_holder", "ptr", .global_storage));
    try std.testing.expect(!hasAggregateReturnPointerFact(typed_mir, "local_only_holder", "ptr", .global_storage));
    try std.testing.expect(!hasAggregateReturnSummaryFact(typed_mir, "exported_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "call_before_return"));
    try std.testing.expect(!hasAggregateReturnSummaryFact(typed_mir, "call_arg_before_return"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "call_before_literal_return"));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "call_before_literal_return", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "call_before_return", "ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "pointer_array_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "nested_holder"));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "nested_array_holder"));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "pointer_array_holder", "ptrs[0]", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "pointer_array_holder", "ptrs[1]", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "nested_holder", "inner.ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "nested_holder", "inner.ptrs[0]", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "nested_array_holder", "cells[0].ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "nested_array_holder", "cells[1].ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "cell_matrix_holder"));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "cell_matrix_holder", "groups[0][0].ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "cell_matrix_holder", "groups[1][1].ptr", .global_storage));
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "nested_pointer_array_holder"));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "nested_pointer_array_holder", "ptrs[0][0]", .global_storage));
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "nested_pointer_array_holder", "ptrs[1][1]", .global_storage));

    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(std.testing.allocator);
    try mir.appendDumpFromDecls(std.testing.allocator, module.decls, &dump);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir aggregate_return_summary_fact callee=direct_holder recorded=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir aggregate_return_pointer_fact callee=direct_holder field=ptr provenance=global_storage pointer_kind=single") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir aggregate_return_pointer_fact callee=pointer_array_holder field=ptrs[0] provenance=global_storage pointer_kind=single") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir aggregate_return_pointer_fact callee=nested_holder field=inner.ptrs[0] provenance=global_storage pointer_kind=single") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir aggregate_return_pointer_fact callee=trailing_deep_nested_field_updated_holder field=middle.leaf.ptr provenance=global_storage pointer_kind=single") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir aggregate_return_pointer_fact callee=nested_array_holder field=cells[0].ptr provenance=global_storage pointer_kind=single") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir aggregate_return_pointer_fact callee=cell_matrix_holder field=groups[0][0].ptr provenance=global_storage pointer_kind=single") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir aggregate_return_pointer_fact callee=nested_pointer_array_holder field=ptrs[0][0] provenance=global_storage pointer_kind=single") != null);
}

test "MIR records direct internal global pointer return provenance in callers" {
    const source =
        \\global shared_counter: u32 = 0;
        \\fn forwarded_global_pointer_twice() -> *mut u32 {
        \\    return forwarded_global_pointer();
        \\}
        \\fn forwarded_global_pointer() -> *mut u32 {
        \\    return returned_global_pointer();
        \\}
        \\extern fn external_pointer() -> *mut u32;
        \\fn forwards_external_pointer() -> *mut u32 {
        \\    return external_pointer();
        \\}
        \\fn recursive_pointer_forward() -> *mut u32 {
        \\    return recursive_pointer_forward();
        \\}
        \\fn noalias_global_pointer() -> *mut u32 {
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        return compiler.assume_noalias_unchecked(&shared_counter, 4);
        \\    }
        \\}
        \\fn local_global_pointer() -> *mut u32 {
        \\    let gp: *mut u32 = &shared_counter;
        \\    return gp;
        \\}
        \\fn assigned_local_global_pointer() -> *mut u32 {
        \\    var gp: *mut u32 = &shared_counter;
        \\    gp = returned_global_pointer();
        \\    return gp;
        \\}
        \\fn mixed_local_pointer(fallback: *mut u32) -> *mut u32 {
        \\    var gp: *mut u32 = &shared_counter;
        \\    gp = fallback;
        \\    return gp;
        \\}
        \\fn malformed_noalias_global_pointer() -> *mut u32 {
        \\    return compiler.assume_noalias_unchecked(&shared_counter);
        \\}
        \\fn returned_global_pointer() -> *mut u32 {
        \\    return &shared_counter;
        \\}
        \\export fn exported_global_pointer() -> *mut u32 {
        \\    return &shared_counter;
        \\}
        \\fn uses_returned_global_pointer() -> u32 {
        \\    let gp: *mut u32 = returned_global_pointer();
        \\    return gp.*;
        \\}
        \\fn uses_exported_global_pointer() -> u32 {
        \\    let p: *mut u32 = exported_global_pointer();
        \\    return p.*;
        \\}
        \\fn uses_callback_pointer_return(producer: fn() -> *mut u32) -> u32 {
        \\    let p: *mut u32 = producer();
        \\    return p.*;
        \\}
        \\fn uses_forwarded_global_pointer() -> u32 {
        \\    let gp: *mut u32 = forwarded_global_pointer_twice();
        \\    return gp.*;
        \\}
        \\fn uses_external_pointer_forward() -> u32 {
        \\    let p: *mut u32 = forwards_external_pointer();
        \\    return p.*;
        \\}
        \\fn uses_recursive_pointer_forward() -> u32 {
        \\    let p: *mut u32 = recursive_pointer_forward();
        \\    return p.*;
        \\}
        \\fn uses_noalias_global_pointer() -> u32 {
        \\    let p: *mut u32 = noalias_global_pointer();
        \\    return p.*;
        \\}
        \\fn uses_local_global_pointer() -> u32 {
        \\    let p: *mut u32 = local_global_pointer();
        \\    return p.*;
        \\}
        \\fn uses_assigned_local_global_pointer() -> u32 {
        \\    let p: *mut u32 = assigned_local_global_pointer();
        \\    return p.*;
        \\}
        \\fn uses_mixed_local_pointer(fallback: *mut u32) -> u32 {
        \\    let p: *mut u32 = mixed_local_pointer(fallback);
        \\    return p.*;
        \\}
        \\fn uses_malformed_noalias_global_pointer() -> u32 {
        \\    let p: *mut u32 = malformed_noalias_global_pointer();
        \\    return p.*;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_pointer_return_provenance.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "uses_returned_global_pointer").?;
    try std.testing.expect(hasPointerProvenanceFact(function, "gp", null, .global_storage, .none, "shared_counter"));
    const exported = functionByName(typed_mir, "uses_exported_global_pointer").?;
    try std.testing.expect(!hasPointerProvenanceFact(exported, "p", null, .global_storage, .none, "shared_counter"));
    const callback = functionByName(typed_mir, "uses_callback_pointer_return").?;
    try std.testing.expect(!hasPointerProvenanceFact(callback, "p", null, .global_storage, .none, "shared_counter"));
    const forwarded = functionByName(typed_mir, "uses_forwarded_global_pointer").?;
    try std.testing.expect(hasPointerProvenanceFact(forwarded, "gp", null, .global_storage, .none, "shared_counter"));
    const external = functionByName(typed_mir, "uses_external_pointer_forward").?;
    try std.testing.expect(!hasPointerProvenanceFact(external, "p", null, .global_storage, .none, "shared_counter"));
    const recursive = functionByName(typed_mir, "uses_recursive_pointer_forward").?;
    try std.testing.expect(!hasPointerProvenanceFact(recursive, "p", null, .global_storage, .none, "shared_counter"));
    const noalias_function = functionByName(typed_mir, "uses_noalias_global_pointer").?;
    try std.testing.expect(hasPointerProvenanceFact(noalias_function, "p", null, .global_storage, .none, "shared_counter"));
    const local_function = functionByName(typed_mir, "uses_local_global_pointer").?;
    try std.testing.expect(hasPointerProvenanceFact(local_function, "p", null, .global_storage, .none, "shared_counter"));
    const assigned_local_function = functionByName(typed_mir, "uses_assigned_local_global_pointer").?;
    try std.testing.expect(hasPointerProvenanceFact(assigned_local_function, "p", null, .global_storage, .none, "shared_counter"));
    const mixed_local_function = functionByName(typed_mir, "uses_mixed_local_pointer").?;
    try std.testing.expect(!hasPointerProvenanceFact(mixed_local_function, "p", null, .global_storage, .none, "shared_counter"));
    const malformed_noalias = functionByName(typed_mir, "uses_malformed_noalias_global_pointer").?;
    try std.testing.expect(!hasPointerProvenanceFact(malformed_noalias, "p", null, .global_storage, .none, "shared_counter"));
}

test "MIR records internal global pointer return provenance through local function aliases" {
    const source =
        \\global shared_counter: u32 = 0;
        \\fn returned_global_pointer() -> *mut u32 {
        \\    return &shared_counter;
        \\}
        \\extern fn unknown_pointer() -> *mut u32;
        \\fn uses_global_pointer_through_alias() -> u32 {
        \\    let producer: fn() -> *mut u32 = returned_global_pointer;
        \\    let gp: *mut u32 = producer();
        \\    return gp.*;
        \\}
        \\fn reassigns_returned_global_pointer_alias() -> u32 {
        \\    var producer: fn() -> *mut u32 = returned_global_pointer;
        \\    producer = unknown_pointer;
        \\    let gp: *mut u32 = producer();
        \\    return gp.*;
        \\}
        \\fn branches_after_returned_global_pointer_alias(flag: bool) -> u32 {
        \\    var producer: fn() -> *mut u32 = returned_global_pointer;
        \\    if flag { producer = unknown_pointer; }
        \\    let gp: *mut u32 = producer();
        \\    return gp.*;
        \\}
        \\fn loops_after_returned_global_pointer_alias(flag: bool) -> u32 {
        \\    let producer: fn() -> *mut u32 = returned_global_pointer;
        \\    while flag {}
        \\    let gp: *mut u32 = producer();
        \\    return gp.*;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_pointer_return_alias_provenance.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const aliased = functionByName(typed_mir, "uses_global_pointer_through_alias").?;
    try std.testing.expect(hasPointerProvenanceFact(aliased, "gp", null, .global_storage, .none, "shared_counter"));
    const reassigned = functionByName(typed_mir, "reassigns_returned_global_pointer_alias").?;
    try std.testing.expect(!hasPointerProvenanceFact(reassigned, "gp", null, .global_storage, .none, "shared_counter"));
    const branched = functionByName(typed_mir, "branches_after_returned_global_pointer_alias").?;
    try std.testing.expect(!hasPointerProvenanceFact(branched, "gp", null, .global_storage, .none, "shared_counter"));
    const looped = functionByName(typed_mir, "loops_after_returned_global_pointer_alias").?;
    try std.testing.expect(!hasPointerProvenanceFact(looped, "gp", null, .global_storage, .none, "shared_counter"));
}

test "MIR joins consistent internal global pointer returns across branches" {
    const source =
        \\global shared_counter: u32 = 0;
        \\fn branched_global_pointer(flag: bool) -> *mut u32 {
        \\    if flag { return &shared_counter; } else { return &shared_counter; }
        \\}
        \\fn mixed_pointer_return(flag: bool, fallback: *mut u32) -> *mut u32 {
        \\    if flag { return &shared_counter; } else { return fallback; }
        \\}
        \\fn uses_branched_global_pointer(flag: bool) -> u32 {
        \\    let gp: *mut u32 = branched_global_pointer(flag);
        \\    return gp.*;
        \\}
        \\fn uses_mixed_pointer_return(flag: bool, fallback: *mut u32) -> u32 {
        \\    let p: *mut u32 = mixed_pointer_return(flag, fallback);
        \\    return p.*;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_branched_pointer_return_provenance.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    const branched = functionByName(typed_mir, "uses_branched_global_pointer").?;
    try std.testing.expect(hasPointerProvenanceFact(branched, "gp", null, .global_storage, .none, "shared_counter"));
    const mixed = functionByName(typed_mir, "uses_mixed_pointer_return").?;
    try std.testing.expect(!hasPointerProvenanceFact(mixed, "p", null, .global_storage, .none, "shared_counter"));
}

test "MIR pointer provenance facts fail closed on reassignment dynamic writes calls and address escape" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, ptrs: [2]*mut u32 }
        \\
        \\fn touch() {}
        \\
        \\fn invalidations(index: usize) {
        \\    var local: u32 = 1;
        \\    var p: *mut u32 = &shared_counter;
        \\    p = p;
        \\    p = &shared_counter;
        \\    touch();
        \\    var q: *mut u32 = &shared_counter;
        \\    let qp: *mut *mut u32 = &q;
        \\    var ptrs: [2]*mut u32 = .{ &shared_counter, &shared_counter };
        \\    ptrs[index] = &local;
        \\    var holder: Holder = .{ .ptr = &shared_counter, .ptrs = .{ &shared_counter, &shared_counter } };
        \\    holder.ptr = &local;
        \\    holder.ptr = q;
        \\    holder.ptrs[index] = &local;
        \\    holder.ptr = &shared_counter;
        \\    touch();
        \\}
        \\
        \\fn absent_computed_pointer(index: usize) {
        \\    var local: u32 = 2;
        \\    let ptrs: [2]*mut u32 = .{ &shared_counter, &local };
        \\    let p: *mut u32 = ptrs[index];
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_pointer_provenance_invalid.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    const invalidations_fn = functionByName(typed_mir, "invalidations").?;
    try std.testing.expect(hasPointerProvenanceFact(invalidations_fn, "p", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(invalidations_fn, "p", null, .unknown, .reassignment, null));
    try std.testing.expect(hasPointerProvenanceFact(invalidations_fn, "p", null, .unknown, .call, null));
    try std.testing.expect(hasPointerProvenanceFact(invalidations_fn, "q", null, .unknown, .address_escape, null));
    try std.testing.expect(hasPointerProvenanceFact(invalidations_fn, "ptrs", null, .unknown, .dynamic_index_write, null));
    try std.testing.expect(hasPointerProvenanceFieldFact(invalidations_fn, "holder", "ptr", null, .unknown, .reassignment, null));
    try std.testing.expect(hasPointerProvenanceFieldFact(invalidations_fn, "holder", "ptrs", 0, .unknown, .dynamic_index_write, null));
    try std.testing.expect(hasPointerProvenanceFieldFact(invalidations_fn, "holder", "ptr", null, .unknown, .call, null));

    const absent_fn = functionByName(typed_mir, "absent_computed_pointer").?;
    try std.testing.expectEqual(@as(usize, 0), countPointerProvenanceFacts(absent_fn, "p", .global_storage));

    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(std.testing.allocator);
    try mir.appendDumpFromDecls(std.testing.allocator, module.decls, &dump);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=invalidations subject=p element=none provenance=unknown storage=none") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "invalidation_reason=call") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "invalidation_reason=address_escape") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "invalidation_reason=dynamic_index_write") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "subject=holder element=0 provenance=unknown storage=none pointer_kind=single mutability=mut child=u32 field=ptrs invalidation_reason=dynamic_index_write") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "subject=holder element=none provenance=unknown storage=none pointer_kind=single mutability=mut child=u32 field=ptr invalidation_reason=call") != null);
}

test "MIR records direct pointer-local copy provenance facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\
        \\fn touch() {}
        \\
        \\fn pointer_local_copy_fact() {
        \\    let p: *mut u32 = &shared_counter;
        \\    let q: *mut u32 = p;
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        let noalias_q: *mut u32 = compiler.assume_noalias_unchecked(p, 4);
        \\    }
        \\    var r: *mut u32 = &shared_counter;
        \\    r = p;
        \\}
        \\
        \\fn pointer_local_copy_fail_closed() {
        \\    var local: u32 = 1;
        \\    let lp: *mut u32 = &local;
        \\    let local_copy: *mut u32 = lp;
        \\    var p: *mut u32 = &shared_counter;
        \\    p = p;
        \\    let self_invalidated_copy: *mut u32 = p;
        \\    let gp: *mut u32 = &shared_counter;
        \\    touch();
        \\    let call_invalidated_copy: *mut u32 = gp;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_pointer_copy_provenance.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    const copy_fn = functionByName(typed_mir, "pointer_local_copy_fact").?;
    try std.testing.expect(hasPointerProvenanceFact(copy_fn, "p", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(copy_fn, "q", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(copy_fn, "noalias_q", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(copy_fn, "r", null, .global_storage, .reassignment, "shared_counter"));

    const fail_closed_fn = functionByName(typed_mir, "pointer_local_copy_fail_closed").?;
    try std.testing.expect(hasPointerProvenanceFact(fail_closed_fn, "lp", null, .local_storage, .none, "local"));
    try std.testing.expectEqual(@as(usize, 0), countPointerProvenanceFacts(fail_closed_fn, "local_copy", .global_storage));
    try std.testing.expect(hasPointerProvenanceFact(fail_closed_fn, "p", null, .unknown, .reassignment, null));
    try std.testing.expectEqual(@as(usize, 0), countPointerProvenanceFacts(fail_closed_fn, "self_invalidated_copy", .global_storage));
    try std.testing.expect(hasPointerProvenanceFact(fail_closed_fn, "gp", null, .unknown, .call, null));
    try std.testing.expectEqual(@as(usize, 0), countPointerProvenanceFacts(fail_closed_fn, "call_invalidated_copy", .global_storage));

    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(std.testing.allocator);
    try mir.appendDumpFromDecls(std.testing.allocator, module.decls, &dump);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=pointer_local_copy_fact subject=q element=none provenance=global_storage storage=shared_counter pointer_kind=single") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=pointer_local_copy_fact subject=noalias_q element=none provenance=global_storage storage=shared_counter pointer_kind=single") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=pointer_local_copy_fact subject=r element=none provenance=global_storage storage=shared_counter pointer_kind=single") != null);
}

test "MIR records fixed pointer-array assignment from pointer-local copy facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\const FIRST_INDEX: usize = 0;
        \\struct ZeroField { value: u8 }
        \\const REFLECT_INDEX: usize = field_offset<ZeroField>(.value);
        \\
        \\fn pointer_array_assignment_from_copy() {
        \\    var local: u32 = 0;
        \\    var ptrs: [2]*mut u32 = .{ &local, &local };
        \\    let gp: *mut u32 = &shared_counter;
        \\    ptrs[FIRST_INDEX] = gp;
        \\    let p: *mut u32 = ptrs[FIRST_INDEX];
        \\    let q: *mut u32 = ptrs[REFLECT_INDEX];
        \\    let r: *mut u32 = ptrs[field_offset<ZeroField>(.value)];
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_pointer_array_assignment_from_copy.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    const function = functionByName(typed_mir, "pointer_array_assignment_from_copy").?;
    try std.testing.expect(hasPointerProvenanceFact(function, "gp", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "ptrs", 0, .global_storage, .reassignment, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "p", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "q", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "r", null, .global_storage, .none, "shared_counter"));
}

test "MIR records aggregate pointer assignments from pointer-local copy facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\const FIRST_INDEX: usize = 0;
        \\struct ZeroField { value: u8 }
        \\const REFLECT_INDEX: usize = field_offset<ZeroField>(.value);
        \\struct Holder { ptr: *mut u32, ptrs: [2]*mut u32 }
        \\struct RawHolder { ptr: [*]mut u32, ptrs: [2][*]mut u32 }
        \\struct Outer { inner: Holder }
        \\struct RawOuter { inner: RawHolder }
        \\
        \\fn aggregate_assignment_from_copy() {
        \\    var local: u32 = 0;
        \\    var holder: Holder = .{ .ptr = &local, .ptrs = .{ &local, &local } };
        \\    let gp: *mut u32 = &shared_counter;
        \\    holder.ptr = gp;
        \\    holder.ptrs[FIRST_INDEX] = gp;
        \\    let p: *mut u32 = holder.ptr;
        \\    let q: *mut u32 = holder.ptrs[FIRST_INDEX];
        \\    let r: *mut u32 = holder.ptrs[REFLECT_INDEX];
        \\    let s: *mut u32 = holder.ptrs[field_offset<ZeroField>(.value)];
        \\}
        \\
        \\fn aggregate_assignment_from_raw_many_zero() {
        \\    unsafe {
        \\        var local: u32 = 0;
        \\        var holder: RawHolder = .{ .ptr = (&local) as [*]mut u32, .ptrs = .{ (&local) as [*]mut u32, (&local) as [*]mut u32 } };
        \\        let gp: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        holder.ptr = gp.offset(0);
        \\        holder.ptrs[0] = gp.offset(0);
        \\        let p: [*]mut u32 = holder.ptr;
        \\        let q: [*]mut u32 = holder.ptrs[0];
        \\    }
        \\}
        \\
        \\fn aggregate_assignment_from_noalias() {
        \\    var local: u32 = 0;
        \\    var holder: Holder = .{ .ptr = &local, .ptrs = .{ &local, &local } };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        holder.ptr = compiler.assume_noalias_unchecked(&shared_counter, 4);
        \\        holder.ptrs[0] = compiler.assume_noalias_unchecked(&shared_counter, 4);
        \\    }
        \\    let p: *mut u32 = holder.ptr;
        \\    let q: *mut u32 = holder.ptrs[0];
        \\}
        \\
        \\fn aggregate_noalias_read_from_fields() {
        \\    var local: u32 = 0;
        \\    let holder: Holder = .{ .ptr = &shared_counter, .ptrs = .{ &shared_counter, &local } };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        let p: *mut u32 = compiler.assume_noalias_unchecked(holder.ptr, 4);
        \\        let q: *mut u32 = compiler.assume_noalias_unchecked(holder.ptrs[0], 4);
        \\        let r: *mut u32 = compiler.assume_noalias_unchecked(holder.ptr, 4) as *mut u32;
        \\        let s: *mut u32 = compiler.assume_noalias_unchecked(holder.ptrs[0], 4) as *mut u32;
        \\    }
        \\}
        \\
        \\fn aggregate_update_from_noalias_reads() {
        \\    var local: u32 = 0;
        \\    let src: Holder = .{ .ptr = &shared_counter, .ptrs = .{ &shared_counter, &local } };
        \\    var dst: Holder = .{ .ptr = &local, .ptrs = .{ &local, &local } };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        dst.ptr = compiler.assume_noalias_unchecked(src.ptr, 4);
        \\        dst.ptrs[0] = compiler.assume_noalias_unchecked(src.ptrs[0], 4);
        \\    }
        \\    let p: *mut u32 = dst.ptr;
        \\    let q: *mut u32 = dst.ptrs[0];
        \\}
        \\
        \\fn aggregate_update_from_casted_noalias_reads() {
        \\    var local: u32 = 0;
        \\    let src: Holder = .{ .ptr = &shared_counter, .ptrs = .{ &shared_counter, &local } };
        \\    var dst: Holder = .{ .ptr = &local, .ptrs = .{ &local, &local } };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        dst.ptr = compiler.assume_noalias_unchecked(src.ptr, 4) as *mut u32;
        \\        dst.ptrs[0] = compiler.assume_noalias_unchecked(src.ptrs[0], 4) as *mut u32;
        \\    }
        \\    let p: *mut u32 = dst.ptr;
        \\    let q: *mut u32 = dst.ptrs[0];
        \\}
        \\
        \\fn nested_aggregate_member_copy_from_noalias() {
        \\    var local: u32 = 0;
        \\    let src: Outer = .{ .inner = .{ .ptr = &shared_counter, .ptrs = .{ &shared_counter, &local } } };
        \\    var dst: Outer = .{ .inner = .{ .ptr = &local, .ptrs = .{ &local, &local } } };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        dst.inner = compiler.assume_noalias_unchecked(src.inner, 4);
        \\    }
        \\    let p: *mut u32 = dst.inner.ptr;
        \\    let q: *mut u32 = dst.inner.ptrs[0];
        \\}
        \\
        \\fn nested_aggregate_member_copy_from_casted_noalias() {
        \\    var local: u32 = 0;
        \\    let src: Outer = .{ .inner = .{ .ptr = &shared_counter, .ptrs = .{ &shared_counter, &local } } };
        \\    var dst: Outer = .{ .inner = .{ .ptr = &local, .ptrs = .{ &local, &local } } };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        dst.inner = compiler.assume_noalias_unchecked(src.inner, 4) as Inner;
        \\    }
        \\    let p: *mut u32 = dst.inner.ptr;
        \\    let q: *mut u32 = dst.inner.ptrs[0];
        \\}
        \\
        \\fn aggregate_literal_from_direct_pointer_expressions() {
        \\    var local: u32 = 0;
        \\    let gp: *mut u32 = &shared_counter;
        \\    let holder: Holder = .{ .ptr = gp, .ptrs = .{ gp, &local } };
        \\    let p: *mut u32 = holder.ptr;
        \\    let q: *mut u32 = holder.ptrs[0];
        \\}
        \\
        \\fn aggregate_copy_from_noalias() {
        \\    let holder: Holder = .{ .ptr = &shared_counter, .ptrs = .{ &shared_counter, &shared_counter } };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        let copied: Holder = compiler.assume_noalias_unchecked(holder, 4);
        \\        let p: *mut u32 = copied.ptr;
        \\        let q: *mut u32 = copied.ptrs[0];
        \\    }
        \\}
        \\
        \\fn aggregate_copy_from_casted_noalias() {
        \\    let holder: Holder = .{ .ptr = &shared_counter, .ptrs = .{ &shared_counter, &shared_counter } };
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        let copied: Holder = compiler.assume_noalias_unchecked(holder, 4) as Holder;
        \\        let p: *mut u32 = copied.ptr;
        \\        let q: *mut u32 = copied.ptrs[0];
        \\    }
        \\}
        \\
        \\fn aggregate_literal_from_raw_many_zero() {
        \\    unsafe {
        \\        var local: u32 = 0;
        \\        let gp: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        let holder: RawHolder = .{ .ptr = gp.offset(0), .ptrs = .{ gp.offset(0), (&local) as [*]mut u32 } };
        \\        let p: [*]mut u32 = holder.ptr;
        \\        let q: [*]mut u32 = holder.ptrs[0];
        \\    }
        \\}
        \\
        \\fn aggregate_literal_from_noalias() {
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        var local: u32 = 0;
        \\        let holder: Holder = .{ .ptr = compiler.assume_noalias_unchecked(&shared_counter, 4), .ptrs = .{ compiler.assume_noalias_unchecked(&shared_counter, 4), &local } };
        \\        let p: *mut u32 = holder.ptr;
        \\        let q: *mut u32 = holder.ptrs[0];
        \\    }
        \\}
        \\
        \\fn aggregate_literal_reassignment_from_direct_pointer_expressions() {
        \\    var local: u32 = 0;
        \\    var holder: Holder = .{ .ptr = &local, .ptrs = .{ &local, &local } };
        \\    let gp: *mut u32 = &shared_counter;
        \\    holder = .{ .ptr = gp, .ptrs = .{ gp, &local } };
        \\    let p: *mut u32 = holder.ptr;
        \\    let q: *mut u32 = holder.ptrs[0];
        \\}
        \\
        \\fn aggregate_literal_reassignment_from_raw_many_zero() {
        \\    unsafe {
        \\        var local: u32 = 0;
        \\        var holder: RawHolder = .{ .ptr = (&local) as [*]mut u32, .ptrs = .{ (&local) as [*]mut u32, (&local) as [*]mut u32 } };
        \\        let gp: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        holder = .{ .ptr = gp.offset(0), .ptrs = .{ gp.offset(0), (&local) as [*]mut u32 } };
        \\        let p: [*]mut u32 = holder.ptr;
        \\        let q: [*]mut u32 = holder.ptrs[0];
        \\    }
        \\}
        \\
        \\fn aggregate_literal_reassignment_from_noalias() {
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        var local: u32 = 0;
        \\        var holder: Holder = .{ .ptr = &local, .ptrs = .{ &local, &local } };
        \\        holder = .{ .ptr = compiler.assume_noalias_unchecked(&shared_counter, 4), .ptrs = .{ compiler.assume_noalias_unchecked(&shared_counter, 4), &local } };
        \\        let p: *mut u32 = holder.ptr;
        \\        let q: *mut u32 = holder.ptrs[0];
        \\    }
        \\}
        \\
        \\fn nested_aggregate_literal_reassignment_from_direct_pointer_expressions() {
        \\    var local: u32 = 0;
        \\    var outer: Outer = .{ .inner = .{ .ptr = &local, .ptrs = .{ &local, &local } } };
        \\    let gp: *mut u32 = &shared_counter;
        \\    outer.inner = .{ .ptr = gp, .ptrs = .{ gp, &local } };
        \\    let p: *mut u32 = outer.inner.ptr;
        \\    let q: *mut u32 = outer.inner.ptrs[0];
        \\}
        \\
        \\fn nested_aggregate_literal_reassignment_from_raw_many_zero() {
        \\    unsafe {
        \\        var local: u32 = 0;
        \\        var outer: RawOuter = .{ .inner = .{ .ptr = (&local) as [*]mut u32, .ptrs = .{ (&local) as [*]mut u32, (&local) as [*]mut u32 } } };
        \\        let gp: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        outer.inner = .{ .ptr = gp.offset(0), .ptrs = .{ gp.offset(0), (&local) as [*]mut u32 } };
        \\        let p: [*]mut u32 = outer.inner.ptr;
        \\        let q: [*]mut u32 = outer.inner.ptrs[0];
        \\    }
        \\}
        \\
        \\fn nested_aggregate_literal_reassignment_from_noalias() {
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        var local: u32 = 0;
        \\        var outer: Outer = .{ .inner = .{ .ptr = &local, .ptrs = .{ &local, &local } } };
        \\        outer.inner = .{ .ptr = compiler.assume_noalias_unchecked(&shared_counter, 4), .ptrs = .{ compiler.assume_noalias_unchecked(&shared_counter, 4), &local } };
        \\        let p: *mut u32 = outer.inner.ptr;
        \\        let q: *mut u32 = outer.inner.ptrs[0];
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_aggregate_assignment_from_copy.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    const function = functionByName(typed_mir, "aggregate_assignment_from_copy").?;
    try std.testing.expect(hasPointerProvenanceFact(function, "gp", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(function, "holder", "ptr", null, .global_storage, .reassignment, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(function, "holder", "ptrs", 0, .global_storage, .reassignment, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "p", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "q", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "r", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(function, "s", null, .global_storage, .none, "shared_counter"));

    const raw_function = functionByName(typed_mir, "aggregate_assignment_from_raw_many_zero").?;
    try std.testing.expect(hasPointerProvenanceFact(raw_function, "gp", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(raw_function, "holder", "ptr", null, .global_storage, .reassignment, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(raw_function, "holder", "ptrs", 0, .global_storage, .reassignment, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(raw_function, "p", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(raw_function, "q", null, .global_storage, .none, "shared_counter"));

    const noalias_function = functionByName(typed_mir, "aggregate_assignment_from_noalias").?;
    try std.testing.expect(hasPointerProvenanceFieldFact(noalias_function, "holder", "ptr", null, .global_storage, .reassignment, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(noalias_function, "holder", "ptrs", 0, .global_storage, .reassignment, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(noalias_function, "p", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(noalias_function, "q", null, .global_storage, .none, "shared_counter"));

    const noalias_read_function = functionByName(typed_mir, "aggregate_noalias_read_from_fields").?;
    try std.testing.expect(hasPointerProvenanceFieldFact(noalias_read_function, "holder", "ptr", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(noalias_read_function, "holder", "ptrs", 0, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(noalias_read_function, "p", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(noalias_read_function, "q", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(noalias_read_function, "r", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(noalias_read_function, "s", null, .global_storage, .none, "shared_counter"));

    const noalias_update_function = functionByName(typed_mir, "aggregate_update_from_noalias_reads").?;
    try std.testing.expect(hasPointerProvenanceFieldFact(noalias_update_function, "src", "ptr", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(noalias_update_function, "src", "ptrs", 0, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(noalias_update_function, "dst", "ptr", null, .global_storage, .reassignment, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(noalias_update_function, "dst", "ptrs", 0, .global_storage, .reassignment, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(noalias_update_function, "p", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(noalias_update_function, "q", null, .global_storage, .none, "shared_counter"));

    const casted_noalias_update_function = functionByName(typed_mir, "aggregate_update_from_casted_noalias_reads").?;
    try std.testing.expect(hasPointerProvenanceFieldFact(casted_noalias_update_function, "src", "ptr", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(casted_noalias_update_function, "src", "ptrs", 0, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(casted_noalias_update_function, "dst", "ptr", null, .global_storage, .reassignment, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(casted_noalias_update_function, "dst", "ptrs", 0, .global_storage, .reassignment, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(casted_noalias_update_function, "p", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(casted_noalias_update_function, "q", null, .global_storage, .none, "shared_counter"));

    const noalias_nested_member_copy_function = functionByName(typed_mir, "nested_aggregate_member_copy_from_noalias").?;
    try std.testing.expect(hasPointerProvenanceFieldFact(noalias_nested_member_copy_function, "src", "inner.ptr", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(noalias_nested_member_copy_function, "src", "inner.ptrs", 0, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(noalias_nested_member_copy_function, "dst", "inner.ptr", null, .global_storage, .reassignment, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(noalias_nested_member_copy_function, "dst", "inner.ptrs", 0, .global_storage, .reassignment, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(noalias_nested_member_copy_function, "p", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(noalias_nested_member_copy_function, "q", null, .global_storage, .none, "shared_counter"));

    const casted_noalias_nested_member_copy_function = functionByName(typed_mir, "nested_aggregate_member_copy_from_casted_noalias").?;
    try std.testing.expect(hasPointerProvenanceFieldFact(casted_noalias_nested_member_copy_function, "src", "inner.ptr", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(casted_noalias_nested_member_copy_function, "src", "inner.ptrs", 0, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(casted_noalias_nested_member_copy_function, "dst", "inner.ptr", null, .global_storage, .reassignment, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(casted_noalias_nested_member_copy_function, "dst", "inner.ptrs", 0, .global_storage, .reassignment, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(casted_noalias_nested_member_copy_function, "p", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(casted_noalias_nested_member_copy_function, "q", null, .global_storage, .none, "shared_counter"));

    const literal_function = functionByName(typed_mir, "aggregate_literal_from_direct_pointer_expressions").?;
    try std.testing.expect(hasPointerProvenanceFact(literal_function, "gp", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(literal_function, "holder", "ptr", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(literal_function, "holder", "ptrs", 0, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(literal_function, "p", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(literal_function, "q", null, .global_storage, .none, "shared_counter"));

    const noalias_copy_function = functionByName(typed_mir, "aggregate_copy_from_noalias").?;
    try std.testing.expect(hasPointerProvenanceFieldFact(noalias_copy_function, "copied", "ptr", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(noalias_copy_function, "copied", "ptrs", 0, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(noalias_copy_function, "p", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(noalias_copy_function, "q", null, .global_storage, .none, "shared_counter"));

    const casted_noalias_copy_function = functionByName(typed_mir, "aggregate_copy_from_casted_noalias").?;
    try std.testing.expect(hasPointerProvenanceFieldFact(casted_noalias_copy_function, "copied", "ptr", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(casted_noalias_copy_function, "copied", "ptrs", 0, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(casted_noalias_copy_function, "p", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(casted_noalias_copy_function, "q", null, .global_storage, .none, "shared_counter"));

    const raw_literal_function = functionByName(typed_mir, "aggregate_literal_from_raw_many_zero").?;
    try std.testing.expect(hasPointerProvenanceFact(raw_literal_function, "gp", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(raw_literal_function, "holder", "ptr", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(raw_literal_function, "holder", "ptrs", 0, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(raw_literal_function, "p", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(raw_literal_function, "q", null, .global_storage, .none, "shared_counter"));

    const noalias_literal_function = functionByName(typed_mir, "aggregate_literal_from_noalias").?;
    try std.testing.expect(hasPointerProvenanceFieldFact(noalias_literal_function, "holder", "ptr", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(noalias_literal_function, "holder", "ptrs", 0, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(noalias_literal_function, "p", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(noalias_literal_function, "q", null, .global_storage, .none, "shared_counter"));

    const literal_reassignment_function = functionByName(typed_mir, "aggregate_literal_reassignment_from_direct_pointer_expressions").?;
    try std.testing.expect(hasPointerProvenanceFact(literal_reassignment_function, "gp", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(literal_reassignment_function, "holder", "ptr", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(literal_reassignment_function, "holder", "ptrs", 0, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(literal_reassignment_function, "p", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(literal_reassignment_function, "q", null, .global_storage, .none, "shared_counter"));

    const raw_literal_reassignment_function = functionByName(typed_mir, "aggregate_literal_reassignment_from_raw_many_zero").?;
    try std.testing.expect(hasPointerProvenanceFact(raw_literal_reassignment_function, "gp", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(raw_literal_reassignment_function, "holder", "ptr", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(raw_literal_reassignment_function, "holder", "ptrs", 0, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(raw_literal_reassignment_function, "p", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(raw_literal_reassignment_function, "q", null, .global_storage, .none, "shared_counter"));

    const noalias_literal_reassignment_function = functionByName(typed_mir, "aggregate_literal_reassignment_from_noalias").?;
    try std.testing.expect(hasPointerProvenanceFieldFact(noalias_literal_reassignment_function, "holder", "ptr", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(noalias_literal_reassignment_function, "holder", "ptrs", 0, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(noalias_literal_reassignment_function, "p", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(noalias_literal_reassignment_function, "q", null, .global_storage, .none, "shared_counter"));

    const nested_literal_reassignment_function = functionByName(typed_mir, "nested_aggregate_literal_reassignment_from_direct_pointer_expressions").?;
    try std.testing.expect(hasPointerProvenanceFact(nested_literal_reassignment_function, "gp", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(nested_literal_reassignment_function, "outer", "inner.ptr", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(nested_literal_reassignment_function, "outer", "inner.ptrs", 0, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(nested_literal_reassignment_function, "p", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(nested_literal_reassignment_function, "q", null, .global_storage, .none, "shared_counter"));

    const raw_nested_literal_reassignment_function = functionByName(typed_mir, "nested_aggregate_literal_reassignment_from_raw_many_zero").?;
    try std.testing.expect(hasPointerProvenanceFact(raw_nested_literal_reassignment_function, "gp", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(raw_nested_literal_reassignment_function, "outer", "inner.ptr", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(raw_nested_literal_reassignment_function, "outer", "inner.ptrs", 0, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(raw_nested_literal_reassignment_function, "p", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(raw_nested_literal_reassignment_function, "q", null, .global_storage, .none, "shared_counter"));

    const noalias_nested_literal_reassignment_function = functionByName(typed_mir, "nested_aggregate_literal_reassignment_from_noalias").?;
    try std.testing.expect(hasPointerProvenanceFieldFact(noalias_nested_literal_reassignment_function, "outer", "inner.ptr", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFieldFact(noalias_nested_literal_reassignment_function, "outer", "inner.ptrs", 0, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(noalias_nested_literal_reassignment_function, "p", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(noalias_nested_literal_reassignment_function, "q", null, .global_storage, .none, "shared_counter"));
}

test "MIR records direct local aggregate pointer alias provenance facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, ptrs: [2]*mut u32 }
        \\
        \\fn alias_field_and_element() {
        \\    var local: u32 = 0;
        \\    let holder: Holder = .{ .ptr = &local, .ptrs = .{ &local, &local } };
        \\    let hp: *mut Holder = &holder;
        \\    let p: *mut u32 = hp.ptr;
        \\    let q: *mut u32 = hp.ptrs[0];
        \\}
        \\
        \\fn alias_write_preserves_only_alias_fact() {
        \\    var local: u32 = 0;
        \\    var holder: Holder = .{ .ptr = &shared_counter, .ptrs = .{ &local, &local } };
        \\    let hp: *mut Holder = &holder;
        \\    hp.ptr = &local;
        \\    let alias_read: *mut u32 = hp.ptr;
        \\    let direct_read: *mut u32 = holder.ptr;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_local_aggregate_pointer_alias_provenance.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    const direct = functionByName(typed_mir, "alias_field_and_element").?;
    try std.testing.expect(hasPointerProvenanceFact(direct, "p", null, .local_storage, .none, "local"));
    try std.testing.expect(hasPointerProvenanceFact(direct, "q", null, .local_storage, .none, "local"));

    const written = functionByName(typed_mir, "alias_write_preserves_only_alias_fact").?;
    try std.testing.expect(hasPointerProvenanceFieldFact(written, "holder", "ptr", null, .unknown, .reassignment, null));
    try std.testing.expect(hasPointerProvenanceFieldFact(written, "hp", "ptr", null, .local_storage, .reassignment, "local"));
    try std.testing.expect(hasPointerProvenanceFact(written, "alias_read", null, .local_storage, .none, "local"));
    try std.testing.expect(!hasPointerProvenanceFact(written, "direct_read", null, .local_storage, .none, "local"));
}

test "MIR records direct local pointer-array alias provenance facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\
        \\fn alias_constant_element() {
        \\    var local: u32 = 0;
        \\    var ptrs: [2]*mut u32 = .{ &local, &local };
        \\    let pa: *mut [2]*mut u32 = &ptrs;
        \\    let p: *mut u32 = pa.*[0];
        \\}
        \\
        \\fn alias_write_invalidates_backing_array() {
        \\    var local: u32 = 0;
        \\    var ptrs: [2]*mut u32 = .{ &shared_counter, &shared_counter };
        \\    let pa: *mut [2]*mut u32 = &ptrs;
        \\    pa.*[0] = &local;
        \\    let p: *mut u32 = pa.*[0];
        \\}
        \\
        \\fn alias_reassignment_stays_unproven() {
        \\    var local: u32 = 0;
        \\    var ptrs: [2]*mut u32 = .{ &shared_counter, &shared_counter };
        \\    var other: [2]*mut u32 = .{ &local, &local };
        \\    var pa: *mut [2]*mut u32 = &ptrs;
        \\    pa = &other;
        \\    let p: *mut u32 = pa.*[0];
        \\}
        \\
        \\fn dynamic_alias_all_local(index: usize) {
        \\    var local: u32 = 0;
        \\    var ptrs: [2]*mut u32 = .{ &local, &local };
        \\    let pa: *mut [2]*mut u32 = &ptrs;
        \\    let p: *mut u32 = pa.*[index];
        \\}
        \\
        \\fn dynamic_alias_all_global(index: usize) {
        \\    var ptrs: [2]*mut u32 = .{ &shared_counter, &shared_counter };
        \\    let pa: *mut [2]*mut u32 = &ptrs;
        \\    let p: *mut u32 = pa.*[index];
        \\}
        \\
        \\fn dynamic_alias_mixed(index: usize) {
        \\    var local: u32 = 0;
        \\    var ptrs: [2]*mut u32 = .{ &shared_counter, &local };
        \\    let pa: *mut [2]*mut u32 = &ptrs;
        \\    let p: *mut u32 = pa.*[index];
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_local_pointer_array_alias_provenance.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    const direct = functionByName(typed_mir, "alias_constant_element").?;
    try std.testing.expect(hasPointerProvenanceFact(direct, "p", null, .local_storage, .none, "local"));

    const written = functionByName(typed_mir, "alias_write_invalidates_backing_array").?;
    try std.testing.expect(hasPointerProvenanceFact(written, "ptrs", null, .unknown, .reassignment, null));
    try std.testing.expect(!hasPointerProvenanceFact(written, "p", null, .local_storage, .none, "local"));

    const reassigned = functionByName(typed_mir, "alias_reassignment_stays_unproven").?;
    try std.testing.expect(!hasPointerProvenanceFact(reassigned, "p", null, .local_storage, .none, "local"));

    const all_local = functionByName(typed_mir, "dynamic_alias_all_local").?;
    try std.testing.expect(hasPointerProvenanceFact(all_local, "p", null, .local_storage, .none, "local"));
    const all_global = functionByName(typed_mir, "dynamic_alias_all_global").?;
    try std.testing.expect(hasPointerProvenanceFact(all_global, "p", null, .global_storage, .none, "shared_counter"));
    const mixed = functionByName(typed_mir, "dynamic_alias_mixed").?;
    try std.testing.expect(!hasPointerProvenanceFact(mixed, "p", null, .local_storage, .none, "local"));
    try std.testing.expect(!hasPointerProvenanceFact(mixed, "p", null, .global_storage, .none, "shared_counter"));
}

test "MIR records narrow raw-many zero offset pointer provenance facts" {
    const source =
        \\global shared_counter: u32 = 0;
        \\const ZERO_OFFSET: usize = 0;
        \\struct ZeroField { value: u8 }
        \\const REFLECT_ZERO_OFFSET: usize = field_offset<ZeroField>(.value);
        \\
        \\extern fn external_raw_many_pointer() -> [*]mut u32;
        \\
        \\fn touch() {}
        \\
        \\fn raw_many_zero_fact() {
        \\    unsafe {
        \\        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        let copy: [*]mut u32 = p;
        \\        let q: [*]mut u32 = p.offset(0);
        \\        let r: [*]mut u32 = p.offset(REFLECT_ZERO_OFFSET);
        \\        let s: [*]mut u32 = p.offset(field_offset<ZeroField>(.value));
        \\        let grouped: [*]mut u32 = (p.offset(0));
        \\        let casted: [*]mut u32 = p.offset(0) as [*]mut u32;
        \\        #[unsafe_contract(noalias)]
        \\        {
        \\            let t: [*]mut u32 = compiler.assume_noalias_unchecked(p.offset(0), 4);
        \\        }
        \\    }
        \\}
        \\
        \\fn raw_many_zero_assignment_fact() {
        \\    unsafe {
        \\        var local: u32 = 1;
        \\        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        var q: [*]mut u32 = (&local) as [*]mut u32;
        \\        q = p;
        \\        q = p.offset(ZERO_OFFSET);
        \\        q = (p.offset(0));
        \\        q = p.offset(0) as [*]mut u32;
        \\    }
        \\}
        \\
        \\fn raw_many_zero_fail_closed(i: usize) {
        \\    unsafe {
        \\        var local: u32 = 1;
        \\        let global_p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        let local_p: [*]mut u32 = (&local) as [*]mut u32;
        \\        var q: [*]mut u32 = (&shared_counter) as [*]mut u32;
        \\        q = global_p.offset(1);
        \\        q = global_p.offset(i);
        \\        q = local_p.offset(0);
        \\        q = external_raw_many_pointer().offset(0);
        \\        touch();
        \\        q = global_p.offset(0);
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_raw_many_zero_pointer_provenance.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    const zero_fn = functionByName(typed_mir, "raw_many_zero_fact").?;
    try std.testing.expect(hasPointerProvenanceFact(zero_fn, "p", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(zero_fn, "copy", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(zero_fn, "q", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(zero_fn, "r", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(zero_fn, "s", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(zero_fn, "grouped", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(zero_fn, "casted", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(zero_fn, "t", null, .global_storage, .none, "shared_counter"));

    const assignment_fn = functionByName(typed_mir, "raw_many_zero_assignment_fact").?;
    try std.testing.expect(hasPointerProvenanceFact(assignment_fn, "q", null, .global_storage, .reassignment, "shared_counter"));

    const fail_closed_fn = functionByName(typed_mir, "raw_many_zero_fail_closed").?;
    try std.testing.expect(hasPointerProvenanceFact(fail_closed_fn, "global_p", null, .global_storage, .none, "shared_counter"));
    try std.testing.expect(hasPointerProvenanceFact(fail_closed_fn, "local_p", null, .local_storage, .none, "local"));
    try std.testing.expect(hasPointerProvenanceFact(fail_closed_fn, "q", null, .local_storage, .reassignment, "local"));
    try std.testing.expectEqual(@as(usize, 1), countPointerProvenanceFacts(fail_closed_fn, "q", .global_storage));
    try std.testing.expectEqual(@as(usize, 5), countPointerProvenanceFacts(fail_closed_fn, "q", .unknown));

    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(std.testing.allocator);
    try mir.appendDumpFromDecls(std.testing.allocator, module.decls, &dump);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=raw_many_zero_fact subject=q element=none provenance=global_storage storage=shared_counter pointer_kind=raw_many") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=raw_many_zero_fact subject=t element=none provenance=global_storage storage=shared_counter pointer_kind=raw_many") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=raw_many_zero_assignment_fact subject=q element=none provenance=global_storage storage=shared_counter pointer_kind=raw_many") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=raw_many_zero_fail_closed subject=q element=none provenance=local_storage storage=local pointer_kind=raw_many") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=raw_many_zero_fail_closed subject=q element=none provenance=unknown storage=none pointer_kind=raw_many") != null);
}

test "MIR records every no_overflow operation and rejects unknown operations" {
    const source =
        \\struct Counter {
        \\    next: u32,
        \\}
        \\
        \\fn id(value: u32) -> u32 { return value; }
        \\
        \\fn nested(a: u32, b: u32) -> u32 {
        \\    var sum: u32 = 0;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        sum = id(unchecked.add(a, b));
        \\    }
        \\    return sum;
        \\}
        \\
        \\fn cast_call_arg(a: u32, b: u32) -> u32 {
        \\    var sum: u32 = 0;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        sum = id(unchecked.add(a, b) as u32);
        \\    }
        \\    return sum;
        \\}
        \\
        \\fn grouped_return(a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return (unchecked.add(a, b));
        \\    }
        \\}
        \\
        \\fn cast_return(a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return unchecked.add(a, b) as u32;
        \\    }
        \\}
        \\
        \\fn cast_local(a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let value: u32 = unchecked.add(a, b) as u32;
        \\        return value;
        \\    }
        \\}
        \\
        \\fn cast_inferred_local(a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let inferred = unchecked.add(a, b) as u32;
        \\        return inferred;
        \\    }
        \\}
        \\
        \\fn grouped_assign(a: u32, b: u32) -> u32 {
        \\    var sum: u32 = a;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        sum = (unchecked.mul(sum, b));
        \\    }
        \\    return sum;
        \\}
        \\
        \\fn cast_assign(a: u32, b: u32) -> u32 {
        \\    var sum: u32 = a;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        sum = unchecked.mul(sum, b) as u32;
        \\    }
        \\    return sum;
        \\}
        \\
        \\fn nested_binary(a: u32, b: u32, c: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return (unchecked.add(a, b)) + c;
        \\    }
        \\}
        \\
        \\fn aggregate_array_fact(a: u32, b: u32) -> [1]u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return .{ unchecked.add(a, b) };
        \\    }
        \\}
        \\
        \\fn cast_aggregate_array_fact(a: u32, b: u32) -> [1]u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return .{ unchecked.add(a, b) as u32 };
        \\    }
        \\}
        \\
        \\fn aggregate_field_fact(a: u32, b: u32) -> Counter {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return .{ .next = unchecked.mul(a, b) };
        \\    }
        \\}
        \\
        \\fn cast_aggregate_field_fact(a: u32, b: u32) -> Counter {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return .{ .next = unchecked.mul(a, b) as u32 };
        \\    }
        \\}
        \\
        \\fn known_ops(a: u32, b: u32) -> u32 {
        \\    var sum: u32 = a;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        sum = unchecked.sub(sum, b);
        \\        sum = unchecked.mul(sum, b);
        \\    }
        \\    return sum;
        \\}
        \\
        \\fn nested_ops(a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return unchecked.add(unchecked.add(a, b), unchecked.mul(a, b));
        \\    }
        \\}
        \\
        \\fn unknown_op(a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return unchecked.foo(a, b);
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_range_top_level.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    const nested_fn = functionByName(typed_mir, "nested").?;
    try std.testing.expectEqual(@as(usize, 1), nested_fn.range_facts.len);
    try std.testing.expectEqualStrings("call_arg", nested_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("add", nested_fn.range_facts[0].op);
    const cast_call_arg_fn = functionByName(typed_mir, "cast_call_arg").?;
    try std.testing.expectEqual(@as(usize, 1), cast_call_arg_fn.range_facts.len);
    try std.testing.expectEqualStrings("call_arg", cast_call_arg_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("add", cast_call_arg_fn.range_facts[0].op);
    const grouped_return_fn = functionByName(typed_mir, "grouped_return").?;
    try std.testing.expectEqual(@as(usize, 1), grouped_return_fn.range_facts.len);
    try std.testing.expectEqualStrings("value", grouped_return_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("add", grouped_return_fn.range_facts[0].op);
    try std.testing.expectEqualStrings("u32", valueTypeName(grouped_return_fn.range_facts[0].result_ty));
    const cast_return_fn = functionByName(typed_mir, "cast_return").?;
    try std.testing.expectEqual(@as(usize, 1), cast_return_fn.range_facts.len);
    try std.testing.expectEqualStrings("value", cast_return_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("add", cast_return_fn.range_facts[0].op);
    try std.testing.expectEqualStrings("u32", valueTypeName(cast_return_fn.range_facts[0].result_ty));
    const cast_local_fn = functionByName(typed_mir, "cast_local").?;
    try std.testing.expectEqual(@as(usize, 1), cast_local_fn.range_facts.len);
    try std.testing.expectEqualStrings("value", cast_local_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("add", cast_local_fn.range_facts[0].op);
    try std.testing.expectEqualStrings("u32", valueTypeName(cast_local_fn.range_facts[0].result_ty));
    const cast_inferred_local_fn = functionByName(typed_mir, "cast_inferred_local").?;
    try std.testing.expectEqual(@as(usize, 1), cast_inferred_local_fn.range_facts.len);
    try std.testing.expectEqualStrings("inferred", cast_inferred_local_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("add", cast_inferred_local_fn.range_facts[0].op);
    try std.testing.expectEqualStrings("u32", valueTypeName(cast_inferred_local_fn.range_facts[0].result_ty));
    const grouped_assign_fn = functionByName(typed_mir, "grouped_assign").?;
    try std.testing.expectEqual(@as(usize, 1), grouped_assign_fn.range_facts.len);
    try std.testing.expectEqualStrings("sum", grouped_assign_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("mul", grouped_assign_fn.range_facts[0].op);
    const cast_assign_fn = functionByName(typed_mir, "cast_assign").?;
    try std.testing.expectEqual(@as(usize, 1), cast_assign_fn.range_facts.len);
    try std.testing.expectEqualStrings("sum", cast_assign_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("mul", cast_assign_fn.range_facts[0].op);
    try std.testing.expectEqualStrings("u32", valueTypeName(cast_assign_fn.range_facts[0].result_ty));
    const nested_binary_fn = functionByName(typed_mir, "nested_binary").?;
    try std.testing.expectEqual(@as(usize, 2), nested_binary_fn.range_facts.len);
    var found_nested_binary_operand = false;
    for (nested_binary_fn.range_facts) |fact| {
        if (std.mem.eql(u8, fact.target, "binary_operand") and std.mem.eql(u8, fact.op, "add")) {
            found_nested_binary_operand = true;
            try std.testing.expectEqualStrings("u32", valueTypeName(fact.result_ty));
        }
    }
    try std.testing.expect(found_nested_binary_operand);
    const aggregate_array_fn = functionByName(typed_mir, "aggregate_array_fact").?;
    try std.testing.expectEqual(@as(usize, 2), aggregate_array_fn.range_facts.len);
    try std.testing.expectEqualStrings("aggregate_element", aggregate_array_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("add", aggregate_array_fn.range_facts[0].op);
    try std.testing.expectEqualStrings("u32", valueTypeName(aggregate_array_fn.range_facts[0].result_ty));
    const cast_aggregate_array_fn = functionByName(typed_mir, "cast_aggregate_array_fact").?;
    try std.testing.expectEqual(@as(usize, 2), cast_aggregate_array_fn.range_facts.len);
    try std.testing.expectEqualStrings("aggregate_element", cast_aggregate_array_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("add", cast_aggregate_array_fn.range_facts[0].op);
    try std.testing.expectEqualStrings("u32", valueTypeName(cast_aggregate_array_fn.range_facts[0].result_ty));
    const aggregate_field_fn = functionByName(typed_mir, "aggregate_field_fact").?;
    try std.testing.expectEqual(@as(usize, 2), aggregate_field_fn.range_facts.len);
    try std.testing.expectEqualStrings("next", aggregate_field_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("mul", aggregate_field_fn.range_facts[0].op);
    try std.testing.expectEqualStrings("u32", valueTypeName(aggregate_field_fn.range_facts[0].result_ty));
    const cast_aggregate_field_fn = functionByName(typed_mir, "cast_aggregate_field_fact").?;
    try std.testing.expectEqual(@as(usize, 2), cast_aggregate_field_fn.range_facts.len);
    try std.testing.expectEqualStrings("next", cast_aggregate_field_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("mul", cast_aggregate_field_fn.range_facts[0].op);
    try std.testing.expectEqualStrings("u32", valueTypeName(cast_aggregate_field_fn.range_facts[0].result_ty));
    const known_ops_fn = functionByName(typed_mir, "known_ops").?;
    try std.testing.expectEqual(@as(usize, 2), known_ops_fn.range_facts.len);
    try std.testing.expectEqualStrings("sub", known_ops_fn.range_facts[0].op);
    try std.testing.expectEqualStrings("mul", known_ops_fn.range_facts[1].op);
    const nested_ops_fn = functionByName(typed_mir, "nested_ops").?;
    try std.testing.expectEqual(@as(usize, 3), nested_ops_fn.range_facts.len);
    try std.testing.expectEqualStrings("add", nested_ops_fn.range_facts[0].op);
    try std.testing.expectEqualStrings("add", nested_ops_fn.range_facts[1].op);
    try std.testing.expectEqualStrings("mul", nested_ops_fn.range_facts[2].op);

    try mir.verifyBuiltMir(typed_mir, &reporter);
    var found_unknown = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_UNCHECKED_OUTSIDE_CONTRACT") != null) found_unknown = true;
    }
    try std.testing.expect(found_unknown);
}

test "MIR verifier reports address-class deref and operations" {
    const source =
        \\extern fn make_paddr() -> PAddr;
        \\
        \\fn reject_paddr_deref(pa: PAddr) -> u8 {
        \\    return pa.*;
        \\}
        \\
        \\fn reject_vaddr_deref(va: VAddr) -> u8 {
        \\    return va.*;
        \\}
        \\
        \\fn reject_user_ptr_deref(buf: UserPtr<u8>) -> u8 {
        \\    return buf.*;
        \\}
        \\
        \\fn reject_mmio_ptr_deref(uart: MmioPtr<Uart>) -> Uart {
        \\    return uart.*;
        \\}
        \\
        \\fn reject_dma_addr_deref(addr: DmaAddr) -> u8 {
        \\    return addr.*;
        \\}
        \\
        \\fn reject_phys_ptr_deref(ptr: PhysPtr<Page>) -> Page {
        \\    return ptr.*;
        \\}
        \\
        \\fn reject_call_deref() -> u8 {
        \\    return make_paddr().*;
        \\}
        \\
        \\fn reject_paddr_arithmetic(addr: PAddr, offset: usize) -> PAddr {
        \\    return addr + offset;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_address.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    try mir.verifyFromDecls(std.testing.allocator, module.decls, &reporter);

    const expected = [_][]const u8{
        "E_PADDR_DEREF",
        "E_VADDR_DEREF",
        "E_USER_PTR_DEREF",
        "E_MMIO_PTR_DEREF",
        "E_DMA_ADDR_DEREF",
        "E_PHYS_PTR_DEREF",
        "E_ADDRESS_CLASS_OPERATION",
    };
    for (expected) |code| {
        var found = false;
        for (reporter.diagnostics.items) |diag| {
            if (std.mem.indexOf(u8, diag.message, code) != null) found = true;
        }
        try std.testing.expect(found);
    }

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFactsFromDecls(std.testing.allocator, module.decls, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_paddr_deref pass=address finding=direct_deref class=PAddr") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_call_deref pass=address finding=direct_deref class=PAddr") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_paddr_arithmetic pass=address finding=opaque_operation detail=add") != null);
}

test "MIR verifier reports address-class conversion mismatches" {
    const source =
        \\extern fn takes_paddr(addr: PAddr) -> void;
        \\
        \\fn reject_dma_addr_return(addr: DmaAddr) -> PAddr {
        \\    return addr;
        \\}
        \\
        \\fn reject_dma_addr_as_vaddr(addr: DmaAddr) -> VAddr {
        \\    return addr;
        \\}
        \\
        \\fn reject_paddr_as_vaddr(addr: PAddr) -> VAddr {
        \\    return addr;
        \\}
        \\
        \\fn reject_dma_addr_local(addr: DmaAddr) -> void {
        \\    let pa: PAddr = addr;
        \\}
        \\
        \\fn reject_dma_addr_assignment(addr: DmaAddr, fallback: PAddr) -> void {
        \\    var pa: PAddr = fallback;
        \\    pa = addr;
        \\}
        \\
        \\fn reject_dma_addr_call_arg(addr: DmaAddr) -> void {
        \\    takes_paddr(addr);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_address_conversion.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    try mir.verifyFromDecls(std.testing.allocator, module.decls, &reporter);

    const expected = [_][]const u8{
        "E_DMA_ADDR_NOT_PADDR",
        "E_DMA_ADDR_NOT_VADDR",
        "E_ADDRESS_CLASS_MISMATCH",
    };
    for (expected) |code| {
        var found = false;
        for (reporter.diagnostics.items) |diag| {
            if (std.mem.indexOf(u8, diag.message, code) != null) found = true;
        }
        try std.testing.expect(found);
    }

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFactsFromDecls(std.testing.allocator, module.decls, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_dma_addr_return pass=address finding=address_class_mismatch source=DmaAddr target=PAddr") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_dma_addr_as_vaddr pass=address finding=address_class_mismatch source=DmaAddr target=VAddr") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_paddr_as_vaddr pass=address finding=address_class_mismatch source=PAddr target=VAddr") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_dma_addr_local pass=address finding=address_class_mismatch source=DmaAddr target=PAddr") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_dma_addr_assignment pass=address finding=address_class_mismatch source=DmaAddr target=PAddr") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_dma_addr_call_arg pass=address finding=address_class_mismatch source=DmaAddr target=PAddr") != null);
}

test "MIR emits representation checks for nonnull pointer and closed enum call results" {
    const source =
        \\enum Irq: u8 {
        \\    timer,
        \\}
        \\
        \\open enum DeviceState: u8 {
        \\    ready,
        \\}
        \\
        \\struct Packet {
        \\    ptr: *mut u8,
        \\    irq: Irq,
        \\    state: DeviceState,
        \\}
        \\
        \\extern fn make_ptr() -> *mut u8;
        \\extern fn make_irq() -> Irq;
        \\extern fn make_state() -> DeviceState;
        \\extern fn make_ptrs() -> [2]*mut u8;
        \\extern fn make_irqs() -> [2]Irq;
        \\extern fn make_packet() -> Packet;
        \\
        \\fn use_ptr() -> *mut u8 {
        \\    return make_ptr();
        \\}
        \\
        \\fn use_irq() -> Irq {
        \\    return make_irq();
        \\}
        \\
        \\fn use_open_enum() -> DeviceState {
        \\    return make_state();
        \\}
        \\
        \\fn use_ptr_param(p: *mut u8) -> *mut u8 {
        \\    return p;
        \\}
        \\
        \\fn use_irq_param(irq: Irq) -> Irq {
        \\    return irq;
        \\}
        \\
        \\fn use_packet_ptr(packet: Packet) -> *mut u8 {
        \\    return packet.ptr;
        \\}
        \\
        \\fn use_packet_irq(packet: Packet) -> Irq {
        \\    return packet.irq;
        \\}
        \\
        \\fn use_packet_open_enum(packet: Packet) -> DeviceState {
        \\    return packet.state;
        \\}
        \\
        \\fn use_copied_packet_ptr(packet: Packet) -> *mut u8 {
        \\    let copy = packet;
        \\    return copy.ptr;
        \\}
        \\
        \\fn use_copied_packet_irq(packet: Packet) -> Irq {
        \\    let copy = packet;
        \\    return copy.irq;
        \\}
        \\
        \\fn use_copied_call_packet_ptr() -> *mut u8 {
        \\    let copy = make_packet();
        \\    return copy.ptr;
        \\}
        \\
        \\fn use_copied_call_packet_irq() -> Irq {
        \\    let copy = make_packet();
        \\    return copy.irq;
        \\}
        \\
        \\fn use_packet_ptr_deref(packet: Packet) -> u8 {
        \\    return packet.ptr.*;
        \\}
        \\
        \\fn compare_packet_ptrs(left: Packet, right: Packet) -> bool {
        \\    return left.ptr == right.ptr;
        \\}
        \\
        \\fn compare_irq_values(left: Packet, right: Packet) -> bool {
        \\    return left.irq == right.irq;
        \\}
        \\
        \\fn compare_irq_literal(irq: Irq) -> bool {
        \\    return .timer == irq;
        \\}
        \\
        \\fn use_array_ptr(values: [2]*mut u8) -> *mut u8 {
        \\    return values[0];
        \\}
        \\
        \\fn use_array_irq(values: [2]Irq) -> Irq {
        \\    return values[0];
        \\}
        \\
        \\fn use_copied_array_ptr(values: [2]*mut u8) -> *mut u8 {
        \\    let copy = values;
        \\    return copy[0];
        \\}
        \\
        \\fn use_copied_array_irq(values: [2]Irq) -> Irq {
        \\    let copy = values;
        \\    return copy[0];
        \\}
        \\
        \\fn use_call_array_ptr() -> *mut u8 {
        \\    return make_ptrs()[0];
        \\}
        \\
        \\fn use_call_array_irq() -> Irq {
        \\    return make_irqs()[0];
        \\}
        \\
        \\fn use_copied_call_array_ptr() -> *mut u8 {
        \\    let copy = make_ptrs();
        \\    return copy[0];
        \\}
        \\
        \\fn use_copied_call_array_irq() -> Irq {
        \\    let copy = make_irqs();
        \\    return copy[0];
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_representation.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    const use_ptr_fn = functionByName(typed_mir, "use_ptr").?;
    const use_irq_fn = functionByName(typed_mir, "use_irq").?;
    const use_open_enum_fn = functionByName(typed_mir, "use_open_enum").?;
    const use_ptr_param_fn = functionByName(typed_mir, "use_ptr_param").?;
    const use_irq_param_fn = functionByName(typed_mir, "use_irq_param").?;
    const use_packet_ptr_fn = functionByName(typed_mir, "use_packet_ptr").?;
    const use_packet_irq_fn = functionByName(typed_mir, "use_packet_irq").?;
    const use_packet_open_enum_fn = functionByName(typed_mir, "use_packet_open_enum").?;
    const use_copied_packet_ptr_fn = functionByName(typed_mir, "use_copied_packet_ptr").?;
    const use_copied_packet_irq_fn = functionByName(typed_mir, "use_copied_packet_irq").?;
    const use_copied_call_packet_ptr_fn = functionByName(typed_mir, "use_copied_call_packet_ptr").?;
    const use_copied_call_packet_irq_fn = functionByName(typed_mir, "use_copied_call_packet_irq").?;
    const use_packet_ptr_deref_fn = functionByName(typed_mir, "use_packet_ptr_deref").?;
    const compare_packet_ptrs_fn = functionByName(typed_mir, "compare_packet_ptrs").?;
    const compare_irq_values_fn = functionByName(typed_mir, "compare_irq_values").?;
    const compare_irq_literal_fn = functionByName(typed_mir, "compare_irq_literal").?;
    const use_array_ptr_fn = functionByName(typed_mir, "use_array_ptr").?;
    const use_array_irq_fn = functionByName(typed_mir, "use_array_irq").?;
    const use_copied_array_ptr_fn = functionByName(typed_mir, "use_copied_array_ptr").?;
    const use_copied_array_irq_fn = functionByName(typed_mir, "use_copied_array_irq").?;
    const use_call_array_ptr_fn = functionByName(typed_mir, "use_call_array_ptr").?;
    const use_call_array_irq_fn = functionByName(typed_mir, "use_call_array_irq").?;
    const use_copied_call_array_ptr_fn = functionByName(typed_mir, "use_copied_call_array_ptr").?;
    const use_copied_call_array_irq_fn = functionByName(typed_mir, "use_copied_call_array_irq").?;
    try std.testing.expect(functionHasInstruction(use_ptr_fn, .representation_check, "nonnull_pointer"));
    try std.testing.expect(functionHasInstruction(use_irq_fn, .representation_check, "Irq"));
    try std.testing.expect(!functionHasInstruction(use_open_enum_fn, .representation_check, "DeviceState"));
    try std.testing.expect(functionHasInstruction(use_ptr_param_fn, .typed_load, "p"));
    try std.testing.expect(functionHasInstruction(use_ptr_param_fn, .representation_check, "nonnull_pointer"));
    try std.testing.expect(functionHasInstruction(use_irq_param_fn, .typed_load, "irq"));
    try std.testing.expect(functionHasInstruction(use_irq_param_fn, .representation_check, "Irq"));
    try std.testing.expect(functionHasInstruction(use_packet_ptr_fn, .typed_load, "ptr"));
    try std.testing.expect(functionHasInstruction(use_packet_ptr_fn, .representation_check, "nonnull_pointer"));
    try std.testing.expect(functionHasInstruction(use_packet_irq_fn, .typed_load, "irq"));
    try std.testing.expect(functionHasInstruction(use_packet_irq_fn, .representation_check, "Irq"));
    try std.testing.expect(!functionHasInstruction(use_packet_open_enum_fn, .representation_check, "DeviceState"));
    try std.testing.expect(functionHasInstruction(use_copied_packet_ptr_fn, .typed_load, "ptr"));
    try std.testing.expect(functionHasInstruction(use_copied_packet_ptr_fn, .representation_check, "nonnull_pointer"));
    try std.testing.expect(functionHasInstruction(use_copied_packet_irq_fn, .typed_load, "irq"));
    try std.testing.expect(functionHasInstruction(use_copied_packet_irq_fn, .representation_check, "Irq"));
    try std.testing.expect(functionHasInstruction(use_copied_call_packet_ptr_fn, .typed_load, "ptr"));
    try std.testing.expect(functionHasInstruction(use_copied_call_packet_ptr_fn, .representation_check, "nonnull_pointer"));
    try std.testing.expect(functionHasInstruction(use_copied_call_packet_irq_fn, .typed_load, "irq"));
    try std.testing.expect(functionHasInstruction(use_copied_call_packet_irq_fn, .representation_check, "Irq"));
    try std.testing.expect(functionHasInstruction(use_packet_ptr_deref_fn, .typed_load, "ptr"));
    try std.testing.expect(functionHasInstruction(use_packet_ptr_deref_fn, .representation_check, "nonnull_pointer"));
    try std.testing.expect(functionHasInstruction(compare_packet_ptrs_fn, .representation_use, "binary_operand"));
    try std.testing.expect(functionHasInstruction(compare_irq_values_fn, .representation_use, "binary_operand"));
    try std.testing.expect(functionHasInstruction(compare_irq_literal_fn, .representation_use, "binary_operand"));
    try std.testing.expect(functionHasInstruction(use_array_ptr_fn, .typed_load, "index"));
    try std.testing.expect(functionHasInstruction(use_array_ptr_fn, .representation_check, "nonnull_pointer"));
    try std.testing.expect(functionHasInstruction(use_array_irq_fn, .typed_load, "index"));
    try std.testing.expect(functionHasInstruction(use_array_irq_fn, .representation_check, "Irq"));
    try std.testing.expect(functionHasInstruction(use_copied_array_ptr_fn, .typed_load, "index"));
    try std.testing.expect(functionHasInstruction(use_copied_array_ptr_fn, .representation_check, "nonnull_pointer"));
    try std.testing.expect(functionHasInstruction(use_copied_array_irq_fn, .typed_load, "index"));
    try std.testing.expect(functionHasInstruction(use_copied_array_irq_fn, .representation_check, "Irq"));
    try std.testing.expect(functionHasInstruction(use_call_array_ptr_fn, .typed_load, "index"));
    try std.testing.expect(functionHasInstruction(use_call_array_ptr_fn, .representation_check, "nonnull_pointer"));
    try std.testing.expect(functionHasInstruction(use_call_array_irq_fn, .typed_load, "index"));
    try std.testing.expect(functionHasInstruction(use_call_array_irq_fn, .representation_check, "Irq"));
    try std.testing.expect(functionHasInstruction(use_copied_call_array_ptr_fn, .typed_load, "index"));
    try std.testing.expect(functionHasInstruction(use_copied_call_array_ptr_fn, .representation_check, "nonnull_pointer"));
    try std.testing.expect(functionHasInstruction(use_copied_call_array_irq_fn, .typed_load, "index"));
    try std.testing.expect(functionHasInstruction(use_copied_call_array_irq_fn, .representation_check, "Irq"));

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFactsFromDecls(std.testing.allocator, module.decls, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_ptr pass=representation finding=representation_check type=nonnull_pointer") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_irq pass=representation finding=representation_check type=Irq") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_ptr_param pass=representation finding=typed_load detail=p type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_irq_param pass=representation finding=typed_load detail=irq type=Irq") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_packet_ptr pass=representation finding=typed_load detail=ptr type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_packet_irq pass=representation finding=typed_load detail=irq type=Irq") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_copied_packet_ptr pass=representation finding=typed_load detail=ptr type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_copied_packet_irq pass=representation finding=typed_load detail=irq type=Irq") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_copied_call_packet_ptr pass=representation finding=typed_load detail=ptr type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_copied_call_packet_irq pass=representation finding=typed_load detail=irq type=Irq") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_packet_ptr_deref pass=representation finding=representation_use detail=deref_base type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=compare_packet_ptrs pass=representation finding=representation_use detail=binary_operand type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=compare_irq_values pass=representation finding=representation_use detail=binary_operand type=Irq") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=compare_irq_literal pass=representation finding=representation_use detail=binary_operand type=Irq") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=compare_irq_literal pass=representation finding=representation_use detail=binary_operand type=value") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_array_ptr pass=representation finding=typed_load detail=index type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_array_irq pass=representation finding=typed_load detail=index type=Irq") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_copied_array_ptr pass=representation finding=typed_load detail=index type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_copied_array_irq pass=representation finding=typed_load detail=index type=Irq") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_call_array_ptr pass=representation finding=typed_load detail=index type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_call_array_irq pass=representation finding=typed_load detail=index type=Irq") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_copied_call_array_ptr pass=representation finding=typed_load detail=index type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=use_copied_call_array_irq pass=representation finding=typed_load detail=index type=Irq") != null);

    try mir.verifyBuiltMir(typed_mir, &reporter);
    try std.testing.expect(!reporter.has_errors);
}

test "MIR nullable-pointer narrowing discharges the nonnull trap" {
    const source =
        \\extern struct ProbeState {
        \\    value: u32,
        \\}
        \\
        \\#[no_lang_trap]
        \\fn narrowed_read(maybe_state: ?*const ProbeState) -> u32 {
        \\    if let state = maybe_state {
        \\        return state.value;
        \\    }
        \\    return 0;
        \\}
        \\
        \\#[no_lang_trap]
        \\fn unchecked_read(state: *const ProbeState) -> u32 {
        \\    return state.value;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_nullable_pointer_narrowing.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    const narrowed_fn = functionByName(typed_mir, "narrowed_read").?;
    const unchecked_fn = functionByName(typed_mir, "unchecked_read").?;
    try std.testing.expectEqual(@as(usize, 0), countTrapEdges(narrowed_fn, .InvalidRepresentation));
    try std.testing.expectEqual(@as(usize, 1), countTrapEdges(unchecked_fn, .InvalidRepresentation));
    try std.testing.expect(functionHasInstruction(narrowed_fn, .representation_check, "nonnull_pointer"));

    try mir.verifyBuiltMir(typed_mir, &reporter);
    var no_lang_count: usize = 0;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_NO_LANG_TRAP_EDGE") != null) no_lang_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), no_lang_count);
}

test "MIR representation checks emit invalid-representation trap edges" {
    const source =
        \\enum Irq: u8 {
        \\    timer,
        \\}
        \\
        \\open enum DeviceState: u8 {
        \\    ready,
        \\}
        \\
        \\fn checked_ptr_param(p: *mut u8) -> *mut u8 {
        \\    return p;
        \\}
        \\
        \\fn checked_irq_param(irq: Irq) -> Irq {
        \\    return irq;
        \\}
        \\
        \\fn checked_open_enum(state: DeviceState) -> DeviceState {
        \\    return state;
        \\}
        \\
        \\#[no_lang_trap]
        \\fn reject_no_lang_ptr_param(p: *mut u8) -> *mut u8 {
        \\    return p;
        \\}
        \\
        \\#[no_lang_trap]
        \\fn reject_no_lang_irq_param(irq: Irq) -> Irq {
        \\    return irq;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_representation_traps.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    const checked_ptr_fn = functionByName(typed_mir, "checked_ptr_param").?;
    const checked_irq_fn = functionByName(typed_mir, "checked_irq_param").?;
    const checked_open_fn = functionByName(typed_mir, "checked_open_enum").?;
    try std.testing.expectEqual(@as(usize, 1), countTrapEdges(checked_ptr_fn, .InvalidRepresentation));
    try std.testing.expectEqual(@as(usize, 1), countTrapEdges(checked_irq_fn, .InvalidRepresentation));
    try std.testing.expectEqual(@as(usize, 0), countTrapEdges(checked_open_fn, .InvalidRepresentation));

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFactsFromDecls(std.testing.allocator, module.decls, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=checked_ptr_param pass=trap finding=trap_edge detail=InvalidRepresentation source=representation_check") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=checked_irq_param pass=trap finding=trap_edge detail=InvalidRepresentation source=representation_check") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=checked_open_enum pass=trap finding=trap_edge detail=InvalidRepresentation") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_no_lang_ptr_param pass=trap finding=trap_edge detail=InvalidRepresentation source=representation_check no_lang_trap=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_no_lang_irq_param pass=trap finding=trap_edge detail=InvalidRepresentation source=representation_check no_lang_trap=true") != null);

    try mir.verifyBuiltMir(typed_mir, &reporter);
    var no_lang_count: usize = 0;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_NO_LANG_TRAP_EDGE") != null) no_lang_count += 1;
    }
    try std.testing.expect(no_lang_count >= 2);
}

test "MIR verifier rejects missing representation check" {
    var instructions = [_]Instruction{
        .{ .kind = .call, .result_ty = .{ .pointer = .{ .kind = .single, .mutability = .mut, .child = "u8" } }, .detail = "make_ptr", .typed_callee_span_id = SpanId.fromIndex(0), .line = 1, .column = 1 },
    };
    var span_identities = [_]mir.SpanIdentity{
        .{ .id = SpanId.fromIndex(0), .source = .{ .line = 1, .column = 1 } },
    };
    var successors = [_]usize{};
    var blocks = [_]Block{
        .{ .id = 0, .kind = "entry", .instructions = instructions[0..], .successors = successors[0..], .terminator = .fallthrough },
    };
    var trap_edges = [_]TrapEdge{};
    var contract_regions = [_]ContractRegion{};
    var range_facts = [_]RangeFact{};
    var functions = [_]Function{
        .{
            .name = "missing_rep_check",
            .return_ty = .void,
            .no_lang_trap = false,
            .irq_context = false,
            .blocks = blocks[0..],
            .trap_edges = trap_edges[0..],
            .contract_regions = contract_regions[0..],
            .range_facts = range_facts[0..],
            .span_identities = span_identities[0..],
            .pointer_provenance_facts = &.{},
            .representation_facts = &.{},
            .elided_bounds = &.{},
        },
    };
    const module = Module{ .allocator = std.testing.allocator, .functions = functions[0..] };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "missing_rep_check.mc", "");
    defer reporter.deinit();
    try mir.verifyBuiltMir(module, &reporter);
    try std.testing.expect(reporter.has_errors);
    // DIAGNOSTIC_UNIT: E_REPRESENTATION_CHECK_MISSING
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, "E_REPRESENTATION_CHECK_MISSING") != null);
}

test "MIR verifier rejects missing representation check on indirect call" {
    var instructions = [_]Instruction{
        .{ .kind = .indirect_call, .result_ty = .{ .pointer = .{ .kind = .single, .mutability = .mut, .child = "u8" } }, .detail = "callee", .typed_callee_span_id = SpanId.fromIndex(0), .line = 1, .column = 1 },
    };
    var span_identities = [_]mir.SpanIdentity{
        .{ .id = SpanId.fromIndex(0), .source = .{ .line = 1, .column = 1 } },
    };
    var successors = [_]usize{};
    var blocks = [_]Block{
        .{ .id = 0, .kind = "entry", .instructions = instructions[0..], .successors = successors[0..], .terminator = .fallthrough },
    };
    var trap_edges = [_]TrapEdge{};
    var contract_regions = [_]ContractRegion{};
    var range_facts = [_]RangeFact{};
    var functions = [_]Function{
        .{
            .name = "missing_indirect_rep_check",
            .return_ty = .void,
            .no_lang_trap = false,
            .irq_context = false,
            .blocks = blocks[0..],
            .trap_edges = trap_edges[0..],
            .contract_regions = contract_regions[0..],
            .range_facts = range_facts[0..],
            .span_identities = span_identities[0..],
            .pointer_provenance_facts = &.{},
            .representation_facts = &.{},
            .elided_bounds = &.{},
        },
    };
    const module = Module{ .allocator = std.testing.allocator, .functions = functions[0..] };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "missing_indirect_rep_check.mc", "");
    defer reporter.deinit();
    try mir.verifyBuiltMir(module, &reporter);
    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, "E_REPRESENTATION_CHECK_MISSING") != null);
}

test "MIR verifier rejects missing representation check on typed load" {
    var instructions = [_]Instruction{
        .{ .kind = .typed_load, .result_ty = .{ .closed_enum = "Irq" }, .detail = "irq", .line = 1, .column = 1 },
    };
    var successors = [_]usize{};
    var blocks = [_]Block{
        .{ .id = 0, .kind = "entry", .instructions = instructions[0..], .successors = successors[0..], .terminator = .fallthrough },
    };
    var trap_edges = [_]TrapEdge{};
    var contract_regions = [_]ContractRegion{};
    var range_facts = [_]RangeFact{};
    var functions = [_]Function{
        .{
            .name = "missing_load_rep_check",
            .return_ty = .void,
            .no_lang_trap = false,
            .irq_context = false,
            .blocks = blocks[0..],
            .trap_edges = trap_edges[0..],
            .contract_regions = contract_regions[0..],
            .range_facts = range_facts[0..],
            .pointer_provenance_facts = &.{},
            .representation_facts = &.{},
            .elided_bounds = &.{},
        },
    };
    const module = Module{ .allocator = std.testing.allocator, .functions = functions[0..] };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "missing_load_rep_check.mc", "");
    defer reporter.deinit();
    try mir.verifyBuiltMir(module, &reporter);
    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, "E_REPRESENTATION_CHECK_MISSING") != null);
}

test "MIR verifier requires representation checks to dominate sensitive returns" {
    const ptr_ty = ValueType{ .pointer = .{ .kind = .single, .mutability = .mut, .child = "u8" } };
    var entry_instructions = [_]Instruction{};
    var then_instructions = [_]Instruction{
        .{ .kind = .representation_check, .result_ty = ptr_ty, .detail = "nonnull_pointer", .line = 2, .column = 5 },
    };
    var else_instructions = [_]Instruction{
        .{ .kind = .representation_check, .result_ty = ptr_ty, .detail = "nonnull_pointer", .line = 3, .column = 5 },
    };
    var join_instructions = [_]Instruction{
        .{ .kind = .return_value, .result_ty = ptr_ty, .detail = "value", .line = 4, .column = 5 },
    };
    var entry_successors = [_]usize{ 1, 2 };
    var then_successors = [_]usize{3};
    var else_successors = [_]usize{3};
    var join_successors = [_]usize{};
    var blocks = [_]Block{
        .{ .id = 0, .kind = "entry", .instructions = entry_instructions[0..], .successors = entry_successors[0..], .terminator = .{ .branch = .{ .true_block = 1, .false_block = 2 } } },
        .{ .id = 1, .kind = "then", .instructions = then_instructions[0..], .successors = then_successors[0..], .terminator = .{ .jump = 3 } },
        .{ .id = 2, .kind = "else", .instructions = else_instructions[0..], .successors = else_successors[0..], .terminator = .{ .jump = 3 } },
        .{ .id = 3, .kind = "join", .instructions = join_instructions[0..], .successors = join_successors[0..], .terminator = .{ .return_ = ptr_ty } },
    };
    var trap_edges = [_]TrapEdge{};
    var contract_regions = [_]ContractRegion{};
    var range_facts = [_]RangeFact{};
    var functions = [_]Function{
        .{
            .name = "dominated_return",
            .return_ty = ptr_ty,
            .no_lang_trap = false,
            .irq_context = false,
            .blocks = blocks[0..],
            .trap_edges = trap_edges[0..],
            .contract_regions = contract_regions[0..],
            .range_facts = range_facts[0..],
            .pointer_provenance_facts = &.{},
            .representation_facts = &.{},
            .elided_bounds = &.{},
        },
    };
    const module = Module{ .allocator = std.testing.allocator, .functions = functions[0..] };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "dominated_return.mc", "");
    defer reporter.deinit();
    try mir.verifyBuiltMir(module, &reporter);
    try std.testing.expect(!reporter.has_errors);
}

test "MIR verifier rejects representation return when one predecessor lacks check" {
    const ptr_ty = ValueType{ .pointer = .{ .kind = .single, .mutability = .mut, .child = "u8" } };
    var entry_instructions = [_]Instruction{};
    var then_instructions = [_]Instruction{
        .{ .kind = .representation_check, .result_ty = ptr_ty, .detail = "nonnull_pointer", .line = 2, .column = 5 },
    };
    var else_instructions = [_]Instruction{};
    var join_instructions = [_]Instruction{
        .{ .kind = .return_value, .result_ty = ptr_ty, .detail = "value", .line = 4, .column = 5 },
    };
    var entry_successors = [_]usize{ 1, 2 };
    var then_successors = [_]usize{3};
    var else_successors = [_]usize{3};
    var join_successors = [_]usize{};
    var blocks = [_]Block{
        .{ .id = 0, .kind = "entry", .instructions = entry_instructions[0..], .successors = entry_successors[0..], .terminator = .{ .branch = .{ .true_block = 1, .false_block = 2 } } },
        .{ .id = 1, .kind = "then", .instructions = then_instructions[0..], .successors = then_successors[0..], .terminator = .{ .jump = 3 } },
        .{ .id = 2, .kind = "else", .instructions = else_instructions[0..], .successors = else_successors[0..], .terminator = .{ .jump = 3 } },
        .{ .id = 3, .kind = "join", .instructions = join_instructions[0..], .successors = join_successors[0..], .terminator = .{ .return_ = ptr_ty } },
    };
    var trap_edges = [_]TrapEdge{};
    var contract_regions = [_]ContractRegion{};
    var range_facts = [_]RangeFact{};
    var functions = [_]Function{
        .{
            .name = "undominated_return",
            .return_ty = ptr_ty,
            .no_lang_trap = false,
            .irq_context = false,
            .blocks = blocks[0..],
            .trap_edges = trap_edges[0..],
            .contract_regions = contract_regions[0..],
            .range_facts = range_facts[0..],
            .pointer_provenance_facts = &.{},
            .representation_facts = &.{},
            .elided_bounds = &.{},
        },
    };
    const module = Module{ .allocator = std.testing.allocator, .functions = functions[0..] };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "undominated_return.mc", "");
    defer reporter.deinit();
    try mir.verifyBuiltMir(module, &reporter);
    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, "E_REPRESENTATION_CHECK_MISSING") != null);
}

test "MIR verifier matches representation identity across predecessor paths" {
    const ptr_ty = ValueType{ .pointer = .{ .kind = .single, .mutability = .mut, .child = "u8" } };
    var entry_instructions = [_]Instruction{};
    var then_instructions = [_]Instruction{
        .{ .kind = .representation_check, .result_ty = ptr_ty, .detail = "nonnull_pointer", .value_id = "p", .line = 2, .column = 5 },
    };
    var else_instructions = [_]Instruction{
        .{ .kind = .representation_check, .result_ty = ptr_ty, .detail = "nonnull_pointer", .value_id = "p", .line = 3, .column = 5 },
    };
    var join_instructions = [_]Instruction{
        .{ .kind = .representation_use, .result_ty = ptr_ty, .detail = "call_arg", .value_id = "p", .line = 4, .column = 5 },
    };
    var entry_successors = [_]usize{ 1, 2 };
    var then_successors = [_]usize{3};
    var else_successors = [_]usize{3};
    var join_successors = [_]usize{};
    var blocks = [_]Block{
        .{ .id = 0, .kind = "entry", .instructions = entry_instructions[0..], .successors = entry_successors[0..], .terminator = .{ .branch = .{ .true_block = 1, .false_block = 2 } } },
        .{ .id = 1, .kind = "then", .instructions = then_instructions[0..], .successors = then_successors[0..], .terminator = .{ .jump = 3 } },
        .{ .id = 2, .kind = "else", .instructions = else_instructions[0..], .successors = else_successors[0..], .terminator = .{ .jump = 3 } },
        .{ .id = 3, .kind = "join", .instructions = join_instructions[0..], .successors = join_successors[0..], .terminator = .fallthrough },
    };
    var trap_edges = [_]TrapEdge{};
    var contract_regions = [_]ContractRegion{};
    var range_facts = [_]RangeFact{};
    var functions = [_]Function{
        .{
            .name = "identity_dominated_use",
            .return_ty = .void,
            .no_lang_trap = false,
            .irq_context = false,
            .blocks = blocks[0..],
            .trap_edges = trap_edges[0..],
            .contract_regions = contract_regions[0..],
            .range_facts = range_facts[0..],
            .pointer_provenance_facts = &.{},
            .representation_facts = &.{},
            .elided_bounds = &.{},
        },
    };
    const module = Module{ .allocator = std.testing.allocator, .functions = functions[0..] };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "identity_dominated_use.mc", "");
    defer reporter.deinit();
    try mir.verifyBuiltMir(module, &reporter);
    try std.testing.expect(!reporter.has_errors);
}

test "MIR verifier rejects predecessor representation check for wrong identity" {
    const ptr_ty = ValueType{ .pointer = .{ .kind = .single, .mutability = .mut, .child = "u8" } };
    var entry_instructions = [_]Instruction{};
    var then_instructions = [_]Instruction{
        .{ .kind = .representation_check, .result_ty = ptr_ty, .detail = "nonnull_pointer", .value_id = "p", .line = 2, .column = 5 },
    };
    var else_instructions = [_]Instruction{
        .{ .kind = .representation_check, .result_ty = ptr_ty, .detail = "nonnull_pointer", .value_id = "q", .line = 3, .column = 5 },
    };
    var join_instructions = [_]Instruction{
        .{ .kind = .representation_use, .result_ty = ptr_ty, .detail = "call_arg", .value_id = "p", .line = 4, .column = 5 },
    };
    var entry_successors = [_]usize{ 1, 2 };
    var then_successors = [_]usize{3};
    var else_successors = [_]usize{3};
    var join_successors = [_]usize{};
    var blocks = [_]Block{
        .{ .id = 0, .kind = "entry", .instructions = entry_instructions[0..], .successors = entry_successors[0..], .terminator = .{ .branch = .{ .true_block = 1, .false_block = 2 } } },
        .{ .id = 1, .kind = "then", .instructions = then_instructions[0..], .successors = then_successors[0..], .terminator = .{ .jump = 3 } },
        .{ .id = 2, .kind = "else", .instructions = else_instructions[0..], .successors = else_successors[0..], .terminator = .{ .jump = 3 } },
        .{ .id = 3, .kind = "join", .instructions = join_instructions[0..], .successors = join_successors[0..], .terminator = .fallthrough },
    };
    var trap_edges = [_]TrapEdge{};
    var contract_regions = [_]ContractRegion{};
    var range_facts = [_]RangeFact{};
    var functions = [_]Function{
        .{
            .name = "wrong_identity_predecessor_use",
            .return_ty = .void,
            .no_lang_trap = false,
            .irq_context = false,
            .blocks = blocks[0..],
            .trap_edges = trap_edges[0..],
            .contract_regions = contract_regions[0..],
            .range_facts = range_facts[0..],
            .pointer_provenance_facts = &.{},
            .representation_facts = &.{},
            .elided_bounds = &.{},
        },
    };
    const module = Module{ .allocator = std.testing.allocator, .functions = functions[0..] };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "wrong_identity_predecessor_use.mc", "");
    defer reporter.deinit();
    try mir.verifyBuiltMir(module, &reporter);
    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, "E_REPRESENTATION_CHECK_MISSING") != null);
}

test "MIR verifier requires representation checks to dominate non-return typed uses" {
    const ptr_ty = ValueType{ .pointer = .{ .kind = .single, .mutability = .mut, .child = "u8" } };
    var instructions = [_]Instruction{
        .{ .kind = .typed_load, .result_ty = ptr_ty, .detail = "p", .line = 1, .column = 5 },
        .{ .kind = .representation_check, .result_ty = ptr_ty, .detail = "nonnull_pointer", .line = 1, .column = 5 },
        .{ .kind = .representation_use, .result_ty = ptr_ty, .detail = "assignment", .line = 1, .column = 9 },
    };
    var successors = [_]usize{};
    var blocks = [_]Block{
        .{ .id = 0, .kind = "entry", .instructions = instructions[0..], .successors = successors[0..], .terminator = .fallthrough },
    };
    var trap_edges = [_]TrapEdge{};
    var contract_regions = [_]ContractRegion{};
    var range_facts = [_]RangeFact{};
    var functions = [_]Function{
        .{
            .name = "checked_non_return_use",
            .return_ty = .void,
            .no_lang_trap = false,
            .irq_context = false,
            .blocks = blocks[0..],
            .trap_edges = trap_edges[0..],
            .contract_regions = contract_regions[0..],
            .range_facts = range_facts[0..],
            .pointer_provenance_facts = &.{},
            .representation_facts = &.{},
            .elided_bounds = &.{},
        },
    };
    const module = Module{ .allocator = std.testing.allocator, .functions = functions[0..] };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "checked_non_return_use.mc", "");
    defer reporter.deinit();
    try mir.verifyBuiltMir(module, &reporter);
    try std.testing.expect(!reporter.has_errors);
}

test "MIR verifier rejects missing representation check on non-return typed use" {
    const ptr_ty = ValueType{ .pointer = .{ .kind = .single, .mutability = .mut, .child = "u8" } };
    var instructions = [_]Instruction{
        .{ .kind = .representation_use, .result_ty = ptr_ty, .detail = "call_arg", .line = 1, .column = 9 },
    };
    var successors = [_]usize{};
    var blocks = [_]Block{
        .{ .id = 0, .kind = "entry", .instructions = instructions[0..], .successors = successors[0..], .terminator = .fallthrough },
    };
    var trap_edges = [_]TrapEdge{};
    var contract_regions = [_]ContractRegion{};
    var range_facts = [_]RangeFact{};
    var functions = [_]Function{
        .{
            .name = "missing_non_return_use_check",
            .return_ty = .void,
            .no_lang_trap = false,
            .irq_context = false,
            .blocks = blocks[0..],
            .trap_edges = trap_edges[0..],
            .contract_regions = contract_regions[0..],
            .range_facts = range_facts[0..],
            .pointer_provenance_facts = &.{},
            .representation_facts = &.{},
            .elided_bounds = &.{},
        },
    };
    const module = Module{ .allocator = std.testing.allocator, .functions = functions[0..] };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "missing_non_return_use_check.mc", "");
    defer reporter.deinit();
    try mir.verifyBuiltMir(module, &reporter);
    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, "E_REPRESENTATION_CHECK_MISSING") != null);
}

test "MIR verifier rejects representation check for the wrong value identity" {
    const ptr_ty = ValueType{ .pointer = .{ .kind = .single, .mutability = .mut, .child = "u8" } };
    var instructions = [_]Instruction{
        .{ .kind = .typed_load, .result_ty = ptr_ty, .detail = "checked_ptr", .value_id = "checked_ptr", .line = 1, .column = 5 },
        .{ .kind = .representation_check, .result_ty = ptr_ty, .detail = "nonnull_pointer", .value_id = "checked_ptr", .line = 1, .column = 9 },
        .{ .kind = .return_value, .result_ty = ptr_ty, .detail = "value", .value_id = "unchecked_ptr", .line = 2, .column = 5 },
    };
    var successors = [_]usize{};
    var blocks = [_]Block{
        .{ .id = 0, .kind = "entry", .instructions = instructions[0..], .successors = successors[0..], .terminator = .{ .return_ = ptr_ty } },
    };
    var trap_edges = [_]TrapEdge{};
    var contract_regions = [_]ContractRegion{};
    var range_facts = [_]RangeFact{};
    var functions = [_]Function{
        .{
            .name = "wrong_identity_return",
            .return_ty = ptr_ty,
            .no_lang_trap = false,
            .irq_context = false,
            .blocks = blocks[0..],
            .trap_edges = trap_edges[0..],
            .contract_regions = contract_regions[0..],
            .range_facts = range_facts[0..],
            .pointer_provenance_facts = &.{},
            .representation_facts = &.{},
            .elided_bounds = &.{},
        },
    };
    const module = Module{ .allocator = std.testing.allocator, .functions = functions[0..] };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "wrong_identity_return.mc", "");
    defer reporter.deinit();
    try mir.verifyBuiltMir(module, &reporter);
    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, "E_REPRESENTATION_CHECK_MISSING") != null);
}

test "MIR target representation checks see through casts" {
    const source =
        \\struct PtrPacket {
        \\    ptr: *mut u8,
        \\}
        \\
        \\extern fn make_ptr() -> *mut u8;
        \\extern fn take_ptr(value: *mut u8) -> void;
        \\
        \\fn cast_pointer_return() -> *mut u8 {
        \\    return make_ptr() as *mut u8;
        \\}
        \\
        \\fn cast_pointer_local() -> *mut u8 {
        \\    let p: *mut u8 = make_ptr() as *mut u8;
        \\    return p;
        \\}
        \\
        \\fn cast_pointer_assignment() -> *mut u8 {
        \\    var p: *mut u8 = make_ptr();
        \\    p = make_ptr() as *mut u8;
        \\    return p;
        \\}
        \\
        \\fn cast_pointer_call_arg() -> void {
        \\    take_ptr(make_ptr() as *mut u8);
        \\}
        \\
        \\fn cast_pointer_aggregate_field() -> PtrPacket {
        \\    return .{ .ptr = make_ptr() as *mut u8 };
        \\}
        \\
        \\fn cast_pointer_aggregate_element() -> [1]*mut u8 {
        \\    return .{ make_ptr() as *mut u8 };
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_cast_representation.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFactsFromDecls(std.testing.allocator, module.decls, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=cast_pointer_return pass=representation finding=representation_check type=nonnull_pointer") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=cast_pointer_local pass=representation finding=representation_use detail=initializer type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=cast_pointer_assignment pass=representation finding=representation_use detail=assignment type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=cast_pointer_call_arg pass=representation finding=representation_use detail=call_arg type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=cast_pointer_aggregate_field pass=representation finding=representation_use detail=aggregate_field type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=cast_pointer_aggregate_element pass=representation finding=representation_use detail=aggregate_element type=*mut") != null);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();

    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(std.testing.allocator);
    try mir.appendDumpFromDecls(std.testing.allocator, module.decls, &dump);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir representation_fact fn=cast_pointer_return kind=representation_check detail=nonnull_pointer type=*mut value_id=cast recorded=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir representation_fact fn=cast_pointer_local kind=representation_use detail=initializer type=*mut value_id=cast recorded=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir representation_fact fn=cast_pointer_assignment kind=representation_use detail=assignment type=*mut value_id=cast recorded=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir representation_fact fn=cast_pointer_call_arg kind=representation_use detail=call_arg type=*mut value_id=cast recorded=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir representation_fact fn=cast_pointer_aggregate_field kind=representation_use detail=aggregate_field type=*mut value_id=cast recorded=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir representation_fact fn=cast_pointer_aggregate_element kind=representation_use detail=aggregate_element type=*mut value_id=cast recorded=true") != null);

    try mir.verifyBuiltMir(typed_mir, &reporter);
    try std.testing.expect(!reporter.has_errors);
}

test "MIR verifier reports nullability conversion violations" {
    const source =
        \\extern fn make_nullable() -> ?*mut u8;
        \\
        \\fn reject_null_local() -> *mut u8 {
        \\    let p: *mut u8 = null;
        \\    return p;
        \\}
        \\
        \\fn reject_null_assignment(fallback: *mut u8) -> *mut u8 {
        \\    var p: *mut u8 = fallback;
        \\    p = null;
        \\    return p;
        \\}
        \\
        \\fn reject_nullable_return(maybe: ?*mut u8) -> *mut u8 {
        \\    return maybe;
        \\}
        \\
        \\fn reject_nullable_call_return() -> *mut u8 {
        \\    return make_nullable();
        \\}
        \\
        \\fn accept_nonnull_to_nullable(p: *mut u8) -> ?*mut u8 {
        \\    return p;
        \\}
        \\
        \\fn accept_null_nullable() -> ?*mut u8 {
        \\    return null;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_nullability.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFactsFromDecls(std.testing.allocator, module.decls, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_null_local pass=nullability finding=null_to_nonnull") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_null_assignment pass=nullability finding=null_to_nonnull") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_nullable_return pass=nullability finding=nullable_to_nonnull") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_nullable_call_return pass=nullability finding=nullable_to_nonnull") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_nonnull_to_nullable pass=nullability") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_null_nullable pass=nullability") == null);

    try mir.verifyFromDecls(std.testing.allocator, module.decls, &reporter);
    var found_null_to_nonnull = false;
    var found_nullable_to_nonnull = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_NULL_NON_NULL_POINTER") != null) found_null_to_nonnull = true;
        if (std.mem.indexOf(u8, diag.message, "E_NO_IMPLICIT_POINTER_CONVERSION") != null) found_nullable_to_nonnull = true;
    }
    try std.testing.expect(found_null_to_nonnull);
    try std.testing.expect(found_nullable_to_nonnull);
}

test "MIR verifier reports general return local and assignment conversions" {
    const source =
        \\extern fn make_u32() -> u32;
        \\extern fn make_mut_u8_pointer() -> *mut u8;
        \\extern fn make_c_void_pointer() -> *mut c_void;
        \\extern fn takes_u32(value: u32) -> void;
        \\extern fn takes_mut_pointer(value: *mut u8) -> void;
        \\extern fn takes_c_void_pointer(value: *mut c_void) -> void;
        \\extern struct Packet {
        \\    value: u32,
        \\    ptr: *mut u8,
        \\}
        \\
        \\fn accept_matching_return() -> u32 {
        \\    return make_u32();
        \\}
        \\
        \\fn reject_return_type() -> i32 {
        \\    return make_u32();
        \\}
        \\
        \\fn reject_local_initializer() -> void {
        \\    let value: i32 = make_u32();
        \\}
        \\
        \\fn reject_assignment() -> void {
        \\    var value: i32 = 0;
        \\    value = make_u32();
        \\}
        \\
        \\fn accept_nonnull_to_nullable(p: *mut u8) -> ?*mut u8 {
        \\    return p;
        \\}
        \\
        \\fn accept_return_pointer_const_narrow(p: *mut u8) -> *const u8 {
        \\    return p;
        \\}
        \\
        \\fn reject_return_pointer_element_conversion(p: *mut u8) -> *mut u16 {
        \\    return p;
        \\}
        \\
        \\fn reject_return_c_void_conversion(p: *mut c_void) -> *mut u8 {
        \\    return p;
        \\}
        \\
        \\fn accept_initializer_pointer_const_narrow(p: *mut u8) -> void {
        \\    let q: *const u8 = p;
        \\}
        \\
        \\fn reject_initializer_pointer_element_conversion(p: *mut u8) -> void {
        \\    let q: *mut u16 = p;
        \\}
        \\
        \\fn reject_initializer_c_void_conversion(p: *mut u8) -> void {
        \\    let q: *mut c_void = p;
        \\}
        \\
        \\fn reject_nullable_initializer_pointer_conversion(p: *mut u8) -> void {
        \\    let q: ?*const u8 = p;
        \\}
        \\
        \\fn reject_call_argument_type(flag: bool) -> void {
        \\    takes_u32(flag);
        \\}
        \\
        \\fn reject_call_argument_pointer(p: *const u8) -> void {
        \\    takes_mut_pointer(p);
        \\}
        \\
        \\fn reject_call_argument_c_void(p: *mut u8) -> void {
        \\    takes_c_void_pointer(p);
        \\}
        \\
        \\fn reject_assert_condition_type(value: u32) -> void {
        \\    assert(value);
        \\}
        \\
        \\fn reject_while_condition_type(value: u32) -> void {
        \\    while value {
        \\        break;
        \\    }
        \\}
        \\
        \\fn reject_for_base_type(value: u32) -> void {
        \\    for x in value {
        \\    }
        \\}
        \\
        \\fn reject_index_base_type(value: u32, index: usize) -> u8 {
        \\    return value[index];
        \\}
        \\
        \\fn reject_index_operand_type(values: []const u8, flag: bool) -> u8 {
        \\    return values[flag];
        \\}
        \\
        \\fn reject_direct_call_return_pointer_element() -> *mut u16 {
        \\    return make_mut_u8_pointer();
        \\}
        \\
        \\fn reject_direct_call_return_c_void() -> *mut u8 {
        \\    return make_c_void_pointer();
        \\}
        \\
        \\fn reject_member_assignment_pointer_conversion(p: *const u8) -> void {
        \\    var packet: Packet = uninit;
        \\    packet.ptr = p;
        \\}
        \\
        \\fn reject_deref_assignment_type(p: *mut u32, flag: bool) -> void {
        \\    p.* = flag;
        \\}
        \\
        \\fn reject_index_assignment_pointer(xs: []mut *mut u8, p: *const u8) -> void {
        \\    xs[0] = p;
        \\}
        \\
        \\fn reject_cast_return_type() -> u32 {
        \\    return make_u32() as i32;
        \\}
        \\
        \\fn reject_cast_local_initializer() -> void {
        \\    let value: u32 = make_u32() as i32;
        \\}
        \\
        \\fn reject_cast_assignment() -> void {
        \\    var value: u32 = 0;
        \\    value = make_u32() as i32;
        \\}
        \\
        \\fn reject_cast_call_argument() -> void {
        \\    takes_u32(make_u32() as i32);
        \\}
        \\
        \\fn reject_cast_nullable_to_nonnull(maybe: ?*mut u8) -> *mut u8 {
        \\    return maybe as ?*mut u8;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_conversions.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFactsFromDecls(std.testing.allocator, module.decls, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_matching_return pass=conversion") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_nonnull_to_nullable pass=conversion") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_return_type pass=conversion finding=return_type_mismatch source_type=u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_local_initializer pass=conversion finding=initializer_type_mismatch source_type=u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assignment pass=conversion finding=assignment_type_mismatch source_type=u32") != null);
    // G30: a `*mut T` -> `*const T` const-narrow is a safe no-op coercion, NOT a reported conversion.
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_return_pointer_const_narrow pass=conversion") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_return_pointer_element_conversion pass=conversion finding=return_pointer_conversion source_type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_return_c_void_conversion pass=conversion finding=return_c_void_conversion source_type=*mut c_void") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_initializer_pointer_const_narrow pass=conversion") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_initializer_pointer_element_conversion pass=conversion finding=initializer_pointer_conversion source_type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_initializer_c_void_conversion pass=conversion finding=initializer_c_void_conversion source_type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_nullable_initializer_pointer_conversion pass=conversion finding=initializer_pointer_conversion source_type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_call_argument_type pass=conversion finding=call_arg_type_mismatch source_type=bool") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_call_argument_pointer pass=conversion finding=call_arg_pointer_conversion source_type=*const") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_call_argument_c_void pass=conversion finding=call_arg_c_void_conversion source_type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assert_condition_type pass=conversion finding=condition_type_mismatch source_type=u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_while_condition_type pass=conversion finding=condition_type_mismatch source_type=u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_for_base_type pass=conversion finding=for_base_not_iterable source_type=u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_index_base_type pass=conversion finding=index_base_not_array_or_slice source_type=u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_index_operand_type pass=conversion finding=index_not_usize source_type=bool") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_direct_call_return_pointer_element pass=conversion finding=return_pointer_conversion source_type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_direct_call_return_c_void pass=conversion finding=return_c_void_conversion source_type=*mut c_void") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_member_assignment_pointer_conversion pass=conversion finding=assignment_pointer_conversion source_type=*const") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_deref_assignment_type pass=conversion finding=assignment_type_mismatch source_type=bool") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_index_assignment_pointer pass=conversion finding=assignment_pointer_conversion source_type=*const") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_cast_return_type pass=conversion finding=return_type_mismatch source_type=i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_cast_local_initializer pass=conversion finding=initializer_type_mismatch source_type=i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_cast_assignment pass=conversion finding=assignment_type_mismatch source_type=i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_cast_call_argument pass=conversion finding=call_arg_type_mismatch source_type=i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_cast_nullable_to_nonnull pass=nullability finding=nullable_to_nonnull") != null);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    try mir.verifyBuiltMir(typed_mir, &reporter);

    var found_return_mismatch = false;
    var found_no_implicit = false;
    var found_pointer_conversion = false;
    var found_c_void_conversion = false;
    var found_condition = false;
    var found_for_base = false;
    var found_index_base = false;
    var found_index_operand = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_RETURN_TYPE_MISMATCH") != null) found_return_mismatch = true;
        if (std.mem.indexOf(u8, diag.message, "E_NO_IMPLICIT_CONVERSION") != null) found_no_implicit = true;
        if (std.mem.indexOf(u8, diag.message, "E_NO_IMPLICIT_POINTER_CONVERSION") != null) found_pointer_conversion = true;
        if (std.mem.indexOf(u8, diag.message, "E_C_VOID_CONVERSION") != null) found_c_void_conversion = true;
        if (std.mem.indexOf(u8, diag.message, "E_CONDITION_NOT_BOOL") != null) found_condition = true;
        if (std.mem.indexOf(u8, diag.message, "E_FOR_BASE_NOT_ARRAY_OR_SLICE") != null) found_for_base = true;
        if (std.mem.indexOf(u8, diag.message, "E_INDEX_BASE_NOT_ARRAY_OR_SLICE") != null) found_index_base = true;
        if (std.mem.indexOf(u8, diag.message, "E_INDEX_NOT_USIZE") != null) found_index_operand = true;
    }
    try std.testing.expect(found_return_mismatch);
    try std.testing.expect(found_no_implicit);
    try std.testing.expect(found_pointer_conversion);
    try std.testing.expect(found_c_void_conversion);
    try std.testing.expect(found_condition);
    try std.testing.expect(found_for_base);
    try std.testing.expect(found_index_base);
    try std.testing.expect(found_index_operand);
}

test "MIR verifier reports invalid assignment targets for immutable locals and const views" {
    const source =
        \\extern struct Packet {
        \\    value: u32,
        \\}
        \\
        \\extern fn local_array() -> [4]u32;
        \\
        \\fn accept_assign_to_var() -> u32 {
        \\    var x: u32 = 1;
        \\    x = 2;
        \\    return x;
        \\}
        \\
        \\fn reject_assign_to_let() -> u32 {
        \\    let x: u32 = 1;
        \\    x = 2;
        \\    return x;
        \\}
        \\
        \\fn reject_assign_to_param(x: u32) -> u32 {
        \\    x = 2;
        \\    return x;
        \\}
        \\
        \\fn reject_assign_to_param_field(packet: Packet) -> u32 {
        \\    packet.value = 2;
        \\    return packet.value;
        \\}
        \\
        \\fn reject_assign_to_let_array_element(i: usize, value: u32) -> u32 {
        \\    let xs = local_array();
        \\    xs[i] = value;
        \\    return xs[i];
        \\}
        \\
        \\fn reject_assign_through_const_pointer(p: *const u32, value: u32) -> void {
        \\    p.* = value;
        \\}
        \\
        \\fn reject_assign_through_const_slice(xs: []const u32, i: usize, value: u32) -> void {
        \\    xs[i] = value;
        \\}
        \\
        \\fn reject_assign_field_through_const_pointer(packet: *const Packet, value: u32) -> void {
        \\    packet.*.value = value;
        \\}
        \\
        \\fn reject_assign_through_cast_const_pointer(p: *mut u32, value: u32) -> void {
        \\    (p as *const u32).* = value;
        \\}
        \\
        \\fn reject_assign_through_cast_const_raw_many(p: [*]mut u32, value: u32) -> void {
        \\    (p as [*]const u32).* = value;
        \\}
        \\
        \\fn reject_assign_through_cast_const_slice(xs: []mut u32, i: usize, value: u32) -> void {
        \\    (xs as []const u32)[i] = value;
        \\}
        \\
        \\fn reject_assign_field_through_cast_const_pointer(packet: *mut Packet, value: u32) -> void {
        \\    (packet as *const Packet).*.value = value;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_assignment_targets.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFactsFromDecls(std.testing.allocator, module.decls, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_assign_to_var pass=core finding=assign_") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assign_to_let pass=core finding=assign_to_immutable_local") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assign_to_param pass=core finding=assign_to_immutable_local") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assign_to_param_field pass=core finding=assign_to_immutable_local") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assign_to_let_array_element pass=core finding=assign_to_immutable_local") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assign_through_const_pointer pass=core finding=assign_through_const_view") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assign_through_const_slice pass=core finding=assign_through_const_view") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assign_field_through_const_pointer pass=core finding=assign_through_const_view") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assign_through_cast_const_pointer pass=core finding=assign_through_const_view") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assign_through_cast_const_raw_many pass=core finding=assign_through_const_view") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assign_through_cast_const_slice pass=core finding=assign_through_const_view") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assign_field_through_cast_const_pointer pass=core finding=assign_through_const_view") != null);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    try mir.verifyBuiltMir(typed_mir, &reporter);
    var found_immutable = false;
    var found_const_view = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_ASSIGN_TO_IMMUTABLE_LOCAL") != null) found_immutable = true;
        if (std.mem.indexOf(u8, diag.message, "E_ASSIGN_THROUGH_CONST_VIEW") != null) found_const_view = true;
    }
    try std.testing.expect(found_immutable);
    try std.testing.expect(found_const_view);
}

test "MIR verifier reports integer literal range conversions" {
    const source =
        \\extern fn takes_u8(value: u8) -> void;
        \\
        \\fn accept_literals() -> u8 {
        \\    let a: u8 = 255;
        \\    let b: i8 = -128;
        \\    takes_u8(0xff);
        \\    return 255;
        \\}
        \\
        \\fn reject_return_literal() -> u8 {
        \\    return 256;
        \\}
        \\
        \\fn reject_local_literal() -> u8 {
        \\    let y: u8 = 0x100;
        \\    return 0;
        \\}
        \\
        \\fn reject_negative_unsigned() -> u8 {
        \\    let y: u8 = -1;
        \\    return 0;
        \\}
        \\
        \\fn reject_i8_high() -> i8 {
        \\    let y: i8 = 128;
        \\    return 0;
        \\}
        \\
        \\fn reject_i8_low() -> i8 {
        \\    let y: i8 = -129;
        \\    return 0;
        \\}
        \\
        \\fn reject_assignment_literal() -> void {
        \\    var y: u8 = 0;
        \\    y = 300;
        \\}
        \\
        \\fn reject_call_arg_literal() -> void {
        \\    takes_u8(999);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_integer_literals.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFactsFromDecls(std.testing.allocator, module.decls, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_literals pass=conversion") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_return_literal pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_local_literal pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_negative_unsigned pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_i8_high pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_i8_low pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assignment_literal pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_call_arg_literal pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    try mir.verifyBuiltMir(typed_mir, &reporter);

    var found_literal_range = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_INTEGER_LITERAL_OUT_OF_RANGE") != null) found_literal_range = true;
    }
    try std.testing.expect(found_literal_range);
}

test "MIR verifier recurses into target typed aggregate literal conversions" {
    const source =
        \\struct Packet {
        \\    tag: u8,
        \\    ptr: *mut u8,
        \\    bytes: [2]u8,
        \\}
        \\
        \\struct PtrPacket {
        \\    ptr: *mut u8,
        \\}
        \\
        \\packed bits Flags: u8 {
        \\    ready: bool,
        \\    busy: bool,
        \\}
        \\
        \\type Byte = u8;
        \\type Bytes = [2]Byte;
        \\type PacketAlias = Packet;
        \\type BytePtr = *mut Byte;
        \\type FlagsAlias = Flags;
        \\
        \\extern fn make_ptr() -> *mut u8;
        \\extern fn make_alias_ptr() -> BytePtr;
        \\extern fn take_bytes(value: [2]u8) -> void;
        \\extern fn take_alias_bytes(value: Bytes) -> void;
        \\extern fn take_flags(value: FlagsAlias) -> void;
        \\
        \\fn accept_aggregate_literals() -> Packet {
        \\    let xs: [2]u8 = .{1, 2};
        \\    return .{ .tag = 255, .ptr = make_ptr(), .bytes = xs };
        \\}
        \\
        \\fn accept_pointer_aggregate_field(cell: u8) -> PtrPacket {
        \\    return .{ .ptr = &cell };
        \\}
        \\
        \\fn accept_pointer_aggregate_element(cell: u8) -> [2]*mut u8 {
        \\    return .{ &cell, &cell };
        \\}
        \\
        \\fn accept_member_aggregate_field(packet: Packet) -> PtrPacket {
        \\    return .{ .ptr = packet.ptr };
        \\}
        \\
        \\fn accept_index_aggregate_field(values: [2]*mut u8) -> PtrPacket {
        \\    return .{ .ptr = values[0] };
        \\}
        \\
        \\fn reject_struct_fields() -> Packet {
        \\    return .{ .tag = 300, .ptr = null, .bytes = .{1, 999} };
        \\}
        \\
        \\fn reject_local_array_element() -> void {
        \\    let xs: [2]u8 = .{1, 300};
        \\}
        \\
        \\fn reject_assignment_array_element() -> void {
        \\    var xs: [2]u8 = uninit;
        \\    xs = .{1, 400};
        \\}
        \\
        \\fn reject_call_array_element() -> void {
        \\    take_bytes(.{1, 500});
        \\}
        \\
        \\fn reject_short_array() -> [2]u8 {
        \\    return .{1};
        \\}
        \\
        \\fn reject_long_array() -> [2]u8 {
        \\    return .{1, 2, 3};
        \\}
        \\
        \\fn reject_missing_struct_field() -> Packet {
        \\    return .{ .tag = 1, .ptr = make_ptr() };
        \\}
        \\
        \\fn reject_duplicate_struct_field() -> Packet {
        \\    return .{ .tag = 1, .ptr = make_ptr(), .tag = 2, .bytes = .{1, 2} };
        \\}
        \\
        \\fn reject_unknown_struct_field() -> Packet {
        \\    return .{ .tag = 1, .ptr = make_ptr(), .extra = 2, .bytes = .{1, 2} };
        \\}
        \\
        \\fn accept_alias_aggregate_literals() -> PacketAlias {
        \\    let xs: Bytes = .{1, 2};
        \\    return .{ .tag = 3, .ptr = make_alias_ptr(), .bytes = xs };
        \\}
        \\
        \\fn reject_alias_array_element() -> Bytes {
        \\    return .{1, 600};
        \\}
        \\
        \\fn reject_alias_struct_fields() -> PacketAlias {
        \\    return .{ .tag = 700, .ptr = null, .bytes = .{1, 2} };
        \\}
        \\
        \\fn reject_alias_call_array_element() -> void {
        \\    take_alias_bytes(.{1, 800});
        \\}
        \\
        \\fn reject_cast_array_element() -> Bytes {
        \\    return (.{1, 900} as Bytes);
        \\}
        \\
        \\fn reject_cast_short_array() -> Bytes {
        \\    return (.{1} as Bytes);
        \\}
        \\
        \\fn reject_cast_struct_fields() -> PacketAlias {
        \\    return (.{ .tag = 901, .ptr = null, .bytes = .{1, 2} } as PacketAlias);
        \\}
        \\
        \\fn reject_cast_missing_struct_field() -> PacketAlias {
        \\    return (.{ .tag = 1, .ptr = make_ptr() } as PacketAlias);
        \\}
        \\
        \\fn accept_packed_bits_literals() -> FlagsAlias {
        \\    let flags: FlagsAlias = .{ .ready = true, .busy = false };
        \\    take_flags(.{ .ready = flags.ready, .busy = true });
        \\    return flags;
        \\}
        \\
        \\fn reject_packed_bits_field_type() -> FlagsAlias {
        \\    return .{ .ready = 1, .busy = false };
        \\}
        \\
        \\fn reject_packed_bits_missing_field() -> FlagsAlias {
        \\    return .{ .ready = true };
        \\}
        \\
        \\fn reject_packed_bits_duplicate_field() -> FlagsAlias {
        \\    return .{ .ready = true, .ready = false, .busy = false };
        \\}
        \\
        \\fn reject_packed_bits_unknown_field() -> FlagsAlias {
        \\    return .{ .ready = true, .missing = false, .busy = false };
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_aggregate_literals.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFactsFromDecls(std.testing.allocator, module.decls, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_aggregate_literals pass=conversion") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_aggregate_literals pass=nullability") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_pointer_aggregate_field pass=representation finding=representation_use detail=aggregate_field type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_pointer_aggregate_element pass=representation finding=representation_use detail=aggregate_element type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_member_aggregate_field pass=representation finding=representation_use detail=aggregate_field type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_index_aggregate_field pass=representation finding=representation_use detail=aggregate_field type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_struct_fields pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_struct_fields pass=nullability finding=null_to_nonnull") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_local_array_element pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assignment_array_element pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_call_array_element pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_short_array pass=aggregate finding=array_literal_length type=array") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_long_array pass=aggregate finding=array_literal_length type=array") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_missing_struct_field pass=aggregate finding=struct_literal_missing_field type=Packet") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_duplicate_struct_field pass=aggregate finding=struct_literal_duplicate_field type=Packet") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_unknown_struct_field pass=aggregate finding=struct_literal_unknown_field type=Packet") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_alias_aggregate_literals pass=conversion") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_alias_aggregate_literals pass=nullability") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_alias_array_element pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_alias_struct_fields pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_alias_struct_fields pass=nullability finding=null_to_nonnull") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_alias_call_array_element pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_cast_array_element pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_cast_short_array pass=aggregate finding=array_literal_length type=array") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_cast_struct_fields pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_cast_struct_fields pass=nullability finding=null_to_nonnull") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_cast_missing_struct_field pass=aggregate finding=struct_literal_missing_field type=Packet") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_packed_bits_literals pass=conversion") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_packed_bits_literals pass=aggregate") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_packed_bits_field_type pass=conversion finding=return_type_mismatch source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_packed_bits_missing_field pass=aggregate finding=struct_literal_missing_field type=Flags") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_packed_bits_duplicate_field pass=aggregate finding=struct_literal_duplicate_field type=Flags") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_packed_bits_unknown_field pass=aggregate finding=struct_literal_unknown_field type=Flags") != null);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    try mir.verifyBuiltMir(typed_mir, &reporter);

    var found_literal_range = false;
    var found_null_to_nonnull = false;
    var found_array_length = false;
    var found_missing_field = false;
    var found_duplicate_field = false;
    var found_unknown_field = false;
    var found_return_mismatch = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_INTEGER_LITERAL_OUT_OF_RANGE") != null) found_literal_range = true;
        if (std.mem.indexOf(u8, diag.message, "E_NULL_NON_NULL_POINTER") != null) found_null_to_nonnull = true;
        if (std.mem.indexOf(u8, diag.message, "E_ARRAY_LITERAL_LENGTH") != null) found_array_length = true;
        if (std.mem.indexOf(u8, diag.message, "E_STRUCT_LITERAL_MISSING_FIELD") != null) found_missing_field = true;
        if (std.mem.indexOf(u8, diag.message, "E_DUPLICATE_STRUCT_LITERAL_FIELD") != null) found_duplicate_field = true;
        if (std.mem.indexOf(u8, diag.message, "E_UNKNOWN_STRUCT_FIELD") != null) found_unknown_field = true;
        if (std.mem.indexOf(u8, diag.message, "E_RETURN_TYPE_MISMATCH") != null) found_return_mismatch = true;
    }
    try std.testing.expect(found_literal_range);
    try std.testing.expect(found_null_to_nonnull);
    try std.testing.expect(found_array_length);
    try std.testing.expect(found_missing_field);
    try std.testing.expect(found_duplicate_field);
    try std.testing.expect(found_unknown_field);
    try std.testing.expect(found_return_mismatch);
}

test "MIR verifier validates typed global aggregate initializers" {
    const source =
        \\struct GlobalPacket {
        \\    tag: u8,
        \\    ptr: *mut u8,
        \\    bytes: [2]u8,
        \\}
        \\
        \\packed bits GlobalFlags: u8 {
        \\    ready: bool,
        \\    busy: bool,
        \\}
        \\
        \\type GlobalBytes = [2]u8;
        \\type GlobalPacketAlias = GlobalPacket;
        \\type GlobalFlagsAlias = GlobalFlags;
        \\
        \\global ok_bytes: GlobalBytes = .{1, 2};
        \\global ok_raw_flags: GlobalFlagsAlias = 0xff;
        \\global reject_global_array_element: GlobalBytes = .{1, 300};
        \\global reject_global_array_shape: GlobalBytes = .{1};
        \\global reject_global_struct_fields: GlobalPacketAlias = .{ .tag = 400, .ptr = null, .bytes = .{1, 999} };
        \\global reject_global_struct_missing: GlobalPacketAlias = .{ .tag = 1, .ptr = null };
        \\global reject_global_flags_type: GlobalFlagsAlias = .{ .ready = 1, .busy = false };
        \\global reject_global_flags_missing: GlobalFlagsAlias = .{ .ready = true };
        \\global reject_raw_flags_range: GlobalFlagsAlias = 0x100;
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_global_aggregates.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFactsFromDecls(std.testing.allocator, module.decls, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=ok_bytes pass=conversion") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=ok_bytes pass=aggregate") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=ok_raw_flags pass=conversion") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_global_array_element pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_global_array_shape pass=aggregate finding=array_literal_length type=array") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_global_struct_fields pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_global_struct_fields pass=nullability finding=null_to_nonnull") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_global_struct_missing pass=aggregate finding=struct_literal_missing_field type=GlobalPacket") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_global_flags_type pass=conversion finding=initializer_type_mismatch source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_global_flags_missing pass=aggregate finding=struct_literal_missing_field type=GlobalFlags") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_raw_flags_range pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    try mir.verifyBuiltMir(typed_mir, &reporter);

    var found_literal_range = false;
    var found_array_length = false;
    var found_null_to_nonnull = false;
    var found_missing_field = false;
    var found_no_implicit = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_INTEGER_LITERAL_OUT_OF_RANGE") != null) found_literal_range = true;
        if (std.mem.indexOf(u8, diag.message, "E_ARRAY_LITERAL_LENGTH") != null) found_array_length = true;
        if (std.mem.indexOf(u8, diag.message, "E_NULL_NON_NULL_POINTER") != null) found_null_to_nonnull = true;
        if (std.mem.indexOf(u8, diag.message, "E_STRUCT_LITERAL_MISSING_FIELD") != null) found_missing_field = true;
        if (std.mem.indexOf(u8, diag.message, "E_NO_IMPLICIT_CONVERSION") != null) found_no_implicit = true;
    }
    try std.testing.expect(found_literal_range);
    try std.testing.expect(found_array_length);
    try std.testing.expect(found_null_to_nonnull);
    try std.testing.expect(found_missing_field);
    try std.testing.expect(found_no_implicit);
}

test "MIR verifier reports unhandled Result expressions and locals" {
    const source =
        \\extern fn make_result_u32() -> Result<u32, Error>;
        \\
        \\fn reject_unhandled_result_statement() -> void {
        \\    make_result_u32();
        \\}
        \\
        \\fn reject_unhandled_result_local() -> void {
        \\    let result = make_result_u32();
        \\}
        \\
        \\fn reject_defer_unhandled_result() -> void {
        \\    defer make_result_u32();
        \\}
        \\
        \\fn reject_switch_arm_unhandled_result(flag: bool) -> void {
        \\    switch flag {
        \\        true => make_result_u32(),
        \\        false => {},
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_result_unhandled.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFactsFromDecls(std.testing.allocator, module.decls, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_unhandled_result_statement pass=result finding=unhandled_result") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_unhandled_result_local pass=result finding=unhandled_result") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_defer_unhandled_result pass=result finding=unhandled_result") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_switch_arm_unhandled_result pass=result finding=unhandled_result") != null);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    try mir.verifyBuiltMir(typed_mir, &reporter);
    var unhandled_count: usize = 0;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_UNHANDLED_RESULT") != null) unhandled_count += 1;
    }
    try std.testing.expect(unhandled_count >= 4);
}

test "MIR verifier accepts Result locals handled by try if-let-else and switch" {
    const source =
        \\struct ResultBox {
        \\    value: u32,
        \\}
        \\
        \\extern fn make_result_u32() -> Result<u32, Error>;
        \\
        \\fn accept_handled_result_local() -> u32 {
        \\    let result = make_result_u32();
        \\    return result?;
        \\}
        \\
        \\fn accept_if_let_else_result() -> void {
        \\    let result = make_result_u32();
        \\    if let ok(value) = result {
        \\        let copy: u32 = value;
        \\    } else {
        \\        let fallback: u32 = 0;
        \\    }
        \\}
        \\
        \\fn accept_result_switch_handles_both_tags() -> void {
        \\    let result = make_result_u32();
        \\    switch result {
        \\        ok(value) => {
        \\            let copy: u32 = value;
        \\        },
        \\        err(e) => {
        \\            let fallback: u32 = 0;
        \\        },
        \\    }
        \\}
        \\
        \\fn accept_array_literal_result_local() -> void {
        \\    let result = make_result_u32();
        \\    let values: [1]u32 = .{ result? };
        \\}
        \\
        \\fn accept_struct_literal_result_local() -> void {
        \\    let result = make_result_u32();
        \\    let boxed: ResultBox = .{ .value = result? };
        \\}
        \\
        \\fn accept_switch_arm_body_result_local(flag: bool) -> u32 {
        \\    let result = make_result_u32();
        \\    switch flag {
        \\        true => {
        \\            return result?;
        \\        },
        \\        false => {
        \\            return 0;
        \\        },
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_result_handled.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFactsFromDecls(std.testing.allocator, module.decls, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "pass=result finding=unhandled_result") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_handled_result_local pass=result finding=try_handled") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_array_literal_result_local pass=result finding=try_handled") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_struct_literal_result_local pass=result finding=try_handled") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_switch_arm_body_result_local pass=result finding=try_handled") != null);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    try mir.verifyBuiltMir(typed_mir, &reporter);
    try std.testing.expect(!reporter.has_errors);
}

test "MIR verifier reports invalid if-let and switch Result patterns" {
    const source =
        \\extern fn make_result_u32() -> Result<u32, Error>;
        \\
        \\enum Status {
        \\    ready,
        \\    waiting,
        \\}
        \\
        \\fn reject_if_let_optional_required(value: u32) -> void {
        \\    if let x = value {
        \\    }
        \\}
        \\
        \\fn reject_if_let_result_required(maybe: ?*mut u8) -> void {
        \\    if let ok(value) = maybe {
        \\    }
        \\}
        \\
        \\fn reject_if_let_result_tag(result: Result<u32, Error>) -> void {
        \\    if let ready(value) = result {
        \\    }
        \\}
        \\
        \\fn reject_if_let_narrow_pattern(status: Status) -> void {
        \\    if let .ready = status {
        \\    }
        \\}
        \\
        \\fn reject_switch_result_tag(result: Result<u32, Error>) -> void {
        \\    switch result {
        \\        ready(value) => {},
        \\        _ => {},
        \\    }
        \\}
        \\
        \\fn reject_switch_result_required(value: u32) -> void {
        \\    switch value {
        \\        .ok => {},
        \\        _ => {},
        \\    }
        \\}
        \\
        \\fn reject_switch_multi_binding_arm(result: Result<u32, Error>) -> void {
        \\    switch result {
        \\        ok(value), err(error_value) => {},
        \\        _ => {},
        \\    }
        \\}
        \\
        \\fn accept_valid_result_patterns() -> void {
        \\    let result = make_result_u32();
        \\    if let ok(value) = result {
        \\    }
        \\    switch result {
        \\        ok(value) => {},
        \\        err(error_value) => {},
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_branch_patterns.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFactsFromDecls(std.testing.allocator, module.decls, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_if_let_optional_required pass=result finding=if_let_optional_required") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_if_let_result_required pass=result finding=if_let_result_required") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_if_let_result_tag pass=result finding=if_let_result_tag") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_if_let_narrow_pattern pass=result finding=if_let_narrow_pattern") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_switch_result_tag pass=result finding=switch_result_tag") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_switch_result_required pass=result finding=switch_result_required") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_switch_multi_binding_arm pass=result finding=switch_multi_binding_arm") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_valid_result_patterns pass=result finding=if_let_") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_valid_result_patterns pass=result finding=switch_") == null);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    try mir.verifyBuiltMir(typed_mir, &reporter);
    var found_if_optional = false;
    var found_if_required = false;
    var found_if_tag = false;
    var found_if_narrow = false;
    var found_switch_tag = false;
    var found_switch_required = false;
    var found_switch_multi = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_IF_LET_OPTIONAL_REQUIRED") != null) found_if_optional = true;
        if (std.mem.indexOf(u8, diag.message, "E_IF_LET_RESULT_REQUIRED") != null) found_if_required = true;
        if (std.mem.indexOf(u8, diag.message, "E_IF_LET_RESULT_TAG") != null) found_if_tag = true;
        if (std.mem.indexOf(u8, diag.message, "E_IF_LET_NARROW_PATTERN") != null) found_if_narrow = true;
        if (std.mem.indexOf(u8, diag.message, "E_SWITCH_RESULT_TAG") != null) found_switch_tag = true;
        if (std.mem.indexOf(u8, diag.message, "E_SWITCH_RESULT_REQUIRED") != null) found_switch_required = true;
        if (std.mem.indexOf(u8, diag.message, "E_SWITCH_MULTI_BINDING_ARM") != null) found_switch_multi = true;
    }
    try std.testing.expect(found_if_optional);
    try std.testing.expect(found_if_required);
    try std.testing.expect(found_if_tag);
    try std.testing.expect(found_if_narrow);
    try std.testing.expect(found_switch_tag);
    try std.testing.expect(found_switch_required);
    try std.testing.expect(found_switch_multi);
}

test "MIR verifier reports duplicate switch cases" {
    const source =
        \\fn reject_bool_duplicate(flag: bool) -> void {
        \\    switch flag {
        \\        true => {},
        \\        true => {},
        \\        false => {},
        \\    }
        \\}
        \\
        \\fn reject_integer_duplicate(value: u32) -> void {
        \\    switch value {
        \\        1 => {},
        \\        0x1 => {},
        \\        _ => {},
        \\    }
        \\}
        \\
        \\fn reject_result_duplicate(result: Result<u32, Error>) -> void {
        \\    switch result {
        \\        ok(value) => {},
        \\        .ok => {},
        \\        err(error_value) => {},
        \\    }
        \\}
        \\
        \\fn reject_case_after_wildcard(value: u32) -> void {
        \\    switch value {
        \\        _ => {},
        \\        2 => {},
        \\    }
        \\}
        \\
        \\fn reject_same_arm_wildcard_cover(value: u32) -> void {
        \\    switch value {
        \\        _, 3 => {},
        \\    }
        \\}
        \\
        \\fn accept_distinct_switches(flag: bool, value: u32, result: Result<u32, Error>) -> void {
        \\    switch flag {
        \\        true => {},
        \\        false => {},
        \\    }
        \\    switch value {
        \\        1 => {},
        \\        2 => {},
        \\        _ => {},
        \\    }
        \\    switch result {
        \\        ok(value) => {},
        \\        err(error_value) => {},
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_switch_duplicates.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFactsFromDecls(std.testing.allocator, module.decls, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_bool_duplicate pass=core finding=duplicate_switch_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_integer_duplicate pass=core finding=duplicate_switch_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_result_duplicate pass=core finding=duplicate_switch_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_case_after_wildcard pass=core finding=duplicate_switch_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_same_arm_wildcard_cover pass=core finding=duplicate_switch_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_distinct_switches pass=core finding=duplicate_switch_case") == null);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    try mir.verifyBuiltMir(typed_mir, &reporter);
    var duplicate_count: usize = 0;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_DUPLICATE_SWITCH_CASE") != null) duplicate_count += 1;
    }
    try std.testing.expect(duplicate_count >= 5);
}

test "MIR verifier reports switch literal pattern type mismatches" {
    const source =
        \\enum Irq {
        \\    timer,
        \\    keyboard,
        \\}
        \\
        \\fn reject_bool_switch_integer_pattern(flag: bool) -> void {
        \\    switch flag {
        \\        1 => {},
        \\        _ => {},
        \\    }
        \\}
        \\
        \\fn reject_integer_switch_bool_pattern(value: u32) -> void {
        \\    switch value {
        \\        true => {},
        \\        _ => {},
        \\    }
        \\}
        \\
        \\fn reject_enum_switch_literal_pattern(irq: Irq) -> void {
        \\    switch irq {
        \\        1 => {},
        \\        _ => {},
        \\    }
        \\}
        \\
        \\fn accept_scalar_switch_literals(flag: bool, value: u32) -> void {
        \\    switch flag {
        \\        true => {},
        \\        false => {},
        \\    }
        \\    switch value {
        \\        1 => {},
        \\        2 => {},
        \\        _ => {},
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_switch_literal_patterns.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFactsFromDecls(std.testing.allocator, module.decls, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_bool_switch_integer_pattern pass=core finding=switch_literal_type_mismatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_integer_switch_bool_pattern pass=core finding=switch_literal_type_mismatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_enum_switch_literal_pattern pass=core finding=switch_literal_type_mismatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_scalar_switch_literals pass=core finding=switch_literal_type_mismatch") == null);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    try mir.verifyBuiltMir(typed_mir, &reporter);
    var mismatch_count: usize = 0;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_NO_IMPLICIT_CONVERSION") != null) mismatch_count += 1;
    }
    try std.testing.expect(mismatch_count >= 3);
}

test "MIR verifier validates enum switch cases and closed enum exhaustiveness" {
    const source =
        \\enum Irq {
        \\    timer,
        \\    keyboard,
        \\}
        \\
        \\open enum OpenError: u8 {
        \\    fault = 1,
        \\    busy = 2,
        \\}
        \\
        \\fn reject_closed_enum_nonexhaustive(irq: Irq) -> void {
        \\    switch irq {
        \\        .timer => {},
        \\    }
        \\}
        \\
        \\fn reject_closed_enum_unknown_case(irq: Irq) -> void {
        \\    switch irq {
        \\        .missing => {},
        \\        _ => {},
        \\    }
        \\}
        \\
        \\fn reject_open_enum_unknown_case(error_value: OpenError) -> void {
        \\    switch error_value {
        \\        .missing => {},
        \\        _ => {},
        \\    }
        \\}
        \\
        \\fn reject_enum_duplicate_case(irq: Irq) -> void {
        \\    switch irq {
        \\        .timer => {},
        \\        .timer => {},
        \\        .keyboard => {},
        \\    }
        \\}
        \\
        \\fn accept_closed_enum_exhaustive(irq: Irq) -> void {
        \\    switch irq {
        \\        .timer => {},
        \\        .keyboard => {},
        \\    }
        \\}
        \\
        \\fn accept_closed_enum_wildcard(irq: Irq) -> void {
        \\    switch irq {
        \\        .timer => {},
        \\        _ => {},
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_enum_switch.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFactsFromDecls(std.testing.allocator, module.decls, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_closed_enum_nonexhaustive pass=core finding=closed_enum_switch_exhaustive") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_closed_enum_unknown_case pass=core finding=unknown_enum_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_open_enum_unknown_case pass=core finding=unknown_enum_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_enum_duplicate_case pass=core finding=duplicate_switch_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_closed_enum_exhaustive pass=representation finding=representation_use detail=switch_subject type=Irq") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_closed_enum_exhaustive pass=core") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_closed_enum_wildcard pass=core") == null);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    try mir.verifyBuiltMir(typed_mir, &reporter);
    var found_nonexhaustive = false;
    var found_unknown = false;
    var found_duplicate = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_CLOSED_ENUM_SWITCH_EXHAUSTIVE") != null) found_nonexhaustive = true;
        if (std.mem.indexOf(u8, diag.message, "E_UNKNOWN_ENUM_CASE") != null) found_unknown = true;
        if (std.mem.indexOf(u8, diag.message, "E_DUPLICATE_SWITCH_CASE") != null) found_duplicate = true;
    }
    try std.testing.expect(found_nonexhaustive);
    try std.testing.expect(found_unknown);
    try std.testing.expect(found_duplicate);
}

test "MIR verifier validates tagged union switch cases" {
    const source =
        \\union Token {
        \\    int: i64,
        \\    ident: []const u8,
        \\    eof,
        \\}
        \\
        \\type TokenAlias = Token;
        \\
        \\fn reject_unknown_union_case(token: Token) -> void {
        \\    switch token {
        \\        .missing => {},
        \\        .int => {},
        \\        .ident => {},
        \\        .eof => {},
        \\    }
        \\}
        \\
        \\fn reject_payloadless_union_case_binding(token: Token) -> void {
        \\    switch token {
        \\        int(value) => {},
        \\        ident(name) => {},
        \\        eof(value) => {},
        \\    }
        \\}
        \\
        \\fn reject_duplicate_union_case(token: TokenAlias) -> void {
        \\    switch token {
        \\        int(value) => {},
        \\        .int => {},
        \\        .ident => {},
        \\        .eof => {},
        \\    }
        \\}
        \\
        \\fn accept_union_patterns(token: TokenAlias) -> void {
        \\    switch token {
        \\        int(value) => {},
        \\        ident(name) => {},
        \\        .eof => {},
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_union_switch.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFactsFromDecls(std.testing.allocator, module.decls, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_unknown_union_case pass=core finding=unknown_union_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_payloadless_union_case_binding pass=core finding=union_case_has_no_payload") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_duplicate_union_case pass=core finding=duplicate_switch_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_union_patterns pass=core") == null);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    try mir.verifyBuiltMir(typed_mir, &reporter);
    var found_unknown = false;
    var found_payloadless = false;
    var found_duplicate = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_UNKNOWN_UNION_CASE") != null) found_unknown = true;
        if (std.mem.indexOf(u8, diag.message, "E_UNION_CASE_HAS_NO_PAYLOAD") != null) found_payloadless = true;
        if (std.mem.indexOf(u8, diag.message, "E_DUPLICATE_SWITCH_CASE") != null) found_duplicate = true;
    }
    try std.testing.expect(found_unknown);
    try std.testing.expect(found_payloadless);
    try std.testing.expect(found_duplicate);
}

test "MIR verifier reports Result reassignment and invalid try operands" {
    const source =
        \\extern fn make_result_u32() -> Result<u32, Error>;
        \\extern fn make_void() -> void;
        \\
        \\fn reject_overwrite_unhandled_result() -> u32 {
        \\    var result = make_result_u32();
        \\    result = make_result_u32();
        \\    return result?;
        \\}
        \\
        \\fn accept_assignment_handled_later() -> u32 {
        \\    var result: Result<u32, Error> = make_result_u32();
        \\    result?;
        \\    result = make_result_u32();
        \\    return result?;
        \\}
        \\
        \\fn reject_void_direct_call_try() -> void {
        \\    return make_void()?;
        \\}
        \\
        \\fn reject_integer_try(n: u32) -> u32 {
        \\    return n?;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_result_reassign_try.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFactsFromDecls(std.testing.allocator, module.decls, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_overwrite_unhandled_result pass=result finding=unhandled_result") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_assignment_handled_later pass=result finding=unhandled_result") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_void_direct_call_try pass=result finding=try_requires_result_or_nullable") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_integer_try pass=result finding=try_requires_result_or_nullable") != null);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    try mir.verifyBuiltMir(typed_mir, &reporter);
    var found_unhandled = false;
    var found_invalid_try = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_UNHANDLED_RESULT") != null) found_unhandled = true;
        if (std.mem.indexOf(u8, diag.message, "E_TRY_REQUIRES_RESULT_OR_NULLABLE") != null) found_invalid_try = true;
    }
    try std.testing.expect(found_unhandled);
    try std.testing.expect(found_invalid_try);
}

test "MIR verifier reports Result try payload return mismatches" {
    const source =
        \\extern fn make_result_u32() -> Result<u32, Error>;
        \\extern fn make_result_pointer() -> Result<*mut u8, Error>;
        \\extern fn make_result_c_void_pointer() -> Result<*mut c_void, Error>;
        \\extern fn make_result_u16_pointer() -> Result<*mut u16, Error>;
        \\extern fn make_result_bytes() -> Result<[2]u8, Error>;
        \\extern fn make_nullable_mut_pointer() -> ?*mut u8;
        \\extern fn make_nullable_c_void_pointer() -> ?*mut c_void;
        \\extern fn takes_const_pointer(value: *const u8) -> void;
        \\
        \\struct PointerBox {
        \\    ptr: *const u8,
        \\}
        \\
        \\fn accept_result_try_payload() -> u32 {
        \\    return make_result_u32()?;
        \\}
        \\
        \\fn accept_result_pointer_try_payload() -> *mut u8 {
        \\    return make_result_pointer()?;
        \\}
        \\
        \\fn accept_nullable_pointer_try_payload() -> *mut u8 {
        \\    return make_nullable_mut_pointer()?;
        \\}
        \\
        \\fn reject_result_try_payload() -> *mut u8 {
        \\    return make_result_u32()?;
        \\}
        \\
        \\fn reject_pointer_payload_to_integer() -> u32 {
        \\    return make_result_pointer()?;
        \\}
        \\
        \\fn accept_result_pointer_payload_const_narrow() -> *const u8 {
        \\    return make_result_pointer()?;
        \\}
        \\
        \\fn reject_result_pointer_payload_element_conversion() -> *mut u16 {
        \\    return make_result_pointer()?;
        \\}
        \\
        \\fn reject_result_c_void_payload_conversion() -> *mut u8 {
        \\    return make_result_c_void_pointer()?;
        \\}
        \\
        \\fn reject_result_typed_to_c_void_payload_conversion() -> *mut c_void {
        \\    return make_result_pointer()?;
        \\}
        \\
        \\fn accept_nullable_pointer_payload_const_narrow() -> *const u8 {
        \\    return make_nullable_mut_pointer()?;
        \\}
        \\
        \\fn reject_nullable_c_void_payload_conversion() -> *mut u8 {
        \\    return make_nullable_c_void_pointer()?;
        \\}
        \\
        \\fn accept_result_try_local_initializer_const_narrow() -> void {
        \\    let ptr: *const u8 = make_result_pointer()?;
        \\}
        \\
        \\fn accept_result_try_assignment_const_narrow(fallback: *const u8) -> void {
        \\    var ptr: *const u8 = fallback;
        \\    ptr = make_result_pointer()?;
        \\}
        \\
        \\fn accept_result_try_call_arg_const_narrow() -> void {
        \\    takes_const_pointer(make_result_pointer()?);
        \\}
        \\
        \\fn accept_result_try_aggregate_field_const_narrow() -> PointerBox {
        \\    return .{ .ptr = make_result_pointer()? };
        \\}
        \\
        \\fn accept_cast_result_try_payload_const_narrow() -> *const u8 {
        \\    return (make_result_pointer()? as *const u8);
        \\}
        \\
        \\fn accept_cast_result_try_local_initializer_const_narrow() -> void {
        \\    let ptr: *const u8 = (make_result_pointer()? as *const u8);
        \\}
        \\
        \\fn accept_cast_result_try_assignment_const_narrow(fallback: *const u8) -> void {
        \\    var ptr: *const u8 = fallback;
        \\    ptr = (make_result_pointer()? as *const u8);
        \\}
        \\
        \\fn accept_cast_result_try_call_arg_const_narrow() -> void {
        \\    takes_const_pointer(make_result_pointer()? as *const u8);
        \\}
        \\
        \\fn accept_cast_result_try_aggregate_field_const_narrow() -> PointerBox {
        \\    return .{ .ptr = make_result_pointer()? as *const u8 };
        \\}
        \\
        \\fn reject_inferred_result_array_try_index() -> *mut u8 {
        \\    let bytes = make_result_bytes()?;
        \\    return bytes[0];
        \\}
        \\
        \\fn reject_if_let_result_array_binding() -> *mut u8 {
        \\    if let ok(bytes) = make_result_bytes() {
        \\        return bytes[0];
        \\    } else {
        \\        return make_result_pointer()?;
        \\    }
        \\}
        \\
        \\fn reject_switch_result_array_binding() -> *mut u8 {
        \\    let result = make_result_bytes();
        \\    switch result {
        \\        ok(bytes) => {
        \\            return bytes[0];
        \\        },
        \\        err(e) => {
        \\            return make_result_pointer()?;
        \\        },
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_result_payload.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFactsFromDecls(std.testing.allocator, module.decls, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_result_try_payload pass=result finding=try_payload_type_mismatch") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_result_pointer_try_payload pass=result finding=try_payload_") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_nullable_pointer_try_payload pass=result finding=try_payload_") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_result_pointer_try_payload pass=representation finding=representation_use detail=try_unwrap type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_nullable_pointer_try_payload pass=representation finding=representation_use detail=try_unwrap type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_result_try_payload pass=result finding=try_payload_type_mismatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_pointer_payload_to_integer pass=result finding=try_payload_type_mismatch") != null);
    // G30: a `*mut T` try-payload const-narrows to `*const T` at every position (return, let,
    // assignment, call arg, aggregate field, and through an explicit `as`) — a safe no-op
    // coercion, so NO try_payload conversion finding is emitted for these.
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_result_pointer_payload_const_narrow pass=result finding=try_payload_") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_nullable_pointer_payload_const_narrow pass=result finding=try_payload_") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_result_try_local_initializer_const_narrow pass=result finding=try_payload_") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_result_try_assignment_const_narrow pass=result finding=try_payload_") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_result_try_call_arg_const_narrow pass=result finding=try_payload_") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_result_try_aggregate_field_const_narrow pass=result finding=try_payload_") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_cast_result_try_payload_const_narrow pass=result finding=try_payload_") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_cast_result_try_local_initializer_const_narrow pass=result finding=try_payload_") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_cast_result_try_assignment_const_narrow pass=result finding=try_payload_") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_cast_result_try_call_arg_const_narrow pass=result finding=try_payload_") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_cast_result_try_aggregate_field_const_narrow pass=result finding=try_payload_") == null);
    // Element mismatch + c_void payloads stay rejected (genuine incompatibilities).
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_result_pointer_payload_element_conversion pass=result finding=try_payload_pointer_conversion") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_result_c_void_payload_conversion pass=result finding=try_payload_c_void_conversion") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_result_typed_to_c_void_payload_conversion pass=result finding=try_payload_c_void_conversion") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_nullable_c_void_payload_conversion pass=result finding=try_payload_c_void_conversion") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_inferred_result_array_try_index pass=conversion finding=return_type_mismatch source_type=u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_if_let_result_array_binding pass=conversion finding=return_type_mismatch source_type=u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_switch_result_array_binding pass=conversion finding=return_type_mismatch source_type=u8") != null);

    var typed_mir = try mir.buildFromDecls(std.testing.allocator, module.decls);
    defer typed_mir.deinit();
    try mir.verifyBuiltMir(typed_mir, &reporter);
    var mismatch_count: usize = 0;
    var pointer_conversion_count: usize = 0;
    var c_void_conversion_count: usize = 0;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_RETURN_TYPE_MISMATCH") != null) mismatch_count += 1;
        if (std.mem.indexOf(u8, diag.message, "E_NO_IMPLICIT_POINTER_CONVERSION") != null) pointer_conversion_count += 1;
        if (std.mem.indexOf(u8, diag.message, "E_C_VOID_CONVERSION") != null) c_void_conversion_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), mismatch_count);
    // G30: the mut->const try-payload narrows are now allowed; only the genuine element
    // mismatch (`*mut u8` -> `*mut u16`) remains a pointer-conversion diagnostic.
    try std.testing.expectEqual(@as(usize, 1), pointer_conversion_count);
    try std.testing.expectEqual(@as(usize, 3), c_void_conversion_count);
}

test "MIR scalar switch plan owns normalized arm patterns" {
    const source =
        \\fn classify(n: i32) -> u32 {
        \\    switch n {
        \\        -1 => { return 1; },
        \\        0, 'A' => { return 2; },
        \\        _ => { return 3; },
        \\    }
        \\}
    ;
    var parsed = try test_support.parseModule("mir_scalar_switch_plan.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();

    const function = module_mir.functions[0];
    const plan = mir_statement_plan.buildScalarSwitchReturn(function) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("n", plan.subject_name);
    try std.testing.expectEqual(@as(usize, 3), plan.arm_count);
    try std.testing.expectEqual(@as(usize, 2), plan.default_arm_index);
    switch (plan.arms[0].patterns[0]) {
        .scalar => |value| {
            try std.testing.expect(value.negative);
            try std.testing.expectEqual(@as(u128, 1), value.magnitude);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (plan.arms[1].patterns[1]) {
        .scalar => |value| {
            try std.testing.expect(!value.negative);
            try std.testing.expectEqual(@as(u128, 'A'), value.magnitude);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (plan.arms[2].patterns[0]) {
        .wildcard => {},
        else => return error.TestUnexpectedResult,
    }

    var corrupted = false;
    for (module_mir.functions[0].blocks) |*block| {
        for (block.instructions) |*instruction| {
            if (instruction.typed_switch_pattern_count == 0) continue;
            instruction.typed_switch_patterns[0] = .unused;
            corrupted = true;
            break;
        }
        if (corrupted) break;
    }
    try std.testing.expect(corrupted);
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_scalar_switch_plan.mc", source);
    defer reporter.deinit();
    try mir.verifyBuiltMir(module_mir, &reporter);
    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, "E_MIR_IDENTITY") != null);
}
