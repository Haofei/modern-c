const std = @import("std");

const ast = @import("ast.zig");
const lower_c = @import("lower_c.zig");
const lower_llvm = @import("lower_llvm.zig");

/// Code-generation profile. Re-exported from `lower_c.zig`, which owns the
/// definition (`kernel`/`hosted`). Only profile-aware backends (currently the C
/// backend) act on it; profile-agnostic backends ignore it.
pub const Profile = lower_c.Profile;

/// Options threaded from the CLI into a backend's lowering entry point. This is
/// the union of everything any built-in backend needs; a given backend reads
/// only the subset it supports (e.g. the LLVM backend ignores `profile`).
pub const LowerOptions = struct {
    /// Code-gen profile. Honored when `Backend.supports_profiles` is true.
    profile: Profile,
    /// Whether optimization-dependent lowering is enabled (mir.buildOpt).
    optimize: bool,
    /// Source path embedded in #line / !DILocation metadata; null means the
    /// backend picks its own default.
    source_path: ?[]const u8,
};

/// A code-generation backend: the seam at which `main.zig` selects a target and
/// invokes lowering. This is the *entry* abstraction — it routes backend
/// selection and the top-level `module -> textual artifact` call through one
/// vtable. Per-construct emission (statements, expressions, types) is still
/// implemented privately inside each backend module; this interface does not
/// unify that.
///
/// To add a native MC backend: create `src/lower_<name>.zig`, implement a
/// `lowerFn` (module -> output bytes), expose a `pub fn mcBackend() Backend`
/// constructor, and register it in `builtins` below. See
/// `docs/backend-abstraction.md`.
pub const Backend = struct {
    /// Stable identifier used for CLI selection and the registry ("c", "llvm").
    name: []const u8,
    /// Conventional file extension for the emitted artifact (".c", ".ll").
    artifact_ext: []const u8,
    /// True if the backend acts on `LowerOptions.profile`. The C backend has
    /// kernel/hosted profiles; the LLVM backend does not.
    supports_profiles: bool,
    /// Opaque per-backend state pointer. Built-in backends are stateless and
    /// pass `undefined`; the field exists so a stateful backend can carry
    /// context without changing the interface.
    ctx: *anyopaque,
    /// Top-level lowering: append the textual artifact for `module` to `out`.
    lowerFn: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        module: ast.Module,
        out: *std.ArrayList(u8),
        opts: LowerOptions,
    ) anyerror!void,
    /// Optional source-map emission ("emit-map"). Only the C backend supplies
    /// this; null means the backend has no source-map artifact. Signature
    /// mirrors `lower_c.appendCSourceMap`.
    emitMapFn: ?*const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        module: ast.Module,
        out: *std.ArrayList(u8),
        profile: Profile,
        source_path: []const u8,
    ) anyerror!void = null,

    /// Lower `module` to its textual artifact via the backend's vtable.
    pub fn lower(
        self: Backend,
        allocator: std.mem.Allocator,
        module: ast.Module,
        out: *std.ArrayList(u8),
        opts: LowerOptions,
    ) anyerror!void {
        return self.lowerFn(self.ctx, allocator, module, out, opts);
    }

    /// Whether this backend can emit a source map (i.e. `emitMapFn != null`).
    pub fn supportsEmitMap(self: Backend) bool {
        return self.emitMapFn != null;
    }

    /// Emit a source map. Asserts the backend supports it (`supportsEmitMap`).
    pub fn emitMap(
        self: Backend,
        allocator: std.mem.Allocator,
        module: ast.Module,
        out: *std.ArrayList(u8),
        profile: Profile,
        source_path: []const u8,
    ) anyerror!void {
        return self.emitMapFn.?(self.ctx, allocator, module, out, profile, source_path);
    }
};

/// Registry of built-in backends. Adding a backend means adding its constructor
/// here.
fn builtins() [2]Backend {
    return .{ lower_c.mcBackend(), lower_llvm.mcBackend() };
}

/// All registered built-in backends.
pub fn all() [2]Backend {
    return builtins();
}

/// Look up a backend by its CLI name ("c"/"llvm"); null if unknown.
pub fn byName(name: []const u8) ?Backend {
    for (builtins()) |b| {
        if (std.mem.eql(u8, b.name, name)) return b;
    }
    return null;
}
