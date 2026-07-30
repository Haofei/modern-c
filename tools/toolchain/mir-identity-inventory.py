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
        "typed_value_id: ?ValueId = null,",
        "typed_value_id: ValueId = .invalid,",
        "pub const ValueIdentity = struct {",
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
        "value_ids: std.StringHashMap(ValueId),",
        "fn internValueId(self: *FunctionBuilder, spelling: []const u8) !ValueId {",
        "fn buildValueIdentities(self: *FunctionBuilder) ![]ValueIdentity {",
        "for (function.value_identities) |identity| {",
        ".typed_value_id = typed_value_id,",
        "fn representationTypedValueIdsCompatible(instruction: Instruction, fact: RepresentationFact) bool {",
        "pub fn appendDumpFromMir(allocator: std.mem.Allocator, module_mir: Module, out: *std.ArrayList(u8)) !void {",
    ):
        require_contains("src/mir.zig", needle)

    for needle in (
        "const BlockId = mir.BlockId;",
        "const ValueId = mir.ValueId;",
        "fn valueIdentityBySpelling(function: mir.Function, spelling: []const u8) ?mir.ValueIdentity {",
        'test "MIR block model carries typed block identity"',
        'test "MIR verifier rejects typed successor drift in CFG"',
        'test "MIR representation admission rejects typed value identity drift"',
        "try std.testing.expectEqual(BlockId.fromIndex(block.id), block.typed_id);",
        "try std.testing.expectEqual(block.successors.len, block.typed_successors.len);",
        "try std.testing.expectEqual(read_fn.representation_facts[0].typed_value_id, read_fn.representation_facts[2].typed_value_id);",
        'try std.testing.expect(std.mem.indexOf(u8, dump.items, "mir value_identity fn=read_ptr_param id=0 spelling=p") != null);',
        "read_fn.representation_facts[0].typed_value_id = ValueId.fromIndex(4096);",
    ):
        require_contains("src/mir_tests.zig", needle)

    for path, needle in (
        ("docs/refactoring-plan.md", "Block identity now has a typed `BlockId` seed"),
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
