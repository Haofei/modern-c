//! Structural architecture-boundary check: backends and MIR body/plan modules
//! must not import the syntax/checker front end.
//!
//! This replaces the former family of needle-count "inventory" ratchets
//! (`semantic-facts-inventory.py`, `architecture-boundary-inventory.py`,
//! `codegen-ingress-migration-test.py`, `mir-identity-inventory.py`, the
//! `move-*-inventory.py` family, and friends). Those gates pinned exact
//! occurrence counts of source strings, so they broke on unrelated edits and
//! proved nothing about the module graph. What the review actually wants is
//! one invariant:
//!
//!   A backend (or MIR body/plan) module reads MIR, not syntax.
//!
//! So this test parses `@import("...")` edges out of the real source files and
//! enforces that invariant directly. Everything still violating it is listed
//! once, by name, in `exceptions` below, with the reason it is still there.
//! The list must stay exact: a stale entry fails too, so the remaining debt
//! can only shrink and is always readable in one place.

const std = @import("std");

/// Modules the rule applies to: anything that emits code, or that models an
/// executable MIR body/plan consumed by an emitter.
const backend_prefixes = [_][]const u8{
    "lower_c",
    "lower_llvm",
    "backend",
    "mir_body_plan",
};

const backend_exact_files = [_][]const u8{
    "lower_cov.zig",
    "mir_executable_body.zig",
    "mir_executable_c.zig",
    "mir_executable_llvm.zig",
};

/// Front-end syntax/checker modules a backend may not depend on. `ast_bridge`
/// and `type_bridge` are included because they are transparent re-exports of
/// `ast.zig` / `type_syntax.zig`; leaving them out would make the rule
/// trivially bypassable by adding another bridge.
const forbidden_exact = [_][]const u8{
    "ast.zig",
    "ast_bridge.zig",
    "ast_query.zig",
    "attr_syntax.zig",
    "expr_syntax.zig",
    "parser.zig",
    "sema.zig",
    "type_bridge.zig",
    "type_syntax.zig",
};

/// `sema_*.zig` is forbidden as a family. `semantic_ids.zig` is deliberately
/// not matched: it is the typed-id vocabulary, not checker logic.
const forbidden_prefix = "sema_";

const Exception = struct {
    file: []const u8,
    import: []const u8,
    why: []const u8,
};

/// The complete, current set of boundary violations. Shrink it; do not grow
/// it. A new edge that is not listed here fails this test, and an entry that
/// no longer corresponds to a real import fails it too.
const exceptions = [_]Exception{
    // Unit-test roots build their fixtures by parsing MC source in-process.
    // They are test drivers, not lowering paths, so the front-end dependency
    // is inherent rather than a leak of syntax authority into codegen.
    .{ .file = "lower_c_tests.zig", .import = "ast.zig", .why = "test driver parses fixture source" },
    .{ .file = "lower_c_tests.zig", .import = "parser.zig", .why = "test driver parses fixture source" },
    .{ .file = "lower_llvm_tests.zig", .import = "ast.zig", .why = "test driver parses fixture source" },
    .{ .file = "mir_body_plan_tests.zig", .import = "parser.zig", .why = "test driver parses fixture source" },

    // Remaining transitional C-backend syntax surface. The C emitter still
    // receives AST-shaped declarations (globals, aggregates, asm, mmio) and
    // AST-shaped type expressions for naming/shape decisions. Closing these
    // is the sema-to-MIR typed-handoff work; until then each edge is named.
    .{ .file = "lower_c_aggregate_deps.zig", .import = "ast_bridge.zig", .why = "aggregate emission order still walks declaration syntax" },
    .{ .file = "lower_c_aggregate_deps.zig", .import = "type_bridge.zig", .why = "aggregate closure still inspects type syntax" },
    .{ .file = "lower_c_collect.zig", .import = "ast_bridge.zig", .why = "declaration collection walks AST decls" },
    .{ .file = "lower_c_const.zig", .import = "ast_bridge.zig", .why = "constant emission still reads literal syntax" },
    .{ .file = "lower_c_defs.zig", .import = "ast_bridge.zig", .why = "type/global definition emission walks AST decls" },
    .{ .file = "lower_c_emitter.zig", .import = "ast_bridge.zig", .why = "emitter state still carries AST declaration payloads" },
    .{ .file = "lower_c_emitter.zig", .import = "type_bridge.zig", .why = "emitter still classifies type syntax" },
    .{ .file = "lower_c_mmio_defs.zig", .import = "ast_bridge.zig", .why = "MMIO definition emission walks AST decls" },
    .{ .file = "lower_c_model.zig", .import = "ast_bridge.zig", .why = "C lowering model stores AST declaration payloads" },
    .{ .file = "lower_c_names.zig", .import = "ast_bridge.zig", .why = "C name mangling reads declaration syntax" },
    .{ .file = "lower_c_names.zig", .import = "type_bridge.zig", .why = "C name mangling reads type syntax" },
    .{ .file = "lower_c_shape.zig", .import = "ast_bridge.zig", .why = "shape classification reads declaration syntax" },
    .{ .file = "lower_c_shape.zig", .import = "type_bridge.zig", .why = "shape classification reads type syntax" },
    .{ .file = "lower_c_type.zig", .import = "ast_bridge.zig", .why = "C type emission reads declaration syntax" },
    .{ .file = "lower_c_type.zig", .import = "type_bridge.zig", .why = "C type emission reads type syntax" },
};

