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
    '@import("ast.zig")': 0,
    '@import("attr_syntax.zig")': 2,
    '@import("ast_query.zig")': 0,
    '@import("expr_syntax.zig")': 0,
    '@import("sema': 0,
    '@import("early_declaration_metadata.zig")': 0,
    '@import("mir_facts_view.zig")': 0,
    '@import("type_syntax.zig")': 0,
    "[]const ast.Decl": 0,
    "LegacyDeclarationSlice": 0,
    "SourceMapRowsView": 0,
    "initFromDecls": 0,
}

EXACT_FILE_COUNTS = {
    ("src/backend.zig", "[]const ast.Decl"): 0,
    ("src/backend.zig", "@import(\"ast.zig\")"): 0,
    ("src/backend.zig", "@import(\"artifact_model.zig\")"): 0,
    ("src/backend.zig", "@import(\"diagnostics.zig\")"): 0,
    ("src/backend.zig", "@import(\"legacy_backend_syntax.zig\")"): 0,
    ("src/codegen_request.zig", "@import(\"legacy_backend_syntax.zig\")"): 0,
    ("src/codegen_request.zig", "@import(\"early_declaration_metadata.zig\")"): 0,
    ("src/codegen_request.zig", "@import(\"declaration_artifacts.zig\")"): 1,
    ("src/declaration_artifacts.zig", "@import(\"early_declaration_metadata.zig\")"): 0,
    ("src/main.zig", "@import(\"declaration_artifacts.zig\")"): 0,
    ("src/main.zig", "@import(\"driver_codegen_inputs.zig\")"): 1,
    ("src/main.zig", "collectFromDecls"): 0,
    ("src/driver_codegen_inputs.zig", "@import(\"ast.zig\")"): 1,
    ("src/driver_codegen_inputs.zig", "@import(\"declaration_artifacts.zig\")"): 1,
    ("src/driver_codegen_inputs.zig", "DeclarationArtifacts.collectFromDecls(session.allocator, module.decls)"): 0,
    ("src/driver_codegen_inputs.zig", "DeclarationArtifacts.collectFromSyntaxDecls(session.allocator, module.decls)"): 2,
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
    ("src/backend.zig", "pub const SourceMapRowsView = legacy_backend_syntax.SourceMapRowsView"): 0,
    ("src/backend.zig", "pub const LegacyDeclarationSlice = struct"): 0,
    ("src/backend.zig", "pub const SourceMapRowsView = struct"): 0,
    ("src/declaration_artifacts.zig", "[]const ast.Decl"): 1,
    ("src/declaration_artifacts.zig", "pub const SyntaxDeclarationSlice = []const ast.Decl"): 1,
    ("src/declaration_artifacts.zig", "pub const EarlyDeclarationArtifacts = struct"): 1,
    ("src/declaration_artifacts.zig", "function_artifacts: []const FunctionArtifact"): 1,
    ("src/declaration_artifacts.zig", "global_artifacts: []const ast.GlobalDecl"): 0,
    ("src/declaration_artifacts.zig", "global_artifacts: []const GlobalArtifact"): 1,
    ("src/declaration_artifacts.zig", "trait_artifacts: []const TraitArtifact"): 0,
    ("src/declaration_artifacts.zig", "trait_decl_artifacts: []const TraitDeclArtifact"): 1,
    ("src/declaration_artifacts.zig", "impl_trait_artifacts: []const ImplTraitArtifact"): 1,
    ("src/declaration_artifacts.zig", "type_alias_artifacts: []const ast.TypeAlias"): 1,
    ("src/declaration_artifacts.zig", "struct_artifacts: []const ast.StructDecl"): 1,
    ("src/declaration_artifacts.zig", "enum_artifacts: []const ast.EnumDecl"): 1,
    ("src/declaration_artifacts.zig", "union_artifacts: []const ast.UnionDecl"): 1,
    ("src/declaration_artifacts.zig", "packed_bits_artifacts: []const ast.PackedBitsDecl"): 1,
    ("src/declaration_artifacts.zig", "overlay_union_artifacts: []const ast.OverlayUnionDecl"): 1,
    ("src/declaration_artifacts.zig", "pub const FunctionArtifact = struct"): 1,
    ("src/declaration_artifacts.zig", "    fn_decl: ast.FnDecl,"): 0,
    ("src/declaration_artifacts.zig", "pub const GlobalArtifact = struct"): 1,
    ("src/declaration_artifacts.zig", "pub const TraitArtifact = union(enum)"): 0,
    ("src/declaration_artifacts.zig", "pub const TraitDeclArtifact = struct"): 1,
    ("src/declaration_artifacts.zig", "pub const ImplTraitArtifact = struct"): 1,
    ("src/declaration_artifacts.zig", "pub const TypeArtifact = union(enum)"): 0,
    ("src/declaration_artifacts.zig", "type_artifacts: []const TypeArtifact"): 0,
    ("src/declaration_artifacts.zig", "pub const CallableValueArtifact = union(enum)"): 0,
    ("src/declaration_artifacts.zig", "body: ast.Block"): 0,
    ("src/declaration_artifacts.zig", "opaque_decl: ast.Ident"): 0,
    ("src/codegen_request.zig", '@import("source_map_rows.zig")'): 0,
    ("src/codegen_request.zig", "source_map_rows: source_map_rows.SourceMapRows"): 0,
    ("src/codegen_request.zig", "source_map_artifacts: []const declaration_artifacts.SourceMapArtifact"): 1,
    ("src/lower_c_map.zig", "source_map_rows"): 0,
    ("src/lower_c_map.zig", "[]const declaration_artifacts.SourceMapArtifact"): 2,
    ("src/lower_c_map.zig", "fn emitFunctionMirRows(self: *SourceMapEmitter, symbol: []const u8) !void"): 1,
    ("src/lower_c_map.zig", "fn emitBlock(self: *SourceMapEmitter"): 0,
    ("src/mir_facts_view.zig", "targetTypeFactAtWithModuleFallback"): 0,
    ("src/mir_facts_view.zig", "targetTypeFactAtOwnedWithModuleFallback"): 0,
    ("src/mir_facts_view.zig", "targetTypeFactAtCurrentSpan"): 1,
    ("src/mir_facts_view.zig", "targetTypeFactAtOwnedCurrentSpan"): 1,
    ("src/lower_c_emitter.zig", "targetTypeFactAtWithModuleFallback"): 0,
    ("src/lower_c_emitter.zig", "targetTypeFactAtOwnedWithModuleFallback"): 0,
    ("src/lower_c_emitter.zig", "targetTypeFactAtCurrentSpan"): 1,
    ("src/lower_c_emitter.zig", "targetTypeFactAtOwnedCurrentSpan"): 1,
    ("src/lower_llvm.zig", "targetTypeFactAtWithModuleFallback"): 0,
    ("src/lower_llvm.zig", "targetTypeFactAtOwnedWithModuleFallback"): 0,
    ("src/lower_llvm.zig", "targetTypeFactAtCurrentSpan"): 1,
    ("src/lower_llvm.zig", "targetTypeFactAtOwnedCurrentSpan"): 1,
    ("src/backend.zig", "pub fn init("): 0,
    ("src/backend.zig", "pub fn initFromDecls("): 0,
    ("src/verified_program.zig", "pub fn init("): 1,
    ("src/verified_program.zig", "pub fn initFromDecls("): 0,
    ("src/backend.zig", "declaration_metadata"): 0,
    ("src/backend.zig", "declarationMetadata"): 0,
    ("src/backend.zig", "source_map_rows"): 0,
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
    ("src/lower_llvm.zig", "fn isPointerLikeType("): 0,
    ("src/lower_llvm.zig", "fn isFloatTypeOf("): 0,
    ("src/lower_llvm.zig", "fn isF32TypeOf("): 0,
    ("src/lower_llvm.zig", "fn isMmioPtrType("): 0,
    ("src/lower_llvm.zig", "fn pointerAddressCoercion("): 0,
    ("src/lower_llvm.zig", "fn nullableInnerType("): 0,
    ("src/lower_llvm.zig", "fn atomicPayloadType("): 0,
    ("src/lower_llvm.zig", "fn maybeUninitPayloadType("): 0,
    ("src/lower_llvm.zig", "fn resultInfo("): 0,
    ("src/lower_llvm.zig", "fn domainPayloadType("): 0,
    ("src/lower_llvm_shape.zig", "pub fn isPointerLikeType("): 1,
    ("src/lower_llvm_shape.zig", "pub fn isFloatTypeOf("): 1,
    ("src/lower_llvm_shape.zig", "pub fn isF32TypeOf("): 1,
    ("src/lower_llvm_shape.zig", "pub fn isMmioPtrType("): 1,
    ("src/lower_llvm_shape.zig", "pub fn pointerAddressCoercion("): 1,
    ("src/lower_llvm_shape.zig", "pub fn nullableInnerType("): 1,
    ("src/lower_llvm_shape.zig", "pub fn atomicPayloadType("): 1,
    ("src/lower_llvm_shape.zig", "pub fn maybeUninitPayloadType("): 1,
    ("src/lower_llvm_shape.zig", "pub fn resultInfo("): 1,
    ("src/lower_llvm_shape.zig", "pub fn domainPayloadType("): 1,
    ("src/lower_c_emitter.zig", "fn sourcePointMatchesSpan("): 0,
    ("src/lower_c_emitter.zig", "fn sourcePointFromOptionalSpan("): 0,
    ("src/lower_c_emitter.zig", "fn isSourceSpan("): 0,
    ("src/lower_llvm.zig", "fn sourcePointMatchesSpan("): 0,
    ("src/lower_llvm.zig", "fn sourcePointFromOptionalSpan("): 0,
    ("src/lower_llvm.zig", "fn isSourceSpan("): 0,
    ("src/mir_source_bridge.zig", "pub fn sourcePointMatchesSpan("): 1,
    ("src/mir_source_bridge.zig", "pub fn sourcePointFromOptionalSpan("): 1,
    ("src/mir_source_bridge.zig", "pub fn isSourceSpan("): 1,
    ("src/mir_source_bridge.zig", "pub fn firstCallTargetKindAt("): 1,
    ("src/mir_source_bridge.zig", "pub fn uniqueCallTargetKindAt("): 1,
    ("src/mir_source_bridge.zig", "pub fn hasCallTargetKindAt("): 1,
    ("src/mir_source_bridge.zig", "pub const TargetTypeLookupKey = mir_facts_view.TargetTypeLookupKey"): 1,
    ("src/mir_source_bridge.zig", "pub fn targetTypeFactById("): 1,
    ("src/mir_source_bridge.zig", "pub fn targetTypeFactAtWithModuleFallback("): 0,
    ("src/mir_source_bridge.zig", "pub fn targetTypeFactAtCurrentSpan("): 1,
    ("src/mir_source_bridge.zig", "pub fn targetTypeFactMatchingType("): 1,
    ("src/mir_source_bridge.zig", "pub fn atomicInitPayloadTypeAt("): 1,
    ("src/mir_source_bridge.zig", "pub fn targetTypeFactAtOwnedWithModuleFallback("): 0,
    ("src/mir_source_bridge.zig", "pub fn targetTypeFactAtOwnedCurrentSpan("): 1,
    ("src/mir_source_bridge.zig", "pub fn uniqueConstGetIndexAt("): 1,
    ("src/mir_source_bridge.zig", "pub fn pointerFactMatchesAt("): 1,
    ("src/mir_source_bridge.zig", "pub fn aggregatePointerFieldFactMatchesAt("): 1,
    ("src/mir_source_bridge.zig", "pub fn pointerFactIsCallInvalidationAt("): 1,
    ("src/mir_source_bridge.zig", "pub fn pointerFactMatchesSubjectFieldAt("): 1,
    ("src/mir_source_bridge.zig", "pub fn pointerFactIsLiveGlobal("): 1,
    ("src/mir_source_bridge.zig", "pub fn pointerFactIsLiveLocal("): 1,
    ("src/mir_source_bridge.zig", "pub fn pointerFactLiveState("): 1,
    ("src/mir_source_bridge.zig", "pub fn deferCleanupRefAtSpan("): 1,
    ("src/mir_source_bridge.zig", "pub fn directDeferCallCleanupForSpans("): 1,
    ("src/mir_source_bridge.zig", "pub fn callTargetDeferCleanupForSpans("): 1,
    ("src/mir_source_bridge.zig", "pub fn replacementSourceFromSpan("): 1,
    ("src/mir_source_bridge.zig", "pub fn replacementSourceMatchesSpan("): 1,
    ("src/mir_source_bridge.zig", "@import(\"ast.zig\")"): 0,
    ("src/mir_source_bridge.zig", "@import(\"type_syntax.zig\")"): 0,
    ("src/mir_source_bridge.zig", "@import(\"ast_bridge.zig\")"): 1,
    ("src/mir_source_bridge.zig", "@import(\"type_bridge.zig\")"): 1,
    ("src/lower_c_emitter.zig", "mir_facts_view.TargetTypeFactQuery"): 0,
    ("src/lower_c_emitter.zig", "mir_facts_view.PointerFactQuery"): 0,
    ("src/lower_llvm.zig", "mir_facts_view.PointerFactQuery"): 0,
    ("src/lower_c_emitter.zig", "@import(\"mir_facts_view.zig\")"): 0,
    ("src/lower_llvm.zig", "@import(\"mir_facts_view.zig\")"): 0,
    ("src/lower_c_access.zig", "mir.sourcePointFromSpan("): 0,
    ("src/lower_c_access.zig", "fn replacementForSource("): 0,
    ("src/lower_c_access.zig", "fn sameSource("): 0,
    ("src/lower_c_try.zig", "mir.sourcePointFromSpan("): 0,
    ("src/lower_c_mmio.zig", "mir.sourcePointFromSpan("): 0,
    ("src/lower_c_emitter.zig", "targetTypeFactMatchesFamily(function, result_fact, .atomic_init_result"): 0,
    ("src/lower_llvm.zig", "targetTypeFactMatchesFamily(function, result_fact, .atomic_init_result"): 0,
    ("src/lower_c_emitter.zig", "targetTypeFactMatchesFamily(function, payload_fact, .atomic_init_payload"): 0,
    ("src/lower_llvm.zig", "targetTypeFactMatchesFamily(function, payload_fact, .atomic_init_payload"): 0,
    ("src/lower_c_emitter.zig", "mir.deferCleanupRefAtSource("): 0,
    ("src/lower_llvm.zig", "mir.deferCleanupRefAtSource("): 0,
    ("src/lower_c_emitter.zig", "mir.directDeferCallCleanupForRef("): 0,
    ("src/lower_llvm.zig", "mir.directDeferCallCleanupForRef("): 0,
    ("src/lower_c_emitter.zig", "mir.callTargetDeferCleanupForRef("): 0,
    ("src/lower_llvm.zig", "mir.callTargetDeferCleanupForRef("): 0,
}

