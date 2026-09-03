const std = @import("std");
const artifact_model = @import("artifact_model.zig");
const backend = @import("backend.zig");
const backend_registry = @import("backend_registry.zig");
const build_options = @import("build_options");
const compiler_session = @import("compiler_session.zig");
const diagnostics = @import("diagnostics.zig");
const driver_codegen_inputs = @import("driver_codegen_inputs.zig");
const mir = @import("mir.zig");

const CompilationSession = compiler_session.CompilationSession;
const max_artifact_metadata_bytes = compiler_session.max_artifact_metadata_bytes;

/// Build the hosted C artifact through Clang, then atomically publish the executable and
/// its metadata. Compiler checking and lowering remain in the shared session/codegen APIs;
/// this module owns only driver-level hosted toolchain orchestration.
pub fn runBuild(session: *CompilationSession, path: []const u8, artifact_source_path: []const u8, source: []const u8, target_arch: backend.TargetArch, output_path: []const u8, clang_bin: []const u8) !void {
    const allocator = session.allocator;
    const io = session.io;
    const source_sha256 = session.sourceDigest(source);
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const resolved = session.resolved_program orelse return error.MissingResolvedSources;
    try session.checkResolvedProgram(resolved.*, parse_allocator, &diag, false, error.BuildFailed);

    var module_mir: mir.Module = undefined;
    var early_metadata = driver_codegen_inputs.DeclarationArtifacts.empty;
    const program = try driver_codegen_inputs.buildBackendInputs(session, &diag, false, &module_mir, &early_metadata, error.BuildFailed);
    defer module_mir.deinit();
    defer early_metadata.deinit(allocator);

    var raw_c: std.ArrayList(u8) = .empty;
    defer raw_c.deinit(allocator);
    const be = backend_registry.byName("c").?;
    const lower_opts = backend.LowerOptions{
        .profile = .hosted,
        .source_path = artifact_source_path,
        .target_arch = target_arch,
        .reporter = &diag,
        .source_sha256 = source_sha256,
        .compiler_version = build_options.version,
    };
    be.lowerRequest(allocator, .{
        .program = program,
        .declaration_artifacts = early_metadata.codegen(),
        .out = &raw_c,
        .opts = lower_opts,
    }) catch |err| switch (err) {
        error.UnsupportedCEmission => {
            if (!diag.has_errors) reportBackendUnsupportedFallback(&diag, "C");
            diag.render();
            return error.BuildFailed;
        },
        else => return err,
    };

    var hosted_c: std.ArrayList(u8) = .empty;
    defer hosted_c.deinit(allocator);
    try appendHostedBuildWrapper(allocator, raw_c.items, &hosted_c, path);

    const tmp_c = try writeExclusiveBuildTemp(allocator, io, output_path, "c", hosted_c.items);
    defer allocator.free(tmp_c);
    defer std.Io.Dir.cwd().deleteFile(io, tmp_c) catch {};

    const tmp_exe = try reserveExclusiveBuildTemp(allocator, io, output_path, "out");
    defer allocator.free(tmp_exe);
    defer std.Io.Dir.cwd().deleteFile(io, tmp_exe) catch {};

    const argv = [_][]const u8{
        clang_bin,
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-fno-strict-aliasing",
        "-fno-delete-null-pointer-checks",
        "-fwrapv",
        tmp_c,
        "-lm",
        "-o",
        tmp_exe,
    };
    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .expand_arg0 = .expand,
    }) catch |err| {
        std.debug.print("mcc build: clang invocation failed: {s}\n", .{@errorName(err)});
        return error.BuildFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.stdout.len != 0) std.debug.print("{s}", .{result.stdout});
    const clang_ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!clang_ok) {
        if (result.stderr.len != 0) std.debug.print("{s}", .{result.stderr});
        std.debug.print("mcc build: clang failed while linking {s}\n", .{output_path});
        return error.BuildFailed;
    }

    const executable_bytes = std.Io.Dir.cwd().readFileAlloc(io, tmp_exe, allocator, .limited(max_artifact_metadata_bytes)) catch |err| {
        std.debug.print("mcc build: unable to read linked temporary executable {s}: {s}\n", .{ tmp_exe, @errorName(err) });
        return error.BuildFailed;
    };
    defer allocator.free(executable_bytes);
    const toolchain_identity = try clangToolchainIdentity(allocator, io, clang_bin);
    defer allocator.free(toolchain_identity);
    var bundle = artifact_model.ArtifactBundle.forArtifact(executable_bytes, lower_opts, .{
        .artifact_kind = "host-executable",
        .backend_name = "c",
        .toolchain_identity = toolchain_identity,
    });
    try attachCSourceMapDigests(allocator, be, program, early_metadata, raw_c.items, lower_opts, &bundle);
    session.publishExistingArtifactWithMetadata(tmp_exe, output_path, bundle, "executable") catch {
        return error.BuildFailed;
    };
    try session.writeStdout("mcc build: wrote ");
    try session.writeStdout(output_path);
    try session.writeStdout("\n");
}

