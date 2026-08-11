const std = @import("std");

const backend = @import("backend.zig");

pub const max_metadata_bytes = 512 * 1024 * 1024;

pub const Publisher = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Publisher {
        return .{
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn writeStdout(self: Publisher, bytes: []const u8) !void {
        std.Io.File.stdout().writeStreamingAll(self.io, bytes) catch |err| switch (err) {
            error.BrokenPipe => return,
            else => return err,
        };
    }

    pub fn writeOutputPath(self: Publisher, path: []const u8, bytes: []const u8) !void {
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

    pub const MetadataDraft = struct {
        path: []const u8,
        bytes: std.ArrayList(u8),

        pub fn deinit(self: *MetadataDraft, allocator: std.mem.Allocator) void {
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

    pub fn ensureReplaceTargetNotDirectory(self: Publisher, path: []const u8, label: []const u8) !void {
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

    pub fn snapshotMetadataSidecar(self: Publisher, path: []const u8) !MetadataSidecarSnapshot {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(max_metadata_bytes)) catch |err| switch (err) {
            error.FileNotFound => return .absent,
            else => {
                std.debug.print("error: unable to snapshot metadata sidecar \"{s}\": {s}\n", .{ path, @errorName(err) });
                return error.OutputWriteFailed;
            },
        };
        return .{ .present = bytes };
    }

    pub fn restoreMetadataSidecar(self: Publisher, path: []const u8, snapshot: MetadataSidecarSnapshot) !void {
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

    pub fn prepareMetadataSidecar(self: Publisher, output_path: []const u8, bundle: backend.ArtifactBundle) !MetadataDraft {
        const metadata_path = try metadataPath(self.allocator, output_path);
        errdefer self.allocator.free(metadata_path);

        var metadata: std.ArrayList(u8) = .empty;
        errdefer metadata.deinit(self.allocator);
        try backend.appendArtifactMetadata(self.allocator, &metadata, bundle);

        return .{
            .path = metadata_path,
            .bytes = metadata,
        };
    }

    pub fn writeArtifact(self: Publisher, bytes: []const u8, output_path: ?[]const u8) !void {
        if (output_path) |path| return self.writeOutputPath(path, bytes);
        return self.writeStdout(bytes);
    }

    pub fn writeArtifactMetadataSidecar(self: Publisher, output_path: []const u8, bundle: backend.ArtifactBundle) !void {
        var metadata = try self.prepareMetadataSidecar(output_path, bundle);
        defer metadata.deinit(self.allocator);
        try self.writeOutputPath(metadata.path, metadata.bytes.items);
    }

    pub fn writeArtifactWithMetadata(self: Publisher, bytes: []const u8, output_path: ?[]const u8, bundle: backend.ArtifactBundle) !void {
        const path = output_path orelse return self.writeStdout(bytes);

        var metadata = try self.prepareMetadataSidecar(path, bundle);
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

    pub fn publishExistingFileWithMetadata(
        self: Publisher,
        tmp_path: []const u8,
        output_path: []const u8,
        bundle: backend.ArtifactBundle,
        artifact_label: []const u8,
    ) !void {
        var metadata = try self.prepareMetadataSidecar(output_path, bundle);
        defer metadata.deinit(self.allocator);
        try self.ensureReplaceTargetNotDirectory(output_path, artifact_label);
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

        // The existing temp artifact was produced by an external tool; commit
        // metadata first, then rename that temp artifact as the visible commit
        // point. If the rename fails, roll back the metadata sidecar.
        metadata_file.replace(self.io) catch |err| {
            std.debug.print("error: unable to commit metadata sidecar \"{s}\": {s}\n", .{ metadata.path, @errorName(err) });
            return error.OutputWriteFailed;
        };
        std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), output_path, self.io) catch |err| {
            std.debug.print("error: unable to commit {s} \"{s}\": {s}\n", .{ artifact_label, output_path, @errorName(err) });
            self.restoreMetadataSidecar(metadata.path, metadata_snapshot) catch |restore_err| {
                std.debug.print("error: unable to roll back metadata sidecar \"{s}\" after {s} commit failure: {s}\n", .{ metadata.path, artifact_label, @errorName(restore_err) });
            };
            return error.OutputWriteFailed;
        };
    }
};

pub fn metadataPath(allocator: std.mem.Allocator, output_path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.mcmeta", .{output_path});
}
