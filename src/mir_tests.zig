const std = @import("std");

const diagnostics = @import("diagnostics.zig");
const parser = @import("parser.zig");
const mir = @import("mir.zig");

const Block = mir.Block;
const ContractRegion = mir.ContractRegion;
const Function = mir.Function;
const Instruction = mir.Instruction;
const Module = mir.Module;
const PointerProvenance = mir.PointerProvenance;
const PointerProvenanceInvalidationReason = mir.PointerProvenanceInvalidationReason;
const RangeFact = mir.RangeFact;
const TrapEdge = mir.TrapEdge;
const TrapKind = mir.TrapKind;
const ValueType = mir.ValueType;

fn functionByName(module: mir.Module, name: []const u8) ?mir.Function {
    for (module.functions) |function| {
        if (std.mem.eql(u8, function.name, name)) return function;
    }
    return null;
}

fn functionByNameMut(module: *mir.Module, name: []const u8) ?*mir.Function {
    for (module.functions) |*function| {
        if (std.mem.eql(u8, function.name, name)) return function;
    }
    return null;
}

fn functionHasInstruction(function: mir.Function, kind: mir.Instruction.Kind, detail: []const u8) bool {
    for (function.blocks) |block| {
        for (block.instructions) |instruction| {
            if (instruction.kind == kind and std.mem.eql(u8, instruction.detail, detail)) return true;
        }
    }
    return false;
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
    var typed_mir = try mir.build(std.testing.allocator, module);
    defer typed_mir.deinit();
    try mir.validateCallTargetFactsForLowering(typed_mir);

    const cases = [_]struct { name: []const u8, kind: mir.CallTargetKind }{
        .{ .name = "from_value", .kind = .conversion_from },
        .{ .name = "try_value", .kind = .conversion_try_from },
        .{ .name = "trap_value", .kind = .conversion_trap_from },
        .{ .name = "wrap_value", .kind = .conversion_wrap_from },
        .{ .name = "sat_value", .kind = .conversion_sat_from },
        .{ .name = "mod_value", .kind = .conversion_from_mod },
        .{ .name = "adapted_binary", .kind = .conversion_trap_from },
    };
    for (cases) |case| {
        const function = functionByName(typed_mir, case.name).?;
        try std.testing.expectEqual(@as(usize, 1), function.call_target_facts.len);
        try std.testing.expectEqual(case.kind, function.call_target_facts[0].kind);
        try std.testing.expectEqual(@as(usize, 2), function.target_type_facts.len);
        try std.testing.expectEqual(mir.TargetTypeKind.conversion_source, function.target_type_facts[0].kind);
        try std.testing.expectEqual(mir.TargetTypeKind.conversion_target, function.target_type_facts[1].kind);
    }
    try std.testing.expectEqualStrings("u32", valueTypeName(functionByName(typed_mir, "mod_value").?.target_type_facts[0].result_ty));
    try std.testing.expectEqualStrings("u64", valueTypeName(functionByName(typed_mir, "adapted_binary").?.target_type_facts[0].result_ty));
}

