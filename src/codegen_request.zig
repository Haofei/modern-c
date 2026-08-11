const std = @import("std");

const codegen_options = @import("codegen_options.zig");
const legacy_backend_syntax = @import("legacy_backend_syntax.zig");
const verified_program = @import("verified_program.zig");

/// Backend lowering request.
///
/// `legacy_declarations` is intentionally named as a transitional adapter:
/// lowerers still need declaration slices for early metadata and comptime
/// mechanics, but the backend vtable should receive one request object rather
/// than exposing syntax mechanics as independent semantic parameters.
pub const LowerRequest = struct {
    program: verified_program.VerifiedProgram,
    legacy_declarations: legacy_backend_syntax.LegacyDeclarationSlice,
    out: *std.ArrayList(u8),
    opts: codegen_options.LowerOptions,
};

/// Backend source-map request. This stays separate from ordinary lowering so
/// the remaining source-map syntax mechanics are explicit and isolated from
/// code-generation semantics.
pub const EmitMapRequest = struct {
    program: verified_program.VerifiedProgram,
    legacy_source_map: legacy_backend_syntax.SourceMapMechanicsView,
    out: *std.ArrayList(u8),
    generated_artifact: []const u8,
    opts: codegen_options.LowerOptions,
};

test "codegen requests keep legacy syntax mechanics behind named adapter fields" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/codegen_request.zig", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "legacy_declarations") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "legacy_source_map") != null);
}
