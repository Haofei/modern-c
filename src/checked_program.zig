//! Minimal syntax-free semantic boundary.
//!
//! This is intentionally not a second expression IR. Callable identity,
//! signature representation, ABI, and closed effect flags live here; function
//! bodies remain canonical typed MIR. The table is constructed before body MIR
//! lowering and then admitted against the finished MIR module.

const std = @import("std");

const mir = @import("mir_model.zig");

pub const CheckedProgram = struct {
    callables: []const mir.CheckedCallableFact,
    globals: []const mir.CheckedGlobalFact,
    /// Borrowed module-owned signature type graph. The checked program never
    /// owns syntax or source type expressions.
    signature_types: mir.SignatureTypeTable,
    const_global_scalar_inits: []const mir.ConstGlobalScalarInitFact,

    pub fn init(
        callables: []const mir.CheckedCallableFact,
        globals: []const mir.CheckedGlobalFact,
        signature_types: mir.SignatureTypeTable,
        const_global_scalar_inits: []const mir.ConstGlobalScalarInitFact,
    ) !CheckedProgram {
        if (!signature_types.validate()) return error.InvalidCheckedProgram;
        for (callables, 0..) |callable, index| {
            if (!callable.symbol_id.isValid()) return error.InvalidCheckedProgram;
            if (callable.kind == .global_initializer) {
                if (callable.def_id.isValid()) return error.InvalidCheckedProgram;
            } else {
                if (!callable.def_id.isValid()) return error.InvalidCheckedProgram;
                for (callables[0..index]) |prior| {
                    if (prior.kind != .global_initializer and prior.def_id.eql(callable.def_id))
                        return error.DuplicateDefinitionIdentity;
                }
            }
            if (callable.param_types.len != callable.param_count) return error.InvalidCheckedProgram;
            if (callable.signature_param_type_ids.len != callable.param_count) return error.InvalidCheckedProgram;
            // Every callable must refer to a validated recursive shape. This
            // is deliberately fail-closed: even hand-built unit fixtures must
            // construct the same module-owned signature boundary.
            if (!signature_types.contains(callable.signature_return_type_id)) return error.InvalidCheckedProgram;
            for (callable.signature_param_type_ids) |type_id| {
                if (!signature_types.contains(type_id)) return error.InvalidCheckedProgram;
            }
            if (callable.kind == .extern_function) {
                if (callable.body_id.isValid()) return error.InvalidCheckedProgram;
            } else if (!callable.body_id.isValid() or callable.body_id.index() != index) {
                return error.InvalidCheckedProgram;
            }
            if (callable.kind == .global_initializer and
                (callable.param_count != 0 or callable.return_ty != .void or callable.c_abi or callable.is_variadic)) return error.InvalidCheckedProgram;
        }
        for (globals) |global| {
            if (!global.symbol_id.isValid() or global.ty == .unknown) return error.InvalidCheckedProgram;
            if (global.is_extern and global.initializer_body_id.isValid()) return error.InvalidCheckedProgram;
            if (global.initializer_body_id.isValid()) {
                if (global.initializer_body_id.index() >= callables.len) return error.InvalidCheckedProgram;
                const initializer = callables[global.initializer_body_id.index()];
                if (initializer.kind != .global_initializer or !initializer.symbol_id.eql(global.symbol_id))
                    return error.InvalidCheckedProgram;
            }
        }
        for (const_global_scalar_inits, 0..) |fact, index| {
            if (!fact.initializer_body_id.isValid() or fact.initializer_body_id.index() >= callables.len)
                return error.InvalidConstGlobalScalarInitFact;
            const callable = callables[fact.initializer_body_id.index()];
            if (callable.kind != .global_initializer or !callable.body_id.eql(fact.initializer_body_id))
                return error.InvalidConstGlobalScalarInitFact;
            const global = globalForInitializer(callables, globals, fact.initializer_body_id) orelse return error.InvalidConstGlobalScalarInitFact;
            if (!global.is_const or !mir.ValueType.eql(global.ty, fact.value_ty) or !fact.value.isCompatibleWith(fact.value_ty))
                return error.InvalidConstGlobalScalarInitFact;
            for (const_global_scalar_inits[0..index]) |prior| {
                if (prior.initializer_body_id.eql(fact.initializer_body_id)) return error.DuplicateConstGlobalScalarInitFact;
            }
        }
        for (globals) |global| {
            if (requiresScalarConstInitFact(global)) {
                _ = scalarConstInitFactForGlobal(const_global_scalar_inits, global) orelse return error.MissingConstGlobalScalarInitFact;
            }
        }
        return .{
            .callables = callables,
            .globals = globals,
            .signature_types = signature_types,
            .const_global_scalar_inits = const_global_scalar_inits,
        };
    }

    pub fn body(self: CheckedProgram, body_id: mir.BodyId) ?mir.CheckedCallableFact {
        if (!body_id.isValid() or body_id.index() >= self.callables.len) return null;
        const callable = self.callables[body_id.index()];
        if (!callable.body_id.eql(body_id)) return null;
        return callable;
    }

    pub fn matchesMir(self: CheckedProgram, module: mir.Module) bool {
        return self.globals.ptr == module.checked_globals.ptr and self.globals.len == module.checked_globals.len and
            self.signature_types.shapes.ptr == module.signature_types.shapes.ptr and self.signature_types.shapes.len == module.signature_types.shapes.len and
            self.const_global_scalar_inits.ptr == module.const_global_scalar_inits.ptr and
            self.const_global_scalar_inits.len == module.const_global_scalar_inits.len and
            callableFactsMatchMir(self.callables, module);
    }
};

