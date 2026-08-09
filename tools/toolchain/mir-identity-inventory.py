#!/usr/bin/env python3
"""Check the typed MIR identity migration seed stays anchored.

This is intentionally a narrow Phase 2 ratchet: it does not claim MIR is fully
typed yet. It makes the first typed identity domain explicit and prevents the
tree from drifting back to raw block indexes only.
"""

from __future__ import annotations

import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def fail(message: str) -> None:
    print(f"FAIL: mir-identity-inventory - {message}", file=sys.stderr)
    sys.exit(1)


def read(path: str) -> str:
    full = ROOT / path
    if not full.is_file():
        fail(f"missing {path}")
    return full.read_text(encoding="utf-8")


def require_contains(path: str, needle: str) -> None:
    if needle not in read(path):
        fail(f"{path} missing {needle!r}")


def require_not_contains(path: str, needle: str) -> None:
    if needle in read(path):
        fail(f"{path} unexpectedly contains {needle!r}")


def main() -> int:
    for needle in (
        "fn TypedIndex(comptime name: []const u8) type {",
        "pub const SourceId = TypedIndex(\"SourceId\");",
        "pub const NodeId = TypedIndex(\"NodeId\");",
        "pub const SymbolId = TypedIndex(\"SymbolId\");",
        "pub const TypeId = TypedIndex(\"TypeId\");",
        "pub const ValueId = TypedIndex(\"ValueId\");",
        "pub const BlockId = TypedIndex(\"BlockId\");",
        "pub const SpanId = TypedIndex(\"SpanId\");",
        "pub const OwnershipEventKind = enum",
        "pub const OwnershipPlace = struct",
        "root_type_symbol_id: SymbolId = .invalid,",
        "pub const OwnershipEvent = struct",
        "pub const TypeOwnershipKind = enum",
        "pub const TypeOwnershipFact = struct",
        "pub fn eql(self: @This(), other: @This()) bool {",
        "typed_symbol_id: SymbolId = .invalid,",
        "typed_span_id: SpanId = .invalid,",
        "typed_span_id: SpanId = .invalid,",
        "typed_span_id: SpanId = .invalid,",
        "pub const SymbolIdentity = struct {",
        "pub const SpanIdentity = struct {",
        "typed_result_ty: TypeId = .invalid,",
        "typed_result_ty: TypeId = .invalid,",
        "typed_result_ty: TypeId = .invalid,",
        "pub const TypeIdentity = struct {",
        "typed_value_id: ?ValueId = null,",
        "typed_value_id: ValueId = .invalid,",
        "pub const ValueIdentity = struct {",
        "typed_target_owner_id: ?SymbolId = null,",
        "typed_target_owner_id: SymbolId = .invalid,",
        "target_owner_identities: []SymbolIdentity = &.{},",
        "ownership_events: []OwnershipEvent = &.{},",
        "type_ownership_facts: []TypeOwnershipFact = &.{},",
        "symbol_identities: []SymbolIdentity = &.{},",
        "span_identities: []SpanIdentity = &.{},",
        "type_identities: []TypeIdentity = &.{},",
        "typed_id: BlockId = .invalid,",
        "typed_successors: []BlockId = &.{},",
    ):
        require_contains("src/mir_model.zig", needle)

    for needle in (
        "pub const BlockId = mir_model.BlockId;",
        "pub const OwnershipEvent = mir_model.OwnershipEvent;",
        ".typed_id = BlockId.fromIndex(block.id),",
        ".typed_successors = typed_successors,",
        "if (block.typed_id.isValid() and block.typed_id.index() != block.id) return blockLastSpan(block);",
        "if (block.typed_successors.len != 0) {",
        "pub const SymbolIdentity = mir_model.SymbolIdentity;",
        "pub const TypeIdentity = mir_model.TypeIdentity;",
        "pub const TypeOwnershipFact = mir_model.TypeOwnershipFact;",
        "fn collectTypeOwnershipFacts(",
        "fn dropGlueSymbolForType(drop_glue_facts: []const DropGlueFact, type_name: []const u8) SymbolId {",
        "pub fn validateTypeOwnershipFactsForLowering(module: Module) error{InvalidMirTypeOwnershipFacts}!void {",
        "fn typeOwnershipSymbolIdentityValid(module: Module, fact: TypeOwnershipFact) bool {",
        "fn internSymbolId(symbol_ids: *std.StringHashMap(SymbolId), spelling: []const u8) !SymbolId {",
        "fn buildSymbolIdentities(allocator: std.mem.Allocator, symbol_ids: *std.StringHashMap(SymbolId)) ![]SymbolIdentity {",
        "for (module_mir.symbol_identities) |identity| {",
        "for (module_mir.type_ownership_facts) |fact| {",
        "verifyModuleSymbolIdentities(mir, reporter);",
        "verifyFunctionOwnershipEvents(mir, function, reporter);",
        "fn verifyModuleSymbolIdentities(module: Module, reporter: *diagnostics.Reporter) void {",
        "verifyFunctionInstructionIdentities(function, reporter);",
        "fn verifyFunctionInstructionIdentities(function: Function, reporter: *diagnostics.Reporter) void {",
        "fn instructionTypedIdentitiesValid(function: Function, instruction: Instruction) bool {",
        "pub const SpanIdentity = mir_model.SpanIdentity;",
        "span_ids: std.AutoHashMap(SourcePoint, SpanId),",
        "fn internSpanId(self: *FunctionBuilder, source: SourcePoint) !SpanId {",
        "fn buildSpanIdentities(self: *FunctionBuilder) ![]SpanIdentity {",
        "for (function.span_identities) |identity| {",
        "type_ids: std.StringHashMap(TypeId),",
        "value_ids: std.StringHashMap(ValueId),",
        "target_owner_ids: std.StringHashMap(SymbolId),",
        "fn internTypeId(self: *FunctionBuilder, ty: ValueType) !TypeId {",
        "fn buildTypeIdentities(self: *FunctionBuilder) ![]TypeIdentity {",
        "for (function.type_identities) |identity| {",
        "fn internValueId(self: *FunctionBuilder, spelling: []const u8) !ValueId {",
        "fn buildValueIdentities(self: *FunctionBuilder) ![]ValueIdentity {",
        "for (function.value_identities) |identity| {",
        "fn internTargetOwnerId(self: *FunctionBuilder, spelling: []const u8) !SymbolId {",
        "fn buildTargetOwnerIdentities(self: *FunctionBuilder) ![]SymbolIdentity {",
        "for (function.target_owner_identities) |identity| {",
        ".typed_span_id = typed_span_id,",
        ".typed_result_ty = typed_result_ty,",
        ".typed_value_id = typed_value_id,",
        ".typed_target_owner_id = typed_target_owner_id,",
        "fn targetTypeTypedOwnerCompatible(instruction: Instruction, fact: TargetTypeFact) bool {",
        "fn targetTypeTypedResultCompatible(instruction: Instruction, fact: TargetTypeFact) bool {",
        "fn targetTypeTypedSpanCompatible(instruction: Instruction, fact: TargetTypeFact) bool {",
        "fn targetTypeInstructionSpansCompatible(left: Instruction, right: Instruction) bool {",
        "fn representationFactTypedIdentitiesValid(function: Function, fact: RepresentationFact) bool {",
        "if (!fact.typed_result_ty.isValid()) return false;",
        "if (!fact.typed_span_id.isValid()) return false;",
        "fn representationTypedSpansCompatible(instruction: Instruction, fact: RepresentationFact) bool {",
        "fn representationSourceMatches(instruction: Instruction, fact: RepresentationFact) bool {",
        "fn representationTypedResultTypesCompatible(instruction: Instruction, fact: RepresentationFact) bool {",
        "fn representationTypedValueIdsCompatible(instruction: Instruction, fact: RepresentationFact) bool {",
        "pub fn validateOwnershipEventsForLowering(module: Module) error{InvalidMirOwnershipEvents}!void {",
        "fn ownershipEventValid(module: Module, function: Function, event: OwnershipEvent) bool {",
        "fn ownershipEventSequenceValid(function: Function) bool {",
        "fn typedOwnershipRootsClosed(function: Function) bool {",
        "fn ownershipRootStateBefore(function: Function, event_index: usize, root: ValueId) OwnershipRootState {",
        "fn ownershipRootGenerationBefore(function: Function, event_index: usize, root: ValueId) u32 {",
        "fn simpleOwnershipRootValue(place: OwnershipPlace) ?ValueId {",
        "fn addDiscardOwnershipEvent(self: *FunctionBuilder, target: CallTargetKind, argument: ast.Expr, call_span: ast.Span) !void {",
        ".root_type_symbol_id = root_type_symbol_id,",
        "root_type_symbol={}",
        "fn ownershipDropGlueSymbolMatchesPlace(module: Module, event: OwnershipEvent) bool {",
        "fn discardArgumentDropGlueIdentity(self: *FunctionBuilder, argument: ast.Expr) ?DiscardDropGlueIdentity {",
        "fn dropGlueIdentityForTypeName(self: *FunctionBuilder, type_name: []const u8) ?DiscardDropGlueIdentity {",
        "fn localRootTypeSymbol(self: *FunctionBuilder, name: []const u8) SymbolId {",
        "fn appendSimpleLocalCleanupOwnershipEvents(self: *FunctionBuilder) !void {",
        "fn currentOwnershipRootState(self: *FunctionBuilder, root: ValueId) OwnershipRootState {",
        "fn currentOwnershipRootGeneration(self: *FunctionBuilder, root: ValueId) u32 {",
        "fn ownershipGenerationForLocalEvent(self: *FunctionBuilder, kind: OwnershipEventKind, root: ValueId) u32 {",
        "fn addLocalOwnershipEvent(self: *FunctionBuilder, kind: OwnershipEventKind, name: []const u8, span: ast.Span) !void {",
        "const drop_glue_identity = self.discardArgumentDropGlueIdentity(argument) orelse return;",
        "const root_type_symbol_id = self.localRootTypeSymbol(name);",
        "try self.appendSimpleLocalCleanupOwnershipEvents();",
        "try self.addLocalOwnershipEvent(.storage_live, name.text, stmt.span);",
        "if (local.names.len == 1) try self.addLocalOwnershipEvent(.init, local.names[0].text, expr.span);",
        "if (self.local_mutability.get(target_name) orelse false) {",
        "try self.addLocalOwnershipEvent(.reinit, target_name, node.value.span);",
        "try self.addLocalOwnershipEvent(.move_out, name, expr.span);",
        "try self.addDiscardOwnershipEvent(target, node.args[0], expr.span);",
        "try validateOwnershipEventsForLowering(module);",
        "mir ownership_event fn={s} kind={s}",
        "pub fn appendDumpFromMir(allocator: std.mem.Allocator, module_mir: Module, out: *std.ArrayList(u8)) !void {",
    ):
        require_contains("src/mir.zig", needle)

    for needle in (
        "const BlockId = mir.BlockId;",
        "const SymbolId = mir.SymbolId;",
        "const SourcePoint = mir.SourcePoint;",
        "const SpanId = mir.SpanId;",
        "const TypeId = mir.TypeId;",
        "const ValueId = mir.ValueId;",
        "fn symbolIdentityBySpelling(module: mir.Module, spelling: []const u8) ?mir.SymbolIdentity {",
        "fn spanIdentityBySource(function: mir.Function, source: SourcePoint) ?mir.SpanIdentity {",
        "fn typeIdentityBySpelling(function: mir.Function, spelling: []const u8) ?mir.TypeIdentity {",
        "fn valueIdentityBySpelling(function: mir.Function, spelling: []const u8) ?mir.ValueIdentity {",
        "fn targetOwnerIdentityBySpelling(function: mir.Function, spelling: []const u8) ?mir.SymbolIdentity {",
        'test "MIR block model carries typed block identity"',
        'test "MIR verifier rejects function symbol identity drift"',
        'test "MIR verifier rejects instruction typed identity drift"',
        'test "MIR target-type owner identities mirror direct calls"',
        'test "MIR verifier rejects target owner instruction identity drift"',
        'test "MIR target-type admission rejects target owner fact identity drift"',
        'test "MIR target-type admission rejects target result type identity drift"',
        'test "MIR target-type admission rejects target span identity drift"',
        'test "MIR verifier rejects typed successor drift in CFG"',
        "try std.testing.expect(main_fn.typed_symbol_id.eql(main_symbol.id));",
        "module_mir.functions[0].typed_symbol_id = SymbolId.fromIndex(4096);",
        "type_drift_fn.blocks[0].instructions[0].typed_result_ty = TypeId.fromIndex(4096);",
        "span_drift_fn.blocks[0].instructions[0].typed_span_id = SpanId.fromIndex(4096);",
        'test "MIR representation admission rejects typed span identity drift"',
        'test "MIR representation admission rejects typed result type drift"',
        'test "MIR representation admission requires typed result identity"',
        'test "MIR representation admission rejects typed value identity drift"',
        'test "MIR records canonical type ownership facts"',
        'test "MIR type ownership fact admission rejects symbol and duplicate drift"',
        'test "MIR ownership events are admitted and dumped through typed MIR"',
        'test "MIR records local reinit ownership events"',
        'test "MIR reinit ownership events require mutable locals"',
        'test "MIR records simple move-out ownership events"',
        'test "MIR ownership event admission rejects duplicate local consumption"',
        'test "MIR ownership event admission rejects malformed event identity"',
        "try std.testing.expectEqual(mir.OwnershipEventKind.storage_live, use_guard.ownership_events[0].kind);",
        "try std.testing.expectEqual(mir.OwnershipEventKind.init, use_guard.ownership_events[1].kind);",
        "try std.testing.expectEqual(mir.OwnershipEventKind.reinit, function.ownership_events[2].kind);",
        "try std.testing.expectEqual(mir.OwnershipEventKind.move_out, function.ownership_events[2].kind);",
        "try std.testing.expectEqual(mir.OwnershipEventKind.explicit_drop, function.ownership_events[0].kind);",
        "try std.testing.expectEqual(mir.OwnershipEventKind.forget, function.ownership_events[1].kind);",
        "try std.testing.expectEqual(@as(usize, 0), plain_function.ownership_events.len);",
        "try std.testing.expectEqual(mir.TypeOwnershipKind.affine, ticket.kind);",
        "try std.testing.expectError(error.InvalidMirTypeOwnershipFacts, mir.validateLoweringAdmission(symbol_drift));",
        "try std.testing.expectEqual(BlockId.fromIndex(block.id), block.typed_id);",
        "try std.testing.expectEqual(block.successors.len, block.typed_successors.len);",
        "try std.testing.expect(read_fn.representation_facts[0].typed_span_id.eql(read_load_span_identity.id));",
        "try std.testing.expect(result_fact.typed_span_id.eql(result_span.id));",
        "typed_result_ty_id={}",
        "typed_span_id={}",
        "typed_target_owner_id={}",
        "try std.testing.expectEqual(read_fn.representation_facts[0].typed_result_ty, read_fn.representation_facts[2].typed_result_ty);",
        "try std.testing.expectEqual(read_fn.representation_facts[0].typed_value_id, read_fn.representation_facts[2].typed_value_id);",
        'try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir span_identity fn=read_ptr_param id=") != null);',
        'try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir type_identity fn=read_ptr_param id=") != null);',
        'try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir value_identity fn=read_ptr_param id=0 spelling=p") != null);',
        "expected_repr_result",
        "expected_repr_value",
        "expected_repr_span",
        "read_fn.representation_facts[0].typed_span_id = SpanId.fromIndex(4096);",
        "fact.typed_span_id = SpanId.fromIndex(4096);",
        "read_fn.representation_facts[0].typed_result_ty = TypeId.fromIndex(4096);",
        "fact.typed_result_ty = .invalid;",
        "read_fn.representation_facts[0].typed_value_id = ValueId.fromIndex(4096);",
        "fact.typed_target_owner_id = SymbolId.fromIndex(4096);",
        "fact.typed_result_ty = TypeId.fromIndex(4096);",
        "try std.testing.expectError(error.InvalidMirOwnershipEvents, mir.validateLoweringAdmission(bad_mir));",
        'try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir ownership_event fn=use_guard kind=explicit_drop") != null);',
        "MIR ownership event admission rejects auto-drop without storage-dead",
        "MIR ownership event admission accepts sibling copy locals with reused names",
        "MIR records forget events for no-drop move resources",
        "MIR ownership authority does not let forget authorize auto-drop registration",
        "MIR ownership authority skips cleanup registration for move-out",
        "MIR records explicit drop glue call ownership events",
        "MIR cleanup producer ignores move-out events that cannot reach fallthrough cleanup",
        "MIR ownership event admission enforces local generations",
        "mir.buildOwnershipCleanupPlan",
        "mir.buildOwnershipCleanupEdgeTable",
        "mir.ownershipCleanupEdgeTableValid",
        "mir.appendOwnershipCleanupPlan",
        "mir.appendOwnershipCleanupCancellationPlan",
        "mir.CleanupActionKind.auto_drop",
        "mir.CleanupActionKind.explicit_drop",
        "mir.CleanupCancellationKind.move_out",
        "mir.CleanupCancellationKind.explicit_drop",
        "mir.ownershipLocalHasAutoDropResourceEvent",
        "mir.ownershipLocalHasConsumingResourceEvent",
    ):
        require_contains("src/mir_tests.zig", needle)

    for path, needle in (
        ("src/mir_model.zig", "pub const CleanupActionKind"),
        ("src/mir_model.zig", "pub const CleanupActionPlanEntry"),
        ("src/mir_model.zig", "pub const CleanupCancellationKind"),
        ("src/mir_model.zig", "pub const CleanupCancellationPlanEntry"),
        ("src/mir_model.zig", "pub const OwnershipCleanupPlan"),
        ("src/mir_model.zig", "pub const OwnershipCleanupEdgeKind"),
        ("src/mir_model.zig", "pub const OwnershipCleanupEdgeActionRef"),
        ("src/mir_model.zig", "pub const OwnershipCleanupEdge = struct"),
        ("src/mir_model.zig", "pub const OwnershipCleanupEdgeTable"),
        ("src/mir.zig", "pub fn appendOwnershipCleanupPlan"),
        ("src/mir.zig", "pub fn appendOwnershipCleanupCancellationPlan"),
        ("src/mir.zig", "pub fn buildOwnershipCleanupPlan"),
        ("src/mir.zig", "pub fn buildOwnershipCleanupEdgeTable"),
        ("src/mir.zig", "pub fn ownershipCleanupEdgeTableValid"),
        ("src/mir.zig", "pub const DeferCleanupRef"),
        ("src/mir.zig", "pub fn deferCleanupRefAtSource"),
        ("src/mir.zig", "pub fn deferCleanupRefValid"),
        ("src/mir.zig", "pub fn directDeferCallCleanupForRef"),
        ("src/mir.zig", "pub fn callTargetDeferCleanupForRef"),
        ("src/mir.zig", "fn directCallArgumentFactAtSource"),
        ("src/mir.zig", "pub fn ownershipLocalHasAutoDropResourceEvent"),
        ("src/mir.zig", "pub fn ownershipLocalHasConsumingResourceEvent"),
        ("src/mir.zig", "fn autoDropClosingStorageDeadIndex"),
        ("src/mir.zig", "fn ownershipEventCanReachBlock"),
        ("src/mir.zig", "pub fn sourcePointFromSpan"),
        ("src/mir.zig", "fn typeOwnershipSymbolForTypeName"),
        ("src/mir.zig", "fn addDropGlueCallOwnershipEvent"),
        ("src/mir_ownership_authority.zig", "pub const FunctionDeclArtifact"),
        ("src/mir_ownership_authority.zig", "pub fn dropGlueFactsMatchDeclArtifacts"),
        ("src/mir_ownership_authority.zig", "pub const AutoDropLocalRegistrationDecision"),
        ("src/mir_ownership_authority.zig", "root_value_id: mir.ValueId = .invalid"),
        ("src/mir_ownership_authority.zig", "resource_type_symbol_id: mir.SymbolId = .invalid"),
        ("src/mir_ownership_authority.zig", "drop_glue_symbol_id: mir.SymbolId = .invalid"),
        ("src/mir_ownership_authority.zig", "auto_drop_event_index: usize = std.math.maxInt(usize)"),
        ("src/mir_ownership_authority.zig", "explicit_drop_event_index: usize = std.math.maxInt(usize)"),
        ("src/mir_ownership_authority.zig", "storage_dead_event_index: usize = std.math.maxInt(usize)"),
        ("src/mir_ownership_authority.zig", "pub fn autoDropLocalRegistrationDecision"),
        ("src/mir_ownership_authority.zig", "mir.buildOwnershipCleanupPlan"),
        ("src/mir_ownership_authority.zig", "pub fn autoDropCleanupEmissionAllowed"),
        ("src/mir_ownership_authority.zig", "mir.ownershipLocalHasConsumingResourceEvent"),
        ("src/mir_ownership_authority.zig", "entry.place.root_type_symbol_id.eql(ownership.typed_type_symbol_id)"),
        ("src/mir_ownership_authority.zig", "fn dropGlueFactForSymbols"),
        ("src/mir_ownership_authority.zig", "fn sourceMatches"),
        ("src/mir_ownership_authority.zig", "pub const AutoDropCancellationDecision"),
        ("src/mir_ownership_authority.zig", "pub const OwnershipCleanupActionRef"),
        ("src/mir_ownership_authority.zig", "pub const OwnershipCleanupRemovalRef"),
        ("src/mir_ownership_authority.zig", "pub fn ownershipCleanupActionRef"),
        ("src/mir_ownership_authority.zig", "pub fn autoDropLocalCleanupFromActionRef"),
        ("src/mir_ownership_authority.zig", "pub fn explicitDropLocalCleanupFromActionRef"),
        ("src/mir_ownership_authority.zig", "remove_auto_drop: OwnershipCleanupRemovalRef"),
        ("src/mir_ownership_authority.zig", "pub fn moveAutoDropCancellationDecision"),
        ("src/mir_ownership_authority.zig", "pub fn explicitDropCancellationDecision"),
        ("src/mir_ownership_authority.zig", "try cleanupCancellationPlanEntryForSource"),
        ("src/mir_ownership_authority.zig", "fn removalRefForCancellationEntry"),
        ("src/mir_ownership_authority.zig", "pub fn explicitDropLocalCleanup"),
        ("src/mir_ownership_authority.zig", "pub fn explicitDropCleanupEmissionAllowed"),
        ("src/mir_ownership_authority.zig", "pub fn deferredExplicitDropCleanupDecision"),
        ("src/mir_ownership_authority.zig", "valueIdForLocal(function, release.local_name)"),
        ("src/mir_ownership_authority.zig", "mir.ownershipLocalHasAutoDropResourceEvent"),
        ("src/mir_ownership_authority.zig", "try explicitDropPlanEntryForSource"),
        ("src/backend_cleanup.zig", "pub const DeferredCleanup"),
        ("src/backend_cleanup.zig", "pub const OrdinaryDeferCallCleanup"),
        ("src/backend_cleanup.zig", "pub const CallTargetDeferCleanup"),
        ("src/backend_cleanup.zig", "pub const DeferBlockCleanup"),
        ("src/backend_cleanup.zig", "defer_ref: mir.DeferCleanupRef"),
        ("src/backend_cleanup.zig", "pub fn deferCleanupStackRefsValid"),
        ("src/backend_cleanup.zig", "pub fn deferCleanupEmissionRangeValid"),
        ("src/backend_cleanup.zig", "pub fn deferCleanupEmissionCount"),
        ("src/backend_cleanup.zig", "pub fn deferCleanupAtEmissionIndex"),
        ("src/backend_cleanup.zig", "pub const CleanupEdgeKind"),
        ("src/backend_cleanup.zig", "pub const CleanupRef"),
        ("src/backend_cleanup.zig", "pub const CleanupEdge = struct"),
        ("src/backend_cleanup.zig", "pub const CleanupEdgeTable"),
        ("src/backend_cleanup.zig", "pub fn cleanupEdgeTableValid"),
        ("src/backend_cleanup.zig", "pub const CleanupEdgePlan"),
        ("src/backend_cleanup.zig", "pub fn buildTransitionalCleanupEdgeTable"),
        ("src/backend_cleanup.zig", "pub fn buildCleanupEdgePlan"),
        ("src/backend_cleanup.zig", "pub fn cleanupEdgePlanFromTable"),
        ("src/backend_cleanup.zig", "pub fn cleanupEdgeFor"),
        ("src/backend_cleanup.zig", "pub fn cleanupRef"),
        ("src/backend_cleanup.zig", "pub const DeferCleanupStackSnapshot"),
        ("src/backend_cleanup.zig", "pub fn captureDeferCleanupStack"),
        ("src/backend_cleanup.zig", "pub fn restoreDeferCleanupStack("),
        ("src/backend_cleanup.zig", "pub fn restoreDeferCleanupStackLength"),
        ("src/backend_cleanup.zig", "pub const AutoDropStackDecision"),
        ("src/backend_cleanup.zig", "pub fn registerAutoDropLocalCleanup"),
        ("src/backend_cleanup.zig", "fn autoDropLocalCleanupFromMirEdge"),
        ("src/backend_cleanup.zig", "fn typeOwnershipFactForTypeName"),
        ("src/backend_cleanup.zig", "fn valueIdForLocal"),
        ("src/backend_cleanup.zig", "pub fn cancelAutoDropForMove("),
        ("src/backend_cleanup.zig", "pub fn cancelAutoDropForExplicitDrop"),
        ("src/backend_cleanup.zig", "pub fn registerDeferredExplicitDropCleanup"),
        ("src/backend_cleanup.zig", "pub fn registerOrdinaryDirectDeferCleanup"),
        ("src/backend_cleanup.zig", "pub fn registerOrdinaryCallTargetDeferCleanup"),
        ("src/backend_cleanup.zig", "pub fn registerOrdinaryBlockDeferCleanup"),
        ("src/backend_cleanup.zig", "fn appendValidatedCleanup"),
        ("src/backend_cleanup.zig", "fn deferCleanupRefAfter"),
        ("src/backend_cleanup.zig", "callee: ast.Expr"),
        ("src/backend_cleanup.zig", "callee_span: ast.Span"),
        ("src/backend_cleanup.zig", "type_args: []const ast.TypeExpr"),
        ("src/backend_cleanup.zig", "args: []const ast.Expr"),
        ("src/backend_cleanup.zig", "block: DeferBlockCleanup"),
        ("src/backend_cleanup.zig", "direct_call: OrdinaryDeferCallCleanup"),
        ("src/backend_cleanup.zig", "call_target: CallTargetDeferCleanup"),
        ("src/backend_cleanup.zig", "auto_drop: mir_ownership_authority.OwnershipCleanupActionRef"),
        ("src/backend_cleanup.zig", "explicit_drop: mir_ownership_authority.OwnershipCleanupActionRef"),
        ("src/backend_cleanup.zig", "pub fn removeAutoDropCleanup("),
        ("src/backend_cleanup.zig", "fn autoDropCleanupMatchesRef"),
        ("src/backend_cleanup.zig", "cleanup.cleanup_action_index != ref.cleanup_action_index"),
        ("src/lower_c_tests.zig", "lower-c rejects auto-drop transfer authorization with stale MIR resource type"),
        ("src/lower_c_tests.zig", "lower-c move auto-drop cancellation requires MIR move-out event"),
        ("src/lower_c_tests.zig", "lower-c move auto-drop cancellation requires source-matched MIR move-out event"),
        ("src/lower_c_tests.zig", "lower-c explicit drop release cancellation requires MIR explicit-drop event"),
        ("src/lower_c_tests.zig", "lower-c explicit drop release cancellation requires source-matched MIR explicit-drop event"),
        ("src/lower_llvm_tests.zig", "LLVM rejects auto-drop transfer authorization with stale MIR resource type"),
        ("src/lower_llvm_tests.zig", "LLVM move auto-drop cancellation requires MIR move-out event"),
        ("src/lower_llvm_tests.zig", "LLVM move auto-drop cancellation requires source-matched MIR move-out event"),
        ("src/lower_llvm_tests.zig", "LLVM explicit drop release cancellation requires MIR explicit-drop event"),
        ("src/lower_llvm_tests.zig", "LLVM explicit drop release cancellation requires source-matched MIR explicit-drop event"),
        ("docs/refactoring-plan.md", "MIR already has typed seeds for block, function symbol, value, type, and span"),
        ("docs/refactoring-plan.md", "Verifier/admission checks reject result/span/owner drift."),
        ("docs/typed-semantic-facts.md", "The typed MIR identity migration has started with `BlockId`"),
        ("build/qemu.zig", "mir-identity-inventory-test"),
        ("build/tiers.zig", 'm0_step.dependOn(ctx.cmd("mir-identity-inventory-test"))'),
        ("build/tiers.zig", 'fast_step.dependOn(ctx.cmd("mir-identity-inventory-test"))'),
        ("build/tiers.zig", 'c0_step.dependOn(ctx.cmd("mir-identity-inventory-test"))'),
        ("tools/dev-gates.py", "mir-identity-inventory-test"),
        ("tools/toolchain/dev-gates-test.py", "mir-identity-inventory-test"),
    ):
        require_contains(path, needle)

    require_not_contains("src/mir_ownership_authority.zig", "pub fn authorizesAutoDropLocal")
    require_not_contains("src/mir_ownership_authority.zig", "pub fn authorizesMoveOutLocal(")
    require_not_contains("src/mir_ownership_authority.zig", "fn authorizesMoveOutLocalAutoDrop")
    require_not_contains("src/mir_ownership_authority.zig", "fn localHasConsumingOwnershipEvent")
    require_not_contains("src/mir_ownership_authority.zig", "fn localHasAutoDropOwnershipEvent")
    require_not_contains("src/mir_ownership_authority.zig", "fn autoDropTypeSymbolHasGlue")
    require_not_contains("src/mir_ownership_authority.zig", "fn autoDropGlueSymbolForType")
    require_not_contains("src/mir_ownership_authority.zig", "legacy_cancellable_cleanup")
    require_not_contains("src/mir_ownership_authority.zig", "pub const DeferredCleanup")
    require_not_contains("src/backend_cleanup.zig", "trivial_expr: ast.Expr")
    require_not_contains("src/backend_cleanup.zig", "defer_span")
    require_not_contains("src/backend_cleanup.zig", "ordinaryDeferTrivialExprSupported")
    require_not_contains("src/mir_ownership_authority.zig", "removeAutoDropCleanupForLocalName")
    require_not_contains("src/mir_ownership_authority.zig", "pub const AutoDropCleanupKey")
    require_not_contains("src/mir_ownership_authority.zig", "missingAutoDropCancellationIsAllowed")
    require_not_contains("src/backend_cleanup.zig", "removeAutoDropCleanupForLocalName")
    require_not_contains("src/backend_cleanup.zig", "mir_ownership_authority.AutoDropCleanupKey")
    require_not_contains("src/ownership_facts.zig", "AutoDropCleanupRegistration")
    require_not_contains("src/mir_model.zig", "AutoDropCleanupPlanEntry")
    require_not_contains("src/mir_model.zig", "ExplicitDropCleanupPlanEntry")
    require_not_contains("src/mir.zig", "appendAutoDropCleanupPlan")
    require_not_contains("src/mir.zig", "appendExplicitDropCleanupPlan")
    require_not_contains("src/mir_ownership_authority.zig", "fn authorizesExplicitDropLocal")
    require_not_contains("src/lower_c_emitter.zig", "authorizesAutoDropLocal(")
    require_not_contains("src/lower_llvm.zig", "authorizesAutoDropLocal(")

    print("PASS: mir-identity-inventory - typed MIR identity seed is anchored")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