test "MIR owns target types for contextual constructors and literals" {
    const source =
        \\enum E { bad }
        \\struct Slot { cb: closure(u32) -> u32, result: Result<u32, E> }
        \\struct TextSlot { ptr: *const u8, bytes: []const u8 }
        \\struct FloatSlot { small: f32, wide: f64 }
        \\packed bits Flags: u8 { ready: bool }
        \\union Token { number: i64, eof, ok: u32 }
        \\union Event { mode: E }
        \\global default_error: E = .bad;
        \\global default_text: *const u8 = "global";
        \\global default_float: f32 = 1.25;
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
        \\fn make_float() -> f32 { return 1.5; }
        \\fn make_float_expr() -> f32 { return 1.7 * 2.3; }
        \\fn make_float_slot() -> FloatSlot { return .{ .small = 1.0, .wide = 2.0 }; }
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

    var typed_mir = try mir.build(std.testing.allocator, module);
    defer typed_mir.deinit();
    try mir.validateCallTargetFactsForLowering(typed_mir);
    try mir.validateTargetTypeFactsForLowering(typed_mir);

    const bind_fn = functionByName(typed_mir, "make_bind").?;
    try std.testing.expectEqual(@as(usize, 1), bind_fn.target_type_facts.len);
    try std.testing.expectEqual(mir.TargetTypeKind.bind, bind_fn.target_type_facts[0].kind);
    try std.testing.expect(bind_fn.target_type_facts[0].target_ty.kind == .closure_type);

    const ok_fn = functionByName(typed_mir, "make_ok").?;
    try std.testing.expectEqual(@as(usize, 1), ok_fn.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.result_ok, ok_fn.call_target_facts[0].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.result_ok, ok_fn.target_type_facts[0].kind);
    try std.testing.expect(ok_fn.target_type_facts[0].target_ty.kind == .generic);
    try std.testing.expectEqualStrings("Result", ok_fn.target_type_facts[0].target_ty.kind.generic.base.text);

    const err_fn = functionByName(typed_mir, "make_err").?;
    try std.testing.expectEqual(@as(usize, 1), err_fn.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.result_err, err_fn.call_target_facts[0].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.result_err, err_fn.target_type_facts[0].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.enum_literal, err_fn.target_type_facts[1].kind);
    const arg_fn = functionByName(typed_mir, "pass_ok").?;
    try std.testing.expectEqual(mir.TargetTypeKind.result_ok, arg_fn.target_type_facts[0].kind);
    const slot_fn = functionByName(typed_mir, "make_slot").?;
    try std.testing.expectEqual(@as(usize, 3), slot_fn.target_type_facts.len);
    try std.testing.expectEqual(mir.TargetTypeKind.struct_literal, slot_fn.target_type_facts[0].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.bind, slot_fn.target_type_facts[1].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.result_ok, slot_fn.target_type_facts[2].kind);
    try std.testing.expectEqual(@as(usize, 0), functionByName(typed_mir, "make_number").?.target_type_facts.len);
    try std.testing.expectEqual(mir.TargetTypeKind.tagged_union, functionByName(typed_mir, "make_eof").?.target_type_facts[0].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.tagged_union, functionByName(typed_mir, "make_union_ok").?.target_type_facts[0].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.enum_literal, functionByName(typed_mir, "make_enum").?.target_type_facts[0].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.enum_literal, functionByName(typed_mir, "compare_enum").?.target_type_facts[0].kind);
    const cast_enum_fn = functionByName(typed_mir, "cast_enum").?;
    try std.testing.expectEqual(@as(usize, 3), cast_enum_fn.target_type_facts.len);
    try std.testing.expectEqual(mir.TargetTypeKind.explicit_cast_source, cast_enum_fn.target_type_facts[0].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.explicit_cast_target, cast_enum_fn.target_type_facts[1].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.enum_literal, cast_enum_fn.target_type_facts[2].kind);
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
    try std.testing.expectEqual(mir.TargetTypeKind.struct_literal, functionByName(typed_mir, "make_flags").?.target_type_facts[0].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.float_literal, functionByName(typed_mir, "default_float").?.target_type_facts[0].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.float_literal, functionByName(typed_mir, "make_float").?.target_type_facts[0].kind);
    const float_expr_fn = functionByName(typed_mir, "make_float_expr").?;
    try std.testing.expectEqual(@as(usize, 2), float_expr_fn.target_type_facts.len);
    try std.testing.expectEqual(mir.TargetTypeKind.float_literal, float_expr_fn.target_type_facts[0].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.float_literal, float_expr_fn.target_type_facts[1].kind);
    const float_slot_fn = functionByName(typed_mir, "make_float_slot").?;
    try std.testing.expectEqual(mir.TargetTypeKind.struct_literal, float_slot_fn.target_type_facts[0].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.float_literal, float_slot_fn.target_type_facts[1].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.float_literal, float_slot_fn.target_type_facts[2].kind);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
    defer typed_mir.deinit();
    try mir.validateTargetTypeFactsForLowering(typed_mir);

    for ([_][]const u8{ "slice_return", "slice_local", "slice_argument", "pointer_return" }) |name| {
        const function = functionByName(typed_mir, name).?;
        try std.testing.expectEqual(@as(usize, 2), function.target_type_facts.len);
        try std.testing.expectEqual(mir.TargetTypeKind.view_const_narrow_source, function.target_type_facts[0].kind);
        try std.testing.expectEqual(mir.TargetTypeKind.view_const_narrow_target, function.target_type_facts[1].kind);
    }

    try std.testing.expectEqual(@as(usize, 0), functionByName(typed_mir, "slice_passthrough").?.target_type_facts.len);
    try std.testing.expectEqual(@as(usize, 0), functionByName(typed_mir, "raw_many_passthrough").?.target_type_facts.len);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
    defer typed_mir.deinit();
    try mir.validateTargetTypeFactsForLowering(typed_mir);

    const make = functionByName(typed_mir, "make").?;
    var qualified_count: usize = 0;
    for (make.target_type_facts) |fact| if (fact.kind == .qualified_union_result) {
        try std.testing.expectEqualStrings("Token", fact.target_ty.kind.name.text);
        qualified_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), qualified_count);

    const variant = functionByName(typed_mir, "variant").?;
    var variant_count: usize = 0;
    for (variant.target_type_facts) |fact| if (fact.kind == .enum_variant_path_result) {
        try std.testing.expectEqualStrings("E", fact.target_ty.kind.name.text);
        variant_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), variant_count);

    for (functionByName(typed_mir, "shadow").?.target_type_facts) |fact| {
        try std.testing.expect(fact.kind != .enum_variant_path_result);
    }
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
    var typed_mir = try mir.build(std.testing.allocator, module);
    defer typed_mir.deinit();
    try std.testing.expectEqual(mir.TargetTypeKind.dyn_coercion, functionByName(typed_mir, "as_dyn").?.target_type_facts[0].kind);
    const holder = functionByName(typed_mir, "hold").?;
    try std.testing.expectEqual(mir.TargetTypeKind.struct_literal, holder.target_type_facts[0].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.dyn_coercion, holder.target_type_facts[1].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.dyn_coercion, functionByName(typed_mir, "pass_arg").?.target_type_facts[0].kind);
    try std.testing.expectEqual(@as(usize, 0), functionByName(typed_mir, "pass_through").?.target_type_facts.len);
    try std.testing.expectEqual(@as(usize, 0), functionByName(typed_mir, "pass_nullable").?.target_type_facts.len);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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
    var base = try mir.build(std.testing.allocator, module);
    defer base.deinit();
    try std.testing.expectEqual(@as(usize, 1), functionByName(base, "const_index").?.trap_edges.len);
    try std.testing.expectEqual(@as(usize, 1), functionByName(base, "var_index").?.trap_edges.len);
    try std.testing.expectEqual(@as(usize, 1), functionByName(base, "const_div").?.trap_edges.len);
    try std.testing.expectEqual(@as(usize, 1), functionByName(base, "var_div").?.trap_edges.len);

    // Optimized mir.build elides the provably-dead checks — the in-range constant index (2 < 4)
    // and the unsigned division by a non-zero literal (/ 7) — but keeps the variable index's
    // and variable divisor's checks; the proofs are conservative.
    var opt = try mir.buildOpt(std.testing.allocator, module, .{ .optimize = true });
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

    try mir.verify(std.testing.allocator, module, &reporter);

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
    try mir.appendVerificationFacts(std.testing.allocator, module, &facts);
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

    try mir.verify(std.testing.allocator, module, &reporter);

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
    try mir.appendVerificationFacts(std.testing.allocator, module, &facts);
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

    try mir.verify(std.testing.allocator, module, &reporter);

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
    try mir.appendVerificationFacts(std.testing.allocator, module, &facts);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
    defer typed_mir.deinit();

    try std.testing.expectEqual(@as(usize, 1), typed_mir.functions.len);
    try std.testing.expect(typed_mir.functions[0].blocks.len >= 2);
    try std.testing.expectEqual(@as(usize, 1), typed_mir.functions[0].trap_edges.len);
    try std.testing.expectEqual(TrapKind.IntegerOverflow, typed_mir.functions[0].trap_edges[0].kind);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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
    try mir.appendVerificationFacts(std.testing.allocator, module, &facts);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
    defer typed_mir.deinit();

    const checked = functionByName(typed_mir, "checked").?;
    try std.testing.expectEqual(@as(usize, 1), checked.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.reduce_sum_checked, checked.call_target_facts[0].kind);
    try std.testing.expectEqualStrings("Result", checked.call_target_facts[0].result_ty.name());

    const left = functionByName(typed_mir, "left").?;
    try std.testing.expectEqual(@as(usize, 1), left.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.reduce_sum_left, left.call_target_facts[0].kind);
    try std.testing.expectEqualStrings("f64", left.call_target_facts[0].result_ty.name());
    try mir.validateCallTargetFactsForLowering(typed_mir);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
    defer typed_mir.deinit();

    const expected = [_]struct { name: []const u8, kind: mir.CallTargetKind }{
        .{ .name = "reflected_size", .kind = .reflection_size },
        .{ .name = "reflected_alignment", .kind = .reflection_alignment },
        .{ .name = "reflected_field_offset", .kind = .reflection_field_offset },
        .{ .name = "reflected_bit_offset", .kind = .reflection_bit_offset },
        .{ .name = "reflected_repr", .kind = .reflection_repr },
    };
    for (expected) |item| {
        const function = functionByName(typed_mir, item.name).?;
        try std.testing.expectEqual(@as(usize, 1), function.call_target_facts.len);
        try std.testing.expectEqual(item.kind, function.call_target_facts[0].kind);
        try std.testing.expectEqualStrings("usize", function.call_target_facts[0].result_ty.name());
        try std.testing.expectEqual(@as(usize, 1), function.target_type_facts.len);
        try std.testing.expectEqual(mir.TargetTypeKind.reflection_result, function.target_type_facts[0].kind);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
    defer typed_mir.deinit();

    const view = functionByName(typed_mir, "byte_view").?;
    try std.testing.expectEqual(@as(usize, 1), view.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.byte_view_as_bytes, view.call_target_facts[0].kind);
    try std.testing.expectEqualStrings("u8", view.call_target_facts[0].result_ty.name());
    try std.testing.expectEqual(@as(usize, 1), view.target_type_facts.len);
    try std.testing.expectEqual(mir.TargetTypeKind.byte_view_result, view.target_type_facts[0].kind);

    const equal = functionByName(typed_mir, "byte_equal").?;
    try std.testing.expectEqual(@as(usize, 1), equal.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.byte_view_equal, equal.call_target_facts[0].kind);
    try std.testing.expectEqualStrings("bool", equal.call_target_facts[0].result_ty.name());
    try std.testing.expectEqual(@as(usize, 1), equal.target_type_facts.len);
    try std.testing.expectEqual(mir.TargetTypeKind.byte_view_result, equal.target_type_facts[0].kind);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
    defer typed_mir.deinit();

    const reveal_fn = functionByName(typed_mir, "reveal_value").?;
    try std.testing.expectEqual(@as(usize, 1), reveal_fn.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.declassify, reveal_fn.call_target_facts[0].kind);
    try std.testing.expectEqualStrings("u8", reveal_fn.call_target_facts[0].result_ty.name());
    try std.testing.expectEqual(@as(usize, 2), reveal_fn.target_type_facts.len);
    try std.testing.expectEqual(mir.TargetTypeKind.declassify_source, reveal_fn.target_type_facts[0].kind);
    try std.testing.expectEqualStrings("Secret", reveal_fn.target_type_facts[0].target_ty.kind.generic.base.text);
    try std.testing.expectEqual(mir.TargetTypeKind.declassify_result, reveal_fn.target_type_facts[1].kind);
    try std.testing.expectEqualStrings("u8", reveal_fn.target_type_facts[1].result_ty.name());

    const noalias_fn = functionByName(typed_mir, "noalias_value").?;
    try std.testing.expectEqual(@as(usize, 1), noalias_fn.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.assume_noalias, noalias_fn.call_target_facts[0].kind);
    try std.testing.expectEqualStrings("*mut", noalias_fn.call_target_facts[0].result_ty.name());
    try std.testing.expectEqual(@as(usize, 2), noalias_fn.target_type_facts.len);
    try std.testing.expectEqual(mir.TargetTypeKind.assume_noalias_source, noalias_fn.target_type_facts[0].kind);
    try std.testing.expectEqual(mir.TargetTypeKind.assume_noalias_result, noalias_fn.target_type_facts[1].kind);

    const address_fn = functionByName(typed_mir, "noalias_address").?;
    try std.testing.expectEqual(@as(usize, 1), address_fn.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.assume_noalias, address_fn.call_target_facts[0].kind);
    try std.testing.expectEqualStrings("*mut", address_fn.call_target_facts[0].result_ty.name());
    try std.testing.expectEqual(@as(usize, 2), address_fn.target_type_facts.len);
    try std.testing.expectEqual(mir.TargetTypeKind.assume_noalias_source, address_fn.target_type_facts[0].kind);
    try std.testing.expectEqualStrings("*mut", address_fn.target_type_facts[0].result_ty.name());
    try std.testing.expectEqual(mir.TargetTypeKind.assume_noalias_result, address_fn.target_type_facts[1].kind);
    try mir.validateCallTargetFactsForLowering(typed_mir);
    try mir.validateTargetTypeFactsForLowering(typed_mir);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
    defer typed_mir.deinit();
    const caller = functionByName(typed_mir, "caller").?;
    try std.testing.expectEqual(@as(usize, 0), caller.call_target_facts.len);
    try mir.validateCallTargetFactsForLowering(typed_mir);
}

