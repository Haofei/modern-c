#!/usr/bin/env python3
"""Ratchet the request-scoped, per-file compiler-session boundary."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def fail(message: str) -> None:
    print(f"FAIL: compilation-session-inventory - {message}", file=sys.stderr)
    raise SystemExit(1)


def read(path: str) -> str:
    full = ROOT / path
    if not full.is_file():
        fail(f"missing {path}")
    return full.read_text(encoding="utf-8")


def require(path: str, *needles: str) -> None:
    text = read(path)
    for needle in needles:
        if needle not in text:
            fail(f"{path} missing {needle!r}")


def forbid(path: str, *patterns: str) -> None:
    text = read(path)
    for pattern in patterns:
        if re.search(pattern, text, flags=re.MULTILINE):
            fail(f"{path} still matches retired pattern {pattern!r}")


def main() -> int:
    session = "src/compiler_session.zig"
    main_zig = "src/main.zig"

    require(
        session,
        "pub const CompilationSession = struct {",
        "source_views: ?[]const diagnostics.SourceView = null,",
        "module_graph: ?*const loader.ModuleGraph = null,",
        "source_db: ?*const loader.SourceDatabase = null,",
        "resolved_sources: ?*const module_parser.ResolvedSourceDatabase = null,",
        "resolved_program: ?*const module_parser.ResolvedProgram = null,",
        "pub fn attachLoadedProjectSyntax(",
        "pub fn prepareResolvedProgram(",
        "pub fn checkResolvedProgram(",
        "pub fn buildVerifiedProgramFromResolvedDecls(",
        "pub fn buildMirFromResolvedDecls(",
        "module_mir.* = try mir.buildOptFromResolvedDecls",
        'test "CompilationSession attaches per-file resolved module syntax"',
    )
    require(
        main_zig,
        'const compiler_session = @import("compiler_session.zig");',
        "session.module_graph = &loaded.graph;",
        "session.source_db = &loaded.source_db;",
        "session.attachLoadedProjectSyntax(",
        "session.prepareResolvedProgram(",
    )
    require(
        "src/driver_check.zig",
        "session.checkResolvedProgram(",
    )
    require(
        "src/driver_codegen.zig",
        "session.checkResolvedProgram(",
        "driver_codegen_inputs.buildBackendInputs(",
    )
    require(
        "src/module_graph.zig",
        "pub const ModuleGraph = struct",
        "pub const SourceDatabase = struct",
        "pub const LoadedProject = struct",
    )
    require(
        "src/module_parser.zig",
        "pub const ParsedSourceDatabase = struct",
        "pub const ResolvedSourceDatabase = struct",
        "pub const ResolvedProgram = struct",
        "parser.Parser.initWithFileId",
    )

    for path in (
        session,
        main_zig,
        "src/loader.zig",
        "src/module_graph.zig",
        "src/module_parser.zig",
        "src/diagnostics.zig",
        "src/sema.zig",
        "src/mangle_private.zig",
    ):
        forbid(
            path,
            r"\bFileBoundary\b",
            r"\bfile_boundaries\b",
            r"\bloadCombinedSource\b",
            r"\bparseCheckedModuleOrReport\b",
            r"\bparseModuleOrReport\b",
            r"\bcombined_boundaries\b",
        )

    forbid(
        main_zig,
        r"var checker = sema\.Checker\.init",
        r"mir\.buildOpt(?:FromDecls)?\(",
        r"@import\(\"[^\"]*_tests\.zig\"\)",
    )
    require(
        "src/driver_codegen_inputs.zig",
        "session.buildVerifiedProgramFromResolvedDecls(",
    )
    require(
        "src/artifact_publisher.zig",
        "pub const Publisher = struct",
        "pub fn writeArtifactWithMetadata(",
        "pub fn publishExistingFileWithMetadata(",
    )
    # `test-unit` is partitioned in the build registry. Keep the composition
    # root and the request-context coverage anchor explicit so a future shard
    # edit cannot silently drop session tests.
    require(
        "src/test_root.zig",
        'const core = @import("test_root_core.zig");',
        'const mir = @import("test_root_mir.zig");',
        'const lower_c = @import("test_shard_lower_c.zig");',
        'const lower_llvm = @import("test_shard_lower_llvm.zig");',
    )
    require("src/test_root_core.zig", 'const compiler_session = @import("compiler_session.zig");')
    require(
        "build/compiler.zig",
        '"test-unit-core", "src/test_root_core.zig"',
        '"test-unit-mir", "src/test_root_mir.zig"',
        "unit_test_step.dependOn(unit_core_step);",
        "unit_test_step.dependOn(unit_mir_step);",
        "unit_test_step.dependOn(lower_c_shard_step);",
        "unit_test_step.dependOn(lower_llvm_shard_step);",
    )

    print("PASS: compilation-session-inventory - per-file request context is the only production path")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
