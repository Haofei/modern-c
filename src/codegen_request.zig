const std = @import("std");

const codegen_options = @import("codegen_options.zig");
const declaration_artifacts = @import("declaration_artifacts.zig");
const diagnostics = @import("diagnostics.zig");
const mir = @import("mir_model.zig");
const CgDeclArtifacts = declaration_artifacts.CodegenDeclarationArtifacts;
const SourceMapArtifact = declaration_artifacts.SourceMapArtifact;
const verified_program = @import("verified_program.zig");

/// Backend lowering request.
///
/// `declaration_artifacts` is the transitional ordinary-codegen artifact
/// boundary: lowerers still need declaration-derived data for
/// not-yet-normalized early metadata and comptime mechanics, but source-map row
/// artifacts and function-body syntax fallbacks are not bundled into that
/// declaration view.
pub const LowerRequest = struct {
    program: verified_program.VerifiedProgram,
    declaration_artifacts: CgDeclArtifacts,
    out: *std.ArrayList(u8),
    opts: codegen_options.LowerOptions,
};

/// Backend source-map request. This stays separate from ordinary lowering so
/// the remaining source-map syntax row enumeration is explicit and isolated
/// from code-generation semantics.
pub const EmitMapRequest = struct {
    program: verified_program.VerifiedProgram,
    source_map_artifacts: []const SourceMapArtifact,
    out: *std.ArrayList(u8),
    generated_artifact: []const u8,
    opts: codegen_options.LowerOptions,
};

/// Dynamic trait objects are intentionally outside the qualified backend
/// surface.  Static trait uses are monomorphized before MIR construction and
/// therefore do not carry any of these dynamic representation facts.
///
/// Keep this admission at the shared codegen boundary: C and LLVM must fail
/// the same way instead of each maintaining an AST/vtable fallback.
pub fn rejectExperimentalDynamicTraits(
    program: verified_program.VerifiedProgram,
    reporter: ?*diagnostics.Reporter,
) error{ExperimentalDynamicTraitCodegen}!void {
    // The checked signature table covers extern declarations, which deliberately
    // have no executable body.  Do this before inspecting body-local facts so a
    // `extern fn use(value: *dyn Trait)` cannot bypass qualified admission.
    for (program.checked.callables) |callable| {
        if (signatureTypeContainsDynamicTrait(program.checked.signature_types, callable.signature_return_type_id)) {
            reportExperimentalDynamicTrait(reporter);
            return error.ExperimentalDynamicTraitCodegen;
        }
        for (callable.signature_param_type_ids) |type_id| {
            if (signatureTypeContainsDynamicTrait(program.checked.signature_types, type_id)) {
                reportExperimentalDynamicTrait(reporter);
                return error.ExperimentalDynamicTraitCodegen;
            }
        }
    }
    for (program.typed_mir.functions) |function| {
        if (functionHasDynamicTraitRepresentation(function)) {
            reportExperimentalDynamicTrait(reporter);
            return error.ExperimentalDynamicTraitCodegen;
        }
    }
    for (program.checked.globals) |global| {
        if (global.dyn_trait_symbol_id.isValid() or global.ty == .nullable_dyn_trait or
            signatureTypeContainsDynamicTrait(program.checked.signature_types, global.signature_type_id))
        {
            reportExperimentalDynamicTrait(reporter);
            return error.ExperimentalDynamicTraitCodegen;
        }
    }
}

