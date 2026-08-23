const std = @import("std");

const diagnostics = @import("diagnostics.zig");
const lexer = @import("lexer.zig");
const module_graph = @import("module_graph.zig");
const path_policy = @import("path_policy.zig");
const string_literal = @import("string_literal.zig");
const token = @import("token.zig");

// Module loader for `import "path";` (section 22 / toolchain). Every file is
// retained independently in SourceDatabase and connected through ModuleGraph.
// Import statements are blanked only in that file's parser view, preserving
// its local offsets without creating a whole-program textual projection.
//
// Import path resolution:
//   - An *explicitly relative* path (`./foo.mc`, `../bar.mc`, or absolute) is
//     resolved against the importing file's directory.
//   - A *rooted* path (anything else, e.g. `std/sync.mc`) is resolved by walking
//     up the importing file's ancestor directories and taking the first existing
//     match. So `import "std/sync.mc"` works from any depth in a project (it
//     finds `<project-root>/std/sync.mc`) without `../../` prefixes.
//   - If that rooted search misses, `--std-dir=<dir>` may supply the standard
//     library directory: `import "std/sync.mc"` maps to `<dir>/sync.mc`.
//   - Finally, `MC_PATH` entries are searched left-to-right as installed import
//     roots. For `import "std/sync.mc"`, an entry whose basename is `std` maps
//     to `<entry>/sync.mc`; otherwise the candidate is `<entry>/std/sync.mc`.
//     These installed roots never apply to explicit relative or absolute imports.
//
// `import` is recognized lexically (an `import` identifier followed by a string
// literal and `;` at brace-depth 0); parser/sema consume the resulting per-file
// parser views.

pub const LoadError = error{ Reported, ImportNotFound, ImportBudgetExceeded, AccessDenied, InputOutput } || std.mem.Allocator.Error;

pub const LoadLimits = struct {
    max_files: usize = 10_000,
    max_total_input_bytes: usize = 512 * 1024 * 1024,
    max_import_depth: usize = 256,
};

pub const LoadOptions = struct {
    arch: ?[]const u8 = null,
    std_dir: ?[]const u8 = null,
    mc_path: []const []const u8 = &.{},
    limits: LoadLimits = .{},
};

const LoadBudget = struct {
    limits: LoadLimits,
    file_count: usize = 0,
    total_input_bytes: usize = 0,
    exhausted: bool = false,
};

const ImportOrigin = struct {
    span: diagnostics.Span,
    requested: []const u8,
    path: []const u8,
    source: []const u8,
};

pub const FileId = module_graph.FileId;
pub const ModuleFile = module_graph.ModuleFile;
pub const ImportEdge = module_graph.ImportEdge;
pub const ModuleGraph = module_graph.ModuleGraph;
pub const SourceFile = module_graph.SourceFile;
pub const SourceDatabase = module_graph.SourceDatabase;
pub const LoadedProject = module_graph.LoadedProject;

const GraphBuilder = struct {
    files: std.ArrayList(ModuleFile) = .empty,
    imports: std.ArrayList(ImportEdge) = .empty,
    sources: std.ArrayList(SourceFile) = .empty,
};

const PendingFile = struct {
    id: FileId,
    path: []const u8,
    display_path: []const u8,
    source: []const u8,
    source_owned: bool,
    depth: usize,
};

const InstalledRootKind = enum {
    std_dir,
    import_root,
};

const InstalledRoot = struct {
    kind: InstalledRootKind,
    path: []const u8,
};

const ImportRef = struct {
    path: []const u8, // resolved path, owned by the arena
    display_path: []const u8,
    requested: []const u8,
    span: diagnostics.Span,
    start: usize,
    end: usize,
    outside_sandbox: bool = false,
};

const ResolvedImport = struct {
    path: []const u8,
    display_path: []const u8,
    outside_sandbox: bool = false,
};

