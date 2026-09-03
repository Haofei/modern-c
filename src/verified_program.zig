const std = @import("std");

const checked_program = @import("checked_program.zig");
const diagnostics = @import("diagnostics.zig");
const mir = @import("mir.zig");

pub const trap_hook_names = [_][]const u8{
    "mc_trap_IntegerOverflow",
    "mc_trap_DivideByZero",
    "mc_trap_InvalidShift",
    "mc_trap_InvalidRepresentation",
    "mc_trap_Bounds",
    "mc_trap_Assert",
    "mc_trap_NullUnwrap",
    "mc_trap_Unreachable",
};

pub const sanitizer_hook_names = [_][]const u8{
    "mc_ksan_poison",
    "mc_ksan_unpoison",
    "mc_ksan_check",
    "mc_ksan_store",
    "mc_csan_read",
    "mc_csan_write",
};

/// Backend-facing runtime-hook facts. This is intentionally narrower than a
/// general source spelling table: codegen can decide whether to emit weak
/// runtime stubs, but cannot query arbitrary source names through this view.
pub const RuntimeHookFacts = struct {
    defined_trap_hooks: [trap_hook_names.len]bool = [_]bool{false} ** trap_hook_names.len,
    defined_sanitizer_hooks: [sanitizer_hook_names.len]bool = [_]bool{false} ** sanitizer_hook_names.len,

    pub fn fromMir(typed_mir: mir.Module) RuntimeHookFacts {
        var facts = RuntimeHookFacts{};
        for (typed_mir.functions) |function| {
            if (function.is_extern) continue;
            if (!function.typed_symbol_id.isValid()) continue;
            const spelling = symbolSpelling(typed_mir, function.typed_symbol_id) orelse continue;
            for (trap_hook_names, 0..) |hook, index| {
                if (std.mem.eql(u8, spelling, hook)) facts.defined_trap_hooks[index] = true;
            }
            for (sanitizer_hook_names, 0..) |hook, index| {
                if (std.mem.eql(u8, spelling, hook)) facts.defined_sanitizer_hooks[index] = true;
            }
        }
        return facts;
    }

    pub fn definesTrapHook(self: RuntimeHookFacts, index: usize) bool {
        if (index >= self.defined_trap_hooks.len) return false;
        return self.defined_trap_hooks[index];
    }

    pub fn definesSanitizerHook(self: RuntimeHookFacts, index: usize) bool {
        if (index >= self.defined_sanitizer_hooks.len) return false;
        return self.defined_sanitizer_hooks[index];
    }
};

fn symbolSpelling(typed_mir: mir.Module, id: mir.SymbolId) ?[]const u8 {
    if (!id.isValid()) return null;
    const index = id.index();
    if (index >= typed_mir.symbol_identities.len) return null;
    const identity = typed_mir.symbol_identities[index];
    if (!identity.id.eql(id)) return null;
    return identity.spelling;
}

fn symbolIdentitiesMatchFunctionSpelling(typed_mir: mir.Module) bool {
    for (typed_mir.functions) |function| {
        const spelling = symbolSpelling(typed_mir, function.typed_symbol_id) orelse return false;
        if (!std.mem.eql(u8, spelling, function.name)) return false;
    }
    return true;
}

/// The only code-generation input accepted by a Backend for ordinary lowering.
/// Construction runs the MIR verifier and exposes verified runtime hook facts.
/// Legacy declaration mechanics stay outside this verified semantic boundary.
pub const VerifiedProgram = struct {
    checked: checked_program.CheckedProgram,
    runtime_hooks: RuntimeHookFacts,
    typed_mir: *const mir.Module,

    pub fn init(
        typed_mir: *const mir.Module,
        reporter: *diagnostics.Reporter,
    ) !VerifiedProgram {
        try mir.validateLoweringAdmission(typed_mir.*);
        try mir.verifyBuiltMir(typed_mir.*, reporter);
        if (reporter.has_errors) return error.InvalidMir;
        if (!symbolIdentitiesMatchFunctionSpelling(typed_mir.*)) return error.InvalidMir;
        const checked = try checked_program.CheckedProgram.init(
            typed_mir.checked_callables,
            typed_mir.checked_globals,
            typed_mir.signature_types,
            typed_mir.const_global_scalar_inits,
        );
        if (!checked.matchesMir(typed_mir.*)) return error.InvalidCheckedProgram;
        return .{
            .checked = checked,
            .runtime_hooks = RuntimeHookFacts.fromMir(typed_mir.*),
            .typed_mir = typed_mir,
        };
    }
};

