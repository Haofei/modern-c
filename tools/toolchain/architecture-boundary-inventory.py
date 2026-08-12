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
    ("src/declaration_artifacts.zig", "@import(\"module_parser.zig\")"): 1,
    ("src/main.zig", "@import(\"declaration_artifacts.zig\")"): 0,
    ("src/main.zig", "@import(\"driver_codegen_inputs.zig\")"): 1,
    ("src/main.zig", "collectFromDecls"): 0,
    ("src/driver_codegen_inputs.zig", "@import(\"ast.zig\")"): 0,
    ("src/driver_codegen_inputs.zig", "@import(\"declaration_artifacts.zig\")"): 1,
    ("src/driver_codegen_inputs.zig", "@import(\"module_parser.zig\")"): 1,
    ("src/driver_codegen_inputs.zig", "pub const SourceMapArtifact = declaration_artifacts.SourceMapArtifact"): 0,
    ("src/driver_codegen_inputs.zig", "DeclarationArtifacts.collectFromDecls(session.allocator, module.decls)"): 0,
    ("src/driver_codegen_inputs.zig", "DeclarationArtifacts.collectFromSyntaxDecls(session.allocator, module.decls)"): 0,
    ("src/driver_codegen_inputs.zig", "module: ast.Module"): 0,
    ("src/driver_codegen_inputs.zig", "session.buildVerifiedProgram(module"): 0,
    ("src/driver_codegen_inputs.zig", "session.buildVerifiedProgramFromDecls(decls"): 0,
    ("src/driver_codegen_inputs.zig", "session.buildVerifiedProgramFromResolvedDecls(resolved_decls"): 1,
    ("src/driver_codegen_inputs.zig", "session.buildMirFromResolvedDecls(resolved_decls"): 1,
    ("src/driver_codegen_inputs.zig", "DeclarationArtifacts.collectFromResolvedDecls(session.allocator, resolved_decls)"): 2,
    ("src/driver_codegen_inputs.zig", "DeclarationArtifacts.collectFromResolvedDecls(session.allocator, fallback_decls)"): 0,
    ("src/driver_codegen_inputs.zig", "fn fallbackResolvedDecls("): 0,
    ("src/driver_codegen_inputs.zig", "fn collectDeclarationArtifacts(session: *CompilationSession, module: ast.Module)"): 0,
    ("src/driver_codegen_inputs.zig", "fn collectDeclarationArtifacts(session: *CompilationSession)"): 0,
    ("src/driver_codegen_inputs.zig", "fn collectResolvedDecls(session: *CompilationSession)"): 1,
    ("src/driver_codegen_inputs.zig", "return error.MissingResolvedSources"): 1,
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
    ("src/declaration_artifacts.zig", "pub const SyntaxDeclarationSlice = []const ast.Decl"): 0,
    ("src/declaration_artifacts.zig", "pub fn collectFromSyntaxDecls("): 0,
    ("src/declaration_artifacts.zig", "fn collectFromSyntaxDecls("): 0,
    ("src/declaration_artifacts.zig", "fn collectFromResolvedDeclItems("): 1,
    ("src/declaration_artifacts.zig", "pub fn collectFromResolvedDecls("): 1,
    ("src/declaration_artifacts.zig", "pub fn collectFromModuleDeclsForTests("): 0,
    ("src/declaration_artifacts.zig", "[]const module_parser.ResolvedDecl"): 1,
    ("src/declaration_artifacts.zig", "var syntax_decls = try allocator.alloc(ast.Decl"): 0,
    ("src/declaration_artifacts.zig", "syntax_decls[i] = entry.decl"): 0,
    ("src/declaration_artifacts.zig", "return collectFromSyntaxDecls(allocator, syntax_decls)"): 0,
    ("src/declaration_artifacts.zig", "pub const EarlyDeclarationArtifacts = struct"): 1,
    ("src/declaration_artifacts.zig", "function_artifacts: []const FunctionArtifact"): 1,
    ("src/declaration_artifacts.zig", "global_artifacts: []const ast.GlobalDecl"): 0,
    ("src/declaration_artifacts.zig", "global_artifacts: []const GlobalArtifact"): 1,
    ("src/declaration_artifacts.zig", "trait_artifacts: []const TraitArtifact"): 0,
    ("src/declaration_artifacts.zig", "trait_decl_artifacts: []const TraitDeclArtifact"): 1,
    ("src/declaration_artifacts.zig", "impl_trait_artifacts: []const ImplTraitArtifact"): 1,
    ("src/declaration_artifacts.zig", "type_alias_artifacts: []const ast.TypeAlias"): 0,
    ("src/declaration_artifacts.zig", "struct_artifacts: []const ast.StructDecl"): 0,
    ("src/declaration_artifacts.zig", "enum_artifacts: []const ast.EnumDecl"): 0,
    ("src/declaration_artifacts.zig", "union_artifacts: []const ast.UnionDecl"): 0,
    ("src/declaration_artifacts.zig", "packed_bits_artifacts: []const ast.PackedBitsDecl"): 0,
    ("src/declaration_artifacts.zig", "overlay_union_artifacts: []const ast.OverlayUnionDecl"): 0,
    ("src/declaration_artifacts.zig", "type_decl_artifacts: []const TypeDeclArtifact"): 1,
    ("src/declaration_artifacts.zig", "pub const TypeDeclArtifact = union(enum)"): 1,
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
    ("src/loader.zig", "fn recordSourceFile("): 1,
    ("src/module_graph.zig", "pub const ModuleGraph = struct"): 1,
    ("src/module_graph.zig", "pub const SourceDatabase = struct"): 1,
    ("src/module_graph.zig", "pub const LoadedProject = struct"): 1,
    ("src/module_graph.zig", "source_db: SourceDatabase"): 1,
    ("src/module_graph.zig", "parser_source: []const u8"): 1,
    ("src/module_graph.zig", "combined textual source"): 1,
    ("src/ast.zig", "pub fn withDecls"): 0,
    ("src/module_parser.zig", "pub const ParsedSourceDatabase = struct"): 1,
    ("src/module_parser.zig", "pub const ResolvedSourceFile = struct"): 1,
    ("src/module_parser.zig", "pub const ResolvedSourceFile = struct {\n    id: module_graph.FileId,\n    module: ast.Module"): 0,
    ("src/module_parser.zig", "pub const ResolvedSourceFile = struct {\n    id: module_graph.FileId,\n    decls: []ast.Decl"): 1,
    ("src/module_parser.zig", "pub const ResolvedSourceDatabase = struct"): 1,
    ("src/module_parser.zig", "pub const ResolvedDecl = struct"): 1,
    ("src/module_parser.zig", "pub fn collectDecls(self: ResolvedSourceDatabase"): 1,
    ("src/module_parser.zig", "parseSourceDatabase("): 3,
    ("src/module_parser.zig", "resolveParsedSourceDatabase("): 2,
    ("src/main.zig", "resolved_sources.files"): 0,
    ("src/main.zig", "resolved_sources.collectDecls"): 1,
    ("src/main.zig", "symbols.emitJson(allocator, module, &diag, &output)"): 0,
    ("src/main.zig", "fn appendModuleTests("): 0,
    ("src/main.zig", "try appendModuleTests(allocator, module, &out)"): 0,
    ("src/main.zig", "ir.appendFacts(allocator, module, &facts)"): 0,
    ("src/main.zig", "ir.appendLowerIr(allocator, module, &output)"): 0,
    ("src/ir_inspection.zig", "pub fn appendLowerIr(allocator: std.mem.Allocator, module: ast.Module"): 0,
    ("src/ir_inspection.zig", "pub fn appendLowerIrFromResolvedSources("): 1,
    ("src/ir_inspection.zig", "pub const Collector = struct"): 0,
    ("src/ir_inspection.zig", "pub fn appendFactsFromResolvedSources("): 1,
    ("src/ir_inspection.zig", "pub fn appendFactsFromResolvedSources(\n    allocator: std.mem.Allocator,\n    module: ast.Module"): 0,
    ("src/ir_inspection.zig", "pub fn appendFacts(\n        allocator: std.mem.Allocator"): 0,
    ("src/ir_inspection.zig", "pub fn appendFacts(\n    allocator: std.mem.Allocator,\n    module: ast.Module"): 0,
    ("src/ir_inspection.zig", "pub fn writeFacts("): 0,
    ("src/ir_inspection.zig", "fn writeFacts(self: *ModuleFactCollector"): 0,
    ("src/ir_inspection.zig", "fn collectDeclFacts(self: *ModuleFactCollector, module: ast.Module)"): 0,
    ("src/ir_inspection.zig", "try Collector.appendFacts(allocator, module, out)"): 0,
    ("src/ir_inspection.zig", "Collector.appendFactsFromResolvedSources"): 0,
    ("src/ir_inspection.zig", "Collector.writeFacts"): 0,
    ("src/ir_tests.zig", "try ir.appendFacts(std.testing.allocator, module, &facts)"): 0,
    ("src/ir_tests.zig", "var module_ir = try ir.buildModuleIr(std.testing.allocator, module)"): 0,
    ("src/ir_tests.zig", "ir.buildModuleIr(failing.allocator(), module)"): 0,
    ("src/ir_tests.zig", "try ir.appendFactsFromResolvedSources(std.testing.allocator, fixture.resolved, &facts)"): 1,
    ("src/ir_tests.zig", "var module_ir = try ir.buildModuleIrFromDecls(std.testing.allocator, decls)"): 1,
    ("src/ir_tests.zig", "ir.buildModuleIrFromDecls(failing.allocator(), decls)"): 1,
    ("src/ir_inspection.zig", "pub fn buildModuleIr("): 0,
    ("src/ir_inspection.zig", "pub fn buildModuleIrFromModuleForSpecHarness("): 0,
    ("src/ir_inspection.zig", "pub fn buildModuleIrFromDeclSliceForSpecHarness("): 1,
    ("src/spec_tests.zig", "ir.buildModuleIr(allocator, module)"): 0,
    ("src/spec_tests.zig", "ir.buildModuleIrFromModuleForSpecHarness(allocator, module)"): 0,
    ("src/spec_tests.zig", "ir.buildModuleIrFromDeclSliceForSpecHarness(allocator, module.decls)"): 1,
    ("src/spec_tests.zig", "try ir.appendFacts(allocator, module, &facts)"): 0,
    ("src/spec_tests.zig", "try ir.appendFacts(allocator, module.decls, &facts)"): 1,
    ("src/main.zig", "fn backendUnsupportedFallbackSpan("): 0,
    ("src/main.zig", "reportBackendUnsupportedFallback(&diag, module"): 0,
    ("src/symbols.zig", "sources.files"): 0,
    ("src/symbols.zig", "sources.collectDecls"): 1,
    ("src/symbols.zig", "pub fn emitJson(allocator: std.mem.Allocator, module: ast.Module"): 0,
    ("src/symbols.zig", "fn collectModule("): 0,
    ("src/symbols.zig", "fn walkModule("): 0,
    ("src/ir_inspection.zig", "sources.files"): 0,
    ("src/ir_inspection.zig", "sources.collectDecls"): 2,
    ("src/hir_inspection.zig", "inspection_only_header"): 3,
    ("src/hir_inspection.zig", "pub fn build(allocator: std.mem.Allocator, module: ast.Module"): 0,
    ("src/hir_inspection.zig", "pub fn verify(allocator: std.mem.Allocator, module: ast.Module"): 0,
    ("src/hir_inspection.zig", "pub fn appendVerificationFacts(allocator: std.mem.Allocator, module: ast.Module"): 0,
    ("src/hir_inspection.zig", "pub fn appendDump(allocator: std.mem.Allocator, module: ast.Module"): 0,
    ("src/hir_inspection.zig", "pub fn appendDumpFromDecls("): 1,
    ("src/hir_inspection.zig", "pub fn appendVerificationFactsFromDecls("): 1,
    ("src/hir_inspection.zig", "pub fn buildFromDecls("): 1,
    ("src/hir_inspection.zig", "pub fn verifyFromDecls("): 1,
    ("src/main.zig", "hir.appendDump(allocator, module, &output)"): 0,
    ("src/main.zig", "hir.appendDumpFromDecls(allocator, module.decls, &output)"): 0,
    ("src/main.zig", "hir.appendDumpFromDecls(allocator, parsed.decls(), &output)"): 1,
    ("src/main.zig", "hir.appendVerificationFacts(allocator, module, &output)"): 0,
    ("src/main.zig", "hir.appendVerificationFactsFromDecls(allocator, module.decls, &output)"): 0,
    ("src/main.zig", "hir.appendVerificationFactsFromDecls(allocator, parsed.decls(), &output)"): 1,
    ("src/spec_tests.zig", "hir.appendVerificationFacts(allocator, module, &hir_facts)"): 0,
    ("src/spec_tests.zig", "hir.appendVerificationFactsFromDecls(allocator, module.decls, &hir_facts)"): 1,
    ("src/hir_tests.zig", "appendVerificationFacts(std.testing.allocator, module, &facts)"): 0,
    ("src/hir_tests.zig", "appendVerificationFactsFromDecls(std.testing.allocator, module.decls, &facts)"): 2,
    ("src/hir_tests.zig", "const build = hir.build"): 0,
    ("src/hir_tests.zig", "const appendDump = hir.appendDump"): 0,
    ("src/hir_tests.zig", "const verify = hir.verify"): 0,
    ("src/mir.zig", "pub fn build(allocator: std.mem.Allocator, module: ast.Module"): 0,
    ("src/mir.zig", "pub fn buildOpt(allocator: std.mem.Allocator, module: ast.Module"): 0,
    ("src/mir.zig", "pub fn appendDump(allocator: std.mem.Allocator, module: ast.Module"): 0,
    ("src/mir.zig", "pub fn appendDumpOpt(allocator: std.mem.Allocator, module: ast.Module"): 0,
    ("src/mir.zig", "pub fn appendVerificationFacts(allocator: std.mem.Allocator, module: ast.Module"): 0,
    ("src/mir.zig", "pub fn verify(allocator: std.mem.Allocator, module: ast.Module"): 0,
    ("src/mir.zig", "pub fn verifyOpt(allocator: std.mem.Allocator, module: ast.Module"): 0,
    ("src/mir.zig", "pub fn buildFromDecls("): 1,
    ("src/mir.zig", "@import(\"module_parser.zig\")"): 1,
    ("src/mir.zig", "pub fn buildOptFromResolvedDecls("): 1,
    ("src/mir.zig", "fn buildOptFromDeclItems("): 1,
    ("src/mir.zig", "fn declFromBuildItem("): 1,
    ("src/mir.zig", "fn syntaxDeclsFromResolved("): 0,
    ("src/mir.zig", "pub fn buildOptFromDecls("): 1,
    ("src/mir.zig", "pub fn appendDumpFromDecls("): 1,
    ("src/mir.zig", "pub fn appendDumpOptFromDecls("): 1,
    ("src/mir.zig", "pub fn appendVerificationFactsFromDecls("): 1,
    ("src/mir.zig", "pub fn verifyFromDecls("): 1,
    ("src/mir.zig", "pub fn verifyOptFromDecls("): 1,
    ("src/mir.zig", "ast.Module{ .decls = decls }"): 0,
    ("src/mir.zig", "module: ast.Module"): 0,
    ("src/mir.zig", "for (module.decls)"): 0,
    ("src/mir.zig", "collectDropGlueFacts(allocator, module"): 0,
    ("src/mir.zig", "collectTypeOwnershipFacts(allocator, module"): 0,
    ("src/mir.zig", "collectDirectAggregateReturnPointerFacts(allocator, module"): 0,
    ("src/mir.zig", "collectDirectGlobalPointerReturnSummaries(allocator, module"): 0,
    ("src/eval.zig", "pub fn runTrapExpectation("): 0,
    ("src/eval.zig", "pub fn runTrapExpectationFromDecls("): 1,
    ("src/generic_precheck.zig", "pub fn check(\n    allocator: std.mem.Allocator,\n    module: ast.Module"): 0,
    ("src/generic_precheck.zig", "pub fn checkDecls("): 1,
    ("src/generic_precheck.zig", "checker.checkModule(module)"): 0,
    ("src/generic_precheck.zig", "checker.checkDecls(decls, visibility_mode"): 1,
    ("src/sema.zig", "pub fn checkModule(self: *Checker, module: ast.Module"): 0,
    ("src/sema.zig", "pub fn checkDecls(self: *Checker, decls: []ast.Decl"): 1,
    ("src/sema.zig", "self.checkTopLevelNames(module)"): 0,
    ("src/sema.zig", "self.checkTopLevelNames(decls)"): 1,
    ("src/sema.zig", "self.collectTypeAliases(module"): 0,
    ("src/sema.zig", "self.collectTypeAliases(decls"): 1,
    ("src/sema.zig", "self.collectStructs(module"): 0,
    ("src/sema.zig", "self.collectStructs(decls"): 1,
    ("src/sema.zig", "self.collectFunctions(module"): 0,
    ("src/sema.zig", "self.collectFunctions(decls"): 1,
    ("src/sema.zig", "self.collectGlobals(module"): 0,
    ("src/sema.zig", "self.collectGlobals(decls"): 1,
    ("src/sema.zig", "self.collectDropPointerReleaseFns(module"): 0,
    ("src/sema.zig", "self.collectDropPointerReleaseFns(decls"): 1,
    ("src/sema.zig", "moduleHasSafeModuleAttr(module)"): 0,
    ("src/sema.zig", "moduleHasSafeModuleAttr(decls)"): 1,
    ("src/sema.zig", "moduleHasScopedBorrow(module)"): 0,
    ("src/sema.zig", "moduleHasScopedBorrow(decls)"): 1,
    ("src/sema.zig", "fn checkErrorFromDecls(self: *Checker, module: ast.Module"): 0,
    ("src/sema.zig", "fn checkErrorFromDecls(self: *Checker, decls: []const ast.Decl"): 1,
    ("src/sema.zig", "fn checkBoundedCallCycles(self: *Checker, module: ast.Module"): 0,
    ("src/sema.zig", "fn checkBoundedCallCycles(self: *Checker, decls: []const ast.Decl"): 1,
    ("src/sema.zig", "fn checkBackendNameUniqueness(self: *Checker, module: ast.Module"): 0,
    ("src/sema.zig", "fn checkBackendNameUniqueness(self: *Checker, decls: []const ast.Decl"): 1,
    ("src/sema.zig", "fn checkOrphanImpls(self: *Checker, module: ast.Module"): 0,
    ("src/sema.zig", "fn checkOrphanImpls(self: *Checker, decls: []const ast.Decl"): 1,
    ("src/sema.zig", "fn checkTraits(self: *Checker, module: ast.Module"): 0,
    ("src/sema.zig", "fn checkTraits(self: *Checker, decls: []const ast.Decl"): 1,
    ("src/sema.zig", "for (module.decls)"): 0,
    ("src/sema.zig", "module.visibility_mode"): 0,
    ("src/sema.zig", "module.qualified_owners"): 0,
    ("src/monomorphize.zig", "pub fn transformReport(arena: std.mem.Allocator, module: ast.Module"): 0,
    ("src/monomorphize.zig", "pub fn transformReportOptions(arena: std.mem.Allocator, module: ast.Module"): 0,
    ("src/monomorphize.zig", "pub fn transformDeclsReport("): 1,
    ("src/monomorphize.zig", "pub fn transformDeclsReportOptions("): 1,
    ("src/async_lower.zig", "pub fn transform(arena: std.mem.Allocator, module: ast.Module"): 0,
    ("src/async_lower.zig", "pub fn transformDecls("): 1,
    ("src/async_lower.zig", "fn collectAsyncResourceAggregates(low: *Lowerer, module: ast.Module"): 0,
    ("src/async_lower.zig", "fn collectAsyncResourceAggregates(low: *Lowerer, decls: []const ast.Decl"): 1,
    ("src/name_resolve.zig", "pub fn transform(allocator: std.mem.Allocator, module: ast.Module"): 0,
    ("src/name_resolve.zig", "pub fn transformWithGraph(allocator: std.mem.Allocator, module: ast.Module"): 0,
    ("src/name_resolve.zig", "pub fn transformDeclsWithSymbols("): 1,
    ("src/compiler_session.zig", "pub const CheckedModule = struct"): 1,
    ("src/compiler_session.zig", "pub const ParsedModule = struct"): 1,
    ("src/compiler_session.zig", "module: ast.Module"): 0,
    ("src/compiler_session.zig", "fn parseModuleOrReportMode(self: *CompilationSession, source: []const u8, allocator: std.mem.Allocator, diag: *diagnostics.Reporter, render_errors: bool) !ast.Module"): 0,
    ("src/compiler_session.zig", "fn parseModuleOrReportMode(self: *CompilationSession, source: []const u8, allocator: std.mem.Allocator, diag: *diagnostics.Reporter, render_errors: bool) !ParsedModule"): 1,
    ("src/compiler_session.zig", ") !CheckedModule {"): 1,
    ("src/compiler_session.zig", "pub fn parseModuleOrReportMode("): 0,
    ("src/compiler_session.zig", "pub fn checkModule(self: *CompilationSession, module: ast.Module"): 0,
    ("src/compiler_session.zig", "fn checkModule(self: *CompilationSession, module: ast.Module"): 0,
    ("src/compiler_session.zig", "fn checkDecls(self: *CompilationSession, decls: []ast.Decl"): 1,
    ("src/compiler_session.zig", "checker.checkModule(module)"): 0,
    ("src/compiler_session.zig", "checker.checkDecls(decls, visibility_mode, qualified_owners)"): 1,
    ("src/compiler_session.zig", "name_resolve.transformWithGraph(allocator, module"): 0,
    ("src/compiler_session.zig", "name_resolve.transformDeclsWithSymbols(allocator, module.decls"): 0,
    ("src/compiler_session.zig", "name_resolve.transformDeclsWithSymbols(allocator, decls, qualified_symbols"): 1,
    ("src/compiler_session.zig", "async_lower.transform(allocator, resolved"): 0,
    ("src/compiler_session.zig", "async_lower.transformDecls(allocator, resolved.decls"): 0,
    ("src/compiler_session.zig", "async_lower.transformDecls(allocator, decls, qualified_owners"): 1,
    ("src/compiler_session.zig", "generic_precheck.check(allocator, lowered"): 0,
    ("src/compiler_session.zig", "generic_precheck.checkDecls(allocator, lowered.decls"): 0,
    ("src/compiler_session.zig", "generic_precheck.checkDecls(allocator, decls, visibility_mode"): 1,
    ("src/compiler_session.zig", "monomorphize.transformReport(allocator, lowered"): 0,
    ("src/compiler_session.zig", "monomorphize.transformDeclsReport(allocator, lowered.decls"): 0,
    ("src/compiler_session.zig", "monomorphize.transformDeclsReport(allocator, decls"): 1,
    ("src/compiler_session.zig", "mangle_private.transform(allocator, specialized"): 0,
    ("src/compiler_session.zig", "mangle_private.transformDecls(allocator, specialized.decls"): 0,
    ("src/compiler_session.zig", "mangle_private.transformDecls(allocator, decls, visibility_mode"): 1,
    ("src/compiler_session.zig", "pub fn buildVerifiedProgramFromResolvedDecls("): 1,
    ("src/compiler_session.zig", "pub fn buildMirFromResolvedDecls("): 1,
    ("src/compiler_session.zig", "fn syntaxDeclsFromResolved("): 0,
    ("src/compiler_session.zig", "moduleForInspection"): 0,
    ("src/test_support.zig", "module: ast.Module"): 0,
    ("src/test_support.zig", "syntax_module.withDecls"): 0,
    ("src/test_support.zig", "decls_slice: []ast.Decl"): 1,
    ("src/test_support.zig", "pub fn decls(self: ParsedModule) []ast.Decl"): 1,
    ("src/mangle_private.zig", "pub fn transform(arena: std.mem.Allocator, module: ast.Module"): 0,
    ("src/mangle_private.zig", "pub fn transformDecls("): 1,
    ("src/mangle_private_tests.zig", "mangle_private.transform(arena.allocator(), module"): 0,
    ("src/mangle_private_tests.zig", "mangle_private.transformDecls(arena.allocator(), module.decls"): 3,
    ("src/module_parser.zig", "moduleForFile"): 0,
    ("src/module_parser.zig", "name_resolve.transform(allocator, file.module"): 0,
    ("src/module_parser.zig", "name_resolve.transformDeclsWithSymbols(allocator, file.module.decls"): 0,
    ("src/module_parser.zig", "name_resolve.transformDeclsWithSymbols(allocator, file.decls(), file.qualifiedSymbols(), null)"): 1,
    ("src/module_parser.zig", "file.module.withDecls"): 0,
    ("src/module_parser.zig", "file.module.qualified_symbols"): 0,
    ("src/module_parser.zig", "file.module.decls.len"): 0,
    ("src/module_parser.zig", "file.decls.len"): 1,
    ("src/module_parser.zig", "file.decls()"): 2,
    ("src/module_parser.zig", "file.deinit(allocator)"): 2,
    ("src/module_parser.zig", "pub fn declsForFile("): 2,
    ("src/main.zig", "parsed.decls()"): 4,
    ("src/main.zig", "parsed.moduleForInspection()"): 0,
    ("src/lower_c.zig", "pub fn appendInspection(allocator: std.mem.Allocator, module"): 0,
    ("src/lower_c.zig", "pub fn appendInspectionFromDecls("): 1,
    ("src/lower_c_inspect.zig", "pub fn appendInspection(allocator: std.mem.Allocator, module"): 0,
    ("src/lower_c_inspect.zig", "pub fn appendInspectionFromDecls("): 1,
    ("src/lower_c_inspect.zig", "for (module.decls)"): 0,
    ("src/spec_tests.zig", "lower_c.appendInspection(allocator, module"): 0,
    ("src/spec_tests.zig", "lower_c.appendInspectionFromDecls(allocator, module.decls"): 1,
    ("src/spec_tests.zig", "name_resolve.transform(allocator, module"): 0,
    ("src/spec_tests.zig", "name_resolve.transformDeclsWithSymbols(allocator, module.decls"): 1,
    ("src/spec_tests.zig", "generic_precheck.check(allocator, resolved"): 0,
    ("src/spec_tests.zig", "generic_precheck.checkDecls(allocator, resolved.decls"): 1,
    ("src/spec_tests.zig", "monomorphize.transformReport(allocator, resolved"): 0,
    ("src/spec_tests.zig", "monomorphize.transformDeclsReport(allocator, resolved.decls"): 1,
    ("src/spec_tests.zig", "fn appendCModuleTest("): 0,
    ("src/spec_tests.zig", "fn appendLlvmModuleTest("): 0,
    ("src/spec_tests.zig", "fn appendCDeclsTest("): 1,
    ("src/spec_tests.zig", "fn appendLlvmDeclsTest("): 1,
    ("src/lower_c_tests.zig", "fn appendCModuleTest("): 0,
    ("src/lower_c_tests.zig", "fn appendCProfileWithSourcePathTest("): 0,
    ("src/lower_c_tests.zig", "fn appendCProfileWithMirTest("): 0,
    ("src/lower_c_tests.zig", "fn appendCSourceMapTest("): 0,
    ("src/lower_c_tests.zig", "fn appendCDeclsTest("): 1,
    ("src/lower_c_tests.zig", "fn appendCProfileWithSourcePathDeclsTest("): 1,
    ("src/lower_c_tests.zig", "fn appendCProfileWithMirDeclsTest("): 1,
    ("src/lower_c_tests.zig", "fn appendCSourceMapDeclsTest("): 1,
    ("src/lower_c_tests.zig", "fn appendLlvmModuleTest("): 0,
    ("src/lower_c_tests.zig", "fn appendLlvmDeclsTest("): 1,
    ("src/lower_llvm_tests.zig", "fn appendLlvmModuleTest("): 0,
    ("src/lower_llvm_tests.zig", "fn appendLlvmWithSourcePathTest("): 0,
    ("src/lower_llvm_tests.zig", "fn appendLlvmCheckedTest("): 0,
    ("src/lower_llvm_tests.zig", "fn appendLlvmCheckedMirTest("): 0,
    ("src/lower_llvm_tests.zig", "fn appendLlvmCheckedMirProfileTest("): 0,
    ("src/lower_llvm_tests.zig", "fn appendLlvmDeclsTest("): 1,
    ("src/lower_llvm_tests.zig", "fn appendLlvmWithSourcePathDeclsTest("): 1,
    ("src/lower_llvm_tests.zig", "fn appendLlvmCheckedDeclsTest("): 1,
    ("src/lower_llvm_tests.zig", "fn appendLlvmCheckedMirDeclsTest("): 1,
    ("src/lower_llvm_tests.zig", "fn appendLlvmCheckedMirProfileDeclsTest("): 1,
    ("src/main.zig", "checked.decls()"): 3,
    ("src/main.zig", "buildVerifiedProgramFromDecls(module.decls"): 0,
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
        "per-file source ownership",
    ),
    "src/module_parser.zig": (
        "parser-owned per-file syntax boundary",
        "per-file name-resolution boundary",
        "ResolvedDecl",
        "SourceDatabase.parser_source",
        "independent from expanded byte offsets",
    ),
    "src/hir_inspection.zig": (
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
        "Declaration artifacts for the remaining codegen compatibility edge.",
        "Backends consume these through `codegen_request`",
        "Transitional declaration artifacts isolated from backend lowering requests.",
    ),
    "src/driver_codegen_inputs.zig": (
        "Driver-owned codegen input assembly.",
        "session-owned resolved declaration stream",
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