pub fn loadProjectOptionsReport(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    root_source: []const u8,
    options: LoadOptions,
    reporter: ?*diagnostics.Reporter,
) LoadError!LoadedProject {
    var graph_builder = GraphBuilder{};
    errdefer {
        for (graph_builder.files.items) |file| {
            allocator.free(file.canonical_path);
            allocator.free(file.display_path);
        }
        for (graph_builder.sources.items) |source_file| {
            allocator.free(source_file.source);
            allocator.free(source_file.parser_source);
        }
        graph_builder.files.deinit(allocator);
        graph_builder.imports.deinit(allocator);
        graph_builder.sources.deinit(allocator);
    }
    const initial_reported_diagnostics = if (reporter) |r| r.diagnostics.items.len else 0;
    const initial_diagnostic_oom = if (reporter) |r| r.diagnostic_oom else false;
    try loadModuleGraph(allocator, io, root_path, root_source, options, reporter, &graph_builder);
    if (reporter) |r| {
        if (reporterHasNewImportDiagnostic(r, initial_reported_diagnostics) or (!initial_diagnostic_oom and r.diagnostic_oom)) return error.Reported;
    }
    const files = try graph_builder.files.toOwnedSlice(allocator);
    errdefer {
        for (files) |file| {
            allocator.free(file.canonical_path);
            allocator.free(file.display_path);
        }
        allocator.free(files);
    }
    const source_files = try graph_builder.sources.toOwnedSlice(allocator);
    errdefer {
        for (source_files) |source_file| {
            allocator.free(source_file.source);
            allocator.free(source_file.parser_source);
        }
        allocator.free(source_files);
    }
    return .{
        .graph = .{
            .files = files,
            .imports = try graph_builder.imports.toOwnedSlice(allocator),
        },
        .source_db = .{ .files = source_files },
    };
}

fn loadModuleGraph(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    root_source: []const u8,
    options: LoadOptions,
    reporter: ?*diagnostics.Reporter,
    graph: *GraphBuilder,
) LoadError!void {
    const canon_root = (try realPathFileDupe(allocator, io, root_path)) orelse try canonicalize(allocator, root_path, ".");
    defer allocator.free(canon_root);
    const sandbox_root = try defaultSandboxRoot(allocator, io, canon_root);
    defer allocator.free(sandbox_root);
    const cwd_root = (try realPathFileDupe(allocator, io, ".")) orelse try allocator.dupe(u8, ".");
    defer allocator.free(cwd_root);
    var installed_roots: std.ArrayList(InstalledRoot) = .empty;
    defer {
        for (installed_roots.items) |root| allocator.free(root.path);
        installed_roots.deinit(allocator);
    }
    if (options.std_dir) |std_dir| {
        try installed_roots.append(allocator, .{
            .kind = .std_dir,
            .path = try canonicalizeConfiguredRoot(allocator, io, std_dir, cwd_root),
        });
    }
    for (options.mc_path) |entry| {
        const trimmed = std.mem.trim(u8, entry, " \t\r\n");
        if (trimmed.len == 0) continue;
        try installed_roots.append(allocator, .{
            .kind = .import_root,
            .path = try canonicalizeConfiguredRoot(allocator, io, trimmed, cwd_root),
        });
    }
    var budget = LoadBudget{ .limits = options.limits };
    try expandAll(
        allocator,
        io,
        canon_root,
        root_path,
        root_source,
        sandbox_root,
        installed_roots.items,
        reporter,
        &budget,
        graph,
    );
}

fn reporterHasNewImportDiagnostic(reporter: *const diagnostics.Reporter, start: usize) bool {
    for (reporter.diagnostics.items[start..]) |diag| {
        if (diag.severity == .error_ and isImportDiagnosticMessage(diag.message)) return true;
    }
    return false;
}

fn isImportDiagnosticMessage(message: []const u8) bool {
    return message.len > 9 and message[0] == 'E' and message[1] == '_' and std.mem.startsWith(u8, message[2..], "IMPORT_");
}

