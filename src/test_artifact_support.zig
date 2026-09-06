const std = @import("std");

const ast = @import("ast.zig");
const mir = @import("mir_model.zig");

/// Test-only view of source-map facts already admitted into typed MIR.
///
/// The declaration slice stays in this transitional signature solely to keep
/// older test helpers source-compatible; it is neither inspected nor retained.
pub const SourceMapFacts = struct {
    declarations: []const mir.SourceMapDeclarationFact,

    pub fn deinit(self: *SourceMapFacts, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

pub fn collectArtifactsFromDecls(allocator: std.mem.Allocator, decls: []const ast.Decl, typed_mir: *const mir.Module) !SourceMapFacts {
    _ = allocator;
    _ = decls;
    return .{ .declarations = typed_mir.source_map_declarations };
}
