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
    for needle in (
        "const CompilationSession = struct {",
        "allocator: std.mem.Allocator,",
        "io: std.Io,",
        "file_boundaries: ?[]const loader.FileBoundary = null,",
        "module_graph: ?*const loader.ModuleGraph = null,",
        "visibility_mode: ast.VisibilityMode = .legacy_pub_opt_in,",
        "fn writeStdout(self: *CompilationSession, bytes: []const u8) !void {",
        "fn writeOutputPath(self: *CompilationSession, path: []const u8, bytes: []const u8) !void {",
        "fn writeArtifact(self: *CompilationSession, bytes: []const u8, output_path: ?[]const u8) !void {",
        "fn initReporter(self: *CompilationSession, path: []const u8, source: []const u8) diagnostics.Reporter {",
        "fn parseModuleOrReportMode(self: *CompilationSession, source: []const u8, allocator: std.mem.Allocator, diag: *diagnostics.Reporter, render_errors: bool) !ast.Module {",
        "fn checkModule(self: *CompilationSession, module: ast.Module, diag: *diagnostics.Reporter, optimize: bool) void {",
        "fn parseCheckedModuleOrReport(",
        "fn buildVerifiedProgram(",
        "var session = CompilationSession.init(allocator, init.io);",
        "session.visibility_mode = options.visibility_mode;",
        "session.file_boundaries = loaded.boundaries;",
        "session.module_graph = &loaded.graph;",
        "module.visibility_mode = self.visibility_mode;",
        "name_resolve.transformWithGraph(allocator, module, self.module_graph)",
        "generic_precheck.check(allocator, lowered, diag, self.file_boundaries)",
        "mangle_private.transform(allocator, specialized, self.file_boundaries)",
        "checker.file_boundaries = self.file_boundaries;",
        "module_mir.* = try mir.buildOpt(self.allocator, module, .{ .optimize = optimize });",
        "const program = backend.VerifiedProgram.init(module, module_mir, diag) catch |err| {",
        "const module = try session.parseCheckedModuleOrReport(source, parse_allocator, &diag, optimize, true, error.LowerMirFailed);",
        "_ = try session.buildVerifiedProgram(module, &diag, optimize, &module_mir, error.LowerMirFailed);",
        "try mir.appendDumpFromMir(allocator, module_mir, &output);",
        "const program = try session.buildVerifiedProgram(module, &diag, optimize, &module_mir, error.EmitCFailed);",
        'test "CompilationSession keeps parse context request scoped"',
        "try std.testing.expectEqual(ast.VisibilityMode.explicit_public, module_a.visibility_mode);",
        "try std.testing.expectEqual(ast.VisibilityMode.legacy_pub_opt_in, module_b.visibility_mode);",
    ):
        require_contains(main_zig, needle)

    main_text = read(main_zig)
    if main_text.count("var checker = sema.Checker.init") != 1:
        fail("sema checker construction must stay centralized in CompilationSession.checkModule")
    if main_text.count("mir.buildOpt(") != 1:
        fail("MIR build must stay centralized in CompilationSession.buildVerifiedProgram")
    if main_text.count("backend.VerifiedProgram.init(") != 1:
        fail("VerifiedProgram construction must stay centralized in CompilationSession.buildVerifiedProgram")
    if main_text.count("session.parseCheckedModuleOrReport(") < 7:
        fail("compile-like CLI commands must share CompilationSession.parseCheckedModuleOrReport")
    if main_text.count("session.checkModule(") != 0:
        fail("compile-like CLI commands must not bypass parseCheckedModuleOrReport")
    require_contains("src/mir.zig", "pub fn appendDumpFromMir(allocator: std.mem.Allocator, module_mir: Module, out: *std.ArrayList(u8)) !void {")

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
        ("build/tiers.zig", 'm0_step.dependOn(ctx.cmd("compilation-session-inventory-test"))'),
        ("build/tiers.zig", 'fast_step.dependOn(ctx.cmd("compilation-session-inventory-test"))'),
        ("build/tiers.zig", 'c0_step.dependOn(ctx.cmd("compilation-session-inventory-test"))'),
        ("tools/dev-gates.py", "compilation-session-inventory-test"),
        ("tools/toolchain/dev-gates-test.py", "compilation-session-inventory-test"),
        ("docs/refactoring-plan.md", "File-boundary, module-graph, visibility, IO, parse/check, MIR build, and"),
    ):
        require_contains(path, needle)

    print("PASS: compilation-session-inventory - request-scoped main context is anchored")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