fn expandAll(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    display_path: []const u8,
    source: []const u8,
    sandbox_root: []const u8,
    installed_roots: []const InstalledRoot,
    reporter: ?*diagnostics.Reporter,
    budget: *LoadBudget,
    graph: *GraphBuilder,
) LoadError!void {
    var graph_arena = std.heap.ArenaAllocator.init(allocator);
    defer graph_arena.deinit();
    const graph_allocator = graph_arena.allocator();

    var discovered = std.StringHashMap(FileId).init(allocator);
    defer discovered.deinit();
    var pending: std.ArrayList(PendingFile) = .empty;
    defer {
        for (pending.items) |item| if (item.source_owned) allocator.free(item.source);
        pending.deinit(allocator);
    }

    try reserveFile(reporter, budget, null, 0, stripUtf8Bom(source).len);
    if (budget.exhausted) return;
    const root_id = try recordFile(allocator, graph, path, display_path, 0);
    try discovered.put(path, root_id);
    try pending.append(allocator, .{ .id = root_id, .path = path, .display_path = display_path, .source = source, .source_owned = false, .depth = 0 });

    while (pending.pop()) |item| {
        defer if (item.source_owned) allocator.free(item.source);
        if (budget.exhausted) break;

        const file_source = stripUtf8Bom(item.source);
        const imports = try scanImports(
            graph_allocator,
            io,
            item.path,
            item.display_path,
            file_source,
            sandbox_root,
            installed_roots,
            reporter,
            item.id,
        );

        const blanked = try allocator.dupe(u8, file_source);
        defer allocator.free(blanked);
        for (imports) |imp| {
            var i = imp.start;
            while (i < imp.end and i < blanked.len) : (i += 1) {
                if (blanked[i] != '\n' and blanked[i] != '\r') blanked[i] = ' ';
            }
        }
        try recordSourceFile(allocator, graph, item.id, file_source, blanked);

        var children: std.ArrayList(PendingFile) = .empty;
        defer {
            for (children.items) |child| if (child.source_owned) allocator.free(child.source);
            children.deinit(allocator);
        }
        for (imports) |imp| {
            const origin = ImportOrigin{ .span = imp.span, .requested = imp.requested, .path = item.display_path, .source = file_source };
            if (imp.outside_sandbox) {
                if (reporter) |r| {
                    r.captureSourceView(@intFromEnum(item.id), item.display_path, file_source);
                    r.err(.{
                        .offset = imp.span.offset,
                        .len = imp.span.len,
                        .line = imp.span.line,
                        .column = imp.span.column,
                        .file_id = @intFromEnum(item.id),
                    }, "E_IMPORT_OUTSIDE_SANDBOX: import \"{s}\" resolves to {s}, outside the import sandbox rooted at {s}", .{ imp.requested, imp.path, sandbox_root });
                    continue;
                }
                return error.ImportNotFound;
            }
            if (discovered.get(imp.path)) |imported_id| {
                try recordImport(allocator, graph, item.id, imported_id, imp.span);
                continue;
            }
            if (item.depth >= budget.limits.max_import_depth) {
                try rejectBudget(reporter, budget, origin, "E_IMPORT_DEPTH_LIMIT", "import depth exceeds configured limit {d}", .{budget.limits.max_import_depth});
                break;
            }
            if (budget.file_count >= budget.limits.max_files) {
                try rejectBudget(reporter, budget, origin, "E_IMPORT_FILE_LIMIT", "import graph exceeds configured file limit {d}", .{budget.limits.max_files});
                break;
            }
            const imp_source = readResolvedImportAlloc(
                allocator,
                io,
                imp.path,
                sandbox_root,
                installed_roots,
            ) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                if (reporter) |r| {
                    r.captureSourceView(@intFromEnum(item.id), item.display_path, file_source);
                    r.err(.{
                        .offset = imp.span.offset,
                        .len = imp.span.len,
                        .line = imp.span.line,
                        .column = imp.span.column,
                        .file_id = @intFromEnum(item.id),
                    }, "E_IMPORT_NOT_FOUND: cannot find import \"{s}\" (resolved candidate: {s})", .{ imp.requested, imp.path });
                    continue;
                }
                return error.ImportNotFound;
            };
            errdefer allocator.free(imp_source);
            try reserveFile(reporter, budget, origin, item.depth + 1, stripUtf8Bom(imp_source).len);
            if (budget.exhausted) {
                allocator.free(imp_source);
                break;
            }
            const imported_id = try recordFile(allocator, graph, imp.path, imp.display_path, item.depth + 1);
            try discovered.put(imp.path, imported_id);
            try recordImport(allocator, graph, item.id, imported_id, imp.span);
            try children.append(allocator, .{
                .id = imported_id,
                .path = imp.path,
                .display_path = imp.display_path,
                .source = imp_source,
                .source_owned = true,
                .depth = item.depth + 1,
            });
        }
        if (budget.exhausted) break;
        var child_index = children.items.len;
        while (child_index > 0) {
            child_index -= 1;
            try pending.append(allocator, children.items[child_index]);
            children.items[child_index].source_owned = false;
        }
    }
}

