const std = @import("std");

const artifact_model = @import("artifact_model.zig");
const diagnostics = @import("diagnostics.zig");
const legacy_backend_syntax = @import("legacy_backend_syntax.zig");
const mir = @import("mir.zig");

/// Code-generation profile (`kernel`/`hosted`). The backend seam owns this
/// request-level option; profile-aware backends act on it and profile-agnostic
/// backends ignore it.
pub const Profile = enum { kernel, hosted };

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

/// Code-generation target architecture for backend details that are ABI-shaped
/// rather than import-shaped. `--arch` already selects architecture-specific
/// imports; LLVM lowering also needs the same target to pick the correct C ABI
/// representation for things like `va_list`.
pub const TargetArch = enum {
    riscv64,
    x86_64,
    aarch64,
};

pub const LowerError = std.mem.Allocator.Error || error{
    UnsupportedCEmission,
    UnsupportedLlvmEmission,
    InvalidMirTargetTypeFacts,
    InvalidMirCallTargetFacts,
    InvalidMirConstGetFacts,
    InvalidMirIntegerFacts,
    InvalidMirRepresentationFacts,
    StaleMirTargetTypeFacts,
    GeneratedTypeNameCollision,
    LayoutStructNotFound,
    LayoutUnresolved,
    InternalLoweringFailure,
};

pub fn lowerErrorFromAny(err: anyerror) LowerError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsupportedCEmission => error.UnsupportedCEmission,
        error.UnsupportedLlvmEmission => error.UnsupportedLlvmEmission,
        error.InvalidMirTargetTypeFacts => error.InvalidMirTargetTypeFacts,
        error.InvalidMirCallTargetFacts => error.InvalidMirCallTargetFacts,
        error.InvalidMirConstGetFacts => error.InvalidMirConstGetFacts,
        error.InvalidMirIntegerFacts => error.InvalidMirIntegerFacts,
        error.InvalidMirRepresentationFacts => error.InvalidMirRepresentationFacts,
        error.StaleMirTargetTypeFacts => error.StaleMirTargetTypeFacts,
        error.GeneratedTypeNameCollision => error.GeneratedTypeNameCollision,
        error.LayoutStructNotFound => error.LayoutStructNotFound,
        error.LayoutUnresolved => error.LayoutUnresolved,
        else => error.InternalLoweringFailure,
    };
}

pub fn targetArchFromName(name: []const u8) ?TargetArch {
    if (std.mem.eql(u8, name, "riscv64")) return .riscv64;
    if (std.mem.eql(u8, name, "x86_64")) return .x86_64;
    if (std.mem.eql(u8, name, "aarch64")) return .aarch64;
    return null;
}

/// Options threaded from the CLI into a backend's lowering entry point. This is
/// the union of everything any built-in backend needs; a given backend reads
/// only the subset it supports (e.g. the LLVM backend ignores `profile`).
pub const LowerOptions = struct {
    /// Code-gen profile. Honored when `Backend.supports_profiles` is true.
    profile: Profile,
    /// Source path embedded in #line / !DILocation metadata; null means the
    /// backend picks its own default.
    source_path: ?[]const u8,
    /// Target ABI used for backend lowering. Defaults to the historical RISC-V
    /// path so existing invocations without `--arch` are unchanged.
    target_arch: TargetArch = .riscv64,
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
    /// Optional reporter used by backends to turn expected unsupported lowering
    /// bailouts into source-spanned diagnostics instead of raw backend errors.
    reporter: ?*diagnostics.Reporter = null,
    /// SHA-256 of the exact source bytes used for this request. Source-map
    /// emission records this when the application layer can provide it.
    source_sha256: ?artifact_model.Sha256Digest = null,
    /// Compiler version string reported by `mcc --version`; artifact metadata
    /// records it when the application layer can provide it.
    compiler_version: ?[]const u8 = null,
    /// External toolchain identity for artifacts that pass through another
    /// compiler/linker (e.g. `mcc build` invoking clang).
    toolchain_identity: ?[]const u8 = null,
    /// LLVM kernel-profile runtime import mode (`mcc emit-llvm --linux-kernel`).
    /// Ignored by backends that do not consume LLVM runtime declarations.
    linux_kernel: bool = false,
};

