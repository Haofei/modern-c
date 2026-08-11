const std = @import("std");

const codegen_options = @import("codegen_options.zig");
const legacy_backend_syntax = @import("legacy_backend_syntax.zig");
const source_map_mechanics = @import("source_map_mechanics.zig");
const verified_program = @import("verified_program.zig");

/// Backend lowering request.
///
/// `early_declaration_metadata` is intentionally named as a transitional
/// adapter: lowerers still need declaration slices for not-yet-normalized early
/// metadata and comptime mechanics, but the backend vtable receives the narrow
/// view needed for that use case rather than a generic legacy declaration
/// handle.
pub const LowerRequest = struct {
    program: verified_program.VerifiedProgram,
    early_declaration_metadata: legacy_backend_syntax.EarlyDeclarationMetadataView,
    out: *std.ArrayList(u8),
    opts: codegen_options.LowerOptions,
};

/// Backend source-map request. This stays separate from ordinary lowering so
/// the remaining source-map syntax mechanics are explicit and isolated from
/// code-generation semantics.
pub const EmitMapRequest = struct {
    program: verified_program.VerifiedProgram,
    source_map_mechanics: source_map_mechanics.SourceMapMechanicsView,
    out: *std.ArrayList(u8),
    generated_artifact: []const u8,
    opts: codegen_options.LowerOptions,
};

test "codegen requests keep legacy syntax mechanics behind named adapter fields" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/codegen_request.zig", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "early_declaration_metadata") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "source_map_mechanics") != null);
}