fn readResolvedImportAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    resolved_path: []const u8,
    sandbox_root: []const u8,
    installed_roots: []const InstalledRoot,
) ![]u8 {
    var authority_root: ?[]const u8 = null;
    if (pathWithin(sandbox_root, resolved_path)) {
        authority_root = sandbox_root;
    } else {
        for (installed_roots) |root| {
            if (pathWithin(root.path, resolved_path)) {
                authority_root = root.path;
                break;
            }
        }
    }
    const root = authority_root orelse return error.AccessDenied;
    const relative = try std.fs.path.relative(allocator, root, null, root, resolved_path);
    defer allocator.free(relative);

    // The opened root descriptor is the authority. resolve_beneath asks the OS
    // to keep component traversal below it, and follow_symlinks=false binds the
    // bytes read below to the same non-symlink final object that was opened.
    var root_dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .follow_symlinks = false });
    defer root_dir.close(io);
    const file = try root_dir.openFile(io, relative, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(64 * 1024 * 1024));
}

fn recordFile(
    allocator: std.mem.Allocator,
    graph: ?*GraphBuilder,
    canonical_path: []const u8,
    display_path: []const u8,
    depth: usize,
) std.mem.Allocator.Error!FileId {
    const id: FileId = @enumFromInt(if (graph) |builder| builder.files.items.len else 0);
    if (graph) |builder| {
        const canonical_copy = try allocator.dupe(u8, canonical_path);
        errdefer allocator.free(canonical_copy);
        const display_copy = try allocator.dupe(u8, display_path);
        errdefer allocator.free(display_copy);
        try builder.files.append(allocator, .{
            .id = id,
            .canonical_path = canonical_copy,
            .display_path = display_copy,
            .depth = depth,
        });
    }
    return id;
}

fn recordImport(
    allocator: std.mem.Allocator,
    graph: ?*GraphBuilder,
    importer: FileId,
    imported: FileId,
    span: diagnostics.Span,
) std.mem.Allocator.Error!void {
    if (graph) |builder| try builder.imports.append(allocator, .{ .importer = importer, .imported = imported, .span = span });
}

fn recordSourceFile(
    allocator: std.mem.Allocator,
    graph: ?*GraphBuilder,
    id: FileId,
    source: []const u8,
    parser_source: []const u8,
) std.mem.Allocator.Error!void {
    if (graph) |builder| {
        const source_copy = try allocator.dupe(u8, source);
        errdefer allocator.free(source_copy);
        const parser_source_copy = try allocator.dupe(u8, parser_source);
        errdefer allocator.free(parser_source_copy);
        try builder.sources.append(allocator, .{
            .id = id,
            .source = source_copy,
            .parser_source = parser_source_copy,
        });
    }
}

fn reserveFile(reporter: ?*diagnostics.Reporter, budget: *LoadBudget, origin: ?ImportOrigin, depth: usize, input_bytes: usize) LoadError!void {
    if (depth > budget.limits.max_import_depth) {
        return rejectBudget(reporter, budget, origin, "E_IMPORT_DEPTH_LIMIT", "import depth exceeds configured limit {d}", .{budget.limits.max_import_depth});
    }
    if (budget.file_count >= budget.limits.max_files) {
        return rejectBudget(reporter, budget, origin, "E_IMPORT_FILE_LIMIT", "import graph exceeds configured file limit {d}", .{budget.limits.max_files});
    }
    const next_total = std.math.add(usize, budget.total_input_bytes, input_bytes) catch {
        return rejectBudget(reporter, budget, origin, "E_IMPORT_TOTAL_BYTES_LIMIT", "import graph exceeds configured cumulative input limit {d} bytes", .{budget.limits.max_total_input_bytes});
    };
    if (next_total > budget.limits.max_total_input_bytes) {
        return rejectBudget(reporter, budget, origin, "E_IMPORT_TOTAL_BYTES_LIMIT", "import graph exceeds configured cumulative input limit {d} bytes", .{budget.limits.max_total_input_bytes});
    }
    budget.file_count += 1;
    budget.total_input_bytes = next_total;
}

