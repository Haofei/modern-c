const std = @import("std");

const codegen_options = @import("codegen_options.zig");
const declaration_artifacts = @import("declaration_artifacts.zig");
const verified_program = @import("verified_program.zig");

/// Backend lowering request.
///
/// `declaration_artifacts` is the transitional ordinary-codegen artifact
/// boundary: lowerers still need declaration-derived data for
/// not-yet-normalized early metadata and comptime mechanics, but source-map row
/// artifacts are not exposed to ordinary lowering.
pub const LowerRequest = struct {
    program: verified_program.VerifiedProgram,
    declaration_artifacts: declaration_artifacts.CodegenDeclarationArtifacts,
    out: *std.ArrayList(u8),
    opts: codegen_options.LowerOptions,
};

/// Backend source-map request. This stays separate from ordinary lowering so
/// the remaining source-map syntax row enumeration is explicit and isolated
/// from code-generation semantics.
pub const EmitMapRequest = struct {
    program: verified_program.VerifiedProgram,
    source_map_artifacts: []const declaration_artifacts.SourceMapArtifact,
    out: *std.ArrayList(u8),
    generated_artifact: []const u8,
    opts: codegen_options.LowerOptions,
};

test "codegen requests keep syntax mechanics behind named artifact fields" {
    try std.testing.expect(@hasField(LowerRequest, "declaration_artifacts"));
    try std.testing.expect(!@hasField(LowerRequest, "source_map_artifacts"));
    try std.testing.expect(!@hasField(EmitMapRequest, "declaration_artifacts"));
    try std.testing.expect(@hasField(EmitMapRequest, "source_map_artifacts"));
}
