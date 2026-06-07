const std = @import("std");

const diagnostics = @import("diagnostics.zig");
const lexer = @import("lexer.zig");
const token = @import("token.zig");

// Module loader for `import "path";` (section 22 / toolchain). MC has no
// separate module/object model in the front end, so an import is resolved by
// *textual inclusion*: the loader produces a single combined source containing
// the root file followed by each transitively-imported file (deduped by
// resolved path). Each `import` statement is blanked in place — replaced by
// spaces, preserving newlines — so the root file's byte offsets and line
// numbers are unchanged and diagnostics in user code stay accurate.
//
// Import paths are resolved relative to the directory of the importing file.
// `import` is recognized lexically (an `import` identifier followed by a string
// literal and `;` at brace-depth 0), so no parser/sema/backend changes are
// needed: the combined source the rest of the pipeline sees contains only
// ordinary declarations.

pub const LoadError = error{ImportNotFound} || std.mem.Allocator.Error;

const ImportRef = struct {
    path: []const u8, // resolved path, owned by the arena
    start: usize,
    end: usize,
};

pub fn loadCombinedSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    root_source: []const u8,
) LoadError![]u8 {
    var visited = std.StringHashMap(void).init(allocator);
    defer {
        var it = visited.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        visited.deinit();
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const canon_root = std.fs.path.resolve(allocator, &.{root_path}) catch try allocator.dupe(u8, root_path);
    defer allocator.free(canon_root);
    try expand(allocator, io, canon_root, root_source, &visited, &out);
    return out.toOwnedSlice(allocator);
}

fn expand(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    source: []const u8,
    visited: *std.StringHashMap(void),
    out: *std.ArrayList(u8),
) LoadError!void {
    if (visited.contains(path)) return;
    try visited.put(try allocator.dupe(u8, path), {});

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const imports = try scanImports(a, path, source);

    // Append this file's source with its import statements blanked out.
    const blanked = try allocator.dupe(u8, source);
    defer allocator.free(blanked);
    for (imports) |imp| {
        var i = imp.start;
        while (i < imp.end and i < blanked.len) : (i += 1) {
            if (blanked[i] != '\n' and blanked[i] != '\r') blanked[i] = ' ';
        }
    }
    try out.appendSlice(allocator, blanked);
    try out.append(allocator, '\n');

    // Then expand each imported file once.
    for (imports) |imp| {
        if (visited.contains(imp.path)) continue;
        const imp_source = std.Io.Dir.cwd().readFileAlloc(io, imp.path, allocator, .limited(64 * 1024 * 1024)) catch {
            return error.ImportNotFound;
        };
        defer allocator.free(imp_source);
        try expand(allocator, io, imp.path, imp_source, visited, out);
    }
}

// Find top-level `import "path";` statements by lexing. Returns the resolved
// path and the byte range (start of `import` .. end of `;`) for each.
fn scanImports(arena: std.mem.Allocator, path: []const u8, source: []const u8) LoadError![]ImportRef {
    var refs: std.ArrayList(ImportRef) = .empty;
    var reporter = diagnostics.Reporter.init(arena, path, source);
    var lx = lexer.Lexer.init(source, &reporter);
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
                const rel = std.mem.trim(u8, str.lexeme, "\"");
                const resolved = try resolveImportPath(arena, path, rel);
                try refs.append(arena, .{
                    .path = resolved,
                    .start = t.span.offset,
                    .end = semi.span.offset + semi.span.len,
                });
            }
        }
    }
    return refs.toOwnedSlice(arena);
}

fn resolveImportPath(arena: std.mem.Allocator, importer: []const u8, rel: []const u8) LoadError![]const u8 {
    // Resolve relative imports against the importing file's directory, then
    // canonicalize (collapsing `.`/`..`, making absolute) so the same file
    // imported via different paths dedups to one copy.
    const joined = if (std.fs.path.isAbsolute(rel))
        try arena.dupe(u8, rel)
    else
        try std.fs.path.join(arena, &.{ std.fs.path.dirname(importer) orelse ".", rel });
    return canonicalize(arena, joined);
}

fn canonicalize(arena: std.mem.Allocator, path: []const u8) LoadError![]const u8 {
    // Normalize lexically (no filesystem access needed; works for not-yet-read
    // paths) into an absolute, `..`-collapsed form.
    return std.fs.path.resolve(arena, &.{path});
}