fn rejectBudget(
    reporter: ?*diagnostics.Reporter,
    budget: *LoadBudget,
    origin: ?ImportOrigin,
    code: []const u8,
    comptime message: []const u8,
    args: anytype,
) LoadError!void {
    if (reporter) |r| {
        const where = if (origin) |value| diagnostics.Span{
            .offset = value.span.offset,
            .len = value.span.len,
            .line = value.span.line,
            .column = value.span.column,
            .file_id = value.span.file_id,
        } else diagnostics.Span{ .offset = 0, .len = 0, .line = 1, .column = 1 };
        const requested = if (origin) |value| value.requested else "<root>";
        if (origin) |value| r.captureSourceView(value.span.file_id, value.path, value.source);
        r.err(where, "{s}: import \"{s}\": " ++ message, .{ code, requested } ++ args);
        budget.exhausted = true;
        return;
    }
    return error.ImportBudgetExceeded;
}

// Find top-level `import "path";` statements by lexing. Returns the resolved
// path and the byte range (start of `import` .. end of `;`) for each.
fn scanImports(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    display_path: []const u8,
    source: []const u8,
    sandbox_root: []const u8,
    installed_roots: []const InstalledRoot,
    outer_reporter: ?*diagnostics.Reporter,
    file_id: FileId,
) LoadError![]ImportRef {
    var refs: std.ArrayList(ImportRef) = .empty;
    var lex_reporter = diagnostics.Reporter.init(arena, path, source);
    defer lex_reporter.deinit();
    var lx = lexer.Lexer.initWithFileId(source, &lex_reporter, @intFromEnum(file_id));
    var depth: i32 = 0;
    while (true) {
        const t = lx.next();
        if (t.kind == .eof) break;
        if (t.kind == .l_brace) {
            depth += 1;
            continue;
        }
        if (t.kind == .r_brace) {
            depth -= 1;
            continue;
        }
        if (depth == 0 and t.kind == .identifier and std.mem.eql(u8, t.lexeme, "import")) {
            const str = lx.next();
            const semi = lx.next();
            if (str.kind == .string_literal and semi.kind == .semicolon) {
                const storage = try arena.alloc(u8, str.lexeme.len - 2);
                const rel = string_literal.decodeInto(storage, str.lexeme) catch {
                    if (outer_reporter) |r| {
                        r.captureSourceView(@intFromEnum(file_id), display_path, source);
                        r.err(.{
                            .offset = str.span.offset,
                            .len = str.span.len,
                            .line = str.span.line,
                            .column = str.span.column,
                            .file_id = @intFromEnum(file_id),
                        }, "E_IMPORT_INVALID_STRING: import path must be a valid string literal", .{});
                    } else {
                        return error.ImportNotFound;
                    }
                    continue;
                };
                if (std.mem.indexOfScalar(u8, rel, 0) != null) {
                    if (outer_reporter) |r| {
                        r.captureSourceView(@intFromEnum(file_id), display_path, source);
                        r.err(.{
                            .offset = str.span.offset,
                            .len = str.span.len,
                            .line = str.span.line,
                            .column = str.span.column,
                            .file_id = @intFromEnum(file_id),
                        }, "E_IMPORT_INVALID_STRING: import path cannot contain NUL", .{});
                    } else {
                        return error.ImportNotFound;
                    }
                    continue;
                }
                const resolved = try resolveImportPath(arena, io, path, rel, sandbox_root, installed_roots);
                try refs.append(arena, .{
                    .path = resolved.path,
                    .display_path = resolved.display_path,
                    .requested = rel,
                    .span = t.span,
                    .start = t.span.offset,
                    .end = semi.span.offset + semi.span.len,
                    .outside_sandbox = resolved.outside_sandbox,
                });
            }
        }
    }
    if (outer_reporter) |r| {
        if (lex_reporter.has_errors) r.captureSourceView(@intFromEnum(file_id), display_path, source);
        for (lex_reporter.diagnostics.items) |diag| {
            r.err(.{
                .offset = diag.span.offset,
                .len = diag.span.len,
                .line = diag.span.line,
                .column = diag.span.column,
                .file_id = @intFromEnum(file_id),
            }, "{s}", .{diag.message});
        }
    } else if (lex_reporter.has_errors) {
        return error.ImportNotFound;
    }
    return refs.toOwnedSlice(arena);
}

