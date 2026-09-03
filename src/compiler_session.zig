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
const sema = @import("sema.zig");

pub const max_artifact_metadata_bytes = artifact_publisher.max_metadata_bytes;

pub const StageFailure = error{
    CheckFailed,
    RunTrapFailed,
    LowerHirFailed,
    VerifyHirFailed,
    LowerMirFailed,
    VerifyFailed,
    LowerCFailed,
    EmitCFailed,
    BuildFailed,
    EmitLlvmFailed,
    EmitLayoutFailed,
    EmitCStructFailed,
};

pub const CompilationSession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    source_views: ?[]const diagnostics.SourceView = null,
    module_graph: ?*const loader.ModuleGraph = null,
    source_db: ?*const loader.SourceDatabase = null,
    resolved_sources: ?*const module_parser.ResolvedSourceDatabase = null,
    resolved_program: ?*const module_parser.ResolvedProgram = null,
    project_source_digest: ?artifact_model.Sha256Digest = null,
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
        reporter.source_views = self.source_views;
        return reporter;
    }

    pub fn sourceDigest(self: *const CompilationSession, fallback_source: []const u8) artifact_model.Sha256Digest {
        return self.project_source_digest orelse artifact_model.sha256Bytes(fallback_source);
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
        resolved_out.* = try module_parser.resolveParsedSourceDatabase(parse_allocator, parsed_out.*, project.graph);
        self.resolved_sources = resolved_out;
        parsed_ready = false;
    }

    pub fn prepareResolvedProgram(
        self: *CompilationSession,
        allocator: std.mem.Allocator,
        diag: *diagnostics.Reporter,
    ) !module_parser.ResolvedProgram {
        const sources = self.resolved_sources orelse return error.MissingResolvedSources;
        const graph = self.module_graph orelse return error.MissingModuleGraph;
        const resolved = try sources.collectDecls(allocator);
        defer allocator.free(resolved);
        var decls = try allocator.alloc(ast.Decl, resolved.len);
        for (resolved, 0..) |entry, index| decls[index] = entry.decl;

        var qualified_owners = try sources.collectQualifiedOwners(allocator);
        const lowered = try async_lower.transformDecls(allocator, decls, qualified_owners, diag);
        decls = lowered.decls;
        qualified_owners = lowered.qualified_owners;
        try generic_precheck.checkDecls(allocator, decls, self.visibility_mode, diag);
        if (diag.has_errors) return error.ParseFailed;
        decls = try monomorphize.transformDeclsReport(allocator, decls, diag);
        if (diag.has_errors) return error.ParseFailed;
        decls = try mangle_private.transformDeclsForFiles(allocator, decls, self.visibility_mode, graph.files.len);

        const root_id = if (graph.files.len != 0) graph.files[0].id else return error.MissingModuleGraph;
        const output = try allocator.alloc(module_parser.ResolvedDecl, decls.len);
        errdefer allocator.free(output);
        // IDs are deliberately allocated only after async/generic expansion
        // and private-name rewriting. Those passes may create or reorder
        // declarations; assigning earlier would either lose identity or need
        // an incremental database that this compiler does not have.
        var next_decl_ordinal = std.AutoHashMap(loader.FileId, u32).init(allocator);
        defer next_decl_ordinal.deinit();
        for (decls, 0..) |decl, index| {
            const file_id: loader.FileId = if (decl.span.file_id != diagnostics.invalid_file_id)
                @enumFromInt(decl.span.file_id)
            else if (graph.files.len == 1)
                root_id
            else
                return error.GeneratedDeclarationMissingFileIdentity;
            if (graph.fileById(file_id) == null) return error.InvalidModuleGraph;
            const ordinal = next_decl_ordinal.get(file_id) orelse 0;
            if (ordinal == std.math.maxInt(u32)) return error.TooManyDeclarationsInFile;
            try next_decl_ordinal.put(file_id, ordinal + 1);
            output[index] = .{
                .def_id = .{ .file_id = @intFromEnum(file_id), .ordinal = ordinal },
                .file_id = file_id,
                .decl = decl,
            };
        }
        return .{
            .decls = output,
            .visibility_mode = self.visibility_mode,
            .qualified_owners = qualified_owners,
        };
    }

    pub fn checkResolvedProgram(
        self: *CompilationSession,
        program: module_parser.ResolvedProgram,
        allocator: std.mem.Allocator,
        diag: *diagnostics.Reporter,
        optimize: bool,
        failure_error: StageFailure,
    ) !void {
        const decls = try program.astDecls(allocator);
        defer allocator.free(decls);
        self.checkDecls(decls, program.visibility_mode, program.qualified_owners, diag, optimize);
        if (diag.has_errors) return failure_error;
    }

    fn checkDecls(self: *CompilationSession, decls: []ast.Decl, visibility_mode: ast.VisibilityMode, qualified_owners: [][]const u8, diag: *diagnostics.Reporter, optimize: bool) void {
        _ = self;
        var checker = sema.Checker.init(diag);
        checker.optimize = optimize;
        checker.checkDecls(decls, visibility_mode, qualified_owners);
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

    pub fn buildVerifiedProgramFromResolvedDecls(
        self: *CompilationSession,
        resolved_decls: []const module_parser.ResolvedDecl,
        diag: *diagnostics.Reporter,
        optimize: bool,
        module_mir: *mir.Module,
        failure_error: StageFailure,
    ) !backend.VerifiedProgram {
        module_mir.* = try mir.buildOptFromResolvedDecls(self.allocator, resolved_decls, .{ .optimize = optimize });
        errdefer module_mir.deinit();
        const program = backend.VerifiedProgram.init(module_mir, diag) catch |err| {
            if (diag.has_errors) return failure_error;
            return err;
        };
        if (diag.has_errors) return failure_error;
        return program;
    }

    pub fn buildMirFromResolvedDecls(
        self: *CompilationSession,
        resolved_decls: []const module_parser.ResolvedDecl,
        optimize: bool,
        module_mir: *mir.Module,
    ) !void {
        module_mir.* = try mir.buildOptFromResolvedDecls(self.allocator, resolved_decls, .{ .optimize = optimize });
    }
};

pub fn artifactMetadataPath(allocator: std.mem.Allocator, output_path: []const u8) ![]const u8 {
    return artifact_publisher.metadataPath(allocator, output_path);
}

test "CompilationSession attaches per-file resolved module syntax" {
    const root_path = "tests/spec_support/import_wide_root.mc";
    const root_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, root_path, std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(root_source);

    var loaded = try loader.loadProjectOptionsReport(std.testing.allocator, std.testing.io, root_path, root_source, .{}, null);
    defer loaded.deinit(std.testing.allocator);

    const root_parser_source = loaded.source_db.parserSourceForFile(loaded.graph.files[0].id).?;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, root_path, root_parser_source);
    defer reporter.deinit();
    const source_views = try loaded.source_db.diagnosticViews(std.testing.allocator, loaded.graph);
    defer std.testing.allocator.free(source_views);
    reporter.source_views = source_views;
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
    try std.testing.expect(session.resolved_sources.?.declsForFile(loaded.graph.files[0].id) != null);
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
