const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const module_graph = @import("module_graph.zig");
const name_resolve = @import("name_resolve.zig");
const parser = @import("parser.zig");

pub const ParsedSourceFile = struct {
    id: module_graph.FileId,
    module: ast.Module,
};

/// ParsedSourceDatabase is the parser-owned per-file syntax boundary.
///
/// It deliberately consumes `SourceDatabase.parser_source` instead of the
/// legacy combined source. Name resolution and sema still consume the flattened
/// module today, but this gives the module model a concrete AST ownership point
/// that is independent from expanded byte offsets.
pub const ParsedSourceDatabase = struct {
    files: []ParsedSourceFile,

    pub fn moduleForFile(self: ParsedSourceDatabase, id: module_graph.FileId) ?ast.Module {
        for (self.files) |file| {
            if (file.id == id) return file.module;
        }
        return null;
    }

    pub fn deinit(self: *ParsedSourceDatabase, allocator: std.mem.Allocator) void {
        for (self.files) |file| file.module.deinit(allocator);
        allocator.free(self.files);
    }
};

pub const ResolvedSourceFile = struct {
    id: module_graph.FileId,
    module: ast.Module,
};

pub const ResolvedDecl = struct {
    file_id: module_graph.FileId,
    decl: ast.Decl,
};

/// ResolvedSourceDatabase is the per-file name-resolution boundary.
///
/// It keeps qualified-symbol rewriting attached to each FileId instead of
/// requiring a flattened whole-program AST. Cross-file import visibility is
/// still a later phase, but per-file syntax no longer has to round-trip through
/// the legacy combined module to run local name resolution.
pub const ResolvedSourceDatabase = struct {
    files: []ResolvedSourceFile,

    pub fn moduleForFile(self: ResolvedSourceDatabase, id: module_graph.FileId) ?ast.Module {
        for (self.files) |file| {
            if (file.id == id) return file.module;
        }
        return null;
    }

    pub fn declCount(self: ResolvedSourceDatabase) usize {
        var count: usize = 0;
        for (self.files) |file| count += file.module.decls.len;
        return count;
    }

    pub fn collectDecls(self: ResolvedSourceDatabase, allocator: std.mem.Allocator) ![]ResolvedDecl {
        var decls: std.ArrayList(ResolvedDecl) = .empty;
        errdefer decls.deinit(allocator);
        try decls.ensureTotalCapacity(allocator, self.declCount());
        for (self.files) |file| {
            for (file.module.decls) |decl| {
                decls.appendAssumeCapacity(.{
                    .file_id = file.id,
                    .decl = decl,
                });
            }
        }
        return decls.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *ResolvedSourceDatabase, allocator: std.mem.Allocator) void {
        for (self.files) |file| file.module.deinit(allocator);
        allocator.free(self.files);
    }
};

pub fn parseSourceDatabase(
    allocator: std.mem.Allocator,
    graph: module_graph.ModuleGraph,
    sources: module_graph.SourceDatabase,
    reporter: *diagnostics.Reporter,
) !ParsedSourceDatabase {
    var files: std.ArrayList(ParsedSourceFile) = .empty;
    errdefer {
        for (files.items) |file| file.module.deinit(allocator);
        files.deinit(allocator);
    }

    for (graph.files) |file| {
        const parser_source = sources.parserSourceForFile(file.id) orelse return error.MissingModuleSource;
        const saved_path = reporter.path;
        const saved_source = reporter.source;
        const saved_boundaries = reporter.file_boundaries;
        reporter.path = file.display_path;
        reporter.source = parser_source;
        reporter.file_boundaries = null;
        var parsed_ok = false;
        defer if (parsed_ok) {
            reporter.path = saved_path;
            reporter.source = saved_source;
            reporter.file_boundaries = saved_boundaries;
        };
        var file_parser = parser.Parser.init(parser_source, reporter);
        const parsed = try file_parser.parseModule(allocator);
        parsed_ok = true;
        var parsed_transferred = false;
        errdefer if (!parsed_transferred) parsed.deinit(allocator);
        try files.append(allocator, .{
            .id = file.id,
            .module = parsed,
        });
        parsed_transferred = true;
    }

    return .{
        .files = try files.toOwnedSlice(allocator),
    };
}

