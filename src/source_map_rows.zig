const declaration_artifacts = @import("declaration_artifacts.zig");
const std = @import("std");

/// Transitional source-map row artifacts. Source maps still need syntax-shaped
/// spans until rows are generated from MIR/source-span tables, but syntax
/// enumeration is isolated in `declaration_artifacts.zig` instead of being
/// exposed through backend map requests or re-imported here.
pub const SourceMapRows = struct {
    artifacts: []const RowArtifact,

    pub fn collectFromSourceArtifacts(
        allocator: std.mem.Allocator,
        source_artifacts: []const declaration_artifacts.SourceMapArtifact,
    ) !SourceMapRows {
        return .{ .artifacts = try allocator.dupe(RowArtifact, source_artifacts) };
    }

    pub fn deinit(self: *SourceMapRows, allocator: std.mem.Allocator) void {
        allocator.free(self.artifacts);
        self.* = .{ .artifacts = &.{} };
    }
};

pub const RowArtifact = declaration_artifacts.SourceMapArtifact;
