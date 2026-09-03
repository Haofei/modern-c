const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const module_graph = @import("module_graph.zig");
const name_resolve = @import("name_resolve.zig");
const parser = @import("parser.zig");
const semantic_ids = @import("semantic_ids.zig");

pub const ParsedSourceFile = struct {
    id: module_graph.FileId,
    module: ast.Module,

    pub fn decls(self: ParsedSourceFile) []ast.Decl {
        return self.module.decls;
    }

    pub fn qualifiedSymbols(self: ParsedSourceFile) []const ast.QualifiedSymbol {
        return self.module.qualified_symbols;
    }

    pub fn deinit(self: ParsedSourceFile, allocator: std.mem.Allocator) void {
        self.module.deinit(allocator);
    }
};

/// ParsedSourceDatabase is the parser-owned per-file syntax boundary.
///
/// It consumes `SourceDatabase.parser_source`; source offsets and AST ownership
/// remain local to each FileId.
pub const ParsedSourceDatabase = struct {
    files: []ParsedSourceFile,

    pub fn declsForFile(self: ParsedSourceDatabase, id: module_graph.FileId) ?[]const ast.Decl {
        for (self.files) |file| {
            if (file.id == id) return file.decls();
        }
        return null;
    }

    pub fn deinit(self: *ParsedSourceDatabase, allocator: std.mem.Allocator) void {
        for (self.files) |file| file.deinit(allocator);
        allocator.free(self.files);
    }
};

pub const ResolvedSourceFile = struct {
    id: module_graph.FileId,
    decls: []ast.Decl,
    qualified_owners: [][]const u8 = &.{},
};

pub const ResolvedDecl = struct {
    /// Assigned after all declaration-producing frontend transforms. It is
    /// stable for this compilation request and is the codegen declaration
    /// join key; source spelling remains presentation/linkage only.
    def_id: semantic_ids.DefId = .invalid,
    file_id: module_graph.FileId,
    decl: ast.Decl,
};

pub const ResolvedProgram = struct {
    decls: []ResolvedDecl,
    visibility_mode: ast.VisibilityMode,
    qualified_owners: [][]const u8,

    pub fn astDecls(self: ResolvedProgram, allocator: std.mem.Allocator) ![]ast.Decl {
        const decls = try allocator.alloc(ast.Decl, self.decls.len);
        for (self.decls, 0..) |entry, index| decls[index] = entry.decl;
        return decls;
    }

    pub fn deinit(self: *ResolvedProgram, allocator: std.mem.Allocator) void {
        allocator.free(self.decls);
        allocator.free(self.qualified_owners);
        self.* = undefined;
    }
};

