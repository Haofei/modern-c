const std = @import("std");

const ast_bridge = @import("ast_bridge.zig");
const backend_mod = @import("backend.zig");
const diagnostics = @import("diagnostics.zig");
const declaration_artifacts = @import("declaration_artifacts.zig");
const mir = @import("mir.zig");
const lower_c_emitter = @import("lower_c_emitter.zig");
const lower_c_inspect = @import("lower_c_inspect.zig");
const lower_c_map = @import("lower_c_map.zig");
const lower_c_runtime = @import("lower_c_runtime.zig");

pub fn appendInspection(allocator: std.mem.Allocator, module: ast_bridge.Module, out: *std.ArrayList(u8)) anyerror!void {
    return lower_c_inspect.appendInspection(allocator, module, out);
}

// The target conformance profile is owned by the backend seam. `kernel` is
// freestanding-by-default and has no ambient I/O. `hosted` opts in to a host C
// runtime (libc/libm); it changes only the toolchain link step (link libc +
// `-lm`) — the generated C is the same shape, so emitting hosted code with no
// hosted features is harmless. The profile is stamped into the C as a marker so
// the toolchain driver and a reader can see which target was selected.
pub const Profile = backend_mod.Profile;

/// Construct the `Backend` registry entry for the C backend. The C backend is
/// profile-aware and supports source-map emission (`emit-map`).
pub fn mcBackend() backend_mod.Backend {
    return .{
        .name = "c",
        .artifact_ext = ".c",
        .supports_profiles = true,
        .ctx = null,
        .lowerFn = backendLower,
        .emitMapFn = backendEmitMap,
    };
}

fn backendLower(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    request: backend_mod.LowerRequest,
) backend_mod.LowerError!void {
    _ = ctx;
    return appendCProfileWithMirSourceSpelling(allocator, request.declaration_artifacts, request.program.typed_mir, request.program.source_spelling, request.out, request.opts.profile, request.opts.source_path, request.opts.checks, request.opts.stub_asm, request.opts.reporter) catch |err| backend_mod.lowerErrorFromAny(err);
}

fn backendEmitMap(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    request: backend_mod.EmitMapRequest,
) backend_mod.LowerError!void {
    _ = ctx;
    return appendCSourceMapFromGenerated(
        allocator,
        request.source_map_artifacts,
        request.out,
        request.generated_artifact,
        request.program.typed_mir,
        request.opts.source_path orelse "-",
        null,
        request.opts,
    ) catch |err| backend_mod.lowerErrorFromAny(err);
}

pub fn appendLayoutAssertsWithMirArtifacts(
    allocator: std.mem.Allocator,
    artifacts: declaration_artifacts.EarlyDeclarationArtifacts,
    typed_mir: *const mir.Module,
    out: *std.ArrayList(u8),
    struct_names: []const []const u8,
) anyerror!void {
    return lower_c_emitter.appendLayoutAsserts(allocator, artifacts, typed_mir, out, struct_names);
}

pub fn appendStructDeclsWithMirArtifacts(
    allocator: std.mem.Allocator,
    artifacts: declaration_artifacts.EarlyDeclarationArtifacts,
    typed_mir: *const mir.Module,
    out: *std.ArrayList(u8),
    struct_names: []const []const u8,
) anyerror!void {
    return lower_c_emitter.appendStructDecls(allocator, artifacts, typed_mir, out, struct_names);
}

pub fn appendCProfileWithMirArtifacts(
    allocator: std.mem.Allocator,
    artifacts: declaration_artifacts.EarlyDeclarationArtifacts,
    typed_mir: *const mir.Module,
    out: *std.ArrayList(u8),
    profile: Profile,
    source_path: ?[]const u8,
    checks: backend_mod.Checks,
    stub_asm: bool,
    reporter: ?*diagnostics.Reporter,
) anyerror!void {
    return appendCProfileWithMirSourceSpelling(allocator, artifacts, typed_mir, .{ .symbols = typed_mir.symbol_identities }, out, profile, source_path, checks, stub_asm, reporter);
}

fn appendCProfileWithMirSourceSpelling(
    allocator: std.mem.Allocator,
    early_metadata: declaration_artifacts.EarlyDeclarationArtifacts,
    typed_mir: *const mir.Module,
    source_spelling: backend_mod.SourceSpellingView,
    out: *std.ArrayList(u8),
    profile: Profile,
    source_path: ?[]const u8,
    checks: backend_mod.Checks,
    stub_asm: bool,
    reporter: ?*diagnostics.Reporter,
) anyerror!void {
    mir.validateLoweringAdmission(typed_mir.*) catch |err| switch (err) {
        error.StaleMirTargetTypeFacts => return error.UnsupportedCEmission,
        else => return err,
    };
    if (!source_spelling.validateAgainstMir(typed_mir.*)) return error.UnsupportedCEmission;
    const profile_marker = switch (profile) {
        .kernel => "/* mc-profile: kernel (freestanding) */\n",
        .hosted => "/* mc-profile: hosted (links libc + -lm) */\n",
    };
    try lower_c_runtime.appendHeaderAndSanitizerHooks(allocator, source_spelling, typed_mir.*, out, profile_marker);
    try lower_c_runtime.appendCheckedArithmeticHelpers(allocator, out);
    try lower_c_runtime.appendMemoryAccessHelpers(allocator, out, checks.ksan, checks.msan, checks.csan);

    try lower_c_emitter.appendModuleMir(
        allocator,
        early_metadata,
        typed_mir,
        out,
        source_path,
        checks.ksan,
        checks.msan,
        checks.csan,
        stub_asm,
        reporter,
    );
}

pub fn appendCSourceMapFromGenerated(
    allocator: std.mem.Allocator,
    source_map_artifacts: []const declaration_artifacts.SourceMapArtifact,
    out: *std.ArrayList(u8),
    generated_c: []const u8,
    typed_mir: *const mir.Module,
    source_path: []const u8,
    generated_c_path: ?[]const u8,
    opts: backend_mod.LowerOptions,
) anyerror!void {
    try lower_c_map.appendSourceMap(allocator, source_map_artifacts, out, generated_c, typed_mir, source_path, generated_c_path, opts);
}
