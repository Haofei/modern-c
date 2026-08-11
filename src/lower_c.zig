const std = @import("std");

const ast = @import("ast.zig");
const backend_mod = @import("backend.zig");
const diagnostics = @import("diagnostics.zig");
const mir = @import("mir.zig");
const lower_c_emitter = @import("lower_c_emitter.zig");
const lower_c_inspect = @import("lower_c_inspect.zig");
const lower_c_map = @import("lower_c_map.zig");
const lower_c_runtime = @import("lower_c_runtime.zig");

pub fn appendInspection(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8)) anyerror!void {
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
    program: backend_mod.VerifiedProgram,
    declarations: backend_mod.LegacyDeclarationSlice,
    out: *std.ArrayList(u8),
    opts: backend_mod.LowerOptions,
) backend_mod.LowerError!void {
    _ = ctx;
    return appendCProfileWithMirSourceSpelling(allocator, declarations, program.typed_mir, program.source_spelling, out, opts.profile, opts.source_path, opts.checks, opts.stub_asm, opts.reporter) catch |err| backend_mod.lowerErrorFromAny(err);
}

fn backendEmitMap(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    program: backend_mod.VerifiedProgram,
    source_map: backend_mod.SourceMapMechanicsView,
    out: *std.ArrayList(u8),
    generated_artifact: []const u8,
    opts: backend_mod.LowerOptions,
) backend_mod.LowerError!void {
    _ = ctx;
    return appendCSourceMapFromGenerated(
        allocator,
        source_map,
        out,
        generated_artifact,
        program.typed_mir,
        opts.source_path orelse "-",
        null,
        opts,
    ) catch |err| backend_mod.lowerErrorFromAny(err);
}

pub fn appendC(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8)) anyerror!void {
    return appendCProfile(allocator, module, out, .kernel);
}

/// Emit a generated C header asserting MC's authoritative layout for the named structs.
pub fn appendLayoutAsserts(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8), struct_names: []const []const u8) anyerror!void {
    return lower_c_emitter.appendLayoutAsserts(allocator, module, out, struct_names);
}

/// Emit the GENERATED C struct *definitions* for the named structs (A2: single source of truth).
pub fn appendStructDecls(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8), struct_names: []const []const u8) anyerror!void {
    return lower_c_emitter.appendStructDecls(allocator, module, out, struct_names);
}

pub fn appendCProfile(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8), profile: Profile) anyerror!void {
    return appendCProfileWithSourcePath(allocator, module, out, profile, null, .{}, false);
}

pub fn appendCProfileWithSourcePath(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8), profile: Profile, source_path: ?[]const u8, checks: backend_mod.Checks, stub_asm: bool) anyerror!void {
    return appendCProfileWithOptions(allocator, module, out, profile, source_path, checks, stub_asm, null);
}

fn appendCProfileWithOptions(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8), profile: Profile, source_path: ?[]const u8, checks: backend_mod.Checks, stub_asm: bool, reporter: ?*diagnostics.Reporter) anyerror!void {
    var typed_mir = try mir.buildOpt(allocator, module, .{ .optimize = checks.optimize });
    defer typed_mir.deinit();
    try appendCProfileWithMir(allocator, module, &typed_mir, out, profile, source_path, checks, stub_asm, reporter);
}

pub fn appendCProfileWithMir(allocator: std.mem.Allocator, module: ast.Module, typed_mir: *const mir.Module, out: *std.ArrayList(u8), profile: Profile, source_path: ?[]const u8, checks: backend_mod.Checks, stub_asm: bool, reporter: ?*diagnostics.Reporter) anyerror!void {
    return appendCProfileWithMirSourceSpelling(allocator, backend_mod.LegacyDeclarationSlice.forDecls(module.decls), typed_mir, .{ .symbols = typed_mir.symbol_identities }, out, profile, source_path, checks, stub_asm, reporter);
}

fn appendCProfileWithMirSourceSpelling(
    allocator: std.mem.Allocator,
    declarations: backend_mod.LegacyDeclarationSlice,
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
        declarations,
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

pub fn appendCSourceMap(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8), profile: Profile, source_path: []const u8, generated_c_path: ?[]const u8) anyerror!void {
    var generated_c: std.ArrayList(u8) = .empty;
    defer generated_c.deinit(allocator);
    try appendCProfileWithSourcePath(allocator, module, &generated_c, profile, source_path, .{}, false);

    var typed_mir = try mir.build(allocator, module);
    defer typed_mir.deinit();

    try appendCSourceMapFromGenerated(allocator, backend_mod.SourceMapMechanicsView.forDecls(module.decls), out, generated_c.items, &typed_mir, source_path, generated_c_path, .{
        .profile = profile,
        .source_path = source_path,
    });
}

pub fn appendCSourceMapFromGenerated(
    allocator: std.mem.Allocator,
    source_map_view: backend_mod.SourceMapMechanicsView,
    out: *std.ArrayList(u8),
    generated_c: []const u8,
    typed_mir: *const mir.Module,
    source_path: []const u8,
    generated_c_path: ?[]const u8,
    opts: backend_mod.LowerOptions,
) anyerror!void {
    try lower_c_map.appendSourceMap(allocator, source_map_view, out, generated_c, typed_mir, source_path, generated_c_path, opts);
}
