const std = @import("std");

pub const Sha256Digest = [std.crypto.hash.sha2.Sha256.digest_length]u8;

/// Shared artifact/source-map provenance metadata. This lives outside the
/// backend seam so artifact publication and source-map verification can share
/// one envelope contract without making code generation own publication state.
pub const ArtifactBundle = struct {
    artifact_kind: ?[]const u8 = null,
    backend_name: ?[]const u8 = null,
    generated_artifact_sha256: Sha256Digest,
    source_map_generated_artifact_sha256: ?Sha256Digest = null,
    source_map_payload_sha256: ?Sha256Digest = null,
    mir_facts_sha256: ?Sha256Digest = null,
    source_sha256: ?Sha256Digest = null,
    compiler_version: ?[]const u8 = null,
    target_arch: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    checks_optimize: ?bool = null,
    checks_ksan: ?bool = null,
    checks_msan: ?bool = null,
    checks_csan: ?bool = null,
    stub_asm: ?bool = null,
    linux_kernel: ?bool = null,
    toolchain_identity: ?[]const u8 = null,

    pub const Metadata = struct {
        artifact_kind: []const u8,
        backend_name: []const u8,
        toolchain_identity: ?[]const u8 = null,
    };

    pub fn forArtifact(
        generated_artifact: []const u8,
        opts: anytype,
        metadata: Metadata,
    ) ArtifactBundle {
        return .{
            .artifact_kind = metadata.artifact_kind,
            .backend_name = metadata.backend_name,
            .generated_artifact_sha256 = sha256Bytes(generated_artifact),
            .source_sha256 = opts.source_sha256,
            .compiler_version = opts.compiler_version,
            .target_arch = @tagName(opts.target_arch),
            .profile = @tagName(opts.profile),
            .checks_optimize = opts.checks.optimize,
            .checks_ksan = opts.checks.ksan,
            .checks_msan = opts.checks.msan,
            .checks_csan = opts.checks.csan,
            .stub_asm = opts.stub_asm,
            .linux_kernel = opts.linux_kernel,
            .toolchain_identity = metadata.toolchain_identity orelse opts.toolchain_identity,
        };
    }

    pub fn forSourceMap(
        generated_artifact: []const u8,
        source_map_payload: []const u8,
        mir_facts_input: []const u8,
        opts: anytype,
    ) ArtifactBundle {
        var bundle = forArtifact(generated_artifact, opts, .{
            .artifact_kind = "c-source-map",
            .backend_name = "c",
        });
        bundle.source_map_generated_artifact_sha256 = sha256Bytes(generated_artifact);
        bundle.source_map_payload_sha256 = sha256Bytes(source_map_payload);
        bundle.mir_facts_sha256 = sha256Bytes(mir_facts_input);
        return bundle;
    }
};

pub fn sha256Bytes(bytes: []const u8) Sha256Digest {
    var digest: Sha256Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

pub fn appendArtifactBundleHeaders(allocator: std.mem.Allocator, out: *std.ArrayList(u8), bundle: ArtifactBundle) !void {
    try appendOptionalStringHeader(allocator, out, "artifact_kind", bundle.artifact_kind);
    try appendOptionalStringHeader(allocator, out, "backend", bundle.backend_name);
    try appendDigestValueHeader(allocator, out, "generated_artifact_sha256", bundle.generated_artifact_sha256);
    try appendOptionalDigestHeader(allocator, out, "source_map_generated_artifact_sha256", bundle.source_map_generated_artifact_sha256);
    try appendOptionalDigestHeader(allocator, out, "source_map_payload_sha256", bundle.source_map_payload_sha256);
    try appendOptionalDigestHeader(allocator, out, "mir_facts_sha256", bundle.mir_facts_sha256);
    try appendOptionalDigestHeader(allocator, out, "source_sha256", bundle.source_sha256);
    try appendOptionalStringHeader(allocator, out, "compiler_version", bundle.compiler_version);
    try appendOptionalStringHeader(allocator, out, "target_arch", bundle.target_arch);
    try appendOptionalStringHeader(allocator, out, "lower_profile", bundle.profile);
    try appendOptionalBoolHeader(allocator, out, "lower_checks_optimize", bundle.checks_optimize);
    try appendOptionalBoolHeader(allocator, out, "lower_checks_ksan", bundle.checks_ksan);
    try appendOptionalBoolHeader(allocator, out, "lower_checks_msan", bundle.checks_msan);
    try appendOptionalBoolHeader(allocator, out, "lower_checks_csan", bundle.checks_csan);
    try appendOptionalBoolHeader(allocator, out, "lower_stub_asm", bundle.stub_asm);
    try appendOptionalBoolHeader(allocator, out, "lower_linux_kernel", bundle.linux_kernel);
    try appendOptionalStringHeader(allocator, out, "toolchain_identity", bundle.toolchain_identity);
}

pub const ArtifactBundleFormat = enum {
    metadata_sidecar,
    source_map,

    fn magic(self: ArtifactBundleFormat) []const u8 {
        return switch (self) {
            .metadata_sidecar => "# mcmeta v1\n",
            .source_map => "# mcmap v1\n",
        };
    }
};

pub fn appendArtifactBundle(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    bundle: ArtifactBundle,
    format: ArtifactBundleFormat,
) !void {
    try out.appendSlice(allocator, format.magic());
    try appendArtifactBundleHeaders(allocator, out, bundle);
}

pub fn appendArtifactMetadata(allocator: std.mem.Allocator, out: *std.ArrayList(u8), bundle: ArtifactBundle) !void {
    try appendArtifactBundle(allocator, out, bundle, .metadata_sidecar);
}

fn appendDigestValueHeader(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, digest: Sha256Digest) !void {
    try out.print(allocator, "# {s}=", .{name});
    try appendHexBytes(allocator, out, &digest);
    try out.appendSlice(allocator, "\n");
}

fn appendOptionalDigestHeader(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, maybe_digest: ?Sha256Digest) !void {
    const digest = maybe_digest orelse return;
    try appendDigestValueHeader(allocator, out, name, digest);
}

fn appendOptionalStringHeader(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, value: ?[]const u8) !void {
    const text = value orelse return;
    try out.print(allocator, "# {s}=", .{name});
    try appendEscapedMetadataValue(allocator, out, text);
    try out.appendSlice(allocator, "\n");
}

fn appendOptionalBoolHeader(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, value: ?bool) !void {
    const flag = value orelse return;
    try out.print(allocator, "# {s}={s}\n", .{ name, if (flag) "true" else "false" });
}

fn appendHexBytes(allocator: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    for (bytes) |byte| {
        try out.print(allocator, "{x:0>2}", .{byte});
    }
}

fn appendEscapedMetadataValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    for (value) |ch| switch (ch) {
        '\\', '\n', '\r', '\t', ' ' => {
            try out.append(allocator, '\\');
            switch (ch) {
                '\\' => try out.append(allocator, '\\'),
                '\n' => try out.append(allocator, 'n'),
                '\r' => try out.append(allocator, 'r'),
                '\t' => try out.append(allocator, 't'),
                ' ' => try out.append(allocator, 's'),
                else => unreachable,
            }
        },
        else => try out.append(allocator, ch),
    };
}

