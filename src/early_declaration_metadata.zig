const ast = @import("ast.zig");
const std = @import("std");

pub const DeclarationSlice = []const ast.Decl;

/// Transitional early declaration artifacts.
///
/// Early declaration prepasses still read top-level syntax declarations, but
/// declaration enumeration is isolated here instead of being exposed through
/// backend lowering requests as a generic legacy view.
pub const EarlyDeclarationArtifacts = struct {
    decls: DeclarationSlice,

    pub fn collectFromDecls(allocator: std.mem.Allocator, decls: DeclarationSlice) !EarlyDeclarationArtifacts {
        _ = allocator;
        return .{ .decls = decls };
    }

    pub fn deinit(self: *EarlyDeclarationArtifacts, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.* = .{ .decls = &.{} };
    }

    pub fn declsForComptimeEvaluation(self: EarlyDeclarationArtifacts) DeclarationSlice {
        return self.decls;
    }

    pub fn declsForLegacyArtifactEnumeration(self: EarlyDeclarationArtifacts) DeclarationSlice {
        return self.decls;
    }
};
