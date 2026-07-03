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
//   - If that rooted search misses, `--std-dir=<dir>` may supply the standard
//     library directory: `import "std/sync.mc"` maps to `<dir>/sync.mc`.
//   - Finally, `MC_PATH` entries are searched left-to-right as installed import
//     roots. For `import "std/sync.mc"`, an entry whose basename is `std` maps
//     to `<entry>/sync.mc`; otherwise the candidate is `<entry>/std/sync.mc`.
//     These installed roots never apply to explicit relative or absolute imports.
//
// `import` is recognized lexically (an `import` identifier followed by a string
// literal and `;` at brace-depth 0), so no parser/sema/backend changes are
// needed: the combined source the rest of the pipeline sees contains only
// ordinary declarations.

pub const LoadError = error{ImportNotFound} || std.mem.Allocator.Error;

pub const LoadOptions = struct {
    arch: ?[]const u8 = null,
    platform: ?[]const u8 = null,
    std_dir: ?[]const u8 = null,
    mc_path: []const []const u8 = &.{},
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

// One entry per file that contributes to the import-flattened source, in append order.
// `start` is the byte offset in the combined source where this file's text begins; `path`
// is its resolved (canonical) path. A span into the combined source is mapped back to its
// origin file by taking the last boundary whose `start <= span.offset`. The orphan rule in
// sema uses this to compare the defining file of an `opaque struct` against the file of a
// peer `impl` accessor, so a cross-file `impl` can no longer forge access to private fields.
pub const FileBoundary = diagnostics.FileBoundary;

// The virtual arch directory: an `import "kernel/arch/active/<x>"` is rewritten to
// `import "kernel/arch/<arch>/<x>"` where <arch> is the `--arch` selection (default
// "riscv64"). This is the arch-selection seam (plan R0b): ONE generic core module (e.g.
// kernel/core/uaccess.mc, elf_loader.mc) imports `active`, and the per-arch kernel binary
// is produced by picking the arch at compile time — no duplicated per-arch source copies.
pub const arch_active_prefix = "kernel/arch/active/";
pub const default_arch = "riscv64";

// The virtual platform directory: an `import "kernel/platform/active/<x>"` is rewritten to
// `import "kernel/platform/<platform>/<x>"` where <platform> is the `--platform` selection
// (default "qemu_virt"). This is the platform-selection seam (kernel-layering plan, Wave 0):
// a generic core module keeps its stable import path and pulls its board/device backend
// (the fixed MMIO addresses for the UART console, the RTC, the virtio-rng window) from
// `active`, so swapping boards is a compile-time selection — not a source edit of the 45
// modules that import the console interface.
pub const platform_active_prefix = "kernel/platform/active/";
pub const default_platform = "qemu_virt";

pub fn loadCombinedSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    root_source: []const u8,
) LoadError![]u8 {
    return loadCombinedSourceWithBoundaries(allocator, io, root_path, root_source, null, null, null);
}

// As `loadCombinedSource`, but if `boundaries` is non-null it is filled (appended) with one
// `FileBoundary` per contributing file. The boundary `path` strings are allocated with
// `allocator` and owned by the caller (free each `.path`, then the list). `arch` selects the
// `kernel/arch/active/` alias target (null => default_arch); `platform` selects the
// `kernel/platform/active/` alias target (null => default_platform).
pub fn loadCombinedSourceWithBoundaries(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    root_source: []const u8,
    boundaries: ?*std.ArrayList(FileBoundary),
    arch: ?[]const u8,
    platform: ?[]const u8,
) LoadError![]u8 {
    return loadCombinedSourceWithBoundariesOptionsReport(allocator, io, root_path, root_source, boundaries, .{
        .arch = arch,
        .platform = platform,
    }, null);
}

pub fn loadCombinedSourceWithBoundariesReport(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    root_source: []const u8,
    boundaries: ?*std.ArrayList(FileBoundary),
    arch: ?[]const u8,
    platform: ?[]const u8,
    reporter: ?*diagnostics.Reporter,
) LoadError![]u8 {
    return loadCombinedSourceWithBoundariesOptionsReport(allocator, io, root_path, root_source, boundaries, .{
        .arch = arch,
        .platform = platform,
    }, reporter);
}

pub fn loadCombinedSourceWithBoundariesOptionsReport(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    root_source: []const u8,
    boundaries: ?*std.ArrayList(FileBoundary),
    options: LoadOptions,
    reporter: ?*diagnostics.Reporter,
) LoadError![]u8 {
    var visited = std.StringHashMap(void).init(allocator);
    defer {
        var it = visited.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        visited.deinit();
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
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
            .path = try canonicalize(allocator, std_dir, cwd_root),
        });
    }
    for (options.mc_path) |entry| {
        const trimmed = std.mem.trim(u8, entry, " \t\r\n");
        if (trimmed.len == 0) continue;
        try installed_roots.append(allocator, .{
            .kind = .import_root,
            .path = try canonicalize(allocator, trimmed, cwd_root),
        });
    }
    try expand(
        allocator,
        io,
        canon_root,
        root_path,
        root_source,
        &visited,
        &out,
        boundaries,
        options.arch orelse default_arch,
        options.platform orelse default_platform,
        sandbox_root,
        installed_roots.items,
        reporter,
    );
    return out.toOwnedSlice(allocator);
}

