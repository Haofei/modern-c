const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const mir = @import("mir.zig");

pub const Sha256Digest = [std.crypto.hash.sha2.Sha256.digest_length]u8;

/// Shared artifact/source-map provenance metadata. The first consumer is
/// `emit-map`, but this type deliberately lives at the backend seam so `emit-c`,
/// `emit-llvm`, and `build` can converge on the same digest/header contract
/// instead of each artifact path inventing local metadata.
pub const ArtifactBundle = struct {
    artifact_kind: ?[]const u8 = null,
    backend_name: ?[]const u8 = null,
    generated_artifact_sha256: Sha256Digest,
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
        opts: LowerOptions,
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
        opts: LowerOptions,
    ) ArtifactBundle {
        var bundle = forArtifact(generated_artifact, opts, .{
            .artifact_kind = "c-source-map",
            .backend_name = "c",
        });
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
    source_sha256: ?Sha256Digest = null,
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

/// Transitional declaration metadata view for backend mechanics that still need
/// not-yet-normalized declarations. This is narrower than exposing a syntax
/// module at backend entrypoints: every call site must name the remaining
/// legacy declaration dependency explicitly.
pub const DeclarationMetadataView = struct {
    decls: []const ast.Decl,

    pub fn forDecls(decls: []const ast.Decl) DeclarationMetadataView {
        return .{ .decls = decls };
    }

    pub fn cEarlyDeclarationMetadata(self: DeclarationMetadataView) CEarlyDeclarationMetadataView {
        return .{ .decls = self.decls };
    }

    pub fn llvmEarlyDeclarationMetadata(self: DeclarationMetadataView) LlvmEarlyDeclarationMetadataView {
        return .{ .decls = self.decls };
    }
};

/// Transitional C declaration metadata prepass view. This is the only C backend
/// syntax escape for early const/type/declaration artifact collection.
pub const CEarlyDeclarationMetadataView = struct {
    decls: []const ast.Decl,

    pub fn declsForEarlyDeclarationScan(self: CEarlyDeclarationMetadataView) []const ast.Decl {
        return self.decls;
    }
};

/// Transitional LLVM declaration metadata prepass view. This is the only LLVM
/// backend syntax escape for early type/declaration artifact collection.
pub const LlvmEarlyDeclarationMetadataView = struct {
    decls: []const ast.Decl,

    pub fn declsForEarlyDeclarationScan(self: LlvmEarlyDeclarationMetadataView) []const ast.Decl {
        return self.decls;
    }
};

/// Transitional source-map mechanics view. Source maps still enumerate syntax
/// spans until map rows are normalized into MIR/source-span tables, but this
/// keeps that escape separate from backend semantic lowering and declaration
/// metadata.
pub const SourceMapMechanicsView = struct {
    decls: []const ast.Decl,

    pub fn forDecls(decls: []const ast.Decl) SourceMapMechanicsView {
        return .{ .decls = decls };
    }

    pub fn declsForRowEnumeration(self: SourceMapMechanicsView) []const ast.Decl {
        return self.decls;
    }
};

/// The only code-generation input accepted by a Backend. Construction runs the
/// MIR verifier and exposes MIR-owned source spelling plus narrow declaration
/// slices for metadata/source-map mechanics that MIR emission has not yet
/// normalized.
pub const VerifiedProgram = struct {
    source_spelling: SourceSpellingView,
    declaration_metadata: DeclarationMetadataView,
    source_map_mechanics: SourceMapMechanicsView,
    typed_mir: *const mir.Module,

    pub fn initFromDecls(
        decls: []const ast.Decl,
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
            .declaration_metadata = DeclarationMetadataView.forDecls(decls),
            .source_map_mechanics = SourceMapMechanicsView.forDecls(decls),
            .typed_mir = typed_mir,
        };
    }

    /// Temporary compatibility view for legacy declaration metadata that has
    /// not yet been normalized into typed MIR tables. New backend consumers
    /// should prefer `source_spelling`, MIR identities, or explicit facts.
    pub fn declarationMetadata(self: VerifiedProgram) DeclarationMetadataView {
        return self.declaration_metadata;
    }

    /// Source-map mechanics still walk syntax spans to enumerate source rows.
    /// This accessor makes that use explicit and keeps ordinary backend code
    /// from reaching for syntax as an unclassified semantic input.
    pub fn sourceMapMechanics(self: VerifiedProgram) SourceMapMechanicsView {
        return self.source_map_mechanics;
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
        out: *std.ArrayList(u8),
        opts: LowerOptions,
    ) anyerror!void,
    /// Optional source-map emission ("emit-map"). Only the C backend supplies
    /// this; null means the backend has no source-map artifact. The map is
    /// emitted from the same verified program and generated artifact as the
    /// codegen request, so map metadata cannot silently drift from lowering
    /// options such as checks/profile/stub-asm.
    emitMapFn: ?*const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        program: VerifiedProgram,
        out: *std.ArrayList(u8),
        generated_artifact: []const u8,
        opts: LowerOptions,
    ) anyerror!void = null,

    /// Lower `module` to its textual artifact via the backend's vtable.
    pub fn lower(
        self: Backend,
        allocator: std.mem.Allocator,
        program: VerifiedProgram,
        out: *std.ArrayList(u8),
        opts: LowerOptions,
    ) anyerror!void {
        return self.lowerFn(self.ctx, allocator, program, out, opts);
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
        out: *std.ArrayList(u8),
        generated_artifact: []const u8,
        opts: LowerOptions,
    ) anyerror!void {
        return self.emitMapFn.?(self.ctx, allocator, program, out, generated_artifact, opts);
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

    const program = try VerifiedProgram.initFromDecls(module.decls, &module_mir, &reporter);
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

test "ArtifactBundle emits shared source-map provenance headers" {
    const source_digest = sha256Bytes("source");
    const bundle = ArtifactBundle.forSourceMap("artifact", "payload", "mir-facts", .{
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
    const bundle = ArtifactBundle.forArtifact("artifact", .{
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