const TestArch = enum {
    riscv64,
};

const TestProfile = enum {
    kernel,
    hosted,
};

const TestChecks = struct {
    optimize: bool = false,
    ksan: bool = false,
    msan: bool = false,
    csan: bool = false,
};

const TestLowerOptions = struct {
    profile: TestProfile,
    source_path: ?[]const u8,
    target_arch: TestArch = .riscv64,
    checks: TestChecks = .{},
    stub_asm: bool = false,
    source_sha256: ?Sha256Digest = null,
    compiler_version: ?[]const u8 = null,
    toolchain_identity: ?[]const u8 = null,
    linux_kernel: bool = false,
};

test "ArtifactBundle emits shared source-map provenance headers" {
    const source_digest = sha256Bytes("source");
    const bundle = ArtifactBundle.forSourceMap("artifact", "payload", "mir-facts", TestLowerOptions{
        .profile = .hosted,
        .source_path = "source.mc",
        .checks = .{ .optimize = true, .ksan = true },
        .stub_asm = true,
        .source_sha256 = source_digest,
        .compiler_version = "0.7.0 dev",
    });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendArtifactMetadata(std.testing.allocator, &out, bundle);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "# mcmeta v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "# artifact_kind=c-source-map\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "# backend=c\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "# generated_artifact_sha256=") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "# source_map_payload_sha256=") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "# mir_facts_sha256=") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "# source_sha256=") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "# compiler_version=0.7.0\\sdev\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "# target_arch=riscv64\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "# lower_profile=hosted\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "# lower_checks_optimize=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "# lower_checks_ksan=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "# lower_checks_msan=false\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "# lower_checks_csan=false\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "# lower_stub_asm=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "# lower_linux_kernel=false\n") != null);
}

test "ArtifactBundle shared writer preserves metadata and source-map magic" {
    const bundle = ArtifactBundle.forArtifact("artifact", TestLowerOptions{
        .profile = .kernel,
        .source_path = "source.mc",
        .compiler_version = "0.7.0-dev",
    }, .{
        .artifact_kind = "c",
        .backend_name = "c",
    });

    var sidecar: std.ArrayList(u8) = .empty;
    defer sidecar.deinit(std.testing.allocator);
    var explicit_sidecar: std.ArrayList(u8) = .empty;
    defer explicit_sidecar.deinit(std.testing.allocator);
    var source_map: std.ArrayList(u8) = .empty;
    defer source_map.deinit(std.testing.allocator);

    try appendArtifactMetadata(std.testing.allocator, &sidecar, bundle);
    try appendArtifactBundle(std.testing.allocator, &explicit_sidecar, bundle, .metadata_sidecar);
    try appendArtifactBundle(std.testing.allocator, &source_map, bundle, .source_map);

    try std.testing.expectEqualStrings(sidecar.items, explicit_sidecar.items);
    try std.testing.expect(std.mem.startsWith(u8, sidecar.items, "# mcmeta v1\n"));
    try std.testing.expect(std.mem.startsWith(u8, source_map.items, "# mcmap v1\n"));
    try std.testing.expect(std.mem.indexOf(u8, source_map.items, "# generated_artifact_sha256=") != null);
}
