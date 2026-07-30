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
        "pub fn eql(self: @This(), other: @This()) bool {",
        "typed_symbol_id: SymbolId = .invalid,",
        "typed_span_id: SpanId = .invalid,",
        "typed_span_id: SpanId = .invalid,",
        "pub const SymbolIdentity = struct {",
        "pub const SpanIdentity = struct {",
        "typed_result_ty: TypeId = .invalid,",
        "typed_result_ty: TypeId = .invalid,",
        "pub const TypeIdentity = struct {",
        "typed_value_id: ?ValueId = null,",
        "typed_value_id: ValueId = .invalid,",
        "pub const ValueIdentity = struct {",
        "typed_target_owner_id: ?SymbolId = null,",
        "typed_target_owner_id: SymbolId = .invalid,",
        "target_owner_identities: []SymbolIdentity = &.{},",
        "symbol_identities: []SymbolIdentity = &.{},",
        "span_identities: []SpanIdentity = &.{},",
        "type_identities: []TypeIdentity = &.{},",
        "typed_id: BlockId = .invalid,",
        "typed_successors: []BlockId = &.{},",
    ):
        require_contains("src/mir_model.zig", needle)

    for needle in (
        "pub const BlockId = mir_model.BlockId;",
        ".typed_id = BlockId.fromIndex(block.id),",
        ".typed_successors = typed_successors,",
        "if (block.typed_id.isValid() and block.typed_id.index() != block.id) return blockLastSpan(block);",
        "if (block.typed_successors.len != 0) {",
        "pub const SymbolIdentity = mir_model.SymbolIdentity;",
        "pub const TypeIdentity = mir_model.TypeIdentity;",
        "fn internSymbolId(symbol_ids: *std.StringHashMap(SymbolId), spelling: []const u8) !SymbolId {",
        "fn buildSymbolIdentities(allocator: std.mem.Allocator, symbol_ids: *std.StringHashMap(SymbolId)) ![]SymbolIdentity {",
        "for (module_mir.symbol_identities) |identity| {",
        "verifyModuleSymbolIdentities(mir, reporter);",
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
        "fn representationTypedSpansCompatible(instruction: Instruction, fact: RepresentationFact) bool {",
        "fn representationSourceMatches(instruction: Instruction, fact: RepresentationFact) bool {",
        "fn representationTypedResultTypesCompatible(instruction: Instruction, fact: RepresentationFact) bool {",
        "fn representationTypedValueIdsCompatible(instruction: Instruction, fact: RepresentationFact) bool {",
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
        'test "MIR verifier rejects typed successor drift in CFG"',
        "try std.testing.expect(main_fn.typed_symbol_id.eql(main_symbol.id));",
        "module_mir.functions[0].typed_symbol_id = SymbolId.fromIndex(4096);",
        "type_drift_fn.blocks[0].instructions[0].typed_result_ty = TypeId.fromIndex(4096);",
        "span_drift_fn.blocks[0].instructions[0].typed_span_id = SpanId.fromIndex(4096);",
        'test "MIR representation admission rejects typed span identity drift"',
        'test "MIR representation admission rejects typed result type drift"',
        'test "MIR representation admission rejects typed value identity drift"',
        "try std.testing.expectEqual(BlockId.fromIndex(block.id), block.typed_id);",
        "try std.testing.expectEqual(block.successors.len, block.typed_successors.len);",
        "try std.testing.expect(read_fn.representation_facts[0].typed_span_id.eql(read_load_span_identity.id));",
        "try std.testing.expectEqual(read_fn.representation_facts[0].typed_result_ty, read_fn.representation_facts[2].typed_result_ty);",
        "try std.testing.expectEqual(read_fn.representation_facts[0].typed_value_id, read_fn.representation_facts[2].typed_value_id);",
        'try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir span_identity fn=read_ptr_param id=") != null);',
        'try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir type_identity fn=read_ptr_param id=") != null);',
        'try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir value_identity fn=read_ptr_param id=0 spelling=p") != null);',
        "read_fn.representation_facts[0].typed_span_id = SpanId.fromIndex(4096);",
        "read_fn.representation_facts[0].typed_result_ty = TypeId.fromIndex(4096);",
        "read_fn.representation_facts[0].typed_value_id = ValueId.fromIndex(4096);",
        "fact.typed_target_owner_id = SymbolId.fromIndex(4096);",
    ):
        require_contains("src/mir_tests.zig", needle)

    for path, needle in (
        ("docs/refactoring-plan.md", "MIR already has typed seeds for block, function symbol, value, type, and span"),
        ("docs/refactoring-plan.md", "Add typed `SymbolId` mirrors to target-type owner facts and direct-call instruction metadata."),
        ("docs/typed-semantic-facts.md", "The typed MIR identity migration has started with `BlockId`"),
        ("build/qemu.zig", "mir-identity-inventory-test"),
        ("build/tiers.zig", 'm0_step.dependOn(ctx.cmd("mir-identity-inventory-test"))'),
        ("build/tiers.zig", 'fast_step.dependOn(ctx.cmd("mir-identity-inventory-test"))'),
        ("build/tiers.zig", 'c0_step.dependOn(ctx.cmd("mir-identity-inventory-test"))'),
        ("tools/dev-gates.py", "mir-identity-inventory-test"),
        ("tools/toolchain/dev-gates-test.py", "mir-identity-inventory-test"),
    ):
        require_contains(path, needle)

    print("PASS: mir-identity-inventory - typed MIR identity seed is anchored")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
