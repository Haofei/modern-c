const std = @import("std");

const artifact_model = @import("artifact_model.zig");
const artifact_publisher = @import("artifact_publisher.zig");
const ast = @import("ast.zig");
const async_lower = @import("async_lower.zig");
const backend = @import("backend.zig");
const diagnostics = @import("diagnostics.zig");
const generic_precheck = @import("generic_precheck.zig");
const loader = @import("loader.zig");
const mangle_private = @import("mangle_private.zig");
const mir = @import("mir.zig");
const module_parser = @import("module_parser.zig");
const monomorphize = @import("monomorphize.zig");
const name_resolve = @import("name_resolve.zig");
const parser = @import("parser.zig");
const sema = @import("sema.zig");

pub const max_artifact_metadata_bytes = artifact_publisher.max_metadata_bytes;

pub const StageFailure = error{
    CheckFailed,
    LowerMirFailed,
    VerifyFailed,
    EmitCFailed,
    BuildFailed,
    EmitLlvmFailed,
    EmitLayoutFailed,
    EmitCStructFailed,
};

pub const CompilationSession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    // File-origin boundaries of the import-flattened source
    // (loader.loadCombinedSourceWithBoundaries), set once per source-loading
    // invocation and consumed by diagnostics/sema/name transforms. Null when no
    // module was loaded (e.g. `fmt`, which bypasses the loader).
    file_boundaries: ?[]const loader.FileBoundary = null,
    module_graph: ?*const loader.ModuleGraph = null,
    resolved_sources: ?*const module_parser.ResolvedSourceDatabase = null,
    visibility_mode: ast.VisibilityMode = .legacy_pub_opt_in,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) CompilationSession {
        return .{
            .allocator = allocator,
            .io = io,
        };
    }

    fn publisher(self: *CompilationSession) artifact_publisher.Publisher {
        return artifact_publisher.Publisher.init(self.allocator, self.io);
    }

    pub fn writeStdout(self: *CompilationSession, bytes: []const u8) !void {
        try self.publisher().writeStdout(bytes);
    }

    pub fn writeOutputPath(self: *CompilationSession, path: []const u8, bytes: []const u8) !void {
        try self.publisher().writeOutputPath(path, bytes);
    }

    pub const ArtifactMetadataDraft = artifact_publisher.Publisher.MetadataDraft;
    pub const MetadataSidecarSnapshot = artifact_publisher.Publisher.MetadataSidecarSnapshot;

    pub fn ensureReplaceTargetNotDirectory(self: *CompilationSession, path: []const u8, label: []const u8) !void {
        try self.publisher().ensureReplaceTargetNotDirectory(path, label);
    }

    pub fn snapshotMetadataSidecar(self: *CompilationSession, path: []const u8) !MetadataSidecarSnapshot {
        return self.publisher().snapshotMetadataSidecar(path);
    }

    pub fn restoreMetadataSidecar(self: *CompilationSession, path: []const u8, snapshot: MetadataSidecarSnapshot) !void {
        try self.publisher().restoreMetadataSidecar(path, snapshot);
    }

    pub fn prepareArtifactMetadataSidecar(self: *CompilationSession, output_path: []const u8, bundle: artifact_model.ArtifactBundle) !ArtifactMetadataDraft {
        return self.publisher().prepareMetadataSidecar(output_path, bundle);
    }

    pub fn writeArtifact(self: *CompilationSession, bytes: []const u8, output_path: ?[]const u8) !void {
        try self.publisher().writeArtifact(bytes, output_path);
    }

    pub fn writeArtifactMetadataSidecar(self: *CompilationSession, output_path: []const u8, bundle: artifact_model.ArtifactBundle) !void {
        try self.publisher().writeArtifactMetadataSidecar(output_path, bundle);
    }

    pub fn writeArtifactWithMetadata(self: *CompilationSession, bytes: []const u8, output_path: ?[]const u8, bundle: artifact_model.ArtifactBundle) !void {
        try self.publisher().writeArtifactWithMetadata(bytes, output_path, bundle);
    }

    pub fn publishExistingArtifactWithMetadata(
        self: *CompilationSession,
        tmp_path: []const u8,
        output_path: []const u8,
        bundle: artifact_model.ArtifactBundle,
        artifact_label: []const u8,
    ) !void {
        try self.publisher().publishExistingFileWithMetadata(tmp_path, output_path, bundle, artifact_label);
    }

    pub fn initReporter(self: *CompilationSession, path: []const u8, source: []const u8) diagnostics.Reporter {
        var reporter = diagnostics.Reporter.init(self.allocator, path, source);
        reporter.file_boundaries = self.file_boundaries;
        return reporter;
    }

    pub fn attachLoadedProjectSyntax(
        self: *CompilationSession,
        project: *const loader.LoadedProject,
        parse_allocator: std.mem.Allocator,
        reporter: *diagnostics.Reporter,
        parsed_out: *module_parser.ParsedSourceDatabase,
        resolved_out: *module_parser.ResolvedSourceDatabase,
    ) !void {
        parsed_out.* = try module_parser.parseSourceDatabase(parse_allocator, project.graph, project.source_db, reporter);
        var parsed_ready = true;
        errdefer if (parsed_ready) parsed_out.deinit(parse_allocator);
        resolved_out.* = try module_parser.resolveParsedSourceDatabase(parse_allocator, parsed_out.*);
        self.resolved_sources = resolved_out;
        parsed_ready = false;
    }

    pub fn parseModuleOrReport(self: *CompilationSession, source: []const u8, allocator: std.mem.Allocator, diag: *diagnostics.Reporter) !ast.Module {
        return self.parseModuleOrReportMode(source, allocator, diag, true);
    }

    pub fn parseModuleOrReportMode(self: *CompilationSession, source: []const u8, allocator: std.mem.Allocator, diag: *diagnostics.Reporter, render_errors: bool) !ast.Module {
        var p = parser.Parser.init(source, diag);
        var module = p.parseModule(allocator) catch |err| {
            if (render_errors) diag.render();
            return err;
        };
        module.visibility_mode = self.visibility_mode;
        const resolved = name_resolve.transformWithGraph(allocator, module, self.module_graph) catch |err| {
            if (render_errors) diag.render();
            return err;
        };
        // Lower `async fn` / `await` to stackless Future state machines BEFORE
        // monomorphize/sema, so the move/borrow checker and both backends only
        // ever see ordinary MC. No-op for modules without any `async fn`
        // (passes the module through untouched).
        const lowered = async_lower.transform(allocator, resolved, diag) catch |err| {
            if (render_errors) diag.render();
            return err;
        };
        try generic_precheck.check(allocator, lowered, diag, self.file_boundaries);
        if (diag.has_errors) {
            if (render_errors) diag.render();
            return error.ParseFailed;
        }
        const specialized = monomorphize.transformReport(allocator, lowered, diag) catch |err| {
            if (render_errors) diag.render();
            return err;
        };
        if (diag.has_errors) {
            if (render_errors) diag.render();
            return error.ParseFailed;
        }
        return mangle_private.transform(allocator, specialized, self.file_boundaries) catch |err| {
            if (render_errors) diag.render();
            return err;
        };
    }

    pub fn checkModule(self: *CompilationSession, module: ast.Module, diag: *diagnostics.Reporter, optimize: bool) void {
        var checker = sema.Checker.init(diag);
        checker.file_boundaries = self.file_boundaries;
        checker.optimize = optimize;
        checker.checkModule(module);
    }

    pub fn parseCheckedModuleOrReport(
        self: *CompilationSession,
        source: []const u8,
        allocator: std.mem.Allocator,
        diag: *diagnostics.Reporter,
        optimize: bool,
        render_errors: bool,
        failure_error: StageFailure,
    ) !ast.Module {
        const module = try self.parseModuleOrReportMode(source, allocator, diag, render_errors);
        if (diag.has_errors) {
            if (render_errors) diag.render();
            return failure_error;
        }
        self.checkModule(module, diag, optimize);
        if (diag.has_errors) {
            if (render_errors) diag.render();
            return failure_error;
        }
        return module;
    }

    pub fn buildVerifiedProgramFromDecls(
        self: *CompilationSession,
        decls: []ast.Decl,
        diag: *diagnostics.Reporter,
        optimize: bool,
        module_mir: *mir.Module,
        failure_error: StageFailure,
    ) !backend.VerifiedProgram {
        module_mir.* = try mir.buildOptFromDecls(self.allocator, decls, .{ .optimize = optimize });
        errdefer module_mir.deinit();
        const program = backend.VerifiedProgram.init(module_mir, diag) catch |err| {
            if (diag.has_errors) return failure_error;
            return err;
        };
        if (diag.has_errors) return failure_error;
        return program;
    }
};