fn stripUtf8Bom(source: []const u8) []const u8 {
    if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) return source[3..];
    return source;
}

fn isExplicitlyRelative(rel: []const u8) bool {
    return path_policy.isExplicitlyRelative(rel);
}

fn fileExists(io: std.Io, path: []const u8) bool {
    // `access` against cwd works for both cwd-relative and absolute paths.
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn resolveImportPath(arena: std.mem.Allocator, io: std.Io, importer: []const u8, rel: []const u8, sandbox_root: []const u8, installed_roots: []const InstalledRoot) LoadError!ResolvedImport {
    // Explicitly-relative or absolute: resolve against the importing file's
    // directory and canonicalize (so diamond imports dedup to one copy).
    if (std.fs.path.isAbsolute(rel) or isExplicitlyRelative(rel)) {
        const joined = if (std.fs.path.isAbsolute(rel))
            try arena.dupe(u8, rel)
        else
            try std.fs.path.join(arena, &.{ std.fs.path.dirname(importer) orelse ".", rel });
        const resolved = try canonicalize(arena, joined, sandbox_root);
        const actual = (try realPathFileDupe(arena, io, resolved)) orelse resolved;
        return .{ .path = actual, .display_path = try displayPath(arena, sandbox_root, actual), .outside_sandbox = !pathWithin(sandbox_root, actual) };
    }

    // Rooted (e.g. `std/sync.mc`): walk up the importer's ancestor directories,
    // then the current working directory, taking the first existing match.
    var first: ?[]const u8 = null;
    var first_outside: ?[]const u8 = null;
    var dir: ?[]const u8 = std.fs.path.dirname(importer);
    while (dir) |d| {
        const cand = try canonicalize(arena, try std.fs.path.join(arena, &.{ d, rel }), sandbox_root);
        if (!pathWithin(sandbox_root, cand)) {
            if (first_outside == null) first_outside = cand;
            const parent_outside = std.fs.path.dirname(d);
            dir = if (parent_outside != null and !std.mem.eql(u8, parent_outside.?, d)) parent_outside else null;
            continue;
        }
        if (first == null) first = cand;
        if (fileExists(io, cand)) {
            const actual = (try realPathFileDupe(arena, io, cand)) orelse cand;
            return .{ .path = actual, .display_path = try displayPath(arena, sandbox_root, actual), .outside_sandbox = !pathWithin(sandbox_root, actual) };
        }
        const parent = std.fs.path.dirname(d);
        dir = if (parent != null and !std.mem.eql(u8, parent.?, d)) parent else null;
    }
    // Cwd-relative (the project root when mcc is run from there).
    const bare = try canonicalize(arena, rel, sandbox_root);
    if (!pathWithin(sandbox_root, bare)) {
        if (first_outside == null) first_outside = bare;
    } else if (fileExists(io, bare)) {
        const actual = (try realPathFileDupe(arena, io, bare)) orelse bare;
        return .{ .path = actual, .display_path = try displayPath(arena, sandbox_root, actual), .outside_sandbox = !pathWithin(sandbox_root, actual) };
    }
    for (installed_roots) |root| {
        if (try installedCandidate(arena, root, rel)) |cand| {
            if (fileExists(io, cand)) {
                const actual = (try realPathFileDupe(arena, io, cand)) orelse cand;
                if (!pathWithin(root.path, actual)) {
                    return .{ .path = actual, .display_path = actual, .outside_sandbox = true };
                }
                return .{ .path = actual, .display_path = try displayPath(arena, sandbox_root, actual) };
            }
        }
    }
    // None found: return a sensible candidate for the error message.
    if (first) |candidate| return .{ .path = candidate, .display_path = try displayPath(arena, sandbox_root, candidate) };
    if (first_outside) |candidate| return .{ .path = candidate, .display_path = candidate, .outside_sandbox = true };
    return .{ .path = bare, .display_path = try displayPath(arena, sandbox_root, bare) };
}

fn installedCandidate(arena: std.mem.Allocator, root: InstalledRoot, rel: []const u8) LoadError!?[]const u8 {
    const std_prefix = "std/";
    var joined: []const u8 = undefined;
    switch (root.kind) {
        .std_dir => {
            if (!std.mem.startsWith(u8, rel, std_prefix)) return null;
            joined = try std.fs.path.join(arena, &.{ root.path, rel[std_prefix.len..] });
        },
        .import_root => {
            if (std.mem.startsWith(u8, rel, std_prefix) and std.mem.eql(u8, std.fs.path.basename(root.path), "std")) {
                joined = try std.fs.path.join(arena, &.{ root.path, rel[std_prefix.len..] });
            } else {
                joined = try std.fs.path.join(arena, &.{ root.path, rel });
            }
        },
    }
    const resolved = try canonicalize(arena, joined, root.path);
    if (!pathWithin(root.path, resolved)) return null;
    return resolved;
}

fn canonicalize(arena: std.mem.Allocator, path: []const u8, relative_root: []const u8) LoadError![]const u8 {
    // Normalize lexically (no filesystem access needed; works for not-yet-read
    // paths) into an absolute, `..`-collapsed form.
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(arena, &.{path});
    return std.fs.path.resolve(arena, &.{ relative_root, path });
}

fn canonicalizeConfiguredRoot(allocator: std.mem.Allocator, io: std.Io, path: []const u8, relative_root: []const u8) LoadError![]const u8 {
    const lexical = try canonicalize(allocator, path, relative_root);
    if (try realPathFileDupe(allocator, io, lexical)) |actual| {
        allocator.free(lexical);
        return actual;
    }
    return lexical;
}

fn realPathFileDupe(allocator: std.mem.Allocator, io: std.Io, path: []const u8) LoadError!?[]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.cwd().realPathFile(io, path, &buffer) catch |err| {
        if (realPathMissingResult(err)) return null;
        return realPathLoadError(err);
    };
    return try allocator.dupe(u8, buffer[0..len]);
}