fn requiresScalarConstInitFact(global: mir.CheckedGlobalFact) bool {
    if (!global.is_const or !global.initializer_body_id.isValid()) return false;
    return mir.valueTypeRequiresScalarConstInitFact(global.ty);
}

fn scalarConstInitFactForGlobal(facts: []const mir.ConstGlobalScalarInitFact, global: mir.CheckedGlobalFact) ?mir.ConstGlobalScalarInitFact {
    var found: ?mir.ConstGlobalScalarInitFact = null;
    for (facts) |fact| {
        if (!fact.initializer_body_id.eql(global.initializer_body_id)) continue;
        if (found != null) return null;
        found = fact;
    }
    return found;
}

fn globalForInitializer(
    callables: []const mir.CheckedCallableFact,
    globals: []const mir.CheckedGlobalFact,
    body_id: mir.BodyId,
) ?mir.CheckedGlobalFact {
    if (!body_id.isValid() or body_id.index() >= callables.len) return null;
    const callable = callables[body_id.index()];
    for (globals) |global| {
        if (global.initializer_body_id.eql(body_id) and global.symbol_id.eql(callable.symbol_id)) return global;
    }
    return null;
}

fn callableFactsMatchMir(callables: []const mir.CheckedCallableFact, module: mir.Module) bool {
    if (callables.len != module.functions.len) return false;
    for (callables, module.functions, 0..) |checked, function, index| {
        if (!checked.symbol_id.eql(function.typed_symbol_id) or !checked.source_id.eql(function.typed_source_id) or
            !checked.def_id.eql(function.typed_def_id)) return false;
        if (checked.kind != .global_initializer and
            !defIdMatchesSource(checked.def_id, checked.source_id, module.source_identities)) return false;
        if (!std.meta.eql(checked.return_ty, function.return_ty)) return false;
        if (checked.param_count != function.param_count or checked.param_types.len != function.param_types.len or
            checked.signature_param_type_ids.len != function.signature_param_type_ids.len or
            checked.c_abi != function.c_abi or checked.is_variadic != function.is_variadic) return false;
        if (!checked.signature_return_type_id.eql(function.signature_return_type_id)) return false;
        for (checked.param_types, function.param_types) |checked_type, mir_type| {
            if (!mir.ValueType.eql(checked_type, mir_type)) return false;
        }
        for (checked.signature_param_type_ids, function.signature_param_type_ids) |checked_type, mir_type| {
            if (!checked_type.eql(mir_type)) return false;
        }
        if (checked.no_lang_trap != function.no_lang_trap or checked.irq_context != function.irq_context) return false;

        if (function.is_extern) {
            if (checked.kind != .extern_function or checked.body_id.isValid()) return false;
        } else {
            if (checked.kind == .extern_function or !checked.body_id.isValid() or checked.body_id.index() != index) return false;
        }
        if (checked.kind == .global_initializer and (checked.param_count != 0 or checked.return_ty != .void or checked.c_abi or checked.is_variadic)) return false;
    }
    return true;
}

fn defIdMatchesSource(def_id: mir.DefId, source_id: mir.SourceId, sources: []const mir.SourceIdentity) bool {
    // Hand-built/unit-test MIR may not have a source table. Production
    // per-file programs do, and their declaration identity must agree with it.
    if (!source_id.isValid()) return true;
    if (!def_id.isValid() or source_id.index() >= sources.len) return false;
    const source = sources[source_id.index()];
    return source.id.eql(source_id) and source.file_id == def_id.file_id;
}

test "CheckedProgram rejects duplicate source declaration identities" {
    const signature_shapes = [_]mir.TypeShape{.{ .name = "void" }};
    const signature_types = mir.SignatureTypeTable{ .shapes = &signature_shapes };
    const callables = [_]mir.CheckedCallableFact{
        .{
            .def_id = .{ .file_id = 7, .ordinal = 3 },
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
        },
        .{
            .def_id = .{ .file_id = 7, .ordinal = 3 },
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
        },
    };
    try std.testing.expectError(error.DuplicateDefinitionIdentity, CheckedProgram.init(&callables, &.{}, signature_types, &.{}));
}

test "declaration identity must belong to the callable source file" {
    const sources = [_]mir.SourceIdentity{
        .{ .id = mir.SourceId.fromIndex(0), .file_id = 4 },
    };
    try std.testing.expect(defIdMatchesSource(.{ .file_id = 4, .ordinal = 1 }, mir.SourceId.fromIndex(0), &sources));
    try std.testing.expect(!defIdMatchesSource(.{ .file_id = 5, .ordinal = 1 }, mir.SourceId.fromIndex(0), &sources));
}
