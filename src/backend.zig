const std = @import("std");

const codegen_options = @import("codegen_options.zig");
const legacy_backend_syntax = @import("legacy_backend_syntax.zig");
const lower_error = @import("lower_error.zig");
const verified_program = @import("verified_program.zig");

pub const Profile = codegen_options.Profile;
pub const Checks = codegen_options.Checks;
pub const TargetArch = codegen_options.TargetArch;
pub const LowerOptions = codegen_options.LowerOptions;
pub const targetArchFromName = codegen_options.targetArchFromName;

pub const LowerError = lower_error.LowerError;
pub const lowerErrorFromAny = lower_error.lowerErrorFromAny;
pub const SourceSpellingView = verified_program.SourceSpellingView;
pub const LegacyDeclarationSlice = legacy_backend_syntax.LegacyDeclarationSlice;
pub const SourceMapMechanicsView = legacy_backend_syntax.SourceMapMechanicsView;
pub const VerifiedProgram = verified_program.VerifiedProgram;

/// A code-generation backend: the seam at which `main.zig` selects a target and
/// invokes lowering. This is the *entry* abstraction — it routes backend
/// selection and the top-level `module -> textual artifact` call through one
/// vtable. Per-construct emission (statements, expressions, types) is still
/// implemented privately inside each backend module; this interface does not
/// unify that.
///
/// Concrete backend constructors are registered in `backend_registry.zig`, the
/// composition root for built-in lowerers. This interface module deliberately
/// does not import concrete C/LLVM lowering implementations.
pub const Backend = struct {
    /// Stable identifier used for CLI selection and the registry ("c", "llvm").
    name: []const u8,
    /// Conventional file extension for the emitted artifact (".c", ".ll").
    artifact_ext: []const u8,
    /// True if the backend acts on `LowerOptions.profile`. The C backend has
    /// kernel/hosted profiles; the LLVM backend does not.
    supports_profiles: bool,
    /// Opaque per-backend state pointer. Built-in backends are stateless and
    /// pass null; the field exists so a stateful backend can carry
    /// context without changing the interface.
    ctx: ?*anyopaque,
    /// Top-level lowering: append the textual artifact for `module` to `out`.
    lowerFn: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        program: VerifiedProgram,
        declarations: LegacyDeclarationSlice,
        out: *std.ArrayList(u8),
        opts: LowerOptions,
    ) LowerError!void,
    /// Optional source-map emission ("emit-map"). Only the C backend supplies
    /// this; null means the backend has no source-map artifact. The map is
    /// emitted from the same verified program and generated artifact as the
    /// codegen request, so map metadata cannot silently drift from lowering
    /// options such as checks/profile/stub-asm.
    emitMapFn: ?*const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        program: VerifiedProgram,
        source_map: SourceMapMechanicsView,
        out: *std.ArrayList(u8),
        generated_artifact: []const u8,
        opts: LowerOptions,
    ) LowerError!void = null,

    /// Lower `module` to its textual artifact via the backend's vtable.
    pub fn lower(
        self: Backend,
        allocator: std.mem.Allocator,
        program: VerifiedProgram,
        declarations: LegacyDeclarationSlice,
        out: *std.ArrayList(u8),
        opts: LowerOptions,
    ) LowerError!void {
        return self.lowerFn(self.ctx, allocator, program, declarations, out, opts);
    }

    /// Whether this backend can emit a source map (i.e. `emitMapFn != null`).
    pub fn supportsEmitMap(self: Backend) bool {
        return self.emitMapFn != null;
    }

    /// Emit a source map. Asserts the backend supports it (`supportsEmitMap`).
    pub fn emitMap(
        self: Backend,
        allocator: std.mem.Allocator,
        program: VerifiedProgram,
        source_map: SourceMapMechanicsView,
        out: *std.ArrayList(u8),
        generated_artifact: []const u8,
        opts: LowerOptions,
    ) LowerError!void {
        return self.emitMapFn.?(self.ctx, allocator, program, source_map, out, generated_artifact, opts);
    }
};

test "backend interface does not import concrete lowerers" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/backend.zig", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "@import(\"lower_c.zig\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "@import(\"lower_llvm.zig\")") == null);
}
