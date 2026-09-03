//! CLI code-generation and layout-inspection commands.
//!
//! This is a thin driver layer over `CompilationSession` and the existing
//! codegen-input/artifact-publishing APIs. It does not own compiler semantics.
const std = @import("std");
const artifact_model = @import("artifact_model.zig");
const backend = @import("backend.zig");
const backend_registry = @import("backend_registry.zig");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const compiler_session = @import("compiler_session.zig");
const driver_build = @import("driver_build.zig");
const driver_codegen_inputs = @import("driver_codegen_inputs.zig");
const lower_c = @import("lower_c.zig");
const mir = @import("mir.zig");

const CompilationSession = compiler_session.CompilationSession;

pub fn artifactSourcePath(allocator: std.mem.Allocator, io: std.Io, options: cli.Options, path: []const u8) !?[]const u8 {
    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = if (std.Io.Dir.cwd().realPathFile(io, ".", &cwd_buffer)) |cwd_len|
        cwd_buffer[0..cwd_len]
    else |_|
        null;
    return options.artifactSourcePath(allocator, path, cwd);
}

pub fn runLowerC(session: *CompilationSession, path: []const u8, source: []const u8) !void {
    const allocator = session.allocator;
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const resolved = session.resolved_program orelse return error.MissingResolvedSources;
    try session.checkResolvedProgram(resolved.*, parse_allocator, &diag, false, error.LowerCFailed);
    const decls = try resolved.astDecls(parse_allocator);
    defer parse_allocator.free(decls);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try lower_c.appendInspectionFromDecls(allocator, decls, &output);
    try session.writeStdout(output.items);
}

pub fn runEmitC(session: *CompilationSession, path: []const u8, artifact_source_path: []const u8, source: []const u8, profile: backend.Profile, checks: backend.Checks, stub_asm: bool, target_arch: backend.TargetArch, output_path: ?[]const u8) !void {
    const allocator = session.allocator;
    const optimize = checks.optimize;
    const source_sha256 = session.sourceDigest(source);
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const resolved = session.resolved_program orelse return error.MissingResolvedSources;
    try session.checkResolvedProgram(resolved.*, parse_allocator, &diag, optimize, error.EmitCFailed);

    var module_mir: mir.Module = undefined;
    var early_metadata = driver_codegen_inputs.DeclarationArtifacts.empty;
    const program = try driver_codegen_inputs.buildBackendInputs(session, &diag, optimize, &module_mir, &early_metadata, error.EmitCFailed);
    defer module_mir.deinit();
    defer early_metadata.deinit(allocator);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    const be = backend_registry.byName("c").?;
    const lower_opts = backend.LowerOptions{
        .profile = profile,
        .source_path = artifact_source_path,
        .target_arch = target_arch,
        .checks = checks,
        .stub_asm = stub_asm,
        .reporter = &diag,
        .source_sha256 = source_sha256,
        .compiler_version = build_options.version,
    };
    be.lowerRequest(allocator, .{
        .program = program,
        .declaration_artifacts = early_metadata.codegen(),
        .out = &output,
        .opts = lower_opts,
    }) catch |err| switch (err) {
        error.UnsupportedCEmission => {
            if (!diag.has_errors) driver_build.reportBackendUnsupportedFallback(&diag, "C");
            diag.render();
            return error.EmitCFailed;
        },
        else => return err,
    };
    var bundle = artifact_model.ArtifactBundle.forArtifact(output.items, lower_opts, .{
        .artifact_kind = "c",
        .backend_name = "c",
    });
    try driver_build.attachCSourceMapDigests(allocator, be, program, early_metadata, output.items, lower_opts, &bundle);
    try session.writeArtifactWithMetadata(output.items, output_path, bundle);
}

pub fn runEmitMap(session: *CompilationSession, path: []const u8, artifact_source_path: []const u8, source: []const u8, profile: backend.Profile, checks: backend.Checks, stub_asm: bool, target_arch: backend.TargetArch, output_path: ?[]const u8) !void {
    const allocator = session.allocator;
    const optimize = checks.optimize;
    const source_sha256 = session.sourceDigest(source);
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const resolved = session.resolved_program orelse return error.MissingResolvedSources;
    try session.checkResolvedProgram(resolved.*, parse_allocator, &diag, optimize, error.EmitCFailed);

    var module_mir: mir.Module = undefined;
    var early_metadata = driver_codegen_inputs.DeclarationArtifacts.empty;
    const program = try driver_codegen_inputs.buildBackendInputs(session, &diag, optimize, &module_mir, &early_metadata, error.EmitCFailed);
    defer module_mir.deinit();
    defer early_metadata.deinit(allocator);

    const be = backend_registry.byName("c").?;
    var generated_c: std.ArrayList(u8) = .empty;
    defer generated_c.deinit(allocator);
    const lower_opts = backend.LowerOptions{
        .profile = profile,
        .source_path = artifact_source_path,
        .target_arch = target_arch,
        .checks = checks,
        .stub_asm = stub_asm,
        .reporter = &diag,
        .source_sha256 = source_sha256,
        .compiler_version = build_options.version,
    };
    be.lowerRequest(allocator, .{
        .program = program,
        .declaration_artifacts = early_metadata.codegen(),
        .out = &generated_c,
        .opts = lower_opts,
    }) catch |err| switch (err) {
        error.UnsupportedCEmission => {
            if (!diag.has_errors) driver_build.reportBackendUnsupportedFallback(&diag, "C");
            diag.render();
            return error.EmitCFailed;
        },
        else => return err,
    };

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try be.emitMapRequest(allocator, .{
        .program = program,
        .source_map_artifacts = early_metadata.source_map_artifacts,
        .out = &output,
        .generated_artifact = generated_c.items,
        .opts = lower_opts,
    });
    try session.writeArtifact(output.items, output_path);
}

