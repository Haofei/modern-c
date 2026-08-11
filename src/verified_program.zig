const std = @import("std");

const diagnostics = @import("diagnostics.zig");
const mir = @import("mir.zig");

/// Backend-facing source spelling view. This is intentionally backed by
/// verified MIR identities, not by an AST rescan. It is the first explicit
/// source/symbol table that backend entrypoints can consume while legacy
/// lowerers still carry declaration slices for not-yet-normalized metadata.
pub const SourceSpellingView = struct {
    symbols: []const mir.SymbolIdentity,

    pub fn symbolSpelling(self: SourceSpellingView, id: mir.SymbolId) ?[]const u8 {
        if (!id.isValid()) return null;
        const index = id.index();
        if (index >= self.symbols.len) return null;
        const identity = self.symbols[index];
        if (!identity.id.eql(id)) return null;
        return identity.spelling;
    }

    fn functionSpelling(self: SourceSpellingView, function: mir.Function) ?[]const u8 {
        return self.symbolSpelling(function.typed_symbol_id);
    }

    /// True when verified MIR contains a non-extern function definition whose
    /// source spelling matches `name`. Backends use this for emission mechanics
    /// such as runtime-hook stub suppression; the query is intentionally
    /// MIR-backed so it cannot rescan syntax declarations as semantic authority.
    pub fn definesFunctionSpelling(self: SourceSpellingView, typed_mir: mir.Module, name: []const u8) bool {
        for (typed_mir.functions) |function| {
            if (function.is_extern) continue;
            const spelling = self.functionSpelling(function) orelse continue;
            if (std.mem.eql(u8, spelling, name)) return true;
        }
        return false;
    }

    pub fn validateAgainstMir(self: SourceSpellingView, typed_mir: mir.Module) bool {
        if (self.symbols.len != typed_mir.symbol_identities.len) return false;
        for (self.symbols, typed_mir.symbol_identities) |left, right| {
            if (!left.id.eql(right.id)) return false;
            if (!std.mem.eql(u8, left.spelling, right.spelling)) return false;
        }
        for (typed_mir.functions) |function| {
            const spelling = self.functionSpelling(function) orelse return false;
            if (!std.mem.eql(u8, spelling, function.name)) return false;
        }
        return true;
    }
};

/// The only code-generation input accepted by a Backend for ordinary lowering.
/// Construction runs the MIR verifier and exposes MIR-owned source spelling.
/// Legacy declaration mechanics stay outside this verified semantic boundary.
pub const VerifiedProgram = struct {
    source_spelling: SourceSpellingView,
    typed_mir: *const mir.Module,

    pub fn init(
        typed_mir: *const mir.Module,
        reporter: *diagnostics.Reporter,
    ) !VerifiedProgram {
        try mir.verifyBuiltMir(typed_mir.*, reporter);
        if (reporter.has_errors) return error.InvalidMir;
        try mir.validateLoweringAdmission(typed_mir.*);
        const source_spelling = SourceSpellingView{ .symbols = typed_mir.symbol_identities };
        if (!source_spelling.validateAgainstMir(typed_mir.*)) return error.InvalidMir;
        return .{
            .source_spelling = source_spelling,
            .typed_mir = typed_mir,
        };
    }
};

test "VerifiedProgram exposes MIR-owned source spelling view" {
    const source = "verified MIR fixture";
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "backend_source_spelling.mc", source);
    defer reporter.deinit();

    const symbols = try std.testing.allocator.alloc(mir.SymbolIdentity, 1);
    symbols[0] = .{ .id = mir.SymbolId.fromIndex(0), .spelling = "add_one" };
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
    const functions = try std.testing.allocator.alloc(mir.Function, 1);
    functions[0] = .{
        .name = "add_one",
        .typed_symbol_id = mir.SymbolId.fromIndex(0),
        .return_ty = .void,
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
    var module_mir = mir.Module{
        .allocator = std.testing.allocator,
        .symbol_identities = symbols,
        .functions = functions,
    };
    defer module_mir.deinit();

    const program = try VerifiedProgram.init(&module_mir, &reporter);
    try std.testing.expect(program.source_spelling.validateAgainstMir(module_mir));
    try std.testing.expect(module_mir.functions.len != 0);
    try std.testing.expectEqualStrings(
        "add_one",
        program.source_spelling.symbolSpelling(module_mir.functions[0].typed_symbol_id).?,
    );
    try std.testing.expect(program.source_spelling.definesFunctionSpelling(module_mir, "add_one"));
    try std.testing.expect(!program.source_spelling.definesFunctionSpelling(module_mir, "missing"));
}
