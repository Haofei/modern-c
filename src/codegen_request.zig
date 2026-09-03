const std = @import("std");

const codegen_options = @import("codegen_options.zig");
const declaration_artifacts = @import("declaration_artifacts.zig");
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

test "codegen requests keep source map mechanics out of ordinary lowering" {
    try std.testing.expect(@hasField(LowerRequest, "declaration_artifacts"));
    try std.testing.expect(!@hasField(LowerRequest, "function_bodies"));
    try std.testing.expect(!@hasField(LowerRequest, "source_map_artifacts"));
    try std.testing.expect(!@hasField(EmitMapRequest, "declaration_artifacts"));
    try std.testing.expect(!@hasField(EmitMapRequest, "function_bodies"));
    try std.testing.expect(@hasField(EmitMapRequest, "source_map_artifacts"));
}