pub fn attachCSourceMapDigests(
    allocator: std.mem.Allocator,
    be: backend.Backend,
    program: backend.VerifiedProgram,
    declaration_artifacts: driver_codegen_inputs.DeclarationArtifacts,
    generated_c: []const u8,
    lower_opts: backend.LowerOptions,
    bundle: *artifact_model.ArtifactBundle,
) !void {
    if (!be.supportsEmitMap()) return;
    var map_bytes: std.ArrayList(u8) = .empty;
    defer map_bytes.deinit(allocator);
    try be.emitMapRequest(allocator, .{
        .program = program,
        .source_map_artifacts = declaration_artifacts.source_map_artifacts,
        .out = &map_bytes,
        .generated_artifact = generated_c,
        .opts = lower_opts,
    });
    bundle.source_map_generated_artifact_sha256 = try metadataDigestHeader(map_bytes.items, "generated_artifact_sha256");
    bundle.source_map_payload_sha256 = try metadataDigestHeader(map_bytes.items, "source_map_payload_sha256");
    bundle.mir_facts_sha256 = try metadataDigestHeader(map_bytes.items, "mir_facts_sha256");
}

pub fn reportBackendUnsupportedFallback(diag: *diagnostics.Reporter, backend_name: []const u8) void {
    diag.err(.{ .offset = 0, .len = 1, .line = 1, .column = 1 }, "E_BACKEND_UNSUPPORTED: {s} backend does not yet support this construct", .{backend_name});
}

fn metadataDigestHeader(bytes: []const u8, name: []const u8) !artifact_model.Sha256Digest {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (!std.mem.startsWith(u8, line, "# ")) continue;
        const body = line[2..];
        const eq = std.mem.indexOfScalar(u8, body, '=') orelse continue;
        if (!std.mem.eql(u8, body[0..eq], name)) continue;
        const value = body[eq + 1 ..];
        if (value.len != 64) return error.InvalidArtifactMetadata;
        var digest: artifact_model.Sha256Digest = undefined;
        var index: usize = 0;
        while (index < digest.len) : (index += 1) {
            digest[index] = try std.fmt.parseInt(u8, value[index * 2 .. index * 2 + 2], 16);
        }
        return digest;
    }
    return error.InvalidArtifactMetadata;
}

fn buildTempPath(allocator: std.mem.Allocator, output_path: []const u8, suffix: []const u8, attempt: usize) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.mc-build-{d}-{d}-{d}.{s}", .{
        output_path,
        std.posix.system.getpid(),
        std.Thread.getCurrentId(),
        attempt,
        suffix,
    });
}

fn isExistingPathError(err: anyerror) bool {
    const name = @errorName(err);
    return std.mem.eql(u8, name, "PathAlreadyExists") or
        std.mem.eql(u8, name, "FileAlreadyExists");
}