fn expand(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    display_path: []const u8,
    source: []const u8,
    visited: *std.StringHashMap(void),
    out: *std.ArrayList(u8),
    boundaries: ?*std.ArrayList(FileBoundary),
    arch: []const u8,
    platform: []const u8,
    sandbox_root: []const u8,
    installed_roots: []const InstalledRoot,
    reporter: ?*diagnostics.Reporter,
) LoadError!void {
    if (visited.contains(path)) return;
    try visited.put(try allocator.dupe(u8, path), {});
    const file_source = stripUtf8Bom(source);

    // Record where this file's text starts in the combined source (before appending it).
    const file_start = out.items.len;
    if (boundaries) |b| try b.append(allocator, .{ .start = file_start, .path = try allocator.dupe(u8, display_path) });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const imports = try scanImports(a, io, path, file_source, arch, platform, sandbox_root, installed_roots);

    // Append this file's source with its import statements blanked out.
    const blanked = try allocator.dupe(u8, file_source);
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
        if (imp.outside_sandbox) {
            if (reporter) |r| {
                r.err(.{
                    .offset = file_start + imp.span.offset,
                    .len = imp.span.len,
                    .line = imp.span.line,
                    .column = imp.span.column,
                }, "E_IMPORT_OUTSIDE_SANDBOX: import \"{s}\" resolves to {s}, outside the import sandbox rooted at {s}", .{ imp.requested, imp.path, sandbox_root });
                continue;
            }
            return error.ImportNotFound;
        }
        if (visited.contains(imp.path)) continue;
        const imp_source = std.Io.Dir.cwd().readFileAlloc(io, imp.path, allocator, .limited(64 * 1024 * 1024)) catch {
            if (reporter) |r| {
                r.err(.{
                    .offset = file_start + imp.span.offset,
                    .len = imp.span.len,
                    .line = imp.span.line,
                    .column = imp.span.column,
                }, "E_IMPORT_NOT_FOUND: cannot find import \"{s}\" (resolved candidate: {s})", .{ imp.requested, imp.path });
                continue;
            }
            return error.ImportNotFound;
        };
        defer allocator.free(imp_source);
        try expand(allocator, io, imp.path, imp.display_path, imp_source, visited, out, boundaries, arch, platform, sandbox_root, installed_roots, reporter);
    }
}

// Find top-level `import "path";` statements by lexing. Returns the resolved
// path and the byte range (start of `import` .. end of `;`) for each.
fn scanImports(arena: std.mem.Allocator, io: std.Io, path: []const u8, source: []const u8, arch: []const u8, platform: []const u8, sandbox_root: []const u8, installed_roots: []const InstalledRoot) LoadError![]ImportRef {
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
                } else if (std.mem.startsWith(u8, rel, platform_active_prefix)) {
                    // Platform-selection seam: rewrite `kernel/platform/active/<x>` to the board.
                    rel = try std.fmt.allocPrint(arena, "kernel/platform/{s}/{s}", .{ platform, rel[platform_active_prefix.len..] });
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
    return refs.toOwnedSlice(arena);
}

fn stripUtf8Bom(source: []const u8) []const u8 {
    if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) return source[3..];
    return source;
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

fn resolveImportPath(arena: std.mem.Allocator, io: std.Io, importer: []const u8, rel: []const u8, sandbox_root: []const u8, installed_roots: []const InstalledRoot) LoadError!ResolvedImport {
    // Explicitly-relative or absolute: resolve against the importing file's
    // directory and canonicalize (so diamond imports dedup to one copy).
    if (std.fs.path.isAbsolute(rel) or isExplicitlyRelative(rel)) {
        const joined = if (std.fs.path.isAbsolute(rel))
            try arena.dupe(u8, rel)
        else
            try std.fs.path.join(arena, &.{ std.fs.path.dirname(importer) orelse ".", rel });
        const resolved = try canonicalize(arena, joined, sandbox_root);
        return .{ .path = resolved, .display_path = try displayPath(arena, sandbox_root, resolved), .outside_sandbox = !pathWithin(sandbox_root, resolved) };
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
        if (fileExists(io, cand)) return .{ .path = cand, .display_path = try displayPath(arena, sandbox_root, cand) };
        const parent = std.fs.path.dirname(d);
        dir = if (parent != null and !std.mem.eql(u8, parent.?, d)) parent else null;
    }
    // Cwd-relative (the project root when mcc is run from there).
    const bare = try canonicalize(arena, rel, sandbox_root);
    if (!pathWithin(sandbox_root, bare)) {
        if (first_outside == null) first_outside = bare;
    } else if (fileExists(io, bare)) {
        return .{ .path = bare, .display_path = try displayPath(arena, sandbox_root, bare) };
    }
    for (installed_roots) |root| {
        if (try installedCandidate(arena, root, rel)) |cand| {
            if (fileExists(io, cand)) return .{ .path = cand, .display_path = try displayPath(arena, sandbox_root, cand) };
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

fn realPathFileDupe(allocator: std.mem.Allocator, io: std.Io, path: []const u8) std.mem.Allocator.Error!?[]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.cwd().realPathFile(io, path, &buffer) catch return null;
    return try allocator.dupe(u8, buffer[0..len]);
}

fn displayPath(arena: std.mem.Allocator, sandbox_root: []const u8, path: []const u8) ![]const u8 {
    if (!pathWithin(sandbox_root, path)) return arena.dupe(u8, path);
    return std.fs.path.relative(arena, sandbox_root, null, sandbox_root, path) catch arena.dupe(u8, path);
}

fn defaultSandboxRoot(allocator: std.mem.Allocator, io: std.Io, canon_root: []const u8) std.mem.Allocator.Error![]const u8 {
    const cwd = (try realPathFileDupe(allocator, io, ".")) orelse try allocator.dupe(u8, ".");
    if (pathWithin(cwd, canon_root)) return cwd;
    allocator.free(cwd);
    const root_dir = std.fs.path.dirname(canon_root) orelse canon_root;
    return allocator.dupe(u8, root_dir);
}

fn pathWithin(root: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, root, path)) return true;
    if (root.len == 0) return false;
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (root[root.len - 1] == '/') return true;
    return path.len > root.len and path[root.len] == '/';
}