pub fn resolveParsedSourceDatabase(
    allocator: std.mem.Allocator,
    parsed_sources: ParsedSourceDatabase,
) !ResolvedSourceDatabase {
    var files: std.ArrayList(ResolvedSourceFile) = .empty;
    errdefer {
        for (files.items) |file| file.module.deinit(allocator);
        files.deinit(allocator);
    }

    for (parsed_sources.files) |file| {
        const resolved = try name_resolve.transform(allocator, file.module);
        var resolved_transferred = false;
        errdefer if (!resolved_transferred) resolved.deinit(allocator);
        try files.append(allocator, .{
            .id = file.id,
            .module = resolved,
        });
        resolved_transferred = true;
    }

    return .{
        .files = try files.toOwnedSlice(allocator),
    };
}

test "ParsedSourceDatabase owns per-file AST modules" {
    var graph = module_graph.ModuleGraph{
        .files = try std.testing.allocator.alloc(module_graph.ModuleFile, 1),
        .imports = try std.testing.allocator.alloc(module_graph.ImportEdge, 0),
    };
    graph.files[0] = .{
        .id = @enumFromInt(0),
        .canonical_path = try std.testing.allocator.dupe(u8, "/tmp/root.mc"),
        .display_path = try std.testing.allocator.dupe(u8, "root.mc"),
        .depth = 0,
        .source_start = 0,
        .source_len = 27,
    };
    defer graph.deinit(std.testing.allocator);

    var sources = module_graph.SourceDatabase{
        .files = try std.testing.allocator.alloc(module_graph.SourceFile, 1),
    };
    sources.files[0] = .{
        .id = @enumFromInt(0),
        .source = try std.testing.allocator.dupe(u8, "fn answer() -> u32 { return 1; }\n"),
        .parser_source = try std.testing.allocator.dupe(u8, "fn answer() -> u32 { return 1; }\n"),
    };
    defer sources.deinit(std.testing.allocator);

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "root.mc", sources.files[0].parser_source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parsed = try parseSourceDatabase(arena.allocator(), graph, sources, &reporter);
    defer parsed.deinit(arena.allocator());

    try std.testing.expect(!reporter.has_errors);
    try std.testing.expectEqual(@as(usize, 1), parsed.files.len);
    const root_module = parsed.moduleForFile(@enumFromInt(0)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), root_module.decls.len);
    try std.testing.expect(parsed.moduleForFile(@enumFromInt(1)) == null);
}

test "ResolvedSourceDatabase runs per-file name resolution" {
    var graph = module_graph.ModuleGraph{
        .files = try std.testing.allocator.alloc(module_graph.ModuleFile, 1),
        .imports = try std.testing.allocator.alloc(module_graph.ImportEdge, 0),
    };
    graph.files[0] = .{
        .id = @enumFromInt(0),
        .canonical_path = try std.testing.allocator.dupe(u8, "/tmp/root.mc"),
        .display_path = try std.testing.allocator.dupe(u8, "root.mc"),
        .depth = 0,
        .source_start = 0,
        .source_len = 87,
    };
    defer graph.deinit(std.testing.allocator);

    const source =
        \\module Math {
        \\    fn one() -> u32 { return 1; }
        \\}
        \\fn answer() -> u32 { return Math.one(); }
        \\
    ;
    var sources = module_graph.SourceDatabase{
        .files = try std.testing.allocator.alloc(module_graph.SourceFile, 1),
    };
    sources.files[0] = .{
        .id = @enumFromInt(0),
        .source = try std.testing.allocator.dupe(u8, source),
        .parser_source = try std.testing.allocator.dupe(u8, source),
    };
    defer sources.deinit(std.testing.allocator);

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "root.mc", sources.files[0].parser_source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parsed = try parseSourceDatabase(arena.allocator(), graph, sources, &reporter);
    defer parsed.deinit(arena.allocator());
    var resolved = try resolveParsedSourceDatabase(arena.allocator(), parsed);
    defer resolved.deinit(arena.allocator());

    try std.testing.expect(!reporter.has_errors);
    const root_module = resolved.moduleForFile(@enumFromInt(0)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), root_module.decls.len);
    const answer = root_module.decls[1].kind.fn_decl;
    const return_expr = answer.body.?.items[0].kind.@"return".?.kind.call.callee.kind.ident;
    try std.testing.expectEqualStrings("Math__one", return_expr.text);

    const decls = try resolved.collectDecls(std.testing.allocator);
    defer std.testing.allocator.free(decls);
    try std.testing.expectEqual(@as(usize, 2), decls.len);
    try std.testing.expectEqual(@as(module_graph.FileId, @enumFromInt(0)), decls[0].file_id);
    try std.testing.expectEqual(@as(module_graph.FileId, @enumFromInt(0)), decls[1].file_id);
    const collected_answer = decls[1].decl.kind.fn_decl;
    try std.testing.expectEqualStrings("answer", collected_answer.name.text);
}
