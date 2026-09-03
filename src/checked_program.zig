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

    pub fn init(callables: []const mir.CheckedCallableFact, globals: []const mir.CheckedGlobalFact) !CheckedProgram {
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
        return .{ .callables = callables, .globals = globals };
    }

    pub fn body(self: CheckedProgram, body_id: mir.BodyId) ?mir.CheckedCallableFact {
        if (!body_id.isValid() or body_id.index() >= self.callables.len) return null;
        const callable = self.callables[body_id.index()];
        if (!callable.body_id.eql(body_id)) return null;
        return callable;
    }

    pub fn matchesMir(self: CheckedProgram, module: mir.Module) bool {
        return self.globals.ptr == module.checked_globals.ptr and self.globals.len == module.checked_globals.len and
            callableFactsMatchMir(self.callables, module);
    }
};

fn callableFactsMatchMir(callables: []const mir.CheckedCallableFact, module: mir.Module) bool {
    if (callables.len != module.functions.len) return false;
    for (callables, module.functions, 0..) |checked, function, index| {
        if (!checked.symbol_id.eql(function.typed_symbol_id) or !checked.source_id.eql(function.typed_source_id) or
            !checked.def_id.eql(function.typed_def_id)) return false;
        if (!std.meta.eql(checked.return_ty, function.return_ty)) return false;
        if (checked.param_count != function.param_count or checked.param_types.len != function.param_types.len or
            checked.c_abi != function.c_abi or checked.is_variadic != function.is_variadic) return false;
        for (checked.param_types, function.param_types) |checked_type, mir_type| {
            if (!mir.ValueType.eql(checked_type, mir_type)) return false;
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

test "CheckedProgram rejects duplicate source declaration identities" {
    const callables = [_]mir.CheckedCallableFact{
        .{
            .def_id = .{ .file_id = 7, .ordinal = 3 },
            .symbol_id = mir.SymbolId.fromIndex(0),
            .source_id = .invalid,
            .body_id = mir.BodyId.fromIndex(0),
            .kind = .function,
            .return_ty = .void,
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
            .param_count = 0,
            .c_abi = false,
            .no_lang_trap = false,
            .irq_context = false,
        },
    };
    try std.testing.expectError(error.DuplicateDefinitionIdentity, CheckedProgram.init(&callables, &.{}));
}
