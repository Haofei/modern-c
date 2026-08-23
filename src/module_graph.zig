const std = @import("std");

const diagnostics = @import("diagnostics.zig");

pub const FileId = enum(u32) { _ };

pub const ModuleFile = struct {
    id: FileId,
    canonical_path: []const u8,
    display_path: []const u8,
    depth: usize,
};

pub const ImportEdge = struct {
    importer: FileId,
    imported: FileId,
    span: diagnostics.Span,
};

pub const SourceFile = struct {
    id: FileId,
    /// Original source bytes after BOM stripping. Import directives remain
    /// present so tools can inspect the file exactly as loaded.
    source: []const u8,
    /// Parser-ready per-file source. Import directive bytes are blanked while
    /// offsets remain local to this FileId.
    parser_source: []const u8,
};

/// SourceDatabase owns each module file's independent source buffer.
pub const SourceDatabase = struct {
    files: []SourceFile,

    /// Stable digest of the complete source set in loader order. A single-file
    /// project hashes exactly that file's bytes, preserving the public artifact
    /// metadata contract without materializing a combined source buffer.
    pub fn digest(self: SourceDatabase) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
        var project = std.crypto.hash.sha2.Sha256.init(.{});
        for (self.files) |file| {
            project.update(file.source);
        }
        var result: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        project.final(&result);
        return result;
    }

    pub fn sourceForFile(self: SourceDatabase, id: FileId) ?[]const u8 {
        for (self.files) |file| {
            if (file.id == id) return file.source;
        }
        return null;
    }

    pub fn parserSourceForFile(self: SourceDatabase, id: FileId) ?[]const u8 {
        for (self.files) |file| {
            if (file.id == id) return file.parser_source;
        }
        return null;
    }

    pub fn diagnosticViews(
        self: SourceDatabase,
        allocator: std.mem.Allocator,
        graph: ModuleGraph,
    ) ![]diagnostics.SourceView {
        const views = try allocator.alloc(diagnostics.SourceView, self.files.len);
        errdefer allocator.free(views);
        for (self.files, 0..) |source_file, index| {
            const module_file = graph.fileById(source_file.id) orelse return error.MissingModuleFile;
            views[index] = .{
                .file_id = @intFromEnum(source_file.id),
                .path = module_file.display_path,
                .source = source_file.parser_source,
            };
        }
        return views;
    }

    pub fn deinit(self: *SourceDatabase, allocator: std.mem.Allocator) void {
        for (self.files) |file| {
            allocator.free(file.source);
            allocator.free(file.parser_source);
        }
        allocator.free(self.files);
    }
};

/// ModuleGraph is the stable file/import identity model.
pub const ModuleGraph = struct {
    files: []ModuleFile,
    imports: []ImportEdge,

    pub fn fileById(self: ModuleGraph, id: FileId) ?ModuleFile {
        for (self.files) |module_file| if (module_file.id == id) return module_file;
        return null;
    }

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
    graph: ModuleGraph,
    source_db: SourceDatabase,

    pub fn deinit(self: *LoadedProject, allocator: std.mem.Allocator) void {
        self.graph.deinit(allocator);
        self.source_db.deinit(allocator);
    }
};

test "ModuleGraph owns file and import slices" {
    var graph = ModuleGraph{
        .files = try std.testing.allocator.alloc(ModuleFile, 1),
        .imports = try std.testing.allocator.alloc(ImportEdge, 0),
    };
    graph.files[0] = .{
        .id = @enumFromInt(0),
        .canonical_path = try std.testing.allocator.dupe(u8, "/tmp/root.mc"),
        .display_path = try std.testing.allocator.dupe(u8, "root.mc"),
        .depth = 0,
    };
    graph.deinit(std.testing.allocator);
}

test "SourceDatabase maps file ids to independent source buffers" {
    var db = SourceDatabase{
        .files = try std.testing.allocator.alloc(SourceFile, 1),
    };
    db.files[0] = .{
        .id = @enumFromInt(0),
        .source = try std.testing.allocator.dupe(u8, "let x: u32 = 1;"),
        .parser_source = try std.testing.allocator.dupe(u8, "let x: u32 = 1;"),
    };
    defer db.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("let x: u32 = 1;", db.sourceForFile(@enumFromInt(0)).?);
    try std.testing.expectEqualStrings("let x: u32 = 1;", db.parserSourceForFile(@enumFromInt(0)).?);
    try std.testing.expect(db.sourceForFile(@enumFromInt(1)) == null);
    try std.testing.expect(db.parserSourceForFile(@enumFromInt(1)) == null);
}

test "SourceDatabase diagnostic views join graph paths by stable file id" {
    var graph = ModuleGraph{
        .files = try std.testing.allocator.alloc(ModuleFile, 2),
        .imports = try std.testing.allocator.alloc(ImportEdge, 0),
    };
    defer graph.deinit(std.testing.allocator);
    graph.files[0] = .{
        .id = @enumFromInt(3),
        .canonical_path = try std.testing.allocator.dupe(u8, "/tmp/root.mc"),
        .display_path = try std.testing.allocator.dupe(u8, "root.mc"),
        .depth = 0,
    };
    graph.files[1] = .{
        .id = @enumFromInt(7),
        .canonical_path = try std.testing.allocator.dupe(u8, "/tmp/lib.mc"),
        .display_path = try std.testing.allocator.dupe(u8, "lib.mc"),
        .depth = 1,
    };

    var db = SourceDatabase{
        .files = try std.testing.allocator.alloc(SourceFile, 2),
    };
    defer db.deinit(std.testing.allocator);
    db.files[0] = .{
        .id = @enumFromInt(7),
        .source = try std.testing.allocator.dupe(u8, "original lib"),
        .parser_source = try std.testing.allocator.dupe(u8, "parsed lib"),
    };
    db.files[1] = .{
        .id = @enumFromInt(3),
        .source = try std.testing.allocator.dupe(u8, "original root"),
        .parser_source = try std.testing.allocator.dupe(u8, "parsed root"),
    };

    const views = try db.diagnosticViews(std.testing.allocator, graph);
    defer std.testing.allocator.free(views);
    try std.testing.expectEqual(@as(u32, 7), views[0].file_id);
    try std.testing.expectEqualStrings("lib.mc", views[0].path);
    try std.testing.expectEqualStrings("parsed lib", views[0].source);
    try std.testing.expectEqual(@as(u32, 3), views[1].file_id);
    try std.testing.expectEqualStrings("root.mc", views[1].path);
    try std.testing.expectEqualStrings("parsed root", views[1].source);
}