/// Backend-facing source spelling view. This is intentionally backed by
/// verified MIR identities, not by an AST rescan. It is the first explicit
/// source/symbol table that backend entrypoints can consume while legacy
/// lowerers still carry declaration slices for not-yet-normalized metadata.
pub const SourceSpellingView = struct {
    symbols: []const mir.SymbolIdentity,

    pub fn symbolSpelling(self: SourceSpellingView, id: mir.SymbolId) ?[]const u8 {
        if (!id.isValid()) return null;
        const index = id.index();
        if (index >= self.symbols.len) return null;
        const identity = self.symbols[index];
        if (!identity.id.eql(id)) return null;
        return identity.spelling;
    }

    fn functionSpelling(self: SourceSpellingView, function: mir.Function) ?[]const u8 {
        return self.symbolSpelling(function.typed_symbol_id);
    }

    /// True when verified MIR contains a non-extern function definition whose
    /// source spelling matches `name`. Backends use this for emission mechanics
    /// such as runtime-hook stub suppression; the query is intentionally
    /// MIR-backed so it cannot rescan syntax declarations as semantic authority.
    pub fn definesFunctionSpelling(self: SourceSpellingView, typed_mir: mir.Module, name: []const u8) bool {
        for (typed_mir.functions) |function| {
            if (function.is_extern) continue;
            const spelling = self.functionSpelling(function) orelse continue;
            if (std.mem.eql(u8, spelling, name)) return true;
        }
        return false;
    }

    pub fn validateAgainstMir(self: SourceSpellingView, typed_mir: mir.Module) bool {
        if (self.symbols.len != typed_mir.symbol_identities.len) return false;
        for (self.symbols, typed_mir.symbol_identities) |left, right| {
            if (!left.id.eql(right.id)) return false;
            if (!std.mem.eql(u8, left.spelling, right.spelling)) return false;
        }
        for (typed_mir.functions) |function| {
            const spelling = self.functionSpelling(function) orelse return false;
            if (!std.mem.eql(u8, spelling, function.name)) return false;
        }
        return true;
    }
};

pub const LegacyDeclarationSlice = legacy_backend_syntax.LegacyDeclarationSlice;
pub const SourceMapMechanicsView = legacy_backend_syntax.SourceMapMechanicsView;

/// The only code-generation input accepted by a Backend for ordinary lowering.
/// Construction runs the MIR verifier and exposes MIR-owned source spelling plus
/// a narrow declaration slice for early metadata that MIR emission has not yet
/// normalized.
pub const VerifiedProgram = struct {
    source_spelling: SourceSpellingView,
    typed_mir: *const mir.Module,

    pub fn init(
        typed_mir: *const mir.Module,
        reporter: *diagnostics.Reporter,
    ) !VerifiedProgram {
        try mir.verifyBuiltMir(typed_mir.*, reporter);
        if (reporter.has_errors) return error.InvalidMir;
        try mir.validateLoweringAdmission(typed_mir.*);
        const source_spelling = SourceSpellingView{ .symbols = typed_mir.symbol_identities };
        if (!source_spelling.validateAgainstMir(typed_mir.*)) return error.InvalidMir;
        return .{
            .source_spelling = source_spelling,
            .typed_mir = typed_mir,
        };
    }
};

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

test "VerifiedProgram exposes MIR-owned source spelling view" {
    const source =
        \\fn add_one(value: u32) -> u32 {
        \\    return value + 1;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "backend_source_spelling.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parser_mod = @import("parser.zig");
    var p = parser_mod.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var module_mir = try mir.build(std.testing.allocator, module);
    defer module_mir.deinit();

    const program = try VerifiedProgram.init(&module_mir, &reporter);
    try std.testing.expect(program.source_spelling.validateAgainstMir(module_mir));
    try std.testing.expect(module_mir.functions.len != 0);
    try std.testing.expectEqualStrings(
        "add_one",
        program.source_spelling.symbolSpelling(module_mir.functions[0].typed_symbol_id).?,
    );
    try std.testing.expect(program.source_spelling.definesFunctionSpelling(module_mir, "add_one"));
    try std.testing.expect(!program.source_spelling.definesFunctionSpelling(module_mir, "missing"));
}

test "backend interface does not import concrete lowerers" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/backend.zig", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "@import(\"lower_c.zig\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "@import(\"lower_llvm.zig\")") == null);
}

test "backend lowering errors are mapped to the domain error set" {
    try std.testing.expectEqual(LowerError.UnsupportedCEmission, lowerErrorFromAny(error.UnsupportedCEmission));
    try std.testing.expectEqual(LowerError.InvalidMirTargetTypeFacts, lowerErrorFromAny(error.InvalidMirTargetTypeFacts));
    try std.testing.expectEqual(LowerError.OutOfMemory, lowerErrorFromAny(error.OutOfMemory));
    try std.testing.expectEqual(LowerError.InternalLoweringFailure, lowerErrorFromAny(error.UnexpectedBackendBug));
}