test "MIR records typed call target facts for atomic member calls" {
    const source =
        \\fn atomic_ops() -> u32 {
        \\    var counter: atomic<u32> = atomic.init(1);
        \\    counter.store(2, .release);
        \\    let previous: u32 = counter.fetch_add(3, .acq_rel);
        \\    let next: u32 = counter.fetch_sub(1, .seq_cst);
        \\    return previous + next + counter.load(.acquire);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "atomic_ops").?;
    try std.testing.expectEqual(@as(usize, 4), function.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.atomic_store, function.call_target_facts[0].kind);
    try std.testing.expectEqualStrings("void", function.call_target_facts[0].result_ty.name());
    try std.testing.expectEqual(mir.CallTargetKind.atomic_fetch_add, function.call_target_facts[1].kind);
    try std.testing.expectEqual(mir.CallTargetKind.atomic_fetch_sub, function.call_target_facts[2].kind);
    try std.testing.expectEqual(mir.CallTargetKind.atomic_load, function.call_target_facts[3].kind);
    for (function.call_target_facts[1..]) |fact| try std.testing.expectEqualStrings("u32", fact.result_ty.name());
    try std.testing.expectEqual(@as(usize, 4), function.target_type_facts.len);
    for (function.target_type_facts) |fact| {
        try std.testing.expectEqual(mir.TargetTypeKind.atomic_payload, fact.kind);
        try std.testing.expectEqualStrings("u32", fact.result_ty.name());
    }
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "bitcast_bits").?;
    try std.testing.expectEqual(@as(usize, 1), function.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.bitcast, function.call_target_facts[0].kind);
    try std.testing.expectEqualStrings("u32", function.call_target_facts[0].result_ty.name());
    try std.testing.expectEqual(@as(usize, 2), function.target_type_facts.len);
    try std.testing.expectEqual(mir.TargetTypeKind.bitcast_source, function.target_type_facts[0].kind);
    try std.testing.expectEqualStrings("f32", function.target_type_facts[0].result_ty.name());
    try std.testing.expectEqual(mir.TargetTypeKind.bitcast_target, function.target_type_facts[1].kind);
    try std.testing.expectEqualStrings("u32", function.target_type_facts[1].result_ty.name());
    try mir.validateCallTargetFactsForLowering(typed_mir);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "make_phys").?;
    try std.testing.expectEqual(@as(usize, 1), function.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.phys, function.call_target_facts[0].kind);
    try std.testing.expectEqualStrings("PAddr", function.call_target_facts[0].result_ty.name());
    try std.testing.expectEqual(@as(usize, 1), function.target_type_facts.len);
    try std.testing.expectEqual(mir.TargetTypeKind.phys_result, function.target_type_facts[0].kind);
    try std.testing.expectEqualStrings("PAddr", function.target_type_facts[0].result_ty.name());
    try mir.validateCallTargetFactsForLowering(typed_mir);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
    defer typed_mir.deinit();
    const read = functionByName(typed_mir, "read").?;
    const pointer = functionByName(typed_mir, "pointer").?;
    const store = functionByName(typed_mir, "store").?;
    const pause = functionByName(typed_mir, "pause").?;
    const fences = functionByName(typed_mir, "fences").?;
    try std.testing.expectEqual(@as(usize, 1), read.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.raw_load, read.call_target_facts[0].kind);
    try std.testing.expectEqualStrings("u32", read.call_target_facts[0].result_ty.name());
    try std.testing.expectEqual(@as(usize, 1), read.target_type_facts.len);
    try std.testing.expectEqual(mir.TargetTypeKind.raw_load_result, read.target_type_facts[0].kind);
    try std.testing.expectEqual(@as(usize, 1), pointer.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.raw_ptr, pointer.call_target_facts[0].kind);
    try std.testing.expectEqualStrings("*mut", pointer.call_target_facts[0].result_ty.name());
    try std.testing.expectEqual(@as(usize, 1), pointer.target_type_facts.len);
    try std.testing.expectEqual(mir.TargetTypeKind.raw_ptr_result, pointer.target_type_facts[0].kind);
    try std.testing.expectEqual(@as(usize, 1), store.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.raw_store, store.call_target_facts[0].kind);
    try std.testing.expectEqualStrings("void", store.call_target_facts[0].result_ty.name());
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

