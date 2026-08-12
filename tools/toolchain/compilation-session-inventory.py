#!/usr/bin/env python3
"""Check request-scoped compiler context does not regress to main.zig globals."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def fail(message: str) -> None:
    print(f"FAIL: compilation-session-inventory - {message}", file=sys.stderr)
    sys.exit(1)


def read(path: str) -> str:
    full = ROOT / path
    if not full.is_file():
        fail(f"missing {path}")
    return full.read_text(encoding="utf-8")


def require_contains(path: str, needle: str) -> None:
    if needle not in read(path):
        fail(f"{path} missing {needle!r}")


def require_absent(path: str, pattern: str, description: str) -> None:
    text = read(path)
    if re.search(pattern, text, flags=re.MULTILINE):
        fail(f"{path} still contains {description}")


def main() -> int:
    main_zig = "src/main.zig"
    session_zig = "src/compiler_session.zig"
    for needle in (
        'const compiler_session = @import("compiler_session.zig");',
        "const CompilationSession = compiler_session.CompilationSession;",
        "const CompilationStageFailure = compiler_session.StageFailure;",
        "const max_artifact_metadata_bytes = compiler_session.max_artifact_metadata_bytes;",
    ):
        require_contains(main_zig, needle)

    for needle in (
        "pub const CompilationSession = struct {",
        "allocator: std.mem.Allocator,",
        "io: std.Io,",
        "file_boundaries: ?[]const loader.FileBoundary = null,",
        "module_graph: ?*const loader.ModuleGraph = null,",
        "resolved_sources: ?*const module_parser.ResolvedSourceDatabase = null,",
        "visibility_mode: ast.VisibilityMode = .legacy_pub_opt_in,",
        "pub fn writeStdout(self: *CompilationSession, bytes: []const u8) !void {",
        "pub fn writeOutputPath(self: *CompilationSession, path: []const u8, bytes: []const u8) !void {",
        "fn publisher(self: *CompilationSession) artifact_publisher.Publisher {",
        "pub const ArtifactMetadataDraft = artifact_publisher.Publisher.MetadataDraft;",
        "pub const MetadataSidecarSnapshot = artifact_publisher.Publisher.MetadataSidecarSnapshot;",
        "pub fn ensureReplaceTargetNotDirectory(self: *CompilationSession, path: []const u8, label: []const u8) !void {",
        "pub fn prepareArtifactMetadataSidecar(self: *CompilationSession, output_path: []const u8, bundle: artifact_model.ArtifactBundle) !ArtifactMetadataDraft {",
        "pub fn writeArtifact(self: *CompilationSession, bytes: []const u8, output_path: ?[]const u8) !void {",
        "pub fn writeArtifactMetadataSidecar(self: *CompilationSession, output_path: []const u8, bundle: artifact_model.ArtifactBundle) !void {",
        "pub fn writeArtifactWithMetadata(self: *CompilationSession, bytes: []const u8, output_path: ?[]const u8, bundle: artifact_model.ArtifactBundle) !void {",
        "pub fn publishExistingArtifactWithMetadata(",
        "pub fn initReporter(self: *CompilationSession, path: []const u8, source: []const u8) diagnostics.Reporter {",
        "pub fn attachLoadedProjectSyntax(",
        "pub fn parseModuleOrReportMode(self: *CompilationSession, source: []const u8, allocator: std.mem.Allocator, diag: *diagnostics.Reporter, render_errors: bool) !ast.Module {",
        "pub fn checkModule(self: *CompilationSession, module: ast.Module, diag: *diagnostics.Reporter, optimize: bool) void {",
        "pub fn parseCheckedModuleOrReport(",
        "pub fn buildVerifiedProgram(",
        "pub fn artifactMetadataPath(allocator: std.mem.Allocator, output_path: []const u8) ![]const u8 {",
    ):
        require_contains(session_zig, needle)

    for needle in (
        "pub const Publisher = struct {",
        "pub fn writeOutputPath(self: Publisher, path: []const u8, bytes: []const u8) !void {",
        "pub const MetadataDraft = struct {",
        "pub const MetadataSidecarSnapshot = union(enum) {",
        "pub fn prepareMetadataSidecar(self: Publisher, output_path: []const u8, bundle: artifact_model.ArtifactBundle) !MetadataDraft {",
        "pub fn writeArtifactWithMetadata(self: Publisher, bytes: []const u8, output_path: ?[]const u8, bundle: artifact_model.ArtifactBundle) !void {",
        "pub fn publishExistingFileWithMetadata(",
        "pub fn metadataPath(allocator: std.mem.Allocator, output_path: []const u8) ![]const u8 {",
    ):
        require_contains("src/artifact_publisher.zig", needle)

    for needle in (
        "var session = CompilationSession.init(allocator, init.io);",
        "session.visibility_mode = options.visibility_mode;",
        "session.file_boundaries = loaded.boundaries;",
        "session.module_graph = &loaded.graph;",
        "session.attachLoadedProjectSyntax(&loaded, module_parse_arena.allocator(), &load_diag, &parsed_sources, &resolved_sources) catch |err| {",
        "try load_diag.appendJson(&out);",
        "const module = try session.parseCheckedModuleOrReport(source, parse_allocator, &diag, optimize, true, error.LowerMirFailed);",
        "_ = try session.buildVerifiedProgram(module, &diag, optimize, &module_mir, error.LowerMirFailed);",
        "try mir.appendDumpFromMir(allocator, module_mir, &output);",
        "const program = try driver_codegen_inputs.buildBackendInputs(session, module, &diag, optimize, &module_mir, &early_metadata, error.EmitCFailed);",
    ):
        require_contains(main_zig, needle)

    for needle in (
        "module.visibility_mode = self.visibility_mode;",
        "name_resolve.transformWithGraph(allocator, module, self.module_graph)",
        "parsed_out.* = try module_parser.parseSourceDatabase(parse_allocator, project.graph, project.source_db, reporter);",
        "resolved_out.* = try module_parser.resolveParsedSourceDatabase(parse_allocator, parsed_out.*);",
        "generic_precheck.check(allocator, lowered, diag, self.file_boundaries)",
        "mangle_private.transform(allocator, specialized, self.file_boundaries)",
        "checker.file_boundaries = self.file_boundaries;",
        "module_mir.* = try mir.buildOptFromDecls(self.allocator, module.decls, .{ .optimize = optimize });",
        "const program = backend.VerifiedProgram.init(module_mir, diag) catch |err| {",
        'test "CompilationSession keeps parse context request scoped"',
        'test "CompilationSession attaches per-file resolved module syntax"',
        'test "CompilationSession restores artifact metadata sidecar snapshots"',
        'test "CompilationSession diagnostic stage failures use a bounded error set"',
        "try std.testing.expectEqual(ast.VisibilityMode.explicit_public, module_a.visibility_mode);",
        "try std.testing.expectEqual(ast.VisibilityMode.legacy_pub_opt_in, module_b.visibility_mode);",
    ):
        require_contains(session_zig, needle)

    main_text = read(main_zig)
    session_text = read(session_zig)
    if session_text.count("var checker = sema.Checker.init") != 1:
        fail("sema checker construction must stay centralized in CompilationSession.checkModule")
    if main_text.count("var checker = sema.Checker.init") != 0:
        fail("main.zig must not construct sema checkers")
    if session_text.count("mir.buildOptFromDecls(") != 1:
        fail("MIR build must stay centralized in CompilationSession.buildVerifiedProgram")
    if session_text.count("mir.buildOpt(") != 0:
        fail("CompilationSession must not use the old module-shaped MIR build API")
    if main_text.count("mir.buildOpt(") != 0 or main_text.count("mir.buildOptFromDecls(") != 0:
        fail("main.zig must not build MIR directly")
    if "createFileAtomic(" in main_text:
        fail("main.zig must not own artifact publication transactions")
    if "metadata_file" in main_text:
        fail("main.zig must not write metadata sidecars directly")
    if "std.Io.Dir.cwd().rename(tmp_exe" in main_text:
        fail("main.zig must not commit existing build artifacts directly")
    for forbidden_import in (
        '@import("async_lower.zig")',
        '@import("generic_precheck.zig")',
        '@import("mangle_private.zig")',
        '@import("name_resolve.zig")',
        '@import("parser.zig")',
        '@import("sema.zig")',
    ):
        if forbidden_import in main_text:
            fail(f"main.zig must not import compiler pipeline stage {forbidden_import}")
    if (main_text + session_text).count("backend.VerifiedProgram.initFromDecls(") != 0:
        fail("VerifiedProgram declaration-slice construction must not be used")
    if session_text.count("backend.VerifiedProgram.init(") != 1:
        fail("VerifiedProgram construction must stay centralized in CompilationSession.buildVerifiedProgram")
    require_contains("src/driver_codegen_inputs.zig", "const program = try session.buildVerifiedProgram(module, diag, optimize, module_mir, failure_error);")
    if main_text.count("session.parseCheckedModuleOrReport(") < 7:
        fail("compile-like CLI commands must share CompilationSession.parseCheckedModuleOrReport")
    if main_text.count("session.checkModule(") != 0:
        fail("compile-like CLI commands must not bypass parseCheckedModuleOrReport")
    if re.search(r'@import\("[^"]*_tests\.zig"\)', main_text):
        fail("main.zig must not aggregate repository test modules")
    require_contains("src/mir.zig", "pub fn appendDumpFromMir(allocator: std.mem.Allocator, module_mir: Module, out: *std.ArrayList(u8)) !void {")
    require_contains("src/test_root.zig", 'const main = @import("main.zig");')
    require_contains("src/test_root.zig", 'const compiler_session = @import("compiler_session.zig");')
    require_contains("src/test_root.zig", 'const lower_c_tests = @import("lower_c_tests.zig");')
    require_contains("src/test_root.zig", 'const lower_llvm_tests = @import("lower_llvm_tests.zig");')

    for pattern, description in (
        (r"^var\s+combined_boundaries\s*:", "combined_boundaries module global"),
        (r"^var\s+combined_module_graph\s*:", "combined_module_graph module global"),
        (r"^var\s+active_visibility_mode\s*:", "active_visibility_mode module global"),
        (r"^var\s+stdout_io\s*:", "stdout_io module global"),
        (r"\bcombined_boundaries\b", "combined_boundaries identifier"),
        (r"\bcombined_module_graph\b", "combined_module_graph identifier"),
        (r"\bactive_visibility_mode\b", "active_visibility_mode identifier"),
        (r"\bstdout_io\b", "stdout_io identifier"),
    ):
        require_absent(main_zig, pattern, description)

    for path, needle in (
        ("build/qemu.zig", "compilation-session-inventory-test"),
        ("build/compiler.zig", '.root_source_file = b.path("src/test_root.zig"),'),
        ("build/tiers.zig", 'm0_step.dependOn(ctx.cmd("compilation-session-inventory-test"))'),
        ("build/tiers.zig", 'fast_step.dependOn(ctx.cmd("compilation-session-inventory-test"))'),
        ("build/tiers.zig", 'c0_step.dependOn(ctx.cmd("compilation-session-inventory-test"))'),
        ("tools/dev-gates.py", "compilation-session-inventory-test"),
        ("tools/toolchain/dev-gates-test.py", "compilation-session-inventory-test"),
        ("tools/toolchain/mcc-cli-test.sh", "emit-c metadata sidecar preflight"),
        ("tools/toolchain/mcc-build-test.sh", "metadata sidecar failure corrupted an existing executable"),
        ("tools/toolchain/mcc-build-test.sh", "directory output target did not fail closed"),
        ("docs/refactoring-plan.md", "`src/compiler_session.zig` owns `CompilationSession`: file-boundary,"),
        ("docs/refactoring-plan.md", "`src/artifact_publisher.zig` owns"),
        ("docs/refactoring-plan.md", "`src/main.zig`"),
    ):
        require_contains(path, needle)

    print("PASS: compilation-session-inventory - request-scoped main context is anchored")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
