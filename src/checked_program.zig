//! Minimal syntax-free semantic boundary.
//!
//! This is intentionally not a second expression IR. Callable identity,
//! signature representation, ABI, and closed effect flags live here; function
//! bodies remain canonical typed MIR. The table is produced with MIR today and
//! can move earlier in the pipeline without changing backend consumers.

const std = @import("std");

const mir = @import("mir.zig");

pub const CheckedProgram = struct {
    callables: []const mir.CheckedCallableFact,

    pub fn init(module: *const mir.Module) !CheckedProgram {
        if (!callableFactsMatchMir(module.*)) return error.InvalidCheckedProgram;
        return .{ .callables = module.checked_callables };
    }

    pub fn body(self: CheckedProgram, body_id: mir.BodyId) ?mir.CheckedCallableFact {
        if (!body_id.isValid() or body_id.index() >= self.callables.len) return null;
        const callable = self.callables[body_id.index()];
        if (!callable.body_id.eql(body_id)) return null;
        return callable;
    }
};

fn callableFactsMatchMir(module: mir.Module) bool {
    if (module.checked_callables.len != module.functions.len) return false;
    for (module.checked_callables, module.functions, 0..) |checked, function, index| {
        if (!checked.symbol_id.eql(function.typed_symbol_id) or !checked.source_id.eql(function.typed_source_id)) return false;
        if (checked.kind != function.callable_kind or !std.meta.eql(checked.return_ty, function.return_ty)) return false;
        if (checked.param_count != function.param_count or checked.c_abi != function.c_abi) return false;
        if (checked.no_lang_trap != function.no_lang_trap or checked.irq_context != function.irq_context) return false;

        if (function.is_extern) {
            if (checked.kind != .extern_function or checked.body_id.isValid()) return false;
        } else {
            if (checked.kind == .extern_function or !checked.body_id.isValid() or checked.body_id.index() != index) return false;
        }
        if (checked.kind == .global_initializer and (checked.param_count != 0 or checked.return_ty != .void)) return false;
    }
    return true;
}