/// The signature graph is validated by `CheckedProgram` before it reaches this
/// admission. Missing rows still reject defensively: treating an unknown shape
/// as dyn-free would reopen the syntax-free extern declaration escape hatch.
fn signatureTypeContainsDynamicTrait(types: mir.SignatureTypeTable, id: mir.SignatureTypeId) bool {
    const shape = types.get(id) orelse return true;
    return switch (shape) {
        .dyn_trait => true,
        .name, .enum_literal => false,
        .member => |value| signatureTypeContainsDynamicTrait(types, value.base),
        .nullable => |child| signatureTypeContainsDynamicTrait(types, child),
        .qualified => |value| signatureTypeContainsDynamicTrait(types, value.child),
        .pointer => |value| signatureTypeContainsDynamicTrait(types, value.child),
        .raw_many_pointer => |value| signatureTypeContainsDynamicTrait(types, value.child),
        .slice => |value| signatureTypeContainsDynamicTrait(types, value.child),
        .array => |value| signatureTypeContainsDynamicTrait(types, value.child),
        .generic => |value| signatureTypeIdsContainDynamicTrait(types, value.args),
        .fn_pointer => |value| signatureTypeContainsDynamicTrait(types, value.ret) or
            signatureTypeIdsContainDynamicTrait(types, value.params),
        .closure_type => |value| signatureTypeContainsDynamicTrait(types, value.ret) or
            signatureTypeIdsContainDynamicTrait(types, value.params),
    };
}

fn signatureTypeIdsContainDynamicTrait(types: mir.SignatureTypeTable, ids: []const mir.SignatureTypeId) bool {
    for (ids) |id| if (signatureTypeContainsDynamicTrait(types, id)) return true;
    return false;
}

fn reportExperimentalDynamicTrait(reporter: ?*diagnostics.Reporter) void {
    if (reporter) |active_reporter| active_reporter.err(.{
        .offset = 0,
        .len = 0,
        .line = 1,
        .column = 1,
    }, "E_EXPERIMENTAL_DYN_CODEGEN: dynamic trait objects are experimental and are not admitted by qualified backends", .{});
}

fn functionHasDynamicTraitRepresentation(function: mir.Function) bool {
    const body = function.executable_body;
    if (body.return_dyn_trait_symbol_id.isValid()) return true;
    for (body.parameters) |parameter| if (parameter.dyn_trait_symbol_id.isValid()) return true;
    for (body.locals) |local| if (local.dyn_trait_symbol_id.isValid()) return true;
    for (body.aggregate_types) |aggregate| {
        for (aggregate.field_dyn_trait_symbols[0..aggregate.field_count]) |trait_symbol| {
            if (trait_symbol.isValid()) return true;
        }
    }
    for (body.expressions) |expression| switch (expression.operation) {
        .dyn_bind, .dyn_call => return true,
        else => {},
    };
    return false;
}

test "codegen requests keep source map mechanics out of ordinary lowering" {
    try std.testing.expect(@hasField(LowerRequest, "declaration_artifacts"));
    try std.testing.expect(!@hasField(LowerRequest, "function_bodies"));
    try std.testing.expect(!@hasField(LowerRequest, "source_map_artifacts"));
    try std.testing.expect(!@hasField(EmitMapRequest, "declaration_artifacts"));
    try std.testing.expect(!@hasField(EmitMapRequest, "function_bodies"));
    try std.testing.expect(@hasField(EmitMapRequest, "source_map_artifacts"));
}

test "dynamic trait signature admission traverses nested syntax-free shapes" {
    const ids = [_]mir.SignatureTypeId{
        mir.SignatureTypeId.fromIndex(0),
        mir.SignatureTypeId.fromIndex(4),
    };
    const shapes = [_]mir.TypeShape{
        .{ .dyn_trait = .{ .mutability = .none, .trait_name = "Shape" } },
        .{ .nullable = mir.SignatureTypeId.fromIndex(0) },
        .{ .pointer = .{ .mutability = .constant, .child = mir.SignatureTypeId.fromIndex(1) } },
        .{ .generic = .{ .base = "Result", .args = ids[0..1] } },
        .{ .fn_pointer = .{ .params = ids[0..1], .ret = mir.SignatureTypeId.fromIndex(3) } },
        .{ .closure_type = .{ .params = ids[1..], .ret = mir.SignatureTypeId.fromIndex(2) } },
    };
    const types = mir.SignatureTypeTable{ .shapes = shapes[0..] };
    try std.testing.expect(types.validate());
    try std.testing.expect(signatureTypeContainsDynamicTrait(types, mir.SignatureTypeId.fromIndex(5)));
}
