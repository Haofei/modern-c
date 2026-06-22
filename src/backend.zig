const std = @import("std");

const ast = @import("ast.zig");
const lower_c = @import("lower_c.zig");
const lower_llvm = @import("lower_llvm.zig");

/// Code-generation profile. Re-exported from `lower_c.zig`, which owns the
/// definition (`kernel`/`hosted`). Only profile-aware backends (currently the C
/// backend) act on it; profile-agnostic backends ignore it.
pub const Profile = lower_c.Profile;

/// The sanitizer/build-safety instrumentation axis (the `--checks=` profiles),
/// bundled into one value so it can be threaded as a unit instead of as four
/// loose, positionally-dropped bools. Backends that don't instrument ignore it.
///
/// `ksan`/`msan`/`csan` are NOT independently combinable: msan implies ksan
/// (shares the shadow), and csan is mutually exclusive with ksan/msan (a single
/// raw.load/raw.store wraps exactly one shadow protocol). `main.zig` enforces
/// the legal combinations at flag-parse time; the emitters assume a legal value.
pub const Checks = struct {
    /// Whether optimization-dependent lowering is enabled (mir.buildOpt): the
    /// RELEASE build (`--checks=elide-proven`) vs the SAFE default (`--checks=all`).
    optimize: bool = false,
    /// KASAN profile (D2.1): instrumented memory accesses (raw.load / raw.store)
    /// emit a shadow-memory check (`mc_ksan_check`) that traps on a poisoned access.
    ksan: bool = false,
    /// KMSAN profile (D2.2, implies `ksan`): raw.store additionally calls
    /// `mc_ksan_store` to mark the written bytes initialized in the shadow, and the
    /// msan runtime makes `mc_ksan_check` trap on a load of still-uninitialized heap
    /// bytes.
    msan: bool = false,
    /// KCSAN profile (D2.3): instrumented memory accesses emit a data-race watchpoint
    /// hook (`mc_csan_read` / `mc_csan_write`) on the shadow that flags a conflicting
    /// concurrent access (one a write) to the same location without synchronization.
    /// The `mc_race_*` synchronized accessors stay plain relaxed atomics (no
    /// watchpoint) — the properly-synchronized path is clean.
    csan: bool = false,
};

/// Options threaded from the CLI into a backend's lowering entry point. This is
/// the union of everything any built-in backend needs; a given backend reads
/// only the subset it supports (e.g. the LLVM backend ignores `profile`).
pub const LowerOptions = struct {
    /// Code-gen profile. Honored when `Backend.supports_profiles` is true.
    profile: Profile,
    /// Source path embedded in #line / !DILocation metadata; null means the
    /// backend picks its own default.
    source_path: ?[]const u8,
    /// The `--checks=` instrumentation axis (optimize + the ksan/msan/csan
    /// sanitizer profiles), threaded as one value rather than four loose bools.
    checks: Checks = .{},
    /// `--stub-asm` (test-only): lower every inline-`asm`/`asm precise` block to a
    /// semantically-neutral host stub (a compiler memory barrier for opaque asm;
    /// consume-inputs/zero-outputs for precise asm) instead of the real
    /// instruction(s). This lets an arch module's PORTABLE logic be compiled and
    /// run host-natively (where the host assembler cannot encode the target ISA's
    /// mnemonics) without the arch asm. OFF by default, so kernel/bare-metal builds
    /// are byte-for-byte unchanged; only host-native logic tests pass it.
    stub_asm: bool = false,
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