pub fn runEmitLlvm(session: *CompilationSession, path: []const u8, artifact_source_path: []const u8, source: []const u8, checks: backend.Checks, stub_asm: bool, target_arch: backend.TargetArch, linux_kernel: bool, output_path: ?[]const u8) !void {
    const allocator = session.allocator;
    const optimize = checks.optimize;
    const source_sha256 = session.sourceDigest(source);
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const resolved = session.resolved_program orelse return error.MissingResolvedSources;
    try session.checkResolvedProgram(resolved.*, parse_allocator, &diag, optimize, error.EmitLlvmFailed);

    var module_mir: mir.Module = undefined;
    var early_metadata = driver_codegen_inputs.DeclarationArtifacts.empty;
    const program = try driver_codegen_inputs.buildBackendInputs(session, &diag, optimize, &module_mir, &early_metadata, error.EmitLlvmFailed);
    defer module_mir.deinit();
    defer early_metadata.deinit(allocator);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    const be = backend_registry.byName("llvm").?;
    const lower_opts = backend.LowerOptions{
        .profile = .kernel,
        .source_path = artifact_source_path,
        .target_arch = target_arch,
        .checks = checks,
        .stub_asm = stub_asm,
        .reporter = &diag,
        .linux_kernel = linux_kernel,
        .source_sha256 = source_sha256,
        .compiler_version = build_options.version,
    };
    be.lowerRequest(allocator, .{
        .program = program,
        .declaration_artifacts = early_metadata.codegen(),
        .out = &output,
        .opts = lower_opts,
    }) catch |err| switch (err) {
        error.UnsupportedLlvmEmission => {
            if (!diag.has_errors) driver_build.reportBackendUnsupportedFallback(&diag, "LLVM");
            diag.render();
            return error.EmitLlvmFailed;
        },
        else => return err,
    };
    const bundle = artifact_model.ArtifactBundle.forArtifact(output.items, lower_opts, .{
        .artifact_kind = "llvm-ir",
        .backend_name = "llvm",
    });
    try session.writeArtifactWithMetadata(output.items, output_path, bundle);
}

pub fn runEmitLayout(session: *CompilationSession, path: []const u8, source: []const u8, structs_csv: []const u8, usage: []const u8) !void {
    const allocator = session.allocator;
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const resolved = session.resolved_program orelse return error.MissingResolvedSources;
    try session.checkResolvedProgram(resolved.*, parse_allocator, &diag, false, error.EmitLayoutFailed);
    var names = try parseStructNames(allocator, structs_csv, usage);
    defer names.deinit(allocator);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var typed_mir: mir.Module = undefined;
    var artifacts = driver_codegen_inputs.DeclarationArtifacts.empty;
    try driver_codegen_inputs.buildCArtifactInputs(session, &typed_mir, &artifacts);
    defer typed_mir.deinit();
    defer artifacts.deinit(allocator);
    lower_c.appendLayoutAssertsWithMirArtifacts(allocator, artifacts.codegen(), &typed_mir, &output, names.items) catch |err| switch (err) {
        error.LayoutStructNotFound => {
            std.debug.print("emit-layout: a struct named in --structs= was not found in {s}\n", .{path});
            return error.EmitLayoutFailed;
        },
        error.LayoutUnresolved => {
            std.debug.print("emit-layout: could not resolve a struct's layout in {s}\n", .{path});
            return error.EmitLayoutFailed;
        },
        else => return err,
    };
    try session.writeStdout(output.items);
}

pub fn runEmitCStruct(session: *CompilationSession, path: []const u8, source: []const u8, structs_csv: []const u8, usage: []const u8) !void {
    const allocator = session.allocator;
    var diag = session.initReporter(path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const resolved = session.resolved_program orelse return error.MissingResolvedSources;
    try session.checkResolvedProgram(resolved.*, parse_allocator, &diag, false, error.EmitCStructFailed);
    var names = try parseStructNames(allocator, structs_csv, usage);
    defer names.deinit(allocator);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var typed_mir: mir.Module = undefined;
    var artifacts = driver_codegen_inputs.DeclarationArtifacts.empty;
    try driver_codegen_inputs.buildCArtifactInputs(session, &typed_mir, &artifacts);
    defer typed_mir.deinit();
    defer artifacts.deinit(allocator);
    lower_c.appendStructDeclsWithMirArtifacts(allocator, artifacts.codegen(), &typed_mir, &output, names.items) catch |err| switch (err) {
        error.LayoutStructNotFound => {
            std.debug.print("emit-c-struct: a struct named in --structs= was not found in {s}\n", .{path});
            return error.EmitCStructFailed;
        },
        error.LayoutUnresolved => {
            std.debug.print("emit-c-struct: could not resolve a struct's layout in {s}\n", .{path});
            return error.EmitCStructFailed;
        },
        else => return err,
    };
    try session.writeStdout(output.items);
}

fn parseStructNames(allocator: std.mem.Allocator, structs_csv: []const u8, usage: []const u8) !std.ArrayList([]const u8) {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(allocator);
    var it = std.mem.splitScalar(u8, structs_csv, ',');
    while (it.next()) |name| {
        if (name.len != 0) try names.append(allocator, name);
    }
    if (names.items.len == 0) {
        std.debug.print("{s}", .{usage});
        return error.InvalidArgs;
    }
    return names;
}