fn reserveExclusiveBuildTemp(allocator: std.mem.Allocator, io: std.Io, output_path: []const u8, suffix: []const u8) ![]const u8 {
    for (0..64) |attempt| {
        const path = try buildTempPath(allocator, output_path, suffix, attempt);
        var file = std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |err| {
            if (isExistingPathError(err)) {
                allocator.free(path);
                continue;
            }
            std.debug.print("mcc build: unable to reserve temporary {s} artifact {s}: {s}\n", .{ suffix, path, @errorName(err) });
            allocator.free(path);
            return error.BuildFailed;
        };
        file.close(io);
        return path;
    }
    std.debug.print("mcc build: unable to reserve unique temporary {s} artifact for {s}\n", .{ suffix, output_path });
    return error.BuildFailed;
}

fn writeExclusiveBuildTemp(allocator: std.mem.Allocator, io: std.Io, output_path: []const u8, suffix: []const u8, bytes: []const u8) ![]const u8 {
    for (0..64) |attempt| {
        const path = try buildTempPath(allocator, output_path, suffix, attempt);
        var file = std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |err| {
            if (isExistingPathError(err)) {
                allocator.free(path);
                continue;
            }
            std.debug.print("mcc build: unable to reserve temporary {s} artifact {s}: {s}\n", .{ suffix, path, @errorName(err) });
            allocator.free(path);
            return error.BuildFailed;
        };
        file.writeStreamingAll(io, bytes) catch |err| {
            file.close(io);
            std.Io.Dir.cwd().deleteFile(io, path) catch {};
            std.debug.print("mcc build: unable to write temporary {s}: {s}\n", .{ path, @errorName(err) });
            allocator.free(path);
            return error.BuildFailed;
        };
        file.close(io);
        return path;
    }
    std.debug.print("mcc build: unable to reserve unique temporary {s} artifact for {s}\n", .{ suffix, output_path });
    return error.BuildFailed;
}

fn clangToolchainIdentity(allocator: std.mem.Allocator, io: std.Io, clang_bin: []const u8) ![]const u8 {
    const fallback = struct {
        fn make(a: std.mem.Allocator, bin: []const u8) ![]const u8 {
            return std.fmt.allocPrint(a, "clang={s}", .{bin});
        }
    }.make;

    const digest_identity = try clangExecutableDigestIdentity(allocator, io, clang_bin);
    defer if (digest_identity) |identity| allocator.free(identity);

    const argv = [_][]const u8{ clang_bin, "--version" };
    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .expand_arg0 = .expand,
    }) catch {
        return fallback(allocator, clang_bin);
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok or result.stdout.len == 0) return fallback(allocator, clang_bin);

    const first_line_end = std.mem.indexOfScalar(u8, result.stdout, '\n') orelse result.stdout.len;
    const first_line = std.mem.trim(u8, result.stdout[0..first_line_end], "\r\n\t ");
    if (first_line.len == 0) return fallback(allocator, clang_bin);
    if (digest_identity) |identity| {
        return std.fmt.allocPrint(allocator, "clang={s};{s};version={s}", .{ clang_bin, identity, first_line });
    }
    return std.fmt.allocPrint(allocator, "clang={s};version={s}", .{ clang_bin, first_line });
}

fn clangExecutableDigestIdentity(allocator: std.mem.Allocator, io: std.Io, clang_bin: []const u8) !?[]const u8 {
    if (hasPathSeparator(clang_bin)) {
        const path = try resolveExplicitToolPath(allocator, io, clang_bin);
        defer allocator.free(path);
        return try toolDigestIdentityForPath(allocator, io, path);
    }

    const raw_path = std.c.getenv("PATH") orelse return null;
    var entries = std.mem.splitScalar(u8, std.mem.span(raw_path), std.fs.path.delimiter);
    while (entries.next()) |entry| {
        if (entry.len == 0) continue;
        const candidate = try std.fs.path.join(allocator, &.{ entry, clang_bin });
        defer allocator.free(candidate);
        if (try toolDigestIdentityForPath(allocator, io, candidate)) |identity| return identity;
    }
    return null;
}