fn realPathMissingResult(err: anyerror) bool {
    return err == error.FileNotFound or err == error.NotDir;
}

fn realPathLoadError(err: anyerror) LoadError {
    if (err == error.AccessDenied) return error.AccessDenied;
    return error.InputOutput;
}

fn displayPath(arena: std.mem.Allocator, sandbox_root: []const u8, path: []const u8) ![]const u8 {
    if (!pathWithin(sandbox_root, path)) return arena.dupe(u8, path);
    return std.fs.path.relative(arena, sandbox_root, null, sandbox_root, path) catch arena.dupe(u8, path);
}

fn defaultSandboxRoot(allocator: std.mem.Allocator, io: std.Io, canon_root: []const u8) LoadError![]const u8 {
    const cwd = (try realPathFileDupe(allocator, io, ".")) orelse try allocator.dupe(u8, ".");
    if (pathWithin(cwd, canon_root)) return cwd;
    allocator.free(cwd);
    const root_dir = std.fs.path.dirname(canon_root) orelse canon_root;
    return allocator.dupe(u8, root_dir);
}

fn pathWithin(root: []const u8, path: []const u8) bool {
    return path_policy.pathWithin(root, path);
}

test "import path predicates accept native and Windows separators without sibling escape" {
    try std.testing.expect(isExplicitlyRelative("./child.mc"));
    try std.testing.expect(pathWithin("/project", "/project/child.mc"));
    try std.testing.expect(!pathWithin("/project", "/project2/child.mc"));
    try std.testing.expect(!pathWithin("/project", "/project\\escape/child.mc"));
}

test "realPathFileDupe only treats missing paths as absent" {
    try std.testing.expect(realPathMissingResult(error.FileNotFound));
    try std.testing.expect(realPathMissingResult(error.NotDir));
    try std.testing.expect(!realPathMissingResult(error.AccessDenied));
    try std.testing.expectEqual(error.AccessDenied, realPathLoadError(error.AccessDenied));
    try std.testing.expectEqual(error.InputOutput, realPathLoadError(error.Unexpected));
}
