const std = @import("std");

const diagnostics = @import("diagnostics.zig");

pub const FileBoundary = diagnostics.FileBoundary;
pub const FileId = enum(u32) { _ };

pub const ModuleFile = struct {
    id: FileId,
    canonical_path: []const u8,
    display_path: []const u8,
    depth: usize,
    source_start: usize = 0,
    source_len: usize = 0,
};

pub const ImportEdge = struct {
    importer: FileId,
    imported: FileId,
    span: diagnostics.Span,
};

/// ModuleGraph is the stable file/import identity model. The current loader
/// still builds a combined textual source for the legacy frontend, but graph
/// ownership is separate so future parser/sema work can consume per-file
/// identities without treating expanded byte offsets as semantic identity.
pub const ModuleGraph = struct {
    files: []ModuleFile,
    imports: []ImportEdge,

    pub fn deinit(self: *ModuleGraph, allocator: std.mem.Allocator) void {
        for (self.files) |file| {
            allocator.free(file.canonical_path);
            allocator.free(file.display_path);
        }
        allocator.free(self.files);
        allocator.free(self.imports);
    }
};

pub const LoadedProject = struct {
    source: []u8,
    boundaries: []FileBoundary,
    graph: ModuleGraph,

    pub fn deinit(self: *LoadedProject, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        for (self.boundaries) |boundary| allocator.free(boundary.path);
        allocator.free(self.boundaries);
        self.graph.deinit(allocator);
    }
};

test "ModuleGraph owns file and import slices independently from combined source" {
    var graph = ModuleGraph{
        .files = try std.testing.allocator.alloc(ModuleFile, 1),
        .imports = try std.testing.allocator.alloc(ImportEdge, 0),
    };
    graph.files[0] = .{
        .id = @enumFromInt(0),
        .canonical_path = try std.testing.allocator.dupe(u8, "/tmp/root.mc"),
        .display_path = try std.testing.allocator.dupe(u8, "root.mc"),
        .depth = 0,
        .source_start = 0,
        .source_len = 7,
    };
    graph.deinit(std.testing.allocator);
}
