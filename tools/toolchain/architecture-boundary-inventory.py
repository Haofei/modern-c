#!/usr/bin/env python3
"""Ratchet compiler architecture boundaries called out by review.

This is intentionally an inventory gate, not a claim that the boundary is
finished.  It makes the remaining transitional backend syntax/sema escapes
explicit and prevents the old backend cleanup state machines from coming back.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


BACKEND_SOURCE_PREFIXES = (
    "backend",
    "lower_c",
    "lower_llvm",
)
BACKEND_EXTRA_FILES = {
    "lower_cov.zig",
}

EXACT_BACKEND_COUNTS = {
    '@import("ast.zig")': 50,
    '@import("sema': 0,
    '@import("mir_facts_view.zig")': 2,
    '@import("type_syntax.zig")': 5,
    "[]const ast.Decl": 7,
    "LegacyDeclarationSlice": 12,
    "SourceMapMechanicsView": 3,
    "initFromDecls": 0,
}

EXACT_FILE_COUNTS = {
    ("src/backend.zig", "[]const ast.Decl"): 0,
    ("src/backend.zig", "@import(\"ast.zig\")"): 0,
    ("src/backend.zig", "@import(\"artifact_model.zig\")"): 0,
    ("src/backend.zig", "@import(\"diagnostics.zig\")"): 0,
    ("src/backend.zig", "@import(\"legacy_backend_syntax.zig\")"): 0,
    ("src/backend.zig", "@import(\"codegen_request.zig\")"): 1,
    ("src/backend.zig", "pub const Profile = enum"): 0,
    ("src/backend.zig", "pub const Checks = struct"): 0,
    ("src/backend.zig", "pub const TargetArch = enum"): 0,
    ("src/backend.zig", "pub const LowerOptions = struct"): 0,
    ("src/backend.zig", "pub const LowerError = std.mem.Allocator.Error || error"): 0,
    ("src/backend.zig", "pub fn lowerErrorFromAny"): 0,
    ("src/codegen_options.zig", "pub const Profile = enum"): 1,
    ("src/codegen_options.zig", "pub const Checks = struct"): 1,
    ("src/codegen_options.zig", "pub const TargetArch = enum"): 1,
    ("src/codegen_options.zig", "pub const LowerOptions = struct"): 1,
    ("src/lower_error.zig", "pub const LowerError = std.mem.Allocator.Error || error"): 1,
    ("src/lower_error.zig", "pub fn lowerErrorFromAny"): 1,
    ("src/backend.zig", "pub const LegacyDeclarationSlice = legacy_backend_syntax.LegacyDeclarationSlice"): 0,
    ("src/backend.zig", "pub const SourceMapMechanicsView = legacy_backend_syntax.SourceMapMechanicsView"): 0,
    ("src/backend.zig", "pub const LegacyDeclarationSlice = struct"): 0,
    ("src/backend.zig", "pub const SourceMapMechanicsView = struct"): 0,
    ("src/legacy_backend_syntax.zig", "[]const ast.Decl"): 6,
    ("src/legacy_backend_syntax.zig", "pub const LegacyDeclarationSlice = struct"): 1,
    ("src/legacy_backend_syntax.zig", "pub const SourceMapMechanicsView = struct"): 1,
    ("src/backend.zig", "pub fn init("): 0,
    ("src/backend.zig", "pub fn initFromDecls("): 0,
    ("src/verified_program.zig", "pub fn init("): 1,
    ("src/verified_program.zig", "pub fn initFromDecls("): 0,
    ("src/backend.zig", "declaration_metadata"): 0,
    ("src/backend.zig", "declarationMetadata"): 0,
    ("src/backend.zig", "source_map_mechanics"): 0,
    ("src/backend.zig", "sourceMapMechanics"): 0,
    ("src/loader.zig", "*textual inclusion*"): 1,
    ("src/loader.zig", "pub const ModuleGraph = struct"): 0,
    ("src/loader.zig", "pub const LoadedProject = struct"): 0,
    ("src/module_graph.zig", "pub const ModuleGraph = struct"): 1,
    ("src/module_graph.zig", "pub const LoadedProject = struct"): 1,
    ("src/module_graph.zig", "combined textual source"): 1,
    ("src/hir.zig", "inspection_only_header"): 3,
    ("src/mir_facts_view.zig", "pub const MirFactsView = struct"): 1,
    ("src/type_syntax.zig", "pub fn sameTypeSyntax("): 1,
    ("src/type_syntax.zig", "pub fn viewType("): 1,
}

REQUIRED_ANCHORS = {
    "src/verified_program.zig": (
        "MIR verifier",
    ),
    "src/legacy_backend_syntax.zig": (
        "Transitional declaration slice",
        "Transitional source-map mechanics view",
        "every call site must name the remaining",
        "legacy declaration dependency explicitly.",
    ),
    "src/loader.zig": (
        "MC has no",
        "separate module/object model",
        "combined source",
    ),
    "src/module_graph.zig": (
        "stable file/import identity model",
        "expanded byte offsets as semantic identity",
    ),
    "src/hir.zig": (
        'pub const inspection_only_header = "hir mode=inspection-only production_boundary=false\\n";',
    ),
    "src/mir_facts_view.zig": (
        "MIR owns construction and verification.",
        "small query surface",
        "targetTypeFactById",
    ),
    "src/type_syntax.zig": (
        "pub const ViewType = struct",
        "pub fn sameTypeSyntax(left: ast.TypeExpr, right: ast.TypeExpr) bool",
        "fn sameExprSyntax(left: ast.Expr, right: ast.Expr) bool",
    ),
}

FORBIDDEN_BACKEND_PATTERNS = {
    r"\bCleanupState\b": "backend cleanup state type",
    r"\bCleanupCursor\b": "backend cleanup cursor type",
    r"\bcleanup_state\b": "backend cleanup_state field",
    r"\bcleanup_start\b": "backend cleanup_start cursor",
    r"\bloop_cleanup_cursors\b": "loop cleanup cursor cache",
    r"\bdefer_stack\b": "backend defer_stack",
    r"\bDeferredCleanup\b": "backend deferred cleanup stack entry",
    r"\bAutoDropCleanupEntry\b": "backend auto-drop cleanup stack entry",
    r"\bcaptureDeferCleanupStack\b": "defer stack snapshot helper",
    r"\brestoreDeferCleanupStack\b": "defer stack restore helper",
    r"\brestoreToCursor\b": "cleanup cursor restore helper",
    r"\brootCleanupCursor\b": "root cleanup cursor helper",
    r"\bcleanupCursorIndex\b": "cleanup cursor index helper",
}

FORBIDDEN_GLOBAL_PATTERNS = {
    r"VerifiedProgram\.initFromDecls\(": "declaration-slice VerifiedProgram construction",
}


def fail(message: str) -> None:
    print(f"FAIL: architecture-boundary-inventory - {message}", file=sys.stderr)
    sys.exit(1)


def read(rel_path: str) -> str:
    path = ROOT / rel_path
    if not path.is_file():
        fail(f"missing {rel_path}")
    return path.read_text(encoding="utf-8")


def backend_sources() -> list[Path]:
    paths: list[Path] = []
    for path in (ROOT / "src").glob("*.zig"):
        name = path.name
        if name.endswith("_tests.zig"):
            continue
        if name in BACKEND_EXTRA_FILES or any(name.startswith(prefix) for prefix in BACKEND_SOURCE_PREFIXES):
            paths.append(path)
    return sorted(paths)


def count_in_backend(needle: str) -> int:
    return sum(path.read_text(encoding="utf-8").count(needle) for path in backend_sources())


def require_exact_backend_count(needle: str, expected: int) -> None:
    actual = count_in_backend(needle)
    if actual != expected:
        fail(f"backend count for {needle!r} is {actual}, expected {expected}; update only when the count intentionally decreases")


def require_exact_file_count(rel_path: str, needle: str, expected: int) -> None:
    actual = read(rel_path).count(needle)
    if actual != expected:
        fail(f"{rel_path} count for {needle!r} is {actual}, expected {expected}; update only when the count intentionally decreases")


def require_contains(rel_path: str, needle: str) -> None:
    if needle not in read(rel_path):
        fail(f"{rel_path} missing {needle!r}")


def require_absent_in_backend(pattern: str, description: str) -> None:
    regex = re.compile(pattern)
    for path in backend_sources():
        text = path.read_text(encoding="utf-8")
        match = regex.search(text)
        if match:
            rel_path = path.relative_to(ROOT)
            fail(f"{rel_path} contains {description}: {match.group(0)!r}")


def require_absent_glob(pattern: str, description: str) -> None:
    regex = re.compile(pattern)
    for path in (ROOT / "src").glob("*.zig"):
        if path.name.endswith("_tests.zig"):
            continue
        text = path.read_text(encoding="utf-8")
        match = regex.search(text)
        if match:
            rel_path = path.relative_to(ROOT)
            fail(f"{rel_path} contains {description}: {match.group(0)!r}")


def main() -> int:
    sources = backend_sources()
    if len(sources) != 56:
        fail(f"backend source inventory has {len(sources)} files, expected 56")

    for needle, expected in EXACT_BACKEND_COUNTS.items():
        require_exact_backend_count(needle, expected)

    for (rel_path, needle), expected in EXACT_FILE_COUNTS.items():
        require_exact_file_count(rel_path, needle, expected)

    for rel_path, needles in REQUIRED_ANCHORS.items():
        for needle in needles:
            require_contains(rel_path, needle)

    for pattern, description in FORBIDDEN_BACKEND_PATTERNS.items():
        require_absent_in_backend(pattern, description)

    for pattern, description in FORBIDDEN_GLOBAL_PATTERNS.items():
        require_absent_glob(pattern, description)

    print("PASS: architecture-boundary-inventory - backend cleanup state stays removed and syntax escapes are ratcheted")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
