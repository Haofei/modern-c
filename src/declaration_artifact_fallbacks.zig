//! Syntax-shaped function body fallbacks for the remaining codegen
//! compatibility edge.
//!
//! This module deliberately contains the legacy `ast.Block` authority so the
//! ordinary declaration artifact model can keep moving toward syntax-free
//! facts. Delete this module when all function bodies lower from verified MIR.

const ast = @import("ast.zig");
const std = @import("std");

/// Compatibility edge for function-body lowering that still needs source-shaped
/// blocks. It is kept out of `FunctionArtifact` so ordinary declaration facts do
/// not grow another syntax body authority while MIR-body lowering is completed.
pub const FunctionBodyFallbackArtifact = struct {
    name: []const u8,
    syntax: ast.Block,
};

pub fn findLegacyFunctionBody(fallbacks: []const FunctionBodyFallbackArtifact, name: []const u8) ?ast.Block {
    for (fallbacks) |fallback| {
        if (std.mem.eql(u8, fallback.name, name)) return fallback.syntax;
    }
    return null;
}
