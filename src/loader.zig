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
// Import path resolution:
//   - An *explicitly relative* path (`./foo.mc`, `../bar.mc`, or absolute) is
//     resolved against the importing file's directory.
//   - A *rooted* path (anything else, e.g. `std/sync.mc`) is resolved by walking
//     up the importing file's ancestor directories and taking the first existing
//     match. So `import "std/sync.mc"` works from any depth in a project (it
//     finds `<project-root>/std/sync.mc`) without `../../` prefixes.
//
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

// One entry per file that contributes to the import-flattened source, in append order.
// `start` is the byte offset in the combined source where this file's text begins; `path`
// is its resolved (canonical) path. A span into the combined source is mapped back to its
// origin file by taking the last boundary whose `start <= span.offset`. The orphan rule in
// sema uses this to compare the defining file of an `opaque struct` against the file of a
// peer `impl` accessor, so a cross-file `impl` can no longer forge access to private fields.
pub const FileBoundary = struct {
    start: usize,
    path: []const u8, // owned by the caller's allocator
};

// The virtual arch directory: an `import "kernel/arch/active/<x>"` is rewritten to
// `import "kernel/arch/<arch>/<x>"` where <arch> is the `--arch` selection (default
// "riscv64"). This is the arch-selection seam (plan R0b): ONE generic core module (e.g.
// kernel/core/uaccess.mc, elf_loader.mc) imports `active`, and the per-arch kernel binary
// is produced by picking the arch at compile time — no duplicated per-arch source copies.
pub const arch_active_prefix = "kernel/arch/active/";
pub const default_arch = "riscv64";

pub fn loadCombinedSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    root_source: []const u8,
) LoadError![]u8 {
    return loadCombinedSourceWithBoundaries(allocator, io, root_path, root_source, null, null);
}

// As `loadCombinedSource`, but if `boundaries` is non-null it is filled (appended) with one
// `FileBoundary` per contributing file. The boundary `path` strings are allocated with
// `allocator` and owned by the caller (free each `.path`, then the list). `arch` selects the
// `kernel/arch/active/` alias target (null => default_arch).
pub fn loadCombinedSourceWithBoundaries(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    root_source: []const u8,
    boundaries: ?*std.ArrayList(FileBoundary),
    arch: ?[]const u8,
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
    try expand(allocator, io, canon_root, root_source, &visited, &out, boundaries, arch orelse default_arch);
    return out.toOwnedSlice(allocator);
}

fn expand(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    source: []const u8,
    visited: *std.StringHashMap(void),
    out: *std.ArrayList(u8),
    boundaries: ?*std.ArrayList(FileBoundary),
    arch: []const u8,
) LoadError!void {
    if (visited.contains(path)) return;
    try visited.put(try allocator.dupe(u8, path), {});

    // Record where this file's text starts in the combined source (before appending it).
    if (boundaries) |b| try b.append(allocator, .{ .start = out.items.len, .path = try allocator.dupe(u8, path) });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const imports = try scanImports(a, io, path, source, arch);

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
        try expand(allocator, io, imp.path, imp_source, visited, out, boundaries, arch);
    }
}

// Find top-level `import "path";` statements by lexing. Returns the resolved
// path and the byte range (start of `import` .. end of `;`) for each.
fn scanImports(arena: std.mem.Allocator, io: std.Io, path: []const u8, source: []const u8, arch: []const u8) LoadError![]ImportRef {
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
                var rel = std.mem.trim(u8, str.lexeme, "\"");
                // Arch-selection seam: rewrite `kernel/arch/active/<x>` to the chosen arch.
                if (std.mem.startsWith(u8, rel, arch_active_prefix)) {
                    rel = try std.fmt.allocPrint(arena, "kernel/arch/{s}/{s}", .{ arch, rel[arch_active_prefix.len..] });
                }
                const resolved = try resolveImportPath(arena, io, path, rel);
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

fn isExplicitlyRelative(rel: []const u8) bool {
    return std.mem.startsWith(u8, rel, "./") or std.mem.startsWith(u8, rel, "../") or
        std.mem.eql(u8, rel, ".") or std.mem.eql(u8, rel, "..");
}

fn fileExists(io: std.Io, path: []const u8) bool {
    // `access` against cwd works for both cwd-relative and absolute paths.
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn resolveImportPath(arena: std.mem.Allocator, io: std.Io, importer: []const u8, rel: []const u8) LoadError![]const u8 {
    // Explicitly-relative or absolute: resolve against the importing file's
    // directory and canonicalize (so diamond imports dedup to one copy).
    if (std.fs.path.isAbsolute(rel) or isExplicitlyRelative(rel)) {
        const joined = if (std.fs.path.isAbsolute(rel))
            try arena.dupe(u8, rel)
        else
            try std.fs.path.join(arena, &.{ std.fs.path.dirname(importer) orelse ".", rel });
        return canonicalize(arena, joined);
    }

    // Rooted (e.g. `std/sync.mc`): walk up the importer's ancestor directories,
    // then the current working directory, taking the first existing match.
    var first: ?[]const u8 = null;
    var dir: ?[]const u8 = std.fs.path.dirname(importer);
    while (dir) |d| {
        const cand = try canonicalize(arena, try std.fs.path.join(arena, &.{ d, rel }));
        if (first == null) first = cand;
        if (fileExists(io, cand)) return cand;
        const parent = std.fs.path.dirname(d);
        dir = if (parent != null and !std.mem.eql(u8, parent.?, d)) parent else null;
    }
    // Cwd-relative (the project root when mcc is run from there).
    const bare = try canonicalize(arena, rel);
    if (fileExists(io, bare)) return bare;
    // None found: return a sensible candidate for the error message.
    return first orelse bare;
}

fn canonicalize(arena: std.mem.Allocator, path: []const u8) LoadError![]const u8 {
    // Normalize lexically (no filesystem access needed; works for not-yet-read
    // paths) into an absolute, `..`-collapsed form.
    return std.fs.path.resolve(arena, &.{path});
}
