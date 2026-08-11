const artifact_model = @import("artifact_model.zig");
const diagnostics = @import("diagnostics.zig");
const std = @import("std");

/// Code-generation profile (`kernel`/`hosted`). This is request-level backend
/// policy; profile-aware backends act on it and profile-agnostic backends ignore
/// it.
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

test "targetArchFromName maps supported backend target names" {
    try std.testing.expectEqual(TargetArch.riscv64, targetArchFromName("riscv64").?);
    try std.testing.expectEqual(TargetArch.x86_64, targetArchFromName("x86_64").?);
    try std.testing.expectEqual(TargetArch.aarch64, targetArchFromName("aarch64").?);
    try std.testing.expect(targetArchFromName("mips64") == null);
}