pub fn artifactMetadataPath(allocator: std.mem.Allocator, output_path: []const u8) ![]const u8 {
    return artifact_publisher.metadataPath(allocator, output_path);
}

test "CompilationSession keeps parse context request scoped" {
    const source = "fn answer() -> u32 { return 1; }\n";

    var boundaries_a = [_]loader.FileBoundary{.{ .start = 0, .path = "a.mc" }};
    var session_a = CompilationSession.init(std.testing.allocator, std.testing.io);
    session_a.visibility_mode = .explicit_public;
    session_a.file_boundaries = boundaries_a[0..];
    try std.testing.expect(session_a.resolved_sources == null);
    var diag_a = session_a.initReporter("root_a.mc", source);
    defer diag_a.deinit();
    try std.testing.expectEqualStrings("a.mc", diag_a.file_boundaries.?[0].path);
    var arena_a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_a.deinit();
    const module_a = try session_a.parseModuleOrReportMode(source, arena_a.allocator(), &diag_a, false);
    defer module_a.deinit(arena_a.allocator());
    try std.testing.expectEqual(ast.VisibilityMode.explicit_public, module_a.visibility_mode);

    var boundaries_b = [_]loader.FileBoundary{.{ .start = 0, .path = "b.mc" }};
    var session_b = CompilationSession.init(std.testing.allocator, std.testing.io);
    session_b.file_boundaries = boundaries_b[0..];
    try std.testing.expect(session_b.resolved_sources == null);
    var diag_b = session_b.initReporter("root_b.mc", source);
    defer diag_b.deinit();
    try std.testing.expectEqualStrings("b.mc", diag_b.file_boundaries.?[0].path);
    var arena_b = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_b.deinit();
    const module_b = try session_b.parseModuleOrReportMode(source, arena_b.allocator(), &diag_b, false);
    defer module_b.deinit(arena_b.allocator());
    try std.testing.expectEqual(ast.VisibilityMode.legacy_pub_opt_in, module_b.visibility_mode);
}