test "MIR owns varargs call identities and result types" {
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

    var typed_mir = try mir.build(std.testing.allocator, module);
    defer typed_mir.deinit();
    const function = functionByName(typed_mir, "sum_args").?;
    try std.testing.expectEqual(@as(usize, 3), function.call_target_facts.len);
    try std.testing.expectEqual(mir.CallTargetKind.va_start, function.call_target_facts[0].kind);
    try std.testing.expectEqual(mir.CallTargetKind.va_arg, function.call_target_facts[1].kind);
    try std.testing.expectEqual(mir.CallTargetKind.va_end, function.call_target_facts[2].kind);
    var va_start_results: usize = 0;
    var va_arg_results: usize = 0;
    for (function.target_type_facts) |fact| switch (fact.kind) {
        .va_start_result => va_start_results += 1,
        .va_arg_result => va_arg_results += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), va_start_results);
    try std.testing.expectEqual(@as(usize, 1), va_arg_results);
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

    try mir.verify(std.testing.allocator, module, &reporter);

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

    try mir.verify(std.testing.allocator, module, &reporter);

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

    try mir.verify(std.testing.allocator, module, &reporter);

    var unsafe_required_count: usize = 0;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_UNSAFE_REQUIRED") != null) unsafe_required_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), unsafe_required_count);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFacts(std.testing.allocator, module, &facts);
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

    try mir.verify(std.testing.allocator, module, &reporter);

    var irq_call_count: usize = 0;
    var irq_blocking_count: usize = 0;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_IRQ_CONTEXT_CALL") != null) irq_call_count += 1;
        if (std.mem.indexOf(u8, diag.message, "E_IRQ_CONTEXT_BLOCKING") != null) irq_blocking_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), irq_call_count);
    try std.testing.expectEqual(@as(usize, 4), irq_blocking_count);
    try std.testing.expectEqual(@as(usize, 5), reporter.diagnostics.items.len);

    var typed_mir = try mir.build(std.testing.allocator, module);
    defer typed_mir.deinit();
    const accepted_mmio_fn = functionByName(typed_mir, "accepted_mmio").?;
    try std.testing.expect(functionHasInstruction(accepted_mmio_fn, .call, "mmio.write"));
    try std.testing.expect(functionHasInstruction(accepted_mmio_fn, .call, "mmio.read"));

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFacts(std.testing.allocator, module, &facts);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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
    try mir.appendVerificationFacts(std.testing.allocator, module, &facts);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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
    try mir.appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accumulate pass=range finding=no_overflow_range target=sum op=add left=sum right=b") != null);
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

    var typed_mir = try mir.buildOpt(std.testing.allocator, module, .{ .optimize = true });
    defer typed_mir.deinit();

    const index_fn = functionByName(typed_mir, "read_const_index").?;
    const slice_fn = functionByName(typed_mir, "read_const_slice").?;
    const div_fn = functionByName(typed_mir, "divide_const_nonzero").?;
    try std.testing.expect(index_fn.elided_bounds.len >= 1);
    try std.testing.expect(slice_fn.elided_bounds.len >= 1);
    try std.testing.expect(div_fn.elided_bounds.len >= 1);

    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(std.testing.allocator);
    try mir.appendDumpOpt(std.testing.allocator, module, &dump, .{ .optimize = true });
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
    try mir.appendDump(std.testing.allocator, module, &dump);
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
    try mir.appendDump(std.testing.allocator, module, &dump);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "integer_facts=3") != null);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
    defer typed_mir.deinit();

    const return_fn = functionByName(typed_mir, "return_ptr_param").?;
    const read_fn = functionByName(typed_mir, "read_ptr_param").?;
    try std.testing.expectEqual(@as(usize, 2), return_fn.representation_facts.len);
    try std.testing.expectEqual(.typed_load, return_fn.representation_facts[0].kind);
    try std.testing.expectEqualStrings("p", return_fn.representation_facts[0].detail);
    try std.testing.expectEqualStrings("p", return_fn.representation_facts[0].value_id);
    try std.testing.expectEqual(.representation_check, return_fn.representation_facts[1].kind);
    try std.testing.expectEqualStrings("nonnull_pointer", return_fn.representation_facts[1].detail);
    try std.testing.expectEqualStrings("p", return_fn.representation_facts[1].value_id);
    try std.testing.expectEqual(@as(usize, 3), read_fn.representation_facts.len);
    try std.testing.expectEqual(.typed_load, read_fn.representation_facts[0].kind);
    try std.testing.expectEqualStrings("p", read_fn.representation_facts[0].detail);
    try std.testing.expectEqualStrings("p", read_fn.representation_facts[0].value_id);
    try std.testing.expectEqual(.representation_check, read_fn.representation_facts[1].kind);
    try std.testing.expectEqualStrings("nonnull_pointer", read_fn.representation_facts[1].detail);
    try std.testing.expectEqualStrings("p", read_fn.representation_facts[1].value_id);
    try std.testing.expectEqual(.representation_use, read_fn.representation_facts[2].kind);
    try std.testing.expectEqualStrings("deref_base", read_fn.representation_facts[2].detail);
    try std.testing.expectEqualStrings("p", read_fn.representation_facts[2].value_id);

    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(std.testing.allocator);
    try mir.appendDump(std.testing.allocator, module, &dump);

    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir instr fn=return_ptr_param") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "representation_facts=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "kind=typed_load detail=p type=*mut value_id=p") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "kind=representation_check detail=nonnull_pointer type=*mut value_id=p") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir instr fn=read_ptr_param") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "kind=representation_use detail=deref_base type=*mut value_id=p") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir representation_fact fn=return_ptr_param kind=typed_load detail=p type=*mut value_id=p recorded=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir representation_fact fn=return_ptr_param kind=representation_check detail=nonnull_pointer type=*mut value_id=p recorded=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir representation_fact fn=read_ptr_param kind=representation_use detail=deref_base type=*mut value_id=p recorded=true") != null);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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
    try mir.appendDump(std.testing.allocator, module, &dump);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir function name=direct_pointer_and_array return=void no_lang_trap=false irq_context=false") != null);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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
    try std.testing.expect(hasAggregateReturnSummaryFact(typed_mir, "defer_expr_prefix_holder"));
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
    try std.testing.expect(hasAggregateReturnPointerFact(typed_mir, "defer_expr_prefix_holder", "ptr", .global_storage));
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
    try mir.appendDump(std.testing.allocator, module, &dump);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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
    try mir.appendDump(std.testing.allocator, module, &dump);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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
    try mir.appendDump(std.testing.allocator, module, &dump);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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
    try mir.appendDump(std.testing.allocator, module, &dump);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=raw_many_zero_fact subject=q element=none provenance=global_storage storage=shared_counter pointer_kind=raw_many") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=raw_many_zero_fact subject=t element=none provenance=global_storage storage=shared_counter pointer_kind=raw_many") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=raw_many_zero_assignment_fact subject=q element=none provenance=global_storage storage=shared_counter pointer_kind=raw_many") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=raw_many_zero_fail_closed subject=q element=none provenance=local_storage storage=local pointer_kind=raw_many") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir pointer_provenance_fact fn=raw_many_zero_fail_closed subject=q element=none provenance=unknown storage=none pointer_kind=raw_many") != null);
}