fn isBackendFile(name: []const u8) bool {
    if (!std.mem.endsWith(u8, name, ".zig")) return false;
    for (backend_exact_files) |exact| {
        if (std.mem.eql(u8, name, exact)) return true;
    }
    for (backend_prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return true;
    }
    return false;
}

fn isForbiddenImport(name: []const u8) bool {
    for (forbidden_exact) |exact| {
        if (std.mem.eql(u8, name, exact)) return true;
    }
    return std.mem.startsWith(u8, name, forbidden_prefix) and std.mem.endsWith(u8, name, ".zig");
}

fn exceptionIndex(file: []const u8, import_name: []const u8) ?usize {
    for (exceptions, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.file, file) and std.mem.eql(u8, entry.import, import_name)) return index;
    }
    return null;
}

/// Collect the `@import("...")` targets of one Zig source file.
fn collectImports(allocator: std.mem.Allocator, source: []const u8) !std.ArrayList([]const u8) {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(allocator);

    const open = "@import(\"";
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, open)) |hit| {
        const start = hit + open.len;
        const end = std.mem.indexOfScalarPos(u8, source, start, '"') orelse break;
        try names.append(allocator, source[start..end]);
        cursor = end + 1;
    }
    return names;
}

test "backend and MIR body modules do not import the syntax front end" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var dir = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer dir.close(io);

    var used = [_]bool{false} ** exceptions.len;
    var scanned: usize = 0;
    var matched_prefix = [_]bool{false} ** backend_prefixes.len;
    var matched_exact = [_]bool{false} ** backend_exact_files.len;
    var ok = true;

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!isBackendFile(entry.basename)) continue;

        scanned += 1;
        for (backend_prefixes, 0..) |prefix, index| {
            if (std.mem.startsWith(u8, entry.basename, prefix)) matched_prefix[index] = true;
        }
        for (backend_exact_files, 0..) |exact, index| {
            if (std.mem.eql(u8, entry.basename, exact)) matched_exact[index] = true;
        }

        const source = try dir.readFileAlloc(io, entry.path, allocator, .limited(8 * 1024 * 1024));
        defer allocator.free(source);

        var imports = try collectImports(allocator, source);
        defer imports.deinit(allocator);

        for (imports.items) |import_name| {
            if (!isForbiddenImport(import_name)) continue;
            if (exceptionIndex(entry.basename, import_name)) |index| {
                used[index] = true;
                continue;
            }
            std.debug.print(
                "architecture boundary: src/{s} must not @import(\"{s}\")\n",
                .{ entry.basename, import_name },
            );
            ok = false;
        }
    }

    for (exceptions, used) |entry, was_used| {
        if (was_used) continue;
        std.debug.print(
            "architecture boundary: stale exception src/{s} -> {s} ({s}); delete it from src/architecture_boundary_tests.zig\n",
            .{ entry.file, entry.import, entry.why },
        );
        ok = false;
    }

    // Anti-vacuity: the scan must actually have seen every configured module
    // family, so a rename cannot silently turn this gate into a no-op.
    for (backend_prefixes, matched_prefix) |prefix, seen| {
        if (seen) continue;
        std.debug.print("architecture boundary: no src file matches prefix {s}\n", .{prefix});
        ok = false;
    }
    for (backend_exact_files, matched_exact) |exact, seen| {
        if (seen) continue;
        std.debug.print("architecture boundary: missing src/{s}\n", .{exact});
        ok = false;
    }

    try std.testing.expect(scanned >= backend_exact_files.len);
    try std.testing.expect(ok);
}