/// ResolvedSourceDatabase is the per-file name-resolution boundary.
///
/// It keeps qualified-symbol rewriting attached to each FileId instead of
/// requiring a whole-program source buffer. The compilation session may collect
/// these declarations for whole-program analysis without rebasing their spans.
pub const ResolvedSourceDatabase = struct {
    files: []ResolvedSourceFile,

    pub fn declsForFile(self: ResolvedSourceDatabase, id: module_graph.FileId) ?[]const ast.Decl {
        for (self.files) |file| {
            if (file.id == id) return file.decls;
        }
        return null;
    }

    pub fn declCount(self: ResolvedSourceDatabase) usize {
        var count: usize = 0;
        for (self.files) |file| count += file.decls.len;
        return count;
    }

    pub fn collectDecls(self: ResolvedSourceDatabase, allocator: std.mem.Allocator) ![]ResolvedDecl {
        var decls: std.ArrayList(ResolvedDecl) = .empty;
        errdefer decls.deinit(allocator);
        try decls.ensureTotalCapacity(allocator, self.declCount());
        for (self.files) |file| {
            for (file.decls) |decl| {
                decls.appendAssumeCapacity(.{
                    .file_id = file.id,
                    .decl = decl,
                });
            }
        }
        return decls.toOwnedSlice(allocator);
    }

    pub fn collectQualifiedOwners(self: ResolvedSourceDatabase, allocator: std.mem.Allocator) ![][]const u8 {
        var owners: std.ArrayList([]const u8) = .empty;
        errdefer owners.deinit(allocator);
        for (self.files) |file| try owners.appendSlice(allocator, file.qualified_owners);
        return owners.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *ResolvedSourceDatabase, allocator: std.mem.Allocator) void {
        for (self.files) |file| {
            allocator.free(file.decls);
            allocator.free(file.qualified_owners);
        }
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
        for (files.items) |file| file.deinit(allocator);
        files.deinit(allocator);
    }

    for (graph.files) |file| {
        const parser_source = sources.parserSourceForFile(file.id) orelse return error.MissingModuleSource;
        const saved_path = reporter.path;
        const saved_source = reporter.source;
        reporter.path = file.display_path;
        reporter.source = parser_source;
        var parsed_ok = false;
        defer if (parsed_ok) {
            reporter.path = saved_path;
            reporter.source = saved_source;
        };
        var file_parser = parser.Parser.initWithFileId(parser_source, reporter, @intFromEnum(file.id));
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
    graph: module_graph.ModuleGraph,
) !ResolvedSourceDatabase {
    var files: std.ArrayList(ResolvedSourceFile) = .empty;
    errdefer {
        for (files.items) |file| {
            allocator.free(file.decls);
            allocator.free(file.qualified_owners);
        }
        files.deinit(allocator);
    }

    var qualified_symbols: std.ArrayList(ast.QualifiedSymbol) = .empty;
    defer qualified_symbols.deinit(allocator);
    for (parsed_sources.files) |file| try qualified_symbols.appendSlice(allocator, file.qualifiedSymbols());

    for (parsed_sources.files) |file| {
        const resolved_decls = try name_resolve.transformDeclsWithSymbols(allocator, file.decls(), qualified_symbols.items, &graph);
        var resolved_transferred = false;
        errdefer if (!resolved_transferred) allocator.free(resolved_decls);
        const qualified_owners = try allocator.dupe([]const u8, file.module.qualified_owners);
        errdefer allocator.free(qualified_owners);
        try files.append(allocator, .{
            .id = file.id,
            .decls = resolved_decls,
            .qualified_owners = qualified_owners,
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
    const root_decls = parsed.declsForFile(@enumFromInt(0)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), root_decls.len);
    try std.testing.expect(parsed.declsForFile(@enumFromInt(1)) == null);
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
    var resolved = try resolveParsedSourceDatabase(arena.allocator(), parsed, graph);
    defer resolved.deinit(arena.allocator());

    try std.testing.expect(!reporter.has_errors);
    const root_decls = resolved.declsForFile(@enumFromInt(0)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), root_decls.len);
    const answer = root_decls[1].kind.fn_decl;
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

test "ResolvedSourceDatabase resolves cross-file owners without flattening offsets" {
    const root_source = "fn answer() -> u32 { return Math.one(); }\n";
    const lib_source =
        \\module Math {
        \\    fn one() -> u32 { return 1; }
        \\}
        \\
    ;
    var graph = module_graph.ModuleGraph{
        .files = try std.testing.allocator.alloc(module_graph.ModuleFile, 2),
        .imports = try std.testing.allocator.alloc(module_graph.ImportEdge, 1),
    };
    defer graph.deinit(std.testing.allocator);
    graph.files[0] = .{
        .id = @enumFromInt(0),
        .canonical_path = try std.testing.allocator.dupe(u8, "/tmp/root.mc"),
        .display_path = try std.testing.allocator.dupe(u8, "root.mc"),
        .depth = 0,
    };
    graph.files[1] = .{
        .id = @enumFromInt(1),
        .canonical_path = try std.testing.allocator.dupe(u8, "/tmp/lib.mc"),
        .display_path = try std.testing.allocator.dupe(u8, "lib.mc"),
        .depth = 1,
    };
    graph.imports[0] = .{
        .importer = @enumFromInt(0),
        .imported = @enumFromInt(1),
        .span = .{ .offset = 0, .len = 0, .line = 1, .column = 1, .file_id = 0 },
    };

    var sources = module_graph.SourceDatabase{
        .files = try std.testing.allocator.alloc(module_graph.SourceFile, 2),
    };
    defer sources.deinit(std.testing.allocator);
    sources.files[0] = .{
        .id = @enumFromInt(0),
        .source = try std.testing.allocator.dupe(u8, root_source),
        .parser_source = try std.testing.allocator.dupe(u8, root_source),
    };
    sources.files[1] = .{
        .id = @enumFromInt(1),
        .source = try std.testing.allocator.dupe(u8, lib_source),
        .parser_source = try std.testing.allocator.dupe(u8, lib_source),
    };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "root.mc", root_source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parsed = try parseSourceDatabase(arena.allocator(), graph, sources, &reporter);
    defer parsed.deinit(arena.allocator());
    var resolved = try resolveParsedSourceDatabase(arena.allocator(), parsed, graph);
    defer resolved.deinit(arena.allocator());

    try std.testing.expect(!reporter.has_errors);
    const root_decls = resolved.declsForFile(@enumFromInt(0)).?;
    try std.testing.expectEqual(@as(usize, 1), root_decls.len);
    const answer = root_decls[0].kind.fn_decl;
    try std.testing.expectEqual(@as(u32, 0), answer.name.span.file_id);
    const callee = answer.body.?.items[0].kind.@"return".?.kind.call.callee.kind.ident;
    try std.testing.expectEqualStrings("Math__one", callee.text);
    try std.testing.expectEqual(@as(u32, 0), callee.span.file_id);

    const lib_decls = resolved.declsForFile(@enumFromInt(1)).?;
    try std.testing.expectEqual(@as(usize, 1), lib_decls.len);
    try std.testing.expectEqual(@as(u32, 1), lib_decls[0].span.file_id);
    const owners = try resolved.collectQualifiedOwners(std.testing.allocator);
    defer std.testing.allocator.free(owners);
    try std.testing.expectEqual(@as(usize, 1), owners.len);
    try std.testing.expectEqualStrings("Math", owners[0]);

    const decls = try resolved.collectDecls(std.testing.allocator);
    defer std.testing.allocator.free(decls);
    try std.testing.expectEqual(@as(module_graph.FileId, @enumFromInt(0)), decls[0].file_id);
    try std.testing.expectEqual(@as(module_graph.FileId, @enumFromInt(1)), decls[1].file_id);
}