test "MIR range facts are top-level and no_overflow operations are known" {
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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
    try std.testing.expectEqual(@as(usize, 1), nested_binary_fn.range_facts.len);
    try std.testing.expectEqualStrings("binary_operand", nested_binary_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("add", nested_binary_fn.range_facts[0].op);
    try std.testing.expectEqualStrings("u32", valueTypeName(nested_binary_fn.range_facts[0].result_ty));
    const aggregate_array_fn = functionByName(typed_mir, "aggregate_array_fact").?;
    try std.testing.expectEqual(@as(usize, 1), aggregate_array_fn.range_facts.len);
    try std.testing.expectEqualStrings("aggregate_element", aggregate_array_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("add", aggregate_array_fn.range_facts[0].op);
    try std.testing.expectEqualStrings("u32", valueTypeName(aggregate_array_fn.range_facts[0].result_ty));
    const cast_aggregate_array_fn = functionByName(typed_mir, "cast_aggregate_array_fact").?;
    try std.testing.expectEqual(@as(usize, 1), cast_aggregate_array_fn.range_facts.len);
    try std.testing.expectEqualStrings("aggregate_element", cast_aggregate_array_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("add", cast_aggregate_array_fn.range_facts[0].op);
    try std.testing.expectEqualStrings("u32", valueTypeName(cast_aggregate_array_fn.range_facts[0].result_ty));
    const aggregate_field_fn = functionByName(typed_mir, "aggregate_field_fact").?;
    try std.testing.expectEqual(@as(usize, 1), aggregate_field_fn.range_facts.len);
    try std.testing.expectEqualStrings("next", aggregate_field_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("mul", aggregate_field_fn.range_facts[0].op);
    try std.testing.expectEqualStrings("u32", valueTypeName(aggregate_field_fn.range_facts[0].result_ty));
    const cast_aggregate_field_fn = functionByName(typed_mir, "cast_aggregate_field_fact").?;
    try std.testing.expectEqual(@as(usize, 1), cast_aggregate_field_fn.range_facts.len);
    try std.testing.expectEqualStrings("next", cast_aggregate_field_fn.range_facts[0].target);
    try std.testing.expectEqualStrings("mul", cast_aggregate_field_fn.range_facts[0].op);
    try std.testing.expectEqualStrings("u32", valueTypeName(cast_aggregate_field_fn.range_facts[0].result_ty));
    const known_ops_fn = functionByName(typed_mir, "known_ops").?;
    try std.testing.expectEqual(@as(usize, 2), known_ops_fn.range_facts.len);
    try std.testing.expectEqualStrings("sub", known_ops_fn.range_facts[0].op);
    try std.testing.expectEqualStrings("mul", known_ops_fn.range_facts[1].op);

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

    try mir.verify(std.testing.allocator, module, &reporter);

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
    try mir.appendVerificationFacts(std.testing.allocator, module, &facts);
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

    try mir.verify(std.testing.allocator, module, &reporter);

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
    try mir.appendVerificationFacts(std.testing.allocator, module, &facts);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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
    try mir.appendVerificationFacts(std.testing.allocator, module, &facts);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
    defer typed_mir.deinit();

    const checked_ptr_fn = functionByName(typed_mir, "checked_ptr_param").?;
    const checked_irq_fn = functionByName(typed_mir, "checked_irq_param").?;
    const checked_open_fn = functionByName(typed_mir, "checked_open_enum").?;
    try std.testing.expectEqual(@as(usize, 1), countTrapEdges(checked_ptr_fn, .InvalidRepresentation));
    try std.testing.expectEqual(@as(usize, 1), countTrapEdges(checked_irq_fn, .InvalidRepresentation));
    try std.testing.expectEqual(@as(usize, 0), countTrapEdges(checked_open_fn, .InvalidRepresentation));

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try mir.appendVerificationFacts(std.testing.allocator, module, &facts);
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
        .{ .kind = .call, .result_ty = .{ .pointer = .{ .kind = .single, .mutability = .mut, .child = "u8" } }, .detail = "make_ptr", .line = 1, .column = 1 },
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
        .{ .kind = .indirect_call, .result_ty = .{ .pointer = .{ .kind = .single, .mutability = .mut, .child = "u8" } }, .detail = "callee", .line = 1, .column = 1 },
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
    try mir.appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=cast_pointer_return pass=representation finding=representation_check type=nonnull_pointer") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=cast_pointer_local pass=representation finding=representation_use detail=initializer type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=cast_pointer_assignment pass=representation finding=representation_use detail=assignment type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=cast_pointer_call_arg pass=representation finding=representation_use detail=call_arg type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=cast_pointer_aggregate_field pass=representation finding=representation_use detail=aggregate_field type=*mut") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=cast_pointer_aggregate_element pass=representation finding=representation_use detail=aggregate_element type=*mut") != null);

    var typed_mir = try mir.build(std.testing.allocator, module);
    defer typed_mir.deinit();

    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(std.testing.allocator);
    try mir.appendDump(std.testing.allocator, module, &dump);
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
    try mir.appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_null_local pass=nullability finding=null_to_nonnull") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_null_assignment pass=nullability finding=null_to_nonnull") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_nullable_return pass=nullability finding=nullable_to_nonnull") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_nullable_call_return pass=nullability finding=nullable_to_nonnull") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_nonnull_to_nullable pass=nullability") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_null_nullable pass=nullability") == null);

    try mir.verify(std.testing.allocator, module, &reporter);
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
    try mir.appendVerificationFacts(std.testing.allocator, module, &facts);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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
    try mir.appendVerificationFacts(std.testing.allocator, module, &facts);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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
    try mir.appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_literals pass=conversion") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_return_literal pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_local_literal pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_negative_unsigned pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_i8_high pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_i8_low pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_assignment_literal pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_call_arg_literal pass=conversion finding=integer_literal_out_of_range source_type=comptime_int") != null);

    var typed_mir = try mir.build(std.testing.allocator, module);
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
    try mir.appendVerificationFacts(std.testing.allocator, module, &facts);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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
    try mir.appendVerificationFacts(std.testing.allocator, module, &facts);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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
    try mir.appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_unhandled_result_statement pass=result finding=unhandled_result") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_unhandled_result_local pass=result finding=unhandled_result") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_defer_unhandled_result pass=result finding=unhandled_result") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_switch_arm_unhandled_result pass=result finding=unhandled_result") != null);

    var typed_mir = try mir.build(std.testing.allocator, module);
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
    try mir.appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "pass=result finding=unhandled_result") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_handled_result_local pass=result finding=try_handled") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_array_literal_result_local pass=result finding=try_handled") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_struct_literal_result_local pass=result finding=try_handled") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_switch_arm_body_result_local pass=result finding=try_handled") != null);

    var typed_mir = try mir.build(std.testing.allocator, module);
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
    try mir.appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_if_let_optional_required pass=result finding=if_let_optional_required") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_if_let_result_required pass=result finding=if_let_result_required") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_if_let_result_tag pass=result finding=if_let_result_tag") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_if_let_narrow_pattern pass=result finding=if_let_narrow_pattern") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_switch_result_tag pass=result finding=switch_result_tag") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_switch_result_required pass=result finding=switch_result_required") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_switch_multi_binding_arm pass=result finding=switch_multi_binding_arm") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_valid_result_patterns pass=result finding=if_let_") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_valid_result_patterns pass=result finding=switch_") == null);

    var typed_mir = try mir.build(std.testing.allocator, module);
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
    try mir.appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_bool_duplicate pass=core finding=duplicate_switch_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_integer_duplicate pass=core finding=duplicate_switch_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_result_duplicate pass=core finding=duplicate_switch_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_case_after_wildcard pass=core finding=duplicate_switch_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_same_arm_wildcard_cover pass=core finding=duplicate_switch_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_distinct_switches pass=core finding=duplicate_switch_case") == null);

    var typed_mir = try mir.build(std.testing.allocator, module);
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
    try mir.appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_bool_switch_integer_pattern pass=core finding=switch_literal_type_mismatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_integer_switch_bool_pattern pass=core finding=switch_literal_type_mismatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_enum_switch_literal_pattern pass=core finding=switch_literal_type_mismatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_scalar_switch_literals pass=core finding=switch_literal_type_mismatch") == null);

    var typed_mir = try mir.build(std.testing.allocator, module);
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
    try mir.appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_closed_enum_nonexhaustive pass=core finding=closed_enum_switch_exhaustive") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_closed_enum_unknown_case pass=core finding=unknown_enum_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_open_enum_unknown_case pass=core finding=unknown_enum_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_enum_duplicate_case pass=core finding=duplicate_switch_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_closed_enum_exhaustive pass=representation finding=representation_use detail=switch_subject type=Irq") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_closed_enum_exhaustive pass=core") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_closed_enum_wildcard pass=core") == null);

    var typed_mir = try mir.build(std.testing.allocator, module);
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
    try mir.appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_unknown_union_case pass=core finding=unknown_union_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_payloadless_union_case_binding pass=core finding=union_case_has_no_payload") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_duplicate_union_case pass=core finding=duplicate_switch_case") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_union_patterns pass=core") == null);

    var typed_mir = try mir.build(std.testing.allocator, module);
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
    try mir.appendVerificationFacts(std.testing.allocator, module, &facts);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_overwrite_unhandled_result pass=result finding=unhandled_result") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=accept_assignment_handled_later pass=result finding=unhandled_result") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_void_direct_call_try pass=result finding=try_requires_result_or_nullable") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "mir verify fn=reject_integer_try pass=result finding=try_requires_result_or_nullable") != null);

    var typed_mir = try mir.build(std.testing.allocator, module);
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
    try mir.appendVerificationFacts(std.testing.allocator, module, &facts);
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

    var typed_mir = try mir.build(std.testing.allocator, module);
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