test "CompilationSession attaches per-file resolved module syntax" {
    const root_path = "tests/spec_support/import_wide_root.mc";
    const root_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, root_path, std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(root_source);

    var loaded = try loader.loadProjectOptionsReport(std.testing.allocator, std.testing.io, root_path, root_source, .{}, null);
    defer loaded.deinit(std.testing.allocator);

    var reporter = diagnostics.Reporter.init(std.testing.allocator, root_path, loaded.source);
    defer reporter.deinit();
    var session = CompilationSession.init(std.testing.allocator, std.testing.io);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parsed_sources: module_parser.ParsedSourceDatabase = undefined;
    var resolved_sources: module_parser.ResolvedSourceDatabase = undefined;
    try session.attachLoadedProjectSyntax(&loaded, arena.allocator(), &reporter, &parsed_sources, &resolved_sources);
    defer {
        resolved_sources.deinit(arena.allocator());
        parsed_sources.deinit(arena.allocator());
    }

    try std.testing.expect(!reporter.has_errors);
    try std.testing.expect(session.resolved_sources != null);
    try std.testing.expectEqual(loaded.graph.files.len, session.resolved_sources.?.files.len);
    try std.testing.expect(session.resolved_sources.?.moduleForFile(loaded.graph.files[0].id) != null);
}

test "CompilationSession restores artifact metadata sidecar snapshots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const artifact_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/artifact", .{tmp.sub_path});
    defer allocator.free(artifact_path);
    const metadata_path = try artifactMetadataPath(allocator, artifact_path);
    defer allocator.free(metadata_path);

    var session = CompilationSession.init(allocator, std.testing.io);
    try session.writeOutputPath(metadata_path, "old metadata");
    var present_snapshot = try session.snapshotMetadataSidecar(metadata_path);
    defer present_snapshot.deinit(allocator);
    try session.writeOutputPath(metadata_path, "new metadata");
    try session.restoreMetadataSidecar(metadata_path, present_snapshot);
    const restored = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, metadata_path, allocator, .limited(1024));
    defer allocator.free(restored);
    try std.testing.expectEqualStrings("old metadata", restored);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, metadata_path);
    var absent_snapshot = try session.snapshotMetadataSidecar(metadata_path);
    defer absent_snapshot.deinit(allocator);
    try session.writeOutputPath(metadata_path, "new metadata");
    try session.restoreMetadataSidecar(metadata_path, absent_snapshot);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, metadata_path, .{}));
}

test "CompilationSession diagnostic stage failures use a bounded error set" {
    const allowed = [_]StageFailure{
        error.CheckFailed,
        error.LowerMirFailed,
        error.VerifyFailed,
        error.EmitCFailed,
        error.BuildFailed,
        error.EmitLlvmFailed,
        error.EmitLayoutFailed,
        error.EmitCStructFailed,
    };
    comptime std.debug.assert(@TypeOf(allowed[0]) == StageFailure);
    try std.testing.expectEqual(@as(usize, 8), allowed.len);
}