REQUIRED_ANCHORS = {
    "src/verified_program.zig": (
        "MIR verifier",
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
    "src/mir_source_bridge.zig": (
        "Transitional AST-span to MIR-source-point bridge.",
        "VerifiedProgram boundary is being",
    ),
    "src/syntax_bridge.zig": (
        "Transitional backend syntax-shape bridge.",
        "expression-shape helper access behind this narrow bridge",
    ),
    "src/type_bridge.zig": (
        "Transitional backend type-shape bridge.",
        "direct type-syntax helper access behind this narrow bridge",
    ),
    "src/ast_bridge.zig": (
        "Transitional backend AST-shape bridge.",
        "direct AST access behind this bridge",
    ),
    "src/declaration_artifacts.zig": (
        "Syntax-backed declaration artifacts for the codegen compatibility edge.",
        "declaration enumeration is isolated here",
        "generic legacy view",
    ),
    "src/driver_codegen_inputs.zig": (
        "Driver-owned codegen input assembly.",
        "remaining syntax compatibility edge for CLI backend commands",
        "Keep this boundary out of backend lowerers",
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
    r"@import\(\"early_declaration_metadata\.zig\"\)": "retired early declaration metadata shim import",
    r"@import\(\"source_map_rows\.zig\"\)": "retired source-map rows wrapper import",
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
    if len(sources) != 52:
        fail(f"backend source inventory has {len(sources)} files, expected 52")

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