test "VerifiedProgram exposes narrow runtime hook facts" {
    const source = "verified MIR fixture";
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "backend_runtime_hook_facts.mc", source);
    defer reporter.deinit();

    const symbols = try std.testing.allocator.alloc(mir.SymbolIdentity, 2);
    symbols[0] = .{ .id = mir.SymbolId.fromIndex(0), .spelling = "add_one" };
    symbols[1] = .{ .id = mir.SymbolId.fromIndex(1), .spelling = "mc_ksan_check" };
    const signature_shapes = try std.testing.allocator.alloc(mir.TypeShape, 1);
    errdefer std.testing.allocator.free(signature_shapes);
    signature_shapes[0] = .{ .name = try std.testing.allocator.dupe(u8, "void") };
    errdefer signature_shapes[0].deinit(std.testing.allocator);
    const blocks = try std.testing.allocator.alloc(mir.Block, 1);
    blocks[0] = .{
        .id = 0,
        .typed_id = mir.BlockId.fromIndex(0),
        .kind = "entry",
        .instructions = &.{},
        .successors = &.{},
        .typed_successors = &.{},
        .terminator = .{ .return_ = .void },
    };
    const hook_blocks = try std.testing.allocator.alloc(mir.Block, 1);
    hook_blocks[0] = .{
        .id = 0,
        .typed_id = mir.BlockId.fromIndex(0),
        .kind = "entry",
        .instructions = &.{},
        .successors = &.{},
        .typed_successors = &.{},
        .terminator = .{ .return_ = .void },
    };
    const functions = try std.testing.allocator.alloc(mir.Function, 2);
    functions[0] = .{
        .name = "add_one",
        .typed_def_id = .{ .file_id = 0, .ordinal = 0 },
        .typed_symbol_id = mir.SymbolId.fromIndex(0),
        .return_ty = .void,
        .signature_return_type_id = mir.SignatureTypeId.fromIndex(0),
        .no_lang_trap = false,
        .irq_context = false,
        .blocks = hook_blocks,
        .trap_edges = &.{},
        .contract_regions = &.{},
        .range_facts = &.{},
        .pointer_provenance_facts = &.{},
        .representation_facts = &.{},
        .elided_bounds = &.{},
    };
    functions[1] = .{
        .name = "mc_ksan_check",
        .typed_def_id = .{ .file_id = 0, .ordinal = 1 },
        .typed_symbol_id = mir.SymbolId.fromIndex(1),
        .return_ty = .void,
        .signature_return_type_id = mir.SignatureTypeId.fromIndex(0),
        .no_lang_trap = false,
        .irq_context = false,
        .blocks = blocks,
        .trap_edges = &.{},
        .contract_regions = &.{},
        .range_facts = &.{},
        .pointer_provenance_facts = &.{},
        .representation_facts = &.{},
        .elided_bounds = &.{},
    };
    const checked_callables = try std.testing.allocator.alloc(mir.CheckedCallableFact, 2);
    checked_callables[0] = .{
        .def_id = .{ .file_id = 0, .ordinal = 0 },
        .symbol_id = mir.SymbolId.fromIndex(0),
        .source_id = .invalid,
        .body_id = mir.BodyId.fromIndex(0),
        .kind = .function,
        .return_ty = .void,
        .signature_return_type_id = mir.SignatureTypeId.fromIndex(0),
        .param_count = 0,
        .c_abi = false,
        .no_lang_trap = false,
        .irq_context = false,
    };
    checked_callables[1] = .{
        .def_id = .{ .file_id = 0, .ordinal = 1 },
        .symbol_id = mir.SymbolId.fromIndex(1),
        .source_id = .invalid,
        .body_id = mir.BodyId.fromIndex(1),
        .kind = .function,
        .return_ty = .void,
        .signature_return_type_id = mir.SignatureTypeId.fromIndex(0),
        .param_count = 0,
        .c_abi = false,
        .no_lang_trap = false,
        .irq_context = false,
    };
    var module_mir = mir.Module{
        .allocator = std.testing.allocator,
        .symbol_identities = symbols,
        .signature_types = .{ .shapes = signature_shapes },
        .checked_callables = checked_callables,
        .functions = functions,
    };
    defer module_mir.deinit();

    const program = try VerifiedProgram.init(&module_mir, &reporter);
    try std.testing.expect(module_mir.functions.len != 0);
    try std.testing.expectEqual(@as(usize, 2), program.checked.callables.len);
    try std.testing.expectEqual(mir.SymbolId.fromIndex(0), program.checked.body(mir.BodyId.fromIndex(0)).?.symbol_id);
    try std.testing.expect(!program.runtime_hooks.definesTrapHook(0));
    try std.testing.expect(program.runtime_hooks.definesSanitizerHook(2));
    try std.testing.expect(!program.runtime_hooks.definesSanitizerHook(0));

    module_mir.checked_callables[0].param_count = 1;
    try std.testing.expectError(error.InvalidCheckedProgram, VerifiedProgram.init(&module_mir, &reporter));
    module_mir.checked_callables[0].param_count = 0;
    module_mir.checked_callables[0].is_variadic = true;
    try std.testing.expectError(error.InvalidCheckedProgram, VerifiedProgram.init(&module_mir, &reporter));
}

test "VerifiedProgram rejects checked callable parameter type drift" {
    const test_support = @import("test_support.zig");
    const source =
        \\extern fn sink(value: u32) -> void;
        \\fn forward(value: u32) -> u32 { return value; }
    ;
    var parsed = try test_support.parseModule("verified_callable_param_drift.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "verified_callable_param_drift.mc", source);
    defer reporter.deinit();

    _ = try VerifiedProgram.init(&module_mir, &reporter);
    const forward_index = for (module_mir.functions, 0..) |function, index| {
        if (std.mem.eql(u8, function.name, "forward")) break index;
    } else return error.TestUnexpectedResult;
    const saved = module_mir.checked_callables[forward_index].param_types;
    const wrong = [_]mir.ValueType{.{ .integer = "u64" }};
    module_mir.checked_callables[forward_index].param_types = &wrong;
    try std.testing.expectError(error.InvalidCheckedProgram, VerifiedProgram.init(&module_mir, &reporter));

    module_mir.checked_callables[forward_index].param_types = &.{};
    try std.testing.expectError(error.InvalidCheckedProgram, VerifiedProgram.init(&module_mir, &reporter));
    module_mir.checked_callables[forward_index].param_types = saved;

    const saved_signature_type = module_mir.checked_callables[forward_index].signature_return_type_id;
    module_mir.checked_callables[forward_index].signature_return_type_id = .invalid;
    try std.testing.expectError(error.InvalidCheckedProgram, VerifiedProgram.init(&module_mir, &reporter));
    module_mir.checked_callables[forward_index].signature_return_type_id = saved_signature_type;
    _ = try VerifiedProgram.init(&module_mir, &reporter);
}
