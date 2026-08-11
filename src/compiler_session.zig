const std = @import("std");

const ast = @import("ast.zig");
const async_lower = @import("async_lower.zig");
const backend = @import("backend.zig");
const diagnostics = @import("diagnostics.zig");
const generic_precheck = @import("generic_precheck.zig");
const loader = @import("loader.zig");
const mangle_private = @import("mangle_private.zig");
const mir = @import("mir.zig");
const monomorphize = @import("monomorphize.zig");
const name_resolve = @import("name_resolve.zig");
const parser = @import("parser.zig");
const sema = @import("sema.zig");

pub const max_artifact_metadata_bytes = 512 * 1024 * 1024;

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
    visibility_mode: ast.VisibilityMode = .legacy_pub_opt_in,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) CompilationSession {
        return .{
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn writeStdout(self: *CompilationSession, bytes: []const u8) !void {
        std.Io.File.stdout().writeStreamingAll(self.io, bytes) catch |err| switch (err) {
            error.BrokenPipe => return,
            else => return err,
        };
    }

    pub fn writeOutputPath(self: *CompilationSession, path: []const u8, bytes: []const u8) !void {
        // Materialize artifacts through a sibling temporary file and atomically
        // replace the destination only after the complete write succeeds. A
        // failed or killed compilation therefore cannot truncate a previously
        // valid artifact or expose a partially written one.
        var atomic_file = std.Io.Dir.cwd().createFileAtomic(self.io, path, .{
            .replace = true,
        }) catch |err| {
            std.debug.print("error: unable to write output \"{s}\": {s}\n", .{ path, @errorName(err) });
            return error.OutputWriteFailed;
        };
        defer atomic_file.deinit(self.io);
        atomic_file.file.writeStreamingAll(self.io, bytes) catch |err| {
            std.debug.print("error: unable to write output \"{s}\": {s}\n", .{ path, @errorName(err) });
            return error.OutputWriteFailed;
        };
        atomic_file.replace(self.io) catch |err| {
            std.debug.print("error: unable to commit output \"{s}\": {s}\n", .{ path, @errorName(err) });
            return error.OutputWriteFailed;
        };
    }

    pub const ArtifactMetadataDraft = struct {
        path: []const u8,
        bytes: std.ArrayList(u8),

        pub fn deinit(self: *ArtifactMetadataDraft, allocator: std.mem.Allocator) void {
            allocator.free(self.path);
            self.bytes.deinit(allocator);
        }
    };

    pub const MetadataSidecarSnapshot = union(enum) {
        absent,
        present: []u8,

        pub fn deinit(self: *MetadataSidecarSnapshot, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .absent => {},
                .present => |bytes| allocator.free(bytes),
            }
        }
    };

    pub fn ensureReplaceTargetNotDirectory(self: *CompilationSession, path: []const u8, label: []const u8) !void {
        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => {
                std.debug.print("error: unable to inspect {s} \"{s}\": {s}\n", .{ label, path, @errorName(err) });
                return error.OutputWriteFailed;
            },
        };
        if (stat.kind == .directory) {
            std.debug.print("error: unable to replace {s} \"{s}\": destination is a directory\n", .{ label, path });
            return error.OutputWriteFailed;
        }
    }

    pub fn snapshotMetadataSidecar(self: *CompilationSession, path: []const u8) !MetadataSidecarSnapshot {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(max_artifact_metadata_bytes)) catch |err| switch (err) {
            error.FileNotFound => return .absent,
            else => {
                std.debug.print("error: unable to snapshot metadata sidecar \"{s}\": {s}\n", .{ path, @errorName(err) });
                return error.OutputWriteFailed;
            },
        };
        return .{ .present = bytes };
    }

    pub fn restoreMetadataSidecar(self: *CompilationSession, path: []const u8, snapshot: MetadataSidecarSnapshot) !void {
        switch (snapshot) {
            .absent => {
                std.Io.Dir.cwd().deleteFile(self.io, path) catch |err| switch (err) {
                    error.FileNotFound => return,
                    else => {
                        std.debug.print("error: unable to remove rolled-back metadata sidecar \"{s}\": {s}\n", .{ path, @errorName(err) });
                        return error.OutputWriteFailed;
                    },
                };
            },
            .present => |bytes| try self.writeOutputPath(path, bytes),
        }
    }

    pub fn prepareArtifactMetadataSidecar(self: *CompilationSession, output_path: []const u8, bundle: backend.ArtifactBundle) !ArtifactMetadataDraft {
        const metadata_path = try artifactMetadataPath(self.allocator, output_path);
        errdefer self.allocator.free(metadata_path);

        var metadata: std.ArrayList(u8) = .empty;
        errdefer metadata.deinit(self.allocator);
        try backend.appendArtifactMetadata(self.allocator, &metadata, bundle);

        return .{
            .path = metadata_path,
            .bytes = metadata,
        };
    }

    pub fn writeArtifact(self: *CompilationSession, bytes: []const u8, output_path: ?[]const u8) !void {
        if (output_path) |path| return self.writeOutputPath(path, bytes);
        return self.writeStdout(bytes);
    }

    pub fn writeArtifactMetadataSidecar(self: *CompilationSession, output_path: []const u8, bundle: backend.ArtifactBundle) !void {
        var metadata = try self.prepareArtifactMetadataSidecar(output_path, bundle);
        defer metadata.deinit(self.allocator);
        try self.writeOutputPath(metadata.path, metadata.bytes.items);
    }

    pub fn writeArtifactWithMetadata(self: *CompilationSession, bytes: []const u8, output_path: ?[]const u8, bundle: backend.ArtifactBundle) !void {
        const path = output_path orelse return self.writeStdout(bytes);

        var metadata = try self.prepareArtifactMetadataSidecar(path, bundle);
        defer metadata.deinit(self.allocator);
        try self.ensureReplaceTargetNotDirectory(path, "output");
        try self.ensureReplaceTargetNotDirectory(metadata.path, "metadata sidecar");
        var metadata_snapshot = try self.snapshotMetadataSidecar(metadata.path);
        defer metadata_snapshot.deinit(self.allocator);

        var metadata_file = std.Io.Dir.cwd().createFileAtomic(self.io, metadata.path, .{
            .replace = true,
        }) catch |err| {
            std.debug.print("error: unable to write metadata sidecar \"{s}\": {s}\n", .{ metadata.path, @errorName(err) });
            return error.OutputWriteFailed;
        };
        defer metadata_file.deinit(self.io);
        metadata_file.file.writeStreamingAll(self.io, metadata.bytes.items) catch |err| {
            std.debug.print("error: unable to write metadata sidecar \"{s}\": {s}\n", .{ metadata.path, @errorName(err) });
            return error.OutputWriteFailed;
        };

        var artifact_file = std.Io.Dir.cwd().createFileAtomic(self.io, path, .{
            .replace = true,
        }) catch |err| {
            std.debug.print("error: unable to write output \"{s}\": {s}\n", .{ path, @errorName(err) });
            return error.OutputWriteFailed;
        };
        defer artifact_file.deinit(self.io);
        artifact_file.file.writeStreamingAll(self.io, bytes) catch |err| {
            std.debug.print("error: unable to write output \"{s}\": {s}\n", .{ path, @errorName(err) });
            return error.OutputWriteFailed;
        };

        // Publish the sidecar before the artifact. The artifact is the
        // consumer-visible commit point, so a newly visible artifact always has
        // its matching metadata in place. If the final artifact replace fails,
        // strict consumers compare the newer sidecar against the still-old
        // artifact and fail closed on the digest mismatch.
        metadata_file.replace(self.io) catch |err| {
            std.debug.print("error: unable to commit metadata sidecar \"{s}\": {s}\n", .{ metadata.path, @errorName(err) });
            return error.OutputWriteFailed;
        };
        artifact_file.replace(self.io) catch |err| {
            std.debug.print("error: unable to commit output \"{s}\": {s}\n", .{ path, @errorName(err) });
            self.restoreMetadataSidecar(metadata.path, metadata_snapshot) catch |restore_err| {
                std.debug.print("error: unable to roll back metadata sidecar \"{s}\" after output commit failure: {s}\n", .{ metadata.path, @errorName(restore_err) });
            };
            return error.OutputWriteFailed;
        };
    }

    pub fn initReporter(self: *CompilationSession, path: []const u8, source: []const u8) diagnostics.Reporter {
        var reporter = diagnostics.Reporter.init(self.allocator, path, source);
        reporter.file_boundaries = self.file_boundaries;
        return reporter;
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

    pub fn buildVerifiedProgram(
        self: *CompilationSession,
        module: ast.Module,
        diag: *diagnostics.Reporter,
        optimize: bool,
        module_mir: *mir.Module,
        failure_error: StageFailure,
    ) !backend.VerifiedProgram {
        module_mir.* = try mir.buildOpt(self.allocator, module, .{ .optimize = optimize });
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
    return std.fmt.allocPrint(allocator, "{s}.mcmeta", .{output_path});
}
