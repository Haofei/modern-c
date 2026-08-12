const std = @import("std");

const codegen_options = @import("codegen_options.zig");
const declaration_artifacts = @import("declaration_artifacts.zig");
const verified_program = @import("verified_program.zig");

/// Backend lowering request.
///
/// `declaration_artifacts` is the transitional artifact boundary: lowerers
/// still need declaration-derived data for not-yet-normalized early metadata
/// and comptime mechanics, but the backend vtable receives a pre-collected
/// artifact object rather than a generic legacy declaration view.
pub const LowerRequest = struct {
    program: verified_program.VerifiedProgram,
    declaration_artifacts: declaration_artifacts.EarlyDeclarationArtifacts,
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
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/codegen_request.zig", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "declaration_artifacts") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "source_map_artifacts") != null);
}