fn hasPathSeparator(path: []const u8) bool {
    return std.mem.indexOfScalar(u8, path, '/') != null or
        std.mem.indexOfScalar(u8, path, '\\') != null;
}

fn resolveExplicitToolPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return try allocator.dupe(u8, path);

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try std.Io.Dir.cwd().realPathFile(io, ".", &cwd_buffer);
    return std.fs.path.join(allocator, &.{ cwd_buffer[0..cwd_len], path });
}

fn toolDigestIdentityForPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]const u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_artifact_metadata_bytes)) catch return null;
    defer allocator.free(bytes);
    const digest = artifact_model.sha256Bytes(bytes);
    const digest_hex = try allocHexDigest(allocator, digest);
    defer allocator.free(digest_hex);
    const identity = try std.fmt.allocPrint(allocator, "path={s};sha256={s}", .{ path, digest_hex });
    return identity;
}

fn allocHexDigest(allocator: std.mem.Allocator, digest: artifact_model.Sha256Digest) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (digest) |byte| {
        try out.print(allocator, "{x:0>2}", .{byte});
    }
    return out.toOwnedSlice(allocator);
}

fn appendHostedBuildWrapper(allocator: std.mem.Allocator, raw_c: []const u8, out: *std.ArrayList(u8), source_path: []const u8) !void {
    const entry_ret = findHostedMainReturnType(raw_c) orelse {
        std.debug.print("mcc build: expected exported no-argument main() entry point in {s}\n", .{source_path});
        return error.BuildFailed;
    };

    var lines = std.mem.splitScalar(u8, raw_c, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (cMainReturnTypeForSuffix(line, " main(void);")) |ret| {
            try out.appendSlice(allocator, ret);
            try out.appendSlice(allocator, " mc_user_main(void);");
        } else if (cMainReturnTypeForSuffix(line, " main(void) {")) |ret| {
            try out.appendSlice(allocator, ret);
            try out.appendSlice(allocator, " mc_user_main(void) {");
        } else {
            try out.appendSlice(allocator, raw_line);
        }
        try out.append(allocator, '\n');
    }
    try out.appendSlice(allocator, "\nint main(void) {\n");
    if (std.mem.eql(u8, entry_ret, "void")) {
        try out.appendSlice(allocator, "    mc_user_main();\n    return 0;\n");
    } else {
        try out.appendSlice(allocator, "    return (int)mc_user_main();\n");
    }
    try out.appendSlice(allocator, "}\n");
}

fn findHostedMainReturnType(raw_c: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, raw_c, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (cMainReturnTypeForSuffix(line, " main(void);")) |ret| return ret;
    }
    return null;
}

fn cMainReturnTypeForSuffix(line: []const u8, suffix: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, line, suffix)) return null;
    const ret = line[0 .. line.len - suffix.len];
    if (!isCIdentifier(ret)) return null;
    return ret;
}

fn isCIdentifier(text: []const u8) bool {
    if (text.len == 0) return false;
    if (!isCIdentifierStart(text[0])) return false;
    for (text[1..]) |ch| {
        if (!isCIdentifierContinue(ch)) return false;
    }
    return true;
}

fn isCIdentifierStart(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or ch == '_';
}

fn isCIdentifierContinue(ch: u8) bool {
    return isCIdentifierStart(ch) or (ch >= '0' and ch <= '9');
}

test "hosted wrapper renames only the user entry point" {
    const allocator = std.testing.allocator;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    try appendHostedBuildWrapper(
        allocator,
        "int main(void);\nint main(void) {\n    return 7;\n}\n",
        &output,
        "test.mc",
    );

    try std.testing.expectEqualStrings(
        "int mc_user_main(void);\nint mc_user_main(void) {\n    return 7;\n}\n\n\nint main(void) {\n    return (int)mc_user_main();\n}\n",
        output.items,
    );
}

test "hosted wrapper rejects missing no-argument entry point" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.BuildFailed,
        appendHostedBuildWrapper(std.testing.allocator, "int other(void);\n", &output, "test.mc"),
    );
}
